#!/usr/bin/env bash
# bin/configure_ssh_keys.sh — v1.0
# Registers an SSH key on NSX Edge Nodes or NSX Managers so subsequent
# automations can run without prompting for passwords.
#
# Usage:
#   # Local — register on THIS DC's NSX (reads the local central inventory):
#   ./bin/configure_ssh_keys.sh --type edge    [--hosts <edge_nodes.txt>]
#   ./bin/configure_ssh_keys.sh --type manager [--hosts <managers.conf>] [--root]
#
#   # Fleet — from the ORCHESTRATOR, run this same script on EVERY jump
#   # (interactive, one DC at a time; each jump uses its own inventory):
#   ./bin/configure_ssh_keys.sh --all-dcs --conf <datacenters.conf> [--only-dc <label>]
#                               [--type manager --root]   # default when omitted
#
# Flags:
#   --all-dcs                   Orchestrator fan-out: walk every jump in --conf and
#                               run THIS script there over `ssh -t` (interactive —
#                               each DC's passwords are entered on its own jump,
#                               nothing is stored here). The remaining flags below
#                               (--type/--root/--key/--label) are forwarded to each
#                               per-jump run; they default to `--type manager --root`.
#                               Mirrors `deploy.sh --all-dcs`.
#   --conf <file>               datacenters.conf (jump hosts). Required with --all-dcs.
#   --only-dc <label>           With --all-dcs: run on ONLY this DC section.
#   --ssh-key <path>            With --all-dcs: override the orchestrator->jump key.
#   --type edge|manager         Required (local mode). Edge uses ssh-key per user
#                               (admin + root); manager uses `set user ... ssh-keys
#                               label ... value ...`.
#   --hosts <file>              For edge: a flat text file of IPs.
#                               For manager: an INI managers.conf (multi-cluster).
#                               Default: inventory/edge_nodes.txt or
#                               inventory/managers.conf (central per-DC inventory).
#   --key <path>                Local SSH private key. Default: ~/.ssh/id_rsa.
#                               Key type (ssh-rsa, ssh-ed25519, ...) is auto-
#                               detected from the .pub header and passed through
#                               to the NSX CLI, so both RSA and ed25519 work.
#   --label <text>              Label used in `set user ... ssh-keys label ...`
#                               (manager only). Default: netops-key
#   --root                      Manager only: ALSO register the key for root
#                               (enables root SSH, registers, verifies, disables
#                               again). Needed by root-using manager automations
#                               like apiuser_audit. Prompts for the root password
#                               per cluster. Edge always registers admin + root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

TYPE=""
HOSTS_FILE=""
SSH_PRIV="${HOME}/.ssh/id_rsa"
KEY_LABEL="netops-key"
REGISTER_ROOT=false
ALL_DCS=false
CONF=""
ONLY_DC=""
SSH_KEY_OVERRIDE=""
PASSTHRU=()          # local flags forwarded to each per-jump run under --all-dcs

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)    TYPE="$2"; PASSTHRU+=(--type "$2"); shift 2 ;;
    --hosts)   HOSTS_FILE="$2"; shift 2 ;;   # per-jump inventory differs; NOT forwarded
    --key)     SSH_PRIV="$2"; PASSTHRU+=(--key "$2"); shift 2 ;;
    --label)   KEY_LABEL="$2"; PASSTHRU+=(--label "$2"); shift 2 ;;
    --root)    REGISTER_ROOT=true; PASSTHRU+=(--root); shift ;;
    --all-dcs) ALL_DCS=true; shift ;;
    --conf)    CONF="$2"; shift 2 ;;
    --only-dc) ONLY_DC="$2"; shift 2 ;;
    --ssh-key) SSH_KEY_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# --all-dcs (orchestrator): configure_ssh_keys.sh reads the LOCAL central
