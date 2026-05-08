# prgs_client_upgrade_launcher Cookbook CHANGELOG

This file is used to list changes made in each version of the master cookbook.

## 0.1.0 (2026-05-08)

- Initial release
- Adds `cron_d` resource to schedule one-shot Chef Client upgrade
- Guards execution with `upgrade19` and `rollback16` node tags
- Cron entry self-removes after the upgrade run completes
