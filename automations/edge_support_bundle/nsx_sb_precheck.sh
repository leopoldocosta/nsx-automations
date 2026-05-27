#!/usr/bin/env bash
# nsx_sb_precheck.sh
# Inspects support bundle state on each Edge Node WITHOUT generating new ones.
# Optional --clean-all removes ALL bundles from the file-store.
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
load_session_env || true

[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds

log_banner "PRE-CHECK -- Support Bundle state"

CLEAN_ALL=false
[[ "${1:-}" == "--clean-all" ]] && { CLEAN_ALL=true; log "=== CLEAN-ALL: removing ALL existing bundles ==="; }

declare -A PC_STATUS PC_ACAO PC_FILE PC_SKIP PC_DURACAO

for ip in "${HOST_IPS[@]}"; do
  log "${ip}: PRE-CHECK..."
  enable_root_ssh "$ip"

  last_log="$(root_cmd "$ip" "tail -1 /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND")"
  printf '\n  +-- %s: ls -lh /var/vmware/nsx/file-store/ ---------------+\n' "$ip"
  ls_out="$(root_cmd "$ip" "ls -lh /var/vmware/nsx/file-store/ 2>/dev/null" || true)"
  while IFS= read -r line; do printf '  |  %s\n' "$line"; done <<< "$ls_out"
  printf '  +----------------------------------------------------------+\n\n'

  if echo "$last_log" | grep -qiE 'error|fail|unable|denied'; then
    log_warn "${ip}: log's last line looks like an error."
  else
    log_ok   "${ip}: log's last line OK."
  fi

  if $CLEAN_ALL; then
    log "${ip}: collecting ALL bundles for full cleanup..."
    mapfile -t all_bundles < <(list_remote_bundles "$ip")
    log "${ip}: ${#all_bundles[@]} bundle(s) to delete."
    for f in "${all_bundles[@]}"; do
      log ">> ${ip}: rm -f /var/vmware/nsx/file-store/${f}"
      root_cmd "$ip" "rm -f /var/vmware/nsx/file-store/${f}" || true
      log_warn "${ip}: deleted -- ${f}"
    done
    disable_root_ssh "$ip"
    PC_STATUS["$ip"]="CLEANED"; PC_ACAO["$ip"]="CLEANED"
    PC_FILE["$ip"]="--"; PC_SKIP["$ip"]="false"; PC_DURACAO["$ip"]="--"
    continue
  fi

  # Shared classifier: populates PCR_* scalars (see lib/nsx_edge.sh).
  # Copy them into the per-host associative arrays.
  precheck_bundle_for "$ip"
  PC_STATUS["$ip"]="${PCR_STATUS}"
  PC_ACAO["$ip"]="${PCR_ACAO}"
  PC_FILE["$ip"]="${PCR_FILE}"
  PC_SKIP["$ip"]="${PCR_SKIP}"
  PC_DURACAO["$ip"]="${PCR_DURACAO}"

  case "${PCR_ACAO}" in
    OK)       log_ok   "${ip}: recent bundle present." ;;
    GENERATE) if [[ "${PCR_TOTAL}" -gt 0 ]]; then
                log_warn "${ip}: only old bundle(s)."
              else
                log "${ip}: no bundle found."
              fi ;;
  esac

  disable_root_ssh "$ip"
done

# Output table + CSV
precheck_csv="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,status,action,file,duration' > "$precheck_csv"
tbl_header "PRE-CHECK -- Support Bundle state"
for ip in "${HOST_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}" "${PC_DURACAO[$ip]:---}"
  printf '%s,%s,%s,%s,%s\n' "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}" "${PC_DURACAO[$ip]:---}" >> "$precheck_csv"
done
tbl_footer
log_ok "Pre-check done. CSV: ${precheck_csv}"
log "To generate missing bundles: ./nsx_sb_main.sh"
log "To clean ALL bundles:        ./nsx_sb_precheck.sh --clean-all"
