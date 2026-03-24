---
name: fly-io-deploy
description: >
  Deploy, configure, and operate applications on Fly.io platform using flyctl CLI, fly.toml, and Machines API.
  TRIGGER when: user mentions Fly.io, flyctl, fly.toml, fly deploy, fly launch, fly scale, fly secrets,
  Fly Machines, Fly Volumes, fly-replay, .internal DNS, Fly Postgres, Tigris storage, LiteFS, or deploying
  to Fly.io edge infrastructure. Also trigger for multi-region deployment on Fly, Fly.io autoscaling,
  Fly GPU machines, or Fly.io CI/CD pipelines.
  DO NOT TRIGGER when: deploying with Kamal, Caddy server config, AWS/GCP/Azure/Heroku/Railway/Render
  deployment, generic Docker without Fly context, or Kubernetes orchestration.
---

# Fly.io Deployment Skill

## Architecture

Fly.io runs apps as Firecracker microVMs called **Machines** on bare-metal servers worldwide. Key concepts:

- **Machines**: Individual Firecracker microVMs. Each runs one process from a Docker image. Start in ~300ms.
- **Fly Apps**: Logical grouping of Machines under one app name. Managed via `fly.toml`.
- **Regions**: 30+ regions globally (e.g., `iad` Virginia, `cdg` Paris, `nrt` Tokyo, `gru` São Paulo). Set `primary_region` in `fly.toml`.
- **Anycast**: Every app gets a shared global Anycast IP. Requests route to the nearest healthy Machine automatically.
- **WireGuard mesh**: All Machines in an org communicate over encrypted private WireGuard tunnels. Access via `<app>.internal` DNS.
- **Fly Proxy**: Edge proxy handles TLS termination, load balancing, auto-stop/start, and `fly-replay` routing.

## flyctl CLI

Install:
```sh
curl -L https://fly.io/install.sh | sh
# or: brew install flyctl
```

### Core commands:
```sh
fly auth login                    # Authenticate
fly launch                        # Initialize app, generate fly.toml, select region
fly deploy                        # Build and deploy (local Docker build)
fly deploy --remote-only          # Build on Fly's remote builders
fly deploy --image ghcr.io/org/app:v1  # Deploy pre-built image
fly status                        # Show app status, Machines, allocations
fly logs                          # Stream live logs
fly ssh console                   # SSH into a running Machine
fly ssh console -s -C "bin/rails console"  # Run command via SSH, select Machine
fly secrets set DATABASE_URL=postgres://...  # Set encrypted secret
fly secrets list                  # List secret names (not values)
fly secrets unset SECRET_NAME     # Remove a secret
fly scale count 3                 # Scale to 3 Machines
fly scale count 3 --region iad    # Scale to 3 in specific region
fly scale vm shared-cpu-2x        # Change VM size
fly scale show                    # Show current VM size and count
fly apps list                     # List all apps in org
fly apps destroy app-name         # Delete app and all Machines
fly regions list                  # List available regions
fly ips list                      # List allocated IPs
fly ips allocate-v6               # Allocate shared IPv6
fly ips allocate-v4 --shared      # Allocate shared IPv4
fly certs add example.com         # Add custom domain + auto TLS
fly certs show example.com        # Check certificate status
fly proxy 5432:5432               # Proxy local port to Machine port
```

## fly.toml Configuration

### Minimal web app:
```toml
app = "my-app"
primary_region = "iad"

[build]
  dockerfile = "Dockerfile"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 1

  [http_service.concurrency]
    type = "requests"
    soft_limit = 200
    hard_limit = 250

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"
```

