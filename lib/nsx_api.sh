#!/usr/bin/env bash
# lib/nsx_api.sh — v1.0
# NSX Manager / Policy REST API helpers on top of lib/common.sh.
#
# Adds: safe Basic-Auth curl wrapper (credentials never appear in `ps`),
# GET/PATCH, LB-service realization-id resolution, paginated pool lookup
# by member, and monitor-profile summaries.
#
# Requires lib/common.sh sourced first (for log* and NSX_USER/NSX_PASS).
#
# Globals expected from the automation:
#   NSX_MGR   : NSX Manager IP or FQDN (no scheme, no trailing slash)
#   NSX_USER  : admin username (default 'admin')
#   NSX_PASS  : admin password (any special characters accepted)

if ! declare -f log >/dev/null; then
  echo "[ERR] lib/common.sh must be sourced before lib/nsx_api.sh" >&2
  exit 1
fi

NSX_API_INSECURE="${NSX_API_INSECURE:-1}"   # 1 => curl -k (self-signed mgr cert)
NSX_API_MAXTIME="${NSX_API_MAXTIME:-30}"    # per-request timeout (s)
NSX_API_PAGE_SIZE="${NSX_API_PAGE_SIZE:-1000}"
NSX_API_MAX_PAGES="${NSX_API_MAX_PAGES:-200}"

# ---------------------------------------------------------------------------
# _nsx_api_b64 — base64 of "user:pass".
#   Encoding the RAW bytes is what makes this safe for $, !, @, #, \, spaces,
#   quotes — any special character — without shell-quoting headaches. This is
#   the same robustness goal as common.sh's printf '%q' session handling.
# ---------------------------------------------------------------------------
_nsx_api_b64(){
  printf '%s:%s' "${NSX_USER:-admin}" "${NSX_PASS:-}" | base64 | tr -d '\n'
}

# ---------------------------------------------------------------------------
# _nsx_curl <curl-args...> <url>
#   Core wrapper. The Authorization header is passed via a curl --config read
#   from a process-substitution FD, so the credential never lands in the
#   process argument list (unlike `--user` / `-H`, which leak via `ps`).
#   The base64 token only uses the base64 alphabet, so it is safe to embed in
#   the curl config file syntax.
# ---------------------------------------------------------------------------
_nsx_curl(){
  local b64; b64="$(_nsx_api_b64)"
  local insecure=()
  [[ "${NSX_API_INSECURE}" == "1" ]] && insecure=(-k)
  curl -sS "${insecure[@]}" --max-time "${NSX_API_MAXTIME}" \
    --config <(printf 'header = "Authorization: Basic %s"\n' "${b64}") \
    "$@"
}

# nsx_api_get <path>            -> response body on stdout (path begins with /)
nsx_api_get(){
  local path="${1:?usage: nsx_api_get <path>}"
  _nsx_curl "https://${NSX_MGR}${path}"
}

# nsx_api_get_code <path>       -> HTTP status code only (for reachability/auth)
nsx_api_get_code(){
  local path="${1:?usage: nsx_api_get_code <path>}"
  _nsx_curl -o /dev/null -w '%{http_code}' "https://${NSX_MGR}${path}"
}

# nsx_api_patch <path> <json>   -> response body on stdout
nsx_api_patch(){
  local path="${1:?usage: nsx_api_patch <path> <json>}"
  local json="${2:?missing json body}"
  _nsx_curl -X PATCH -H 'Content-Type: application/json' -d "${json}" \
    "https://${NSX_MGR}${path}"
}

# ---------------------------------------------------------------------------
# nsx_api_check_auth
#   Quick admin/auth + reachability probe against the Policy root.
#   Returns 0 if HTTP 200, else 1 (and logs the code).
# ---------------------------------------------------------------------------
nsx_api_check_auth(){
  local code
  code="$(nsx_api_get_code '/policy/api/v1/infra/lb-services?page_size=1' 2>/dev/null || true)"
  if [[ "${code}" == "200" ]]; then
    return 0
  fi
  log_err "NSX API auth/reachability failed against ${NSX_MGR} (HTTP ${code:-000})."
  case "${code}" in
    401|403) log_warn "Check NSX_USER/NSX_PASS (401/403 = bad credentials)." ;;
    000)     log_warn "No HTTP response — check IP/FQDN, routing, or TLS to ${NSX_MGR}." ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# lb_service_json <policy-id>     -> full LB-service object (Policy API)
# lb_service_field <policy-id> <jq>  -> a single jq-extracted field
# ---------------------------------------------------------------------------
lb_service_json(){
  local id="${1:?usage: lb_service_json <lb-service-policy-id>}"
  nsx_api_get "/policy/api/v1/infra/lb-services/${id}"
}

