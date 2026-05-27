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
  C_BLUE=$'\033[0;34m';  C_MAGENTA=$'\033[0;35m'
else
  C_RESET=''; C_BOLD=''; C_GREEN=''; C_YELLOW=''
  C_RED='';   C_CYAN=''; C_BLUE='';  C_MAGENTA=''
fi

# ---------------------------------------------------------------------------
# Logging (color-aware, timestamped)
# ---------------------------------------------------------------------------
log()      { printf '%s[%s]%s %s\n'           "${C_CYAN}"    "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_ok()   { printf '%s[%s] [OK]%s   %s\n'    "${C_GREEN}"   "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_warn() { printf '%s[%s] [WARN]%s %s\n'    "${C_YELLOW}"  "$(date '+%F %T')" "${C_RESET}" "$*"; }
log_err()  { printf '%s[%s] [ERR]%s  %s\n'    "${C_RED}"     "$(date '+%F %T')" "${C_RESET}" "$*"; }

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
# Stderr silenced for clean stdout capture.
# ---------------------------------------------------------------------------
ssh_admin(){
  local ip="$1"; shift
  if [[ -f "${ADMIN_KEY}" ]]; then
    ssh -i "${ADMIN_KEY}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        -o LogLevel=ERROR \
        "${NSX_USER:-admin}@${ip}" "$@" 2>/dev/null
  else
    _sshpass_safe NSX_PASS ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o LogLevel=ERROR \
        "${NSX_USER:-admin}@${ip}" "$@" 2>/dev/null
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