### Key fly.toml sections:
- **`[build]`**: Dockerfile path, build args, or `image` for pre-built. `[build.args]` for build-time ARGs.
- **`[http_service]`**: Public HTTP/HTTPS. Set `internal_port`, `concurrency`, `auto_stop_machines`, `auto_start_machines`, `min_machines_running`. Add `[[http_service.checks]]` for health checks.
- **`[[services]]`**: Non-HTTP TCP/UDP services with port mappings and handlers.
- **`[mounts]`**: Attach Fly Volume (`source` = volume name, `destination` = mount path).
- **`[deploy]`**: `release_command` (runs once before deploy, e.g., migrations), `strategy` (rolling/immediate/canary/bluegreen).
- **`[env]`**: Non-secret environment variables. **`[metrics]`**: Prometheus endpoint (`port`, `path`).
- **`[[vm]]`**: VM size and memory. **`[[statics]]`**: Serve static files from proxy directly.
- **`[processes]`**: Multiple process groups from one app. **`[checks]`**: Machine-level checks.

### Process groups:
```toml
[processes]
  web = "bin/rails server -b 0.0.0.0 -p 8080"
  worker = "bin/sidekiq"

[http_service]
  internal_port = 8080
  processes = ["web"]
```

## Machines API

Base URL: `https://api.machines.dev/v1`. Authenticate with `Authorization: Bearer <fly-api-token>`.

```sh
# List machines
curl -s -H "Authorization: Bearer $FLY_API_TOKEN" \
  https://api.machines.dev/v1/apps/my-app/machines

# Create a machine
curl -X POST -H "Authorization: Bearer $FLY_API_TOKEN" \
  -H "Content-Type: application/json" \
  https://api.machines.dev/v1/apps/my-app/machines \
  -d '{
    "region": "iad",
    "config": {
      "image": "registry.fly.io/my-app:latest",
      "guest": {"cpu_kind": "shared", "cpus": 1, "memory_mb": 256},
      "services": [{"ports": [{"port": 443, "handlers": ["tls","http"]}], "internal_port": 8080, "protocol": "tcp"}]
    }
  }'

# Stop/Start/Destroy
curl -X POST .../machines/{id}/stop
curl -X POST .../machines/{id}/start
curl -X DELETE .../machines/{id}
```

Use the Machines API for: custom orchestration, GPU machine provisioning, programmatic scaling, CI/CD beyond `flyctl`, integration with external autoscalers.

## Deployment Strategies

Set in `fly.toml` under `[deploy]`:

| Strategy | Behavior |
|----------|----------|
| `rolling` (default) | Replace Machines one at a time. Zero-downtime. |
| `immediate` | Replace all at once. Brief downtime. Fastest. |
| `canary` | Deploy one Machine first, health-check, then roll out rest. |
| `bluegreen` | Stand up full parallel set, switch traffic, tear down old. |

```toml
[deploy]
  strategy = "canary"
  release_command = "bin/rails db:migrate"
  wait_timeout = "5m"
```

`release_command` runs in a temporary Machine before deployment proceeds. Use for migrations.

## Scaling

### Horizontal (more Machines):
```sh
fly scale count 5                          # 5 total Machines
fly scale count web=3 worker=2             # Per process group
fly scale count 2 --region iad --region cdg  # 2 per region
```

### Vertical (bigger Machines):
```sh
fly scale vm shared-cpu-1x                 # Shared vCPU, cheapest
fly scale vm shared-cpu-2x --memory 1024   # 2x shared, 1GB RAM
fly scale vm performance-1x               # Dedicated vCPU
fly scale vm performance-4x --memory 8192  # 4 dedicated vCPUs, 8GB
fly scale vm a100-40gb                     # GPU machine
```

VM sizes: `shared-cpu-1x` (256MB), `shared-cpu-2x` (512MB), `shared-cpu-4x` (1GB), `performance-1x` (2GB), `performance-2x` (4GB), `performance-4x` (8GB), `performance-8x` (16GB), `a100-40gb`, `a100-80gb`, `l40s`.

### Autoscaling (proxy-based):
Configure in `fly.toml`:
```toml
[http_service]
  auto_stop_machines = "stop"     # "stop", "suspend", or false
  auto_start_machines = true
  min_machines_running = 1        # Keep at least 1 warm. Set 0 for scale-to-zero.
  [http_service.concurrency]
    type = "requests"             # or "connections"
    soft_limit = 200
    hard_limit = 250
```

