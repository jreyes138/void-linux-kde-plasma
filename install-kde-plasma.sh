#!/bin/bash
#
# install-kde-plasma.sh
# Automates KDE Plasma installation on a fresh Void Linux base install.
# Performs hardware discovery first, then installs only what's needed.
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
#   --autologin USER Enable SDDM autologin for given user (e.g. --autologin joser)
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
AUTOLOGIN=""
LOG=/var/log/kde-plasma-install.log

# ── parse args ───────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --minimal)     MINIMAL=1; shift ;;
    --no-reboot)   REBOOT=0; shift ;;
    --wayland)     WAYLAND=1; shift ;;
    --no-extras)   EXTRAS=0; shift ;;
    --no-firmware) FIRMWARE=0; shift ;;
    --no-flatpak)  FLATPAK=0; shift ;;
    --autologin)   shift; AUTOLOGIN="${1:-}"; shift ;;
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
echo "[*] Options: minimal=${MINIMAL} wayland=${WAYLAND} extras=${EXTRAS} firmware=${FIRMWARE} flatpak=${FLATPAK} autologin=${AUTOLOGIN:-none} reboot=${REBOOT}"
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

  output=$(xbps-install -y "${pkgs[@]}" 2>&1) || true

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
elif echo "$GPU_PCI_LINE" | grep -qi 'advanced micro devices\|amd\|ati\|radeon'; then
  GPU_VENDOR="amd"
  GPU_MODEL=$(echo "$GPU_PCI_LINE" | sed 's/.*:\s*//; s/ *\[.*//')
elif echo "$GPU_PCI_LINE" | grep -qi 'intel'; then
  GPU_VENDOR="intel"
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
if lsusb 2>/dev/null | grep -qi 'bluetooth\|bt'; then
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

# ── print discovery results ───────────────────────────────────────────
echo "  CPU vendor:        $CPU_VENDOR"
echo "  GPU vendor:        $GPU_VENDOR"
echo "  GPU model:         $GPU_MODEL"
echo "  Virtualization:    $VIRT_PLATFORM"
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
mkdir -p "$cgroup"
if ! mountpoint "$cgroup" > /dev/null; then
  mount -t cgroup -o none,name=elogind cgroup "$cgroup" || exit 1
fi

for tmpfs in /run/systemd /run/user; do
  mountpoint "$tmpfs" > /dev/null && continue
  mkdir -p "$tmpfs"
  mount -t tmpfs -o nosuid,nodev,noexec,mode=0755 none "$tmpfs" || exit 1
done

# Start elogind in background, then wait for it.
# elogind forks by default — the parent exits immediately, which makes
# runit think the service crashed. We start it in the background and
# then wait on the daemon PID file so runit sees a long-running process.
/usr/libexec/elogind/elogind &
EPID=$!

# Give elogind a moment to fork and write its state
sleep 2

# Find the actual daemon process (the forked child)
DPID=$(pgrep -x elogind 2>/dev/null | head -1)
if [ -n "$DPID" ] && [ "$DPID" != "$EPID" ]; then
  # Parent already exited, wait on the child
  wait "$DPID" 2>/dev/null || wait "$EPID" 2>/dev/null
else
  wait "$EPID" 2>/dev/null
fi
ELOGINDRUN
  chmod 755 /etc/sv/elogind/run
  echo "[*] Patched elogind run script (inline wrapper + wait loop)"
fi

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

  # WirePlumber session manager config
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
    if [ -d /etc/sv/vmblockd ] && [ ! -L /var/service/vmblockd ]; then
      ln -s /etc/sv/vmblockd /var/service/
      echo "[*] vmblockd symlink created."
    elif [ -L /var/service/vmblockd ]; then
      echo "[*] vmblockd already enabled."
    fi
    ;;
  virtualbox)
    echo "[*] VirtualBox VM detected. Installing virtualbox-guest-tools."
    xinstall virtualbox-guest-tools
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

# ── dbus ─────────────────────────────────────────────────────────────
echo ""
echo "=== Step 10.1: Enabling dbus service ==="
if [ -L /var/service/dbus ]; then
  echo "[*] dbus already enabled."
else
  ln -s /etc/sv/dbus /var/service/
  echo "[*] dbus symlink created."
fi
# Give runit a moment to scan the new symlink before sv commands
sleep 2
sv status dbus 2>/dev/null || sv up dbus 2>/dev/null || true

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

  cat > "$SDDM_CONF" << SDDMCONF
${AUTOLOGIN_SECTION}

[General]
# Use Wayland for the greeter (Plasma 6 default); fall back to x11 if issues
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell
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
  echo "    To apply breeze theme manually, add/modify in [Theme] section:"
  echo "    Current=breeze"
  echo "    CursorTheme=breeze_cursors"
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
xinstall bat micro nano eza git wget curl bash-completion wezterm wezterm-terminfo desktop-file-utils

