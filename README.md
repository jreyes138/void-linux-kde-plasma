# Void Linux KDE Plasma Installer

Two-script pipeline for a full Void Linux + KDE Plasma 6 desktop with Gruvbox theming.

1. **install-void-base.sh** — partitions disk, creates btrfs subvolumes, bootstraps base-system via XBPS chroot method, installs GRUB, nonfree repos, reboots
2. **install-kde-plasma.sh** — installs KDE Plasma 6, Gruvbox theme, audio, network, CLI tools, Flatpak apps on top of the base

## Two-script installation workflow

### Step 1: Base system (install-void-base.sh)

Boot a Void live image, then run:

```sh
# Basic install — btrfs with @ and @home subvolumes, mainline kernel
sudo bash install-void-base.sh --disk /dev/sda --hostname voidbox

# With a user account
sudo bash install-void-base.sh --disk /dev/nvme0n1 --hostname laptop --user lenier

# ext4 instead of btrfs
sudo bash install-void-base.sh --disk /dev/sda --hostname voidbox --fs ext4

# Stock kernel instead of mainline
sudo bash install-void-base.sh --disk /dev/sda --hostname voidbox --kernel stock
```

This partitions the disk (UEFI or BIOS auto-detected), creates btrfs subvolumes (@ and @home with zstd compression), installs base-system via XBPS, installs GRUB, enables nonfree/multilib repos, and reboots.

### Step 2: Desktop (install-kde-plasma.sh)

After reboot, log in as root (or your wheel user), download the script, and run:

```sh
curl -O https://raw.githubusercontent.com/jreyes138/void-linux-kde-plasma/main/install-kde-plasma.sh
sudo bash install-kde-plasma.sh
```

This installs KDE Plasma 6, Gruvbox theme, audio, network, CLI tools, Flatpak apps, automatic updates, and power management.

## Features

