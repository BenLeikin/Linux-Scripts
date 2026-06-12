#!/usr/bin/env bash
# patroni_ha_demo.sh
# HA validation runner for a 3-node Patroni + etcd + HAProxy + Keepalived PostgreSQL cluster
# Scenarios:
#   - Primary failure (stop Patroni on leader)
#   - Replica failure (stop Patroni on a replica)
#   - VIP carrier failure (stop Keepalived + HAProxy on VIP holder)
#   - etcd member failure (stop etcd on a random node)
#   - Planned switchover (patronictl switchover to a chosen replica)
#   - Full host reboot (reboot current leader)
#   - Network partition (block etcd port on leader using iptables)
# Each scenario:
#   - Captures initial snapshot
#   - Starts a background write loop via VIP
#   - Injects failure
#   - Measures RTO (time to first successful write after failure)
#   - Captures reaction snapshot
#   - Restores and verifies
#   - Captures restored snapshot
#   - Summarizes results
#Options:
#  -n            Dry run. Snapshot and print actions but do not disrupt services.
#  -q            Quiet. Reduce logging.
#  -t scenario   primary | replica | vip | etcd | switchover | reboot | netpartition | all
#  -D            Enable auto-discovery (same as AUTO_DISCOVER=true)
#  -s seed_host  Hostname or IP of any cluster node to seed discovery

set -euo pipefail

############################
# CONFIGURATION
############################

# Cluster nodes (used if AUTO_DISCOVER=false). Use resolvable hostnames or IPs.
NODES=(pg01 pg02 pg03)

# SSH user used to administer the nodes
SSH_USER="admin"

# Patroni control command. Must work on PATRONI_CTL_NODE.
PATRONI_CTL_NODE="${NODES[0]:-}"
PATRONICTL_CMD="patronictl -c /etc/patroni/patroni.yml"

# PostgreSQL access through the VIP (can be auto-discovered)
VIP=""
PGPORT="5432"
PGDATABASE="postgres"
PGUSER="postgres"
# Provide auth via .pgpass or export PGPASSWORD before running

# HAProxy stats (can be auto-discovered)
HAPROXY_STATS_SOCKET=""                # e.g. /var/lib/haproxy/stats
HAPROXY_STATS_URL=""                   # e.g. http://127.0.0.1:8404/;csv
HAPROXY_STATS_AUTH=""                  # "user:pass" if needed

# etcdctl endpoints (can be auto-discovered)
ETCDCTL_API="3"
ETCDCTL_ENDPOINTS=""                   # e.g. https://pg01:2379,https://pg02:2379,https://pg03:2379
ETCDCTL_CACERT="/etc/etcd/ca.crt"
ETCDCTL_CERT="/etc/etcd/etcd.crt"
ETCDCTL_KEY="/etc/etcd/etcd.key"

# Services
SVC_PATRONI="patroni"
SVC_KEEPALIVED="keepalived"
SVC_HAPROXY="haproxy"
SVC_ETCD="etcd"

# Script behavior
ARTIFACTS_DIR_BASE="${PWD}/ha_artifacts"
POLL_INTERVAL_SECS=2
LEADER_ELECTION_TIMEOUT_SECS=180
REJOIN_TIMEOUT_SECS=240
SSH_DOWN_TIMEOUT_SECS=120
SSH_UP_TIMEOUT_SECS=300
DRY_RUN="false"
VERBOSE="true"

# Auto-discovery settings
AUTO_DISCOVER="true"       # set to "false" to keep static config
SEED_HOST=""               # optional. if empty, uses PATRONI_CTL_NODE
REQUIRE_JQ="false"         # set to "true" to fail if jq is missing

############################
# PATHS AND RUNTIME
############################

RUN_ID="$(date +%Y%m%d_%H%M%S)"
ART_RUN="${ARTIFACTS_DIR_BASE}/${RUN_ID}"
ART_INIT="${ART_RUN}/phase_initial"
ART_FAIL="${ART_RUN}/phase_failover"
ART_REST="${ART_RUN}/phase_restored"
SUMMARY_FILE="${ART_RUN}/summary.txt"

STOPPED_SERVICES=()     # "node:service"
BLOCKED_ETCD_NODES=()   # nodes where we applied iptables block
WRITE_LOOP_PID=""
WRITE_LOOP_LOG=""
HAVE_JQ="false"

############################
# LOGGING AND UTILS
############################

ensure_dirs() {
  mkdir -p "${ART_INIT}" "${ART_FAIL}" "${ART_REST}"
  mkdir -p "$(dirname "${SUMMARY_FILE}")"
  : > "${SUMMARY_FILE}"
}

log() {
  local ts; ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "[$ts] $*" | tee -a "${SUMMARY_FILE}"
}

vlog() {
  if [[ "${VERBOSE}" == "true" ]]; then
    log "$@"
  fi
}

die() {
  log "FATAL: $*"
  exit 1
}

now_epoch() { date +%s; }

# Local save helper
save_local() {
  local outfile="$1"; shift
  "$@" > "${outfile}" 2>&1 || true
}

############################
# AUTH: sudo helpers
############################

# If the remote allows passwordless sudo, we will use that.
# Else we prompt once and stream the password to sudo via STDIN.

SUDO_MODE="auto"  # auto | nopass | pass
SUDO_PASS=""

prompt_sudo_password() {
  if [[ -n "${SUDO_PASS}" ]]; then return; fi
  read -rsp "Enter sudo password for ${SSH_USER}: " SUDO_PASS
  echo
}

ssh_base() {
  # Add -tt if your sudoers requires a TTY
  echo "-o BatchMode=yes -o StrictHostKeyChecking=accept-new"
}

