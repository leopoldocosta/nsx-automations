# NSX Automations

Unified Bash automation toolkit for **VMware NSX-T** (Edge Nodes + Managers).

Built from two previous projects:
- [`nsx-edge-automation`](https://github.com/leopoldocosta/nsx-edge-automation) — Edge Node toolkit (support bundle workflow, KB404700 disk validation)
- [`nsx-rolling-reboot`](https://github.com/leopoldocosta/nsx-rolling-reboot) — Manager rolling reboot (mitigation for KB 396719)

> **Notice:** No proprietary data, credentials, or real IP addresses are included.

## Design

**Three-layer libraries + thin automations:**

```
┌─────────────────────────────────────────────┐
│  automations/<use_case>/*.sh                │  ← orchestration only
├─────────────────────────────────────────────┤
│  lib/nsx_edge.sh   │   lib/nsx_manager.sh   │  ← type-specific helpers
├─────────────────────────────────────────────┤
│                lib/common.sh                │  ← log, SSH, IPs, TCP, parsers
└─────────────────────────────────────────────┘

           bin/deploy.sh         bin/configure_ssh_keys.sh
                (optional, top-level helpers — not per-automation)
```

Everything reusable lives in `lib/`. Automation folders contain **only** the orchestration specific to that automation.

## Repository structure

```
nsx-automations/
├── lib/
│   ├── common.sh           # log, deps, sshpass, IPs, TCP probe, crontab, parsers
│   ├── nsx_edge.sh         # root SSH toggle, support bundle, retry-on-auth helper
│   └── nsx_manager.sh      # multi-cluster parser, reboot+wait, key registration
│
├── bin/
│   ├── deploy.sh                       # copy lib/ + bin/ + automations/ to a target host (or --all-dcs)
│   ├── configure_ssh_keys.sh           # one-shot SSH-key registration (edge or manager)
│   ├── run_across_datacenters.sh       # fan-out an automation to every DC, pull logs back
│   ├── run_command_across_dcs.sh       # ad-hoc: run ANY command on every DC jump
│   ├── rolling_reboot_next.sh          # orchestrator: reboot ONE manager (next entry in reboot_plan.conf)
│   ├── install_orchestrator_cron.sh    # install daily cron on the orchestrator
│   └── uninstall_orchestrator_cron.sh  # remove daily cron (--purge-state also wipes state)
│
├── automations/
│   ├── edge_support_bundle/        # SB workflow (main + precheck + interactive CLI)
│   ├── kb404700_disk_validation/   # detect root partition/overlay2 issues
│   └── manager_rolling_reboot/     # multi-cluster monthly reboot
│
├── docs/
│   ├── MANUAL.md
│   ├── CONTRIBUTING.md
│   ├── ARCHITECTURE.md
│   ├── MULTIDC.md            # hub-and-spoke topology + datacenters.conf schema
│   ├── RUNBOOK_INSTALACAO.md    # PT-BR: instalação da plataforma multi-DC
│   ├── RUNBOOK_ROLLING_REBOOT.md# PT-BR: operação do rolling reboot (plano+cron)
│   └── GO_FRAMEWORK.md       # language strategy reference (Bash default, Go on demand)
│
├── inventory/                # CENTRAL per-DC host inventory — single source of truth
│   ├── edge_nodes.example    #   copy to edge_nodes.txt (git-ignored)
│   └── managers.conf.example #   copy to managers.conf (git-ignored)
│
├── examples/
│   ├── edge_nodes.example
│   └── managers.conf.example
│
├── datacenters.conf.example  # inventory for run_across_datacenters / deploy --all-dcs
├── reboot_plan.example       # orchestrator-side ordered plan for the daily rolling reboot
└── .gitignore
```

## Available automations

| Folder | Target | Purpose |
|---|---|---|
| `device_command` | Managers + Edges | Run any read-only NSX CLI command on every device of the DC (table + CSV) |
| `edge_support_bundle` | Edges | Collect & verify NSX support bundles across all Edges |
| `kb404700_disk_validation` | Edges | Check `/dev/sda2` + `overlay2` usage; flag nodes needing action |
| `manager_rolling_reboot` | Managers | Multi-cluster monthly rolling reboot (mitigates KB 396719) |

## Quick start

```bash
git clone https://github.com/leopoldocosta/nsx-automations.git
cd nsx-automations

# Pick an automation
cd automations/<name>
cat README.md
```

Fill the **central inventory** once per jump VM — every automation reads it:

```bash
cp inventory/edge_nodes.example    inventory/edge_nodes.txt
cp inventory/managers.conf.example inventory/managers.conf
vim inventory/edge_nodes.txt inventory/managers.conf

cd automations/<name>
./<main_script>.sh
```

To run one automation against a **subset**, drop a local `<hosts>.txt` /
`managers.conf` inside its folder — a local file overrides the central one.

## Multi-datacenter

Run any automation in every datacenter from a single orchestrator VM (one
local jump per DC, NSX credentials never leave the DC they belong to):

```bash
cp datacenters.conf.example datacenters.conf      # one [DC-X] section per DC
vim datacenters.conf

./bin/deploy.sh --all-dcs --conf ./datacenters.conf       # sync code to every jump
./bin/run_across_datacenters.sh                            \
    --conf ./datacenters.conf                              \
    --automation manager_rolling_reboot/nsx_rolling_reboot.sh
```

### Daily rolling reboot (1 manager / day across all DCs)

For KB 396719 mitigation at production cadence — 21 managers, 21 days:

```bash
cp reboot_plan.example reboot_plan.conf           # ordered "<DC> <manager-ip>" list
vim reboot_plan.conf

./bin/rolling_reboot_next.sh --list               # show the plan
./bin/install_orchestrator_cron.sh                # daily cron at 02:00
```

See [docs/MULTIDC.md](docs/MULTIDC.md) for the topology, security model, and full CLI reference.

## Top-level helpers (optional)

```bash
# Install scripts on a remote jump/monitor server
./bin/deploy.sh --target user@host:~/nsx-automations --deps

# Register SSH key on Edge Nodes (reads inventory/edge_nodes.txt by default)
./bin/configure_ssh_keys.sh --type edge

# Register SSH key on Managers (reads inventory/managers.conf by default)
./bin/configure_ssh_keys.sh --type manager
```

Not every automation needs them — e.g. `kb404700_disk_validation` runs straight from the clone, no deploy needed.

## Adding a new automation

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

## Security

- Passwords prompted interactively, cleared from memory after run
- Root SSH on Edges enabled only during execution, disabled at the end
- `_sshpass_safe` writes passwords to a tmp file (mode 600), never to process args
- Real host lists (`*.txt`, `managers.conf`) are git-ignored — only `.example` templates are committed
- `managers.conf` parser rejects shell metacharacters in `hosts =` and `admin_user =` entries

## Requirements

| Component        | Supported                                                          |
|------------------|--------------------------------------------------------------------|
| Bash             | 4.3+ (uses `declare -n` namerefs, `mapfile`, `${var,,}`)           |
| NSX-T            | 3.x and 4.x (Edge Nodes + Managers)                                |
| Jump host OS     | Ubuntu / Debian / RHEL / Rocky / Alma / Fedora / SLES / openSUSE   |
| Jump host deps   | `ssh`, `sshpass` (only if no SSH key is registered), `curl` (opt.) |
| Network          | Outbound TCP/22 to each NSX node; outbound HTTPS for webhook (opt.)|

> **macOS note:** ships with Bash 3.2 — install Bash 4.3+ via `brew install bash` to run these scripts locally.

## Environment variables

Opt-in tunables, all unset by default:

| Variable                      | Effect                                                          |
|-------------------------------|-----------------------------------------------------------------|
| `NSX_DEBUG=1`                 | Let SSH stderr through (host-key / auth troubleshooting)        |
| `NSX_REBOOT_INTERVAL`         | Seconds between managers in a rolling reboot (default 3600)     |
| `NSX_REBOOT_MAX_WAIT`         | TCP down/up timeout per host (default 900)                      |
| `NSX_CLUSTER_STABLE_TIMEOUT`  | Cluster `STABLE` poll budget post-reboot (default 600)          |
| `NSX_CLUSTER_STABLE_INTERVAL` | Cluster `STABLE` poll interval (default 15)                     |
| `NSX_SKIP_CLUSTER_GATE=1`     | Skip the STABLE gate after reboot (NOT recommended in prod)     |
| `NSX_LOG_RETENTION_DAYS`      | Days kept by `rotate_logs` (default 30)                         |
| `NSX_NOTIFY_WEBHOOK`          | Slack/Teams-compatible URL — posts on `log_err`                 |
| `NSX_BUNDLE_RECENT_DAYS`      | "Recent" threshold for support-bundle precheck (default 7)      |

## Versioning

See [CHANGELOG.md](CHANGELOG.md). The project follows [SemVer](https://semver.org/):
breaking changes to the `lib/` API bump the major version.

## License

MIT
