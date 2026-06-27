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
#   --keymap us            Console keyboard layout (default: us)
#   --locale en_US.UTF-8   System locale (default: en_US.UTF-8, glibc only)
#   --no-nonfree           Skip nonfree/multilib repo enablement
#   --no-reboot            Don't reboot at the end
#   --kernel mainline      Kernel: mainline (default) or stock
#   --user NAME            Create user account with wheel + sudo
#   --password-stdin       Read root password from stdin (for scripting)
#   --repo URL             XBPS repository URL (default: https://repo-default.voidlinux.org/current)
#   --arch x86_64          Target architecture (default: auto-detect)
#   --uefi                  Force UEFI mode (auto-detect may fail if live image booted in BIOS mode)
#   --bios                  Force BIOS mode
#   --yes                  Skip confirmation prompt (for automation)

# Re-exec with bash if not already running under bash
if [ -z "$BASH_VERSION" ]; then
  exec bash "$0" "$@"
fi

set -e

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
KEYMAP=""
LOCALE=""
FORCE_UEFI=0
FORCE_BIOS=0
LOG=/var/log/void-base-install.log

# ── parse args ──────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --disk)          shift; DISK="${1:-}"; shift ;;
    --hostname)      shift; HOSTNAME="${1:-}"; shift ;;
    --fs)            shift; FS="${1:-}"; shift ;;
    --keymap)        shift; KEYMAP="${1:-}"; shift ;;
    --locale)        shift; LOCALE="${1:-}"; shift ;;
    --no-nonfree)    NONFREE=0; shift ;;
    --no-reboot)     REBOOT=0; shift ;;
    --kernel)        shift; KERNEL="${1:-}"; shift ;;
    --user)          shift; USERNAME="${1:-}"; shift ;;
    --password-stdin) PASSWORD_STDIN=1 shift ;;
    --repo)          shift; REPO="${1:-}"; shift ;;
    --arch)          shift; ARCH="${1:-}"; shift ;;
    --uefi)          FORCE_UEFI=1; shift ;;
    --bios)          FORCE_BIOS=1; shift ;;
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

# Auto-detect UEFI vs BIOS, or use forced mode
IS_UEFI=0
if [ "$FORCE_UEFI" -eq 1 ]; then
  IS_UEFI=1
  echo "[*] UEFI mode forced (--uefi)"
elif [ "$FORCE_BIOS" -eq 1 ]; then
  IS_UEFI=0
  echo "[*] BIOS mode forced (--bios)"
elif [ -d /sys/firmware/efi ]; then
  IS_UEFI=1
  echo "[*] UEFI mode detected (/sys/firmware/efi exists)"
else
  IS_UEFI=0
  echo "[*] BIOS mode detected (/sys/firmware/efi not found)"
  echo "[*] If installing to a UEFI VM, make sure the live image booted in UEFI mode"
  echo "[*] or use --uefi flag to force UEFI install"
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

# ── interactive: keyboard layout ──────────────────────────────────────
# Void uses keymaps from /usr/share/kbd/keymaps. Common ones:
#   us (default), gb, de, fr, es, it, br, ru, etc.
# Full list: ls /usr/share/kbd/keymaps/*/ | sed 's/.map.gz//'
# If --keymap was passed via flag, use it. Otherwise default to us.
# Prompt interactively unless --yes.
if [ -z "$KEYMAP" ]; then
  KEYMAP="us"
fi
if [ "$YES" -eq 0 ]; then
  echo ""
  echo "── Keyboard layout ──"
  echo "Common layouts: us, gb, de, fr, es, it, br, ru, dvorak, colemak"
  echo -n "Keyboard layout [$KEYMAP]: "
  read -r INPUT_KEYMAP
  if [ -n "$INPUT_KEYMAP" ]; then
    KEYMAP="$INPUT_KEYMAP"
  fi
fi

