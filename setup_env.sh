#!/usr/bin/env bash
# ============================================================
#  setup_env.sh  –  Manage environment variables for SW Rescue
#  Updates values directly in:
#    • docker-compose.yml
#    • rescue_with_trigger.sh
#  Run:  bash setup_env.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
RESCUE_FILE="$SCRIPT_DIR/rescue_with_trigger.sh"
USB_DEV_DEFAULT="/dev/sdb1"   # literal default path baked into docker-compose.yml

# ─── colour helpers ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
section() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }

# ─── validate target files exist ─────────────────────────────
check_files() {
    local missing=0
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        echo -e "${RED}[ERROR]${RESET} docker-compose.yml not found at: $COMPOSE_FILE"
        missing=1
    fi
    if [[ ! -f "$RESCUE_FILE" ]]; then
        echo -e "${RED}[ERROR]${RESET} rescue_with_trigger.sh not found at: $RESCUE_FILE"
        missing=1
    fi
    if [[ $missing -eq 1 ]]; then
        echo -e "${RED}${BOLD}Aborting – required files are missing.${RESET}"
        exit 1
    fi
}

# ─── read current value for a key from both target files ─────
#     Checks docker-compose.yml first, then rescue_with_trigger.sh
#     Handles formats:
#       docker-compose:         - KEY=value          (env block, list style)
#                               KEY: value           (env block, map style)
#       rescue_with_trigger.sh: KEY=value
#                               export KEY=value
#                               KEY="value"  / export KEY="value"
current() {
    local key="$1"
    local val=""

    # ── docker-compose.yml ──
    if [[ -f "$COMPOSE_FILE" ]]; then
        # special case: USB_DEV is stored as a literal device path in the
        # devices: block  (e.g.  - /dev/sdb1:/dev/sdb1), not as KEY=value
        if [[ "$key" == "USB_DEV" ]]; then
            val=$(grep -E "^\s*-\s*/dev/" "$COMPOSE_FILE" \
                  | head -n1 | sed 's|.*-\s*\(/dev/[^:]*\):.*|\1|;s/[[:space:]]//g' || true)
        else
            # list style:  - KEY=value
            val=$(grep -E "^\s*-\s*${key}=" "$COMPOSE_FILE" \
                  | head -n1 | sed "s/.*${key}=//;s/['\"]//g" || true)
            if [[ -z "$val" ]]; then
                # map style:  KEY: value
                val=$(grep -E "^\s*${key}:" "$COMPOSE_FILE" \
                      | head -n1 | sed "s/.*${key}:\s*//;s/['\"]//g" || true)
            fi
        fi
    fi

    # ── rescue_with_trigger.sh (fallback if not found in compose) ──
    if [[ -z "$val" && -f "$RESCUE_FILE" ]]; then
        val=$(grep -E "^(export\s+)?${key}=" "$RESCUE_FILE" \
              | head -n1 | sed "s/.*${key}=//;s/^['\"]//;s/['\"]$//" || true)
    fi

    echo "$val"
}

# ─── update a key=value in docker-compose.yml ────────────────
#     Handles both list style (- KEY=val) and map style (KEY: val)
upsert_compose() {
    local key="$1" value="$2"
    if [[ ! -f "$COMPOSE_FILE" ]]; then return; fi

    # list style:  - KEY=old  →  - KEY=new
    if grep -qE "^\s*-\s*${key}=" "$COMPOSE_FILE"; then
        sed -i.bak "s|^\(\s*-\s*\)${key}=.*|\1${key}=${value}|" "$COMPOSE_FILE" \
            && rm -f "${COMPOSE_FILE}.bak"
        return
    fi

    # map style:  KEY: old  →  KEY: new
    if grep -qE "^\s*${key}:" "$COMPOSE_FILE"; then
        sed -i.bak "s|^\(\s*\)${key}:.*|\1${key}: ${value}|" "$COMPOSE_FILE" \
            && rm -f "${COMPOSE_FILE}.bak"
        return
    fi
}

