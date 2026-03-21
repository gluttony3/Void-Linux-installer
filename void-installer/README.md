# Void Linux Installer

![License](https://img.shields.io/badge/license-GPL--2.0-blue)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/platform-linux-lightgrey?logo=linux&logoColor=white)
![Init](https://img.shields.io/badge/init-runit-orange)
![Desktop](https://img.shields.io/badge/desktop-KDE_Plasma_5-1d99f3?logo=kde&logoColor=white)

A shell-based automated installer for **Void Linux** that sets up a complete
desktop environment from the live ISO.

---

## Stack

| Component   | Choice                        |
|-------------|-------------------------------|
| Init        | **runit**                     |
| Desktop     | **KDE Plasma 5** — Wayland    |
| Audio       | **PipeWire** + WirePlumber    |
| Network     | **NetworkManager**            |
| Bootloader  | **GRUB** (UEFI & BIOS)        |

---

## Features

- Auto-detection of **UEFI / BIOS** firmware
- Auto-detection of **SSD / HDD** — enables `discard` + weekly `fstrim` for SSDs
- Auto-installation of **CPU microcode** (Intel / AMD)
- Auto-detection and installation of **GPU drivers**:

  | GPU              | Packages installed                                              |
  |------------------|-----------------------------------------------------------------|
  | Intel            | `mesa` `mesa-vulkan-intel` `intel-media-driver`                 |
  | AMD              | `mesa` `mesa-vulkan-radeon` `xf86-video-amdgpu` `mesa-vaapi`   |
  | NVIDIA           | `nvidia` `egl-wayland` — DRM modesetting, nonfree repo enabled  |
  | Intel + NVIDIA   | Both sets above — PRIME offload ready                           |

- **GPT** partition layout for UEFI, **MBR** for BIOS
- SWAP size = RAM size, capped at **8 GB**
- Minimal KDE Plasma — no unnecessary applications
- PipeWire started via **XDG autostart** (no systemd user sessions)

---

## Requirements

- Booted from a **Void Linux live ISO** (any init variant)
- Active **internet connection**
- The target disk will be **completely erased**

---

## Usage

```bash
git clone https://github.com/gluttony3/void-installer.git
cd void-installer
chmod +x void-installer.sh lib/*.sh
sudo ./void-installer.sh
```

The installer will guide you through:

1. CPU & GPU detection
2. Disk selection and automatic partitioning
3. Hostname, username, timezone and passwords
4. Full system installation and configuration
5. Reboot

---

## Partition Layout

**UEFI (GPT)**

```
Part 1   512 MB    EFI System   (FAT32)
Part 2   [RAM] GB  Linux swap
Part 3   rest      Linux root   (ext4)
```

**BIOS (MBR)**

```
Part 1   [RAM] GB  Linux swap
Part 2   rest      Linux root   (ext4, bootable)
```

---

## File Structure

```
void-installer.sh        Entry point
lib/
  common.sh              Colors, logging, user input collection
  detect.sh              CPU, GPU and disk-type detection
  disk.sh                Partitioning, formatting, mounting, fstab
  install.sh             Package list construction and xbps-install
  configure.sh           Chroot orchestrator
  chroot-setup.sh        Runs inside xchroot to configure the system
```

---

## After Installation

At the SDDM login screen select **Plasma (Wayland)** from the session menu.

---

## License

[GPL-2.0](LICENSE)
