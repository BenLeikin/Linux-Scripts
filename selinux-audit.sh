#!/usr/bin/env bash
# selinux-helper.sh
# Identify SELinux denials and generate exemption rules
# Requires: audit2allow, audit2why, semodule (policycoreutils), ausearch

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

AUDIT_LOG="/var/log/audit/audit.log"
MODULE_DIR="/tmp/selinux_modules"

# ─── Helpers ────────────────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[ERROR]${RESET} This script must be run as root."
        exit 1
    fi
}

require_cmds() {
    local missing=()
    for cmd in audit2allow audit2why ausearch semodule sestatus; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}[ERROR]${RESET} Missing required commands: ${missing[*]}"
        echo "       Install with: dnf install policycoreutils policycoreutils-python-utils"
        exit 1
    fi
}

print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo -e "${BOLD}${CYAN}  SELinux Denial Analyzer & Rule Helper ${RESET}"
    echo -e "${BOLD}${CYAN}========================================${RESET}"
    echo ""
}

selinux_status_check() {
    local mode
    mode=$(getenforce)
    echo -e "${BOLD}SELinux Status:${RESET}"
    sestatus | grep -E "^SELinux status|^SELinuxfs mount|^Current mode|^Mode from config"
    echo ""
    if [[ "$mode" == "Disabled" ]]; then
        echo -e "${RED}[WARN]${RESET} SELinux is disabled. Nothing to do."
        exit 0
    fi
    if [[ "$mode" == "Permissive" ]]; then
        echo -e "${YELLOW}[INFO]${RESET} SELinux is in Permissive mode -- denials are logged but not enforced."
        echo ""
    fi
}

# ─── Denial Fetching ────────────────────────────────────────────────────────

fetch_recent_denials() {
    local since="${1:-today}"
    echo -e "${BOLD}Fetching AVC denials (since: $since)...${RESET}"

    local raw
    if [[ "$since" == "all" ]]; then
        raw=$(ausearch -m avc,user_avc -i 2>/dev/null || true)
    else
        raw=$(ausearch -m avc,user_avc -i --start "$since" 2>/dev/null || true)
    fi

    if [[ -z "$raw" ]]; then
        echo -e "${GREEN}[OK]${RESET} No AVC denials found for the specified period."
        return 1
    fi

    echo "$raw"
    return 0
}

count_denials() {
    local since="${1:-today}"
    local count
    if [[ "$since" == "all" ]]; then
        count=$(ausearch -m avc,user_avc 2>/dev/null | grep -c "type=AVC" || echo 0)
    else
        count=$(ausearch -m avc,user_avc --start "$since" 2>/dev/null | grep -c "type=AVC" || echo 0)
    fi
    echo "$count"
}

# ─── Summary View ───────────────────────────────────────────────────────────

show_denial_summary() {
    local since="${1:-today}"
    echo -e "${BOLD}=== Denial Summary (since: $since) ===${RESET}"
    echo ""

    local raw
    raw=$(ausearch -m avc,user_avc --start "$since" -i 2>/dev/null || true)

    if [[ -z "$raw" ]]; then
        echo -e "${GREEN}[OK]${RESET} No denials found."
        return
    fi

    # Extract and summarize unique source/target/permission combos
    echo "$raw" | grep "type=AVC" | \
        grep -oP "(scontext|tcontext|tclass|\{[^}]+\})=[^\s]+" | \
        awk '
            /scontext/ { split($0,a,"="); sctx=a[2] }
            /tcontext/ { split($0,a,"="); tctx=a[2] }
            /tclass/   { split($0,a,"="); cls=a[2] }
        ' || true

    # Cleaner summary using audit2allow -w style
    echo -e "${BOLD}Unique denial signatures:${RESET}"
    echo ""
    if [[ "$since" == "all" ]]; then
        ausearch -m avc,user_avc 2>/dev/null | \
            audit2allow 2>/dev/null | \
            grep -v "^#" | grep -v "^$" || echo "  (none parsed)"
    else
        ausearch -m avc,user_avc --start "$since" 2>/dev/null | \
            audit2allow 2>/dev/null | \
            grep -v "^#" | grep -v "^$" || echo "  (none parsed)"
    fi
    echo ""
}

# ─── Human-Readable Explanations ────────────────────────────────────────────

