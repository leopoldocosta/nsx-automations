#!/usr/bin/env bash
# lib/nsx_manager.sh — v1.0
# NSX Manager helpers on top of lib/common.sh.
# Adds: SSH-key registration via NSX CLI, reboot+wait cycle, and
# multi-cluster config parsing/cred handling.
#
# Requires lib/common.sh sourced first.

if ! declare -f log >/dev/null; then
  echo "[ERR] lib/common.sh must be sourced before lib/nsx_manager.sh" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Tunables (overridable by automation)
# ---------------------------------------------------------------------------
NSX_REBOOT_INTERVAL="${NSX_REBOOT_INTERVAL:-3600}"        # seconds between managers
NSX_REBOOT_MAX_WAIT="${NSX_REBOOT_MAX_WAIT:-900}"         # max wait for TCP down/up
NSX_CLUSTER_STABLE_TIMEOUT="${NSX_CLUSTER_STABLE_TIMEOUT:-600}"  # poll budget for STABLE
NSX_CLUSTER_STABLE_INTERVAL="${NSX_CLUSTER_STABLE_INTERVAL:-15}" # poll interval
NSX_SSH_PORT="${NSX_SSH_PORT:-22}"

# ---------------------------------------------------------------------------
# SSH-key registration via NSX CLI.
# Uses NSX_PASS (admin password) for the one-time auth.
#
# register_manager_admin_key <ip> <pub_key_value> [label] [key_type]
#   pub_key_value: the base64 portion (no "ssh-rsa "/"ssh-ed25519 " prefix
#                  and no trailing comment). Use `ensure_local_ssh_key`
#                  from common.sh to obtain it.
#   key_type     : NSX CLI type token. Default "ssh-rsa". Use "ssh-ed25519"
#                  for ed25519 keys.
#
# Returns:
#   0 — key registered now OR already present (idempotent OK)
#   1 — unexpected response from the NSX CLI
# ---------------------------------------------------------------------------
register_manager_admin_key(){
  local ip="$1"
  local pub_val="$2"
  local label="${3:-nsx-automation-key}"
  local key_type="${4:-ssh-rsa}"
  local user="${NSX_USER:-admin}"
  local result

  log "${ip}: registering SSH key (label='${label}', user='${user}', type='${key_type}')..."
  # Same strategy as the edge registrar (field-hardened on 2 DCs):
  #   1. modern syntax WITH the inline `password` parameter — some builds
  #      silently DISCARD the change on a non-TTY session without it
  #      (empty response, nothing stored);
  #   2. fallback to the stdin-feed variant when the build lacks the param;
  #   3. rc=255 (ssh auth/unreachable) reported as such, never as success;
  #   4. real BatchMode login verification at the end.
  local -a _to=()
  command -v timeout >/dev/null 2>&1 && _to=(timeout 30)
  local -a _ssh_base=(ssh
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
    -o LogLevel=ERROR
    "${user}@${ip}")

  local qpass rc=0
  qpass="${NSX_PASS//\\/\\\\}"; qpass="${qpass//\"/\\\"}"
  result="$(_sshpass_safe NSX_PASS "${_to[@]}" "${_ssh_base[@]}" \
    "set user ${user} ssh-keys label ${label} type ${key_type} value ${pub_val} password \"${qpass}\"" \
    </dev/null 2>&1)" || rc=$?

  if (( rc == 255 )); then
    log_err "${ip}: SSH as ${user} FAILED — wrong password or host unreachable (nothing was registered)."
    log "  Inherited credentials from the shell? Clear them:  unset NSX_PASS NSX_USER ROOT_PASS"
    return 1
  fi
  if echo "${result}" | grep -qi "command not found"; then
    result="$(_sshpass_safe NSX_PASS "${_to[@]}" "${_ssh_base[@]}" \
      "set user ${user} ssh-keys label ${label} type ${key_type} value ${pub_val}" \
      <<<"${NSX_PASS}" 2>&1 || true)"
  fi

  # Drop the noise the remote getpass fallback prints on a non-TTY session,
  # and never let the password leak into terminal/logs via a CLI error echo.
  result="$(echo "${result}" | grep -viE 'getpass|fallback_getpass|Password input may be echoed|Password \(required' || true)"
  [[ -n "${NSX_PASS:-}" ]] && result="${result//${NSX_PASS}/***}"

  echo "  Return: ${result:-<empty>}"
  if echo "${result}" | grep -qiE "invalid current password"; then
    log_err "${ip}: NSX rejected the ${user} password when confirming the change — check it and rerun."
    return 1
  fi
  if echo "${result}" | grep -qiE "already exists|duplicate"; then
    log_ok "${ip}: key already registered (no-op)."
  elif echo "${result}" | grep -qiE "${label}|success" || [[ -z "${result}" ]]; then
    log_ok "${ip}: key registered."
  else
    log_warn "${ip}: unexpected response — review output above."
    return 1
  fi

  # Trust the lock, verify the door: BatchMode login with the just-registered
  # key is the only real proof (CLI can accept and store nothing).
  local priv="${SSH_PRIV:-${HOME}/.ssh/id_rsa}"
  if [[ -f "${priv}" ]]; then
    sleep 2
    if ssh -i "${priv}" -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR \
        "${user}@${ip}" "exit" </dev/null &>/dev/null; then
      log_ok "${ip}: ${user} key VERIFIED (BatchMode login ok)."
    else
      log_warn "${ip}: CLI accepted the key but a key-only login still fails — inspect with: ssh ${user}@${ip} then 'get user ${user} ssh-keys'"
      log "  Stored value differs from your key? On the device: del user ${user} ssh-keys label ${label} — then rerun."
      log "  Value matches? Check algorithm policy: ssh -v -i <key> ${user}@${ip} exit 2>&1 | grep -i 'no mutual'"
      return 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Quick SSH-key reachability test.
