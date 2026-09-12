#!/usr/bin/env bash
# routing_model_audit.sh
# NSX-T <-> underlay routing model audit — is it BGP or static route?
#
# READ-ONLY. Pure Policy API GETs against each DC's NSX Manager (no SSH, no
# PATCH, nothing mutated). Answers, per Tier-0 gateway (the ONLY place NSX-T
# peers with the physical underlay), the one question a pre-design must settle
# before assuming a routing model:
#
#     Does the NSX <-> physical boundary run BGP, or static routes?
#
# For each Tier-0, across every locale-service, it collects:
#   1. BGP enabled?              GET .../locale-services/<ls>/bgp        (.enabled)
#   2. Local AS                  (.local_as_num)
#   3. BGP neighbors CONFIGURED  GET .../bgp/neighbors                  (count + list)
#   4. BGP neighbors ESTABLISHED GET .../bgp/neighbors/status  (runtime; best-effort)
#   5. Static routes             GET .../tier-0s/<t0>/static-routes     (count)
#   6. Default static route?     any static route with network 0.0.0.0/0
#
# Verdict per Tier-0:
#   BGP     : BGP enabled with >=1 neighbor configured (no default static route).
#   STATIC  : no BGP neighbors, but static route(s) present.
#   MIXED   : BGP neighbors AND static route(s) both present.
#   NONE    : neither — a stub/disconnected Tier-0 (flagged for review).
#   ERROR   : the API calls for this Tier-0 failed.
# A "default origin" column says how the default route to the underlay is set:
#   static (an explicit 0.0.0.0/0 route), bgp? (inferred from an up session), or
#   none. The BGP one carries a "?" because confirming it is via the RIB, not
#   config — but a design premise ("there are BGP sessions to the fabric") is
#   already answered yes/no by neighbors-configured + established here.
#
# The fleet SUMMARY prints a one-line CONCLUSION — e.g. "all Tier-0s are STATIC,
# no BGP configured" — which is exactly the fact a pre-design checkpoint needs
# before building on a BGP assumption.
#
# Manager & credentials (same contract as lb_troubleshoot, fan-out safe):
#   * --manager <ip|fqdn> is optional; without it the first manager of THIS DC's
#     central inventory (inventory/managers.conf) is used, so the same fan-out
#     command works in every datacenter.
#   * API creds come from env (NSX_USER/NSX_PASS) or a saved run/session.env;
#     under the non-interactive fan-out the script never prompts.
#
# Run across the fleet from the orchestrator:
#   ./bin/run_across_datacenters.sh --conf ./datacenters.conf \
#     --automation routing_model_audit/routing_model_audit.sh
#
# Flags:
#   --manager <ip|fqdn>  NSX Manager (no scheme). Optional (see above).
#   --tier0 <id|name>    Audit only this Tier-0 (matches id or display name).
#   --no-runtime         Skip the BGP neighbor STATUS calls (config-only; faster).
#   -h | --help          Show this header.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=../../lib/nsx_api.sh
source "${REPO_ROOT}/lib/nsx_api.sh"
# nsx_manager.sh provides parse_managers_conf for the --manager fallback
# shellcheck source=../../lib/nsx_manager.sh
source "${REPO_ROOT}/lib/nsx_manager.sh"

need_cmd curl
need_cmd jq
need_cmd base64

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
NSX_MGR=""
T0_FILTER=""
WITH_RUNTIME=true

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manager)    NSX_MGR="$2"; shift 2 ;;
    --tier0)      T0_FILTER="$2"; shift 2 ;;
    --no-runtime) WITH_RUNTIME=false; shift ;;
    -h|--help)    usage ;;
    *) log_err "Unknown flag: $1"; usage ;;
  esac
done

has_tty(){ [[ -t 0 && -e /dev/tty ]]; }