explain_denials() {
    local since="${1:-today}"
    echo -e "${BOLD}=== Human-Readable Explanations (audit2why) ===${RESET}"
    echo ""

    if [[ "$since" == "all" ]]; then
        ausearch -m avc,user_avc 2>/dev/null | audit2why 2>/dev/null || true
    else
        ausearch -m avc,user_avc --start "$since" 2>/dev/null | audit2why 2>/dev/null || true
    fi
    echo ""
}

# ─── Filter by Process ──────────────────────────────────────────────────────

filter_by_process() {
    local procname="$1"
    local since="${2:-today}"
    echo -e "${BOLD}=== Denials for process: $procname (since: $since) ===${RESET}"
    echo ""

    local raw
    if [[ "$since" == "all" ]]; then
        raw=$(ausearch -m avc,user_avc -i --comm "$procname" 2>/dev/null || true)
    else
        raw=$(ausearch -m avc,user_avc -i --comm "$procname" --start "$since" 2>/dev/null || true)
    fi

    if [[ -z "$raw" ]]; then
        echo -e "${GREEN}[OK]${RESET} No denials found for process: $procname"
        return
    fi

    echo "$raw"
    echo ""
    echo -e "${BOLD}Suggested rules:${RESET}"
    if [[ "$since" == "all" ]]; then
        ausearch -m avc,user_avc --comm "$procname" 2>/dev/null | audit2allow -w 2>/dev/null || true
        echo ""
        ausearch -m avc,user_avc --comm "$procname" 2>/dev/null | audit2allow 2>/dev/null || true
    else
        ausearch -m avc,user_avc --comm "$procname" --start "$since" 2>/dev/null | audit2allow -w 2>/dev/null || true
        echo ""
        ausearch -m avc,user_avc --comm "$procname" --start "$since" 2>/dev/null | audit2allow 2>/dev/null || true
    fi
}

# ─── Generate & Install Policy Module ───────────────────────────────────────

generate_module() {
    local module_name="$1"
    local since="${2:-today}"

    mkdir -p "$MODULE_DIR"
    local te_file="$MODULE_DIR/${module_name}.te"
    local mod_file="$MODULE_DIR/${module_name}.mod"
    local pp_file="$MODULE_DIR/${module_name}.pp"

    echo -e "${BOLD}=== Generating policy module: $module_name ===${RESET}"
    echo ""

    # Generate .te file
    if [[ "$since" == "all" ]]; then
        ausearch -m avc,user_avc 2>/dev/null | \
            audit2allow -M "$module_name" -d 2>/dev/null || {
            echo -e "${RED}[ERROR]${RESET} Failed to generate module. No denials to process?"
            return 1
        }
    else
        ausearch -m avc,user_avc --start "$since" 2>/dev/null | \
            audit2allow -M "$module_name" -d 2>/dev/null || {
            echo -e "${RED}[ERROR]${RESET} Failed to generate module. No denials to process?"
            return 1
        }
    fi

    # audit2allow -M writes to cwd, move them
    mv -f "${module_name}.te" "$te_file" 2>/dev/null || true
    mv -f "${module_name}.pp" "$pp_file" 2>/dev/null || true

    echo -e "${GREEN}[OK]${RESET} Generated policy files:"
    echo "     Type enforcement: $te_file"
    echo "     Compiled module:  $pp_file"
    echo ""
    echo -e "${BOLD}=== Policy content (.te) ===${RESET}"
    cat "$te_file"
    echo ""
}

install_module() {
    local module_name="$1"
    local pp_file="$MODULE_DIR/${module_name}.pp"

    if [[ ! -f "$pp_file" ]]; then
        echo -e "${RED}[ERROR]${RESET} Module file not found: $pp_file"
        echo "       Run --generate first."
        return 1
    fi

    echo -e "${YELLOW}[WARN]${RESET} You are about to install SELinux policy module: $module_name"
    echo "       This will allow the denied operations that were logged."
    echo ""
    read -r -p "Proceed with installation? [y/N] " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "Aborted."
        return 0
    fi

    semodule -i "$pp_file" && \
        echo -e "${GREEN}[OK]${RESET} Module '$module_name' installed successfully." || \
        echo -e "${RED}[ERROR]${RESET} Failed to install module."

    echo ""
    echo "To remove this module later:"
    echo "  semodule -r $module_name"
}

