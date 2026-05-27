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
NSX_REBOOT_INTERVAL="${NSX_REBOOT_INTERVAL:-3600}"   # seconds between managers
NSX_REBOOT_MAX_WAIT="${NSX_REBOOT_MAX_WAIT:-900}"    # max wait for down/up
NSX_SSH_PORT="${NSX_SSH_PORT:-22}"

# ---------------------------------------------------------------------------
# SSH-key registration via NSX CLI.
# Uses NSX_PASS (admin password) for the one-time auth.
#
# register_manager_admin_key <ip> <pub_key_value> [label]
#   pub_key_value: the base64 portion (no "ssh-rsa "/"ssh-ed25519 " prefix
#                  and no trailing comment). Use `ensure_local_ssh_key`
#                  from common.sh to obtain it.
# ---------------------------------------------------------------------------
register_manager_admin_key(){
  local ip="$1"
  local pub_val="$2"
  local label="${3:-nsx-automation-key}"
  local user="${NSX_USER:-admin}"
  local result

  log "${ip}: registering SSH key (label='${label}', user='${user}')..."
  result="$(_sshpass_safe NSX_PASS ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${user}@${ip}" \
    "set user ${user} ssh-keys label ${label} type ssh-rsa value ${pub_val}" 2>&1 || true)"

  echo "  Return: ${result}"
  if echo "${result}" | grep -qiE "already exists|${label}|success"; then
    log_ok "${ip}: key registered."
    return 0
  fi
  log_warn "${ip}: unexpected response — review output above."
  return 1
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

  if tcp_check "$ip" "${NSX_SSH_PORT}"; then
    log_ok "${ip}: back online after ${waited}s."
    return 0
  fi
  log_err "${ip}: did NOT return within ${NSX_REBOOT_MAX_WAIT}s. INVESTIGATE."
  return 1
}

get_cluster_status(){ ssh_admin "$1" "get cluster status"; }
get_managers(){       ssh_admin "$1" "get managers"; }

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
      # init empty hosts array for this cluster
      eval "declare -ga CLUSTER_HOSTS_${current_idx}=()"
      continue
    fi

    if [[ "${current_idx}" -lt 0 ]]; then
      log_warn "Ignoring line outside section: ${line}"
      continue
    fi

    if [[ "${line}" =~ ^([a-zA-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      case "${key}" in
        hosts)
          # split on commas or whitespace
          local item
          for item in ${val//,/ }; do
            item="${item#"${item%%[![:space:]]*}"}"
            item="${item%"${item##*[![:space:]]}"}"
            [[ -z "${item}" ]] && continue
            eval "CLUSTER_HOSTS_${current_idx}+=(\"${item}\")"
          done
          ;;
        admin_user)
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
  local i hosts_var hosts_count user_var
  for (( i=0; i<CLUSTER_COUNT; i++ )); do
    hosts_var="CLUSTER_HOSTS_${i}[@]"
    user_var="CLUSTER_ADMIN_USER_${i}"
    hosts_count="$(eval "echo \${#CLUSTER_HOSTS_${i}[@]}")"
    log "  [${CLUSTER_LABELS[$i]}] user=${!user_var} hosts=${hosts_count}: $(eval "echo \"\${${hosts_var}}\"")"
  done
}

# Helper: echo the hosts array of a cluster by index, space-separated.
cluster_hosts(){
  local idx="$1"
  eval "echo \"\${CLUSTER_HOSTS_${idx}[@]}\""
}

cluster_admin_user(){
  local idx="$1"
  local var="CLUSTER_ADMIN_USER_${idx}"
  echo "${!var:-admin}"
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
# ---------------------------------------------------------------------------
rolling_reboot_cluster(){
  local idx="${1:?usage: rolling_reboot_cluster <idx>}"
  local label="${CLUSTER_LABELS[$idx]:-cluster-${idx}}"
  local hosts
  read -r -a hosts <<<"$(cluster_hosts "${idx}")"

  log_banner "[${label}] Rolling reboot — ${#hosts[@]} host(s)"

  local i last=$(( ${#hosts[@]} - 1 ))
  for i in "${!hosts[@]}"; do
    local ip="${hosts[$i]}"
    log "[${label}] reboot ${ip} ($((i+1))/${#hosts[@]})"
    reboot_manager_and_wait "${ip}" || log_err "[${label}] ${ip}: reboot cycle error"
    if (( i < last )); then
      log "[${label}] sleeping ${NSX_REBOOT_INTERVAL}s before next host..."
      sleep "${NSX_REBOOT_INTERVAL}"
    fi
  done

  log_ok "[${label}] rolling reboot done."
}
