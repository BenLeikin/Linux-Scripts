#!/bin/bash
# fw-port-sync.sh
# Checks all non-loopback listening TCP ports and ensures they're open in firewalld.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must be run as root." >&2
    exit 1
fi

if ! firewall-cmd --state &>/dev/null; then
    echo "ERROR: firewalld is not running." >&2
    exit 1
fi

if ! command -v ss &>/dev/null; then
    echo "ERROR: ss not found (install iproute2)." >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Args
# --------------------------------------------------------------------------- #

DRY_RUN=0
ZONE=""

usage() {
    echo "Usage: $(basename "$0") [--dry-run] [--zone <zone>]"
    echo ""
    echo "  --dry-run       Preview changes without modifying firewalld"
    echo "  --zone <zone>   Target a specific firewalld zone (default: default zone)"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=1 ;;
        --zone)      shift; ZONE="$1" ;;
        -h|--help)   usage ;;
        *)           echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
    shift
done

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #

ZONE="${ZONE:-$(firewall-cmd --get-default-zone)}"
CHANGES=0

# Ports to always ignore regardless of what's listening.
# 111  - rpcbind: no reason to expose this
SKIP_PORTS=
(
111
112
)

# --------------------------------------------------------------------------- #
# Build a set of already-allowed ports (services + explicit port rules)
# --------------------------------------------------------------------------- #

declare -A ALLOWED_PORTS

# Ports covered by active service definitions
for svc in $(firewall-cmd --zone="${ZONE}" --list-services 2>/dev/null); do
    while read -r portproto; do
        [[ -z "$portproto" ]] && continue
        port="${portproto%%/*}"
        ALLOWED_PORTS["$port"]=1
    done < <(firewall-cmd --service="${svc}" --get-ports 2>/dev/null || true)
done

# Ports explicitly opened in the zone
for portproto in $(firewall-cmd --zone="${ZONE}" --list-ports 2>/dev/null); do
    port="${portproto%%/*}"
    ALLOWED_PORTS["$port"]=1
done

# --------------------------------------------------------------------------- #
# Parse non-loopback listening TCP ports from ss
# --------------------------------------------------------------------------- #

mapfile -t LISTEN_PORTS < <(
    ss -tlnp 2>/dev/null | awk '
    NR > 1 {
        addr = $4

        # Skip loopback-only bindings
        if (addr ~ /^127\./)
            next

        # Skip all IPv6 (includes ::1, [::], [::ffff:127.x.x.x], etc.)
        if (addr ~ /^\[/ || addr == "::1")
            next

        # Extract port: strip everything up to and including the last colon
        port = addr
        gsub(/.*:/, "", port)

        # Sanity check: must be numeric
        if (port ~ /^[0-9]+$/)
            print port
    }' | sort -nu
)

# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #

echo "Zone      : ${ZONE}"
echo "Dry run   : $([ "${DRY_RUN}" = "1" ] && echo yes || echo no)"
echo "=========================================="

for port in "${LISTEN_PORTS[@]}"; do
    # Check against the hardcoded ignore list
    skip=0
    for ignored in "${SKIP_PORTS[@]}"; do
        if [[ "$port" == "$ignored" ]]; then
            skip=1
            break
        fi
    done
    if [[ $skip -eq 1 ]]; then
        printf "[SKIP] %5s/tcp  on ignore list\n" "${port}"
        continue
    fi

    if [[ -n "${ALLOWED_PORTS[$port]+_}" ]]; then
        printf "[OK]  %5s/tcp  already allowed\n" "${port}"
    else
        printf "[ADD] %5s/tcp  not in firewalld" "${port}"
        if [[ "${DRY_RUN}" == "1" ]]; then
            printf "  (dry run, skipping)\n"
        else
            printf "  -- adding...\n"
            firewall-cmd --zone="${ZONE}" --permanent --add-port="${port}/tcp" > /dev/null
            CHANGES=$(( CHANGES + 1 ))
        fi
    fi
done

echo "=========================================="

if [[ "${DRY_RUN}" == "1" ]]; then
    echo "Dry run complete. No changes made."
elif [[ ${CHANGES} -gt 0 ]]; then
    echo "Reloading firewalld to apply ${CHANGES} change(s)..."
    firewall-cmd --reload > /dev/null
    echo "Done."
else
    echo "No changes needed."
fi