# Multi-datacenter operation

Run an automation in every datacenter from a single orchestrator VM, while
keeping NSX credentials **scoped to each datacenter**.

## Topology

```
                  ┌────────────────────────────────┐
                  │  ORCHESTRATOR VM               │
                  │  (in DC-Primary or anywhere    │
                  │   that can reach the jumps)    │
                  │                                │
                  │  - nsx-automations clone       │
                  │  - datacenters.conf            │
                  │  - aggregated_logs/<ts>/...    │
                  │  - ~/.ssh/nsx_dc_fanout        │
                  └───────────────┬────────────────┘
                                  │  SSH (dedicated key, no agent forwarding)
              ┌───────────────────┼────────────────────┐
              ▼                   ▼                    ▼
       ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
       │ DC-A jump   │     │ DC-B jump   │     │ DC-C jump   │
       │ Linux VM    │     │ Linux VM    │     │ Linux VM    │
       │  - toolkit  │     │  - toolkit  │     │  - toolkit  │
       │  - hosts    │     │  - hosts    │     │  - hosts    │
       │    of DC-A  │     │    of DC-B  │     │    of DC-C  │
       │  - NSX key  │     │  - NSX key  │     │  - NSX key  │
       │    for DC-A │     │    for DC-B │     │    for DC-C │
       └──────┬──────┘     └──────┬──────┘     └──────┬──────┘
              │ NSX CLI / API     │                   │
              ▼                   ▼                   ▼
       ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
       │  NSX DC-A   │     │  NSX DC-B   │     │  NSX DC-C   │
       └─────────────┘     └─────────────┘     └─────────────┘
```

## Security principles

| Principle | How it is enforced |
|---|---|
| **Different key per hop** | `orchestrator → jump` uses `~/.ssh/nsx_dc_fanout`. `jump → NSX` uses the key `bin/configure_ssh_keys.sh` registered. They are never the same key. |
| **No agent forwarding** | The orchestrator opens every SSH with `-o ForwardAgent=no`. If a jump is compromised it cannot pivot back to other jumps or to NSX in another DC. |
| **Each jump owns only its DC** | A jump has `managers.conf`/`edge_nodes.txt` for **its own** datacenter only — no cross-DC inventories. Blast radius of a jump compromise = 1 DC. |
| **No NSX credentials on the orchestrator** | The orchestrator only knows how to reach the jumps. NSX credentials live on the jump where they were registered. |
| **Pull logs, never push them** | `bin/run_across_datacenters.sh` does `rsync` PULL of `logs/`. A jump never writes to the orchestrator's filesystem. |
| **Anti-injection at the conf parser** | `parse_datacenters_conf` validates `jump_host` against IPv4-or-FQDN, `jump_user` against `[A-Za-z0-9._-]+`, paths against `^/[…]+$`. Shell metacharacters are rejected before they can reach `ssh` or `rsync`. |
| **Per-DC `NSX_NOTIFY_WEBHOOK`** | Set the webhook in `~/.bashrc` of each jump VM. Errors from any DC reach a single channel — even when the orchestrator is offline. |
| **Lock per scope** | The orchestrator has its own lock (`/tmp/nsx_fanout.lock`). Each jump still has its automation-level lock (e.g. `/tmp/nsx_rolling_reboot.lock`). |

## One-time setup

### On each DC jump VM (manual, once)

```bash
# 1. Clone
git clone https://github.com/leopoldocosta/nsx-automations.git ~/nsx-automations
cd ~/nsx-automations

# 2. Inventory of the LOCAL DC only
cp automations/manager_rolling_reboot/managers.conf.example \
   automations/manager_rolling_reboot/managers.conf
vim automations/manager_rolling_reboot/managers.conf
cp automations/edge_support_bundle/edge_nodes.example \
   automations/edge_support_bundle/edge_nodes.txt
vim automations/edge_support_bundle/edge_nodes.txt

# 3. Register the jump's SSH key on the local NSX (one-time)
./bin/configure_ssh_keys.sh --type manager \
   --hosts automations/manager_rolling_reboot/managers.conf
./bin/configure_ssh_keys.sh --type edge \
   --hosts automations/edge_support_bundle/edge_nodes.txt

# 4. Notification + retention (optional)
{
  echo 'export NSX_NOTIFY_WEBHOOK=https://hooks.slack.com/services/XXX/YYY/ZZZ'
  echo 'export NSX_LOG_RETENTION_DAYS=60'
} >> ~/.bashrc
```

### On the orchestrator VM (manual, once)

