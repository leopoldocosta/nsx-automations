#!/usr/bin/env bash
# lb_troubleshoot.sh
# NSX-T Native Load Balancer — Virtual Server / Pool DOWN troubleshooter.
#
# Encapsulates the real workflow used to diagnose an LB whose pool members
# were marked DOWN because an HTTP monitor was probing an HTTPS/SSL backend.
#
# The whole point of this tool is to handle the THREE NSX id namespaces
# correctly so you never again hit "Invalid value for argument <lb-uuid>"
# or a NOT_FOUND from querying a dataplane id on the Policy API:
#
#   Policy id        -> /policy/api/v1/infra/...   (UI + Policy REST)
#   Realization id   -> Edge CLI: get load-balancer <id> ... AND /api/v1/...
#   Object path      -> /infra/lb-virtual-servers/... tells you the TYPE
#
# Resolution rules this script automates:
#   * Policy LB-service  --(.realization_id)-->  Edge CLI id
#   * Edge pool id (dataplane) is NOT queryable on Policy. Re-discover the
#     Policy pool by matching member ip+port (find_pool_by_member).
#
# Flow:
#   1. Resolve the LB service (from --lb-service | --vs | --vip+--port)
#   2. Print realization_id + connectivity_path (Tier-1)
#   3. (optional) --edge : runtime status + health-check-table, classified
#   4. (optional) --member ip:port : resolve Policy pool + monitor, root-cause
#   5. (optional) --fix-monitor <path> : guarded PATCH to swap the monitor
#   6. Report to logs/ + decoder legend
#
# Read-only by default. The only mutating action is --fix-monitor, which is
# explicit and asks for confirmation (or --yes when non-interactive).
#
# Fan-out safe: designed to also run from the orchestrator via
#   ./bin/run_across_datacenters.sh --only-dc <DC> \
#       --automation lb_troubleshoot/lb_troubleshoot.sh -- <args>
# In that mode there is NO TTY on the jump, so:
#   * --manager may be omitted — falls back to the first manager of the
#     central inventory (inventory/managers.conf) of THAT jump's DC;
#   * API credentials must already exist on the jump (env NSX_USER/NSX_PASS
#     or a saved session in run/session.env) — the script never prompts;
#   * --fix-monitor requires --yes (no interactive confirmation possible);
#   * --edge uses the registered ADMIN_KEY (default ~/.ssh/id_rsa) — no
#     password prompt.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
# Jump-registered admin key (bin/configure_ssh_keys.sh) — used by --edge SSH.
export ADMIN_KEY="${ADMIN_KEY:-${HOME}/.ssh/id_rsa}"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=../../lib/nsx_api.sh
source "${REPO_ROOT}/lib/nsx_api.sh"
# nsx_edge.sh only needed for the optional --edge runtime checks
# shellcheck source=../../lib/nsx_edge.sh
source "${REPO_ROOT}/lib/nsx_edge.sh"
# nsx_manager.sh provides parse_managers_conf for the --manager fallback
# shellcheck source=../../lib/nsx_manager.sh
source "${REPO_ROOT}/lib/nsx_manager.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
NSX_MGR=""
LB_SERVICE_ID=""
VS_ID=""
VIP=""
VIP_PORT=""
MEMBER_IP=""
MEMBER_PORT=""
EDGE_IP=""
FIX_MONITOR_PATH=""
ASSUME_YES=0

