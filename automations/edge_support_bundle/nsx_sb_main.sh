#!/usr/bin/env bash
# nsx_sb_main.sh — Support Bundle orchestrator (Phase 1 request + Phase 2 verify)
# Recommended: run inside screen or tmux (~35 min total).
#
# Flags:
#   --clean-all   delegates to nsx_sb_precheck.sh --clean-all
#   --precheck    runs only the precheck and exits
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

if [[ "${1:-}" == "--clean-all" || "${1:-}" == "--precheck" ]]; then
  exec "${SCRIPT_DIR}/nsx_sb_precheck.sh" "${1}"
fi

need_cmd ssh
load_ips

# Try to resume creds from a previous session
load_session_env || true

[[ -f "${ADMIN_KEY}" ]] || { need_cmd sshpass; ask_admin_creds; }
[[ -f "${ROOT_KEY}" ]]  || ask_root_creds

RUN_LOG="${LOG_DIR}/sb_run_$(date +%Y%m%d_%H%M%S).log"
STATUS_CSV="${LOG_DIR}/sb_status_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,phase,status,details,timestamp' > "$STATUS_CSV"

# Save session for next 30 min so precheck/main can reuse without re-prompting
if [[ -n "${NSX_PASS:-}" ]]; then
  save_session_env
  auto_clear_session_after "$(( $(date +%s) + 1800 ))"
fi

# ---------------------------------------------------------------------------
# Inline PRE-CHECK (avoids opening root SSH twice)
# ---------------------------------------------------------------------------
log_banner "PRE-CHECK -- Support Bundle state"

declare -A PC_STATUS PC_ACAO PC_FILE PC_SKIP

for ip in "${HOST_IPS[@]}"; do
  log "${ip}: PRE-CHECK..."
  enable_root_ssh "$ip"

  last_log="$(root_cmd "$ip" "tail -1 /var/log/support_bundle.log 2>/dev/null || echo FILE_NOT_FOUND")"
  printf '\n  +-- %s: /var/log/support_bundle.log (last line) -----------+\n' "$ip"
  printf '  |  %s\n' "$last_log"
  printf '  +----------------------------------------------------------+\n\n'

  ls_out="$(root_cmd "$ip" "ls -lh /var/vmware/nsx/file-store/ 2>/dev/null" || true)"
  printf '\n  +-- %s: ls -lh /var/vmware/nsx/file-store/ ---------------+\n' "$ip"
  while IFS= read -r line; do printf '  |  %s\n' "$line"; done <<< "$ls_out"
  printf '  +----------------------------------------------------------+\n\n'

  # Shared classifier: populates PCR_* scalars.
  precheck_bundle_for "$ip"
  log "${ip}: ${PCR_TOTAL} bundle(s) found."

  PC_STATUS["$ip"]="${PCR_STATUS}"
  PC_ACAO["$ip"]="${PCR_ACAO}"
  PC_FILE["$ip"]="${PCR_FILE}"
  PC_SKIP["$ip"]="${PCR_SKIP}"

  if [[ "${PCR_ACAO}" == "OK" ]]; then
    log_ok "${ip}: recent bundle present — generation will be skipped."
  elif [[ "${PCR_TOTAL}" -gt 0 ]]; then
    log_warn "${ip}: only old bundles — will generate new."
  else
    log "${ip}: no bundle found."
  fi
done

# Pre-check table
precheck_csv="${LOG_DIR}/precheck_$(date +%Y%m%d_%H%M%S).csv"
echo 'ip,status,action,file' > "$precheck_csv"
tbl_header "PRE-CHECK -- Support Bundle state"
for ip in "${HOST_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]}" "${PC_ACAO[$ip]}" "${PC_FILE[$ip]}" ""
  printf '%s,%s,%s,%s\n' "$ip" "${PC_STATUS[$ip]}" "${PC_ACAO[$ip]}" "${PC_FILE[$ip]}" >> "$precheck_csv"
done
tbl_footer
log_ok "Pre-check done. CSV: ${precheck_csv}"

# ---------------------------------------------------------------------------
# PHASE 1: request support bundle on nodes that need it
# ---------------------------------------------------------------------------
log_banner "PHASE 1 -- Support Bundle request"
for ip in "${HOST_IPS[@]}"; do
  if [[ "${PC_SKIP[$ip]:-false}" == "true" ]]; then
    log "${ip}: skipping — recent bundle exists."
    continue
  fi
  enable_root_ssh "$ip"
  printf '%s,phase1,root_ssh_enabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
  request_support_bundle "$ip"
  printf '%s,phase1,sb_requested,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done
log "Phase 1 done. Waiting for bundles to generate..."

# ---------------------------------------------------------------------------
# PHASE 2: verify every 5 min, up to 30 min (6 rounds)
# ---------------------------------------------------------------------------
log_banner "PHASE 2 -- Verification"
declare -A NODE_DONE
for ip in "${HOST_IPS[@]}"; do NODE_DONE["$ip"]="false"; done

for ((round=1; round<=6; round++)); do
  log "Check ${round}/6 — sleeping 5 min..."
  sleep 300
  for ip in "${HOST_IPS[@]}"; do
    [[ "${NODE_DONE[$ip]}" == "true" ]] && continue
    OUT="$(check_support_bundle "$ip" || true)"
    if grep -qiE 'error|fail|unable|denied' <<< "$OUT"; then
      log_err  "${ip}: error detected — stopping checks for this node."
      printf '%s,phase2,error,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    elif grep -qiE 'complete|generated|success' <<< "$OUT" && ! grep -q 'FILE_NOT_FOUND' <<< "$OUT"; then
      log_ok   "${ip}: bundle confirmed."
      printf '%s,phase2,success,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
      NODE_DONE["$ip"]="true"
    else
      log_warn "${ip}: still pending..."
      printf '%s,phase2,pending,%q,%s\n' "$ip" "$OUT" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
    fi
  done
done

# ---------------------------------------------------------------------------
# FINAL REPORT + disable root SSH
# ---------------------------------------------------------------------------
log_banner "FINAL REPORT -- Support Bundle Check"
tbl_header "FINAL REPORT"
for ip in "${HOST_IPS[@]}"; do
  tbl_row "$ip" "${PC_STATUS[$ip]:-?}" "${PC_ACAO[$ip]:-?}" "${PC_FILE[$ip]:---}" ""
done
tbl_footer

log_banner "FINAL -- Disabling root SSH"
for ip in "${HOST_IPS[@]}"; do
  disable_root_ssh "$ip" || true
  printf '%s,final,root_ssh_disabled,ok,%s\n' "$ip" "$(date +%F_%T)" | tee -a "$RUN_LOG" >> "$STATUS_CSV"
done

clear_creds
rm -f "${RUN_DIR}/session.env" 2>/dev/null || true
rotate_logs   # honor NSX_LOG_RETENTION_DAYS (default 30)
log_ok "Done. Status CSV: ${STATUS_CSV}"
