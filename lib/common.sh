#!/usr/bin/env bash
# lib/common.sh — v1.0
# Generic, type-agnostic helpers for all NSX automations.
#
# Source this first. Then optionally source one of:
#   - lib/nsx_edge.sh
#   - lib/nsx_manager.sh
#
# Recommended preamble in any automation/helper script:
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   export AUTO_DIR="${SCRIPT_DIR}"
#   export HOST_FILE="${SCRIPT_DIR}/<hosts>.txt"
#   export HOST_EXAMPLE="${SCRIPT_DIR}/<hosts>.example"
#   # source the libs (path varies if invoked from automations/<name>/)
#   source "${REPO_ROOT}/lib/common.sh"
#
# Layout:
#   AUTO_DIR : where logs/, run/, .ssh_keys/ are created (per automation)
#   HOST_FILE: file with one IP per line, ignored by git
#   HOST_EXAMPLE: committed template, copied by user to HOST_FILE

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${LIB_DIR}/.." && pwd)}"

AUTO_DIR="${AUTO_DIR:-$(pwd)}"

LOG_DIR="${AUTO_DIR}/logs"
RUN_DIR="${AUTO_DIR}/run"
KEY_DIR="${AUTO_DIR}/.ssh_keys"

HOST_FILE="${HOST_FILE:-${AUTO_DIR}/hosts.txt}"
HOST_EXAMPLE="${HOST_EXAMPLE:-${AUTO_DIR}/hosts.example}"

ADMIN_KEY="${ADMIN_KEY:-${KEY_DIR}/nsx_admin_key}"
ROOT_KEY="${ROOT_KEY:-${KEY_DIR}/nsx_root_key}"

mkdir -p "${LOG_DIR}" "${RUN_DIR}" "${KEY_DIR}"

# ---------------------------------------------------------------------------
# Colors (auto-disabled when stdout is not a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m';   C_BOLD=$'\033[1m'
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_RED=$'\033[0;31m';   C_CYAN=$'\033[0;36m'
  C_BLUE=$'\033[0;34m'
else
  C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''
  C_RED='';   C_CYAN=''; C_BLUE=''
fi

