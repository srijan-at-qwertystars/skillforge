---
name: backup-strategies
description: >
  Guide for implementing production backup and disaster recovery solutions.
  Covers the 3-2-1 backup rule, backup types (full, incremental, differential, synthetic full),
  filesystem backups (rsync, borgbackup, restic, duplicity), database backups
  (pg_dump, pg_basebackup, WAL archiving, mysqldump, xtrabackup, mongodump),
  cloud backups (AWS S3 lifecycle, GCS, Azure Blob), snapshot-based backups
  (LVM, ZFS, EBS), Kubernetes backup with Velero, backup verification/testing,
  disaster recovery planning (RPO/RTO), encryption, retention policies, monitoring,
  bare-metal restore, and automated backup scripts with cron/systemd timers.
  Use when user needs backup setup, disaster recovery, database backup, rsync, restic,
  borgbackup, snapshot management, backup automation, or restore procedures.
  NOT for high availability/failover setup, NOT for replication configuration,
  NOT for version control/git.
---

# Backup Strategies

## Core Principles

### 3-2-1-1-0 Rule
Maintain **3** copies of data on **2** different media types with **1** offsite copy, **1** immutable/air-gapped copy, and **0** errors (verified restores). Every backup plan starts here.

### RPO and RTO
- **RPO (Recovery Point Objective)**: Maximum acceptable data loss measured in time. Drives backup frequency.
- **RTO (Recovery Time Objective)**: Maximum acceptable downtime. Drives restore method selection.
- Classify systems by criticality. Tier-1 (RPO <1h, RTO <1h) needs continuous WAL/binlog shipping. Tier-3 (RPO <24h, RTO <8h) needs daily dumps.

### Backup Types
| Type | Description | Storage | Restore Speed |
|------|-------------|---------|---------------|
| Full | Complete copy every run | Highest | Fastest |
| Incremental | Only changes since last backup (any type) | Lowest | Slowest (chain) |
| Differential | Changes since last full | Medium | Medium (full + diff) |
| Synthetic Full | Reconstructs full from previous full + incrementals server-side | Medium | Fast |

## Filesystem Backups

### rsync
Mirror files with delta transfer. No deduplication, no encryption, no snapshots.
```bash
# Basic mirror with delete
rsync -avz --delete /data/ user@backup:/backup/data/

# Exclude patterns, bandwidth limit
rsync -avz --delete --exclude='*.tmp' --exclude='.cache/' --bwlimit=10000 /data/ user@backup:/backup/data/

# Hardlink-based incremental snapshots
rsync -avz --delete --link-dest=/backup/data/latest /data/ /backup/data/$(date +%F)
ln -snf /backup/data/$(date +%F) /backup/data/latest
```

### BorgBackup
Deduplicating, compressed, encrypted archiver. Best for local/SSH targets.
```bash
# Initialize encrypted repo
borg init --encryption=repokey-blake2 /backup/borg-repo
export BORG_PASSPHRASE='your-secure-passphrase'

# Create backup with compression
borg create --compression zstd,3 --stats \
  /backup/borg-repo::{hostname}-{now:%Y-%m-%dT%H:%M} \
  /etc /home /var/lib --exclude '*.cache'

# Prune: keep 7 daily, 4 weekly, 6 monthly
borg prune --keep-daily=7 --keep-weekly=4 --keep-monthly=6 /backup/borg-repo
borg compact /backup/borg-repo

# Restore specific archive
borg extract /backup/borg-repo::myhost-2024-01-15T02:00 home/user/documents

# List archives and verify
borg list /backup/borg-repo
borg check --verify-data /backup/borg-repo
```

### Restic
Deduplicating backup with native cloud backend support. Always encrypted.
```bash
# Initialize repo on S3
restic -r s3:s3.amazonaws.com/my-backup-bucket init

# Backup with tags and exclusions
restic -r s3:s3.amazonaws.com/my-backup-bucket backup \
  /data /etc --tag production --exclude-file=/etc/restic-excludes

# Apply retention policy
restic -r s3:s3.amazonaws.com/my-backup-bucket forget \
  --keep-hourly 24 --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune

# Restore latest snapshot to target
restic -r s3:s3.amazonaws.com/my-backup-bucket restore latest --target /restore

# Verify snapshot integrity
restic -r s3:s3.amazonaws.com/my-backup-bucket check --read-data
```

