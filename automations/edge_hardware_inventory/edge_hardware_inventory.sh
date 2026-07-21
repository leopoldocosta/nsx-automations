#!/usr/bin/env bash
# edge_hardware_inventory.sh
# Dell PowerEdge inventory for NSX-T Edge Nodes (bare-metal).
#
# Per node, via root SSH:
#   1. Admin SSH : get uptime + version (with 1 re-prompt on failure)
#   2. Admin     : enable root SSH
#   3. Root      : hostname
#   4. Root      : dmidecode -s system-manufacturer
#                  dmidecode -s system-product-name
#                  dmidecode -s system-serial-number   (Dell Service Tag)
#                  dmidecode -s baseboard-serial-number (fallback only)
#                  lscpu                                 (CPU model / topology)
#                  dmidecode -t processor | grep -E "Version|Core|Thread|Speed"
#   5. Admin     : disable root SSH
#   6. Final report: hardware table + CPU table + CPU-model grouping + CSV,
#                    plus a per-node raw lscpu/dmidecode dump (edge_cpu_raw_*).
#   7. Prompt to clear creds (default Y after 30s)
#
# Verdict per node (hardware — the CPU columns are supplementary data and do
# not change the verdict):
#   OK             : manufacturer matches Dell AND model matches PowerEdge
#                    AND service tag is non-empty.
#   NOT_DELL       : manufacturer is not Dell (e.g. VMware Virtual Platform —
#                    the edge is a VM, not bare-metal).
#   MISSING_TAG    : Dell hardware but service tag could not be read.
#   ERROR          : SSH or dmidecode failed.
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
need_cmd grep

# ---------------------------------------------------------------------------
# Per-node data (associative arrays)
# ---------------------------------------------------------------------------
declare -A NODE_UPTIME NODE_VERSION NODE_VERSION_SHORT
declare -A NODE_HOSTNAME NODE_ERROR
declare -A NODE_HW_MANUFACTURER NODE_HW_MODEL NODE_HW_SERIAL NODE_HW_BASEBOARD
declare -A NODE_CPU_MODEL NODE_CPU_SOCKETS NODE_CPU_CPS NODE_CPU_TPC
declare -A NODE_CPU_TOTAL NODE_CPU_MAXMHZ NODE_CPU_DMISPEED NODE_RAWFILE
declare -A NODE_VERDICT

# ---------------------------------------------------------------------------
# _clean <raw>
#   Trims whitespace, drops empty lines, returns the first non-empty line.
#   dmidecode sometimes emits leading "# ..." comment lines that we strip too.
# ---------------------------------------------------------------------------
_clean(){
  echo "$1" | tr -d '\r' | grep -v '^#' | grep -v '^$' | head -1 | xargs
}