# ---------------------------------------------------------------------------
# Logging (color-aware, timestamped)
# ---------------------------------------------------------------------------
log()      { printf '%s[%s]%s %s\n'           "${C_CYAN}"    "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_ok()   { printf '%s[%s] [OK]%s   %s\n'    "${C_GREEN}"   "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_warn() { printf '%s[%s] [WARN]%s %s\n'    "${C_YELLOW}"  "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_err()  {
  printf '%s[%s] [ERR]%s  %s\n' "${C_RED}" "$(date '+%F %T')" "${C_RESET}" "$*"
  # Optional outbound notification on errors (Slack/Teams-compatible webhook).
  # Opt-in via NSX_NOTIFY_WEBHOOK=<url>. We never block on this — failures are
  # silent so an unavailable webhook doesn't mask the original error.
  if [[ -n "${NSX_NOTIFY_WEBHOOK:-}" ]] && command -v curl >/dev/null 2>&1; then
    local _host; _host="$(hostname 2>/dev/null || echo unknown)"
    local _payload
    _payload="$(printf '{"text":"[NSX][%s] ERR: %s"}' "${_host}" "$*" | sed 's/[[:cntrl:]]//g')"
    curl -sS -X POST -H 'Content-Type: application/json' \
      --max-time 5 --data "${_payload}" \
      "${NSX_NOTIFY_WEBHOOK}" >/dev/null 2>&1 || true
  fi
}

log_banner(){
  local title="${1:-}"
  local width=76
  local pad=$(( (width - ${#title} - 2) / 2 ))
  (( pad < 0 )) && pad=0
  printf '\n%s' "${C_BOLD}${C_BLUE}"
  printf '+'; printf '%0.s-' $(seq 1 $width); printf '+\n'
  printf '|%*s%s%*s|\n' $pad '' "$title" $pad ''
  printf '+'; printf '%0.s-' $(seq 1 $width); printf '+\n'
  printf '%s\n' "${C_RESET}"
}

# ---------------------------------------------------------------------------
# Box-drawing table helpers (ASCII-safe).
# Columns: NODE(19) STATUS(18) ACTION(18) FILE(18) DURATION(12)
# ---------------------------------------------------------------------------
tbl_header(){
  local title="${1:-Status}"
  printf '+--------------------------------------------------------------------------------------------+\n'
  printf '| %-90s |\n' "${title}  $(date '+%F %T')"
  printf '+---------------------+--------------------+--------------------+--------------------+--------------+\n'
  printf '| %-19s | %-18s | %-18s | %-18s | %-12s |\n' 'NODE' 'STATUS' 'ACTION' 'FILE' 'DURATION'
  printf '+---------------------+--------------------+--------------------+--------------------+--------------+\n'
}

tbl_row(){
  # $1=node $2=status $3=action $4=file $5=duration
  printf '| %-19s | %-18s | %-18s | %-18s | %-12s |\n' \
    "$1" "${2:0:18}" "${3:0:18}" "${4:0:18}" "${5:0:12}"
}

tbl_footer(){
  printf '+---------------------+--------------------+--------------------+--------------------+--------------+\n\n'
}

# ---------------------------------------------------------------------------
# Dependency / OS helpers
# ---------------------------------------------------------------------------
need_cmd(){
  command -v "$1" >/dev/null 2>&1 || { log_err "Missing required command: $1"; exit 1; }
}

# Echoes the package-manager binary appropriate for the current distro.
detect_pkg_manager(){
  local distro="unknown"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    distro="$(echo "${ID:-unknown}" | tr '[:upper:]' '[:lower:]')"
  fi
  case "${distro}" in
    ubuntu|debian)                              echo "apt" ;;
    rhel|centos|rocky|almalinux|fedora|ol|oracle) echo "dnf" ;;
    sles|opensuse*)                             echo "zypper" ;;
    *)                                          echo "" ;;
  esac
}

# install_pkg <names...> - distro-aware install using sudo. Idempotent enough.
install_pkg(){
  local pkg
  pkg="$(detect_pkg_manager)"
  if [[ -z "${pkg}" ]]; then
    log_err "Unsupported distro. Install manually: $*"
    return 1
  fi
  case "${pkg}" in
    apt)
      sudo apt-get update -y
      sudo apt-get install -y "$@"
      ;;
    dnf)
      sudo dnf install -y "$@" 2>/dev/null || sudo yum install -y "$@"
      ;;
    zypper)
      sudo zypper install -y "$@"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Local SSH key helpers (the key used FROM the jump host)
# ---------------------------------------------------------------------------
# ensure_local_ssh_key <private_path> [type]
#   - Generates an SSH key pair if missing (default type: ed25519)
#   - Extracts the .pub if missing
#   - Echoes the base64-encoded public key value (the field after "ssh-rsa "
#     or "ssh-ed25519 "), suitable for `set user admin ssh-keys label … value …`
ensure_local_ssh_key(){
  local privkey="${1:?usage: ensure_local_ssh_key <path> [type]}"
  local ktype="${2:-ed25519}"
  local pubkey="${privkey}.pub"

  mkdir -p "$(dirname "${privkey}")"
  chmod 700 "$(dirname "${privkey}")" 2>/dev/null || true

  if [[ ! -f "${privkey}" ]]; then
    log "Generating ${ktype} key pair at ${privkey}..."
    if [[ "${ktype}" == "rsa" ]]; then
      ssh-keygen -t rsa -b 2048 -f "${privkey}" -N "" -C "nsx-automation" -q
    else
      ssh-keygen -t ed25519 -f "${privkey}" -N "" -C "nsx-automation" -q
    fi
  fi

  if [[ ! -f "${pubkey}" ]]; then
    log "Extracting public key..."
    ssh-keygen -y -f "${privkey}" > "${pubkey}"
  fi

  awk '{print $2}' "${pubkey}"
}

