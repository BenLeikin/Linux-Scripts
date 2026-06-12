#!/bin/bash
set -euo pipefail

# Migrate /var/tmp to a new LVM logical volume with safety checks, dry-run,
# and a summary prompt. Volume group is auto-detected from existing /var/tmp.

usage() {
  cat <<EOF
Usage: $0 [-n <lv-name>] [-d]
  -n  Logical volume name (default: lv_tmp)
  -d  Dry run; show what would happen without making changes
EOF
  exit 1
}

LV=lv_tmp
DRY_RUN=false

while getopts n:d opt; do
  case $opt in
    n) LV=$OPTARG     ;;
    d) DRY_RUN=true   ;;
    *) usage          ;;
  esac
done

# 1. Auto-detect source device for /var/tmp
SRCDEV=$(df --output=source /var/tmp | tail -1)
if [[ -z $SRCDEV ]]; then
  echo "Error: could not detect current device for /var/tmp" >&2
  exit 2
fi

# 2. Auto-detect volume group from source device
VG=$(lvs --noheadings -o vg_name "$SRCDEV" | tr -d ' ')
if [[ -z $VG ]]; then
  echo "Error: could not detect volume group for $SRCDEV" >&2
  exit 3
fi

echo "Auto-detected volume group: $VG"

# Prevent migrating to the same device
NEWDEV="/dev/${VG}/${LV}"
if [[ $SRCDEV == $NEWDEV ]]; then
  echo "Error: source and target devices are the same ($SRCDEV)" >&2
  exit 4
fi

# 3. Detect filesystem type, label, size
FSTYPE=$(lsblk -no FSTYPE "$SRCDEV")
if [[ -z $FSTYPE ]]; then
  echo "Error: could not detect filesystem type for $SRCDEV" >&2
  exit 5
fi
LABEL=$(blkid -o value -s LABEL "$SRCDEV" || true)
SIZE_BYTES=$(blockdev --getsize64 "$SRCDEV")
SIZE_MB=$(( (SIZE_BYTES + 1024*1024 - 1) / (1024*1024) ))
SIZE="${SIZE_MB}M"

echo "Source device: $SRCDEV"
echo "Filesystem type: $FSTYPE"
[[ -n $LABEL ]] && echo "Volume label: $LABEL"
echo "Detected size: $SIZE"

echo "Target LV: $LV in VG: $VG (will use size $SIZE)"

echo "Dry run: $DRY_RUN"

# 4. Check VG has enough free space
VG_FREE=$(vgs --units m --noheadings --nosuffix -o vg_free "$VG" | tr -d ' ')
VG_FREE_INT=${VG_FREE%%.*}
if [[ $VG_FREE_INT -lt $SIZE_MB ]]; then
  echo "Error: not enough free space in VG '$VG': have ${VG_FREE_INT}M, need ${SIZE_MB}M" >&2
  exit 6
fi

# 5. Summary and prompt
cat <<EOF
Migration plan summary:

- Source device: $SRCDEV
- Filesystem type: $FSTYPE
- Volume label: ${LABEL:-<none>}
- Current size: $SIZE
- Volume group: $VG
- Logical volume name: $LV
- Target device: $NEWDEV
- Dry run: $DRY_RUN
EOF

if $DRY_RUN; then
  echo "Dry run mode; exiting without making changes"
  exit 0
fi

read -rp "Proceed with migration? [y/N]: " confirm
case $confirm in
  [yY]|[yY][eE][sS]) ;;
  *) echo "Aborting. No changes made."; exit 0 ;;
esac

# 6. Create or reuse LV
if lvdisplay "$NEWDEV" &>/dev/null; then
  echo "Logical volume $NEWDEV already exists; skipping creation"
else
  echo "Creating LV $LV in VG $VG with size $SIZE"
  lvcreate -L "$SIZE" -n "$LV" "$VG"
fi

# 7. Format new LV if needed
if ! blkid "$NEWDEV" &>/dev/null; then
  echo "Formatting $NEWDEV as $FSTYPE"
  if [[ -n $LABEL ]]; then
    mkfs."$FSTYPE" -L "$LABEL" "$NEWDEV"
  else
    mkfs."$FSTYPE" "$NEWDEV"
  fi
else
  echo "$NEWDEV already has a filesystem; skipping format"
fi

# 8. Sync data
TMPMNT=$(mktemp -d)
trap 'rm -rf "$TMPMNT"' EXIT

echo "Mounting $NEWDEV at $TMPMNT"
mount "$NEWDEV" "$TMPMNT"

echo "Syncing /var/tmp to new device"
rsync -aHAXx --numeric-ids /var/tmp/ "$TMPMNT/"

# 9. Backup and prepare mountpoint
echo "Backing up existing /var/tmp to /var/tmp.bak"
mv /var/tmp /var/tmp.bak

mkdir -p /var/tmp
chmod 1777 /var/tmp
restorecon -Rv /var/tmp

umount "$TMPMNT"

# 10. Update fstab and mount
cat >> /etc/fstab <<EOF

# migrated /var/tmp onto LV $LV in VG $VG (size: $SIZE)
$NEWDEV    /var/tmp    $FSTYPE    defaults    0 0
EOF

echo "Mounting /var/tmp"
mount /var/tmp

echo "Migration complete. Original data is in /var/tmp.bak"