# ---------------------------------------------------------------------------
# Manager resolution — explicit --manager wins; else first manager of THIS DC's
# central inventory (each jump owns only its own managers.conf). Identical
# contract to lb_troubleshoot so one fan-out command fits every DC.
# ---------------------------------------------------------------------------
resolve_manager(){
  if [[ -n "${NSX_MGR}" ]]; then export NSX_MGR; return 0; fi
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
# API credentials — env first, then a saved session, then a TTY prompt only
# when a terminal is present. Never prompts under the fan-out.
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
  log_err "  cd automations/routing_model_audit && source ../../lib/common.sh \\"
  log_err "    && ask_admin_creds && save_session_env"
  log_err "or export NSX_USER/NSX_PASS in the environment before the run."
  exit 1
}

# ---------------------------------------------------------------------------
# Policy API readers (all read-only). Each emits TSV so we parse locally.
# ---------------------------------------------------------------------------
_t0_list(){
  _nsx_paginate "/policy/api/v1/infra/tier-0s" \
    '.results[]? | [(.id // "-"), (.display_name // .id // "-"), (.ha_mode // "-")] | @tsv'
}
_ls_list(){
  local t0="$1"
  _nsx_paginate "/policy/api/v1/infra/tier-0s/${t0}/locale-services" \
    '.results[]? | (.id // empty)'
}
_bgp_cfg(){   # -> "<enabled>\t<local_as>"
  local t0="$1" ls="$2"
  nsx_api_get "/policy/api/v1/infra/tier-0s/${t0}/locale-services/${ls}/bgp" \
    | jq -r '[(.enabled // false), (.local_as_num // "-")] | @tsv' 2>/dev/null || true
}
_bgp_neighbors(){  # -> "<neighbor_address>\t<remote_as>\t<name>" per neighbor
  local t0="$1" ls="$2"
  _nsx_paginate "/policy/api/v1/infra/tier-0s/${t0}/locale-services/${ls}/bgp/neighbors" \
    '.results[]? | [(.neighbor_address // "-"), (.remote_as_num // "-"), (.display_name // .id // "-")] | @tsv'
}
_bgp_status(){     # -> "<neighbor_address>\t<connection_state>\t<source_address>" (runtime)
  local t0="$1" ls="$2"
  nsx_api_get "/policy/api/v1/infra/tier-0s/${t0}/locale-services/${ls}/bgp/neighbors/status" \
    | jq -r '.results[]? | [(.neighbor_address // "-"), (.connection_state // "-"), (.source_address // "-")] | @tsv' 2>/dev/null || true
}
_static_routes(){  # -> "<network>\t<nexthops-csv>" per static route
  local t0="$1"
  _nsx_paginate "/policy/api/v1/infra/tier-0s/${t0}/static-routes" \
    '.results[]? | [(.network // "-"), ([.next_hops[]?.ip_address] | map(select(. != null)) | join(",") | if . == "" then "-" else . end)] | @tsv'
}

# ---------------------------------------------------------------------------
# Per-Tier-0 result arrays (keyed by Tier-0 id)
# ---------------------------------------------------------------------------
declare -A T0_NAME T0_HA
declare -A T0_BGP_ENABLED T0_LOCAL_AS
declare -A T0_NBR_CFG T0_NBR_EST T0_NBR_RT
declare -A T0_STATIC_CNT T0_STATIC_DEFAULT
declare -A T0_DEFAULT_ORIGIN T0_VERDICT T0_ERROR
declare -A T0_NBR_DETAIL T0_STATIC_DETAIL   # on-disk report detail (carries underlay IPs)
T0_IDS=()

