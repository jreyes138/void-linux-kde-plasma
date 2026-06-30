# Void Linux Base Installer with Btrfs Subvolumes — Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Create a new script `install-void-base.sh` that performs a full Void Linux base installation via the chroot/XBPS method, with btrfs subvolumes (@ and @home), UEFI/BIOS support, and nonfree repos. This script runs BEFORE `install-kde-plasma.sh` (which installs the desktop on top of the base system).

**Architecture:** Two-script pipeline:
1. `install-void-base.sh` — partitions disk, creates btrfs filesystem with subvolumes, bootstraps base-system via XBPS, installs GRUB, configures system, reboots
2. `install-kde-plasma.sh` — (existing) installs KDE Plasma + Gruvbox theme on top of the base

The new script is a standalone base installer. It does NOT replace or modify install-kde-plasma.sh. After reboot into the new base system, the user runs install-kde-plasma.sh to get the desktop.

**Tech Stack:** bash, sgdisk/parted, mkfs.btrfs, btrfs subvolume, xbps-install (XBPS method), xchroot/xgenfstab (xtools), GRUB, dracut

---

## Current Context

### What the Void chroot docs say (confirmed from void-docs source)

The XBPS method is fully scriptable:
```
REPO=https://repo-default.voidlinux.org/current
ARCH=x86_64
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
XBPS_ARCH=$ARCH xbps-install -S -r /mnt -R "$REPO" base-system
```

Then configure:
```
xgenfstab -U /mnt > /mnt/etc/fstab
xchroot /mnt /bin/bash
# ... configure hostname, rc.conf, locale, root password, GRUB
xbps-reconfigure -fa
```

### Key facts

1. **XBPS method is fully scriptable** — no interactive steps required (xbps-install -r /mnt is non-interactive with -y)
2. **btrfs subvolumes are supported** — create with `btrfs subvolume create`, mount with `mount -o subvol=<name>`
3. **GRUB on Void supports btrfs subvolumes** — dracut handles `rootflags=subvol=` via kernel cmdline
4. **xtools provides xgenfstab and xchroot** — available on live images, can be installed if missing
5. **No btrfs-specific Void doc exists** — Void docs have no btrfs subvolume guide. This script fills that gap.

### Btrfs subvolume layout (simplified — just root and home)

```
/dev/sda2 (btrfs, single partition)
├── @                          → mounted at / (root)
└── @home                      → mounted at /home
```

ESP (EFI System Partition) at /dev/sda1 → FAT32 → mounted at /boot/efi

No snapper. No @snapshots, no @var_cache, no @var_tmp, no @var_log. Keep it simple.

### Design decisions

- **UEFI default, BIOS fallback** — auto-detect via `/sys/firmware/efi`
- **btrfs default, ext4 fallback** — `--fs ext4` flag for simple installs
- **Single disk only** — no LVM, no RAID, no full disk encryption in v1
- **LUKS optional** — `--encrypt` flag for v2 (not in this plan)
- **No interactive partitioning** — disk selection via `--disk /dev/sdX` flag, auto-partition
- **No snapper** — snapshots can be added later if desired. Keep the base install simple.
- **zram swap, not partition swap** — install-kde-plasma.sh already sets up zramen
- **Nonfree repos enabled at base install** — so base-system can pull firmware if needed

---

## File Layout

```
/home/joser/void-linux-kde-plasma/
├── install-void-base.sh       ← NEW: base installer (this plan)
├── install-kde-plasma.sh      ← EXISTING: desktop installer (unchanged)
├── README.md                  ← EXISTING: update with two-script workflow
└── .hermes/plans/             ← this plan
```

---

## Task List

### Task 1: Script skeleton — shebang, set -euo pipefail, usage, flag parsing

**Objective:** Create the script file with argument parsing and pre-flight checks.

**Files:**
- Create: `install-void-base.sh`

**Flags to support:**
```
--disk /dev/sdX        Required: target disk (e.g. /dev/nvme0n1, /dev/sda)
--hostname voidbox     Required: system hostname
--fs btrfs             Filesystem: btrfs (default) or ext4
--no-nonfree           Skip nonfree/multilib repo enablement
--no-reboot            Don't reboot at the end
--kernel mainline      Kernel: mainline (default) or stock
--user NAME            Create user account with wheel + sudo
--password-stdin       Read root password from stdin (for scripting)
--repo URL             XBPS repository URL (default: https://repo-default.voidlinux.org/current)
--arch x86_64          Target architecture (default: auto-detect)
--yes                  Skip confirmation prompt (for automation)
```