# ─── special: replace literal USB device path in docker-compose.yml ──
#     docker-compose uses the path directly, e.g.:
#       devices:
#         - /dev/sdb1:/dev/sdb1
#     We find whatever /dev/… path is currently there and swap it out.
upsert_compose_usb_dev() {
    local new_dev="$1"
    if [[ ! -f "$COMPOSE_FILE" ]]; then return; fi

    # Detect the current literal path (fallback to known default)
    local old_dev
    old_dev=$(grep -E "^\s*-\s*/dev/" "$COMPOSE_FILE" \
              | head -n1 | sed 's|.*-\s*\(/dev/[^:]*\):.*|\1|;s/[[:space:]]//g' || true)
    old_dev="${old_dev:-$USB_DEV_DEFAULT}"

    if [[ "$old_dev" == "$new_dev" ]]; then
        info "USB_DEV already set to ${new_dev} in docker-compose.yml – no change."
        return
    fi

    # Escape forward-slashes for sed
    local old_esc new_esc
    old_esc=$(printf '%s' "$old_dev" | sed 's|/|\\/|g')
    new_esc=$(printf '%s' "$new_dev" | sed 's|/|\\/|g')

    # Replace every occurrence of the old path in the file
    sed -i.bak "s|${old_esc}|${new_esc}|g" "$COMPOSE_FILE" \
        && rm -f "${COMPOSE_FILE}.bak"

    ok "docker-compose.yml: replaced ${old_dev} → ${new_dev}"
}

# ─── update a key=value in rescue_with_trigger.sh ────────────
#     Handles:  KEY=val  and  export KEY=val  (with/without quotes)
upsert_rescue() {
    local key="$1" value="$2"
    if [[ ! -f "$RESCUE_FILE" ]]; then return; fi

    # export KEY=...
    if grep -qE "^export\s+${key}=" "$RESCUE_FILE"; then
        sed -i.bak "s|^export\s\+${key}=.*|export ${key}=\"${value}\"|" "$RESCUE_FILE" \
            && rm -f "${RESCUE_FILE}.bak"
        return
    fi

    # plain KEY=...
    if grep -qE "^${key}=" "$RESCUE_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=\"${value}\"|" "$RESCUE_FILE" \
            && rm -f "${RESCUE_FILE}.bak"
        return
    fi
}

# ─── update key in BOTH files (whichever contains it) ────────
upsert() {
    local key="$1" value="$2"
    local updated=0

    # USB_DEV: stored as a literal device path in docker-compose.yml, not as KEY=value
    if [[ "$key" == "USB_DEV" ]]; then
        upsert_compose_usb_dev "$value"
        updated=1
        # also update rescue_with_trigger.sh if it references USB_DEV there
        if grep -qE "^(export\s+)?USB_DEV=" "$RESCUE_FILE" 2>/dev/null; then
            upsert_rescue "USB_DEV" "$value"
        fi
        return
    fi

    # update in docker-compose.yml if key exists there
    if grep -qE "^\s*(-\s*)?${key}[=:]" "$COMPOSE_FILE" 2>/dev/null; then
        upsert_compose "$key" "$value"
        updated=1
    fi

    # update in rescue_with_trigger.sh if key exists there
    if grep -qE "^(export\s+)?${key}=" "$RESCUE_FILE" 2>/dev/null; then
        upsert_rescue "$key" "$value"
        updated=1
    fi

    if [[ $updated -eq 0 ]]; then
        warn "Key '${key}' not found in docker-compose.yml or rescue_with_trigger.sh – skipped."
    fi
}

# ─── prompt helper: shows current value, keeps it if user just hits ENTER ─
ask() {
    local key="$1" prompt="$2" default="$3" secret="${4:-false}"
    local cur; cur=$(current "$key")
    local display_default="${cur:-$default}"

    if [[ "$secret" == "true" && -n "$cur" ]]; then
        display_default="******* (set)"
    fi

    if [[ -n "$display_default" ]]; then
        echo -ne "  ${prompt} [${YELLOW}${display_default}${RESET}]: "
    else
        echo -ne "  ${prompt}: "
    fi

    local input
    if [[ "$secret" == "true" ]]; then
        read -rs input; echo
    else
        read -r input
    fi

    # Use input if provided; otherwise keep current value; otherwise use default
    local final="${input:-${cur:-$default}}"
    upsert "$key" "$final"
    echo "$final"
}

# ─── detect connected USB block devices ──────────────────────
detect_usb_dev() {
    local candidates=()
    for d in /dev/sda1 /dev/sdb1 /dev/sdc1 /dev/sdd1; do
        [[ -b "$d" ]] && candidates+=("$d")
    done
    if command -v lsblk >/dev/null 2>&1; then
        while IFS= read -r line; do
            candidates+=("$line")
        done < <(lsblk -nr -o PATH,TYPE,RM 2>/dev/null | awk '$2=="part" && $3==1 {print $1}')
    fi
    printf '%s\n' "${candidates[@]}" | sort -u | head -5
}

# ─── detect connected ADB devices ────────────────────────────
detect_adb_devices() {
    if command -v adb >/dev/null 2>&1; then
        adb devices -l 2>/dev/null | grep -E '\bdevice\b' | awk '{print $1}' || true
    fi
}

# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════
clear
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║        SW Rescue – Environment Setup         ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Verify both target files exist before doing anything ─────
check_files

