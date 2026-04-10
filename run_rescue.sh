#!/usr/bin/env bash
# ============================================================
#  run_rescue.sh  –  Master launcher
#  1. Clone / update  rntbci_flash  repo from GitHub
#  2. Run  setup_env.sh  (interactive env setup → .env)
#  3. Patch docker-compose.yml with detected USB_DEV via sed
#  4. Run  docker-compose up  with full live log streaming
# ============================================================
set -euo pipefail

# ─── colour helpers ──────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m';   BOLD='\033[1m';  RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}   $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}     $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}   $*"; }
error()  { echo -e "${RED}[ERROR]${RESET}  $*" >&2; }
step()   { echo -e "\n${BOLD}${BLUE}━━━━━  $*  ━━━━━${RESET}\n"; }

banner() {
  echo -e "${BOLD}${GREEN}"
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║          SW Rescue  –  Master Launcher               ║"
  echo "  ║          ccs3-automation-execution.git               ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

# ─── constants ───────────────────────────────────────────────
REPO_URL="https://gitlabee.dt.renault.com/sdv/platforms/sweet500/cdc/modules/automated_execution/ccs3-automation-execution.git"
REPO_DIR="$(pwd)/rntbci_flash"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR=""        # set after clone
RUN_LOG=""        # set after clone
COMPOSE_CMD=""    # set in preflight

# ─── require a command ───────────────────────────────────────
require() {
  command -v "$1" >/dev/null 2>&1 || {
    error "Required command not found: '$1' – please install it and re-run."
    exit 1
  }
}

# ─── tee everything to run log (called once REPO_DIR exists) ─
setup_logging() {
  LOG_DIR="$REPO_DIR/logs"
  mkdir -p "$LOG_DIR"
  RUN_LOG="$LOG_DIR/run_${TIMESTAMP}.log"
  exec > >(tee -a "$RUN_LOG") 2>&1
  info "Full session log  →  $RUN_LOG"
}

# ════════════════════════════════════════════════════════════
#  STEP 0  –  Preflight
# ════════════════════════════════════════════════════════════
preflight() {
  step "STEP 0 – Preflight checks"
  require git
  require docker

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
    info "Using: docker compose  (plugin)"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
    info "Using: docker-compose  (standalone)"
  else
    error "Neither 'docker compose' plugin nor 'docker-compose' found."
    exit 1
  fi

  ok "Preflight passed."
}

# ════════════════════════════════════════════════════════════
#  STEP 1  –  Clone or pull the repository
# ════════════════════════════════════════════════════════════
clone_or_update() {
  step "STEP 1 – Clone / update repository"
  info "Repository : $REPO_URL"
  info "Local path : $REPO_DIR"

  if [ -d "$REPO_DIR/.git" ]; then
    warn "Repository already exists locally."
    echo -ne "  ${BOLD}Pull latest changes from GitHub?${RESET} [Y/n]: "
    read -r pull_ans
    if [[ "${pull_ans,,}" != "n" ]]; then
      info "Pulling latest changes..."
      git -C "$REPO_DIR" pull --ff-only 2>&1 | sed 's/^/  [git] /'
      ok "Repository updated."
    else
      info "Skipping pull – using existing local copy."
    fi
  else
    info "Cloning repository (this may take a moment)..."
    git clone "$REPO_URL" -b dev/rescue_update "$REPO_DIR" 2>&1 | sed 's/^/  [git] /'
    ok "Clone complete."
  fi
  # Logging can now be set up (REPO_DIR exists)
  setup_logging
  info "Repository ready at: $REPO_DIR"
}

# ════════════════════════════════════════════════════════════
#  STEP 2  –  Run setup_env.sh
# ════════════════════════════════════════════════════════════
run_setup_env() {
  step "STEP 2 – Environment variable setup"

  ENV_SCRIPT="$REPO_DIR/setup_env.sh"
  ENV_FILE="$REPO_DIR/.env"

  if [ ! -f "$ENV_SCRIPT" ]; then
    error "setup_env.sh not found at $ENV_SCRIPT"
    error "Make sure setup_env.sh is committed in the repo."
    exit 1
  fi

  chmod +x "$ENV_SCRIPT"

  # If .env already exists, show current values and let user decide
  if [ -f "$ENV_FILE" ]; then
    info "Found existing .env:"
    echo
    while IFS='=' read -r k v; do
      [[ "$k" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$k" ]] && continue
      if [[ "$k" =~ TOKEN|PASSWORD|SECRET ]]; then
        printf "    ${CYAN}%-42s${RESET}= ${YELLOW}*******${RESET}\n" "$k"
      else
        printf "    ${CYAN}%-42s${RESET}= %s\n" "$k" "$v"
      fi
    done < "$ENV_FILE"
    echo
    echo -ne "  ${BOLD}Re-run env setup to update any values?${RESET} [y/N]: "
    read -r rerun_ans
    if [[ "${rerun_ans,,}" != "y" ]]; then
      info "Keeping current .env – skipping setup_env.sh"
      return 0
    fi
  fi

  info "Launching setup_env.sh (interactive) ..."
  bash "$ENV_SCRIPT"
  ok "Environment setup complete  →  $ENV_FILE"
}

# ════════════════════════════════════════════════════════════
#  STEP 2b –  Patch docker-compose.yml with USB_DEV from .env
# ════════════════════════════════════════════════════════════
patch_compose_usb() {
  step "STEP 2b – Patch docker-compose.yml with USB device"

  ENV_FILE="$REPO_DIR/.env"
  COMPOSE_FILE="$REPO_DIR/docker-compose.yml"

  # ── Sanity checks ────────────────────────────────────────
  if [ ! -f "$ENV_FILE" ]; then
    error ".env not found at $ENV_FILE – cannot determine USB_DEV."
    exit 1
  fi
  if [ ! -f "$COMPOSE_FILE" ]; then
    error "docker-compose.yml not found at $COMPOSE_FILE"
    exit 1
  fi

  # ── Read USB_DEV from .env ────────────────────────────────
  USB_DEV=$(grep -E '^USB_DEV=' "$ENV_FILE" \
              | head -n1 \
              | cut -d'=' -f2- \
              | tr -d '"'"'" \
              | tr -d '[:space:]' \
              || true)

  # ── Fall back to /dev/sdb1 if not set ────────────────────
  if [ -z "$USB_DEV" ]; then
    warn "USB_DEV not found in .env – falling back to /dev/sdb1"
    USB_DEV="/dev/sdb1"
    # Write the default back into .env for consistency
    echo "USB_DEV=${USB_DEV}" >> "$ENV_FILE"
  fi

  info "USB_DEV resolved  →  ${BOLD}${USB_DEV}${RESET}"

  # ── Verify the device actually exists on the host ─────────
  if [ -b "$USB_DEV" ]; then
    ok "Block device ${USB_DEV} is present on this host."
  else
    warn "Block device ${USB_DEV} not found on host right now."
    warn "Continuing anyway – it may appear inside the container."
  fi

  # ── Backup the original compose file ─────────────────────
  COMPOSE_BACKUP="${COMPOSE_FILE}.bak_${TIMESTAMP}"
  cp "$COMPOSE_FILE" "$COMPOSE_BACKUP"
  info "Backup  →  $COMPOSE_BACKUP"

  # ── sed: replace every occurrence of the old hardcoded path
  #    Pattern matches any /dev/sd?N  already in the file so
  #    re-running the script stays idempotent.
  OLD_PATTERN='/dev/sd[a-z][0-9]*'

  # Count replacements before and after for a clear summary
  MATCH_COUNT=$(grep -cE "$OLD_PATTERN" "$COMPOSE_FILE" || true)

  if [ "$MATCH_COUNT" -eq 0 ]; then
    warn "No hardcoded /dev/sd* paths found in docker-compose.yml – nothing to patch."
  else
    # Use | as delimiter so paths with / don't break sed
    sed -i.tmp "s|${OLD_PATTERN}|${USB_DEV}|g" "$COMPOSE_FILE"
    rm -f "${COMPOSE_FILE}.tmp"
    ok "Replaced ${MATCH_COUNT} occurrence(s) of /dev/sd* with  ${BOLD}${USB_DEV}${RESET}  in docker-compose.yml"
  fi

  # ── Show the patched lines for confirmation ───────────────
  echo
  echo -e "  ${BOLD}Patched lines in docker-compose.yml:${RESET}"
  grep -n "$USB_DEV" "$COMPOSE_FILE" | sed "s/^/    /" || echo "    (none)"
  echo
}

# ════════════════════════════════════════════════════════════
#  STEP 2c –  Patch rescue_with-trigger.sh with values from .env
#             Updates the 5 hardcoded CONFIG variables:
#               USB_STICK_ID, USB_STICK_MCH_PORT_ID,
#               USB_STICK_PORT_ID, PHONE_USB_PORT_ID,
#               ADB_DEVICE_ID
# ════════════════════════════════════════════════════════════
patch_trigger_script() {
  step "STEP 2c – Patch rescue_with-trigger.sh with .env values"

  ENV_FILE="$REPO_DIR/.env"
  TRIGGER_SCRIPT="$REPO_DIR/rescue_with-trigger.sh"

  # ── Sanity checks ────────────────────────────────────────
  if [ ! -f "$ENV_FILE" ]; then
    error ".env not found at $ENV_FILE – cannot patch trigger script."
    exit 1
  fi
  if [ ! -f "$TRIGGER_SCRIPT" ]; then
    warn "rescue_with-trigger.sh not found at $TRIGGER_SCRIPT – skipping patch."
    return 0
  fi

  # ── Helper: read a key from .env (empty string if missing) ──
  read_env() {
    grep -E "^${1}=" "$ENV_FILE" \
      | head -n1 \
      | cut -d'=' -f2- \
      | tr -d '"'"'" \
      | tr -d '[:space:]' \
      || true
  }

  # ── Read values from .env ─────────────────────────────────
  VAL_USB_STICK_ID=$(read_env "USB_STICK_ID")
  VAL_MCH_PORT_ID=$(read_env "USB_STICK_MCH_PORT_ID")
  VAL_STICK_PORT_ID=$(read_env "USB_STICK_PORT_ID")
  VAL_PHONE_PORT_ID=$(read_env "PHONE_USB_PORT_ID")
  VAL_ADB_DEVICE_ID=$(read_env "ADB_DEVICE_ID")

  # ── Backup trigger script ─────────────────────────────────
  TRIGGER_BACKUP="${TRIGGER_SCRIPT}.bak_${TIMESTAMP}"
  cp "$TRIGGER_SCRIPT" "$TRIGGER_BACKUP"
  info "Backup  →  $TRIGGER_BACKUP"

  # ── Patch each hardcoded CONFIG line with sed ─────────────
  # Pattern matches:  VARNAME="<anything>"
  # and replaces the quoted value with the one from .env.
  # Uses | as sed delimiter so values with / are safe.

  patch_var() {
    local varname="$1" newval="$2"
    if [ -z "$newval" ]; then
      warn "  $varname not set in .env – keeping existing value in script."
      return
    fi
    # Only patch the bare assignment line (no ${ prefix) to avoid touching
    # the safety-default lines like:  USB_STICK_ID="${USB_STICK_ID:-}"
    sed -i.tmp "s|^${varname}=\"[^\"]*\"|${varname}=\"${newval}\"|" "$TRIGGER_SCRIPT"
    rm -f "${TRIGGER_SCRIPT}.tmp"
    ok "  ${varname}  →  \"${newval}\""
  }

  echo
  info "Patching CONFIG block in rescue_with-trigger.sh ..."
  patch_var "USB_STICK_ID"          "$VAL_USB_STICK_ID"
  patch_var "USB_STICK_MCH_PORT_ID" "$VAL_MCH_PORT_ID"
  patch_var "USB_STICK_PORT_ID"     "$VAL_STICK_PORT_ID"
  patch_var "PHONE_USB_PORT_ID"     "$VAL_PHONE_PORT_ID"
  patch_var "ADB_DEVICE_ID"         "$VAL_ADB_DEVICE_ID"

  # ── Show the patched CONFIG block for confirmation ─────────
  echo
  echo -e "  ${BOLD}Resulting CONFIG block in rescue_with-trigger.sh:${RESET}"
  grep -n \
    -e '^USB_STICK_ID=' \
    -e '^USB_STICK_MCH_PORT_ID=' \
    -e '^USB_STICK_PORT_ID=' \
    -e '^PHONE_USB_PORT_ID=' \
    -e '^ADB_DEVICE_ID=' \
    "$TRIGGER_SCRIPT" | sed 's/^/    /' || echo "    (no matching lines found)"
  echo
}

# ════════════════════════════════════════════════════════════
#  STEP 3  –  docker-compose up with full live logs
# ════════════════════════════════════════════════════════════
run_docker_compose() {
  step "STEP 3 – docker compose up  (streaming live logs)"

  COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
  if [ ! -f "$COMPOSE_FILE" ]; then
    error "docker-compose.yml not found at $COMPOSE_FILE"
    exit 1
  fi

  DOCKER_LOG="$LOG_DIR/docker_${TIMESTAMP}.log"
  info "Docker log file  →  $DOCKER_LOG"
  echo
  echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════╗"
  echo -e "║           CONTAINER  OUTPUT  START                   ║"
  echo -e "╚══════════════════════════════════════════════════════╝${RESET}"
  echo

  # ── Run compose from inside REPO_DIR so .env is auto-loaded ──
  # --abort-on-container-exit: stop all containers when sw_rescue exits
  # --exit-code-from sw_rescue: propagate the container's exit code
  # All output piped through tee → terminal AND docker log file
  set +e
  (
    cd "$REPO_DIR"
    DOCKER_BUILDKIT=1 \
    COMPOSE_DOCKER_CLI_BUILD=1 \
    $COMPOSE_CMD up \
      --abort-on-container-exit \
      --exit-code-from sw_rescue \
      2>&1
  ) | tee "$DOCKER_LOG"
  COMPOSE_EXIT="${PIPESTATUS[0]}"
  set -e

  echo
  echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════╗"
  echo -e "║           CONTAINER  OUTPUT  END                     ║"
  echo -e "╚══════════════════════════════════════════════════════╝${RESET}"
  echo

  # ─── print summary ───────────────────────────────────────
  step "Run Summary"
  info "Session log  →  $RUN_LOG"
  info "Docker log   →  $DOCKER_LOG"
  echo

  if [ "$COMPOSE_EXIT" -eq 0 ]; then
    ok "SW Rescue job  PASSED ✅"
  else
    error "SW Rescue job  FAILED ❌  (container exit code: $COMPOSE_EXIT)"
    echo
    echo -e "${BOLD}${RED}──── Last 60 lines of Docker log ────${RESET}"
    tail -n 60 "$DOCKER_LOG" | sed 's/^/  /'
    echo
    exit "$COMPOSE_EXIT"
  fi
}

# ════════════════════════════════════════════════════════════
#  STEP 4  –  (optional) clean up stopped container
# ════════════════════════════════════════════════════════════
cleanup() {
  echo -ne "\n  ${BOLD}Remove stopped container & networks?${RESET} [y/N]: "
  read -r clean_ans
  if [[ "${clean_ans,,}" == "y" ]]; then
    (cd "$REPO_DIR" && $COMPOSE_CMD down --remove-orphans 2>&1 | sed 's/^/  [docker] /')
    ok "Container removed."
  else
    info "Container left in stopped state. Run 'docker-compose down' to remove later."
  fi
}

# ════════════════════════════════════════════════════════════
#  SIGNAL HANDLER
# ════════════════════════════════════════════════════════════
cleanup_on_interrupt() {
  echo
  warn "Interrupted! Bringing down containers..."
  if [ -d "$REPO_DIR" ]; then
    (cd "$REPO_DIR" && $COMPOSE_CMD down --remove-orphans 2>/dev/null || true)
  fi
  echo -e "${RED}Aborted.${RESET}"
  exit 130
}
trap 'cleanup_on_interrupt' INT TERM

# ════════════════════════════════════════════════════════════
#  ENTRY POINT
# ════════════════════════════════════════════════════════════
banner
preflight
clone_or_update
run_setup_env
patch_compose_usb      # sed-patches docker-compose.yml with USB_DEV
patch_trigger_script   # sed-patches rescue_with-trigger.sh with .env values
run_docker_compose
cleanup

echo
ok "All done 🎉"
