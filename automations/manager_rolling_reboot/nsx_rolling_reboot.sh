#!/usr/bin/env bash
# nsx_rolling_reboot.sh
# Multi-cluster rolling reboot of NSX-T Managers.
#
# For each cluster defined in managers.conf, reboots each host sequentially,
# waiting for it to drop and return via TCP probe before moving on.
# Honors NSX_REBOOT_INTERVAL (default 3600s) between hosts.
# Lock file prevents overlapping crontab executions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
export ADMIN_KEY="${ADMIN_KEY:-${HOME}/.ssh/id_rsa}"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=../../lib/nsx_manager.sh
source "${REPO_ROOT}/lib/nsx_manager.sh"

MANAGERS_CONF="${MANAGERS_CONF:-${SCRIPT_DIR}/managers.conf}"
LOCK_FILE="${LOCK_FILE:-/tmp/nsx_rolling_reboot.lock}"

# --- Lock file (prevents overlapping crontab runs) ---
if [[ -f "${LOCK_FILE}" ]]; then
  PID="$(cat "${LOCK_FILE}" 2>/dev/null || echo)"
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    log "[LOCKED] Already running (PID ${PID}). Exiting."
    exit 0
  fi
  rm -f "${LOCK_FILE}"
fi
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT INT TERM

# --- Parse multi-cluster config ---
parse_managers_conf "${MANAGERS_CONF}"

# --- Per-run log ---
RUN_LOG="${LOG_DIR}/rolling_reboot_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${RUN_LOG}") 2>&1

log_banner "NSX Rolling Reboot — ${CLUSTER_COUNT} cluster(s)"
log "Interval: ${NSX_REBOOT_INTERVAL}s | Max wait: ${NSX_REBOOT_MAX_WAIT}s"

for (( i=0; i<CLUSTER_COUNT; i++ )); do
  user="$(cluster_admin_user "${i}")"
  log "Setting NSX_USER='${user}' for cluster [${CLUSTER_LABELS[$i]}]"
  export NSX_USER="${user}"
  rolling_reboot_cluster "${i}"
done

log_banner "Rolling reboot completed"
