#!/usr/bin/env bash
set -Eeuo pipefail

# Automatic Void Linux installer for x86_64 machines.
# WARNING: this script erases the selected target disk.
#
# Example:
#   TARGET_DISK=/dev/nvme0n1 USERNAME=alex HOSTNAME=voidbox ./void-auto-install.sh
#
# Optional environment variables:
#   TARGET_DISK=/dev/sda              skip interactive disk selection
#   USERNAME=user HOSTNAME=void       installed account and hostname
#   TIMEZONE=Europe/Kyiv KEYMAP=us    timezone and console keymap
#   LOCALE=en_US.UTF-8                glibc locale
#   REPOSITORY=https://.../current    XBPS repository mirror
#   NVIDIA_DRIVER=nouveau             or nvidia, nvidia580, nvidia470, nvidia390

MOUNTPOINT="${MOUNTPOINT:-/mnt}"
HOSTNAME="${HOSTNAME:-void}"
USERNAME="${USERNAME:-user}"
TIMEZONE="${TIMEZONE:-Europe/Kyiv}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
REPOSITORY="${REPOSITORY:-https://repo-default.voidlinux.org/current}"
TARGET_DISK="${TARGET_DISK:-}"
FILESYSTEM="${FILESYSTEM:-ext4}"
NVIDIA_DRIVER="${NVIDIA_DRIVER:-nouveau}"

log() {
  printf '\033[1;32m==>\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

run() {
  log "$*"
  "$@"
}

cleanup() {
  set +e
  mountpoint -q "$MOUNTPOINT/dev" && umount -R "$MOUNTPOINT/dev"
  mountpoint -q "$MOUNTPOINT/proc" && umount -R "$MOUNTPOINT/proc"
  mountpoint -q "$MOUNTPOINT/sys" && umount -R "$MOUNTPOINT/sys"
}
trap cleanup EXIT

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root from a Void Linux live system."
}

require_commands() {
  local missing=()
  local cmd
  for cmd in awk bash blkid chroot findmnt grep lsblk mkfs.ext4 mkswap mount partprobe sfdisk swapoff swapon wipefs xbps-install xbps-query; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}"
  fi
}

detect_boot_mode() {
  if [[ -d /sys/firmware/efi/efivars ]]; then
    BOOT_MODE="uefi"
  else
    BOOT_MODE="bios"
  fi
  log "Detected boot mode: $BOOT_MODE"
}

disk_is_install_media() {
  local disk="$1"
  local source parent
  source="$(findmnt -n -o SOURCE /run/initramfs/live 2>/dev/null || true)"
  [[ -z "$source" ]] && source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  [[ -z "$source" ]] && return 1
  parent="/dev/$(lsblk -no PKNAME "$source" 2>/dev/null | head -n1)"
  [[ "$parent" == "$disk" ]]
}

choose_disk() {
  if [[ -n "$TARGET_DISK" ]]; then
    [[ -b "$TARGET_DISK" ]] || die "TARGET_DISK is not a block device: $TARGET_DISK"
    DISK="$TARGET_DISK"
    return
  fi

  mapfile -t candidates < <(
    lsblk -dpno NAME,TYPE,RM,SIZE,MODEL |
      awk '$2 == "disk" && $3 == "0" {print $1}'
  )

  local filtered=()
  local d
  for d in "${candidates[@]}"; do
    if ! disk_is_install_media "$d"; then
      filtered+=("$d")
    fi
  done

  if [[ "${#filtered[@]}" -eq 1 ]]; then
    DISK="${filtered[0]}"
    log "Selected the only non-removable disk: $DISK"
    return
  fi

  printf '\nAvailable disks:\n'
  lsblk -dpno NAME,SIZE,MODEL,TRAN,ROTA,RM,TYPE | awk '$7 == "disk" {print "  " $0}'
  printf '\nType target disk path, for example /dev/nvme0n1: '
  read -r DISK
  [[ -b "$DISK" ]] || die "Not a block device: $DISK"
}

detect_storage() {
  local name rotational
  name="$(basename "$DISK")"
  rotational="$(cat "/sys/block/$name/queue/rotational" 2>/dev/null || printf '1')"
  if [[ "$rotational" == "0" ]]; then
    STORAGE="ssd"
    ROOT_OPTS="defaults,noatime,discard"
  else
    STORAGE="hdd"
    ROOT_OPTS="defaults,noatime"
  fi
  log "Detected storage type for $DISK: $STORAGE"
}

