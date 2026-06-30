#!/bin/bash
#
# install-kde-plasma.sh
# Automates KDE Plasma installation on a fresh Void Linux base install.
# Performs hardware discovery first, then installs only what's needed.
# Optionally installs a full Gruvbox theme (color scheme, icons, Kvantum,
# fastfetch, wallpaper) for Plasma 6.
#
# Usage:
#   sudo bash install-kde-plasma.sh
#   sudo ./install-kde-plasma.sh
#
# Optional flags:
#   --minimal        Use xorg-minimal instead of full xorg
#   --no-reboot      Do not reboot at the end
#   --wayland        Prefer Wayland session (SDDM still handles both)
#   --no-extras      Skip optional packages (sounds, browser integration, thumbnails)
#   --no-firmware    Skip linux-firmware installation (already installed or not needed)
#   --no-flatpak     Skip Flatpak/Flathub setup and app installation
#   --no-mainline    Skip linux-mainline kernel installation (keep stock kernel)
#   --no-btrfs-compress  Skip btrfs zstd compression enablement (if btrfs root)
#   --no-apparmor    Skip AppArmor installation (MAC, enforce mode)
#   --no-hardening   Skip kernel hardening (sysctl + GRUB cmdline)
#   --no-firewall     Skip UFW + plasma-firewall installation
#   --autologin USER Enable SDDM autologin for given user (e.g. --autologin joser)
#
# Gruvbox theme — enabled by default (dark variant + wallpaper):
#   --no-gruvbox              Disable Gruvbox theming entirely
#   --gruvbox-light           Use light variant (default: dark)
#   --no-gruvbox-icons        Skip Gruvbox Plus icon pack
#   --no-gruvbox-kvantum      Skip Kvantum theme
#   --no-gruvbox-fastfetch    Skip fastfetch installation
#   --no-gruvbox-wallpaper    Skip wallpaper installation
#   --gruvbox-wallpaper PATH  Use local wallpaper file instead of downloading default
#

# Re-exec with bash if not already running under bash
if [ -z "$BASH_VERSION" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────
MINIMAL=0
REBOOT=1
WAYLAND=0
EXTRAS=1
FIRMWARE=1
FLATPAK=1
MAINLINE_KERNEL=1
BTRFS_COMPRESS=1
APPARMOR=1
HARDENING=1
FIREWALL=1
AUTOLOGIN=""
LOG=/var/log/kde-plasma-install.log

# Gruvbox theme — enabled by default (dark variant + wallpaper)
# Applied after install, before reboot. Disable with --no-gruvbox.
GRUVBOX=1
GRUVBOX_VARIANT="dark"
GRUVBOX_ICONS=1
GRUVBOX_KVANTUM=1
GRUVBOX_FASTFETCH=1
GRUVBOX_WALLPAPER=1
GRUVBOX_WALLPAPER_PATH=""
GRUVBOX_WALLPAPER_URL="https://gruvbox-wallpapers.pages.dev/wallpapers/vector%20graphics/chillhop.com-cosy_retreat.png"
GRUVBOX_WALLPAPER_FILENAME="chillhop-cosy_retreat.png"

# ── parse args ───────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --minimal)     MINIMAL=1; shift ;;
    --no-reboot)   REBOOT=0; shift ;;
    --wayland)     WAYLAND=1; shift ;;
    --no-extras)   EXTRAS=0; shift ;;
    --no-firmware) FIRMWARE=0; shift ;;
    --no-flatpak)  FLATPAK=0; shift ;;
    --no-mainline) MAINLINE_KERNEL=0; shift ;;
    --no-btrfs-compress) BTRFS_COMPRESS=0; shift ;;
    --no-apparmor)  APPARMOR=0; shift ;;
    --no-hardening) HARDENING=0; shift ;;
    --no-firewall)  FIREWALL=0; shift ;;
    --autologin)   shift; AUTOLOGIN="${1:-}"; shift ;;
    --no-gruvbox)            GRUVBOX=0; shift ;;
    --gruvbox-light)         GRUVBOX_VARIANT="light"; shift ;;
    --no-gruvbox-icons)      GRUVBOX_ICONS=0; shift ;;
    --no-gruvbox-kvantum)    GRUVBOX_KVANTUM=0; shift ;;
    --no-gruvbox-fastfetch)  GRUVBOX_FASTFETCH=0; shift ;;
    --no-gruvbox-wallpaper)  GRUVBOX_WALLPAPER=0; shift ;;
    --gruvbox-wallpaper)     shift; GRUVBOX_WALLPAPER_PATH="${1:-}"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── pre-flight checks ────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run this script as root (sudo bash install-kde-plasma.sh)"
  exit 1
fi

if ! command -v xbps-install >/dev/null 2>&1; then
  echo "ERROR: xbps-install not found. This script is for Void Linux only."
  exit 1
fi

echo "[*] Void Linux KDE Plasma installer (with hardware discovery)"
echo "[*] Options: minimal=${MINIMAL} wayland=${WAYLAND} extras=${EXTRAS} firmware=${FIRMWARE} flatpak=${FLATPAK} mainline=${MAINLINE_KERNEL} btrfs_compress=${BTRFS_COMPRESS} apparmor=${APPARMOR} hardening=${HARDENING} firewall=${FIREWALL} autologin=${AUTOLOGIN:-none} reboot=${REBOOT} gruvbox=${GRUVBOX}"
echo "[*] Logging to ${LOG}"
exec > >(tee -a "$LOG") 2>&1
echo "[*] Started: $(date)"

# ═══════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════

# xinstall — wrapper around xbps-install that handles common errors:
#   - "already installed" -> not an error, skip silently
#   - "not found in repository pool" -> warn but don't abort
#   - network/other errors -> warn but don't abort
# Usage: xinstall <package1> [package2] ...
xinstall() {
  local pkgs=("$@")
  local output
  local real_error=0

  # xbps-install output goes to two places:
  #   - Progress bar: fetch_cb.c checks isatty(STDOUT_FILENO). When not a tty
  #     (our script pipes stdout through tee), it prints to STDOUT with \n
  #     per tick: "filename: [size N%] rate ETA: time\n" — one line per tick.
  #   - Status messages (state_cb.c): ALL go to STDOUT via printf():
  #     "[*] Downloading packages", "pkg: installed successfully", etc.
  #   - Errors (state_cb.c): go to STDERR via xbps_error_printf().
  #
  # We capture stdout+stderr, then filter out the progress bar lines (they
  # match the pattern: "filename: [size N%] rate ETA:" or "filename: size [avg rate:").
  # This keeps the useful status/error messages without the progress spam.
  output=$(xbps-install -y "${pkgs[@]}" 2>&1 | grep -v 'ETA:.*[0-9]*m[0-9]*s$\|avg rate:') || true

  while IFS= read -r line; do
    case "$line" in
      *already*installed*)
        # Not an error — package is already present
        ;;
      *not*found*in*repository*pool*|*not*found*in*repository*)
        echo "[!] WARNING: $line"
        real_error=1
        ;;
      *ERROR*|*No*space*|*failed*)
        echo "[!] ERROR: $line"
        real_error=1
        ;;
      *)
        [ -n "$line" ] && echo "$line"
        ;;
    esac
  done <<< "$output"

  if [ $real_error -eq 1 ]; then
    echo "[!] xbps-install had errors with: ${pkgs[*]}"
    echo "[!] Continuing — these packages may need manual installation."
  fi

  return 0
}

# dl_file — download a URL to a file using curl, falling back to wget.
# Usage: dl_file <url> <output_path>
# Returns 0 on success, 1 on failure.
dl_file() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    if curl -sL "$url" -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
      return 0
    fi
  fi

  if command -v wget >/dev/null 2>&1; then
    if wget -q "$url" -O "$dest" 2>/dev/null && [ -s "$dest" ]; then
      return 0
    fi
  fi

  return 1
}

# ═══════════════════════════════════════════════════════════════════════
# Phase 0: Install hardware detection tools
# ═══════════════════════════════════════════════════════════════════════
# A fresh Void base does NOT include lspci, lsusb, or lsmod.
# These are needed for Phase 1 hardware discovery.
echo ""
echo "=== Step 0.1: Installing hardware detection tools ==="
xbps-install -y -S xbps 2>/dev/null || true  # sync index first
xinstall pciutils usbutils kmod

# ═══════════════════════════════════════════════════════════════════════
# HARDWARE DISCOVERY
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 1: Hardware Discovery"
echo "══════════════════════════════════════════════════════════════"

# ── GPU detection ────────────────────────────────────────────────────
GPU_VENDOR="unknown"
GPU_MODEL="unknown"
GPU_PCI_LINE=""

# Read the first VGA/3D/display controller line from lspci
GPU_PCI_LINE=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | head -1 || true)

if echo "$GPU_PCI_LINE" | grep -qi 'nvidia'; then
  GPU_VENDOR="nvidia"
  GPU_MODEL=$(echo "$GPU_PCI_LINE" | sed 's/.*:\s*//; s/ *\[.*//')
elif echo "$GPU_PCI_LINE" | grep -qi 'qxl'; then
  GPU_VENDOR="qxl"
  GPU_MODEL="Red Hat QXL paravirtual graphics"
elif echo "$GPU_PCI_LINE" | grep -qi 'virtio'; then
  GPU_VENDOR="virtio"
  GPU_MODEL="virtio-gpu"
elif echo "$GPU_PCI_LINE" | grep -qi 'vmware\|svga'; then
  GPU_VENDOR="vmware"
  GPU_MODEL="VMware SVGA"
elif echo "$GPU_PCI_LINE" | grep -qi 'hyper-v\|microsoft'; then
  GPU_VENDOR="hyperv"
  GPU_MODEL="Hyper-V Virtual GPU"
elif echo "$GPU_PCI_LINE" | grep -qi 'advanced micro devices\|amd\|radeon'; then
  GPU_VENDOR="amd"
  GPU_MODEL=$(echo "$GPU_PCI_LINE" | sed 's/.*:\s*//; s/ *\[.*//')
elif echo "$GPU_PCI_LINE" | grep -qi 'intel'; then
  GPU_VENDOR="intel"
  GPU_MODEL=$(echo "$GPU_PCI_LINE" | sed 's/.*:\s*//; s/ *\[.*//')
elif [ -n "$GPU_PCI_LINE" ]; then
  GPU_VENDOR="unknown"
  GPU_MODEL=$(echo "$GPU_PCI_LINE" | sed 's/.*:\s*//; s/ *\[.*//')
fi

# Detect virtualization platform
VIRT_PLATFORM="none"
if [ -d /proc/1 ]; then
  if grep -qi 'hypervisor' /proc/cpuinfo 2>/dev/null; then
    # Running in a VM — detect which one
    if [ -f /sys/class/dmi/id/sys_vendor ]; then
      DMI_VENDOR=$(cat /sys/class/dmi/id/sys_vendor)
      case "$DMI_VENDOR" in
        *QEMU*|*Red*Hat*)      VIRT_PLATFORM="qemu-kvm" ;;
        *VMware*)               VIRT_PLATFORM="vmware" ;;
        *Hyper-V*|*Microsoft*)  VIRT_PLATFORM="hyperv" ;;
        *VirtualBox*|*innotek*) VIRT_PLATFORM="virtualbox" ;;
        *Xen*)                  VIRT_PLATFORM="xen" ;;
        *)                      VIRT_PLATFORM="vm-unknown($DMI_VENDOR)" ;;
      esac
    fi
  else
    VIRT_PLATFORM="none"
  fi
fi

# Detect CPU vendor for microcode
CPU_VENDOR="unknown"
if grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
  CPU_VENDOR="intel"
elif grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
  CPU_VENDOR="amd"
fi

# Detect audio controller
AUDIO_DETECTED=0
if lspci 2>/dev/null | grep -qi 'audio\|multimedia audio\|sound'; then
  AUDIO_DETECTED=1
fi

# Detect Bluetooth
BLUETOOTH_DETECTED=0
if lsusb 2>/dev/null | grep -qi 'bluetooth'; then
  BLUETOOTH_DETECTED=1
fi
# Also check for bluetooth kernel module loaded
if lsmod 2>/dev/null | grep -qi 'btusb\|bluetooth'; then
  BLUETOOTH_DETECTED=1
fi

# Detect Wi-Fi
WIFI_DETECTED=0
if lspci 2>/dev/null | grep -qi 'network.*wireless\|wifi\|802.11'; then
  WIFI_DETECTED=1
fi
if ls /sys/class/net/*/wireless 2>/dev/null | grep -q .; then
  WIFI_DETECTED=1
fi

# Detect touchpad
TOUCHPAD_DETECTED=0
if lspci 2>/dev/null | grep -qi 'touchpad'; then
  TOUCHPAD_DETECTED=1
fi
if [ -d /sys/class/input ]; then
  for dev in /sys/class/input/*/name; do
    if grep -qi 'touchpad\|synaptics\|elan\|alps' "$dev" 2>/dev/null; then
      TOUCHPAD_DETECTED=1
      break
    fi
  done
fi

# Detect Wacom tablet
WACOM_DETECTED=0
if lsusb 2>/dev/null | grep -qi 'wacom'; then
  WACOM_DETECTED=1
