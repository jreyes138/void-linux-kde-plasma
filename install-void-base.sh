#!/bin/bash
#
# install-void-base.sh
# Installs a fresh Void Linux base system via the chroot/XBPS method.
# Supports btrfs subvolumes (@ and @home), UEFI/BIOS, nonfree repos.
#
# Usage:
#   sudo bash install-void-base.sh --disk /dev/sda --hostname voidbox
#   sudo bash install-void-base.sh --disk /dev/nvme0n1 --hostname laptop --user lenier
#
# This script DESTROYS all data on the target disk.
# After reboot, run install-kde-plasma.sh to install the desktop.
#
# Optional flags:
#   --disk /dev/sdX        Target disk (required)
#   --hostname NAME        System hostname (required)
#   --fs btrfs             Filesystem: btrfs (default) or ext4
#   --no-nonfree           Skip nonfree/multilib repo enablement
#   --no-reboot            Don't reboot at the end
#   --kernel mainline      Kernel: mainline (default) or stock
#   --user NAME            Create user account with wheel + sudo
#   --password-stdin       Read root password from stdin (for scripting)
#   --repo URL             XBPS repository URL (default: https://repo-default.voidlinux.org/current)
#   --arch x86_64          Target architecture (default: auto-detect)
#   --yes                  Skip confirmation prompt (for automation)

# Re-exec with bash if not already running under bash
if [ -z "$BASH_VERSION" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

# ── defaults ────────────────────────────────────────────────────────
DISK=""
HOSTNAME=""
FS="btrfs"
NONFREE=1
REBOOT=1
KERNEL="mainline"
USERNAME=""
PASSWORD_STDIN=0
REPO="https://repo-default.voidlinux.org/current"
ARCH=""
YES=0
LOG=/var/log/void-base-install.log

# ── parse args ──────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --disk)          shift; DISK="${1:-}"; shift ;;
    --hostname)      shift; HOSTNAME="${1:-}"; shift ;;
    --fs)            shift; FS="${1:-}"; shift ;;
    --no-nonfree)    NONFREE=0; shift ;;
    --no-reboot)     REBOOT=0; shift ;;
    --kernel)        shift; KERNEL="${1:-}"; shift ;;
    --user)          shift; USERNAME="${1:-}"; shift ;;
    --password-stdin) PASSWORD_STDIN=1; shift ;;
    --repo)          shift; REPO="${1:-}"; shift ;;
    --arch)          shift; ARCH="${1:-}"; shift ;;
    --yes)           YES=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── pre-flight checks ───────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run this script as root (sudo bash install-void-base.sh)"
  exit 1
fi

if ! command -v xbps-install >/dev/null 2>&1; then
  echo "ERROR: xbps-install not found."
  echo "       This script must run from a Void live image or an existing Void system."
  echo "       For non-Void hosts, see: https://docs.voidlinux.org/xbps/troubleshooting/static.html"
  exit 1
fi

# ── interactive: disk selection ──────────────────────────────────────
if [ -z "$DISK" ]; then
  echo ""
  echo "Available disks:"
  lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || lsblk -d 2>/dev/null || true
  echo ""
  echo -n "Enter target disk (e.g. /dev/sda or /dev/nvme0n1): "
  read -r DISK
  if [ -z "$DISK" ]; then
    echo "ERROR: No disk specified."
    exit 1
  fi
fi

if [ ! -b "$DISK" ]; then
  echo "ERROR: $DISK is not a block device."
  exit 1
fi

# ── interactive: hostname ─────────────────────────────────────────────
if [ -z "$HOSTNAME" ]; then
  echo ""
  echo -n "Enter system hostname (e.g. voidbox): "
  read -r HOSTNAME
  if [ -z "$HOSTNAME" ]; then
    echo "ERROR: No hostname specified."
    exit 1
  fi
fi