# ---------------------------------------------------------------------------
# collect_t0 <id> — aggregate BGP + static across all locale-services of a T0.
# ---------------------------------------------------------------------------
collect_t0(){
  local id="$1"
  T0_ERROR["${id}"]=""
  local bgp_enabled="no" local_as="-"
  local nbr_cfg=0 nbr_est=0 nbr_rt=0
  local nbr_detail="" line

  # --- BGP, per locale-service ---
  local ls
  while IFS= read -r ls; do
    [[ -z "${ls}" ]] && continue
    local en="" as=""
    { IFS=$'\t' read -r en as || true; } < <(_bgp_cfg "${id}" "${ls}")
    [[ "${en}" == "true" ]] && bgp_enabled="yes"
    [[ -n "${as:-}" && "${as}" != "-" ]] && local_as="${as}"

    # configured neighbors
    while IFS=$'\t' read -r naddr nas nname; do
      [[ -z "${naddr}" ]] && continue
      nbr_cfg=$(( nbr_cfg + 1 ))
      nbr_detail+="${nbr_detail:+; }${naddr} (AS ${nas}${nname:+, ${nname}})"
    done < <(_bgp_neighbors "${id}" "${ls}")

    # runtime established count (best-effort)
    if "${WITH_RUNTIME}"; then
      while IFS=$'\t' read -r saddr state _; do
        [[ -z "${saddr}" ]] && continue
        nbr_rt=$(( nbr_rt + 1 ))
        # NSX reports "ESTABLISHED"; be lenient on case/spelling.
        [[ "${state^^}" == *ESTAB* ]] && nbr_est=$(( nbr_est + 1 ))
      done < <(_bgp_status "${id}" "${ls}")
    fi
  done < <(_ls_list "${id}")

  # --- Static routes (T0-level) ---
  local static_cnt=0 has_default="no" static_detail=""
  while IFS=$'\t' read -r net nh; do
    [[ -z "${net}" ]] && continue
    static_cnt=$(( static_cnt + 1 ))
    [[ "${net}" == "0.0.0.0/0" ]] && has_default="yes"
    static_detail+="${static_detail:+; }${net} -> ${nh}"
  done < <(_static_routes "${id}")

  # --- Verdict + default-route origin ---
  local has_bgp="no"
  [[ "${bgp_enabled}" == "yes" && "${nbr_cfg}" -gt 0 ]] && has_bgp="yes"
  local verdict origin
  if [[ "${has_bgp}" == "yes" && "${static_cnt}" -gt 0 ]]; then verdict="MIXED"
  elif [[ "${has_bgp}" == "yes" ]];                        then verdict="BGP"
  elif [[ "${static_cnt}" -gt 0 ]];                        then verdict="STATIC"
  else                                                          verdict="NONE"
  fi
  if   [[ "${has_default}" == "yes" ]]; then origin="static"
  elif [[ "${has_bgp}" == "yes" ]];     then origin="bgp?"
  else                                       origin="none"
  fi

  T0_BGP_ENABLED["${id}"]="${bgp_enabled}"
  T0_LOCAL_AS["${id}"]="${local_as}"
  T0_NBR_CFG["${id}"]="${nbr_cfg}"
  T0_NBR_EST["${id}"]="$( "${WITH_RUNTIME}" && echo "${nbr_est}" || echo "-" )"
  T0_NBR_RT["${id}"]="${nbr_rt}"
  T0_STATIC_CNT["${id}"]="${static_cnt}"
  T0_STATIC_DEFAULT["${id}"]="${has_default}"
  T0_DEFAULT_ORIGIN["${id}"]="${origin}"
  T0_VERDICT["${id}"]="${verdict}"
  T0_NBR_DETAIL["${id}"]="${nbr_detail:--}"
  T0_STATIC_DETAIL["${id}"]="${static_detail:--}"

  local est_note; est_note="$( "${WITH_RUNTIME}" && echo "est=${nbr_est}/${nbr_rt}" || echo "est=skipped" )"
  log_progress "T0 '${T0_NAME[${id}]:-${id}}': ${verdict} (bgp=${bgp_enabled} nbr=${nbr_cfg} ${est_note} static=${static_cnt} default=${origin})"
}

