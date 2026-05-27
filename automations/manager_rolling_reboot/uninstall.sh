#!/usr/bin/env bash
# uninstall.sh - Removes the crontab entry and the runtime lock file.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

remove_crontab_line "${SCRIPT_DIR}/nsx_rolling_reboot.sh"
rm -f /tmp/nsx_rolling_reboot.lock
log_ok "Crontab removed and lock file cleared."
