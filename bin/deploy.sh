#!/usr/bin/env bash
# bin/deploy.sh — v1.0
# Optional, top-level installer.
# Copies the repo tree (lib/, bin/, automations/[<name>]) to a target host
# (jump/monitor server) so the scripts can be executed there.
#
# Some automations (e.g. kb404700_disk_validation) don't need deploy — you
# can clone the repo on the target host and run them directly.
#
# Usage:
#   ./bin/deploy.sh --target user@host:~/nsx-automations [--automation manager_rolling_reboot] [--deps] [--dry-run]
#
# Flags:
#   --target <user@host:path>    Destination. Required.
#   --automation <name>          Install only one automation (default: all).
#   --deps                       After copying, install OS deps on the target.
#   --dry-run                    Show actions without executing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

TARGET=""
AUTOMATION=""
DO_DEPS=false
DRY_RUN=false

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     TARGET="$2"; shift 2 ;;
    --automation) AUTOMATION="$2"; shift 2 ;;
    --deps)       DO_DEPS=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    usage ;;
    *) log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

[[ -z "${TARGET}" ]] && { log_err "--target is required."; exit 1; }

need_cmd rsync || need_cmd scp

# Source paths to copy
SRC_ITEMS=("${REPO_ROOT}/lib" "${REPO_ROOT}/bin" "${REPO_ROOT}/docs" "${REPO_ROOT}/README.md")
if [[ -n "${AUTOMATION}" ]]; then
  AUTO_PATH="${REPO_ROOT}/automations/${AUTOMATION}"
  [[ -d "${AUTO_PATH}" ]] || { log_err "Automation not found: ${AUTOMATION}"; exit 1; }
  SRC_ITEMS+=("${AUTO_PATH}")
else
  SRC_ITEMS+=("${REPO_ROOT}/automations")
fi

log_banner "Deploying to ${TARGET}"
log "Items to copy:"
for it in "${SRC_ITEMS[@]}"; do echo "  - ${it}"; done

# Split TARGET into host:path
T_HOST="${TARGET%%:*}"
T_PATH="${TARGET#*:}"
[[ "${T_HOST}" == "${TARGET}" ]] && T_PATH="\$HOME/nsx-automations"

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

# 1. Ensure target dir exists
run_or_show ssh -o StrictHostKeyChecking=no "${T_HOST}" "mkdir -p ${T_PATH}"

# 2. rsync (preferred) or scp fallback
if command -v rsync >/dev/null 2>&1; then
  for it in "${SRC_ITEMS[@]}"; do
    run_or_show rsync -avz --delete-excluded \
      --exclude logs/ --exclude run/ --exclude .ssh_keys/ \
      "${it}" "${T_HOST}:${T_PATH}/"
  done
else
  for it in "${SRC_ITEMS[@]}"; do
    run_or_show scp -r "${it}" "${T_HOST}:${T_PATH}/"
  done
fi

# 3. Optional: install deps on the target
if "${DO_DEPS}"; then
  log "Installing dependencies on ${T_HOST}..."
  run_or_show ssh "${T_HOST}" \
    "cd ${T_PATH} && bash -lc 'source lib/common.sh && install_pkg openssh-client sshpass'"
fi

log_ok "Deploy complete."
echo ""
echo "On the target host:"
echo "  cd ${T_PATH}"
echo "  ls automations/"