run_remote() {
  local node="$1"; shift
  # shellcheck disable=SC2046
  ssh $(ssh_base) "${SSH_USER}@${node}" "$@"
}

run_remote_sudo() {
  local node="$1"; shift
  if [[ "${SUDO_MODE}" == "nopass" ]]; then
    # shellcheck disable=SC2046
    ssh $(ssh_base) "${SSH_USER}@${node}" "sudo -n bash -lc $(printf '%q ' "$@")"
  else
    prompt_sudo_password
    # shellcheck disable=SC2046
    ssh $(ssh_base) "${SSH_USER}@${node}" "sudo -S -p '' bash -lc $(printf '%q ' "$@")" <<<"${SUDO_PASS}"
  fi
}

save_remote() {
  local node="$1"; local outfile="$2"; shift 2
  run_remote "${node}" "$@" > "${outfile}" 2>&1 || true
}

save_remote_sudo() {
  local node="$1"; local outfile="$2"; shift 2
  if [[ "${SUDO_MODE}" == "nopass" ]]; then
    # shellcheck disable=SC2046
    ssh $(ssh_base) "${SSH_USER}@${node}" "sudo -n bash -lc $(printf '%q ' "$@")" > "${outfile}" 2>&1 || true
  else
    prompt_sudo_password
    # shellcheck disable=SC2046
    ssh $(ssh_base) "${SSH_USER}@${node}" "sudo -S -p '' bash -lc $(printf '%q ' "$@")" <<<"${SUDO_PASS}" > "${outfile}" 2>&1 || true
  fi
}

############################
# AUTO-DISCOVERY
############################

discover_requirements() {
  if command -v jq >/dev/null 2>&1; then
    HAVE_JQ="true"
  else
    HAVE_JQ="false"
    if [[ "${REQUIRE_JQ}" == "true" ]]; then
      die "jq is required for auto-discovery"
    fi
  fi

  if [[ -z "${SEED_HOST}" || "${SEED_HOST}" == "auto" ]]; then
    if [[ -n "${PATRONI_CTL_NODE}" ]]; then
      SEED_HOST="${PATRONI_CTL_NODE}"
    else
      die "Set SEED_HOST or PATRONI_CTL_NODE for discovery"
    fi
  fi

  run_remote "${SEED_HOST}" true || die "Cannot SSH to SEED_HOST=${SEED_HOST} as ${SSH_USER}"
}

