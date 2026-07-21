# CLAUDE.md — read this first

Toolkit to operate an NSX-T fleet across **7 datacenters** from one
orchestrator VM. Read `docs/MULTIDC.md` for the topology and `TODO.md` for
what's pending — those two are the source of truth.

## The one thing to get right: execution is fanned out, not local

```
orchestrator VM ──SSH──► DC-A jump ──► NSX devices of DC-A
                ──SSH──► DC-B jump ──► NSX devices of DC-B   ... (7 DCs)
```

Running an automation **directly on the orchestrator does NOT reach all DCs** —
it only reaches DC-A (whose jump *is* the orchestrator), and DC IPs overlap
(DC-E and DC-F share edge/manager IPs, resolvable only from inside each jump).
To act on the whole fleet, fan out — the jump runs the automation locally:

```bash
./bin/run_across_datacenters.sh --conf ./datacenters.conf \
  --automation <folder>/<script>.sh            # add --only-dc DC-A to test one
```

## Facts that avoid dead ends

- **git lives only on the orchestrator.** Edits happen there (or on Windows →
  commit/push), then `git pull` on the orchestrator, then distribute to jumps:
  `./bin/deploy.sh --all-dcs --conf ./datacenters.conf`. Jumps have no git.
- **Fan-out is non-interactive** (`ssh bash -lc`, no tty). Code must never read
  `/dev/tty` on that path — prompts must be guarded or skipped (creds come from
  keys/env). This has bitten several times.
- **Device SSH uses a key, not a password.** `ssh_admin`/`ssh_root` use
  `ADMIN_KEY`/`ROOT_KEY`, which resolve to `~/.ssh/id_rsa` on each jump (the key
  `configure_ssh_keys.sh` registered). `~/.ssh/orchestrator` is a *different*
  key, only for orchestrator→jump hops.
- **Jump service user is `netops`** — plain user, **no sudo** (keep it that way).
- **Per-DC inventories.** Each jump owns its own `inventory/managers.conf` /
  `inventory/edge_nodes.txt`. There is no cross-DC list on the orchestrator.
- **Rolling reboot** = one manager/day via an ordered plan + daily cron on the
  orchestrator. See `docs/RUNBOOK_ROLLING_REBOOT.md`.

## Conventions

- Real host lists, `datacenters.conf`, `reboot_plan.conf`, `notify.conf` and the
  Slack webhook are **git-ignored / credentials** — never commit them. Examples
  use RFC 5737 documentation IPs.
- The operator masks real IPs when pasting (work laptop DLP). Don't echo real
  IPs back into chat or committed files.
- Passwords are never written to disk or logs (scrubbed to `***`).
- Validate shell with `bash -n`; CI runs shellcheck + bats on push.
