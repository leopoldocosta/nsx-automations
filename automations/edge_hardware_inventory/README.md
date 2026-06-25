# Edge Hardware Inventory — Dell PowerEdge (Edge Nodes)

Collects **chassis model** and **Service Tag** for each bare-metal NSX-T Edge
Node in the fleet, by running `dmidecode` over root SSH and parsing the
`system-product-name` / `system-serial-number` fields.

## Why

NSX-T Edge Nodes deployed as bare-metal usually run on Dell PowerEdge servers.
Inventory, warranty checks and field replacements need the **Service Tag** of
each host — this script collects it across the fleet in one pass, with no
out-of-band BMC required.

## Verdict logic

| Condition | Verdict |
|---|---|
| `system-manufacturer` matches `Dell` AND `system-product-name` matches `PowerEdge` AND `system-serial-number` is non-empty | **OK** |
| `system-manufacturer` is not Dell (e.g. `VMware, Inc.` — edge is a VM, not bare-metal) | **NOT_DELL** |
| Dell hardware but service tag empty / placeholder (`Not Specified`, `To Be Filled By O.E.M.`) | **MISSING_TAG** |
| SSH or `dmidecode` failed | **ERROR** |

## Setup

```bash
cd automations/edge_hardware_inventory
cp edge_nodes.example edge_nodes.txt
vim edge_nodes.txt
```

No SSH key registration is needed — the script prompts for `admin` and `root`
passwords once and reuses them for all nodes.

(Optional, to avoid passwords next time:)

```bash
../../bin/configure_ssh_keys.sh --type edge --hosts ./edge_nodes.txt
```

## Run

```bash
bash edge_hardware_inventory.sh
```

The script:
1. Asks for `admin` and `root` passwords.
2. For each node: collects `uptime`, `version`, enables root SSH, runs
   `dmidecode` to read manufacturer / model / service tag, disables root SSH.
3. Prints a consolidated table and saves both a `.txt` report and a `.csv`
   side-output to `logs/`.
4. Asks whether to clear credentials (default: Yes after 30s).

## Output

- `logs/edge_hw_run_YYYYMMDD_HHMMSS.log`     — full execution log
- `logs/edge_hw_report_YYYYMMDD_HHMMSS.txt`  — final human-readable report
- `logs/edge_hw_report_YYYYMMDD_HHMMSS.csv`  — machine-readable inventory:
  `ip,hostname,nsx_version,manufacturer,model,service_tag,baseboard_serial,verdict,error`

## Tunables

| Var | Default | Effect |
|---|---|---|
| `NSX_LOG_RETENTION_DAYS` | `30` | Days of `logs/` kept after each run |
| `NSX_DEBUG` | _(unset)_ | `1` surfaces SSH stderr (auth/host-key troubleshooting) |
| `NSX_NOTIFY_WEBHOOK` | _(unset)_ | Slack/Teams URL — each `log_err` is posted |

## Requirements

- Each Edge Node must allow root SSH from the jump host while the script runs
  (the script toggles it on/off via the admin CLI — same pattern as the other
  edge automations).
- `dmidecode` must be installed on the Edge (default on NSX Edge OS).
- For VM edges, expect `NOT_DELL` verdicts — `dmidecode` returns the
  hypervisor identity (`VMware, Inc.`), not the underlying ESXi host. To
  inventory the ESXi host's PowerEdge tag instead, query vCenter / iDRAC.

## Dependencies

Scripts source:
- `lib/common.sh`   — log, IPs, sshpass-safe, NSX-CLI parsers, timed-confirm, `rotate_logs`
- `lib/nsx_edge.sh` — root SSH toggle, retry-on-auth-failure helper
