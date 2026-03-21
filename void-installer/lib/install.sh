#!/usr/bin/env bash
# install.sh — Package list construction and xbps-install to target

VOID_REPO_MAIN="https://repo-default.voidlinux.org/current"
VOID_REPO_NONFREE="https://repo-default.voidlinux.org/current/nonfree"

_setup_repos() {
    log_info "Configuring XBPS repositories for target..."

    mkdir -p /mnt/var/db/xbps/keys /mnt/etc/xbps.d

    # Copy XBPS signing keys
    cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

    # Main repository
    echo "repository=${VOID_REPO_MAIN}" > /mnt/etc/xbps.d/00-repo-main.conf

    # Non-free repository (required for NVIDIA)
    if [[ "$GPU_TYPE" == "nvidia" || "$GPU_TYPE" == "hybrid_intel_nvidia" ]]; then
        echo "repository=${VOID_REPO_NONFREE}" > /mnt/etc/xbps.d/10-repo-nonfree.conf
        log_info "Non-free repo enabled (NVIDIA)"
    fi
}

_build_package_list() {
    PACKAGES=(
        # Base system
        base-system
        linux
        linux-firmware
        linux-headers

        # Bootloader
        grub
        os-prober

        # Desktop — KDE Plasma 5 (minimal, Wayland)
        kde5
        kde5-baseapps
        sddm
        xorg-server          # X11 fallback + Xwayland
        xwayland             # X11 apps inside Wayland session

        # Audio — PipeWire stack
        pipewire
        wireplumber
        pipewire-pulse       # PulseAudio compatibility layer
        alsa-pipewire        # ALSA compatibility
        libspa-bluetooth     # Bluetooth audio

        # Network
        NetworkManager
        network-manager-applet
        wpa_supplicant

        # System services / desktop integration
        dbus
        elogind
        polkit
        xdg-user-dirs
        xdg-utils
        udisks2
        upower
        bluez
        cups

        # Basic utilities
        sudo
        bash
        bash-completion
        nano
        wget
        curl
        git
        htop
        zip
        unzip
    )

    # UEFI boot
    if [[ "$UEFI" == "true" ]]; then
        PACKAGES+=(grub-x86_64-efi efibootmgr)
    fi

    # CPU microcode
    case "$CPU_VENDOR" in
        intel) PACKAGES+=(intel-ucode) ;;
        # AMD microcode is shipped inside linux-firmware
    esac

    # GPU drivers
    case "$GPU_TYPE" in
        intel)
            PACKAGES+=(
                mesa
                mesa-dri
                vulkan-loader
                mesa-vulkan-intel
                intel-media-driver    # VAAPI (Gen 8+)
                xf86-input-libinput
            )
            ;;
        amd)
            PACKAGES+=(
                mesa
                mesa-dri
                vulkan-loader
                mesa-vulkan-radeon
                xf86-video-amdgpu
                mesa-vaapi
                mesa-vdpau
                xf86-input-libinput
            )
            ;;
        nvidia)
            PACKAGES+=(
                nvidia              # proprietary driver (nonfree)
                egl-wayland         # EGL Wayland platform support
            )
            ;;
        hybrid_intel_nvidia)
            PACKAGES+=(
                mesa
                mesa-dri
                vulkan-loader
                mesa-vulkan-intel
                intel-media-driver
                nvidia
                egl-wayland
                xf86-input-libinput
            )
            ;;
        generic)
            PACKAGES+=(mesa mesa-dri xf86-input-libinput)
            ;;
    esac

    export PACKAGES
}

install_base() {
    _setup_repos
    _build_package_list

    log_info "Synchronizing repository index..."
    xbps-install -S -y -r /mnt 2>/dev/null || true  # sync only

    log_info "Installing ${#PACKAGES[@]} packages — this may take a while..."
    xbps-install -S -y -r /mnt "${PACKAGES[@]}" \
        || die "Base installation failed. Check your internet connection and try again."

    log_success "Base system installed (${#PACKAGES[@]} packages)"
}