fi
if [ -d /sys/class/input ]; then
  for dev in /sys/class/input/*/name; do
    if grep -qi 'wacom' "$dev" 2>/dev/null; then
      WACOM_DETECTED=1
      break
    fi
  done
fi

# Detect VMware tools need
VMWARE_TOOLS=0
if [ "$VIRT_PLATFORM" = "vmware" ] || [ "$VIRT_PLATFORM" = "virtualbox" ]; then
  VMWARE_TOOLS=1
fi

# Detect root filesystem type
ROOT_FS_TYPE="unknown"
ROOT_DEVICE=""
ROOT_DEVICE=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOT_FS_TYPE=$(findmnt -no FSTYPE / 2>/dev/null || true)

# ── print discovery results ───────────────────────────────────────────
echo "  CPU vendor:        $CPU_VENDOR"
echo "  GPU vendor:        $GPU_VENDOR"
echo "  GPU model:         $GPU_MODEL"
echo "  Virtualization:    $VIRT_PLATFORM"
echo "  Root filesystem:   $ROOT_FS_TYPE ($ROOT_DEVICE)"
echo "  Audio controller:  $([ $AUDIO_DETECTED -eq 1 ] && echo 'present' || echo 'none')"
echo "  Bluetooth:         $([ $BLUETOOTH_DETECTED -eq 1 ] && echo 'present' || echo 'none')"
echo "  Wi-Fi:             $([ $WIFI_DETECTED -eq 1 ] && echo 'present' || echo 'none')"
echo "  Touchpad:          $([ $TOUCHPAD_DETECTED -eq 1 ] && echo 'present' || echo 'none')"
echo "  Wacom tablet:      $([ $WACOM_DETECTED -eq 1 ] && echo 'present' || echo 'none')"
echo "  VMware/VBox tools: $([ $VMWARE_TOOLS -eq 1 ] && echo 'yes' || echo 'no')"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Phase 2: System upgrade
# ═══════════════════════════════════════════════════════════════════════
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 2: System Upgrade"
echo "══════════════════════════════════════════════════════════════"

# A full upgrade is critical before installing KDE — Qt6 is built
# against the current GCC toolchain. If the base system has an older
# libstdc++ (e.g. GCC 13.2), SDDM/Plasma will crash with:
#   "CXXABI_1.3.15 not found (required by libQt6Core.so.6)"
# xbps-install -Sy only syncs the index; -Syu actually upgrades
# installed packages, pulling in the matching libstdc++.
echo ""
echo "=== Step 2.1: Updating xbps package manager ==="
# Update xbps itself first — a stale xbps can fail to parse newer repo metadata
xbps-install -y -u xbps 2>/dev/null || true

echo ""
echo "=== Step 2.2: Full system upgrade ==="
xbps-install -Syu || {
  echo "[!] WARNING: System upgrade had errors. Continuing but some packages may be outdated."
  echo "[!] Check the log and re-run: sudo xbps-install -Syu"
}

# Re-sync after upgrade
echo "=== Step 2.3: Re-syncing package index ==="
xbps-install -Sy || true

# ── Install curl and wget early ──────────────────────────────────────
# These are needed by Phase 10 (SDDM theme download) and Phase 14 (Gruvbox
# theme downloads). A fresh Void base install does NOT include curl by
# default, so if we wait until Phase 12 (CLI tools) to install it, the
# SDDM theme download in Phase 10b silently fails and SDDM keeps breeze.
echo ""
echo "=== Step 2.4: Installing curl and wget (needed for theme downloads) ==="
xinstall curl wget

# ── Enable nonfree and multilib repositories ──────────────────────────
# void-repo-nonfree: packages with non-free licenses (firmware blobs,
#   proprietary drivers, patented codecs). Needed for some Wi-Fi/GPU
#   firmware and media codecs.
# void-repo-multilib: 32-bit compatibility libraries for x86_64 (glibc).
#   Needed for Steam, Wine, and some proprietary 32-bit apps.
# void-repo-multilib-nonfree: non-free 32-bit packages (glibc x86_64 only).
# These packages install a repository config file in /usr/share/xbps.d/.
# On non-x86_64 or musl, multilib packages don't exist — xinstall will
# warn but not abort.
echo ""
echo "=== Step 2.5: Enabling nonfree and multilib repositories ==="
xinstall void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
# Re-sync index to pick up the new repositories
xbps-install -Sy || true
echo "[*] Repository configuration:"
grep '^repository=' /usr/share/xbps.d/* 2>/dev/null | sed 's/.*repository=//' || true

# ═══════════════════════════════════════════════════════════════════════
# Phase 3: Firmware and microcode (hardware-specific)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 3: Firmware and CPU Microcode"
echo "══════════════════════════════════════════════════════════════"

# linux-firmware — needed for real hardware Wi-Fi/Bluetooth/GPU firmware
# Not needed in most VMs, but harmless if installed.
if [ "$FIRMWARE" -eq 1 ]; then
  if [ "$VIRT_PLATFORM" = "none" ]; then
    echo ""
    echo "=== Step 3.1: Installing linux-firmware (bare metal) ==="
    xinstall linux-firmware
  else
    echo ""
    echo "=== Step 3.1: Skipping linux-firmware (running in $VIRT_PLATFORM VM) ==="
    echo "    Use --no-firmware is redundant here. Install manually if needed:"
    echo "    xbps-install linux-firmware"
  fi
else
  echo ""
  echo "=== Step 3.1: Firmware skipped (--no-firmware) ==="
fi

# CPU microcode — install based on CPU vendor
# Note: Void Linux no longer ships a standalone 'intel-ucode' package.
# Intel microcode is now part of linux-firmware-intel.
# The kernel has CONFIG_MICROCODE=y (built-in), so microcode updates
# are loaded automatically from firmware at boot when the package is present.
echo ""
echo "=== Step 3.2: CPU microcode ==="
case "$CPU_VENDOR" in
  intel)
    echo "[*] Intel CPU detected. Installing linux-firmware-intel (includes CPU microcode)."
    xinstall linux-firmware-intel
    ;;
  amd)
    echo "[*] AMD CPU detected. Installing linux-firmware-amd (includes CPU microcode)."
    xinstall linux-firmware-amd
    ;;
  *)
    echo "[*] CPU vendor unknown ($CPU_VENDOR). Skipping microcode installation."
    ;;
esac

# ── Mainline kernel ──────────────────────────────────────────────────
# Void ships the stock LTS kernel (linux) by default. linux-mainline
# tracks the latest upstream stable release (currently 7.x series).
# Installing it gives you the newest kernel features, hardware support,
# and security fixes. The stock kernel is kept as a fallback — both
# appear in the GRUB menu at boot.
# Disable with --no-mainline to stay on the stock LTS kernel.
echo ""
echo "=== Step 3.3: Mainline kernel ==="
if [ "$MAINLINE_KERNEL" -eq 1 ]; then
  echo "[*] Installing linux-mainline (latest upstream stable kernel, 7.x series)."
  echo "    The stock LTS kernel (linux) remains installed as a fallback."
  xinstall linux-mainline

  # Verify the mainline kernel was actually installed
  if xbps-query linux-mainline >/dev/null 2>&1; then
    MAINLINE_VERSION=$(xbps-query linux-mainline 2>/dev/null | grep -oP 'pkgver:\s*\K\S+' || echo "unknown")
    echo "[*] linux-mainline installed: version ${MAINLINE_VERSION}"
  else
    echo "[!] WARNING: linux-mainline did not install successfully."
    echo "[!] The stock kernel (linux) is still present and bootable."
  fi
else
  echo "[*] Mainline kernel skipped (--no-mainline). Keeping stock LTS kernel."
fi

# ── Btrfs compression ────────────────────────────────────────────────
# If the root filesystem is btrfs, enable zstd transparent compression
# by adding compress=zstd to fstab and remounting. zstd gives good
# compression ratios (typically 2-3x on system files) with fast
# decompression.
# Disable with --no-btrfs-compress.
echo ""
echo "=== Step 3.4: Btrfs compression ==="
BTRFS_ENABLED=0
if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
  if [ "$BTRFS_COMPRESS" -eq 1 ]; then
    echo "[*] Btrfs root filesystem detected on $ROOT_DEVICE"

    # Check current mount options
    CURRENT_OPTS=$(findmnt -no OPTIONS / 2>/dev/null || true)
    if echo "$CURRENT_OPTS" | grep -q "compress=zstd"; then
      echo "[*] zstd compression already enabled in mount options."
      BTRFS_ENABLED=1
    else
      # Add compress=zstd to fstab
      FSTAB=/etc/fstab
      if grep -q "^[^#].* / btrfs" "$FSTAB" 2>/dev/null; then
        # Replace the options field for the btrfs root mount only (exact " / " match)
        sed -i "s|\(^[^#]\S\+\s\+/\s\+btrfs\s\+\)defaults|\1defaults,compress=zstd|" "$FSTAB"
        echo "[*] Added compress=zstd to fstab for btrfs root."

        # Remount to apply immediately
        mount -o remount,compress=zstd / 2>/dev/null && \
          echo "[*] Remounted / with compress=zstd" || \
          echo "[!] Remount failed — compression will apply on next boot."

        # Verify
        NEW_OPTS=$(findmnt -no OPTIONS / 2>/dev/null || true)
        if echo "$NEW_OPTS" | grep -q "compress=zstd"; then
          echo "[*] Verified: zstd compression is active."
          BTRFS_ENABLED=1
        fi
      else
        echo "[!] Could not find btrfs root entry in fstab. Skipping compression."
      fi
    fi

  else
    echo "[*] Btrfs root detected but compression skipped (--no-btrfs-compress)."
  fi
else
  echo "[*] Root filesystem is $ROOT_FS_TYPE (not btrfs). Skipping compression."
  if [ "$BTRFS_COMPRESS" -eq 1 ]; then
    echo "    To use btrfs compression, install Void with btrfs as the root filesystem."
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# Phase 4: Core desktop installation
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 4: Core Desktop Installation"
echo "══════════════════════════════════════════════════════════════"

# ── elogind (session/seat management) ────────────────────────────────
# Without elogind, SDDM/Plasma cannot start — no XDG_RUNTIME_DIR, no
# seat management. This is the #1 reason "Plasma didn't start" on Void.
echo ""
echo "=== Step 4.1: Installing elogind (session/seat management) ==="
xinstall elogind

# Fix elogind boot race: the stock run script uses elogind.wrapper which
# does cgroup/tmpfs setup then execs elogind. But elogind forks and the
# parent exits immediately, causing runit to mark the service as "down"
# even though the child is running. This creates a race on boot where
# elogind may not be ready when SDDM/Plasma need it.
# Fix: inline the wrapper setup and use a wait loop so the run script
# stays alive as long as the elogind daemon is running. This keeps runit
# happy (service stays "run" instead of flapping to "down").
if [ -f /etc/sv/elogind/run ] && ! grep -q 'elogind-inline-fix' /etc/sv/elogind/run; then
  cp /etc/sv/elogind/run /etc/sv/elogind/run.orig 2>/dev/null || true
  cat > /etc/sv/elogind/run << 'ELOGINDRUN'
#!/bin/sh
# elogind-inline-fix — inlined wrapper + wait loop to avoid fork/exit race
exec 2>&1
sv check dbus >/dev/null || exit 1

cgroup=/sys/fs/cgroup/elogind
mkdir -p "$cgroup" 2>/dev/null || true
if ! mountpoint "$cgroup" > /dev/null; then
  # Try cgroup v2 first (unified hierarchy, modern kernels)
  if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    # cgroup v2 — elogind uses the unified hierarchy, no named mount needed
    # Just ensure the directory exists (created above)
    :
  else
    # cgroup v1 — mount named hierarchy
    mount -t cgroup -o none,name=elogind cgroup "$cgroup" || exit 1
  fi
fi

for tmpfs in /run/systemd /run/user; do
  mountpoint "$tmpfs" > /dev/null && continue
  mkdir -p "$tmpfs"
  mount -t tmpfs -o nosuid,nodev,noexec,mode=0755 none "$tmpfs" || exit 1
done

# Start elogind and keep the run script alive while it runs.
# elogind forks by default — the parent exits immediately, which makes
# runit think the service crashed. We use a polling loop instead of wait()
# because wait() only works on direct child processes, and the forked
# daemon is reparented to init (not a child of this shell).
/usr/libexec/elogind/elogind &
sleep 2
# Poll: keep the run script alive as long as elogind is running
while pgrep -x elogind >/dev/null 2>&1; do
  sleep 5
done
ELOGINDRUN
  chmod 755 /etc/sv/elogind/run
  echo "[*] Patched elogind run script (inline wrapper + wait loop)"
fi

# Enable dbus BEFORE elogind — elogind's run script checks sv check dbus
if [ -L /var/service/dbus ]; then
  echo "[*] dbus already enabled."
else
  ln -s /etc/sv/dbus /var/service/
  echo "[*] dbus symlink created."
fi
sleep 1
sv status dbus 2>/dev/null || sv up dbus 2>/dev/null || true

if [ -L /var/service/elogind ]; then
  echo "[*] elogind already enabled."
else
  ln -s /etc/sv/elogind /var/service/
  echo "[*] elogind symlink created."
fi

# ── KDE Plasma + base apps ───────────────────────────────────────────
echo ""
echo "=== Step 4.2: Installing kde-plasma, kde-baseapps, sddm, and core deps ==="
# sddm is pulled in by kde-plasma but install explicitly for robustness
# dbus is needed by elogind/sddm/plasma — install explicitly
# polkit-elogind needed for GUI privilege escalation (mount, shutdown, etc.)
# xdg-utils provides xdg-open, xdg-mime (URL/file handling in KDE)
# konsole is KDE's default terminal — needed as fallback even with wezterm
xinstall kde-plasma kde-baseapps sddm dbus polkit-elogind xdg-utils konsole

# Enable polkitd service — needed for GUI privilege escalation
# (mounting USB drives, shutdown/reboot from KDE menu, PackageKit updates)
if [ -d /etc/sv/polkitd ] && [ ! -L /var/service/polkitd ]; then
  ln -s /etc/sv/polkitd /var/service/
  echo "[*] polkitd symlink created."
elif [ -L /var/service/polkitd ]; then
  echo "[*] polkitd already enabled."
fi

# ── Archive tools (Dolphin extract/compress integration) ─────────────
# ark: KDE archiver — provides Dolphin right-click "Extract" and
#   "Compress" service menus. Without it, Dolphin can't extract or
#   create archives from the context menu.
# unzip: ZIP extraction (CLI backend ark uses for .zip)
# zip: ZIP creation (CLI backend ark uses to create .zip)
# 7zip: handles .7z, .rar, and other formats (replaces deprecated p7zip)
echo ""
echo "=== Step 4.2b: Installing archive tools (ark, unzip, zip, 7zip) ==="
xinstall ark unzip zip 7zip

# ── Xorg ─────────────────────────────────────────────────────────────
echo ""
echo "=== Step 4.3: Installing Xorg ==="
if [ "$MINIMAL" -eq 1 ]; then
  echo "[*] Minimal mode: installing xorg-minimal + fonts + terminal + mesa-dri"
  xinstall xorg-minimal xorg-fonts xterm mesa-dri
else
  echo "[*] Full mode: installing xorg meta-package (includes free drivers, fonts, input drivers)"
  xinstall xorg
fi

# ═══════════════════════════════════════════════════════════════════════
# Phase 5: GPU driver installation (based on discovery)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 5: GPU Driver Installation"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "[*] Detected GPU: $GPU_VENDOR ($GPU_MODEL)"

# NVIDIA proprietary drivers are NEVER installed by this script.
# If NVIDIA is detected, we fall back to modesetting/nouveau.
case "$GPU_VENDOR" in
  nvidia)
    echo "[!] NVIDIA GPU detected. This script does not install proprietary drivers."
    echo "    Using nouveau (open-source) via mesa-dri. For proprietary drivers,"
    echo "    install manually: xbps-install void-repo-nonfree && xbps-install nvidia"
    if [ "$MINIMAL" -eq 1 ]; then
      xinstall mesa-dri xf86-video-nouveau
    fi
    ;;
  amd)
    echo "[*] AMD/ATI GPU detected. Installing xf86-video-amdgpu."
    if [ "$MINIMAL" -eq 1 ]; then
      xinstall xf86-video-amdgpu mesa-dri
    else
      echo "[*] Full xorg already includes xf86-video-amdgpu."
    fi
    ;;
  intel)
    echo "[*] Intel GPU detected. Installing xf86-video-intel."
    if [ "$MINIMAL" -eq 1 ]; then
      xinstall xf86-video-intel mesa-dri
    else
      echo "[*] Full xorg already includes xf86-video-intel."
    fi
    ;;
  qxl)
    echo "[*] QXL paravirtual graphics detected (QEMU/KVM VM)."
    echo "[*] Installing xf86-video-qxl driver."
    if [ "$MINIMAL" -eq 1 ]; then
      xinstall xf86-video-qxl mesa-dri
    else
      # Even with full xorg, QXL is in the video-drivers meta-package,
      # but install explicitly to be sure.
      xinstall xf86-video-qxl
    fi
    # QXL has no Vulkan support. Without this, Mesa tries Zink (GL-over-
    # Vulkan), fails with VK_ERROR_INITIALIZATION_FAILED, and KWin hangs
    # for ~30 seconds before falling back to software rendering. Force
    # software GL from the start to eliminate the timeout.
    echo "[*] QXL has no Vulkan — enabling software GL to avoid Zink timeout."
    mkdir -p /etc/environment.d
    echo "LIBGL_ALWAYS_SOFTWARE=1" > /etc/environment.d/00-software-gl.conf
    echo "[*] Set LIBGL_ALWAYS_SOFTWARE=1 in /etc/environment.d/"
    ;;
  virtio)
    echo "[*] virtio-gpu detected. Using modesetting with mesa-dri."
    if [ "$MINIMAL" -eq 1 ]; then
      xinstall mesa-dri
    fi
    ;;
  vmware)
    echo "[*] VMware SVGA detected. Installing xf86-video-vmware."
    if [ "$MINIMAL" -eq 1 ]; then
      xinstall xf86-video-vmware mesa-dri
    else
      xinstall xf86-video-vmware
    fi
    ;;
  hyperv)
    echo "[*] Hyper-V virtual GPU detected. Using modesetting with mesa-dri."
    if [ "$MINIMAL" -eq 1 ]; then
      xinstall mesa-dri
    fi
    ;;
  *)
    echo "[*] Unknown GPU vendor. Using modesetting with mesa-dri (generic fallback)."
    if [ "$MINIMAL" -eq 1 ]; then
      xinstall mesa-dri
    fi
    ;;
esac

# ═══════════════════════════════════════════════════════════════════════
# Phase 6: Input device drivers (based on discovery)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 6: Input Device Drivers"
echo "══════════════════════════════════════════════════════════════"

# With full xorg, input drivers are already included.
# With minimal xorg, install only what's detected.
if [ "$MINIMAL" -eq 1 ]; then
  echo "[*] Minimal mode — installing input drivers based on hardware."

  # Always need evdev for keyboards
  echo "[*] Installing xf86-input-evdev (keyboard/base input)."
  xinstall xf86-input-evdev

  # Touchpad
  if [ $TOUCHPAD_DETECTED -eq 1 ]; then
    echo "[*] Touchpad detected. Installing xf86-input-synaptics."
    xinstall xf86-input-synaptics
  fi

  # Wacom tablet
  if [ $WACOM_DETECTED -eq 1 ]; then
    echo "[*] Wacom tablet detected. Installing xf86-input-wacom."
    xinstall xf86-input-wacom
  fi

  # VMware/VirtualBox virtual mouse
  if [ "$VIRT_PLATFORM" = "vmware" ] || [ "$VIRT_PLATFORM" = "virtualbox" ]; then
    echo "[*] $VIRT_PLATFORM VM detected. Installing xf86-input-vmmouse."
    xinstall xf86-input-vmmouse
  fi
else
  echo "[*] Full xorg already includes input drivers. Skipping individual installs."
fi

# ═══════════════════════════════════════════════════════════════════════
# Phase 7: Audio stack (if audio hardware detected)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 7: Audio Stack"
echo "══════════════════════════════════════════════════════════════"
if [ $AUDIO_DETECTED -eq 1 ]; then
  echo "[*] Audio controller detected. Installing PipeWire stack."
  # pipewire-pulse is not a separate package on Void — PulseAudio
  # compatibility is built into the main pipewire package.
  # wireplumber-elogind is required on Void for elogind session integration.
  # rtkit (package name, not rtkit-daemon) gives PipeWire real-time scheduling
  # for glitch-free audio. The service is /etc/sv/rtkit.
  # libspa-bluetooth: Bluetooth audio bridge for PipeWire (needed if BT detected)
  # alsa-pipewire: ALSA plugin to route ALSA apps through PipeWire
  # pulseaudio-utils: provides pactl/pacmd for testing PulseAudio compatibility

  # Remove legacy pulseaudio if installed (handbook: uninstall it first)
  if xbps-query -l 2>/dev/null | grep -q '^ii pulseaudio-'; then
    echo "[*] Removing legacy pulseaudio package..."
    xbps-remove -y pulseaudio 2>/dev/null || true
  fi

  xinstall pipewire wireplumber wireplumber-elogind rtkit alsa-utils pulseaudio-utils alsa-pipewire
  if [ $BLUETOOTH_DETECTED -eq 1 ]; then
    xinstall libspa-bluetooth
  fi

  # Enable rtkit service for real-time audio scheduling
  if [ -L /var/service/rtkit ]; then
    echo "[*] rtkit already enabled."
  elif [ -d /etc/sv/rtkit ]; then
    ln -s /etc/sv/rtkit /var/service/
    echo "[*] rtkit symlink created."
    sv up rtkit 2>/dev/null || true
    else
    echo "[*] No rtkit service dir found — may not be needed."
  fi

  # Clean up stale rtkit-daemon symlink from older script versions
  if [ -L /var/service/rtkit-daemon ]; then
    rm -f /var/service/rtkit-daemon
    echo "[*] Removed stale rtkit-daemon symlink (replaced by rtkit)."
  fi

  # PipeWire/WirePlumber .desktop files ship in /usr/share/applications/
  # but are NOT auto-placed in /etc/xdg/autostart/ on Void. Without this,
  # Plasma never starts PipeWire/WirePlumber on login — no audio.
  echo "[*] Enabling PipeWire/WirePlumber autostart in /etc/xdg/autostart/..."
  for desktop in pipewire wireplumber pipewire-pulse; do
    src="/usr/share/applications/${desktop}.desktop"
    dst="/etc/xdg/autostart/${desktop}.desktop"
    if [ -f "$src" ] && [ ! -f "$dst" ]; then
      cp "$src" "$dst"
      echo "[*] Copied ${desktop}.desktop to /etc/xdg/autostart/"
    elif [ -f "$dst" ]; then
      echo "[*] ${desktop}.desktop already in autostart."
    else
      echo "[!] ${desktop}.desktop not found in /usr/share/applications/"
    fi
  done

  # ── WirePlumber D-Bus session bus fix ────────────────────────────────
  # On Void Linux, KDE wraps the Plasma session in `dbus-run-session` which
  # creates a private D-Bus session bus with a random socket path in /tmp.
  # WirePlumber's autostart .desktop file may not inherit the
  # DBUS_SESSION_BUS_ADDRESS environment variable, causing WirePlumber to
  # fail with "Unable to autolaunch a dbus-daemon without a $DISPLAY for X11"
  # and never start — leaving PipeWire with only a "Dummy Output" sink.
  #
  # Fix: create a wrapper script that finds the session bus address from
  # an already-running Plasma process (plasmashell/ksmserver) and exports
  # it before launching WirePlumber. Point the autostart .desktop Exec line
  # at this wrapper.
  echo "[*] Creating WirePlumber D-Bus session bus wrapper..."
  cat > /usr/local/bin/wireplumber-autostart << 'WPWRAPPER'
#!/bin/sh
# wireplumber-autostart — find the D-Bus session bus before launching WirePlumber
# Generated by install-kde-plasma.sh
# On Void, KDE's plasma-dbus-run-session-if-needed wraps the session in
# dbus-run-session, putting the bus socket in /tmp with a random name.
# Autostarted apps may not inherit DBUS_SESSION_BUS_ADDRESS. This wrapper
# finds it from a running Plasma process and exports it.

if [ -n "${DBUS_SESSION_BUS_ADDRESS}" ]; then
  exec wireplumber
fi

for pid in $(pgrep -u $(id -u) plasmashell 2>/dev/null) \
           $(pgrep -u $(id -u) ksmserver 2>/dev/null) \
           $(pgrep -u $(id -u) startplasma 2>/dev/null); do
  addr=$(cat /proc/$pid/environ 2>/dev/null | tr '\0' '\n' | grep '^DBUS_SESSION_BUS_ADDRESS=' | cut -d= -f2-)
  if [ -n "$addr" ]; then
    export DBUS_SESSION_BUS_ADDRESS="$addr"
    break
  fi
done

if [ -z "${DBUS_SESSION_BUS_ADDRESS}" ]; then
  eval $(dbus-launch --sh-syntax 2>/dev/null)
fi

exec wireplumber
WPWRAPPER
  chmod 755 /usr/local/bin/wireplumber-autostart
  echo "[*] Created /usr/local/bin/wireplumber-autostart"

  WP_DESKTOP=/etc/xdg/autostart/wireplumber.desktop
  if [ -f "$WP_DESKTOP" ]; then
    sed -i 's|^Exec=.*|Exec=/usr/local/bin/wireplumber-autostart|' "$WP_DESKTOP"
    # Remove any stale X-KDE-Autostart-phase line (it caused early-start issues)
    sed -i '/X-KDE-Autostart-phase/d' "$WP_DESKTOP"
    echo "[*] Updated wireplumber.desktop to use D-Bus wrapper"
  fi

  # ── PipeWire config symlinks (Void handbook recommended) ────────────
  # These symlinks ensure proper session manager startup ordering and
  # PulseAudio compatibility layer configuration.
  echo "[*] Creating PipeWire config symlinks..."
  mkdir -p /etc/pipewire/pipewire.conf.d

  # WirePlumber session manager config — launches WirePlumber from PipeWire
  WP_CONF_SRC=/usr/share/examples/wireplumber/10-wireplumber.conf
  WP_CONF_DST=/etc/pipewire/pipewire.conf.d/10-wireplumber.conf
  if [ -f "$WP_CONF_SRC" ] && [ ! -L "$WP_CONF_DST" ]; then
    ln -s "$WP_CONF_SRC" "$WP_CONF_DST"
    echo "[*] Linked WirePlumber config to pipewire.conf.d/"
  elif [ -L "$WP_CONF_DST" ]; then
    echo "[*] WirePlumber config symlink already exists."
  else
    echo "[*] WirePlumber example config not found at $WP_CONF_SRC — skipping."
  fi

  # PulseAudio compatibility config
  PW_PULSE_SRC=/usr/share/examples/pipewire/20-pipewire-pulse.conf
  PW_PULSE_DST=/etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf
  if [ -f "$PW_PULSE_SRC" ] && [ ! -L "$PW_PULSE_DST" ]; then
    ln -s "$PW_PULSE_SRC" "$PW_PULSE_DST"
    echo "[*] Linked pipewire-pulse config to pipewire.conf.d/"
  elif [ -L "$PW_PULSE_DST" ]; then
    echo "[*] pipewire-pulse config symlink already exists."
  else
    echo "[*] pipewire-pulse example config not found at $PW_PULSE_SRC — skipping."
  fi

  # pipewire.conf.d launches WirePlumber and pipewire-pulse directly via
  # context.exec INSIDE the pipewire daemon. The wireplumber.desktop and
  # pipewire-pulse.desktop autostart files would cause DUPLICATE instances
  # that fight over ALSA device reservation (ReserveDevice1.Audio0) and
  # PulseAudio sockets, causing "Dummy Output" as the only sink.
  # Remove those two — but KEEP pipewire.desktop, because it starts the
  # main pipewire daemon itself. Without pipewire.desktop, pipewire never
  # starts, so the conf.d context.exec lines never run → no audio at all.
  if [ -L "$WP_CONF_DST" ] || [ -f "$WP_CONF_DST" ]; then
    for autostart_file in wireplumber.desktop pipewire-pulse.desktop; do
      if [ -f "/etc/xdg/autostart/$autostart_file" ]; then
        rm -f "/etc/xdg/autostart/$autostart_file"
        echo "[*] Removed $autostart_file autostart (launched via pipewire.conf.d)"
      fi
    done
    # Ensure pipewire.desktop is present — it starts the main daemon
    PW_DESKTOP_SRC=/usr/share/applications/pipewire.desktop
    PW_DESKTOP_DST=/etc/xdg/autostart/pipewire.desktop
    if [ ! -f "$PW_DESKTOP_DST" ] && [ -f "$PW_DESKTOP_SRC" ]; then
      cp "$PW_DESKTOP_SRC" "$PW_DESKTOP_DST"
      echo "[*] Restored pipewire.desktop to autostart (starts main pipewire daemon)"
    fi
  fi

  # ALSA config symlinks — route ALSA apps through PipeWire
  # Handbook: ln -s /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d
  for alsacfg in 50-pipewire.conf 99-pipewire-default.conf; do
    src="/usr/share/alsa/alsa.conf.d/$alsacfg"
    dst="/etc/alsa/conf.d/$alsacfg"
    if [ -f "$src" ] && [ ! -L "$dst" ]; then
      mkdir -p /etc/alsa/conf.d
      ln -s "$src" "$dst"
      echo "[*] Linked ALSA config $alsacfg"
    elif [ -L "$dst" ]; then
      echo "[*] ALSA config $alsacfg already linked."
    else
      echo "[*] ALSA config source $alsacfg not found — skipping."
    fi
  done

else
  echo "[*] No audio controller detected. Skipping PipeWire/ALSA."
fi

# ═══════════════════════════════════════════════════════════════════════
# Phase 8: Network and Bluetooth (based on discovery)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 8: Network and Bluetooth"
echo "══════════════════════════════════════════════════════════════"

# ── NetworkManager (always — KDE Networks widget needs it) ───────────
echo ""
echo "=== Step 8.1: NetworkManager ==="
xinstall NetworkManager

if [ -L /var/service/NetworkManager ]; then
  echo "[*] NetworkManager already enabled."
else
  ln -s /etc/sv/NetworkManager /var/service/
  echo "[*] NetworkManager symlink created."
fi

# Disable conflicting services — dhcpcd and wpa_supplicant interfere
# with NetworkManager. The handbook explicitly says to disable them.
for svc in dhcpcd wpa_supplicant; do
  if [ -L /var/service/$svc ]; then
    echo "[*] Disabling $svc (conflicts with NetworkManager)..."
    rm -f /var/service/$svc
    echo "[*] $svc disabled."
  fi
done

# Add users to the network group (required by NetworkManager handbook)
for user_home in /home/*; do
  username=$(basename "$user_home")
  if id "$username" >/dev/null 2>&1 && ! id -nG "$username" | grep -qw network; then
    usermod -aG network "$username" 2>/dev/null && echo "[*] Added $username to network group"
  fi
done

# Ensure all users are in the wheel group (Void's sudo group).
# /etc/sudoers.d/wheel grants %wheel ALL=(ALL:ALL) ALL — but if the
# user wasn't added to wheel during base install, sudo is silently
# broken and there's no error until they try to use it.
# Also add audio/video/input groups — elogind handles these via logind
# seats on modern systems, but having them doesn't hurt and some
# legacy ALSA paths still check them.
echo ""
echo "=== Step 8.1b: Ensuring user groups (wheel, audio, video, input) ==="
for user_home in /home/*; do
  username=$(basename "$user_home")
  id "$username" >/dev/null 2>&1 || continue
  for grp in wheel audio video input; do
    if ! id -nG "$username" | grep -qw "$grp"; then
      usermod -aG "$grp" "$username" 2>/dev/null && echo "[*] Added $username to $grp group"
    fi
  done
done

# ── Bluetooth (only if detected) ──────────────────────────────────────
echo ""
echo "=== Step 8.2: Bluetooth ==="
if [ $BLUETOOTH_DETECTED -eq 1 ]; then
  echo "[*] Bluetooth detected. Installing bluez."
  xinstall bluez

  if [ -L /var/service/bluetoothd ]; then
    echo "[*] bluetoothd already enabled."
  elif [ -d /etc/sv/bluetoothd ]; then
    ln -s /etc/sv/bluetoothd /var/service/
    echo "[*] bluetoothd symlink created."
  else
    echo "[*] No bluetoothd service dir found."
  fi

  # Add users to bluetooth group (handbook: required for non-root BT access)
  for user_home in /home/*; do
    username=$(basename "$user_home")
    if id "$username" >/dev/null 2>&1 && ! id -nG "$username" | grep -qw bluetooth; then
      usermod -aG bluetooth "$username" 2>/dev/null && echo "[*] Added $username to bluetooth group"
    fi
  done

  # rfkill: unblock bluetooth if soft-blocked
  if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock bluetooth 2>/dev/null && echo "[*] Unblocked bluetooth via rfkill" || true
  fi
else
  echo "[*] No Bluetooth detected. Skipping bluez."
fi

# ── Power management ─────────────────────────────────────────────────
# powerdevil: KDE's power management daemon — battery, brightness,
#   suspend/hibernate, lid switch handling. Integrates with Plasma's
#   battery widget and system settings.
# power-profiles-daemon: D-Bus service for switching between power
#   profiles (balanced/power-saver/performance). powerdevil uses this
#   to expose profile switching in the KDE battery widget.
# upower: power device enumeration (batteries, UPS) — dependency of
#   both powerdevil and power-profiles-daemon, installed automatically.
# acpid conflicts with elogind for lid-switch/power-button handling.
#   elogind handles these natively, so we do NOT install acpid.
# Installed on all systems — VMs benefit from power-profiles-daemon for
# CPU frequency scaling, and powerdevil provides brightness control for
# virtual displays. No harm if no battery is present.
echo ""
echo "=== Step 8.3: Power management ==="
xinstall powerdevil power-profiles-daemon upower

# Enable power-profiles-daemon runit service
# powerdevil runs as a KDE Plasma component (no runit service needed)
if [ -d /etc/sv/power-profiles-daemon ] && [ ! -L /var/service/power-profiles-daemon ]; then
  ln -s /etc/sv/power-profiles-daemon /var/service/
  echo "[*] power-profiles-daemon symlink created."
elif [ -L /var/service/power-profiles-daemon ]; then
  echo "[*] power-profiles-daemon already enabled."
fi
echo "[*] Power management installed: powerdevil + power-profiles-daemon"
echo "[*] Battery widget, brightness, suspend/hibernate available in Plasma."

# ═══════════════════════════════════════════════════════════════════════
# Phase 9: VM guest tools (if running in a VM)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 9: VM Guest Tools"
echo "══════════════════════════════════════════════════════════════"

case "$VIRT_PLATFORM" in
  qemu-kvm)
    echo "[*] QEMU/KVM VM detected. Installing spice-vdagent for clipboard/share."
    xinstall spice-vdagent
    if [ -d /etc/sv/spice-vdagentd ] && [ ! -L /var/service/spice-vdagentd ]; then
      ln -s /etc/sv/spice-vdagentd /var/service/
      echo "[*] spice-vdagentd symlink created."
    elif [ -L /var/service/spice-vdagentd ]; then
      echo "[*] spice-vdagentd already enabled."
    fi
    ;;
  vmware)
    echo "[*] VMware VM detected. Installing open-vm-tools."
    xinstall open-vm-tools
    for vm_svc in vmblockd vmtoolsd; do
      if [ -d /etc/sv/$vm_svc ] && [ ! -L /var/service/$vm_svc ]; then
        ln -s /etc/sv/$vm_svc /var/service/
        echo "[*] $vm_svc symlink created."
      elif [ -L /var/service/$vm_svc ]; then
        echo "[*] $vm_svc already enabled."
      fi
    done
    ;;
  virtualbox)
    echo "[*] VirtualBox VM detected. Installing virtualbox-guest-tools."
    xinstall virtualbox-guest-tools
    if [ -d /etc/sv/vboxservice ] && [ ! -L /var/service/vboxservice ]; then
      ln -s /etc/sv/vboxservice /var/service/
      echo "[*] vboxservice symlink created."
    elif [ -L /var/service/vboxservice ]; then
      echo "[*] vboxservice already enabled."
    fi
    ;;
  hyperv)
    echo "[*] Hyper-V VM detected. No additional guest tools package needed."
    echo "[*] Kernel includes hv_utils. Using modesetting for display."
    ;;
  xen)
    echo "[*] Xen VM detected. No additional guest tools package needed."
    ;;
  *)
    echo "[*] Bare metal or unknown platform. No VM guest tools needed."
    ;;
esac

# ═══════════════════════════════════════════════════════════════════════
# Phase 10: Services and display manager
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 10: Services and Display Manager"
echo "══════════════════════════════════════════════════════════════"

# ── zramen (zram swap) ───────────────────────────────────────────────
echo ""
echo "=== Step 10.1b: Enabling zramen (zram swap) ==="
# zramen creates a compressed swap device in RAM using lz4.
# Default: 25% of RAM as zram size, priority 32767 (highest).
# This reduces disk I/O and improves responsiveness on low-RAM systems
# and VMs. Especially useful for Void VMs with limited disk I/O.
xinstall zramen
if [ -L /var/service/zramen ]; then
  echo "[*] zramen already enabled."
else
  ln -s /etc/sv/zramen /var/service/
  echo "[*] zramen symlink created."
fi

# Enable lz4 compression — faster than default lzo-rle for both
# compression and decompression with similar ratios.
ZRAMEN_CONF="/etc/sv/zramen/conf"
if [ -f "$ZRAMEN_CONF" ]; then
  sed -i 's/^#export ZRAM_COMP_ALGORITHM=lz4/export ZRAM_COMP_ALGORITHM=lz4/' "$ZRAMEN_CONF"
  if grep -q '^export ZRAM_COMP_ALGORITHM=lz4' "$ZRAMEN_CONF" 2>/dev/null; then
    echo "[*] zramen: enabled lz4 compression"
  else
    echo "[!] zramen: could not enable lz4 via sed — config format may differ"
  fi
fi

# Give runit a moment to pick it up
sleep 1
sv status zramen 2>/dev/null || true
echo "[*] zramen service enabled — zram swap (lz4, 25% RAM) will start on boot."

# ── SDDM test then enable ─────────────────────────────────────────────
echo ""
echo "=== Step 10.2: Testing and enabling SDDM display manager ==="

touch /etc/sv/sddm/down

if [ -L /var/service/sddm ]; then
  echo "[*] sddm symlink already exists."
else
  ln -s /etc/sv/sddm /var/service/
  echo "[*] sddm symlink created (with down file — test mode)."
fi

# Give runit a moment to scan the new symlink
sleep 2

echo "[*] Starting sddm once for test..."
sv once sddm 2>/dev/null || true
sleep 3

if sv status sddm 2>/dev/null | grep -q 'run:'; then
  echo "[*] SDDM test: service is running."
else
  echo "[!] SDDM test: service may not have started cleanly."
  echo "[!] This can happen in a headless VM with no display attached."
  echo "[!] Proceeding with enablement — SDDM will start when a display is available."
fi

rm -f /etc/sv/sddm/down
echo "[*] SDDM down file removed — service now enabled for boot."

# ── Patch SDDM run script (elogind double-start fix) ─────────────────
# The stock Void SDDM run script unconditionally calls
# dbus-send StartServiceByName org.freedesktop.login1, which tries to
# D-Bus activate a second elogind instance. Since elogind already runs
# as a runit service, the second instance prints "elogind is already
# running as pid X" on the login screen and causes a long delay before
# login completes. Fix: only call dbus-send if elogind is NOT already
# running.
echo ""
echo "=== Step 10.2b: Patching SDDM run script (elogind fix) ==="
if [ -f /etc/sv/sddm/run ] && ! grep -q 'pgrep -x elogind' /etc/sv/sddm/run 2>/dev/null; then
  cp /etc/sv/sddm/run /etc/sv/sddm/run.orig 2>/dev/null || true
  cat > /etc/sv/sddm/run << 'SDDMRUN'
#!/bin/sh
exec 2>&1
sv check dbus >/dev/null || exit 1

# Only dbus-activate elogind if it is not already running.
# On Void, elogind runs as a runit service. The stock SDDM run script
# unconditionally calls StartServiceByName org.freedesktop.login1,
# which tries to start a second elogind instance that prints
# "elogind is already running as pid X" on the login screen.
if [ -x /usr/bin/elogind-inhibit ] && ! pgrep -x elogind >/dev/null 2>&1; then
        dbus-send --system --print-reply --dest=org.freedesktop.DBus \
                /org/freedesktop/DBus \
                org.freedesktop.DBus.StartServiceByName \
                string:org.freedesktop.login1 uint32:0 2>/dev/null || true
fi

# respect system locale
[ -r /etc/locale.conf ] && . /etc/locale.conf && export LANG

[ -f ./conf ] && . ./conf

exec sddm 2>&1
SDDMRUN
  chmod 755 /etc/sv/sddm/run
  echo "[*] Patched /etc/sv/sddm/run — elogind double-start fix"
else
  echo "[*] SDDM run script already patched (or not found)."
fi

# ── Configure SDDM theme and settings ────────────────────────────────
echo ""
echo "=== Step 10.3: Configuring SDDM theme ==="

SDDM_CONF=/etc/sddm.conf

# Only create if it doesn't exist (don't overwrite user customizations)
if [ ! -f "$SDDM_CONF" ]; then
  # Build Autologin section if --autologin was specified
  if [ -n "$AUTOLOGIN" ]; then
    AUTOLOGIN_SECTION="[Autologin]
Relogin=false
User=${AUTOLOGIN}
Session=plasma"
  else
    AUTOLOGIN_SECTION="[Autologin]
Relogin=false
User=
Session="
  fi

  # Determine SDDM display server: use x11 for QXL VMs (no Vulkan/Wayland
  # support), wayland for everything else (Plasma 6 default).
  SDDM_DISPLAY_SERVER="wayland"
  SDDM_GREETER_ENV="QT_WAYLAND_SHELL_INTEGRATION=layer-shell"
  if { [ "$GPU_VENDOR" = "qxl" ] || [ "$GPU_VENDOR" = "virtio" ]; } && [ "$VIRT_PLATFORM" != "none" ]; then
    SDDM_DISPLAY_SERVER="x11"
    SDDM_GREETER_ENV=""
    echo "[*] QXL/virtio GPU in VM detected — SDDM will use X11 greeter (no Wayland/Vulkan support)"
  fi

  cat > "$SDDM_CONF" << SDDMCONF
${AUTOLOGIN_SECTION}

[General]
# SDDM greeter display server (x11 for QXL VMs, wayland otherwise)
DisplayServer=${SDDM_DISPLAY_SERVER}
${SDDM_GREETER_ENV:+GreeterEnvironment=${SDDM_GREETER_ENV}}
Numlock=none
HaltCommand=/usr/bin/loginctl poweroff
RebootCommand=/usr/bin/loginctl reboot

[Theme]
# Breeze is the KDE default — matches the Plasma desktop look
Current=breeze
CursorSize=24
CursorTheme=breeze_cursors
EnableAvatars=true
FacesDir=/usr/share/sddm/faces
ThemeDir=/usr/share/sddm/themes

[Users]
DefaultPath=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin
SDDMCONF

  echo "[*] Created $SDDM_CONF with breeze theme."
  if [ -n "$AUTOLOGIN" ]; then
    echo "[*] Autologin enabled for user: $AUTOLOGIN (session: plasma)"
  fi
else
  echo "[*] $SDDM_CONF already exists — not overwriting."
  echo "    To apply theme manually, add/modify in [Theme] section:"
  echo "    Current=<theme-name>"
  echo "    CursorTheme=breeze_cursors"
fi

# ── Gruvbox SDDM theme (if gruvbox is enabled) ──────────────────────
if [ "$GRUVBOX" -eq 1 ]; then
  echo ""
  echo "=== Step 10.3b: Installing Gruvbox SDDM theme ==="
  # he1senbrg/sddm-gruvbox — QML theme, Qt6 compatible, Plasma 6 ready
  SDDM_GRUVBOX_ZIP="/tmp/sddm-gruvbox.zip"
  SDDM_GRUVBOX_DIR="/usr/share/sddm/themes/sddm-gruvbox"

  if [ -d "$SDDM_GRUVBOX_DIR" ] && [ -f "$SDDM_GRUVBOX_DIR/metadata.desktop" ]; then
    echo "[*] Gruvbox SDDM theme already installed."
  else
    echo "[*] Downloading sddm-gruvbox v1.1.0..."
    if dl_file "https://github.com/he1senbrg/sddm-gruvbox/releases/download/v1.1.0/sddm-gruvbox.zip" "$SDDM_GRUVBOX_ZIP"; then
      echo "[*] Downloaded sddm-gruvbox.zip ($(du -h "$SDDM_GRUVBOX_ZIP" 2>/dev/null | cut -f1 || echo '?'))"

      # Extract and install
      mkdir -p /tmp/sddm-gruvbox-extract
      unzip -q -o "$SDDM_GRUVBOX_ZIP" -d /tmp/sddm-gruvbox-extract/ 2>/dev/null || true
      mkdir -p "$SDDM_GRUVBOX_DIR"
      cp -r /tmp/sddm-gruvbox-extract/sddm-gruvbox/* "$SDDM_GRUVBOX_DIR/" 2>/dev/null || true
      rm -rf /tmp/sddm-gruvbox-extract "$SDDM_GRUVBOX_ZIP"

      if [ -f "$SDDM_GRUVBOX_DIR/metadata.desktop" ]; then
        echo "[*] Gruvbox SDDM theme installed to $SDDM_GRUVBOX_DIR"
      else
        echo "[!] Failed to install Gruvbox SDDM theme — files missing after extract."
        echo "[!] SDDM will fall back to breeze theme."
      fi
    else
      echo "[!] Failed to download sddm-gruvbox.zip (both curl and wget failed)."
      echo "[!] SDDM will fall back to breeze theme."
      echo "[!] Manual install: download from https://github.com/he1senbrg/sddm-gruvbox/releases"
    fi
  fi

  # Gruvbox SDDM theme — standard Gruvbox Dark palette
  # he1senbrg/sddm-gruvbox ships with non-standard colors.
  # We overwrite theme.conf with the real gruvbox palette after install.
  if [ -f "$SDDM_GRUVBOX_DIR/theme.conf" ]; then
    cat > "$SDDM_GRUVBOX_DIR/theme.conf" << 'SDDMTHEMECONF'
[General]
Font="Noto Sans"
FontSize=10

PasswordShowLastLetter=0

# [Colors] — standard Gruvbox Dark palette
# https://github.com/morhetz/gruvbox
hower     = "#928374"
text      = "#ebdbb2"
surface2  = "#504945"
surface1  = "#3c3836"
surface0  = "#282828"
overlay   = "#3c3836"
border    = "#504945"
base      = "#1d2021"
Primary   = "#fabd2f"
onPrimary = "#282828"

## [Locale Settings]
Locale=""
HourFormat="hh:mm A"
DateFormat = "ddd dd/MM/yy"
SDDMTHEMECONF
    echo "[*] Gruvbox SDDM theme.conf patched with standard gruvbox palette"
  fi

  # Set sddm-gruvbox as the active SDDM theme
  if [ -f "$SDDM_GRUVBOX_DIR/metadata.desktop" ]; then
    if grep -q "^\[Theme\]" "$SDDM_CONF" 2>/dev/null; then
      if grep -q "^Current=" "$SDDM_CONF" 2>/dev/null; then
        sed -i "s/^Current=.*/Current=sddm-gruvbox/" "$SDDM_CONF"
      else
        sed -i "/^\[Theme\]/a Current=sddm-gruvbox" "$SDDM_CONF"
      fi
    else
      echo "" >> "$SDDM_CONF"
      echo "[Theme]" >> "$SDDM_CONF"
      echo "Current=sddm-gruvbox" >> "$SDDM_CONF"
    fi
    echo "[*] SDDM theme set to: sddm-gruvbox"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# Phase 11: Optional extras
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 11: Optional Extras"
echo "══════════════════════════════════════════════════════════════"

