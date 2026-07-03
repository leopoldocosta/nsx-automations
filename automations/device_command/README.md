# device_command

Run a read-only NSX CLI command on **every device of this datacenter** —
all manager clusters and/or all edge nodes — and get one consolidated
table + CSV. The estate-wide "show me X on everything" tool.

## Typical use: uptime of the whole estate, all DCs, one command

From the **orchestrator** (each jump queries its own devices with its own
keys; results are pulled back automatically):

```bash
./bin/run_across_datacenters.sh --conf ./datacenters.conf --parallel 3 \
    --automation device_command/device_command.sh -- --cmd "get uptime"

# then:
cat aggregated_logs/<ts>/summary.csv                      # per-DC exit codes
cat aggregated_logs/<ts>/DC-*/logs/device_command_*.csv   # per-device rows
```

## Local (single DC) usage

```bash
./device_command.sh                              # get uptime, managers + edges
./device_command.sh --cmd "get version"
./device_command.sh --targets managers
./device_command.sh --targets edges --cmd "get interface eth0"
```

## Inventory

Reads the central per-DC inventory (`inventory/managers.conf`,
`inventory/edge_nodes.txt`); a local file beside the script overrides it.
A DC without edges just skips that class with a warning — no prompt,
no failure (fan-out safe).

## Prerequisites

- `bin/configure_ssh_keys.sh` ran once on this jump (admin key registered
  on managers and edges). The script refuses to run without `ADMIN_KEY`
  (default `~/.ssh/id_rsa`) — it never prompts for passwords.

## Output

- stdout: `TYPE CLUSTER IP EXIT OUTPUT` table
- `logs/device_command_<ts>.csv`: `type,cluster,ip,exit_code,output`
- exit code = number of devices that failed (0 = estate fully green)
