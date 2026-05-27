# KB404700 — Disk Validation (Edge Nodes)

Validates whether `/dev/sda2` (root partition) is at 100% capacity and whether `/var/lib/docker/overlay2` is the cause, across a fleet of NSX Edge Nodes.

## Context

KB404700 covers Edge Nodes where the root partition fills due to excessive Docker overlay2 data accumulation. This script automates detection.

## Verdict logic

| Condition | Verdict |
|---|---|
| `/dev/sda2` < 100% AND `overlay2` < 10G | OK |
| `/dev/sda2` = 100% OR `overlay2` ≥ 10G | ACTION REQUIRED |

> The 10G threshold for `overlay2` is configurable directly in the script (`overlay_num >= 10`).

## Setup

```bash
cd automations/kb404700_disk_validation
cp edge_nodes.example edge_nodes.txt
vim edge_nodes.txt
```

No SSH key registration is needed — the script prompts for `admin` and `root` passwords once and reuses them for all nodes.

(Optional, to avoid passwords next time:)

```bash
../../bin/configure_ssh_keys.sh --type edge --hosts ./edge_nodes.txt
```

## Run

```bash
bash kb404700_disk_validation.sh
```

The script:
1. Asks for `admin` and `root` passwords.
2. For each node: collects `uptime`, `version`, runs `df -h` and `du` under root, then disables root SSH.
3. Prints a consolidated report and saves it to `logs/`.
4. Asks whether to clear credentials (default: Yes after 30s).

## Output

- `logs/kb404700_run_YYYYMMDD_HHMMSS.log`     — full execution log
- `logs/kb404700_report_YYYYMMDD_HHMMSS.txt`  — final report (also printed)

## Dependencies

Scripts source:
- `lib/common.sh`   — log, IPs, sshpass-safe, NSX-CLI parsers, timed-confirm
- `lib/nsx_edge.sh` — root SSH toggle, retry-on-auth-failure helper
