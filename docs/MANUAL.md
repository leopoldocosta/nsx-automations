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

Each automation writes timestamped logs to its own `logs/` (git-ignored).

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

By default the key registered is `~/.ssh/id_rsa` (RSA, required for NSX CLI on Managers). Use `--key <path>` to override.

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

`nsx_rolling_reboot.sh` iterates each cluster in order, reboots each host sequentially honoring `NSX_REBOOT_INTERVAL` (default 3600s). A single global lock file prevents overlapping crontab runs.

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
| Bundle still in `FILE_NOT_FOUND` | Generation in progress | rerun after a few minutes |
| `bash -n` warns on `(( ))` | Old bash on target | use Bash ≥ 4.2 |