# Check disk is not mounted
if lsblk -no MOUNTPOINT "$DISK" 2>/dev/null | grep -q .; then
  echo "ERROR: $DISK or one of its partitions is currently mounted. Unmount before proceeding."
  lsblk "$DISK"
  exit 1
fi

# Warn if disk is the current root device
CURRENT_ROOT=$(findmnt -no SOURCE / 2>/dev/null || true)
if [ -n "$CURRENT_ROOT" ]; then
  CURRENT_DISK=$(lsblk -no PKNAME "$CURRENT_ROOT" 2>/dev/null | head -1 || true)
  if [ -n "$CURRENT_DISK" ]; then
    CURRENT_DISK_DEV="/dev/$CURRENT_DISK"
    if [ "$DISK" = "$CURRENT_DISK_DEV" ] || [ "$DISK" = "$CURRENT_ROOT" ]; then
      echo "ERROR: $DISK appears to be the current root disk. Refusing to proceed."
      exit 1
    fi
  fi
fi

# Auto-detect architecture if not set
if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    x86_64)  ARCH="x86_64" ;;
    i686)    ARCH="i686" ;;
    aarch64) ARCH="aarch64" ;;
    *) echo "ERROR: Could not auto-detect architecture. Use --arch."; exit 1 ;;
  esac
fi

# Auto-detect UEFI vs BIOS
IS_UEFI=0
if [ -d /sys/firmware/efi ]; then
  IS_UEFI=1
fi

# ── confirmation prompt ─────────────────────────────────────────────
echo ""
echo "[*] Void Linux base installer (chroot/XBPS method)"
echo "[*] Options: disk=$DISK hostname=$HOSTNAME fs=$FS kernel=$KERNEL uefi=$IS_UEFI arch=$ARCH nonfree=$NONFREE user=${USERNAME:-none} reboot=$REBOOT"

if [ "$YES" -eq 0 ]; then
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  WARNING: ALL DATA ON $DISK WILL BE DESTROYED"
  echo "══════════════════════════════════════════════════════════════"
  lsblk "$DISK" 2>/dev/null || true
  echo ""
  echo -n "Type YES to continue: "
  read -r CONFIRM
  if [ "$CONFIRM" != "YES" ]; then
    echo "Aborted."
    exit 1
  fi
fi

# ── interactive: root password ──────────────────────────────────────
# Collect passwords BEFORE log redirect so they don't end up in the log.
ROOT_PASSWORD=""
if [ "$PASSWORD_STDIN" -eq 1 ]; then
  echo "[*] Reading root password from stdin..."
  read -r ROOT_PASSWORD
elif [ "$YES" -eq 0 ]; then
  echo ""
  echo "── Root password ──"
  echo "Set a root password for the new system."
  passwd_hashed=""
  while true; do
    read -r -s -p "Root password: " ROOT_PASSWORD
    echo ""
    read -r -s -p "Confirm root password: " ROOT_PASSWORD2
    echo ""
    if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD2" ] && [ -n "$ROOT_PASSWORD" ]; then
      break
    fi
    echo "Passwords do not match or are empty. Try again."
  done
fi

# ── interactive: user creation ───────────────────────────────────────
USER_PASSWORD=""
if [ -z "$USERNAME" ] && [ "$YES" -eq 0 ]; then
  echo ""
  echo "── User account ──"
  echo "Create a user account? This user will have sudo (wheel) access."
  echo -n "Username (leave empty to skip): "
  read -r USERNAME
  if [ -n "$USERNAME" ]; then
    while true; do
      read -r -s -p "Password for $USERNAME: " USER_PASSWORD
      echo ""
      read -r -s -p "Confirm password for $USERNAME: " USER_PASSWORD2
      echo ""
      if [ "$USER_PASSWORD" = "$USER_PASSWORD2" ] && [ -n "$USER_PASSWORD" ]; then
        break
      fi
      echo "Passwords do not match or are empty. Try again."
    done
  fi
fi

