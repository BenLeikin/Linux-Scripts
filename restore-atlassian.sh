#!/usr/bin/env bash
#
# restore-atlassian.sh
# Companion to the Atlassian update script. Restores the most recent backup
# from /root/atlassian-config-backup back to its original location.
#
# Useful when an installer fails partway through and the update script's
# trailing restore step never runs.

set -uo pipefail

# -------- Config ----------
JIRA_SERVICE="jira"
CONFLUENCE_SERVICE="confluence"
BACKUP_ROOT="/root/atlassian-config-backup"
TIMESTAMP="$(date +%F_%H%M%S)"
LOG_FILE="/var/log/restore-atlassian-${TIMESTAMP}.log"

# Files the update script backs up. Keep these in sync with that script.
JIRA_BACKUPS=(
  "/opt/atlassian/jira/conf/server.xml"
  "/opt/atlassian/jira/jre/lib/security/cacerts"
  "/opt/atlassian/jira/bin/setenv.sh"
)
CONFLUENCE_BACKUPS=(
  "/opt/atlassian/confluence/conf/server.xml"
  "/opt/atlassian/confluence/jre/lib/security/cacerts"
  "/opt/atlassian/confluence/bin/setenv.sh"
)

need_jira="false"
need_confluence="false"
BACKUP_DIR=""

# -------- Helpers ----------
log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE" >&2; }

die() { log "ERROR: $*"; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run as root (use sudo)."
  fi
}

ensure_log() {
  mkdir -p "$(dirname "$LOG_FILE")" || true
  touch "$LOG_FILE" || true
}

find_latest_backup() {
  [[ -d "$BACKUP_ROOT" ]] || die "Backup root not found: $BACKUP_ROOT"

  # Timestamp dirs are named YYYY-MM-DD_HHMMSS, so version-sort gives newest last.
  local latest
  latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
            | sort -V | tail -n 1)"

  [[ -n "$latest" && -d "$latest" ]] || die "No backup directories found in $BACKUP_ROOT"
  echo "$latest"
}

restore_if_exists() {
  local backup_path="$1" target="$2"
  if [[ -e "$backup_path" ]]; then
    # Preserve the existing file before clobbering, in case the restore itself
    # is the wrong move and we need to walk it back.
    if [[ -e "$target" ]]; then
      cp -a "$target" "${target}.pre-restore-${TIMESTAMP}" \
        && log "Snapshot of current file: ${target} -> ${target}.pre-restore-${TIMESTAMP}"
    fi
    mkdir -p "$(dirname "$target")"
    cp -a "$backup_path" "$target"
    log "Restored: $backup_path -> $target"
  else
    log "No backup found for: $target (looked at $backup_path)"
  fi
}

restore_files() {
  local product="$1"; shift
  local -a files=( "$@" )
  log "Restoring ${product} files from ${BACKUP_DIR}/${product}"
  for f in "${files[@]}"; do
    local backup_path="${BACKUP_DIR}/${product}${f}"
    restore_if_exists "$backup_path" "$f"
  done
}

service_stop() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    log "systemctl stop ${svc}"
    systemctl stop "$svc" || log "WARN: failed to stop ${svc} (may already be down)"
  else
    log "service ${svc} stop"
    service "$svc" stop || log "WARN: failed to stop ${svc} (may already be down)"
  fi
}

service_start() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    log "systemctl start ${svc}"
    systemctl start "$svc" || die "Failed to start ${svc}"
  else
    log "service ${svc} start"
    service "$svc" start || die "Failed to start ${svc}"
  fi
}

restore_jira() {
  log "=== Restoring Jira ==="
  service_stop "$JIRA_SERVICE"
  restore_files "jira" "${JIRA_BACKUPS[@]}"
  service_start "$JIRA_SERVICE"
  log "Jira restore complete."
}

restore_confluence() {
  log "=== Restoring Confluence ==="
  service_stop "$CONFLUENCE_SERVICE"
  restore_files "confluence" "${CONFLUENCE_BACKUPS[@]}"
  service_start "$CONFLUENCE_SERVICE"
  log "Confluence restore complete."
}

print_help() {
  cat <<EOF
Usage: sudo $0 [--jira] [--confluence] [--all]

Restores the most recent backup from ${BACKUP_ROOT} to the original install
locations. Stops the service before copying, starts it after.

Options:
  --jira           Restore Jira config files.
  --confluence     Restore Confluence config files.
  --all            Restore both.
  -h, --help       Show this help.

Files restored (Jira):
  /opt/atlassian/jira/conf/server.xml
  /opt/atlassian/jira/jre/lib/security/cacerts
  /opt/atlassian/jira/bin/setenv.sh

Files restored (Confluence):
  /opt/atlassian/confluence/conf/server.xml
  /opt/atlassian/confluence/jre/lib/security/cacerts
  /opt/atlassian/confluence/bin/setenv.sh

Before each file is overwritten, the current version is saved alongside it as
<file>.pre-restore-<timestamp> so you can roll the restore back if needed.

Logs: ${LOG_FILE}
EOF
}

# -------- Parse args ----------
while (( "$#" )); do
  case "$1" in
    --jira) need_jira="true"; shift;;
    --confluence) need_confluence="true"; shift;;
    --all) need_jira="true"; need_confluence="true"; shift;;
    -h|--help) print_help; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

if [[ "$need_jira" != "true" && "$need_confluence" != "true" ]]; then
  print_help
  exit 1
fi

# -------- Main ----------
require_root
ensure_log

BACKUP_DIR="$(find_latest_backup)"
log "Starting Atlassian restore. Using backup dir: $BACKUP_DIR"

trap 'log "An error occurred during restore. Check the log: $LOG_FILE"' ERR

if [[ "$need_jira" == "true" ]]; then
  if [[ -d "${BACKUP_DIR}/jira" ]]; then
    restore_jira
  else
    log "WARN: no jira/ subdirectory inside ${BACKUP_DIR}; skipping Jira restore."
  fi
fi

if [[ "$need_confluence" == "true" ]]; then
  if [[ -d "${BACKUP_DIR}/confluence" ]]; then
    restore_confluence
  else
    log "WARN: no confluence/ subdirectory inside ${BACKUP_DIR}; skipping Confluence restore."
  fi
fi

log "All requested restores finished."
