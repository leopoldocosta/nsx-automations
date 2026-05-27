# Automation: Edge Support Bundle

Collects and verifies NSX support bundles across all Edge Nodes.

## Scripts

| Script | Purpose |
|---|---|
| `nsx_sb_main.sh` | Full workflow: PRE-CHECK → PHASE 1 (request) → PHASE 2 (verify every 5 min, up to 30 min) → disable root SSH |
| `nsx_sb_precheck.sh` | Inspect existing bundles without generating new ones. `--clean-all` removes every bundle from the file-store. |
| `nsx_ssh_cli.sh` | Interactive SSH CLI: pick a node (or broadcast), pick `admin` or `root`, run single commands or stay in a session. |

## Setup

```bash
cd automations/edge_support_bundle
cp edge_nodes.example edge_nodes.txt
vim edge_nodes.txt
```

**(Optional)** Configure SSH keys once so subsequent runs don't prompt for passwords:

```bash
../../bin/configure_ssh_keys.sh --type edge --hosts ./edge_nodes.txt
```

## Run

```bash
# Recommended inside screen — ~35 minutes total
screen -S nsx_sb
./nsx_sb_main.sh

# Only inspect bundle state, no generation
./nsx_sb_precheck.sh

# Wipe every bundle (use with care)
./nsx_sb_precheck.sh --clean-all

# Interactive CLI for ad-hoc commands
./nsx_ssh_cli.sh
```

## Dependencies

Scripts source:
- `lib/common.sh`   — log, IPs, sshpass-safe, session cache, table helpers
- `lib/nsx_edge.sh` — root SSH toggle, support bundle helpers