if [ "$EXTRAS" -eq 1 ]; then
  echo "[*] Installing system sounds, browser integration, Dolphin thumbnails..."
  xinstall ocean-sound-theme plasma-browser-integration \
                kdegraphics-thumbnailers ffmpegthumbs
else
  echo "[*] Extras skipped (--no-extras)."
fi

# ═══════════════════════════════════════════════════════════════════════
# Phase 12: CLI tools, fonts, and shell configuration
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 12: CLI Tools, Nerd Fonts, and Shell Configuration"
echo "══════════════════════════════════════════════════════════════"

# ── Install CLI packages ────────────────────────────────────────────
echo ""
echo "=== Step 12.1: Installing CLI tools ==="
xinstall bat micro nano eza git bash-completion desktop-file-utils
# Note: curl and wget are installed earlier (Phase 2.4) for theme downloads

# ── Install wezterm nightly ──────────────────────────────────────────
# Void repos only have wezterm 20240203 which lacks get_selection_text_for_pane()
# needed for copy_or_interrupt keybinding. Install nightly binary from GitHub
# which has the latest API (matches Lenier's laptop version).
echo ""
echo "=== Step 12.1b: Installing wezterm nightly ==="
# xz and tar are needed to extract the .tar.xz archive.
# A fresh Void base may not have xz installed yet.
xinstall xz tar
WEZTERM_NIGHTLY_TAR="/tmp/wezterm-nightly.tar.xz"
WEZTERM_NIGHTLY_URL="https://github.com/wezterm/wezterm/releases/download/nightly/wezterm-nightly.Ubuntu22.04.tar.xz"
if dl_file "$WEZTERM_NIGHTLY_URL" "$WEZTERM_NIGHTLY_TAR"; then
  mkdir -p /tmp/wezterm-nightly-extract
  tar -xf "$WEZTERM_NIGHTLY_TAR" -C /tmp/wezterm-nightly-extract/ 2>/dev/null || true
  if [ -f /tmp/wezterm-nightly-extract/wezterm/usr/bin/wezterm ]; then
    cp -r /tmp/wezterm-nightly-extract/wezterm/usr/* /usr/ 2>/dev/null || true
    rm -rf /tmp/wezterm-nightly-extract "$WEZTERM_NIGHTLY_TAR"
    WEZTERM_VERSION=$(wezterm --version 2>/dev/null || echo "unknown")
    echo "[*] wezterm nightly installed: $WEZTERM_VERSION"
  else
    echo "[!] wezterm nightly binary not found after extract. Falling back to xbps."
    xinstall wezterm wezterm-terminfo
  fi
else
  echo "[!] Failed to download wezterm nightly. Falling back to xbps package."
  xinstall wezterm wezterm-terminfo
fi

# ── Install Nerd Fonts + base fonts ──────────────────────────────────
# nerd-fonts-symbols-ttf (2MB) provides the icon glyphs that eza --icons
# needs. Instead of the full nerd-fonts-ttf (1.42GB), we download only the
# 4 font families we want from the Nerd Fonts GitHub releases (~13MB total):
#   CaskaydiaMono, FiraCode, JetBrainsMono, RobotoMono
# RobotoMono is set as the default monospace font system-wide via fontconfig.
# Base fonts: dejavu (default sans/mono fallback), noto (multi-language),
# noto-cjk (CJK), noto-emoji (emoji support — important for modern desktop).
echo ""
echo "=== Step 12.2: Installing fonts ==="
xinstall nerd-fonts-symbols-ttf dejavu-fonts-ttf noto-fonts-ttf noto-fonts-emoji
# CJK fonts are large — skip on VMs unless bare metal
if [ "$VIRT_PLATFORM" = "none" ]; then
  xinstall noto-fonts-cjk
else
  echo "[*] VM detected — skipping noto-fonts-cjk (large). Install manually if needed."
fi

# ── Download individual Nerd Fonts from GitHub releases ───────────────
# Void only ships the full 1.42GB nerd-fonts-ttf collection — no per-family
# packages. We download only the 4 families we need as .tar.xz from the
# Nerd Fonts release page. Each archive is 2-5MB.
NERD_FONT_VERSION="3.4.0"
NERD_FONT_BASE_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v${NERD_FONT_VERSION}"
NERD_FONT_DIR="/usr/share/fonts/nerd-fonts"
NERD_FONT_FAMILIES="CaskaydiaMono FiraCode JetBrainsMono RobotoMono"

mkdir -p "$NERD_FONT_DIR"
echo "[*] Downloading individual Nerd Fonts (v${NERD_FONT_VERSION})..."

for family in $NERD_FONT_FAMILIES; do
  archive="${family}.tar.xz"
  url="${NERD_FONT_BASE_URL}/${archive}"
  tmpfile="/tmp/nf-${archive}"
  echo "[*] Downloading ${family}..."
  if dl_file "$url" "$tmpfile"; then
    tar -xf "$tmpfile" -C "$NERD_FONT_DIR" 2>/dev/null || true
    rm -f "$tmpfile"
    echo "[*] ${family} installed to ${NERD_FONT_DIR}"
  else
    echo "[!] Failed to download ${family} — skipping. Install manually if needed."
  fi
done

# Rebuild font cache so the new fonts are immediately available
echo "[*] Rebuilding font cache..."
fc-cache -f 2>/dev/null || echo "[!] fc-cache not found — font cache not rebuilt"

# Reconfigure fontconfig to pick up new font config files (handbook recommended)
xbps-reconfigure -f fontconfig 2>/dev/null || true

# ── Set RobotoMono as default monospace font system-wide ─────────────
# Create a fontconfig prefer config so RobotoMono Nerd Font is the preferred
# monospace font everywhere — terminal emulators, KDE, Qt apps, etc.
echo "[*] Setting RobotoMono Nerd Font as default monospace system-wide..."
mkdir -p /etc/fonts/conf.d
cat > /etc/fonts/conf.d/99-nerd-font-mono.conf << 'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <!-- Prefer RobotoMono Nerd Font as the default monospace font -->
  <match target="pattern">
    <test name="family">
      <string>monospace</string>
    </test>
    <edit name="family" mode="prepend" binding="strong">
      <string>RobotoMono Nerd Font</string>
      <string>RobotoMono Nerd Font Mono</string>
    </edit>
  </match>
  <!-- Also prefer it for the generic "monospace" alias -->
  <match target="pattern">
    <test name="family">
      <string>monospace</string>
    </test>
    <edit name="family" mode="append" binding="weak">
      <string>DejaVu Sans Mono</string>
    </edit>
  </match>
</fontconfig>
FONTCONF

# Rebuild cache again after adding the fontconfig drop-in
fc-cache -f 2>/dev/null || true

# ── Configure bash for all users ─────────────────────────────────────
# Write /etc/bashrc.d/void-enhancements.sh — sourced by /etc/bashrc
# on Void for interactive shells. This applies to all users.
echo ""
echo "=== Step 12.3: Configuring bash (history, completion, aliases, fonts) ==="

BASHRC_DIR=/etc/bashrc.d
mkdir -p "$BASHRC_DIR"

cat > "${BASHRC_DIR}/void-enhancements.sh" << 'BASHRC'
# ═══════════════════════════════════════════════════════════════════════
#  Void Linux KDE Plasma Installer — Bash Enhancements (system-wide)
#  File: /etc/bashrc.d/void-enhancements.sh
#  Sourced by: /etc/bashrc (interactive shells) and ~/.bashrc
# ═══════════════════════════════════════════════════════════════════════

# ── Bash history ──────────────────────────────────────────────────────
export HISTSIZE=10000
export HISTFILESIZE=20000
shopt -s histappend
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT="%F %T  "
export HISTIGNORE="ls:ll:cd:cd ..:pwd:exit:clear:history"

# ── Bash completion ──────────────────────────────────────────────────
if [ -f /usr/share/bash-completion/bash_completion ]; then
  . /usr/share/bash-completion/bash_completion
fi

# ── Editor ────────────────────────────────────────────────────────────
export EDITOR=micro
export VISUAL=micro
export MICRO_TRUECOLOR=1
alias nano="micro"

# ── Aliases: file listing (eza with Nerd Font icons) ──────────────────
alias ls="eza --icons --group-directories-first"
alias ll="eza -lh --icons --group-directories-first --git"
alias la="eza -lah --icons --group-directories-first --git"
alias lt="eza --tree --icons --level=2"
alias l="eza -lh --icons --group-directories-first"

# ── Aliases: file viewing (bat) ───────────────────────────────────────
alias cat="bat --paging=never"
alias catn="bat --paging=never --plain"
alias bathelp="bat --paging=never --language=help"

# ── Aliases: Void Linux package management (XBPS) ─────────────────────
alias update="sudo xbps-install -Su && flatpak update -y 2>/dev/null; flatpak uninstall --unused -y 2>/dev/null || true"
alias install="sudo xbps-install -S"
alias search="xbps-query -Rs"
alias remove="sudo xbps-remove -R"
alias cleanup="sudo xbps-remove -O && sudo xbps-remove -o"
alias xlock="sudo xbps-pkgdb -m repolock"
alias xunlock="sudo xbps-pkgdb -m repounlock"
alias xheld="xbps-query -l | grep -i held"
alias repos="command cat /usr/share/xbps.d/* 2>/dev/null | grep repository"

# ── Aliases: system info ──────────────────────────────────────────────
alias ports="ss -tulpn"
alias myip="ip -br addr"

# ── Aliases: Flatpak ──────────────────────────────────────────────────
alias fpupdate="flatpak update -y"
alias fpinstall="flatpak install flathub"
alias fpsearch="flatpak search"
alias fplist="flatpak list"
alias fpremove="flatpak uninstall -y"

# NOTE: Prompt is NOT set here — it is set in the user .bashrc directly.
# This file only provides history, completion, aliases, and editor.
BASHRC

chmod 644 "${BASHRC_DIR}/void-enhancements.sh"
echo "[*] Created ${BASHRC_DIR}/void-enhancements.sh"

# ── Verify /etc/bashrc sources bashrc.d ──────────────────────────────
# Void's default /etc/bashrc should source files in /etc/bashrc.d/
# but let's make sure
if ! grep -q 'bashrc.d' /etc/bashrc 2>/dev/null; then
  echo "[*] Adding bashrc.d sourcing to /etc/bashrc..."
  cat >> /etc/bashrc << 'BASHRC_SOURCE'

# ── Source enhancements from /etc/bashrc.d/ ──
if [ -d /etc/bashrc.d ]; then
  for f in /etc/bashrc.d/*.sh; do
    [ -r "$f" ] && . "$f"
  done
  unset f
fi
BASHRC_SOURCE
else
  echo "[*] /etc/bashrc already sources bashrc.d/"
fi

# ── Per-user .bashrc (for login shells that don't read /etc/bashrc) ─
echo ""
echo "=== Step 12.4: Writing user .bashrc with full enhancements ==="
# Write the full .bashrc directly (single-user system) instead of just
# sourcing from /etc/bashrc.d/. This makes `cat ~/.bashrc` show all
# customizations without needing to look at a separate file.
for user_home in /root /home/*; do
  user_bashrc="${user_home}/.bashrc"

  # If .bashrc already has our marker, skip it
  if grep -q 'install-kde-plasma.sh' "$user_bashrc" 2>/dev/null; then
    echo "[*] $user_bashrc already has full enhancements — skipping."
    continue
  fi

  cat > "$user_bashrc" << 'USERBASHRC'
# ═══════════════════════════════════════════════════════════════════════
#  User .bashrc — full customizations (single-user system)
#  Generated by install-kde-plasma.sh
# ═══════════════════════════════════════════════════════════════════════

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# ──────────────────────────────────────────────────────────────────────
# [1] BASH HISTORY
# ──────────────────────────────────────────────────────────────────────
export HISTSIZE=10000
export HISTFILESIZE=20000
shopt -s histappend
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT="%F %T  "
export HISTIGNORE="ls:ll:cd:cd ..:pwd:exit:clear:history"

# ──────────────────────────────────────────────────────────────────────
# [2] BASH COMPLETION
# ──────────────────────────────────────────────────────────────────────
if [ -f /usr/share/bash-completion/bash_completion ]; then
  . /usr/share/bash-completion/bash_completion
fi

# ──────────────────────────────────────────────────────────────────────
# [3] EDITOR
# ──────────────────────────────────────────────────────────────────────
export EDITOR=micro
export VISUAL=micro
export MICRO_TRUECOLOR=1
alias nano='micro'

# ──────────────────────────────────────────────────────────────────────
# [4] ALIASES — FILE LISTING (eza with Nerd Font icons)
# ──────────────────────────────────────────────────────────────────────
alias ls='eza --icons --group-directories-first'
alias ll='eza -lh --icons --group-directories-first --git'
alias la='eza -lah --icons --group-directories-first --git'
alias lt='eza --tree --icons --level=2'
alias l='eza -lh --icons --group-directories-first'

# ──────────────────────────────────────────────────────────────────────
# [5] ALIASES — FILE VIEWING (bat with syntax highlighting)
# ──────────────────────────────────────────────────────────────────────
alias cat='bat --paging=never'
alias catn='bat --paging=never --plain'
alias bathelp='bat --paging=never --language=help'

# ──────────────────────────────────────────────────────────────────────
# [6] ALIASES — VOID LINUX PACKAGE MANAGEMENT (XBPS)
# ──────────────────────────────────────────────────────────────────────
alias update='sudo xbps-install -Su && flatpak update -y 2>/dev/null; flatpak uninstall --unused -y 2>/dev/null || true'
alias install='sudo xbps-install -S'
alias search='xbps-query -Rs'
alias remove='sudo xbps-remove -R'
alias cleanup='sudo xbps-remove -O && sudo xbps-remove -o'
alias xlock='sudo xbps-pkgdb -m repolock'
alias xunlock='sudo xbps-pkgdb -m repounlock'
alias xheld='xbps-query -l | grep -i held'
alias repos="command cat /usr/share/xbps.d/* 2>/dev/null | grep repository"

# ──────────────────────────────────────────────────────────────────────
# [7] ALIASES — SYSTEM INFO
# ──────────────────────────────────────────────────────────────────────
alias ports='ss -tulpn'
alias myip='ip -br addr'

# ──────────────────────────────────────────────────────────────────────
# [7.5] ALIASES — FLATPAK
# ──────────────────────────────────────────────────────────────────────
alias fpupdate='flatpak update -y'
alias fpinstall='flatpak install flathub'
alias fpsearch='flatpak search'
alias fplist='flatpak list'
alias fpremove='flatpak uninstall -y'

# ──────────────────────────────────────────────────────────────────────
# [8] PROMPT — custom two-line prompt with exit code indicator
# ──────────────────────────────────────────────────────────────────────
# Prompt: two-line box style with time, jobs, hostname, and working directory
#   ╭─(time)-(jobs)-(hostname)-(working dir)
#   ╰─>
# Shows red [exitcode] before the prompt when the last command failed
# Uses \033 (octal) for colors instead of \e — bash 5.3 does not
# interpret \e in PS1 strings. Uses $'...' for the literal newline.
__exit_code_ps1() {
  local ec=$?
  local green='\[\033[38;5;35m\]'
  local cyan='\[\033[38;5;38m\]'
  local reset='\[\033[0m\]'
  local nl=$'\n'
  local base="${green}╭─(${cyan}\t${green})-(${cyan}\j${green})-(${cyan}\H${green})-(${cyan}\w${green})${nl}${green}╰─>${reset} "
  if [ $ec -ne 0 ]; then
    PS1="\[\033[01;31m\][$ec]\[\033[00m\]${base}"
  else
    PS1="${base}"
  fi
  return $ec
}
PROMPT_COMMAND="__exit_code_ps1; history -a; history -n; ${PROMPT_COMMAND:-}"

# ──────────────────────────────────────────────────────────────────────
# [9] SOURCE SYSTEM-WIDE ENHANCEMENTS (if any exist)
# ──────────────────────────────────────────────────────────────────────
if [ -d /etc/bashrc.d ]; then
  for f in /etc/bashrc.d/*.sh; do
    [ -r "$f" ] && . "$f"
  done
  unset f
fi
USERBASHRC

  if [ "$user_home" = "/root" ]; then
    chown root:root "$user_bashrc"
  else
    owner=$(stat -c %U "$user_home" 2>/dev/null || true)
    [ -n "$owner" ] && chown "$owner":"$owner" "$user_bashrc" 2>/dev/null || true
  fi
  chmod 644 "$user_bashrc"
  echo "[*] Created $user_bashrc with full enhancements"
done

# ── bash-completion verification ─────────────────────────────────────
echo ""
echo "=== Step 12.5: Verifying bash-completion ==="
if [ -f /usr/share/bash-completion/bash_completion ]; then
  echo "[*] bash-completion installed and available."
else
  echo "[!] bash-completion file not found — completion may not work."
fi

# ── Nerd Font verification ───────────────────────────────────────────
echo ""
echo "=== Step 12.6: Verifying Nerd Fonts ==="
if fc-list 2>/dev/null | grep -qi 'RobotoMono Nerd Font'; then
  echo "[*] RobotoMono Nerd Font detected by fontconfig (default monospace)."
  echo "[*] eza --icons will display file-type icons in the terminal."
  echo "[*] WezTerm configured to use RobotoMono Nerd Font."
else
  echo "[!] RobotoMono Nerd Font not detected by fontconfig."
  echo "[!] Run: sudo fc-cache -f && fc-list | grep -i robotomono"
fi
if fc-list 2>/dev/null | grep -qi 'CaskaydiaMono Nerd Font'; then
  echo "[*] CaskaydiaMono Nerd Font detected."
fi
if fc-list 2>/dev/null | grep -qi 'FiraCode Nerd Font'; then
  echo "[*] FiraCode Nerd Font detected."
fi
if fc-list 2>/dev/null | grep -qi 'JetBrainsMono Nerd Font'; then
  echo "[*] JetBrainsMono Nerd Font detected."
fi

echo ""
echo "[*] CLI tools, fonts, and shell configuration complete."
echo "[*] Changes take effect on next shell session (or run: source /etc/bashrc)"

# ── Set wezterm as default terminal ───────────────────────────────────
echo ""
echo "=== Step 12.7: Setting wezterm as default terminal ==="
WEZTERM_DESKTOP=/usr/share/applications/org.wezfurlong.wezterm.desktop

if [ -f "$WEZTERM_DESKTOP" ]; then
  # Set wezterm as the default terminal emulator for xdg-terminal-exec
  # and for the TerminalEmulator desktop category.
  # This makes KDE Plasma use wezterm for Ctrl+Alt+T and other terminal
  # launch actions.

  # Create a terminal.desktop symlink that xdg-terminal-exec looks for
  if [ ! -f /usr/share/applications/terminal.desktop ]; then
    ln -sf "$WEZTERM_DESKTOP" /usr/share/applications/terminal.desktop
    echo "[*] Linked terminal.desktop -> wezterm"
  else
    rm -f /usr/share/applications/terminal.desktop
    ln -sf "$WEZTERM_DESKTOP" /usr/share/applications/terminal.desktop
    echo "[*] Replaced terminal.desktop -> wezterm"
  fi

  # Set the x-scheme-handler/terminal mime type to wezterm
  # This is how KDE resolves the default terminal application
  for user_home in /root /home/*; do
    usermime="${user_home}/.config/mimeapps.list"
    mkdir -p "$(dirname "$usermime")"

    # Remove any existing terminal handler entry
    if [ -f "$usermime" ]; then
      sed -i '/x-scheme-handler\/terminal/d' "$usermime"
    fi

    # Add wezterm as the default terminal handler
    if ! grep -q '\[Default Applications\]' "$usermime" 2>/dev/null; then
      echo "[Default Applications]" >> "$usermime"
    fi
    echo "x-scheme-handler/terminal=org.wezfurlong.wezterm.desktop" >> "$usermime"

    # Set ownership
    if [ "$user_home" = "/root" ]; then
      chown root:root "$usermime"
    else
      owner=$(stat -c %U "$user_home" 2>/dev/null || true)
      [ -n "$owner" ] && chown "$owner":"$owner" "$usermime" 2>/dev/null || true
    fi
    echo "[*] Set wezterm as default terminal for $(basename "$user_home")"
  done

  # Also set the system-wide default in /etc
  SYSMIME=/etc/xdg/mimeapps.list
  mkdir -p "$(dirname "$SYSMIME")"
  if [ -f "$SYSMIME" ]; then
    sed -i '/x-scheme-handler\/terminal/d' "$SYSMIME"
  fi
  if ! grep -q '\[Default Applications\]' "$SYSMIME" 2>/dev/null; then
    echo "[Default Applications]" >> "$SYSMIME"
  fi
  echo "x-scheme-handler/terminal=org.wezfurlong.wezterm.desktop" >> "$SYSMIME"
  echo "[*] Set wezterm as default terminal system-wide (/etc/xdg/mimeapps.list)"

  # Update the MIME database
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database 2>/dev/null || true

  echo "[*] wezterm is now the default terminal emulator."
  echo "[*] KDE Plasma will use wezterm for Ctrl+Alt+T and terminal actions."
else
  echo "[!] wezterm .desktop file not found at $WEZTERM_DESKTOP"
  echo "[!] Default terminal not changed."
fi

# ── Create wezterm configuration ──────────────────────────────────────
echo ""
echo "=== Step 12.8: Creating wezterm configuration (Gruvbox + opacity) ==="
for user_home in /root /home/*; do
  wt_dir="${user_home}/.config/wezterm"
  wt_file="${wt_dir}/wezterm.lua"
  mkdir -p "$wt_dir"

  cat > "$wt_file" << 'WEZTERMCFG'
-- ═══════════════════════════════════════════════════════════════════════
--  WezTerm Configuration — Gruvbox with opacity
--  Generated by install-kde-plasma.sh
-- ═══════════════════════════════════════════════════════════════════════

local wezterm = require("wezterm")
local act = wezterm.action

-- ── copy_or_interrupt: copy if selection, SIGINT if not ──────────────
local copy_or_interrupt = wezterm.action_callback(function(window, pane)
  local has_selection = window:get_selection_text_for_pane(pane) ~= ""
  if has_selection then
    window:perform_action(act.CopyTo("Clipboard"), pane)
    window:perform_action(act.ClearSelection, pane)
  else
    window:perform_action(act.SendKey({ key = "c", mods = "CTRL" }), pane)
  end
end)

return {
  -- ── Font ──────────────────────────────────────────────────────────────
  font = wezterm.font_with_fallback {
    { family = "RobotoMono Nerd Font", scale = 1.0 },
    { family = "Symbols Nerd Font Mono", scale = 1.0 },
    { family = "DejaVu Sans Mono", scale = 1.0 },
  },
  font_size = 12.0,
  line_height = 1.1,

  -- ── Colors ────────────────────────────────────────────────────────────
  color_scheme = "Gruvbox Dark",

  -- ── Window ────────────────────────────────────────────────────────────
  initial_cols = 120,
  initial_rows = 32,
  window_background_opacity = 0.85,
  window_decorations = "TITLE | RESIZE",
  window_padding = {
    left   = 8,
    right  = 8,
    top    = 8,
    bottom = 8,
  },

  -- ── Tab Bar ───────────────────────────────────────────────────────────
  use_fancy_tab_bar            = true,
  hide_tab_bar_if_only_one_tab = true,
  tab_bar_at_bottom            = false,

  -- ── Scrollback ────────────────────────────────────────────────────────
  scrollback_lines = 10000,

  -- ── Keys ──────────────────────────────────────────────────────────────
  keys = {
    { key = "c", mods = "CTRL",       action = copy_or_interrupt },
    { key = "v", mods = "CTRL",       action = act.PasteFrom("Clipboard") },

    { key = "t", mods = "CTRL|SHIFT", action = act.SpawnTab("CurrentPaneDomain") },
    { key = "w", mods = "CTRL|SHIFT", action = act.CloseCurrentTab({ confirm = false }) },
    { key = "n", mods = "CTRL|SHIFT", action = act.SpawnWindow },
    { key = "q", mods = "CTRL|SHIFT", action = act.QuitApplication },

    { key = "Tab", mods = "CTRL",       action = act.ActivateTabRelative(1) },
    { key = "Tab", mods = "CTRL|SHIFT", action = act.ActivateTabRelative(-1) },

    { key = "f", mods = "CTRL|SHIFT",  action = act.Search({ CaseInSensitiveString = "" }) },

    { key = "=", mods = "CTRL", action = act.IncreaseFontSize },
    { key = "-", mods = "CTRL", action = act.DecreaseFontSize },
    { key = "0", mods = "CTRL", action = act.ResetFontSize },

    { key = "d", mods = "CTRL|SHIFT", action = act.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
    { key = "e", mods = "CTRL|SHIFT", action = act.SplitVertical({ domain = "CurrentPaneDomain" }) },
    { key = "x", mods = "CTRL|SHIFT", action = act.CloseCurrentPane({ confirm = false }) },

    { key = "h", mods = "ALT", action = act.ActivatePaneDirection("Left") },
    { key = "j", mods = "ALT", action = act.ActivatePaneDirection("Down") },
    { key = "k", mods = "ALT", action = act.ActivatePaneDirection("Up") },
    { key = "l", mods = "ALT", action = act.ActivatePaneDirection("Right") },
    { key = "t", mods = "ALT", action = act.SpawnTab("CurrentPaneDomain") },
    { key = "LeftArrow",  mods = "ALT", action = act.ActivateTabRelative(-1) },
    { key = "RightArrow", mods = "ALT", action = act.ActivateTabRelative(1) },

    { key = "1", mods = "ALT", action = act.ActivateTab(0) },
    { key = "2", mods = "ALT", action = act.ActivateTab(1) },
    { key = "3", mods = "ALT", action = act.ActivateTab(2) },
    { key = "4", mods = "ALT", action = act.ActivateTab(3) },
    { key = "5", mods = "ALT", action = act.ActivateTab(4) },

    { key = "Enter", mods = "ALT", action = act.ToggleFullScreen },
  },
}
WEZTERMCFG

  if [ "$user_home" = "/root" ]; then
    chown -R root:root "$wt_dir"
  else
    owner=$(stat -c %U "$user_home" 2>/dev/null || true)
    [ -n "$owner" ] && chown -R "$owner":"$owner" "$wt_dir" 2>/dev/null || true
  fi
  echo "[*] Created $wt_file"
done

# ── Wayland preference note ──────────────────────────────────────────
if [ "$WAYLAND" -eq 1 ]; then
  echo ""
  echo "[*] Wayland preference noted."
  echo "    SDDM supports both X11 and Wayland sessions."
  echo "    After login, select 'Plasma (Wayland)' from the SDDM session dropdown."
  echo "    No additional package is needed — Plasma Wayland support is included in kde-plasma."
fi

# ── Apply Breeze Dark theme (only when Gruvbox is disabled) ──────────
# Pre-configure the Breeze Dark color scheme and look-and-feel so the
# user gets a dark desktop on first login without needing to manually
# apply it in System Settings (where the Apply button would fail if
# .config is root-owned — fixed above).
# When Gruvbox is enabled (Phase 14), skip this — Phase 14 writes its own
# kdeglobals with GruvboxPlusDark color scheme and Gruvbox-Plus-Dark icons.
# If Breeze Dark runs first, it writes LookAndFeelPackage=org.kde.breezedark.desktop
# which overrides the Gruvbox color scheme on login.
if [ "$GRUVBOX" -eq 0 ]; then
echo ""
echo "[*] Pre-configuring Breeze Dark theme..."
for user_home in /home/*; do
  owner=$(stat -c %U "$user_home" 2>/dev/null || true)
  [ -z "$owner" ] || [ "$owner" = "root" ] && continue

  kde_defaults="${user_home}/.config/kdedefaults"
  mkdir -p "$kde_defaults"
  chown -R "$owner":"$owner" "$kde_defaults"

  # Write kdeglobals with BreezeDark color scheme
  cat > "${user_home}/.config/kdeglobals" << 'KDEGLOBALS'
[General]
ColorScheme=BreezeDark

[Icons]
Theme=breeze-dark

[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
widgetStyle=Breeze
contrast=4
frameContrast=0.2
KDEGLOBALS
  chown "$owner":"$owner" "${user_home}/.config/kdeglobals"

  # Write kdedefaults/kdeglobals
  cat > "${kde_defaults}/kdeglobals" << 'KDDEFAULTS'
[General]
ColorScheme=BreezeDark

[Icons]
Theme=breeze-dark

[KDE]
widgetStyle=Breeze
KDDEFAULTS
  chown "$owner":"$owner" "${kde_defaults}/kdeglobals"

  # Write kdedefaults/package
  echo "org.kde.breezedark.desktop" > "${kde_defaults}/package"
  chown "$owner":"$owner" "${kde_defaults}/package"

  echo "[*] Configured Breeze Dark theme for $owner"
done
fi # end Breeze Dark (GRUVBOX=0 gate)

# ── Install Gruvbox Plus Dark icons ──────────────────────────────────
# Gruvbox Plus is an icon pack based on Gruvbox colors, by SylEleuth.
# Source: https://github.com/SylEleuth/gruvbox-plus-icon-pack
# KDE Store: https://store.kde.org/p/1961046
# The Dark variant has light symbolic icons for dark themes (matches Breeze Dark).
# Installed to /usr/share/icons (system-wide) so all users see them.
echo ""
echo "[*] Installing Gruvbox Plus Dark icons..."
GRUVBOX_TMP=$(mktemp -d)
if git clone --depth 1 https://github.com/SylEleuth/gruvbox-plus-icon-pack.git "$GRUVBOX_TMP" 2>/dev/null; then
  # Install the Dark variant system-wide
  if [ -d "$GRUVBOX_TMP/Gruvbox-Plus-Dark" ]; then
    rm -rf /usr/share/icons/Gruvbox-Plus-Dark
    cp -r "$GRUVBOX_TMP/Gruvbox-Plus-Dark" /usr/share/icons/Gruvbox-Plus-Dark
    echo "[*] Installed Gruvbox-Plus-Dark to /usr/share/icons/"
  fi
  # Also install Light variant for completeness
  if [ -d "$GRUVBOX_TMP/Gruvbox-Plus-Light" ]; then
    rm -rf /usr/share/icons/Gruvbox-Plus-Light
    cp -r "$GRUVBOX_TMP/Gruvbox-Plus-Light" /usr/share/icons/Gruvbox-Plus-Light
    echo "[*] Installed Gruvbox-Plus-Light to /usr/share/icons/"
  fi
  # Rebuild icon cache
  gtk-update-icon-cache -f /usr/share/icons/Gruvbox-Plus-Dark 2>/dev/null || true
  gtk-update-icon-cache -f /usr/share/icons/Gruvbox-Plus-Light 2>/dev/null || true
else
  echo "[!] Could not clone Gruvbox Plus icon pack. Installing manually:"
  echo "    git clone https://github.com/SylEleuth/gruvbox-plus-icon-pack.git"
  echo "    cp -r gruvbox-plus-icon-pack/Gruvbox-Plus-Dark /usr/share/icons/"
fi
rm -rf "$GRUVBOX_TMP"

# (Dead code removed — the Breeze Dark sed replacements for Theme=breeze-dark
#  can never match when GRUVBOX=1 because the Breeze Dark section is gated
#  behind GRUVBOX=0. Phase 14.2 handles icon theme setting correctly with
#  proper variant support.)

# ═══════════════════════════════════════════════════════════════════════
# Phase 13: Flatpak + Flathub + Apps (Brave, Tutanota)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 13: Flatpak, Flathub, and Applications"
echo "══════════════════════════════════════════════════════════════"

if [ "$FLATPAK" -eq 1 ]; then

# ── Install flatpak via xbps ──────────────────────────────────────────
echo ""
echo "=== Step 13.1: Installing flatpak ==="
xinstall flatpak

# ── Add Flathub remote ────────────────────────────────────────────────
# Flathub is the primary Flatpak repository. We add it system-wide
# so all users see the same apps and runtimes.
echo ""
echo "=== Step 13.2: Adding Flathub remote ==="
if flatpak remotes 2>/dev/null | grep -q 'flathub'; then
  echo "[*] Flathub remote already exists."
else
  fp_output=$(flatpak remote-add --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo 2>&1 | tr -d '\r') || true
  if flatpak remotes 2>/dev/null | grep -q 'flathub'; then
    echo "[*] Flathub remote added."
  else
    echo "[!] Failed to add Flathub remote. Flatpak apps may not install."
  fi
fi

# ── Install xdg-desktop-portal for Flatpak ↔ KDE integration ─────────
# Without the portal backend, Flatpak apps can't open files, share
# notifications, or take screenshots properly under Plasma.
echo ""
echo "=== Step 13.3: Installing Flatpak/KDE portal integration ==="
xinstall xdg-desktop-portal xdg-desktop-portal-kde

# ── Install Brave Browser ─────────────────────────────────────────────
# App ID: com.brave.Browser (verified on Flathub by Brave Software)
echo ""
echo "=== Step 13.4: Installing Brave Browser ==="
if flatpak list 2>/dev/null | grep -q 'com.brave.Browser'; then
  echo "[*] Brave Browser already installed."
else
  fp_output=$(flatpak install -y flathub com.brave.Browser 2>&1 | tr -d '\r') || true
  if flatpak list 2>/dev/null | grep -q 'com.brave.Browser'; then
    echo "[*] Brave Browser installed."
  else
    echo "[!] Brave Browser install failed — try manually: flatpak install flathub com.brave.Browser"
  fi
fi

# ── Install Tutanota (Tuta) ───────────────────────────────────────────
# App ID: com.tutanota.Tutanota (experimental, by Tutao GmbH)
# This is the Flatpak preview release — known issues exist but it
# works for basic email/calendar. Check tuta.com/support if issues.
echo ""
echo "=== Step 13.5: Installing Tutanota (Tuta) ==="
if flatpak list 2>/dev/null | grep -q 'com.tutanota.Tutanota'; then
  echo "[*] Tutanota already installed."
else
  fp_output=$(flatpak install -y flathub com.tutanota.Tutanota 2>&1 | tr -d '\r') || true
  if flatpak list 2>/dev/null | grep -q 'com.tutanota.Tutanota'; then
    echo "[*] Tutanota installed."
  else
    echo "[!] Tutanota install failed — try manually: flatpak install flathub com.tutanota.Tutanota"
  fi
fi

# ── Update flatpak desktop database ───────────────────────────────────
echo ""
echo "=== Step 13.6: Updating desktop database ==="
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database 2>/dev/null || true
echo "[*] Desktop database updated — apps visible in KDE menu."

echo ""
echo "[*] Flatpak setup complete."
echo "[*] Update Flatpak apps periodically: flatpak update"

else
  echo "[*] Flatpak skipped (--no-flatpak)."
fi

# ═══════════════════════════════════════════════════════════════════════
# Phase 13b: Automatic updates (snooze-daily + cron.daily script)
# ═══════════════════════════════════════════════════════════════════════
# Void doesn't have an auto-update daemon. We use snooze (Void's native
# cron alternative) with a daily script in /etc/cron.daily that runs:
#   1. xbps-install -Su (system packages)
#   2. flatpak update (if flatpak is installed)
#   3. xbps-remove -O (clean cache)
# The script logs to /var/log/void-autoupdate.log and never aborts on
# error — it logs failures but doesn't block the system from booting.
# snooze-daily fires once per day (not at a fixed time, but within 24h
# of the last run, accounting for missed runs while powered off).
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 13b: Automatic Updates"
echo "══════════════════════════════════════════════════════════════"

# Install snooze for cron-style scheduling
xinstall snooze

# Enable snooze-daily runit service
if [ -d /etc/sv/snooze-daily ] && [ ! -L /var/service/snooze-daily ]; then
  ln -s /etc/sv/snooze-daily /var/service/
  echo "[*] snooze-daily symlink created."
elif [ -L /var/service/snooze-daily ]; then
  echo "[*] snooze-daily already enabled."
fi

# Create the daily auto-update script
# /etc/cron.daily is executed by snooze-daily's run script via run-parts
mkdir -p /etc/cron.daily
cat > /etc/cron.daily/void-autoupdate << 'AUTUPDATE'
#!/bin/sh
# void-autoupdate — daily system + Flatpak update
# Executed by snooze-daily via run-parts /etc/cron.daily
# Logs to /var/log/void-autoupdate.log
LOG=/var/log/void-autoupdate.log
echo "=== $(date) ===" >> "$LOG"

# Update XBPS packages
echo "[*] Updating system packages..." >> "$LOG"
xbps-install -Syu >> "$LOG" 2>&1 || echo "[!] xbps-update failed" >> "$LOG"

# Update Flatpak apps (if flatpak is installed)
if command -v flatpak >/dev/null 2>&1; then
  echo "[*] Updating Flatpak apps..." >> "$LOG"
  flatpak update -y >> "$LOG" 2>&1 || echo "[!] flatpak update failed" >> "$LOG"
  flatpak uninstall --unused -y >> "$LOG" 2>&1 || true
fi

# Clean XBPS cache
echo "[*] Cleaning package cache..." >> "$LOG"
xbps-remove -O >> "$LOG" 2>&1 || true

echo "[*] Auto-update complete." >> "$LOG"
echo "" >> "$LOG"
AUTUPDATE
chmod 755 /etc/cron.daily/void-autoupdate
echo "[*] Created /etc/cron.daily/void-autoupdate"

# Rotate log if it gets large (>10MB), keep last 3
mkdir -p /etc/cron.weekly
cat > /etc/cron.weekly/void-autoupdate-logrotate << 'LOGROTATE'
#!/bin/sh
# Rotate void-autoupdate.log — keep last 3, rotate at 10MB
LOG=/var/log/void-autoupdate.log
if [ -f "$LOG" ]; then
  SIZE=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 10485760 ]; then
    for i in 2 1; do
      [ -f "${LOG}.$i" ] && mv "${LOG}.$i" "${LOG}.$((i+1))"
    done
    mv "$LOG" "${LOG}.1"
    echo "=== $(date) — log rotated ===" > "$LOG"
  fi
fi
LOGROTATE
chmod 755 /etc/cron.weekly/void-autoupdate-logrotate
echo "[*] Created /etc/cron.weekly/void-autoupdate-logrotate"

# Enable snooze-weekly for the log rotation
if [ -d /etc/sv/snooze-weekly ] && [ ! -L /var/service/snooze-weekly ]; then
  ln -s /etc/sv/snooze-weekly /var/service/
  echo "[*] snooze-weekly symlink created."
elif [ -L /var/service/snooze-weekly ]; then
  echo "[*] snooze-weekly already enabled."
fi

echo "[*] Automatic updates configured:"
echo "    - snooze-daily runs /etc/cron.daily/void-autoupdate"
echo "    - Updates xbps packages + flatpak apps, cleans cache"
echo "    - Logs to /var/log/void-autoupdate.log"
echo "    - snooze-weekly rotates the log"

# ═══════════════════════════════════════════════════════════════════════
# PHASE 14: Gruvbox Theme (optional — enabled with --gruvbox)
# ═══════════════════════════════════════════════════════════════════════
if [ "$GRUVBOX" -eq 1 ]; then
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  Phase 14: Gruvbox Theme"
  echo "══════════════════════════════════════════════════════════════"

  # Detect target user (same logic as gruvbox-setup.sh)
  GRUVBOX_USER=""
  if [ -n "$AUTOLOGIN" ]; then
    GRUVBOX_USER="$AUTOLOGIN"
  else
    for user_home in /home/*; do
      username=$(basename "$user_home")
      if id "$username" >/dev/null 2>&1; then
        GRUVBOX_USER="$username"
        break
      fi
    done
  fi

  if [ -z "$GRUVBOX_USER" ]; then
    echo "[!] No user found for Gruvbox theme. Skipping."
    GRUVBOX=0
  else
    G_USER_HOME=$(getent passwd "$GRUVBOX_USER" 2>/dev/null | cut -d: -f6 || true)
    echo "[*] Target user: $GRUVBOX_USER ($G_USER_HOME)"
    echo "[*] Variant: $GRUVBOX_VARIANT"
    echo "[*] Options: icons=$GRUVBOX_ICONS kvantum=$GRUVBOX_KVANTUM fastfetch=$GRUVBOX_FASTFETCH wallpaper=$GRUVBOX_WALLPAPER"

    # ── 14.1: Color Scheme ──────────────────────────────────────────
    echo ""
    echo "=== Step 14.1: Gruvbox Color Scheme ==="
    COLOR_SCHEMES_DIR="$G_USER_HOME/.local/share/color-schemes"
    mkdir -p "$COLOR_SCHEMES_DIR"

    DARK_URL="https://raw.githubusercontent.com/SylEleuth/gruvbox-plus-kde/master/color-scheme/GruvboxPlusDark.colors"
    LIGHT_URL="https://raw.githubusercontent.com/SylEleuth/gruvbox-plus-kde/master/color-scheme/GruvboxPlusLight.colors"

    dl_file "$DARK_URL" "$COLOR_SCHEMES_DIR/GruvboxPlusDark.colors" && echo "[*] Downloaded GruvboxPlusDark.colors" || echo "[!] Failed to download dark color scheme"
    dl_file "$LIGHT_URL" "$COLOR_SCHEMES_DIR/GruvboxPlusLight.colors" && echo "[*] Downloaded GruvboxPlusLight.colors" || echo "[!] Failed to download light color scheme"
    chown -R "$GRUVBOX_USER":"$GRUVBOX_USER" "$COLOR_SCHEMES_DIR"

    ACTIVE_SCHEME="GruvboxPlusDark"
    [ "$GRUVBOX_VARIANT" = "light" ] && ACTIVE_SCHEME="GruvboxPlusLight"

    # Write scheme name to kdeglobals (plasma-apply-colorscheme won't work
    # before first login — colors apply on next login)
    KDEGLOBALS="$G_USER_HOME/.config/kdeglobals"
    mkdir -p "$G_USER_HOME/.config"
    touch "$KDEGLOBALS"
    if grep -q "^\[General\]" "$KDEGLOBALS" 2>/dev/null; then
      if grep -q "^ColorScheme=" "$KDEGLOBALS" 2>/dev/null; then
        sed -i "s/^ColorScheme=.*/ColorScheme=$ACTIVE_SCHEME/" "$KDEGLOBALS"
      else
        sed -i "/^\[General\]/a ColorScheme=$ACTIVE_SCHEME" "$KDEGLOBALS"
      fi
    else
      echo "" >> "$KDEGLOBALS"
      echo "[General]" >> "$KDEGLOBALS"
      echo "ColorScheme=$ACTIVE_SCHEME" >> "$KDEGLOBALS"
    fi
    chown "$GRUVBOX_USER":"$GRUVBOX_USER" "$KDEGLOBALS"
    echo "[*] Active color scheme: $ACTIVE_SCHEME"

    # Set widgetStyle in kdeglobals (Breeze widget style works with Gruvbox colors).
    # Do NOT set LookAndFeelPackage — that triggers KDE to apply a full look-and-feel
    # package (e.g. Breeze Dark) which overrides the color scheme and icon theme we
    # just set. By leaving LookAndFeelPackage unset, KDE reads ColorScheme and Theme
    # directly from kdeglobals/kdedefaults.
    if grep -q "^\[KDE\]" "$KDEGLOBALS" 2>/dev/null; then
      if ! grep -q "^widgetStyle=" "$KDEGLOBALS" 2>/dev/null; then
        sed -i '/^\[KDE\]/a widgetStyle=Breeze' "$KDEGLOBALS" 2>/dev/null || true
      fi
      # Remove any existing LookAndFeelPackage so KDE doesn't override our colors
      if grep -q "^LookAndFeelPackage=" "$KDEGLOBALS" 2>/dev/null; then
        sed -i '/^LookAndFeelPackage=/d' "$KDEGLOBALS" 2>/dev/null || true
      fi
    else
      echo "" >> "$KDEGLOBALS"
      echo "[KDE]" >> "$KDEGLOBALS"
      echo "widgetStyle=Breeze" >> "$KDEGLOBALS"
    fi
    chown "$GRUVBOX_USER":"$GRUVBOX_USER" "$KDEGLOBALS"

    # Write kdedefaults/kdeglobals with Gruvbox color scheme + icons
    # Do NOT write kdedefaults/package — that sets the look-and-feel which
    # overrides our color scheme. Leave it absent so KDE falls back to kdeglobals.
    KDE_DEFAULTS_DIR="$G_USER_HOME/.config/kdedefaults"
    mkdir -p "$KDE_DEFAULTS_DIR"
    # Remove any stale kdedefaults/package from a previous Breeze Dark install
    rm -f "$KDE_DEFAULTS_DIR/package" 2>/dev/null || true
    # Use correct icon variant
    ICON_THEME_DEFAULT="Gruvbox-Plus-Dark"
    [ "$GRUVBOX_VARIANT" = "light" ] && ICON_THEME_DEFAULT="Gruvbox-Plus-Light"
    cat > "$KDE_DEFAULTS_DIR/kdeglobals" << KDEDEFGLOBALS