# ── start logging (AFTER password collection) ────────────────────────
echo "[*] Logging to ${LOG}"
exec > >(tee -a "$LOG") 2>&1
echo "[*] Started: $(date)"

# ═══════════════════════════════════════════════════════════════════════
# PHASE 1: Partitioning
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 1: Partitioning ($DISK)"
echo "══════════════════════════════════════════════════════════════"

# Wipe existing partition table
echo "[*] Wiping $DISK..."
wipefs -a "$DISK" 2>/dev/null || true

# Determine partition device naming
# NVMe/mmcblk use pN suffix (e.g. /dev/nvme0n1p1), SATA/SAS use N (e.g. /dev/sda1)
if echo "$DISK" | grep -qE '/dev/(nvme|mmcblk)'; then
  PART1="${DISK}p1"
  PART2="${DISK}p2"
else
  PART1="${DISK}1"
  PART2="${DISK}2"
fi

# Install gptfdisk (sgdisk) if not present — the Void live image
# does not include it by default. parted is also not guaranteed.
echo "[*] Ensuring partitioning tools are available..."
xbps-install -Sy gptfdisk 2>/dev/null || true

# Create partitions with sgdisk (from gptfdisk) or parted fallback
if command -v sgdisk >/dev/null 2>&1; then
  if [ "$IS_UEFI" -eq 1 ]; then
    echo "[*] Creating GPT partitions (UEFI)..."
    sgdisk -Z "$DISK"
    sgdisk -n 1:0:+512M -t 1:EF00 -c 1:"EFI System" "$DISK"
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
  else
    echo "[*] Creating GPT partitions (BIOS)..."
    sgdisk -Z "$DISK"
    sgdisk -n 1:0:+1M -t 1:EF02 -c 1:"BIOS boot" "$DISK"
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
  fi
else
  echo "[*] sgdisk not found, trying parted..."
  xbps-install -Sy parted 2>/dev/null || true
  if ! command -v parted >/dev/null 2>&1; then
    echo "ERROR: Neither sgdisk nor parted available. Cannot partition."
    echo "       Install manually: xbps-install gptfdisk"
    exit 1
  fi
  if [ "$IS_UEFI" -eq 1 ]; then
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary btrfs 513MiB 100%
  else
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart bios_grub 1MiB 2MiB
    parted -s "$DISK" set 1 bios_grub on
    parted -s "$DISK" mkpart primary btrfs 2MiB 100%
  fi
fi

# Inform kernel of partition changes
partprobe "$DISK" 2>/dev/null || true
sleep 2

echo "[*] Partition layout:"
lsblk "$DISK" 2>/dev/null || true
echo "[*] Partitions: ESP=$PART1  Root=$PART2"

# ═══════════════════════════════════════════════════════════════════════
# PHASE 2: Filesystem creation
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 2: Filesystem Creation ($FS)"
echo "══════════════════════════════════════════════════════════════"

# Format ESP (EFI System Partition) — FAT32
echo "[*] Formatting ESP ($PART1) as FAT32..."
mkfs.vfat -F32 "$PART1"

if [ "$FS" = "btrfs" ]; then
  # ── btrfs with subvolumes ────────────────────────────────────────
  echo "[*] Formatting $PART2 as btrfs..."
  mkfs.btrfs -f -L voidroot "$PART2"

  # Mount top-level subvolume temporarily to create subvolumes
  echo "[*] Creating btrfs subvolumes (@ and @home)..."
  mount "$PART2" /mnt
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home
  umount /mnt

  # Mount root subvolume
  echo "[*] Mounting subvolumes at /mnt..."
  mount -o noatime,compress=zstd,subvol=@ "$PART2" /mnt
  mkdir -p /mnt/home /mnt/boot/efi
  mount -o noatime,compress=zstd,subvol=@home "$PART2" /mnt/home
  mount "$PART1" /mnt/boot/efi

  echo "[*] Btrfs subvolumes created:"
  btrfs subvolume list /mnt 2>/dev/null || true

