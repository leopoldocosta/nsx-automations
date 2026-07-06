# TO-DO

Operational debts to settle — tracked here so they survive sessions and
operators. Remove items when done (git history keeps the record).

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
2. Switch the automations to the new user (see harness task #19: per-operation
   NSX user — read-only automations move first; `manager_rolling_reboot`
   stays on `admin` until NSX offers a restricted role that can reboot).
3. Run one full fan-out cycle green with the new user.
4. ONLY THEN delete the admin/root-era keys (NSX side, then VM side).
