#!/usr/bin/env bash
# bin/configure_ssh_keys_all_dcs.sh
#
# Orchestrator-side helper: walk every jump listed in datacenters.conf and run
# `./bin/configure_ssh_keys.sh` on each one, INTERACTIVELY. Use it to register
# the root key on the managers of the whole fleet in one pass:
#
#   orchestrator VM ── ssh -t ──► DC-A jump ──► ./bin/configure_ssh_keys.sh --type manager --root
#                   ── ssh -t ──► DC-B jump ──► ./bin/configure_ssh_keys.sh --type manager --root
#                   ── ssh -t ──► ...                                   (7 DCs)
#
# Why a separate script (not `run_across_datacenters.sh` / a `--all-dcs` flag on
# configure_ssh_keys.sh):
#   - configure_ssh_keys.sh runs *on a jump* against that jump's LOCAL inventory
#     (inventory/managers.conf). On the orchestrator that inventory is DC-A only,
#     so a plain local run touches DC-A alone. Each jump owns its own managers.
#   - Registering the root key needs the admin AND root passwords per cluster —
#     it is INTERACTIVE. The normal fan-out (run_across_datacenters.sh) is
#     non-interactive (ssh bash -lc, no tty) and cannot carry password prompts,
#     and passwords must never be written to disk/env. So this helper allocates a
#     tty per jump (`ssh -t`) and lets the remote script prompt you directly.
#     Nothing is stored on the orchestrator; each DC's creds live only on its jump
#     for the duration of that prompt.
#
# Usage:
#   ./bin/configure_ssh_keys_all_dcs.sh --conf <datacenters.conf>
#       [--only-dc <label>] [--ssh-key <path>] [-- <args for configure_ssh_keys.sh>]
#
# Examples:
#   # Register the root key on every DC's managers (the default remote command):
#   ./bin/configure_ssh_keys_all_dcs.sh --conf ./datacenters.conf
#
#   # Just one DC:
#   ./bin/configure_ssh_keys_all_dcs.sh --conf ./datacenters.conf --only-dc DC-B
#
#   # Override the remote command entirely (e.g. edges instead of manager root):
#   ./bin/configure_ssh_keys_all_dcs.sh --conf ./datacenters.conf -- --type edge
#
# Flags:
#   --conf <file>       datacenters.conf (jump hosts). Required.
#   --only-dc <label>   Run on ONLY this DC (must match a section label).
#   --ssh-key <path>    Override the per-DC ssh_key used to reach the jump.
#   -- <args...>        Everything after `--` is passed verbatim to the remote
#                       ./bin/configure_ssh_keys.sh. Default when omitted:
#                       --type manager --root
#   -h | --help         Show this header.
#
# Runs sequentially by design — you enter each DC's passwords in turn.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export AUTO_DIR="${REPO_ROOT}"
export NSX_AUTOMATION_NAME="orchestrator"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

CONF=""
ONLY_DC=""
SSH_KEY_OVERRIDE=""
REMOTE_ARGS=()

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf)     CONF="$2"; shift 2 ;;
    --only-dc)  ONLY_DC="$2"; shift 2 ;;
    --ssh-key)  SSH_KEY_OVERRIDE="$2"; shift 2 ;;
    -h|--help)  usage ;;
    --)         shift; REMOTE_ARGS=("$@"); break ;;
    *)          log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

[[ -z "${CONF}" ]] && { log_err "--conf <datacenters.conf> is required."; exit 1; }
[[ -f "${CONF}" ]] || { log_err "conf not found: ${CONF}"; exit 1; }

# Default remote command: register the root key on the managers.
if (( ${#REMOTE_ARGS[@]} == 0 )); then
  REMOTE_ARGS=(--type manager --root)
fi

need_cmd ssh
parse_datacenters_conf "${CONF}"

# Build the target list (filtered by --only-dc if given).
TARGETS=()
if [[ -n "${ONLY_DC}" ]]; then
  for (( i=0; i<DC_COUNT; i++ )); do
    [[ "${DC_LABELS[$i]}" == "${ONLY_DC}" ]] && TARGETS+=("${i}")
  done
  if (( ${#TARGETS[@]} == 0 )); then
    log_err "--only-dc='${ONLY_DC}' did not match any section in ${CONF}."
    exit 1
  fi
else
  for (( i=0; i<DC_COUNT; i++ )); do TARGETS+=("${i}"); done
fi

# printf %q each arg so nothing expands on the orchestrator's shell.
_quote_args(){
  local out="" a
  for a in "$@"; do out+=" $(printf '%q' "$a")"; done
  printf '%s' "${out# }"
}

log_banner "Interactive SSH-key config — ${#TARGETS[@]} datacenter(s)${ONLY_DC:+ (filtered: ${ONLY_DC})}"
log "Remote command per jump: ./bin/configure_ssh_keys.sh ${REMOTE_ARGS[*]}"
log "You will be prompted for each DC's admin + root passwords on its own jump."
log "Nothing is stored on the orchestrator; sequential, one DC at a time."

OK_DCS=()
FAIL_DCS=()

for idx in "${TARGETS[@]}"; do
  label="${DC_LABELS[$idx]}"
  host="$(dc_jump_host "${idx}")"
  user="$(dc_jump_user "${idx}")"
  repo="$(dc_repo_path "${idx}")"
  key="${SSH_KEY_OVERRIDE:-$(dc_ssh_key "${idx}")}"
  key="${key/#\~/$HOME}"   # expand a leading ~

  log_banner "[${label}] ${user}@${host}"

  if [[ ! -f "${key}" ]]; then
    log_err "[${label}] SSH key not found: ${key} — skipping."
    FAIL_DCS+=("${label}")
    continue
  fi

  # Remote command as a single-quoted string so $repo / args expand on the jump.
  printf -v remote_cmd 'cd %q && ./bin/configure_ssh_keys.sh %s' \
    "${repo}" "$(_quote_args "${REMOTE_ARGS[@]}")"

  # -t: allocate a tty so the remote script can prompt for NSX passwords.
  # BatchMode=yes: reach the jump with the key only (no jump-password fallback);
  # it does not affect the remote program's ability to read from the tty.
  rc=0
  ssh -t -i "${key}" \
      -o BatchMode=yes \
      -o ForwardAgent=no \
      -o IdentitiesOnly=yes \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=15 \
      -o ServerAliveInterval=30 \
      "${user}@${host}" \
      "bash -lc $(printf '%q' "${remote_cmd}")" || rc=$?

  if (( rc == 0 )); then
    log_ok "[${label}] configure_ssh_keys.sh completed."
    OK_DCS+=("${label}")
  else
    log_err "[${label}] configure_ssh_keys.sh FAILED (rc=${rc})."
    FAIL_DCS+=("${label}")
  fi
done

log_banner "SSH-key config summary"
log_ok "Succeeded (${#OK_DCS[@]}): ${OK_DCS[*]:-none}"
if (( ${#FAIL_DCS[@]} > 0 )); then
  log_err "Failed/skipped (${#FAIL_DCS[@]}): ${FAIL_DCS[*]}"
  exit 1
fi
