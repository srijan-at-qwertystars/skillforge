# Backup Troubleshooting Guide

> Comprehensive guide to diagnosing and resolving backup failures, corruption, performance issues,
> and monitoring gaps across filesystem, database, and cloud backup systems.

## Table of Contents

- [Failed Restore Diagnosis](#failed-restore-diagnosis)
  - [Common Restore Failure Patterns](#common-restore-failure-patterns)
  - [Restic Restore Failures](#restic-restore-failures)
  - [Borg Restore Failures](#borg-restore-failures)
  - [Database Restore Failures](#database-restore-failures)
- [Corruption Detection and Repair](#corruption-detection-and-repair)
  - [Repository Corruption Detection](#repository-corruption-detection)
  - [Restic Repository Repair](#restic-repository-repair)
  - [Borg Repository Repair](#borg-repository-repair)
  - [Backup File Corruption](#backup-file-corruption)
- [Slow Backup Performance Analysis](#slow-backup-performance-analysis)
  - [Diagnosis Methodology](#diagnosis-methodology)
  - [I/O Bottleneck Analysis](#io-bottleneck-analysis)
  - [CPU Bottleneck Analysis](#cpu-bottleneck-analysis)
  - [Memory Pressure Analysis](#memory-pressure-analysis)
  - [Backend-Specific Performance Tuning](#backend-specific-performance-tuning)
- [Storage Quota Management](#storage-quota-management)
  - [Identifying Storage Consumers](#identifying-storage-consumers)
  - [Emergency Space Recovery](#emergency-space-recovery)
  - [Proactive Quota Management](#proactive-quota-management)
- [Network Backup Optimization](#network-backup-optimization)
  - [Compression Strategies](#compression-strategies)
  - [Deduplication Tuning](#deduplication-tuning)
  - [Bandwidth Limiting and Scheduling](#bandwidth-limiting-and-scheduling)
  - [Connection Optimization](#connection-optimization)
- [Backup Lock Contention](#backup-lock-contention)
  - [Restic Lock Management](#restic-lock-management)
  - [Borg Lock Management](#borg-lock-management)
  - [Database Backup Locking](#database-backup-locking)
- [Incremental Chain Repair](#incremental-chain-repair)
  - [Understanding Incremental Chains](#understanding-incremental-chains)
  - [Broken Chain Recovery](#broken-chain-recovery)
  - [Preventing Chain Corruption](#preventing-chain-corruption)
- [Backup Monitoring Gaps](#backup-monitoring-gaps)
  - [Essential Backup Metrics](#essential-backup-metrics)
  - [Alerting Configuration](#alerting-configuration)
  - [Monitoring Stack Integration](#monitoring-stack-integration)
  - [Backup SLA Dashboards](#backup-sla-dashboards)

---

## Failed Restore Diagnosis

### Common Restore Failure Patterns

**Systematic diagnosis checklist:**

```bash
#!/bin/bash
# restore-diagnosis.sh — Quick diagnostic for restore failures
echo "=== Restore Failure Diagnosis ==="

# 1. Check backup exists and is accessible
echo "--- Backup Repository Access ---"
restic -r "$REPO" snapshots --latest 5 2>&1 || echo "FAIL: Cannot access repository"

# 2. Check available disk space at restore target
echo "--- Disk Space ---"
df -h /restore-target/
BACKUP_SIZE=$(restic -r "$REPO" stats latest --json 2>/dev/null | jq '.total_size')
echo "Backup size: $((BACKUP_SIZE / 1024 / 1024)) MB"

# 3. Check permissions
echo "--- Permissions ---"
ls -la /restore-target/
id

# 4. Check network connectivity (for remote repos)
echo "--- Network ---"
ping -c 3 backup-server 2>&1 | tail -1

# 5. Check for version mismatches
echo "--- Version ---"
restic version
```

**Common failure causes and solutions:**

| Symptom | Likely Cause | Solution |
|---------|-------------|----------|
| "repository not found" | Wrong path/credentials | Verify RESTIC_REPOSITORY, AWS keys |
| "wrong password" | Password changed/lost | Check RESTIC_PASSWORD or key file |
| Partial restore | Disk full | Free space, use `--target` to alt location |
| Permission denied | Running as wrong user | Use sudo or match original permissions |
| "pack not found" | Repository corruption | Run `restic check`, then `repair packs` |
| Slow restore | Network/IO bottleneck | Check bandwidth, use `--target` on fast disk |
| Timeout errors | Network instability | Retry with `--retry-lock`, check firewall |

### Restic Restore Failures

```bash
# Diagnose: list snapshots to verify backup exists
restic -r "$REPO" snapshots --json | jq '.[] | {id: .short_id, time, paths, tags}'

# Diagnose: check specific snapshot contents
restic -r "$REPO" ls latest | head -20

# Fix: restore with verbose output to identify failure point
restic -r "$REPO" restore latest --target /restore --verbose=3 2>&1 | tee restore.log

# Fix: restore specific files instead of full snapshot
restic -r "$REPO" restore latest --target /restore \
  --include "/etc/nginx" --include "/var/lib/postgresql"

# Fix: mount and copy manually (for selective recovery)
restic -r "$REPO" mount /mnt/restic-mount &
cp -a /mnt/restic-mount/snapshots/latest/etc/important.conf /etc/
fusermount -u /mnt/restic-mount
```

### Borg Restore Failures

```bash
# Diagnose: list archives
borg list /backup/borg-repo

# Diagnose: check archive integrity before restore
borg check --verify-data /backup/borg-repo::archive-name

# Fix: extract with verbose output
borg extract --verbose --list /backup/borg-repo::archive-name 2>&1 | tee extract.log

# Fix: extract specific path
borg extract /backup/borg-repo::archive-name home/user/documents

# Fix: dry-run extract to verify without writing
borg extract --dry-run --list /backup/borg-repo::archive-name

# Fix: handle "Repository has been moved" error
borg config /backup/borg-repo storage_quota 0  # if quota is the issue
# If repo was moved to new path:
borg config /backup/borg-repo id  # note the ID
# Move repo back to original path or update symlinks
```

### Database Restore Failures

```bash
# PostgreSQL: diagnose pg_restore failures
pg_restore -U postgres -d mydb --list backup.dump | head -20  # list TOC
pg_restore -U postgres -d mydb -v backup.dump 2>&1 | tee restore.log

# Fix: restore with error continuation
pg_restore -U postgres -d mydb --clean --if-exists \
  --no-owner --no-privileges backup.dump 2>&1 | grep -i error

# Fix: restore specific tables
pg_restore -U postgres -d mydb -t critical_table backup.dump

# Fix: handle "database already exists"
psql -U postgres -c "DROP DATABASE IF EXISTS mydb;"
psql -U postgres -c "CREATE DATABASE mydb OWNER appuser;"
pg_restore -U postgres -d mydb backup.dump

# MySQL: diagnose restore failures
mysql -u root -p test_db < backup.sql 2>&1 | head -20

# Fix: handle character set issues
mysql -u root -p --default-character-set=utf8mb4 test_db < backup.sql

# Fix: handle foreign key constraint failures during restore
mysql -u root -p -e "SET FOREIGN_KEY_CHECKS=0; SOURCE backup.sql; SET FOREIGN_KEY_CHECKS=1;"
```

---

## Corruption Detection and Repair

### Repository Corruption Detection

```bash
# Restic: full integrity check (reads all data from backend)
restic -r "$REPO" check --read-data 2>&1 | tee check.log
# Expected: "no errors were found"
# Concerning: "pack XXXXX: does not exist" or "blob not found"

# Restic: check subset (faster, samples N% of packs)
restic -r "$REPO" check --read-data-subset=5% 2>&1

# Borg: full integrity check
borg check --verify-data /backup/borg-repo 2>&1 | tee check.log

# Borg: check only repository structure (faster)
borg check /backup/borg-repo

# Borg: check specific archive
borg check --archives-only --verify-data --last 3 /backup/borg-repo

# Verify file checksums for dump-based backups
sha256sum -c /backup/checksums.sha256
md5sum -c /backup/checksums.md5
```

### Restic Repository Repair

```bash
# Step 1: Identify broken packs
restic -r "$REPO" check 2>&1 | grep -E "(error|missing|orphaned)"

# Step 2: Repair pack index
restic -r "$REPO" repair index
# Rebuilds the index from actual pack files on the backend

# Step 3: Repair snapshots (remove references to missing data)
restic -r "$REPO" repair snapshots --forget
# Creates new snapshots without references to broken/missing packs

# Step 4: Remove orphaned packs
restic -r "$REPO" prune

# Step 5: Verify repair
restic -r "$REPO" check --read-data

# Nuclear option: rebuild entire index from scratch
restic -r "$REPO" cat config  # save config ID
restic -r "$REPO" repair index --read-all-packs
```

### Borg Repository Repair

```bash
# Step 1: Check and diagnose
borg check --verbose /backup/borg-repo 2>&1 | tee check.log

# Step 2: Repair repository
borg check --repair /backup/borg-repo
# WARNING: This may remove corrupted archives. Always backup the repo first!

# Step 3: Rebuild manifest (if manifest is corrupted)
# First, backup the repo directory
cp -a /backup/borg-repo /backup/borg-repo.bak

# Step 4: Verify repair
borg check --verify-data /backup/borg-repo
borg list /backup/borg-repo  # verify archives are listed

# Step 5: Compact to reclaim space from removed data
borg compact /backup/borg-repo
```

### Backup File Corruption

```bash
# Test gzip integrity
gzip -t backup.sql.gz && echo "OK" || echo "CORRUPTED"

# Test tar archive integrity
tar -tzf backup.tar.gz > /dev/null && echo "OK" || echo "CORRUPTED"

# Repair truncated gzip (recover partial data)
zcat backup.sql.gz > recovered.sql 2>/dev/null
wc -l recovered.sql  # check how much was recovered

# Test GPG-encrypted backup
gpg --batch --passphrase-file /etc/backup-key -d backup.sql.gz.gpg | gzip -t

# Validate PostgreSQL custom-format dump
pg_restore --list backup.dump > /dev/null && echo "OK" || echo "CORRUPTED"
```

---

## Slow Backup Performance Analysis

### Diagnosis Methodology

**Step-by-step performance diagnosis:**

```bash
# 1. Baseline: measure backup time and data volume
time restic -r "$REPO" backup /data --verbose 2>&1 | tee backup.log
# Look for: "processed X files, Y GiB in Z:MM"

# 2. Identify bottleneck category
# Check if CPU, I/O, memory, or network is the limiting factor

# Quick system overview during backup
vmstat 5  # CPU, memory, swap, IO
iostat -x 5  # disk I/O per device
iftop -n  # network bandwidth (live)
```

### I/O Bottleneck Analysis

```bash
# Check disk utilization during backup
iostat -xz 5 3
# Key metrics:
# - %util > 90%: disk saturated
# - await > 10ms: high latency
# - r/s + w/s: IOPS

# Check for I/O wait
sar -u 5 3
# %iowait > 20% indicates I/O bottleneck

# Solutions:
# 1. Use faster storage (NVMe vs spinning disk)
# 2. Reduce I/O priority: ionice -c3 restic backup /data
# 3. Exclude large changing files: --exclude='*.log'
# 4. Use LVM/ZFS snapshots to reduce read contention
# 5. Schedule backups during low-I/O periods
```

### CPU Bottleneck Analysis

```bash
# Check CPU usage during backup
top -b -n 1 -p $(pgrep -d, restic) 2>/dev/null
mpstat -P ALL 5 3

# CPU bottleneck indicators:
# - Compression: high CPU but low I/O
# - Encryption: consistent high single-core usage
# - Chunking: CPU-bound during scan phase

# Solutions:
# 1. Reduce compression level: borg create --compression lz4 (fast)
# 2. Increase worker threads: set GOMAXPROCS for restic
# 3. Use hardware AES (check: grep aes /proc/cpuinfo)
# 4. For Borg, lz4 or no compression is fastest
```

### Memory Pressure Analysis

```bash
# Check memory during backup
free -h
vmstat 5 | awk '{print $7, $8}'  # swap in/out

# Restic memory issues
# Large repos need more memory for index operations
# If OOM, check: dmesg | grep -i "out of memory"

# Solutions:
# 1. Limit restic cache size: --cache-dir=/tmp/restic-cache
# 2. Split large backups into multiple runs
# 3. For Borg: limit chunk index size with smaller repos
# 4. Add swap as emergency buffer
```

### Backend-Specific Performance Tuning

```bash
# S3 backend optimization
restic -r s3:s3.amazonaws.com/bucket backup /data \
  -o s3.connections=20 \          # increase parallel uploads (default: 5)
  -o s3.region=us-east-1           # explicit region avoids redirect

# SFTP backend optimization
restic -r sftp:user@host:/backup backup /data \
  -o sftp.connections=10 \         # parallel SFTP connections
  -o sftp.command="ssh -o Compression=no user@host -s sftp"  # disable SSH compression

# REST server backend (fastest for LAN)
# On backup server:
rest-server --path /backup --listen :8000 --no-auth
# On client:
restic -r rest:http://backup-server:8000/ backup /data

# Borg performance tuning
borg create --compression none \   # skip compression for speed
  --chunker-params=buzhash,19,23,21,4095 \
  --checkpoint-interval 300 \      # checkpoint every 5 min
  /backup/repo::archive /data
```

---

## Storage Quota Management

### Identifying Storage Consumers

```bash
# Restic: storage breakdown
restic -r "$REPO" stats                    # total size
restic -r "$REPO" stats --mode raw-data    # raw data size (before dedup)
restic -r "$REPO" stats --mode restore-size  # restore size

# Per-snapshot storage (identify large snapshots)
restic -r "$REPO" snapshots --json | \
  jq -r '.[] | "\(.short_id)\t\(.time | split("T")[0])\t\(.tags | join(","))"'

# Borg: storage breakdown
borg info /backup/borg-repo
borg list --format '{name}{TAB}{size}{NEWLINE}' /backup/borg-repo

# S3: bucket size
aws s3 ls s3://backup-bucket --summarize --recursive | tail -2

# Local: directory sizes
du -sh /backup/* | sort -rh | head -20
```

### Emergency Space Recovery

```bash
# Restic: aggressive prune
restic -r "$REPO" forget \
  --keep-last 3 --keep-daily 3 --keep-weekly 2 \
  --prune --max-unused 0

# Borg: aggressive prune + compact
borg prune --keep-last 3 --keep-daily 3 /backup/borg-repo
borg compact /backup/borg-repo

# Remove specific old snapshots
restic -r "$REPO" forget abc123def  # remove by snapshot ID
restic -r "$REPO" prune             # reclaim space

# Clean restic cache
restic cache --cleanup
rm -rf ~/.cache/restic/

# S3: abort incomplete multipart uploads (hidden space consumers)
aws s3api list-multipart-uploads --bucket backup-bucket | \
  jq -r '.Uploads[] | .UploadId' | while read id; do
    aws s3api abort-multipart-upload --bucket backup-bucket \
      --key "$key" --upload-id "$id"
  done
```

### Proactive Quota Management

```bash
#!/bin/bash
# quota-monitor.sh — Alert before storage runs out
REPO="$1"
WARN_PERCENT=80
CRIT_PERCENT=90

# For S3
BUCKET_SIZE=$(aws s3 ls s3://$BUCKET --summarize --recursive | \
  grep "Total Size" | awk '{print $3}')
QUOTA=$((5 * 1024 * 1024 * 1024 * 1024))  # 5 TB quota
USAGE_PCT=$((BUCKET_SIZE * 100 / QUOTA))

if [ "$USAGE_PCT" -ge "$CRIT_PERCENT" ]; then
  echo "CRITICAL: Backup storage at ${USAGE_PCT}%"
  # Trigger emergency prune
elif [ "$USAGE_PCT" -ge "$WARN_PERCENT" ]; then
  echo "WARNING: Backup storage at ${USAGE_PCT}%"
fi
```

---

## Network Backup Optimization

### Compression Strategies

| Algorithm | Speed | Ratio | CPU Usage | Best For |
|-----------|-------|-------|-----------|----------|
| lz4       | Fastest | Low | Minimal | Fast networks, CPU-limited |
| zstd,1    | Fast  | Good  | Low | General purpose |
| zstd,3    | Medium | Better | Moderate | Balanced (default recommend) |
| zstd,9    | Slow  | Best  | High | Slow networks, compress-once |
| zlib,6    | Slow  | Good  | High | Legacy compatibility |

```bash
# Borg: test compression options
borg create --compression lz4 /backup/repo::test-lz4 /data
borg create --compression zstd,3 /backup/repo::test-zstd /data
borg info /backup/repo  # compare sizes

# Restic: compression (v0.14+)
restic -r "$REPO" backup /data --compression max  # best ratio
restic -r "$REPO" backup /data --compression auto  # default
restic -r "$REPO" backup /data --compression off   # no compression
```

### Deduplication Tuning

```bash
# Check dedup effectiveness
borg info /backup/borg-repo
# Look for: "Deduplicated size" vs "Original size"
# Good: >2:1 ratio. Poor: <1.5:1

# Improve dedup ratio:
# 1. Don't pre-compress data before backup
# 2. Exclude constantly-changing files
# 3. Use the same repo for similar data sets
# 4. Avoid tar/zip archives as backup input
```

### Bandwidth Limiting and Scheduling

```bash
# Restic bandwidth limits
restic -r "$REPO" backup /data \
  --limit-upload 25000 \    # 25 MB/s
  --limit-download 50000    # 50 MB/s

# Borg via SSH rate limiting
borg create --remote-ratelimit 25000 ssh://backup@host/./repo::archive /data

# rsync bandwidth limit
rsync -avz --bwlimit=25000 /data/ backup@host:/backup/

# OS-level: tc (traffic control) for precise bandwidth management
tc qdisc add dev eth0 root tbf rate 200mbit burst 32kbit latency 400ms

# Schedule-based limits (in backup script)
HOUR=$(date +%H)
if [ "$HOUR" -ge 8 ] && [ "$HOUR" -lt 18 ]; then
  BW_LIMIT="--limit-upload 10000"  # 10 MB/s during business hours
else
  BW_LIMIT=""  # unlimited outside business hours
fi
restic -r "$REPO" backup /data $BW_LIMIT
```

### Connection Optimization

```bash
# SSH: optimize for backup traffic
# In ~/.ssh/config for backup connections:
Host backup-server
  Compression no              # backup tools handle compression
  Ciphers aes128-gcm@openssh.com  # fast cipher with hardware acceleration
  MACs hmac-sha2-256-etm@openssh.com
  ServerAliveInterval 60
  ServerAliveCountMax 3
  ControlMaster auto          # connection multiplexing
  ControlPath ~/.ssh/ctrl-%r@%h:%p
  ControlPersist 600

# Test SSH throughput
dd if=/dev/zero bs=1M count=100 | ssh backup-server 'cat > /dev/null'

# S3: use regional endpoints (avoid cross-region latency)
export AWS_DEFAULT_REGION=us-east-1
restic -r s3:s3.us-east-1.amazonaws.com/bucket backup /data

# Use S3 Transfer Acceleration for cross-region uploads
restic -r s3:bucket.s3-accelerate.amazonaws.com/prefix backup /data
```

---

## Backup Lock Contention

### Restic Lock Management

```bash
# List current locks
restic -r "$REPO" list locks

# Diagnose: check for stale locks (from crashed backup processes)
restic -r "$REPO" list locks --json | \
  jq '.[] | select(.time | split("T")[0] < "'$(date -d '-1 day' +%F)'")'

# Remove stale locks (safe if no backup is running)
restic -r "$REPO" unlock

# Remove all locks including non-stale (use with caution)
restic -r "$REPO" unlock --remove-all

# Prevent lock contention: use --retry-lock
restic -r "$REPO" backup /data --retry-lock 30m
# Retries acquiring the lock for up to 30 minutes
```

### Borg Lock Management

```bash
# Check for locks
ls -la /backup/borg-repo/lock*

# Break stale lock (verify no borg process is running first)
borg break-lock /backup/borg-repo

# For remote repos
borg break-lock ssh://backup@host/./repo

# Check for borg processes before breaking lock
pgrep -a borg
ssh backup@host "pgrep -a borg"
```

### Database Backup Locking

```bash
# PostgreSQL: identify backup-related locks
psql -U postgres -c "
  SELECT pid, state, query, wait_event_type, wait_event
  FROM pg_stat_activity
  WHERE query ILIKE '%backup%' OR query ILIKE '%pg_dump%'
  ORDER BY query_start;
"

# PostgreSQL: check for long-running pg_dump blocking queries
psql -U postgres -c "
  SELECT blocked.pid, blocked.query, blocking.pid AS blocking_pid
  FROM pg_stat_activity blocked
  JOIN pg_locks bl ON bl.pid = blocked.pid
  JOIN pg_locks kl ON kl.locktype = bl.locktype AND kl.relation = bl.relation
  JOIN pg_stat_activity blocking ON blocking.pid = kl.pid
  WHERE NOT bl.granted AND blocked.pid != blocking.pid;
"

# MySQL: check for backup locks
mysql -u root -p -e "SHOW PROCESSLIST;" | grep -i backup

# MySQL: long-running FLUSH TABLES WITH READ LOCK
mysql -u root -p -e "SHOW OPEN TABLES WHERE In_use > 0;"
```

---

## Incremental Chain Repair

### Understanding Incremental Chains

**Chain types:**

```
Traditional incremental chain:
  [Full] → [Inc1] → [Inc2] → [Inc3] → [Inc4]
  Restore Inc4 requires: Full + Inc1 + Inc2 + Inc3 + Inc4

Differential chain:
  [Full] → [Diff1]
         → [Diff2]
         → [Diff3]
  Restore Diff3 requires: Full + Diff3

Dedup-based (restic/borg):
  [Snap1 chunks] [Snap2 chunks] [Snap3 chunks]
  Each snapshot references specific chunks
  No chain dependency — any snapshot is independently restorable
```

### Broken Chain Recovery

```bash
# XtraBackup: repair broken incremental chain
# If Inc2 is corrupted, you lose Inc2 and all subsequent incrementals

# Step 1: Identify last good backup in chain
xtrabackup --prepare --target-dir=/backup/full-2024-01-15
xtrabackup --prepare --target-dir=/backup/full-2024-01-15 \
  --incremental-dir=/backup/inc-2024-01-16
# If the next --prepare fails, this is where the chain breaks

# Step 2: Restore from last good point
xtrabackup --copy-back --target-dir=/backup/full-2024-01-15

# Step 3: Start a new chain with a fresh full backup
xtrabackup --backup --target-dir=/backup/full-$(date +%F)

# PostgreSQL WAL chain repair
# If WAL files are missing, PITR stops at the gap

# Step 1: Identify missing WAL files
pg_archivecleanup -n /backup/wal 000000010000000000000050
# Lists files that would be removed — shows the chain

# Step 2: Check for gaps
ls /backup/wal/ | sort | awk '{
  if (NR > 1 && $1 != expected) print "GAP before " $1
  expected = sprintf("%024X", strtonum("0x" $1) + 1) ".gz"
}'

# Step 3: If gaps exist, you can only recover up to the gap
# Set recovery_target_lsn or recovery_target_time before the gap
```

### Preventing Chain Corruption

```bash
# 1. Periodic full backups to limit chain length
# Schedule weekly full + daily incremental
0 2 * * 0 /usr/local/bin/backup-full.sh    # Sunday full
0 2 * * 1-6 /usr/local/bin/backup-inc.sh   # Mon-Sat incremental

# 2. Verify chain integrity after each backup
restic -r "$REPO" check 2>&1 | grep -E "(error|warning)" && \
  echo "CHAIN INTEGRITY ISSUE" | mail -s "Backup Alert" admin@company.com

# 3. Use dedup-based tools (restic, borg) to avoid chain dependency entirely
# Every snapshot is independently restorable — no chain to break

# 4. WAL archiving: verify continuous archiving
psql -U postgres -c "SELECT pg_stat_get_archiver();"
# Check: archived_count is increasing, failed_count is 0
# Check: last_archived_time is recent
```

---

## Backup Monitoring Gaps

### Essential Backup Metrics

Monitor these metrics to catch issues before they become outages:

| Metric | Warning | Critical | Check Method |
|--------|---------|----------|-------------|
| Last successful backup age | >26h | >50h | Snapshot timestamp |
| Backup duration | >2× baseline | >4× baseline | Timing data |
| Backup size delta | ±30% from baseline | ±50% from baseline | Snapshot stats |
| Repository size growth | >10% weekly | >20% weekly | `stats` command |
| Restore test result | N/A | Any failure | Automated test |
| Storage utilization | >75% | >90% | `df` / S3 metrics |
| Error count in logs | >0 | >5 | Log parsing |

### Alerting Configuration

```bash
#!/bin/bash
# backup-alerting.sh — Comprehensive backup monitoring script
set -euo pipefail

REPO="${RESTIC_REPOSITORY}"
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"
MAX_AGE_HOURS=26
MIN_SIZE_MB=100
BASELINE_DURATION_SEC=3600  # 1 hour baseline

alert() {
  local level="$1" msg="$2"
  echo "[$level] $msg"

  if [ -n "$SLACK_WEBHOOK" ]; then
    local emoji="⚠️"
    [ "$level" = "CRITICAL" ] && emoji="🚨"
    curl -s -X POST "$SLACK_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"text\":\"${emoji} Backup ${level} on $(hostname): ${msg}\"}"
  fi
}

# Check 1: Backup freshness
LAST_BACKUP=$(restic -r "$REPO" snapshots --latest 1 --json 2>/dev/null | \
  jq -r '.[0].time // empty')
if [ -z "$LAST_BACKUP" ]; then
  alert "CRITICAL" "No snapshots found in repository"
else
  AGE_SEC=$(( $(date +%s) - $(date -d "$LAST_BACKUP" +%s) ))
  AGE_HOURS=$((AGE_SEC / 3600))
  if [ "$AGE_HOURS" -gt 50 ]; then
    alert "CRITICAL" "Last backup is ${AGE_HOURS}h old"
  elif [ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]; then
    alert "WARNING" "Last backup is ${AGE_HOURS}h old"
  fi
fi

# Check 2: Backup size anomaly
LATEST_SIZE=$(restic -r "$REPO" stats latest --json 2>/dev/null | \
  jq '.total_size // 0')
PREV_SIZE=$(restic -r "$REPO" stats latest~1 --json 2>/dev/null | \
  jq '.total_size // 0' 2>/dev/null || echo "$LATEST_SIZE")
if [ "$PREV_SIZE" -gt 0 ]; then
  DELTA=$(( (LATEST_SIZE - PREV_SIZE) * 100 / PREV_SIZE ))
  if [ "${DELTA#-}" -gt 50 ]; then
    alert "CRITICAL" "Backup size changed by ${DELTA}%"
  elif [ "${DELTA#-}" -gt 30 ]; then
    alert "WARNING" "Backup size changed by ${DELTA}%"
  fi
fi

# Check 3: Repository integrity (weekly)
DOW=$(date +%u)
if [ "$DOW" -eq 7 ]; then
  if ! restic -r "$REPO" check 2>/dev/null; then
    alert "CRITICAL" "Repository integrity check FAILED"
  fi
fi

echo "Backup monitoring completed at $(date)"
```

### Monitoring Stack Integration

**Prometheus metrics exporter:**

```bash
#!/bin/bash
# backup-metrics.sh — Generate Prometheus metrics for node_exporter textfile collector
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
METRICS_FILE="${METRICS_DIR}/backup_metrics.prom"

cat > "${METRICS_FILE}.tmp" << EOF
# HELP backup_last_success_timestamp_seconds Timestamp of last successful backup
# TYPE backup_last_success_timestamp_seconds gauge
backup_last_success_timestamp_seconds{repo="primary"} $(date -d "$LAST_BACKUP" +%s)

# HELP backup_last_duration_seconds Duration of last backup in seconds
# TYPE backup_last_duration_seconds gauge
backup_last_duration_seconds{repo="primary"} ${DURATION}

# HELP backup_snapshot_count Total number of snapshots
# TYPE backup_snapshot_count gauge
backup_snapshot_count{repo="primary"} $(restic -r "$REPO" snapshots --json | jq length)

# HELP backup_repo_size_bytes Total repository size in bytes
# TYPE backup_repo_size_bytes gauge
backup_repo_size_bytes{repo="primary"} $(restic -r "$REPO" stats --json | jq '.total_size')

# HELP backup_success_bool Whether the last backup succeeded (1=yes, 0=no)
# TYPE backup_success_bool gauge
backup_success_bool{repo="primary"} ${SUCCESS}
EOF

mv "${METRICS_FILE}.tmp" "${METRICS_FILE}"
```

**Prometheus alerting rules:**

```yaml
# prometheus/rules/backup-alerts.yml
groups:
  - name: backup_alerts
    rules:
      - alert: BackupStale
        expr: (time() - backup_last_success_timestamp_seconds) > 93600  # 26h
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Backup is stale on {{ $labels.instance }}"

      - alert: BackupMissing
        expr: (time() - backup_last_success_timestamp_seconds) > 180000  # 50h
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Backup is MISSING on {{ $labels.instance }}"

      - alert: BackupFailed
        expr: backup_success_bool == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Last backup FAILED on {{ $labels.instance }}"

      - alert: BackupSlow
        expr: backup_last_duration_seconds > 4 * avg_over_time(backup_last_duration_seconds[30d])
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Backup taking 4x longer than average on {{ $labels.instance }}"
```

### Backup SLA Dashboards

Key dashboard panels for a Grafana backup SLA dashboard:

1. **Backup Status Overview**: Table of all hosts with last backup time, colored by freshness
2. **Backup Duration Trend**: Time series of backup durations over 30 days
3. **Backup Size Trend**: Time series of backup sizes with anomaly band
4. **Repository Growth Rate**: Rate of storage consumption
5. **Restore Test Results**: Pass/fail history for automated restore tests
6. **Storage Utilization**: Gauge of backup storage usage vs quota

```json
{
  "title": "Backup SLA Dashboard",
  "panels": [
    {
      "title": "Backup Freshness",
      "type": "stat",
      "targets": [{"expr": "(time() - backup_last_success_timestamp_seconds) / 3600"}],
      "thresholds": {"steps": [
        {"color": "green", "value": 0},
        {"color": "yellow", "value": 26},
        {"color": "red", "value": 50}
      ]}
    }
  ]
}
```
