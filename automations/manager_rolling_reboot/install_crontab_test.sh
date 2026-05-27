#!/usr/bin/env bash
# install_crontab_test.sh - TEST crontab: every 30 min (lock file prevents overlap).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

install_crontab_line "*/30 * * * *" "${SCRIPT_DIR}/nsx_rolling_reboot.sh"
crontab -l | grep nsx_rolling_reboot || true