# ---------------------------------------------------------------------------
# print_report — human table (tee to REPORT_FILE) + CSV side-output.
# The DETAIL section and CSV carry underlay neighbor/next-hop IPs; they are
# operational artifacts written to logs/ on the jump (git-ignored), same as the
# other automations. Do not paste them verbatim into chat — mask when sharing.
# ---------------------------------------------------------------------------
print_report(){
  local sep; sep="$(printf '=%.0s' {1..104})"
  local nbgp=0 nstatic=0 nmixed=0 nnone=0 nerr=0 id

  {
    echo ""; echo "${sep}"
    printf '  NSX-T <-> Underlay Routing Model (Tier-0 gateways)\n'
    printf '  Manager: %s   Generated: %s\n' "${NSX_MGR}" "$(date '+%F %T')"
    "${WITH_RUNTIME}" || printf '  (--no-runtime: BGP session state not queried; Est shown as -)\n'
    echo "${sep}"; echo ""

    printf '  %-3s  %-26s  %-9s  %-5s  %-8s  %-9s  %-4s  %-8s  %-9s  %s\n' \
      "#" "Tier-0" "HA" "BGP" "LocalAS" "Nbr(cfg)" "Est" "Static" "Default" "Verdict"
    printf '  %-3s  %-26s  %-9s  %-5s  %-8s  %-9s  %-4s  %-8s  %-9s  %s\n' \
      "---" "--------------------------" "---------" "-----" "--------" "---------" \
      "----" "--------" "---------" "--------"

    local idx=1
    for id in "${T0_IDS[@]}"; do
      local v="${T0_VERDICT[${id}]:-ERROR}"
      case "${v}" in
        BGP)    nbgp=$(( nbgp+1 )) ;;
        STATIC) nstatic=$(( nstatic+1 )) ;;
        MIXED)  nmixed=$(( nmixed+1 )) ;;
        NONE)   nnone=$(( nnone+1 )) ;;
        *)      nerr=$(( nerr+1 )) ;;
      esac
      printf '  %-3s  %-26s  %-9s  %-5s  %-8s  %-9s  %-4s  %-8s  %-9s  %s\n' \
        "${idx}." "${T0_NAME[${id}]:0:26}" "${T0_HA[${id}]:--}" \
        "${T0_BGP_ENABLED[${id}]:-?}" "${T0_LOCAL_AS[${id}]:--}" \
        "${T0_NBR_CFG[${id}]:-0}" "${T0_NBR_EST[${id}]:--}" \
        "${T0_STATIC_CNT[${id}]:-0}" "${T0_DEFAULT_ORIGIN[${id}]:--}" "${v}"
      idx=$(( idx+1 ))
    done

    echo ""; echo "${sep}"
    printf '  SUMMARY: BGP=%d  STATIC=%d  MIXED=%d  NONE=%d  ERROR=%d   (of %d Tier-0)\n' \
      "${nbgp}" "${nstatic}" "${nmixed}" "${nnone}" "${nerr}" "${#T0_IDS[@]}"

    # --- The one line a pre-design checkpoint needs ---
    printf '  CONCLUSION: '
    if (( ${#T0_IDS[@]} == 0 )); then
      printf 'no Tier-0 gateway found on this manager.\n'
    elif (( nbgp == 0 && nmixed == 0 && nstatic > 0 )); then
      printf 'NO BGP configured — the NSX<->underlay boundary is STATIC ROUTE on every Tier-0.\n'
      printf '              A design premise of "BGP sessions between NSX and the physical fabric" does NOT hold here.\n'
    elif (( nstatic == 0 && nnone == 0 && (nbgp > 0 || nmixed > 0) )); then
      printf 'BGP is the routing model to the underlay (%d Tier-0 peer via BGP).\n' "$(( nbgp + nmixed ))"
    else
      printf 'MIXED — %d Tier-0 use BGP, %d use static route. Confirm the intended model per Tier-0.\n' \
        "$(( nbgp + nmixed ))" "${nstatic}"
    fi
    echo "${sep}"; echo ""

    # --- Detail (per Tier-0): neighbors + static routes (carries underlay IPs) ---
    printf '  DETAIL (neighbor + static-route addresses — underlay IPs; mask when sharing)\n'
    for id in "${T0_IDS[@]}"; do
      printf '  - %-26s [%s]\n' "${T0_NAME[${id}]:0:26}" "${T0_VERDICT[${id}]:-ERROR}"
      printf '      BGP neighbors : %s\n' "${T0_NBR_DETAIL[${id}]:--}"
      printf '      static routes : %s\n' "${T0_STATIC_DETAIL[${id}]:--}"
      [[ -n "${T0_ERROR[${id}]:-}" ]] && printf '      ERROR         : %s\n' "${T0_ERROR[${id}]}"
    done

    echo ""; echo "${sep}"
    printf '  LEGEND\n'
    printf '   BGP      Tier-0 has BGP enabled with >=1 neighbor CONFIGURED (Est = sessions ESTABLISHED now).\n'
    printf '   STATIC   no BGP neighbors; reachability to the underlay is via static route(s).\n'
    printf '   MIXED    both a BGP neighbor and static route(s) exist on the Tier-0.\n'
    printf '   NONE     neither — stub/disconnected Tier-0 (no uplink routing). Review.\n'
    printf '   Default  origin of the default route: static (explicit 0.0.0.0/0), bgp? (inferred), none.\n'
    printf '   Read-only: Policy API GETs only. Confirm live sessions/RIB on the Edge CLI if needed:\n'
    printf '     get logical-router  /  get bgp neighbor summary\n'
    echo "${sep}"; echo "  END OF REPORT"; echo "${sep}"; echo ""
  } | tee "${REPORT_FILE}"

  # ---- CSV side-output ----
  {
    printf 'tier0_id,tier0_name,ha_mode,bgp_enabled,local_as,neighbors_cfg,neighbors_established,neighbors_runtime,static_routes,has_default_static,default_origin,verdict,error\n'
    for id in "${T0_IDS[@]}"; do
      printf '%s,"%s",%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s"\n' \
        "${id}" "${T0_NAME[${id}]:-}" "${T0_HA[${id}]:-}" \
        "${T0_BGP_ENABLED[${id}]:-}" "${T0_LOCAL_AS[${id}]:-}" \
        "${T0_NBR_CFG[${id}]:-0}" "${T0_NBR_EST[${id}]:--}" "${T0_NBR_RT[${id}]:-0}" \
        "${T0_STATIC_CNT[${id}]:-0}" "${T0_STATIC_DEFAULT[${id}]:-}" \
        "${T0_DEFAULT_ORIGIN[${id}]:-}" "${T0_VERDICT[${id}]:-ERROR}" "${T0_ERROR[${id}]:-}"
    done
  } > "${CSV_FILE}"

  log "Report saved to: ${REPORT_FILE}"
  log "CSV    saved to: ${CSV_FILE}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main(){
  resolve_manager
  ensure_api_creds
  nsx_api_check_auth || exit 1

  local ts; ts="$(date '+%Y%m%d_%H%M%S')"
  REPORT_FILE="${LOG_DIR}/routing_model_${ts}.txt"
  CSV_FILE="${LOG_DIR}/routing_model_${ts}.csv"
  LOG_FILE="${LOG_DIR}/routing_model_run_${ts}.log"
  exec > >(tee -a "${LOG_FILE}") 2>&1

  log_banner "NSX Routing Model Audit"
  log "Manager: ${NSX_MGR}  |  runtime status: $("${WITH_RUNTIME}" && echo on || echo off)"

  # Enumerate Tier-0s (optionally filtered by --tier0 id|name).
  local id name ha
  while IFS=$'\t' read -r id name ha; do
    [[ -z "${id}" ]] && continue
    if [[ -n "${T0_FILTER}" && "${id}" != "${T0_FILTER}" && "${name}" != "${T0_FILTER}" ]]; then
      continue
    fi
    T0_IDS+=("${id}")
    T0_NAME["${id}"]="${name}"
    T0_HA["${id}"]="${ha}"
  done < <(_t0_list)

  if (( ${#T0_IDS[@]} == 0 )); then
    if [[ -n "${T0_FILTER}" ]]; then
      log_err "No Tier-0 matched --tier0 '${T0_FILTER}' on ${NSX_MGR}."
    else
      log_warn "No Tier-0 gateway found on ${NSX_MGR} (nothing to audit)."
    fi
  fi

  log "Tier-0 gateways to audit: ${#T0_IDS[@]}"
  local i=0 total="${#T0_IDS[@]}"
  for id in "${T0_IDS[@]}"; do
    i=$(( i+1 ))
    log "--- (${i}/${total}) Tier-0 '${T0_NAME[${id}]:-${id}}' ---"
    collect_t0 "${id}" || { T0_VERDICT["${id}"]="ERROR"; T0_ERROR["${id}"]="collection failed"; }
  done

  # Wrap in the aggregation sentinels so a multi-DC fan-out lifts this one
  # report block out of run.log into the unified fleet report.
  report_wrap print_report

  log "=== Done ==="
  rotate_logs
}

main "$@"
