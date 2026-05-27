#!/usr/bin/env bash
# bin/configure_ssh_keys.sh — v1.0
# Registers an SSH key on NSX Edge Nodes or NSX Managers so subsequent
# automations can run without prompting for passwords.
#
# Usage:
#   ./bin/configure_ssh_keys.sh --type edge    --hosts <edge_nodes.txt>
#   ./bin/configure_ssh_keys.sh --type manager --hosts <managers.conf>
#
# Flags:
#   --type edge|manager         Required. Edge uses ssh-key per user (admin + root);
#                               manager uses `set user ... ssh-keys label ... value ...`.
#   --hosts <file>              For edge: a flat text file of IPs.
#                               For manager: an INI managers.conf (multi-cluster).
#   --key <path>                Local SSH private key. Default: ~/.ssh/id_rsa
#                               (rsa for manager — required by NSX CLI;
#                                ed25519 also works for edge).
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
[[ -z "${HOSTS_FILE}" ]] && { log_err "--hosts is required."; exit 1; }
[[ -f "${HOSTS_FILE}" ]] || { log_err "Hosts file not found: ${HOSTS_FILE}"; exit 1; }

need_cmd ssh
need_cmd sshpass
need_cmd ssh-keygen

# Generate / locate the local key
PUB_VAL="$(ensure_local_ssh_key "${SSH_PRIV}" rsa)"
PUB_FULL="$(cat "${SSH_PRIV}.pub")"
# Detect NSX-CLI key-type token from the OpenSSH header (e.g. "ssh-rsa", "ssh-ed25519")
PUB_TYPE="$(awk '{print $1}' "${SSH_PRIV}.pub")"
log "Local public key: ${PUB_VAL:0:32}... (type=${PUB_TYPE})"

case "${TYPE}" in
  edge)
    # shellcheck source=../lib/nsx_edge.sh
    source "${REPO_ROOT}/lib/nsx_edge.sh"

    export HOST_FILE="${HOSTS_FILE}"
    load_ips
    ask_admin_creds
    ask_root_creds

    for ip in "${HOST_IPS[@]}"; do
      log_banner "Edge ${ip}"
      register_edge_admin_key "${ip}" "${PUB_FULL}"
      register_edge_root_key  "${ip}" "${PUB_FULL}"
    done

    clear_creds
    log_ok "Edge SSH-key configuration complete."
    ;;

  manager)
    # shellcheck source=../lib/nsx_manager.sh
    source "${REPO_ROOT}/lib/nsx_manager.sh"

    parse_managers_conf "${HOSTS_FILE}"

    local_idx=0
    for (( i=0; i<CLUSTER_COUNT; i++ )); do
      ask_cluster_creds "${i}"
    done

    for (( i=0; i<CLUSTER_COUNT; i++ )); do
      label="${CLUSTER_LABELS[$i]}"
      log_banner "Cluster [${label}]"
      read -r -a hosts <<<"$(cluster_hosts "${i}")"
      for ip in "${hosts[@]}"; do
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
