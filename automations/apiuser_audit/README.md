# Service-Account Audit (`apiuser`) — NSX-T Managers

Answers, across every NSX-T Manager in the fleet, **read-only and as root**:

- Does the account (`apiuser` by default) **exist** on this manager? *(in some
  managers it does not — that is a valid, reported outcome.)*
- Is it **locked** (`passwd -S` → `L`), and does it have an **interactive
  shell**?
- Is it **privileged** (`sudoers` / a `sudo`/`wheel`/`admin` group)?
- Has it **ever** logged in via SSH, **when**, and **from where** (`lastlog`)?
- How many **SSH sessions** and **failed attempts** fall inside the time window
  (`wtmp` / `btmp`)?

It is a **discovery + audit** tool: it validates existence *first*, then usage.

## Scope — v1 vs v2

**v1 (this script)** deliberately does **not** open the large, rotated,
compressed text logs. Everything above comes from account metadata and the
login-accounting files (`getent`, `passwd -S`, `id`, `lastlog`, `last`,
`last -f /var/log/btmp`), so a full-fleet run is near-instant and cheap.

**v2 (planned)** adds the deep scans that *do* need the big logs, honoring the
same window flags:

- **SSH:** `/var/log/auth.log*` — exact accepted/failed counts, auth method.
- **API:** the NSX audit log (entries with `userName="<acct>"`) — call volume,
  top endpoints (`uri` + method), source IPs, response codes.

v2 selects rotated/`.gz` files by **mtime** (skips any file older than the
window) and streams them with `zcat -f`, so the huge/compressed volume stays
cheap even as the window widens. Start narrow (`--hours 1`) and grow.

## Window

The window filters only **event** metrics (`wtmp`/`btmp` sessions). **State**
metrics (exists / locked / shell / last-login time / privilege) are always
shown — they are current facts, not events.

| Flag | Meaning | Default |
|---|---|---|
| `--hours N` | window = now − N hours | `1` |
| `--days N` | window = now − N days | — (overrides `--hours`) |
| `--since "<ts>"` | absolute start, any GNU-`date` string | — (overrides both) |
| `--user <name>` | account to audit (`[A-Za-z0-9._-]`) | `apiuser` |

## Verdict

| Condition | Verdict |
|---|---|
| Account does not exist on the manager | **ABSENT** |
| Exists, password locked, never used | **PRESENT_LOCKED** |
| Exists, not used (never logged in, no sessions in window) | **PRESENT_UNUSED** |
| Exists and has SSH login history (`lastlog` or `wtmp`) | **PRESENT_USED** |
| Root SSH or the probe failed | **ERROR** |

A **PRIVILEGED** flag (sudoers / admin group) is surfaced as its own column and
raises a per-manager warning regardless of the verdict.

## Inventory

Manager IPs are resolved by `resolve_inventory_file()`: a local
`managers.conf` in this folder wins, otherwise the central
`inventory/managers.conf` (same file the rolling-reboot uses). Every cluster's
hosts are flattened and audited; the cluster label is shown per row.

## Access

Runs as **root** on each manager via `ssh_root` — `ROOT_KEY` (`~/.ssh/id_rsa`)
when present, otherwise `ROOT_PASS` from the environment (or an interactive
prompt on a TTY-backed local run). Under the non-interactive fan-out there is no
`/dev/tty`, so provide root by key or `ROOT_PASS`.

## Run

Single DC (local, from this repo on a jump):

```bash
./apiuser_audit.sh --hours 1                 # narrow: last hour
./apiuser_audit.sh --days 7 --user apiuser   # widen the window
```

Whole fleet, from the orchestrator (unified report at the end):

```bash
./bin/run_across_datacenters.sh --conf ./datacenters.conf \
  --automation apiuser_audit/apiuser_audit.sh            # add --only-dc DC-A to test one
```

## Output

- Human report + `NEEDS ATTENTION` list, `tee`'d to
  `logs/apiuser_audit_<ts>.txt` and wrapped in the fan-out report sentinels
  (so it appears in the unified fleet report).
- Machine-readable `logs/apiuser_audit_<ts>.csv` (one row per manager).
