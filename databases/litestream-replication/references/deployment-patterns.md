# Litestream Deployment Patterns

## Table of Contents

- [Docker Sidecar Pattern](#docker-sidecar-pattern)
  - [Init Container for Restore](#init-container-for-restore)
  - [Sidecar for Continuous Replication](#sidecar-for-continuous-replication)
  - [Single-Container with -exec](#single-container-with--exec)
- [Kubernetes Deployments](#kubernetes-deployments)
  - [StatefulSet with Init + Sidecar](#statefulset-with-init--sidecar)
  - [ConfigMap and Secret Management](#configmap-and-secret-management)
  - [Liveness and Readiness Probes](#liveness-and-readiness-probes)
  - [Persistent Volume Considerations](#persistent-volume-considerations)
  - [Horizontal Pod Autoscaling Constraints](#horizontal-pod-autoscaling-constraints)
- [systemd Service Integration](#systemd-service-integration)
  - [Standalone Service](#standalone-service)
  - [Dependency Ordering with Application](#dependency-ordering-with-application)
  - [Logging and Journal Integration](#logging-and-journal-integration)
- [Fly.io Deployment](#flyio-deployment)
  - [fly.toml Configuration](#flytoml-configuration)
  - [Persistent Volumes on Fly](#persistent-volumes-on-fly)
  - [Entrypoint Script for Fly](#entrypoint-script-for-fly)
  - [Multi-Region on Fly](#multi-region-on-fly)
- [Multi-Replica Destinations](#multi-replica-destinations)
  - [Primary + DR Bucket](#primary--dr-bucket)
  - [Cross-Provider Redundancy](#cross-provider-redundancy)
  - [Local + Remote Hybrid](#local--remote-hybrid)
- [Cross-Region Replication](#cross-region-replication)
  - [Active-Passive with S3 Cross-Region](#active-passive-with-s3-cross-region)
  - [Multi-Region Replica Fan-Out](#multi-region-replica-fan-out)
  - [Latency and Cost Considerations](#latency-and-cost-considerations)
- [Application Framework Integration](#application-framework-integration)
  - [Go Applications](#go-applications)
  - [Rails with Litestream](#rails-with-litestream)
  - [Django with Litestream](#django-with-litestream)
  - [Node.js / Express](#nodejs--express)
  - [Phoenix / Elixir](#phoenix--elixir)

---

## Docker Sidecar Pattern

The Docker sidecar pattern runs Litestream as a separate container or process alongside the application. There are three primary approaches: init container for restore, sidecar for continuous replication, and single-container with `-exec`.

### Init Container for Restore

An init container runs `litestream restore` before the application starts. This ensures the database is present and populated from the replica before the app attempts to read it.

```dockerfile
# Dockerfile.restore
FROM litestream/litestream:latest
ENTRYPOINT ["litestream", "restore", "-if-db-not-exists", "-if-replica-exists"]
CMD ["/data/app.db"]
```

In Docker Compose, model this as a service with `service_completed_successfully`:

```yaml
services:
  restore:
    image: litestream/litestream:latest
    command: restore -if-db-not-exists -if-replica-exists /data/app.db
    volumes:
      - data:/data
      - ./litestream.yml:/etc/litestream.yml
    env_file: .env

  app:
    image: myapp:latest
    volumes:
      - data:/data
    depends_on:
      restore:
        condition: service_completed_successfully
```

Key points:
- `-if-db-not-exists` makes restore idempotent — if the database already exists on the volume, restore is skipped
- `-if-replica-exists` prevents failure when deploying for the first time (no replica yet)
- The restore container exits after completion; it does not stay running

### Sidecar for Continuous Replication

A sidecar container runs `litestream replicate` continuously alongside the application container, sharing a Docker volume:

```yaml
services:
  app:
    image: myapp:latest
    volumes:
      - data:/data
    depends_on:
      restore:
        condition: service_completed_successfully

  litestream:
    image: litestream/litestream:latest
    command: replicate
    volumes:
      - data:/data
      - ./litestream.yml:/etc/litestream.yml
    env_file: .env
    restart: unless-stopped
    depends_on:
      restore:
        condition: service_completed_successfully

volumes:
  data:
```

The sidecar monitors the WAL file on the shared volume and streams changes to the configured replica destinations. It must start after the restore init container completes and should have `restart: unless-stopped` for resilience.

### Single-Container with -exec

The simplest pattern bundles Litestream into the application image using a multi-stage build, then uses `-exec` to run the application as a child process:

```dockerfile
FROM litestream/litestream:latest AS litestream

FROM python:3.12-slim
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream
COPY litestream.yml /etc/litestream.yml
COPY . /app
WORKDIR /app

COPY <<'EOF' /entrypoint.sh
#!/bin/bash
set -e
litestream restore -if-db-not-exists -if-replica-exists /data/app.db
exec litestream replicate -exec "python app.py"
EOF
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

Benefits:
- Single image to deploy
- Signal forwarding handled by Litestream — SIGTERM propagates to child
- No shared volumes to coordinate
- Simpler deployment topology

Drawbacks:
- Larger image size
- Cannot independently update app or Litestream
- If Litestream crashes, the application also stops (which may be desirable for data safety)

---

## Kubernetes Deployments

### StatefulSet with Init + Sidecar

SQLite requires single-writer semantics, so Kubernetes deployments **must** use `replicas: 1`. Use a StatefulSet for stable network identity and persistent volumes:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: myapp
spec:
  serviceName: myapp
  replicas: 1  # MUST be 1 — SQLite single-writer
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
    spec:
      terminationGracePeriodSeconds: 30
      volumes:
        - name: litestream-config
          configMap:
            name: litestream-config
      initContainers:
        - name: litestream-restore
          image: litestream/litestream:latest
          args:
            - restore
            - -if-db-not-exists
            - -if-replica-exists
            - /data/app.db
          envFrom:
            - secretRef:
                name: litestream-creds
          volumeMounts:
            - name: data
              mountPath: /data
            - name: litestream-config
              mountPath: /etc/litestream.yml
              subPath: litestream.yml
      containers:
        - name: app
          image: myapp:latest
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: data
              mountPath: /data
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
        - name: litestream
          image: litestream/litestream:latest
          args: ["replicate"]
          ports:
            - containerPort: 9090
              name: metrics
          envFrom:
            - secretRef:
                name: litestream-creds
          volumeMounts:
            - name: data
              mountPath: /data
            - name: litestream-config
              mountPath: /etc/litestream.yml
              subPath: litestream.yml
          livenessProbe:
            httpGet:
              path: /metrics
              port: 9090
            initialDelaySeconds: 10
            periodSeconds: 30
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 10Gi
```

### ConfigMap and Secret Management

Store the Litestream configuration in a ConfigMap and credentials in a Secret:

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
          - type: s3
            bucket: myapp-backups
            path: production
            region: us-east-1
            sync-interval: 1s
            snapshot-interval: 1h
            retention: 168h
            validation-interval: 12h
---
apiVersion: v1
kind: Secret
metadata:
  name: litestream-creds
type: Opaque
stringData:
  LITESTREAM_ACCESS_KEY_ID: "AKIAIOSFODNN7EXAMPLE"
  LITESTREAM_SECRET_ACCESS_KEY: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
```

For production, use a secrets manager (e.g., AWS Secrets Manager, HashiCorp Vault) via a CSI driver or external-secrets operator instead of plaintext Kubernetes secrets.

### Liveness and Readiness Probes

Litestream exposes a metrics endpoint when `addr` is set. Use this for the sidecar liveness probe:

```yaml
livenessProbe:
  httpGet:
    path: /metrics
    port: 9090
  initialDelaySeconds: 10
  periodSeconds: 30
```

For the application container, implement a health check that verifies both the app and the database:

```python
@app.route("/healthz")
def healthz():
    try:
        db.execute("SELECT 1")
        journal = db.execute("PRAGMA journal_mode").fetchone()[0]
        if journal != "wal":
            return "journal_mode not wal", 503
        return "ok", 200
    except Exception:
        return "db error", 503
```

### Persistent Volume Considerations

- Use `ReadWriteOnce` access mode — SQLite requires exclusive access
- Choose an SSD-backed StorageClass (`fast-ssd`, `gp3`, etc.) for low-latency WAL writes
- Size the PVC to at least 2x the expected database size to accommodate WAL files and temporary operations
- Avoid network-attached storage with high latency (EFS, NFS) — local SSDs or EBS gp3 are preferred
- Consider CSI snapshots as an additional backup layer

### Horizontal Pod Autoscaling Constraints

**Do not use HPA with SQLite-based applications.** Since SQLite is a single-writer database, running multiple pods will cause database lock contention and corruption. Set `replicas: 1` and use `PodDisruptionBudget` to minimize downtime during node maintenance:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: myapp-pdb
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: myapp
```

---

## systemd Service Integration

### Standalone Service

Run Litestream as a systemd service alongside an application managed by another unit:

```ini
[Unit]
Description=Litestream SQLite Replication
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=litestream
Group=litestream
ExecStart=/usr/local/bin/litestream replicate -config /etc/litestream.yml
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/data
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Dependency Ordering with Application

If the app is also a systemd service, order them with `Before`/`After` and create a restore oneshot:

```ini
# litestream-restore.service
[Unit]
Description=Litestream Restore on Boot
After=network-online.target
Before=myapp.service litestream.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/litestream restore -if-db-not-exists -if-replica-exists /data/app.db
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
```

```ini
# myapp.service
[Unit]
Description=My Application
After=litestream-restore.service
Requires=litestream-restore.service

[Service]
Type=simple
ExecStart=/usr/local/bin/myapp
Restart=always

[Install]
WantedBy=multi-user.target
```

```ini
# litestream.service
[Unit]
Description=Litestream Replication
After=litestream-restore.service myapp.service
Requires=litestream-restore.service

[Service]
Type=simple
ExecStart=/usr/local/bin/litestream replicate -config /etc/litestream.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enable all three: `systemctl enable litestream-restore litestream myapp`.

### Logging and Journal Integration

Litestream logs to stdout/stderr, which systemd captures in the journal:

```bash
# View Litestream logs
journalctl -u litestream -f

# View logs since last boot
journalctl -u litestream -b

# Filter for errors
journalctl -u litestream -p err

# Export structured JSON logs
journalctl -u litestream -o json --since "1 hour ago"
```

Set `logging.type: json` in `litestream.yml` for structured journal entries:

```yaml
logging:
  level: info
  type: json
```

---

## Fly.io Deployment

Fly.io is a popular platform for single-server SQLite apps. Litestream integrates well with Fly's persistent volumes.

### fly.toml Configuration

```toml
app = "myapp"
primary_region = "ord"

[build]
  dockerfile = "Dockerfile"

[env]
  DATABASE_PATH = "/data/app.db"
  LITESTREAM_CONFIG = "/etc/litestream.yml"

[mounts]
  source = "myapp_data"
  destination = "/data"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = false  # Keep running for continuous replication
  auto_start_machines = true

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"
```

### Persistent Volumes on Fly

Create the volume before deployment:

```bash
fly volumes create myapp_data --region ord --size 10
```

Important: Fly volumes are tied to a specific region and machine. When a machine is replaced, the volume persists but data may be lost if the machine is destroyed. Litestream ensures recovery from the replica.

### Entrypoint Script for Fly

```bash
#!/bin/bash
set -e

# Restore from S3 if database doesn't exist
litestream restore -if-db-not-exists -if-replica-exists /data/app.db

# Run app under Litestream supervision
exec litestream replicate -exec "myapp serve --addr :8080"
```

Store S3 credentials as Fly secrets:

```bash
fly secrets set \
  LITESTREAM_ACCESS_KEY_ID=AKIA... \
  LITESTREAM_SECRET_ACCESS_KEY=secret...
```

### Multi-Region on Fly

Fly supports multi-region deployments, but SQLite is single-writer. The pattern is:
1. Primary region runs the writer instance with Litestream replicating to S3
2. Read replicas in other regions use `fly-replay` headers to forward writes to the primary
3. Each read replica can restore from the same S3 bucket for read-heavy caching (stale reads)

This is an advanced pattern better served by LiteFS for live read replicas. Use Litestream for disaster recovery across regions.

---

## Multi-Replica Destinations

### Primary + DR Bucket

Replicate to two S3 buckets in different regions for disaster recovery:

```yaml
dbs:
  - path: /data/app.db
    replicas:
      - name: primary
        type: s3
        bucket: myapp-backups-us-east-1
        path: production
        region: us-east-1
        sync-interval: 1s
        snapshot-interval: 1h
        retention: 168h
      - name: dr
        type: s3
        bucket: myapp-backups-eu-west-1
        path: production
        region: eu-west-1
        sync-interval: 5s
        snapshot-interval: 4h
        retention: 720h  # 30 days in DR
```

The DR replica can have a longer sync interval to reduce cross-region transfer costs while maintaining a larger retention window for compliance.

### Cross-Provider Redundancy

Protect against a single cloud provider outage by replicating to multiple providers:

```yaml
dbs:
  - path: /data/app.db
    replicas:
      - name: aws
        type: s3
        bucket: myapp-aws
        region: us-east-1
        sync-interval: 1s
      - name: gcs
        type: gcs
        bucket: myapp-gcs
        sync-interval: 10s
      - name: b2
        type: s3
        bucket: myapp-b2
        endpoint: https://s3.us-west-002.backblazeb2.com
        force-path-style: true
        sync-interval: 30s
```

### Local + Remote Hybrid

Keep a fast local backup for quick restores plus a remote backup for disaster recovery:

```yaml
dbs:
  - path: /data/app.db
    replicas:
      - name: local
        type: file
        path: /mnt/backup/app
        sync-interval: 1s
        retention: 48h
      - name: remote
        type: s3
        bucket: myapp-backups
        path: production
        sync-interval: 5s
        retention: 720h
```

The local replica provides near-instant restores while the remote replica protects against hardware failure.

---

## Cross-Region Replication

### Active-Passive with S3 Cross-Region

In an active-passive setup, the primary region runs the application with Litestream replicating to a local S3 bucket. S3 Cross-Region Replication (CRR) copies objects to a DR bucket:

```
App (us-east-1) → Litestream → S3 (us-east-1) → S3 CRR → S3 (eu-west-1)
```

This adds latency to the replication chain but requires no Litestream configuration changes. S3 CRR is eventually consistent (typically seconds to minutes).

Alternatively, configure Litestream itself to push to both regions:

```
App (us-east-1) → Litestream → S3 (us-east-1)
                             → S3 (eu-west-1)
```

This gives Litestream-level consistency guarantees for both replicas.

### Multi-Region Replica Fan-Out

For organizations with strict compliance requirements (data sovereignty, regional backups):

```yaml
dbs:
  - path: /data/app.db
    replicas:
      - name: us-east
        type: s3
        bucket: backups-us-east-1
        region: us-east-1
        sync-interval: 1s
        retention: 168h
      - name: eu-west
        type: s3
        bucket: backups-eu-west-1
        region: eu-west-1
        sync-interval: 5s
        retention: 720h
      - name: ap-southeast
        type: s3
        bucket: backups-ap-southeast-1
        region: ap-southeast-1
        sync-interval: 10s
        retention: 720h
```

### Latency and Cost Considerations

Cross-region replication adds:
- **Latency**: 50–200ms per segment upload depending on regions
- **Transfer costs**: S3 cross-region data transfer is ~$0.02/GB
- **API costs**: Each WAL segment upload is a PUT request (~$0.005/1000 requests)

Mitigations:
- Increase `sync-interval` for remote replicas (5–30s) to batch WAL segments
- Use longer `snapshot-interval` for remote replicas to reduce full-copy frequency
- Monitor `litestream_replica_bytes_total` metric to track transfer volumes

---

## Application Framework Integration

### Go Applications

Go applications commonly use `database/sql` with `mattn/go-sqlite3` or `modernc.org/sqlite`. Run Litestream externally:

```go
// main.go
package main

import (
    "database/sql"
    "log"
    _ "github.com/mattn/go-sqlite3"
)

func main() {
    db, err := sql.Open("sqlite3", "/data/app.db?_journal_mode=WAL&_busy_timeout=5000&_synchronous=NORMAL")
    if err != nil {
        log.Fatal(err)
    }
    defer db.Close()

    // Application logic
    startServer(db)
}
```

Dockerfile:

```dockerfile
FROM litestream/litestream:latest AS litestream
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -o /myapp .

FROM alpine:3.19
RUN apk add --no-cache libc6-compat
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream
COPY --from=builder /myapp /usr/local/bin/myapp
COPY litestream.yml /etc/litestream.yml
COPY run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
```

### Rails with Litestream

Rails 8+ has first-class SQLite support. Combine with the `litestream` gem or run Litestream externally.

Using the `litestream-ruby` gem:

```ruby
# Gemfile
gem "litestream"
```

```ruby
# config/initializers/litestream.rb
Litestream.configure do |config|
  config.database_path = Rails.root.join("storage/production.sqlite3")
  config.replica_url = "s3://myapp-backups/production"
end
```

Or run externally with a Procfile:

```
# Procfile
web: bundle exec rails server -b 0.0.0.0 -p 3000
litestream: litestream replicate -config config/litestream.yml
```

Use `foreman` or `overmind` to manage both processes in development.

### Django with Litestream

Django uses SQLite as the default database. Configure it in `settings.py`:

```python
# settings.py
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": "/data/app.db",
        "OPTIONS": {
            "init_command": "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;",
        },
    }
}
```

Note: Django's `init_command` support varies by version. For older versions, set PRAGMAs in a startup signal:

```python
from django.db.backends.signals import connection_created

def set_sqlite_pragmas(sender, connection, **kwargs):
    if connection.vendor == "sqlite":
        cursor = connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL;")
        cursor.execute("PRAGMA busy_timeout=5000;")
        cursor.execute("PRAGMA synchronous=NORMAL;")

connection_created.connect(set_sqlite_pragmas)
```

Deploy with a multi-process supervisor or the `-exec` pattern:

```bash
#!/bin/bash
set -e
litestream restore -if-db-not-exists -if-replica-exists /data/app.db
exec litestream replicate -exec "gunicorn myproject.wsgi:application --bind 0.0.0.0:8000"
```

### Node.js / Express

With `better-sqlite3`:

```javascript
const Database = require("better-sqlite3");
const db = new Database("/data/app.db");

db.pragma("journal_mode = WAL");
db.pragma("busy_timeout = 5000");
db.pragma("synchronous = NORMAL");
db.pragma("cache_size = -64000");
```

Dockerfile with Litestream:

```dockerfile
FROM litestream/litestream:latest AS litestream
FROM node:20-alpine

COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream
WORKDIR /app
COPY package*.json ./
RUN npm ci --production
COPY . .
COPY litestream.yml /etc/litestream.yml
COPY run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
```

### Phoenix / Elixir

Elixir/Phoenix with `ecto_sqlite3`:

```elixir
# config/runtime.exs
config :myapp, MyApp.Repo,
  database: "/data/app.db",
  journal_mode: :wal,
  busy_timeout: 5000,
  cache_size: -64000
```

Use the same `-exec` entrypoint pattern:

```bash
#!/bin/bash
set -e
litestream restore -if-db-not-exists -if-replica-exists /data/app.db
exec litestream replicate -exec "/app/bin/myapp start"
```