**Step 1: Create skeleton**

```bash
#!/bin/bash
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

set -euo pipefail

# defaults
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

# parse args
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
```

**Step 2: Pre-flight checks**

- Must be root
- Must have xbps-install (running from Void live image or existing Void)
- --disk and --hostname are required
- --disk must exist and be a block device
- Disk must not be mounted
- Warn if disk is the current root device
- Auto-detect ARCH if not set (uname -m, map to x86_64/i686/aarch64)
- Auto-detect UEFI vs BIOS (/sys/firmware/efi exists = UEFI)

**Step 3: Confirmation prompt** (unless --yes)

Show disk info (lsblk), warn about data destruction, require typing "YES" to proceed.

**Step 4: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: add install-void-base.sh skeleton with flag parsing and pre-flight checks"
```

---

### Task 2: Partitioning — wipe disk, create GPT/MBR, ESP + root partition

**Objective:** Wipe the target disk and create partitions based on UEFI/BIOS detection.

**Files:**
- Modify: `install-void-base.sh`

**Partition layout:**

UEFI (GPT):
```
/dev/sdX1   EFI System Partition   512MB   FAT32   type EF00
/dev/sdX2   Linux filesystem       rest    btrfs/ext4   type 8300
```

BIOS (MBR):
```
/dev/sdX1   BIOS boot    1MB   no filesystem   type EF02 (BIOS boot)
/dev/sdX2   Linux        rest  btrfs/ext4       bootable
```

Note: For NVMe disks, partitions are /dev/nvme0n1p1, /dev/nvme0n1p2 (pN suffix).

**Step 1: Wipe disk**

```bash
wipefs -a "$DISK"
sgdisk -Z "$DISK" 2>/dev/null || parted -s "$DISK" mklabel gpt
```

**Step 2: Create partitions**

Use sgdisk (from gptfdisk) for GPT. sgdisk is non-interactive and scriptable.

For UEFI:
```bash
sgdisk -n 1:0:+512M -t 1:EF00 -c 1:"EFI System" "$DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
```

For BIOS:
```bash
sgdisk -n 1:0:+1M -t 1:EF02 -c 1:"BIOS boot" "$DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux root" "$DISK"
```

If gptfdisk not available, fall back to parted:
```bash
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary btrfs 513MiB 100%
```

**Step 3: Set up partition device paths**

NVMe disks use pN suffix (e.g. /dev/nvme0n1p1), SATA/SAS use N suffix (e.g. /dev/sda1).

```bash
if echo "$DISK" | grep -qE '/dev/(nvme|mmcblk)'; then
  PART1="${DISK}p1"
  PART2="${DISK}p2"
else
  PART1="${DISK}1"
  PART2="${DISK}2"
fi
```

**Step 4: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: add disk partitioning (UEFI GPT + BIOS MBR, ESP + root)"
```

---

### Task 3: Filesystem creation — btrfs with @ and @home subvolumes (or ext4 fallback)

**Objective:** Create filesystems and btrfs subvolumes, mount everything at /mnt.

**Files:**
- Modify: `install-void-base.sh`

**Step 1: Format ESP**

```bash
mkfs.vfat -F32 "$PART1"
```

**Step 2a: btrfs path — format, create subvolumes, mount**

```bash
mkfs.btrfs -f -L voidroot "$PART2"

# Mount the top-level subvolume temporarily
mount "$PART2" /mnt

# Create subvolumes — just root and home, keep it simple
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home

# Unmount top-level
umount /mnt

# Mount root subvolume
mount -o noatime,compress=zstd,subvol=@ "$PART2" /mnt

# Create mount points and mount subvolumes
mkdir -p /mnt/home /mnt/boot/efi
mount -o noatime,compress=zstd,subvol=@home "$PART2" /mnt/home

# Mount ESP
mount "$PART1" /mnt/boot/efi
```

**Step 2b: ext4 path — format, mount**

