#!/bin/bash
# Quiet update for NoMachine Terminal Server
# - Logs to /var/log/update_nomachine.log
# - Minimal terminal output only if run interactively
# - Safe to run from cron

set -uo pipefail

LOGFILE="/var/log/update_nomachine.log"
RPM_PATH="/nomachine-terminal-server_8.14.2_1_x86_64.rpm"
LOCK="/var/lock/update_nomachine.lock"

# Pick package manager
if command -v yum >/dev/null 2>&1; then
  PM="yum"
  PM_REMOVE="yum -y -q remove"
elif command -v dnf >/dev/null 2>&1; then
  PM="dnf"
  PM_REMOVE="dnf -y -q remove"
else
  echo "No yum/dnf found" >&2
  exit 1
fi

# Only echo to terminal if interactive
log_term() {
  if [ -t 1 ]; then
    echo "$@"
  fi
}
# Always append to logfile
log_file() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOGFILE"
}

# Ensure logfile exists
touch "$LOGFILE" 2>/dev/null || {
  echo "Cannot write $LOGFILE" >&2
  exit 1
}

# Single instance lock
exec 9>"$LOCK"
if ! flock -n 9; then
  log_file "Another instance is running. Exiting."
  exit 0
fi

log_file "Starting NoMachine Terminal Server update with $PM"
log_term "Starting NoMachine update..."

# Validate RPM path
if [ ! -f "$RPM_PATH" ]; then
  log_file "RPM not found at $RPM_PATH"
  exit 1
fi

# Remove if installed
if rpm -q nomachine-terminal-server >/dev/null 2>&1; then
  $PM_REMOVE nomachine-terminal-server >>"$LOGFILE" 2>&1 || {
    log_file "Removal failed"
    exit 1
  }
  log_file "Removed existing nomachine-terminal-server"
  log_term "Removed existing package"
else
  log_file "Package not installed. Skipping removal."
fi

# Install quietly
if rpm -i --quiet "$RPM_PATH" >>"$LOGFILE" 2>&1; then
  log_file "Installed from $RPM_PATH"
  log_term "Installation complete"
else
  log_file "Install failed from $RPM_PATH"
  exit 1
fi

log_file "Update finished"
log_term "Done."
exit 0