# ---------------------------------------------------------------------------
test_ssh_admin(){
  local ip="$1"
  ssh -i "${ADMIN_KEY:-${HOME}/.ssh/id_rsa}" \
      -o BatchMode=yes \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 \
      -o LogLevel=ERROR \
      "${NSX_USER:-admin}@${ip}" "get managers" &>/dev/null
}

# ---------------------------------------------------------------------------
# Reboot a manager and wait for it to drop and return via TCP probe.
# Logs the full cycle. Returns 0 on success, 1 if the host did not return.
# ---------------------------------------------------------------------------
reboot_manager_and_wait(){
  local ip="$1"
  local waited=0

  log "[START] Rebooting ${ip}..."
  ssh_admin "$ip" "reboot" || true

  log "[WAITING] ${ip} to drop offline..."
  while tcp_check "$ip" "${NSX_SSH_PORT}" && [ $waited -lt "${NSX_REBOOT_MAX_WAIT}" ]; do
    sleep 5; waited=$((waited + 5))
  done

  if tcp_check "$ip" "${NSX_SSH_PORT}"; then
    log_warn "${ip}: did not drop offline after ${NSX_REBOOT_MAX_WAIT}s."
  else
    log "[DOWN] ${ip} offline. Waiting for return..."
  fi

  waited=0
  while ! tcp_check "$ip" "${NSX_SSH_PORT}" && [ $waited -lt "${NSX_REBOOT_MAX_WAIT}" ]; do
    sleep 10; waited=$((waited + 10))
  done

  if ! tcp_check "$ip" "${NSX_SSH_PORT}"; then
    log_err "${ip}: did NOT return within ${NSX_REBOOT_MAX_WAIT}s. INVESTIGATE."
    return 1
  fi
  log_ok "${ip}: TCP back online after ${waited}s."

  # Cluster-level gate: TCP up does not imply the cluster has reconciled.
  # This is exactly the failure mode KB 396719 mitigates — moving to the
  # next manager before the previous one has rejoined.
  if [[ "${NSX_SKIP_CLUSTER_GATE:-0}" == "1" ]]; then
    log_warn "${ip}: NSX_SKIP_CLUSTER_GATE=1 — skipping cluster STABLE check."
    return 0
  fi
  wait_cluster_stable "$ip" || return 1
  return 0
}

get_cluster_status(){ ssh_admin "$1" "get cluster status"; }
get_managers(){       ssh_admin "$1" "get managers"; }