```bash
git clone https://github.com/leopoldocosta/nsx-automations.git ~/nsx-automations
cd ~/nsx-automations

# Dedicated key for orchestrator -> jump (NOT the same as the NSX keys)
ssh-keygen -t ed25519 -f ~/.ssh/nsx_dc_fanout -N ""

# Distribute the public key to each jump (one-time)
for jump in dc-a-jump.internal dc-b-jump.internal dc-c-jump.internal; do
  ssh-copy-id -i ~/.ssh/nsx_dc_fanout.pub nsxops@$jump
done

# Inventory of datacenters
cp datacenters.conf.example datacenters.conf
vim datacenters.conf

# Mirror the latest code to every jump (one command)
./bin/deploy.sh --all-dcs --conf ./datacenters.conf
```

## Ongoing operation

### Daily rolling reboot — 1 manager / day, multi-DC

Production cadence for KB 396719 mitigation. Instead of "reboot every manager on day 1 of the month" (the old per-jump cron), the orchestrator reboots **one manager per day** following an ordered plan. With ~21 managers across multiple DCs, the cycle runs ~21 days and then idles until the operator resets the plan.

```bash
# One-time setup on the ORCHESTRATOR VM:
cp reboot_plan.example reboot_plan.conf
vim reboot_plan.conf                          # see schema below

./bin/rolling_reboot_next.sh --list           # show ordered plan with [DONE]/[NEXT]/[PENDING]
./bin/rolling_reboot_next.sh --dry-run        # preview tomorrow's target — no state change

./bin/install_orchestrator_cron.sh            # daily at 02:00 (override: CRON_HOUR=H CRON_MINUTE=M)
```

`rolling_reboot_next.sh` on each firing:

1. Reads `reboot_plan.conf` (ordered `<DC-LABEL> <manager-ip>` lines)
2. Reads `run/rolling_global_state` → current index
3. Resolves the next entry and calls
   `bin/run_across_datacenters.sh --only-dc <DC> -- --only <ip>`
4. On rc=0 → advance index. On rc≠0 → index unchanged, cron retries next day.

Operator controls:

```bash
./bin/rolling_reboot_next.sh --show-state     # what was the last action, what's pending
./bin/rolling_reboot_next.sh --advance        # skip next entry (e.g. manager rebooted out-of-band)
./bin/rolling_reboot_next.sh --reset --yes    # restart plan from index 0
./bin/uninstall_orchestrator_cron.sh          # remove cron; --purge-state also wipes state
```

#### `reboot_plan.conf` schema

```text
# orchestrator-side; git-ignored. Order = reboot order.
<DC-LABEL>  <manager-ip>
```

| Field | Validation | Notes |
|---|---|---|
| `<DC-LABEL>` | `[A-Za-z0-9._-]+` | Must match a `[section]` in `datacenters.conf` |
| `<manager-ip>` | IPv4 dotted quad | Must exist in that DC jump's `managers.conf` |

The parser (`lib/common.sh:parse_reboot_plan`) rejects malformed lines, shell metacharacters, and duplicate IPs — same anti-injection posture as `parse_datacenters_conf` (covered by `tests/test_reboot_plan.bats`).

### Ad-hoc multi-DC commands

```bash
# Dry-run the rolling reboot across every DC sequentially (preview only)
./bin/run_across_datacenters.sh \
   --conf ./datacenters.conf \
   --automation manager_rolling_reboot/nsx_rolling_reboot.sh \
   -- --dry-run

# Full multi-cluster reboot of ONE specific DC (operator chooses)
./bin/run_across_datacenters.sh \
   --conf ./datacenters.conf \
   --only-dc DC-A \
   --automation manager_rolling_reboot/nsx_rolling_reboot.sh

# Read-only inventory across all DCs, up to 3 in parallel
./bin/run_across_datacenters.sh \
   --conf ./datacenters.conf \
   --parallel 3 \
   --automation kb404700_disk_validation/kb404700_disk_validation.sh
```

### Keeping every jump in sync with main

```bash
./bin/deploy.sh --all-dcs --conf ./datacenters.conf
```

This rsyncs `lib/`, `bin/`, `docs/`, `automations/` and the README to every
jump listed in `datacenters.conf` (excludes `logs/`, `run/`, `.ssh_keys/`,
and `aggregated_logs/`).

### Output

After every fan-out:

```
aggregated_logs/<YYYYMMDD_HHMMSS>/
├── summary.csv         dc,start,end,duration_s,exit_code,log_path
├── DC-A/
│   ├── run.log         full stdout+stderr captured from the remote run
│   └── logs/           rsync'd from <jump>:<repo>/automations/<auto>/logs/
├── DC-B/
│   └── ...
└── DC-C/
    └── ...
```