### Duplicity
GPG-encrypted incremental backups with broad backend support.
```bash
duplicity full /data s3://s3.amazonaws.com/my-bucket/backup
duplicity /data s3://s3.amazonaws.com/my-bucket/backup          # incremental
duplicity --full-if-older-than 30D /data s3://s3.amazonaws.com/my-bucket/backup
duplicity remove-older-than 90D --force s3://s3.amazonaws.com/my-bucket/backup
duplicity restore --time 3D s3://s3.amazonaws.com/my-bucket/backup /restore/
```

## Database Backups

### PostgreSQL

#### pg_dump (Logical)
Use for individual databases, cross-version migration, selective restore.
```bash
# Custom format (parallel restore capable)
pg_dump -U postgres -d mydb -Fc -j4 -f mydb_$(date +%F).dump

# Plain SQL with all objects
pg_dump -U postgres -d mydb --create --clean --if-exists \
  --routines --triggers -f mydb_$(date +%F).sql

# Cluster-wide (roles + all databases)
pg_dumpall -U postgres -f cluster_$(date +%F).sql

# Restore custom format with parallelism
pg_restore -U postgres -d mydb -j4 --clean --if-exists mydb_2024-01-15.dump
```

#### pg_basebackup (Physical) + WAL Archiving for PITR
Use for full-cluster backup with point-in-time recovery.
```bash
# Configure WAL archiving in postgresql.conf
# wal_level = replica
# archive_mode = on
# archive_command = 'gzip < %p > /backup/wal/%f.gz'

# Take base backup with WAL streaming
pg_basebackup -U replicator -D /backup/base/$(date +%F) \
  -Ft -z -P -X stream -c fast

# PITR restore procedure:
# 1. Stop PostgreSQL
# 2. Clear data directory, restore base backup
# 3. Configure recovery in postgresql.conf:
#    restore_command = 'gunzip < /backup/wal/%f.gz > %p'
#    recovery_target_time = '2024-01-15 14:30:00'
# 4. Create recovery.signal file
# 5. Start PostgreSQL — replays WAL to target time
```

### MySQL

#### mysqldump (Logical)
```bash
# Full backup with consistent snapshot (InnoDB)
mysqldump -u root -p --single-transaction --flush-logs \
  --routines --triggers --events --all-databases \
  | gzip > all_db_$(date +%F).sql.gz

# Restore
gunzip < all_db_2024-01-15.sql.gz | mysql -u root -p
```

#### Percona XtraBackup (Physical)
```bash
# Full hot backup
xtrabackup --backup --target-dir=/backup/full-$(date +%F)

# Incremental backup based on last full
xtrabackup --backup --target-dir=/backup/inc-$(date +%F) \
  --incremental-basedir=/backup/full-2024-01-15

# Prepare and restore
xtrabackup --prepare --target-dir=/backup/full-2024-01-15
xtrabackup --prepare --target-dir=/backup/full-2024-01-15 \
  --incremental-dir=/backup/inc-2024-01-16
# Stop MySQL, clear datadir, copy back, fix permissions, start MySQL
xtrabackup --copy-back --target-dir=/backup/full-2024-01-15
chown -R mysql:mysql /var/lib/mysql
```

### MongoDB
```bash
# Full dump with oplog for PITR consistency (replica sets)
mongodump --uri="mongodb://user:pass@host:27017" \
  --oplog --gzip --out=/backup/mongo-$(date +%F)

# Single database with compression
mongodump --db=myapp --gzip --archive=/backup/myapp-$(date +%F).gz

# Restore with oplog replay
mongorestore --oplogReplay --gzip /backup/mongo-2024-01-15/

# Restore single collection
mongorestore --db=myapp --collection=orders --gzip \
  /backup/mongo-2024-01-15/myapp/orders.bson.gz
```

## Cloud Backups

### AWS S3 with Lifecycle Policies
```bash
# Sync backup directory to S3 with server-side encryption
aws s3 sync /backup/ s3://my-backup-bucket/$(hostname)/ \
  --storage-class STANDARD_IA --sse AES256 --delete

# Create lifecycle policy (JSON)
cat > lifecycle.json << 'EOF'
{
  "Rules": [{
    "ID": "BackupLifecycle",
    "Status": "Enabled",
    "Filter": {"Prefix": ""},
    "Transitions": [
      {"Days": 30, "StorageClass": "STANDARD_IA"},
      {"Days": 90, "StorageClass": "GLACIER"},
      {"Days": 365, "StorageClass": "DEEP_ARCHIVE"}
    ],
    "Expiration": {"Days": 2555}
  }]
}
EOF
aws s3api put-bucket-lifecycle-configuration \
  --bucket my-backup-bucket --lifecycle-configuration file://lifecycle.json

# Enable versioning + object lock for immutability
aws s3api put-bucket-versioning --bucket my-backup-bucket \
  --versioning-configuration Status=Enabled
```