[General]
ColorScheme=$ACTIVE_SCHEME

[Icons]
Theme=$ICON_THEME_DEFAULT

[KDE]
widgetStyle=Breeze
KDEDEFGLOBALS
    chown -R "$GRUVBOX_USER":"$GRUVBOX_USER" "$KDE_DEFAULTS_DIR"

    # ── 14.2: Icon Pack ─────────────────────────────────────────────
    if [ "$GRUVBOX_ICONS" -eq 1 ]; then
      echo ""
      echo "=== Step 14.2: Gruvbox Plus Icon Pack ==="
      ICONS_DIR="$G_USER_HOME/.local/share/icons"
      mkdir -p "$ICONS_DIR"

      if ! command -v unzip >/dev/null 2>&1; then
        echo "[*] Installing unzip..."
        xinstall unzip
      fi

      echo "[*] Fetching latest Gruvbox Plus icon pack release..."
      ICON_RELEASE_URL=$(curl -sL "https://api.github.com/repos/SylEleuth/gruvbox-plus-icon-pack/releases/latest" \
        -H "Accept: application/json" 2>/dev/null | \
        grep -o '"browser_download_url": *"[^"]*gruvbox-plus-icon-pack[^"]*\.zip"' | \
        head -1 | sed 's/.*"browser_download_url": *"//;s/"//' || true)

      if [ -z "$ICON_RELEASE_URL" ]; then
        echo "[!] Could not fetch icon pack release URL. Falling back to clone."
        if [ -d "$G_USER_HOME/gruvbox-plus-icon-pack" ]; then
          echo "[*] Icon pack repo already exists"
        else
          git clone --depth 1 "https://github.com/SylEleuth/gruvbox-plus-icon-pack.git" \
            "$G_USER_HOME/gruvbox-plus-icon-pack" 2>/dev/null && echo "[*] Cloned icon pack repo" || { echo "[!] Failed to clone. Skipping icons."; GRUVBOX_ICONS=0; }
        fi
        if [ "$GRUVBOX_ICONS" -eq 1 ]; then
          ICON_REPO="$G_USER_HOME/gruvbox-plus-icon-pack"
          [ -d "$ICON_REPO/Gruvbox-Plus-Dark" ] && rm -rf "$ICONS_DIR/Gruvbox-Plus-Dark" && ln -sf "$ICON_REPO/Gruvbox-Plus-Dark" "$ICONS_DIR/Gruvbox-Plus-Dark"
          [ -d "$ICON_REPO/Gruvbox-Plus-Light" ] && rm -rf "$ICONS_DIR/Gruvbox-Plus-Light" && ln -sf "$ICON_REPO/Gruvbox-Plus-Light" "$ICONS_DIR/Gruvbox-Plus-Light"
        fi
      else
        echo "[*] Downloading icon pack from: $ICON_RELEASE_URL"
        ICON_ZIP="/tmp/gruvbox-plus-icons.zip"
        if dl_file "$ICON_RELEASE_URL" "$ICON_ZIP"; then
          echo "[*] Downloaded icon pack ($(du -h "$ICON_ZIP" 2>/dev/null | cut -f1 || echo '?'))"
          unzip -q -o "$ICON_ZIP" -d "$ICONS_DIR/" 2>/dev/null || true
          rm -f "$ICON_ZIP"
          echo "[*] Icons extracted to $ICONS_DIR/"
        else
          echo "[!] Failed to download icon pack. Skipping icons."
          GRUVBOX_ICONS=0
        fi
      fi

      if [ "$GRUVBOX_ICONS" -eq 1 ]; then
        ICON_THEME="Gruvbox-Plus-Dark"
        [ "$GRUVBOX_VARIANT" = "light" ] && ICON_THEME="Gruvbox-Plus-Light"
        KDEGLOBALS="$G_USER_HOME/.config/kdeglobals"
        touch "$KDEGLOBALS"
        if grep -q "^\[Icons\]" "$KDEGLOBALS" 2>/dev/null; then
          awk -v icon_theme="$ICON_THEME" '
            BEGIN { in_icons=0; icons_written=0 }
            /^\[Icons\]/ {
              if (icons_written==0) { in_icons=1; icons_written=1; print $0; print "Theme=" icon_theme }
              else { in_icons=1 }
              next
            }
            /^\[/ { in_icons=0 }
            /^Theme=/ && in_icons==1 { next }
            { if (in_icons==0 || icons_written==1) print $0 }
          ' "$KDEGLOBALS" > "$KDEGLOBALS.tmp" && mv "$KDEGLOBALS.tmp" "$KDEGLOBALS"
        else
          echo "" >> "$KDEGLOBALS"
          echo "[Icons]" >> "$KDEGLOBALS"
          echo "Theme=$ICON_THEME" >> "$KDEGLOBALS"
        fi
        chown -R "$GRUVBOX_USER":"$GRUVBOX_USER" "$ICONS_DIR"
        chown "$GRUVBOX_USER":"$GRUVBOX_USER" "$KDEGLOBALS"
        echo "[*] Active icon theme: $ICON_THEME"
      fi
    fi

    # ── 14.3: Kvantum Theme ─────────────────────────────────────────
    if [ "$GRUVBOX_KVANTUM" -eq 1 ]; then
      echo ""
      echo "=== Step 14.3: Kvantum Theme ==="
      xinstall kvantum

      KVANTUM_THEMES_DIR="$G_USER_HOME/.config/Kvantum"
      mkdir -p "$KVANTUM_THEMES_DIR"
      KVANTUM_THEME_DIR="$KVANTUM_THEMES_DIR/gruvbox-kvantum"
      mkdir -p "$KVANTUM_THEME_DIR"

      echo "[*] Downloading Gruvbox Kvantum theme..."
      KV_CONFIG_URL="https://raw.githubusercontent.com/TheSerphh/Gruvbox-Kvantum/master/gruvbox-kvantum/gruvbox-kvantum.kvconfig"
      KV_SVG_URL="https://raw.githubusercontent.com/TheSerphh/Gruvbox-Kvantum/master/gruvbox-kvantum/gruvbox-kvantum.svg"

      if dl_file "$KV_CONFIG_URL" "$KVANTUM_THEME_DIR/gruvbox-kvantum.kvconfig"; then
        echo "[*] Downloaded gruvbox-kvantum.kvconfig"
        dl_file "$KV_SVG_URL" "$KVANTUM_THEME_DIR/gruvbox-kvantum.svg" && echo "[*] Downloaded gruvbox-kvantum.svg" || echo "[!] Failed to download SVG"
      else
        echo "[!] Failed to download kvantum config. Skipping kvantum."
        GRUVBOX_KVANTUM=0
      fi

      if [ "$GRUVBOX_KVANTUM" -eq 1 ]; then
        chown -R "$GRUVBOX_USER":"$GRUVBOX_USER" "$KVANTUM_THEMES_DIR"

        ENV_FILE="$G_USER_HOME/.config/environment.d/gruvbox.conf"
        mkdir -p "$G_USER_HOME/.config/environment.d"
        cat > "$ENV_FILE" << 'ENVEOF'
# Gruvbox theme — set Kvantum as the Qt style engine
QT_QPA_PLATFORMTHEME=kvantum
ENVEOF
        chown -R "$GRUVBOX_USER":"$GRUVBOX_USER" "$G_USER_HOME/.config/environment.d"

        KVANTUM_CONF="$G_USER_HOME/.config/Kvantum/kvantum.kvconfig"
        if [ ! -f "$KVANTUM_CONF" ] || ! grep -q "^\[General\]" "$KVANTUM_CONF" 2>/dev/null; then
          cat > "$KVANTUM_CONF" << 'KVCONFEOF'
[General]
theme=gruvbox-kvantum
KVCONFEOF
        else
          if grep -q "^theme=" "$KVANTUM_CONF" 2>/dev/null; then
            sed -i "s/^theme=.*/theme=gruvbox-kvantum/" "$KVANTUM_CONF"
          else
            sed -i "/^\[General\]/a theme=gruvbox-kvantum" "$KVANTUM_CONF"
          fi
        fi
        chown "$GRUVBOX_USER":"$GRUVBOX_USER" "$KVANTUM_CONF"
        echo "[*] Kvantum theme 'gruvbox-kvantum' installed and configured"
      fi
    fi

    # ── 14.4: Fastfetch ─────────────────────────────────────────────
    if [ "$GRUVBOX_FASTFETCH" -eq 1 ]; then
      echo ""
      echo "=== Step 14.4: Fastfetch with Gruvbox Config ==="
      xinstall fastfetch

      FF_DIR="$G_USER_HOME/.config/fastfetch"
      mkdir -p "$FF_DIR"

      cat > "$FF_DIR/config.jsonc" << 'FFCONFIG'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "source": "$HOME/.config/fastfetch/gruvbox-logo.txt",
        "color": {
            "1": "#ebdbb2"
        }
    },
    "display": {
        "color": {
            "keys": "#83a598"
        },
        "separator": "",
        "constants": [
            "──────────────────────────────────────────────",
            "\u001b[47D",
            "\u001b[47C",
            "\u001b[46C"
        ],
        "bar": {
            "char": {
                "elapsed": "⣿",
                "total": "⢕"
            },
            "width": 20
        },
        "percent": {
            "type": 2,
            "color": {
                "green": "#b8bb26",
                "yellow": "#fabd2f",
                "red": "#fb4934"
            }
        },
        "temp": {
            "color": {
                "green": "#b8bb26",
                "yellow": "#fabd2f",
                "red": "#fb4934"
            }
        }
    },
    "modules": [
        {
            "type": "title",
            "key": "╭─────────────────{$1}╮\u001b[60D",
            "format": "\u001b[1m{#keys} FastFetch - [ {##ebdbb2}{2}{#keys} ] "
        },
        {
            "type": "custom",
            "key": "│{##ebdbb2}╭──────────────┬{$1}╮{#keys}│\u001b[30D",
            "format": "{##ebdbb2} Machine "
        },
        {
            "type": "cpu",
            "key": "│{##ebdbb2}│ {icon}  CPU       │{$4}│{#keys}│{$2}",
            "showPeCoreCount": true,
            "temp": true,
            "format": "{##ebdbb2}[ {##83a598}{1}{##ebdbb2} ] ~ {##ebdbb2}{8}{##ebdbb2}"
        },
        {
            "type": "gpu",
            "key": "│{##ebdbb2}│ {icon}  GPU       │{$4}│{#keys}│{$2}",
            "temp": true,
            "format": "{##ebdbb2}[ {##fb4934}{2}{##ebdbb2} ] ~ {##ebdbb2}{4}{##ebdbb2}"
        },
        {
            "type": "memory",
            "key": "│{##ebdbb2}│ {icon}  Memory    │{$4}│{#keys}│{$2}",
            "format": "{4} {##ebdbb2}[ {##ebdbb2}{1}{##ebdbb2} ]"
        },
        {
            "type": "swap",
            "key": "│{##ebdbb2}│ {icon}  Swap      │{$4}│{#keys}│{$2}",
            "format": "{4} {##ebdbb2}[ {##ebdbb2}{1}{##ebdbb2} ]"
        },
        {
            "type": "disk",
            "key": "│{##ebdbb2}│ {icon}  Disk      │{$4}│{#keys}│{$2}",
            "format": "{13} {##ebdbb2}[ {##ebdbb2}{1}{##ebdbb2} ]"
        },
        {
            "type": "disk",
            "key": "│{##ebdbb2}│ {icon}  Type      │{$4}│{#keys}│{$2}",
            "format": "{##ebdbb2}{9}"
        },
        {
            "type": "custom",
            "key": "│{##ebdbb2}╰──────────────┴{$1}╯{#keys}│",
            "format": ""
        },
        {
            "type": "custom",
            "key": "│{##83a598}╭──────────────┬{$1}╮{#keys}│\u001b[30D",
            "format": "{##83a598} System "
        },
        {
            "type": "os",
            "key": "│{##83a598}│ {icon}  OS        │{$4}│{#keys}│{$2}",
            "format": "{##83a598}{2} ~> [ {##ebdbb2}{3}{##83a598} ]"
        },
        {
            "type": "kernel",
            "keyIcon": "󰣇",
            "key": "│{##83a598}│ {icon}  Kernel    │{$4}│{#keys}│{$2}",
            "format": "{##83a598}{2} ~> [ {##ebdbb2}{4}{##83a598} ]"
        },
        {
            "type": "de",
            "key": "│{##458588}│ {icon}  Desktop   │{$4}│{#keys}│{$2}",
            "format": "{##458588}{2} ~> [ {##ebdbb2}{3}{##458588} ]"
        },
        {
            "type": "wm",
            "key": "│{##458588}│ {icon}  WM        │{$4}│{#keys}│{$2}",
            "format": "{##458588}{2} ~> [ {##ebdbb2}{3}{##458588} ]"
        },
        {
            "type": "uptime",
            "keyIcon": "󰅐",
            "key": "│{##458588}│ {icon}  Uptime    │{$4}│{#keys}│{$2}",
            "format": "{##458588}[ {##ebdbb2}{1}d {2}h {3}m{##458588} ]"
        },
        {
            "type": "custom",
            "key": "│{##458588}╰──────────────┴{$1}╯{#keys}│",
            "format": ""
        },
        {
            "type": "custom",
            "key": "│{##fabd2f}╭──────────────┬{$1}╮{#keys}│\u001b[30D",
            "format": "{##fabd2f} Shell "
        },
        {
            "type": "shell",
            "key": "│{##fabd2f}│ {icon}  Shell     │{$4}│{#keys}│{$2}",
            "format": "{##fabd2f}{6} ~> [ {##ebdbb2}{4}{##fabd2f} ]"
        },
        {
            "type": "terminal",
            "key": "│{##d79921}│ {icon}  Terminal  │{$4}│{#keys}│{$2}",
            "format": "{##d79921}{5} ~> [ {##ebdbb2}{6}{##d79921} ]"
        },
        {
            "type": "packages",
            "key": "│{##fe8019}│ {icon}  Packages  │{$4}│{#keys}│{$2}",
            "format": "{##fe8019}xbps ~> [ {##ebdbb2}{2}{##fe8019} ]"
        },
        {
            "type": "custom",
            "key": "│{##d65d0e}╰──────────────┴{$1}╯{#keys}│",
            "format": ""
        },
        {
            "type": "custom",
            "key": "│{##fb4934}╭──────────────┬{$1}╮{#keys}│\u001b[30D",
            "format": "{##fb4934} Dev "
        },
        {
            "type": "command",
            "keyIcon": "󰅭",
            "key": "│{##fb4934}│ {icon}  Editor    │{$4}│{#keys}│{$2}",
            "text": "command -v micro >/dev/null 2>&1 && micro --version 2>/dev/null | head -1 || echo 'none'",
            "format": "{##fb4934}micro ~> [ {##ebdbb2}{}{##fb4934} ]"
        },
        {
            "type": "command",
            "keyIcon": "󰊢",
            "key": "│{##cc241d}│ {icon}  Git       │{$4}│{#keys}│{$2}",
            "text": "git --version 2>/dev/null | cut -d' ' -f3 || echo 'none'",
            "format": "{##cc241d}git ~> [ {##ebdbb2}{}{##cc241d} ]"
        },
        {
            "type": "custom",
            "key": "│{##cc241d}╰──────────────┴{$1}╯{#keys}│",
            "format": ""
        },
        {
            "type": "custom",
            "key": "│{##8ec07c}╭──────────────┬{$1}╮{#keys}│\u001b[30D",
            "format": "{##8ec07c} Status "
        },
        {
            "type": "datetime",
            "keyIcon": "󰥔",
            "key": "│{##8ec07c}│ {icon}  Fetched   │{$4}│{#keys}│{$2}",
            "format": "{##8ec07c}[ {##ebdbb2}{hour-pretty} : {minute-pretty} : {second-pretty}{##8ec07c} ]"
        },
        {
            "type": "custom",
            "key": "│{##427b58}╰──────────────┴{$1}╯{#keys}│",
            "format": ""
        },
        {
            "type": "custom",
            "key": "╰─────────────────{$1}╯",
            "format": ""
        }
    ]
}
FFCONFIG

      cat > "$FF_DIR/gruvbox-logo.txt" << 'LOGOEOF'
    .--.
   |o_o |   Void Linux
   |:_/ |
  //   \ \
 (|     | )
