#!/usr/bin/env bash
# bin/run_across_datacenters.sh
#
# Fan-out an automation to every datacenter listed in datacenters.conf and
# pull the resulting logs/ back to the orchestrator. Designed for the
# hub-and-spoke topology:
#
#   orchestrator VM ── SSH ──► DC-A jump VM ──► NSX of DC-A
#                   ── SSH ──► DC-B jump VM ──► NSX of DC-B
#                   ── SSH ──► DC-C jump VM ──► NSX of DC-C
#
# Each jump VM owns the NSX credentials/keys for its own DC. The orchestrator
# only needs an SSH key to the jump VMs (default ~/.ssh/orchestrator).
#
# Usage:
#   ./bin/run_across_datacenters.sh \
#       --conf       <datacenters.conf>           \
#       --automation <relpath/inside/automations>  [--parallel N] \
#       [--no-pull-logs] [--out <dir>] [--ssh-key <path>] \
#       [--] [args passed verbatim to the remote automation]
#
# Example:
#   ./bin/run_across_datacenters.sh \
#       --conf ./datacenters.conf \
#       --automation manager_rolling_reboot/nsx_rolling_reboot.sh \
#       -- --dry-run
#
# Flags:
#   --conf <file>          datacenters.conf. Required.
#   --automation <rel>     Path under automations/ to run on each jump.
#                          Example: manager_rolling_reboot/nsx_rolling_reboot.sh
#   --parallel N           Run up to N DCs concurrently (default 1, sequential).
#                          Uses `wait -n` to cap fan-out without xargs fragility.
#   --only-dc <label>      Fan out to ONLY this DC (must match a section in
#                          datacenters.conf). Used by the daily rolling-reboot
#                          orchestrator (bin/rolling_reboot_next.sh) to target
#                          one DC per cron firing.
#   --no-pull-logs         Skip the rsync pull of automations/<auto>/logs/.
#   --out <dir>            Aggregation directory on the orchestrator.
#                          Default: ./aggregated_logs/<YYYYMMDD_HHMMSS>/
#   --ssh-key <path>       Override the per-DC ssh_key from datacenters.conf.
#   -h | --help            Show this header.
#
# Security posture:
#   - SSH flags hard-coded: -o BatchMode=yes -o ForwardAgent=no
#     -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes
#   - Each remote command is exec'd via `ssh user@host -- bash -c <quoted>`
#     so neither $TARGET, $REPO nor $ARGS goes through `eval`.
#   - datacenters.conf is parsed with the same anti-injection validation as
#     managers.conf (see lib/common.sh:parse_datacenters_conf).
#   - On the jump, the script honors NSX_NOTIFY_WEBHOOK / NSX_DEBUG /
#     NSX_LOG_RETENTION_DAYS exactly like a local run.
#
# Output:
#   <out>/summary.csv             dc,start,end,duration_s,exit_code,log_path
#   <out>/<dc-label>/run.log      full stdout+stderr of the remote run
#   <out>/<dc-label>/logs/...     rsync of the remote automation's logs/ (unless --no-pull-logs)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export AUTO_DIR="${REPO_ROOT}"          # write logs/ next to the orchestrator script
export NSX_AUTOMATION_NAME="orchestrator"   # notify.conf key for bin/ tools
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

CONF=""
AUTOMATION=""
PARALLEL=1
PULL_LOGS=true
OUT_BASE=""
SSH_KEY_OVERRIDE=""
ONLY_DC=""

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# argv parsing — `--` ends our flags, everything after goes to the remote auto.
REMOTE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf)         CONF="$2"; shift 2 ;;
    --automation)   AUTOMATION="$2"; shift 2 ;;
    --parallel)     PARALLEL="$2"; shift 2 ;;
    --only-dc)      ONLY_DC="$2"; shift 2 ;;
    --no-pull-logs) PULL_LOGS=false; shift ;;
    --out)          OUT_BASE="$2"; shift 2 ;;
    --ssh-key)      SSH_KEY_OVERRIDE="$2"; shift 2 ;;
    -h|--help)      usage ;;
    --)             shift; REMOTE_ARGS=("$@"); break ;;
    *)              log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

[[ -z "${CONF}" ]]       && { log_err "--conf is required."; exit 1; }
[[ -z "${AUTOMATION}" ]] && { log_err "--automation is required (e.g. manager_rolling_reboot/nsx_rolling_reboot.sh)"; exit 1; }
[[ -f "${CONF}" ]]       || { log_err "Conf not found: ${CONF}"; exit 1; }
[[ "${PARALLEL}" =~ ^[1-9][0-9]*$ ]] || { log_err "--parallel must be a positive integer"; exit 1; }

