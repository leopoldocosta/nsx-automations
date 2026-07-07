#!/usr/bin/env bash
# bin/run_command_across_dcs.sh
#
# Run an arbitrary shell command on EVERY jump VM in datacenters.conf
# (or a single one with --only-dc). The "ansible ad-hoc" of this toolkit:
# perfect for smoke-testing the orchestrator -> jump SSH mesh before
# running real automations, or for quick estate-wide checks.
#
# Usage:
#   ./bin/run_command_across_dcs.sh [--conf <file>] [--only-dc <label>] -- <command...>
#
# Examples:
#   ./bin/run_command_across_dcs.sh -- hostname
#   ./bin/run_command_across_dcs.sh -- "uname -a && uptime"
#   ./bin/run_command_across_dcs.sh --only-dc DC-7 -- "df -h /"
#   ./bin/run_command_across_dcs.sh -- "cd ~/nsx-automations && git log -1 --oneline"
#
# Flags:
#   --conf <file>       datacenters.conf (default: <repo>/datacenters.conf)
#   --only-dc <label>   Run on ONLY this DC section.
#   --dry-run           Print the ssh command per DC without executing.
#   --                  REQUIRED separator; everything after is the remote
#                       command (quote it if it contains pipes/&&).
#
# Behavior:
#   - Sequential, one DC at a time, output streamed under a per-DC banner.
#   - Same SSH posture as the automation fan-out: BatchMode=yes,
#     ForwardAgent=no, IdentitiesOnly=yes, ConnectTimeout=10.
#   - Summary table at the end; exit code = number of failed DCs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export AUTO_DIR="${REPO_ROOT}"
export NSX_AUTOMATION_NAME="orchestrator"   # notify.conf key for bin/ tools
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

CONF="${REPO_ROOT}/datacenters.conf"
ONLY_DC=""
DRY_RUN=false

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

CMD_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf)    CONF="$2"; shift 2 ;;
    --only-dc) ONLY_DC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    --)        shift; CMD_ARGS=("$@"); break ;;
    *)         log_err "Unknown flag: $1 (remote command goes after --)"; exit 1 ;;
  esac
done

(( ${#CMD_ARGS[@]} > 0 )) || { log_err "No command given. Usage: $(basename "$0") [--conf f] [--only-dc L] -- <command>"; exit 1; }
[[ -f "${CONF}" ]] || { log_err "Conf not found: ${CONF}"; exit 1; }
need_cmd ssh

# Join args into one remote command string. A single quoted arg keeps
# pipes/&& intact; multiple bare args are joined with spaces.
REMOTE_CMD="${CMD_ARGS[*]}"

parse_datacenters_conf "${CONF}"

TARGETS=()
if [[ -n "${ONLY_DC}" ]]; then
  for (( i=0; i<DC_COUNT; i++ )); do
    [[ "${DC_LABELS[$i]}" == "${ONLY_DC}" ]] && TARGETS+=("${i}")
  done
  (( ${#TARGETS[@]} > 0 )) || { log_err "--only-dc='${ONLY_DC}' did not match any section in ${CONF}."; exit 1; }
else
  for (( i=0; i<DC_COUNT; i++ )); do TARGETS+=("${i}"); done
fi

declare -a R_DC=() R_RC=() R_SECS=()
FAILED=0

for i in "${TARGETS[@]}"; do
  dc="${DC_LABELS[$i]}"
  host="$(dc_jump_host "${i}")"
  user="$(dc_jump_user "${i}")"
  key="$(dc_ssh_key   "${i}")"
  key="${key/#\~/$HOME}"

  log_banner "[${dc}] ${user}@${host}"
  ssh_cmd=(ssh -i "${key}"
           -o BatchMode=yes -o ForwardAgent=no -o IdentitiesOnly=yes
           -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
           "${user}@${host}" "bash -lc $(printf '%q' "${REMOTE_CMD}")")

  if "${DRY_RUN}"; then
    printf '  DRY-RUN: %q ' "${ssh_cmd[@]}"; echo
    R_DC+=("${dc}"); R_RC+=("dry"); R_SECS+=(0)
    continue
  fi

  t0=$(date +%s)
  rc=0
  "${ssh_cmd[@]}" || rc=$?
  t1=$(date +%s)

  R_DC+=("${dc}"); R_RC+=("${rc}"); R_SECS+=($(( t1 - t0 )))
  if (( rc == 0 )); then
    log_ok "[${dc}] exit 0 ($(( t1 - t0 ))s)"
  else
    log_err "[${dc}] exit ${rc} ($(( t1 - t0 ))s)"
    FAILED=$(( FAILED + 1 ))
  fi
done

echo ""
log_banner "Summary — command: ${REMOTE_CMD}"
printf '  %-12s %-8s %s\n' "DC" "EXIT" "SECONDS"
for (( j=0; j<${#R_DC[@]}; j++ )); do
  printf '  %-12s %-8s %s\n' "${R_DC[$j]}" "${R_RC[$j]}" "${R_SECS[$j]}"
done

exit "${FAILED}"
