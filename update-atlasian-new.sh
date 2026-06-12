#!/usr/bin/env bash
# update-atlassian.sh
# Updates Jira Core, Jira Software, and/or Confluence using .bin installers in /tmp.
# Backs up & restores key config files around the update.
#
# Usage examples:
#   sudo ./update-atlassian.sh --jira-core
#   sudo ./update-atlassian.sh --jira-software
#   sudo ./update-atlassian.sh --jira              # runs core then software
#   sudo ./update-atlassian.sh --confluence
#   sudo ./update-atlassian.sh --all
#   sudo ./update-atlassian.sh --jira-core --quiet --varfile /root/jira-response.varfile
#
# Notes:
# - Installers in /tmp must be named like:
#     /tmp/atlassian-jira-core-<version>.bin
#     /tmp/atlassian-jira-software-<version>.bin
#     /tmp/atlassian-confluence-<version>.bin
# - By default runs in console mode (-c). With --quiet and --varfile, runs silently (-q -varfile).

set -euo pipefail

# -------- Config you can tweak ----------
JIRA_SERVICE="jira"
CONFLUENCE_SERVICE="confluence"
BACKUP_ROOT="/root/atlassian-config-backup"
TIMESTAMP="$(date +%F_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
LOG_FILE="/var/log/update-atlassian-${TIMESTAMP}.log"

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

QUIET="false"
VARFILE=""

need_jira_core="false"
need_jira_software="false"
need_confluence="false"

# -------- Helpers ----------
log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE" >&2; }

die() { log "ERROR: $*"; exit 1; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run as root (use sudo)."
  fi
}

ensure_dirs() {
  mkdir -p "$BACKUP_DIR"
  mkdir -p "$(dirname "$LOG_FILE")" || true
  touch "$LOG_FILE" || true
}

copy_if_exists() {
  local src="$1" dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    log "Backed up: $src -> $dst"
  else
    log "Skipping missing file (not found): $src"
  fi
}

restore_if_exists() {
  local backup_path="$1" target="$2"
  if [[ -e "$backup_path" ]]; then
    cp -a "$backup_path" "$target"
    log "Restored: $backup_path -> $target"
  else
    log "No backup found to restore for: $target"
  fi
}

backup_files() {
  local product="$1"; shift
  local -a files=( "$@" )
  log "Backing up ${product} files to ${BACKUP_DIR}/${product}"
  for f in "${files[@]}"; do
    local target="${BACKUP_DIR}/${product}${f}"
    copy_if_exists "$f" "$target"
  done
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

chmod_installers() {
  if compgen -G "/tmp/atlassian-*.bin" > /dev/null; then
    chmod +x /tmp/atlassian-*.bin || true
    log "Marked /tmp/atlassian-*.bin as executable."
  else
    log "No installers matched /tmp/atlassian-*.bin"
  fi
}

latest_installer() {
  local pattern="$1"
  local latest
  latest="$(ls -1v ${pattern} 2>/dev/null | tail -n 1 || true)"
  echo "$latest"
}

run_installer() {
  local path="$1"
  if [[ -z "$path" || ! -f "$path" ]]; then
    die "Installer not found: $path"
  fi

  if [[ "$QUIET" == "true" ]]; then
    if [[ -n "$VARFILE" ]]; then
      log "Running (quiet) installer: $path"
      "$path" -q -varfile "$VARFILE" | tee -a "$LOG_FILE"
    else
      log "Running (quiet, no varfile) installer: $path"
      "$path" -q | tee -a "$LOG_FILE"
    fi
  else
    log "Running (console) installer: $path"
    "$path" -c | tee -a "$LOG_FILE"
  fi
}

service_stop() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    log "systemctl stop ${svc}"
    systemctl stop "$svc"
  else
    log "service ${svc} stop"
    service "$svc" stop
  fi
}

service_start() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    log "systemctl start ${svc}"
    systemctl start "$svc"
  else
    log "service ${svc} start"
    service "$svc" start
  fi
}

# -------- Product update functions ----------

update_jira_core() {
  log "=== Updating Jira Core ==="
  backup_files "jira" "${JIRA_BACKUPS[@]}"
  service_stop "$JIRA_SERVICE"

  local core_bin
  core_bin="$(latest_installer "/tmp/atlassian-jira-core-*.bin")"
  [[ -n "$core_bin" ]] || die "No Jira Core installer found in /tmp (pattern: atlassian-jira-core-*.bin)"

  run_installer "$core_bin"

  restore_files "jira" "${JIRA_BACKUPS[@]}"
  service_start "$JIRA_SERVICE"
  log "Jira Core update complete."
}