```bash
mkfs.ext4 -F -L voidroot "$PART2"
mount "$PART2" /mnt
mkdir -p /mnt/boot/efi
mount "$PART1" /mnt/boot/efi
```

**Step 3: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: add btrfs subvolume creation (@ + @home) and mount (with ext4 fallback)"
```

---

### Task 4: Bootstrap base system via XBPS

**Objective:** Install base-system into /mnt using the XBPS method.

**Files:**
- Modify: `install-void-base.sh`

**Step 1: Copy RSA keys**

```bash
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
```

**Step 2: Install base-system**

```bash
XBPS_ARCH=$ARCH xbps-install -S -y -r /mnt -R "$REPO" base-system
```

**Step 3: Install additional base packages**

```bash
# xtools for xgenfstab + xchroot
# gptfdisk for sgdisk (already used but needed in chroot too)
# btrfs-progs for subvolume management in the installed system
EXTRA_PKGS="xtools gptfdisk btrfs-progs"
if [ "$NONFREE" -eq 1 ]; then
  EXTRA_PKGS="$EXTRA_PKGS void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree"
fi
XBPS_ARCH=$ARCH xbps-install -y -r /mnt -R "$REPO" $EXTRA_PKGS
```

**Step 4: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: add XBPS base-system bootstrap into /mnt"
```

---

### Task 5: Generate fstab and enter chroot

**Objective:** Generate fstab from mounted filesystems, enter the chroot.

**Files:**
- Modify: `install-void-base.sh`

**Step 1: Generate fstab**

```bash
xgenfstab -U /mnt > /mnt/etc/fstab
```

Verify fstab has the btrfs subvol= entries for @ and @home.

**Step 2: Enter chroot**

Use xchroot (from xtools) which handles /dev, /proc, /sys, /dev/pts binding:

```bash
xchroot /mnt /bin/bash << 'CHROOT_EOF'
# ... all chroot commands here ...
CHROOT_EOF
```

Or use manual mount + chroot for robustness (in case xtools not available):

```bash
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
mount --bind /run /mnt/run
mount -t devpts devpts /mnt/dev/pts
chroot /mnt /bin/bash
```

Prefer xchroot. Fall back to manual if xchroot not found.

**Step 3: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: add fstab generation and chroot entry"
```

---

### Task 6: System configuration inside chroot

**Objective:** Configure hostname, locale, rc.conf, root password, user account.

**Files:**
- Modify: `install-void-base.sh`

**Step 1: Hostname**

```bash
echo "$HOSTNAME" > /etc/hostname
```

**Step 2: rc.conf**

```bash
sed -i "s|^HOSTNAME=.*|HOSTNAME=$HOSTNAME|" /etc/rc.conf
```

**Step 3: Locale (glibc only)**

```bash
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
```

**Step 4: Root password**

```bash
if [ "$PASSWORD_STDIN" -eq 1 ]; then
  passwd root << 'PASS'
<password from stdin>
PASS
else
  # Interactive prompt
  passwd
fi
```

Note: for --password-stdin, read the password BEFORE entering chroot and pass it via environment variable. Never echo passwords.

**Step 5: User account (if --user specified)**

```bash
if [ -n "$USERNAME" ]; then
  useradd -m -G wheel,audio,video,input,network,bluetooth "$USERNAME"
  passwd "$USERNAME"
fi
```

**Step 6: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: add system configuration (hostname, locale, root password, user)"
```

---

### Task 7: GRUB bootloader installation

**Objective:** Install and configure GRUB for UEFI or BIOS.

**Files:**
- Modify: `install-void-base.sh`

**Step 1: UEFI GRUB**

```bash
if [ "$IS_UEFI" -eq 1 ]; then
  xbps-install -S grub-x86_64-efi
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Void"
fi
```

**Step 2: BIOS GRUB**

```bash
if [ "$IS_UEFI" -eq 0 ]; then
  xbps-install -S grub
  grub-install "$DISK"
fi
```

**Step 3: GRUB configuration for btrfs subvolumes**

If btrfs with subvolumes, add `rootflags=subvol=@` to GRUB_CMDLINE_LINUX_DEFAULT:

```bash
if [ "$FS" = "btrfs" ]; then
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 rootflags=subvol=@\"|" /etc/default/grub
fi
```

