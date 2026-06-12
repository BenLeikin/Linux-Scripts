#!/usr/bin/env bash

# Disk Health Monitoring & Alerting Script
# Requires: smartctl (from smartmontools), mail (or mailx)

# Discover all block devices (NVMe, SD and others)
DEVICES=($(lsblk -d -n -p -o NAME,TYPE | awk '$2=="disk"{print $1}'))

ALERT_EMAIL="admin@example.com"            # Email address for alerts
LOGFILE="/var/log/disk_health_monitor.log" # Log file path

# Ensure dependencies are available
if ! command -v smartctl &> /dev/null; then
  echo "[ERROR] smartctl not found. Please install smartmontools." >&2
  exit 1
fi
if ! command -v mail &> /dev/null; then
  echo "[WARNING] mail command not found. Alerts will not be sent via email." >&2
fi

# Function: send_alert
# Sends an email alert and logs the event
send_alert() {
  local device="$1"
  local status="$2"
  local stats="$3"
  local subject="[ALERT] Disk Health Issue on ${device}"
  local body="Device: ${device}\nStatus: ${status}\nStatistics:\n${stats}\nTime: $(date '+%Y-%m-%d %H:%M:%S')"

  # Log and display the alert
  echo -e "[ALERT] ${body}" | tee -a "${LOGFILE}"

  # Send email if mail is available
  if command -v mail &> /dev/null; then
    echo -e "${body}" | mail -s "${subject}" "${ALERT_EMAIL}"
  fi
}

# Function: log_and_echo
# Logs a message and outputs to screen
log_and_echo() {
  echo -e "$1" | tee -a "${LOGFILE}"
}

# Function: gather_stats
# Extracts key SMART attributes: Temperature, Power-On Hours, Reallocated Sectors
gather_stats() {
  local dev="$1"
  # Use smartctl -A and grep for attribute IDs
  local temp=$(smartctl -A "$dev" | awk '/Temperature_Celsius/ {print $10 " C"}')
  local hours=$(smartctl -A "$dev" | awk '/Power_On_Hours/ {print $10 " h"}')
  local realloc=$(smartctl -A "$dev" | awk '/Reallocated_Sector_Ct/ {print $10}')
  echo -e "Temperature: ${temp:-N/A}\nPower-On Hours: ${hours:-N/A}\nReallocated Sector Count: ${realloc:-N/A}"
}

# Function: log_header
# Prints a header with timestamp to the log file
log_header() {
  local header="============================================="$'\n'
  header+="Disk Health Check: $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
  log_and_echo "$header"
}

# Main routine
main() {
  log_header
  for DEV in "${DEVICES[@]}"; do
    # Check overall health
    local health_out=$(smartctl -H "${DEV}" 2>&1)
    local overall=$(echo "$health_out" | awk -F":" '/SMART overall-health/ {print $2}' | xargs)

    # Gather additional stats
    local stats=$(gather_stats "$DEV")

    if [[ "${overall,,}" != "passed" ]]; then
      send_alert "$DEV" "$overall" "$stats"
    else
      log_and_echo "${DEV}: HEALTH PASSED\n${stats}\n"
    fi
  done
}

main
exit 0
