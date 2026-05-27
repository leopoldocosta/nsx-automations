#!/usr/bin/env bash
# lib/nsx_edge.sh — v1.0
# Edge-Node specific helpers on top of lib/common.sh.
#
# Requires lib/common.sh sourced first.

if ! declare -f log >/dev/null; then
  echo "[ERR] lib/common.sh must be sourced before lib/nsx_edge.sh" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Root credentials (Edge Nodes — root SSH is toggled via admin CLI)
# ---------------------------------------------------------------------------
ask_root_creds(){
  if [[ -n "${ROOT_PASS:-}" ]]; then
    log "Root credentials already loaded."
    return 0
  fi
  IFS= read -rsp 'Root password (all special characters accepted): ' ROOT_PASS </dev/tty; printf '\n' >/dev/tty
  export ROOT_PASS
  log "Root credentials collected."
}

# ---------------------------------------------------------------------------
# SSH as root — uses ROOT_KEY when present, falls back to ROOT_PASS.
# ---------------------------------------------------------------------------
ssh_root(){
  local ip="$1"; shift
  if [[ -f "${ROOT_KEY}" ]]; then
    ssh -i "${ROOT_KEY}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o BatchMode=yes \
        -o LogLevel=ERROR \
        "root@${ip}" "$@" 2>/dev/null
  else
    _sshpass_safe ROOT_PASS ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o LogLevel=ERROR \
        "root@${ip}" "$@" 2>/dev/null
  fi
}

root_cmd(){ local ip="$1" cmd="$2"; ssh_root "$ip" "$cmd"; }

# ---------------------------------------------------------------------------
# Root SSH toggling (Edge-specific — Managers don't expose this knob)
# ---------------------------------------------------------------------------
enable_root_ssh(){
  local ip="$1"
  log "${ip}: enabling root SSH..."
  admin_cmd "$ip" 'set service ssh root-login enabled' 2>/dev/null || true
  log "${ip}: [set ssh root-login] done"
}

disable_root_ssh(){
  local ip="$1"
  log "${ip}: disabling root SSH..."
  admin_cmd "$ip" 'set service ssh root-login disabled' 2>/dev/null || true
  log "${ip}: [clear ssh root-login] done"
}

# ---------------------------------------------------------------------------
# Admin SSH with one automatic re-prompt on failure (returns 0/1).
# Useful for auth-error retry without losing the loop position.
# ---------------------------------------------------------------------------
try_admin_ssh_with_retry(){
  local ip="$1"; shift
  local cmd="${*:-get version}"
  if admin_cmd "${ip}" "${cmd}" >/dev/null 2>&1; then
    return 0
  fi
  log_warn "${ip}: admin SSH failed — re-prompting credentials..."
  reprompt_admin_creds
  if admin_cmd "${ip}" "${cmd}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Support bundle helpers
# ---------------------------------------------------------------------------
request_support_bundle(){
  local ip="$1"
  admin_cmd "$ip" 'get support-bundle status; start support-bundle' \
    || admin_cmd "$ip" 'start support-bundle' || true
}

check_support_bundle(){
  local ip="$1"
  local out_log out_files out_root
  out_log="$(root_cmd "$ip" \
    "test -f /var/log/support_bundle && tail -50 /var/log/support_bundle || echo FILE_NOT_FOUND")"
  out_files="$(root_cmd "$ip" \
    "find /var/log /storage /tmp -maxdepth 3 \( -name '*support*bundle*' -o -name '*.tgz' -o -name '*.tar.gz' \) -type f 2>/dev/null | head -20")"
  out_root="$(root_cmd "$ip" "getent passwd root >/dev/null 2>&1; echo ROOT_OK")"
  printf '%s\n----FILES----\n%s\n----ROOT----\n%s\n' "$out_log" "$out_files" "$out_root"
}

# Returns only lines matching sb_*.tgz, one per line.
list_remote_bundles(){
  local ip="$1"
  root_cmd "$ip" "ls /var/vmware/nsx/file-store/ 2>/dev/null" \
    | grep -E '^sb_.*\.tgz$' || true
}

# bundle_file_date <fname>
#   Extracts date from bundle filename. Pattern: sb_*_YYYYMMDD_HHMMSS.tgz
#   -> "YYYY-MM-DD HH:MM"; empty on no match.
bundle_file_date(){
  local fname="$1"
  if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})[0-9]{2}\.tgz$ ]]; then
    printf '%s-%s-%s %s:%s' \
      "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
  fi
}

# bundle_duration <ip> <fname>
#   Time between bundle request (parsed from filename) and creation (remote mtime).
#   Output format: "Xh Ym Zs" / "Ym Zs" / "Zs" / "--" on failure.
bundle_duration(){
  local ip="$1" fname="$2"
  local req_epoch=""

  if [[ "$fname" =~ _([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})\.tgz$ ]]; then
    req_epoch=$(date -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null || echo "")
  fi
  [[ -z "$req_epoch" ]] && { printf '--'; return; }

  local created_epoch
  created_epoch="$(root_cmd "$ip" "stat -c '%Y' /var/vmware/nsx/file-store/${fname} 2>/dev/null" | tr -d '\r' || echo "")"
  [[ -z "$created_epoch" || ! "$created_epoch" =~ ^[0-9]+$ ]] && { printf '--'; return; }

  local diff=$(( created_epoch - req_epoch ))
  (( diff < 0 )) && diff=0
  local hh=$(( diff / 3600 ))
  local mm=$(( (diff % 3600) / 60 ))
  local ss=$(( diff % 60 ))

  if (( hh > 0 )); then printf '%dh %02dm %02ds' "$hh" "$mm" "$ss"
  elif (( mm > 0 )); then printf '%dm %02ds' "$mm" "$ss"
  else printf '%ds' "$ss"
  fi
}

# ---------------------------------------------------------------------------
# Edge SSH-key registration (one-time setup via admin CLI)
# Uses NSX_PASS (collected via ask_admin_creds).
# ---------------------------------------------------------------------------
register_edge_admin_key(){
  local ip="$1"
  local pub_full="$2"   # full line: "ssh-ed25519 AAAA... comment"
  log "${ip}: registering admin SSH key..."
  admin_cmd "$ip" "set user admin ssh-key \"${pub_full}\"" || true
}

register_edge_root_key(){
  local ip="$1"
  local pub_full="$2"
  enable_root_ssh "$ip"
  sleep 2
  log "${ip}: registering root SSH key..."
  admin_cmd "$ip" "set user root ssh-key \"${pub_full}\"" || true
  disable_root_ssh "$ip"
}
