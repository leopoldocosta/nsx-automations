#!/usr/bin/env bash
# test_reboot_single.sh - Reboot one Manager for testing.
# Usage: ./test_reboot_single.sh <ip> [admin_user]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
export ADMIN_KEY="${ADMIN_KEY:-${HOME}/.ssh/id_rsa}"
# shellcheck source=../../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=../../lib/nsx_manager.sh
source "${REPO_ROOT}/lib/nsx_manager.sh"

IP="${1:?Usage: $0 <ip> [admin_user]}"
export NSX_USER="${2:-admin}"

log "[TEST] Single-manager reboot cycle for ${IP} (user: ${NSX_USER})"
reboot_manager_and_wait "${IP}"