elif [ "$FS" = "ext4" ]; then
  # ── ext4 (no subvolumes) ─────────────────────────────────────────
  echo "[*] Formatting $PART2 as ext4..."
  mkfs.ext4 -F -L voidroot "$PART2"
  mount "$PART2" /mnt
  mkdir -p /mnt/boot/efi
  mount "$PART1" /mnt/boot/efi
else
  echo "ERROR: Unknown filesystem type: $FS (use btrfs or ext4)"
  exit 1
fi

echo "[*] Mounted filesystems:"
findmnt -R /mnt 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════
# PHASE 3: Bootstrap base system via XBPS
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 3: Bootstrap Base System (XBPS)"
echo "══════════════════════════════════════════════════════════════"

# Copy XBPS RSA keys from the host/live image
echo "[*] Copying XBPS RSA keys..."
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ 2>/dev/null || true

# Install base-system
echo "[*] Installing base-system into /mnt (this takes a few minutes)..."
XBPS_ARCH=$ARCH xbps-install -S -y -r /mnt -R "$REPO" base-system

# Install additional base packages
echo "[*] Installing additional packages..."
EXTRA_PKGS="xtools gptfdisk btrfs-progs"
if [ "$NONFREE" -eq 1 ]; then
  EXTRA_PKGS="$EXTRA_PKGS void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree"
fi
XBPS_ARCH=$ARCH xbps-install -y -r /mnt -R "$REPO" $EXTRA_PKGS || true

echo "[*] Base system installed. Packages:"
xbps-query -r /mnt -l 2>/dev/null | wc -l || true

# ═══════════════════════════════════════════════════════════════════════
# PHASE 4: Generate fstab and enter chroot
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 4: fstab + Chroot"
echo "══════════════════════════════════════════════════════════════"

# Generate fstab from mounted filesystems
echo "[*] Generating /etc/fstab..."
if command -v xgenfstab >/dev/null 2>&1; then
  xgenfstab -U /mnt > /mnt/etc/fstab
else
  # Manual fstab generation fallback
  ROOT_UUID=$(blkid -o value -s UUID "$PART2" 2>/dev/null || true)
  ESP_UUID=$(blkid -o value -s UUID "$PART1" 2>/dev/null || true)
  cat > /mnt/etc/fstab << FSTAB
# Generated by install-void-base.sh
UUID=$ROOT_UUID  /            btrfs   noatime,compress=zstd,subvol=@       0 0
UUID=$ROOT_UUID  /home        btrfs   noatime,compress=zstd,subvol=@home   0 0
UUID=$ESP_UUID   /boot/efi    vfat    defaults,umask=0077                  0 0
tmpfs             /tmp         tmpfs   defaults,nosuid,nodev                0 0
FSTAB
fi

echo "[*] fstab contents:"
cat /mnt/etc/fstab

# Enter chroot — use xchroot if available, otherwise manual
echo "[*] Entering chroot..."

# Export variables for use inside the chroot heredoc
export DISK PART1 PART2 FS IS_UEFI KERNEL NONFREE USERNAME HOSTNAME ROOT_PASSWORD USER_PASSWORD REPO ARCH

# Prepare chroot environment
if command -v xchroot >/dev/null 2>&1; then
  CHROOT_CMD="xchroot /mnt /bin/bash"
else
  # Manual chroot setup
  mount --bind /dev /mnt/dev 2>/dev/null || true
  mount --bind /proc /mnt/proc 2>/dev/null || true
  mount --bind /sys /mnt/sys 2>/dev/null || true
  mount --bind /run /mnt/run 2>/dev/null || true
  mount -t devpts devpts /mnt/dev/pts 2>/dev/null || true
  CHROOT_CMD="chroot /mnt /bin/bash"
fi

# Run all chroot commands in a single heredoc
$CHROOT_CMD << 'CHROOT_EOF'
set -euo pipefail

