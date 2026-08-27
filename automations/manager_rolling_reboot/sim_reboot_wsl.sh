#!/usr/bin/env bash
# sim_reboot_wsl.sh
# LOCAL / WSL SIMULATION of the manager rolling-reboot cycle — NO NSX, NO network.
#
# Why this exists:
#   NSX_DRY_RUN=1 short-circuits the real reboot path (reboot_one_manager_by_ip
#   just logs "would reboot" and returns 0). So dry-run never exercises the state
#   machine that actually matters and is NOT yet field-validated (TODO #2):
#       ssh_admin reboot <<<yes  ->  TCP drops  ->  TCP returns  ->  cluster STABLE
#   ...plus the safety trap: "still online after MAX_WAIT => abort, do NOT report
#   success" (which is what stops the daily orchestrator from silently advancing
#   the plan index over a manager that never actually rebooted).
#
#   This harness sources the REAL lib functions and stubs ONLY the two network
#   primitives (ssh_admin / tcp_check). A fake manager is driven through a reboot
#   so you can WATCH — and the script ASSERTS — the exact logic production runs.
#   Green here does NOT replace the one controlled real reboot the gate needs; it
#   is the cheap net that catches a logic bug BEFORE you touch a real manager.
#
# Safe by construction:
#   - touches no host (ssh/tcp are stubbed), writes only to a throwaway tmp dir,
#   - uses RFC 5737 documentation IPs (192.0.2.x), never real addresses,
#   - runs in a few seconds, exits non-zero if any scenario misbehaves.
#
# Usage (on your Ubuntu/WSL, from the repo root):
#   bash automations/manager_rolling_reboot/sim_reboot_wsl.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Isolate every artifact (logs/, run/, .ssh_keys/) in a throwaway dir so the
# simulation never writes inside the repo or a real automation's logs/.
SIM_TMP="$(mktemp -d -t nsx_sim_XXXXXX)"
export AUTO_DIR="${SIM_TMP}"
export NSX_NOTIFY_CONF="${SIM_TMP}/nonexistent.conf"   # guarantee no webhook side effects
trap 'rm -rf "${SIM_TMP}"' EXIT

# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=../../lib/nsx_manager.sh
source "${REPO_ROOT}/lib/nsx_manager.sh"

# Deterministic, fast timers. The lib loops terminate on their `waited<timeout`
# counters, so making sleep instant (below) does not break their termination.
export NSX_REBOOT_INTERVAL=1
export NSX_REBOOT_MAX_WAIT=20
export NSX_CLUSTER_STABLE_TIMEOUT=6
export NSX_CLUSTER_STABLE_INTERVAL=1

# ---------------------------------------------------------------------------
# Fake-manager state machine + stubs (override the real lib functions AFTER the
# libs are sourced, so every by-name call inside the lib resolves to these).
# ---------------------------------------------------------------------------
declare -A SIM_DOWN=()        # ip -> remaining "offline" probe ticks
declare -A SIM_NO_REBOOT=()   # ip -> 1: reboot verb is a no-op (box never drops)
declare -A SIM_NO_STABLE=()   # ip -> 1: cluster never reports STABLE
SIM_REBOOTS=0                 # count of reboot verbs issued (for assertions)

# Instant sleep — loops still exit via their waited<timeout guards.
sleep(){ :; }

# Stub SSH: we only care about two verbs the reboot cycle sends.
ssh_admin(){
  local ip="$1"; shift
  local cmd="$*"
  case "${cmd}" in
    *reboot*)
      SIM_REBOOTS=$(( SIM_REBOOTS + 1 ))
      if [[ "${SIM_NO_REBOOT[$ip]:-0}" != "1" ]]; then
        SIM_DOWN["$ip"]=3           # will read offline on the next few probes
      fi                             # else: verb "accepted" but box never drops
      ;;
    *"get cluster status"*)
      if [[ "${SIM_NO_STABLE[$ip]:-0}" == "1" ]]; then
        printf 'Cluster Status: DEGRADED\n'
      else
        printf 'Overall Status: STABLE\n'
      fi
      ;;
  esac
  return 0
}

