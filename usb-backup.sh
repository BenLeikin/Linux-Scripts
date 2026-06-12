#!/bin/bash
set -euo pipefail

# ===== CONFIG =====
# Set this to your USB partition filesystem UUID (recommended).
# Find it with: blkid  or  lsblk -f (if lsblk is available)
USB_UUID="${USB_UUID:-PUT-UUID-HERE}"

USB_MNT="${USB_MNT:-/mnt/usbbackup}"
BACKUP_ROOT="${BACKUP_ROOT:-$USB_MNT/backups}"

HOST="$(hostname -s)"
STAMP="$(date +%F_%H%M%S)"
DEST="$BACKUP_ROOT/$HOST/$STAMP"
LATEST="$BACKUP_ROOT/$HOST/latest"

# ===== SAFETY =====
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

if [ -z "$USB_UUID" ] || [ "$USB_UUID" = "PUT-UUID-HERE" ]; then
  echo "Set USB_UUID to the USB filesystem UUID." >&2
  exit 1
fi

mkdir -p "$USB_MNT"

USB_DEV="/dev/disk/by-uuid/$USB_UUID"
if [ ! -e "$USB_DEV" ]; then
  # Fallback for systems without /dev/disk/by-uuid
  USB_DEV="$(blkid -U "$USB_UUID" 2>/dev/null || true)"
fi

if [ -z "${USB_DEV:-}" ] || [ ! -b "$USB_DEV" ]; then
  echo "Could not resolve USB device for UUID: $USB_UUID" >&2
  exit 1
fi

# ===== MOUNT USB =====
if ! mountpoint -q "$USB_MNT"; then
  mount "$USB_DEV" "$USB_MNT"
fi

mkdir -p "$DEST"

# ===== BACKUP =====
# -a: archive (perms/owner/times)
# -H: hardlinks
# -A: ACLs
# -X: xattrs (includes SELinux labels if in use)
# --numeric-ids: preserve numeric UID/GID exactly
# --one-file-system: don't cross into other mounted filesystems
rsync -aHAX --numeric-ids --progress \
  --one-file-system \
  --exclude="/dev/*" \
  --exclude="/proc/*" \
  --exclude="/sys/*" \
  --exclude="/run/*" \
  --exclude="/tmp/*" \
  --exclude="/mnt/*" \
  --exclude="/media/*" \
  --exclude="/selinux/*" \
  --exclude="/cgroup/*" \
  --exclude="/lost+found" \
  / "$DEST/rootfs/"

# Tiny manifest
{
  echo "Host: $(hostname)"
  echo "Time: $(date)"
  echo "Source: /"
  echo "Destination: $DEST/rootfs"
  echo "USB UUID: $USB_UUID"
  echo "USB device: $USB_DEV"
} > "$DEST/manifest.txt"

ln -sfn "$STAMP" "$LATEST"
sync

echo "Backup complete:"
echo "  $DEST"
echo "Latest:"
echo "  $LATEST"
