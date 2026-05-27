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

## License

MIT
