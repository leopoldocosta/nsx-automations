#!/usr/bin/env bats
# Tests for resolve_inventory_file (lib/common.sh) — no SSH, no network.
# Run locally:  bats tests/test_inventory_resolver.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export REPO_ROOT
  export AUTO_DIR="${BATS_TEST_TMPDIR}/auto"
  export NSX_INVENTORY_DIR="${BATS_TEST_TMPDIR}/inventory"
  mkdir -p "${AUTO_DIR}" "${NSX_INVENTORY_DIR}"
  # shellcheck source=../lib/common.sh
  source "${REPO_ROOT}/lib/common.sh"
}

@test "resolver: local file wins over central" {
  echo "10.0.0.1" > "${AUTO_DIR}/edge_nodes.txt"
  echo "10.9.9.9" > "${NSX_INVENTORY_DIR}/edge_nodes.txt"
  result="$(resolve_inventory_file "${AUTO_DIR}/edge_nodes.txt")"
  [ "${result}" = "${AUTO_DIR}/edge_nodes.txt" ]
}

@test "resolver: falls back to central when local missing" {
  echo "10.9.9.9" > "${NSX_INVENTORY_DIR}/edge_nodes.txt"
  result="$(resolve_inventory_file "${AUTO_DIR}/edge_nodes.txt")"
  [ "${result}" = "${NSX_INVENTORY_DIR}/edge_nodes.txt" ]
}

@test "resolver: echoes local path when neither exists (error stays local)" {
  result="$(resolve_inventory_file "${AUTO_DIR}/edge_nodes.txt")"
  [ "${result}" = "${AUTO_DIR}/edge_nodes.txt" ]
}

@test "resolver: HOST_FILE is resolved at source time" {
  # setup() already sourced with no files present → HOST_FILE stays local.
  # Re-source with only the central file present → HOST_FILE must be central.
  echo "10.9.9.9" > "${NSX_INVENTORY_DIR}/hosts.txt"
  unset HOST_FILE
  source "${REPO_ROOT}/lib/common.sh"
  [ "${HOST_FILE}" = "${NSX_INVENTORY_DIR}/hosts.txt" ]
}
