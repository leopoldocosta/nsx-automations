#!/usr/bin/env bats
# Repo-consistency gate — makes docs-vs-reality drift a BUILD FAILURE instead of
# something a human has to catch in a manual audit. Pure filesystem/text checks:
# no SSH, no network, no lib sourcing.
#
# Run locally:  bats tests/
# Run in CI:    auto-discovered by the `bats tests/` job in .github/workflows/lint.yml
#
# Invariants enforced (the classes of drift that actually happened):
#   1. every bin/*.sh is referenced in README.md
#   2. every automations/*/ folder has a README.md AND is named in README.md
#   3. no doc references a bin/<name>.sh that does not exist on disk
#   4. every bin and automation script has a bash shebang + `set -euo pipefail`
#
# NOT yet enforced (see TODO item 12): each automation README documenting exactly
# the --flags its script parses. That needs flag extraction and is done manually.

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export REPO_ROOT
  shopt -s nullglob
}

# --- 1. every bin/ script is documented in the README -----------------------
@test "every bin/*.sh is referenced in README.md" {
  local missing=() f b
  for f in "${REPO_ROOT}"/bin/*.sh; do
    b="$(basename "$f")"
    grep -qF "$b" "${REPO_ROOT}/README.md" || missing+=("$b")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'bin/ script missing from README.md: %s\n' "${missing[@]}"
  fi
  [ "${#missing[@]}" -eq 0 ]
}

# --- 2. every automation folder has a README and appears in the README -------
@test "every automations/*/ folder has a README.md and is named in README.md" {
  local problems=() d name
  for d in "${REPO_ROOT}"/automations/*/; do
    name="$(basename "$d")"
    [ -f "${d}README.md" ] || problems+=("${name}: missing README.md")
    grep -qF "$name" "${REPO_ROOT}/README.md" || problems+=("${name}: not referenced in README.md")
  done
  if [ "${#problems[@]}" -ne 0 ]; then
    printf '%s\n' "${problems[@]}"
  fi
  [ "${#problems[@]}" -eq 0 ]
}

# --- 3. no dangling bin/<name>.sh reference in the CURRENT-STATE docs ---------
# Scans docs that describe the repo as it is now. TODO.md (backlog names scripts
# not built yet) and CHANGELOG.md (history names removed scripts) are excluded on
# purpose — they legitimately reference scripts that do not exist on disk.
@test "no current-state doc references a non-existent bin/ script" {
  local bad=() ref files=()
  files+=( "${REPO_ROOT}/README.md" "${REPO_ROOT}/AGENTS.md" "${REPO_ROOT}/CONTRIBUTING.md" )
  files+=( "${REPO_ROOT}"/docs/*.md )
  files+=( "${REPO_ROOT}"/automations/*/README.md )
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    [ -e "${REPO_ROOT}/${ref}" ] || bad+=("$ref")
  done < <(grep -hoE 'bin/[A-Za-z0-9_-]+\.sh' "${files[@]}" 2>/dev/null | sort -u)
  if [ "${#bad[@]}" -ne 0 ]; then
    printf 'Doc references a bin/ script that does not exist: %s\n' "${bad[@]}"
  fi
  [ "${#bad[@]}" -eq 0 ]
}

# --- 4. shebang + `set -euo pipefail` on every script -----------------------
@test "every bin and automation script has a bash shebang and set -euo pipefail" {
  local problems=() f
  for f in "${REPO_ROOT}"/bin/*.sh "${REPO_ROOT}"/automations/*/*.sh; do
    head -1 "$f" | grep -qE '^#!.*bash' || problems+=("$(basename "$f"): no bash shebang")
    grep -qE '^set -euo pipefail' "$f"  || problems+=("$(basename "$f"): no 'set -euo pipefail'")
  done
  if [ "${#problems[@]}" -ne 0 ]; then
    printf '%s\n' "${problems[@]}"
  fi
  [ "${#problems[@]}" -eq 0 ]
}
