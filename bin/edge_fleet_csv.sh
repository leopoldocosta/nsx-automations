#!/usr/bin/env bash
# bin/edge_fleet_csv.sh
#
# Consolidate the per-DC edge_hardware_inventory CSVs that a fan-out pulled back
# into ONE fleet CSV — one row per Edge node — with a leading `dc` column, ready
# to import into a spreadsheet (e.g. a "SERVIDORES" tab, or VLOOKUP'd by
# service_tag). The heavy NIC data is already digested per node by the automation
# (datapath_nics / other_nics / edp_datapath columns), so this is a pure merge —
# it never re-parses the verbose unified_report.txt.
#
# Usage:
#   ./bin/edge_fleet_csv.sh [aggregated_logs/<run-dir>]
#     no arg -> newest aggregated_logs/<ts>/ under the repo
#
# Output:
#   <run-dir>/edge_fleet_servers.csv
#
# Run it on the ORCHESTRATOR, after a fan-out of
# edge_hardware_inventory/edge_hardware_inventory.sh has pulled each DC's logs/
# into aggregated_logs/<ts>/<DC>/logs/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN="${1:-}"
if [[ -z "${RUN}" ]]; then
  RUN="$(ls -dt "${REPO_ROOT}"/aggregated_logs/*/ 2>/dev/null | head -1 || true)"
fi
[[ -n "${RUN}" && -d "${RUN}" ]] || {
  echo "usage: $0 <aggregated_logs/RUN-DIR>   (no aggregated_logs run found)"; exit 1; }
RUN="${RUN%/}"

OUT="${RUN}/edge_fleet_servers.csv"
: > "${OUT}"
header_written=0

for dcdir in "${RUN}"/*/; do
  [[ -d "${dcdir}logs" ]] || continue
  dc="$(basename "${dcdir}")"
  # newest server-level CSV for this DC (logs/ may hold several timestamps)
  csv="$(ls -t "${dcdir}logs/"edge_hw_report_*.csv 2>/dev/null | head -1 || true)"
  [[ -n "${csv}" && -f "${csv}" ]] || { echo "  [skip] ${dc}: no edge_hw_report_*.csv"; continue; }
  if (( ! header_written )); then
    { printf 'dc,'; head -1 "${csv}"; } >> "${OUT}"
    header_written=1
  fi
  # data rows (skip the header), prefixed with the DC label
  tail -n +2 "${csv}" | sed "s/^/${dc},/" >> "${OUT}"
  echo "  [ok]   ${dc}: $(( $(wc -l < "${csv}") - 1 )) node(s) from $(basename "${csv}")"
done

if (( ! header_written )); then
  echo "No edge_hw_report_*.csv found under ${RUN}/*/logs/ — did the fan-out run"
  echo "edge_hardware_inventory and pull logs (i.e. not --no-pull-logs)?"
  rm -f "${OUT}"
  exit 1
fi

echo "Wrote ${OUT}  ($(( $(wc -l < "${OUT}") - 1 )) node row(s) across the fleet)"
