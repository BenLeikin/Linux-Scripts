#!/usr/bin/env bash
# Enforce RHEL 8 STIG permissions for user homes
# - RHEL-08-010730: home dirs must be <= 0750 (cap by removing disallowed bits)
# - RHEL-08-010731: contents of home dirs must be <= 0750
#                   Do not add execute to regular files
# - RHEL-08-010770: local initialization files (top-level dotfiles in $HOME)
#                   must be <= 0740
#
# Usage:
#   ./stig_homes.sh          # enforce
#   ./stig_homes.sh --check  # dry run, print what would change; exits 1 if changes needed

set -euo pipefail

CHECK=0
if [[ "${1:-}" == "--check" ]]; then
  CHECK=1
fi

# Get local interactive users' home dirs (UID >=1000 and shell not nologin/false)
mapfile -t HOMES < <(awk -F: '($3>=1000)&&($7 !~ /(nologin|false)/){print $6}' /etc/passwd | sort -u)

changes=0

do_chmod() {
  # do_chmod <mode> <path...>
  local mode="$1"; shift
  if (( CHECK )); then
    while IFS= read -r -d '' p; do
      printf "[CHANGE] chmod %s %q (was %s)\n" "$mode" "$p" "$(stat -c '%a' "$p")"
      ((changes++))
    done
  else
    # shellcheck disable=SC2046
    xargs -0 -r chmod -c "$mode" <<<"$(printf '%s\0' "$@")" || true
  fi
}

for HOME in "${HOMES[@]}"; do
  [[ -d "$HOME" ]] || continue
  echo "==> Checking $HOME"

  # 010730: cap home dir at 0750 by removing disallowed bits (do not add bits)
  if (( CHECK )); then
    if find "$HOME" -maxdepth 0 -type d \( -perm /0007 -o -perm /0020 \) -print -quit | grep -q .; then
      printf "[CHANGE] chmod g-w,o-rwx %q (was %s)\n" "$HOME" "$(stat -c '%a' "$HOME")"
      ((changes++))
    fi
  else
    chmod -c g-w,o-rwx "$HOME" || true
  fi

  # 010731: Directories under $HOME must not have group write or any other perms
  # Select only noncompliant directories
  if (( CHECK )); then
    while IFS= read -r -d '' d; do
      printf "[CHANGE] chmod g-w,o-rwx %q (was %s)\n" "$d" "$(stat -c '%a' "$d")"
      ((changes++))
    done < <(find "$HOME" -mindepth 1 -type d \( -perm /0007 -o -perm /0020 \) -print0)
  else
    find "$HOME" -mindepth 1 -type d \( -perm /0007 -o -perm /0020 \) -print0 \
      | xargs -0 -r chmod -c g-w,o-rwx || true
  fi

  # 010731: Regular files under $HOME (excluding top-level dotfiles)
  # Must not have group write/exec or any other perms
  if (( CHECK )); then
    while IFS= read -r -d '' f; do
      printf "[CHANGE] chmod g-wx,o-rwx %q (was %s)\n" "$f" "$(stat -c '%a' "$f")"
      ((changes++))
    done < <(find "$HOME" -mindepth 1 \
                  \( -maxdepth 1 -type f -name '.*' -prune \) -o \
                  \( -type f \( -perm /0023 -o -perm /0007 \) -print0 \))
  else
    find "$HOME" -mindepth 1 \
         \( -maxdepth 1 -type f -name '.*' -prune \) -o \
         \( -type f \( -perm /0023 -o -perm /0007 \) -print0 \) \
      | xargs -0 -r chmod -c g-wx,o-rwx || true
  fi

  # 010770: Top-level dotfiles must be <= 0740
  if (( CHECK )); then
    while IFS= read -r -d '' df; do
      printf "[CHANGE] chmod g-wx,o-rwx %q (was %s)\n" "$df" "$(stat -c '%a' "$df")"
      ((changes++))
    done < <(find "$HOME" -maxdepth 1 -type f -name '.*' \
                  \( -perm /0020 -o -perm /0010 -o -perm /0007 \) -print0)
  else
    find "$HOME" -maxdepth 1 -type f -name '.*' \
         \( -perm /0020 -o -perm /0010 -o -perm /0007 \) -print0 \
      | xargs -0 -r chmod -c g-wx,o-rwx || true
  fi
done

if (( CHECK )); then
  if (( changes == 0 )); then
    echo "All good. No changes needed."
    exit 0
  else
    echo "Total items that would change: $changes"
    exit 1
  fi
fi
