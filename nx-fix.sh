#!/usr/bin/env bash
# nx_stig_check.sh - Verify RHEL-08-010420 (NX execute-disable), fix, and revert.

set -u

usage() {
  cat <<'EOF'
Usage: nx_stig_check.sh [--fix] [--revert] [--quiet]

Checks:
  1) CPU exposes NX to the guest (lscpu flags)
  2) Kernel logs show "NX (Execute Disable) protection: active"
  3) Kernel cmdline does not disable NX (noexec=off / noexec32=off)

Exit code:
  0 = compliant
  1 = not compliant
  2 = usage error

Options:
  --fix     Remove noexec=off/noexec32=off from GRUB defaults, set noexec=on for all kernels,
            then rebuild GRUB. Does not reboot. Requires root.
  --revert  Restore the latest /etc/default/grub backup made by this script if present,
            remove noexec=on (and noexec32=on) from all kernels, then rebuild GRUB.
            Does not reboot. Requires root.
  --quiet   Print only 1 (compliant) or 0 (non-compliant).
EOF
}

MODE="check"
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --fix) MODE="fix" ;;
    --revert) MODE="revert" ;;
    --quiet|-q) QUIET=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 2 ;;
  esac
done

have_cmd() { command -v "$1" >/dev/null 2>&1; }

rebuild_grub() {
  if [ -d /sys/firmware/efi ]; then
    grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg
  else
    grub2-mkconfig -o /boot/grub2/grub.cfg
  fi
}

latest_grub_backup() {
  ls -1t /etc/default/grub.bak.* 2>/dev/null | head -n1
}

# 1) CPU NX flag visible?
NX_FLAG=0
if have_cmd lscpu && lscpu | tr '[:upper:]' '[:lower:]' | grep -qw nx; then
  NX_FLAG=1
elif grep -qw nx /proc/cpuinfo 2>/dev/null; then
  NX_FLAG=1
fi

# 2) Kernel enabled NX?
KERNEL_ACTIVE=0
if have_cmd journalctl && journalctl -k -b 0 2>/dev/null | grep -qi 'NX (Execute Disable) protection: active'; then
  KERNEL_ACTIVE=1
elif dmesg 2>/dev/null | grep -qi 'NX (Execute Disable) protection: active'; then
  KERNEL_ACTIVE=1
fi

# 3) Kernel cmdline disabling NX?
CMDLINE_DISABLE=0
if grep -Eq '(^|[[:space:]])noexec(32)?=off([[:space:]]|$)' /proc/cmdline 2>/dev/null; then
  CMDLINE_DISABLE=1
fi

COMPLIANT=0
if [ "$NX_FLAG" -eq 1 ] && [ "$KERNEL_ACTIVE" -eq 1 ] && [ "$CMDLINE_DISABLE" -eq 0 ]; then
  COMPLIANT=1
fi

if [ "$MODE" = "fix" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: --fix requires root. Re-run with sudo." >&2
    exit 1
  fi
  if ! have_cmd grubby; then
    echo "Error: grubby not found. Install it: sudo dnf install -y grubby" >&2
    exit 1
  fi

  # Backup and remove disables from /etc/default/grub
  if [ -f /etc/default/grub ]; then
    cp -a /etc/default/grub /etc/default/grub.bak.$(date +%Y%m%d%H%M%S)
    sed -i 's/\bnoexec=off\b//g; s/\bnoexec32=off\b//g' /etc/default/grub
  fi

  # Force-enable NX on all installed kernels
  grubby --update-kernel=ALL --args="noexec=on"

  # Rebuild GRUB menu
  rebuild_grub || { echo "Error: grub2-mkconfig failed." >&2; exit 1; }

  echo "Applied: removed any noexec=off/noexec32=off, set noexec=on for all kernels. Reboot required."
fi

if [ "$MODE" = "revert" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: --revert requires root. Re-run with sudo." >&2
    exit 1
  fi
  if ! have_cmd grubby; then
    echo "Error: grubby not found. Install it: sudo dnf install -y grubby" >&2
    exit 1
  fi

  # Restore latest backup if present
  BAK="$(latest_grub_backup || true)"
  if [ -n "${BAK:-}" ] && [ -f "$BAK" ]; then
    if [ -f /etc/default/grub ]; then
      cp -a /etc/default/grub /etc/default/grub.pre-revert.$(date +%Y%m%d%H%M%S)
    fi
    cp -a "$BAK" /etc/default/grub
    echo "Restored /etc/default/grub from backup: $BAK"
  else
    # No backup to restore; best effort remove explicit enable from current config
    if [ -f /etc/default/grub ]; then
      sed -i 's/\bnoexec=on\b//g; s/\bnoexec32=on\b//g' /etc/default/grub || true
      echo "No backup found. Cleaned explicit noexec=on from /etc/default/grub if present."
    else
      echo "No backup found and /etc/default/grub missing. Skipping file restore."
    fi
  fi

  # Remove explicit enables from all installed kernels
  # Use separate calls so absence does not cause failure
  grubby --update-kernel=ALL --remove-args="noexec=on" || true
  grubby --update-kernel=ALL --remove-args="noexec32=on" || true
  grubby --update-kernel=ALL --remove-args="noexec" || true

  # Rebuild GRUB menu
  rebuild_grub || { echo "Error: grub2-mkconfig failed." >&2; exit 1; }

  echo "Reverted: restored GRUB defaults where possible and removed explicit noexec enables. Reboot required."
fi

if [ "$QUIET" -eq 1 ]; then
  echo "$COMPLIANT"
  [ "$COMPLIANT" -eq 1 ] && exit 0 || exit 1
fi

# Human-readable summary
printf "%-35s : %s\n" "CPU exposes NX (lscpu flag)"     "$([ "$NX_FLAG" -eq 1 ] && echo Yes || echo No)"
printf "%-35s : %s\n" "Kernel enabled NX (logs)"        "$([ "$KERNEL_ACTIVE" -eq 1 ] && echo Yes || echo No)"
printf "%-35s : %s\n" "Cmdline disables NX present"     "$([ "$CMDLINE_DISABLE" -eq 1 ] && echo Yes || echo No)"
printf "%-35s : %s\n" "RHEL-08-010420 compliant"        "$([ "$COMPLIANT" -eq 1 ] && echo Yes || echo No)"

[ "$COMPLIANT" -eq 1 ] && exit 0 || exit 1
