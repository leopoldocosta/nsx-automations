#!/usr/bin/env bash
# apiuser_audit.sh
# Audit a service account (default: apiuser) across every NSX-T Manager.
#
# READ-ONLY. Runs as root on each manager (root SSH, ssh_root). Writes nothing
# on the managers; only reads account metadata and the login accounting files.
#
# v1 (this file) answers, per manager, WITHOUT touching the large/compressed
# text logs — so it is cheap and near-instant fleet-wide:
#   1. Does the account exist at all?         getent passwd <acct>
#   2. Is it locked / has a usable password?  passwd -S <acct>   (root)
#   3. Does it have an interactive shell?      (shell field of getent)
#   4. Is it privileged?                       id <acct> + sudoers grep
#   5. Has it EVER logged in, and when/where?  lastlog -u <acct>
#   6. SSH sessions in the window?             last  (wtmp)  filtered by --since
#   7. Failed SSH attempts in the window?      last -f /var/log/btmp filtered
#
# v2 (planned, not here): scan /var/log/auth.log* (deep SSH) and the NSX API
# audit log (userName="<acct>") by time window, selecting rotated/.gz files by
# mtime and streaming with `zcat -f` so the huge/compressed volume stays cheap.
# The window flags below are already plumbed for that.
#
# The window (--hours / --days / --since) filters only EVENT metrics (wtmp/btmp
# sessions). STATE metrics (exists / locked / shell / last-login time) are
# always shown — they are current facts, not events.
#
# Verdict per manager:
#   ABSENT           : the account does not exist on this manager.
#   PRESENT_LOCKED   : exists but the password is locked (passwd -S => L).
#   PRESENT_UNUSED   : exists, not locked, but never logged in / no sessions.
#   PRESENT_USED     : exists and has SSH login history (lastlog or wtmp).
#   ERROR            : root SSH or the probe failed.
# A PRIVILEGED flag (sudo/admin) is surfaced as a separate column + warning.
#
# Flags:
#   --user <name>    Account to audit (default: apiuser). [A-Za-z0-9._-]
#   --hours <N>      Window = now - N hours (default: 1).
#   --days <N>       Window = now - N days (overrides --hours).
#   --since "<ts>"   Window start as an absolute GNU-date string
#                    (e.g. "2026-07-24 09:00"). Overrides --hours/--days.
#   -h | --help      Show this header.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=../../lib/nsx_manager.sh
source "${REPO_ROOT}/lib/nsx_manager.sh"
# shellcheck source=../../lib/nsx_edge.sh
source "${REPO_ROOT}/lib/nsx_edge.sh"   # for ssh_root / root_cmd / ask_root_creds

need_cmd ssh
need_cmd awk
need_cmd date

# Local managers.conf wins; falls back to inventory/managers.conf (central).
MANAGERS_CONF="${MANAGERS_CONF:-$(resolve_inventory_file "${SCRIPT_DIR}/managers.conf")}"

ACCOUNT="apiuser"
WIN_HOURS=1
WIN_DAYS=""
SINCE_ARG=""

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)   ACCOUNT="$2"; shift 2 ;;
    --hours)  WIN_HOURS="$2"; shift 2 ;;
    --days)   WIN_DAYS="$2"; shift 2 ;;
    --since)  SINCE_ARG="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