# ---------------------------------------------------------------------------
# wait_cluster_stable <ip> [timeout] [interval]
#   Polls `get cluster status` on <ip> until the overall status reports
#   STABLE (NSX 3.x/4.x) or, as a fallback, every line contains "UP".
#   Defaults from NSX_CLUSTER_STABLE_TIMEOUT / NSX_CLUSTER_STABLE_INTERVAL.
#   Returns 0 on STABLE, 1 on timeout.
# ---------------------------------------------------------------------------
wait_cluster_stable(){
  local ip="${1:?usage: wait_cluster_stable <ip>}"
  local timeout="${2:-${NSX_CLUSTER_STABLE_TIMEOUT}}"
  local interval="${3:-${NSX_CLUSTER_STABLE_INTERVAL}}"
  local waited=0 out

  log "[CLUSTER] ${ip}: waiting for STABLE (timeout ${timeout}s, poll ${interval}s)..."
  while (( waited < timeout )); do
    out="$(get_cluster_status "$ip" 2>/dev/null || true)"
    if [[ -n "${out}" ]]; then
      # Primary signal: "Overall Status: STABLE" / "Cluster Status: STABLE"
      if echo "${out}" | grep -qiE '(overall|cluster)[[:space:]]*status[[:space:]]*:[[:space:]]*stable'; then
        log_ok "[CLUSTER] ${ip}: STABLE after ${waited}s."
        return 0
      fi
      # Fallback: degraded/down/joining anywhere — keep waiting
      if echo "${out}" | grep -qiE 'degraded|unstable|down|joining|unavailable'; then
        :
      elif echo "${out}" | grep -qi 'stable'; then
        log_ok "[CLUSTER] ${ip}: STABLE (fallback match) after ${waited}s."
        return 0
      fi
    fi
    sleep "${interval}"
    waited=$(( waited + interval ))
  done
  log_err "[CLUSTER] ${ip}: did NOT reach STABLE within ${timeout}s. INVESTIGATE."
  return 1
}

