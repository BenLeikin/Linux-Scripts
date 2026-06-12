#!/usr/bin/env bash
set -euo pipefail

# system_health_report.sh
# One-page health report of a Linux server, with OS detection,
# usage thresholds, service checks, and extended diagnostics.

# Thresholds (percent)
CPU_THRESHOLD=75         # total or per-core CPU usage
MEM_THRESHOLD=75         # memory usage
DISK_THRESHOLD=80        # percent used on any filesystem
# Load threshold = number of cores * LOAD_COEF
LOAD_COEF=1

# Critical services to check
SERVICES=(sshd nginx mysql)

# ANSI color codes
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
RED=$'\e[31m'
RESET=$'\e[0m'

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID,,}" in
      ubuntu|debian)                OS_FAMILY=debian ;;
      rhel|centos|fedora|rocky|ol) OS_FAMILY=rhel   ;;
      *)                            OS_FAMILY=other  ;;
    esac
  else
    OS_FAMILY=other
  fi
}

print_header() {
  echo -e "${GREEN}System Health Report for $(hostname) @ $(date '+%F %T')${RESET}"
  echo
}

usage() {
  cat <<EOF
Usage: $0 [-h]
  -h    Show this help
EOF
  exit 0
}

check_deps() {
  for cmd in hostname date uptime awk free df ps ip systemctl nproc; do
    command -v "$cmd" &>/dev/null || {
      echo -e "${RED}Missing dependency:${RESET} $cmd" >&2
      exit 1
    }
  done
}

report_os() {
  echo -e "${YELLOW}OS Information:${RESET}"
  if command -v lsb_release &>/dev/null; then
    lsb_release -a
  else
    awk -F= '/^NAME|^VERSION/ {print $1 ": " $2}' /etc/os-release
  fi
  echo
}

report_uptime_load() {
  echo -e "${YELLOW}Uptime and Load:${RESET}"
  uptime
  local load1
  load1=$(awk '{print $1}' /proc/loadavg)
  local cores max_load flag
  cores=$(nproc)
  max_load=$(( cores * LOAD_COEF ))
  flag=$GREEN
  awk -v l="$load1" -v m="$max_load" 'BEGIN { exit (l>m) }' && flag=$RED
  printf "  Load 1min: %b%s%s (threshold %d×%d=%d)%b\n\n" \
    "$flag" "$load1" "$RESET" "$LOAD_COEF" "$cores" "$max_load" "$RESET"
}

report_cpu() {
  echo -e "${YELLOW}CPU Usage:${RESET}"
  local total flag
  total=$(awk '/^cpu /{printf "%.0f", (1-($5/($2+$3+$4+$5)))*100}' /proc/stat)
  flag=$GREEN
  (( total>=CPU_THRESHOLD )) && flag=$RED
  printf "  Total: %b%3s%%%s\n" "$flag" "$total" "$RESET"
  awk -v th=$CPU_THRESHOLD -v g="$GREEN" -v r="$RED" -v z="$RESET" \
    '/^cpu[0-9]/ {
       sum=$2+$3+$4+$5
       used=(sum-$5)/sum*100
       flag=(used>=th?r:g)
       printf "  %s: %b%3.0f%%%s\n", $1, flag, used, z
     }' /proc/stat
  echo
}

report_memory() {
  echo -e "${YELLOW}Memory Usage:${RESET}"
  local total used buff used_pct flag
  read -r _ total used _ buff _ <<<"$(free -k | awk '/^Mem:/ {print $2, $3, $6}')"
  used_pct=$(( (used+buff)*100/total ))
  flag=$GREEN
  (( used_pct>=MEM_THRESHOLD )) && flag=$RED
  free -h --si
  printf "  Usage: %b%3s%%%s (threshold %d%%)%b\n\n" \
    "$flag" "$used_pct" "$RESET" "$MEM_THRESHOLD" "$RESET"
}

report_swap_io() {
  echo -e "${YELLOW}Swap & I/O Wait:${RESET}"
  free -h --si
  if command -v vmstat &>/dev/null; then
    local wa
    wa=$(vmstat 1 2 | tail -1 | awk '{print $16}')
    echo "  I/O wait: ${wa}%"
  else
    echo "  vmstat not installed"
  fi
  echo
}

report_disk() {
  echo -e "${YELLOW}Disk Usage:${RESET}"
  df -h --output=source,size,used,avail,pcent,target | tail -n +2 | \
  while read fs size used avail pcent mnt; do
    local pct flag
    pct=${pcent%\%}
    flag=$GREEN
    (( pct>=DISK_THRESHOLD )) && flag=$RED
    printf "  %b%3s%%%s %-20s size:%6s used:%6s avail:%6s\n" \
      "$flag" "$pct" "$RESET" "$mnt" "$size" "$used" "$avail"
  done
  echo
}

report_top_procs() {
  echo -e "${YELLOW}Top Processes:${RESET}"
  echo "  By CPU:";    ps -eo pid,ppid,cmd,%cpu --sort=-%cpu | head -6
  echo; echo "  By Memory:"; ps -eo pid,ppid,cmd,%mem --sort=-%mem | head -6
  echo
}

report_zombies() {
  echo -e "${YELLOW}Zombie Processes:${RESET}"
  local z
  z=$(ps -eo stat | grep -c Z || echo 0)
  echo "  Count: $z"
  echo
}

