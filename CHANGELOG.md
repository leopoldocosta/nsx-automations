# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- New library `lib/nsx_api.sh`: NSX Manager/Policy REST helpers — safe Basic-Auth
  curl (credentials never reach `ps`; any special character accepted via raw
  base64), GET/PATCH, cursor pagination, LB-service `realization_id` resolution,
  and pool lookup by member ip+port (the Edge<->Policy id-mismatch workaround).
- New automation `lb_troubleshoot/`: diagnoses an NSX-T native LB with a down
  virtual server / off pool members. Resolves the three id namespaces (Policy,
  realization/Edge, object path), classifies the Edge `health-check-table`
  (`BACKEND_DOWN` / `MONITOR_MISMATCH` / `TIMEOUT_FILTER`), root-causes a member,
  and can PATCH the pool monitor (guarded by an explicit confirmation). Ships an
  API-error / FAIL_REASON decoder. Built from a real incident (HTTP monitor
  probing an HTTPS/SSL backend). Fan-out safe: `--manager` falls back to the
  jump's central `inventory/managers.conf`, credentials come from the
  environment or a saved session (never prompts without a TTY), `--edge` uses
  the registered `ADMIN_KEY`, and `--fix-monitor` requires `--yes` when
  non-interactive — so one `run_across_datacenters.sh --only-dc <DC>` command
  troubleshoots an LB in any datacenter from the orchestrator.
- **`notify.conf` — central per-VM notification config**: `[slack] webhook`
  plus `[notify]` policy per automation (`errors`/`none`, `default` key,
  automation folder name as key; bin/ tools report as `orchestrator`).
  `log_err` consults it before posting; `NSX_NOTIFY_WEBHOOK` env still
  overrides everything (legacy opt-in behavior). Webhook value validated
  against a strict URL regex; the real file is git-ignored (credential),
  `notify.conf.example` committed.
- New automation `device_command/`: run a read-only NSX CLI command on every
  device of the local DC — all manager clusters (multi-cluster aware, e.g.
  infrabase + workload domain) and/or all edge nodes — producing a
  consolidated table + CSV (`type,cluster,ip,exit_code,output`). Never
  prompts (fan-out safe); exit code = number of failed devices. Fanned out
  from the orchestrator it answers "get uptime of the whole estate" in one
  command, with per-device CSVs pulled back to `aggregated_logs/`.
- `bin/run_command_across_dcs.sh` — ad-hoc runner: execute ANY shell command
  on every DC jump (or one, with `--only-dc`) with the same SSH posture as
  the automation fan-out. Streamed per-DC output, summary table, exit code =
  number of failed DCs. Recommended first smoke-test of the SSH mesh.
- **Central per-DC inventory** (`inventory/` at repo root): `edge_nodes.txt`
  and `managers.conf` live once per jump VM and every automation reads them
  via the new `resolve_inventory_file` helper (an automation-local file still
  wins — intentional subset override). Removes the 3-way `edge_nodes.txt`
  duplication across the edge automations. `bin/configure_ssh_keys.sh`
  `--hosts` is now optional and defaults to the central inventory.
  Covered by `tests/test_inventory_resolver.bats`.
- **Daily 1-manager/day rolling reboot orchestrator** — production-cadence
  replacement for the old "all managers on day 1 of the month" cron.
  Operators with ~21 managers across multiple DCs now reboot **one
  manager per day** following an explicit, ordered plan.
  - New `bin/rolling_reboot_next.sh` (orchestrator entrypoint): reads
    `reboot_plan.conf` + `run/rolling_global_state`, resolves the next
    `<DC> <ip>` entry, calls
    `bin/run_across_datacenters.sh --only-dc <DC> -- --only <ip>`,
    advances the index only on rc=0 (so a failure is retried the
    following day, not silently skipped). Flags: `--dry-run`, `--list`,
    `--show-state`, `--reset --yes`, `--advance`.
  - New `bin/install_orchestrator_cron.sh` / `bin/uninstall_orchestrator_cron.sh`
    (the latter supports `--purge-state`). Default schedule 02:00 daily,
    override with `CRON_HOUR` / `CRON_MINUTE`.
  - New `parse_reboot_plan <file>` + `plan_dc/plan_ip <idx>` helpers in
    `lib/common.sh`. Strict syntax validation: rejects shell metacharacters,
    malformed lines, duplicate IPs (covered by `tests/test_reboot_plan.bats`,
    4 asserts including the injection fixture).
  - New `bin/run_across_datacenters.sh --only-dc <label>` flag — restricts
    the fan-out to a single DC. Used by the daily orchestrator script.
  - New `--only <ip>` flag in `automations/manager_rolling_reboot/nsx_rolling_reboot.sh`:
    reboots a single manager, auto-resolving its cluster and `admin_user`
    from `managers.conf`. Mutually exclusive with `--resume`/`--resume-from`.
  - New `find_cluster_for_ip` + `reboot_one_manager_by_ip` helpers in
    `lib/nsx_manager.sh`.
  - New `reboot_plan.example` at the repo root (template, committed);
    `reboot_plan.conf` added to `.gitignore`.
  - Documented in `docs/MULTIDC.md` ("Daily rolling reboot" section + plan
    schema + full CLI reference) and `docs/MANUAL.md`.
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

### Fixed
- **`reboot_manager_and_wait` never actually rebooted the manager.** The NSX
  CLI `reboot` command asks `Are you sure you want to reboot (yes/no)` even
  on a non-TTY SSH session, but shows no prompt — the session blocked until
  the CLI idle timeout (~7 min observed on 4.1.2.3) and the manager stayed
  up. The confirmation is now fed via stdin (`<<<"yes"`), the same
  stdin-feed strategy already used by the key registrars. Additionally, a
  manager that does not drop offline within `NSX_REBOOT_MAX_WAIT` is now a
  **hard failure** (rc=1) instead of a warning — previously the cycle would
  trivially pass the TCP-up and STABLE gates and report success for a
  manager that never rebooted, silently advancing the daily orchestrator's
  plan index.
- **`bin/deploy.sh` no longer destroys target-side state on re-deploy.**
  The rsync used `--delete-excluded`, which deletes *excluded* paths on the
  receiver — every re-deploy wiped the jump's `.ssh_keys/` (registered NSX
  keys), `run/` (resume state) and `logs/`; the implied `--delete` also
  removed any jump-local `managers.conf`/`edge_nodes.txt` absent from the
  sender. Now uses plain `--delete` (stale code is still pruned; excluded
  runtime paths are protected) plus explicit protection for
  `edge_nodes.txt`, `managers.conf`, `hosts.txt`, `datacenters.conf` and
  `reboot_plan.conf`. `inventory/` templates are now shipped by deploy too.

### Security
- `parse_managers_conf` rejects shell metacharacters and tokens like
  `rm` / `-rf` from `hosts =` and `admin_user =` values.
- `bin/deploy.sh`: removed `eval`-based command construction.
- `parse_reboot_plan` enforces strict `<label> <IPv4>` syntax and rejects
  shell metacharacters before any value reaches `ssh`/`rsync`.

### Removed
- **Legacy per-jump cron scripts** — `automations/manager_rolling_reboot/install_crontab.sh`,
  `install_crontab_test.sh`, and `uninstall.sh` were the old monthly cron
  that rebooted every manager of a jump on day 1. Replaced by the
  orchestrator-side daily cron (`bin/install_orchestrator_cron.sh`).
  Operators with the old cron should run `crontab -e` and remove the line
  manually, then install the orchestrator cron on the new model.

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
