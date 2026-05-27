# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `NSX_DEBUG=1` env var to surface SSH stderr (was unconditionally silenced).
- `wait_cluster_stable` polls `get cluster status` post-reboot; integrated into
  `reboot_manager_and_wait`. Bypass with `NSX_SKIP_CLUSTER_GATE=1`.
  Tunables: `NSX_CLUSTER_STABLE_TIMEOUT` (600s), `NSX_CLUSTER_STABLE_INTERVAL` (15s).
- `--dry-run` flag in `nsx_rolling_reboot.sh` to preview the reboot plan.
- `--resume` (state-based) and `--resume-from <ip>` (manual) flags in
  `nsx_rolling_reboot.sh`. State file at `run/rolling_state`.
- `ssh_admin_retry` helper with linear backoff for read-only commands.
- `rotate_logs [days] [dir]` helper, called at end of each automation.
  Honors `NSX_LOG_RETENTION_DAYS` (default 30).
- `NSX_NOTIFY_WEBHOOK` opt-in hook: `log_err` posts the message to a
  Slack/Teams-compatible webhook (best-effort, never blocks).
- `precheck_bundle_for <ip>` extracted to `lib/nsx_edge.sh`; both
  `nsx_sb_main.sh` and `nsx_sb_precheck.sh` now call it (eliminating drift).
- GitHub Actions workflow `.github/workflows/lint.yml`: shellcheck + bats.
- `tests/test_parsers.bats` covering parsers and security-defense of the
  managers.conf parser.
- `CHANGELOG.md` (this file) and compatibility matrix in README.

### Changed
- `register_manager_admin_key` now accepts `[key_type]` (default `ssh-rsa`).
  `bin/configure_ssh_keys.sh` auto-detects the type from the public key.
- `register_edge_admin_key` and `register_edge_root_key` capture the CLI
  response and classify "already registered" vs "newly registered" vs
  "unexpected response". They return 0/1 instead of swallowing errors.
- `parse_managers_conf` uses bash 4.3 namerefs (`declare -n`) instead of
  `eval` for dynamic arrays. Hosts and usernames are validated against a
  strict regex (IPv4 OR FQDN-like) — shell metacharacters are rejected.
- `bin/deploy.sh` no longer uses `eval`; commands run via argv array.

### Security
- `parse_managers_conf` rejects shell metacharacters and tokens like
  `rm` / `-rf` from `hosts =` and `admin_user =` values.
- `bin/deploy.sh`: removed `eval`-based command construction.

### Changed (cleanup)
- PT→EN refactor: globals renamed for consistency across the codebase.
  - `PC_ACAO` → `PC_ACTION`, `PC_DURACAO` → `PC_DURATION`
  - `PCR_ACAO` → `PCR_ACTION`, `PCR_DURACAO` → `PCR_DURATION`
  - `nsx_ssh_cli.sh`: drop bilingual builtins `nos` / `historico`
    (English `nodes` / `history` only).
  - `docs/ARCHITECTURE.md` Principle 1 reworded in English.
- Docs sync sweep: `docs/MANUAL.md`, `docs/CONTRIBUTING.md`, the per-automation
  READMEs, and `bin/configure_ssh_keys.sh` header brought in line with the
  new helpers, env vars, and flags (`--dry-run`, `--resume`,
  cluster STABLE gate, `rotate_logs`, `NSX_NOTIFY_WEBHOOK`, `NSX_DEBUG`).

## [1.0.0] — initial unified release

Merged the two source repos into a single layered toolkit:
- `nsx-edge-automation`
- `nsx-rolling-reboot`

### Layout
- `lib/common.sh`, `lib/nsx_edge.sh`, `lib/nsx_manager.sh`
- `automations/edge_support_bundle/`
- `automations/kb404700_disk_validation/`
- `automations/manager_rolling_reboot/`
- `bin/deploy.sh`, `bin/configure_ssh_keys.sh`
