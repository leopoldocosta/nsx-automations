#!/usr/bin/env bats
# Parser tests for parse_datacenters_conf (no SSH, no network).
# Run locally:  bats tests/test_datacenters_parser.bats
# CI:           .github/workflows/lint.yml

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export REPO_ROOT
  export AUTO_DIR="${BATS_TEST_TMPDIR}"
  # shellcheck source=../lib/common.sh
  source "${REPO_ROOT}/lib/common.sh"
}

@test "parse_datacenters_conf: counts 3 datacenters" {
  parse_datacenters_conf "${REPO_ROOT}/tests/fixtures/datacenters_basic.conf"
  [ "${DC_COUNT}" -eq 3 ]
}

@test "parse_datacenters_conf: labels in order" {
  parse_datacenters_conf "${REPO_ROOT}/tests/fixtures/datacenters_basic.conf"
  [ "${DC_LABELS[0]}" = "DC-A" ]
  [ "${DC_LABELS[1]}" = "DC-B" ]
  [ "${DC_LABELS[2]}" = "DC-C" ]
}

@test "parse_datacenters_conf: FQDN jump_host accepted" {
  parse_datacenters_conf "${REPO_ROOT}/tests/fixtures/datacenters_basic.conf"
  [ "$(dc_jump_host 0)" = "dc-a-jump.internal.example" ]
  [ "$(dc_jump_user 0)" = "nsxops" ]
  [ "$(dc_repo_path 0)" = "/home/nsxops/nsx-automations" ]
}

@test "parse_datacenters_conf: IPv4 jump_host accepted" {
  parse_datacenters_conf "${REPO_ROOT}/tests/fixtures/datacenters_basic.conf"
  [ "$(dc_jump_host 1)" = "10.20.0.50" ]
}

@test "parse_datacenters_conf: per-section ssh_key override honored" {
  parse_datacenters_conf "${REPO_ROOT}/tests/fixtures/datacenters_basic.conf"
  [ "$(dc_ssh_key 1)" = "~/.ssh/nsx_dc_fanout_dcb" ]
}

@test "parse_datacenters_conf: default ssh_key applied when not set" {
  parse_datacenters_conf "${REPO_ROOT}/tests/fixtures/datacenters_basic.conf"
  default_key="${NSX_FANOUT_KEY:-${HOME}/.ssh/nsx_dc_fanout}"
  [ "$(dc_ssh_key 0)" = "${default_key}" ]
  [ "$(dc_ssh_key 2)" = "${default_key}" ]
}

@test "parse_datacenters_conf: dotted username accepted" {
  parse_datacenters_conf "${REPO_ROOT}/tests/fixtures/datacenters_basic.conf"
  [ "$(dc_jump_user 2)" = "automation.bot" ]
}

@test "parse_datacenters_conf: rejects shell-meta in every field (defense in depth)" {
  # All four fields in [BAD] are injection attempts. Parser must reject them.
  # Since jump_host/jump_user/repo_path are required, the parser should return 1
  # (missing required fields after rejection).
  run parse_datacenters_conf "${REPO_ROOT}/tests/fixtures/datacenters_malformed.conf"
  [ "${status}" -ne 0 ]

  # And none of the malicious values should have been stored.
  [[ "$(dc_jump_host 0)" != *";"*    ]]
  [[ "$(dc_jump_user 0)" != *'$('*   ]]
  [[ "$(dc_repo_path 0)" != *'`'*    ]]
  [[ "$(dc_ssh_key   0)" != *".."*   ]]

  # [PARTIAL]: legit jump_host + jump_user should be kept, but repo_path
  # containing $() must be dropped — leaving the section invalid.
  [ "$(dc_jump_host 1)" = "10.30.0.10" ]
  [ "$(dc_jump_user 1)" = "ok-user" ]
  [[ "$(dc_repo_path 1)" != *'$('* ]]
}
