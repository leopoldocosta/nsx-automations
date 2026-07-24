# Contributing

The full contributor guide — how to add a new automation, the reusable
library API, and the **fan-out contract** (non-interactive execution +
the unified-report opt-in) — lives in **[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md)**.

Two rules that bite if ignored (details in the guide):

1. **Never read `/dev/tty` on the fan-out path** — guard every credential
   prompt so it is skipped when a key is present and only runs on a real TTY.
2. **Wrap your final report in `report_wrap`** so it appears in the unified
   fleet report at the end of a multi-DC run.

Before pushing: `bash -n` your script; CI runs shellcheck + bats on every push.
