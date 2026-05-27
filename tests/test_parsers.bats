#!/usr/bin/env bats
# Pure-parser tests — no SSH, no network.
# Run locally:  bats tests/
# Run in CI:    see .github/workflows/lint.yml

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export REPO_ROOT
  # Isolate AUTO_DIR so common.sh doesn't write into the repo during tests.
  export AUTO_DIR="${BATS_TEST_TMPDIR}"
  # shellcheck source=../lib/common.sh
  source "${REPO_ROOT}/lib/common.sh"
  # shellcheck source=../lib/nsx_edge.sh
  source "${REPO_ROOT}/lib/nsx_edge.sh"
  # shellcheck source=../lib/nsx_manager.sh
  source "${REPO_ROOT}/lib/nsx_manager.sh"
}

# ---------------------------------------------------------------------------
# parse_uptime_days
# ---------------------------------------------------------------------------
@test "parse_uptime_days: classic 'up X days'" {
  result="$(parse_uptime_days 'up 42 days, 3:12')"
  [ "${result}" = "42" ]
}

@test "parse_uptime_days: single day" {
  result="$(parse_uptime_days 'up 1 day, 0:00')"
  [ "${result}" = "1" ]
}

@test "parse_uptime_days: no days returns empty" {
  result="$(parse_uptime_days 'up 3:14')"
  [ -z "${result}" ]
}

# ---------------------------------------------------------------------------
# parse_version_short
# ---------------------------------------------------------------------------
@test "parse_version_short: full NSX banner" {
  result="$(parse_version_short 'NSX 3.2.3.1 Build 21703605')"
  [ "${result}" = "3.2.3.1" ]
}

@test "parse_version_short: 4.x" {
  result="$(parse_version_short 'NSX 4.1.2.3 Build 99999999')"
  [ "${result}" = "4.1.2.3" ]
}

@test "parse_version_short: empty input returns empty" {
  result="$(parse_version_short '')"
  [ -z "${result}" ]
}

# ---------------------------------------------------------------------------
# bundle_file_date
# ---------------------------------------------------------------------------
@test "bundle_file_date: canonical pattern" {
  result="$(bundle_file_date 'sb_edge01_20250127_143015.tgz')"
  [ "${result}" = "2025-01-27 14:30" ]
}

@test "bundle_file_date: non-matching filename returns empty" {
  result="$(bundle_file_date 'random.tgz')"
  [ -z "${result}" ]
}

# ---------------------------------------------------------------------------
# parse_managers_conf
# ---------------------------------------------------------------------------
@test "parse_managers_conf: counts 3 clusters" {
  parse_managers_conf "${REPO_ROOT}/tests/fixtures/managers_basic.conf"
  [ "${CLUSTER_COUNT}" -eq 3 ]
}

@test "parse_managers_conf: cluster labels in order" {
  parse_managers_conf "${REPO_ROOT}/tests/fixtures/managers_basic.conf"
  [ "${CLUSTER_LABELS[0]}" = "GER1" ]
  [ "${CLUSTER_LABELS[1]}" = "GER2" ]
  [ "${CLUSTER_LABELS[2]}" = "SP1" ]
}

@test "parse_managers_conf: GER1 hosts parsed via commas" {
  parse_managers_conf "${REPO_ROOT}/tests/fixtures/managers_basic.conf"
  result="$(cluster_hosts 0)"
  [ "${result}" = "192.168.20.10 192.168.20.11 192.168.20.12" ]
}

@test "parse_managers_conf: GER2 hosts parsed via whitespace" {
  parse_managers_conf "${REPO_ROOT}/tests/fixtures/managers_basic.conf"
  result="$(cluster_hosts 1)"
  [ "${result}" = "10.0.0.1 10.0.0.2" ]
}

@test "parse_managers_conf: admin_user defaults to admin" {
  parse_managers_conf "${REPO_ROOT}/tests/fixtures/managers_basic.conf"
  result="$(cluster_admin_user 2)"
  [ "${result}" = "admin" ]
}

@test "parse_managers_conf: admin_user override honored" {
  parse_managers_conf "${REPO_ROOT}/tests/fixtures/managers_basic.conf"
  result="$(cluster_admin_user 1)"
  [ "${result}" = "nsxadmin" ]
}

@test "parse_managers_conf: rejects shell-meta hosts/users (defense in depth)" {
  # The malformed conf contains "; rm -rf /" and "admin$(touch ...)" —
  # both must be skipped, never stored.
  parse_managers_conf "${REPO_ROOT}/tests/fixtures/managers_malformed.conf" >/dev/null 2>&1
  # Only legit IPs should remain in the hosts list.
  result="$(cluster_hosts 0)"
  [[ "${result}" != *"rm"* ]]
  [[ "${result}" != *";"* ]]
  [[ "${result}" != *"/"* ]]
  [[ "${result}" == *"192.168.1.1"* ]]
  [[ "${result}" == *"192.168.1.2"* ]]
  # admin_user with $() must NOT be accepted — default "admin" must persist.
  user="$(cluster_admin_user 0)"
  [ "${user}" = "admin" ]
}
