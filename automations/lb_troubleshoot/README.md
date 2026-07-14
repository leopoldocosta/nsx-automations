# LB Troubleshoot — NSX-T Native Load Balancer (Virtual Server / Pool DOWN)

Diagnoses an NSX-T native Load Balancer whose **virtual server is down / pool
members are off**, end to end, and (optionally) applies the monitor fix.

Built from a real incident: pool members marked **down** because an **HTTP
monitor was probing an HTTPS/SSL backend** (`Receive Message Failure`).

## Why this exists — the three id namespaces

Most wasted time on these tickets comes from mixing up NSX's id namespaces.
This tool resolves them for you:

| Namespace | Where it's used | Example |
|---|---|---|
| **Policy id** | `/policy/api/v1/infra/...` and the UI | LB service `b74d0f77-…`, pool `842de5a4-…` |
| **Realization id** | **Edge CLI** (`get load-balancer <id> …`) and `/api/v1/...` | `48e25df2-…` |
| **Object path** | tells you the object **type** | `/infra/lb-virtual-servers/…` is a VS, not an LB |

Automated conversions:

- **Policy LB-service → Edge CLI id**: read `.realization_id` from the Policy object.
- **Edge pool id → Policy pool**: the Edge shows a *dataplane* pool id that is
  **not** queryable on Policy (returns `NOT_FOUND 600`). The tool re-discovers
  the Policy pool by matching **member ip + port** instead.

## Decoder (kept in every report)

API/CLI errors:

| Error | Meaning | Fix |
|---|---|---|
| `% Invalid value for argument <lb-uuid>` | VS id passed where an LB id is required | use the LB service `realization_id` |
| `error_code 600 NOT_FOUND` ("case sensitive") | id absent in that namespace (e.g. dataplane id on Policy) or stale | convert / re-discover by member ip+port |
| `error_code 258` "requested URI ... not found" | wrong **endpoint** (e.g. `/status` vs `/detailed-status`) | correct the path |

health-check `FAIL_REASON`:

| Reason | Class | Where the problem is |
|---|---|---|
| `Connect to Peer Failure` / `Connection refused` | `BACKEND_DOWN` | app not listening on the port |
| `Receive Message Failure` / `Resource temporarily unavailable` | `MONITOR_MISMATCH` | port open, but monitor protocol ≠ app protocol (HTTP monitor vs HTTPS app) |
| `Timeout` | `TIMEOUT_FILTER` | reachability / firewall / monitor timeout |

## Requirements

`curl`, `jq`, `base64` on the host that runs the script (typically the
jump host with API access to the NSX Manager). `ssh` only if you use
`--edge` (`sshpass` only when no admin key is registered).

Credentials are collected once (`admin`) and the password is passed to `curl`
via a `--config` FD, so it never appears in `ps`. Any special character is
accepted (raw base64 of `user:pass`).

## Usage (local, on a jump host)

```bash
cd automations/lb_troubleshoot

# Full picture from the LB service id + edge runtime + member root-cause
bash lb_troubleshoot.sh --manager 192.168.20.10 \
  --lb-service b74d0f77-fe30-4a5e-809e-d711811b2c8a \
  --edge 192.168.30.11 \
  --member 198.51.100.11 --member-port 4010
```

`--manager` is optional when the central inventory exists
(`inventory/managers.conf`): the first manager of the first cluster is used.

Target the LB by any one of:

- `--lb-service <policy-id>`
- `--vs <policy-id>` (climbs to the parent LB service via `lb_service_path`)
- `--vip <ip> --port <port>` (finds the VS, then the LB service)

Optional diagnostics:

- `--edge <ip>`: admin SSH to an Edge for `get load-balancer <realization_id>
  status` + `health-check-table`, classified per member. Run against the
  **active** Edge for live counters (the report flags `LR-HA-State`).
- `--member <ip> --member-port <port>`: resolve the Policy pool for that backend
  and inspect its monitor; the report states the root cause and suggested fix.

## Multi-DC: running from the orchestrator

The automation is **fan-out safe**: launched via
`bin/run_across_datacenters.sh`, each jump resolves **its own** NSX Manager
from its local `inventory/managers.conf` and uses its own credentials — the
same command works against any datacenter. An LB lives in ONE DC, so target
it with `--only-dc`:

```bash
# Diagnose a VS in DC-B without leaving the orchestrator
./bin/run_across_datacenters.sh --conf ./datacenters.conf --only-dc DC-B \
    --automation lb_troubleshoot/lb_troubleshoot.sh -- \
    --vip 203.0.113.34 --port 4010 \
    --edge 192.168.30.11 --member 198.51.100.11 --member-port 4010

# Report + run log land in aggregated_logs/<ts>/DC-B/logs/
```

Fan-out rules (no TTY on the jump — the script never prompts):

1. **Credentials**: the jump must already hold API credentials. Either save a
   session once per shift on the jump (mode 600, expirable):

   ```bash
   cd ~/nsx-automations/automations/lb_troubleshoot
   source ../../lib/common.sh && ask_admin_creds && save_session_env
   ```

   …or export `NSX_USER`/`NSX_PASS` in the environment of the run.
2. **`--manager`**: omit it — each jump uses its own `inventory/managers.conf`.
3. **`--edge`**: uses the registered `ADMIN_KEY` (default `~/.ssh/id_rsa`),
   no password needed.
4. **`--fix-monitor`**: requires `--yes` (there is no TTY to confirm).
   Recommended flow: run read-only first, review the report in
   `aggregated_logs/`, then re-run with `--fix-monitor … --yes`.

## Remediation (optional, mutating)

If the root cause is a monitor protocol mismatch, swap the pool's monitor.
This is the **only** mutating action and it asks for confirmation
(`--yes` replaces the prompt in non-interactive runs):

```bash
bash lb_troubleshoot.sh --manager 192.168.20.10 \
  --lb-service b74d0f77-fe30-4a5e-809e-d711811b2c8a \
  --member 198.51.100.11 --member-port 4010 \
  --fix-monitor /infra/lb-monitor-profiles/default-tcp-lb-monitor
```

A **TCP** monitor validates connectivity only (resolves `Receive Message
Failure` immediately). If you need a real L7 check against an SSL app, use an
`LBHttpsMonitorProfile` with `SERVER_AUTH_IGNORE` instead.

After the PATCH, validate on the active Edge (~30s):

```
get load-balancer <realization_id> health-check-table
get load-balancer <realization_id> status
```

## Output

A timestamped report and run log under `logs/`. The report includes the LB
service block (with the `realization_id` to use on the Edge), the classified
health-check table, the member root-cause, and the decoder above. Under the
fan-out, `logs/` is rsync-pulled back to the orchestrator's
`aggregated_logs/<ts>/<DC>/logs/`.

## Notes

- Read-only by default; nothing changes without `--fix-monitor` + an explicit
  confirmation (`yes` at the prompt, or the `--yes` flag).
- No `--target`/deploy step is required — `bin/deploy.sh` already copies all of
  `automations/`, so this folder ships with it automatically.
