#!/bin/bash

DRY_RUN=0
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|-n)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--dry-run|-n] <dnf_hosts_file> <apt_hosts_file>

Options:
  --dry-run, -n    Show what would be done without executing
  -h, --help       Show this help

Environment variables:
  MAX_PARALLEL     Max concurrent SSH sessions (default 50)
  WAIT_TIMEOUT     Per-host timeout in seconds (default 1800)
  POLL_INTERVAL    Poll frequency in seconds (default 15)
EOF
            exit 0
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

DNF_FILE="${POSITIONAL[0]:-dnf_hosts.txt}"
APT_FILE="${POSITIONAL[1]:-apt_hosts.txt}"
MAX_PARALLEL="${MAX_PARALLEL:-50}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-1800}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

if [[ ! -f "$DNF_FILE" ]] || [[ ! -f "$APT_FILE" ]]; then
    echo "Error: host file(s) not found"
    echo "Run $0 --help for usage"
    exit 1
fi

count_hosts() {
    local file=$1
    grep -cvE '^[[:space:]]*(#|$)' "$file"
}

if [[ $DRY_RUN -eq 1 ]]; then
    echo "========================================"
    echo "            DRY RUN MODE"
    echo "========================================"
    echo ""
    echo "No SSH connections will be made."
    echo ""
    echo "Configuration:"
    echo "  DNF hosts file:  $DNF_FILE ($(count_hosts "$DNF_FILE") hosts)"
    echo "  APT hosts file:  $APT_FILE ($(count_hosts "$APT_FILE") hosts)"
    echo "  Max parallel:    $MAX_PARALLEL"
    echo "  Timeout:         ${WAIT_TIMEOUT}s"
    echo "  Poll interval:   ${POLL_INTERVAL}s"
    echo ""
    echo "----------------------------------------"
    echo "Hosts that would run: yum update -y"
    echo "----------------------------------------"
    while IFS= read -r host || [[ -n "$host" ]]; do
        [[ -z "$host" || "$host" =~ ^[[:space:]]*# ]] && continue
        echo "  $host"
    done < "$DNF_FILE"

    echo ""
    echo "----------------------------------------"
    echo "Hosts that would run: apt update -y && apt upgrade -y"
    echo "----------------------------------------"
    while IFS= read -r host || [[ -n "$host" ]]; do
        [[ -z "$host" || "$host" =~ ^[[:space:]]*# ]] && continue
        echo "  $host"
    done < "$APT_FILE"

    echo ""
    echo "----------------------------------------"
    echo "Example SSH commands that would execute:"
    echo "----------------------------------------"
    first_dnf=$(grep -vE '^[[:space:]]*(#|$)' "$DNF_FILE" | head -1)
    first_apt=$(grep -vE '^[[:space:]]*(#|$)' "$APT_FILE" | head -1)

    if [[ -n "$first_dnf" ]]; then
        echo ""
        echo "For $first_dnf (dispatch):"
        echo "  ssh -q $first_dnf \"tmux send-keys -t 0 'yum update -y; echo \\\$? > /tmp/claude_update_exit_PID; echo MARKER' ENTER\""
        echo ""
        echo "For $first_dnf (poll, every ${POLL_INTERVAL}s):"
        echo "  ssh -q $first_dnf \"tmux capture-pane -t 0 -p -S -200\""
        echo ""
        echo "For $first_dnf (fetch exit code after marker found):"
        echo "  ssh -q $first_dnf \"cat /tmp/claude_update_exit_PID; rm -f /tmp/claude_update_exit_PID\""
    fi

    if [[ -n "$first_apt" ]]; then
        echo ""
        echo "For $first_apt (dispatch):"
        echo "  ssh -q $first_apt \"tmux send-keys -t 0 'apt update -y && apt upgrade -y; echo \\\$? > /tmp/claude_update_exit_PID; echo MARKER' ENTER\""
    fi

    echo ""
    echo "========================================"
    echo "Dry run complete. Re-run without --dry-run to execute."
    echo "========================================"
    exit 0
fi

RESULTS_DIR=$(mktemp -d)
LOGS_DIR=$(mktemp -d)
trap "rm -rf $RESULTS_DIR" EXIT

echo "Results dir: $RESULTS_DIR"
echo "Logs dir: $LOGS_DIR (preserved on exit for review)"
echo "Max parallel: $MAX_PARALLEL, Timeout: ${WAIT_TIMEOUT}s"
echo ""

run_update() {
    local host=$1
    local cmd=$2
    local result_file="$RESULTS_DIR/$host"
    local log_file="$LOGS_DIR/$host.log"
    local marker="UPDATE_DONE_$$_$RANDOM"
    local exit_file="/tmp/claude_update_exit_$$"

    local remote_cmd="tmux send-keys -t 0 '$cmd; echo \$? > $exit_file; echo $marker' ENTER"

    if ! ssh -q -o LogLevel=QUIET -o ConnectTimeout=10 -o BatchMode=yes \
            "$host" "$remote_cmd" >"$log_file" 2>&1; then
        echo "[$host] SSH failed on dispatch" | tee -a "$log_file"
        echo "FAIL_SSH_DISPATCH" > "$result_file"
        return
    fi

    echo "[$host] dispatched, polling for completion"

    local elapsed=0
    local found=0
    while [[ $elapsed -lt $WAIT_TIMEOUT ]]; do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))

        local pane
        pane=$(ssh -q -o LogLevel=QUIET -o ConnectTimeout=10 -o BatchMode=yes \
                "$host" "tmux capture-pane -t 0 -p -S -200" 2>>"$log_file")
        local ssh_rc=$?

        if [[ $ssh_rc -ne 0 ]]; then
            echo "[$host] SSH failed during poll (rc=$ssh_rc), continuing"
            continue
        fi

        if echo "$pane" | grep -q "$marker"; then
            found=1
            break
        fi
    done

    if [[ $found -eq 0 ]]; then
        echo "[$host] TIMEOUT after ${WAIT_TIMEOUT}s"
        echo "FAIL_TIMEOUT" > "$result_file"
        return
    fi

    local exit_code
    exit_code=$(ssh -q -o LogLevel=QUIET -o ConnectTimeout=10 -o BatchMode=yes \
                "$host" "cat $exit_file 2>/dev/null; rm -f $exit_file" 2>>"$log_file")

    ssh -q -o LogLevel=QUIET -o ConnectTimeout=10 -o BatchMode=yes \
        "$host" "tmux capture-pane -t 0 -p -S -2000" >> "$log_file" 2>&1

    if [[ -z "$exit_code" ]]; then
        echo "[$host] could not retrieve exit code"
        echo "FAIL_NO_EXIT_CODE" > "$result_file"
    elif [[ "$exit_code" == "0" ]]; then
        echo "[$host] SUCCESS"
        echo "SUCCESS" > "$result_file"
    else
        echo "[$host] FAIL (exit=$exit_code)"
        echo "FAIL_EXIT_$exit_code" > "$result_file"
    fi
}

process_hosts() {
    local file=$1
    local cmd=$2

    while IFS= read -r host || [[ -n "$host" ]]; do
        [[ -z "$host" || "$host" =~ ^[[:space:]]*# ]] && continue

        while [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]]; do
            sleep 1
        done

        run_update "$host" "$cmd" &
    done < "$file"
}

START=$(date +%s)

process_hosts "$DNF_FILE" "yum update -y"
process_hosts "$APT_FILE" "apt update -y && apt upgrade -y"

wait

END=$(date +%s)
DURATION=$((END - START))

echo ""
echo "========================================"
echo "            SUMMARY"
echo "========================================"
echo "Total runtime: ${DURATION}s"
echo ""

declare -A buckets
for result_file in "$RESULTS_DIR"/*; do
    [[ -f "$result_file" ]] || continue
    host=$(basename "$result_file")
    status=$(cat "$result_file")
    buckets["$status"]+="$host "
done

success_count=0
fail_count=0

for status in "${!buckets[@]}"; do
    hosts="${buckets[$status]}"
    count=$(echo $hosts | wc -w)
    echo ""
    echo "$status ($count):"
    for h in $hosts; do
        echo "  $h"
    done
    if [[ "$status" == "SUCCESS" ]]; then
        success_count=$count
    else
        fail_count=$((fail_count + count))
    fi
done

echo ""
echo "Total: $success_count succeeded, $fail_count failed"
echo "Per-host logs in: $LOGS_DIR"

[[ $fail_count -eq 0 ]]