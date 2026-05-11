# Cookbook:: prgs_client_upgrade_launcher
# Recipe:: default
#
# Copyright:: 2026, The Authors, All Rights Reserved.
# execute Resource: 'schedule one-shot upgrade'

# Purpose:
#   Schedules a one-time (one-shot) Chef Client upgrade by creating a
#   scheduled job (cron_d on Linux, windows_task on Windows) that runs
#   'recipe[prgs_chef_custom_migration]' via an override run-list.

# Design decisions:
#   Fix 1 — Correct sentinel file
#     A dedicated flag file (/etc/chef/.upgrade_scheduled on Linux,
#     C:\chef\upgrade_scheduled on Windows) is written at scheduling time
#     and is the sole idempotency guard.  It is removed only by the upgrade
#     recipe after a confirmed successful install.  This prevents the cron
#     file's own lifecycle from masking re-convergence attempts.
#
#   Fix 2 — Conditional self-removal (&& not ;)
#     Linux : the cron command uses && so rm only runs on chef-client success.
#             On failure the cron entry fires again next minute, allowing retry.
#     Windows: PowerShell exit-code check replaces cmd.exe & (unconditional).
#
#   Fix 3 — flock concurrency guard (Linux)
#     flock -n prevents a second cron invocation from spawning a concurrent
#     chef-client process if the first one is still running (>1 min run time).
#     The Windows Task Scheduler serialises by default; no extra guard needed.
#
#   Fix 4 — Windows self-removal uses PowerShell && equivalent
#     cmd.exe '&' is unconditional.  Replaced with powershell.exe using
#     $LASTEXITCODE so schtasks /Delete runs only on success.

# Guards:
#   not_if  — flag file present  → already scheduled, skip
#   only_if — node tag is one of 'prepare', 'upgrade', 'rollback'

# Observability:
#   Linux   — journalctl -u crond | grep chef-slave-upgrade
#   Windows — Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational

# Tags that qualify a node for upgrade scheduling
UPGRADE_TAGS = %w[prepare upgrade rollback].freeze

if platform_family?('windows')
  # ---------------------------------------------------------------------------
  # Windows — Task Scheduler
  # ---------------------------------------------------------------------------
  # Sentinel : C:\chef\upgrade_scheduled  (created by this recipe;
  # Self-removal: PowerShell checks $LASTEXITCODE so the task deletes itself
  #               ONLY when chef-client exits 0.  On failure it remains and
  #               fires again on the next scheduler tick.
  # ---------------------------------------------------------------------------
  WIN_FLAG_FILE = 'C:\chef\upgrade_scheduled'.freeze

  windows_task 'chef-slave-upgrade' do
    user      'SYSTEM'
    command   'powershell.exe'
    arguments(
      '-NonInteractive -NoProfile -Command ' \
      '"chef-client -o \'recipe[prgs_chef_custom_migration]\'; ' \
      'if ($LASTEXITCODE -eq 0) { ' \
      "  schtasks /Delete /TN 'chef-slave-upgrade' /F " \
      '}"'
    )
    run_level :highest
    frequency :minute
    # not_if  { ::File.exist?(WIN_FLAG_FILE) }  # disabled: upgrade cookbook is idempotent
    only_if { node.tags.any? { |t| UPGRADE_TAGS.include?(t) } }
  end

  # Sentinel file disabled: upgrade cookbook is idempotent, no flag file needed.
  # file WIN_FLAG_FILE do
  #   content   "scheduled by chef prgs_client_upgrade_launcher::default at #{Time.now.utc.iso8601}\n"
  #   action    :create_if_missing
  #   only_if { node.tags.any? { |t| UPGRADE_TAGS.include?(t) } }
  # end

else
  # ---------------------------------------------------------------------------
  # Linux — cron_d
  # ---------------------------------------------------------------------------
  # Sentinel : /etc/chef/.upgrade_scheduled  (created by this recipe;
  #            removed by the upgrade recipe after successful install)
  #
  # Command breakdown:
  #   flock -n /var/run/chef-slave-upgrade.lock
  #     → exclusive non-blocking lock; exits immediately if already locked,
  #       preventing a second concurrent chef-client when a run exceeds 1 min.
  #   chef-client -o 'recipe[prgs_chef_custom_migration]'
  #     → override run-list; only the migration recipe runs.
  #   && rm -f /etc/cron.d/chef-slave-upgrade
  #     → self-removes cron entry ONLY on success; on failure the entry stays
  #       and fires again next minute until the upgrade succeeds.
  # The sentinel file keeps re-convergence from registering a duplicate entry.
  # ---------------------------------------------------------------------------
  LINUX_FLAG_FILE = '/etc/chef/.upgrade_scheduled'.freeze

  # cron_d is only available in Chef >= 14.4; write the drop-in file directly
  # so this recipe works on Chef 13.x as well.
  file '/etc/cron.d/chef-slave-upgrade' do
    content "* * * * * root flock -n /var/run/chef-slave-upgrade.lock " \
            "chef-client -o 'recipe[prgs_chef_custom_migration]' " \
            "&& rm -f /etc/cron.d/chef-slave-upgrade\n"
    mode    '0644'
    owner   'root'
    group   'root'
    # not_if  { ::File.exist?(LINUX_FLAG_FILE) }  # disabled: upgrade cookbook is idempotent
    only_if { node.tags.any? { |t| UPGRADE_TAGS.include?(t) } }
  end

  # Sentinel file disabled: upgrade cookbook is idempotent, no flag file needed.
  # file LINUX_FLAG_FILE do
  #   content   "scheduled by chef prgs_client_upgrade_launcher::default at #{Time.now.utc.iso8601}\n"
  #   action    :create_if_missing
  #   only_if { node.tags.any? { |t| UPGRADE_TAGS.include?(t) } }
  # end
end