detect_cpu_vendor() {
  if grep -qi GenuineIntel /proc/cpuinfo; then
    CPU_VENDOR="intel"
  elif grep -qi AuthenticAMD /proc/cpuinfo; then
    CPU_VENDOR="amd"
  else
    CPU_VENDOR="unknown"
  fi
  log "Detected CPU vendor: $CPU_VENDOR"
}

detect_gpus() {
  GPU_VENDORS=()
  if command -v lspci >/dev/null 2>&1; then
    lspci -nn | grep -Eiq 'VGA|3D|Display' || true
    if lspci -nn | grep -Ei 'VGA|3D|Display' | grep -qi 'Intel'; then
      GPU_VENDORS+=("intel")
    fi
    if lspci -nn | grep -Ei 'VGA|3D|Display' | grep -Eqi 'AMD|ATI'; then
      GPU_VENDORS+=("amd")
    fi
    if lspci -nn | grep -Ei 'VGA|3D|Display' | grep -qi 'NVIDIA'; then
      GPU_VENDORS+=("nvidia")
    fi
  fi

  if [[ "${#GPU_VENDORS[@]}" -eq 0 ]]; then
    GPU_VENDORS=("generic")
  fi
  log "Detected GPU vendor(s): ${GPU_VENDORS[*]}"
}

calculate_swap() {
  local ram_mib
  ram_mib="$(awk '/MemTotal/ {printf "%d\n", ($2 + 1023) / 1024}' /proc/meminfo)"
  if (( ram_mib > 8192 )); then
    SWAP_MIB=8192
  else
    SWAP_MIB="$ram_mib"
  fi
  (( SWAP_MIB >= 512 )) || SWAP_MIB=512
  log "Swap size: ${SWAP_MIB} MiB"
}

partition_name() {
  local index="$1"
  if [[ "$DISK" =~ [0-9]$ ]]; then
    printf '%sp%s' "$DISK" "$index"
  else
    printf '%s%s' "$DISK" "$index"
  fi
}

confirm_erase() {
  printf '\nThis will ERASE ALL DATA on %s.\n' "$DISK"
  lsblk "$DISK"
  printf '\nType exactly ERASE %s to continue: ' "$DISK"
  read -r answer
  [[ "$answer" == "ERASE $DISK" ]] || die "Aborted."
}

partition_disk() {
  run swapoff -a || true
  run wipefs -af "$DISK"

  if [[ "$BOOT_MODE" == "uefi" ]]; then
    log "Creating GPT layout for UEFI"
    sfdisk "$DISK" <<EOF
label: gpt
unit: MiB

1,512,U
,${SWAP_MIB},S
,,L
EOF
    EFI_PART="$(partition_name 1)"
    SWAP_PART="$(partition_name 2)"
    ROOT_PART="$(partition_name 3)"
  else
    log "Creating MBR layout for BIOS"
    sfdisk "$DISK" <<EOF
label: dos
unit: MiB

1,${SWAP_MIB},S
,,L,*
EOF
    EFI_PART=""
    SWAP_PART="$(partition_name 1)"
    ROOT_PART="$(partition_name 2)"
  fi

  run partprobe "$DISK"
  sleep 2
}

format_and_mount() {
  if [[ "$BOOT_MODE" == "uefi" ]]; then
    command -v mkfs.vfat >/dev/null 2>&1 || die "mkfs.vfat is required for UEFI. Install dosfstools in the live environment."
    run mkfs.vfat -F32 "$EFI_PART"
  fi

  run mkswap -f "$SWAP_PART"
  run mkfs.ext4 -F "$ROOT_PART"

  run mkdir -p "$MOUNTPOINT"
  run mount "$ROOT_PART" "$MOUNTPOINT"
  if [[ "$BOOT_MODE" == "uefi" ]]; then
    run mkdir -p "$MOUNTPOINT/boot/efi"
    run mount "$EFI_PART" "$MOUNTPOINT/boot/efi"
  fi
  run swapon "$SWAP_PART"
}

xbps_target() {
  xbps-install -Sy -R "$REPOSITORY" -r "$MOUNTPOINT" "$@"
}

pkg_available() {
  xbps-query -R -r "$MOUNTPOINT" "$1" >/dev/null 2>&1
}

