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
│   ├── deploy.sh                   # copy lib/ + bin/ + automations/ to a target host
│   └── configure_ssh_keys.sh       # one-shot SSH-key registration (edge or manager)
│
├── automations/
│   ├── edge_support_bundle/        # SB workflow (main + precheck + interactive CLI)
│   ├── kb404700_disk_validation/   # detect root partition/overlay2 issues
│   └── manager_rolling_reboot/     # multi-cluster monthly reboot
│
├── docs/
│   ├── MANUAL.md
│   ├── CONTRIBUTING.md
│   └── ARCHITECTURE.md
│
├── examples/
│   ├── edge_nodes.example
│   └── managers.conf.example
│
└── .gitignore
```

## Available automations

| Folder | Target | Purpose |
|---|---|---|
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

Every automation follows the same pattern:

```bash
cp <hosts>.example <hosts>.txt           # or managers.conf
vim <hosts>.txt
./<main_script>.sh
```

## Top-level helpers (optional)

```bash
# Install scripts on a remote jump/monitor server
./bin/deploy.sh --target user@host:~/nsx-automations --deps

# Register SSH key on Edge Nodes
./bin/configure_ssh_keys.sh --type edge --hosts automations/edge_support_bundle/edge_nodes.txt

# Register SSH key on Managers (multi-cluster aware)
./bin/configure_ssh_keys.sh --type manager --hosts automations/manager_rolling_reboot/managers.conf
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
