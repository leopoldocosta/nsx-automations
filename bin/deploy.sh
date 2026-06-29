#!/usr/bin/env bash
# bin/deploy.sh — v1.1
# Optional, top-level installer.
# Copies the repo tree (lib/, bin/, automations/[<name>]) to a target host
# (jump/monitor server) so the scripts can be executed there.
#
# Some automations (e.g. kb404700_disk_validation) don't need deploy — you
# can clone the repo on the target host and run them directly.
#
# Usage (single target):
#   ./bin/deploy.sh --target user@host:~/nsx-automations [--automation manager_rolling_reboot] [--deps] [--dry-run]
#
# Usage (fan-out to every datacenter in datacenters.conf):
#   ./bin/deploy.sh --all-dcs --conf ./datacenters.conf [--automation <name>] [--deps] [--dry-run]
#
# Flags:
#   --target <user@host:path>    Single destination. Mutually exclusive with --all-dcs.
#   --all-dcs                    Deploy to every section of datacenters.conf.
#   --conf <file>                datacenters.conf (required with --all-dcs).
#   --automation <name>          Install only one automation (default: all).
#   --deps                       After copying, install OS deps on the target.
#   --dry-run                    Show actions without executing.
#   --ssh-key <path>             Private key for the orchestrator -> jump SSH.
#                                Overrides per-DC ssh_key from datacenters.conf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export AUTO_DIR="${REPO_ROOT}"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

TARGET=""
ALL_DCS=false
CONF=""
AUTOMATION=""
DO_DEPS=false
DRY_RUN=false
SSH_KEY_OVERRIDE=""

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     TARGET="$2"; shift 2 ;;
    --all-dcs)    ALL_DCS=true; shift ;;
    --conf)       CONF="$2"; shift 2 ;;
    --automation) AUTOMATION="$2"; shift 2 ;;
    --deps)       DO_DEPS=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --ssh-key)    SSH_KEY_OVERRIDE="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *) log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

if "${ALL_DCS}"; then
  [[ -n "${TARGET}" ]] && { log_err "--all-dcs and --target are mutually exclusive."; exit 1; }
  [[ -z "${CONF}"   ]] && { log_err "--all-dcs requires --conf <datacenters.conf>"; exit 1; }
  [[ -f "${CONF}"   ]] || { log_err "Conf not found: ${CONF}"; exit 1; }
else
  [[ -z "${TARGET}" ]] && { log_err "--target is required (or use --all-dcs)."; exit 1; }
fi

need_cmd rsync || need_cmd scp

# Source paths to copy — identical for single and multi-DC modes.
SRC_ITEMS=("${REPO_ROOT}/lib" "${REPO_ROOT}/bin" "${REPO_ROOT}/docs" "${REPO_ROOT}/README.md")
if [[ -n "${AUTOMATION}" ]]; then
  AUTO_PATH="${REPO_ROOT}/automations/${AUTOMATION}"
  [[ -d "${AUTO_PATH}" ]] || { log_err "Automation not found: ${AUTOMATION}"; exit 1; }
  SRC_ITEMS+=("${AUTO_PATH}")
else
  SRC_ITEMS+=("${REPO_ROOT}/automations")
fi

# run_or_show <argv...> — execute argv directly (no eval). With --dry-run,
# prints the command instead. Arguments are passed verbatim, so no shell
# metachar in TARGET/T_PATH gets reinterpreted.
run_or_show(){
  if "${DRY_RUN}"; then
    printf '  [DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# deploy_to_target <user@host:path> [ssh_key]
#   Encapsulates the per-target rsync / scp logic so --all-dcs can loop.
# ---------------------------------------------------------------------------
deploy_to_target(){
  local target="$1" key="${2:-}"
  local t_host="${target%%:*}"
  local t_path="${target#*:}"
  [[ "${t_host}" == "${target}" ]] && t_path="\$HOME/nsx-automations"

  local -a ssh_opts=()
  local -a rsync_e=()
  if [[ -n "${key}" ]]; then
    key="${key/#\~/$HOME}"
    [[ -f "${key}" ]] || { log_err "SSH key not found: ${key}"; return 1; }
    ssh_opts+=(-i "${key}" -o IdentitiesOnly=yes)
    rsync_e=(-e "ssh -i ${key} -o IdentitiesOnly=yes -o BatchMode=yes -o ForwardAgent=no -o StrictHostKeyChecking=accept-new")
  fi

  log_banner "Deploying to ${target}"
  log "Items to copy:"
  for it in "${SRC_ITEMS[@]}"; do echo "  - ${it}"; done

  # 1. Ensure target dir exists
  run_or_show ssh "${ssh_opts[@]}" -o StrictHostKeyChecking=accept-new \
    "${t_host}" "mkdir -p ${t_path}"

  # 2. rsync (preferred) or scp fallback
  if command -v rsync >/dev/null 2>&1; then
    for it in "${SRC_ITEMS[@]}"; do
      run_or_show rsync -avz --delete-excluded \
        --exclude logs/ --exclude run/ --exclude .ssh_keys/ --exclude aggregated_logs/ \
        "${rsync_e[@]}" \
        "${it}" "${t_host}:${t_path}/"
    done
  else
    for it in "${SRC_ITEMS[@]}"; do
      run_or_show scp "${ssh_opts[@]}" -r "${it}" "${t_host}:${t_path}/"
    done
  fi

  # 3. Optional: install deps on the target
  if "${DO_DEPS}"; then
    log "Installing dependencies on ${t_host}..."
    run_or_show ssh "${ssh_opts[@]}" "${t_host}" \
      "cd ${t_path} && bash -lc 'source lib/common.sh && install_pkg openssh-client sshpass'"
  fi

  log_ok "Deploy to ${target} complete."
}

# ---------------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------------
overall_rc=0
if "${ALL_DCS}"; then
  parse_datacenters_conf "${CONF}"
  for (( i=0; i<DC_COUNT; i++ )); do
    label="${DC_LABELS[$i]}"
    target="$(dc_jump_user "$i")@$(dc_jump_host "$i"):$(dc_repo_path "$i")"
    key="${SSH_KEY_OVERRIDE:-$(dc_ssh_key "$i")}"
    log_banner "[${label}]"
    deploy_to_target "${target}" "${key}" || { overall_rc=1; log_err "[${label}] deploy failed"; }
  done
  log_banner "Multi-DC deploy summary"
  if (( overall_rc == 0 )); then
    log_ok "All ${DC_COUNT} datacenter(s) updated."
  else
    log_err "One or more datacenter deploys failed — see log above."
  fi
else
  deploy_to_target "${TARGET}" "${SSH_KEY_OVERRIDE}" || overall_rc=$?
  echo ""
  echo "On the target host:"
  echo "  cd ${TARGET#*:}"
  echo "  ls automations/"
fi

exit "${overall_rc}"