echo "[*] Inside chroot — configuring system..."

# ── Hostname ──────────────────────────────────────────────────────
echo "$HOSTNAME" > /etc/hostname
sed -i "s|^HOSTNAME=.*|HOSTNAME=$HOSTNAME|" /etc/rc.conf 2>/dev/null || true
echo "[*] Hostname set to: $HOSTNAME"

# ── Locale (glibc only) ───────────────────────────────────────────
if [ ! -d /usr/lib/musl ]; then
  echo "LANG=en_US.UTF-8" > /etc/locale.conf
  if ! grep -q 'en_US.UTF-8' /etc/default/libc-locales 2>/dev/null; then
    echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
  fi
  xbps-reconfigure -f glibc-locales 2>/dev/null || true
  echo "[*] Locale set to: en_US.UTF-8"
fi

# ── Root password ─────────────────────────────────────────────────
if [ -n "$ROOT_PASSWORD" ]; then
  echo "root:$ROOT_PASSWORD" | chpasswd
  echo "[*] Root password set."
else
  echo "[!] No root password set. Use --password-stdin or run passwd root after reboot."
fi

# ── User account ──────────────────────────────────────────────────
if [ -n "$USERNAME" ]; then
  echo "[*] Creating user: $USERNAME"
  useradd -m -G wheel,audio,video,input,network,bluetooth "$USERNAME"
  if [ -n "$USER_PASSWORD" ]; then
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    echo "[*] Password set for $USERNAME."
  else
    echo "[!] No password set for $USERNAME. Run passwd $USERNAME after reboot."
  fi
  echo "[*] User $USERNAME created with wheel + audio + video + input + network + bluetooth groups."
fi

# ── GRUB bootloader ───────────────────────────────────────────────
echo ""
echo "[*] Installing GRUB bootloader..."
if [ "$IS_UEFI" -eq 1 ]; then
  echo "[*] UEFI system — installing grub-x86_64-efi..."
  xbps-install -Sy grub-x86_64-efi 2>/dev/null || true

  # Mount efivarfs if not mounted (needed for grub-install)
  mountpoint -q /sys/firmware/efi/efivars 2>/dev/null || \
    mount -t efivarfs none /sys/firmware/efi/efivars 2>/dev/null || true

  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void" \
    2>/dev/null || grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void" --no-nvram
  echo "[*] GRUB installed (UEFI)."
else
  echo "[*] BIOS system — installing grub..."
  xbps-install -Sy grub 2>/dev/null || true
  grub-install "$DISK"
  echo "[*] GRUB installed (BIOS)."
fi

# ── GRUB configuration for btrfs subvolumes ───────────────────────
if [ "$FS" = "btrfs" ]; then
  echo "[*] Configuring GRUB for btrfs subvol=@..."
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null; then
    sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rootflags=subvol=@"|' /etc/default/grub
  else
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rootflags=subvol=@"' >> /etc/default/grub
  fi
fi

# ── Kernel selection ──────────────────────────────────────────────
echo ""
echo "[*] Kernel selection: $KERNEL"
if [ "$KERNEL" = "mainline" ]; then
  echo "[*] Installing linux-mainline..."
  xbps-install -Sy linux-mainline 2>/dev/null || true
  # Ignore the stock linux meta-package to prevent it from being pulled in
  mkdir -p /etc/xbps.d
  if ! grep -q 'ignorepkg=linux' /etc/xbps.d/10-ignore.conf 2>/dev/null; then
    echo "ignorepkg=linux" >> /etc/xbps.d/10-ignore.conf
    echo "ignorepkg=linux-headers" >> /etc/xbps.d/10-ignore.conf
  fi
  echo "[*] linux-mainline installed. Stock linux ignored."
else
  echo "[*] Using stock linux kernel (installed by base-system)."
fi