### GCS and Azure Blob
```bash
gsutil -m rsync -r -d /backup/ gs://my-backup-bucket/              # GCS upload
gsutil lifecycle set lifecycle.json gs://my-backup-bucket/           # GCS lifecycle
az storage blob upload-batch --destination backups --source /backup/ --tier Cool  # Azure
```

## Snapshot-Based Backups

### LVM Snapshots
```bash
# Create snapshot, backup, remove
lvcreate -L5G -s -n data_snap /dev/vg0/data
dd if=/dev/vg0/data_snap bs=1M | pigz > /backup/data_$(date +%F).img.gz
lvremove -f /dev/vg0/data_snap
```

### ZFS Snapshots
```bash
# Create and list snapshots
zfs snapshot tank/data@backup-$(date +%F)
zfs list -t snapshot -r tank/data

# Send snapshot to remote (incremental)
zfs send -i tank/data@prev tank/data@current | ssh backup zfs recv tank/data

# Rollback
zfs rollback tank/data@backup-2024-01-15

# Prune: destroy old snapshots
zfs destroy tank/data@backup-2024-01-01
```

### AWS EBS Snapshots
```bash
# Create snapshot with tags
aws ec2 create-snapshot --volume-id vol-0abc123 \
  --description "Daily $(date +%F)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Backup,Value=daily}]'

# Prune snapshots older than 30 days
aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:Backup,Values=daily" \
  --query "Snapshots[?StartTime<='$(date -d '-30 days' +%F)'].SnapshotId" \
  --output text | xargs -n1 aws ec2 delete-snapshot --snapshot-id
```

## Kubernetes Backup with Velero

```bash
# Install Velero with AWS S3 backend
velero install --provider aws \
  --bucket velero-backups \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --secret-file ./aws-credentials \
  --backup-location-config region=us-east-1

# One-time backup of specific namespace
velero backup create prod-backup --include-namespaces production

# Scheduled backup: daily at 2AM UTC, retain 7 days
velero schedule create daily-prod \
  --schedule="0 2 * * *" --ttl 168h \
  --include-namespaces production

# Restore to different namespace
velero restore create --from-backup prod-backup \
  --namespace-mappings production:staging

# Check backup status
velero backup describe prod-backup --details
velero backup logs prod-backup
```

## Backup Verification and Testing

Untested backups are not backups. Automate verification.

```bash
# Verify restic repository integrity
restic -r /backup/repo check --read-data

# Verify borg archive
borg check --verify-data /backup/borg-repo

# PostgreSQL: restore to temp DB and validate row counts
pg_restore -U postgres -d test_restore mydb.dump
psql -U postgres -d test_restore -c "SELECT count(*) FROM critical_table;"
psql -U postgres -c "DROP DATABASE test_restore;"

# MySQL: verify dump is valid SQL
gunzip < backup.sql.gz | mysql --connect-timeout=5 -u root -p test_restore
mysql -u root -p -e "DROP DATABASE test_restore;"

# File-level verification script
#!/bin/bash
BACKUP_DIR="/backup/latest"
CHECKSUM_FILE="/backup/checksums.sha256"
sha256sum -c "$CHECKSUM_FILE" || alert "Backup verification FAILED"
```

## Encryption

```bash
# At rest — Restic: always encrypted (AES-256). Borg: use repokey-blake2
borg init --encryption=repokey-blake2 /backup/repo

# GPG for dump files
pg_dump -U postgres mydb | gzip | gpg --symmetric --cipher-algo AES256 \
  --batch --passphrase-file /etc/backup-key > mydb.dump.gz.gpg

# In transit — SSH tunneling
rsync -avz -e "ssh -i /root/.ssh/backup_key" /data/ backupuser@remote:/backup/

# TLS for database connections
pg_dump "host=db sslmode=verify-full sslrootcert=/certs/ca.pem" -d mydb -f dump.sql

# S3: enforce SSL via bucket policy
# {"Condition":{"Bool":{"aws:SecureTransport":"false"}},"Effect":"Deny"}
```

