# Automation: Manager Rolling Reboot

Automated monthly rolling reboot of NSX-T Managers — mitigates **Bug [KB 396719](https://knowledge.broadcom.com/external/article?articleId=396719)** (NSX-T 4.2.1.3), which degrades services when Manager uptime exceeds 30 days.

Refactored from `nsx-rolling-reboot/deploy_nsx_v14.sh`. Supports **multi-cluster** out of the box — define each cluster in `managers.conf`.

## Workflow

```
nsx_rolling_reboot.sh
  ├── Parses managers.conf (multi-cluster, INI-style)
  ├── For each cluster:
  │     For each host in cluster:
  │       ├── ssh_admin "$ip" "reboot"
  │       ├── wait for TCP/22 to drop
  │       └── wait for TCP/22 to return
  │       (sleep NSX_REBOOT_INTERVAL between hosts)
  └── Lock file in /tmp prevents overlapping crontab runs.
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
# Validate
./test_reboot_single.sh 192.168.20.10    # safe test on one host

# Production — runs the full multi-cluster cycle
./nsx_rolling_reboot.sh

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
| `NSX_REBOOT_INTERVAL` | `3600` | Seconds between manager reboots |
| `NSX_REBOOT_MAX_WAIT` | `900` | Max seconds waiting for down or up |
| `ADMIN_KEY` | `~/.ssh/id_rsa` | Private key used by `ssh_admin` |

## Logs

Per-run timestamped log at `logs/rolling_reboot_<ts>.log`.

## Dependencies

Scripts source:
- `lib/common.sh`     — log, crontab helper, TCP probe
- `lib/nsx_manager.sh` — multi-cluster parser, reboot+wait, key registration
