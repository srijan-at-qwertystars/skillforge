# Litestream Disaster Recovery

## Table of Contents

- [Point-in-Time Recovery](#point-in-time-recovery)
  - [Understanding Generations and WAL Segments](#understanding-generations-and-wal-segments)
  - [Restoring to a Specific Timestamp](#restoring-to-a-specific-timestamp)
  - [Restoring from a Specific Generation](#restoring-from-a-specific-generation)
  - [Finding the Right Restore Point](#finding-the-right-restore-point)
- [Automated Restore Testing](#automated-restore-testing)
  - [CI Pipeline Restore Tests](#ci-pipeline-restore-tests)
  - [Cron-Based Verification](#cron-based-verification)
  - [Restore SLA Tracking](#restore-sla-tracking)
- [Backup Verification Scripts](#backup-verification-scripts)
  - [Integrity Check After Restore](#integrity-check-after-restore)
  - [Row Count Comparison](#row-count-comparison)
  - [Schema Drift Detection](#schema-drift-detection)
- [Multi-Region Failover](#multi-region-failover)
  - [Active-Passive Architecture](#active-passive-architecture)
  - [Failover Procedure](#failover-procedure)
  - [Failback Procedure](#failback-procedure)
  - [DNS-Based Failover](#dns-based-failover)
- [RPO and RTO Calculations](#rpo-and-rto-calculations)
  - [Recovery Point Objective (RPO)](#recovery-point-objective-rpo)
  - [Recovery Time Objective (RTO)](#recovery-time-objective-rto)
  - [Tuning for Lower RPO](#tuning-for-lower-rpo)
  - [Tuning for Lower RTO](#tuning-for-lower-rto)
- [Combining with Application-Level Backups](#combining-with-application-level-backups)
  - [Logical Backups with sqlite3 .dump](#logical-backups-with-sqlite3-dump)
  - [VACUUM INTO Snapshots](#vacuum-into-snapshots)
  - [Application-Level Export](#application-level-export)
  - [Layered Backup Strategy](#layered-backup-strategy)
- [Restore to Different Environments](#restore-to-different-environments)
  - [Production to Staging](#production-to-staging)
  - [Production to Local Development](#production-to-local-development)
  - [Cross-Cloud Restore](#cross-cloud-restore)
  - [Security Considerations](#security-considerations)

---

## Point-in-Time Recovery

Litestream's WAL-based replication enables point-in-time recovery (PITR) within the retention window. You can restore the database to any point covered by available snapshots and WAL segments.

### Understanding Generations and WAL Segments

A **generation** is a contiguous series of WAL segments starting from a snapshot. A new generation begins when:
- Litestream starts for the first time
- WAL continuity is broken (e.g., database was opened without Litestream)
- Litestream restarts and detects a gap in the WAL sequence

Each generation consists of:
1. **Snapshot**: A full copy of the database file at the generation's start
2. **WAL segments**: Sequential WAL frames captured every `sync-interval`

To recover to a point in time, Litestream:
1. Restores the most recent snapshot before the target time
2. Replays WAL segments up to the target timestamp

```bash
# View available generations
litestream generations s3://my-bucket/app

# Example output:
# generation    name      lag       start                 end
# a1b2c3d4e5f6  s3        0s        2024-01-10T00:00:00Z  2024-01-15T12:00:00Z
# f6e5d4c3b2a1  s3        0s        2024-01-15T12:00:01Z  2024-01-17T08:30:00Z
```

### Restoring to a Specific Timestamp

```bash
# Restore to a specific point in time
litestream restore \
  -timestamp "2024-01-16T14:30:00Z" \
  -o /data/restored.db \
  s3://my-bucket/app

# Verify the restored database
sqlite3 /data/restored.db "PRAGMA integrity_check;"
```

The `-timestamp` flag accepts ISO 8601 format. Litestream finds the latest snapshot before the timestamp and replays WAL segments up to (but not beyond) the specified time.

### Restoring from a Specific Generation

If you know which generation contains the data you need:

```bash
# List generations
litestream generations s3://my-bucket/app

# Restore from a specific generation
litestream restore \
  -generation a1b2c3d4e5f6 \
  -o /data/restored.db \
  s3://my-bucket/app
```

This restores to the latest point in the specified generation. Combine with `-timestamp` to restore to a specific point within that generation.

### Finding the Right Restore Point

When you need to find exactly when something went wrong:

```bash
# 1. List snapshots to see available restore points
litestream snapshots s3://my-bucket/app

# 2. Restore to progressively earlier points to find the issue
for ts in "2024-01-16T15:00:00Z" "2024-01-16T14:00:00Z" "2024-01-16T13:00:00Z"; do
  litestream restore -timestamp "$ts" -o "/tmp/restore_${ts}.db" s3://my-bucket/app
  echo "=== $ts ==="
  sqlite3 "/tmp/restore_${ts}.db" "SELECT COUNT(*) FROM important_table;"
done

# 3. Once you've narrowed the window, bisect with finer timestamps
```

---

## Automated Restore Testing

The most common DR failure is discovering during an actual disaster that backups are corrupt or restores don't work. Automated testing eliminates this risk.

### CI Pipeline Restore Tests

Add a restore verification step to your CI/CD pipeline:

```yaml
# .github/workflows/backup-verify.yml
name: Verify Backups
on:
  schedule:
    - cron: '0 4 * * *'  # Daily at 4 AM UTC

jobs:
  verify-backup:
    runs-on: ubuntu-latest
    steps:
      - name: Install Litestream
        run: |
          wget -qO- https://github.com/benbjohnson/litestream/releases/latest/download/litestream-linux-amd64.tar.gz | tar xz
          sudo mv litestream /usr/local/bin/

      - name: Restore from replica
        env:
          LITESTREAM_ACCESS_KEY_ID: ${{ secrets.LITESTREAM_ACCESS_KEY_ID }}
          LITESTREAM_SECRET_ACCESS_KEY: ${{ secrets.LITESTREAM_SECRET_ACCESS_KEY }}
        run: |
          litestream restore -o /tmp/verify.db s3://my-bucket/app

      - name: Verify integrity
        run: |
          RESULT=$(sqlite3 /tmp/verify.db "PRAGMA integrity_check;")
          if [ "$RESULT" != "ok" ]; then
            echo "::error::Integrity check failed: $RESULT"
            exit 1
          fi

      - name: Verify data recency
        run: |
          # Check that the most recent record is from today
          LATEST=$(sqlite3 /tmp/verify.db "SELECT MAX(updated_at) FROM some_table;")
          echo "Latest record: $LATEST"
          # Add application-specific recency checks

      - name: Report results
        if: failure()
        run: |
          # Send alert via Slack, PagerDuty, email, etc.
          echo "Backup verification FAILED"
```

### Cron-Based Verification

For environments without CI/CD, use a cron job on the server:

```bash
#!/bin/bash
# /usr/local/bin/verify-backup.sh
set -euo pipefail

RESTORE_DIR=$(mktemp -d)
RESTORE_DB="${RESTORE_DIR}/verify.db"
LOG_FILE="/var/log/backup-verify.log"
ALERT_EMAIL="ops@example.com"

cleanup() {
  rm -rf "$RESTORE_DIR"
}
trap cleanup EXIT

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG_FILE"
}

# Restore
log "Starting backup verification"
RESTORE_START=$(date +%s)
if ! litestream restore -o "$RESTORE_DB" s3://my-bucket/app 2>>"$LOG_FILE"; then
  log "ERROR: Restore failed"
  echo "Backup restore failed" | mail -s "ALERT: Backup Verify Failed" "$ALERT_EMAIL"
  exit 1
fi
RESTORE_END=$(date +%s)
RESTORE_DURATION=$(( RESTORE_END - RESTORE_START ))
log "Restore completed in ${RESTORE_DURATION}s"

# Integrity check
INTEGRITY=$(sqlite3 "$RESTORE_DB" "PRAGMA integrity_check;" 2>>"$LOG_FILE")
if [ "$INTEGRITY" != "ok" ]; then
  log "ERROR: Integrity check failed: $INTEGRITY"
  echo "Integrity check failed: $INTEGRITY" | mail -s "ALERT: Backup Corrupt" "$ALERT_EMAIL"
  exit 1
fi
log "Integrity check passed"

# Record metrics
log "SUCCESS: Restore took ${RESTORE_DURATION}s, integrity OK"
```

Crontab entry:
```
0 3 * * * /usr/local/bin/verify-backup.sh 2>&1 | logger -t backup-verify
```

### Restore SLA Tracking

Track restore times over time to ensure you meet your RTO:

```bash
#!/bin/bash
# Append restore metrics to a tracking file
METRICS_FILE="/var/log/restore-metrics.csv"

# Initialize CSV if it doesn't exist
if [ ! -f "$METRICS_FILE" ]; then
  echo "timestamp,db_size_bytes,restore_duration_seconds,integrity" > "$METRICS_FILE"
fi

START=$(date +%s)
TMPDB=$(mktemp)
litestream restore -o "$TMPDB" s3://my-bucket/app
END=$(date +%s)
DURATION=$(( END - START ))
SIZE=$(stat -c %s "$TMPDB")
INTEGRITY=$(sqlite3 "$TMPDB" "PRAGMA integrity_check;")
rm "$TMPDB"

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$SIZE,$DURATION,$INTEGRITY" >> "$METRICS_FILE"
```

---

## Backup Verification Scripts

### Integrity Check After Restore

The minimum verification after any restore:

```bash
#!/bin/bash
DB_PATH="${1:?Usage: $0 <database-path>}"

echo "=== Database Verification ==="

# 1. File exists and is readable
if [ ! -r "$DB_PATH" ]; then
  echo "FAIL: Database file not readable"
  exit 1
fi

# 2. SQLite integrity check
INTEGRITY=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>&1)
if [ "$INTEGRITY" = "ok" ]; then
  echo "PASS: Integrity check"
else
  echo "FAIL: Integrity check: $INTEGRITY"
  exit 1
fi

# 3. Journal mode (should be WAL after Litestream restore)
JOURNAL=$(sqlite3 "$DB_PATH" "PRAGMA journal_mode;")
echo "INFO: Journal mode: $JOURNAL"

# 4. Page count and size
PAGE_COUNT=$(sqlite3 "$DB_PATH" "PRAGMA page_count;")
PAGE_SIZE=$(sqlite3 "$DB_PATH" "PRAGMA page_size;")
DB_SIZE=$(( PAGE_COUNT * PAGE_SIZE ))
echo "INFO: Database size: $(( DB_SIZE / 1048576 ))MB ($PAGE_COUNT pages x $PAGE_SIZE bytes)"

# 5. Table list
TABLES=$(sqlite3 "$DB_PATH" ".tables")
echo "INFO: Tables: $TABLES"

echo "=== Verification Complete ==="
```

### Row Count Comparison

Compare row counts between the live database and the restored backup to verify data completeness:

```bash
#!/bin/bash
LIVE_DB="${1:?Usage: $0 <live-db> <restored-db>}"
RESTORED_DB="${2:?Usage: $0 <live-db> <restored-db>}"

echo "=== Row Count Comparison ==="

# Get all table names from live database
TABLES=$(sqlite3 "$LIVE_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")

MISMATCH=0
for table in $TABLES; do
  LIVE_COUNT=$(sqlite3 "$LIVE_DB" "SELECT COUNT(*) FROM \"$table\";")
  RESTORED_COUNT=$(sqlite3 "$RESTORED_DB" "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null || echo "TABLE_MISSING")

  if [ "$RESTORED_COUNT" = "TABLE_MISSING" ]; then
    echo "FAIL: Table '$table' missing in restored DB"
    MISMATCH=1
  elif [ "$LIVE_COUNT" = "$RESTORED_COUNT" ]; then
    echo "PASS: $table — $LIVE_COUNT rows"
  else
    DIFF=$(( LIVE_COUNT - RESTORED_COUNT ))
    echo "WARN: $table — live=$LIVE_COUNT restored=$RESTORED_COUNT (diff=$DIFF)"
    # Small differences are expected due to async replication
    if [ "$DIFF" -gt 100 ]; then
      MISMATCH=1
    fi
  fi
done

if [ "$MISMATCH" -eq 1 ]; then
  echo "=== SIGNIFICANT MISMATCHES DETECTED ==="
  exit 1
fi
echo "=== All counts within acceptable range ==="
```

### Schema Drift Detection

Verify the restored database has the expected schema:

```bash
#!/bin/bash
LIVE_DB="${1:?Usage: $0 <live-db> <restored-db>}"
RESTORED_DB="${2:?Usage: $0 <live-db> <restored-db>}"

LIVE_SCHEMA=$(sqlite3 "$LIVE_DB" ".schema" | sort)
RESTORED_SCHEMA=$(sqlite3 "$RESTORED_DB" ".schema" | sort)

if [ "$LIVE_SCHEMA" = "$RESTORED_SCHEMA" ]; then
  echo "PASS: Schemas match"
else
  echo "FAIL: Schema mismatch"
  diff <(echo "$LIVE_SCHEMA") <(echo "$RESTORED_SCHEMA")
  exit 1
fi
```

---

## Multi-Region Failover

### Active-Passive Architecture

```
                    ┌─────────────────┐
                    │   DNS / LB      │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              ▼                             ▼
    ┌─────────────────┐           ┌─────────────────┐
    │  Primary (active)│           │  DR (standby)   │
    │  us-east-1       │           │  eu-west-1      │
    │                  │           │                  │
    │  App + SQLite    │           │  (idle)          │
    │  Litestream ─────┼──────────▶│  S3 replica      │
    │     │            │           │                  │
    │     ▼            │           │                  │
    │  S3 (primary)    │           │                  │
    └─────────────────┘           └─────────────────┘
```

Litestream replicates from the primary to one or more S3 buckets. The DR region has access to the replica and can restore from it during failover.

### Failover Procedure

When the primary region fails:

```bash
#!/bin/bash
# failover.sh — Execute in DR region
set -euo pipefail

DR_REGION="eu-west-1"
REPLICA_URL="s3://myapp-backups-${DR_REGION}/production"
DB_PATH="/data/app.db"

echo "$(date) Starting failover to $DR_REGION"

# 1. Stop any existing application (if running)
systemctl stop myapp 2>/dev/null || true
systemctl stop litestream 2>/dev/null || true

# 2. Remove any stale database
rm -f "$DB_PATH" "${DB_PATH}-wal" "${DB_PATH}-shm"

# 3. Restore from DR replica
echo "$(date) Restoring from $REPLICA_URL"
litestream restore -o "$DB_PATH" "$REPLICA_URL"

# 4. Verify integrity
INTEGRITY=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;")
if [ "$INTEGRITY" != "ok" ]; then
  echo "$(date) ERROR: Restored database failed integrity check: $INTEGRITY"
  exit 1
fi

# 5. Update Litestream config to replicate from DR
cat > /etc/litestream.yml <<EOF
addr: ":9090"
dbs:
  - path: $DB_PATH
    replicas:
      - type: s3
        bucket: myapp-backups-${DR_REGION}
        path: production-dr-active
        region: $DR_REGION
        sync-interval: 1s
        snapshot-interval: 1h
        retention: 168h
EOF

# 6. Start application and Litestream
systemctl start myapp
systemctl start litestream

# 7. Update DNS to point to DR region
echo "$(date) Failover complete. Update DNS to point to $DR_REGION"
echo "$(date) Run: aws route53 change-resource-record-sets ..."
```

### Failback Procedure

After the primary region recovers:

```bash
#!/bin/bash
# failback.sh — Return to primary region
set -euo pipefail

PRIMARY_REGION="us-east-1"
DR_REPLICA_URL="s3://myapp-backups-eu-west-1/production-dr-active"
DB_PATH="/data/app.db"

echo "$(date) Starting failback to $PRIMARY_REGION"

# 1. Stop DR application (put in maintenance mode first)
# Drain connections, show maintenance page
systemctl stop myapp
sleep 5  # Allow final WAL segments to sync
systemctl stop litestream

# 2. On primary: restore from DR's active replica
rm -f "$DB_PATH" "${DB_PATH}-wal" "${DB_PATH}-shm"
litestream restore -o "$DB_PATH" "$DR_REPLICA_URL"

# 3. Verify
sqlite3 "$DB_PATH" "PRAGMA integrity_check;"

# 4. Restore original Litestream config on primary
# (pointing back to primary S3 bucket)

# 5. Start primary application and Litestream
systemctl start myapp
systemctl start litestream

# 6. Update DNS back to primary
echo "$(date) Failback complete. Update DNS to $PRIMARY_REGION"

# 7. Stop DR instance or put back in standby
```

### DNS-Based Failover

Use Route53 health checks or Cloudflare failover for automatic DNS switching:

```bash
# Route53 health check on primary
aws route53 create-health-check --caller-reference "$(date +%s)" \
  --health-check-config '{
    "IPAddress": "primary-ip",
    "Port": 443,
    "Type": "HTTPS",
    "ResourcePath": "/healthz",
    "FailureThreshold": 3,
    "RequestInterval": 30
  }'
```

**Warning**: Automatic DNS failover for SQLite requires the DR instance to automatically restore and start the application. This adds complexity. For most SQLite deployments, manual failover with a runbook is safer.

---

## RPO and RTO Calculations

### Recovery Point Objective (RPO)

RPO = maximum acceptable data loss. With Litestream:

| sync-interval | RPO (worst case) | Scenario |
|---|---|---|
| 1s | ~1s | Catastrophic failure between syncs |
| 5s | ~5s | Lower API costs, slightly more risk |
| 10s | ~10s | Budget-conscious, moderate risk |
| 1m | ~1m | Not recommended for production |

**Actual RPO** = `sync-interval` + network upload time for the last segment.

For most applications with `sync-interval: 1s`, the effective RPO is 1-3 seconds.

### Recovery Time Objective (RTO)

RTO = time from failure to restored service. Components:

| Step | Duration | Factors |
|---|---|---|
| Detection | 30s–5min | Monitoring alerting latency |
| Decision | 0–30min | Manual vs. automatic failover |
| Restore (snapshot) | 10s–10min | Database size, network speed |
| WAL replay | 1s–5min | Number of WAL segments since snapshot |
| Application startup | 5s–2min | Application initialization time |
| DNS propagation | 0–5min | TTL settings |
| **Total** | **~1min–30min** | **Depends on automation level** |

**Key insight**: Snapshot frequency directly impacts restore time. With `snapshot-interval: 1h`, you replay at most 1 hour of WAL segments. With `snapshot-interval: 24h`, you may replay 24 hours of WAL data.

### Tuning for Lower RPO

```yaml
replicas:
  - type: s3
    bucket: my-bucket
    sync-interval: 500ms    # Sub-second sync
    snapshot-interval: 30m   # Frequent snapshots
```

Trade-offs:
- More S3 API calls (higher cost)
- More network bandwidth usage
- Slightly higher CPU usage on the application host

### Tuning for Lower RTO

```yaml
replicas:
  - type: s3
    bucket: my-bucket
    snapshot-interval: 15m   # Very frequent snapshots = fewer WAL segments to replay
    retention: 168h
```

Additional measures:
- Pre-provision a DR instance with Litestream installed and configured
- Use a warm standby that periodically restores (every hour) to minimize restore time
- Place the S3 bucket in the same region as the DR instance
- Use S3 Transfer Acceleration for faster cross-region restores

---

## Combining with Application-Level Backups

Litestream provides physical-level replication (raw database pages and WAL frames). For defense in depth, combine with logical backups.

### Logical Backups with sqlite3 .dump

```bash
#!/bin/bash
# Daily logical backup
BACKUP_DIR="/backups/logical"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
DB_PATH="/data/app.db"

mkdir -p "$BACKUP_DIR"

# Dump SQL statements (schema + data)
sqlite3 "$DB_PATH" ".dump" | gzip > "${BACKUP_DIR}/dump_${TIMESTAMP}.sql.gz"

# Keep last 30 days
find "$BACKUP_DIR" -name "dump_*.sql.gz" -mtime +30 -delete
```

Benefits:
- Human-readable SQL output
- Can restore to any SQLite version
- Can selectively restore specific tables
- Detects logical corruption that physical backups may preserve

### VACUUM INTO Snapshots

`VACUUM INTO` creates a compacted copy without interfering with Litestream:

```bash
#!/bin/bash
# Weekly compacted snapshot
SNAPSHOT_DIR="/backups/snapshots"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
DB_PATH="/data/app.db"

mkdir -p "$SNAPSHOT_DIR"

sqlite3 "$DB_PATH" "VACUUM INTO '${SNAPSHOT_DIR}/snapshot_${TIMESTAMP}.db';"
gzip "${SNAPSHOT_DIR}/snapshot_${TIMESTAMP}.db"

# Upload to cold storage
aws s3 cp "${SNAPSHOT_DIR}/snapshot_${TIMESTAMP}.db.gz" \
  s3://myapp-cold-storage/snapshots/ \
  --storage-class GLACIER_IR

# Keep last 4 local snapshots
ls -t "${SNAPSHOT_DIR}"/snapshot_*.db.gz | tail -n +5 | xargs rm -f
```

**Important**: Never use `VACUUM` (without `INTO`) on a live Litestream-replicated database. It rewrites the entire database file and breaks WAL continuity, forcing a new generation.

### Application-Level Export

Export critical data in application-specific formats for portability:

```python
import sqlite3
import json
from datetime import datetime

def export_critical_data(db_path, export_dir):
    """Export critical tables as JSON for application-level recovery."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    critical_tables = ["users", "orders", "settings"]
    timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")

    for table in critical_tables:
        rows = conn.execute(f"SELECT * FROM {table}").fetchall()
        data = [dict(row) for row in rows]

        export_path = f"{export_dir}/{table}_{timestamp}.json"
        with open(export_path, "w") as f:
            json.dump(data, f, default=str, indent=2)

    conn.close()
```

### Layered Backup Strategy

A production-grade backup strategy combines multiple layers:

| Layer | Tool | Frequency | Retention | Purpose |
|---|---|---|---|---|
| Continuous replication | Litestream | Every 1s | 7 days | Low RPO disaster recovery |
| Logical dump | sqlite3 .dump | Daily | 30 days | Logical corruption recovery |
| Compacted snapshot | VACUUM INTO | Weekly | 90 days | Long-term archive |
| Application export | Custom script | Daily | 30 days | Application-level recovery |
| Cold storage | S3 Glacier | Monthly | 1 year | Compliance/legal |

---

## Restore to Different Environments

### Production to Staging

Restore a production backup to a staging environment for testing:

```bash
#!/bin/bash
# restore-to-staging.sh
set -euo pipefail

PROD_REPLICA="s3://myapp-prod/production"
STAGING_DB="/data/staging.db"

# Restore production data
litestream restore -o "$STAGING_DB" "$PROD_REPLICA"

# Sanitize sensitive data
sqlite3 "$STAGING_DB" <<'SQL'
-- Anonymize user data
UPDATE users SET
  email = 'user' || id || '@staging.example.com',
  name = 'Test User ' || id,
  password_hash = '$2b$10$invalidhashforstagingonly';

-- Clear sensitive tokens
DELETE FROM api_tokens;
DELETE FROM sessions;
DELETE FROM password_reset_tokens;

-- Clear audit logs (optional, can be large)
DELETE FROM audit_log WHERE created_at < datetime('now', '-7 days');

-- Vacuum to reclaim space
VACUUM;
SQL

echo "Staging database ready at $STAGING_DB"
```

### Production to Local Development

Pull production data for local development:

```bash
#!/bin/bash
# pull-prod-data.sh
set -euo pipefail

# Requires AWS credentials configured locally
PROD_REPLICA="s3://myapp-prod/production"
LOCAL_DB="./dev.db"

echo "Restoring production data..."
litestream restore -o "$LOCAL_DB" "$PROD_REPLICA"

echo "Sanitizing..."
sqlite3 "$LOCAL_DB" <<'SQL'
UPDATE users SET
  email = 'dev' || id || '@localhost',
  password_hash = '$2b$10$devhashforlocalonlyxxxxxxxxxxxxxxxxxxxxxxx';
DELETE FROM api_tokens;
DELETE FROM sessions;
SQL

echo "Local dev database ready: $LOCAL_DB"
echo "Size: $(du -h "$LOCAL_DB" | cut -f1)"
```

### Cross-Cloud Restore

Restore from one cloud provider to another:

```bash
# From AWS S3 to a GCP VM
export LITESTREAM_ACCESS_KEY_ID=AKIA...
export LITESTREAM_SECRET_ACCESS_KEY=secret...

litestream restore -o /data/app.db s3://aws-bucket/app

# Start replicating to GCS instead
cat > /etc/litestream.yml <<EOF
dbs:
  - path: /data/app.db
    replicas:
      - type: gcs
        bucket: gcp-bucket
        path: app
EOF

litestream replicate
```

### Security Considerations

When restoring to non-production environments:

1. **Always sanitize PII**: Email addresses, names, phone numbers, addresses
2. **Invalidate credentials**: Clear password hashes, API tokens, sessions, OAuth tokens
3. **Remove payment data**: Credit card tokens, billing information
4. **Restrict access**: Use separate S3 credentials for non-production restores
5. **Audit trail**: Log who restored what and when
6. **Network isolation**: Don't restore production replicas to internet-accessible staging without sanitization
7. **IAM separation**: Use separate IAM roles for production vs. non-production access to replica buckets

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "StagingReadOnly",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::myapp-prod",
                "arn:aws:s3:::myapp-prod/*"
            ],
            "Condition": {
                "IpAddress": {
                    "aws:SourceIp": "10.0.0.0/8"
                }
            }
        }
    ]
}
```