# ── Dracut btrfs module ───────────────────────────────────────────
if [ "$FS" = "btrfs" ]; then
  echo "[*] Configuring dracut for btrfs..."
  mkdir -p /etc/dracut.conf.d
  echo 'filesystems+="btrfs"' > /etc/dracut.conf.d/20-btrfs.conf
fi

# ── Nonfree repos re-sync ─────────────────────────────────────────
if [ "$NONFREE" -eq 1 ]; then
  echo "[*] Re-syncing package index (nonfree repos)..."
  xbps-install -Sy 2>/dev/null || true
fi

# ── Enable essential services ─────────────────────────────────────
echo "[*] Enabling essential services..."
for svc in dbus elogind dhcpcd sshd; do
  if [ -d "/etc/sv/$svc" ] && [ ! -L "/var/service/$svc" ]; then
    ln -s "/etc/sv/$svc" /var/service/
    echo "[*] Enabled: $svc"
  elif [ -L "/var/service/$svc" ]; then
    echo "[*] Already enabled: $svc"
  else
    echo "[*] Service dir not found: $svc (skipping)"
  fi
done

# ── Generate initramfs + grub.cfg ─────────────────────────────────
echo ""
echo "[*] Running xbps-reconfigure -fa (generates initramfs + grub.cfg)..."
xbps-reconfigure -fa

# ── Verify grub.cfg has subvol flag (btrfs only) ──────────────────
if [ "$FS" = "btrfs" ]; then
  if grep -q 'rootflags=subvol=@' /boot/grub/grub.cfg 2>/dev/null; then
    echo "[*] Verified: grub.cfg has rootflags=subvol=@"
  else
    echo "[!] WARNING: grub.cfg is missing rootflags=subvol=@"
    echo "[!] The system may not boot correctly. Check /etc/default/grub and re-run grub-mkconfig."
  fi
fi

# ── Verify kernel installed ───────────────────────────────────────
echo ""
echo "[*] Installed kernels:"
xbps-query -l 2>/dev/null | grep -E '^ii linux' || true

echo ""
echo "[*] Chroot configuration complete."
CHROOT_EOF

# ═══════════════════════════════════════════════════════════════════════
# PHASE 5: Cleanup and reboot
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 5: Cleanup and Reboot"
echo "══════════════════════════════════════════════════════════════"

# Unmount everything
echo "[*] Unmounting /mnt..."
umount -R /mnt 2>/dev/null || true

# Print summary
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Void Linux base installation complete."
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Disk:          $DISK"
echo "  Hostname:      $HOSTNAME"
echo "  Filesystem:    $FS"
if [ "$FS" = "btrfs" ]; then
  echo "  Subvolumes:    @ (root) + @home (/home)"
  echo "  Compression:   zstd"
fi
echo "  Kernel:        $KERNEL"
echo "  Bootloader:    $([ $IS_UEFI -eq 1 ] && echo 'GRUB (UEFI)' || echo 'GRUB (BIOS)')"
echo "  Nonfree repos: $([ $NONFREE -eq 1 ] && echo 'enabled' || echo 'disabled')"
echo "  Services:      dbus, elogind, dhcpcd, sshd"
if [ -n "$USERNAME" ]; then
  echo "  User:          $USERNAME (wheel, audio, video, input, network, bluetooth)"
fi
echo ""
echo "  Next step:"
echo "    1. Reboot into the new system"
echo "    2. Log in as root (or $USERNAME)"
echo "    3. Download and run install-kde-plasma.sh to install KDE Plasma:"
echo "       curl -O https://raw.githubusercontent.com/jreyes138/void-linux-kde-plasma/main/install-kde-plasma.sh"
echo "       sudo bash install-kde-plasma.sh"
echo ""

if [ "$REBOOT" -eq 1 ]; then
  echo "[*] Rebooting in 5 seconds (Ctrl+C to cancel)..."
  sleep 5
  reboot
else
  echo "[*] Reboot skipped (--no-reboot). Reboot manually when ready:"
  echo "    sudo reboot"
fi