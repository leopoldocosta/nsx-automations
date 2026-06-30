#!/usr/bin/env bash
# bin/rolling_reboot_next.sh
#
# Orchestrator-side entrypoint for the DAILY rolling reboot.
# Reboots exactly ONE manager per invocation, advancing through a
# pre-defined plan (reboot_plan.conf). Intended to run from a cron job
# on the orchestrator VM (typically at 02:00 local time).
#
# Flow:
#   1. Parse reboot_plan.conf — ordered list of "<DC-LABEL> <manager-ip>"
#   2. Read state file (run/rolling_global_state) — current index in plan
#   3. If index >= PLAN_COUNT: plan complete, exit 0 (operator runs --reset)
#   4. Resolve (dc,ip) at the current index
#   5. Call bin/run_across_datacenters.sh --only-dc <dc> -- --only <ip>
#   6. On rc=0: advance index. On rc!=0: keep index, cron retries next day.
#
# Why 1 manager per cron firing:
#   - Operators with ~21 managers prefer "21 days, 1 manager each" over
#     "all 21 at once on day 1 of the month". KB 396719 is mitigated
#     equally either way, but a daily cadence limits blast radius and
#     spreads load on the cluster STABLE gate.
#
# Flags:
#   --conf <file>     datacenters.conf  (default: <repo>/datacenters.conf)
#   --plan <file>     reboot_plan.conf  (default: <repo>/reboot_plan.conf)
#   --state <file>    state file path   (default: <repo>/run/rolling_global_state)
#   --dry-run         Forward --dry-run to the remote automation. Does NOT
#                     advance the index — pure preview, can run anytime.
#   --list            Print the plan with [DONE]/[NEXT]/[PENDING] markers
#                     and exit. No SSH, no state mutation.
#   --show-state      Print the current state file content and exit.
#   --reset           Reset the index to 0 (operator must confirm with --yes
#                     or by passing the flag interactively at a TTY).
#   --advance         Skip the next manager without rebooting it (advances
#                     index by 1, records last_status=skipped). Use when a
#                     manager has already been rebooted out-of-band.
#   --yes             Non-interactive confirmation for --reset.
#   -h | --help       Show this header.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export AUTO_DIR="${REPO_ROOT}"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

CONF="${REPO_ROOT}/datacenters.conf"
PLAN="${REPO_ROOT}/reboot_plan.conf"
STATE="${RUN_DIR}/rolling_global_state"

DRY_RUN=false
LIST=false
SHOW_STATE=false
RESET=false
ADVANCE=false
YES=false

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf)        CONF="$2"; shift 2 ;;
    --plan)        PLAN="$2"; shift 2 ;;
    --state)       STATE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --list)        LIST=true; shift ;;
    --show-state)  SHOW_STATE=true; shift ;;
    --reset)       RESET=true; shift ;;
    --advance)     ADVANCE=true; shift ;;
    --yes)         YES=true; shift ;;
    -h|--help)     usage ;;
    *) log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

[[ -f "${PLAN}" ]] || { log_err "Reboot plan not found: ${PLAN}"; exit 1; }
[[ -f "${CONF}" ]] || { log_err "Datacenters config not found: ${CONF}"; exit 1; }

# --- Plan parser (populates PLAN_COUNT / PLAN_DCS / PLAN_IPS) --------------
parse_reboot_plan "${PLAN}"

# --- State load (key=value file) -------------------------------------------
INDEX=0
LAST_IP=""
LAST_DC=""
LAST_RUN=""
LAST_STATUS=""
if [[ -f "${STATE}" ]]; then
  # shellcheck disable=SC1090
  while IFS='=' read -r k v; do
    case "${k}" in
      index)       INDEX="${v}" ;;
      last_ip)     LAST_IP="${v}" ;;
      last_dc)     LAST_DC="${v}" ;;
      last_run)    LAST_RUN="${v}" ;;
      last_status) LAST_STATUS="${v}" ;;
    esac
  done < "${STATE}"
fi
[[ "${INDEX}" =~ ^[0-9]+$ ]] || INDEX=0

write_state(){
  local idx="$1" ip="$2" dc="$3" status="$4"
  umask 077
  {
    printf 'index=%s\n'       "${idx}"
    printf 'last_ip=%s\n'     "${ip}"
    printf 'last_dc=%s\n'     "${dc}"
    printf 'last_run=%s\n'    "$(date -Iseconds 2>/dev/null || date '+%FT%T')"
    printf 'last_status=%s\n' "${status}"
  } > "${STATE}"
}