discover_nodes_from_patroni() {
  vlog "Discovering nodes via Patroni on ${SEED_HOST}"
  local out
  if out="$(run_remote_sudo "${SEED_HOST}" "${PATRONICTL_CMD} list --format=json" 2>/dev/null)"; then
    if [[ "${HAVE_JQ}" == "true" ]]; then
      mapfile -t DISC_NAMES < <(printf '%s' "${out}" | jq -r '.[].Member' 2>/dev/null)
      mapfile -t DISC_HOSTS < <(printf '%s' "${out}" | jq -r '.[].Host'   2>/dev/null)
    else
      mapfile -t DISC_NAMES < <(printf '%s' "${out}" | awk -F'"' '/"Member"/{print $4}')
      mapfile -t DISC_HOSTS < <(printf '%s' "${out}" | awk -F'"' '/"Host"/{print $4}')
    fi
  else
    out="$(run_remote_sudo "${SEED_HOST}" "${PATRONICTL_CMD} list" 2>/dev/null)" || die "Failed to run patronictl list on ${SEED_HOST}"
    mapfile -t DISC_NAMES < <(printf '%s\n' "${out}" | awk 'NR>1 && $1 ~ /^[A-Za-z0-9_.-]+$/ {print $1}')
    mapfile -t DISC_HOSTS < <(printf '%s\n' "${out}" | awk 'NR>1 && $2 ~ /^[A-Za-z0-9_.:-]+$/ {print $2}')
  fi

  if (( ${#DISC_HOSTS[@]} == 0 )); then
    die "Auto-discovery found no Patroni members"
  fi

  NODES=("${DISC_HOSTS[@]}")
  if [[ -z "${PATRONI_CTL_NODE}" ]]; then
    PATRONI_CTL_NODE="${SEED_HOST}"
  fi

  vlog "Discovered ${#NODES[@]} nodes: ${NODES[*]}"
}

discover_vip_from_keepalived() {
  vlog "Attempting VIP discovery from Keepalived configs"
  declare -A vip_counts=()
  for n in "${NODES[@]}"; do
    local confs=("/etc/keepalived/keepalived.conf" "/etc/keepalived/keepalived.d")
    for path in "${confs[@]}"; do
      run_remote_sudo "${n}" "test -e ${path}" || continue
      local ips
      ips="$(run_remote_sudo "${n}" "awk '
        /virtual_ipaddress/ { inblock=1; next }
        /\}/ { inblock=0 }
        inblock && match(\$0, /([0-9]{1,3}\\.){3}[0-9]{1,3}/, a) { print a[0] }
      ' ${path} 2>/dev/null || true")"
      if [[ -n "${ips}" ]]; then
        while read -r ip; do
          [[ -z "${ip}" ]] && continue
          vip_counts["$ip"]=$(( ${vip_counts["$ip"]:-0} + 1 ))
        done <<< "${ips}"
      fi
    done
  done

  if (( ${#vip_counts[@]} == 0 )); then
    vlog "No VIP found in Keepalived configs; will try runtime detection later"
    return 0
  fi

  local best_ip=""; local best_count=0
  for ip in "${!vip_counts[@]}"; do
    if (( vip_counts["$ip"] > best_count )); then
      best_ip="$ip"; best_count=${vip_counts["$ip"]}
    fi
  done
  if [[ -n "${best_ip}" && -z "${VIP}" ]]; then
    VIP="${best_ip}"
    vlog "VIP candidate from config: ${VIP} (seen on ${best_count} node config(s))"
  fi
}

discover_haproxy_stats() {
  vlog "Attempting HAProxy stats discovery"
  for n in "${NODES[@]}"; do
    local cfg="/etc/haproxy/haproxy.cfg"
    run_remote_sudo "${n}" "test -f ${cfg}" || continue

    if [[ -z "${HAPROXY_STATS_SOCKET}" ]]; then
      local sock
      sock="$(run_remote_sudo "${n}" "grep -E 'stats[[:space:]]+socket[[:space:]]' ${cfg} | awk '{for(i=1;i<=NF;i++) if(\$i ~ /^\\//) print \$i}' | head -n1" 2>/dev/null || true)"
      [[ -n "${sock}" ]] && HAPROXY_STATS_SOCKET="${sock}"
    fi

    if [[ -z "${HAPROXY_STATS_URL}" ]]; then
      local uri bind
      uri="$(run_remote_sudo "${n}" "grep -E 'stats[[:space:]]+uri[[:space:]]' ${cfg} | awk '{print \$NF}' | head -n1" 2>/dev/null || true)"
      bind="$(run_remote_sudo "${n}" "grep -E '^[[:space:]]*bind[[:space:]]' ${cfg} | grep -E ':[0-9]+' | awk '{print \$2}' | head -n1" 2>/dev/null || true)"
      if [[ -n "${uri}" && -n "${bind}" ]]; then
        HAPROXY_STATS_URL="${HAPROXY_STATS_URL:-http://${bind}${uri}}"
      fi
    fi

    if [[ -n "${HAPROXY_STATS_SOCKET}" || -n "${HAPROXY_STATS_URL}" ]]; then
      vlog "HAProxy stats detected on ${n}: socket='${HAPROXY_STATS_SOCKET}' url='${HAPROXY_STATS_URL}'"
      return 0
    fi
  done
}

discover_etcd_endpoints() {
  vlog "Building etcd endpoints from discovered hosts"
  if [[ -z "${ETCDCTL_ENDPOINTS}" || "${ETCDCTL_ENDPOINTS}" == "auto" ]]; then
    local eps=()
    for h in "${NODES[@]}"; do
      eps+=("https://${h}:2379")
    done
    ETCDCTL_ENDPOINTS="$(IFS=,; echo "${eps[*]}")"
    vlog "ETCDCTL_ENDPOINTS=${ETCDCTL_ENDPOINTS}"
  fi

  local base="ETCDCTL_API=${ETCDCTL_API} etcdctl --endpoints=${ETCDCTL_ENDPOINTS}"
  if [[ -n "${ETCDCTL_CACERT:-}" && -n "${ETCDCTL_CERT:-}" && -n "${ETCDCTL_KEY:-}" ]]; then
    base="${base} --cacert=${ETCDCTL_CACERT} --cert=${ETCDCTL_CERT} --key=${ETCDCTL_KEY}"
  fi

  local ml
  ml="$(run_remote "${SEED_HOST}" "${base} member list -w json" 2>/dev/null || true)"
  if [[ -n "${ml}" && "${HAVE_JQ}" == "true" ]]; then
    local adv
    adv="$(printf '%s' "${ml}" | jq -r '.members[].clientURLs[]' 2>/dev/null | paste -sd, -)"
    if [[ -n "${adv}" ]]; then
      ETCDCTL_ENDPOINTS="${adv}"
      vlog "Refined ETCDCTL_ENDPOINTS from etcd: ${ETCDCTL_ENDPOINTS}"
    fi
  fi
}

discover_vip_runtime_if_needed() {
  if [[ -n "${VIP}" ]]; then return 0; fi
  vlog "Attempting runtime VIP detection via network interfaces"
  declare -A addr_count=()
  for n in "${NODES[@]}"; do
    local addrs
    addrs="$(run_remote "${n}" "ip -4 -o addr | awk '{print \$4}' | cut -d/ -f1")"
    while read -r ip; do
      [[ -z "${ip}" ]] && continue
      addr_count["$ip"]=$(( ${addr_count["$ip"]:-0} + 1 ))
    done <<< "${addrs}"
  done
  for n in "${NODES[@]}"; do
    local status
    status="$(run_remote_sudo "${n}" "systemctl status ${SVC_KEEPALIVED} 2>/dev/null | sed -n '1,120p'")"
    for ip in "${!addr_count[@]}"; do
      if grep -q "${ip}" <<< "${status}"; then
        VIP="${ip}"
        vlog "VIP candidate from runtime: ${VIP}"
        return 0
      fi
    done
  done
}

discover_config() {
  [[ "${AUTO_DISCOVER}" == "true" ]] || return 0
  discover_requirements
  discover_nodes_from_patroni
  discover_vip_from_keepalived
  discover_haproxy_stats
  discover_etcd_endpoints
  discover_vip_runtime_if_needed

  if (( ${#NODES[@]} < 3 )); then
    log "Warning: discovered fewer than 3 nodes: ${NODES[*]}"
  fi
  if [[ -z "${VIP}" ]]; then
    log "Warning: could not auto-detect VIP. DB checks via VIP may fail unless VIP is set."
  fi
}

############################
# PREREQS
############################

check_prereqs() {
  command -v ssh >/dev/null || die "ssh not found"
  command -v psql >/dev/null || die "psql not found on runner host"
  command -v uuidgen >/dev/null || die "uuidgen not found on runner host"

  for n in "${NODES[@]}"; do
    run_remote "${n}" true || die "Cannot SSH to ${n} as ${SSH_USER}"
  done

  local nopass_ok="yes"
  for n in "${NODES[@]}"; do
    if ! ssh $(ssh_base) "${SSH_USER}@${n}" "sudo -n true" 2>/dev/null; then
      nopass_ok="no"; break
    fi
  done

  if [[ "${nopass_ok}" == "yes" ]]; then
    SUDO_MODE="nopass"
    vlog "Remote sudo works without a password"
  else
    SUDO_MODE="pass"
    prompt_sudo_password
    for n in "${NODES[@]}"; do
      ssh $(ssh_base) "${SSH_USER}@${n}" "sudo -S -p '' -v" <<<"${SUDO_PASS}" >/dev/null 2>&1 \
        || die "Provided sudo password did not work on ${n}"
    done
    vlog "Validated sudo password on all nodes"
  fi

  run_remote_sudo "${PATRONI_CTL_NODE}" "${PATRONICTL_CMD} list" >/dev/null 2>&1 \
    || die "patronictl not working on ${PATRONI_CTL_NODE}"

  vlog "Prereqs OK"
}

############################
# SNAPSHOTS
############################

snapshot_patroni_list() {
  local phase_dir="$1"
  save_remote_sudo "${PATRONI_CTL_NODE}" "${phase_dir}/patroni_list.txt" "${PATRONICTL_CMD} list"
}

snapshot_patroni_rest() {
  local phase_dir="$1"
  for n in "${NODES[@]}"; do
    save_remote "${n}" "${phase_dir}/patroni_health_${n}.json" "curl -fsS http://127.0.0.1:8008/health || true"
    save_remote "${n}" "${phase_dir}/patroni_cluster_${n}.json" "curl -fsS http://127.0.0.1:8008/cluster || true"
  done
}

snapshot_haproxy() {
  local phase_dir="$1"
  for n in "${NODES[@]}"; do
    if [[ -n "${HAPROXY_STATS_SOCKET}" ]]; then
      save_remote_sudo "${n}" "${phase_dir}/haproxy_stats_socket_${n}.txt" "command -v socat >/dev/null && echo show stat | socat stdio ${HAPROXY_STATS_SOCKET} || echo socat not installed"
    fi
    if [[ -n "${HAPROXY_STATS_URL}" ]]; then
      local auth_opt=""; [[ -n "${HAPROXY_STATS_AUTH}" ]] && auth_opt="-u ${HAPROXY_STATS_AUTH}"
      save_remote "${n}" "${phase_dir}/haproxy_stats_http_${n}.csv" "curl -fsS ${auth_opt} '${HAPROXY_STATS_URL}' || true"
    fi
    save_remote_sudo "${n}" "${phase_dir}/haproxy_services_${n}.txt" "systemctl status ${SVC_HAPROXY} || true"
  done
}

snapshot_keepalived_vip_owner() {
  local phase_dir="$1"
  : > "${phase_dir}/vip_owner.txt"
  for n in "${NODES[@]}"; do
    if run_remote "${n}" "ip -4 -o addr | awk '{print \$4}' | grep -qw '^${VIP}/'"; then
      echo "VIP ${VIP} present on ${n}" >> "${phase_dir}/vip_owner.txt"
    fi
    save_remote_sudo "${n}" "${phase_dir}/keepalived_${n}.txt" "systemctl status ${SVC_KEEPALIVED} || true"
  done
}

snapshot_etcd() {
  local phase_dir="$1"
  local base="ETCDCTL_API=${ETCDCTL_API} etcdctl --endpoints=${ETCDCTL_ENDPOINTS}"
  if [[ -n "${ETCDCTL_CACERT:-}" && -n "${ETCDCTL_CERT:-}" && -n "${ETCDCTL_KEY:-}" ]]; then
    base="${base} --cacert=${ETCDCTL_CACERT} --cert=${ETCDCTL_CERT} --key=${ETCDCTL_KEY}"
  fi
  save_remote "${PATRONI_CTL_NODE}" "${phase_dir}/etcd_endpoint_status.txt" "${base} endpoint status --write-out=table || true"
  save_remote "${PATRONI_CTL_NODE}" "${phase_dir}/etcd_endpoint_health.txt" "${base} endpoint health || true"
}

snapshot_db_vip() {
  local phase_dir="$1"
  local q_info="select pg_is_in_recovery() as in_recovery, inet_server_addr() as server_addr, now() as ts;"
  save_local "${phase_dir}/psql_info.txt" psql -h "${VIP}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -X -v ON_ERROR_STOP=1 -c "${q_info}"
}

snapshot_all() {
  local phase_dir="$1"; mkdir -p "${phase_dir}"
  snapshot_patroni_list "${phase_dir}"
  snapshot_patroni_rest "${phase_dir}"
  snapshot_haproxy "${phase_dir}"
  snapshot_keepalived_vip_owner "${phase_dir}"
  snapshot_etcd "${phase_dir}"
  if [[ -n "${VIP}" ]]; then
    snapshot_db_vip "${phase_dir}"
  fi
}

############################
# DB WRITE HELPERS + WRITE LOOP
############################

ensure_audit_table() {
  local sql="
  create schema if not exists ha_test;
  create table if not exists ha_test.audit_log (
    id uuid primary key,
    event_ts timestamptz default now(),
    note text,
    server inet default inet_server_addr()
  );"
  psql -h "${VIP}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -X -v ON_ERROR_STOP=1 -c "${sql}" >/dev/null
}

db_write_event() {
  local note="$1"
  local uuid; uuid="$(uuidgen)"
  local sql="
  insert into ha_test.audit_log(id, note) values ('${uuid}', '${note}');
  select 'inserted' as status, '${uuid}'::uuid as id, inet_server_addr() as server_addr, now() as ts;"
  psql -h "${VIP}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -X -v ON_ERROR_STOP=1 -c "${sql}"
}

db_write_event_quiet() {
  local note="$1"
  local sql="insert into ha_test.audit_log(id, note) values ('$(uuidgen)', '${note}');"
  psql -h "${VIP}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -X -v ON_ERROR_STOP=1 -c "${sql}" >/dev/null 2>&1
}

start_write_loop() {
  local phase_dir="$1"
  WRITE_LOOP_LOG="${phase_dir}/write_loop.log"
  : > "${WRITE_LOOP_LOG}"
  # ensure table exists before loop
  ensure_audit_table || true
  (
    while true; do
      if db_write_event_quiet "write_loop"; then
        echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') OK" >> "${WRITE_LOOP_LOG}"
      else
        echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') FAIL" >> "${WRITE_LOOP_LOG}"
      fi
      sleep 1
    done
  ) &
  WRITE_LOOP_PID=$!
  vlog "Write loop started with PID ${WRITE_LOOP_PID}, logging to ${WRITE_LOOP_LOG}"
}

stop_write_loop() {
  if [[ -n "${WRITE_LOOP_PID}" ]]; then
    kill "${WRITE_LOOP_PID}" >/dev/null 2>&1 || true
    wait "${WRITE_LOOP_PID}" >/dev/null 2>&1 || true
    vlog "Write loop stopped"
    WRITE_LOOP_PID=""
  fi
}

measure_rto() {
  local t0_epoch="$1"
  local waited=0
  while (( waited <= LEADER_ELECTION_TIMEOUT_SECS )); do
    if db_write_event_quiet "rto_probe"; then
      local t1_epoch; t1_epoch="$(now_epoch)"
      echo $(( t1_epoch - t0_epoch ))
      return 0
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  echo -1
  return 1
}

############################
# CLUSTER HELPERS
############################

current_leader() {
  run_remote_sudo "${PATRONI_CTL_NODE}" "${PATRONICTL_CMD} list" | awk 'NR>1 && tolower($3) ~ /leader/ {print $1; exit}'
}

random_replica() {
  run_remote_sudo "${PATRONI_CTL_NODE}" "${PATRONICTL_CMD} list" | awk 'NR>1 && tolower($3) ~ /replica/ {print $1}' | shuf | head -n1
}

vip_holder() {
  for n in "${NODES[@]}"; do
    if run_remote "${n}" "ip -4 -o addr | awk '{print \$4}' | grep -qw '^${VIP}/'"; then
      echo "${n}"; return 0
    fi
  done
  echo ""; return 1
}

stop_service() {
  local node="$1"; local svc="$2"
  log "Stopping ${svc} on ${node}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] ${node}: ${svc} stop"
    return 0
  fi
  run_remote_sudo "${node}" "systemctl stop ${svc}"
  STOPPED_SERVICES+=("${node}:${svc}")
}

start_service() {
  local node="$1"; local svc="$2"
  log "Starting ${svc} on ${node}"
  run_remote_sudo "${node}" "systemctl start ${svc}"
}

wait_for_new_leader() {
  local old_leader="$1"
  local waited=0
  while (( waited < LEADER_ELECTION_TIMEOUT_SECS )); do
    local l; l="$(current_leader || true)"
    if [[ -n "${l}" && "${l}" != "${old_leader}" ]]; then
      log "New leader elected: ${l}"
      echo "${l}"
      return 0
    fi
    sleep "${POLL_INTERVAL_SECS}"
    waited=$(( waited + POLL_INTERVAL_SECS ))
  done
  die "Leader election did not complete within ${LEADER_ELECTION_TIMEOUT_SECS}s"
}

wait_for_db_writable() {
  local waited=0
  while (( waited < LEADER_ELECTION_TIMEOUT_SECS )); do
    if [[ -n "${VIP}" ]] && psql -h "${VIP}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" -X -At -c "select pg_is_in_recovery();" 2>/dev/null | grep -q '^f$'; then
      log "VIP is serving a writable primary"
      return 0
    fi
    sleep "${POLL_INTERVAL_SECS}"
    waited=$(( waited + POLL_INTERVAL_SECS ))
  done
  die "VIP did not serve a writable primary within ${LEADER_ELECTION_TIMEOUT_SECS}s"
}

wait_for_member_rejoin() {
  local node="$1"
  local waited=0
  while (( waited < REJOIN_TIMEOUT_SECS )); do
    if run_remote_sudo "${PATRONI_CTL_NODE}" "${PATRONICTL_CMD} list" | awk -v host="${node}" 'NR>1 && $1==host && tolower($3) ~ /replica/ {ok=1} END {exit ok?0:1}'; then
      log "Node ${node} shows as Replica in patronictl list"
      return 0
    fi
    sleep "${POLL_INTERVAL_SECS}"
    waited=$(( waited + POLL_INTERVAL_SECS ))
  done
  die "Node ${node} did not rejoin as replica within ${REJOIN_TIMEOUT_SECS}s"
}

wait_for_ssh_down() {
  local node="$1"; local waited=0
  while (( waited < SSH_DOWN_TIMEOUT_SECS )); do
    if ! run_remote "${node}" true >/dev/null 2>&1; then
      log "SSH down detected on ${node}"
      return 0
    fi
    sleep 2; waited=$(( waited + 2 ))
  done
  die "SSH did not go down on ${node} within ${SSH_DOWN_TIMEOUT_SECS}s"
}

wait_for_ssh_up() {
  local node="$1"; local waited=0
  while (( waited < SSH_UP_TIMEOUT_SECS )); do
    if run_remote "${node}" true >/dev/null 2>&1; then
      log "SSH up detected on ${node}"
      return 0
    fi
    sleep 5; waited=$(( waited + 5 ))
  done
  die "SSH did not come back on ${node} within ${SSH_UP_TIMEOUT_SECS}s"
}

############################
# FIREWALL HELPERS FOR etcd PARTITION
############################

iptables_available() {
  local node="$1"
  run_remote_sudo "${node}" "command -v iptables >/dev/null"
}

apply_etcd_block() {
  local node="$1"
  iptables_available "${node}" || die "iptables not found on ${node}; cannot apply network partition"
  log "Applying iptables drop rules for tcp/2379 on ${node}"
  run_remote_sudo "${node}" "
    iptables -C INPUT  -p tcp --dport 2379 -m comment --comment ha_demo_block_etcd -j DROP 2>/dev/null || iptables -I INPUT  -p tcp --dport 2379 -m comment --comment ha_demo_block_etcd -j DROP
    iptables -C OUTPUT -p tcp --dport 2379 -m comment --comment ha_demo_block_etcd -j DROP 2>/dev/null || iptables -I OUTPUT -p tcp --dport 2379 -m comment --comment ha_demo_block_etcd -j DROP
    iptables -C INPUT  -p tcp --sport 2379 -m comment --comment ha_demo_block_etcd -j DROP 2>/dev/null || iptables -I INPUT  -p tcp --sport 2379 -m comment --comment ha_demo_block_etcd -j DROP
    iptables -C OUTPUT -p tcp --sport 2379 -m comment --comment ha_demo_block_etcd -j DROP 2>/dev/null || iptables -I OUTPUT -p tcp --sport 2379 -m comment --comment ha_demo_block_etcd -j DROP
  "
  BLOCKED_ETCD_NODES+=("${node}")
}

clear_etcd_block() {
  local node="$1"
  iptables_available "${node}" || return 0
  log "Clearing iptables drop rules on ${node}"
  run_remote_sudo "${node}" "
    while iptables -S | grep -q ha_demo_block_etcd; do
      iptables -S | grep ha_demo_block_etcd | sed 's/^-A /-D /' | while read -r rule; do iptables \$rule || true; done
    done
  "
}

############################
# CLEANUP TRAP
############################

auto_restore_on_exit() {
  stop_write_loop
  if [[ "${#STOPPED_SERVICES[@]}" -gt 0 ]]; then
    log "Attempting auto-restore of stopped services"
    for pair in "${STOPPED_SERVICES[@]}"; do
      IFS=":" read -r node svc <<< "${pair}"
      start_service "${node}" "${svc}" || true
    done
  fi
  if [[ "${#BLOCKED_ETCD_NODES[@]}" -gt 0 ]]; then
    log "Clearing any temporary etcd iptables blocks"
    for n in "${BLOCKED_ETCD_NODES[@]}"; do
      clear_etcd_block "${n}" || true
    done
  fi
}
trap auto_restore_on_exit EXIT

############################
# SCENARIOS
############################

scenario_primary_failure() {
  log "=== Scenario: Primary failure (stop Patroni on current leader) ==="
  local old_leader; old_leader="$(current_leader)"; [[ -n "${old_leader}" ]] || die "Could not determine current leader"
  log "Current leader: ${old_leader}"

  snapshot_all "${ART_INIT}"
  if [[ -n "${VIP}" ]]; then start_write_loop "${ART_INIT}"; fi
  if [[ -n "${VIP}" ]]; then ensure_audit_table || true; fi
  if [[ -n "${VIP}" ]]; then db_write_event "pre-failover" || true; fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Skipping failure injection and observation"
    stop_write_loop
    snapshot_all "${ART_REST}"
    return 0
  fi

  local t0; t0="$(now_epoch)"
  stop_service "${old_leader}" "${SVC_PATRONI}"

  local new_leader; new_leader="$(wait_for_new_leader "${old_leader}")"
  if [[ -n "${VIP}" ]]; then
    wait_for_db_writable
    local rto; rto="$(measure_rto "${t0}")" || true
    log "RTO_seconds: ${rto}"
  fi

  snapshot_all "${ART_FAIL}"
  if [[ -n "${VIP}" ]]; then db_write_event "post-failover" || true; fi
  stop_write_loop

  log "Restoring Patroni on former leader"
  start_service "${old_leader}" "${SVC_PATRONI}"
  wait_for_member_rejoin "${old_leader}"

  snapshot_all "${ART_REST}"
}

scenario_replica_failure() {
  log "=== Scenario: Replica failure (stop Patroni on random replica) ==="
  local leader; leader="$(current_leader)"; [[ -n "${leader}" ]] || die "Cannot find leader"
  local replica; replica="$(random_replica)"; [[ -n "${replica}" ]] || die "No replica found"
  log "Leader: ${leader}, chosen replica: ${replica}"

  snapshot_all "${ART_INIT}"
  if [[ -n "${VIP}" ]]; then start_write_loop "${ART_INIT}"; fi
  if [[ -n "${VIP}" ]]; then ensure_audit_table || true; fi
  if [[ -n "${VIP}" ]]; then db_write_event "pre-replica-failure" || true; fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Skipping failure injection and observation"
    stop_write_loop
    snapshot_all "${ART_REST}"
    return 0
  fi

  local t0; t0="$(now_epoch)"
  stop_service "${replica}" "${SVC_PATRONI}"

  if [[ -n "${VIP}" ]]; then
    wait_for_db_writable
    local rto; rto="$(measure_rto "${t0}")" || true
    log "RTO_seconds: ${rto}"
  fi

  snapshot_all "${ART_FAIL}"
  if [[ -n "${VIP}" ]]; then db_write_event "post-replica-failure" || true; fi
  stop_write_loop

  start_service "${replica}" "${SVC_PATRONI}"
  wait_for_member_rejoin "${replica}"

  snapshot_all "${ART_REST}"
}

scenario_vip_carrier_failure() {
  log "=== Scenario: VIP carrier failure (stop Keepalived + HAProxy on VIP holder) ==="
  local holder; holder="$(vip_holder)"; [[ -n "${holder}" ]] || die "Could not locate VIP holder"
  log "VIP ${VIP} currently on ${holder}"

  snapshot_all "${ART_INIT}"
  if [[ -n "${VIP}" ]]; then start_write_loop "${ART_INIT}"; fi
  if [[ -n "${VIP}" ]]; then ensure_audit_table || true; fi
  if [[ -n "${VIP}" ]]; then db_write_event "pre-vip-carrier-failure" || true; fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Skipping failure injection and observation"
    stop_write_loop
    snapshot_all "${ART_REST}"
    return 0
  fi

  local t0; t0="$(now_epoch)"
  stop_service "${holder}" "${SVC_HAPROXY}"
  stop_service "${holder}" "${SVC_KEEPALIVED}"

  local waited=0
  while (( waited < LEADER_ELECTION_TIMEOUT_SECS )); do
    local new_holder; new_holder="$(vip_holder || true)"
    if [[ -n "${new_holder}" && "${new_holder}" != "${holder}" ]]; then
      log "VIP moved to ${new_holder}"
      break
    fi
    sleep "${POLL_INTERVAL_SECS}"
    waited=$(( waited + POLL_INTERVAL_SECS ))
  done

  if [[ -n "${VIP}" ]]; then
    wait_for_db_writable
    local rto; rto="$(measure_rto "${t0}")" || true
    log "RTO_seconds: ${rto}"
  fi

  snapshot_all "${ART_FAIL}"
  if [[ -n "${VIP}" ]]; then db_write_event "post-vip-carrier-failure" || true; fi
  stop_write_loop

  start_service "${holder}" "${SVC_KEEPALIVED}"
  start_service "${holder}" "${SVC_HAPROXY}"

  snapshot_all "${ART_REST}"
}

scenario_etcd_member_failure() {
  log "=== Scenario: etcd member failure (stop etcd on a random node) ==="
  local pick; pick="$(printf "%s\n" "${NODES[@]}" | shuf | head -n1)"
  log "Chosen etcd node: ${pick}"

  snapshot_all "${ART_INIT}"
  if [[ -n "${VIP}" ]]; then start_write_loop "${ART_INIT}"; fi
  if [[ -n "${VIP}" ]]; then ensure_audit_table || true; fi
  if [[ -n "${VIP}" ]]; then db_write_event "pre-etcd-failure" || true; fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Skipping failure injection and observation"
    stop_write_loop
    snapshot_all "${ART_REST}"
    return 0
  fi

  local t0; t0="$(now_epoch)"
  stop_service "${pick}" "${SVC_ETCD}"

  if [[ -n "${VIP}" ]]; then
    wait_for_db_writable
    local rto; rto="$(measure_rto "${t0}")" || true
    log "RTO_seconds: ${rto}"
  fi

  snapshot_all "${ART_FAIL}"
  if [[ -n "${VIP}" ]]; then db_write_event "post-etcd-failure" || true; fi
  stop_write_loop

  start_service "${pick}" "${SVC_ETCD}"

  snapshot_all "${ART_REST}"
}

scenario_planned_switchover() {
  log "=== Scenario: Planned switchover (patronictl switchover) ==="
  local old_leader; old_leader="$(current_leader)"; [[ -n "${old_leader}" ]] || die "Could not determine current leader"
  local target; target="$(random_replica)"; [[ -n "${target}" ]] || die "No replica available to switchover"
  log "Current leader: ${old_leader}, target candidate: ${target}"

  snapshot_all "${ART_INIT}"
  if [[ -n "${VIP}" ]]; then start_write_loop "${ART_INIT}"; fi
  if [[ -n "${VIP}" ]]; then ensure_audit_table || true; fi
  if [[ -n "${VIP}" ]]; then db_write_event "pre-switchover" || true; fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Skipping switchover"
    stop_write_loop
    snapshot_all "${ART_REST}"
    return 0
  fi

  local t0; t0="$(now_epoch)"
  run_remote_sudo "${PATRONI_CTL_NODE}" "${PATRONICTL_CMD} switchover --candidate ${target} --force"

  local new_leader; new_leader="$(wait_for_new_leader "${old_leader}")"
  if [[ -n "${VIP}" ]]; then
    wait_for_db_writable
    local rto; rto="$(measure_rto "${t0}")" || true
    log "RTO_seconds: ${rto} (planned)"
  fi

  snapshot_all "${ART_FAIL}"
  if [[ -n "${VIP}" ]]; then db_write_event "post-switchover" || true; fi
  stop_write_loop

  snapshot_all "${ART_REST}"
}

scenario_full_host_reboot() {
  log "=== Scenario: Full host reboot of current leader ==="
  local old_leader; old_leader="$(current_leader)"; [[ -n "${old_leader}" ]] || die "Could not determine current leader"
  log "Current leader: ${old_leader}"

  snapshot_all "${ART_INIT}"
  if [[ -n "${VIP}" ]]; then start_write_loop "${ART_INIT}"; fi
  if [[ -n "${VIP}" ]]; then ensure_audit_table || true; fi
  if [[ -n "${VIP}" ]]; then db_write_event "pre-reboot" || true; fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Skipping reboot"
    stop_write_loop
    snapshot_all "${ART_REST}"
    return 0
  fi

  local t0; t0="$(now_epoch)"
  log "Rebooting ${old_leader}"
  run_remote_sudo "${old_leader}" "nohup systemctl reboot -i >/dev/null 2>&1 &"

  wait_for_ssh_down "${old_leader}"
  local new_leader; new_leader="$(wait_for_new_leader "${old_leader}")"
  if [[ -n "${VIP}" ]]; then
    wait_for_db_writable
    local rto; rto="$(measure_rto "${t0}")" || true
    log "RTO_seconds: ${rto}"
  fi

  snapshot_all "${ART_FAIL}"
  if [[ -n "${VIP}" ]]; then db_write_event "post-reboot-failover" || true; fi

  wait_for_ssh_up "${old_leader}"
  wait_for_member_rejoin "${old_leader}"

  stop_write_loop
  snapshot_all "${ART_REST}"
}

scenario_network_partition_etcd() {
  log "=== Scenario: Network partition of etcd port on leader (iptables block tcp/2379) ==="
  local old_leader; old_leader="$(current_leader)"; [[ -n "${old_leader}" ]] || die "Could not determine current leader"
  log "Current leader: ${old_leader}"

  snapshot_all "${ART_INIT}"
  if [[ -n "${VIP}" ]]; then start_write_loop "${ART_INIT}"; fi
  if [[ -n "${VIP}" ]]; then ensure_audit_table || true; fi
  if [[ -n "${VIP}" ]]; then db_write_event "pre-net-partition" || true; fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Skipping network partition"
    stop_write_loop
    snapshot_all "${ART_REST}"
    return 0
  fi

  local t0; t0="$(now_epoch)"
  apply_etcd_block "${old_leader}"

  local new_leader; new_leader="$(wait_for_new_leader "${old_leader}")"
  if [[ -n "${VIP}" ]]; then
    wait_for_db_writable
    local rto; rto="$(measure_rto "${t0}")" || true
    log "RTO_seconds: ${rto}"
  fi

  snapshot_all "${ART_FAIL}"
  if [[ -n "${VIP}" ]]; then db_write_event "post-net-partition" || true; fi

  clear_etcd_block "${old_leader}"
  stop_write_loop

  wait_for_member_rejoin "${old_leader}"

  snapshot_all "${ART_REST}"
}

scenario_all() {
  scenario_primary_failure
  scenario_replica_failure
  scenario_vip_carrier_failure
  scenario_etcd_member_failure
  scenario_planned_switchover
  scenario_full_host_reboot
  scenario_network_partition_etcd
}

############################
# MENU AND CLI
############################

usage() {
  cat <<EOF
Usage: $0 [-n] [-q] [-t scenario] [-D] [-s seed_host]

Options:
  -n            Dry run. Snapshot and print actions but do not disrupt services.
  -q            Quiet. Reduce logging.
  -t scenario   primary | replica | vip | etcd | switchover | reboot | netpartition | all
  -D            Enable auto-discovery (same as AUTO_DISCOVER=true)
  -s seed_host  Hostname or IP of any cluster node to seed discovery

Edit the CONFIGURATION block for overrides if auto-discovery cannot find something.
EOF
}

interactive_menu() {
  echo "Select a test to run:"
  echo "  1) Primary failure"
  echo "  2) Replica failure"
  echo "  3) VIP carrier failure"
  echo "  4) etcd member failure"
  echo "  5) Planned switchover"
  echo "  6) Full host reboot (leader)"
  echo "  7) Network partition etcd on leader"
  echo "  8) Run all in sequence"
  echo "  9) Quit"
  read -rp "Choice [1-9]: " choice
  case "${choice}" in
    1) echo "primary" ;;
    2) echo "replica" ;;
    3) echo "vip" ;;
    4) echo "etcd" ;;
    5) echo "switchover" ;;
    6) echo "reboot" ;;
    7) echo "netpartition" ;;
    8) echo "all" ;;
    *) echo "quit" ;;
  esac
}