### Metrics-based autoscaling:
Use `fly-autoscaler` (open-source) for queue-depth, job-latency, or custom-metric scaling. Deploy it as a separate Fly app that watches your Prometheus metrics and adjusts Machine count via the Machines API.

## Volumes and Persistent Storage

Volumes are NVMe-backed block storage attached to a single Machine in a single region.

```sh
fly volumes create data --size 10 --region iad   # 10GB volume in iad
fly volumes list                                  # List volumes
fly volumes extend vol_abc123 --size 20           # Grow to 20GB (no shrink)
fly volumes snapshots list vol_abc123             # List snapshots
fly volumes fork vol_abc123 --region cdg          # Clone to another region
fly volumes destroy vol_abc123                    # Delete volume
```

Mount in `fly.toml`:
```toml
[mounts]
  source = "data"
  destination = "/data"
```

Rules:
- One volume per Machine. Scale count = scale volumes.
- Volumes are NOT shared across Machines. Each gets its own.
- Volumes are region-locked. Multi-region = replicate at app layer.
- Automatic daily snapshots retained for 5 days. NOT a backup strategy—use external backups.
- Volumes survive deploys and restarts. Destroyed only explicitly.

## Databases and Storage Services

### Fly Postgres (managed by Supabase):
```sh
fly postgres create --name my-db --region iad
fly postgres attach my-db -a my-app    # Sets DATABASE_URL secret
fly postgres connect -a my-db          # Interactive psql
fly postgres db list -a my-db
```
Supports HA with automatic failover, read replicas, and PostGIS/pgvector.

### Tigris Object Storage (S3-compatible):
```sh
fly storage create                     # Create bucket, sets AWS_* env vars
fly storage list                       # List buckets
fly storage dashboard                  # Open Tigris dashboard
```
No egress fees. Use any S3-compatible SDK. Globally distributed.

### LiteFS (distributed SQLite):
Mount LiteFS as a FUSE filesystem. Primary node handles writes; replicas get async replication.
```toml
# litefs.yml
fuse:
  dir: "/litefs"
data:
  dir: "/data/litefs"
proxy:
  addr: ":8080"
  target: "localhost:8081"
  db: "db.sqlite3"
  passthrough:
    - "*.css"
    - "*.js"
lease:
  type: "consul"
  candidate: ${FLY_REGION == PRIMARY_REGION}
```

### Upstash Redis:
```sh
fly redis create                       # Provision Redis, sets REDIS_URL
fly redis list
fly redis status my-redis
```

## Secrets Management

Secrets are encrypted, injected as environment variables at runtime. Never in `fly.toml`.

```sh
fly secrets set DATABASE_URL="postgres://..." SECRET_KEY_BASE="abc123"
fly secrets list               # Shows names and digest, never values
fly secrets unset OLD_SECRET
```

Setting secrets triggers a rolling restart. Use `--stage` to defer restart:
```sh
fly secrets set KEY1=val1 --stage
fly secrets set KEY2=val2 --stage
fly deploy                     # Apply staged secrets with next deploy
```

## Custom Domains and Certificates

```sh
fly certs add myapp.example.com
fly certs show myapp.example.com
fly certs list
fly certs remove myapp.example.com
```

Then set DNS: CNAME `myapp.example.com` → `my-app.fly.dev`. Fly auto-provisions and renews Let's Encrypt TLS certificates.

For apex domains, use A/AAAA records pointing to your app's dedicated IPs (`fly ips list`).

## Private Networking

All Machines in an org share a private WireGuard mesh network.

- **Internal DNS**: `<app>.internal` resolves to all Machines for that app. `top1.nearest.of.<app>.internal` resolves to the closest Machine.
- **Direct Machine access**: `<machine-id>.vm.<app>.internal`.
- **Service discovery**: Apps find each other via `.internal` hostnames. No public exposure needed for internal services.
- **Fly Proxy on 6PN**: Internal requests on the private network bypass the public proxy. Use port directly.

```sh
# From inside a Machine:
dig aaaa my-db.internal           # Find Postgres Machines
curl http://my-api.internal:8080  # Call internal service
```

