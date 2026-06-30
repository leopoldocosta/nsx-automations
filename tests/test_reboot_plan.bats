#!/usr/bin/env bats
# Parser tests for parse_reboot_plan (no SSH, no network).
# Run locally:  bats tests/test_reboot_plan.bats
# CI:           .github/workflows/lint.yml

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export REPO_ROOT
  export AUTO_DIR="${BATS_TEST_TMPDIR}"
  # shellcheck source=../lib/common.sh
  source "${REPO_ROOT}/lib/common.sh"
}

@test "parse_reboot_plan: counts 6 entries in the basic fixture" {
  parse_reboot_plan "${REPO_ROOT}/tests/fixtures/reboot_plan_basic.conf"
  [ "${PLAN_COUNT}" -eq 6 ]
}

@test "parse_reboot_plan: order matches the file (interleaved DC-A / DC-B)" {
  parse_reboot_plan "${REPO_ROOT}/tests/fixtures/reboot_plan_basic.conf"
  [ "$(plan_dc 0)" = "DC-A" ]
  [ "$(plan_ip 0)" = "192.168.20.10" ]
  [ "$(plan_dc 1)" = "DC-B" ]
  [ "$(plan_ip 1)" = "192.168.30.10" ]
  [ "$(plan_dc 5)" = "DC-B" ]
  [ "$(plan_ip 5)" = "192.168.30.12" ]
}

@test "parse_reboot_plan: rejects every malformed line, keeps the one valid entry" {
  # Direct call (not via `run`) so PLAN_* globals stay in this shell.
  # set +e/-e brackets `set -euo pipefail` from common.sh.
  set +e
  parse_reboot_plan "${REPO_ROOT}/tests/fixtures/reboot_plan_malformed.conf" >/dev/null 2>&1
  local rc=$?
  set -e
  # Even though most lines are rejected, one valid entry remains → rc=0.
  [ "${rc}" -eq 0 ]
  [ "${PLAN_COUNT}" -eq 1 ]
  [ "$(plan_dc 0)" = "DC-A" ]
  [ "$(plan_ip 0)" = "10.0.0.5" ]

  # And no shell metacharacters or duplicates leaked into the arrays.
  for ip in "${PLAN_IPS[@]}"; do
    [[ "${ip}" != *';'*  ]]
    [[ "${ip}" != *'$('* ]]
    [[ "${ip}" != *'`'*  ]]
  done
  for dc in "${PLAN_DCS[@]}"; do
    [[ "${dc}" != *'$('* ]]
  done
}

@test "parse_reboot_plan: returns 1 on an empty/comments-only file" {
  empty="${BATS_TEST_TMPDIR}/empty_plan.conf"
  printf '# just a comment\n\n' > "${empty}"
  set +e
  parse_reboot_plan "${empty}" >/dev/null 2>&1
  rc=$?
  set -e
  [ "${rc}" -ne 0 ]
}