# ── Install Nerd Fonts + base fonts ──────────────────────────────────
# nerd-fonts-symbols-ttf (5MB) provides the icon glyphs that eza --icons
# needs. The full nerd-fonts-ttf (7GB) includes all patched font families
# (Hack, FiraCode, JetBrains Mono, etc.) for use as terminal fonts.
# Base fonts: dejavu (default sans/mono), noto (multi-language), noto-cjk
# (CJK), noto-emoji (emoji support — important for modern desktop).
echo ""
echo "=== Step 12.2: Installing fonts ==="
xinstall nerd-fonts-symbols-ttf dejavu-fonts-ttf noto-fonts-ttf noto-fonts-emoji
# CJK fonts are large — skip on VMs unless bare metal
if [ "$VIRT_PLATFORM" = "none" ]; then
  xinstall noto-fonts-cjk
else
  echo "[*] VM detected — skipping noto-fonts-cjk (large). Install manually if needed."
fi

# Full font collection is optional — 7GB. Install if not on a constrained VM.
if [ "$VIRT_PLATFORM" = "none" ]; then
  echo "[*] Bare metal detected — installing full nerd-fonts-ttf (7GB)..."
  xinstall nerd-fonts-ttf
else
  echo "[*] VM detected ($VIRT_PLATFORM) — skipping full nerd-fonts-ttf (7GB)."
  echo "    Symbols-only font installed. To get full patched fonts later:"
  echo "    xbps-install nerd-fonts-ttf"
fi

# Rebuild font cache so the new fonts are immediately available
echo "[*] Rebuilding font cache..."
fc-cache -f 2>/dev/null || echo "[!] fc-cache not found — font cache not rebuilt"

# Reconfigure fontconfig to pick up new font config files (handbook recommended)
xbps-reconfigure -f fontconfig 2>/dev/null || true

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
alias update="sudo xbps-install -Su"
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
alias update='sudo xbps-install -Su'
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
    owner=$(stat -c %U "$user_home" 2>/dev/null)
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
if fc-list 2>/dev/null | grep -qi 'nerd'; then
  echo "[*] Nerd Font symbols detected by fontconfig."
  echo "[*] eza --icons will display file-type icons in the terminal."
  echo "[*] Set a Nerd Font (e.g. 'Hack Nerd Font') in your terminal"
  echo "    emulator for full icon support including powerline glyphs."
else
  echo "[!] Nerd Font not detected by fontconfig."
  echo "[!] Run: sudo fc-cache -f && fc-list | grep -i nerd"
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
      owner=$(stat -c %U "$user_home" 2>/dev/null)
      [ -n "$owner" ] && chown "$owner":"$owner" "$usermime"
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
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database

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

local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- ── Color scheme (Gruvbox Dark Hard — built into wezterm 20240203) ───
config.color_scheme = 'GruvboxDarkHard'

-- ── Window appearance ────────────────────────────────────────────────
config.window_background_opacity = 0.85
config.window_decorations = 'TITLE | RESIZE'
config.window_padding = {
  left = 8,
  right = 8,
  top = 8,
  bottom = 8,
}

-- ── Font ─────────────────────────────────────────────────────────────
-- Primary font is a real monospace font for regular text.
-- Nerd Font Mono is the fallback for icon glyphs (eza --icons).
config.font = wezterm.font_with_fallback {
  { family = 'DejaVu Sans Mono', scale = 1.0 },
  { family = 'Symbols Nerd Font Mono', scale = 1.0 },
}
config.font_size = 12.0
config.line_height = 1.1

-- ── Tab bar ──────────────────────────────────────────────────────────
config.use_fancy_tab_bar = true
config.hide_tab_bar_if_only_one_tab = true
config.tab_bar_at_bottom = false

-- ── Scrollback ──────────────────────────────────────────────────────
config.scrollback_lines = 10000

