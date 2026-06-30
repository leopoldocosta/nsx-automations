#!/usr/bin/env bash
# bin/install_orchestrator_cron.sh
#
# Installs a DAILY cron entry on the orchestrator VM that reboots ONE
# manager per firing via bin/rolling_reboot_next.sh. Default schedule:
# 02:00 local time, every day.
#
# Override the schedule with env vars:
#   CRON_HOUR=2 CRON_MINUTE=0 ./bin/install_orchestrator_cron.sh
#
# Override conf/plan paths:
#   CONF=/etc/nsx/datacenters.conf PLAN=/etc/nsx/reboot_plan.conf \
#     ./bin/install_orchestrator_cron.sh
#
# Idempotent — replaces any existing entry that mentions rolling_reboot_next.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

HOUR="${CRON_HOUR:-2}"
MIN="${CRON_MINUTE:-0}"
CONF="${CONF:-${REPO_ROOT}/datacenters.conf}"
PLAN="${PLAN:-${REPO_ROOT}/reboot_plan.conf}"
LOG_FILE="${LOG_FILE:-${REPO_ROOT}/logs/orchestrator_cron.log}"

# Defense in depth: refuse to install a cron that points at files that don't exist.
[[ -f "${CONF}" ]] || { log_err "datacenters.conf not found at ${CONF}. Create it before installing the cron."; exit 1; }
[[ -f "${PLAN}" ]] || { log_err "reboot_plan.conf not found at ${PLAN}. Copy from reboot_plan.example before installing."; exit 1; }
mkdir -p "$(dirname "${LOG_FILE}")"

CMD="${SCRIPT_DIR}/rolling_reboot_next.sh --conf ${CONF} --plan ${PLAN} >> ${LOG_FILE} 2>&1"
install_crontab_line "${MIN} ${HOUR} * * *" "${CMD}"
log "Schedule: every day at ${HOUR}:${MIN} (1 manager per firing)."
log "Plan:     ${PLAN}"
log "Log:      ${LOG_FILE}"
log "Inspect:  ${SCRIPT_DIR}/rolling_reboot_next.sh --list"
log "Preview:  ${SCRIPT_DIR}/rolling_reboot_next.sh --dry-run"
crontab -l | grep rolling_reboot_next || true
