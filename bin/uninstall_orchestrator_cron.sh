#!/usr/bin/env bash
# bin/uninstall_orchestrator_cron.sh
#
# Removes the daily rolling-reboot cron line from the orchestrator's crontab.
# Does NOT touch the state file or the plan file — operators may want to
# inspect them. Run with --purge-state to additionally delete the state file.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

PURGE=false
case "${1:-}" in
  --purge-state) PURGE=true ;;
  -h|--help)     grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

remove_crontab_line "rolling_reboot_next.sh"
log_ok "Cron line removed."

if "${PURGE}"; then
  STATE="${REPO_ROOT}/run/rolling_global_state"
  rm -f "${STATE}"
  log_ok "State file purged: ${STATE}"
fi