# ── interactive: locale ───────────────────────────────────────────────
# Format: language_COUNTRY.UTF-8 (glibc only, musl doesn't use locales)
# Common: en_US.UTF-8 (default), en_GB.UTF-8, de_DE.UTF-8, es_ES.UTF-8,
#         fr_FR.UTF-8, pt_BR.UTF-8, it_IT.UTF-8, etc.
# If --locale was passed via flag, use it. Otherwise default to en_US.UTF-8.
# Prompt interactively unless --yes or musl.
if [ -z "$LOCALE" ]; then
  LOCALE="en_US.UTF-8"
fi
if [ "$YES" -eq 0 ] && [ ! -d /usr/lib/musl ]; then
  echo ""
  echo "── Locale ──"
  echo "Format: language_COUNTRY.UTF-8 (e.g. en_US.UTF-8, es_ES.UTF-8)"
  echo -n "Locale [$LOCALE]: "
  read -r INPUT_LOCALE
  if [ -n "$INPUT_LOCALE" ]; then
    LOCALE="$INPUT_LOCALE"
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
udevadm settle 2>/dev/null || sleep 3

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

# Format ESP (EFI System Partition) — FAT32, UEFI only
# In BIOS mode, PART1 is the 1MB BIOS boot partition (EF02) which must
# remain raw/unformatted — GRUB writes its core image directly to it.
if [ "$IS_UEFI" -eq 1 ]; then
  echo "[*] Formatting ESP ($PART1) as FAT32..."
  mkfs.vfat -F32 "$PART1"
else
  echo "[*] BIOS mode — skipping ESP format (BIOS boot partition stays raw)"
fi

if [ "$FS" = "btrfs" ]; then
  # ── btrfs with subvolumes ────────────────────────────────────────
  echo "[*] Formatting $PART2 as btrfs..."
  mkfs.btrfs -f -L voidroot "$PART2"

  # Mount top-level subvolume temporarily to create subvolumes
  echo "[*] Creating btrfs subvolumes (@ and @home)..."
  mount "$PART2" /mnt
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home

  # Set @ as the default subvolume. This is CRITICAL for GRUB:
  # GRUB's btrfs module reads the default subvolume. Without this,
  # GRUB sees the top-level (subvolid=5) where /boot/grub/grub.cfg
  # doesn't exist — it's inside @. Setting @ as default makes GRUB
  # find /boot/grub/grub.cfg and /boot/vmlinuz-* correctly.
  DEFAULT_ID=$(btrfs subvolume list /mnt | grep ' path @$' | awk '{print $2}')
  if [ -n "$DEFAULT_ID" ]; then
    btrfs subvolume set-default "$DEFAULT_ID" /mnt
    echo "[*] Set @ (subvolid=$DEFAULT_ID) as default subvolume"
  else
    echo "[!] WARNING: Could not find @ subvolume ID to set as default"
  fi

  umount /mnt

  # Mount root subvolume
  echo "[*] Mounting subvolumes at /mnt..."
  mount -o noatime,compress=zstd,subvol=@ "$PART2" /mnt
  mkdir -p /mnt/home
  mount -o noatime,compress=zstd,subvol=@home "$PART2" /mnt/home
  # Mount ESP only for UEFI
  if [ "$IS_UEFI" -eq 1 ]; then
    mkdir -p /mnt/boot/efi
    mount "$PART1" /mnt/boot/efi
  fi

  echo "[*] Btrfs subvolumes created:"
  btrfs subvolume list /mnt 2>/dev/null || true

elif [ "$FS" = "ext4" ]; then
  # ── ext4 (no subvolumes) ─────────────────────────────────────────
  echo "[*] Formatting $PART2 as ext4..."
  mkfs.ext4 -F -L voidroot "$PART2"
  mount "$PART2" /mnt
  # Mount ESP only for UEFI
  if [ "$IS_UEFI" -eq 1 ]; then
    mkdir -p /mnt/boot/efi
    mount "$PART1" /mnt/boot/efi
  fi
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
# Install GRUB package from outside the chroot — more reliable than
# installing inside the chroot where repo config may be incomplete
if [ "$IS_UEFI" -eq 1 ]; then
  EXTRA_PKGS="$EXTRA_PKGS grub-x86_64-efi"
else
  EXTRA_PKGS="$EXTRA_PKGS grub"
