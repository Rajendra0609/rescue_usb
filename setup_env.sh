#!/usr/bin/env bash
# ============================================================
#  setup_env.sh  –  Manage environment variables for SW Rescue
#  Stores all values in .env (next to this script)
#  Run:  bash setup_env.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# ─── colour helpers ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
section() { echo -e "\n${BOLD}${CYAN}═══ $* ═══${RESET}"; }

# ─── read current value from .env (empty string if missing) ──
current() {
    local key="$1"
    if [[ -f "$ENV_FILE" ]]; then
        grep -E "^${key}=" "$ENV_FILE" | head -n1 | cut -d'=' -f2- | sed "s/^['\"]//;s/['\"]$//" || true
    fi
}

# ─── write / update a key=value pair in .env ─────────────────
upsert() {
    local key="$1" value="$2"
    if [[ -f "$ENV_FILE" ]] && grep -qE "^${key}=" "$ENV_FILE"; then
        # replace existing line (portable sed)
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
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
    # deduplicate
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

# Check if .env already exists
if [[ -f "$ENV_FILE" ]]; then
    warn ".env already exists at $ENV_FILE"
    echo -ne "  ${BOLD}Update existing values?${RESET} (press ENTER to keep current values) [Y/n]: "
    read -r confirm
    if [[ "${confirm,,}" == "n" ]]; then
        ok "No changes made. Exiting."
        exit 0
    fi
else
    info "Creating new .env file at $ENV_FILE"
    touch "$ENV_FILE"
fi

# ─── Section 1: Artifactory / Auth ───────────────────────────
section "Artifactory / Authentication"
ask "ARTIFACTORY_TOKEN_DT"             "Artifactory token (DT)"         ""          "true"
ask "ARTIFACTORY_UNPROTECTED_USERNAME" "Artifactory username (unprotected)" ""       "false"
ask "TOKEN_ACCESS"                     "GitLab / access token"          ""          "true"

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
    # A removable block device is visible on this host machine.
    # For the SW Rescue flow the USB stick must be routed to the
    # container via the Multiverse bench – NOT directly attached
    # to the host.  Prompt the user to fix this before continuing.
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
                # Re-check: if the device is still visible, warn again
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
                    # Clear the auto-detected value – device is no longer on the host
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
                # Loop back to re-check
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
    # ── END WARNING ──────────────────────────────────────────

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
section "Saved Variables"
echo -e "  File: ${BOLD}$ENV_FILE${RESET}\n"
while IFS='=' read -r k v; do
    [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
    if [[ "$k" =~ TOKEN|PASSWORD|SECRET ]]; then
        echo -e "  ${CYAN}${k}${RESET} = ${YELLOW}*******${RESET}"
    else
        echo -e "  ${CYAN}${k}${RESET} = ${v}"
    fi
done < "$ENV_FILE"

echo
ok "Environment saved to $ENV_FILE"
info "Run  'docker-compose up'  to start the rescue job."
echo
