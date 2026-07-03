# Contributing: Adding a New Automation

## Step 1 — Create the folder

```bash
mkdir -p automations/<your_automation_name>
cd automations/<your_automation_name>
```

## Step 2 — Decide the target type

- **Edge automation** → source `lib/common.sh` + `lib/nsx_edge.sh`
- **Manager automation** → source `lib/common.sh` + `lib/nsx_manager.sh`

## Step 3 — Host list

**You usually don't need one.** Automations read the central per-DC inventory
(`inventory/edge_nodes.txt` / `inventory/managers.conf`) via
`resolve_inventory_file` — point `HOST_FILE` at a local name and the central
fallback is automatic (see Step 4).

Only ship a local `.example` template if your automation targets a **subset**
of the estate by design (an automation-local file overrides the central one):

```bash
cat > edge_nodes.example <<'EOF'
# edge_nodes.example — OPTIONAL subset override; omit to use inventory/.
# 192.168.10.10
EOF
```

## Step 4 — Skeleton script

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
# Local file wins if present; otherwise lib/common.sh falls back to
# inventory/<same-basename> (central per-DC inventory).
export HOST_FILE="${SCRIPT_DIR}/<edge_nodes|managers>.txt"
export HOST_EXAMPLE="${SCRIPT_DIR}/<edge_nodes|managers>.example"
source "${REPO_ROOT}/lib/common.sh"
source "${REPO_ROOT}/lib/<nsx_edge|nsx_manager>.sh"

need_cmd ssh
load_ips
[[ -f "${ADMIN_KEY}" ]] || ask_admin_creds

for ip in "${HOST_IPS[@]}"; do
  admin_cmd "$ip" "get version"
done

clear_creds
```

## Step 5 — Available functions

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full list. Highlights:

### Always available (`lib/common.sh`)
- `load_ips` / `HOST_IPS[@]`
- `ask_admin_creds`, `reprompt_admin_creds`, `clear_creds`, `confirm_clear_creds_with_timeout`
- `ssh_admin`, `admin_cmd`
- `ssh_admin_retry <ip> <cmd> [retries] [base]` — linear-backoff wrapper for read-only commands
- `tcp_check`
- `log`/`log_ok`/`log_warn`/`log_err`/`log_banner` (log_err honors `NSX_NOTIFY_WEBHOOK`)
- `tbl_header`, `tbl_row`, `tbl_footer`
- `parse_uptime_days`, `parse_version_short`
- `resolve_inventory_file <path>` — local file wins, else `inventory/<basename>`, else the local path again (so errors stay local). Applied to `HOST_FILE` automatically at source time
- `parse_datacenters_conf <file>` + `dc_jump_host/dc_jump_user/dc_repo_path/dc_ssh_key <idx>` — INI parser for the multi-DC orchestrator; same anti-injection validation as `parse_managers_conf`
- `parse_reboot_plan <file>` + `plan_dc/plan_ip <idx>` — orchestrator-side ordered plan for the daily rolling reboot; rejects shell-meta, malformed lines, and duplicate IPs
- `install_crontab_line`, `remove_crontab_line`
- `ensure_local_ssh_key`
- `save_session_env`, `load_session_env`, `auto_clear_session_after`
- `rotate_logs [days] [dir]` — call once at the end of the run; honors `NSX_LOG_RETENTION_DAYS`
- `_ssh_stderr_redir` — internal; honored by `ssh_admin`/`ssh_root` via `NSX_DEBUG`

### Edge (`lib/nsx_edge.sh`)
- `enable_root_ssh` / `disable_root_ssh`
- `ssh_root`, `root_cmd`, `ask_root_creds`
- `request_support_bundle`, `check_support_bundle`, `list_remote_bundles`
- `bundle_file_date`, `bundle_duration`
- `precheck_bundle_for <ip>` — shared classifier; returns via `PCR_STATUS`, `PCR_ACTION`, `PCR_FILE`, `PCR_SKIP`, `PCR_DURATION`, `PCR_TOTAL`
- `try_admin_ssh_with_retry`
- `register_edge_admin_key`, `register_edge_root_key` — return 0/1; distinguish "already registered" from "newly registered"

### Manager (`lib/nsx_manager.sh`)
- `parse_managers_conf`, `cluster_hosts`, `cluster_admin_user`, `find_cluster_for_ip`, `reboot_one_manager_by_ip`
- `ask_cluster_creds`, `with_cluster_creds`
- `reboot_manager_and_wait` (gates on `wait_cluster_stable` after TCP comes back)
- `wait_cluster_stable <ip> [timeout] [interval]` — poll `get cluster status` for STABLE; bypass with `NSX_SKIP_CLUSTER_GATE=1`
- `rolling_reboot_cluster` — honors `NSX_DRY_RUN`, `NSX_RESUME_FROM`, `NSX_STATE_FILE` env contracts
- `register_manager_admin_key <ip> <pub_val> [label] [key_type]` — `key_type` defaults to `ssh-rsa`; use `ssh-ed25519` for ed25519 keys
- `test_ssh_admin`
- `get_cluster_status`, `get_managers`

## Step 6 — README for your automation

Document: purpose, workflow, prerequisites, usage example. Look at `automations/kb404700_disk_validation/README.md` for a concise reference.

## Step 7 — Tests (if you added a pure parser)

Pure parsers (no SSH / no network) belong in `tests/test_parsers.bats`. To run locally:

```bash
sudo apt-get install -y bats   # or `brew install bats-core`
bats tests/
```

CI runs the bats suite + shellcheck on every push/PR (`.github/workflows/lint.yml`).

## Step 8 — Commit

```bash
git add automations/<your_automation_name>/
git commit -m "feat(automations): add <your_automation_name>"
git push origin main
```