fi
# Install mainline kernel from outside too (base-system already pulled in
# the stock 'linux' kernel, but we want mainline)
if [ "$KERNEL" = "mainline" ]; then
  EXTRA_PKGS="$EXTRA_PKGS linux-mainline"
fi
XBPS_ARCH=$ARCH xbps-install -y -r /mnt -R "$REPO" $EXTRA_PKGS || true

# ── Set up repository config inside the chroot ──────────────────────
# The XBPS method installs packages with -r /mnt but doesn't create
# the xbps.d repo config inside /mnt. Without this, xbps-install
# inside the chroot can't find any repositories.
echo "[*] Configuring XBPS repositories inside /mnt..."
mkdir -p /mnt/usr/share/xbps.d
# Copy ALL xbps.d configs from the host (repo configs, mirror configs, etc.)
if [ -d /usr/share/xbps.d ]; then
  cp /usr/share/xbps.d/*.conf /mnt/usr/share/xbps.d/ 2>/dev/null || true
fi
# If no configs were copied, create one from the REPO variable
if ! ls /mnt/usr/share/xbps.d/*.conf >/dev/null 2>&1; then
  echo "repository=$REPO" > /mnt/usr/share/xbps.d/00-main.conf
fi
# Also copy any user overrides from /etc/xbps.d
if [ -d /etc/xbps.d ]; then
  mkdir -p /mnt/etc/xbps.d
  cp /etc/xbps.d/*.conf /mnt/etc/xbps.d/ 2>/dev/null || true
fi
# Sync the package database inside the chroot target
XBPS_ARCH=$ARCH xbps-install -S -r /mnt -R "$REPO" 2>/dev/null || true

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
  if [ -z "$ROOT_UUID" ]; then
    echo "ERROR: Could not get UUID for root partition ($PART2)"
    exit 1
  fi
  if [ "$FS" = "btrfs" ]; then
    if [ "$IS_UEFI" -eq 1 ]; then
      cat > /mnt/etc/fstab << FSTAB
# Generated by install-void-base.sh
UUID=$ROOT_UUID  /            btrfs   noatime,compress=zstd,subvol=@       0 0
UUID=$ROOT_UUID  /home        btrfs   noatime,compress=zstd,subvol=@home   0 0
UUID=$ESP_UUID   /boot/efi    vfat    defaults,umask=0077                  0 0
tmpfs             /tmp         tmpfs   defaults,nosuid,nodev                0 0
FSTAB
    else
      cat > /mnt/etc/fstab << FSTAB
# Generated by install-void-base.sh (BIOS)
UUID=$ROOT_UUID  /            btrfs   noatime,compress=zstd,subvol=@       0 0
UUID=$ROOT_UUID  /home        btrfs   noatime,compress=zstd,subvol=@home   0 0
tmpfs             /tmp         tmpfs   defaults,nosuid,nodev                0 0
FSTAB
    fi
  else
    if [ "$IS_UEFI" -eq 1 ]; then
      cat > /mnt/etc/fstab << FSTAB
# Generated by install-void-base.sh
UUID=$ROOT_UUID  /            ext4    defaults,noatime                     0 1
UUID=$ESP_UUID   /boot/efi    vfat    defaults,umask=0077                  0 0
tmpfs             /tmp         tmpfs   defaults,nosuid,nodev                0 0
FSTAB
    else
      cat > /mnt/etc/fstab << FSTAB
# Generated by install-void-base.sh (BIOS)
UUID=$ROOT_UUID  /            ext4    defaults,noatime                     0 1
tmpfs             /tmp         tmpfs   defaults,nosuid,nodev                0 0
FSTAB
    fi
  fi
fi

echo "[*] fstab contents:"
cat /mnt/etc/fstab

# Enter chroot — use xchroot if available, otherwise manual
echo "[*] Entering chroot..."

# Export variables for use inside the chroot heredoc
export DISK PART1 PART2 FS IS_UEFI KERNEL NONFREE USERNAME HOSTNAME ROOT_PASSWORD USER_PASSWORD KEYMAP LOCALE REPO ARCH

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

# ═══════════════════════════════════════════════════════════════════════
# PHASE 4a: System configuration inside chroot (hostname, locale, passwords)
# ═══════════════════════════════════════════════════════════════════════
echo "[*] Entering chroot for system configuration..."

$CHROOT_CMD << 'CHROOT_EOF'
# No set -e — we want to see all errors, not abort on first failure

echo "[*] Inside chroot — configuring system..."

# ── Hostname ──────────────────────────────────────────────────────
echo "$HOSTNAME" > /etc/hostname
sed -i "s|^HOSTNAME=.*|HOSTNAME=$HOSTNAME|" /etc/rc.conf 2>/dev/null || true
echo "[*] Hostname set to: $HOSTNAME"

# ── Keyboard layout ───────────────────────────────────────────────
sed -i "s|^KEYMAP=.*|KEYMAP=$KEYMAP|" /etc/rc.conf 2>/dev/null || \
  echo "KEYMAP=$KEYMAP" >> /etc/rc.conf
loadkeys "$KEYMAP" 2>/dev/null || true
echo "[*] Keyboard layout set to: $KEYMAP"

# ── Locale (glibc only) ───────────────────────────────────────────
if [ ! -d /usr/lib/musl ]; then
  echo "LANG=$LOCALE" > /etc/locale.conf
  if ! grep -q "^$LOCALE" /etc/default/libc-locales 2>/dev/null; then
    echo "$LOCALE UTF-8" >> /etc/default/libc-locales
  fi
  xbps-reconfigure -f glibc-locales 2>/dev/null || true
  echo "[*] Locale set to: $LOCALE"
else
  echo "LANG=$LOCALE" > /etc/locale.conf 2>/dev/null || true
  echo "[*] Locale set to: $LOCALE (musl)"
fi

# ── Root password ─────────────────────────────────────────────────
if [ -n "$ROOT_PASSWORD" ]; then
  echo "root:$ROOT_PASSWORD" | chpasswd
  echo "[*] Root password set."
else
  echo "[!] No root password set."
fi

# ── User account ──────────────────────────────────────────────────
if [ -n "$USERNAME" ]; then
  echo "[*] Creating user: $USERNAME"
  useradd -m -G wheel,audio,video,input,network,bluetooth "$USERNAME"
  if [ -n "$USER_PASSWORD" ]; then
    echo "$USERNAME:$USER_PASSWORD" | chpasswd
    echo "[*] Password set for $USERNAME."
  fi
  echo "[*] User $USERNAME created."
fi

echo "[*] System configuration complete."
CHROOT_EOF

# ═══════════════════════════════════════════════════════════════════════
# PHASE 4b: GRUB configuration and install (OUTSIDE chroot)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "[*] Configuring GRUB..."

# Configure /etc/default/grub inside /mnt
if [ "$FS" = "btrfs" ]; then
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /mnt/etc/default/grub 2>/dev/null; then
    sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rootflags=subvol=@"|' /mnt/etc/default/grub
  else
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=4 rootflags=subvol=@"' >> /mnt/etc/default/grub
  fi
  if grep -q '^GRUB_PRELOAD_MODULES=' /mnt/etc/default/grub 2>/dev/null; then
    if ! grep -q 'btrfs' /mnt/etc/default/grub 2>/dev/null; then
      sed -i 's|^GRUB_PRELOAD_MODULES=.*|GRUB_PRELOAD_MODULES="btrfs"|' /mnt/etc/default/grub
    fi
  else
    echo 'GRUB_PRELOAD_MODULES="btrfs"' >> /mnt/etc/default/grub
  fi
  echo "[*] GRUB configured for btrfs (subvol=@, preload btrfs module)"
else
  echo "[*] GRUB configured (ext4, no subvolume flags)"
fi

# Run grub-install using chroot
echo "[*] Running grub-install..."

# Verify ESP is mounted at /mnt/boot/efi
if [ "$IS_UEFI" -eq 1 ]; then
  if ! mountpoint -q /mnt/boot/efi 2>/dev/null; then
    echo "[!] /mnt/boot/efi not mounted! Mounting ESP..."
    mkdir -p /mnt/boot/efi
    mount "$PART1" /mnt/boot/efi
  fi
fi

# Simple grub-install — match the Medium article approach exactly
# No fancy fallback chains that can break under set -e
if [ "$IS_UEFI" -eq 1 ]; then
  echo "[*] Installing GRUB (UEFI)..."
  chroot /mnt grub-install --target=x86_64-efi \
    --efi-directory=/boot/efi --bootloader-id="Void" 2>&1 || {
    echo "[!] grub-install failed, trying --removable..."
    chroot /mnt grub-install --target=x86_64-efi \
      --efi-directory=/boot/efi --bootloader-id="Void" --removable 2>&1 || true
  }

  # Ensure fallback BOOT path exists (for VMs where NVRAM doesn't persist)
  mkdir -p /mnt/boot/efi/EFI/BOOT
  if [ -f /mnt/boot/efi/EFI/Void/grubx64.efi ]; then
    cp /mnt/boot/efi/EFI/Void/grubx64.efi /mnt/boot/efi/EFI/BOOT/bootx64.efi
    echo "[*] Copied grubx64.efi to fallback BOOT path"
  fi
else
  echo "[*] Installing GRUB (BIOS)..."
  chroot /mnt grub-install "$DISK" 2>&1 || true
fi

# ═══════════════════════════════════════════════════════════════════════
# PHASE 4c: Kernel config, dracut, services, initramfs (inside chroot)
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "[*] Entering chroot for kernel + services + initramfs..."

$CHROOT_CMD << 'CHROOT_EOF'
# No set -e — we want to see all errors, not abort on first failure

# ── Kernel ignorepkg config ───────────────────────────────────────
if [ "$KERNEL" = "mainline" ]; then
  echo "[*] Configuring ignorepkg for stock linux..."
  mkdir -p /etc/xbps.d
  if ! grep -q 'ignorepkg=linux' /etc/xbps.d/10-ignore.conf 2>/dev/null; then
    echo "ignorepkg=linux" >> /etc/xbps.d/10-ignore.conf
    echo "ignorepkg=linux-headers" >> /etc/xbps.d/10-ignore.conf
  fi
  echo "[*] Stock linux ignored in favor of linux-mainline."
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
    echo "[!] WARNING: grub.cfg missing rootflags=subvol=@"
  fi
fi

# ── Verify boot artifacts ─────────────────────────────────────────
echo ""
echo "[*] Installed kernels:"
xbps-query -l 2>/dev/null | grep -E '^ii linux' || true

KERNEL_FOUND=0
for kdir in /boot/vmlinuz-*; do
  if [ -f "$kdir" ]; then
    KERNEL_FOUND=1
    echo "[*] Found kernel: $(basename "$kdir")"
    break
  fi
done
if [ "$KERNEL_FOUND" -eq 0 ]; then
  echo "[!] WARNING: No kernel in /boot/!"
fi

INITRAMFS_FOUND=0
for ifile in /boot/initramfs-*.img; do
  if [ -f "$ifile" ]; then
    INITRAMFS_FOUND=1
    echo "[*] Found initramfs: $(basename "$ifile")"
    break
  fi
done
if [ "$INITRAMFS_FOUND" -eq 0 ]; then
  echo "[!] WARNING: No initramfs in /boot/!"
fi

if [ ! -f /boot/grub/grub.cfg ]; then
  echo "[!] WARNING: grub.cfg not found! Running grub-mkconfig..."
  grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
fi

echo ""
echo "[*] Chroot configuration complete."
CHROOT_EOF

# ═══════════════════════════════════════════════════════════════════════
# PHASE 5: Boot diagnostic, cleanup and reboot
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Phase 5: Boot Diagnostic + Cleanup"
echo "══════════════════════════════════════════════════════════════"

# ── Boot diagnostic report ───────────────────────────────────────────
# Check all boot-critical files before unmounting so we can see
# exactly what's on the disk and what's missing.
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          BOOT DIAGNOSTIC REPORT                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

echo "── Partitions ──"
lsblk "$DISK" 2>/dev/null || true
echo ""

echo "── ESP contents ($PART1) ──"
if [ "$IS_UEFI" -eq 1 ]; then
  if mountpoint -q /mnt/boot/efi 2>/dev/null; then
    echo "ESP mounted at /mnt/boot/efi: YES"
  else
    echo "ESP mounted at /mnt/boot/efi: NO — remounting..."
    mount "$PART1" /mnt/boot/efi 2>/dev/null || true
  fi
  echo ""
  echo "EFI files on ESP:"
  find /mnt/boot/efi -type f 2>/dev/null | while read f; do
    size=$(stat -c %s "$f" 2>/dev/null || echo "?")
    echo "  $f ($size bytes)"
  done
  echo ""
  echo "EFI directories on ESP:"
  find /mnt/boot/efi -type d 2>/dev/null | sort | while read d; do
    echo "  $d/"
  done
  echo ""
  if [ -f /mnt/boot/efi/EFI/BOOT/bootx64.efi ]; then
    echo "[OK] /boot/efi/EFI/BOOT/bootx64.efi EXISTS"
  else
    echo "[FAIL] /boot/efi/EFI/BOOT/bootx64.efi MISSING — firmware won't find bootloader!"
  fi
  if [ -f /mnt/boot/efi/EFI/Void/grubx64.efi ]; then
    echo "[OK] /boot/efi/EFI/Void/grubx64.efi EXISTS"
  else
    echo "[--] /boot/efi/EFI/Void/grubx64.efi not found (ok if --removable used)"
  fi
else
  echo "BIOS mode — no ESP"
fi
echo ""

echo "── Kernel + initramfs in /mnt/boot ──"
echo "vmlinuz files:"
ls -la /mnt/boot/vmlinuz-* 2>/dev/null || echo "  [FAIL] No vmlinuz-* found!"
echo ""
echo "initramfs files:"
ls -la /mnt/boot/initramfs-* 2>/dev/null || echo "  [FAIL] No initramfs-* found!"
echo ""

echo "── GRUB config ──"
if [ -f /mnt/boot/grub/grub.cfg ]; then
  echo "[OK] /boot/grub/grub.cfg EXISTS ($(stat -c %s /mnt/boot/grub/grub.cfg) bytes)"
  echo ""
  echo "  Kernel entries in grub.cfg:"
  grep -n 'linux\|initrd\|rootflags\|subvol' /mnt/boot/grub/grub.cfg 2>/dev/null | head -20
else
  echo "[FAIL] /boot/grub/grub.cfg MISSING!"
fi
echo ""

echo "── /etc/default/grub ──"
if [ -f /mnt/etc/default/grub ]; then
  echo "[OK] /etc/default/grub EXISTS"
  grep -E 'GRUB_CMDLINE|GRUB_PRELOAD' /mnt/etc/default/grub 2>/dev/null || echo "  (no GRUB_CMDLINE or GRUB_PRELOAD entries)"
else
  echo "[FAIL] /etc/default/grub MISSING!"
fi
echo ""

echo "── fstab ──"
cat /mnt/etc/fstab 2>/dev/null || echo "  [FAIL] No fstab!"
echo ""

echo "── btrfs subvolumes ──"
if [ "$FS" = "btrfs" ]; then
  mount "$PART2" /mnt/tmp_btrfs_check 2>/dev/null || true
  btrfs subvolume list /mnt/tmp_btrfs_check 2>/dev/null || true
  btrfs subvolume get-default /mnt/tmp_btrfs_check 2>/dev/null || echo "  Could not get default subvolume"
  umount /mnt/tmp_btrfs_check 2>/dev/null || true
fi
echo ""

echo "── Installed packages (kernel + grub) ──"
xbps-query -r /mnt -l 2>/dev/null | grep -iE 'linux|grub' || echo "  [FAIL] No kernel or grub packages found!"
echo ""

echo "── Diagnostic complete ──"
echo ""

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
echo "  Keyboard:      $KEYMAP"
echo "  Locale:        $LOCALE"
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
  echo "[*] Syncing filesystems..."
  sync
  echo "[*] Rebooting in 5 seconds (Ctrl+C to cancel)..."
  sleep 5
  reboot
else
  echo "[*] Reboot skipped (--no-reboot). Reboot manually when ready:"
  echo "    sudo reboot"
fi