lb_service_field(){
  local id="${1:?usage: lb_service_field <id> <jq-filter>}"
  local filter="${2:?missing jq filter}"
  lb_service_json "${id}" | jq -r "${filter} // empty" 2>/dev/null || true
}

# realization_id is the UUID the Edge dataplane CLI expects
# (get load-balancer <realization_id> ...). The Policy id will NOT work there.
lb_service_realization_id(){ lb_service_field "$1" '.realization_id'; }

# ---------------------------------------------------------------------------
# vs_lb_service_path <vs-policy-id>
#   A Policy LBVirtualServer carries .lb_service_path. Use it to climb from a
#   virtual-server id to its parent LB service.
# ---------------------------------------------------------------------------
vs_lb_service_path(){
  local vs="${1:?usage: vs_lb_service_path <vs-policy-id>}"
  nsx_api_get "/policy/api/v1/infra/lb-virtual-servers/${vs}" \
    | jq -r '.lb_service_path // empty' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# find_vs_by_vip <vip-ip> <port>
#   Lists virtual servers and matches VIP ip_address + port. Emits TSV:
#   <vs-id>\t<display_name>\t<lb_service_path>\t<pool_path>
# ---------------------------------------------------------------------------
find_vs_by_vip(){
  local ip="${1:?usage: find_vs_by_vip <ip> <port>}"
  local port="${2:?missing port}"
  _nsx_paginate "/policy/api/v1/infra/lb-virtual-servers" \
    '
      .results[]
      | select(.ip_address == $ip)
      | select(any((.ports // [])[]?; (. | tostring) == $port))
      | [.id, .display_name, (.lb_service_path // "-"), (.pool_path // "-")]
      | @tsv' \
    --arg ip "${ip}" --arg port "${port}"
}

# ---------------------------------------------------------------------------
# find_pool_by_member <member-ip> <member-port>
#   THE workaround for the Edge↔Policy id mismatch: the pool id shown by the
#   Edge CLI is a dataplane/realization id and is NOT queryable on the Policy
#   API. Instead we enumerate Policy pools and match on a stable attribute —
#   the member ip + port. Emits TSV:
#   <pool-policy-id>\t<display_name>\t<active_monitor_paths(csv)>
# ---------------------------------------------------------------------------
find_pool_by_member(){
  local ip="${1:?usage: find_pool_by_member <member-ip> <member-port>}"
  local port="${2:?missing member port}"
  _nsx_paginate "/policy/api/v1/infra/lb-pools" \
    '
      .results[]
      | select(any(.members[]?; .ip_address == $ip and ((.port // "" | tostring) == $port)))
      | [.id, .display_name, ((.active_monitor_paths // []) | join(","))]
      | @tsv' \
    --arg ip "${ip}" --arg port "${port}"
}

# ---------------------------------------------------------------------------
# monitor_profile_summary <monitor-policy-path-or-id>
#   Accepts either a full path (/infra/lb-monitor-profiles/<id>) or a bare id.
#   Emits TSV: <resource_type>\t<monitor_port>\t<request_method>\t<request_url>\t<status_codes(csv)>
# ---------------------------------------------------------------------------
monitor_profile_summary(){
  local ref="${1:?usage: monitor_profile_summary <path-or-id>}"
  local path
  if [[ "${ref}" == /infra/* ]]; then
    path="/policy/api/v1${ref}"
  else
    path="/policy/api/v1/infra/lb-monitor-profiles/${ref}"
  fi
  nsx_api_get "${path}" | jq -r '
    [ (.resource_type // "-"),
      (.monitor_port // "-" | tostring),
      (.request_method // "-"),
      (.request_url // "-"),
      ((.response_status_codes // []) | map(tostring) | join(",") | if . == "" then "-" else . end)
    ] | @tsv' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _nsx_paginate <base-path> <jq-program> [extra jq --arg ...]
#   Internal: walks the NSX cursor pagination, applying <jq-program> to each
#   page's parsed JSON and streaming matching lines. Safe page cap.
# ---------------------------------------------------------------------------
_nsx_paginate(){
  local base="${1:?_nsx_paginate <base> <jq>}"; shift
  local prog="${1:?missing jq program}"; shift
  local cursor="" page=0 sep url body

  while (( page < NSX_API_MAX_PAGES )); do
    if [[ "${base}" == *\?* ]]; then sep='&'; else sep='?'; fi
    url="${base}${sep}page_size=${NSX_API_PAGE_SIZE}"
    [[ -n "${cursor}" ]] && url="${url}&cursor=${cursor}"

    body="$(nsx_api_get "${url}")"
    [[ -z "${body}" ]] && break
    jq -r "$@" "${prog}" <<<"${body}" 2>/dev/null || true

    cursor="$(jq -r '.cursor // empty' <<<"${body}" 2>/dev/null || true)"
    [[ -z "${cursor}" ]] && break
    page=$(( page + 1 ))
  done
}
