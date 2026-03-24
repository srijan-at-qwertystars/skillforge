---
name: litestream-replication
description: |
  Guide for configuring and deploying Litestream for SQLite streaming replication and disaster recovery. Covers WAL-based continuous replication to S3, GCS, Azure Blob, SFTP, and local paths. Includes litestream.yml configuration, restore/recovery procedures, Docker sidecar and Kubernetes patterns, retention policies, snapshot intervals, monitoring, health checks, and production hardening. Use when setting up SQLite backup streaming, WAL replication, point-in-time recovery, or Litestream integration with any SQLite application.
triggers:
  positive:
    - Litestream
    - SQLite replication
    - SQLite backup streaming
    - WAL replication
    - SQLite disaster recovery
    - litestream.yml
    - SQLite point-in-time recovery
    - SQLite continuous backup
  negative:
    - PostgreSQL replication
    - MySQL replication
    - rqlite cluster setup
    - LiteFS distributed SQLite
    - general SQLite without replication
    - general database backups without SQLite
    - MongoDB replication
---

# Litestream SQLite Replication

## Architecture

Litestream runs as a separate process alongside the application. It monitors the SQLite WAL file, copies frames into a shadow WAL, and streams segments to one or more replica destinations. It does NOT modify application code or the database schema.

Key concepts:
- **Shadow WAL**: Litestream holds a read transaction to prevent automatic checkpointing, reads WAL frames, writes them to sequentially-named shadow WAL segments
- **Snapshots**: Periodic full copies of the database file (default: every 24h). Configurable via `snapshot-interval`
- **Generations**: A snapshot plus its contiguous WAL segments. A new generation starts if WAL continuity breaks
- **Async replication**: Changes stream every `sync-interval` (default: 1s). Data loss window equals the sync interval on total failure

## Prerequisites

Set WAL mode and recommended PRAGMAs in the application before Litestream starts:

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
PRAGMA synchronous = NORMAL;
PRAGMA cache_size = -64000;    -- 64MB
PRAGMA foreign_keys = ON;
```

**Critical**: Never call `PRAGMA journal_mode = DELETE` or `PRAGMA journal_mode = TRUNCATE` while Litestream is running. Never run `VACUUM` on a live-replicated database — use `VACUUM INTO` instead.

## Configuration Reference

### Minimal litestream.yml

```yaml
dbs:
  - path: /data/app.db
    replicas:
      - url: s3://my-bucket/app
```

### Full Production Configuration

```yaml
addr: ":9090"  # Prometheus metrics endpoint

logging:
  level: info
  type: text

dbs:
  - path: /data/app.db
    replicas:
      - type: s3
        bucket: my-bucket
        path: app
        region: us-east-1
        access-key-id: ${LITESTREAM_ACCESS_KEY_ID}
        secret-access-key: ${LITESTREAM_SECRET_ACCESS_KEY}
        sync-interval: 1s
        snapshot-interval: 1h
        retention: 168h              # 7 days
        retention-check-interval: 1h
        validation-interval: 12h     # periodic restore validation
```

### Replica Destination Types

**S3 (and S3-compatible: MinIO, Backblaze B2, DigitalOcean Spaces, Cloudflare R2)**:
```yaml
- type: s3
  bucket: my-bucket
  path: backups/app
  region: us-east-1
  endpoint: https://s3.amazonaws.com  # override for S3-compatible
  access-key-id: ${AWS_ACCESS_KEY_ID}
  secret-access-key: ${AWS_SECRET_ACCESS_KEY}
  force-path-style: true              # required for MinIO/some S3-compatible
```
URL form: `s3://bucket/path`

**Google Cloud Storage**:
```yaml
- type: gcs
  bucket: my-gcs-bucket
  path: backups/app
```
Auth via `GOOGLE_APPLICATION_CREDENTIALS` env var pointing to service account JSON.
URL form: `gs://bucket/path`

**Azure Blob Storage**:
```yaml
- type: abs
  account-name: myaccount
  account-key: ${LITESTREAM_AZURE_ACCOUNT_KEY}
  bucket: mycontainer
  path: backups/app
```
URL form: `abs://account@container/path`

**SFTP**:
```yaml
- type: sftp
  host: sftp.example.com:22
  user: backupuser
  key-path: /root/.ssh/id_ed25519
  path: /backups/app
```
URL form: `sftp://user@host/path`

**Local file path**:
```yaml
- type: file
  path: /mnt/nfs/backups/app
```

### Global Defaults

Avoid repeating credentials across replicas:

```yaml
access-key-id: ${LITESTREAM_ACCESS_KEY_ID}
secret-access-key: ${LITESTREAM_SECRET_ACCESS_KEY}
region: us-east-1

dbs:
  - path: /data/app.db
    replicas:
      - url: s3://primary-bucket/app
      - url: s3://dr-bucket/app
```

### Multiple Replicas

Replicate to multiple destinations for redundancy:

```yaml
dbs:
  - path: /data/app.db
    replicas:
      - url: s3://us-east-bucket/app
        name: primary
      - url: s3://eu-west-bucket/app
        name: dr
      - type: file
        path: /mnt/backup/app
        name: local
```

### Environment Variables

| Variable | Purpose |
|---|---|
| `LITESTREAM_ACCESS_KEY_ID` | S3 access key |
| `LITESTREAM_SECRET_ACCESS_KEY` | S3 secret key |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | AWS SDK fallback |
| `GOOGLE_APPLICATION_CREDENTIALS` | GCS service account JSON path |
| `LITESTREAM_AZURE_ACCOUNT_KEY` | Azure Blob account key |

Use `${VAR}` syntax in YAML for any env var expansion.

## CLI Commands

```bash
# Start replication (foreground, reads litestream.yml)
litestream replicate

# Start with explicit config
litestream replicate -config /etc/litestream.yml

# Restore database from replica
litestream restore -o /data/app.db s3://my-bucket/app

# Restore only if DB does not exist (idempotent boot)
litestream restore -if-db-not-exists -if-replica-exists /data/app.db

# Restore to a specific point in time
litestream restore -timestamp "2024-01-15T10:30:00Z" -o /data/app.db s3://my-bucket/app

# List available snapshots and generations
litestream snapshots s3://my-bucket/app
litestream generations s3://my-bucket/app

# List all databases being replicated
litestream databases

# Validate replica integrity
litestream validate s3://my-bucket/app
```

## Docker Deployment

### Dockerfile (multi-stage with Litestream)

```dockerfile
FROM litestream/litestream:latest AS litestream

FROM python:3.12-slim
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream
COPY litestream.yml /etc/litestream.yml
COPY run.sh /run.sh

ENTRYPOINT ["/run.sh"]
```

### Entrypoint Script (run.sh)

```bash
#!/bin/bash
set -e

# Restore database on first boot
litestream restore -if-db-not-exists -if-replica-exists /data/app.db

# Start Litestream replication in background, exec app as child
exec litestream replicate -exec "python app.py"
```

The `-exec` flag runs the application as a child process. Litestream replicates in the background and forwards signals to the child.

### Docker Compose Sidecar

```yaml
services:
  app:
    image: myapp:latest
    volumes:
      - data:/data
    depends_on:
      litestream-restore:
        condition: service_completed_successfully

  litestream-restore:
    image: litestream/litestream:latest
    command: restore -if-db-not-exists -if-replica-exists /data/app.db
    volumes:
      - data:/data
      - ./litestream.yml:/etc/litestream.yml
    env_file: .env

  litestream:
    image: litestream/litestream:latest
    command: replicate
    volumes:
      - data:/data
      - ./litestream.yml:/etc/litestream.yml
    env_file: .env
    depends_on:
      litestream-restore:
        condition: service_completed_successfully

volumes:
  data:
```

## Kubernetes Deployment

### StatefulSet with Init Container + Sidecar

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: myapp
spec:
  replicas: 1  # MUST be 1 — SQLite is single-writer
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: myapp-data
        - name: litestream-config
          configMap:
            name: litestream-config
      initContainers:
        - name: litestream-restore
          image: litestream/litestream:latest
          args: ["restore", "-if-db-not-exists", "-if-replica-exists", "/data/app.db"]
          envFrom:
            - secretRef:
                name: litestream-credentials
          volumeMounts:
            - name: data
              mountPath: /data
            - name: litestream-config
              mountPath: /etc/litestream.yml
              subPath: litestream.yml
      containers:
        - name: app
          image: myapp:latest
          volumeMounts:
            - name: data
              mountPath: /data
        - name: litestream
          image: litestream/litestream:latest
          args: ["replicate"]
          envFrom:
            - secretRef:
                name: litestream-credentials
          volumeMounts:
            - name: data
              mountPath: /data
            - name: litestream-config
              mountPath: /etc/litestream.yml
              subPath: litestream.yml
  volumeClaimTemplates:
    - metadata:
        name: myapp-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
```

### ConfigMap and Secret

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: litestream-config
data:
  litestream.yml: |
    addr: ":9090"
    dbs:
      - path: /data/app.db
        replicas:
          - url: s3://my-bucket/app
            sync-interval: 1s
            snapshot-interval: 1h
            retention: 168h
---
apiVersion: v1
kind: Secret
metadata:
  name: litestream-credentials
stringData:
  LITESTREAM_ACCESS_KEY_ID: "AKIA..."
  LITESTREAM_SECRET_ACCESS_KEY: "secret..."
```

## Monitoring and Health Checks

### Prometheus Metrics

Enable with `addr: ":9090"` in config. Scrape `http://localhost:9090/metrics`.

Key metrics to monitor:
- Replica sync errors and lag
- Snapshot creation timestamps
- WAL segment upload failures

### Validation

Set `validation-interval` per replica to periodically restore and verify backup integrity:
```yaml
validation-interval: 12h
```

### Application-Level Health Check