report_network() {
  echo -e "${YELLOW}Network Interfaces & IPs:${RESET}"
  ip -brief addr | awk '{ printf "  %s: %s\n", $1, ($3==""?"none":$3) }'
  echo; echo -e "${YELLOW}Interface Stats:${RESET}"; ip -s link; echo
  echo -e "${YELLOW}Active TCP Ports:${RESET}"
  if command -v ss &>/dev/null; then
    ss -tln
  else
    netstat -tln
  fi
  echo
}

report_logged_in() {
  echo -e "${YELLOW}Logged In Users:${RESET}"
  who
  echo
}

report_services() {
  echo -e "${YELLOW}Configured Services:${RESET}"
  for s in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$s"; then
      echo -e "  $s: ${GREEN}running${RESET}"
    else
      echo -e "  $s: ${RED}stopped${RESET}"
    fi
  done
  echo
}

report_all_services() {
  echo -e "${YELLOW}All Running Services:${RESET}"
  systemctl list-units --type=service --state=running --no-legend --no-pager \
    | awk '{print "  "$1}'
  echo
}

report_ntp() {
  echo -e "${YELLOW}NTP Sync Status:${RESET}"
  if command -v timedatectl &>/dev/null; then
    timedatectl status | sed -n '/System clock synchronized/,/RTC time/p'
  elif command -v chronyc &>/dev/null; then
    echo "  Tracking:"; chronyc tracking | sed 's/^/    /'
    echo "  Sources:";  chronyc sources -v | sed 's/^/    /'
  elif command -v ntpq &>/dev/null; then
    echo "  Sources:";  ntpq -p | sed 's/^/    /'
  else
    echo "  NTP tools not installed"
  fi
  echo
}

report_updates() {
  echo -e "${YELLOW}Pending Updates:${RESET}"
  case "$OS_FAMILY" in
    debian)
      if command -v apt-get &>/dev/null; then
        apt list --upgradable 2>/dev/null | tail -n +2 || echo "  none"
      else
        echo "  apt-get not installed"
      fi
      ;;
    rhel)
      if command -v yum &>/dev/null; then
        yum check-update || echo "  none"
      else
        echo "  yum not installed"
      fi
      ;;
    *)
      echo "  update check unsupported on $OS_FAMILY"
      ;;
  esac
  echo
}

report_smart() {
  echo -e "${YELLOW}SMART Health:${RESET}"
  if command -v smartctl &>/dev/null; then
    for d in /dev/sd?; do
      printf "  %s: " "$d"
      smartctl -H "$d" 2>/dev/null | awk -F: '/overall-health/ {print $2}'
    done
  else
    echo "  smartctl not installed"
  fi
  echo
}

report_cert_expiry() {
  echo -e "${YELLOW}Certificate Expirations:${RESET}"
  if ! command -v openssl &>/dev/null; then
    echo "  openssl not installed"
    echo
    return
  fi

  mapfile -t certs < <(find /etc/ssl -type f \( -name '*.crt' -o -name '*.pem' \) 2>/dev/null)
  if (( ${#certs[@]} == 0 )); then
    echo "  no certificate files found under /etc/ssl"
  else
    local found=0
    for f in "${certs[@]}"; do
      expiry=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2)
      if [[ -n "$expiry" ]]; then
        printf "  %s: %s\n" "$f" "$expiry"
        found=1
      fi
    done
    (( found == 0 )) && echo "  no valid X.509 certificates to check"
  fi
  echo
}

report_journal_errors() {
  echo -e "${YELLOW}Journal Errors:${RESET}"
  if ! command -v journalctl &>/dev/null; then
    echo "  journalctl not installed"
    echo
    return
  fi

  local out
  out=$(journalctl -p err..alert -n 20 --no-pager 2>&1)
  if [[ -z "$out" ]]; then
    echo "  no journal errors in the last 20 entries"
  elif grep -qi "insufficient permissions" <<<"$out"; then
    echo "  insufficient permissions to read system journal"
    echo "  run as root or add your user to the 'systemd-journal' group"
  else
    echo "$out"
  fi
  echo
}

report_raid() {
  echo -e "${YELLOW}RAID/MD Status:${RESET}"
  if [[ -f /proc/mdstat ]]; then
    cat /proc/mdstat
  else
    echo "  No software RAID detected"
  fi
  echo
}

report_containers() {
  echo -e "${YELLOW}Containers & Pods:${RESET}"
  if command -v docker &>/dev/null; then
    echo "  Docker:"; docker ps --format '    {{.Names}}: {{.Status}}'
  else
    echo "  docker not installed"
  fi
  if command -v podman &>/dev/null; then
    echo "  Podman:"; podman ps --format '    {{.Names}}: {{.Status}}'
  else
    echo "  podman not installed"
  fi
  if command -v kubectl &>/dev/null; then
    echo "  Kubernetes Pods:"
    kubectl get pods --all-namespaces --no-headers \
      -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase'
  else
    echo "  kubectl not installed"
  fi
  echo
}

main() {
  [[ "${1:-}" == "-h" ]] && usage
  detect_os
  check_deps
  print_header

  report_os
  report_uptime_load
  report_cpu
  report_memory
  report_swap_io
  report_disk
  report_top_procs
  report_zombies
  report_network
  report_logged_in
  report_services
  report_all_services

  report_ntp
  report_updates
  report_smart
  report_cert_expiry
  report_journal_errors
  report_raid
  report_containers
}

main "$@"
