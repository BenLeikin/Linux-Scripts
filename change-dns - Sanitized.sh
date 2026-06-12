#!/bin/bash

#############################################################################################
#                        Written by Ben Leikin                                              #
#                        Bug fixes by Claude                                                #
#                                                                                           #
#                                                                                           #
# Purpose: Detects current method of assigning DNS and then Updates DNS and Domain entries  #
#                                                                                           #
# How to use: Place in /root, chmod +x, then run with ./change-dns.sh                       #
#                                                                                           #
#############################################################################################

# DNS servers in priority order
DNS_SERVERS=(
    ""
    ""
)

# Parse args
SKIP_CONFIRM=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)
            SKIP_CONFIRM=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--yes]"
            echo "  --yes, -y   Skip confirmation prompt"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

echo "DNS servers to apply (in order):"
printf '  %s\n' "${DNS_SERVERS[@]}"
echo

if [[ $SKIP_CONFIRM -eq 0 ]]; then
    read -p "Proceed? [y/N] " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && exit 0
    echo
fi

set -e
ts=$(date +%Y%m%d-%H%M%S)
RESOLV=/etc/resolv.conf

# Detect mode
MODE="static"
if [[ -L "$RESOLV" ]]; then
    target=$(readlink -f "$RESOLV")
    if [[ "$target" == *systemd* || "$target" == */run/* ]]; then
        MODE="systemd-resolved"
    fi
fi

echo "Mode detected: $MODE"

if [[ "$MODE" == "systemd-resolved" ]]; then
    mkdir -p /etc/systemd/resolved.conf.d

    # Remove stale drop-ins that set DNS, skipping our own
    for f in /etc/systemd/resolved.conf.d/*.conf; do
        [[ -e "$f" ]] || continue
        [[ "$f" == "/etc/systemd/resolved.conf.d/99-custom-dns.conf" ]] && continue
        if grep -qE "^DNS=" "$f"; then
            echo "  Removing stale drop-in: $f"
            cp -a "$f" "${f}.bak.${ts}"
            rm -f "$f"
        fi
    done

    DROPIN=/etc/systemd/resolved.conf.d/99-custom-dns.conf
    [[ -f "$DROPIN" ]] && cp -a "$DROPIN" "${DROPIN}.bak.${ts}"
    cat > "$DROPIN" <<RESOLVEDEOF
# Managed by dns-push script - $(date)
[Resolve]
DNS=${DNS_SERVERS[*]}
FallbackDNS=
RESOLVEDEOF

    systemctl restart systemd-resolved
    sleep 1
    echo
    echo "--- resolvectl status (Global) ---"
    resolvectl status | sed -n '/^Global/,/^Link/p' | head -15
else
    # Static mode: rewrite /etc/resolv.conf
    if [[ -f "$RESOLV" ]]; then
        cp -a "$RESOLV" "${RESOLV}.bak.${ts}"
    fi
    preserved=""
    if [[ -f "${RESOLV}.bak.${ts}" ]]; then
        preserved=$(grep -E "^(search|domain|options)[[:space:]]" "${RESOLV}.bak.${ts}" || true)
    fi
    {
        echo "# Managed by dns-push script - $(date)"
        [[ -n "$preserved" ]] && echo "$preserved"
        for ns in "${DNS_SERVERS[@]}"; do
            echo "nameserver $ns"
        done
    } > "$RESOLV"
    chmod 644 "$RESOLV"

    # Update resolvconf head if present
    if [[ -d /etc/resolvconf/resolv.conf.d ]]; then
        HEAD=/etc/resolvconf/resolv.conf.d/head
        [[ -s "$HEAD" ]] && cp -a "$HEAD" "${HEAD}.bak.${ts}"
        {
            echo "# Managed by dns-push script - $(date)"
            for ns in "${DNS_SERVERS[@]}"; do
                echo "nameserver $ns"
            done
        } > "$HEAD"
    fi
    echo
    echo "--- /etc/resolv.conf ---"
    cat "$RESOLV"
fi

echo
echo "Done. Backups saved with timestamp .${ts}"