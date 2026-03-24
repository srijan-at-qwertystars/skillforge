# Litestream Troubleshooting Guide

## Table of Contents

- [WAL Mode Not Enabled](#wal-mode-not-enabled)
- [Database Locked Errors](#database-locked-errors)
- [Restore Failures](#restore-failures)
  - [Corrupt Snapshots](#corrupt-snapshots)
  - [Missing WAL Segments](#missing-wal-segments)
  - [Restore Hangs or Times Out](#restore-hangs-or-times-out)
- [S3 Permissions and IAM Policies](#s3-permissions-and-iam-policies)
  - [Minimal IAM Policy](#minimal-iam-policy)
  - [Common Permission Errors](#common-permission-errors)
  - [S3-Compatible Storage Quirks](#s3-compatible-storage-quirks)
- [Slow Initial Snapshot](#slow-initial-snapshot)
- [Retention Cleanup Not Working](#retention-cleanup-not-working)
- [Litestream Process Dying Silently](#litestream-process-dying-silently)
- [Monitoring Gaps](#monitoring-gaps)
- [Checkpoint Conflicts](#checkpoint-conflicts)
- [WAL File Growing Unbounded](#wal-file-growing-unbounded)
- [Replication Lag](#replication-lag)
- [Container and Orchestration Issues](#container-and-orchestration-issues)
- [Diagnostic Commands](#diagnostic-commands)

---

## WAL Mode Not Enabled

**Symptom**: Litestream starts but reports `no wal file found` or `journal_mode is not wal`.

**Root Cause**: The application database is using DELETE or TRUNCATE journal mode instead of WAL.

**Diagnosis**:
```bash
sqlite3 /data/app.db "PRAGMA journal_mode;"
# Expected: wal
# Problem:  delete or truncate
```

**Fix**:
1. Set WAL mode before starting Litestream:
```bash
sqlite3 /data/app.db "PRAGMA journal_mode=WAL;"
```

2. Better: set it in the application code at startup so it persists:
```sql
PRAGMA journal_mode = WAL;
```

3. Verify the WAL file exists:
```bash
ls -la /data/app.db-wal
```

**Gotchas**:
- WAL mode is persistent per-database — you only need to set it once, but it's good practice to set it on every open
- Some ORMs reset journal mode on connection; check your ORM configuration
- WAL mode requires that `-shm` and `-wal` files be on the same filesystem as the database
- WAL mode cannot be set on an in-memory database

---

## Database Locked Errors

**Symptom**: Application reports `SQLITE_BUSY` or `database is locked` errors while Litestream is running.

**Root Cause**: Litestream holds a long-running read transaction to prevent automatic checkpointing. This does not block writes, but other factors can cause lock contention.

**Diagnosis**:
```bash
# Check if busy_timeout is set
sqlite3 /data/app.db "PRAGMA busy_timeout;"
# Should return a value > 0 (e.g., 5000)

# Check for stuck WAL checkpoints
sqlite3 /data/app.db "PRAGMA wal_checkpoint(PASSIVE);"
```

**Fix**:
1. Set `busy_timeout` in the application:
```sql
PRAGMA busy_timeout = 5000;  -- 5 seconds, minimum recommended
```

2. Ensure only one process writes to the database. Multiple writers from different containers or processes sharing the same file will deadlock.

3. Check for long-running transactions in the application. Use shorter transaction scopes:
```python
# Bad: long-running transaction
with db.begin():
    for item in large_list:
        db.execute("INSERT ...", item)

# Good: batch in smaller chunks
for chunk in chunked(large_list, 1000):
    with db.begin():
        db.executemany("INSERT ...", chunk)
```

4. If using `PRAGMA synchronous = NORMAL` (recommended), writes will be slightly faster and reduce lock contention.

**Important**: Litestream's read transaction does NOT cause `SQLITE_BUSY`. If you see this error, the problem is in your application's concurrency model (multiple writers, missing busy_timeout, or long transactions).

---

## Restore Failures

### Corrupt Snapshots

**Symptom**: `litestream restore` fails with `checksum mismatch`, `invalid page`, or `database disk image is malformed`.

**Diagnosis**:
```bash
# List available generations
litestream generations s3://my-bucket/app

# List snapshots in a specific generation
litestream snapshots s3://my-bucket/app

# Try restoring from a different generation
litestream restore -generation <gen-id> -o /tmp/test.db s3://my-bucket/app
```

**Fix**:
1. Try restoring from an older snapshot:
```bash
# List snapshots with timestamps
litestream snapshots s3://my-bucket/app

# Restore to a specific timestamp before the corruption
litestream restore -timestamp "2024-01-14T00:00:00Z" -o /tmp/test.db s3://my-bucket/app
```

2. If all snapshots in the latest generation are corrupt, try a previous generation:
```bash
litestream generations s3://my-bucket/app
# Note an older generation ID
litestream restore -generation <older-gen> -o /tmp/test.db s3://my-bucket/app
```

3. Validate the restored database:
```bash
sqlite3 /tmp/test.db "PRAGMA integrity_check;"
```

4. Enable `validation-interval` to catch corruption early:
```yaml
replicas:
  - url: s3://my-bucket/app
    validation-interval: 12h
```

### Missing WAL Segments

**Symptom**: Restore fails with `no matching wal segments found` or reports an incomplete generation.

**Root Cause**: WAL segments were not uploaded (network issue, process crash, or retention cleaned them up).

**Diagnosis**:
```bash
# Check generation continuity
litestream generations s3://my-bucket/app

# Look for gaps in WAL segment indices
litestream wal s3://my-bucket/app
```

**Fix**:
1. Restore to the latest complete point before the gap:
```bash
litestream restore -timestamp "2024-01-14T10:00:00Z" -o /data/app.db s3://my-bucket/app
```

2. If the WAL gap is recent, the local database may still have the missing WAL data. Check if `/data/app.db` exists and is intact:
```bash
sqlite3 /data/app.db "PRAGMA integrity_check;"
```

3. Prevent future gaps by reducing `sync-interval` and monitoring replication lag.

### Restore Hangs or Times Out

**Symptom**: `litestream restore` appears to hang indefinitely or takes an unexpectedly long time.

**Root Cause**: Large database, slow network, or many WAL segments to replay.

**Fix**:
1. Use a more recent snapshot with fewer WAL segments to replay:
```bash
# Reduce snapshot-interval to create more frequent snapshots
snapshot-interval: 1h  # Instead of default 24h
```

2. For large databases (>1GB), increase the snapshot frequency to reduce restore time.

3. Check network connectivity to the replica:
```bash
aws s3 ls s3://my-bucket/app/ --recursive | head -20
```

4. Add verbose logging for restore diagnostics:
```bash
litestream restore -v -o /data/app.db s3://my-bucket/app
```

---

## S3 Permissions and IAM Policies

### Minimal IAM Policy

Litestream needs the following S3 permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "LitestreamReplication",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": [
                "arn:aws:s3:::my-bucket",
                "arn:aws:s3:::my-bucket/*"
            ]
        }
    ]
}
```

**Important**: Both the bucket ARN (`arn:aws:s3:::my-bucket`) and the object ARN (`arn:aws:s3:::my-bucket/*`) must be included. `ListBucket` applies to the bucket, while `GetObject`/`PutObject`/`DeleteObject` apply to objects.

### Common Permission Errors

**`AccessDenied` on PutObject**:
- Check that the IAM user/role has `s3:PutObject` on the correct bucket path
- Verify the bucket policy does not deny the principal
- Check for S3 Block Public Access settings (usually not relevant for IAM access)

**`NoSuchBucket`**:
- Verify bucket name and region match
- Check for typos in the bucket name
- Ensure the bucket exists in the configured region

**`SignatureDoesNotMatch`**:
- Credentials may be incorrect or have trailing whitespace
- Clock skew between the host and AWS can cause this — sync NTP
- If using S3-compatible storage, check that the endpoint URL is correct

**`403 Forbidden` with AssumeRole**:
- The trust policy on the role must allow the calling identity to assume it
- Check that `sts:AssumeRole` is in the calling identity's permissions
- For EKS, verify the OIDC provider and service account annotation

### S3-Compatible Storage Quirks

**MinIO**:
- Set `endpoint` to your MinIO URL
- Set `force-path-style: true`
- Use `http://` for local development (not `https://`)

```yaml
- type: s3
  bucket: litestream
  endpoint: http://minio:9000
  force-path-style: true
  access-key-id: minioadmin
  secret-access-key: minioadmin
```

**Backblaze B2**:
- Use S3-compatible endpoint: `https://s3.us-west-002.backblazeb2.com`
- Set `force-path-style: true`
- B2 application keys need read/write access to the specific bucket

**Cloudflare R2**:
- Endpoint: `https://<account-id>.r2.cloudflarestorage.com`
- Set `force-path-style: true`
- R2 does not charge for egress, making it cost-effective for frequent restores

**DigitalOcean Spaces**:
- Endpoint: `https://<region>.digitaloceanspaces.com`
- Set `force-path-style: true`

---

## Slow Initial Snapshot

**Symptom**: The first replication takes a very long time, especially for databases > 500MB.

**Root Cause**: The initial snapshot uploads the entire database file to the replica destination.

**Diagnosis**:
```bash
# Check database size
ls -lh /data/app.db

# Check current upload progress (if Litestream is running)
# Look at Prometheus metrics
curl -s http://localhost:9090/metrics | grep litestream
```

**Fix**:
1. For very large databases, consider uploading the initial snapshot manually:
```bash
# Create initial snapshot manually
aws s3 cp /data/app.db s3://my-bucket/app/initial.db

# Then start Litestream — it will detect the existing data
litestream replicate
```

2. Compress the database before initial upload if bandwidth is limited:
```bash
sqlite3 /data/app.db "VACUUM INTO '/tmp/app-compact.db';"
# Use the compacted copy as the starting point
```

3. Use a faster network path for the initial snapshot (e.g., run the initial sync from an EC2 instance in the same region as the S3 bucket).

4. Consider setting a shorter `snapshot-interval` after the initial sync to ensure subsequent snapshots are incremental.

---

## Retention Cleanup Not Working

**Symptom**: Old snapshots and WAL segments accumulate in S3 and are not cleaned up despite `retention` being set.

**Root Cause**: Retention cleanup runs on the `retention-check-interval`, which defaults to 1 hour. Several conditions can prevent cleanup.

**Diagnosis**:
```bash
# List current generations and their ages
litestream generations s3://my-bucket/app

# Check S3 bucket size
aws s3 ls s3://my-bucket/app/ --recursive --summarize
```

**Common Causes and Fixes**:

1. **`retention-check-interval` too long**: If cleanup hasn't run yet, wait or reduce the interval:
```yaml
retention: 168h
retention-check-interval: 1h
```

2. **Active generation cannot be deleted**: Litestream will not delete the current generation, even if it exceeds the retention window. Only completed generations are cleaned up.

3. **Litestream restarts creating new generations**: Every time Litestream starts, it may create a new generation. Frequent restarts = many generations that each need to age out independently.

4. **Missing delete permissions**: Litestream needs `s3:DeleteObject` permission. Check the IAM policy.

5. **S3 lifecycle rules conflicting**: If you have S3 lifecycle rules on the bucket, they may interfere with Litestream's retention logic. Let Litestream manage retention, or use S3 lifecycle as a safety net with a longer retention.

---

## Litestream Process Dying Silently

**Symptom**: Litestream process exits without obvious errors, or replication stops without notification.

**Diagnosis**:
```bash
# Check if process is running
pgrep -a litestream

# Check exit code from systemd
systemctl status litestream
journalctl -u litestream -n 50

# Check Docker container status
docker logs myapp-litestream-1 --tail 50

# Check OOM kills
dmesg | grep -i "oom\|killed"
```

**Common Causes and Fixes**:

1. **OOM killed**: Litestream's memory usage grows with database size. On memory-constrained containers, it may be OOM-killed:
```yaml
# Docker Compose: set memory limit with some headroom
deploy:
  resources:
    limits:
      memory: 256M
```

2. **Signal handling with Docker**: If running Litestream as PID 1 without `-exec`, it may not handle signals properly:
```dockerfile
# Bad: Litestream can't forward signals
CMD ["litestream", "replicate"]

# Good: Use -exec for signal forwarding
CMD ["litestream", "replicate", "-exec", "myapp"]

# Alternative: Use tini as init
ENTRYPOINT ["tini", "--"]
CMD ["litestream", "replicate"]
```

3. **Filesystem permissions**: If the data directory permissions change (e.g., after a volume remount), Litestream may fail to read the WAL:
```bash
# Check permissions
ls -la /data/app.db*
# Fix ownership
chown litestream:litestream /data/app.db*
```

4. **Network timeouts**: Extended network outages cause Litestream to retry and eventually exit. Set `restart: always` in Docker or `Restart=always` in systemd.

5. **Disk full**: If the data volume fills up, Litestream cannot write the shadow WAL:
```bash
df -h /data
```

---

## Monitoring Gaps

**Symptom**: Replication failures go unnoticed until a restore is needed.

**Root Cause**: No alerting on Litestream metrics or health checks.

**Fix**: Implement a monitoring stack:

1. **Enable Prometheus metrics**:
```yaml
addr: ":9090"
```

2. **Key metrics to alert on**:
```
# Replica lag > 1 minute
litestream_replica_last_sync_seconds_ago > 60

# No successful sync in 5 minutes
time() - litestream_replica_last_sync_timestamp > 300

# Snapshot age > 2x snapshot interval
time() - litestream_replica_last_snapshot_timestamp > 2 * snapshot_interval

# Process not running (external check)
up{job="litestream"} == 0
```

3. **Cron-based health check** (for environments without Prometheus):
```bash
#!/bin/bash
# Check Litestream is running
if ! pgrep -x litestream > /dev/null; then
    echo "ALERT: Litestream not running" | mail -s "Litestream down" ops@example.com
    exit 1
fi

# Check database is in WAL mode
MODE=$(sqlite3 /data/app.db "PRAGMA journal_mode;" 2>/dev/null)
if [ "$MODE" != "wal" ]; then
    echo "ALERT: Database not in WAL mode: $MODE" | mail -s "WAL mode lost" ops@example.com
    exit 1
fi

# Check WAL file exists and is being written
WAL_AGE=$(( $(date +%s) - $(stat -c %Y /data/app.db-wal 2>/dev/null || echo 0) ))
if [ "$WAL_AGE" -gt 300 ]; then
    echo "ALERT: WAL file stale (${WAL_AGE}s old)" | mail -s "WAL stale" ops@example.com
    exit 1
fi
```

4. **Periodic restore verification**: Schedule a cron job or CI pipeline to restore and validate:
```bash
# Weekly restore test
0 3 * * 0 /usr/local/bin/verify-backup.sh 2>&1 | logger -t backup-verify
```

---

## Checkpoint Conflicts

**Symptom**: WAL file grows very large; `PRAGMA wal_checkpoint` returns errors or doesn't reduce WAL size.

**Root Cause**: Litestream holds a read transaction that prevents automatic WAL checkpointing. This is by design — Litestream needs the WAL frames to replicate.

**Clarification**: Litestream performs its own checkpointing. It reads WAL frames into the shadow WAL, then allows the SQLite automatic checkpoint mechanism to reclaim the WAL file. If the WAL grows large, it typically means:

1. Very high write throughput overwhelming the sync interval
2. A long-running read transaction in the application (not Litestream) preventing checkpointing
3. Multiple database connections with unfinished transactions

**Diagnosis**:
```bash
# Check WAL file size
ls -lh /data/app.db-wal

# Attempt passive checkpoint (non-blocking)
sqlite3 /data/app.db "PRAGMA wal_checkpoint(PASSIVE);"
# Returns: busy, log_frames, checkpointed_frames

# Check for open transactions
sqlite3 /data/app.db "SELECT * FROM pragma_database_list;"
```

**Fix**:
1. Ensure application connections are properly closed and transactions are short-lived
2. Do NOT run `PRAGMA wal_checkpoint(TRUNCATE)` while Litestream is running — this can break replication
3. If the WAL is consistently large (>100MB), consider reducing `sync-interval` to 500ms or less
4. Restart the application if a connection is leaking (holding an open transaction)

---

## WAL File Growing Unbounded

**Symptom**: The `-wal` file grows continuously to gigabytes, consuming disk space.

**Root Cause**: Checkpointing is blocked by an open read transaction or connection leak.

**Diagnosis**:
```bash
# Monitor WAL size over time
watch -n 5 'ls -lh /data/app.db-wal'

# Check connection counts (application-specific)
# For Python/SQLAlchemy:
# engine.pool.status()
```

**Fix**:
1. Find and fix the leaked connection or long-running transaction in the application
2. As a temporary measure, restart the application to release all connections
3. Set `PRAGMA wal_autocheckpoint = 1000` (default) — do not set it to 0
4. Monitor the WAL size with an alert:
```bash
WAL_SIZE=$(stat -c %s /data/app.db-wal 2>/dev/null || echo 0)
if [ "$WAL_SIZE" -gt 104857600 ]; then  # 100MB
    echo "WAL file is $(( WAL_SIZE / 1048576 ))MB"
fi
```

---

## Replication Lag

**Symptom**: The replica is significantly behind the live database.

**Diagnosis**:
```bash
# Check Prometheus metrics
curl -s http://localhost:9090/metrics | grep sync

# Compare local generation with remote
litestream generations /data/app.db
litestream generations s3://my-bucket/app
```

**Common Causes**:
1. **High write throughput**: WAL segments are generated faster than they can be uploaded. Reduce `sync-interval` or use a faster network/storage destination.
2. **Network throttling**: Check if the cloud provider is throttling S3 API calls. Use exponential backoff.
3. **Large sync-interval**: A `sync-interval` of 10s+ means up to 10s of data loss. Reduce to 1s for lower RPO.
4. **CPU contention**: Litestream shares CPU with the application. On small containers, this can delay syncs.

---

## Container and Orchestration Issues

**Shared volume permissions in Docker**:
```bash
# Both app and litestream containers must access the same files
# Use matching UID/GID or run as root
docker run -v data:/data --user 1000:1000 myapp
docker run -v data:/data --user 1000:1000 litestream/litestream replicate
```

**Kubernetes pod termination**:
- Set `terminationGracePeriodSeconds: 30` to give Litestream time to flush pending WAL segments
- Litestream handles SIGTERM gracefully — it flushes pending data before exiting
- PreStop hooks can add additional safety:
```yaml
lifecycle:
  preStop:
    exec:
      command: ["sleep", "5"]
```

**Init container restore timing out**:
- Large databases take time to restore; increase the init container's timeout
- Set a startup probe instead of a liveness probe for the init period

---

## Diagnostic Commands

Quick reference for debugging Litestream issues:

```bash
# Check Litestream version
litestream version

# Verify configuration
litestream validate /etc/litestream.yml

# List replicated databases
litestream databases

# List generations (shows continuity)
litestream generations s3://my-bucket/app

# List snapshots (shows available restore points)
litestream snapshots s3://my-bucket/app

# Validate replica integrity
litestream validate s3://my-bucket/app

# Check database integrity
sqlite3 /data/app.db "PRAGMA integrity_check;"

# Check journal mode
sqlite3 /data/app.db "PRAGMA journal_mode;"

# Check WAL file status
ls -lah /data/app.db*

# Check Litestream process
pgrep -a litestream

# View Litestream logs (systemd)
journalctl -u litestream -f

# Check Prometheus metrics
curl -s http://localhost:9090/metrics

# Check S3 connectivity
aws s3 ls s3://my-bucket/app/ --recursive | tail -5

# Disk usage
df -h /data
du -sh /data/app.db*
```