usage(){
  cat <<'EOF'
Usage:
  bash lb_troubleshoot.sh [--manager <ip|fqdn>] [target] [diagnostic] [options]

Manager:
  --manager <ip|fqdn>          NSX Manager (no scheme). Optional when the
                               central inventory (inventory/managers.conf)
                               exists — the first manager of the first
                               cluster is used (fan-out mode).

Target — pick ONE to locate the LB service:
  --lb-service <policy-id>     LB service Policy id (e.g. b74d0f77-...).
  --vs <policy-id>             Virtual server Policy id; climbs to its LB service.
  --vip <ip> --port <port>     VIP ip + service port; finds the VS, then the LB.

Diagnostics (optional, combine freely):
  --edge <ip>                  Edge node (admin SSH) for runtime health-check.
  --member <ip> --member-port <port>
                               Backend member to root-cause (resolves the Policy
                               pool by ip+port and inspects its monitor).

Remediation (optional, mutating — asks for confirmation):
  --fix-monitor <policy-path>  PATCH the resolved pool's active_monitor_paths to
                               this monitor (e.g.
                               /infra/lb-monitor-profiles/default-tcp-lb-monitor).
                               Requires --member to have resolved a pool.
  --yes                        Approve --fix-monitor without prompting. REQUIRED
                               when there is no TTY (orchestrator fan-out).

Misc:
  -h | --help                  This help.

Examples:
  # Full picture from the LB service id, with edge runtime + member root-cause
  bash lb_troubleshoot.sh --manager 192.168.20.10 \
    --lb-service b74d0f77-fe30-4a5e-809e-d711811b2c8a \
    --edge 192.168.30.11 --member 10.10.1.11 --member-port 4010

  # Apply the fix (HTTP-vs-HTTPS mismatch -> TCP monitor)
  bash lb_troubleshoot.sh --manager 192.168.20.10 \
    --lb-service b74d0f77-fe30-4a5e-809e-d711811b2c8a \
    --member 10.10.1.11 --member-port 4010 \
    --fix-monitor /infra/lb-monitor-profiles/default-tcp-lb-monitor

  # Same diagnosis, but launched FROM the orchestrator against DC-B:
  ./bin/run_across_datacenters.sh --conf ./datacenters.conf --only-dc DC-B \
    --automation lb_troubleshoot/lb_troubleshoot.sh -- \
    --vip 10.10.0.34 --port 4010 --member 10.10.1.11 --member-port 4010
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manager)      NSX_MGR="$2"; shift 2 ;;
    --lb-service)   LB_SERVICE_ID="$2"; shift 2 ;;
    --vs)           VS_ID="$2"; shift 2 ;;
    --vip)          VIP="$2"; shift 2 ;;
    --port)         VIP_PORT="$2"; shift 2 ;;
    --member)       MEMBER_IP="$2"; shift 2 ;;
    --member-port)  MEMBER_PORT="$2"; shift 2 ;;
    --edge)         EDGE_IP="$2"; shift 2 ;;
    --fix-monitor)  FIX_MONITOR_PATH="$2"; shift 2 ;;
    --yes)          ASSUME_YES=1; shift ;;
    -h|--help)      usage ;;
    *) log_err "Unknown flag: $1"; usage ;;
  esac
done

need_cmd curl
need_cmd jq
need_cmd base64
if [[ -n "${EDGE_IP}" ]]; then
  need_cmd ssh
  # sshpass is only the fallback when no admin key is registered on the edge
  [[ -f "${ADMIN_KEY}" ]] || need_cmd sshpass
fi

if [[ -z "${LB_SERVICE_ID}" && -z "${VS_ID}" && ( -z "${VIP}" || -z "${VIP_PORT}" ) ]]; then
  log_err "Provide a target: --lb-service, --vs, or --vip + --port."
  usage
fi
if [[ -n "${FIX_MONITOR_PATH}" && ( -z "${MEMBER_IP}" || -z "${MEMBER_PORT}" ) ]]; then
  log_err "--fix-monitor requires --member + --member-port (to resolve the pool)."
  exit 1
fi

# ---------------------------------------------------------------------------
# TTY awareness — under the orchestrator fan-out (ssh BatchMode) there is no
# TTY: never prompt, never read /dev/tty.
# ---------------------------------------------------------------------------
has_tty(){ [[ -t 0 && -e /dev/tty ]]; }