# ---------------------------------------------------------------------------
# Multi-cluster config parser (INI-style sections)
#
#   parse_managers_conf <file>
#
# Populates globals:
#   CLUSTER_COUNT                   - number of clusters
#   CLUSTER_LABELS[i]               - the section name
#   CLUSTER_ADMIN_USER_<i>          - "admin_user = ..." value (default "admin")
#   CLUSTER_HOSTS_<i>[]             - array with host IPs
#
# Example:
#   [GER1]
#   hosts = 192.168.20.10, 192.168.20.11, 192.168.20.12
#   admin_user = admin
# ---------------------------------------------------------------------------
parse_managers_conf(){
  local file="${1:?usage: parse_managers_conf <file>}"
  [[ -f "${file}" ]] || { log_err "Config not found: ${file}"; return 1; }

  # Reset
  unset CLUSTER_LABELS
  declare -ga CLUSTER_LABELS=()
  CLUSTER_COUNT=0

  local current_idx=-1 current_label=""
  local line key val

  while IFS= read -r line || [[ -n "${line}" ]]; do
    # strip comments and trim
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]] && continue

    if [[ "${line}" =~ ^\[(.+)\]$ ]]; then
      current_idx=$(( current_idx + 1 ))
      current_label="${BASH_REMATCH[1]}"
      CLUSTER_LABELS[$current_idx]="${current_label}"
      # default admin_user (override below if specified)
      declare -g "CLUSTER_ADMIN_USER_${current_idx}=admin"
      # init empty hosts array for this cluster via nameref (no eval)
      declare -ga "CLUSTER_HOSTS_${current_idx}=()"
      continue
    fi

    if [[ "${current_idx}" -lt 0 ]]; then
      log_warn "Ignoring line outside section: ${line} — did you forget the [CLUSTER] header above it?"
      continue
    fi

    if [[ "${line}" =~ ^([a-zA-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      case "${key}" in
        hosts)
          # Nameref to the cluster's hosts array — avoids eval entirely.
          # shellcheck disable=SC2178   # _hosts_ref is a nameref, inherits array type
          local -n _hosts_ref="CLUSTER_HOSTS_${current_idx}"
          local item
          for item in ${val//,/ }; do
            item="${item#"${item%%[![:space:]]*}"}"
            item="${item%"${item##*[![:space:]]}"}"
            [[ -z "${item}" ]] && continue
            # Defense in depth: accept IPv4 dotted quad OR hostname starting
            # with an alphanumeric and containing only [A-Za-z0-9.-].
            # This rejects shell metacharacters AND tokens like "rm" / "-rf"
            # that could leak from a malformed conf.
            if [[ "${item}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
              :   # IPv4 — accept
            elif [[ "${item}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] \
                 && [[ "${item}" == *.* ]]; then
              :   # FQDN-ish (must contain a dot) — accept
            else
              log_warn "Skipping invalid host entry in [${current_label}]: ${item}"
              continue
            fi
            _hosts_ref+=("${item}")
          done
          unset -n _hosts_ref
          ;;
        admin_user)
          # Defense in depth: usernames are alnum + _ - .
          if [[ ! "${val}" =~ ^[A-Za-z0-9._-]+$ ]]; then
            log_warn "Skipping suspicious admin_user in [${current_label}]: ${val}"
            continue
          fi
          declare -g "CLUSTER_ADMIN_USER_${current_idx}=${val}"
          ;;
        *)
          log_warn "Unknown key '${key}' in [${current_label}]"
          ;;
      esac
    fi
  done < "${file}"

  CLUSTER_COUNT=$(( current_idx + 1 ))
  if [[ "${CLUSTER_COUNT}" -eq 0 ]]; then
    log_err "No clusters parsed from ${file}."
    return 1
  fi

  log_ok "Parsed ${CLUSTER_COUNT} cluster(s) from ${file}:"
  local i user_var
  for (( i=0; i<CLUSTER_COUNT; i++ )); do
    # shellcheck disable=SC2178   # _hosts_view is a nameref, inherits array type
    local -n _hosts_view="CLUSTER_HOSTS_${i}"
    user_var="CLUSTER_ADMIN_USER_${i}"
    log "  [${CLUSTER_LABELS[$i]}] user=${!user_var} hosts=${#_hosts_view[@]}: ${_hosts_view[*]}"
    unset -n _hosts_view
  done
}

# Helper: echo the hosts array of a cluster by index, space-separated.
cluster_hosts(){
  local idx="$1"
  # shellcheck disable=SC2178   # _hosts_ref is a nameref, inherits array type
  local -n _hosts_ref="CLUSTER_HOSTS_${idx}"
  echo "${_hosts_ref[*]}"
}

cluster_admin_user(){
  local idx="$1"
  local var="CLUSTER_ADMIN_USER_${idx}"
  echo "${!var:-admin}"
}

# ---------------------------------------------------------------------------
# find_cluster_for_ip <ip>
#   Echoes the cluster index whose CLUSTER_HOSTS_<i> contains <ip>.
#   Returns 0 on hit, 1 if not found. Assumes parse_managers_conf has run.
# ---------------------------------------------------------------------------
find_cluster_for_ip(){
  local ip="${1:?usage: find_cluster_for_ip <ip>}"
  local i h
  for (( i=0; i<CLUSTER_COUNT; i++ )); do
    # shellcheck disable=SC2178   # nameref to cluster array
    local -n _hosts_ref="CLUSTER_HOSTS_${i}"
    for h in "${_hosts_ref[@]}"; do
      if [[ "${h}" == "${ip}" ]]; then
        unset -n _hosts_ref
        echo "${i}"
        return 0
      fi
    done
    unset -n _hosts_ref
  done
  return 1
}

# ---------------------------------------------------------------------------
# reboot_one_manager_by_ip <ip>
#   Wrapper used by --only mode: locates the cluster <ip> belongs to,
#   exports the right NSX_USER, then runs the standard reboot+wait+STABLE
#   cycle. Honors NSX_DRY_RUN=1.
#   Returns 0 on success, 1 on misconfig or reboot failure.
# ---------------------------------------------------------------------------
reboot_one_manager_by_ip(){
  local ip="${1:?usage: reboot_one_manager_by_ip <ip>}"
  local cidx
  if ! cidx="$(find_cluster_for_ip "${ip}")"; then
    log_err "IP ${ip} not found in any cluster of the parsed managers.conf."
    return 1
  fi
  local user; user="$(cluster_admin_user "${cidx}")"
  export NSX_USER="${user}"
  log "[ONLY] manager=${ip} cluster=[${CLUSTER_LABELS[$cidx]}] user=${user}"

  if [[ "${NSX_DRY_RUN:-0}" == "1" ]]; then
    log "[DRY-RUN] [${CLUSTER_LABELS[$cidx]}] would reboot ${ip}"
    return 0
  fi
  reboot_manager_and_wait "${ip}"
}

# ---------------------------------------------------------------------------
# Per-cluster credential prompt and scoped execution.
# Credentials live in arrays keyed by index:
#   CLUSTER_ADMIN_PASS_<i>
#   CLUSTER_ROOT_PASS_<i>
# ---------------------------------------------------------------------------
ask_cluster_creds(){
  local idx="${1:?usage: ask_cluster_creds <idx>}"
  local label="${CLUSTER_LABELS[$idx]:-cluster-${idx}}"
  local user_var="CLUSTER_ADMIN_USER_${idx}"
  local user="${!user_var:-admin}"

  echo ""
  echo "--- Credentials for cluster [${label}] (admin user: ${user}) ---"
  local apass rpass
  IFS= read -rsp "  Admin password for ${user}@${label}: " apass </dev/tty; printf '\n' >/dev/tty
  IFS= read -rsp "  Root password for ${label}: "          rpass </dev/tty; printf '\n' >/dev/tty
  declare -g "CLUSTER_ADMIN_PASS_${idx}=${apass}"
  declare -g "CLUSTER_ROOT_PASS_${idx}=${rpass}"
  log "  Credentials stored for [${label}]."
}

# with_cluster_creds <idx> <fn> [args...]
#   Exports NSX_USER, NSX_PASS, ROOT_PASS based on the cluster's stored
#   credentials, then invokes <fn>. Restores previous values after.
with_cluster_creds(){
  local idx="${1:?usage: with_cluster_creds <idx> <fn> [args...]}"; shift
  local fn="${1:?missing fn}"; shift

  local prev_user="${NSX_USER:-}"
  local prev_pass="${NSX_PASS:-}"
  local prev_root="${ROOT_PASS:-}"

  local user_var="CLUSTER_ADMIN_USER_${idx}"
  local apass_var="CLUSTER_ADMIN_PASS_${idx}"
  local rpass_var="CLUSTER_ROOT_PASS_${idx}"

  export NSX_USER="${!user_var:-admin}"
  export NSX_PASS="${!apass_var:-}"
  export ROOT_PASS="${!rpass_var:-}"

  "${fn}" "$@"
  local rc=$?

  export NSX_USER="${prev_user}"
  export NSX_PASS="${prev_pass}"
  export ROOT_PASS="${prev_root}"
  return $rc
}

# ---------------------------------------------------------------------------
# rolling_reboot_cluster <idx>
#   Reboots each host of the cluster sequentially, with NSX_REBOOT_INTERVAL
#   between reboots. Honors NSX_REBOOT_MAX_WAIT for down/up window.
#   Assumes NSX_USER is already set (typically via with_cluster_creds).
#
#   Env flags (read by caller; passed via env):
#     NSX_DRY_RUN=1    — print the plan, do not reboot.
#     NSX_RESUME_FROM  — host IP to start from (skip earlier hosts in cluster).
#     NSX_STATE_FILE   — if set, write "<idx>|<host_idx>|<ip>|<ts>" before
#                        each reboot; remove on success.
# ---------------------------------------------------------------------------
rolling_reboot_cluster(){
  local idx="${1:?usage: rolling_reboot_cluster <idx>}"
  local label="${CLUSTER_LABELS[$idx]:-cluster-${idx}}"
  local hosts
  read -r -a hosts <<<"$(cluster_hosts "${idx}")"

  log_banner "[${label}] Rolling reboot — ${#hosts[@]} host(s)"

  local resume_from="${NSX_RESUME_FROM:-}"
  local skipping=false
  if [[ -n "${resume_from}" ]]; then
    skipping=true
    log_warn "[${label}] resume mode: skipping until host '${resume_from}' is reached."
  fi

  local i last=$(( ${#hosts[@]} - 1 ))
  for i in "${!hosts[@]}"; do
    local ip="${hosts[$i]}"

    if "${skipping}"; then
      if [[ "${ip}" == "${resume_from}" ]]; then
        skipping=false
        log "[${label}] resume: starting at ${ip}."
      else
        log "[${label}] resume: skipping ${ip} (already done in previous run)."
        continue
      fi
    fi

    if [[ "${NSX_DRY_RUN:-0}" == "1" ]]; then
      log "[DRY-RUN] [${label}] would reboot ${ip} ($((i+1))/${#hosts[@]})"
      if (( i < last )); then
        log "[DRY-RUN] [${label}] would then sleep ${NSX_REBOOT_INTERVAL}s"
      fi
      continue
    fi

    # Resume bookkeeping
    if [[ -n "${NSX_STATE_FILE:-}" ]]; then
      printf '%s|%s|%s|%s\n' "${idx}" "${i}" "${ip}" "$(date +%s)" > "${NSX_STATE_FILE}"
    fi

    log "[${label}] reboot ${ip} ($((i+1))/${#hosts[@]})"
    reboot_manager_and_wait "${ip}" || log_err "[${label}] ${ip}: reboot cycle error"

    if (( i < last )); then
      log "[${label}] sleeping ${NSX_REBOOT_INTERVAL}s before next host..."
      sleep "${NSX_REBOOT_INTERVAL}"
    fi
  done

  if "${skipping}"; then
    log_warn "[${label}] resume target '${resume_from}' not found in this cluster — nothing done."
  fi

  log_ok "[${label}] rolling reboot done."
  # Clear state once a cluster finishes cleanly.
  [[ -n "${NSX_STATE_FILE:-}" && -f "${NSX_STATE_FILE}" ]] && rm -f "${NSX_STATE_FILE}"
}