# --- Sub-commands that don't reboot anything -------------------------------
if "${SHOW_STATE}"; then
  printf 'plan=%s\n'    "${PLAN}"
  printf 'plan_size=%s\n' "${PLAN_COUNT}"
  printf 'index=%s\n'   "${INDEX}"
  printf 'remaining=%s\n' "$(( PLAN_COUNT - INDEX ))"
  printf 'last_dc=%s\n' "${LAST_DC}"
  printf 'last_ip=%s\n' "${LAST_IP}"
  printf 'last_run=%s\n' "${LAST_RUN}"
  printf 'last_status=%s\n' "${LAST_STATUS}"
  exit 0
fi

if "${LIST}"; then
  log_banner "Rolling reboot plan — ${PLAN_COUNT} manager(s)"
  local_i=0
  while (( local_i < PLAN_COUNT )); do
    marker=""
    if   (( local_i  < INDEX )); then marker="[DONE]   "
    elif (( local_i == INDEX )); then marker="[NEXT]   "
    else                              marker="[PENDING]"
    fi
    printf '%s %3d  %-20s  %s\n' "${marker}" "$(( local_i + 1 ))" \
      "$(plan_dc "${local_i}")" "$(plan_ip "${local_i}")"
    local_i=$(( local_i + 1 ))
  done
  exit 0
fi

if "${RESET}"; then
  if ! "${YES}"; then
    if [[ -t 0 ]]; then
      read -rp "Reset rolling-reboot index to 0? [y/N]: " ans </dev/tty
      [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { log "Aborted."; exit 1; }
    else
      log_err "--reset requires --yes when run non-interactively."
      exit 1
    fi
  fi
  rm -f "${STATE}"
  log_ok "State reset. Next run will start at index 0 (${PLAN_DCS[0]} ${PLAN_IPS[0]})."
  exit 0
fi

# --- Plan-complete short-circuit -------------------------------------------
if (( INDEX >= PLAN_COUNT )); then
  log_ok "Reboot plan complete (${PLAN_COUNT}/${PLAN_COUNT}). Run --reset to start over."
  exit 0
fi

DC="$(plan_dc "${INDEX}")"
IP="$(plan_ip "${INDEX}")"
POS="$(( INDEX + 1 ))/${PLAN_COUNT}"

# --- --advance: skip without rebooting -------------------------------------
if "${ADVANCE}"; then
  log_warn "Advancing index past ${POS} (${DC} ${IP}) WITHOUT rebooting."
  write_state "$(( INDEX + 1 ))" "${IP}" "${DC}" "skipped"
  log_ok "State advanced to index $(( INDEX + 1 ))."
  exit 0
fi

# --- Validate DC label exists in datacenters.conf (fail fast) --------------
parse_datacenters_conf "${CONF}"
dc_idx=""
for (( i=0; i<DC_COUNT; i++ )); do
  if [[ "${DC_LABELS[$i]}" == "${DC}" ]]; then dc_idx="${i}"; break; fi
done
if [[ -z "${dc_idx}" ]]; then
  log_err "Plan entry ${POS} references DC '${DC}', not found in ${CONF}."
  exit 1
fi

# --- Fan out to the one DC with --only <ip> --------------------------------
log_banner "Daily rolling reboot — ${POS} — ${DC} ${IP}"
remote_args=( --only "${IP}" )
if "${DRY_RUN}"; then remote_args+=( --dry-run ); fi

rc=0
"${SCRIPT_DIR}/run_across_datacenters.sh" \
    --conf "${CONF}" \
    --only-dc "${DC}" \
    --automation manager_rolling_reboot/nsx_rolling_reboot.sh \
    -- "${remote_args[@]}" \
  || rc=$?

if "${DRY_RUN}"; then
  log_ok "DRY-RUN complete — state NOT advanced. Would target ${DC} ${IP} (${POS})."
  exit "${rc}"
fi

if (( rc == 0 )); then
  write_state "$(( INDEX + 1 ))" "${IP}" "${DC}" "0"
  log_ok "Manager ${POS} (${DC} ${IP}) rebooted OK. Next firing: index $(( INDEX + 1 ))."
  rotate_logs
  exit 0
else
  write_state "${INDEX}" "${IP}" "${DC}" "${rc}"
  log_err "Manager ${POS} (${DC} ${IP}) FAILED (rc=${rc}). Cron will retry next firing."
  rotate_logs
  exit "${rc}"
fi
