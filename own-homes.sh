#!/usr/bin/env bash
# own-all-homes.sh
# Recursively chown each home directory to user:"domain users"
# By default scans /home. You can pass -r for more roots.
# Usage: sudo ./own-all-homes.sh [-n] [-f] [-v] [-g GROUP] [-r ROOT ...]
#   -n   Dry run
#   -f   Force. Do not skip homes that already look correct
#   -v   Verbose
#   -g   Group name to use. Default: "domain users"
#   -r   Root directory to scan for home dirs. Can be given multiple times

set -euo pipefail

GROUP="domain users"
DRYRUN=0
FORCE=0
VERBOSE=0
ROOTS=()

usage() {
  echo "Usage: $0 [-n] [-f] [-v] [-g GROUP] [-r ROOT ...]" >&2
  exit 2
}

log() { [ "$VERBOSE" -eq 1 ] && echo "$@"; }

while getopts ":nfg:vr:" opt; do
  case "$opt" in
    n) DRYRUN=1 ;;
    f) FORCE=1 ;;
    v) VERBOSE=1 ;;
    g) GROUP="$OPTARG" ;;
    r) ROOTS+=("$OPTARG") ;;
    *) usage ;;
  endcase
done
shift $((OPTIND-1))

# Default to /home if no roots were provided
if [ "${#ROOTS[@]}" -eq 0 ]; then
  ROOTS=("/home")
fi

# Validate group and get numeric GID to avoid issues with spaces
if ! getent group "$GROUP" >/dev/null; then
  echo "Error: group '$GROUP' not found." >&2
  exit 1
fi
GID="$(getent group "$GROUP" | cut -d: -f3)"

# Safety guard so nobody passes /
for root in "${ROOTS[@]}"; do
  case "$root" in
    "/"|"") echo "Refusing to scan root '$root'"; exit 1 ;;
  esac
done

errors=0
processed=0
skipped=0

for root in "${ROOTS[@]}"; do
  # Resolve path and ensure it exists
  root="$(readlink -f "$root" || true)"
  [ -n "$root" ] && [ -d "$root" ] || { echo "Skip missing root: $root"; continue; }

  log "Scanning $root"

  # Only consider immediate subdirectories as homes
  while IFS= read -r -d '' dir; do
    home="$(basename "$dir")"

    # Skip obvious non-homes
    case "$home" in
      ""|"lost+found"|.*) log "Skip $dir"; continue ;;
    esac

    user="$home"

    # Verify the user exists
    if ! getent passwd "$user" >/dev/null; then
      echo "Skip $dir. User '$user' not found."
      ((skipped++)) || true
      continue
    fi

    # Optionally skip if already owned as expected
    if [ "$FORCE" -ne 1 ]; then
      # Check top directory owner and group name to decide quickly
      current_owner="$(stat -c '%U:%G' "$dir" || echo unknown:unknown)"
      if [ "$current_owner" = "$user:$GROUP" ]; then
        log "Already owned: $dir by $current_owner"
        ((skipped++)) || true
        continue
      fi
    fi

    cmd=(chown -R -h "$user:$GID" "$dir")

    if [ "$DRYRUN" -eq 1 ]; then
      printf 'Dry run: '
      printf '%q ' "${cmd[@]}"
      printf '\n'
    else
      if "${cmd[@]}"; then
        echo "Owned: $dir -> $user:'$GROUP'"
      else
        echo "Error owning: $dir" >&2
        ((errors++)) || true
      fi
    fi

    ((processed++)) || true
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0)
done

echo "Summary: processed=$processed skipped=$skipped errors=$errors"
exit $errors
