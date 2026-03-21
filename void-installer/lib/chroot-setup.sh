#!/usr/bin/env bash
# chroot-setup.sh — Runs inside xchroot to fully configure the system
set -euo pipefail

CFG="/tmp/void-install.conf"
[[ -f "$CFG" ]] || { echo "[ERROR] Config file not found: $CFG"; exit 1; }
# shellcheck source=/dev/null
source "$CFG"

log() { echo -e "\033[0;34m[chroot]\033[0m $*"; }
die() { echo -e "\033[0;31m[chroot ERROR]\033[0m $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Sync XBPS and reconfigure all packages
# ---------------------------------------------------------------------------
log "Syncing XBPS and reconfiguring packages..."
xbps-install -S -y 2>/dev/null || true
xbps-reconfigure -fa

# ---------------------------------------------------------------------------
# 2. Timezone
# ---------------------------------------------------------------------------
log "Setting timezone: ${TIMEZONE}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc --utc

# ---------------------------------------------------------------------------
# 3. Locale
# ---------------------------------------------------------------------------
log "Configuring locale: ${LOCALE}"
# Uncomment locale in libc-locales
sed -i "s/^#\(${LOCALE} \)/\1/" /etc/default/libc-locales
xbps-reconfigure -f glibc-locales

# System-wide locale
echo "LANG=${LOCALE}" > /etc/locale.conf

# ---------------------------------------------------------------------------
# 4. Hostname
# ---------------------------------------------------------------------------
log "Setting hostname: ${HOSTNAME}"
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain  ${HOSTNAME}
EOF

# ---------------------------------------------------------------------------
# 5. Root password
# ---------------------------------------------------------------------------
log "Setting root password..."
echo "root:${ROOT_PASSWORD}" | chpasswd

# ---------------------------------------------------------------------------
# 6. Create user
# ---------------------------------------------------------------------------
log "Creating user: ${USERNAME}"
useradd -m -G wheel,audio,video,optical,storage,network,xbuilder \
        -s /bin/bash "$USERNAME"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# ---------------------------------------------------------------------------
# 7. sudo — allow wheel group
# ---------------------------------------------------------------------------
log "Configuring sudo..."
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# ---------------------------------------------------------------------------
# 8. GRUB bootloader
# ---------------------------------------------------------------------------
log "Installing GRUB..."

# Extra kernel parameters for NVIDIA DRM modesetting
GRUB_EXTRA=""
if [[ "$GPU_TYPE" == "nvidia" || "$GPU_TYPE" == "hybrid_intel_nvidia" ]]; then
    GRUB_EXTRA="nvidia-drm.modeset=1"
fi

# Modify GRUB defaults
sed -i "s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/" /etc/default/grub
sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="Void Linux"/' /etc/default/grub

if [[ -n "$GRUB_EXTRA" ]]; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${GRUB_EXTRA}\"|" \
        /etc/default/grub
fi

if [[ "$UEFI" == "true" ]]; then
    grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id="void" \
        --recheck \
        || die "grub-install (UEFI) failed"
else
    grub-install \
        --target=i386-pc \
        --recheck \
        "$INSTALL_DISK" \
        || die "grub-install (BIOS) failed"
fi

grub-mkconfig -o /boot/grub/grub.cfg
log "GRUB installed successfully"

# ---------------------------------------------------------------------------
# 9. NVIDIA: dracut / initramfs module configuration
# ---------------------------------------------------------------------------
if [[ "$GPU_TYPE" == "nvidia" || "$GPU_TYPE" == "hybrid_intel_nvidia" ]]; then
    log "Configuring NVIDIA (DRM modesetting + initramfs)..."
    mkdir -p /etc/dracut.conf.d
    echo 'add_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "' \
        > /etc/dracut.conf.d/nvidia.conf

    # Prevent nouveau from loading
    echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf
    echo 'install nouveau /bin/true' >> /etc/modprobe.d/blacklist-nouveau.conf

    # Regenerate initramfs for all kernels
    xbps-reconfigure -f linux
fi

# ---------------------------------------------------------------------------
# 10. Enable runit services
# ---------------------------------------------------------------------------
log "Enabling system services..."

SERVICES=(
    dbus
    elogind
    polkitd
    NetworkManager
    bluetoothd
    cupsd
    sddm
)

for svc in "${SERVICES[@]}"; do
    if [[ -d "/etc/sv/${svc}" ]]; then
        ln -sf "/etc/sv/${svc}" "/etc/runit/runsvdir/default/${svc}"
        log "  enabled: ${svc}"
    else
        echo "  [skip]  ${svc} (not found in /etc/sv)"
    fi
done

# ---------------------------------------------------------------------------
# 11. PipeWire — XDG autostart entries (per-user, no systemd user sessions)
# ---------------------------------------------------------------------------
log "Creating PipeWire autostart entries..."
mkdir -p /etc/xdg/autostart

cat > /etc/xdg/autostart/pipewire.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=PipeWire
Comment=PipeWire multimedia daemon
Exec=/usr/bin/pipewire
NoDisplay=true
X-KDE-autostart-after=dbus
DESKTOP

cat > /etc/xdg/autostart/wireplumber.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=WirePlumber
Comment=PipeWire session manager
Exec=/usr/bin/wireplumber
NoDisplay=true
X-KDE-autostart-after=dbus
DESKTOP

cat > /etc/xdg/autostart/pipewire-pulse.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=PipeWire PulseAudio
Comment=PulseAudio compatibility via PipeWire
Exec=/usr/bin/pipewire-pulse
NoDisplay=true
X-KDE-autostart-after=dbus
DESKTOP

# ---------------------------------------------------------------------------
# 12. SDDM — default Wayland session
# ---------------------------------------------------------------------------
log "Configuring SDDM..."
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/void.conf << 'EOF'
[Autologin]
Relogin=false

[General]
HaltCommand=/usr/bin/loginctl poweroff
RebootCommand=/usr/bin/loginctl reboot

[Theme]
DisableAvatarImage=false

[Wayland]
SessionDir=/usr/share/wayland-sessions

[X11]
SessionDir=/usr/share/xsessions
EOF

# ---------------------------------------------------------------------------
# 13. XDG user directories
# ---------------------------------------------------------------------------
log "Creating XDG user directories..."
# Create for the new user
su -c "xdg-user-dirs-update" "$USERNAME" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 14. SSD — weekly fstrim via cron
# ---------------------------------------------------------------------------
if [[ "$DISK_TYPE" == "ssd" ]]; then
    log "Scheduling weekly fstrim for SSD..."
    if command -v crond &>/dev/null || xbps-query -l | grep -q "^ii cronie"; then
        echo "0 3 * * 0 root /sbin/fstrim -a 2>/dev/null" > /etc/cron.d/fstrim
    else
        # snooze is a Void-native cron replacement
        xbps-install -y snooze 2>/dev/null || true
        if command -v snooze &>/dev/null; then
            mkdir -p /etc/sv/fstrim-weekly/log
            cat > /etc/sv/fstrim-weekly/run << 'SH'
#!/bin/sh
exec snooze -w Sun -t 03:00:00 fstrim -a
SH
            chmod +x /etc/sv/fstrim-weekly/run
            ln -sf /etc/sv/fstrim-weekly /etc/runit/runsvdir/default/fstrim-weekly
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 15. Final reconfigure pass (kernel + initramfs)
# ---------------------------------------------------------------------------
log "Final xbps-reconfigure pass..."
xbps-reconfigure -fa

log ""
log "Chroot configuration complete."
