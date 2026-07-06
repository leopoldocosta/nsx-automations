#!/usr/bin/env bash
# bin/configure_ssh_keys.sh — v1.0
# Registers an SSH key on NSX Edge Nodes or NSX Managers so subsequent
# automations can run without prompting for passwords.
#
# Usage:
#   ./bin/configure_ssh_keys.sh --type edge    [--hosts <edge_nodes.txt>]
#   ./bin/configure_ssh_keys.sh --type manager [--hosts <managers.conf>]
#
# Flags:
#   --type edge|manager         Required. Edge uses ssh-key per user (admin + root);
#                               manager uses `set user ... ssh-keys label ... value ...`.
#   --hosts <file>              For edge: a flat text file of IPs.
#                               For manager: an INI managers.conf (multi-cluster).
#                               Default: inventory/edge_nodes.txt or
#                               inventory/managers.conf (central per-DC inventory).
#   --key <path>                Local SSH private key. Default: ~/.ssh/id_rsa.
#                               Key type (ssh-rsa, ssh-ed25519, ...) is auto-
#                               detected from the .pub header and passed through
#                               to the NSX CLI, so both RSA and ed25519 work.
#   --label <text>              Label used in `set user ... ssh-keys label ...`
#                               (manager only). Default: nsx-automation-key
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

TYPE=""
HOSTS_FILE=""
SSH_PRIV="${HOME}/.ssh/id_rsa"
KEY_LABEL="nsx-automation-key"

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)    TYPE="$2"; shift 2 ;;
    --hosts)   HOSTS_FILE="$2"; shift 2 ;;
    --key)     SSH_PRIV="$2"; shift 2 ;;
    --label)   KEY_LABEL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

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
    declare -a NEED=()
    for (( i=0; i<CLUSTER_COUNT; i++ )); do
      cuser="$(cluster_admin_user "${i}")"
      read -r -a hosts <<<"$(cluster_hosts "${i}")"
      pending=false
      for ip in "${hosts[@]}"; do
        if _key_works "${cuser}" "${ip}"; then
          log_ok "${ip}: key already works for ${cuser} — will skip."
        else
          pending=true
        fi
      done
      NEED[$i]="${pending}"
    done

    for (( i=0; i<CLUSTER_COUNT; i++ )); do
      [[ "${NEED[$i]}" == "true" ]] && ask_cluster_creds "${i}"
    done

    for (( i=0; i<CLUSTER_COUNT; i++ )); do
      [[ "${NEED[$i]}" == "true" ]] || continue
      label="${CLUSTER_LABELS[$i]}"
      cuser="$(cluster_admin_user "${i}")"
      log_banner "Cluster [${label}]"
      read -r -a hosts <<<"$(cluster_hosts "${i}")"
      for ip in "${hosts[@]}"; do
        if _key_works "${cuser}" "${ip}"; then
          log_ok "${ip}: key already works — skipping."
          continue
        fi
        with_cluster_creds "${i}" register_manager_admin_key "${ip}" "${PUB_VAL}" "${KEY_LABEL}" "${PUB_TYPE}" || true
      done
    done

    log_ok "Manager SSH-key configuration complete."
    log "Note: set ADMIN_KEY=${SSH_PRIV} in scripts that use ssh_admin."
    ;;

  *)
    log_err "Invalid --type: ${TYPE} (use 'edge' or 'manager')"
    exit 1
    ;;
esac
