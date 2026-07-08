#!/usr/bin/env bash
# bin/generate_reboot_plan.sh
#
# Builds reboot_plan.conf AUTOMATICALLY from the fleet: connects to every
# jump in datacenters.conf, reads its inventory/managers.conf (the data the
# operator already filled during onboarding) and emits the interleaved
# round-robin plan — 1 line = 1 manager = 1 day, same-cluster managers
# spaced N days apart (N = number of clusters fleet-wide).
#
# Usage:
#   ./bin/generate_reboot_plan.sh [--conf <datacenters.conf>]          # prints to stdout
#   ./bin/generate_reboot_plan.sh --write                              # saves ./reboot_plan.conf
#
# Flags:
#   --conf <file>   datacenters.conf (default: <repo>/datacenters.conf)
#   --write         Save to <repo>/reboot_plan.conf. If it already exists,
#                   the old file is kept as reboot_plan.conf.bak.
#
# The result is validated with parse_reboot_plan (dup IPs, syntax) before
# anything is written. Review with:  ./bin/rolling_reboot_next.sh --list
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export AUTO_DIR="${REPO_ROOT}"
export NSX_AUTOMATION_NAME="orchestrator"   # notify.conf key for bin/ tools
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

CONF="${REPO_ROOT}/datacenters.conf"
WRITE=false

usage(){ grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf)  CONF="$2"; shift 2 ;;
    --write) WRITE=true; shift ;;
    -h|--help) usage ;;
    *) log_err "Unknown flag: $1"; exit 1 ;;
  esac
done

[[ -f "${CONF}" ]] || { log_err "Conf not found: ${CONF}"; exit 1; }
need_cmd ssh
parse_datacenters_conf "${CONF}" >&2

# ---------------------------------------------------------------------------
# Collect: one flat list of clusters, each "DC|CLUSTER|ip1 ip2 ..."
# ---------------------------------------------------------------------------
declare -a CLUSTERS=()
max_size=0

for (( i=0; i<DC_COUNT; i++ )); do
  dc="${DC_LABELS[$i]}"
  host="$(dc_jump_host "${i}")"
  user="$(dc_jump_user "${i}")"
  key="$(dc_ssh_key   "${i}")"; key="${key/#\~/$HOME}"
  repo="$(dc_repo_path "${i}")"

  log "[${dc}] reading inventory from ${user}@${host}..." >&2
  raw="$(ssh -i "${key}" -o BatchMode=yes -o ForwardAgent=no -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR \
        "${user}@${host}" \
        "grep -E '^\[|^hosts' ${repo}/inventory/managers.conf 2>/dev/null" \
        </dev/null 2>/dev/null || true)"

  if [[ -z "${raw}" ]]; then
    log_warn "[${dc}] no managers.conf on the jump — DC skipped (onboard it first)." >&2
    continue
  fi

  cluster=""
  while IFS= read -r line; do
    if [[ "${line}" =~ ^\[([A-Za-z0-9._-]+)\]$ ]]; then
      cluster="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${line}" =~ ^hosts[[:space:]]*= ]]; then
      [[ -z "${cluster}" ]] && { log_warn "[${dc}] hosts line outside a [section] — skipped" >&2; continue; }
      ips="$(echo "${line#*=}" | tr ',' ' ')"
      # Validate each token strictly — anything non-IPv4 is refused.
      clean=""
      for ip in ${ips}; do
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          clean+="${ip} "
        else
          log_warn "[${dc}/${cluster}] ignoring non-IPv4 token '${ip}'" >&2
        fi
      done
      clean="${clean% }"
      [[ -z "${clean}" ]] && continue
      CLUSTERS+=("${dc}|${cluster}|${clean}")
      n=$(echo "${clean}" | wc -w)
      (( n > max_size )) && max_size=${n}
      log "  [${cluster}] ${n} manager(s): ${clean}" >&2
    fi
  done <<< "${raw}"
done

(( ${#CLUSTERS[@]} > 0 )) || { log_err "No clusters collected — nothing to generate."; exit 1; }

# ---------------------------------------------------------------------------
# Emit: round-robin across clusters (round r = r-th manager of each cluster)
# ---------------------------------------------------------------------------
PLAN=""
total=0
for (( r=0; r<max_size; r++ )); do
  PLAN+="# ---- Round $((r+1)): manager #$((r+1)) of each cluster ----"$'\n'
  for entry in "${CLUSTERS[@]}"; do
    dc="${entry%%|*}"; rest="${entry#*|}"
    cluster="${rest%%|*}"; ips="${rest#*|}"
    read -r -a arr <<< "${ips}"
    if (( r < ${#arr[@]} )); then
      PLAN+="${dc} ${arr[$r]}   # ${cluster}-m$((r+1))"$'\n'
      total=$(( total + 1 ))
    fi
  done
done

HEADER="# reboot_plan.conf — GENERATED $(date '+%F %T') by bin/generate_reboot_plan.sh
# Source of truth: inventory/managers.conf of each jump (via ${CONF##*/}).
# ${total} manager(s), ${#CLUSTERS[@]} cluster(s) -> same-cluster spacing = ${#CLUSTERS[@]} day(s).
# Regenerate after inventory changes; review with: ./bin/rolling_reboot_next.sh --list
"

# ---------------------------------------------------------------------------
# Validate with the real parser before handing it to the operator
# ---------------------------------------------------------------------------
tmp="$(mktemp)"
printf '%s%s' "${HEADER}" "${PLAN}" > "${tmp}"
if ! parse_reboot_plan "${tmp}" >&2; then
  rm -f "${tmp}"
  log_err "Generated plan failed validation — see warnings above. Nothing written."
  exit 1
fi
log_ok "Generated plan: ${total} managers / ${#CLUSTERS[@]} clusters (validated)." >&2

if "${WRITE}"; then
  out="${REPO_ROOT}/reboot_plan.conf"
  if [[ -f "${out}" ]]; then
    cp "${out}" "${out}.bak"
    log_warn "Existing ${out} backed up to reboot_plan.conf.bak" >&2
  fi
  mv "${tmp}" "${out}"
  log_ok "Written: ${out}" >&2
  log "Next: ./bin/rolling_reboot_next.sh --list" >&2
else
  cat "${tmp}"
  rm -f "${tmp}"
  log "Dry output above — rerun with --write to save reboot_plan.conf" >&2
fi