info "Target files:"
info "  → $COMPOSE_FILE"
info "  → $RESCUE_FILE"
echo -ne "  ${BOLD}Update values in the above files?${RESET} (press ENTER to keep current values) [Y/n]: "
read -r confirm
if [[ "${confirm,,}" == "n" ]]; then
    ok "No changes made. Exiting."
    exit 0
fi

# ─── Section 1: Artifactory / Auth ───────────────────────────
section "Artifactory / Authentication"
ask "ARTIFACTORY_TOKEN_DT"             "Artifactory token (DT)"                 ""     "true"
ask "ARTIFACTORY_UNPROTECTED_USERNAME" "Artifactory username (unprotected)"     ""     "false"
ask "TOKEN_ACCESS"                     "GitLab / access token"                  ""     "true"

# ─── Section 2: Docker Image ─────────────────────────────────
section "Docker Image"
ask "MATRIX_IMAGE_VERSION" "Matrix image version (e.g. 1.2.3)" "latest"

# ─── Section 3: Release / Rescue URL ─────────────────────────
section "Release URL"
echo -e "  ${YELLOW}Default:${RESET} generic-sdv_cdc-local/releases_dt/LGE/OFFICIAL/..."
ask "RESCUE_URL" \
    "Artifactory path (without base URL)" \
    "generic-sdv_cdc-local/releases_dt/LGE/OFFICIAL/RELEASE_S510_CDC_261.02.51_BL06.00/USERDEBUG/RESCUE_backup/Rescue_20260210_1526_USERDEBUG_UAT_blank_ORANGE.7z"

# ─── Section 4: USB Block Device ─────────────────────────────
section "USB Block Device"
echo -e "  ${CYAN}Scanning for removable block devices...${RESET}"

mapfile -t usb_devs < <(detect_usb_dev)
AUTO_USB_DEV=""

