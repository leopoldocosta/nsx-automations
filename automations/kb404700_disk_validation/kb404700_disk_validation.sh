#!/usr/bin/env bash
# kb404700_disk_validation.sh
# KB404700 — NSX Edge Node: Root Partition & Docker overlay2 Disk Validation
#
# Flow per node:
#   1. Admin SSH: get uptime + version (with 1 re-prompt on failure)
#   2. Admin    : enable root SSH
#   3. Root SSH : hostname
#   4. Root     : df -h
#   5. Root     : du -xah --time --max-depth=3 /var/lib/docker/
#   6. Admin    : disable root SSH
#   7. Final report + ACTION REQUIRED table
#   8. Prompt to clear creds (default Y after 30s)
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
need_cmd sshpass
need_cmd awk
need_cmd sort
need_cmd grep

# ---------------------------------------------------------------------------
# Per-node data (associative arrays)
# ---------------------------------------------------------------------------
declare -A NODE_UPTIME NODE_UPTIME_DAYS NODE_VERSION NODE_VERSION_SHORT
declare -A NODE_HOSTNAME NODE_ERROR
declare -A NODE_ROOT_DEVICE NODE_ROOT_PART_LINE
declare -A NODE_ROOT_PART_SIZE NODE_ROOT_PART_USED NODE_ROOT_PART_AVAIL
declare -A NODE_ROOT_PART_PCT NODE_ROOT_PART_STATUS  # OK | FULL | NOT_FOUND
declare -A NODE_OVERLAY2_LINE NODE_OVERLAY2_SIZE NODE_OVERLAY2_STATUS
declare -A NODE_DOCKER_TOTAL_LINE NODE_DOCKER_TOTAL