# ---------------------------------------------------------------------------
# _lscpu_get <lscpu_text> <label_ere>
#   Returns one lscpu field value. <label_ere> matches the label up to (not
#   including) the colon, e.g. 'Model name', 'Socket\(s\)', 'CPU\(s\)'.
#   Anchored with ^ and a trailing ':' so 'CPU\(s\)' does not also match
#   'NUMA node0 CPU(s)' / 'On-line CPU(s) list'.
# ---------------------------------------------------------------------------
_lscpu_get(){
  echo "$1" | grep -m1 -E "^$2:" | cut -d: -f2- | tr -d '\r' \
    | sed 's/^[[:space:]]*//' | xargs || true
}

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
  NODE_UPTIME["${ip}"]="$(_clean "${raw_uptime}")"
  NODE_VERSION["${ip}"]="$(_clean "${raw_version}")"

  if [[ -z "${NODE_UPTIME[${ip}]}" && -z "${NODE_VERSION[${ip}]}" ]]; then
    log_warn "${ip}: admin SSH failed."
    reprompt_admin_creds
    raw_uptime="$(admin_cmd "${ip}" 'get uptime'  2>/dev/null || true)"
    raw_version="$(admin_cmd "${ip}" 'get version' 2>/dev/null || true)"
    NODE_UPTIME["${ip}"]="$(_clean "${raw_uptime}")"
    NODE_VERSION["${ip}"]="$(_clean "${raw_version}")"
    if [[ -z "${NODE_UPTIME[${ip}]}" && -z "${NODE_VERSION[${ip}]}" ]]; then
      NODE_ERROR["${ip}"]="Admin SSH failed after credential re-prompt."
      NODE_VERDICT["${ip}"]="ERROR"
      log_warn "${ip}: admin SSH still failing — skipping."
      return 1
    fi
  fi

  NODE_VERSION_SHORT["${ip}"]="$(parse_version_short "${NODE_VERSION[${ip}]}")"
  NODE_VERSION_SHORT["${ip}"]="${NODE_VERSION_SHORT[${ip}]:-N/A}"

  log_ok "${ip}: [uptime]  >> ${NODE_UPTIME[${ip}]}"
  log_ok "${ip}: [version] >> ${NODE_VERSION[${ip}]}"

  enable_root_ssh "${ip}"
  sleep 2

  local raw_hostname
  raw_hostname="$(root_cmd "${ip}" 'hostname' 2>/dev/null || true)"
  NODE_HOSTNAME["${ip}"]="$(_clean "${raw_hostname}")"
  NODE_HOSTNAME["${ip}"]="${NODE_HOSTNAME[${ip}]:-${ip}}"

  # ---- dmidecode + lscpu (single round-trip, parsed locally) ----
  log "${ip}: collecting hardware + CPU identity via 'dmidecode' + 'lscpu'..."
  # Concatenate the queries with line markers so we can split locally in a
  # single SSH round-trip. dmidecode and full lscpu require root; root SSH is on.
  local hw_raw
  hw_raw="$(root_cmd "${ip}" '
    echo "----MANUF----";    dmidecode -s system-manufacturer    2>/dev/null || true
    echo "----MODEL----";    dmidecode -s system-product-name    2>/dev/null || true
    echo "----SERIAL----";   dmidecode -s system-serial-number   2>/dev/null || true
    echo "----BASEBOARD----";dmidecode -s baseboard-serial-number 2>/dev/null || true
    echo "----LSCPU----";    lscpu 2>/dev/null || true
    echo "----DMIPROC----";  dmidecode -t processor 2>/dev/null | grep -E "Version|Core|Thread|Speed" || true
    echo "----END----"
  ' 2>/dev/null || true)"

  if [[ -z "${hw_raw}" ]]; then
    NODE_ERROR["${ip}"]="Root SSH failed on dmidecode."
    NODE_VERDICT["${ip}"]="ERROR"
    log_warn "${ip}: root SSH failed."
    disable_root_ssh "${ip}" || true
    return 1
  fi

  local manuf model serial baseboard lscpu_block dmi_block
  manuf="$(    echo "${hw_raw}" | awk '/^----MANUF----$/,/^----MODEL----$/'      | sed '1d;$d')"
  model="$(    echo "${hw_raw}" | awk '/^----MODEL----$/,/^----SERIAL----$/'     | sed '1d;$d')"
  serial="$(   echo "${hw_raw}" | awk '/^----SERIAL----$/,/^----BASEBOARD----$/' | sed '1d;$d')"
  baseboard="$(echo "${hw_raw}" | awk '/^----BASEBOARD----$/,/^----LSCPU----$/'  | sed '1d;$d')"
  lscpu_block="$(echo "${hw_raw}" | awk '/^----LSCPU----$/,/^----DMIPROC----$/'  | sed '1d;$d')"
  dmi_block="$(  echo "${hw_raw}" | awk '/^----DMIPROC----$/,/^----END----$/'    | sed '1d;$d')"

  NODE_HW_MANUFACTURER["${ip}"]="$(_clean "${manuf}")"
  NODE_HW_MODEL["${ip}"]="$(       _clean "${model}")"
  NODE_HW_SERIAL["${ip}"]="$(      _clean "${serial}")"
  NODE_HW_BASEBOARD["${ip}"]="$(   _clean "${baseboard}")"

  NODE_HW_MANUFACTURER["${ip}"]="${NODE_HW_MANUFACTURER[${ip}]:-N/A}"
  NODE_HW_MODEL["${ip}"]="${NODE_HW_MODEL[${ip}]:-N/A}"
  NODE_HW_SERIAL["${ip}"]="${NODE_HW_SERIAL[${ip}]:-N/A}"
  NODE_HW_BASEBOARD["${ip}"]="${NODE_HW_BASEBOARD[${ip}]:-N/A}"

  # ---- Parse lscpu fields (supplementary CPU data; verdict unaffected) ----
  NODE_CPU_MODEL["${ip}"]="$(  _lscpu_get "${lscpu_block}" 'Model name')"
  NODE_CPU_SOCKETS["${ip}"]="$(_lscpu_get "${lscpu_block}" 'Socket\(s\)')"
  NODE_CPU_CPS["${ip}"]="$(    _lscpu_get "${lscpu_block}" 'Core\(s\) per socket')"
  NODE_CPU_TPC["${ip}"]="$(    _lscpu_get "${lscpu_block}" 'Thread\(s\) per core')"
  NODE_CPU_TOTAL["${ip}"]="$(  _lscpu_get "${lscpu_block}" 'CPU\(s\)')"
  NODE_CPU_MAXMHZ["${ip}"]="$( _lscpu_get "${lscpu_block}" 'CPU max MHz')"
  [[ -z "${NODE_CPU_MAXMHZ[${ip}]}" ]] && \
    NODE_CPU_MAXMHZ["${ip}"]="$(_lscpu_get "${lscpu_block}" 'CPU MHz')"

  # dmidecode "Max Speed" (nameplate rated speed) — first match is enough.
  NODE_CPU_DMISPEED["${ip}"]="$(echo "${dmi_block}" | grep -m1 -E 'Max Speed' \
    | cut -d: -f2- | tr -d '\r' | sed 's/^[[:space:]]*//' | xargs || true)"

  NODE_CPU_MODEL["${ip}"]="${NODE_CPU_MODEL[${ip}]:-N/A}"
  NODE_CPU_SOCKETS["${ip}"]="${NODE_CPU_SOCKETS[${ip}]:-N/A}"
  NODE_CPU_CPS["${ip}"]="${NODE_CPU_CPS[${ip}]:-N/A}"
  NODE_CPU_TPC["${ip}"]="${NODE_CPU_TPC[${ip}]:-N/A}"
  NODE_CPU_TOTAL["${ip}"]="${NODE_CPU_TOTAL[${ip}]:-N/A}"
  NODE_CPU_MAXMHZ["${ip}"]="${NODE_CPU_MAXMHZ[${ip}]:-N/A}"
  NODE_CPU_DMISPEED["${ip}"]="${NODE_CPU_DMISPEED[${ip}]:-N/A}"

  # ---- Per-node raw dump (full lscpu + grepped dmidecode) for reference ----
  local raw_file
  raw_file="${LOG_DIR}/edge_cpu_raw_${NODE_HOSTNAME[${ip}]//[^A-Za-z0-9_.-]/_}.txt"
  {
    printf '# %s (%s) — %s\n' "${NODE_HOSTNAME[${ip}]}" "${ip}" \
      "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '\n===== lscpu =====\n%s\n' "${lscpu_block}"
    printf '\n===== dmidecode -t processor (Version|Core|Thread|Speed) =====\n%s\n' \
      "${dmi_block}"
  } > "${raw_file}"
  NODE_RAWFILE["${ip}"]="${raw_file}"

  # ---- Verdict ----
  local m_lc model_lc s_val
  m_lc="$(echo "${NODE_HW_MANUFACTURER[${ip}]}" | tr '[:upper:]' '[:lower:]')"
  model_lc="$(echo "${NODE_HW_MODEL[${ip}]}"    | tr '[:upper:]' '[:lower:]')"
  s_val="${NODE_HW_SERIAL[${ip}]}"

  if [[ "${m_lc}" != *"dell"* ]]; then
    NODE_VERDICT["${ip}"]="NOT_DELL"
    log_warn "${ip}: manufacturer is not Dell (got: ${NODE_HW_MANUFACTURER[${ip}]})."
  elif [[ "${model_lc}" != *"poweredge"* ]]; then
    NODE_VERDICT["${ip}"]="NOT_DELL"
    log_warn "${ip}: model is not a Dell PowerEdge (got: ${NODE_HW_MODEL[${ip}]})."
  elif [[ -z "${s_val}" || "${s_val}" == "N/A" || \
          "${s_val,,}" == "not specified" || "${s_val,,}" == "to be filled by o.e.m." || \
          "${s_val,,}" == "system serial number" ]]; then
    NODE_VERDICT["${ip}"]="MISSING_TAG"
    log_warn "${ip}: Dell PowerEdge but service tag could not be read."
  else
    NODE_VERDICT["${ip}"]="OK"
    log_ok "${ip}: ${NODE_HW_MODEL[${ip}]} — service tag: ${s_val}"
  fi

  disable_root_ssh "${ip}" || true
  log_ok "${ip}: data collection complete."
}

