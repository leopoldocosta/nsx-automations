# Architecture

## Principles

1. **Thick libs, thin automations.** Anything that can be reused — parsing, distro detection, sshpass wrappers, crontab helpers, multi-cluster handling — lives in `lib/`. Automation folders contain only the orchestration logic specific to that use case.
2. **No per-automation `setup`.** SSH-key registration is a separate top-level helper (`bin/configure_ssh_keys.sh`) callable when needed. Some automations don't need it at all.
3. **Optional, top-level `deploy`.** Use `bin/deploy.sh` to copy the toolkit to a jump/monitor host. Not every automation requires it (e.g. `kb404700_disk_validation` works straight from `git clone`).

## Three-layer library design

```
lib/common.sh           ← layer 1 (always sourced)
  ├── logging           : log, log_ok, log_warn, log_err, log_banner
  ├── colors            : C_RESET, C_BOLD, C_GREEN, C_YELLOW, C_RED, C_CYAN, C_BLUE
  ├── tables            : tbl_header, tbl_row, tbl_footer
  ├── OS                : detect_pkg_manager, install_pkg, need_cmd
  ├── ssh-key (local)   : ensure_local_ssh_key
  ├── host list         : load_ips, collect_ips    (HOST_FILE / HOST_EXAMPLE / HOST_IPS)
  ├── credentials       : ask_admin_creds, reprompt_admin_creds, clear_creds,
  │                       confirm_clear_creds_with_timeout
  ├── session           : save_session_env, load_session_env, auto_clear_session_after
  ├── ssh               : _sshpass_safe, ssh_admin, admin_cmd
  ├── tcp               : tcp_check
  ├── crontab           : install_crontab_line, remove_crontab_line
  └── parsers           : parse_uptime_days, parse_version_short

lib/nsx_edge.sh         ← layer 2a (Edge Nodes)
  ├── credentials       : ask_root_creds
  ├── ssh (root)        : ssh_root, root_cmd
  ├── root SSH toggle   : enable_root_ssh, disable_root_ssh
  ├── support bundle    : request_support_bundle, check_support_bundle,
  │                       list_remote_bundles, bundle_file_date, bundle_duration
  ├── auth retry        : try_admin_ssh_with_retry
  └── ssh-key (remote)  : register_edge_admin_key, register_edge_root_key

lib/nsx_manager.sh      ← layer 2b (Managers)
  ├── ssh-key (remote)  : register_manager_admin_key
  ├── connectivity      : test_ssh_admin
  ├── reboot            : reboot_manager_and_wait
  ├── multi-cluster     : parse_managers_conf, cluster_hosts, cluster_admin_user,
  │                       ask_cluster_creds, with_cluster_creds, rolling_reboot_cluster
  └── helpers           : get_cluster_status, get_managers
```

### Why split Edge from Manager?

| Concern | Edge | Manager |
|---|---|---|
| Root SSH | Toggled via admin CLI | Not normally exposed |
| Support bundle | Generated locally | Different command set |
| Reboot pattern | Rare, ad-hoc | Monthly rolling cycle |
| CLI commands | `set service ssh root-login …` | `reboot`, `get cluster status`, `set user ssh-keys …` |

Folding both into a single file would leak Edge concepts into Manager scripts (and vice versa). The split keeps each layer focused while `common.sh` carries everything that's genuinely shared.

## Host list convention

Generic — same code works for any host type.

```bash
export HOST_FILE="${SCRIPT_DIR}/edge_nodes.txt"       # or managers.txt
export HOST_EXAMPLE="${SCRIPT_DIR}/edge_nodes.example"
source "${REPO_ROOT}/lib/common.sh"
load_ips
# HOST_IPS[@] is now populated
```

## Multi-cluster (managers only)

The Manager rolling reboot supports any number of independent NSX clusters via an INI-style config:

```ini
[GER1]
hosts = 192.168.20.10, 192.168.20.11, 192.168.20.12
admin_user = admin

[GER2]
hosts = 192.168.30.10, 192.168.30.11, 192.168.30.12
admin_user = admin
```

`parse_managers_conf` populates:
- `CLUSTER_COUNT` — number of clusters
- `CLUSTER_LABELS[i]` — section name
- `CLUSTER_HOSTS_<i>[]` — array of hosts (any size)
- `CLUSTER_ADMIN_USER_<i>` — admin user (default "admin")

When credentials are needed per cluster:
- `ask_cluster_creds <idx>` prompts admin + root pass for that cluster
- `with_cluster_creds <idx> <fn> [args]` temporarily exports `NSX_USER`/`NSX_PASS`/`ROOT_PASS` from the cluster's stored values, runs `fn`, restores the previous env

## Where to put new code

| If your function is… | Put it in… |
|---|---|
| Generic (no edge/manager assumption) | `lib/common.sh` |
| Edge-specific but reusable | `lib/nsx_edge.sh` |
| Manager-specific but reusable | `lib/nsx_manager.sh` |
| Only meaningful for one automation | inside that automation's folder |

If you write the same helper twice across two automations, that's the cue to promote it to the appropriate `lib/`.

## Language strategy: Bash by default, Go on demand

Bash is the default and the existing toolkit stays in Bash. It is the right tool for what
this repo does today: sequential SSH against a handful of hosts, interactive
credential-driven flows, and glue over `ssh`/`awk`/`sed`/`crontab`. The current code is
tested (BATS), hardened, and stable — it is not rewritten.

A **new** automation moves to **Go** (not Python) only when it hits **at least one** of
these triggers:

| Trigger | Why Bash struggles | What Go gives |
|---|---|---|
| **Real concurrency** — act on many nodes in parallel (e.g. reboot/collect across 50+ edges at once, with a parallelism cap and aggregated errors) | `&`/`wait`/`xargs -P` is fragile, no clean error aggregation | goroutines + `errgroup` + a semaphore channel |
| **Heavy REST** — primarily talks to the NSX Policy/Manager API (pagination, retry/backoff, structured JSON, typed payloads) | `curl` + `awk` doesn't scale or type | `net/http` + structs + `encoding/json` |
| **Complex state** — non-trivial state machine, transactional resume, checkpointed idempotency | Bash state files don't get unit tests or types | typed state + real unit tests |
| **Performance/volume** — parsing/aggregating thousands of lines | `fork`+`pipe` overhead | native, fast |

If **none** apply (sequential SSH, few hosts, interactive flow), it **stays in Bash**.

**Why Go and not Python:** for a jump-host, SSH-heavy toolkit running across heterogeneous
distros, Go ships a single static binary (`CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build`)
with **zero runtime dependencies** — cross-compile once, `scp` it, run it like a `.sh`. No
interpreter, no venv, no pip. "Recompiling every run" is a myth: you compile once on the
dev machine. Go also aligns with the surrounding infra ecosystem (Terraform, kubectl, NSX
SDK are all Go).

When the first trigger fires, Go code lands in a new `go/` tree (`cmd/<automation>` +
`internal/{nsxssh,config,nsxapi,notify}`), **isolated from the Bash `lib/`**. Parity with
the Bash helpers is built on demand — only what that first automation needs — and the
`managers.conf` parser must preserve the same anti-injection validation as
`parse_managers_conf`. See [GO_FRAMEWORK.md](GO_FRAMEWORK.md) for the chosen stack.
