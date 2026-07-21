# TO-DO

All pending deliverables — operational AND code — tracked here so they
survive sessions and operators. Remove items when done (git history keeps
the record).

Suggested order: **2 → 3 → 0 → rollout → 5 → 1 → 4 → 6** (item 2 blocks
enabling the production reboot cron; item 0 comes before mass rollout;
item 6 is best done BEFORE writing the 7-DC datacenters.conf — less to edit).

## 0. Harden the `netops` OS user on every jump VM (PENDING)

`netops` must be a plain user — verify and tighten on each VM:

```bash
# 1. NOT an admin: no wheel/sudo membership, no sudoers entry
id netops                                  # groups must list ONLY netops
gpasswd -d netops wheel 2>/dev/null        # RHEL-family: remove if present
gpasswd -d netops sudo  2>/dev/null        # Debian-family: remove if present
grep -r netops /etc/sudoers /etc/sudoers.d/ && echo "REMOVE these entries"

# 2. Key-only access after bootstrap: lock the password
#    (SSH keys keep working; console/password login stops)
passwd -l netops

# 3. Private home (blocks other users reading its files, incl. .ssh)
chmod 700 /home/netops

# 4. sshd: pin where netops can log in from + no password auth
#    /etc/ssh/sshd_config:
#      Match User netops
#          AllowUsers netops@<ip-da-orquestradora>
#          PasswordAuthentication no
#    then: systemctl reload sshd
```

Notes:
- A plain Linux user can still READ world-readable files (`/etc/*.conf`,
  binaries) — that is the OS default, not admin access. The line that
  matters: it must NOT read `/etc/shadow`, write outside its home, or
  elevate via sudo/su.
- Do NOT use ForceCommand/rbash for netops: the toolkit needs a real
  shell (bash -lc) and rsync on the jump side.
- Stronger isolation (optional, RHEL-family): map netops to a confined
  SELinux user — `semanage login -a -s user_u netops` (user_u cannot su/sudo
  at the SELinux layer even if misconfigured elsewhere). Test before fleet.