## `datacenters.conf` schema

```ini
[DC-A]
jump_host = dc-a-jump.internal.example
jump_user = nsxops
repo_path = /home/nsxops/nsx-automations

[DC-B]
jump_host = 10.20.0.50
jump_user = nsxops
repo_path = /home/nsxops/nsx-automations
ssh_key   = ~/.ssh/nsx_dc_fanout_dcb     # optional per-section override
```

| Field | Required | Validation |
|---|---|---|
| `jump_host` | yes | IPv4 OR FQDN-like (must contain `.`) |
| `jump_user` | yes | `[A-Za-z0-9._-]+` |
| `repo_path` | yes | Absolute path: `^/[A-Za-z0-9._/~-]+$` |
| `ssh_key` | no  | Absolute or `~`-relative path on the orchestrator. Default `~/.ssh/nsx_dc_fanout` (override globally with `NSX_FANOUT_KEY=…`) |

## CLI reference

`bin/run_across_datacenters.sh`:

| Flag | Default | Meaning |
|---|---|---|
| `--conf <file>` | — | datacenters.conf. Required. |
| `--automation <rel>` | — | Path under `automations/`, e.g. `manager_rolling_reboot/nsx_rolling_reboot.sh`. Required. |
| `--parallel N` | `1` | Cap on concurrent DCs (uses `wait -n`). |
| `--only-dc <label>` | _(all DCs)_ | Fan out to ONLY this DC label. Used by `rolling_reboot_next.sh`. |
| `--no-pull-logs` | _(off)_ | Skip the rsync pull of `logs/`. |
| `--out <dir>` | `aggregated_logs/<ts>/` | Local aggregation dir. |
| `--ssh-key <path>` | per-DC | Override every `ssh_key` from the conf. |
| `--` | — | Everything after `--` is forwarded verbatim to the remote automation. |

`bin/rolling_reboot_next.sh` (orchestrator, daily cron entrypoint):

| Flag | Default | Meaning |
|---|---|---|
| `--conf <file>` | `./datacenters.conf` | DC inventory. |
| `--plan <file>` | `./reboot_plan.conf` | Ordered `<DC> <ip>` plan (git-ignored). |
| `--state <file>` | `run/rolling_global_state` | Index + last_run bookkeeping (auto-managed). |
| `--dry-run` | _(off)_ | Forward `--dry-run` to the remote automation. Does NOT advance the index. |
| `--list` | _(off)_ | Print plan with `[DONE]/[NEXT]/[PENDING]` markers and exit. |
| `--show-state` | _(off)_ | Print current state (index, last_dc, last_ip, last_run, last_status) and exit. |
| `--reset --yes` | _(off)_ | Reset index to 0. Requires `--yes` when run non-interactively. |
| `--advance` | _(off)_ | Skip the next entry without rebooting it (records `last_status=skipped`). |

`bin/deploy.sh`:

| Flag | Default | Meaning |
|---|---|---|
| `--target <user@host:path>` | — | Single destination. Mutually exclusive with `--all-dcs`. |
| `--all-dcs` | _(off)_ | Loop over `datacenters.conf` and deploy to each jump. |
| `--conf <file>` | — | Required with `--all-dcs`. |
| `--automation <name>` | _(all)_ | Restrict to one automation directory. |
| `--deps` | _(off)_ | Run `install_pkg openssh-client sshpass` on the target. |
| `--dry-run` | _(off)_ | Print the plan, do nothing. |
| `--ssh-key <path>` | per-DC | Same override as the orchestrator. |

## When this approach stops being enough

The fan-out is sequential or capped-parallel Bash over SSH. That is fine
for a handful of DCs and "iterate + aggregate" workflows. The moment any of
the following becomes a requirement, the design should move to Go — see
[ARCHITECTURE.md → Language strategy](ARCHITECTURE.md#language-strategy-bash-by-default-go-on-demand)
and [GO_FRAMEWORK.md](GO_FRAMEWORK.md):

| Need | Why Bash struggles |
|---|---|
| Cancel **remaining** DCs the moment one fails | `wait -n` doesn't compose well with structured cancellation |
| Tens of DCs with strict parallelism + retry/backoff | `errgroup` + semaphore is the right primitive |
| Cross-DC state machine (e.g. "halt all DCs if 2 fail in a row") | Needs typed state, not flat CSVs |
| REST against NSX Policy at scale (pagination, typed JSON) | `curl + awk` doesn't scale |