This tells the kernel to mount the @ subvolume as root. Without this, the kernel mounts the top-level subvolume (which contains @, @home as directories, not as the root).

**Step 4: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: add GRUB bootloader installation (UEFI + BIOS, btrfs subvol flag)"
```

---

### Task 8: Kernel selection and dracut configuration

**Objective:** Install the selected kernel (mainline or stock), configure dracut for btrfs.

**Files:**
- Modify: `install-void-base.sh`

**Step 1: Install kernel**

```bash
if [ "$KERNEL" = "mainline" ]; then
  xbps-install -S linux-mainline
  # Ignore the stock linux meta-package
  echo "ignorepkg=linux" >> /etc/xbps.d/10-ignore.conf
  echo "ignorepkg=linux-headers" >> /etc/xbps.d/10-ignore.conf
else
  # Stock linux is already installed by base-system
  :
fi
```

**Step 2: Dracut btrfs module**

Ensure dracut includes btrfs module (it does by default, but be explicit):

```bash
echo 'filesystems+="btrfs"' > /etc/dracut.conf.d/20-btrfs.conf
```

**Step 3: xbps-reconfigure -fa**

This generates initramfs for all installed kernels and generates grub.cfg:

```bash
xbps-reconfigure -fa
```

**Step 4: Verify grub.cfg has rootflags=subvol=@**

```bash
grep "rootflags=subvol=@" /boot/grub/grub.cfg || echo "[!] WARNING: grub.cfg missing subvol flag"
```

**Step 5: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: add kernel selection (mainline/stock) and dracut btrfs config"
```

---

### Task 9: Enable nonfree repos and base services

**Objective:** Enable nonfree/multilib repos, enable essential services.

**Files:**
- Modify: `install-void-base.sh`

**Step 1: Enable nonfree repos (already installed as packages in Task 4, just re-sync)**

```bash
if [ "$NONFREE" -eq 1 ]; then
  xbps-install -Sy
fi
```

**Step 2: Enable essential services**

```bash
# dbus — needed by elogind and everything else
ln -s /etc/sv/dbus /var/service/

# elogind — session/seat management
ln -s /etc/sv/elogind /var/service/

# dhcpcd — network (will be replaced by NetworkManager in install-kde-plasma.sh)
ln -s /etc/sv/dhcpcd /var/service/

# sshd — remote access for initial setup
ln -s /etc/sv/sshd /var/service/
```

Note: dhcpcd is the minimum for network access on first boot. install-kde-plasma.sh replaces it with NetworkManager.

**Step 3: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: enable nonfree repos and base services (dbus, elogind, dhcpcd, sshd)"
```

---

### Task 10: Exit chroot, unmount, finalization, reboot

**Objective:** Clean up the chroot, unmount filesystems, reboot into the new system.

**Files:**
- Modify: `install-void-base.sh`

**Step 1: Exit chroot**

```bash
exit  # or the heredoc ends
```

**Step 2: Unmount everything**

```bash
umount -R /mnt
```

**Step 3: Print summary**

Show:
- Disk partitioned: $DISK
- Filesystem: $FS (with @ and @home subvolumes if btrfs)
- Kernel: $KERNEL
- GRUB installed: UEFI/BIOS
- Nonfree repos: enabled/disabled
- Services enabled: dbus, elogind, dhcpcd, sshd
- Next step: "Run install-kde-plasma.sh after reboot to install KDE Plasma"

**Step 4: Reboot (unless --no-reboot)**

```bash
if [ "$REBOOT" -eq 1 ]; then
  echo "[*] Rebooting in 5 seconds (Ctrl+C to cancel)..."
  sleep 5
  reboot
fi
```

**Step 5: Commit**

```bash
git add install-void-base.sh
git commit -m "feat: add chroot exit, unmount, summary, and reboot"
```

---

### Task 11: README update — document two-script workflow

**Objective:** Update README.md to describe the two-script pipeline.

**Files:**
- Modify: `README.md`

**Content to add:**

```
## Two-script installation workflow

### Step 1: Base system (install-void-base.sh)
Boot a Void live image, then run:
  sudo bash install-void-base.sh --disk /dev/sda --hostname voidbox

This partitions the disk, creates btrfs subvolumes (@ and @home), installs
base-system, GRUB, nonfree repos, and reboots.