### fly-replay header:
Route requests dynamically at the proxy layer:
```
fly-replay: region=iad                    # Replay to specific region
fly-replay: instance=abc123def            # Replay to specific Machine
fly-replay: app=my-other-app              # Replay to different app
fly-replay: region=iad;state=mydata       # Pass state with replay
```

## Multi-Region Patterns

### Read replicas with write forwarding:
```python
# Pseudocode: detect write on replica, replay to primary
@app.before_request
def replay_writes():
    if request.method in ("POST", "PUT", "PATCH", "DELETE"):
        if os.environ["FLY_REGION"] != os.environ["PRIMARY_REGION"]:
            return "", 409, {"fly-replay": f"region={os.environ['PRIMARY_REGION']}"}
```

### Scaling across regions:
```sh
fly scale count 2 --region iad
fly scale count 2 --region cdg
fly scale count 2 --region nrt
```

### Region-aware request header:
Fly injects `Fly-Region` (Machine's region) and `Fly-Client-IP` headers. Use `Fly-Prefer-Region` to hint routing.

## Dockerfile Patterns for Fly

### Multi-stage build example (Node.js):
```dockerfile
FROM node:20-slim AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --production=false
COPY . .
RUN npm run build

FROM node:20-slim
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY package*.json ./
EXPOSE 8080
CMD ["node", "dist/server.js"]
```

Key patterns: use multi-stage builds to minimize image size. Always `EXPOSE` the port matching `internal_port`. For Rails/Python, install runtime deps only in final stage. Always expose a `/health` endpoint and configure checks in `fly.toml`.

## CI/CD with GitHub Actions

### Generate deploy token:
```sh
fly tokens create deploy -x 999999h
# Add as FLY_API_TOKEN in GitHub repo Settings > Secrets
```

### Workflow file (`.github/workflows/fly-deploy.yml`):
```yaml
name: Fly Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    concurrency: deploy-group
    steps:
      - uses: actions/checkout@v4
      - uses: superfly/flyctl-actions/setup-flyctl@master
      - run: flyctl deploy --remote-only
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

For multi-env, use separate `fly.production.toml` / `fly.staging.toml` and select via `--config` flag based on branch.

## Monitoring

```sh
fly status                    # Machine states, IPs, regions
fly logs                      # Stream logs (--region iad to filter)
fly machine status <id>       # Single Machine details
fly checks list               # Health check status
fly dashboard                 # Opens Grafana dashboard with metrics
```

Expose Prometheus metrics in `fly.toml` via `[metrics]` section (`port`, `path`). Fly scrapes automatically and surfaces in built-in Grafana. Export to external Prometheus/Grafana as needed.

## Cost Optimization

- **Use `shared-cpu-1x`** for most workloads (~$2.32/mo full-time for 256MB).
- **Auto-stop idle Machines**: `auto_stop_machines = "stop"` — stopped Machines cost $0 compute (only volume storage).
- **Scale to zero**: Set `min_machines_running = 0`. Cold starts are ~300ms–2s.
- **Use `suspend` over `stop`**: `auto_stop_machines = "suspend"` preserves RAM state, ~50ms wake.
- **Right-size VMs**: Start with `shared-cpu-1x`, monitor, scale up only if needed.
- **Shared IPv4**: Use `fly ips allocate-v4 --shared` (free) instead of dedicated v4 ($2/mo).
- **Process groups**: Run web + worker in one app instead of separate apps.
- **`--stage` secrets**: Batch secret changes to avoid multiple restarts.

## Common Pitfalls

1. **Ephemeral filesystem**: Root filesystem resets on every deploy. Always use Volumes for persistent data.
2. **Volume-Machine affinity**: Volumes attach to ONE Machine. Scaling count without provisioning volumes = crash.
3. **Release command failures**: A failing `release_command` blocks the entire deployment. Test migrations locally first.
4. **Port mismatch**: `internal_port` in `fly.toml` MUST match what your app listens on. Mismatch = health check failures.
5. **Health check too aggressive**: Set `grace_period` long enough for app startup. Default may be too short for Rails/JVM apps.
6. **Secrets trigger restart**: `fly secrets set` restarts all Machines. Use `--stage` to batch.
7. **Region-locked volumes**: Cannot move a volume between regions. Use `fly volumes fork` to clone.
8. **No cross-Machine volume sharing**: For shared filesystem needs, use Tigris object storage instead.
9. **DNS propagation for certs**: `fly certs add` needs DNS to resolve before certificate provisioning succeeds.
10. **Memory limits**: OOM-killed Machines restart silently. Check `fly logs` for exit code 137.

## Examples

### Deploy a Node.js app:
```
1. fly launch --name my-node-app --region iad --no-deploy
2. Edit fly.toml: set internal_port to match your app
3. fly deploy && fly status && fly logs
```

### Rails app with Postgres:
```
1. fly launch --name my-rails-app --region iad
2. fly postgres create --name my-rails-db --region iad
3. fly postgres attach my-rails-db -a my-rails-app
4. Add to fly.toml: [deploy] release_command = "bin/rails db:migrate"
5. fly deploy
```

### Scale across 3 regions:
```
fly scale count 2 --region iad && fly scale count 2 --region cdg && fly scale count 2 --region nrt
```

### Set up CI/CD:
```
1. fly tokens create deploy -x 999999h → add as FLY_API_TOKEN in GitHub Secrets
2. Copy assets/github-actions-deploy.yml to .github/workflows/
```

## Additional Resources

### Reference Guides (`references/`)

| File | Topics |
|------|--------|
| `references/advanced-patterns.md` | Machines API deep dive (create, update, exec, wait, cordon), Fly Launch vs Machines comparison, GPU machines, Tigris object storage, LiteFS distributed SQLite, multi-region Postgres with read replicas, extensions (Sentry, Upstash), process groups, statics, Fly Proxy headers, Prometheus custom metrics, Terraform provider |
| `references/troubleshooting.md` | Deployment failures, health check timeouts, machine not starting, volume attachment errors, DNS resolution in private networking, certificate provisioning delays, cross-region connection timeouts, OOM kills, disk space exhaustion, Postgres failover, slow cold starts, deploy rollback, WireGuard tunnel issues, billing surprises |
| `references/multi-region-guide.md` | Anycast routing behavior, region selection strategies, read replicas with fly-replay, write forwarding patterns, regional routing strategies, data locality, edge caching, CDN integration, latency-based routing, cross-region Postgres replication, LiteFS SQLite replication, cost considerations per region |

### Executable Scripts (`scripts/`)

| Script | Purpose | Usage |
|--------|---------|-------|
| `scripts/fly-init.sh` | Initialize Fly app: detect framework, generate fly.toml + Dockerfile + .dockerignore, configure health checks | `./scripts/fly-init.sh <app-name> [framework]` |
| `scripts/fly-scale.sh` | Scale machines across regions: scale-up, scale-down, add-region, remove-region, status | `./scripts/fly-scale.sh <action> -a <app> -r <region> -c <count>` |
| `scripts/fly-db-setup.sh` | Set up Postgres cluster with optional HA and read replicas | `./scripts/fly-db-setup.sh <db-name> <region> [replicas...] --attach <app>` |

### Template Assets (`assets/`)

| File | Description |
|------|-------------|
| `assets/fly.toml` | Production fly.toml with HTTP service, health checks, auto-stop, mounts, process groups, metrics, statics, canary deploy strategy |
| `assets/Dockerfile` | Multi-stage Dockerfile with non-root user, health check, dumb-init signal handling, layer caching |
| `assets/docker-compose.yml` | Local dev environment with Postgres + Redis mimicking Fly services and env vars |
| `assets/github-actions-deploy.yml` | GitHub Actions workflow with staging (on push) and production (on release) deploy pipelines |
| `assets/litefs.yml` | LiteFS config for distributed SQLite: FUSE mount, proxy, Consul lease, write forwarding |