```bash
#!/bin/bash
# Check Litestream process is running
pgrep -x litestream > /dev/null || exit 1

# Check DB is accessible and in WAL mode
sqlite3 /data/app.db "PRAGMA journal_mode;" | grep -q wal || exit 1
```

## Retention and Snapshot Tuning

| Setting | Default | Recommendation |
|---|---|---|
| `sync-interval` | 1s | 1s for low RPO; 10s for cost savings |
| `snapshot-interval` | 24h | 1h for faster restores; 24h for small DBs |
| `retention` | 24h | 168h (7d) for production; 720h (30d) for compliance |
| `retention-check-interval` | 1h | Match or exceed snapshot-interval |
| `validation-interval` | unset | 12h–24h in production |

Lower `sync-interval` = lower RPO (recovery point objective) but more API calls. Lower `snapshot-interval` = faster restores but more storage.

## Production Checklist

1. **WAL mode enabled** — set `PRAGMA journal_mode = WAL` at application startup
2. **busy_timeout set** — `PRAGMA busy_timeout = 5000` minimum to handle lock contention
3. **Restore-on-boot** — use `-if-db-not-exists -if-replica-exists` in init/entrypoint
4. **Replica validation** — set `validation-interval: 12h` for proactive corruption detection
5. **Metrics enabled** — set `addr: ":9090"` and wire into monitoring stack
6. **Retention configured** — set explicit `retention` and `snapshot-interval`
7. **Multiple replicas** — replicate to ≥2 destinations (primary + DR region)
8. **Credentials via env vars** — never hardcode secrets in litestream.yml
9. **Replica 1** — StatefulSet/Deployment replicas MUST be 1 (SQLite is single-writer)
10. **Test restores regularly** — automate periodic restore-and-verify in CI or cron
11. **No VACUUM** — use `VACUUM INTO` for compaction on live databases
12. **Signal forwarding** — use `litestream replicate -exec` or proper init system

## Limitations

- **Single-writer only** — SQLite allows one writer at a time; Litestream does not change this
- **No live read replicas** — replicas are backup destinations, not queryable secondaries
- **Async replication** — potential data loss of up to `sync-interval` on catastrophic failure
- **No automatic failover** — restore is a manual or scripted operation
- **Database size** — practical limit ~100GB; larger DBs have slow snapshot uploads and restores
- **No schema-aware replication** — replicates raw pages, not logical changes

## When to Use Alternatives

| Need | Use Instead |
|---|---|
| Live read replicas at the edge | LiteFS (FUSE-based, single-writer, many readers) |
| Strong consistency + HA cluster | rqlite (Raft consensus, HTTP API) |
| Embedded distributed SQLite (C) | dqlite (Raft, by Canonical) |
| Multi-writer / CRDT | cr-sqlite or application-level partitioning |
| Full RDBMS replication | PostgreSQL, MySQL with native replication |

Litestream is ideal for: single-server apps, edge deployments, solo/small-team projects, MVP/startup backends, and any SQLite workload needing disaster recovery without architectural complexity.

## References

In-depth guides for specific topics:

| Document | Path | Topics |
|---|---|---|
| Deployment Patterns | `references/deployment-patterns.md` | Docker sidecar, Kubernetes init+sidecar, systemd integration, Fly.io, multi-replica destinations, cross-region replication, framework integration (Go, Rails, Django, Node.js, Phoenix) |
| Troubleshooting | `references/troubleshooting.md` | WAL mode issues, database locked errors, restore failures, S3/IAM permissions, slow snapshots, retention cleanup, silent crashes, monitoring gaps, checkpoint conflicts, diagnostic commands |
| Disaster Recovery | `references/disaster-recovery.md` | Point-in-time recovery, automated restore testing, backup verification, multi-region failover/failback, RPO/RTO calculations, layered backup strategies, cross-environment restores |

## Scripts

Operational scripts in `scripts/`:

| Script | Purpose | Usage |
|---|---|---|
| `setup-litestream.sh` | Install Litestream, configure S3 replication, start and verify | `S3_BUCKET=my-bucket ./scripts/setup-litestream.sh` |
| `restore-database.sh` | Stop app → restore (latest or point-in-time) → verify → restart | `REPLICA_URL=s3://bucket/app ./scripts/restore-database.sh` |
| `verify-backup.sh` | Restore to temp dir, integrity check, generation analysis, optional live comparison | `REPLICA_URL=s3://bucket/app ./scripts/verify-backup.sh` |

## Assets

Ready-to-use configuration files in `assets/`:

| File | Description |
|---|---|
| `litestream.yml` | Production config: S3 replica, 1s sync, 1h snapshots, 7d retention, validation |
| `Dockerfile` | Multi-stage image with Litestream sidecar — restore on boot, `-exec` for signal forwarding |
| `docker-compose.yml` | Full dev stack: app + Litestream + MinIO (local S3), init restore container |
| `systemd-litestream.service` | systemd unit with security hardening, journal logging, auto-restart |
| `k8s-sidecar.yaml` | Complete K8s manifests: StatefulSet, ConfigMap, Secret, Service, PDB, probes |