# ---------------------------------------------------------------------------
# collect_node_info <ip>
# ---------------------------------------------------------------------------
collect_node_info(){
  local ip="$1"
  NODE_ERROR["${ip}"]=""

  log "${ip}: collecting uptime + version via admin..."
  local raw_uptime raw_version
  raw_uptime="$(admin_cmd "${ip}" 'get uptime'  2>/dev/null || true)"
  raw_version="$(admin_cmd "${ip}" 'get version' 2>/dev/null || true)"
  NODE_UPTIME["${ip}"]="$(echo "${raw_uptime}"  | grep -v '^$' | head -1 | xargs)"
  NODE_VERSION["${ip}"]="$(echo "${raw_version}" | grep -v '^$' | head -1 | xargs)"

  if [[ -z "${NODE_UPTIME[${ip}]}" && -z "${NODE_VERSION[${ip}]}" ]]; then
    log_warn "${ip}: admin SSH failed."
    reprompt_admin_creds
    raw_uptime="$(admin_cmd "${ip}" 'get uptime'  2>/dev/null || true)"
    raw_version="$(admin_cmd "${ip}" 'get version' 2>/dev/null || true)"
    NODE_UPTIME["${ip}"]="$(echo "${raw_uptime}"  | grep -v '^$' | head -1 | xargs)"
    NODE_VERSION["${ip}"]="$(echo "${raw_version}" | grep -v '^$' | head -1 | xargs)"
    if [[ -z "${NODE_UPTIME[${ip}]}" && -z "${NODE_VERSION[${ip}]}" ]]; then
      NODE_ERROR["${ip}"]="Admin SSH failed after credential re-prompt."
      log_warn "${ip}: admin SSH still failing — skipping."
      return 1
    fi
  fi

  NODE_UPTIME_DAYS["${ip}"]="$(parse_uptime_days   "${NODE_UPTIME[${ip}]}")"
  NODE_VERSION_SHORT["${ip}"]="$(parse_version_short "${NODE_VERSION[${ip}]}")"
  NODE_UPTIME_DAYS["${ip}"]="${NODE_UPTIME_DAYS[${ip}]:-N/A}"
  NODE_VERSION_SHORT["${ip}"]="${NODE_VERSION_SHORT[${ip}]:-N/A}"

  log_ok "${ip}: [uptime]  >> ${NODE_UPTIME[${ip}]}"
  log_ok "${ip}: [version] >> ${NODE_VERSION[${ip}]}"

  enable_root_ssh "${ip}"
  sleep 2

  local raw_hostname
  raw_hostname="$(root_cmd "${ip}" 'hostname' 2>/dev/null || true)"
  NODE_HOSTNAME["${ip}"]="$(echo "${raw_hostname}" | grep -v '^$' | head -1 | xargs)"
  NODE_HOSTNAME["${ip}"]="${NODE_HOSTNAME[${ip}]:-${ip}}"

  # ---- df -h ----
  log "${ip}: running 'df -h' via root..."
  local df_output root_line
  df_output="$(root_cmd "${ip}" 'df -h' 2>/dev/null || true)"
  if [[ -z "${df_output}" ]]; then
    NODE_ERROR["${ip}"]="Root SSH failed on df -h."
    log_warn "${ip}: root SSH failed."
    disable_root_ssh "${ip}" || true
    return 1
  fi

  root_line="$(echo "${df_output}" | awk '
    NF >= 6 && $NF == "/" { print; next }
    /^\/[^ ]/ && NF < 6   { prev=$0; next }
    NF == 1 && $1 == "/" && prev != "" { print prev " " $1; prev=""; next }
  ' | head -1)"

  NODE_ROOT_PART_LINE["${ip}"]="${root_line}"
  NODE_ROOT_DEVICE["${ip}"]="$(echo "${root_line}" | awk '{print $1}')"

  if [[ -n "${root_line}" ]]; then
    NODE_ROOT_PART_SIZE["${ip}"]="$( echo "${root_line}" | awk '{print $2}')"
    NODE_ROOT_PART_USED["${ip}"]="$( echo "${root_line}" | awk '{print $3}')"
    NODE_ROOT_PART_AVAIL["${ip}"]="$(echo "${root_line}" | awk '{print $4}')"
    NODE_ROOT_PART_PCT["${ip}"]="$(  echo "${root_line}" | awk '{print $5}')"
    local pct_val
    pct_val="$(echo "${NODE_ROOT_PART_PCT[${ip}]}" | tr -d '%')"
    if (( pct_val >= 100 )); then
      NODE_ROOT_PART_STATUS["${ip}"]="FULL"
      log_warn "${ip}: root partition FULL — ${root_line}"
    else
      NODE_ROOT_PART_STATUS["${ip}"]="OK"
      log_ok   "${ip}: [df /] ${root_line}"
    fi
  else
    NODE_ROOT_PART_SIZE["${ip}"]="N/A"; NODE_ROOT_PART_USED["${ip}"]="N/A"
    NODE_ROOT_PART_AVAIL["${ip}"]="N/A"; NODE_ROOT_PART_PCT["${ip}"]="N/A"
    NODE_ROOT_PART_STATUS["${ip}"]="NOT_FOUND"
    NODE_ROOT_PART_LINE["${ip}"]="(not found)"
    NODE_ROOT_DEVICE["${ip}"]="unknown"
    log_warn "${ip}: root partition ('/') not found in df output."
  fi

  # ---- du /var/lib/docker/ ----
  log "${ip}: running 'du -xah --time --max-depth=3 /var/lib/docker/' via root..."
  local du_output docker_total_line overlay2_line
  du_output="$(root_cmd "${ip}" \
    'du -xah --time --max-depth=3 /var/lib/docker/ 2>/dev/null | sort | grep G' \
    2>/dev/null || true)"

  docker_total_line="$( echo "${du_output}" | awk '$NF=="/var/lib/docker"'         | tail -1)"
  overlay2_line="$(     echo "${du_output}" | awk '$NF=="/var/lib/docker/overlay2"' | tail -1)"

  NODE_DOCKER_TOTAL_LINE["${ip}"]="${docker_total_line:-(not found)}"
  NODE_OVERLAY2_LINE["${ip}"]="${overlay2_line:-(not found)}"

  local overlay2_size
  overlay2_size="$(echo "${overlay2_line}" | awk '{print $1}')"
  NODE_OVERLAY2_SIZE["${ip}"]="${overlay2_size:-N/A}"

  if [[ -n "${overlay2_size}" ]]; then
    local overlay_num
    overlay_num="$(echo "${overlay2_size}" | tr -d 'G')"
    if awk "BEGIN{exit !(${overlay_num}+0 >= 10)}"; then
      NODE_OVERLAY2_STATUS["${ip}"]="HIGH"
      log_warn "${ip}: overlay2 HIGH — ${overlay2_line}"
    else
      NODE_OVERLAY2_STATUS["${ip}"]="OK"
      log_ok   "${ip}: [du overlay2] ${overlay2_line}"
    fi
  else
    NODE_OVERLAY2_STATUS["${ip}"]="N/A"
    log_warn "${ip}: could not determine overlay2 size."
  fi

  disable_root_ssh "${ip}" || true
  log_ok "${ip}: data collection complete."
}