- **Set a UNIQUE hostname per jump** (`hostnamectl set-hostname jump-dc-<x>`,
  as root). Field finding 2026-07-07: five jumps cloned from the same
  template all answered `dev-redes` (+1 typo'd `deve-redes`) — operators
  cannot tell sessions apart and every log/notification says the same host.
  The Slack notifications (`[NSX][<hostname>] ERR:`) are useless until this
  is fixed.

### Threat model — you cannot wall `netops` off from a local `root` (don't try)

`root` is the security boundary on the jump, not `netops`. Every lock root
sets, root removes. Recurring operator questions and why the "obvious" fixes
are theater — documented here so nobody re-derives (and re-tries) them:

- **"Make `su - netops` prompt for a password, even from root."** What frees
  root is `auth sufficient pam_rootok.so` in `/etc/pam.d/su`; comment it out
  and root does get prompted — but it stops nobody: `sudo -u netops -s`,
  `runuser -u netops -- bash`, a 3-line `os.setuid()` in python, or just
  re-editing the PAM file all bypass it. **Skip it.**
- **"Stop root changing netops's password without knowing the old one."**
  `passwd netops` as root never needs the old password. `chattr +i
  /etc/shadow` blocks even `passwd` — until root runs `chattr -i` first, and
  it breaks legitimate password management. **Not a real control.**
- **"Prevent cracking netops's password."** Offline (root already holds the
  `/etc/shadow` hash) you cannot prevent, only slow it down (yescrypt/sha512 +
  long random pw). The real answer is step 2 above — `passwd -l netops` → there
  is NO password to crack, key-only login. The thing you actually block is
  ONLINE brute force: `pam_faillock` (lockout after N failures) + `fail2ban`
  on sshd.

What DOES matter is **controlling who becomes root** and **making root
accountable** — prevention against a root that is already present is
impossible; detection and blast-radius are not:

- No shared root: `PermitRootLogin no`, per-person named accounts, elevation
  via a TIGHT sudoers that explicitly denies `sudo su`, `sudo -i`,
  `sudo -u netops`, `sudo passwd`. No root password handed around.
- `auditd` logging `su`/`sudo`/`execve`, **shipped OFF the jump** (remote
  syslog). A compromised root scrubs local logs, not what already left the box.
- The crown jewels on a jump are netops's **NSX SSH keys** — a root reads them
  directly (`cat /home/netops/.ssh/id_rsa`), no `su` needed. So the real
  blast-radius control is the least-privilege NSX user (items 5 + 1) plus a
  passphrase on the device key (ssh-agent on the orchestrator). Harden the
  keys' PRIVILEGES, not the path to `netops`.
- Genuinely constraining a local root needs MAC (SELinux confined root, see
  the `user_u` note above) with a locked bootloader / Secure Boot / kernel
  lockdown — high effort, rarely worth it for a jump host. Noted, not planned.

## 1. NSX least-privilege user migration — credential cleanup (PENDING)

When the NSX-side user is switched from `admin` to a more restricted one
(e.g. the built-in read-only `audit`, or a custom role user), the old
admin-scoped SSH keys become standing credentials nobody uses — **they must
be removed on BOTH sides**:

### On every NSX device (managers AND edges, all DCs)

List what is registered, then delete the stale labels:

```text
get user admin ssh-keys
del user admin ssh-keys label nsx-automation-key    # pilot key (registered by root)
del user admin ssh-keys label netops-key            # only after the new user is validated!
```

Also check for pre-toolkit leftovers (e.g. `rsa-key-2024xxxx` labels from
the old POCs) and remove what is no longer wanted.

**Fleet standard: `netops-key` is the ACTIVE label everywhere** (script
default since 2026-07-06). Cleanup rule: delete `nsx-automation-key` and
pre-toolkit labels (`rsa-key-*` unwanted) from every device — with ONE
prerequisite:

> **DC-C managers hold netops's ACTIVE key under `nsx-automation-key`**
> (registered 2026-07-06 while it was still the script default). BEFORE the
> global delete, migrate the label there:
> 1. `./bin/configure_ssh_keys.sh --type manager` (now defaults to
>    netops-key) — if the build rejects a duplicate VALUE, `del user admin
>    ssh-keys label nsx-automation-key` on the device first (password auth
>    still works), then rerun;
> 2. require VERIFIED;
> 3. only then `nsx-automation-key` is safe to delete fleet-wide.

> Tip: fan the listing out with
> `bin/run_across_datacenters.sh --automation device_command/device_command.sh -- --cmd "get user admin ssh-keys"`
> and review per-DC CSVs before deleting anything.

### On every jump VM

- Remove the pilot-era root setup: `/root/nsx-automations` clone,
  `/root/.ssh/id_rsa[.pub]` if it was created only for NSX registration.
- Remove stale entries from `authorized_keys` (old orchestrator VMs, old
  fanout keys such as `nsx_dc_fanout`).
- Confirm nothing in root's crontab remains from the pilot: `crontab -l -u root`.

### Order matters

1. Register + `VERIFIED` the new restricted user's key everywhere.
2. Switch the automations to the new user (item 5 below: per-operation
   NSX user — read-only automations move first; `manager_rolling_reboot`
   stays on `admin` until NSX offers a restricted role that can reboot).
3. Run one full fan-out cycle green with the new user.
4. ONLY THEN delete the admin/root-era keys (NSX side, then VM side).

## 2. Harden `reboot` against the nsxcli yes/no confirmation (CODE DONE — VALIDATION PENDING, BLOCKS PROD CRON)

CODE SHIPPED (commit 45a84fb): `reboot_manager_and_wait` feeds `yes` via
stdin (field-hit on 4.1.2: without it the CLI blocked ~7min and the node
never rebooted) AND aborts the cycle with an error if the manager is
still online after `NSX_REBOOT_MAX_WAIT` — a no-op reboot can no longer
silently advance the daily plan index.

REMAINING before `bin/install_orchestrator_cron.sh` goes live:
- One CONTROLLED real reboot of a single manager (plan entry #1, run
  `bin/rolling_reboot_next.sh` manually in a maintenance-ok window) and
  watch: reboot fires -> TCP drops -> returns -> cluster STABLE ->
  index advances to 1. `--dry-run` does NOT exercise the real verb.
- Then `--reset --yes` on the eve of day 01 and install the cron.

## 3. Global `NSX_CMD_TIMEOUT` guard in `ssh_admin`/`ssh_root` (PENDING)

Systemic fix for the whole hang class: today only the CONNECTION is bounded
(`ConnectTimeout`); a remote command that prompts interactively hangs
forever, silently, under cron. Wrap the ssh invocation in
`timeout ${NSX_CMD_TIMEOUT:-120}` (lib/common.sh; jumps are Linux, coreutils
present). Classify rc=124 as "timed out — remote command may be prompting
interactively (rerun with NSX_DEBUG=1)". Document the env var in
README/MANUAL cross-cutting tables.

## 4. Audit remaining state-changing CLI verbs for prompts (PENDING)

Same root cause as items 2/3, lower exposure: grep `lib/` and `automations/`
for remote `set service ssh`, `clear`, `restart`, etc., and check each
against the field build. Apply the stdin-feed / `</dev/null` guard where a
prompt is possible (pattern: `lib/nsx_edge.sh` `_register_edge_key`).
`enable_root_ssh` / `disable_root_ssh` are in the support-bundle and
key-registration paths — also make them CHECK their rc instead of printing
"done" unconditionally (a wrong password once produced fake
"[set ssh root-login] done" output).

## 5. Least-privilege NSX user for read-only automations (PENDING)

NSX appliances ship a built-in `audit` CLI user (read-only, cannot
set/reboot). Plan:
1. enable/set password for `audit` on managers + edges;
2. register the jump's key for `audit` (mind the per-build quirks already
   solved in the registrars: inline `password` param, modern/legacy syntax,
   `VERIFIED` check);