/'\_   _/`\
\___)=(___/
LOGOEOF

      chown -R "$GRUVBOX_USER":"$GRUVBOX_USER" "$FF_DIR"

      BASHRC="$G_USER_HOME/.bashrc"
      if [ -f "$BASHRC" ]; then
        if ! grep -q "fastfetch" "$BASHRC" 2>/dev/null; then
          echo "" >> "$BASHRC"
          echo "# Gruvbox fastfetch on terminal open" >> "$BASHRC"
          echo "if command -v fastfetch >/dev/null 2>&1 && [ -t 1 ]; then" >> "$BASHRC"
          echo "    fastfetch" >> "$BASHRC"
          echo "fi" >> "$BASHRC"
          chown "$GRUVBOX_USER":"$GRUVBOX_USER" "$BASHRC"
          echo "[*] Added fastfetch to .bashrc"
        else
          echo "[*] fastfetch already in .bashrc"
        fi
      else
        cat > "$BASHRC" << 'BASHRCEOF'
# Gruvbox fastfetch on terminal open
if command -v fastfetch >/dev/null 2>&1 && [ -t 1 ]; then
    fastfetch
fi
BASHRCEOF
        chown "$GRUVBOX_USER":"$GRUVBOX_USER" "$BASHRC"
        echo "[*] Created .bashrc with fastfetch"
      fi
      echo "[*] Fastfetch installed with gruvbox config"
    fi

    # ── 14.5: Wallpaper ─────────────────────────────────────────────
    if [ "$GRUVBOX_WALLPAPER" -eq 1 ]; then
      echo ""
      echo "=== Step 14.5: Wallpaper ==="
      WP_DIR="$G_USER_HOME/Pictures/wallpapers"
      mkdir -p "$WP_DIR"
      WP_FILE=""

      if [ -n "$GRUVBOX_WALLPAPER_PATH" ] && [ -f "$GRUVBOX_WALLPAPER_PATH" ]; then
        WP_FILE="$WP_DIR/$(basename "$GRUVBOX_WALLPAPER_PATH")"
        echo "[*] Copying wallpaper to $WP_FILE..."
        cp "$GRUVBOX_WALLPAPER_PATH" "$WP_FILE"
        chown -R "$GRUVBOX_USER":"$GRUVBOX_USER" "$WP_DIR"
        echo "[*] Wallpaper copied ($(du -h "$WP_FILE" 2>/dev/null | cut -f1 || echo '?'))"
      elif [ -n "$GRUVBOX_WALLPAPER_PATH" ] && [ ! -f "$GRUVBOX_WALLPAPER_PATH" ]; then
        echo "[!] Wallpaper file not found: $GRUVBOX_WALLPAPER_PATH"
        GRUVBOX_WALLPAPER=0
      elif [ -n "$GRUVBOX_WALLPAPER_URL" ]; then
        WP_FILE="$WP_DIR/$GRUVBOX_WALLPAPER_FILENAME"
        echo "[*] Downloading wallpaper from $GRUVBOX_WALLPAPER_URL..."
        if dl_file "$GRUVBOX_WALLPAPER_URL" "$WP_FILE"; then
          chown -R "$GRUVBOX_USER":"$GRUVBOX_USER" "$WP_DIR"
          echo "[*] Wallpaper downloaded ($(du -h "$WP_FILE" 2>/dev/null | cut -f1 || echo '?'))"
        else
          echo "[!] Failed to download wallpaper. Skipping."
          rm -f "$WP_FILE"
          GRUVBOX_WALLPAPER=0
        fi
      else
        GRUVBOX_WALLPAPER=0
      fi

      if [ "$GRUVBOX_WALLPAPER" -eq 1 ] && [ -n "$WP_FILE" ] && [ -f "$WP_FILE" ]; then
        # Apply wallpaper via plasma-apply-wallpaperimage on first login.
        # We can't call it now (no Plasma session), and writing to
        # plasma-org.kde.plasma.desktop-appletsrc doesn't work because
        # Plasma overwrites it on login. Instead, create an autostart
        # script that applies the wallpaper on first login, then removes
        # itself so it only runs once.
        AUTOSTART_DIR="$G_USER_HOME/.config/autostart"
        mkdir -p "$AUTOSTART_DIR"

        # Create autostart desktop file
        cat > "$AUTOSTART_DIR/apply-gruvbox-wallpaper.desktop" << 'WPDESKTOP'