- **Hardware discovery** — detects GPU, audio, Bluetooth, Wi-Fi, touchpad, Wacom, and VM platform before installing only what's needed
- **Mainline kernel** — installs linux-mainline (latest upstream stable, 7.x series) by default, stock LTS kernel kept as fallback
- **13-phase install** — xbps self-update, full system upgrade, firmware/microcode, mainline kernel, core desktop, GPU drivers, input drivers, audio, network/Bluetooth, VM guest tools, SDDM, CLI tools/fonts/shell, themes, Flatpak apps
- **PipeWire/WirePlumber audio** — D-Bus session bus wrapper for KDE's `dbus-run-session`, config symlinks, ALSA integration
- **elogind boot race fix** — inlined wrapper + wait loop prevents runit from flapping to "down"
- **Breeze Dark theme** — pre-configured via kdeglobals so dark theme is active on first login
- **Gruvbox Plus Dark icons** — installed system-wide from [github.com/SylEleuth/gruvbox-plus-icon-pack](https://github.com/SylEleuth/gruvbox-plus-icon-pack)
- **Flatpak + Flathub** — Brave Browser, Tutanota, xdg-desktop-portal-kde integration
- **CLI tools** — bat, micro (nano aliased to micro), eza, git, wget, curl, wezterm, bash-completion
- **Nerd Fonts + base fonts** — dejavu, noto, noto-emoji, nerd-fonts-symbols
- **Custom bash prompt** — two-line box style with exit code indicator
- **SDDM autologin** — optional `--autologin USER` flag for VMs/headless testing

## Usage

```sh
# Full install (reboots at the end)
sudo bash install-kde-plasma.sh

# Install without reboot
sudo bash install-kde-plasma.sh --no-reboot

# Install with autologin for a specific user
sudo bash install-kde-plasma.sh --autologin joser

# Minimal install (skip full xorg, use xorg-minimal)
sudo bash install-kde-plasma.sh --minimal

# Skip Flatpak/Flathub apps
sudo bash install-kde-plasma.sh --no-flatpak

# Skip optional extras (sounds, browser integration, thumbnails)
sudo bash install-kde-plasma.sh --no-extras

# Combine flags
sudo bash install-kde-plasma.sh --no-reboot --autologin joser --no-flatpak
```

## Flags

### install-void-base.sh

| Flag | Description |
|------|-------------|
| `--disk /dev/sdX` | Target disk (required, e.g. /dev/sda or /dev/nvme0n1) |
| `--hostname NAME` | System hostname (required) |
| `--fs btrfs` | Filesystem: btrfs (default) or ext4 |
| `--keymap us` | Console keyboard layout (default: us) |
| `--locale en_US.UTF-8` | System locale (default: en_US.UTF-8, glibc only) |
| `--kernel mainline` | Kernel: mainline (default) or stock |
| `--user NAME` | Create user account with wheel + sudo |
| `--password-stdin` | Read root password from stdin (for scripting) |
| `--no-nonfree` | Skip nonfree/multilib repo enablement |
| `--no-reboot` | Don't reboot at the end |
| `--repo URL` | XBPS repository URL (default: https://repo-default.voidlinux.org/current) |
| `--arch x86_64` | Target architecture (default: auto-detect) |
| `--yes` | Skip confirmation prompt (for automation) |

### install-kde-plasma.sh

| Flag | Description |
|------|-------------|
| `--minimal` | Use xorg-minimal instead of full xorg |
| `--no-reboot` | Do not reboot at the end |
| `--wayland` | Note Wayland preference (SDDM supports both) |
| `--no-extras` | Skip optional packages (sounds, browser integration, thumbnails) |
| `--no-firmware` | Skip linux-firmware installation |
| `--no-flatpak` | Skip Flatpak/Flathub setup and app installation |
| `--no-mainline` | Skip linux-mainline kernel installation (keep stock LTS kernel) |
| `--no-btrfs-compress` | Skip btrfs zstd compression enablement (if btrfs root) |
| `--autologin USER` | Enable SDDM autologin for the given user |

## Requirements

- Void Linux live image (for Step 1: install-void-base.sh)
- Fresh Void Linux base install (for Step 2: install-kde-plasma.sh)
- Root access (sudo)
- Internet connection

## What it installs

### Core Desktop
- kde-plasma, kde-baseapps, sddm, dbus, polkit-elogind, xdg-utils, konsole
- elogind (session/seat management with boot race fix)
- xorg or xorg-minimal (based on --minimal flag)
- GPU driver auto-detection: Intel, AMD, NVIDIA (nouveau), QXL, virtio, VMware

### Kernel
- linux-mainline (latest upstream stable, 7.x series) — installed by default
- linux (stock LTS kernel) — kept as fallback in GRUB menu
- Use `--no-mainline` to skip mainline kernel installation

### Btrfs Compression (automatic if btrfs root)
- zstd transparent compression enabled via fstab (compress=zstd)
- snapper installed for snapshot management (timeline + cleanup)
- btrfs quota enabled for snapshot space tracking
- Use `--no-btrfs-compress` to skip
- Only activates if root filesystem is btrfs — install Void with btrfs to use

### Audio
- pipewire, wireplumber, wireplumber-elogind, rtkit
- alsa-utils, pulseaudio-utils, alsa-pipewire
- libspa-bluetooth (if Bluetooth detected)
- PipeWire config symlinks + ALSA config symlinks
- WirePlumber D-Bus session bus wrapper (/usr/local/bin/wireplumber-autostart)

### Network
- NetworkManager (disables conflicting dhcpcd/wpa_supplicant)
- bluez + bluetoothd (if Bluetooth detected)
- User added to network and bluetooth groups
- rfkill unblock for Bluetooth

### CLI Tools
- bat (cat replacement), micro (editor, nano aliased to it), eza (ls replacement)
- git, wget, curl, bash-completion
- wezterm (GPU-accelerated terminal, set as default)
- nerd-fonts-symbols-ttf, dejavu-fonts-ttf, noto-fonts-ttf, noto-fonts-emoji

### Themes
- Breeze Dark color scheme + look-and-feel (pre-configured)
- Gruvbox Plus Dark icons (system-wide)
- Breeze cursor theme

### Flatpak Apps
- Brave Browser (com.brave.Browser)
- Tutanota/Tuta (com.tutanota.Tutanota)
- xdg-desktop-portal + xdg-desktop-portal-kde

## Void Linux specific gotchas handled

1. **elogind boot race** — elogind forks, parent exits, runit flaps to "down". Fixed with wait loop.
2. **WirePlumber D-Bus session bus** — KDE's `plasma-dbus-run-session-if-needed` creates a private bus in /tmp. WirePlumber autostart can't find it. Fixed with wrapper script.
3. **libstdc++ ABI mismatch** — Full system upgrade required before installing kde-plasma (Qt6 needs newer CXXABI).
4. **PipeWire autostart** — .desktop files ship in /usr/share/applications/ but Void doesn't place them in /etc/xdg/autostart/.
5. **.config ownership** — Script running as root creates ~/.config with root ownership, breaking Plasma theme Apply button. Fixed with chown pass.
6. **SDDM config** — Must have no leading whitespace or SDDM can't parse it.

## License

MIT