if [[ ${#usb_devs[@]} -gt 0 ]]; then
    AUTO_USB_DEV="${usb_devs[0]}"

    # ── ⚠️  HOST-CONNECTED USB WARNING ───────────────────────
    echo
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║  ⚠️   WARNING – USB DEVICE DETECTED ON HOST MACHINE  ⚠️       ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo
    echo -e "  ${YELLOW}The following removable partition(s) are currently visible${RESET}"
    echo -e "  ${YELLOW}on this host machine:${RESET}"
    echo
    for d in "${usb_devs[@]}"; do
        if command -v lsblk >/dev/null 2>&1; then
            extra=$(lsblk -nr -o SIZE,LABEL "$d" 2>/dev/null | head -1 || true)
            echo -e "    ${RED}•${RESET} ${BOLD}$d${RESET}  ${CYAN}$extra${RESET}"
        else
            echo -e "    ${RED}•${RESET} ${BOLD}$d${RESET}"
        fi
    done
    echo
    echo -e "  ${RED}${BOLD}The USB stick must NOT be connected directly to the host.${RESET}"
    echo -e "  ${YELLOW}Please switch the USB connection using the${RESET} ${BOLD}${CYAN}Multiverse GUI${RESET}${YELLOW}:${RESET}"
    echo
    echo -e "  ${BOLD}  1.${RESET}  Open the ${BOLD}Multiverse GUI${RESET} on the bench."
    echo -e "  ${BOLD}  2.${RESET}  Locate the USB Stick port (ID: ${BOLD}${CYAN}USB_STICK_PORT_ID${RESET})."
    echo -e "  ${BOLD}  3.${RESET}  Switch the connection from ${RED}Host / PC${RESET} → ${GREEN}CDC / DUT${RESET}."
    echo -e "  ${BOLD}  4.${RESET}  Confirm the USB is no longer visible on this host."
    echo
    echo -e "${YELLOW}${BOLD}  ──────────────────────────────────────────────────────────────${RESET}"

    while true; do
        echo -ne "  ${BOLD}Have you switched the USB in Multiverse GUI and it is no longer${RESET}"
        echo -ne "\n  ${BOLD}connected to the host?${RESET} ${GREEN}[yes]${RESET} / ${RED}[no]${RESET} / ${CYAN}[skip – I know what I'm doing]${RESET}: "
        read -r usb_ans

        case "${usb_ans,,}" in
            yes|y)
                mapfile -t recheck < <(detect_usb_dev)
                if [[ ${#recheck[@]} -gt 0 ]]; then
                    echo
                    echo -e "  ${RED}${BOLD}Device still detected on host:${RESET}"
                    for d in "${recheck[@]}"; do echo -e "    ${RED}•${RESET} $d"; done
                    echo -e "  ${YELLOW}Please disconnect it from the host via Multiverse GUI and try again.${RESET}"
                    echo
                else
                    echo
                    ok "USB no longer detected on host. Continuing..."
                    AUTO_USB_DEV=""
                    usb_devs=()
                    echo
                fi
                break
                ;;
            no|n)
                echo
                echo -e "  ${RED}${BOLD}Please switch the USB via the Multiverse GUI before continuing.${RESET}"
                echo -e "  ${YELLOW}Setup will wait – press ENTER once you have made the switch.${RESET}"
                echo -ne "  "
                read -r
                ;;
            skip|s)
                echo
                warn "Skipping USB host-connection check – proceeding with detected device."
                echo
                break
                ;;
            *)
                echo -e "  ${YELLOW}Please answer:${RESET} ${GREEN}yes${RESET}, ${RED}no${RESET}, or ${CYAN}skip${RESET}"
                ;;
        esac
    done

    if [[ ${#usb_devs[@]} -gt 0 ]]; then
        echo -e "  ${GREEN}Detected removable partitions:${RESET}"
        for d in "${usb_devs[@]}"; do
            if command -v lsblk >/dev/null 2>&1; then
                extra=$(lsblk -nr -o SIZE,LABEL "$d" 2>/dev/null | head -1 || true)
                echo -e "    ${YELLOW}•${RESET} $d  ${CYAN}$extra${RESET}"
            else
                echo -e "    ${YELLOW}•${RESET} $d"
            fi
        done
        echo -e "  ${GREEN}Auto-selected:${RESET} ${BOLD}${AUTO_USB_DEV}${RESET}"
    fi
else
    echo -e "  ${GREEN}✅ No removable USB partitions detected on host – good to go.${RESET}"
    AUTO_USB_DEV="/dev/sdb1"
fi

USB_DEV_VAL=$(ask "USB_DEV" "USB block device to use in docker-compose" "${AUTO_USB_DEV}")
echo -e "  ${GREEN}USB_DEV set to:${RESET} ${BOLD}${USB_DEV_VAL}${RESET}"

# ─── Section 5: USB metadata ─────────────────────────────────
section "USB Metadata"
ask "USB_STICK_ID"          "USB Stick ID (label/serial)"  "087E-274D"
ask "USB_STICK_MCH_PORT_ID" "USB MCH port ID"              "1"
ask "USB_STICK_PORT_ID"     "USB Stick port ID"            "2"
ask "PHONE_USB_PORT_ID"     "Phone USB port ID"            "4"

# ─── Section 6: ADB ──────────────────────────────────────────
section "ADB Device (optional)"
echo -e "  ${CYAN}Detected ADB devices:${RESET}"
mapfile -t adb_devs < <(detect_adb_devices)
if [[ ${#adb_devs[@]} -gt 0 ]]; then
    for d in "${adb_devs[@]}"; do echo "    • $d"; done
else
    echo "    (none detected)"
fi
ask "ADB_DEVICE_ID" "ADB device serial (leave blank to auto-detect)" ""

# ─── Section 7: Mount point ──────────────────────────────────
section "Mount Point"
ask "MOUNT_POINT" "USB mount point inside container" "/mnt/Renault"

# ─── Section 8: CI project dir inside container ──────────────
section "Project"
ask "CI_PROJECT_DIR" "Project directory inside container" "/workspace"

# ─── Summary ─────────────────────────────────────────────────
echo
section "Updated Files"

for target_file in "$COMPOSE_FILE" "$RESCUE_FILE"; do
    echo -e "\n  ${BOLD}$(basename "$target_file")${RESET}  →  ${CYAN}${target_file}${RESET}"
    for key in ARTIFACTORY_TOKEN_DT ARTIFACTORY_UNPROTECTED_USERNAME TOKEN_ACCESS \
                MATRIX_IMAGE_VERSION RESCUE_URL USB_DEV \
                USB_STICK_ID USB_STICK_MCH_PORT_ID USB_STICK_PORT_ID PHONE_USB_PORT_ID \
                ADB_DEVICE_ID MOUNT_POINT CI_PROJECT_DIR; do
        # check if key is present in this file
        if grep -qE "(^\s*-?\s*${key}[=:]|^export\s+${key}=)" "$target_file" 2>/dev/null; then
            val=$(current "$key")
            if [[ "$key" =~ TOKEN|PASSWORD|SECRET ]]; then
                echo -e "    ${CYAN}${key}${RESET} = ${YELLOW}*******${RESET}"
            else
                echo -e "    ${CYAN}${key}${RESET} = ${val}"
            fi
        fi
    done
done

echo
ok "Values updated in docker-compose.yml and rescue_with_trigger.sh"
info "Run  'docker-compose up'  to start the rescue job."
echo
