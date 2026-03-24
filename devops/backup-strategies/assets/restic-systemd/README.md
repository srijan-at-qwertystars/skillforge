# Systemd service and timer for automated restic backups
#
# Installation:
#   1. Copy restic-backup.service and restic-backup.timer to /etc/systemd/system/
#   2. Create /etc/restic-env containing your restic configuration
#   3. Install the backup script to /usr/local/bin/backup-restic.sh
#   4. Enable and start:
#        systemctl daemon-reload
#        systemctl enable --now restic-backup.timer
#   5. Verify:
#        systemctl list-timers --all | grep restic
#        journalctl -u restic-backup.service --since today

This directory contains:
  - restic-backup.service  — oneshot service unit for running the backup
  - restic-backup.timer    — timer unit for scheduling daily backups
  - restic-env.example     — example environment file with required variables
