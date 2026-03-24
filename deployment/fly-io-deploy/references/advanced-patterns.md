# Fly.io Advanced Patterns Reference

## Table of Contents
1. [Machines API Deep Dive](#machines-api-deep-dive)
2. [Fly Launch vs Machines API](#fly-launch-vs-machines-api)
3. [GPU Machines](#gpu-machines)
4. [Tigris Object Storage Integration](#tigris-object-storage-integration)
5. [LiteFS for Distributed SQLite](#litefs-for-distributed-sqlite)
6. [Multi-Region Postgres with Read Replicas](#multi-region-postgres-with-read-replicas)
7. [Fly.io Extensions](#flyio-extensions)
8. [Process Groups](#process-groups)
9. [Statics Serving](#statics-serving)
10. [Fly Proxy Headers](#fly-proxy-headers)
11. [Custom Metrics with Prometheus](#custom-metrics-with-prometheus)
12. [Fly.io Terraform Provider](#flyio-terraform-provider)

---

## Machines API Deep Dive

Base URL: `https://api.machines.dev/v1`
Auth: `Authorization: Bearer <FLY_API_TOKEN>` (get via `fly tokens create deploy`).

### Create a Machine

```bash
curl -X POST "https://api.machines.dev/v1/apps/${APP}/machines" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "web-1",
    "region": "iad",
    "config": {
      "image": "registry.fly.io/my-app:deployment-01HXXXX",
      "env": {
        "APP_ENV": "production",
        "PORT": "8080"
      },
      "guest": {
        "cpu_kind": "shared",
        "cpus": 2,
        "memory_mb": 512
      },
      "services": [
        {
          "ports": [
            {"port": 80, "handlers": ["http"]},
            {"port": 443, "handlers": ["tls", "http"]}
          ],
          "internal_port": 8080,
          "protocol": "tcp",
          "checks": [
            {
              "type": "http",
              "port": 8080,
              "method": "GET",
              "path": "/health",
              "interval": "10s",
              "timeout": "2s",
              "grace_period": "30s"
            }
          ]
        }
      ],
      "mounts": [
        {
          "volume": "vol_abc123",
          "path": "/data"
        }
      ],
      "restart": {
        "policy": "on-failure",
        "max_retries": 3
      },
      "auto_destroy": false
    }
  }'
```

Response includes `id`, `instance_id`, `state`, `region`, `created_at`. Save the `id` for subsequent operations.

### Update a Machine

```bash
curl -X POST "https://api.machines.dev/v1/apps/${APP}/machines/${MACHINE_ID}" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "image": "registry.fly.io/my-app:deployment-01HYYYY",
      "guest": {
        "cpu_kind": "shared",
        "cpus": 4,
        "memory_mb": 1024
      }
    }
  }'
```

Update replaces the Machine config entirely. Always send the full desired config, not just changed fields.

### Exec (run command in Machine)

```bash
curl -X POST "https://api.machines.dev/v1/apps/${APP}/machines/${MACHINE_ID}/exec" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": ["bin/rails", "db:migrate"],
    "timeout": 60
  }'
```

Returns `stdout`, `stderr`, `exit_code`. Use for one-off commands like migrations, cache clearing, or diagnostics.

### Wait for Machine State

```bash
# Wait for machine to reach "started" state (timeout in seconds)
curl "https://api.machines.dev/v1/apps/${APP}/machines/${MACHINE_ID}/wait?state=started&timeout=60" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}"
```

Valid states: `created`, `started`, `stopped`, `destroyed`. Use after create/update to confirm readiness before routing traffic.

### Other Key Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/apps/{app}/machines` | List all machines |
| GET | `/apps/{app}/machines/{id}` | Get machine details |
| POST | `/apps/{app}/machines/{id}/stop` | Stop machine (signal: SIGTERM) |
| POST | `/apps/{app}/machines/{id}/start` | Start stopped machine |
| POST | `/apps/{app}/machines/{id}/restart` | Restart machine |
| DELETE | `/apps/{app}/machines/{id}` | Destroy machine permanently |
| GET | `/apps/{app}/machines/{id}/metadata` | Get machine metadata |
| POST | `/apps/{app}/machines/{id}/cordon` | Remove from load balancer |
| POST | `/apps/{app}/machines/{id}/uncordon` | Add back to load balancer |
| GET | `/apps/{app}/machines/{id}/events` | Get machine event log |
| GET | `/apps/{app}/volumes` | List volumes for app |

### Cordon/Uncordon Pattern for Zero-Downtime Deploys

```bash
# 1. Cordon old machine (stop receiving traffic)
curl -X POST ".../machines/${OLD_ID}/cordon" -H "Authorization: Bearer ${FLY_API_TOKEN}"

# 2. Create new machine with updated image
NEW_ID=$(curl -s -X POST ".../machines" ... | jq -r '.id')

# 3. Wait for new machine to be healthy
curl ".../machines/${NEW_ID}/wait?state=started&timeout=60" -H "Authorization: Bearer ${FLY_API_TOKEN}"

# 4. Destroy old machine
curl -X DELETE ".../machines/${OLD_ID}?force=true" -H "Authorization: Bearer ${FLY_API_TOKEN}"
```

---

## Fly Launch vs Machines API

| Aspect | `fly launch` / `fly deploy` | Machines API |
|--------|------------------------------|-------------|
| **Abstraction** | High-level, declarative via `fly.toml` | Low-level, imperative per-Machine |
| **Config** | `fly.toml` is source of truth | JSON payloads, you manage state |
| **Scaling** | `fly scale count N` | Create/destroy individual Machines |
| **Deploys** | Rolling/canary/bluegreen built-in | You implement deploy strategy |
| **Health checks** | Managed by Fly Proxy | You poll `/wait` endpoint |
| **Best for** | Standard web apps, typical services | Custom orchestration, GPU jobs, batch processing, ephemeral workers |
| **Process groups** | Defined in `fly.toml` `[processes]` | Separate Machine configs |
| **Volume mgmt** | Automatic via `[mounts]` | Manual volume creation + attachment |

**Rule of thumb**: Use Fly Launch for 90% of workloads. Use Machines API when you need programmatic control, ephemeral workers, or are building your own orchestrator.

---

## GPU Machines

Available GPU types:
- `a100-40gb` — NVIDIA A100 40GB (training/inference)
- `a100-80gb` — NVIDIA A100 80GB (large models)
- `l40s` — NVIDIA L40S (inference, video)
- `a10` — NVIDIA A10 (cost-effective inference)

### Provisioning GPU Machines

```bash
# Via flyctl
fly scale vm a100-40gb --memory 65536 --count 1

# Via Machines API
curl -X POST "https://api.machines.dev/v1/apps/${APP}/machines" \
  -H "Authorization: Bearer ${FLY_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "region": "ord",
    "config": {
      "image": "registry.fly.io/my-ml-app:latest",
      "guest": {
        "cpu_kind": "performance",
        "cpus": 8,
        "memory_mb": 65536,
        "gpu_kind": "a100-40gb",
        "gpus": 1
      }
    }
  }'
```

### GPU Best Practices
- GPUs are available in limited regions (`ord`, `iad`, `sjc`). Check `fly platform vm-sizes` for current availability.
- Use auto-stop to avoid paying for idle GPU time. GPU Machines cost $2.50+/hr.
- Build Docker images with CUDA pre-installed. Use `nvidia/cuda` base images.
- Large model weights: store in Tigris, download at boot or bake into image.
- Use Volumes for model caching to avoid re-downloading on restart.

```toml
# fly.toml for GPU workload
[[vm]]
  size = "a100-40gb"
  memory = "65536mb"

[http_service]
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0

[mounts]
  source = "model_cache"
  destination = "/models"
```

---

## Tigris Object Storage Integration

Tigris is Fly.io's S3-compatible global object storage. No egress fees.

### Setup

```bash
fly storage create                          # Creates bucket, sets env vars
fly storage create --name my-bucket -o myorg
fly storage list
fly storage dashboard                       # Opens web dashboard
```

Creates these secrets automatically: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3`, `AWS_REGION`, `BUCKET_NAME`.

### Usage with AWS SDKs

```python
# Python (boto3) — works without config changes when env vars are set
import boto3
s3 = boto3.client("s3")  # Picks up AWS_* env vars automatically
s3.upload_file("local.txt", os.environ["BUCKET_NAME"], "remote.txt")
s3.download_file(os.environ["BUCKET_NAME"], "remote.txt", "local.txt")
presigned = s3.generate_presigned_url("get_object",
    Params={"Bucket": os.environ["BUCKET_NAME"], "Key": "remote.txt"},
    ExpiresIn=3600)
```

```javascript
// Node.js (@aws-sdk/client-s3) — uses env vars
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
const s3 = new S3Client({});  // Auto-detects AWS_* env vars
await s3.send(new PutObjectCommand({
  Bucket: process.env.BUCKET_NAME,
  Key: "file.txt",
  Body: Buffer.from("content")
}));
```

### Tigris Features
- **Global caching**: Objects cached at edge near users automatically.
- **Conditional requests**: Standard `If-None-Match` / `If-Modified-Since` ETags supported.
- **Multipart uploads**: For files >5MB, use multipart for reliability.
- **Public buckets**: Enable via Tigris dashboard for static asset hosting.
- **Shadow buckets**: Migrate from S3 by pointing Tigris to your existing S3 bucket as a read-through cache.

---

## LiteFS for Distributed SQLite

LiteFS replicates SQLite databases across Fly Machines using FUSE.

### Architecture
- One **primary** node handles all writes.
- **Replica** nodes get near-real-time async replication (typically <100ms).
- Primary election via Consul lease on Fly.io.
- Write requests on replicas return `fly-replay` header to redirect to primary.

### Setup

1. Add LiteFS to your Dockerfile:
```dockerfile
COPY --from=flyio/litefs:0.5 /usr/local/bin/litefs /usr/local/bin/litefs
RUN mkdir -p /data/litefs /litefs
```

2. Create `litefs.yml` (see assets/litefs.yml).

3. Update `fly.toml`:
```toml
[mounts]
  source = "litefs_data"
  destination = "/data"

[env]
  PRIMARY_REGION = "iad"
```

4. Use LiteFS as entrypoint:
```dockerfile
ENTRYPOINT ["litefs", "mount"]
```

### Write Forwarding Pattern

```python
import os, flask
app = flask.Flask(__name__)

@app.before_request
def forward_writes():
    if flask.request.method in ("POST", "PUT", "PATCH", "DELETE"):
        if os.environ.get("FLY_REGION") != os.environ.get("PRIMARY_REGION"):
            return "", 409, {"fly-replay": f"region={os.environ['PRIMARY_REGION']}"}
```

### LiteFS Caveats
- WAL mode required for SQLite (`PRAGMA journal_mode=WAL`).
- Application must handle `SQLITE_BUSY` errors (retry logic).
- FUSE mount adds ~5% read overhead.
- No multi-primary: only one writer at a time.
- Replicas may lag by ~100ms; design for eventual consistency.

---

## Multi-Region Postgres with Read Replicas

### Create Primary + Replicas

```bash
# Create primary cluster in US East
fly postgres create --name my-db --region iad --vm-size shared-cpu-2x --volume-size 20

# Add read replicas in other regions
fly postgres create --name my-db-cdg --region cdg --vm-size shared-cpu-1x --volume-size 10 \
  --replicaof my-db
fly postgres create --name my-db-nrt --region nrt --vm-size shared-cpu-1x --volume-size 10 \
  --replicaof my-db
```

### Connection Routing

```python
import os

PRIMARY_REGION = os.environ.get("PRIMARY_REGION", "iad")
FLY_REGION = os.environ.get("FLY_REGION", "iad")

# Read replica URL pattern: use .internal DNS
# Primary: my-db.internal:5432
# Replicas: my-db-cdg.internal:5432, my-db-nrt.internal:5432

def get_db_url(write=False):
    if write or FLY_REGION == PRIMARY_REGION:
        return os.environ["DATABASE_URL"]  # Always points to primary
    # Use region-local replica for reads
    replica_app = f"my-db-{FLY_REGION}"
    return f"postgres://postgres:password@{replica_app}.internal:5432/mydb"
```

### Failover

Fly Postgres uses `stolon` for automatic failover. If primary dies:
1. Stolon detects failure within 30s.
2. A replica is promoted to primary.
3. `.internal` DNS updates automatically.
4. Application reconnections route to new primary.

Manual failover: `fly postgres failover -a my-db`.

---

## Fly.io Extensions

### Sentry (Error Tracking)

```bash
fly ext sentry create              # Provisions Sentry project, sets SENTRY_DSN
```

Use the `SENTRY_DSN` env var in your app's Sentry SDK initialization. No additional config needed.

### Upstash Redis

```bash
fly redis create --name my-redis --region iad --plan free
fly redis status my-redis
```

Sets `REDIS_URL`. Use any Redis client library. Plans: `free` (256MB, single-region), `pay-as-you-go`.

### Upstash Kafka

```bash
fly ext kafka create
```

### Supabase (Postgres)

Fly Postgres is now powered by Supabase. `fly postgres create` automatically provisions via Supabase.

---

## Process Groups

Run multiple processes from one codebase in the same app. Each group gets its own set of Machines.

```toml
[processes]
  web = "bin/rails server -b 0.0.0.0 -p 8080"
  worker = "bundle exec sidekiq -q default -q mailers"
  cron = "bundle exec clockwork clock.rb"

[http_service]
  internal_port = 8080
  processes = ["web"]           # Only web gets HTTP traffic

[[services]]
  internal_port = 9394
  processes = ["worker"]        # Prometheus metrics for worker
  protocol = "tcp"
  [[services.ports]]
    port = 9394

# Scale independently
# fly scale count web=3 worker=2 cron=1
```

### Process Group Best Practices
- Workers don't need `[http_service]`; they connect to queues/databases directly.
- Each group can have different VM sizes: `fly scale vm shared-cpu-2x --process-group worker`.
- Health checks per group via `[checks]` with `processes = ["worker"]`.
- Shared secrets across all groups. Use `[env]` or conditional logic if groups need different env vars.

---

## Statics Serving

Serve static files directly from Fly Proxy without hitting your app.

```toml
[[statics]]
  guest_path = "/app/public"
  url_prefix = "/static"

[[statics]]
  guest_path = "/app/assets"
  url_prefix = "/assets"
```

- Files are served with aggressive caching headers.
- Reduces load on application Machines.
- Works with any framework that builds static assets to a known directory.
- Does NOT support directory listing or SPA fallback — use your app for that.

---

## Fly Proxy Headers

Headers injected by Fly Proxy on every request:

| Header | Value | Use Case |
|--------|-------|----------|
| `Fly-Client-IP` | Client's real IP address | Rate limiting, geolocation, logging |
| `Fly-Region` | Region serving the request (e.g., `iad`) | Routing decisions, logging |
| `Fly-Request-Id` | Unique request UUID | Distributed tracing |
| `Fly-Forwarded-Port` | Original port (80/443) | Protocol detection |
| `Fly-Prefer-Region` | Client-set region hint | Sticky sessions to region |
| `Fly-Replay` | Response header for request replay | Write forwarding, instance routing |
| `Fly-Replay-Src` | Source region/instance of replayed request | Debugging replay chains |
| `Via` | `1.1 fly.io` or `2 fly.io` | Proxy detection |

### Using Fly-Replay in Responses

```python
# Forward writes to primary region
return Response(status=409, headers={"fly-replay": "region=iad"})

# Sticky session to specific machine
return Response(status=409, headers={"fly-replay": f"instance={machine_id}"})

# Route to different app
return Response(status=409, headers={"fly-replay": "app=my-api,region=iad"})

# Pass state through replay
return Response(status=409, headers={"fly-replay": "region=iad;state=retry-count:1"})
```

---

## Custom Metrics with Prometheus

### Expose Metrics Endpoint

```toml
# fly.toml
[metrics]
  port = 9091
  path = "/metrics"
```

### Application-Side Setup (Python example)

```python
from prometheus_client import Counter, Histogram, start_http_server
import os

REQUEST_COUNT = Counter("http_requests_total", "Total requests", ["method", "path", "status"])
REQUEST_LATENCY = Histogram("http_request_duration_seconds", "Request latency", ["path"])
REGION = os.environ.get("FLY_REGION", "unknown")

start_http_server(9091)  # Separate port from app

@app.after_request
def track_metrics(response):
    REQUEST_COUNT.labels(
        method=request.method,
        path=request.path,
        status=response.status_code
    ).inc()
    return response
```

### Accessing Metrics
- Fly scrapes your `/metrics` endpoint automatically.
- View in built-in Grafana: `fly dashboard`.
- Export to external Prometheus by exposing a `[[services]]` on the metrics port internally.
- Use `fly-autoscaler` to scale Machines based on custom Prometheus queries.

### Fly-Autoscaler Setup

```toml
# fly-autoscaler fly.toml
[env]
  FAS_APP_NAME = "my-app"
  FAS_PROMETHEUS_ADDRESS = "https://api.fly.io/prometheus/my-org"
  FAS_PROMETHEUS_TOKEN = "" # Set via secrets
  FAS_MIN_MACHINES = "1"
  FAS_MAX_MACHINES = "10"
  FAS_EXPR = "sum(rate(http_requests_total[5m])) / 100"  # 1 machine per 100 rps
```

---

## Fly.io Terraform Provider

Infrastructure-as-code for Fly.io resources.

### Setup

```hcl
terraform {
  required_providers {
    fly = {
      source  = "fly-apps/fly"
      version = "~> 0.1"
    }
  }
}

provider "fly" {
  fly_api_token = var.fly_api_token  # or FLY_API_TOKEN env var
}
```

### Resources

```hcl
resource "fly_app" "web" {
  name = "my-terraform-app"
  org  = "personal"
}

resource "fly_ip" "web_ipv4" {
  app  = fly_app.web.name
  type = "shared_v4"
}

resource "fly_ip" "web_ipv6" {
  app  = fly_app.web.name
  type = "v6"
}

resource "fly_volume" "data" {
  app    = fly_app.web.name
  name   = "app_data"
  size   = 10
  region = "iad"
}

resource "fly_machine" "web" {
  app    = fly_app.web.name
  region = "iad"
  name   = "web-1"

  image = "registry.fly.io/my-terraform-app:latest"

  cpus     = 1
  memorymb = 256
  cputype  = "shared"

  services = [
    {
      ports = [
        { port = 80, handlers = ["http"] },
        { port = 443, handlers = ["tls", "http"] }
      ]
      internal_port = 8080
      protocol      = "tcp"
    }
  ]

  mounts = [
    {
      volume = fly_volume.data.id
      path   = "/data"
    }
  ]

  env = {
    APP_ENV = "production"
  }
}

resource "fly_cert" "web" {
  app      = fly_app.web.name
  hostname = "myapp.example.com"
}
```

### Terraform Best Practices for Fly.io
- Use `terraform import` to bring existing apps under management.
- Store state in remote backend (S3/Tigris, Terraform Cloud).
- Use `count` or `for_each` for multi-region Machine creation.
- Combine with GitHub Actions for GitOps workflow.
- The Fly Terraform provider may lag behind API features; check provider docs for supported resources.
