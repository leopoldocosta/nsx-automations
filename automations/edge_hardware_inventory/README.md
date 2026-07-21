# Edge Hardware + CPU Inventory (Edge Nodes)

Collects, for each bare-metal NSX-T Edge Node, in a single root-SSH pass:

- **Chassis model** and **Service Tag** (Dell PowerEdge) via `dmidecode`;
- **CPU identity / topology** (model, sockets, cores/socket, threads/core,
  total vCPU, max clock) via `lscpu` + `dmidecode -t processor`.

## Why

NSX-T Edge Nodes deployed as bare-metal usually run on Dell PowerEdge servers.
Inventory, warranty checks and field replacements need the **Service Tag**;
capacity and heterogeneity reviews need the **CPU model**. This script collects
both across the fleet in one pass, with no out-of-band BMC required.

## Verdict logic

The verdict is **hardware-based** (the CPU columns are supplementary data and
never change it):

| Condition | Verdict |
|---|---|
| `system-manufacturer` matches `Dell` AND `system-product-name` matches `PowerEdge` AND `system-serial-number` is non-empty | **OK** |
| `system-manufacturer` is not Dell (e.g. `VMware, Inc.` — edge is a VM, not bare-metal) | **NOT_DELL** |
| Dell hardware but service tag empty / placeholder (`Not Specified`, `To Be Filled By O.E.M.`) | **MISSING_TAG** |
| SSH or `dmidecode` failed | **ERROR** |

## Inventory

The list of Edge Nodes is resolved by `resolve_inventory_file()` in
`lib/common.sh`: a local `edge_nodes.txt` in this folder wins, otherwise it
falls back to the **central inventory** (`inventory/edge_nodes.txt` or
`$NSX_INVENTORY_DIR/edge_nodes.txt`) that each jump already maintains. No
per-automation host file to copy or edit.

## Run

### Across every datacenter (from the orchestrator) — the normal way

```bash
./bin/run_across_datacenters.sh --conf ./datacenters.conf \
  --automation edge_hardware_inventory/edge_hardware_inventory.sh
```

The orchestrator SSHes into each jump and runs the automation **there**, where
the jump can reach its own edges and reads its own inventory. Reports are pulled
back to `aggregated_logs/<timestamp>/<DC>/logs/`.

### On a single jump (interactive)

```bash
bash edge_hardware_inventory.sh
```

### Credentials vs. keys

`ssh_admin`/`ssh_root` use the registered device key when it exists
(`ADMIN_KEY`/`ROOT_KEY`, resolved by default to `~/.ssh/id_rsa` — see
`lib/common.sh`). When the key is present the admin/root **password prompts are
skipped**, so the automation runs unattended under the fan-out. Only when no key
is present does it fall back to prompting once (interactive, TTY-backed runs).

> Note: on edges where the **root** key was never registered, root collection
> fails cleanly and the node is reported `ERROR`/`MISSING_TAG` (no hang) — the
> admin data (version, uptime) still lands. Register the root key with
> `../../bin/configure_ssh_keys.sh --type edge` to close those.

## Output

- `logs/edge_hw_run_YYYYMMDD_HHMMSS.log`     — full execution log
- `logs/edge_hw_report_YYYYMMDD_HHMMSS.txt`  — human-readable report:
  hardware table, CPU table, CPU-model grouping, and nodes needing attention
- `logs/edge_hw_report_YYYYMMDD_HHMMSS.csv`  — machine-readable inventory:
  `ip,hostname,nsx_version,manufacturer,model,service_tag,baseboard_serial,cpu_model,sockets,cores_per_socket,threads_per_core,total_vcpu,max_mhz,dmi_max_speed,verdict,error`
- `logs/edge_cpu_raw_<hostname>.txt`          — per-node full `lscpu` +
  grepped `dmidecode -t processor` dump, for reference / debugging

## Tunables

| Var | Default | Effect |
|---|---|---|
| `NSX_DEVICE_KEY` | _(unset)_ | Override the jump→NSX key for both hops (else `ADMIN_KEY`/`ROOT_KEY` → `~/.ssh/id_rsa`) |
| `NSX_LOG_RETENTION_DAYS` | `30` | Days of `logs/` kept after each run |
| `NSX_DEBUG` | _(unset)_ | `1` surfaces SSH stderr (auth/host-key troubleshooting) |
| `NSX_NOTIFY_WEBHOOK` | _(unset)_ | Slack/Teams URL — each `log_err` is posted |

## Requirements

- Each Edge Node must allow root SSH from the jump host while the script runs
  (the script toggles it on/off via the admin CLI — same pattern as the other
  edge automations).
- `dmidecode` and `lscpu` must be installed on the Edge (default on NSX Edge OS).
- For VM edges, expect `NOT_DELL` verdicts — `dmidecode` returns the hypervisor
  identity (`VMware, Inc.`), not the underlying ESXi host. `lscpu` still reports
  the CPU model exposed to the guest, so the CPU columns remain useful there.

## Dependencies

Scripts source:
- `lib/common.sh`   — log, IPs, sshpass-safe, NSX-CLI parsers, timed-confirm, `rotate_logs`
- `lib/nsx_edge.sh` — root SSH toggle, retry-on-auth-failure helper