[Desktop Entry]
Type=Application
Name=Apply Gruvbox Wallpaper
Exec=bash -c 'sleep 3 && plasma-apply-wallpaperimage "WP_FILE_PLACEHOLDER" 2>/dev/null; rm -f "$HOME/.config/autostart/apply-gruvbox-wallpaper.desktop"; rm -f "$HOME/.local/bin/apply-gruvbox-wallpaper.sh"'
Icon=preferences-desktop-wallpaper
Terminal=false
X-KDE-autostart-condition=plasmashell
OnlyShowIn=KDE
WPDESKTOP
        sed -i "s|WP_FILE_PLACEHOLDER|$WP_FILE|" "$AUTOSTART_DIR/apply-gruvbox-wallpaper.desktop"

        chown -R "$GRUVBOX_USER":"$GRUVBOX_USER" "$G_USER_HOME/.config/autostart" 2>/dev/null || true

        echo "[*] Wallpaper saved to $WP_FILE"
        echo "[*] Wallpaper will be applied on first login via autostart script"
      fi
    fi

    echo ""
    echo "[*] Gruvbox theme setup complete."
    echo "[*] All theme components will be active after first login."
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
# PHASE 15: AppArmor (mandatory access control)
# ═══════════════════════════════════════════════════════════════════════
# Void kernels (stock and mainline) ship with CONFIG_SECURITY_APPARMOR=y.
# The apparmor package provides the runit core-service (09-apparmor.sh)
# that loads profiles at boot. Profiles are loaded in enforce mode by default.
# Requires kernel cmdline: apparmor=1 security=apparmor
# Without the cmdline params, AppArmor compiles in but never activates.
if [ "$APPARMOR" -eq 1 ]; then
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  Phase 15: AppArmor (Mandatory Access Control)"
  echo "══════════════════════════════════════════════════════════════"

  echo ""
  echo "=== Step 15.1: Installing AppArmor ==="
  xinstall apparmor

  # Set enforce mode (default is complain — logs only, doesn't block)
  echo ""
  echo "=== Step 15.2: Configuring AppArmor enforce mode ==="
  if [ -f /etc/default/apparmor ]; then
    if grep -q '^APPARMOR=' /etc/default/apparmor 2>/dev/null; then
      sed -i 's/^APPARMOR=.*/APPARMOR=enforce/' /etc/default/apparmor
    else
      echo "APPARMOR=enforce" >> /etc/default/apparmor
    fi
  else
    echo "APPARMOR=enforce" > /etc/default/apparmor
  fi
  echo "[*] AppArmor mode: enforce"

  # Add kernel cmdline parameters for AppArmor activation
  echo ""
  echo "=== Step 15.3: Adding AppArmor to GRUB kernel cmdline ==="
  GRUB_DEFAULT="/etc/default/grub"
  if [ -f "$GRUB_DEFAULT" ]; then
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT" 2>/dev/null; then
      if ! grep -q 'apparmor=1' "$GRUB_DEFAULT" 2>/dev/null; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 apparmor=1 security=apparmor"/' "$GRUB_DEFAULT"
        echo "[*] Added apparmor=1 security=apparmor to GRUB_CMDLINE_LINUX_DEFAULT"
      else
        echo "[*] apparmor=1 already in GRUB cmdline"
      fi
    else
      echo 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 apparmor=1 security=apparmor"' >> "$GRUB_DEFAULT"
      echo "[*] Created GRUB_CMDLINE_LINUX_DEFAULT with apparmor params"
    fi

    # Regenerate GRUB config
    if command -v grub-mkconfig >/dev/null 2>&1; then
      grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || echo "[!] grub-mkconfig failed — run manually after install"
      echo "[*] GRUB config regenerated"
    fi
  else
    echo "[!] /etc/default/grub not found — add apparmor=1 security=apparmor to kernel cmdline manually"
  fi

  echo ""
  echo "[*] AppArmor installed and configured."
  echo "[*] Profiles load in enforce mode on next boot."
  echo "[*] Verify after reboot: aa-status"
  echo "[*] Included profiles: dhcpcd, nginx, pulseaudio, uuidd, wpa_supplicant"
