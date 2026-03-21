#!/usr/bin/env bash
# configure.sh — Chroot orchestrator

_write_config() {
    # Write all variables needed inside the chroot to a temp file
    local cfg="/mnt/tmp/void-install.conf"
    mkdir -p /mnt/tmp
    cat > "$cfg" << EOF
HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}"
ROOT_PASSWORD="${ROOT_PASSWORD}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
CPU_VENDOR="${CPU_VENDOR}"
GPU_TYPE="${GPU_TYPE}"
DISK_TYPE="${DISK_TYPE}"
UEFI="${UEFI}"
INSTALL_DISK="${INSTALL_DISK}"
EOF
    chmod 600 "$cfg"
}

_enter_chroot() {
    log_info "Copying chroot setup script..."
    cp "$(dirname "${BASH_SOURCE[0]}")/chroot-setup.sh" /mnt/tmp/chroot-setup.sh
    chmod +x /mnt/tmp/chroot-setup.sh

    log_info "Entering chroot..."
    # xchroot mounts /dev /proc /sys and copies resolv.conf automatically
    if command -v xchroot &>/dev/null; then
        xchroot /mnt /tmp/chroot-setup.sh
    else
        # Fallback: manual bind mounts
        for d in dev proc sys; do
            mount --rbind "/$d" "/mnt/$d"
            mount --make-rslave "/mnt/$d"
        done
        cp /etc/resolv.conf /mnt/etc/resolv.conf
        chroot /mnt /tmp/chroot-setup.sh
        # Cleanup mounts
        for d in dev proc sys; do
            umount -R "/mnt/$d" 2>/dev/null || true
        done
    fi
}

_cleanup_chroot() {
    rm -f /mnt/tmp/chroot-setup.sh /mnt/tmp/void-install.conf
}

configure_system() {
    generate_fstab   # from disk.sh — needs access to /dev/disk before chroot

    _write_config
    _enter_chroot
    _cleanup_chroot

    log_success "System configuration complete"
}