install_if_available() {
  local pkgs=()
  local pkg
  for pkg in "$@"; do
    if pkg_available "$pkg"; then
      pkgs+=("$pkg")
    else
      warn "Skipping unavailable package: $pkg"
    fi
  done
  if [[ "${#pkgs[@]}" -gt 0 ]]; then
    xbps_target "${pkgs[@]}"
  fi
}

base_packages() {
  PACKAGES=(
    base-system
    linux
    linux-firmware
    grub
    NetworkManager
    dbus
    elogind
    sudo
    vim
    chrony
    cronie
    xtools
    pciutils
    mesa-dri
    vulkan-loader
    xorg-minimal
    xorg-server-xwayland
    kde-plasma
    qt5-wayland
    qt6-wayland
    xdg-desktop-portal-kde
    pipewire
    alsa-pipewire
    libspa-bluetooth
    pulseaudio-utils
    pavucontrol-qt
  )

  if [[ "$BOOT_MODE" == "uefi" ]]; then
    PACKAGES+=(grub-x86_64-efi efibootmgr dosfstools)
  fi

  case "$CPU_VENDOR" in
    intel) PACKAGES+=(void-repo-nonfree intel-ucode linux-firmware-intel) ;;
    amd) PACKAGES+=(linux-firmware-amd) ;;
  esac

  local vendor
  for vendor in "${GPU_VENDORS[@]}"; do
    case "$vendor" in
      intel)
        PACKAGES+=(linux-firmware-intel mesa-vulkan-intel intel-video-accel libvdpau-va-gl)
        ;;
      amd)
        PACKAGES+=(linux-firmware-amd mesa-vulkan-radeon mesa-vaapi libvdpau-va-gl xf86-video-amdgpu)
        ;;
      nvidia)
        if [[ "$NVIDIA_DRIVER" == "nouveau" ]]; then
          PACKAGES+=(xf86-video-nouveau mesa-vulkan-nouveau mesa-vaapi libvdpau-va-gl)
        else
          PACKAGES+=(void-repo-nonfree "$NVIDIA_DRIVER")
        fi
        ;;
    esac
  done
}

install_system() {
  log "Installing base system and desktop packages"
  xbps-install -Sy -R "$REPOSITORY" -r "$MOUNTPOINT" xbps
  xbps-install -S -r "$MOUNTPOINT"
  base_packages

  if printf '%s\n' "${PACKAGES[@]}" | grep -qx 'void-repo-nonfree'; then
    install_if_available void-repo-nonfree
    xbps-install -S -r "$MOUNTPOINT"
  fi

  install_if_available "${PACKAGES[@]}"
}

write_fstab() {
  local root_uuid swap_uuid efi_uuid
  root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
  swap_uuid="$(blkid -s UUID -o value "$SWAP_PART")"
  {
    printf 'UUID=%s / %s %s 0 1\n' "$root_uuid" "$FILESYSTEM" "$ROOT_OPTS"
    printf 'UUID=%s none swap sw 0 0\n' "$swap_uuid"
    if [[ "$BOOT_MODE" == "uefi" ]]; then
      efi_uuid="$(blkid -s UUID -o value "$EFI_PART")"
      printf 'UUID=%s /boot/efi vfat defaults,noatime 0 2\n' "$efi_uuid"
    fi
  } > "$MOUNTPOINT/etc/fstab"
}