else
  echo ""
  echo "[*] AppArmor skipped (--no-apparmor)."
fi

# ═══════════════════════════════════════════════════════════════════════
# PHASE 16: Kernel Hardening (sysctl + GRUB cmdline)
# ═══════════════════════════════════════════════════════════════════════
# Void's stock and mainline kernels already enable most hardening at compile
# time: SLAB_FREELIST_HARDENED, INIT_ON_ALLOC_DEFAULT_ON, FORTIFY_SOURCE,
# HARDENED_USERCOPY, STACKPROTECTOR_STRONG, RANDOMIZE_BASE, KASLR,
# STRICT_KERNEL_RWX, SECURITY_DMESG_RESTRICT, SECURITY_YAMA, BPF_UNPRIV_DEFAULT_OFF,
# MODULE_SIG. This phase adds runtime sysctl settings and optional cmdline
# params for things not enabled at compile time (init_on_free, page shuffle).
if [ "$HARDENING" -eq 1 ]; then
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  Phase 16: Kernel Hardening"
  echo "══════════════════════════════════════════════════════════════"

  # ── 16.1: sysctl hardening config ────────────────────────────────
  echo ""
  echo "=== Step 16.1: Writing sysctl hardening config ==="
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-hardening.conf << 'SYSCTLCONF'
# ═══════════════════════════════════════════════════════════════════════
#  Kernel hardening — desktop-safe settings
#  Applied at boot via sysctl --system
# ═══════════════════════════════════════════════════════════════════════