### Step 2: Desktop (install-kde-plasma.sh)
After reboot, log in as root (or wheel user), download the script, and run:
  sudo bash install-kde-plasma.sh

This installs KDE Plasma, Gruvbox theme, audio, network, CLI tools, etc.
```

**Step 1: Commit**

```bash
git add README.md
git commit -m "docs: update README with two-script workflow (base + desktop)"
```

---

## Risks and Tradeoffs

### 1. Data destruction
The script wipes the entire target disk. No way around this for a base installer. Mitigation: confirmation prompt with disk info display, require typing "YES" unless --yes flag.

### 2. No LUKS encryption in v1
The plan does not include full disk encryption. The Void FDE doc shows it's scriptable (cryptsetup luksFormat, luksOpen, LVM on top). This can be added as --encrypt flag in v2. For now, users who need FDE follow the Void docs manually.

### 3. No LVM
The script uses a single btrfs partition with subvolumes. No LVM. btrfs subvolumes replace LVM logical volumes for most use cases. If someone needs LVM (e.g. for ext4 with multiple partitions), they should partition manually.

### 4. NVMe vs SATA device naming
NVMe disks use /dev/nvme0n1p1 (pN suffix), SATA/SAS use /dev/sda1 (N suffix). The script handles this in Task 2 Step 3. Risk: if the user passes /dev/nvme0n1 (no partition), the script must append p1/p2. If they pass /dev/sda, append 1/2.

### 5. btrfs subvol= in GRUB and fstab
Both GRUB_CMDLINE_LINUX_DEFAULT (rootflags=subvol=@) and fstab (subvol=@ mount option) must be set. If either is missing, the system won't boot or will mount the wrong subvolume. The script sets both.

### 6. Running from a non-Void live image
The XBPS method requires XBPS on the host. If the user boots a non-Void live image (e.g. Ubuntu), they need static XBPS. The script checks for xbps-install and errors out with a message pointing to the static XBPS docs.

### 7. dracut btrfs module
dracut includes btrfs by default on Void. But we add an explicit dracut.conf.d entry for safety. If the module is missing, the initramfs won't find the btrfs root and the kernel will panic.

---

## Open Questions

1. **Should the script download install-kde-plasma.sh into the new system automatically?** E.g. download it from GitHub and place it in /root/ so the user can run it after reboot without needing network setup first. This would be convenient but adds complexity (network must work in the live image for the download).

2. **Should we support multiple disks?** E.g. separate /home on a second disk. This adds significant complexity. YAGNI for v1.

3. **Should we support musl?** The script can detect glibc vs musl from the live image and set ARCH accordingly (x86_64-musl vs x86_64). The --arch flag already allows override. Probably auto-detect is sufficient.

4. **Should we set up the user's SSH keys?** E.g. copy authorized_keys from the live image. This would be convenient for headless installs. Could add --ssh-key flag.

5. **Timezone detection?** The script could auto-detect timezone from the live image's timezone setting or from /etc/timezone. For now, leave as UTC and let the user change it.

---

## Verification

After running install-void-base.sh and rebooting:

1. System boots to a login prompt (TTY, no desktop)
2. `uname -r` shows the selected kernel (mainline 7.x or stock)
3. `findmnt /` shows btrfs with subvol=@
4. `findmnt /home` shows btrfs with subvol=@home
5. `btrfs subvolume list /` shows @ and @home
6. `cat /etc/fstab` has subvol= entries for / and /home
7. `grep rootflags=subvol=@ /boot/grub/grub.cfg` — GRUB cmdline has subvol flag
8. `xbps-query -l | grep base-system` — base-system installed
9. `sv status dbus elogind dhcpcd sshd` — all running
10. If nonfree: `xbps-query -p repository void-repo-nonfree` — nonfree repo enabled
11. `ping -c1 repo-default.voidlinux.org` — network works (dhcpcd)
12. SSH access works (sshd enabled)

After running install-kde-plasma.sh on top:
13. `plasmashell --version` — Plasma 6.x
14. `wpctl status` — audio working
15. `sv status dbus elogind sddm NetworkManager zramen` — all running
16. `plasma-apply-colorscheme -l` — GruvboxPlusDark