configure_target_files() {
  log "Writing system configuration"
  printf '%s\n' "$HOSTNAME" > "$MOUNTPOINT/etc/hostname"
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$MOUNTPOINT/etc/localtime"

  if [[ -f "$MOUNTPOINT/etc/default/libc-locales" ]]; then
    sed -i "s/^#\?$LOCALE UTF-8/$LOCALE UTF-8/" "$MOUNTPOINT/etc/default/libc-locales" || true
  fi

  cat > "$MOUNTPOINT/etc/rc.conf" <<EOF
KEYMAP="$KEYMAP"
HARDWARECLOCK="UTC"
TIMEZONE="$TIMEZONE"
EOF

  mkdir -p "$MOUNTPOINT/etc/sudoers.d"
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$MOUNTPOINT/etc/sudoers.d/00-wheel"
  chmod 0440 "$MOUNTPOINT/etc/sudoers.d/00-wheel"

  mkdir -p "$MOUNTPOINT/etc/pipewire/pipewire.conf.d"
  ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf "$MOUNTPOINT/etc/pipewire/pipewire.conf.d/10-wireplumber.conf"
  ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf "$MOUNTPOINT/etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf"

  mkdir -p "$MOUNTPOINT/etc/alsa/conf.d"
  ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf "$MOUNTPOINT/etc/alsa/conf.d/50-pipewire.conf"
  ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf "$MOUNTPOINT/etc/alsa/conf.d/99-pipewire-default.conf"

  mkdir -p "$MOUNTPOINT/etc/xdg/autostart"
  if [[ -e "$MOUNTPOINT/usr/share/applications/pipewire.desktop" ]]; then
    ln -sf /usr/share/applications/pipewire.desktop "$MOUNTPOINT/etc/xdg/autostart/pipewire.desktop"
  else
    cat > "$MOUNTPOINT/etc/xdg/autostart/pipewire.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire
Exec=pipewire
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
  fi

  cat > "$MOUNTPOINT/etc/xdg/autostart/wireplumber.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=WirePlumber
Exec=wireplumber
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

  cat > "$MOUNTPOINT/etc/xdg/autostart/pipewire-pulse.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=PipeWire PulseAudio
Exec=pipewire-pulse
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

  mkdir -p "$MOUNTPOINT/etc/sddm.conf.d"
  cat > "$MOUNTPOINT/etc/sddm.conf.d/10-wayland-plasma.conf" <<'EOF'
[General]
DisplayServer=wayland

[Autologin]
Session=plasmawayland.desktop
EOF

  if [[ "$STORAGE" == "ssd" ]]; then
    mkdir -p "$MOUNTPOINT/etc/cron.weekly"
    cat > "$MOUNTPOINT/etc/cron.weekly/fstrim" <<'EOF'
#!/bin/sh
/usr/bin/fstrim -av
EOF
    chmod 0755 "$MOUNTPOINT/etc/cron.weekly/fstrim"
  fi
}

bind_mounts() {
  run mount --rbind /dev "$MOUNTPOINT/dev"
  run mount --make-rslave "$MOUNTPOINT/dev"
  run mount -t proc /proc "$MOUNTPOINT/proc"
  run mount --rbind /sys "$MOUNTPOINT/sys"
  run mount --make-rslave "$MOUNTPOINT/sys"
}

in_chroot() {
  chroot "$MOUNTPOINT" /bin/bash -c "$*"
}

configure_chroot() {
  log "Configuring installed system"
  bind_mounts

  in_chroot "xbps-reconfigure -f glibc-locales || true"
  in_chroot "xbps-reconfigure -fa"
  in_chroot "dbus-uuidgen --ensure=/etc/machine-id"

  if [[ "$BOOT_MODE" == "uefi" ]]; then
    in_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id='Void Linux' --recheck"
  else
    in_chroot "grub-install --target=i386-pc --recheck '$DISK'"
  fi
  in_chroot "grub-mkconfig -o /boot/grub/grub.cfg"

  in_chroot "mkdir -p /var/service"
  in_chroot "ln -sf /etc/sv/dbus /var/service/dbus"
  in_chroot "ln -sf /etc/sv/elogind /var/service/elogind"
  in_chroot "ln -sf /etc/sv/NetworkManager /var/service/NetworkManager"
  in_chroot "ln -sf /etc/sv/sddm /var/service/sddm"
  in_chroot "ln -sf /etc/sv/chronyd /var/service/chronyd || true"
  in_chroot "ln -sf /etc/sv/crond /var/service/crond || true"

  if ! in_chroot "id '$USERNAME' >/dev/null 2>&1"; then
    in_chroot "useradd -m -G wheel,audio,video,input,network,storage -s /bin/bash '$USERNAME'"
  fi
}

set_passwords() {
  log "Set root password"
  chroot "$MOUNTPOINT" passwd root
  log "Set password for user $USERNAME"
  chroot "$MOUNTPOINT" passwd "$USERNAME"
}

main() {
  require_root
  require_commands
  detect_boot_mode
  choose_disk
  detect_storage
  detect_cpu_vendor
  detect_gpus
  calculate_swap
  confirm_erase
  partition_disk
  format_and_mount
  install_system
  write_fstab
  configure_target_files
  configure_chroot
  set_passwords

  log "Installation complete. Reboot after unmounting $MOUNTPOINT."
  log "Summary: boot=$BOOT_MODE disk=$DISK storage=$STORAGE swap=${SWAP_MIB}MiB cpu=$CPU_VENDOR gpu=${GPU_VENDORS[*]} nvidia_driver=$NVIDIA_DRIVER"
}

main "$@"
