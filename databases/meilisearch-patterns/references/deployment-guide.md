# Meilisearch Production Deployment Guide

A comprehensive reference for deploying, securing, and operating Meilisearch in production environments.

---

## Table of Contents

- [1. Docker Deployment with Persistent Volumes](#1-docker-deployment-with-persistent-volumes)
- [2. Systemd Service](#2-systemd-service)
- [3. Cloud Deployment](#3-cloud-deployment)
- [4. Meilisearch Cloud](#4-meilisearch-cloud)
- [5. Reverse Proxy with Nginx](#5-reverse-proxy-with-nginx)
- [6. Reverse Proxy with Caddy](#6-reverse-proxy-with-caddy)
- [7. TLS Configuration](#7-tls-configuration)
- [8. Backup Strategy](#8-backup-strategy)
- [9. Monitoring with Prometheus](#9-monitoring-with-prometheus)
- [10. Scaling Strategies](#10-scaling-strategies)
- [11. High Availability Considerations](#11-high-availability-considerations)
- [12. Security Hardening](#12-security-hardening)

---

## 1. Docker Deployment with Persistent Volumes

Docker is the most common way to run Meilisearch in production. Use Docker Compose to define the service declaratively with persistent storage, health checks, and resource constraints.

### Production docker-compose.yml

```yaml
version: "3.8"

services:
  meilisearch:
    image: getmeili/meilisearch:v1.10
    container_name: meilisearch
    restart: unless-stopped
    ports:
      - "127.0.0.1:7700:7700"
    environment:
      MEILI_ENV: production
      MEILI_MASTER_KEY: ${MEILI_MASTER_KEY}
      MEILI_HTTP_ADDR: "0.0.0.0:7700"
      MEILI_MAX_INDEXING_MEMORY: "2Gb"
      MEILI_MAX_INDEXING_THREADS: "4"
      MEILI_LOG_LEVEL: "INFO"
      MEILI_SNAPSHOT_DIR: "/meili_data/snapshots"
      MEILI_SCHEDULE_SNAPSHOT: "86400"
    volumes:
      - meili_data:/meili_data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:7700/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    deploy:
      resources:
        limits:
          cpus: "4.0"
          memory: 4G
        reservations:
          cpus: "1.0"
          memory: 1G
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"

volumes:
  meili_data:
    name: meilisearch_production_data
```

### Environment File

Store secrets in a `.env` file alongside the compose file. Never commit this to version control.

```bash
# .env
MEILI_MASTER_KEY=your-master-key-minimum-16-bytes-long-use-openssl-rand
```

Generate a strong master key:

```bash
openssl rand -base64 32
```

### Key Environment Variables

| Variable | Description | Recommended Value |
|---|---|---|
| `MEILI_ENV` | Runtime mode. Must be `production` in prod. | `production` |
| `MEILI_MASTER_KEY` | Root secret. Required when `MEILI_ENV=production`. Min 16 bytes. | Random 32+ byte string |
| `MEILI_HTTP_ADDR` | Bind address and port. | `0.0.0.0:7700` |
| `MEILI_MAX_INDEXING_MEMORY` | RAM ceiling for indexing operations. | ~2/3 of available RAM |
| `MEILI_MAX_INDEXING_THREADS` | CPU threads for indexing. | Number of cores minus 1 |
| `MEILI_LOG_LEVEL` | Verbosity: `ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE`. | `INFO` |
| `MEILI_SNAPSHOT_DIR` | Where snapshots are written. | `/meili_data/snapshots` |

### Running the Stack

```bash
# Start in detached mode
docker compose up -d

# Verify health
docker compose ps
curl -s http://localhost:7700/health | jq .
# Expected: {"status":"available"}

# View logs
docker compose logs -f meilisearch

# Graceful stop (preserves data on the named volume)
docker compose down
```

### Upgrading Meilisearch in Docker

Meilisearch requires a dump-based migration between major versions. Minor/patch updates within the same major version can use in-place upgrades.

```bash
# 1. Create a dump before upgrading
curl -X POST http://localhost:7700/dumps \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}"

# 2. Wait for the dump task to complete, then copy it out
docker cp meilisearch:/meili_data/dumps/ ./backups/

# 3. Update image tag in docker-compose.yml, then:
docker compose down
docker compose up -d

# 4. If major version change, import the dump
curl -X POST http://localhost:7700/dumps/import \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}"
```

---

## 2. Systemd Service

For bare-metal or VM deployments, run Meilisearch as a systemd service for automatic restarts, log management, and boot-time startup.

### Install the Binary

```bash
# Download the latest release
curl -L https://install.meilisearch.com | sh

# Move to a system path
sudo mv ./meilisearch /usr/local/bin/
sudo chmod +x /usr/local/bin/meilisearch

# Verify
meilisearch --version
```

### Create a Dedicated User

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin meilisearch
sudo mkdir -p /var/lib/meilisearch /var/log/meilisearch
sudo chown meilisearch:meilisearch /var/lib/meilisearch /var/log/meilisearch
```

### Environment File for Secrets

Store configuration in `/etc/meilisearch.env`:

```bash
# /etc/meilisearch.env
MEILI_ENV=production
MEILI_MASTER_KEY=your-master-key-minimum-16-bytes-long
MEILI_HTTP_ADDR=127.0.0.1:7700
MEILI_DB_PATH=/var/lib/meilisearch/data
MEILI_DUMP_DIR=/var/lib/meilisearch/dumps
MEILI_SNAPSHOT_DIR=/var/lib/meilisearch/snapshots
MEILI_SCHEDULE_SNAPSHOT=86400
MEILI_MAX_INDEXING_MEMORY=2Gb
MEILI_MAX_INDEXING_THREADS=4
MEILI_LOG_LEVEL=INFO
```

Lock down permissions:

```bash
sudo chmod 600 /etc/meilisearch.env
sudo chown meilisearch:meilisearch /etc/meilisearch.env
```

### Systemd Unit File

Create `/etc/systemd/system/meilisearch.service`:

```ini
[Unit]
Description=Meilisearch Search Engine
Documentation=https://docs.meilisearch.com
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=meilisearch
Group=meilisearch
EnvironmentFile=/etc/meilisearch.env
ExecStart=/usr/local/bin/meilisearch
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=meilisearch
WorkingDirectory=/var/lib/meilisearch

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/meilisearch
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Enable and Start

```bash
sudo systemctl daemon-reload
sudo systemctl enable meilisearch
sudo systemctl start meilisearch
sudo systemctl status meilisearch
```

### Log Management

```bash
# Follow logs in real time
journalctl -u meilisearch -f

# View logs from the last hour
journalctl -u meilisearch --since "1 hour ago"

# View logs from a specific boot
journalctl -u meilisearch -b

# Check disk usage of journal logs
journalctl --disk-usage

# Retain only the last 7 days of logs
sudo journalctl --vacuum-time=7d
```

---

## 3. Cloud Deployment

### AWS (EC2 + EBS)

**Instance sizing:**

| Workload | Instance Type | vCPUs | RAM | Notes |
|---|---|---|---|---|
| Dev / small | t3.medium | 2 | 4 GB | Burstable, cost-effective |
| Medium | r6i.large | 2 | 16 GB | Memory-optimized |
| Large | r6i.xlarge | 4 | 32 GB | Large indexes |
| Very large | r6i.2xlarge | 8 | 64 GB | Millions of documents |

**EBS volume configuration:**

- Use `gp3` SSD volumes for a good balance of cost and performance.
- Provision at least 3,000 IOPS and 125 MB/s throughput (gp3 baseline).
- Size the volume to 2–3× your expected data size to allow for indexing overhead and snapshots.

```bash
# Attach and mount an EBS volume
sudo mkfs -t ext4 /dev/xvdf
sudo mkdir -p /var/lib/meilisearch
sudo mount /dev/xvdf /var/lib/meilisearch

# Persist across reboots via /etc/fstab
echo '/dev/xvdf /var/lib/meilisearch ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
```

**Security group rules:**

```
Inbound:
  - Port 22 (SSH): Your IP only / bastion host
  - Port 443 (HTTPS): 0.0.0.0/0 (via reverse proxy / ALB)
  - Port 7700: DENY from public (only allow from reverse proxy SG)

Outbound:
  - All traffic: 0.0.0.0/0
```

### GCP (Compute Engine)

- Use `n2-highmem` or `e2-highmem` machine types for memory-intensive workloads.
- Attach a regional SSD persistent disk (`pd-ssd`) for data.
- Place the instance in a VPC with firewall rules restricting port 7700 to internal traffic.

```bash
# Create a Compute Engine instance with an SSD persistent disk
gcloud compute instances create meilisearch-prod \
  --machine-type=n2-highmem-2 \
  --zone=us-central1-a \
  --boot-disk-size=20GB \
  --boot-disk-type=pd-ssd \
  --create-disk=name=meili-data,size=100GB,type=pd-ssd,auto-delete=no \
  --tags=meilisearch \
  --metadata-from-file=startup-script=startup.sh

# Firewall: allow 7700 only from internal network
gcloud compute firewall-rules create allow-meili-internal \
  --direction=INGRESS \
  --priority=1000 \
  --network=default \
  --action=ALLOW \
  --rules=tcp:7700 \
  --source-ranges=10.0.0.0/8 \
  --target-tags=meilisearch
```

### Azure

- Use `Standard_E2s_v5` (2 vCPUs, 16 GB RAM) or larger from the memory-optimized E-series.
- Attach a Premium SSD managed disk for Meilisearch data.
- Use a Network Security Group to restrict access to port 7700.

### General Cloud Considerations

- **RAM is king.** Meilisearch loads indexes into memory. Choose instances with ample RAM — the entire dataset should fit in memory for optimal search latency.
- **Use SSD storage.** NVMe or SSD-backed volumes are essential. Magnetic disks will severely degrade indexing and cold-start performance.
- **Bind to localhost.** Always bind Meilisearch to `127.0.0.1` and front it with a reverse proxy or load balancer for TLS termination.
- **Use private networking.** Place Meilisearch in a private subnet. Only the reverse proxy or load balancer should be in the public subnet.

---

## 4. Meilisearch Cloud

[Meilisearch Cloud](https://www.meilisearch.com/cloud) is the fully managed offering from Meili, the company behind Meilisearch.

### When to Use Meilisearch Cloud

| Factor | Self-Hosted | Meilisearch Cloud |
|---|---|---|
| Operational overhead | You manage infra, updates, backups | Fully managed |
| Scaling | Manual vertical scaling | Managed scaling options |
| Cost at scale | Potentially cheaper for large deployments | Premium for convenience |
| Compliance / data residency | Full control | Depends on available regions |
| Time to production | Hours to days | Minutes |
| HA / uptime SLA | You build it | Included in plans |

### Key Features

- **API-compatible.** The same Meilisearch SDKs and API calls work against Cloud instances. Migration is straightforward.
- **Multiple regions.** Deploy close to your users for lower latency.
- **Automatic backups.** Managed backup and restore without custom cron jobs.
- **Monitoring dashboard.** Built-in metrics and task tracking.

### Pricing Considerations

- Meilisearch Cloud pricing is based on the plan tier, which determines the allocated resources (RAM, storage, documents).
- For small-to-medium workloads or teams without dedicated infrastructure expertise, Cloud is often more cost-effective when you factor in engineering time.
- For very large deployments with an existing ops team, self-hosted may be cheaper in raw compute costs.

---

## 5. Reverse Proxy with Nginx

Never expose Meilisearch directly to the internet. Place it behind a reverse proxy for TLS termination, rate limiting, and security headers.

### Full Nginx Configuration

```nginx
# /etc/nginx/sites-available/meilisearch

# Rate limiting zone: 10 requests/second per IP
limit_req_zone $binary_remote_addr zone=meili_limit:10m rate=10r/s;

upstream meilisearch_backend {
    server 127.0.0.1:7700;
    keepalive 32;
}

# Redirect HTTP to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name search.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name search.example.com;

    # --- TLS ---
    ssl_certificate /etc/letsencrypt/live/search.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/search.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # --- Security Headers ---
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    # --- CORS ---
    # Adjust allowed origins to match your frontend domains.
    add_header Access-Control-Allow-Origin "https://app.example.com" always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type, X-Meili-API-Key" always;
    add_header Access-Control-Max-Age 86400 always;

    if ($request_method = OPTIONS) {
        return 204;
    }

    # --- Request Size ---
    client_max_body_size 100m;

    # --- Proxy to Meilisearch ---
    location / {
        limit_req zone=meili_limit burst=20 nodelay;

        proxy_pass http://meilisearch_backend;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Keep connections alive to the upstream
        proxy_set_header Connection "";

        proxy_connect_timeout 10s;
        proxy_send_timeout 60s;
        proxy_read_timeout 120s;

        # Buffering settings
        proxy_buffering on;
        proxy_buffer_size 16k;
        proxy_buffers 8 16k;
    }

    # --- Search endpoint: do NOT cache ---
    # Search results depend on the index state, query, and API key.
    # Caching at the proxy layer is almost never appropriate.
    location /indexes/ {
        limit_req zone=meili_limit burst=30 nodelay;

        proxy_pass http://meilisearch_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";

        # Explicitly disable caching for search
        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    }

    # --- Health check endpoint (no rate limit) ---
    location = /health {
        proxy_pass http://meilisearch_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        access_log off;
    }
}
```

### Enable the Site

```bash
sudo ln -s /etc/nginx/sites-available/meilisearch /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

---

## 6. Reverse Proxy with Caddy

Caddy is an excellent alternative to Nginx. It handles TLS certificates automatically via Let's Encrypt with zero configuration.

### Caddyfile

```caddyfile
# /etc/caddy/Caddyfile

search.example.com {
    # Automatic HTTPS via Let's Encrypt — no cert config needed

    # Rate limiting (requires the caddy-ratelimit plugin)
    # rate_limit {
    #     zone meili_zone {
    #         key {remote_host}
    #         events 10
    #         window 1s
    #     }
    # }

    # Security headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
        Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        -Server
    }

    # CORS headers for your frontend
    @cors_preflight method OPTIONS
    handle @cors_preflight {
        header Access-Control-Allow-Origin "https://app.example.com"
        header Access-Control-Allow-Methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
        header Access-Control-Allow-Headers "Authorization, Content-Type"
        header Access-Control-Max-Age "86400"
        respond 204
    }

    header Access-Control-Allow-Origin "https://app.example.com"

    # Reverse proxy to Meilisearch
    reverse_proxy 127.0.0.1:7700 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Health checks
        health_uri /health
        health_interval 30s
        health_timeout 5s
    }

    # Logging
    log {
        output file /var/log/caddy/meilisearch-access.log {
            roll_size 50MiB
            roll_keep 5
        }
    }
}
```

### Install and Run Caddy

```bash
sudo apt install -y caddy

# Validate the Caddyfile
caddy validate --config /etc/caddy/Caddyfile

# Reload with new config
sudo systemctl reload caddy
```

Caddy automatically obtains and renews Let's Encrypt certificates for the configured domain. Ensure DNS points to the server and ports 80/443 are open for the ACME challenge.

---

## 7. TLS Configuration

### Why TLS Is Mandatory in Production

Meilisearch API keys (including the master key) are sent in HTTP headers. Without TLS, these keys are transmitted in plain text and are trivially interceptable. **Never run production Meilisearch without TLS.**

### Option A: TLS Termination at the Reverse Proxy (Recommended)

This is the standard approach. The reverse proxy (Nginx/Caddy) handles TLS, and traffic between the proxy and Meilisearch travels over localhost unencrypted.

**Let's Encrypt with Certbot (for Nginx):**

```bash
# Install certbot
sudo apt install -y certbot python3-certbot-nginx

# Obtain a certificate
sudo certbot --nginx -d search.example.com

# Auto-renewal is configured automatically. Verify:
sudo systemctl status certbot.timer
sudo certbot renew --dry-run
```

### Option B: Meilisearch Native TLS

Meilisearch can terminate TLS directly. This is useful in environments without a reverse proxy (development, internal microservices).

```bash
# Environment variables for native TLS
MEILI_SSL_CERT_PATH=/etc/meilisearch/certs/fullchain.pem
MEILI_SSL_KEY_PATH=/etc/meilisearch/certs/privkey.pem
MEILI_SSL_AUTH_PATH=/etc/meilisearch/certs/ca.pem  # Optional: mTLS
MEILI_SSL_REQUIRE_AUTH=false
```

In `docker-compose.yml`:

```yaml
services:
  meilisearch:
    environment:
      MEILI_SSL_CERT_PATH: /certs/fullchain.pem
      MEILI_SSL_KEY_PATH: /certs/privkey.pem
    volumes:
      - ./certs:/certs:ro
      - meili_data:/meili_data
    ports:
      - "443:7700"
```

### Self-Signed Certificates for Internal Use

For internal services that do not face the public internet:

```bash
# Generate a self-signed certificate (valid for 365 days)
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /etc/meilisearch/certs/privkey.pem \
  -out /etc/meilisearch/certs/fullchain.pem \
  -subj "/CN=meilisearch.internal"

# Ensure Meilisearch can read the certs
sudo chown meilisearch:meilisearch /etc/meilisearch/certs/*.pem
sudo chmod 600 /etc/meilisearch/certs/privkey.pem
```

Configure your client SDK to trust the self-signed CA or disable verification (development only).

---

## 8. Backup Strategy

### Snapshots vs Dumps

| Feature | Snapshots | Dumps |
|---|---|---|
| **Format** | Binary copy of the database | Platform-independent JSON/NDJSON |
| **Speed** | Fast (file copy) | Slower (serialization/deserialization) |
| **Portability** | Same Meilisearch version only | Cross-version compatible |
| **Use case** | Fast recovery, same-version restore | Migrations, version upgrades |
| **Created via** | `MEILI_SCHEDULE_SNAPSHOT` or API | API endpoint only |
| **Includes settings** | Yes | Yes |
| **Includes API keys** | Yes | Yes |
| **File size** | Larger (raw DB) | Smaller (compressed) |

### Automated Snapshot Scheduling

Configure Meilisearch to create snapshots at a regular interval:

```bash
# In your environment file or docker-compose.yml
MEILI_SCHEDULE_SNAPSHOT=86400       # Every 24 hours (in seconds)
MEILI_SNAPSHOT_DIR=/var/lib/meilisearch/snapshots
```

### Dump Creation via API

Dumps are essential for version upgrades and cross-environment migrations.

```bash
# Create a dump
curl -X POST 'http://localhost:7700/dumps' \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}"

# Check dump task status
curl 'http://localhost:7700/tasks?types=dumpCreation&limit=1' \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}" | jq .
```

### Offsite Backup with Cron + S3

```bash
#!/usr/bin/env bash
# /opt/scripts/meilisearch-backup.sh

set -euo pipefail

BACKUP_DIR="/var/lib/meilisearch/snapshots"
S3_BUCKET="s3://my-backups/meilisearch"
RETENTION_DAYS=30
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# Trigger a fresh dump
TASK_UID=$(curl -s -X POST 'http://localhost:7700/dumps' \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}" | jq -r '.taskUid')

echo "Dump task created: ${TASK_UID}"

# Poll until the dump task succeeds
while true; do
  STATUS=$(curl -s "http://localhost:7700/tasks/${TASK_UID}" \
    -H "Authorization: Bearer ${MEILI_MASTER_KEY}" | jq -r '.status')
  if [ "$STATUS" = "succeeded" ]; then
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "Dump task failed!" >&2
    exit 1
  fi
  sleep 5
done

# Find the latest dump file
DUMP_FILE=$(ls -t /var/lib/meilisearch/dumps/*.dump 2>/dev/null | head -1)

if [ -z "$DUMP_FILE" ]; then
  echo "No dump file found" >&2
  exit 1
fi

# Upload to S3
aws s3 cp "$DUMP_FILE" "${S3_BUCKET}/dump-${DATE}.dump" \
  --storage-class STANDARD_IA

# Upload latest snapshot to S3
SNAPSHOT_FILE=$(ls -t "${BACKUP_DIR}"/*.snapshot 2>/dev/null | head -1)
if [ -n "$SNAPSHOT_FILE" ]; then
  aws s3 cp "$SNAPSHOT_FILE" "${S3_BUCKET}/snapshot-${DATE}.snapshot" \
    --storage-class STANDARD_IA
fi

# Clean up local dumps older than retention period
find /var/lib/meilisearch/dumps -name "*.dump" -mtime +${RETENTION_DAYS} -delete
find "${BACKUP_DIR}" -name "*.snapshot" -mtime +${RETENTION_DAYS} -delete

# Clean up remote backups older than retention period
aws s3 ls "${S3_BUCKET}/" | while read -r line; do
  FILE_DATE=$(echo "$line" | awk '{print $1}')
  FILE_NAME=$(echo "$line" | awk '{print $4}')
  if [ -n "$FILE_NAME" ]; then
    AGE_DAYS=$(( ($(date +%s) - $(date -d "$FILE_DATE" +%s)) / 86400 ))
    if [ "$AGE_DAYS" -gt "$RETENTION_DAYS" ]; then
      aws s3 rm "${S3_BUCKET}/${FILE_NAME}"
    fi
  fi
done

echo "Backup complete: dump-${DATE}"
```

**Cron entry:**

```bash
# Run daily at 02:00 UTC
0 2 * * * /opt/scripts/meilisearch-backup.sh >> /var/log/meilisearch-backup.log 2>&1
```

For GCS, replace `aws s3 cp` with `gsutil cp` and adjust bucket paths accordingly.

### Testing Restore Procedures

Regularly test your backups. An untested backup is not a backup.

```bash
# Restore from a snapshot (same version only)
meilisearch --import-snapshot /path/to/snapshot.snapshot \
  --ignore-snapshot-if-db-exists=true

# Restore from a dump (cross-version safe)
meilisearch --import-dump /path/to/dump.dump
```

---

## 9. Monitoring with Prometheus

### Built-in Endpoints

Meilisearch exposes two key endpoints for monitoring:

```bash
# Health check — returns 200 when Meilisearch is ready
curl http://localhost:7700/health
# {"status":"available"}

# Stats — index-level statistics
curl http://localhost:7700/stats \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}"
# {"databaseSize":1234567,"lastUpdate":"2024-01-15T...","indexes":{...}}
```

### Custom Prometheus Exporter

Meilisearch does not natively export Prometheus metrics. Build a lightweight exporter that polls the API and exposes metrics in Prometheus format.

```python
#!/usr/bin/env python3
# meilisearch_exporter.py

import time
import requests
from prometheus_client import start_http_server, Gauge, Counter

MEILI_URL = "http://localhost:7700"
MEILI_API_KEY = "your-master-key"
HEADERS = {"Authorization": f"Bearer {MEILI_API_KEY}"}
POLL_INTERVAL = 15  # seconds

# Define metrics
health_status = Gauge(
    "meilisearch_health_status",
    "1 if healthy, 0 if unhealthy"
)
database_size_bytes = Gauge(
    "meilisearch_database_size_bytes",
    "Total database size in bytes"
)
index_document_count = Gauge(
    "meilisearch_index_document_count",
    "Number of documents in an index",
    ["index_name"]
)
index_size_bytes = Gauge(
    "meilisearch_index_size_bytes",
    "Size of an index in bytes",
    ["index_name"]
)
task_queue_total = Gauge(
    "meilisearch_task_queue_total",
    "Total tasks by status",
    ["status"]
)

def collect_metrics():
    # Health
    try:
        r = requests.get(f"{MEILI_URL}/health", timeout=5)
        health_status.set(1 if r.status_code == 200 else 0)
    except Exception:
        health_status.set(0)

    # Stats
    try:
        r = requests.get(f"{MEILI_URL}/stats", headers=HEADERS, timeout=10)
        stats = r.json()
        database_size_bytes.set(stats.get("databaseSize", 0))

        for idx_name, idx_stats in stats.get("indexes", {}).items():
            index_document_count.labels(index_name=idx_name).set(
                idx_stats.get("numberOfDocuments", 0)
            )
            index_size_bytes.labels(index_name=idx_name).set(
                idx_stats.get("fieldDistribution", {}).get("_size", 0)
            )
    except Exception:
        pass

    # Task queue
    try:
        for status in ["enqueued", "processing", "succeeded", "failed"]:
            r = requests.get(
                f"{MEILI_URL}/tasks?statuses={status}&limit=0",
                headers=HEADERS, timeout=10
            )
            task_queue_total.labels(status=status).set(r.json().get("total", 0))
    except Exception:
        pass

if __name__ == "__main__":
    start_http_server(9400)
    print("Meilisearch exporter running on :9400")
    while True:
        collect_metrics()
        time.sleep(POLL_INTERVAL)
```

### Prometheus Scrape Configuration

```yaml
# prometheus.yml
scrape_configs:
  - job_name: "meilisearch"
    scrape_interval: 15s
    static_configs:
      - targets: ["localhost:9400"]
    metrics_path: /metrics
```

### Key Metrics to Monitor

| Metric | Why It Matters |
|---|---|
| `meilisearch_health_status` | Core liveness signal. Alert immediately on 0. |
| `meilisearch_database_size_bytes` | Track growth. Alert before disk fills up. |
| `meilisearch_index_document_count` | Detect unexpected drops (data loss) or spikes. |
| `meilisearch_task_queue_total{status="failed"}` | Failed tasks need investigation. |
| `meilisearch_task_queue_total{status="enqueued"}` | Growing queue means indexing can't keep up. |
| Host: disk usage | Meilisearch data + snapshots + dumps can grow fast. |
| Host: memory usage | Meilisearch is memory-intensive. OOM kills are catastrophic. |
| Host: CPU usage | High CPU during indexing is normal; high CPU during search is not. |

### Grafana Dashboard Setup

1. Add Prometheus as a data source in Grafana.
2. Import or create a dashboard with panels for each metric above.
3. Suggested panels:
   - **Health status** — Stat panel (green/red).
   - **Database size over time** — Time series graph.
   - **Documents per index** — Bar gauge.
   - **Task queue by status** — Stacked time series.
   - **Disk / Memory / CPU** — Use node_exporter metrics.

### Alerting Rules

```yaml
# prometheus-alerts.yml
groups:
  - name: meilisearch
    rules:
      - alert: MeilisearchDown
        expr: meilisearch_health_status == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Meilisearch is unhealthy"
          description: "Health check has returned unhealthy for over 1 minute."

      - alert: MeilisearchDiskUsageHigh
        expr: (node_filesystem_avail_bytes{mountpoint="/var/lib/meilisearch"} / node_filesystem_size_bytes{mountpoint="/var/lib/meilisearch"}) < 0.15
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Meilisearch disk usage above 85%"

      - alert: MeilisearchTaskFailures
        expr: increase(meilisearch_task_queue_total{status="failed"}[1h]) > 0
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "Meilisearch has failed tasks in the last hour"

      - alert: MeilisearchQueueBacklog
        expr: meilisearch_task_queue_total{status="enqueued"} > 100
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Meilisearch task queue backlog exceeding 100 tasks"
```

---

## 10. Scaling Strategies

### Understanding Meilisearch's Architecture

Meilisearch is a **single-node search engine**. It does not support native clustering, distributed indexing, or automatic horizontal scaling. All data lives on one machine. This simplicity is a feature — it eliminates coordination overhead and consistency issues — but it means scaling requires deliberate planning.

### Vertical Scaling

The primary way to scale Meilisearch is vertically:

- **More RAM.** Meilisearch loads indexes into memory. If your dataset grows beyond available RAM, search latency degrades sharply. Upgrade to an instance with more memory.
- **Faster SSDs.** NVMe drives improve indexing throughput and cold-start times. Use local SSDs over network-attached storage when possible.
- **More CPU cores.** Indexing is CPU-intensive and parallelizable. Set `MEILI_MAX_INDEXING_THREADS` to match your core count minus one (leave one core for search queries).

**Sizing rule of thumb:** Provision RAM at roughly 2× your raw dataset size. A 5 GB dataset needs ~10 GB of RAM for comfortable operation.

### Read Replicas

Meilisearch does not have built-in replication, but you can approximate read replicas:

1. Run multiple Meilisearch instances on separate machines.
2. Index documents to a primary instance.
3. Periodically create dumps on the primary and import them on replicas.
4. Use a load balancer to distribute search (read) traffic across replicas.

This approach trades freshness for read throughput. Replicas will lag behind the primary by the dump/restore interval.

### Index Sharding

For very large datasets, consider splitting data across multiple Meilisearch instances by logical shard (e.g., by tenant, region, or category). Your application layer routes queries to the correct shard.

### When to Consider Meilisearch Cloud

If you need:
- Automatic scaling without manual intervention
- High availability guarantees
- Managed infrastructure and operations

Meilisearch Cloud handles these concerns, allowing you to focus on your application rather than search infrastructure.

---

## 11. High Availability Considerations

### The Reality: Single-Node by Design

Meilisearch is not designed for multi-node high availability. There is no leader election, consensus protocol, or automatic failover. Accepting this is the first step to building a resilient deployment.

### Strategies for Resilience

#### Fast Recovery from Snapshots

The most practical HA strategy: recover quickly when failure occurs.

```bash
# Automated recovery script
#!/usr/bin/env bash
# /opt/scripts/meili-recovery.sh

set -euo pipefail

SNAPSHOT_DIR="/var/lib/meilisearch/snapshots"
DATA_DIR="/var/lib/meilisearch/data"

# Find the latest snapshot
LATEST=$(ls -t "${SNAPSHOT_DIR}"/*.snapshot 2>/dev/null | head -1)

if [ -z "$LATEST" ]; then
  echo "No snapshots found. Cannot recover." >&2
  exit 1
fi

echo "Recovering from: ${LATEST}"

# Stop Meilisearch
sudo systemctl stop meilisearch

# Clear corrupted data
rm -rf "${DATA_DIR}"

# Import snapshot
meilisearch --import-snapshot "$LATEST" --db-path "$DATA_DIR"

# Restart service
sudo systemctl start meilisearch

echo "Recovery complete."
```

#### Load Balancer Health Checks

Place Meilisearch behind a load balancer that checks `/health`. The LB removes unhealthy instances from rotation and can trigger alerts.

```nginx
# Nginx upstream with health checks (requires nginx-plus or third-party module)
upstream meilisearch {
    server 127.0.0.1:7700 max_fails=3 fail_timeout=30s;
}
```

For AWS ALB:

```
Health check path: /health
Healthy threshold: 2
Unhealthy threshold: 3
Interval: 15 seconds
Timeout: 5 seconds
```

#### Automated Restart

The systemd unit file (Section 2) already includes `Restart=on-failure`. For Docker, `restart: unless-stopped` provides the same behavior. Combined with health checks, this handles transient crashes.

#### Blue-Green Deployment with Dump/Restore

For zero-downtime upgrades:

1. **Blue** (current production) serves traffic.
2. Create a dump on Blue.
3. Start **Green** (new version) and import the dump.
4. Validate Green is healthy and data is correct.
5. Switch the load balancer / DNS from Blue to Green.
6. Decommission Blue after confirming Green is stable.

```bash
# On Blue: create dump
curl -X POST http://blue:7700/dumps -H "Authorization: Bearer ${KEY}"

# On Green: import dump and start
meilisearch --import-dump /path/to/dump.dump --env production \
  --master-key "${KEY}" --http-addr 0.0.0.0:7700

# Validate Green
curl http://green:7700/health
curl http://green:7700/stats -H "Authorization: Bearer ${KEY}"

# Switch traffic (update DNS, LB, or reverse proxy upstream)
```

### Monitoring and Alerting for Quick Recovery

The difference between minutes and hours of downtime is monitoring. Ensure:

- Health check alerts fire within 1–2 minutes of failure.
- On-call engineers have runbooks for recovery.
- Recovery scripts are tested regularly (monthly at minimum).
- Backup integrity is verified automatically.

---

## 12. Security Hardening

### Network Segmentation

- Run Meilisearch in a **private subnet** with no public IP.
- Only the reverse proxy or load balancer should be publicly accessible.
- Use security groups / firewall rules to restrict port 7700 to the reverse proxy only.

```bash
# UFW example: only allow Meilisearch from the reverse proxy host
sudo ufw default deny incoming
sudo ufw allow from 10.0.1.5 to any port 7700 proto tcp comment "Nginx proxy"
sudo ufw allow 22/tcp comment "SSH"
sudo ufw enable
```

### API Key Management

Meilisearch uses a **two-tier key system** in production:

- **Master key:** Used only to manage other keys. Never embed in client applications. Store in a secrets manager (AWS Secrets Manager, HashiCorp Vault, etc.).
- **Admin key (default):** Full API access. Use server-side only.
- **Search key (default):** Read-only search access. Safe to use in frontend clients.

```bash
# List existing keys
curl http://localhost:7700/keys \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}" | jq .

# Create a scoped key with limited permissions and expiration
curl -X POST http://localhost:7700/keys \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Frontend search key for products index",
    "actions": ["search"],
    "indexes": ["products"],
    "expiresAt": "2025-12-31T23:59:59Z"
  }'
```

**Best practices:**

- Create scoped keys with the minimum required `actions` and `indexes`.
- Set `expiresAt` on all keys and rotate them periodically.
- Never expose the master key or admin key to frontend clients.

### Disabling Master Key Exposure

The master key should only be known to infrastructure automation and key management scripts. It should never appear in:

- Frontend code or client-side bundles
- Application logs
- Version control
- Docker image layers (use runtime environment variables or secrets)

### Firewall Rules

Only expose Meilisearch through the reverse proxy:

```bash
# iptables: allow 7700 only from localhost
sudo iptables -A INPUT -p tcp --dport 7700 -s 127.0.0.1 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 7700 -j DROP
```

### Log Auditing

Enable `INFO` level logging and review logs regularly for suspicious activity:

```bash
# Check for unauthorized access attempts
journalctl -u meilisearch | grep -i "unauthorized\|forbidden\|invalid"

# Monitor for unusual API patterns
journalctl -u meilisearch --since "24 hours ago" | grep "POST /indexes" | wc -l
```

### Keeping Meilisearch Updated

Subscribe to [Meilisearch releases](https://github.com/meilisearch/meilisearch/releases) and apply security patches promptly. Use the dump/restore process (Section 8) to migrate between versions safely.

```bash
# Check current version
curl http://localhost:7700/version \
  -H "Authorization: Bearer ${MEILI_MASTER_KEY}"

# Compare with the latest release
curl -s https://api.github.com/repos/meilisearch/meilisearch/releases/latest \
  | jq -r '.tag_name'
```

---

## Quick Reference: Production Checklist

- [ ] `MEILI_ENV=production` is set
- [ ] Master key is strong (32+ bytes), stored in a secrets manager
- [ ] Meilisearch binds to `127.0.0.1`, not `0.0.0.0`
- [ ] Reverse proxy (Nginx/Caddy) handles TLS termination
- [ ] TLS certificate is valid and auto-renewing
- [ ] Firewall restricts port 7700 to the reverse proxy only
- [ ] Automated snapshots are enabled (`MEILI_SCHEDULE_SNAPSHOT`)
- [ ] Offsite backups run daily with tested restore procedures
- [ ] Monitoring covers health, disk, memory, and task queue
- [ ] Alerting fires within 2 minutes of health check failure
- [ ] Recovery runbooks exist and are tested monthly
- [ ] API keys are scoped with minimal permissions and expiration dates
- [ ] Meilisearch version is current with security patches applied