# ---------------------------------------------------------------------------
# print_report
# ---------------------------------------------------------------------------
print_report(){
  local sep thin_sep
  sep="$(printf '=%.0s' {1..96})"
  thin_sep="$(printf -- '-%.0s' {1..96})"

  local action_nodes=()

  {
    echo ""
    echo "${sep}"
    printf '  KB404700 — NSX Edge Disk Validation Report\n'
    printf '  Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${sep}"

    for ip in "${HOST_IPS[@]}"; do
      echo ""
      echo "  NODE: ${ip}"
      echo "  ${thin_sep:2}"

      if [[ -n "${NODE_ERROR[${ip}]:-}" ]]; then
        printf '  %-22s %s\n' "Status:" "ERROR"
        printf '  %-22s %s\n' "Reason:" "${NODE_ERROR[${ip}]}"
        continue
      fi

      printf '  %-22s %s\n' "Hostname:" "${NODE_HOSTNAME[${ip}]:-N/A}"
      printf '  %-22s %s\n' "Uptime:"   "${NODE_UPTIME[${ip}]:-N/A}"
      printf '  %-22s %s\n' "Version:"  "${NODE_VERSION[${ip}]:-N/A}"
      echo ""

      local root_status="${NODE_ROOT_PART_STATUS[${ip}]:-N/A}"
      local root_flag=""
      [[ "${root_status}" == "FULL"      ]] && root_flag="  <-- *** ROOT PARTITION FULL ***"
      [[ "${root_status}" == "NOT_FOUND" ]] && root_flag="  <-- root partition not found"

      printf '  %-22s %s\n'    "Root device:" "${NODE_ROOT_DEVICE[${ip}]:-unknown}"
      printf '  %-22s\n'        "df -h output:"
      printf '    Filesystem  Size  Used  Avail  Use%%  Mounted on\n'
      printf '    %s%s\n' "${NODE_ROOT_PART_LINE[${ip}]:-N/A}" "${root_flag}"
      echo ""

      local ov_status="${NODE_OVERLAY2_STATUS[${ip}]:-N/A}"
      local ov_flag=""
      [[ "${ov_status}" == "HIGH" ]] && ov_flag="  <-- *** overlay2 CAUSING ROOT FULL ***"

      printf '  %-22s\n' "du /var/lib/docker/:"
      printf '    %s\n'   "${NODE_DOCKER_TOTAL_LINE[${ip}]:-N/A}"
      printf '    %s%s\n' "${NODE_OVERLAY2_LINE[${ip}]:-N/A}" "${ov_flag}"
      echo ""

      local verdict="OK"
      if [[ "${root_status}" == "FULL" || "${ov_status}" == "HIGH" ]]; then
        verdict="ACTION REQUIRED"
        action_nodes+=("${ip}")
      fi
      printf '  %-22s %s\n' "VERDICT:" "${verdict}"
    done

    echo ""
    echo "${sep}"
    printf '  NODES REQUIRING ACTION\n'
    echo "${sep}"
    echo ""
    if (( ${#action_nodes[@]} == 0 )); then
      echo "  All nodes are OK. No action required."
    else
      printf '  %-4s  %-26s  %-17s  %-10s  %-13s  %-7s  %s\n' \
        "#" "Hostname" "IP" "Uptime(d)" "Version" "Root%" "overlay2"
      printf '  %-4s  %-26s  %-17s  %-10s  %-13s  %-7s  %s\n' \
        "----" "--------------------------" "-----------------" "----------" "-------------" "-------" "--------"
      local idx=1
      for aip in "${action_nodes[@]}"; do
        printf '  %-4s  %-26s  %-17s  %-10s  %-13s  %-7s  %s\n' \
          "${idx}." \
          "${NODE_HOSTNAME[${aip}]:-N/A}" \
          "${aip}" \
          "${NODE_UPTIME_DAYS[${aip}]:-N/A}" \
          "${NODE_VERSION_SHORT[${aip}]:-N/A}" \
          "${NODE_ROOT_PART_PCT[${aip}]:-N/A}" \
          "${NODE_OVERLAY2_SIZE[${aip}]:-N/A}"
        idx=$(( idx + 1 ))
      done
    fi
    echo ""
    echo "${sep}"
    echo "  END OF REPORT"
    echo "${sep}"
    echo ""
  } | tee "${REPORT_FILE}"

  log "Report saved to: ${REPORT_FILE}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main(){
  load_ips
  ask_admin_creds
  ask_root_creds

  REPORT_FILE="${LOG_DIR}/kb404700_report_$(date '+%Y%m%d_%H%M%S').txt"
  LOG_FILE="${LOG_DIR}/kb404700_run_$(date '+%Y%m%d_%H%M%S').log"
  exec > >(tee -a "${LOG_FILE}") 2>&1

  log_banner "KB404700 Disk Validation"
  log "Loaded ${#HOST_IPS[@]} Edge Node(s): ${HOST_IPS[*]}"

  local failed_nodes=()
  for ip in "${HOST_IPS[@]}"; do
    log "--- ${ip} ---"
    collect_node_info "${ip}" || failed_nodes+=("${ip}")
  done

  (( ${#failed_nodes[@]} > 0 )) && log_warn "Nodes with errors: ${failed_nodes[*]}"

  print_report

  log "=== Done ==="
  rotate_logs   # honor NSX_LOG_RETENTION_DAYS (default 30)
  confirm_clear_creds_with_timeout 30
}

main "$@"
