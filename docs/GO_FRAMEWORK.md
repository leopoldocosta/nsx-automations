# Go framework — reference for the first Go automation

> **Status:** reference only. **No Go code exists yet.** This document describes the
> chosen stack and layout to use *when* a new automation hits one of the triggers in
> [ARCHITECTURE.md](ARCHITECTURE.md#language-strategy-bash-by-default-go-on-demand).
> Do not create the `go/` tree until that happens.

## When this applies

Build in Go only when a new automation needs **at least one** of: real concurrency,
heavy NSX REST usage, complex/transactional state, or high parsing volume. Otherwise it
stays in Bash. See ARCHITECTURE.md for the full trigger table.

## Chosen stack

| Concern | Choice | Notes |
|---|---|---|
| SSH | `golang.org/x/crypto/ssh` | Canonical; same lib Terraform/kubectl use. Optional `github.com/melbahja/goph` as an ergonomic wrapper. |
| Concurrency | `golang.org/x/sync/errgroup` + semaphore (`chan struct{}`) | Cap parallelism per fleet; aggregate errors cleanly. |
| CLI | `github.com/spf13/cobra` | Subcommands, infra-ecosystem aligned. Use stdlib `flag` if the CLI is trivial. |
| Config (flat) | stdlib | `edge_nodes.txt` — one IPv4 per line, `#` comments. |
| Config (INI) | `gopkg.in/ini.v1` | `managers.conf` — **must replicate the anti-injection validation** of `parse_managers_conf`. |
| REST (REST trigger only) | stdlib `net/http` + `encoding/json` | Retry/backoff via `github.com/cenkalti/backoff`. |
| Logging | stdlib `log/slog` (Go 1.21+) | Honor the same tunables as Bash: `NSX_DEBUG`, `NSX_NOTIFY_WEBHOOK`, `NSX_LOG_RETENTION_DAYS`. |
| Tests | stdlib `testing`, table-driven | Mirror the BATS security fixtures. |
| Build | `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build` | Single static binary, zero runtime deps. |

## Layout (created on first use)

```
nsx-automations/
├── lib/                      # Bash legacy — untouched
├── automations/              # Bash automations — untouched
├── bin/                      # untouched
│
└── go/                       # ← new, only when the first trigger fires
    ├── go.mod
    ├── Makefile              # cross-compile + scp helper
    ├── cmd/
    │   └── <automation>/main.go      # one binary per automation (or multi-cmd via Cobra)
    └── internal/
        ├── nsxssh/           # SSH (key auth + password fallback) — parity with common.sh/nsx_edge/nsx_manager
        ├── config/           # edge_nodes.txt + managers.conf parsers (same validation)
        ├── nsxapi/           # REST client (only if the REST trigger applies)
        └── notify/           # webhook (Slack/Teams) — parity with Bash log_err webhook
```

- Built binaries go in `.gitignore` — only source is committed.
- `bin/deploy.sh` can later gain optional support to copy `go/` binaries (not now).

## Parity map with `lib/` (build on demand, not all at once)

| Bash (`lib/`) | Go (`internal/`) | Priority |
|---|---|---|
| `_sshpass_safe`, SSH key/pass | `nsxssh` (key auth + password fallback) | high |
| `load_ips` / `collect_ips` | `config.LoadEdges` | high |
| `parse_managers_conf` (+ anti-injection) | `config.ParseManagers` (+ same validation) | high if multi-cluster |
| `log_*`, banner, table | `slog` + table helper | high |
| `tcp_check` | `net.DialTimeout` | medium |
| webhook on `log_err` | `notify.Webhook` | medium |
| `rotate_logs` | `internal/logrotate` | low |
| crontab helpers | keep in Bash (`install_crontab.sh`) | n/a |

## Deploy

Cross-compile on the dev machine → `scp` the binary to the jump host → run it directly.
No Python, no venv, no pip, no compilation on the target. This removes the implicit Bash
dependency on `bash 4.3+` and `sshpass` being present on heterogeneous distros.

## CI

Add a Go job (`go vet`, `go test ./...`, `staticcheck`) **alongside** the existing
BATS/shellcheck pipeline — both worlds coexist.

## First-use verification

When the first Go binary is built, validate the strategy against an NSX lab:
1. It runs on the jump host with **no dependencies installed**.
2. The `managers.conf` parser rejects the same malicious payloads as the BATS fixtures
   (`tests/fixtures/managers_malformed.conf`).
3. Concurrency respects the configured parallelism cap.