-- ── Keybindings ─────────────────────────────────────────────────────
config.keys = {
  -- Ctrl+Shift+T = new tab
  { key = 'T', mods = 'CTRL|SHIFT', action = wezterm.action.SpawnTab 'CurrentPaneDomain' },
  -- Ctrl+Shift+W = close tab
  { key = 'W', mods = 'CTRL|SHIFT', action = wezterm.action.CloseCurrentTab { confirm = true } },
  -- Ctrl+C = copy (if text is selected) or send interrupt (if nothing selected)
  {
    key = 'C',
    mods = 'CTRL',
    action = wezterm.action.CopyTo 'ClipboardAndPrimarySelection',
  },
  -- Ctrl+V = paste
  {
    key = 'V',
    mods = 'CTRL',
    action = wezterm.action.PasteFrom 'Clipboard',
  },
  -- Ctrl+Shift+C/V = copy/paste (alternative)
  { key = 'C', mods = 'CTRL|SHIFT', action = wezterm.action.CopyTo 'Clipboard' },
  { key = 'V', mods = 'CTRL|SHIFT', action = wezterm.action.PasteFrom 'Clipboard' },
  -- Alt+D/E = split panes
  { key = 'd', mods = 'ALT', action = wezterm.action.SplitHorizontal { domain = 'CurrentPaneDomain' } },
  { key = 'e', mods = 'ALT', action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' } },
  -- Alt+arrows = navigate panes (ActivatePaneDirection, not ActivatePaneLeft etc.)
  { key = 'LeftArrow',  mods = 'ALT', action = wezterm.action.ActivatePaneDirection 'Left' },
  { key = 'RightArrow', mods = 'ALT', action = wezterm.action.ActivatePaneDirection 'Right' },
  { key = 'UpArrow',    mods = 'ALT', action = wezterm.action.ActivatePaneDirection 'Up' },
  { key = 'DownArrow',  mods = 'ALT', action = wezterm.action.ActivatePaneDirection 'Down' },
}

return config
WEZTERMCFG

  if [ "$user_home" = "/root" ]; then
    chown -R root:root "$wt_dir"
  else
    owner=$(stat -c %U "$user_home" 2>/dev/null)
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

# ── Fix ownership of user config directories ──────────────────────────
# The script runs as root and creates dirs like ~/.config, ~/.config/wezterm
# with root ownership. Plasma can't write settings to root-owned dirs,
# causing the theme/color-scheme Apply button to silently fail.
# Fix: chown all user config dirs back to their rightful owners.
echo ""
echo "[*] Fixing user directory ownership..."
for user_home in /home/*; do
  owner=$(stat -c %U "$user_home" 2>/dev/null)
  if [ -n "$owner" ] && [ "$owner" != "root" ]; then
    chown -R "$owner":"$owner" "$user_home/.config" 2>/dev/null && \
      echo "[*] Fixed .config ownership for $owner"
  fi
done

# ── Apply Breeze Dark theme ──────────────────────────────────────────
# Pre-configure the Breeze Dark color scheme and look-and-feel so the
# user gets a dark desktop on first login without needing to manually
# apply it in System Settings (where the Apply button would fail if
# .config is root-owned — fixed above).
echo ""
echo "[*] Pre-configuring Breeze Dark theme..."
for user_home in /home/*; do
  owner=$(stat -c %U "$user_home" 2>/dev/null)
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

# Update kdeglobals to use Gruvbox-Plus-Dark icons (instead of breeze-dark)
for user_home in /home/*; do
  owner=$(stat -c %U "$user_home" 2>/dev/null)
  [ -z "$owner" ] || [ "$owner" = "root" ] && continue

  # Update kdeglobals Icons theme
  if [ -f "${user_home}/.config/kdeglobals" ]; then
    sed -i 's/^Theme=breeze-dark/Theme=Gruvbox-Plus-Dark/' "${user_home}/.config/kdeglobals"
  fi
  # Update kdedefaults/kdeglobals Icons theme
  if [ -f "${user_home}/.config/kdedefaults/kdeglobals" ]; then
    sed -i 's/^Theme=breeze-dark/Theme=Gruvbox-Plus-Dark/' "${user_home}/.config/kdedefaults/kdeglobals"
  fi
  echo "[*] Set Gruvbox-Plus-Dark icons for $owner"
done

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
  flatpak remote-add --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
  echo "[*] Flathub remote added."
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
  flatpak install -y flathub com.brave.Browser || echo "[!] Brave Browser install failed — try manually: flatpak install flathub com.brave.Browser"
  echo "[*] Brave Browser installed."
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
  flatpak install -y flathub com.tutanota.Tutanota || echo "[!] Tutanota install failed — try manually: flatpak install flathub com.tutanota.Tutanota"
  echo "[*] Tutanota installed."
fi

# ── Update flatpak desktop database ───────────────────────────────────
echo ""
echo "=== Step 13.6: Updating desktop database ==="
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database
echo "[*] Desktop database updated — apps visible in KDE menu."

echo ""
echo "[*] Flatpak setup complete."
echo "[*] Update Flatpak apps periodically: flatpak update"

else
  echo "[*] Flatpak skipped (--no-flatpak)."
fi

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
echo "  Enabled services (start on boot):"
echo "    - dbus           (/var/service/dbus)"
echo "    - elogind        (/var/service/elogind)  — session/seat mgmt"
echo "    - sddm           (/var/service/sddm)      — display manager"
echo "    - NetworkManager (/var/service/NetworkManager)"
[ $BLUETOOTH_DETECTED -eq 1 ] && echo "    - bluetoothd      (/var/service/bluetoothd)"
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
if [ "$VIRT_PLATFORM" = "none" ]; then
  echo "    nerd-fonts-ttf — full patched font families (Hack, FiraCode, etc.)"
fi
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
echo "  Shell aliases:"
echo "    update     — sudo xbps-install -Su"
echo "    install    — sudo xbps-install -S"
echo "    search     — xbps-query -Rs"
echo "    remove     — sudo xbps-remove -R"
echo "    cleanup    — sudo xbps-remove -O -o"
echo ""
echo "  Bash history: 10000 entries, dedup, timestamped, saved per-command"
echo ""

if [ "$REBOOT" -eq 1 ]; then
  echo "[*] Rebooting in 5 seconds (Ctrl+C to cancel)..."
  sleep 5
  reboot
else
  echo "[*] Reboot skipped (--no-reboot). Reboot manually when ready:"
  echo "    sudo reboot"
fi

echo "[*] Finished: $(date)"