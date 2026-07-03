#!/usr/bin/env bash
# automations/device_command/device_command.sh
#
# Run a read-only NSX CLI command on EVERY device of THIS datacenter —
# managers (all clusters in managers.conf) and/or edge nodes — and print
# a consolidated table + CSV. Designed to be fanned out from the
# orchestrator so each jump queries its own devices and the results are
# pulled back to aggregated_logs/:
#
#   ./bin/run_across_datacenters.sh --conf ./datacenters.conf \
#       --automation device_command/device_command.sh -- --cmd "get uptime"
#
# Local (single-DC) usage — the command is whatever you type:
#   ./device_command.sh get version              # positional = the command
#   ./device_command.sh get interface eth0
#   ./device_command.sh --targets managers get certificate api
#   ./device_command.sh                          # asks you for the command (TTY)
#
# Flags:
#   --cmd "<nsx-cli-cmd>"   Same as positional; use it when the command
#                           starts with a dash or for scripting clarity.
#   --targets <t>           managers | edges | all   (default: all)
#
# With no command and no TTY (e.g. under the fan-out) the default is
# "get uptime".
#
# Inventory (central, with local override):
#   managers  : inventory/managers.conf   (or ./managers.conf beside this script)
#   edges     : inventory/edge_nodes.txt  (or ./edge_nodes.txt beside this script)
#   A missing inventory file just skips that device class with a warning —
#   a DC with no edges works out of the box. NEVER prompts (fan-out safe).
#
# Auth: uses ADMIN_KEY (default ~/.ssh/id_rsa) registered previously by
# bin/configure_ssh_keys.sh. No passwords, no prompts, BatchMode only.
#
# Output:
#   - table on stdout (type, cluster, ip, exit, first line of output)
#   - CSV at logs/device_command_<ts>.csv (full first-line output, quoted)
#   - exit code = number of devices that failed
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
export ADMIN_KEY="${ADMIN_KEY:-${HOME}/.ssh/id_rsa}"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=../../lib/nsx_manager.sh
source "${REPO_ROOT}/lib/nsx_manager.sh"

CMD=""
TARGETS="all"

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# Flags first; anything left over IS the command (no --cmd needed):
#   ./device_command.sh get version
#   ./device_command.sh --targets edges get interface eth0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmd)     CMD="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    -h|--help) usage ;;
    --*)       log_err "Unknown flag: $1"; exit 1 ;;
    *)         POSITIONAL+=("$1"); shift ;;
  esac
done
if [[ -z "${CMD}" && ${#POSITIONAL[@]} -gt 0 ]]; then
  CMD="${POSITIONAL[*]}"
fi

# No command given: ask interactively at a TTY; default to "get uptime"
# otherwise (keeps the multi-DC fan-out non-interactive).
if [[ -z "${CMD}" ]]; then
  if [[ -t 0 ]]; then
    read -rp "NSX CLI command to run on every device [get uptime]: " CMD
    CMD="${CMD:-get uptime}"
  else
    CMD="get uptime"
  fi
fi

case "${TARGETS}" in managers|edges|all) ;; *)
  log_err "--targets must be managers|edges|all (got '${TARGETS}')"; exit 1 ;;
esac

need_cmd ssh
[[ -f "${ADMIN_KEY}" ]] || { log_err "ADMIN_KEY not found: ${ADMIN_KEY} — run bin/configure_ssh_keys.sh first."; exit 1; }

MANAGERS_CONF="$(resolve_inventory_file "${SCRIPT_DIR}/managers.conf")"
EDGES_FILE="$(resolve_inventory_file "${SCRIPT_DIR}/edge_nodes.txt")"

TS="$(date +%Y%m%d_%H%M%S)"
CSV="${LOG_DIR}/device_command_${TS}.csv"
echo 'type,cluster,ip,exit_code,output' > "${CSV}"

# _one_line <raw> — first non-empty line, CR stripped, CSV-safe
_one_line(){
  echo "$1" | tr -d '\r' | grep -m1 . || true
}

FAILED=0
TOTAL=0

log_banner "device_command — cmd: ${CMD} | targets: ${TARGETS}"
printf '%-8s %-10s %-16s %-5s %s\n' "TYPE" "CLUSTER" "IP" "EXIT" "OUTPUT"

run_on_device(){
  local dtype="$1" cluster="$2" ip="$3"
  local out rc=0
  out="$(admin_cmd "${ip}" "${CMD}" 2>/dev/null)" || rc=$?
  local line; line="$(_one_line "${out}")"
  TOTAL=$(( TOTAL + 1 ))
  if (( rc != 0 )); then
    FAILED=$(( FAILED + 1 ))
    line="${line:-<no output>}"
  fi
  printf '%-8s %-10s %-16s %-5s %s\n' "${dtype}" "${cluster}" "${ip}" "${rc}" "${line}"
  printf '%s,%s,%s,%s,"%s"\n' "${dtype}" "${cluster}" "${ip}" "${rc}" "${line//\"/\'}" >> "${CSV}"
}

# ---- Managers (all clusters) ----------------------------------------------
if [[ "${TARGETS}" == "managers" || "${TARGETS}" == "all" ]]; then
  if [[ -f "${MANAGERS_CONF}" ]]; then
    parse_managers_conf "${MANAGERS_CONF}"
    for (( c=0; c<CLUSTER_COUNT; c++ )); do
      label="${CLUSTER_LABELS[$c]}"
      export NSX_USER="$(cluster_admin_user "${c}")"
      read -r -a _hosts <<<"$(cluster_hosts "${c}")"
      for ip in "${_hosts[@]}"; do
        run_on_device "manager" "${label}" "${ip}"
      done
    done
    unset NSX_USER
  else
    log_warn "No managers.conf found (looked at ${MANAGERS_CONF}) — skipping managers."
  fi
fi

# ---- Edge nodes -------------------------------------------------------------
if [[ "${TARGETS}" == "edges" || "${TARGETS}" == "all" ]]; then
  if [[ -s "${EDGES_FILE}" ]]; then
    mapfile -t _edges < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${EDGES_FILE}" 2>/dev/null || true)
    if (( ${#_edges[@]} == 0 )); then
      log_warn "No valid IPs in ${EDGES_FILE} — skipping edges."
    fi
    for ip in "${_edges[@]}"; do
      run_on_device "edge" "-" "${ip}"
    done
  else
    log_warn "No edge_nodes.txt found (looked at ${EDGES_FILE}) — skipping edges."
  fi
fi

echo ""
if (( TOTAL == 0 )); then
  log_err "No devices queried — check inventory/ (managers.conf, edge_nodes.txt)."
  exit 1
fi
if (( FAILED == 0 )); then
  log_ok "${TOTAL} device(s) responded. CSV: ${CSV}"
else
  log_err "${FAILED}/${TOTAL} device(s) FAILED. CSV: ${CSV}"
fi

rotate_logs
exit "${FAILED}"
