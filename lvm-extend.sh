#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------
# Usage function
# --------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -n, --dry-run         Show what would happen without making changes
  -y, --yes             Skip all confirmation prompts
  -h, --help            Display this help message
EOF
  exit 1
}

ORIGINAL_ARGS=("$@")

DRY_RUN=0
AUTO_YES=0
POSITIONAL=()

# --------------------------------------------------
# Parse arguments
# --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1; shift
      ;;
    -y|--yes)
      AUTO_YES=1; shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      POSITIONAL+=("$1"); shift
      ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

# --------------------------------------------------
# Session logging
# --------------------------------------------------
if [[ -z "${UNDER_SCRIPT:-}" ]]; then
  LOGFILE="/var/log/lvm-grow-$(date +%F_%H%M%S).log"
  echo "Logging session to $LOGFILE"
  export UNDER_SCRIPT=1
  exec script -q -c "$0 $(printf '%q ' "${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}")" "$LOGFILE"
fi

# --------------------------------------------------
# Debug output
# --------------------------------------------------
echo "[DEBUG] Dry-run mode: $([[ $DRY_RUN -eq 1 ]] && echo ON || echo OFF)"
echo "[DEBUG] Skip confirmations: $([[ $AUTO_YES -eq 1 ]] && echo ON || echo OFF)"

# --------------------------------------------------
# Ensure we're root
# --------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo $0)"
  exit 1
fi

# --------------------------------------------------
# Gather and select volume group
# --------------------------------------------------
mapfile -t VGS < <(vgs --noheading -o vg_name | awk '{$1=$1;print}')
echo "Select the volume group to modify:"
PS3="VG> "
select VG_NAME in "${VGS[@]}"; do
  [[ -n "$VG_NAME" ]] && break
  echo "Invalid selection."
done

# --------------------------------------------------
# Gather and select logical volume
# --------------------------------------------------
mapfile -t LVS < <(lvs --noheading -o lv_name,lv_path --separator '|' "$VG_NAME" | sed 's/^ *//')
echo "Select the logical volume to modify:"
PS3="LV> "
select LV_ENTRY in "${LVS[@]}"; do
  [[ -n "$LV_ENTRY" ]] && break
  echo "Invalid selection."
done
LV_NAME=${LV_ENTRY%%|*}
LV_PATH=${LV_ENTRY##*|}

# --------------------------------------------------
# Verify free space in VG
# --------------------------------------------------
echo "Free space in volume group '$VG_NAME':"
vgs --units g --noheading -o vg_free "$VG_NAME" | sed 's/^/  /'
echo

VG_FREE=$(vgs --units g --noheading -o vg_free "$VG_NAME" | tr -d ' g')
if (( $(echo "$VG_FREE == 0" | bc -l) )); then
  echo "No free space in volume group '$VG_NAME'. Exiting."
  exit 1
fi

# --------------------------------------------------
# Ask grow size and validate
# --------------------------------------------------
read -rp "Specify how much to grow by (e.g. 10G, 500M, 1T): " GROW_SIZE
if ! [[ $GROW_SIZE =~ ^[0-9]+([.][0-9]+)?[KkMmGgTtPp]$ ]]; then
  echo "Error: invalid size format. Use e.g. 10G, 500M, 1.5T."
  exit 1
fi

# --------------------------------------------------
# Confirm actions
# --------------------------------------------------
echo
echo "About to run:"
echo "  lvextend -r -L +$GROW_SIZE $LV_PATH"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[DRY-RUN] No changes will be made."
fi
if [[ $AUTO_YES -eq 0 ]]; then
  read -rp "Proceed? (y/N) " CONFIRM
else
  CONFIRM=Y
fi
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
  echo "Aborting."
  exit 0
fi

# --------------------------------------------------
# Perform the extend (with automatic filesystem resize)
# --------------------------------------------------
EXT_CMD=(lvextend -r -L +"$GROW_SIZE" "$LV_PATH")
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[DRY-RUN] ${EXT_CMD[*]}"
else
  echo "Extending $LV_PATH by $GROW_SIZE..."
  "${EXT_CMD[@]}"
fi

# --------------------------------------------------
# Show summary
# --------------------------------------------------
echo
echo "Updated volume group stats:"
vgs --units g "$VG_NAME"

echo
echo "Updated logical volumes:"
lvs --noheading --units g --separator " " -o vg_name,lv_name,lv_size "$VG_NAME"

echo
echo "Filesystem usage:"
df -h

read -rp "Press Enter to exit..." _