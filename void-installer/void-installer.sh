#!/usr/bin/env bash
# void-installer.sh — Void Linux installer entry point
# Installs: runit + KDE Plasma (Wayland) + PipeWire + NetworkManager
#
# Requirements:
#   - Booted from a Void Linux live ISO
#   - Working internet connection
#   - Target disk will be completely erased
#
# Usage:
#   sudo ./void-installer.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/disk.sh"
source "$SCRIPT_DIR/lib/install.sh"
source "$SCRIPT_DIR/lib/configure.sh"

main() {
    [[ $EUID -eq 0 ]] || die "Run as root:  sudo ./void-installer.sh"

    print_banner
    check_internet

    # --- Hardware detection ---
    log_info "Detecting hardware..."
    detect_cpu
    detect_gpu
    echo
    log_success "CPU: ${CPU_VENDOR}"
    log_success "GPU: ${GPU_TYPE}"

    # --- Disk selection ---
    select_disk
    detect_disk_type "$INSTALL_DISK"

    # --- User configuration ---
    collect_user_info

    # --- Confirm before any destructive action ---
    confirm_settings

    # === Installation ===
    echo
    log_info "=== Starting installation ==="
    echo

    partition_disk   "$INSTALL_DISK"
    format_partitions
    mount_partitions

    install_base

    configure_system   # generates fstab, enters chroot, configures everything

    # --- Done ---
    echo
    echo -e "\033[1;32m╔══════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;32m║   Void Linux installed successfully!             ║\033[0m"
    echo -e "\033[1;32m║                                                  ║\033[0m"
    echo -e "\033[1;32m║   At the SDDM login screen choose:               ║\033[0m"
    echo -e "\033[1;32m║     Plasma (Wayland)                             ║\033[0m"
    echo -e "\033[1;32m╚══════════════════════════════════════════════════╝\033[0m"
    echo

    read -rp "Reboot now? [y/N]: " _ans
    if [[ "${_ans,,}" == "y" ]]; then
        log_info "Unmounting and rebooting..."
        swapoff -a 2>/dev/null || true
        umount -R /mnt 2>/dev/null || true
        reboot
    else
        log_info "You can reboot manually with:  umount -R /mnt && reboot"
    fi
}

main "$@"