main() {
  local scenario=""
  while getopts ":nqt:Ds:" opt; do
    case "${opt}" in
      n) DRY_RUN="true" ;;
      q) VERBOSE="false" ;;
      t) scenario="${OPTARG}" ;;
      D) AUTO_DISCOVER="true" ;;
      s) SEED_HOST="${OPTARG}" ;;
      *) usage; exit 1 ;;
    esac
  done

  ensure_dirs

  # Perform discovery before prereqs so NODES, VIP, etc. are populated
  discover_config

  check_prereqs

  if [[ -z "${scenario}" ]]; then
    scenario="$(interactive_menu)"
  fi
  [[ "${scenario}" != "quit" ]] || exit 0

  log "Run ID: ${RUN_ID}"
  log "Selected scenario: ${scenario}"
  log "Artifacts: ${ART_RUN}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "Dry run enabled"
  fi

  case "${scenario}" in
    primary)      scenario_primary_failure ;;
    replica)      scenario_replica_failure ;;
    vip)          scenario_vip_carrier_failure ;;
    etcd)         scenario_etcd_member_failure ;;
    switchover)   scenario_planned_switchover ;;
    reboot)       scenario_full_host_reboot ;;
    netpartition) scenario_network_partition_etcd ;;
    all)          scenario_all ;;
    *) die "Unknown scenario: ${scenario}" ;;
  esac

  log "Done. See ${SUMMARY_FILE} and per-phase artifacts."
}

main "$@"
