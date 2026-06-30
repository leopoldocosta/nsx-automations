# Automation: Manager Rolling Reboot

Mitigation for **Bug [KB 396719](https://knowledge.broadcom.com/external/article?articleId=396719)** (NSX-T 4.2.1.3), which degrades services when Manager uptime exceeds 30 days.

Refactored from `nsx-rolling-reboot/deploy_nsx_v14.sh`. Supports **multi-cluster** out of the box (`managers.conf`) **and** a multi-datacenter daily cadence via the orchestrator (see [docs/MULTIDC.md → Daily rolling reboot](../../docs/MULTIDC.md)).

## Two operation modes

| Mode | Driven by | Cadence | Use when |
|---|---|---|---|
| **Single-jump full cycle** | this script invoked locally on a jump | one shot — all managers of all clusters | Manual ops, lab cluster, single-DC site |
| **Daily 1-manager/day, multi-DC** | `bin/rolling_reboot_next.sh` on the **orchestrator** + a daily cron | 1 manager per firing across all DCs (e.g. 21 managers → 21 days) | Production with multiple DCs and many managers |

Both modes share the same `nsx_rolling_reboot.sh` and the same `lib/nsx_manager.sh` primitives. The orchestrator just calls `nsx_rolling_reboot.sh --only <ip>` against the right DC each day.

## Workflow (single-jump full cycle)

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
  └── Lock file in /tmp prevents overlapping runs
       (lock is skipped in --dry-run).
```

## Workflow (daily 1-manager/day, multi-DC)

```
[ orchestrator VM ]
  cron 02:00 →  bin/rolling_reboot_next.sh
                  ├── reads reboot_plan.conf (ordered "<DC> <ip>" lines)
                  ├── reads run/rolling_global_state (current index)
                  ├── resolves (DC, ip) of the next entry
                  └── bin/run_across_datacenters.sh --only-dc <DC>
                        -- --only <ip>                       ┐
                                                              │
[ DC jump VM ]                                                │
  nsx_rolling_reboot.sh --only <ip>     ◀ ─────────────── SSH ┘
    ├── parses managers.conf (cluster discovery for that IP)
    ├── exports the cluster's admin_user
    ├── ssh_admin "$ip" "reboot"
    ├── waits TCP/22 drop+return
    └── polls cluster STABLE → exit 0
```

On rc=0 the orchestrator advances the index; on rc≠0 the index is **not** advanced — the next cron firing retries the same manager. Operators can `--list`, `--show-state`, `--reset --yes`, or `--advance` (skip one).

## Setup (single jump)

```bash
cd automations/manager_rolling_reboot
cp managers.conf.example managers.conf
vim managers.conf
../../bin/configure_ssh_keys.sh --type manager --hosts ./managers.conf
```

## Run (single jump)

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

# Reboot ONE specific manager (the cluster + admin_user are auto-resolved
# from managers.conf). Used by the orchestrator's daily cron.
./nsx_rolling_reboot.sh --only 192.168.20.10
```

`--only`, `--resume`, and `--resume-from` are mutually exclusive.

## Setup & run (orchestrator-side daily cadence)

See [docs/MULTIDC.md → Daily rolling reboot](../../docs/MULTIDC.md). TL;DR on the orchestrator VM:

```bash
cp reboot_plan.example reboot_plan.conf
vim reboot_plan.conf                         # 1 line per manager, ordered

./bin/rolling_reboot_next.sh --list          # show the plan
./bin/rolling_reboot_next.sh --dry-run       # preview tomorrow's victim

./bin/install_orchestrator_cron.sh           # daily 02:00 (CRON_HOUR=H CRON_MINUTE=M to override)
```

## Tunables (env vars honored by `nsx_rolling_reboot.sh`)

| Var | Default | Meaning |
|---|---|---|
| `MANAGERS_CONF` | `./managers.conf` | Path to the cluster config |
| `LOCK_FILE` | `/tmp/nsx_rolling_reboot.lock` | Lock file path |
| `STATE_FILE` | `run/rolling_state` | Resume bookkeeping (full-cycle mode); auto-removed on clean completion |
| `NSX_REBOOT_INTERVAL` | `3600` | Seconds between manager reboots (full-cycle mode only — daily mode has a 24h natural gap) |
| `NSX_REBOOT_MAX_WAIT` | `900` | Max seconds waiting for TCP down or up |
| `NSX_CLUSTER_STABLE_TIMEOUT` | `600` | Max seconds polling `get cluster status` for STABLE |
| `NSX_CLUSTER_STABLE_INTERVAL` | `15` | Poll interval for STABLE |
| `NSX_SKIP_CLUSTER_GATE` | _(unset)_ | Set to `1` to skip the STABLE gate (NOT recommended in prod) |
| `NSX_LOG_RETENTION_DAYS` | `30` | Days kept by `rotate_logs` at the end of each run |
| `NSX_NOTIFY_WEBHOOK` | _(unset)_ | If set, every `log_err` POSTs to this Slack/Teams-compatible URL |
| `NSX_DEBUG` | _(unset)_ | Set to `1` to surface SSH stderr (auth/host-key troubleshooting) |
| `ADMIN_KEY` | `~/.ssh/id_rsa` | Private key used by `ssh_admin` |

## Logs

Per-run timestamped log at `logs/rolling_reboot_<ts>.log`. In the multi-DC daily mode, the orchestrator's `aggregated_logs/<ts>/<DC>/{run.log,logs/}` contains both the SSH session output and the rsync'd remote log.

## Dependencies

Scripts source:
- `lib/common.sh`     — log, crontab helper, TCP probe, plan + DC parsers
- `lib/nsx_manager.sh` — multi-cluster parser, reboot+wait, `reboot_one_manager_by_ip`