# ---------------------------------------------------------------------------
# print_report — pretty table + CSV side-output
# ---------------------------------------------------------------------------
print_report(){
  local sep
  sep="$(printf '=%.0s' {1..104})"

  local action_nodes=()

  {
    echo ""
    echo "${sep}"
    printf '  NSX Edge Hardware Inventory (Dell PowerEdge)\n'
    printf '  Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${sep}"
    echo ""

    printf '  %-4s  %-22s  %-17s  %-13s  %-12s  %-22s  %-12s  %s\n' \
      "#" "Hostname" "IP" "NSX Ver" "Manufacturer" "Model" "Service Tag" "Verdict"
    printf '  %-4s  %-22s  %-17s  %-13s  %-12s  %-22s  %-12s  %s\n' \
      "----" "----------------------" "-----------------" "-------------" \
      "------------" "----------------------" "------------" "-----------"

    local idx=1 ip
    for ip in "${HOST_IPS[@]}"; do
      local verdict="${NODE_VERDICT[${ip}]:-ERROR}"
      [[ "${verdict}" != "OK" ]] && action_nodes+=("${ip}")
      printf '  %-4s  %-22s  %-17s  %-13s  %-12s  %-22s  %-12s  %s\n' \
        "${idx}." \
        "${NODE_HOSTNAME[${ip}]:-N/A}" \
        "${ip}" \
        "${NODE_VERSION_SHORT[${ip}]:-N/A}" \
        "${NODE_HW_MANUFACTURER[${ip}]:-N/A}" \
        "${NODE_HW_MODEL[${ip}]:-N/A}" \
        "${NODE_HW_SERIAL[${ip}]:-N/A}" \
        "${verdict}"
      idx=$(( idx + 1 ))
    done

    echo ""
    echo "${sep}"
    printf '  NODES REQUIRING ATTENTION (non-OK)\n'
    echo "${sep}"
    echo ""
    if (( ${#action_nodes[@]} == 0 )); then
      echo "  All nodes are healthy Dell PowerEdge with a readable service tag."
    else
      local aip
      for aip in "${action_nodes[@]}"; do
        printf '  - %-17s  %-22s  verdict=%s  reason=%s\n' \
          "${aip}" \
          "${NODE_HOSTNAME[${aip}]:-N/A}" \
          "${NODE_VERDICT[${aip}]:-ERROR}" \
          "${NODE_ERROR[${aip}]:-see model/serial fields above}"
      done
    fi

    # ---- CPU inventory table (supplementary) ----
    echo ""
    echo "${sep}"
    printf '  CPU INVENTORY (lscpu)\n'
    echo "${sep}"
    echo ""
    printf '  %-4s  %-20s  %-16s  %-42s  %-4s  %-6s  %-6s  %-6s  %s\n' \
      "#" "Hostname" "IP" "CPU Model" "Sock" "Cor/So" "Thr/Co" "vCPU" "Max MHz"
    printf '  %-4s  %-20s  %-16s  %-42s  %-4s  %-6s  %-6s  %-6s  %s\n' \
      "----" "--------------------" "----------------" \
      "------------------------------------------" "----" "------" "------" "------" \
      "-------"
    local cidx=1 cip
    for cip in "${HOST_IPS[@]}"; do
      printf '  %-4s  %-20s  %-16s  %-42s  %-4s  %-6s  %-6s  %-6s  %s\n' \
        "${cidx}." \
        "${NODE_HOSTNAME[${cip}]:-N/A}" \
        "${cip}" \
        "${NODE_CPU_MODEL[${cip}]:-N/A}" \
        "${NODE_CPU_SOCKETS[${cip}]:-N/A}" \
        "${NODE_CPU_CPS[${cip}]:-N/A}" \
        "${NODE_CPU_TPC[${cip}]:-N/A}" \
        "${NODE_CPU_TOTAL[${cip}]:-N/A}" \
        "${NODE_CPU_MAXMHZ[${cip}]:-N/A}"
      cidx=$(( cidx + 1 ))
    done

    # ---- Group by CPU model (spot a heterogeneous fleet) ----
    echo ""
    echo "${sep}"
    printf '  CPU MODELS ACROSS FLEET\n'
    echo "${sep}"
    echo ""
    local uniq_models model count mip
    uniq_models="$(for mip in "${HOST_IPS[@]}"; do
                     printf '%s\n' "${NODE_CPU_MODEL[${mip}]:-N/A}"
                   done | sort -u)"
    while IFS= read -r model; do
      [[ -z "${model}" ]] && continue
      count=0
      for mip in "${HOST_IPS[@]}"; do
        [[ "${NODE_CPU_MODEL[${mip}]:-N/A}" == "${model}" ]] && count=$(( count + 1 ))
      done
      printf '  %3d node(s)  %s\n' "${count}" "${model}"
    done <<< "${uniq_models}"

    echo ""
    echo "${sep}"
    echo "  END OF REPORT"
    echo "${sep}"
    echo ""
  } | tee "${REPORT_FILE}"

  # ---- CSV side-output (machine-readable) ----
  {
    printf 'ip,hostname,nsx_version,manufacturer,model,service_tag,baseboard_serial,cpu_model,sockets,cores_per_socket,threads_per_core,total_vcpu,max_mhz,dmi_max_speed,verdict,error\n'
    local ip
    for ip in "${HOST_IPS[@]}"; do
      # CPU model is quoted (contains commas / parentheses).
      printf '%s,%s,%s,%s,%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${ip}" \
        "${NODE_HOSTNAME[${ip}]:-}" \
        "${NODE_VERSION_SHORT[${ip}]:-}" \
        "${NODE_HW_MANUFACTURER[${ip}]:-}" \
        "${NODE_HW_MODEL[${ip}]:-}" \
        "${NODE_HW_SERIAL[${ip}]:-}" \
        "${NODE_HW_BASEBOARD[${ip}]:-}" \
        "${NODE_CPU_MODEL[${ip}]:-}" \
        "${NODE_CPU_SOCKETS[${ip}]:-}" \
        "${NODE_CPU_CPS[${ip}]:-}" \
        "${NODE_CPU_TPC[${ip}]:-}" \
        "${NODE_CPU_TOTAL[${ip}]:-}" \
        "${NODE_CPU_MAXMHZ[${ip}]:-}" \
        "${NODE_CPU_DMISPEED[${ip}]:-}" \
        "${NODE_VERDICT[${ip}]:-ERROR}" \
        "${NODE_ERROR[${ip}]:-}"
    done
  } > "${CSV_FILE}"

  log "Report saved to: ${REPORT_FILE}"
  log "CSV    saved to: ${CSV_FILE}"
  log "Per-node raw lscpu/dmidecode dumps: ${LOG_DIR}/edge_cpu_raw_*.txt"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main(){
  load_ips

  # Credentials vs. keys.
  # ssh_admin / ssh_root use the registered key when its file exists
  # (ADMIN_KEY / ROOT_KEY) and only fall back to a password otherwise. Mirror
  # that same decision here so the up-front prompts are skipped exactly when
  # the SSH itself won't need a password. This lets the automation run
  # non-interactively under bin/run_across_datacenters.sh (bash -lc over SSH,
  # no controlling terminal — the /dev/tty read in ask_*_creds would abort the
  # run) whenever the jump holds the admin/root keys, while a workstation with
  # neither key still gets the interactive prompt.
  if [[ -f "${ADMIN_KEY}" ]]; then
    log "Admin key present (${ADMIN_KEY}) — password prompt skipped (key auth)."
  else
    ask_admin_creds
  fi
  if [[ -f "${ROOT_KEY}" ]]; then
    log "Root key present (${ROOT_KEY}) — password prompt skipped (key auth)."
  else
    ask_root_creds
  fi

  REPORT_FILE="${LOG_DIR}/edge_hw_report_$(date '+%Y%m%d_%H%M%S').txt"
  CSV_FILE="${LOG_DIR}/edge_hw_report_$(date '+%Y%m%d_%H%M%S').csv"
  LOG_FILE="${LOG_DIR}/edge_hw_run_$(date '+%Y%m%d_%H%M%S').log"
  exec > >(tee -a "${LOG_FILE}") 2>&1

  log_banner "Edge Hardware Inventory"
  log "Loaded ${#HOST_IPS[@]} Edge Node(s): ${HOST_IPS[*]}"

  local failed_nodes=() ip
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