# ---------------------------------------------------------------------------
# Manager resolution — explicit --manager wins; otherwise fall back to the
# central inventory of THIS DC (each jump owns only its own managers.conf,
# so the same fan-out command works in every datacenter).
# ---------------------------------------------------------------------------
resolve_manager(){
  if [[ -n "${NSX_MGR}" ]]; then
    export NSX_MGR
    return 0
  fi
  local conf; conf="$(resolve_inventory_file "${SCRIPT_DIR}/managers.conf")"
  if [[ -f "${conf}" ]] && parse_managers_conf "${conf}"; then
    local -a _mgrs=()
    read -r -a _mgrs <<<"$(cluster_hosts 0)"
    NSX_MGR="${_mgrs[0]:-}"
    if [[ -n "${NSX_MGR}" ]]; then
      export NSX_USER="${NSX_USER:-$(cluster_admin_user 0)}"
      log "No --manager given — using ${NSX_MGR} from ${conf} [${CLUSTER_LABELS[0]}]."
    fi
  fi
  if [[ -z "${NSX_MGR}" ]]; then
    log_err "--manager is required (no usable inventory/managers.conf found)."
    exit 1
  fi
  export NSX_MGR
}

# ---------------------------------------------------------------------------
# API credentials — env first (fan-out / inherited shell), then a saved
# session (run/session.env), then a TTY prompt. Never prompts without a TTY.
# ---------------------------------------------------------------------------
ensure_api_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "API credentials inherited from the environment (user '${NSX_USER:-admin}')."
    return 0
  fi
  if load_session_env && [[ -n "${NSX_PASS:-}" ]]; then
    return 0
  fi
  if has_tty; then
    ask_admin_creds
    return 0
  fi
  log_err "No NSX API credentials and no TTY to prompt (fan-out mode)."
  log_err "On this jump, save a session first (mode 600, auto-clearable):"
  log_err "  cd automations/lb_troubleshoot && source ../../lib/common.sh \\"
  log_err "    && ask_admin_creds && save_session_env"
  log_err "or export NSX_USER/NSX_PASS in the environment before the run."
  exit 1
}

# ---------------------------------------------------------------------------
# Result holders (for the final report)
# ---------------------------------------------------------------------------
LBS_DISPLAY="" ; LBS_REALIZATION="" ; LBS_T1="" ; LBS_ENABLED="" ; LBS_SIZE=""
EDGE_ACTIVE_NOTE=""
POOL_ID="" ; POOL_NAME="" ; POOL_MON_PATHS=""
MON_TYPE="" ; MON_PORT="" ; MON_METHOD="" ; MON_URL="" ; MON_CODES=""
ROOT_CAUSE="" ; SUGGESTION=""
declare -a HC_ROWS=()         # "name|status|class|reason"

# ---------------------------------------------------------------------------
# Step 1 — resolve the LB service id
# ---------------------------------------------------------------------------
resolve_lb_service(){
  if [[ -n "${LB_SERVICE_ID}" ]]; then
    log "Using LB service Policy id: ${LB_SERVICE_ID}"
  elif [[ -n "${VS_ID}" ]]; then
    log "Resolving LB service from virtual server ${VS_ID}..."
    local sp; sp="$(vs_lb_service_path "${VS_ID}")"
    [[ -z "${sp}" ]] && { log_err "VS ${VS_ID}: no lb_service_path (wrong id or stale?)."; exit 1; }
    LB_SERVICE_ID="${sp##*/}"
    log_ok "VS -> LB service: ${LB_SERVICE_ID}"
  else
    log "Resolving virtual server by VIP ${VIP}:${VIP_PORT}..."
    local row; row="$(find_vs_by_vip "${VIP}" "${VIP_PORT}" | head -1)"
    [[ -z "${row}" ]] && { log_err "No virtual server found with VIP ${VIP}:${VIP_PORT}."; exit 1; }
    local sp; sp="$(cut -f3 <<<"${row}")"
    [[ -z "${sp}" || "${sp}" == "-" ]] && { log_err "Matched VS has no lb_service_path."; exit 1; }
    LB_SERVICE_ID="${sp##*/}"
    log_ok "VIP -> VS '$(cut -f2 <<<"${row}")' -> LB service: ${LB_SERVICE_ID}"
  fi

  local json; json="$(lb_service_json "${LB_SERVICE_ID}")"
  if echo "${json}" | jq -e '.error_code? // empty' >/dev/null 2>&1; then
    log_err "LB service ${LB_SERVICE_ID} not found on Policy API:"
    echo "${json}" | jq -r '.error_message // .' 2>/dev/null || echo "${json}"
    exit 1
  fi
  LBS_DISPLAY="$(jq -r '.display_name // "-"' <<<"${json}")"
  LBS_REALIZATION="$(jq -r '.realization_id // "-"' <<<"${json}")"
  LBS_T1="$(jq -r '.connectivity_path // "-"' <<<"${json}")"
  LBS_ENABLED="$(jq -r '.enabled // "-"' <<<"${json}")"
  LBS_SIZE="$(jq -r '.size // "-"' <<<"${json}")"

  log_ok "LB service '${LBS_DISPLAY}' (enabled=${LBS_ENABLED}, size=${LBS_SIZE})"
  log "  realization_id (use this on the Edge CLI): ${LBS_REALIZATION}"
  log "  connectivity_path (Tier-1)              : ${LBS_T1}"
}

