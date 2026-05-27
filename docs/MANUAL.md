# Manual

General notes that apply across all automations.

## Folder convention

```
automations/<name>/
├── README.md
├── <main_script>.sh
├── <hosts>.example          # committed template
└── <hosts>.txt|.conf        # your real hosts (git-ignored)
```

## Common usage pattern

```bash
cd automations/<name>
cp <hosts>.example <hosts>.txt   # or managers.conf for Managers
vim <hosts>.txt
./<main>.sh
```

## Logs

Each automation writes timestamped logs to its own `logs/` (git-ignored). At the end of each run, `rotate_logs` prunes files older than `NSX_LOG_RETENTION_DAYS` (default 30) — set it to `0` to keep everything.

## Notifications (optional)

Set `NSX_NOTIFY_WEBHOOK=https://hooks.example/...` (Slack/Teams compatible) and every `log_err` call POSTs a one-line summary to the webhook. Best-effort and never blocks the run — a broken webhook will not mask the original error.

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
# Edges
./bin/configure_ssh_keys.sh --type edge \
    --hosts automations/edge_support_bundle/edge_nodes.txt

# Managers (parses managers.conf for multi-cluster)
./bin/configure_ssh_keys.sh --type manager \
    --hosts automations/manager_rolling_reboot/managers.conf
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

`nsx_rolling_reboot.sh` iterates each cluster in order, reboots each host sequentially honoring `NSX_REBOOT_INTERVAL` (default 3600s). After TCP comes back, the script polls `get cluster status` on the host until the cluster reports `STABLE` (`NSX_CLUSTER_STABLE_TIMEOUT`, default 600s) before moving to the next host — TCP up does **not** mean the cluster has reconciled. Bypass with `NSX_SKIP_CLUSTER_GATE=1` only when investigating. A single global lock file prevents overlapping crontab runs.

The script supports `--dry-run` (preview only), `--resume` (continue from `run/rolling_state` after a crash) and `--resume-from <ip>` (manual override). See `automations/manager_rolling_reboot/README.md` for details.

## Crontab

```bash
# Production: day 1 of every month at 02:00
./automations/manager_rolling_reboot/install_crontab.sh

# Test cadence: every 30 min (lock prevents overlap)
./automations/manager_rolling_reboot/install_crontab_test.sh

# Remove
./automations/manager_rolling_reboot/uninstall.sh
```

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
