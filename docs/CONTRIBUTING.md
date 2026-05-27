# Contributing: Adding a New Automation

## Step 1 — Create the folder

```bash
mkdir -p automations/<your_automation_name>
cd automations/<your_automation_name>
```

## Step 2 — Decide the target type

- **Edge automation** → source `lib/common.sh` + `lib/nsx_edge.sh`
- **Manager automation** → source `lib/common.sh` + `lib/nsx_manager.sh`

## Step 3 — Host list template

For Edges:
```bash
cat > edge_nodes.example <<'EOF'
# edge_nodes.example — copy to edge_nodes.txt and add IPs.
# 192.168.10.10
EOF
```

For Managers (multi-cluster):
```bash
cat > managers.conf.example <<'EOF'
# managers.conf.example — copy to managers.conf and add clusters.
# [GER1]
# hosts = 192.168.20.10, 192.168.20.11, 192.168.20.12
# admin_user = admin
EOF
```

## Step 4 — Skeleton script

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export AUTO_DIR="${SCRIPT_DIR}"
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
- `tcp_check`
- `log`/`log_ok`/`log_warn`/`log_err`/`log_banner`
- `tbl_header`, `tbl_row`, `tbl_footer`
- `parse_uptime_days`, `parse_version_short`
- `install_crontab_line`, `remove_crontab_line`
- `ensure_local_ssh_key`
- `save_session_env`, `load_session_env`, `auto_clear_session_after`

### Edge (`lib/nsx_edge.sh`)
- `enable_root_ssh` / `disable_root_ssh`
- `ssh_root`, `root_cmd`, `ask_root_creds`
- `request_support_bundle`, `check_support_bundle`, `list_remote_bundles`
- `bundle_file_date`, `bundle_duration`
- `try_admin_ssh_with_retry`
- `register_edge_admin_key`, `register_edge_root_key`

### Manager (`lib/nsx_manager.sh`)
- `parse_managers_conf`, `cluster_hosts`, `cluster_admin_user`
- `ask_cluster_creds`, `with_cluster_creds`
- `reboot_manager_and_wait`, `rolling_reboot_cluster`
- `register_manager_admin_key`, `test_ssh_admin`
- `get_cluster_status`, `get_managers`

## Step 6 — README for your automation

Document: purpose, workflow, prerequisites, usage example. Look at `automations/kb404700_disk_validation/README.md` for a concise reference.

## Step 7 — Commit

```bash
git add automations/<your_automation_name>/
git commit -m "feat(automations): add <your_automation_name>"
git push origin main
```