3. toolkit: per-operation NSX user — read-only automations
   (`device_command`, `kb404700_disk_validation`, `edge_hardware_inventory`,
   precheck) default to `NSX_USER=audit`; write automations
   (`manager_rolling_reboot`, support-bundle root toggle) stay `admin`;
4. docs: MULTIDC security table + MANUAL;
5. validate on the 2-VM pilot before fleet rollout;
6. finish with the credential cleanup of item 1 above.

## 6. Centralize the jump service-user name as ONE variable (PENDING)

The `netops` username is currently repeated in many places: every
`jump_user =` line of `datacenters.conf`, every `repo_path =`
(`/home/netops/...`), docs examples, ssh-copy-id commands. Renaming the
user (or using a different one per environment) means touching them all.

Plan:
- Support a `[defaults]` section in `datacenters.conf`
  (`parse_datacenters_conf` in `lib/common.sh`):

  ```ini
  [defaults]
  jump_user = netops
  repo_base = /home/netops/nsx-automations

  [DC-1]
  jump_host = <ip>          # jump_user/repo_path inherited from defaults
  ```

  Per-section values still override (same pattern as `ssh_key`).
- Optional env override `NSX_JUMP_USER` for ad-hoc runs — but the conf
  stays authoritative because cron does not read `~/.bashrc`.
- Update docs/RUNBOOK examples to define the user once.
- Keep validation strict (same anti-injection regex on the default values).

## 7. `configure_ssh_keys.sh --type edge`: register ONLY the root key (PENDING)

Field case (2026-07-06): root passwords are NOT uniform across the edge
fleet — 4 of 8 edges rejected the typed root password
(`% Invalid current password specified`) while admin registration
succeeded everywhere. Re-running today means redoing admin (skipped fast,
but noisy) AND re-typing the root password for ALL edges when only a few
failed.

Plan:
- New flag `--users admin|root|both` (default `both`, current behavior).
  `--users root` skips admin registration/prompt entirely and only does
  enable_root_ssh -> register root key -> disable_root_ssh.
