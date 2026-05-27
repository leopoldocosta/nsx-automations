#!/usr/bin/env bash
# nsx_ssh_cli.sh
# Interactive SSH CLI to NSX Edge Nodes.
#
# Modes:
#   1. Single command  — run one command and exit
#   2. Session         — loop, multiple commands until "exit"
#
# Users: admin (NSX-T CLI) and root (Linux shell).
# Command history saved in logs/cli_history_<date>.log
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
export HOST_FILE="${SCRIPT_DIR}/edge_nodes.txt"
export HOST_EXAMPLE="${SCRIPT_DIR}/edge_nodes.example"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=../../lib/nsx_edge.sh
source "${REPO_ROOT}/lib/nsx_edge.sh"

need_cmd ssh
load_ips

clear
echo "================================================================"
echo " NSX Edge — Interactive SSH CLI"
echo "================================================================"
echo " Available nodes:"
for i in "${!HOST_IPS[@]}"; do printf '   [%2d] %s\n' "$((i+1))" "${HOST_IPS[$i]}"; done
echo "   [A ] All (broadcast)"
echo "================================================================"
echo ""

read -rp "Select node (number or A): " SEL
echo ""

if [[ "${SEL^^}" == "A" ]]; then
  TARGET_IPS=("${HOST_IPS[@]}"); TARGET_LABEL="ALL"
elif [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#HOST_IPS[@]} )); then
  TARGET_IPS=("${HOST_IPS[$((SEL-1))]}"); TARGET_LABEL="${TARGET_IPS[0]}"
else
  echo "[ERROR] Invalid selection."; exit 1
fi

echo "SSH user:"
echo "  [1] admin  (NSX-T CLI)"
echo "  [2] root   (Linux shell)"
echo ""
read -rp "Select (1 or 2): " USR_SEL

USE_ROOT=false
case "${USR_SEL}" in
  1) USER_LABEL="admin"; [[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; } ;;
  2) USER_LABEL="root"; USE_ROOT=true
     [[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
     [[ -f "${ROOT_KEY}" ]]  || ask_root_creds ;;
  *) echo "[ERROR] Invalid option."; exit 1 ;;
esac

echo ""
echo "Mode:"
echo "  [1] Single command  (run and exit)"
echo "  [2] Session         (multiple commands, type 'exit' to leave)"
echo ""
read -rp "Select (1 or 2): " MODE_SEL

HISTORY_FILE="${LOG_DIR}/cli_history_$(date +%Y%m%d).log"

log_cmd(){
  printf '\n[%s] user=%s ip=%s\nCMD: %s\nOUT:\n%s\n%s\n' \
    "$(date '+%F %T')" "$2" "$1" "$3" "$4" \
    '----------------------------------------------------------------' \
    >> "${HISTORY_FILE}"
}

exec_on_targets(){
  local cmd="$1" out
  for ip in "${TARGET_IPS[@]}"; do
    echo ""; echo "  ===== ${USER_LABEL}@${ip} ====="
    if [[ "${USE_ROOT}" == "true" ]]; then
      enable_root_ssh "$ip" >/dev/null 2>&1 || true
      sleep 1
      out="$(root_cmd "$ip" "$cmd" 2>&1 || true)"
      disable_root_ssh "$ip" >/dev/null 2>&1 || true
    else
      out="$(admin_cmd "$ip" "$cmd" 2>&1 || true)"
    fi
    echo "${out}"
    log_cmd "$ip" "${USER_LABEL}" "$cmd" "$out"
  done
  echo ""
}

if [[ "${MODE_SEL}" == "1" ]]; then
  echo ""; echo "--- Single command | ${USER_LABEL} | ${TARGET_LABEL} ---"; echo ""
  read -rp "Command: " CMD
  [[ -z "$CMD" ]] && { echo "No command given."; clear_creds; exit 0; }
  exec_on_targets "$CMD"
  echo "  History: ${HISTORY_FILE}"
  clear_creds; exit 0
fi

echo ""
echo "================================================================"
echo " INTERACTIVE SESSION"
echo " User    : ${USER_LABEL}"
echo " Target  : ${TARGET_LABEL}"
echo " History : ${HISTORY_FILE}"
echo " Builtins: exit | nodes | history"
echo "================================================================"
echo ""

while true; do
  printf "[nsx-cli][%s@%s]\$ " "${USER_LABEL}" "${TARGET_LABEL}"
  IFS= read -r CMD || break
  case "${CMD,,}" in
    exit|quit)    echo "Closing session."; break ;;
    nodes|nos)    echo "  Nodes: ${TARGET_IPS[*]}"; continue ;;
    history|historico) tail -n 60 "${HISTORY_FILE}" 2>/dev/null || echo "  empty."; continue ;;
    "")           continue ;;
  esac
  exec_on_targets "${CMD}"
done

clear_creds
echo ""
echo "Session closed. History: ${HISTORY_FILE}"