# ---------------------------------------------------------------------------
# Step 2 — Edge runtime: status + classified health-check-table
# ---------------------------------------------------------------------------
classify_health_check(){
  # Reads health-check-table text on stdin, emits "name|status|class|reason".
  awk '
    /(^| )(up|down)( |$)/ {
      name=""; status="";
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$/) name=$i;
        else if (($i=="up" || $i=="down") && name!="" && status=="") status=$i;
      }
      if (name=="" || status=="") next;
      cls="DOWN_OTHER"; reason="member down (reason not parsed)";
      if (status=="up") { cls="OK"; reason="healthy"; }
      else if ($0 ~ /Connection refused/) {
        cls="BACKEND_DOWN"; reason="Connection refused — port closed / app not listening"; }
      else if ($0 ~ /Receive Message Failure|Resource temporarily unavailable/) {
        cls="MONITOR_MISMATCH"; reason="Port open, no valid L7 reply — monitor vs app protocol mismatch"; }
      else if ($0 ~ /[Tt]imeout|timed out/) {
        cls="TIMEOUT_FILTER"; reason="Timeout — reachability/firewall/monitor timeout too low"; }
      printf "%s|%s|%s|%s\n", name, status, cls, reason;
    }'
}

edge_runtime(){
  [[ -z "${EDGE_IP}" ]] && return 0
  [[ "${LBS_REALIZATION}" == "-" || -z "${LBS_REALIZATION}" ]] && {
    log_warn "No realization_id — skipping Edge runtime checks."; return 0; }

  log "Edge ${EDGE_IP}: get load-balancer ${LBS_REALIZATION} status"
  local st; st="$(ssh_admin "${EDGE_IP}" "get load-balancer ${LBS_REALIZATION} status" 2>/dev/null || true)"
  if [[ -z "${st}" ]]; then
    log_warn "Edge ${EDGE_IP}: no output (SSH failed, or this Edge is not ACTIVE for the LB)."
    EDGE_ACTIVE_NOTE="no status output from ${EDGE_IP} (check active Edge / SSH)"
  else
    echo "${st}" | sed 's/^/    /'
    local ha; ha="$(echo "${st}" | grep -iE 'LR-HA-State' | awk -F: '{print $2}' | xargs || true)"
    EDGE_ACTIVE_NOTE="LR-HA-State=${ha:-unknown} on ${EDGE_IP}"
    if echo "${ha}" | grep -qiv active; then
      log_warn "${EDGE_IP}: LR-HA-State is '${ha}', not active — run on the ACTIVE edge for live counters."
    fi
  fi

  log "Edge ${EDGE_IP}: get load-balancer ${LBS_REALIZATION} health-check-table"
  local hc; hc="$(ssh_admin "${EDGE_IP}" "get load-balancer ${LBS_REALIZATION} health-check-table" 2>/dev/null || true)"
  if [[ -z "${hc}" ]]; then
    log_warn "Edge ${EDGE_IP}: empty health-check-table."
    return 0
  fi
  mapfile -t HC_ROWS < <(printf '%s\n' "${hc}" | classify_health_check)
  log_ok "Parsed ${#HC_ROWS[@]} health-check member row(s)."
}