generate_and_preview_for_process() {
    local procname="$1"
    local since="${2:-today}"
    local module_name="local_${procname//[^a-zA-Z0-9]/_}"

    echo -e "${BOLD}=== Targeted module for process: $procname ===${RESET}"
    echo ""

    mkdir -p "$MODULE_DIR"

    if [[ "$since" == "all" ]]; then
        ausearch -m avc,user_avc --comm "$procname" 2>/dev/null | \
            audit2allow -M "$module_name" -d 2>/dev/null || {
            echo -e "${RED}[ERROR]${RESET} No denials found for process: $procname"
            return 1
        }
    else
        ausearch -m avc,user_avc --comm "$procname" --start "$since" 2>/dev/null | \
            audit2allow -M "$module_name" -d 2>/dev/null || {
            echo -e "${RED}[ERROR]${RESET} No denials found for process: $procname (since: $since)"
            return 1
        }
    fi

    mv -f "${module_name}.te" "$MODULE_DIR/${module_name}.te" 2>/dev/null || true
    mv -f "${module_name}.pp" "$MODULE_DIR/${module_name}.pp" 2>/dev/null || true

    echo -e "${BOLD}Generated .te content:${RESET}"
    cat "$MODULE_DIR/${module_name}.te"
    echo ""
    echo -e "${BOLD}Module files written to:${RESET} $MODULE_DIR/"
    echo ""
    echo "To install: $0 --install $module_name"
}

# ─── List Installed Custom Modules ──────────────────────────────────────────

list_modules() {
    echo -e "${BOLD}=== Installed SELinux Policy Modules ===${RESET}"
    echo ""
    semodule -l 2>/dev/null | column -t
    echo ""
}

# ─── Watch Mode ─────────────────────────────────────────────────────────────

watch_denials() {
    echo -e "${BOLD}=== Watching for new SELinux denials (Ctrl+C to stop) ===${RESET}"
    echo ""
    tail -F "$AUDIT_LOG" 2>/dev/null | grep --line-buffered "type=AVC" | while IFS= read -r line; do
        echo -e "${YELLOW}[AVC]${RESET} $(date '+%H:%M:%S') -- $line"
    done
}

# ─── Usage ──────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --status                     Show SELinux status
  --summary [since]            Summarize all denials (default: today)
  --explain [since]            Human-readable explanations via audit2why
  --filter <proc> [since]      Show & explain denials for a specific process/command
  --generate [module] [since]  Generate a .te/.pp policy module from all denials
  --generate-for <proc> [since] Generate targeted module for a specific process
  --install <module_name>      Install a previously generated .pp module
  --list-modules               List all installed policy modules
  --watch                      Live-tail audit.log for new denials
  --help                       Show this help

Time formats for [since]:
  today        Denials since midnight (default)
  recent       Last 10 minutes
  yesterday    Since yesterday midnight
  all          All time (full audit log)
  "MM/DD/YYYY HH:MM:SS"  Specific timestamp

Examples:
  $(basename "$0") --summary
  $(basename "$0") --summary all
  $(basename "$0") --explain today
  $(basename "$0") --filter httpd today
  $(basename "$0") --generate-for nginx all
  $(basename "$0") --generate my_custom_policy all
  $(basename "$0") --install my_custom_policy
  $(basename "$0") --watch

Notes:
  - Generated modules are saved to: $MODULE_DIR/
  - Always review .te files before installing -- only allow what you need
  - Prefer targeted modules (--generate-for) over blanket policy installs
  - In permissive mode, denials are still logged even though they aren't blocked
EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    require_root
    require_cmds
    print_header
    selinux_status_check

    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    case "$1" in
        --status)
            # Already printed by selinux_status_check
            ;;
        --summary)
            show_denial_summary "${2:-today}"
            ;;
        --explain)
            explain_denials "${2:-today}"
            ;;
        --filter)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 --filter <process_name> [since]"; exit 1; }
            filter_by_process "$2" "${3:-today}"
            ;;
        --generate)
            local modname="${2:-local_selinux_exceptions}"
            local since="${3:-today}"
            generate_module "$modname" "$since"
            echo "To install: $0 --install $modname"
            ;;
        --generate-for)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 --generate-for <process_name> [since]"; exit 1; }
            generate_and_preview_for_process "$2" "${3:-today}"
            ;;
        --install)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 --install <module_name>"; exit 1; }
            install_module "$2"
            ;;
        --list-modules)
            list_modules
            ;;
        --watch)
            watch_denials
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo -e "${RED}[ERROR]${RESET} Unknown option: $1"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"