# inventory, so on the orchestrator a plain run only touches the local DC's
# managers (each jump owns its own inventory). This branch fans the SAME
# registration out to every jump in datacenters.conf, running THIS script there
# over `ssh -t` so each DC's admin/root prompts happen on its own jump. Nothing
# is stored on the orchestrator. It exits before the local key-generation path,
# which belongs to the jump, not here. Mirrors `deploy.sh --all-dcs`.
# ---------------------------------------------------------------------------
if "${ALL_DCS}"; then
  [[ -n "${CONF}" ]] || { log_err "--all-dcs requires --conf <datacenters.conf>."; exit 1; }
  [[ -f "${CONF}" ]] || { log_err "conf not found: ${CONF}"; exit 1; }
  need_cmd ssh

  # Flags forwarded to the per-jump run; default to the common case.
  (( ${#PASSTHRU[@]} )) || PASSTHRU=(--type manager --root)

  _quote_args(){ local out="" a; for a in "$@"; do out+=" $(printf '%q' "$a")"; done; printf '%s' "${out# }"; }

  parse_datacenters_conf "${CONF}"

  TARGETS=()
  if [[ -n "${ONLY_DC}" ]]; then
    for (( i=0; i<DC_COUNT; i++ )); do
      [[ "${DC_LABELS[$i]}" == "${ONLY_DC}" ]] && TARGETS+=("${i}")
    done
    (( ${#TARGETS[@]} )) || { log_err "--only-dc='${ONLY_DC}' matched no section in ${CONF}."; exit 1; }
  else
    for (( i=0; i<DC_COUNT; i++ )); do TARGETS+=("${i}"); done
  fi

  log_banner "Fleet SSH-key config — ${#TARGETS[@]} datacenter(s)${ONLY_DC:+ (filtered: ${ONLY_DC})}"
  log "Per-jump command: ./bin/configure_ssh_keys.sh ${PASSTHRU[*]}"
  log "You will be prompted for each DC's admin + root passwords on its own jump; nothing is stored here."

  OK_DCS=(); FAIL_DCS=()
  for idx in "${TARGETS[@]}"; do
    label="${DC_LABELS[$idx]}"
    host="$(dc_jump_host "${idx}")"; user="$(dc_jump_user "${idx}")"
    repo="$(dc_repo_path "${idx}")"; key="${SSH_KEY_OVERRIDE:-$(dc_ssh_key "${idx}")}"
    key="${key/#\~/$HOME}"   # expand a leading ~
    log_banner "[${label}] ${user}@${host}"
    if [[ ! -f "${key}" ]]; then
      log_err "[${label}] SSH key not found: ${key} — skipping."; FAIL_DCS+=("${label}"); continue
    fi
    # Single-quoted so $repo / args expand on the jump, not on the orchestrator.
    printf -v remote_cmd 'cd %q && ./bin/configure_ssh_keys.sh %s' \
      "${repo}" "$(_quote_args "${PASSTHRU[@]}")"
    # -t: give the remote script a tty for its password prompts.
    # BatchMode=yes: reach the jump with the key only (no jump-password fallback);
    # it does not affect the remote program reading from the tty.
    rc=0
    ssh -t -i "${key}" \
        -o BatchMode=yes -o ForwardAgent=no -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30 \
        "${user}@${host}" "bash -lc $(printf '%q' "${remote_cmd}")" || rc=$?
    if (( rc == 0 )); then
      log_ok "[${label}] configure_ssh_keys.sh completed."; OK_DCS+=("${label}")
    else
      log_err "[${label}] configure_ssh_keys.sh FAILED (rc=${rc})."; FAIL_DCS+=("${label}")
    fi
  done

  log_banner "Fleet SSH-key config summary"
  log_ok "Succeeded (${#OK_DCS[@]}): ${OK_DCS[*]:-none}"
  if (( ${#FAIL_DCS[@]} > 0 )); then
    log_err "Failed/skipped (${#FAIL_DCS[@]}): ${FAIL_DCS[*]}"
    exit 1
  fi
  exit 0
fi

[[ -z "${TYPE}" ]] && { log_err "--type is required (edge|manager)."; exit 1; }
if [[ -z "${HOSTS_FILE}" ]]; then
  case "${TYPE}" in
    edge)    HOSTS_FILE="${NSX_INVENTORY_DIR}/edge_nodes.txt" ;;
    manager) HOSTS_FILE="${NSX_INVENTORY_DIR}/managers.conf" ;;
  esac
  log "No --hosts given; using central inventory: ${HOSTS_FILE}"
fi
if [[ ! -f "${HOSTS_FILE}" ]]; then
  log_err "Hosts file not found: ${HOSTS_FILE}"
  log "Create it from the template (note the exact filenames):"
  log "  edges:    cp inventory/edge_nodes.example    inventory/edge_nodes.txt"
  log "  managers: cp inventory/managers.conf.example inventory/managers.conf"
  exit 1
fi

need_cmd ssh
need_cmd sshpass
need_cmd ssh-keygen

# Generate the key if missing (side effect only — we read the values from
# the .pub FILE, never from captured stdout, so a stray log line can never
# end up inside the registered key value).
ensure_local_ssh_key "${SSH_PRIV}" rsa >/dev/null
PUB_FULL="$(cat "${SSH_PRIV}.pub")"
PUB_VAL="$(awk '{print $2}' "${SSH_PRIV}.pub")"
# Detect NSX-CLI key-type token from the OpenSSH header (e.g. "ssh-rsa", "ssh-ed25519")
PUB_TYPE="$(awk '{print $1}' "${SSH_PRIV}.pub")"

# Sanity: a public key value is pure base64 — anything else means the key
# material is corrupt and MUST NOT reach `set user ... value ...`.
if [[ ! "${PUB_VAL}" =~ ^AAAA[A-Za-z0-9+/=]+$ ]]; then
  log_err "Public key value looks corrupt: '${PUB_VAL:0:40}...' — inspect ${SSH_PRIV}.pub"
  exit 1
fi
if [[ ! "${PUB_TYPE}" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)$ ]]; then
  log_err "Unexpected public key type '${PUB_TYPE}' in ${SSH_PRIV}.pub"
  exit 1
fi
log "Local public key: ${PUB_VAL:0:32}... (type=${PUB_TYPE})"

case "${TYPE}" in
  edge)
    # shellcheck source=../lib/nsx_edge.sh
    source "${REPO_ROOT}/lib/nsx_edge.sh"

    export HOST_FILE="${HOSTS_FILE}"
    load_ips
    ask_admin_creds

    _key_works(){ ssh -i "${SSH_PRIV}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
        "$1@$2" "exit" </dev/null &>/dev/null; }

    # Fail fast, BEFORE the root prompt: validate the admin password against
    # ONE edge. Credentials inherited from the shell environment may belong
    # to another device class (e.g. the managers'), and ssh_admin silences
    # ssh's stderr — without this probe a wrong password produces 8x
    # fake-success output (field-confirmed).
    PROBE="${HOST_IPS[0]}"
    if _key_works admin "${PROBE}"; then
      log_ok "Probe ${PROBE}: key auth already works."
    else
      log "Validating admin password against ${PROBE}..."
      if ! admin_cmd "${PROBE}" "get version" </dev/null >/dev/null 2>&1; then
        log_err "Admin password rejected by ${PROBE} (or host unreachable). Nothing was attempted on the other edges."
        log "  Inherited credentials from this shell? Clear them:  unset NSX_PASS NSX_USER ROOT_PASS"
        log "  Inspect the ssh error: NSX_DEBUG=1 $0 --type edge"
        exit 1
      fi
      log_ok "Admin password OK on ${PROBE}."
    fi

    ask_root_creds

    for ip in "${HOST_IPS[@]}"; do
      log_banner "Edge ${ip}"
      # `|| true`: one failing edge must not abort the loop (set -e).
      if _key_works admin "${ip}"; then
        log_ok "${ip}: admin key already works — skipping registration."
      else
        register_edge_admin_key "${ip}" "${PUB_FULL}" "${KEY_LABEL}" || true
      fi
      if _key_works root "${ip}"; then
        log_ok "${ip}: root key already works — skipping registration."
      else
        register_edge_root_key "${ip}" "${PUB_FULL}" "${KEY_LABEL}" || true
      fi
    done

    clear_creds
    log_ok "Edge SSH-key configuration complete."
    ;;

  manager)
    # shellcheck source=../lib/nsx_manager.sh
    source "${REPO_ROOT}/lib/nsx_manager.sh"

    parse_managers_conf "${HOSTS_FILE}"

    _key_works(){ ssh -i "${SSH_PRIV}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
        "$1@$2" "exit" </dev/null &>/dev/null; }

    # Pre-scan: only prompt for credentials of clusters that actually need
    # registration. If the key already opens every host, no password is asked.
    # With --root we always need credentials (root login is gated, so the root
    # key cannot be cheaply pre-checked — registration is idempotent).
    declare -a NEED=() NEED_ADMIN=()
    for (( i=0; i<CLUSTER_COUNT; i++ )); do
      cuser="$(cluster_admin_user "${i}")"
      read -r -a hosts <<<"$(cluster_hosts "${i}")"
      admin_pending=false
      for ip in "${hosts[@]}"; do
        if _key_works "${cuser}" "${ip}"; then
          log_ok "${ip}: admin key already works for ${cuser}."
        else
          admin_pending=true
        fi
      done
      NEED_ADMIN[$i]="${admin_pending}"
      # Prompt/process this cluster if admin registration is pending OR --root.
      if [[ "${admin_pending}" == "true" ]] || "${REGISTER_ROOT}"; then
        NEED[$i]=true
      else
        NEED[$i]=false
      fi
    done

    for (( i=0; i<CLUSTER_COUNT; i++ )); do
      [[ "${NEED[$i]}" == "true" ]] || continue
      # Ask ONLY the passwords that will actually be used: admin only when a host
      # still needs the admin key registered; root only with --root.
      ask_cluster_creds "${i}" "${NEED_ADMIN[$i]}" "${REGISTER_ROOT}"
    done

    for (( i=0; i<CLUSTER_COUNT; i++ )); do
      [[ "${NEED[$i]}" == "true" ]] || continue
      label="${CLUSTER_LABELS[$i]}"
      cuser="$(cluster_admin_user "${i}")"
      log_banner "Cluster [${label}]"
      read -r -a hosts <<<"$(cluster_hosts "${i}")"
      for ip in "${hosts[@]}"; do
        if _key_works "${cuser}" "${ip}"; then
          log_ok "${ip}: admin key already works — skipping admin registration."
        else
          with_cluster_creds "${i}" register_manager_admin_key "${ip}" "${PUB_VAL}" "${KEY_LABEL}" "${PUB_TYPE}" || true
        fi
        if "${REGISTER_ROOT}"; then
          # Root login is gated (off by default), so we cannot cheaply pre-check
          # the root key. register_manager_root_key is idempotent: it enables
          # root SSH, registers (or detects an existing key), verifies a key-only
          # root login, then disables root SSH again — leaving the manager as
          # found (root key present, root login OFF).
          with_cluster_creds "${i}" register_manager_root_key "${ip}" "${PUB_VAL}" "${KEY_LABEL}" "${PUB_TYPE}" || true
        fi
      done
    done

    log_ok "Manager SSH-key configuration complete."
    log "Note: set ADMIN_KEY=${SSH_PRIV} in scripts that use ssh_admin."
    if "${REGISTER_ROOT}"; then
      log "Root key registered; automations that need root (e.g. apiuser_audit) toggle root SSH on/off per run."
    fi
    ;;

  *)
    log_err "Invalid --type: ${TYPE} (use 'edge' or 'manager')"
    exit 1
    ;;
esac
