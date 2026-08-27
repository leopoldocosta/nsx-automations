# NSX-T ↔ Underlay Routing Model Audit

Answers one question the pre-design must settle before anyone assumes a routing
model: **does the NSX-T ↔ physical-underlay boundary run BGP, or static routes?**

The NSX-T ↔ underlay boundary is the **Tier-0 gateway** (Tier-1s peer *north*
into a Tier-0, never directly to the fabric). So this tool audits every Tier-0,
across all its locale-services, purely via **read-only Policy API GETs** — no
SSH, no `PATCH`, nothing on the environment is changed.

## What it checks (per Tier-0)

| Signal | Source (Policy API) |
|---|---|
| BGP enabled + Local AS | `GET …/tier-0s/<t0>/locale-services/<ls>/bgp` (`.enabled`, `.local_as_num`) |
| BGP neighbors **configured** | `GET …/bgp/neighbors` (count + `neighbor_address`/`remote_as_num`) |
| BGP neighbors **established** | `GET …/bgp/neighbors/status` (runtime `connection_state`; best-effort) |
| Static routes | `GET …/tier-0s/<t0>/static-routes` (count) |
| Default static route | any static route with network `0.0.0.0/0` |

## Verdict

| Verdict | Meaning |
|---|---|
| **BGP** | BGP enabled with ≥1 neighbor configured (and no default static route). `Est` = sessions established *now*. |
| **STATIC** | no BGP neighbors; the underlay is reached via static route(s). |
| **MIXED** | both a BGP neighbor and static route(s) exist on the Tier-0. |
| **NONE** | neither — a stub/disconnected Tier-0 (no uplink routing). Review. |
| **ERROR** | the API calls for that Tier-0 failed. |

The **Default** column says how the default route to the underlay is set:
`static` (an explicit `0.0.0.0/0` route), `bgp?` (inferred — a BGP session is up,
but confirming the *default* is learned via BGP is an RIB check), or `none`.

The fleet **SUMMARY** prints a one-line **CONCLUSION**, e.g. *"NO BGP configured
— the NSX↔underlay boundary is STATIC ROUTE on every Tier-0"* — exactly the fact
a checkpoint needs before building a design on a BGP premise.

## Run

### Across every datacenter (from the orchestrator) — the normal way

```bash
./bin/run_across_datacenters.sh --conf ./datacenters.conf \
  --automation routing_model_audit/routing_model_audit.sh
```

Each jump audits its own DC's manager (first of `inventory/managers.conf`); the
fan-out lifts each DC's report block into one unified fleet report.

### On a single manager

```bash
bash routing_model_audit.sh --manager 192.168.20.10
bash routing_model_audit.sh --manager 192.168.20.10 --tier0 T0-EDGE-01
bash routing_model_audit.sh --manager 192.168.20.10 --no-runtime   # config-only, faster
```

## Manager & credentials

Same contract as `lb_troubleshoot` (fan-out safe):

- `--manager` is optional — without it the **first manager of THIS DC's central
  inventory** (`inventory/managers.conf`) is used, so one fan-out command fits
  every DC.
- API credentials come from the environment (`NSX_USER`/`NSX_PASS`) or a saved
  `run/session.env`; under the non-interactive fan-out the script **never
  prompts**. To seed a session on a jump:

  ```bash
  cd automations/routing_model_audit && source ../../lib/common.sh \
    && ask_admin_creds && save_session_env
  ```

A least-privilege read-only NSX user (Auditor role) is sufficient — this tool
only issues GETs.

## Flags

| Flag | Effect |
|---|---|
| `--manager <ip\|fqdn>` | NSX Manager (no scheme). Optional (see above). |
| `--tier0 <id\|name>` | Audit only this Tier-0 (matches id or display name). |
| `--no-runtime` | Skip the BGP neighbor **status** calls (config-only; faster). |
| `-h`, `--help` | Show the script header. |

## Output

- `logs/routing_model_<ts>.txt` — human report: per-Tier-0 table, SUMMARY +
  CONCLUSION, a DETAIL block (neighbor + static-route addresses), and a legend.
- `logs/routing_model_<ts>.csv` — one row per Tier-0:
  `tier0_id,tier0_name,ha_mode,bgp_enabled,local_as,neighbors_cfg,neighbors_established,neighbors_runtime,static_routes,has_default_static,default_origin,verdict,error`.
- `logs/routing_model_run_<ts>.log` — full execution log.

> The DETAIL block and CSV carry **underlay neighbor / next-hop IPs**. They are
> operational artifacts under `logs/` on the jump (git-ignored) — the same as
> the other automations write real IPs there. **Mask them when pasting into
> chat or a ticket.**

## Confirming on the box (optional)

The verdict is config-based (plus runtime session state when `--runtime` is on).
To confirm live sessions / the actual RIB, on the Edge CLI:

```
get logical-router
get bgp neighbor summary
get route
```

## Dependencies

- `lib/common.sh` — logging, inventory resolution, session creds, `report_wrap`,
  `log_progress`, `rotate_logs`.
- `lib/nsx_api.sh` — Basic-Auth `curl` wrapper, `nsx_api_get`, `_nsx_paginate`,
  `nsx_api_check_auth`.
- `lib/nsx_manager.sh` — `parse_managers_conf` for the `--manager` fallback.
- `curl`, `jq`, `base64` on the jump.