# ---------------------------------------------------------------------------
# Step 3 — member root-cause: resolve Policy pool + inspect monitor
# ---------------------------------------------------------------------------
member_root_cause(){
  [[ -z "${MEMBER_IP}" || -z "${MEMBER_PORT}" ]] && return 0

  log "Resolving Policy pool for member ${MEMBER_IP}:${MEMBER_PORT} (matching member ip+port)..."
  local rows; rows="$(find_pool_by_member "${MEMBER_IP}" "${MEMBER_PORT}")"
  local n; n="$(printf '%s' "${rows}" | grep -c . || true)"
  if [[ -z "${rows}" || "${n}" -eq 0 ]]; then
    log_err "No Policy pool found with member ${MEMBER_IP}:${MEMBER_PORT}."
    log_warn "Tip: the Edge pool id is a dataplane id and is NOT queryable on Policy — that's expected."
    return 0
  fi
  if [[ "${n}" -gt 1 ]]; then
    log_warn "${n} pools matched ${MEMBER_IP}:${MEMBER_PORT}; using the first. Candidates:"
    printf '%s\n' "${rows}" | sed 's/^/    /'
  fi
  local row; row="$(printf '%s\n' "${rows}" | head -1)"
  POOL_ID="$(cut -f1 <<<"${row}")"
  POOL_NAME="$(cut -f2 <<<"${row}")"
  POOL_MON_PATHS="$(cut -f3 <<<"${row}")"
  log_ok "Pool '${POOL_NAME}' (Policy id ${POOL_ID})"
  log "  active_monitor_paths: ${POOL_MON_PATHS:-<none>}"

  local first_mon="${POOL_MON_PATHS%%,*}"
  if [[ -z "${first_mon}" ]]; then
    log_warn "Pool has no active monitor."
    ROOT_CAUSE="Pool has no active monitor."
    return 0
  fi

  log "Inspecting monitor ${first_mon}..."
  local msum; msum="$(monitor_profile_summary "${first_mon}")"
  MON_TYPE="$(cut -f1 <<<"${msum}")"
  MON_PORT="$(cut -f2 <<<"${msum}")"
  MON_METHOD="$(cut -f3 <<<"${msum}")"
  MON_URL="$(cut -f4 <<<"${msum}")"
  MON_CODES="$(cut -f5 <<<"${msum}")"
  log_ok "Monitor type=${MON_TYPE} port=${MON_PORT} method=${MON_METHOD} url=${MON_URL} codes=${MON_CODES}"

  # Correlate with the health-check reason for this member, if we have it
  local member_class=""
  local r
  for r in "${HC_ROWS[@]:-}"; do
    [[ -z "${r}" ]] && continue
    if [[ "$(cut -d'|' -f1 <<<"${r}")" == "${MEMBER_IP}:${MEMBER_PORT}" ]]; then
      member_class="$(cut -d'|' -f3 <<<"${r}")"
    fi
  done

  # Verdict
  if [[ "${member_class}" == "MONITOR_MISMATCH" || "${MON_TYPE}" == LBHttpMonitorProfile ]]; then
    if [[ "${MON_TYPE}" == LBHttpMonitorProfile ]]; then
      ROOT_CAUSE="Monitor is ${MON_TYPE} (plain HTTP ${MON_METHOD} ${MON_URL}). If the backend on :${MEMBER_PORT} speaks HTTPS/SSL, the L7 probe never gets a valid reply -> 'Receive Message Failure'."
      SUGGESTION="Switch the monitor to TCP (validates connectivity only) or to an LBHttpsMonitorProfile with SERVER_AUTH_IGNORE."
    else
      ROOT_CAUSE="Health-check shows MONITOR_MISMATCH (port open, no valid L7 reply) for ${MEMBER_IP}:${MEMBER_PORT}."
      SUGGESTION="Align the monitor protocol with the application (TCP, or HTTPS if the app uses SSL)."
    fi
  elif [[ "${member_class}" == "BACKEND_DOWN" ]]; then
    ROOT_CAUSE="Health-check shows Connection refused for ${MEMBER_IP}:${MEMBER_PORT} — the application is not listening on that port (monitor is fine)."
    SUGGESTION="Fix the backend service (start it / correct the port). No NSX change needed."
  elif [[ "${member_class}" == "TIMEOUT_FILTER" ]]; then
    ROOT_CAUSE="Health-check shows a timeout for ${MEMBER_IP}:${MEMBER_PORT} — reachability or filtering between the active Edge and the member."
    SUGGESTION="Check DFW/guest firewall and the Tier-1 SR route to the member; verify monitor timeout/interval."
  else
    ROOT_CAUSE="Monitor inspected (${MON_TYPE}). No edge health-check reason correlated — re-run with --edge for the live reason."
    SUGGESTION="Run with --edge <active-edge> to capture FAIL_REASON, then re-evaluate."
  fi
}

