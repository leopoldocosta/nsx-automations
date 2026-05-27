#!/usr/bin/env bash
# install_crontab.sh - Production crontab: day 1 of every month at 02:00.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

install_crontab_line "0 2 1 * *" "${SCRIPT_DIR}/nsx_rolling_reboot.sh"
crontab -l | grep nsx_rolling_reboot || true