# Sanity: the automation must exist locally (mirrors what's deployed)
LOCAL_AUTO="${REPO_ROOT}/automations/${AUTOMATION}"
[[ -f "${LOCAL_AUTO}" ]] || { log_err "Automation not found locally: automations/${AUTOMATION}"; exit 1; }
AUTO_DIR_REL="$(dirname "automations/${AUTOMATION}")"

need_cmd ssh
"${PULL_LOGS}" && need_cmd rsync

parse_datacenters_conf "${CONF}"

# Build the list of DC indexes to fan out to (filtered by --only-dc if set).
TARGETS=()
if [[ -n "${ONLY_DC}" ]]; then
  for (( i=0; i<DC_COUNT; i++ )); do
    if [[ "${DC_LABELS[$i]}" == "${ONLY_DC}" ]]; then
      TARGETS+=("${i}")
    fi
  done
  if (( ${#TARGETS[@]} == 0 )); then
    log_err "--only-dc='${ONLY_DC}' did not match any section in ${CONF}."
    exit 1
  fi
else
  for (( i=0; i<DC_COUNT; i++ )); do TARGETS+=("${i}"); done
fi

TS="$(date +%Y%m%d_%H%M%S)"
OUT_BASE="${OUT_BASE:-${REPO_ROOT}/aggregated_logs/${TS}}"
mkdir -p "${OUT_BASE}"

SUMMARY="${OUT_BASE}/summary.csv"
echo 'dc,start,end,duration_s,exit_code,log_path' > "${SUMMARY}"

# Lock the orchestrator so two concurrent fan-outs don't trample summary.csv
LOCK_FILE="/tmp/nsx_fanout.lock"
if [[ -f "${LOCK_FILE}" ]]; then
  PID="$(cat "${LOCK_FILE}" 2>/dev/null || echo)"
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    log_err "[LOCKED] orchestrator already running (PID ${PID}). Exiting."
    exit 1
  fi
  rm -f "${LOCK_FILE}"
fi
echo $$ > "${LOCK_FILE}"
trap 'rm -f "${LOCK_FILE}"' EXIT INT TERM

# ---------------------------------------------------------------------------
# run_one_dc <idx> — sequential body, also the unit dispatched in parallel.
# Writes its own row to ${SUMMARY} via flock to keep CSV atomic across DCs.
# ---------------------------------------------------------------------------
run_one_dc(){
  local idx="$1"
  local label="${DC_LABELS[$idx]}"
  local host user repo key
  host="$(dc_jump_host "${idx}")"
  user="$(dc_jump_user "${idx}")"
  repo="$(dc_repo_path "${idx}")"
  key="${SSH_KEY_OVERRIDE:-$(dc_ssh_key "${idx}")}"

  # Expand a leading ~ in the key path
  key="${key/#\~/$HOME}"

  local dc_out="${OUT_BASE}/${label}"
  local run_log="${dc_out}/run.log"
  mkdir -p "${dc_out}"

  log_banner "[${label}] ${user}@${host}: ${AUTOMATION}"

  if [[ ! -f "${key}" ]]; then
    log_err "[${label}] SSH key not found: ${key}"
    printf '%s,%s,%s,%s,%s,%s\n' "${label}" "" "" "" "127" "${run_log}" \
      | _csv_append "${SUMMARY}"
    return 127
  fi

  local start_s end_s dur rc=0
  start_s="$(date +%s)"

  # Build the remote command as a single-quoted string so $REPO/$AUTOMATION
  # never expand on the orchestrator's shell — only on the jump's.
  # The remote uses `bash -lc` so the jump's ~/.bashrc-defined NSX_NOTIFY_WEBHOOK
  # and friends are honored.
  local remote_cmd
  printf -v remote_cmd 'cd %q && ./automations/%q %s' \
    "${repo}" "${AUTOMATION}" "$(_quote_args "${REMOTE_ARGS[@]}")"

  ssh -i "${key}" \
      -o BatchMode=yes \
      -o ForwardAgent=no \
      -o StrictHostKeyChecking=accept-new \
      -o IdentitiesOnly=yes \
      -o ConnectTimeout=15 \
      -o ServerAliveInterval=30 \
      "${user}@${host}" \
      "bash -lc $(printf '%q' "${remote_cmd}")" \
      > "${run_log}" 2>&1 || rc=$?

  end_s="$(date +%s)"
  dur=$(( end_s - start_s ))

  if (( rc == 0 )); then
    log_ok "[${label}] completed in ${dur}s — log: ${run_log}"
  else
    log_err "[${label}] FAILED (rc=${rc}) in ${dur}s — log: ${run_log}"
  fi

  # Optional rsync pull of the automation's logs/ directory
  if "${PULL_LOGS}"; then
    rsync -az --delete \
      -e "ssh -i ${key} -o BatchMode=yes -o ForwardAgent=no -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
      "${user}@${host}:${repo}/${AUTO_DIR_REL}/logs/" \
      "${dc_out}/logs/" 2>>"${run_log}" || \
      log_warn "[${label}] rsync pull of logs/ failed (run still recorded)"
  fi

  printf '%s,%s,%s,%s,%s,%s\n' \
    "${label}" "${start_s}" "${end_s}" "${dur}" "${rc}" "${run_log}" \
    | _csv_append "${SUMMARY}"

  return "${rc}"
}

# ---------------------------------------------------------------------------
# CSV-append helper — flock so parallel DCs don't interleave rows.
# ---------------------------------------------------------------------------
_csv_append(){
  local target="$1"
  if command -v flock >/dev/null 2>&1; then
    flock "${target}" -c "cat >> '${target}'"
  else
    cat >> "${target}"
  fi
}

# ---------------------------------------------------------------------------
# Argv quoter — produces a shell-safe joined string of arguments.
# ---------------------------------------------------------------------------
_quote_args(){
  local out="" a
  for a in "$@"; do
    out+=" $(printf '%q' "$a")"
  done
  printf '%s' "${out# }"
}

# ---------------------------------------------------------------------------
# Fan-out: sequential (PARALLEL=1) or capped concurrency via `wait -n`.
# ---------------------------------------------------------------------------
log_banner "Multi-DC fan-out — ${#TARGETS[@]} datacenter(s), parallelism=${PARALLEL}${ONLY_DC:+ (filtered: ${ONLY_DC})}"
log "Automation: ${AUTOMATION}  args: ${REMOTE_ARGS[*]:-(none)}"
log "Output:     ${OUT_BASE}"

overall_rc=0
if (( PARALLEL == 1 )); then
  for idx in "${TARGETS[@]}"; do
    run_one_dc "${idx}" || overall_rc=1
  done
else
  declare -a pids=()
  declare -a labels=()
  active=0
  for idx in "${TARGETS[@]}"; do
    run_one_dc "${idx}" &
    pids+=("$!")
    labels+=("${DC_LABELS[$idx]}")
    active=$(( active + 1 ))
    if (( active >= PARALLEL )); then
      if wait -n 2>/dev/null; then
        :
      else
        overall_rc=1
      fi
      active=$(( active - 1 ))
    fi
  done
  # Drain remaining
  while (( active > 0 )); do
    if wait -n 2>/dev/null; then :; else overall_rc=1; fi
    active=$(( active - 1 ))
  done
fi

log_banner "Multi-DC fan-out — done"
log "Summary CSV: ${SUMMARY}"
column -ts, "${SUMMARY}" 2>/dev/null || cat "${SUMMARY}"

# ---------------------------------------------------------------------------
# Unified fleet report — lift each DC's report block (delimited by the
# NSX_REPORT_BEGIN/END sentinels from lib/common.sh) out of its run.log and
# print them together, so the operator reads every DC at once instead of
# cat-ing each log by hand. DCs whose automation emits no report block (e.g.
# rolling reboot) are simply noted; if no DC emitted one, this is skipped.
# ---------------------------------------------------------------------------
UNIFIED="${OUT_BASE}/unified_report.txt"
have_report=false
for idx in "${TARGETS[@]}"; do
  if grep -qF "${NSX_REPORT_BEGIN}" "${OUT_BASE}/${DC_LABELS[$idx]}/run.log" 2>/dev/null; then
    have_report=true; break
  fi
done

if "${have_report}"; then
  {
    printf '\n%s\n' "$(printf '#%.0s' {1..72})"
    printf '#  Unified report — %s datacenter(s)   %s\n' "${#TARGETS[@]}" "$(date '+%F %T')"
    printf '%s\n' "$(printf '#%.0s' {1..72})"
    for idx in "${TARGETS[@]}"; do
      label="${DC_LABELS[$idx]}"
      rl="${OUT_BASE}/${label}/run.log"
      printf '\n==================== %s ====================\n' "${label}"
      if [[ -f "${rl}" ]] && grep -qF "${NSX_REPORT_BEGIN}" "${rl}"; then
        awk -v b="${NSX_REPORT_BEGIN}" -v e="${NSX_REPORT_END}" '
          index($0,b){f=1;next} index($0,e){f=0;next} f' "${rl}"
      else
        printf '  (no report block — automation emitted none; see %s)\n' "${rl}"
      fi
    done
  } | tee "${UNIFIED}"
  log "Unified report saved to: ${UNIFIED}"
fi

exit "${overall_rc}"
