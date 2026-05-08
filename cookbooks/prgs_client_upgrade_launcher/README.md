# prgs_client_upgrade_launcher Cookbook

## Problem

At scale (~80,000 nodes across RHEL 6/7/8 and Windows 2012–2022), a subset of
nodes have `chef-client` running but their converge **fails at the recipe level**
— a broken recipe earlier in the run list aborts the converge before any upgrade
recipe can execute. The standard tag-based upgrade flow does not work for these
nodes because the upgrade recipe never gets reached.

## Solution

This cookbook is the **bootstrap step** for the deferred upgrade workflow. It is
designed to run **first** (prepended to the failing node's run list) so it
executes before any broken recipe can abort the converge.

It does not perform the upgrade itself. Instead it schedules a **one-shot
deferred job** — a `cron_d` entry (Linux) or a Task Scheduler job (Windows) —
that runs `chef-client -o 'recipe[prgs_chef_custom_migration]'` with an
override run-list. The `-o` flag bypasses the node's normal (broken) run list
entirely, allowing the upgrade recipe to run cleanly.

### Key design decisions

| Decision | Detail |
|---|---|
| **Prepend, not append** | `role[chef_upgrade_cron]` is prepended so this recipe runs before any broken recipe can abort the converge |
| **Deferred execution** | The job runs outside the Chef converge, so even if the rest of the run list fails after this recipe, the upgrade is already scheduled |
| **Override run-list (`-o`)** | Only `prgs_chef_custom_migration` runs; the node's saved run list is not modified |
| **Sentinel file** | A dedicated flag file (`/etc/chef/.upgrade_scheduled` on Linux, `C:\chef\upgrade_scheduled` on Windows) is the sole idempotency guard — written at scheduling time, removed only by the upgrade recipe after a confirmed successful install |
| **Conditional self-removal (`&&`)** | The cron/task removes itself **only on `chef-client` exit 0**; on failure it stays and retries, allowing automatic recovery |
| **flock concurrency guard (Linux)** | `flock -n` prevents a second cron tick from spawning a concurrent `chef-client` if the first run exceeds 1 minute |
| **PowerShell exit-code check (Windows)** | `$LASTEXITCODE` replaces `cmd.exe &` (unconditional) so the task deletes itself only on success |

## Requirements

### Platforms

- RHEL 6, 7, 8, 9
- Windows Server 2012, 2016, 2019, 2022

### Chef

- Chef >= 16.0

### Prerequisites

- The node must have a working `chef-client` installation (even if converge
  fails at recipe level). Nodes with a corrupted or stopped `chef-client`
  cannot be reached by this mechanism — identify them via stale `ohai_time`:
  ```
  knife node show <node> -a ohai_time
  ```
- Linux: `flock` must be available (part of `util-linux`, present on all RHEL variants)
- Windows: PowerShell and Task Scheduler service must be running

## Recipes

### prgs_client_upgrade_launcher::default

**Linux** — creates `/etc/cron.d/chef-slave-upgrade`:

```bash
flock -n /var/run/chef-slave-upgrade.lock \
  chef-client -o 'recipe[prgs_chef_custom_migration]' \
  && rm -f /etc/cron.d/chef-slave-upgrade
```

**Windows** — registers Task Scheduler job `chef-slave-upgrade`:

```powershell
chef-client -o 'recipe[prgs_chef_custom_migration]'
if ($LASTEXITCODE -eq 0) {
  schtasks /Delete /TN 'chef-slave-upgrade' /F
  Remove-Item -Force 'C:\chef\upgrade_scheduled'
}
```

Guards:
- `not_if`  — sentinel flag file already present → skip (already scheduled)
- `only_if` — node tag must be one of `prepare`, `upgrade`, or `rollback`

## Workflow

1. Node is tagged `prepare`, `upgrade`, or `rollback` via the Jenkins pipeline (`tag_nodes.sh`).
2. `role[chef_upgrade_cron]` (which includes `recipe[prgs_client_upgrade_launcher::default]`) is **prepended** to the node's run list via `prepend_role.sh`.
3. On the next Chef converge this recipe runs first, creates the scheduled job, and writes the sentinel file.
4. Even if the rest of the run list fails, the job is already scheduled.
5. The scheduled job fires and runs `chef-client -o 'recipe[prgs_chef_custom_migration]'` — bypassing all broken recipes.
6. On success: the cron entry / task removes itself; the upgrade recipe removes the sentinel file.
7. On failure: the cron entry / task remains and retries on the next tick until it succeeds.

## Observability

```bash
# Linux — verify cron entry was created
cat /etc/cron.d/chef-slave-upgrade

# Linux — check sentinel file
ls -la /etc/chef/.upgrade_scheduled

# Linux — watch cron execution logs
journalctl -u crond -f
```

```powershell
# Windows — verify task is registered
Get-ScheduledTask -TaskName 'chef-slave-upgrade'

# Windows — check sentinel file
Test-Path 'C:\chef\upgrade_scheduled'

# Windows — view task execution history
Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' |
  Where-Object { $_.Message -match 'chef-slave-upgrade' }
```

## License and Authors

Authors: The Authors  
License: All Rights Reserved