# ---------------------------------------------------------------------------
# Step 4 — optional remediation (guarded)
# ---------------------------------------------------------------------------
apply_fix(){
  [[ -z "${FIX_MONITOR_PATH}" ]] && return 0
  [[ -z "${POOL_ID}" ]] && { log_err "No pool resolved — cannot apply --fix-monitor."; return 1; }

  echo ""
  log_warn "About to PATCH pool '${POOL_NAME}' (${POOL_ID})"
  log_warn "  active_monitor_paths -> [ \"${FIX_MONITOR_PATH}\" ]"
  if (( ASSUME_YES )); then
    log_warn "--yes supplied — applying without interactive confirmation."
  elif has_tty; then
    local answer
    IFS= read -rp "Type 'yes' to apply this change: " answer </dev/tty
    if [[ "${answer}" != "yes" ]]; then
      log "Aborted — no change made."
      return 0
    fi
  else
    log_err "--fix-monitor needs a TTY to confirm — under the fan-out, re-run with --yes to approve."
    return 1
  fi

  local body; body="$(jq -nc --arg m "${FIX_MONITOR_PATH}" '{active_monitor_paths: [$m]}')"
  local resp; resp="$(nsx_api_patch "/policy/api/v1/infra/lb-pools/${POOL_ID}" "${body}")"
  if echo "${resp}" | jq -e '.error_code? // empty' >/dev/null 2>&1; then
    log_err "PATCH failed:"; echo "${resp}" | jq -r '.error_message // .'
    return 1
  fi
  log_ok "Monitor swapped. New active_monitor_paths:"
  echo "${resp}" | jq -r '.active_monitor_paths[]?' | sed 's/^/    /'
  echo ""
  log "Validate on the active Edge in ~30s:"
  echo "    get load-balancer ${LBS_REALIZATION} health-check-table"
  echo "    get load-balancer ${LBS_REALIZATION} status"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
print_report(){
  local sep; sep="$(printf '=%.0s' {1..86})"
  local thin; thin="$(printf -- '-%.0s' {1..86})"
  {
    echo ""
    echo "${sep}"
    echo "  NSX-T Load Balancer Troubleshoot Report"
    echo "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Manager   : ${NSX_MGR}"
    echo "${sep}"
    echo ""
    echo "  LB SERVICE"
    echo "  ${thin:2}"
    printf '    %-22s %s\n' "Display name:"      "${LBS_DISPLAY}"
    printf '    %-22s %s\n' "LB service (Policy):" "${LB_SERVICE_ID}"
    printf '    %-22s %s\n' "realization_id:"     "${LBS_REALIZATION}"
    printf '    %-22s %s\n' "  (Edge CLI id)"     "get load-balancer ${LBS_REALIZATION} status"
    printf '    %-22s %s\n' "Tier-1 (connectivity):" "${LBS_T1}"
    printf '    %-22s %s\n' "Enabled / Size:"     "${LBS_ENABLED} / ${LBS_SIZE}"
    [[ -n "${EDGE_ACTIVE_NOTE}" ]] && printf '    %-22s %s\n' "Edge runtime:" "${EDGE_ACTIVE_NOTE}"

    if (( ${#HC_ROWS[@]} > 0 )); then
      echo ""
      echo "  HEALTH-CHECK (classified)"
      echo "  ${thin:2}"
      printf '    %-22s %-7s %-17s %s\n' "MEMBER" "STATUS" "CLASS" "REASON"
      printf '    %-22s %-7s %-17s %s\n' "----------------------" "-------" "-----------------" "------"
      local r
      for r in "${HC_ROWS[@]}"; do
        [[ -z "${r}" ]] && continue
        printf '    %-22s %-7s %-17s %s\n' \
          "$(cut -d'|' -f1 <<<"${r}")" \
          "$(cut -d'|' -f2 <<<"${r}")" \
          "$(cut -d'|' -f3 <<<"${r}")" \
          "$(cut -d'|' -f4 <<<"${r}")"
      done
    fi

    if [[ -n "${POOL_ID}" ]]; then
      echo ""
      echo "  MEMBER ROOT-CAUSE  (${MEMBER_IP}:${MEMBER_PORT})"
      echo "  ${thin:2}"
      printf '    %-22s %s\n' "Pool (Policy id):" "${POOL_ID}"
      printf '    %-22s %s\n' "Pool display name:" "${POOL_NAME}"
      printf '    %-22s %s\n' "Active monitor(s):" "${POOL_MON_PATHS}"
      printf '    %-22s %s\n' "Monitor type:" "${MON_TYPE}"
      printf '    %-22s %s\n' "Monitor probe:" "${MON_METHOD} ${MON_URL} (port ${MON_PORT}, codes ${MON_CODES})"
      echo ""
      printf '    %-12s %s\n' "ROOT CAUSE:" "${ROOT_CAUSE}"
      printf '    %-12s %s\n' "SUGGESTION:" "${SUGGESTION}"
    fi

    echo ""
    echo "  ID & ERROR DECODER (keep this — the 'desencontros')"
    echo "  ${thin:2}"
    cat <<'LEGEND'
    * "% Invalid value for argument <lb-uuid>"  -> you passed a VS id where the
      Edge CLI wants an LB id. Use the LB service realization_id.
    * error_code 600 NOT_FOUND "case sensitive" -> the id does not exist in THAT
      namespace (e.g. a dataplane/Edge id queried on the Policy API), or it is
      stale. Convert it (re-discover by member ip+port), don't retype.
    * error_code 258 "requested URI ... could not be found" -> wrong ENDPOINT
      path (e.g. /status instead of /detailed-status).

    health-check FAIL_REASON:
    * "Connect to Peer Failure / Connection refused"  -> app not listening (backend).
    * "Receive Message Failure / Resource temporarily unavailable" -> port open but
      no valid L7 reply (monitor protocol mismatch, e.g. HTTP monitor vs HTTPS app).
    * "Timeout"                                        -> reachability / firewall.
LEGEND
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
  REPORT_FILE="${LOG_DIR}/lb_troubleshoot_$(date '+%Y%m%d_%H%M%S').txt"
  LOG_FILE="${LOG_DIR}/lb_troubleshoot_run_$(date '+%Y%m%d_%H%M%S').log"
  exec > >(tee -a "${LOG_FILE}") 2>&1

  log_banner "NSX-T LB Troubleshoot"

  resolve_manager
  # Credentials for the API (admin). Reused for --edge SSH when no key exists.
  ensure_api_creds
  nsx_api_check_auth || { log_err "Aborting — API not reachable/authorized."; exit 1; }

  resolve_lb_service
  edge_runtime
  member_root_cause
  apply_fix
  print_report

  log "=== Done ==="
  rotate_logs
  if has_tty; then
    confirm_clear_creds_with_timeout 30
  else
    clear_creds
  fi
}

main "$@"