## Retention Policies

### GFS (Grandfather-Father-Son)
```bash
# Restic GFS retention
restic forget \
  --keep-hourly 24 \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 12 \
  --keep-yearly 3 \
  --prune

# Borg GFS retention
borg prune --keep-hourly=24 --keep-daily=7 --keep-weekly=4 \
  --keep-monthly=12 --keep-yearly=3 /backup/borg-repo
```

Retention by tier: Tier-1 critical (hourly/30d, daily/90d, monthly/1y, yearly/7y). Tier-3 non-critical (daily/14d, weekly/60d, monthly/6m).

## Automation with Cron and systemd Timers

### Cron
```bash
# /etc/cron.d/backup
0 2 * * * root /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1
0 3 * * 0 root /usr/local/bin/backup-full.sh >> /var/log/backup.log 2>&1
```

### systemd Timer (preferred)
```ini
# /etc/systemd/system/backup.service
[Unit]
Description=Daily Backup
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup.sh
StandardOutput=journal
StandardError=journal

# /etc/systemd/system/backup.timer
[Unit]
Description=Run backup daily at 2AM

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```
```bash
systemctl enable --now backup.timer
systemctl list-timers --all | grep backup
journalctl -u backup.service --since today
```

## Backup Monitoring and Alerting

```bash
#!/bin/bash
# backup-monitor.sh — check backup freshness and alert
BACKUP_DIR="/backup/latest"
MAX_AGE_HOURS=26
LAST_BACKUP=$(stat -c %Y "$BACKUP_DIR" 2>/dev/null || echo 0)
NOW=$(date +%s)
AGE_HOURS=$(( (NOW - LAST_BACKUP) / 3600 ))

if [ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]; then
  curl -s -X POST "$SLACK_WEBHOOK" \
    -d "{\"text\":\"🚨 Backup STALE on $(hostname): ${AGE_HOURS}h old\"}"
  exit 1
fi
# Check backup size (detect empty/truncated backups)
MIN_SIZE_MB=100
ACTUAL_SIZE=$(du -sm "$BACKUP_DIR" | cut -f1)
[ "$ACTUAL_SIZE" -lt "$MIN_SIZE_MB" ] && echo "WARNING: Backup too small" && exit 1
echo "OK: Backup is ${AGE_HOURS}h old, ${ACTUAL_SIZE}MB"
```

## Bare-Metal Restore

Procedure for full system recovery:
1. Boot from live USB/PXE with network access.
2. Partition and format disks matching original layout. Document partition scheme in backup metadata.
3. Restore filesystem from backup:
```bash
# From restic
restic -r s3:s3.amazonaws.com/bucket restore latest --target /mnt/restore

# From borg
cd /mnt/restore && borg extract /backup/borg-repo::latest

# From tar/dd
gunzip < /backup/system.img.gz | dd of=/dev/sda bs=1M
```
4. Reinstall bootloader: `grub-install /dev/sda && update-grub` (chroot into restored system).
5. Verify fstab UUIDs match new disk layout.
6. Reboot and validate all services start.

Store partition layout, package list, and network config alongside backups:
```bash
fdisk -l > /backup/meta/partitions.txt
dpkg --get-selections > /backup/meta/packages.txt
ip addr show > /backup/meta/network.txt
```

## Example: Complete Backup Script

```bash
#!/bin/bash
set -euo pipefail
REPO="s3:s3.amazonaws.com/company-backups"
HOSTNAME=$(hostname -s)
LOG="/var/log/backup-$(date +%F).log"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }

# Filesystem backup
log "Starting filesystem backup"
restic -r "$REPO" backup /etc /home /var/lib/postgresql \
  --tag "$HOSTNAME" --exclude-caches 2>&1 | tee -a "$LOG"

# Database backup
log "Dumping PostgreSQL"
pg_dump -U postgres -Fc production > /tmp/prod.dump
restic -r "$REPO" backup /tmp/prod.dump --tag db 2>&1 | tee -a "$LOG"
rm -f /tmp/prod.dump

# Apply retention
log "Applying retention policy"
restic -r "$REPO" forget --tag "$HOSTNAME" \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune 2>&1 | tee -a "$LOG"

# Verify
log "Verifying backup integrity"
restic -r "$REPO" check 2>&1 | tee -a "$LOG"

log "Backup completed successfully"
```
