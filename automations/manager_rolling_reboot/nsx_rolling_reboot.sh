#!/usr/bin/env bash
# nsx_rolling_reboot.sh
# Multi-cluster rolling reboot of NSX-T Managers.
#
# For each cluster defined in managers.conf, reboots each host sequentially,
# waiting for it to drop and return via TCP probe before moving on.
# Honors NSX_REBOOT_INTERVAL (default 3600s) between hosts.
# Lock file prevents overlapping crontab executions.
#
# Flags:
#   --dry-run             Print the plan; do not actually reboot.
#   --resume              Resume from the host recorded in the state file
#                         (RUN_DIR/rolling_state). The state file is
#                         written before each reboot and removed when a
#                         cluster finishes cleanly.
#   --resume-from <ip>    Skip until <ip> in the FIRST cluster, then
#                         continue normally (manual override).
#   -h | --help           Show this header.
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
STATE_FILE="${STATE_FILE:-${RUN_DIR}/rolling_state}"

DRY_RUN=false
RESUME=false
RESUME_FROM_ARG=""

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=true; shift ;;
    --resume)       RESUME=true; shift ;;
    --resume-from)  RESUME_FROM_ARG="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

# --- Lock file (skip in dry-run so operators can preview anytime) ---
if ! $DRY_RUN; then
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
fi

# --- Parse multi-cluster config ---
parse_managers_conf "${MANAGERS_CONF}"

# --- Per-run log ---
RUN_LOG="${LOG_DIR}/rolling_reboot_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${RUN_LOG}") 2>&1

if $DRY_RUN; then
  log_banner "NSX Rolling Reboot — DRY-RUN — ${CLUSTER_COUNT} cluster(s)"
  export NSX_DRY_RUN=1
else
  log_banner "NSX Rolling Reboot — ${CLUSTER_COUNT} cluster(s)"
  export NSX_STATE_FILE="${STATE_FILE}"
fi
log "Interval: ${NSX_REBOOT_INTERVAL}s | TCP max wait: ${NSX_REBOOT_MAX_WAIT}s | Cluster STABLE timeout: ${NSX_CLUSTER_STABLE_TIMEOUT}s"

# --- Resume logic ---
RESUME_CLUSTER_START=0
if $RESUME && [[ -f "${STATE_FILE}" ]]; then
  IFS='|' read -r RS_IDX _ RS_IP _ < "${STATE_FILE}"
  if [[ -n "${RS_IDX}" && -n "${RS_IP}" ]]; then
    log_warn "Resuming from state: cluster idx=${RS_IDX} host=${RS_IP}"
    RESUME_CLUSTER_START="${RS_IDX}"
    export NSX_RESUME_FROM="${RS_IP}"
  else
    log_warn "State file present but unreadable: ${STATE_FILE}. Starting from the beginning."
  fi
elif [[ -n "${RESUME_FROM_ARG}" ]]; then
  log_warn "Manual --resume-from: ${RESUME_FROM_ARG} (applies to cluster 0)"
  export NSX_RESUME_FROM="${RESUME_FROM_ARG}"
fi

for (( i=RESUME_CLUSTER_START; i<CLUSTER_COUNT; i++ )); do
  user="$(cluster_admin_user "${i}")"
  log "Setting NSX_USER='${user}' for cluster [${CLUSTER_LABELS[$i]}]"
  export NSX_USER="${user}"
  rolling_reboot_cluster "${i}"
  # After the first cluster, the resume offset is consumed.
  unset NSX_RESUME_FROM
done

if $DRY_RUN; then
  log_banner "DRY-RUN completed — no action taken"
else
  log_banner "Rolling reboot completed"
  rotate_logs   # honor NSX_LOG_RETENTION_DAYS (default 30)
fi