- Combine with `--hosts <file>` pointing at a subset list containing only
  the failed edges, OR accept `--only <ip>` for a single node.
- Root passwords may differ per edge: with `--users root`, prompt per host
  (or re-prompt on "% Invalid current password") instead of assuming one
  fleet-wide root password.

Field finding 2026-07-21 (DC-A edge_hardware_inventory run): admin key auth
works on all 8 DC-A edges (version/uptime collected), but the **root** key is
registered on only 4. The 4 pending edges are:

```text
xyz214.36.102   xyz214.36.103   xyz214.36.104   xyz214.36.105
```

On these, `dmidecode`/`lscpu` collection returns `Root SSH failed` and the node
is reported `ERROR` / CPU `N/A` (admin data still lands). Register the root key
there to close them — with the `--users root` flag above this becomes a
targeted rerun over just these four instead of re-touching all eight.

## 8. Slack webhook: error notifications from every jump (PENDING)

Wire `NSX_NOTIFY_WEBHOOK` fleet-wide so every `log_err` from any automation
(including the 02:00 rolling-reboot cron) lands in a Slack channel. The
hook already exists in `lib/common.sh:log_err` — this item is deployment.

Steps:
1. Create the Incoming Webhook in Slack (channel do time, ex. #nsx-ops)
   and store the URL in the team vault.
2. Firewall: each jump needs outbound HTTPS to hooks.slack.com
   (Fase 0 optional row — request for all 7 in one ticket).
3. Set on every jump: copy notify.conf.example to notify.conf (chmod 600),
   fill webhook + per-automation policy. Legacy alternative (env var on the
   fan-out's login shell, so this works for cron-triggered runs too):

   ```bash
   ./bin/run_command_across_dcs.sh -- \
     "grep -q NSX_NOTIFY_WEBHOOK ~/.bashrc || echo 'export NSX_NOTIFY_WEBHOOK=https://hooks.slack.com/services/XXX/YYY/ZZZ' >> ~/.bashrc"
   ```

4. Test end-to-end: force one failure (e.g. device_command against a
   bogus IP added to a subset host file) and confirm the message arrives:
   `[NSX][<jump-hostname>] ERR: ...`
5. Note: delivery is best-effort by design — a dead webhook never blocks
   or masks the original error. Do NOT put the URL in the repo (treat it
   as a credential; it allows posting to the channel).

## 9. Secure NSX Policy API login for `lib/nsx_api.sh` (PENDING)

Today `lb_troubleshoot` (and anything future on `lib/nsx_api.sh`) uses
Basic Auth: the admin password must pre-exist on the jump for fan-out runs
— either `run/session.env` (mode 600, saved manually per shift) or
`NSX_USER`/`NSX_PASS` in the environment. It never touches `ps` or the
orchestrator, but it is still a standing plaintext-at-rest password on
the jump. Replace with something that removes the stored password:

Plan (in preference order):
1. **Certificate-based Principal Identity** (the NSX-native way):
   generate a key+cert per jump, register it as a Principal Identity on
   the local NSX with a scoped role (read-only for diagnosis; the
   `--fix-monitor` PATCH needs `lb_admin`-level), and teach `_nsx_curl`
   to use `--cert/--key` when `NSX_API_CERT`/`NSX_API_KEY` are set —
   Basic Auth stays as fallback. Registration step belongs in
   `bin/configure_ssh_keys.sh` or a sibling `bin/configure_api_identity.sh`.
2. **Session-token auth** as an intermediate hardening: exchange
   user/password for a short-lived session cookie + X-XSRF token at run
   start (`/api/session/create`), so the password is used once per run
   instead of on every request. Still needs the stored password — does
   not close the item alone.
3. Whatever lands: per-DC scoping stays (identity registered per jump on
   ITS NSX only — same blast-radius model as the SSH keys), document in
   MULTIDC security table + the automation README, and align the RBAC
   role with item 5 (least-privilege user migration).
