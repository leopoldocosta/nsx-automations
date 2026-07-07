# Manual

General notes that apply across all automations.

> **New automation?** It stays in Bash by default. It only moves to Go (not Python) when it
> hits a concurrency / heavy-REST / complex-state / volume trigger — see
> [ARCHITECTURE.md → Language strategy](ARCHITECTURE.md#language-strategy-bash-by-default-go-on-demand)
> and [GO_FRAMEWORK.md](GO_FRAMEWORK.md).
>
> **Running across multiple datacenters?** See [MULTIDC.md](MULTIDC.md) — one orchestrator
> VM fans out to per-DC jump VMs; NSX credentials never leave the DC they belong to.
> Passo a passo de instalação em português: [RUNBOOK_INSTALACAO.md](RUNBOOK_INSTALACAO.md).

## Central inventory (per DC)

Host lists are **datacenter inventory**, not per-automation config. Keep them
once in `inventory/` at the repo root and every automation picks them up:

```
inventory/
├── edge_nodes.txt      # all Edge Nodes of THIS datacenter (git-ignored)
└── managers.conf       # all Manager clusters of THIS datacenter (git-ignored)
```

Resolution order (`resolve_inventory_file` in `lib/common.sh`):

1. Automation-local file (e.g. `automations/<name>/edge_nodes.txt`) — if present,
   it **wins**. That is the intentional override for running against a subset.
2. Central `inventory/<same-name>`.
3. Neither → clear error pointing at the local path.

`bin/configure_ssh_keys.sh` also defaults `--hosts` to the central inventory.

## Folder convention

```
automations/<name>/
├── README.md
├── <main_script>.sh
├── <hosts>.example          # committed template
└── <hosts>.txt|.conf        # OPTIONAL subset override (git-ignored);
                             #   omit to use inventory/ (recommended)
```

## Common usage pattern

```bash
# Once per jump VM: fill the central inventory
cp inventory/edge_nodes.example    inventory/edge_nodes.txt
cp inventory/managers.conf.example inventory/managers.conf
vim inventory/edge_nodes.txt inventory/managers.conf

# Then any automation just runs
cd automations/<name>
./<main>.sh
```

## Logs

Each automation writes timestamped logs to its own `logs/` (git-ignored). At the end of each run, `rotate_logs` prunes files older than `NSX_LOG_RETENTION_DAYS` (default 30) — set it to `0` to keep everything.

## Notifications (optional) — notify.conf

Central per-VM config deciding **which automations** post errors to a
Slack/Teams channel:

```bash
cp notify.conf.example notify.conf && chmod 600 notify.conf   # git-ignored
vim notify.conf
```

```ini
[slack]
webhook = https://hooks.slack.com/services/XXX/YYY/ZZZ

[notify]
default = errors                 # policy for every automation: errors | none
device_command = none            # per-automation override (folder name)
manager_rolling_reboot = errors
orchestrator = errors            # the bin/ tools on the orchestrator
```

Each `log_err` from an enabled automation POSTs `[NSX][<host>] ERR: <msg>`
to the webhook. Best-effort and never blocks the run — a broken webhook will
not mask the original error. The webhook URL is a **credential** (posting
rights to the channel): keep the file mode 600, never commit it.

The `NSX_NOTIFY_WEBHOOK` env var, when set, overrides the file entirely
(always notifies errors) — handy for ad-hoc runs.

## Debugging SSH issues

`ssh_admin` / `ssh_root` suppress stderr for clean stdout capture. When troubleshooting host-key mismatches, MaxAuthTries, or kex resets, run with:

```bash
NSX_DEBUG=1 ./<some_automation>.sh
```

## Cross-cutting env vars

These are honored by every automation:

| Var | Default | Effect |
|---|---|---|
| `NSX_DEBUG` | _(unset)_ | `1` lets SSH stderr through (troubleshooting) |
| `NSX_LOG_RETENTION_DAYS` | `30` | Days of `logs/` kept by `rotate_logs` |
| `NSX_NOTIFY_WEBHOOK` | _(unset)_ | Slack/Teams URL that receives each `log_err` |

Manager-specific tunables live in `automations/manager_rolling_reboot/README.md`. Edge support-bundle tunables (`NSX_BUNDLE_RECENT_DAYS`) live in `automations/edge_support_bundle/README.md`.

## Credentials

- Prompted interactively (`read -rsp`), never stored on disk.
- Lifetime = the script's process unless `save_session_env` is called, in which case they live in `run/session.env` (mode 600) until the auto-clear timer expires (default 30 min).
- `_sshpass_safe` writes the password to a tmp file (mode 600) before invoking `sshpass -e`; password is never visible in `ps` output.

## SSH Keys

After running `bin/configure_ssh_keys.sh` once, subsequent automations skip the password prompt:

```bash
# Edges (reads inventory/edge_nodes.txt by default)
./bin/configure_ssh_keys.sh --type edge

# Managers (reads inventory/managers.conf by default; multi-cluster aware)
./bin/configure_ssh_keys.sh --type manager

# Point at a different list explicitly
./bin/configure_ssh_keys.sh --type edge --hosts <path>
```

By default the key registered is `~/.ssh/id_rsa`. The script reads the public-key header (`ssh-rsa`, `ssh-ed25519`, …) and passes the correct `type` token to the NSX CLI, so both RSA and ed25519 keys work on Managers and Edges. Use `--key <path>` to point at a different private key.

## Multi-cluster (Manager rolling reboot)

`managers.conf` uses INI sections — one per cluster:

```ini
[GER1]
hosts = 192.168.20.10, 192.168.20.11, 192.168.20.12
admin_user = admin

[GER2]
hosts = 192.168.30.10, 192.168.30.11, 192.168.30.12
admin_user = admin
```

`nsx_rolling_reboot.sh` iterates each cluster in order, reboots each host sequentially honoring `NSX_REBOOT_INTERVAL` (default 3600s). After TCP comes back, the script polls `get cluster status` on the host until the cluster reports `STABLE` (`NSX_CLUSTER_STABLE_TIMEOUT`, default 600s) before moving to the next host — TCP up does **not** mean the cluster has reconciled. Bypass with `NSX_SKIP_CLUSTER_GATE=1` only when investigating. A single global lock file prevents overlapping runs.

Flags:
- `--dry-run` — preview only
- `--resume` — continue from `run/rolling_state` after a crash
- `--resume-from <ip>` — manual override
- `--only <ip>` — reboot a single manager (cluster + admin_user auto-resolved from `managers.conf`). Used by the orchestrator's daily cron — see [MULTIDC.md → Daily rolling reboot](MULTIDC.md#daily-rolling-reboot--1-manager--day-multi-dc).

See `automations/manager_rolling_reboot/README.md` for the full reference.

## Scheduling

The legacy per-jump crontab scripts have been **removed**. The supported scheduling model is now a single daily cron on the orchestrator VM that walks an ordered plan one entry per day. Install on the orchestrator:

```bash
# One-time: copy the template, then edit (lives at the repo root)
cp reboot_plan.example reboot_plan.conf
vim reboot_plan.conf

./bin/install_orchestrator_cron.sh           # daily at 02:00 (CRON_HOUR=H CRON_MINUTE=M to override)
./bin/uninstall_orchestrator_cron.sh         # remove cron (--purge-state also wipes state)
```

See [MULTIDC.md](MULTIDC.md) for the orchestrator topology and the full `rolling_reboot_next.sh` CLI.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Missing required command: sshpass` | sshpass not installed | run `bin/deploy.sh --deps` or `install_pkg sshpass` |
| `Permission denied (publickey,password)` | Key not yet registered on target | run `bin/configure_ssh_keys.sh --type …` |
| `get managers` hangs | Manager rebooting or unreachable | `tcp_check <ip>` first |
| Rolling reboot exits `[LOCKED]` | Previous run still active | check `/tmp/nsx_rolling_reboot.lock` |
| Rolling reboot stuck "waiting for STABLE" | Cluster not reconciling | inspect on the host: `get cluster status`; or set `NSX_SKIP_CLUSTER_GATE=1` to bypass once |
| Crashed mid-cycle, want to continue | n/a | `./nsx_rolling_reboot.sh --resume` reads `run/rolling_state` |
| Bundle still in `FILE_NOT_FOUND` | Generation in progress | rerun after a few minutes |
| SSH fails but `log_err` is silent | stderr suppressed | rerun with `NSX_DEBUG=1` |
| Need to wipe a single Manager from state | n/a | `rm <auto>/run/rolling_state` |
| `bash -n` warns on `(( ))` | Old bash on target | use Bash ≥ 4.3 (namerefs) |