# Validate the account name — it is interpolated into the remote probe command,
# so keep it to a strict allowlist (defense in depth; never trust it as shell).
if [[ ! "${ACCOUNT}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  log_err "Invalid --user '${ACCOUNT}' (allowed: A-Za-z0-9._-)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the window start (epoch). Precedence: --since > --days > --hours.
# ---------------------------------------------------------------------------
resolve_since_epoch(){
  local s
  if [[ -n "${SINCE_ARG}" ]]; then
    if ! s="$(date -d "${SINCE_ARG}" +%s 2>/dev/null)"; then
      log_err "--since '${SINCE_ARG}' is not a date GNU date understands."
      exit 1
    fi
  elif [[ -n "${WIN_DAYS}" ]]; then
    [[ "${WIN_DAYS}" =~ ^[0-9]+$ ]] || { log_err "--days must be an integer."; exit 1; }
    s="$(date -d "-${WIN_DAYS} days" +%s)"
  else
    [[ "${WIN_HOURS}" =~ ^[0-9]+$ ]] || { log_err "--hours must be an integer."; exit 1; }
    s="$(date -d "-${WIN_HOURS} hours" +%s)"
  fi
  printf '%s' "${s}"
}

SINCE_EPOCH="$(resolve_since_epoch)"
SINCE_HUMAN="$(date -d "@${SINCE_EPOCH}" '+%F %T')"

# ---------------------------------------------------------------------------
# Per-manager result arrays (keyed by IP)
# ---------------------------------------------------------------------------
declare -A M_CLUSTER M_EXISTS M_SHELL M_UID M_HOME
declare -A M_LOCK M_PRIV M_PRIV_WHY
declare -A M_LASTLOGIN M_LASTSRC
declare -A M_SESS_CNT M_SESS_SRCS M_FAIL_CNT
declare -A M_VERDICT M_ERROR

MGR_IPS=()

# ---------------------------------------------------------------------------
# load_managers — flatten every cluster in managers.conf into MGR_IPS[],
# recording each IP's cluster label in M_CLUSTER.
# ---------------------------------------------------------------------------
load_managers(){
  parse_managers_conf "${MANAGERS_CONF}"
  local i ip
  for (( i=0; i<CLUSTER_COUNT; i++ )); do
    # shellcheck disable=SC2178
    local -n _hv="CLUSTER_HOSTS_${i}"
    for ip in "${_hv[@]}"; do
      MGR_IPS+=("${ip}")
      M_CLUSTER["${ip}"]="${CLUSTER_LABELS[$i]}"
    done
    unset -n _hv
  done
  if (( ${#MGR_IPS[@]} == 0 )); then
    log_err "No managers parsed from ${MANAGERS_CONF}."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# _section <raw> <begin_marker> <end_marker>
#   Echo the lines strictly between two markers (markers excluded).
# ---------------------------------------------------------------------------
_section(){
  awk -v b="$2" -v e="$3" 'index($0,b){f=1;next} index($0,e){f=0;next} f' <<<"$1"
}

# ---------------------------------------------------------------------------
# _epoch_of_last_line <last -F line>
#   `last -F` prints e.g.:  "apiuser pts/0 10.0.0.5 Wed Jul 24 13:05:11 2026 - ..."
#   The login timestamp is a fixed 5-field run ending in the year. Extract it
#   ("Wed Jul 24 13:05:11 2026") and convert with GNU date. Echoes epoch or "".
# ---------------------------------------------------------------------------
_epoch_of_last_line(){
  local ts
  # Pull "Dow Mon DD HH:MM:SS YYYY" — the first such run in the line.
  ts="$(grep -oE '[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}' <<<"$1" | head -1 || true)"
  [[ -z "${ts}" ]] && return 0
  date -d "${ts}" +%s 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# collect_manager <ip>
#   One root round-trip; parse locally. Fills the M_* arrays for <ip>.
# ---------------------------------------------------------------------------
collect_manager(){
  local ip="$1"
  M_ERROR["${ip}"]=""
  M_CLUSTER["${ip}"]="${M_CLUSTER[${ip}]:-?}"

  log "${ip}: probing account '${ACCOUNT}' via root..."

  # Single round-trip, marker-delimited so we split locally (same idiom as
  # edge_hardware_inventory). The account name is allowlist-validated above.
  local raw
  raw="$(root_cmd "${ip}" '
    acct='"${ACCOUNT}"'
    echo "----EXISTS----";   getent passwd "$acct" 2>/dev/null || true
    echo "----PWSTATUS----"; passwd -S "$acct" 2>/dev/null || true
    echo "----ID----";       id "$acct" 2>/dev/null || true
    echo "----SUDO----";     grep -rHnE "(^|[[:space:]])${acct}([[:space:]]|,|$)" /etc/sudoers /etc/sudoers.d/ 2>/dev/null || true
    echo "----LASTLOG----";  lastlog -u "$acct" 2>/dev/null || true
    echo "----LAST----";     last -F -w "$acct" 2>/dev/null | head -n 500 || true
    echo "----LASTB----";    last -F -w -f /var/log/btmp "$acct" 2>/dev/null | head -n 500 || true
    echo "----END----"
  ' 2>/dev/null || true)"

  if [[ -z "${raw}" ]] || ! grep -q '^----END----$' <<<"${raw}"; then
    M_ERROR["${ip}"]="root SSH failed or probe returned nothing."
    M_VERDICT["${ip}"]="ERROR"
    log_warn "${ip}: root SSH/probe failed."
    return 1
  fi

  # ---- EXISTS ----
  local exists_line
  exists_line="$(_section "${raw}" '----EXISTS----' '----PWSTATUS----' | head -1)"
  if [[ -z "${exists_line}" ]]; then
    M_EXISTS["${ip}"]="no"
    M_VERDICT["${ip}"]="ABSENT"
    log_ok "${ip}: account '${ACCOUNT}' does NOT exist."
    return 0
  fi
  M_EXISTS["${ip}"]="yes"
  # getent format: name:x:uid:gid:gecos:home:shell
  M_UID["${ip}"]="$(cut -d: -f3 <<<"${exists_line}")"
  M_HOME["${ip}"]="$(cut -d: -f6 <<<"${exists_line}")"
  M_SHELL["${ip}"]="$(cut -d: -f7 <<<"${exists_line}")"

  # ---- PWSTATUS: "apiuser L 2024-... " -> field 2 is L/P/NP ----
  local pw
  pw="$(_section "${raw}" '----PWSTATUS----' '----ID----' | head -1)"
  case "$(awk '{print $2}' <<<"${pw}")" in
    L)  M_LOCK["${ip}"]="locked" ;;
    P)  M_LOCK["${ip}"]="usable" ;;
    NP) M_LOCK["${ip}"]="no-pass" ;;
    *)  M_LOCK["${ip}"]="?" ;;
  esac

  # ---- Privilege: sudoers hit, or a suspicious group in `id` ----
  local sudo_block id_line
  sudo_block="$(_section "${raw}" '----SUDO----' '----LASTLOG----')"
  id_line="$(  _section "${raw}" '----ID----'   '----SUDO----' | head -1)"
  M_PRIV["${ip}"]="no"; M_PRIV_WHY["${ip}"]=""
  if [[ -n "${sudo_block}" ]]; then
    M_PRIV["${ip}"]="yes"; M_PRIV_WHY["${ip}"]="sudoers"
  elif grep -qiE '\((sudo|wheel|admin|root)\)|=root' <<<"${id_line}"; then
    M_PRIV["${ip}"]="yes"; M_PRIV_WHY["${ip}"]="group"
  fi

  # ---- LASTLOG (single most-recent login, any time) ----
  local ll
  ll="$(_section "${raw}" '----LASTLOG----' '----LAST----' | sed -n '2p')"  # row 2 = data
  if [[ -z "${ll}" ]] || grep -qiE 'never logged in|\*\*Never' <<<"${ll}"; then
    M_LASTLOGIN["${ip}"]="never"; M_LASTSRC["${ip}"]="-"
  else
    # lastlog: Username Port From Latest...  — "From" is field 3 when present.
    M_LASTSRC["${ip}"]="$(awk '{print $3}' <<<"${ll}")"
    # "Latest" is the trailing date; grab the Dow..Year run if present.
    local lts
    lts="$(grep -oE '[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]{1,2} [0-9:]{8} [0-9]{4}' <<<"${ll}" | head -1 || true)"
    M_LASTLOGIN["${ip}"]="${lts:-$(echo "${ll}" | sed 's/^[^ ]* *//' | xargs)}"
    [[ -z "${M_LASTSRC[${ip}]}" ]] && M_LASTSRC["${ip}"]="-"
  fi

  # ---- LAST (wtmp sessions) — count + source IPs within the window ----
  local last_block line ep cnt=0 srcs="" src
  last_block="$(_section "${raw}" '----LAST----' '----LASTB----')"
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    grep -qiE '^wtmp begins|^reboot |^\s*$' <<<"${line}" && continue
    [[ "$(awk '{print $1}' <<<"${line}")" == "${ACCOUNT}" ]] || continue
    ep="$(_epoch_of_last_line "${line}")"
    [[ -z "${ep}" ]] && continue
    (( ep < SINCE_EPOCH )) && continue
    cnt=$(( cnt + 1 ))
    src="$(awk '{print $3}' <<<"${line}")"
    [[ -n "${src}" && "${srcs}" != *"${src}"* ]] && srcs="${srcs:+${srcs},}${src}"
  done <<< "${last_block}"
  M_SESS_CNT["${ip}"]="${cnt}"
  M_SESS_SRCS["${ip}"]="${srcs:--}"

  # ---- LASTB (btmp failed attempts) within the window ----
  local lb_block fcnt=0
  lb_block="$(_section "${raw}" '----LASTB----' '----END----')"
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    grep -qiE '^btmp begins|^\s*$' <<<"${line}" && continue
    [[ "$(awk '{print $1}' <<<"${line}")" == "${ACCOUNT}" ]] || continue
    ep="$(_epoch_of_last_line "${line}")"
    [[ -n "${ep}" ]] && (( ep < SINCE_EPOCH )) && continue
    fcnt=$(( fcnt + 1 ))
  done <<< "${lb_block}"
  M_FAIL_CNT["${ip}"]="${fcnt}"

  # ---- Verdict ----
  if [[ "${M_LOCK[${ip}]}" == "locked" && "${M_LASTLOGIN[${ip}]}" == "never" && "${cnt}" -eq 0 ]]; then
    M_VERDICT["${ip}"]="PRESENT_LOCKED"
  elif [[ "${M_LASTLOGIN[${ip}]}" != "never" || "${cnt}" -gt 0 ]]; then
    M_VERDICT["${ip}"]="PRESENT_USED"
  else
    M_VERDICT["${ip}"]="PRESENT_UNUSED"
  fi

  local msg="${ip}: ${ACCOUNT} present — verdict=${M_VERDICT[${ip}]} lock=${M_LOCK[${ip}]} shell=${M_SHELL[${ip}]} last=${M_LASTLOGIN[${ip}]} sess=${cnt} fail=${fcnt}"
  if [[ "${M_PRIV[${ip}]}" == "yes" ]]; then
    log_warn "${msg} PRIVILEGED(${M_PRIV_WHY[${ip}]})"
  else
    log_ok "${msg}"
  fi
}

# ---------------------------------------------------------------------------
# print_report — human table (tee to REPORT_FILE) + CSV side-output
# ---------------------------------------------------------------------------
print_report(){
  local sep; sep="$(printf '=%.0s' {1..118})"
  local used=0 locked=0 unused=0 absent=0 errs=0 priv=0 ip

  {
    echo ""; echo "${sep}"
    printf '  NSX Manager — Service-Account Audit: %s\n' "${ACCOUNT}"
    printf '  Generated: %s   Window since: %s\n' "$(date '+%F %T')" "${SINCE_HUMAN}"
    printf '  (STATE columns are current facts; SESSIONS/FAILED are within the window)\n'
    echo "${sep}"; echo ""

    printf '  %-4s  %-17s  %-8s  %-7s  %-16s  %-8s  %-6s  %-22s  %-6s  %-5s  %s\n' \
      "#" "Manager IP" "Cluster" "Exists" "Shell" "Lock" "Priv" "Last SSH login" "Sess" "Fail" "Verdict"
    printf '  %-4s  %-17s  %-8s  %-7s  %-16s  %-8s  %-6s  %-22s  %-6s  %-5s  %s\n' \
      "----" "-----------------" "--------" "-------" "----------------" "--------" \
      "------" "----------------------" "------" "-----" "--------------"

    local idx=1
    for ip in "${MGR_IPS[@]}"; do
      local v="${M_VERDICT[${ip}]:-ERROR}"
      case "${v}" in
        PRESENT_USED)   used=$(( used+1 )) ;;
        PRESENT_LOCKED) locked=$(( locked+1 )) ;;
        PRESENT_UNUSED) unused=$(( unused+1 )) ;;
        ABSENT)         absent=$(( absent+1 )) ;;
        *)              errs=$(( errs+1 )) ;;
      esac
      [[ "${M_PRIV[${ip}]:-no}" == "yes" ]] && priv=$(( priv+1 ))
      printf '  %-4s  %-17s  %-8s  %-7s  %-16s  %-8s  %-6s  %-22s  %-6s  %-5s  %s\n' \
        "${idx}." "${ip}" "${M_CLUSTER[${ip}]:-?}" \
        "${M_EXISTS[${ip}]:-?}" "${M_SHELL[${ip}]:--}" "${M_LOCK[${ip}]:--}" \
        "${M_PRIV[${ip}]:-no}" "${M_LASTLOGIN[${ip}]:--}" \
        "${M_SESS_CNT[${ip}]:-0}" "${M_FAIL_CNT[${ip}]:-0}" "${v}"
      idx=$(( idx+1 ))
    done

    echo ""; echo "${sep}"
    printf '  SUMMARY: used=%d  locked=%d  unused=%d  absent=%d  error=%d  |  privileged=%d\n' \
      "${used}" "${locked}" "${unused}" "${absent}" "${errs}" "${priv}"
    echo "${sep}"; echo ""

    # Attention list: anything used, privileged, has failures, or errored.
    printf '  NEEDS ATTENTION\n'
    local any=false
    for ip in "${MGR_IPS[@]}"; do
      local v="${M_VERDICT[${ip}]:-ERROR}"
      local flag=""
      [[ "${v}" == "PRESENT_USED" ]]        && flag="${flag} used"
      [[ "${M_PRIV[${ip}]:-no}" == "yes" ]] && flag="${flag} PRIVILEGED(${M_PRIV_WHY[${ip}]:-?})"
      [[ "${M_FAIL_CNT[${ip}]:-0}" -gt 0 ]] && flag="${flag} failed=${M_FAIL_CNT[${ip}]}"
      [[ "${v}" == "ERROR" ]]               && flag="${flag} ERROR:${M_ERROR[${ip}]:-?}"
      if [[ -n "${flag}" ]]; then
        any=true
        printf '  - %-17s [%s]%s  src=%s\n' \
          "${ip}" "${M_CLUSTER[${ip}]:-?}" "${flag}" "${M_SESS_SRCS[${ip}]:-${M_LASTSRC[${ip}]:--}}"
      fi
    done
    ${any} || printf '  Nothing flagged: account is absent/locked/unused everywhere in this window.\n'
    echo ""
    printf '  NOTE: v1 covers existence + SSH (wtmp/btmp/lastlog). API-call auditing\n'
    printf '        (NSX audit log) lands in v2 once the log format is anchored.\n'
    echo ""; echo "${sep}"; echo "  END OF REPORT"; echo "${sep}"; echo ""
  } | tee "${REPORT_FILE}"

  # ---- CSV side-output ----
  {
    printf 'ip,cluster,account,exists,uid,home,shell,lock,privileged,priv_why,last_login,last_src,sessions_window,session_srcs,failed_window,verdict,error\n'
    for ip in "${MGR_IPS[@]}"; do
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s",%s,%s,"%s",%s,%s,"%s"\n' \
        "${ip}" "${M_CLUSTER[${ip}]:-}" "${ACCOUNT}" \
        "${M_EXISTS[${ip}]:-}" "${M_UID[${ip}]:-}" "${M_HOME[${ip}]:-}" "${M_SHELL[${ip}]:-}" \
        "${M_LOCK[${ip}]:-}" "${M_PRIV[${ip}]:-}" "${M_PRIV_WHY[${ip}]:-}" \
        "${M_LASTLOGIN[${ip}]:-}" "${M_LASTSRC[${ip}]:-}" \
        "${M_SESS_CNT[${ip}]:-0}" "${M_SESS_SRCS[${ip}]:-}" "${M_FAIL_CNT[${ip}]:-0}" \
        "${M_VERDICT[${ip}]:-ERROR}" "${M_ERROR[${ip}]:-}"
    done
  } > "${CSV_FILE}"

  log "Report saved to: ${REPORT_FILE}"
  log "CSV    saved to: ${CSV_FILE}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main(){
  load_managers

  # Root access: key (ROOT_KEY) when present, else prompt for a password.
  # Under the non-interactive fan-out there is no /dev/tty, so only prompt when
  # a key is absent AND we actually have a controlling terminal.
  if [[ -f "${ROOT_KEY}" ]]; then
    log "Root key present (${ROOT_KEY}) — password prompt skipped (key auth)."
  elif [[ -t 0 ]]; then
    ask_root_creds
  else
    log_warn "No root key and no TTY — relying on ROOT_PASS from the environment."
  fi

  REPORT_FILE="${LOG_DIR}/apiuser_audit_$(date '+%Y%m%d_%H%M%S').txt"
  CSV_FILE="${LOG_DIR}/apiuser_audit_$(date '+%Y%m%d_%H%M%S').csv"
  LOG_FILE="${LOG_DIR}/apiuser_audit_run_$(date '+%Y%m%d_%H%M%S').log"
  exec > >(tee -a "${LOG_FILE}") 2>&1

  log_banner "apiuser Audit — ${ACCOUNT}"
  log "Managers: ${#MGR_IPS[@]}  |  window since ${SINCE_HUMAN}  |  conf ${MANAGERS_CONF}"

  local ip failed=()
  for ip in "${MGR_IPS[@]}"; do
    log "--- ${ip} [${M_CLUSTER[${ip}]:-?}] ---"
    collect_manager "${ip}" || failed+=("${ip}")
  done
  (( ${#failed[@]} > 0 )) && log_warn "Managers with probe errors: ${failed[*]}"

  # Wrap in the aggregation sentinels so a multi-DC fan-out lifts this one
  # report block out of run.log into the unified fleet report.
  report_wrap print_report

  log "=== Done ==="
  rotate_logs
}

main "$@"