# ---------------------------------------------------------------------------
# Host/IP list (generic — same code for edges or managers)
# ---------------------------------------------------------------------------
collect_ips(){
  if [[ -f "${HOST_EXAMPLE}" ]]; then
    echo "  Template available: ${HOST_EXAMPLE}"
    echo "  Copy: cp $(basename "${HOST_EXAMPLE}") $(basename "${HOST_FILE}"); edit; rerun."
    echo "  Or paste IPs below."
  fi
  echo ""
  echo "Paste IPs, one per line. Empty line to finish:"
  : > "${HOST_FILE}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && break
    [[ "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$line" >> "${HOST_FILE}"
    else
      log_warn "Skipping invalid entry: ${line}"
    fi
  done
  local count
  count=$(wc -l < "${HOST_FILE}" | tr -d ' ')
  log "${count} IP(s) saved to ${HOST_FILE}"
}

load_ips(){
  if [[ ! -s "${HOST_FILE}" ]]; then
    log_warn "${HOST_FILE} not found or empty."
    collect_ips
  fi
  mapfile -t HOST_IPS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "${HOST_FILE}" 2>/dev/null || true)
  if [[ ${#HOST_IPS[@]} -eq 0 ]]; then
    log_err "No valid IPs found in ${HOST_FILE}."
    exit 1
  fi
  log "Loaded ${#HOST_IPS[@]} host(s): ${HOST_IPS[*]}"
  export HOST_IPS
}

# ---------------------------------------------------------------------------
# Credentials (admin user — same for edges and managers)
# ---------------------------------------------------------------------------
ask_admin_creds(){
  if [[ -n "${NSX_PASS:-}" ]]; then
    log "Admin credentials already loaded (user: '${NSX_USER:-admin}')."
    return 0
  fi
  IFS= read -rp 'Admin username [admin]: ' NSX_USER </dev/tty
  NSX_USER="${NSX_USER:-admin}"
  IFS= read -rsp 'Admin password (all special characters accepted): ' NSX_PASS </dev/tty; printf '\n' >/dev/tty
  export NSX_USER NSX_PASS
  log "Admin credentials collected for user '${NSX_USER}'."
}

reprompt_admin_creds(){
  log_warn "Re-prompting admin credentials..."
  unset NSX_PASS NSX_USER
  ask_admin_creds
}

clear_creds(){
  unset NSX_PASS ROOT_PASS NSX_USER 2>/dev/null || true
  log "Credentials cleared from memory."
}

# confirm_clear_creds_with_timeout <seconds>
#   Prompts Y/n; default Y if no input within <seconds>. Then clears or keeps.
confirm_clear_creds_with_timeout(){
  local timeout="${1:-30}"
  local answer
  printf '\n' >/dev/tty
  if IFS= read -r -t "${timeout}" -p "Clear credentials from environment? [Y/n] (auto-yes in ${timeout}s): " answer </dev/tty; then
    printf '\n' >/dev/tty
  else
    printf '\n' >/dev/tty
    log "No response — clearing credentials automatically."
    answer="y"
  fi
  case "${answer,,}" in
    n|no) log "Credentials retained in environment." ;;
    *)    clear_creds ;;
  esac
}

# ---------------------------------------------------------------------------
# Session file (persist creds to a tmpfile so other scripts can resume).
# Auto-cleared by auto_clear_session_after.
# ---------------------------------------------------------------------------
SESSION_FILE_DEFAULT="${RUN_DIR}/session.env"

save_session_env(){
  local target="${1:-${SESSION_FILE_DEFAULT}}"
  umask 077
  : > "${target}"
  [[ -n "${NSX_USER:-}" ]] && printf 'export NSX_USER=%q\n' "${NSX_USER}" >> "${target}"
  [[ -n "${NSX_PASS:-}" ]] && printf 'export NSX_PASS=%q\n' "${NSX_PASS}" >> "${target}"
  [[ -n "${ROOT_PASS:-}" ]] && printf 'export ROOT_PASS=%q\n' "${ROOT_PASS}" >> "${target}"
  log "Session env saved to ${target} (mode 600)."
}

load_session_env(){
  local source_file="${1:-${SESSION_FILE_DEFAULT}}"
  if [[ -f "${source_file}" ]]; then
    # shellcheck disable=SC1090
    source "${source_file}"
    log "Session env loaded from ${source_file}."
    return 0
  fi
  return 1
}

# auto_clear_session_after <epoch_seconds> [session_file]
#   Spawns a background watcher that deletes the session file at the given epoch.
auto_clear_session_after(){
  local expiry_epoch="${1:?usage: auto_clear_session_after <epoch> [file]}"
  local target="${2:-${SESSION_FILE_DEFAULT}}"
  (
    while [[ "$(date +%s)" -lt "${expiry_epoch}" ]]; do sleep 5; done
    rm -f "${target}" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# sshpass safe wrapper — writes password to a private tmp file (mode 600),
# then passes via SSHPASS env. Never visible in process args.
# ---------------------------------------------------------------------------
_sshpass_safe(){
  local _passvar="$1"; shift
  local _pass="${!_passvar}"
  local _tmpfile
  _tmpfile="$(mktemp -t sshpass_XXXXXX)"
  chmod 600 "${_tmpfile}"
  printf '%s' "${_pass}" > "${_tmpfile}"
  SSHPASS="$(cat "${_tmpfile}")" sshpass -e "$@"
  local _rc=$?
  rm -f "${_tmpfile}"
  return $_rc
}

# ---------------------------------------------------------------------------
# Base SSH as admin (works for edge AND manager NSX CLI).
# Uses ADMIN_KEY when present, falls back to NSX_PASS via sshpass.
#
# Stderr is silenced by default for clean stdout capture. Set NSX_DEBUG=1
# in the environment to let SSH's stderr through — useful when diagnosing
# host-key mismatches, MaxAuthTries, kex resets, etc.
# ---------------------------------------------------------------------------
# _ssh_stderr_redir — internal helper. Echoes the redirection token to apply
# to ssh's stderr. Honors NSX_DEBUG=1.
_ssh_stderr_redir(){
  if [[ "${NSX_DEBUG:-0}" == "1" ]]; then
    printf '%s' "/dev/stderr"
  else
    printf '%s' "/dev/null"
  fi
}

ssh_admin(){
  local ip="$1"; shift
  local _err; _err="$(_ssh_stderr_redir)"
  if [[ -f "${ADMIN_KEY}" ]]; then
    ssh -i "${ADMIN_KEY}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        -o LogLevel=ERROR \
        "${NSX_USER:-admin}@${ip}" "$@" 2>>"${_err}"
  else
    _sshpass_safe NSX_PASS ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o LogLevel=ERROR \
        "${NSX_USER:-admin}@${ip}" "$@" 2>>"${_err}"
  fi
}

admin_cmd(){ local ip="$1" cmd="$2"; ssh_admin "$ip" "$cmd"; }

# ---------------------------------------------------------------------------
# TCP reachability probe (no SSH — bash builtin /dev/tcp).
# Usage: tcp_check <ip> [port]    (default 22)
# ---------------------------------------------------------------------------
tcp_check(){
  local ip="$1" port="${2:-22}"
  timeout 2 bash -c "</dev/tcp/${ip}/${port}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Crontab helper — idempotent install/replace of a line whose command matches.
#
#   install_crontab_line "<cron-expr>" "<command>"
#
# Removes any existing crontab line containing <command> (substring match)
# and appends the new one.
# ---------------------------------------------------------------------------
install_crontab_line(){
  local expr="${1:?usage: install_crontab_line <expr> <command>}"
  local cmd="${2:?usage: install_crontab_line <expr> <command>}"
  ( crontab -l 2>/dev/null | grep -vF "${cmd}"; echo "${expr} ${cmd}" ) | crontab -
  log_ok "Crontab line installed: ${expr} ${cmd}"
}

remove_crontab_line(){
  local cmd="${1:?usage: remove_crontab_line <command>}"
  crontab -l 2>/dev/null | grep -vF "${cmd}" | crontab -
  log_ok "Crontab line removed (matching '${cmd}')."
}

# ---------------------------------------------------------------------------
# ssh_admin_retry <ip> <cmd> [retries] [base_backoff_seconds]
#   Read-only retry wrapper around ssh_admin. Backs off linearly
#   (base, 2*base, 3*base, ...). Echoes stdout of the first success.
#   Returns 0 on success, 1 if all attempts fail.
#
# Defaults: 3 retries, 5s base. Use sparingly — do NOT wrap destructive
# commands like `reboot`, since this may submit them multiple times.
# ---------------------------------------------------------------------------
ssh_admin_retry(){
  local ip="${1:?usage: ssh_admin_retry <ip> <cmd> [retries] [base]}"
  local cmd="${2:?missing cmd}"
  local retries="${3:-3}"
  local base="${4:-5}"
  local attempt=1 out
  while (( attempt <= retries )); do
    if out="$(ssh_admin "${ip}" "${cmd}")" && [[ -n "${out}" ]]; then
      printf '%s' "${out}"
      return 0
    fi
    if (( attempt < retries )); then
      local wait_s=$(( base * attempt ))
      log_warn "${ip}: '${cmd}' attempt ${attempt}/${retries} failed — backing off ${wait_s}s"
      sleep "${wait_s}"
    fi
    attempt=$(( attempt + 1 ))
  done
  log_err "${ip}: '${cmd}' failed after ${retries} attempts."
  return 1
}

# ---------------------------------------------------------------------------
# Multi-datacenter inventory parser (INI-style sections)
#
#   parse_datacenters_conf <file>
#
# Schema per section:
#   [DC-LABEL]
#   jump_host = <fqdn-or-ip>          # required
#   jump_user = <username>            # required
#   repo_path = </abs/path/on/jump>   # required (where nsx-automations is checked out)
#   ssh_key   = </abs/path/on/orchestrator>   # optional; default ~/.ssh/nsx_dc_fanout
#
# Populates globals:
#   DC_COUNT                  - number of datacenters
#   DC_LABELS[i]              - the section name
#   DC_JUMP_HOST_<i>          - jump host (validated against IPv4 OR FQDN-like)
#   DC_JUMP_USER_<i>          - SSH user (validated against [A-Za-z0-9._-]+)
#   DC_REPO_PATH_<i>          - absolute path to the toolkit on the jump
#   DC_SSH_KEY_<i>            - private key to use for orchestrator->jump SSH
#
# Defensive: rejects shell metacharacters in every field — the values flow
# into ssh/rsync command lines on the orchestrator.
# ---------------------------------------------------------------------------
parse_datacenters_conf(){
  local file="${1:?usage: parse_datacenters_conf <file>}"
  [[ -f "${file}" ]] || { log_err "Datacenters config not found: ${file}"; return 1; }

  unset DC_LABELS
  declare -ga DC_LABELS=()
  DC_COUNT=0

  local current_idx=-1 current_label=""
  local line key val
  local default_key="${NSX_FANOUT_KEY:-${HOME}/.ssh/nsx_dc_fanout}"

  # Acceptors
  local re_ipv4='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
  local re_fqdn='^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$'
  local re_user='^[A-Za-z0-9._-]+$'
  local re_abspath='^/[A-Za-z0-9._/~-]+$'      # / + harmless chars; we also accept ~ for $HOME-style
  local re_key_path='^[~/][A-Za-z0-9._/~-]*$'  # absolute OR ~-relative

  while IFS= read -r line || [[ -n "${line}" ]]; do
    # strip comments and trim
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" ]] && continue

    if [[ "${line}" =~ ^\[(.+)\]$ ]]; then
      current_idx=$(( current_idx + 1 ))
      current_label="${BASH_REMATCH[1]}"
      DC_LABELS[$current_idx]="${current_label}"
      # default ssh_key (overridable per-section)
      declare -g "DC_SSH_KEY_${current_idx}=${default_key}"
      # clear required fields so we can validate later
      declare -g "DC_JUMP_HOST_${current_idx}="
      declare -g "DC_JUMP_USER_${current_idx}="
      declare -g "DC_REPO_PATH_${current_idx}="
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
        jump_host)
          if [[ "${val}" =~ ${re_ipv4} ]] || [[ "${val}" =~ ${re_fqdn} && "${val}" == *.* ]]; then
            declare -g "DC_JUMP_HOST_${current_idx}=${val}"
          else
            log_warn "Skipping invalid jump_host in [${current_label}]: ${val}"
          fi
          ;;
        jump_user)
          if [[ "${val}" =~ ${re_user} ]]; then
            declare -g "DC_JUMP_USER_${current_idx}=${val}"
          else
            log_warn "Skipping invalid jump_user in [${current_label}]: ${val}"
          fi
          ;;
        repo_path)
          if [[ "${val}" =~ ${re_abspath} ]]; then
            declare -g "DC_REPO_PATH_${current_idx}=${val}"
          else
            log_warn "Skipping invalid repo_path in [${current_label}]: ${val}"
          fi
          ;;
        ssh_key)
          if [[ "${val}" =~ ${re_key_path} ]]; then
            declare -g "DC_SSH_KEY_${current_idx}=${val}"
          else
            log_warn "Skipping invalid ssh_key in [${current_label}]: ${val}"
          fi
          ;;
        *)
          log_warn "Unknown key '${key}' in [${current_label}]"
          ;;
      esac
    fi
  done < "${file}"

  DC_COUNT=$(( current_idx + 1 ))
  if [[ "${DC_COUNT}" -eq 0 ]]; then
    log_err "No datacenters parsed from ${file}."
    return 1
  fi

  # Required-field check
  local i missing=0 host_var user_var repo_var key_var
  for (( i=0; i<DC_COUNT; i++ )); do
    host_var="DC_JUMP_HOST_${i}"
    user_var="DC_JUMP_USER_${i}"
    repo_var="DC_REPO_PATH_${i}"
    if [[ -z "${!host_var}" || -z "${!user_var}" || -z "${!repo_var}" ]]; then
      log_err "[${DC_LABELS[$i]}] missing required field(s): jump_host/jump_user/repo_path"
      missing=$(( missing + 1 ))
    fi
  done
  if (( missing > 0 )); then
    return 1
  fi

  log_ok "Parsed ${DC_COUNT} datacenter(s) from ${file}:"
  for (( i=0; i<DC_COUNT; i++ )); do
    host_var="DC_JUMP_HOST_${i}"; user_var="DC_JUMP_USER_${i}"
    repo_var="DC_REPO_PATH_${i}"; key_var="DC_SSH_KEY_${i}"
    log "  [${DC_LABELS[$i]}] ${!user_var}@${!host_var}:${!repo_var}  (key: ${!key_var})"
  done
}

