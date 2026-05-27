# Automation: Manager Rolling Reboot

Automated monthly rolling reboot of NSX-T Managers — mitigates **Bug [KB 396719](https://knowledge.broadcom.com/external/article?articleId=396719)** (NSX-T 4.2.1.3), which degrades services when Manager uptime exceeds 30 days.

Refactored from `nsx-rolling-reboot/deploy_nsx_v14.sh`. Supports **multi-cluster** out of the box — define each cluster in `managers.conf`.

## Workflow

```
nsx_rolling_reboot.sh
  ├── Parses managers.conf (multi-cluster, INI-style)
  ├── (optional) loads run/rolling_state for --resume
  ├── For each cluster:
  │     For each host in cluster:
  │       ├── write run/rolling_state (cluster_idx | host_idx | ip | ts)
  │       ├── ssh_admin "$ip" "reboot"
  │       ├── wait for TCP/22 to drop          (NSX_REBOOT_MAX_WAIT)
  │       ├── wait for TCP/22 to return        (NSX_REBOOT_MAX_WAIT)
  │       └── poll `get cluster status` until STABLE
  │                (NSX_CLUSTER_STABLE_TIMEOUT, bypass with
  │                 NSX_SKIP_CLUSTER_GATE=1)
  │       (sleep NSX_REBOOT_INTERVAL between hosts)
  ├── On clean cluster completion: rm run/rolling_state
  ├── log_err → optional POST to NSX_NOTIFY_WEBHOOK
  └── Lock file in /tmp prevents overlapping crontab runs
       (lock is skipped in --dry-run).
```

## Setup

```bash
cd automations/manager_rolling_reboot

# 1. Define your clusters
cp managers.conf.example managers.conf
vim managers.conf

# 2. Register SSH key on every Manager so the script runs unattended
../../bin/configure_ssh_keys.sh --type manager --hosts ./managers.conf
```

The `configure_ssh_keys.sh` step generates `~/.ssh/id_rsa` if needed, then registers it as an admin SSH key on each Manager via NSX CLI (`set user admin ssh-keys label ... value ...`). After that, all subsequent SSH access works without a password.

## Run

```bash
# Validate a single host (always safe to repeat)
./test_reboot_single.sh 192.168.20.10

# Preview — show the reboot plan without acting on anything
./nsx_rolling_reboot.sh --dry-run

# Production — full multi-cluster cycle
./nsx_rolling_reboot.sh

# Resume after a crash / killed cron — picks up from run/rolling_state
./nsx_rolling_reboot.sh --resume

# Manual override (skips earlier hosts in the FIRST cluster, then continues)
./nsx_rolling_reboot.sh --resume-from 192.168.20.11

# Install crontab
./install_crontab.sh           # day 1 of every month at 02:00
./install_crontab_test.sh      # every 30 min (lock file prevents overlap)
./uninstall.sh                 # removes crontab + clears lock
```

## Tunables (env vars honored by nsx_rolling_reboot.sh)

| Var | Default | Meaning |
|---|---|---|
| `MANAGERS_CONF` | `./managers.conf` | Path to the cluster config |
| `LOCK_FILE` | `/tmp/nsx_rolling_reboot.lock` | Lock file path |
| `STATE_FILE` | `run/rolling_state` | Resume bookkeeping; auto-removed on clean cluster completion |
| `NSX_REBOOT_INTERVAL` | `3600` | Seconds between manager reboots |
| `NSX_REBOOT_MAX_WAIT` | `900` | Max seconds waiting for TCP down or up |
| `NSX_CLUSTER_STABLE_TIMEOUT` | `600` | Max seconds polling `get cluster status` for STABLE |
| `NSX_CLUSTER_STABLE_INTERVAL` | `15` | Poll interval for STABLE |
| `NSX_SKIP_CLUSTER_GATE` | _(unset)_ | Set to `1` to skip the STABLE gate (NOT recommended in prod) |
| `NSX_LOG_RETENTION_DAYS` | `30` | Days kept by `rotate_logs` at the end of each run |
| `NSX_NOTIFY_WEBHOOK` | _(unset)_ | If set, every `log_err` POSTs to this Slack/Teams-compatible URL |
| `NSX_DEBUG` | _(unset)_ | Set to `1` to surface SSH stderr (auth/host-key troubleshooting) |
| `ADMIN_KEY` | `~/.ssh/id_rsa` | Private key used by `ssh_admin` |

## Logs

Per-run timestamped log at `logs/rolling_reboot_<ts>.log`.

## Dependencies

Scripts source:
- `lib/common.sh`     — log, crontab helper, TCP probe
- `lib/nsx_manager.sh` — multi-cluster parser, reboot+wait, key registration