# Stub TCP probe: offline while SIM_DOWN>0 (decrement per call), else online.
tcp_check(){
  local ip="$1"
  local n="${SIM_DOWN[$ip]:-0}"
  if (( n > 0 )); then
    SIM_DOWN["$ip"]=$(( n - 1 ))
    return 1     # offline
  fi
  return 0        # online
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
SIM_FAILS=0
assert_rc(){ # <expected> <actual> <label>
  if [[ "$1" == "$2" ]]; then
    log_ok "PASS: $3 (rc=$2)"
  else
    log_err "FAIL: $3 (expected rc=$1, got rc=$2)"; SIM_FAILS=$(( SIM_FAILS + 1 ))
  fi
}
assert_eq(){ # <expected> <actual> <label>
  if [[ "$1" == "$2" ]]; then
    log_ok "PASS: $3 (=$2)"
  else
    log_err "FAIL: $3 (expected $1, got $2)"; SIM_FAILS=$(( SIM_FAILS + 1 ))
  fi
}

# Fake managers.conf: one cluster of three documentation-IP managers.
SIM_CONF="${SIM_TMP}/managers.conf"
cat > "${SIM_CONF}" <<'EOF'
[SIM-DC]
hosts = 192.0.2.11, 192.0.2.12, 192.0.2.13
admin_user = admin
EOF
parse_managers_conf "${SIM_CONF}" >/dev/null

# --- Scenario 1: single manager, happy path --------------------------------
log_banner "SIM 1 - single manager, clean reboot (expect rc=0)"
before="${SIM_REBOOTS}"
rc=0; reboot_one_manager_by_ip 192.0.2.11 || rc=$?
assert_rc 0 "${rc}" "single manager down->up->STABLE"
assert_eq 1 "$(( SIM_REBOOTS - before ))" "exactly one reboot issued"

# --- Scenario 2: full cluster of 3, sequential (tonight's shape) ------------
log_banner "SIM 2 - full cluster of 3 managers, sequential (expect rc=0)"
export NSX_STATE_FILE="${SIM_TMP}/rolling_state"   # exercise resume bookkeeping
before="${SIM_REBOOTS}"
rc=0; rolling_reboot_cluster 0 || rc=$?
assert_rc 0 "${rc}" "cluster of 3 rebooted one-at-a-time"
assert_eq 3 "$(( SIM_REBOOTS - before ))" "exactly three reboots issued"
assert_eq "0" "$([[ -e "${NSX_STATE_FILE}" ]] && echo 1 || echo 0)" \
  "state file cleared after clean completion"
unset NSX_STATE_FILE

# --- Scenario 3: SAFETY TRAP - reboot verb no-ops --------------------------
log_banner "SIM 3 - reboot did NOT take effect (expect rc=1, no false success)"
SIM_NO_REBOOT[192.0.2.11]=1
rc=0; reboot_manager_and_wait 192.0.2.11 || rc=$?
assert_rc 1 "${rc}" "still-online manager aborts the cycle"
unset 'SIM_NO_REBOOT[192.0.2.11]'

# --- Scenario 4: cluster never reaches STABLE ------------------------------
log_banner "SIM 4 - cluster never STABLE after return (expect rc=1)"
SIM_NO_STABLE[192.0.2.12]=1
rc=0; reboot_manager_and_wait 192.0.2.12 || rc=$?
assert_rc 1 "${rc}" "STABLE timeout aborts the cycle"
unset 'SIM_NO_STABLE[192.0.2.12]'

# --- Summary ---------------------------------------------------------------
log_banner "SIM RESULT"
if (( SIM_FAILS == 0 )); then
  log_ok "All rolling-reboot scenarios behaved as designed."
  log "This proves the ORCHESTRATION logic. It does NOT prove the real NSX 'reboot'"
  log "verb — that still needs one controlled reboot of a real manager (TODO #2)."
  exit 0
else
  log_err "${SIM_FAILS} scenario(s) misbehaved — do NOT schedule a real reboot until this is green."
  exit 1
fi