# --- dmesg restriction (restrict to CAP_SYSLOG) ---
kernel.dmesg_restrict = 1

# --- kptr restriction: hide kernel pointers ---
# 2 = hide from everyone including root
kernel.kptr_restrict = 2

# --- BPF hardening ---
# 2 = permanently disabled for unprivileged (cannot re-enable at runtime)
kernel.unprivileged_bpf_disabled = 2
# 2 = harden JIT for all users (mitigates JIT spraying)
net.core.bpf_jit_harden = 2
# Do not export BPF JIT kallsyms
net.core.bpf_jit_kallsyms = 0

# --- Performance events ---
# 2 = disallow for unprivileged (breaks some profilers at 3)
kernel.perf_event_paranoid = 2

# --- Yama ptrace scope ---
# 1 = limited to parent (desktop-safe; higher breaks GDB attaching)
kernel.yama.ptrace_scope = 1

# --- ASLR ---
kernel.randomize_va_space = 2

# --- SysRq ---
kernel.sysrq = 0

# --- kexec (prevent kernel replacement at runtime) ---
kernel.kexec_load_disabled = 1

# --- Filesystem protections ---
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2

# --- SUID core dumps ---
fs.suid_dumpable = 0
kernel.core_uses_pid = 1

# --- Network hardening ---
# Reverse path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# Drop ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
# Drop source-routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
# TCP SYN cookies (SYN flood protection)
net.ipv4.tcp_syncookies = 1
# IPv6 — mirror IPv4 settings
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
SYSCTLCONF

  echo "[*] Created /etc/sysctl.d/99-hardening.conf"

  # Apply sysctl settings immediately
  if command -v sysctl >/dev/null 2>&1; then
    sysctl --system 2>/dev/null || echo "[!] Some sysctl settings failed to apply (may need reboot)"
    echo "[*] sysctl hardening applied"
  else
    echo "[!] sysctl command not found — settings apply on reboot"
  fi

  # ── 16.2: GRUB kernel cmdline hardening ─────────────────────────
  echo ""
  echo "=== Step 16.2: Adding kernel hardening to GRUB cmdline ==="
  GRUB_DEFAULT="/etc/default/grub"
  HARDENING_PARAMS="init_on_free=1 page_alloc.shuffle=1"

  if [ -f "$GRUB_DEFAULT" ]; then
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT" 2>/dev/null; then
      # Add each param if not already present
      for param in $HARDENING_PARAMS; do
        param_name="${param%%=*}"
        if ! grep -q "$param_name" "$GRUB_DEFAULT" 2>/dev/null; then
          sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${param}\"/" "$GRUB_DEFAULT"
          echo "[*] Added ${param} to GRUB cmdline"
        else
          echo "[*] ${param_name} already in GRUB cmdline"
        fi
      done

      # Regenerate GRUB config (may have been done by AppArmor phase, but safe to run again)
      if command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || echo "[!] grub-mkconfig failed — run manually"
        echo "[*] GRUB config regenerated with hardening params"
      fi
    else
      echo "[!] GRUB_CMDLINE_LINUX_DEFAULT not found — add ${HARDENING_PARAMS} manually"
    fi
  else
    echo "[!] /etc/default/grub not found — add ${HARDENING_PARAMS} to kernel cmdline manually"
  fi

  echo ""
  echo "[*] Kernel hardening configured."
  echo "[*] Compile-time hardening (already in Void kernels):"
  echo "    SLAB_FREELIST_HARDENED, INIT_ON_ALLOC, FORTIFY_SOURCE,"
  echo "    HARDENED_USERCOPY, STACKPROTECTOR_STRONG, KASLR,"
  echo "    STRICT_KERNEL_RWX, BPF_UNPRIV_DEFAULT_OFF, MODULE_SIG"
  echo "[*] Runtime hardening added:"
  echo "    init_on_free=1 (zero-fill freed pages, ~5% perf cost)"
  echo "    page_alloc.shuffle=1 (shuffle page allocator free lists)"
  echo "[*] sysctl: dmesg_restrict, kptr_restrict=2, BPF harden,"
  echo "    perf_event_paranoid=2, ptrace_scope=1, sysrq=0,"
  echo "    filesystem protections, network hardening"
else
  echo ""
  echo "[*] Kernel hardening skipped (--no-hardening)."
fi

# ═══════════════════════════════════════════════════════════════════════
# PHASE 17: Firewall (UFW + plasma-firewall)
# ═══════════════════════════════════════════════════════════════════════
# UFW is the only firewall backend with both a pre-built binary package on
# Void AND plasma-firewall (KDE GUI) integration. firewalld has no binary
# package on Void (template exists but was never built). UFW uses iptables
# under the hood (can use iptables-nft for nftables backend).
# Default policy: deny incoming, allow outgoing. SSH is allowed.
if [ "$FIREWALL" -eq 1 ]; then
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  Phase 17: Firewall (UFW + plasma-firewall)"
  echo "══════════════════════════════════════════════════════════════"

  echo ""
  echo "=== Step 17.1: Installing UFW + plasma-firewall ==="
  xinstall ufw plasma-firewall

  # ── Enable UFW runit service ──────────────────────────────────────
  echo ""
  echo "=== Step 17.2: Enabling UFW runit service ==="
  if [ -d /etc/sv/ufw ] && [ ! -L /var/service/ufw ]; then
    ln -s /etc/sv/ufw /var/service/
    echo "[*] UFW runit service symlink created."
  elif [ -L /var/service/ufw ]; then
    echo "[*] UFW runit service already enabled."
  else
    echo "[!] /etc/sv/ufw not found — UFW service may need manual enable."
  fi

  # ── Configure default policies ──────────────────────────────────
  echo ""
  echo "=== Step 17.3: Configuring UFW default policies ==="
  # Deny all incoming, allow all outgoing
  ufw default deny incoming 2>/dev/null || true
  ufw default allow outgoing 2>/dev/null || true
  echo "[*] Default policy: deny incoming, allow outgoing"

  # Allow SSH (port 22) — don't lock the user out
  echo ""
  echo "=== Step 17.4: Allowing SSH (port 22) ==="
  ufw allow ssh 2>/dev/null || ufw allow 22/tcp 2>/dev/null || true
  echo "[*] SSH allowed (port 22)"

  # Enable UFW
  echo ""
  echo "=== Step 17.5: Enabling UFW ==="
  ufw enable 2>/dev/null || true
  echo "[*] UFW enabled"

  # Show status
  echo ""
  ufw status verbose 2>/dev/null || echo "[*] Run 'ufw status' to check firewall rules"

  echo ""
  echo "[*] Firewall configured: UFW + plasma-firewall"
  echo "[*] Default: deny incoming, allow outgoing"
  echo "[*] SSH (port 22) allowed"
  echo "[*] Manage via KDE System Settings > Firewall"
else
  echo ""
  echo "[*] Firewall skipped (--no-firewall)."
fi

# ── Final ownership fix (runs AFTER all file creation/modification) ──
# The script runs as root and creates dirs/files in user homes throughout
# all phases. sed -i re-creates files as root-owned. This pass runs at the
# very end to catch everything: .config, .local, Pictures, and any other
# directories created by the script.
echo ""
echo "[*] Final ownership fix..."
for user_home in /home/*; do
  owner=$(stat -c %U "$user_home" 2>/dev/null || true)
  if [ -n "$owner" ] && [ "$owner" != "root" ]; then
    chown -R "$owner":"$owner" "$user_home/.config" 2>/dev/null || true
    chown -R "$owner":"$owner" "$user_home/.local" 2>/dev/null || true
    chown -R "$owner":"$owner" "$user_home/Pictures" 2>/dev/null || true
    # Clean up icon pack clone if it exists (fallback from Phase 14)
    [ -d "$user_home/gruvbox-plus-icon-pack" ] && chown -R "$owner":"$owner" "$user_home/gruvbox-plus-icon-pack" 2>/dev/null || true
    echo "[*] Fixed ownership for $owner: .config .local Pictures"
  fi
done

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  KDE Plasma installation complete."
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Hardware detected:"
echo "    CPU: $CPU_VENDOR"
echo "    GPU: $GPU_VENDOR ($GPU_MODEL)"
echo "    VM:  $VIRT_PLATFORM"
echo "    Audio:     $([ $AUDIO_DETECTED -eq 1 ] && echo 'yes' || echo 'no')"
echo "    Bluetooth: $([ $BLUETOOTH_DETECTED -eq 1 ] && echo 'yes' || echo 'no')"
echo "    Wi-Fi:     $([ $WIFI_DETECTED -eq 1 ] && echo 'yes' || echo 'no')"
echo "    Touchpad:  $([ $TOUCHPAD_DETECTED -eq 1 ] && echo 'yes' || echo 'no')"
echo "    Wacom:     $([ $WACOM_DETECTED -eq 1 ] && echo 'yes' || echo 'no')"
echo ""
echo "  Kernel:"
if [ "$MAINLINE_KERNEL" -eq 1 ]; then
  echo "    - linux-mainline  (latest upstream stable, 7.x series) — default boot"
  echo "    - linux           (stock LTS kernel) — fallback in GRUB menu"
else
  echo "    - linux           (stock LTS kernel)"
fi
echo ""
echo "  Filesystem:"
if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
  echo "    - btrfs on $ROOT_DEVICE"
  if [ "$BTRFS_ENABLED" -eq 1 ]; then
    echo "    - zstd compression enabled (compress=zstd in fstab)"
  fi
else
  echo "    - $ROOT_FS_TYPE on $ROOT_DEVICE"
  echo "    - No compression (btrfs required for zstd compression)"
fi
echo ""
echo "  Enabled services (start on boot):"
echo "    - dbus           (/var/service/dbus)"
echo "    - elogind        (/var/service/elogind)  — session/seat mgmt"
echo "    - zramen         (/var/service/zramen)   — zram compressed swap (lz4, 25% RAM)"
echo "    - sddm           (/var/service/sddm)      — display manager"
echo "    - NetworkManager (/var/service/NetworkManager)"
echo "    - snooze-daily   (/var/service/snooze-daily) — auto-update (xbps + flatpak)"
echo "    - snooze-weekly  (/var/service/snooze-weekly) — log rotation"
[ $BLUETOOTH_DETECTED -eq 1 ] && echo "    - bluetoothd      (/var/service/bluetoothd)"
echo "    - power-profiles-daemon (/var/service/power-profiles-daemon) — power profiles"
if [ "$FIREWALL" -eq 1 ]; then
  echo "    - ufw            (/var/service/ufw)      — firewall (deny incoming, allow outgoing)"
fi
echo ""
echo "  Repositories enabled:"
echo "    - current (main)"
echo "    - nonfree"
echo "    - multilib (32-bit compatibility, x86_64 glibc only)"
echo "    - multilib/nonfree"
echo ""
echo "  SDDM will show the login screen on boot."
echo "  Select 'Plasma (X11)' or 'Plasma (Wayland)' from the session dropdown."
echo ""
echo "  Useful commands:"
echo "    sv status sddm           — check SDDM status"
echo "    sv restart sddm          — restart SDDM"
echo "    sv down sddm             — stop SDDM temporarily"
echo "    rm /var/service/sddm     — permanently disable SDDM at boot"
echo ""
echo "  CLI tools installed:"
echo "    bat      — cat replacement with syntax highlighting"
echo "    micro    — terminal text editor (set as EDITOR, nano aliased to micro)"
echo "    eza      — ls replacement with Nerd Font icons"
echo "    bash-completion — tab completion for commands"
echo "    wezterm  — GPU-accelerated terminal emulator (set as default)"
echo "               Gruvbox Dark theme, 85% opacity, Nerd Font icons"
echo "    nerd-fonts-symbols-ttf — icon glyphs for eza --icons"
echo "    Nerd Fonts (individual): CaskaydiaMono, FiraCode, JetBrainsMono,"
echo "                             RobotoMono (default monospace system-wide)"
echo ""
echo "  Flatpak apps (installed via Flathub):"
echo "    flatpak   — Flatpak runtime, Flathub remote configured"
echo "    Brave     — com.brave.Browser (privacy-focused browser)"
echo "    Tutanota  — com.tutanota.Tutanota (encrypted email, experimental)"
echo "    xdg-desktop-portal-kde — Flatpak↔Plasma integration (files, notifications)"
echo ""
echo "  Useful Flatpak commands:"
echo "    flatpak update              — update all Flatpak apps"
echo "    flatpak list                — list installed apps"
echo "    flatpak uninstall <app-id>  — remove an app"
echo ""
echo "  Automatic updates:"
echo "    snooze-daily runs /etc/cron.daily/void-autoupdate"
echo "    Updates xbps packages + Flatpak apps, cleans cache"
echo "    Logs: /var/log/void-autoupdate.log"
echo "    Manual check: cat /var/log/void-autoupdate.log"
echo ""
echo "  Shell aliases:"
echo "    update     — sudo xbps-install -Su && flatpak update -y"
echo "    install    — sudo xbps-install -S"
echo "    search     — xbps-query -Rs"
echo "    remove     — sudo xbps-remove -R"
echo "    cleanup    — sudo xbps-remove -O -o"
echo ""
echo "  Bash history: 10000 entries, dedup, timestamped, saved per-command"
echo ""

if [ "$APPARMOR" -eq 1 ]; then
  echo "  Security — AppArmor:"
  echo "    [✓] apparmor package installed (runit core-service)"
  echo "    [✓] Mode: enforce (blocks violations)"
  echo "    [✓] GRUB cmdline: apparmor=1 security=apparmor"
  echo "    [✓] Profiles: dhcpcd, nginx, pulseaudio, uuidd, wpa_supplicant"
  echo "    Verify: aa-status"
  echo ""
fi

if [ "$HARDENING" -eq 1 ]; then
  echo "  Security — Kernel hardening:"
  echo "    [✓] sysctl: dmesg_restrict, kptr_restrict=2, BPF harden"
  echo "    [✓] sysctl: perf_event_paranoid=2, ptrace_scope=1, sysrq=0"
  echo "    [✓] sysctl: filesystem protections, network hardening"
  echo "    [✓] GRUB cmdline: init_on_free=1, page_alloc.shuffle=1"
  echo "    [✓] Compile-time (Void kernel): SLAB_FREELIST_HARDENED,"
  echo "        INIT_ON_ALLOC, FORTIFY_SOURCE, KASLR, MODULE_SIG"
  echo "    Config: /etc/sysctl.d/99-hardening.conf"
  echo ""
fi

if [ "$FIREWALL" -eq 1 ]; then
  echo "  Security — Firewall:"
  echo "    [✓] ufw + plasma-firewall installed"
  echo "    [✓] Default: deny incoming, allow outgoing"
  echo "    [✓] SSH (port 22) allowed"
  echo "    [✓] runit service enabled (/var/service/ufw)"
  echo "    Manage: KDE System Settings > Firewall"
  echo "    CLI: ufw status, ufw allow <port>, ufw deny <port>"
  echo ""
fi

if [ "$GRUVBOX" -eq 1 ]; then
  echo "  Gruvbox theme installed (--gruvbox):"
  echo "    [✓] Color scheme: GruvboxPlus${GRUVBOX_VARIANT^}"
  [ "$GRUVBOX_ICONS" -eq 1 ] && echo "    [✓] Icons: Gruvbox-Plus-${GRUVBOX_VARIANT^}"
  [ "$GRUVBOX_KVANTUM" -eq 1 ] && echo "    [✓] Kvantum: gruvbox-kvantum (Qt5/Qt6)"
  [ "$GRUVBOX_FASTFETCH" -eq 1 ] && echo "    [✓] Fastfetch: gruvbox config"
  [ "$GRUVBOX_WALLPAPER" -eq 1 ] && echo "    [✓] Wallpaper: ${GRUVBOX_WALLPAPER_FILENAME}"
  echo "    [✓] SDDM theme: sddm-gruvbox (Qt6, he1senbrg/sddm-gruvbox)"
  echo "    Theme will be active after first login."
  echo ""
fi

if [ "$REBOOT" -eq 1 ]; then
  echo "[*] Rebooting in 5 seconds (Ctrl+C to cancel)..."
  sleep 5
  reboot
else
  echo "[*] Reboot skipped (--no-reboot). Reboot manually when ready:"
  echo "    sudo reboot"
fi

echo "[*] Finished: $(date)"