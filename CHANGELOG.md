# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Multi-datacenter fan-out** — a single orchestrator VM can now run any
  automation in every datacenter without copying NSX credentials around.
  - New `bin/run_across_datacenters.sh`: iterates `datacenters.conf`, opens
    SSH to each jump VM with `BatchMode=yes`, `ForwardAgent=no`,
    `IdentitiesOnly=yes`; captures stdout+stderr per DC; rsync-pulls the
    automation's `logs/` back to `aggregated_logs/<ts>/<DC>/`; writes
    `summary.csv` (`dc,start,end,duration_s,exit_code,log_path`).
    Supports `--parallel N` (uses `wait -n`, no `xargs -P` fragility),
    `--no-pull-logs`, `--out <dir>`, `--ssh-key <override>`, and `--`
    pass-through to the remote automation (e.g. `-- --dry-run`).
  - `bin/deploy.sh --all-dcs --conf <file>`: deploy the toolkit to every
    jump in `datacenters.conf` in one command. Single-target mode kept.
  - New `parse_datacenters_conf` + `dc_jump_host/dc_jump_user/dc_repo_path/dc_ssh_key`
    in `lib/common.sh`. Strict regex validation of every field rejects
    shell metacharacters (covered by `tests/test_datacenters_parser.bats`,
    9 asserts including path-traversal and `$()` injection).
  - New `docs/MULTIDC.md`: topology diagram, security principles,
    one-time setup, schema, CLI reference, and the trigger for moving to
    Go (links to `GO_FRAMEWORK.md`).
  - `datacenters.conf` is git-ignored; `datacenters.conf.example` committed.
  - `aggregated_logs/` added to `.gitignore`.
- Documented **language strategy**: Bash by default, Go on demand. New
  `docs/GO_FRAMEWORK.md` defines the Go stack (`golang.org/x/crypto/ssh`,
  `errgroup` + semaphore, `cobra`, `gopkg.in/ini.v1`, `net/http`, `log/slog`)
  and layout to use **when** a future automation crosses a concurrency / heavy-REST /
  complex-state / volume trigger. Existing Bash code is unchanged.
  `docs/ARCHITECTURE.md` gained the corresponding trigger table and the
  "Go, not Python" rationale; `docs/MANUAL.md` got a top-of-file pointer.
- New automation `edge_hardware_inventory/`: collects Dell PowerEdge model and
  Service Tag from each Edge Node via `dmidecode` over root SSH. Produces both
  a human-readable `.txt` report and a `.csv` side-output. Flags VM edges as
  `NOT_DELL` and missing/placeholder service tags as `MISSING_TAG`.
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
