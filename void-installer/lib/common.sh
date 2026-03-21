#!/usr/bin/env bash
# common.sh — Colors, logging, helper functions

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

die() {
    log_error "$*"
    exit 1
}

confirm() {
    # confirm "message" → returns 0 (yes) or 1 (no)
    local msg="${1:-Continue?}"
    local answer
    read -rp "$(echo -e "${YELLOW}${msg} [y/N]:${RESET} ")" answer
    [[ "${answer,,}" == "y" ]]
}

print_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
 __   __     _    _   _     _
 \ \ / /__  (_)__| | | |   (_)_ _ _  ___ __
  \ V / _ \ | / _` | | |__ | | ' \ || \ \ /
   \_/\___/ |_\__,_| |____|_|_||_\_,_/_\_\
  ___         _        _ _
 |_ _|_ _  __| |_ __ _| | |___ _ _
  | || ' \(_-<  _/ _` | | / -_) '_|
 |___|_||_/__/\__\__,_|_|_\___|_|

  runit + KDE Plasma (Wayland) + PipeWire
EOF
    echo -e "${RESET}"
}

check_internet() {
    log_info "Checking internet connection..."
    if ! ping -c1 -W3 8.8.8.8 &>/dev/null; then
        die "No internet connection. Please connect and re-run the installer."
    fi
    log_success "Internet connection OK"
}

collect_user_info() {
    echo
    echo -e "${BOLD}=== System Configuration ===${RESET}"
    echo

    # Hostname
    read -rp "Hostname: " HOSTNAME
    [[ -n "$HOSTNAME" ]] || die "Hostname cannot be empty"

    # Username
    read -rp "Username: " USERNAME
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username (use lowercase letters, digits, _ or -)"

    # User password
    while true; do
        read -rsp "Password for $USERNAME: " USER_PASSWORD; echo
        read -rsp "Confirm password: " USER_PASSWORD2; echo
        [[ "$USER_PASSWORD" == "$USER_PASSWORD2" ]] && break
        log_warn "Passwords do not match, try again."
    done
    [[ -n "$USER_PASSWORD" ]] || die "Password cannot be empty"

    # Root password
    while true; do
        read -rsp "Root password: " ROOT_PASSWORD; echo
        read -rsp "Confirm root password: " ROOT_PASSWORD2; echo
        [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD2" ]] && break
        log_warn "Passwords do not match, try again."
    done
    [[ -n "$ROOT_PASSWORD" ]] || die "Root password cannot be empty"

    # Timezone
    echo
    echo "Common timezones: Europe/Kyiv, Europe/Warsaw, Europe/Berlin, Europe/London,"
    echo "                  America/New_York, America/Chicago, America/Los_Angeles,"
    echo "                  Asia/Tokyo, Asia/Shanghai, UTC"
    read -rp "Timezone [UTC]: " TIMEZONE
    TIMEZONE="${TIMEZONE:-UTC}"
    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Invalid timezone: $TIMEZONE"

    # Locale
    read -rp "Locale [en_US.UTF-8]: " LOCALE
    LOCALE="${LOCALE:-en_US.UTF-8}"

    export HOSTNAME USERNAME USER_PASSWORD ROOT_PASSWORD TIMEZONE LOCALE
}

confirm_settings() {
    echo
    echo -e "${BOLD}=== Installation Summary ===${RESET}"
    echo -e "  Disk:      ${RED}${INSTALL_DISK}${RESET} (will be ${RED}ERASED${RESET})"
    echo -e "  Mode:      $( [[ "$UEFI" == "true" ]] && echo "UEFI/GPT" || echo "BIOS/MBR" )"
    echo -e "  Disk type: $DISK_TYPE"
    echo -e "  CPU:       $CPU_VENDOR"
    echo -e "  GPU:       $GPU_TYPE"
    echo -e "  Hostname:  $HOSTNAME"
    echo -e "  Username:  $USERNAME"
    echo -e "  Timezone:  $TIMEZONE"
    echo -e "  Locale:    $LOCALE"
    echo
    confirm "ALL DATA ON ${INSTALL_DISK} WILL BE DESTROYED. Proceed?" || die "Installation cancelled."
}