update_jira_software() {
  log "=== Updating Jira Software ==="
  backup_files "jira" "${JIRA_BACKUPS[@]}"
  service_stop "$JIRA_SERVICE"

  local software_bin
  software_bin="$(latest_installer "/tmp/atlassian-jira-software-*.bin")"
  [[ -n "$software_bin" ]] || die "No Jira Software installer found in /tmp (pattern: atlassian-jira-software-*.bin)"

  run_installer "$software_bin"

  restore_files "jira" "${JIRA_BACKUPS[@]}"
  service_start "$JIRA_SERVICE"
  log "Jira Software update complete."
}

update_jira_all() {
  log "=== Updating Jira (Core then Software) ==="
  backup_files "jira" "${JIRA_BACKUPS[@]}"
  service_stop "$JIRA_SERVICE"

  local core_bin software_bin
  core_bin="$(latest_installer "/tmp/atlassian-jira-core-*.bin")"
  software_bin="$(latest_installer "/tmp/atlassian-jira-software-*.bin")"

  [[ -n "$core_bin" ]]     || die "No Jira Core installer found in /tmp (pattern: atlassian-jira-core-*.bin)"
  [[ -n "$software_bin" ]] || die "No Jira Software installer found in /tmp (pattern: atlassian-jira-software-*.bin)"

  run_installer "$core_bin"
  run_installer "$software_bin"

  restore_files "jira" "${JIRA_BACKUPS[@]}"
  service_start "$JIRA_SERVICE"
  log "Jira Core + Software update complete."
}

update_confluence() {
  log "=== Updating Confluence ==="
  backup_files "confluence" "${CONFLUENCE_BACKUPS[@]}"
  service_stop "$CONFLUENCE_SERVICE"

  local confl_bin
  confl_bin="$(latest_installer "/tmp/atlassian-confluence-*.bin")"
  [[ -n "$confl_bin" ]] || die "No Confluence installer found in /tmp (pattern: atlassian-confluence-*.bin)"

  run_installer "$confl_bin"

  restore_files "confluence" "${CONFLUENCE_BACKUPS[@]}"
  service_start "$CONFLUENCE_SERVICE"
  log "Confluence update complete."
}

print_help() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

Switches (can be combined):
  --jira-core      Update Jira Core only.
  --jira-software  Update Jira Software only.
  --jira           Update Jira Core then Software (equivalent to both above).
  --confluence     Update Confluence.
  --all            Update Jira (Core + Software) and Confluence.
  --quiet          Run installers quietly (-q). Often requires a response varfile.
  --varfile PATH   Response file for quiet install (Install4J-style -varfile).
  -h, --help       Show this help.

Examples:
  sudo $0 --jira-core
  sudo $0 --jira-software
  sudo $0 --jira
  sudo $0 --jira-core --jira-software   # same as --jira
  sudo $0 --confluence
  sudo $0 --all
  sudo $0 --jira-core --quiet --varfile /root/jira-response.varfile

What gets backed up (Jira & Confluence):
  <app>/conf/server.xml
  <app>/jre/lib/security/cacerts
  <app>/bin/setenv.sh

Backups stored under: ${BACKUP_DIR}
Logs: ${LOG_FILE}
EOF
}

# -------- Parse args ----------
while (( "$#" )); do
  case "$1" in
    --jira-core)     need_jira_core="true"; shift;;
    --jira-software) need_jira_software="true"; shift;;
    --jira)          need_jira_core="true"; need_jira_software="true"; shift;;
    --confluence)    need_confluence="true"; shift;;
    --all)           need_jira_core="true"; need_jira_software="true"; need_confluence="true"; shift;;
    --quiet)         QUIET="true"; shift;;
    --varfile)       VARFILE="${2:-}"; [[ -n "${VARFILE:-}" ]] || die "--varfile requires a path"; shift 2;;
    -h|--help)       print_help; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

if [[ "$need_jira_core" != "true" && "$need_jira_software" != "true" && "$need_confluence" != "true" ]]; then
  print_help
  exit 1
fi

# -------- Main ----------
require_root
ensure_dirs
log "Starting Atlassian update. Backup dir: $BACKUP_DIR"
chmod_installers

trap 'log "An error occurred. Check the log: $LOG_FILE"' ERR

# Run Jira as a combined operation if both are requested (one stop/start cycle)
if [[ "$need_jira_core" == "true" && "$need_jira_software" == "true" ]]; then
  update_jira_all
elif [[ "$need_jira_core" == "true" ]]; then
  update_jira_core
elif [[ "$need_jira_software" == "true" ]]; then
  update_jira_software
fi

if [[ "$need_confluence" == "true" ]]; then
  update_confluence
fi

log "All requested updates finished successfully."