# Helpers
dc_jump_host(){ local v="DC_JUMP_HOST_${1}"; echo "${!v}"; }
dc_jump_user(){ local v="DC_JUMP_USER_${1}"; echo "${!v}"; }
dc_repo_path(){ local v="DC_REPO_PATH_${1}"; echo "${!v}"; }
dc_ssh_key()  { local v="DC_SSH_KEY_${1}";   echo "${!v}"; }

# ---------------------------------------------------------------------------
# rotate_logs [days] [dir]
#   Removes files under <dir> (default $LOG_DIR) older than <days> days
#   (default $NSX_LOG_RETENTION_DAYS, default 30).
#   Best-effort: never aborts the caller on failure.
# ---------------------------------------------------------------------------
rotate_logs(){
  local days="${1:-${NSX_LOG_RETENTION_DAYS:-30}}"
  local dir="${2:-${LOG_DIR}}"
  [[ -d "${dir}" ]] || return 0
  local removed
  removed="$(find "${dir}" -type f -mtime "+${days}" -print -delete 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${removed}" != "0" && -n "${removed}" ]]; then
    log "Log rotation: removed ${removed} file(s) older than ${days}d from ${dir}"
  fi
}

# ---------------------------------------------------------------------------
# NSX-CLI output parsers
# ---------------------------------------------------------------------------
# parse_uptime_days "up 42 days, 3:12" -> 42
parse_uptime_days(){
  echo "$1" | grep -oP '(?<=up )\d+(?= day)' || true
}

# parse_version_short "NSX 3.2.3.1 Build 21703605" -> "3.2.3.1"
parse_version_short(){
  echo "$1" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true
}
