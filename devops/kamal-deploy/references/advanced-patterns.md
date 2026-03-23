# Advanced Kamal 2 Deployment Patterns

## Table of Contents

- [Blue-Green Deployments](#blue-green-deployments)
- [Canary Deployments with kamal-proxy](#canary-deployments-with-kamal-proxy)
- [Multi-App Setups](#multi-app-setups)
- [Custom Health Check Endpoints](#custom-health-check-endpoints)
- [Rolling Restarts](#rolling-restarts)
- [Accessory Dependencies](#accessory-dependencies)
- [Deploy Hooks for Database Migrations](#deploy-hooks-for-database-migrations)
- [Zero-Downtime SSL Rotation](#zero-downtime-ssl-rotation)
- [Custom Dockerfile Strategies](#custom-dockerfile-strategies)
- [Multi-Architecture Builds](#multi-architecture-builds)

---

## Blue-Green Deployments

Kamal 2 implements blue-green natively. Every deploy creates a new container (green) alongside
the running one (blue). kamal-proxy health-checks the green container and only switches traffic
after it passes.

### How It Works Internally

1. `kamal deploy` builds and pushes a new image tagged with the git SHA.
2. On each server, a new container starts on the Docker network (green).
3. kamal-proxy sends health check requests to the green container's `healthcheck.path`.
4. On success: kamal-proxy atomically switches the upstream, drains existing connections
   from the blue container, then stops it.
5. On failure: the green container is removed; the blue container continues serving.

### Explicit Blue-Green with Destinations

For teams wanting full environment isolation (separate servers for blue/green):

```yaml
# config/deploy.yml (shared base)
service: myapp
image: ghcr.io/org/myapp

# config/deploy.blue.yml
servers:
  web:
    hosts: [10.0.1.10, 10.0.1.11]
proxy:
  host: blue.myapp.example.com

# config/deploy.green.yml
servers:
  web:
    hosts: [10.0.2.10, 10.0.2.11]
proxy:
  host: green.myapp.example.com
```

Deploy to green: `kamal deploy -d green`
Validate, then switch DNS or load balancer from blue → green.
Next deploy targets blue: `kamal deploy -d blue`.

### Traffic Cutover Strategies

| Strategy | Mechanism | Rollback Speed |
|---|---|---|
| Kamal native | kamal-proxy switchover | Instant (`kamal rollback`) |
| DNS-based | Update A/CNAME record | Minutes (TTL-dependent) |
| External LB | Update upstream pool | Seconds |

---

## Canary Deployments with kamal-proxy

Kamal doesn't have built-in canary percentage routing, but you can achieve canary deploys
using role-based server groups and kamal-proxy's host/path routing.

### Strategy 1: Dedicated Canary Role

```yaml
servers:
  web:
    hosts: [10.0.1.10, 10.0.1.11, 10.0.1.12]  # 3 production servers
  canary:
    hosts: [10.0.1.13]                           # 1 canary server
proxy:
  host: myapp.example.com
  app_port: 3000
```

Place all servers behind a load balancer. The canary server receives ~25% of traffic.
Deploy canary first, monitor, then deploy to web role:

```bash
kamal deploy --roles=canary     # Deploy to canary only
# Monitor logs and metrics for 15-30 minutes
kamal app logs --roles=canary -f
# If healthy, deploy to all
kamal deploy
```

### Strategy 2: Path-Based Canary

Route specific paths to a canary deployment:

```yaml
# Canary app (separate deploy.yml or destination)
service: myapp-canary
proxy:
  host: myapp.example.com
  path_prefix: /api/v2          # Only v2 API hits canary
  app_port: 3000
```

### Strategy 3: Subdomain Canary

```yaml
# Main app
proxy:
  host: myapp.example.com

# Canary (separate service or destination)
proxy:
  host: canary.myapp.example.com
```

Internal testers point to `canary.myapp.example.com` for validation.

---

## Multi-App Setups

kamal-proxy routes by Host header, enabling multiple apps on the same servers.

### Shared Server Configuration

```yaml
# App 1: config/deploy.yml
service: frontend
image: ghcr.io/org/frontend
servers:
  web:
    hosts: [10.0.1.10]
proxy:
  host: www.example.com
  app_port: 3000

# App 2: separate repo or separate deploy config
service: api
image: ghcr.io/org/api
servers:
  web:
    hosts: [10.0.1.10]         # Same server
proxy:
  host: api.example.com        # Different hostname
  app_port: 4000
```

### Path-Based Routing on Same Host

```yaml
# Frontend
service: frontend
proxy:
  host: example.com
  app_port: 3000

# API (must be a separate Kamal service)
service: api
proxy:
  host: example.com
  path_prefix: /api
  app_port: 4000
```

### Key Rules for Multi-App

- Each app must have a unique `service` name.
- Each app gets its own Docker container and network namespace.
- kamal-proxy handles TLS termination for all apps sharing a server.
- SSL certs are per-hostname; shared hosts share certs automatically.
- Deploy each app independently — they share only kamal-proxy.

---

## Custom Health Check Endpoints

### Framework-Specific Health Routes

```yaml
proxy:
  healthcheck:
    path: /up              # Rails 7.1+ built-in
    interval: 3
    timeout: 30
```

For custom health checks that verify dependencies:

```ruby
# Rails: config/routes.rb
get "/up", to: proc { |_env|
  ActiveRecord::Base.connection.execute("SELECT 1")
  Redis.current.ping
  [200, {}, ["OK"]]
rescue => e
  [503, {}, [e.message]]
}
```

```javascript
// Node/Express
app.get('/up', async (req, res) => {
  try {
    await db.query('SELECT 1');
    await redis.ping();
    res.status(200).send('OK');
  } catch (e) {
    res.status(503).send(e.message);
  }
});
```

### Health Check Tuning

| Scenario | interval | timeout | Notes |
|---|---|---|---|
| Fast-booting app | 1 | 10 | Node, Go |
| Rails with asset compilation | 3 | 60 | Needs warm-up time |
| Heavy migration on boot | 5 | 120 | DB setup during boot |
| Minimal (just process check) | 1 | 5 | Lightweight `/up` |

**Warning**: Health check timeout is the *total* time Kamal waits, not per-request.
If your app takes 45s to boot, set `timeout: 60` minimum.

### Avoiding Common Health Check Pitfalls

- Don't check external services (third-party APIs) in health checks — they cause false negatives.
- Don't redirect `/up` (e.g., `force_ssl` in Rails redirects HTTP → HTTPS). Exclude it:
  ```ruby
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
  ```
- Return 200 status code only — kamal-proxy treats anything else as unhealthy.

---

## Rolling Restarts

Kamal deploys to all servers in a role concurrently by default. For rolling restarts
(one server at a time), use the `drain_timeout` and deploy in batches.

### Manual Rolling Restart

```bash
# Restart servers one at a time
for host in 10.0.1.10 10.0.1.11 10.0.1.12; do
  echo "Restarting on $host..."
  kamal app boot --hosts=$host
  sleep 30  # Wait for health check + stabilization
done
```

### Rolling Proxy Restarts

```bash
kamal proxy reboot --rolling    # Restart kamal-proxy one server at a time
```

### Boot Strategy

Kamal 2's deploy sequence per server:
1. Pull new image
2. Start new container
3. Health check (configurable interval/timeout)
4. Switch traffic (kamal-proxy upstream update)
5. Drain old connections (default: 30s)
6. Stop old container

This is inherently zero-downtime per server. For cluster-wide safety, combine with
CI concurrency groups to serialize deploys.

---

## Accessory Dependencies

Accessories are long-lived containers (databases, caches) that persist across deploys.

### Boot Order Management

Accessories must be running before the app boots. On first setup:

```bash
kamal accessory boot db        # Start Postgres first
kamal accessory boot redis     # Then Redis
kamal setup                    # Then deploy app
```

### Ensuring App Waits for Accessories

Use a Docker entrypoint script that waits for dependencies:

```bash
#!/bin/bash
# bin/docker-entrypoint
set -e

# Wait for Postgres
until pg_isready -h ${DATABASE_HOST:-localhost} -p 5432 -U postgres; do
  echo "Waiting for Postgres..."
  sleep 2
done

# Wait for Redis
until redis-cli -h ${REDIS_HOST:-localhost} ping 2>/dev/null; do
  echo "Waiting for Redis..."
  sleep 2
done

exec "$@"
```

```dockerfile
ENTRYPOINT ["./bin/docker-entrypoint"]
CMD ["./bin/rails", "server"]
```

### Accessory on Multiple Hosts (Role-Based)

```yaml
accessories:
  redis:
    image: redis:7-alpine
    roles: [web]               # Deploys one Redis per web host
    port: "6379:6379"
    volumes: ["redis_data:/data"]
```

### Shared Accessory for Multiple Apps

```yaml
accessories:
  postgres:
    image: postgres:16-alpine
    host: 10.0.1.50            # Dedicated DB server
    port: "5432:5432"
    env:
      clear:
        POSTGRES_DB: shared_db
      secret: [POSTGRES_PASSWORD]
    volumes: ["pg_data:/var/lib/postgresql/data"]
    options:
      shm-size: 512m
      memory: 4g
      cpus: "2.0"
```

---

## Deploy Hooks for Database Migrations

### Pre-Deploy Migration Hook

Place at `.kamal/hooks/pre-deploy`:

```bash
#!/bin/bash
set -e

echo "Running database migrations for version $KAMAL_VERSION..."

# Run migrations on primary host only to avoid race conditions
kamal app exec --primary \
  --version="$KAMAL_VERSION" \
  "bin/rails db:prepare"

echo "Migrations complete."
```

### Post-Deploy Notification Hook

Place at `.kamal/hooks/post-deploy`:

```bash
#!/bin/bash
set -e

DEPLOY_TIME=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Slack notification
curl -s -X POST "$SLACK_WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "{
    \"text\": \"✅ Deployed *${KAMAL_SERVICE_NAME}* v${KAMAL_VERSION}\",
    \"blocks\": [{
      \"type\": \"section\",
      \"text\": {
        \"type\": \"mrkdwn\",
        \"text\": \"*Deploy Complete*\n• Service: ${KAMAL_SERVICE_NAME}\n• Version: ${KAMAL_VERSION}\n• Hosts: ${KAMAL_HOSTS}\n• Time: ${DEPLOY_TIME}\"
      }
    }]
  }"
```

### Available Hook Points

| Hook | When | Use Case |
|---|---|---|
| `pre-connect` | Before SSH connections | VPN setup, bastion auth |
| `pre-build` | Before Docker build | Asset compilation, code generation |
| `pre-deploy` | Before container swap | DB migrations, cache warming |
| `post-deploy` | After successful deploy | Notifications, cleanup, smoke tests |
| `pre-proxy-reboot` | Before proxy restart | Drain external LB |
| `post-proxy-reboot` | After proxy restart | Re-register with LB |

### Safe Migration Patterns

**Non-Destructive Migrations (Expand-Contract)**:
1. Deploy 1: Add new column (expand) — old code ignores it
2. Deploy 2: Code writes to both old and new columns
3. Deploy 3: Backfill data, switch reads to new column
4. Deploy 4: Remove old column (contract)

This ensures every deploy is backward-compatible with the previous version.

---

## Zero-Downtime SSL Rotation

### Let's Encrypt (Automatic)

With `ssl: true`, kamal-proxy handles renewal automatically. No action needed.

```yaml
proxy:
  ssl: true
  host: myapp.example.com
```

kamal-proxy uses ACME HTTP-01 challenge. Renewal happens ~30 days before expiry.

### Custom Certificates

For corporate/wildcard certs, store PEM content in secrets:

```yaml
# .kamal/secrets
CERTIFICATE_PEM=$(cat /path/to/cert.pem)
PRIVATE_KEY_PEM=$(cat /path/to/key.pem)
```

```yaml
# config/deploy.yml
proxy:
  host: myapp.example.com
  ssl: true
  ssl_certificate_path: /etc/kamal-proxy/ssl
  # Or inline via secrets:
  # certificate_pem: CERTIFICATE_PEM
  # private_key_pem: PRIVATE_KEY_PEM
```

### Rotating Custom Certs Without Downtime

1. Update cert files in `.kamal/secrets`
2. Run `kamal proxy reboot --rolling` — restarts proxy one server at a time
3. Verify: `echo | openssl s_client -connect myapp.example.com:443 2>/dev/null | openssl x509 -noout -dates`

---

## Custom Dockerfile Strategies

### Multi-Stage Build (Rails)

```dockerfile
# Stage 1: Build
FROM ruby:3.3-slim AS build
RUN apt-get update -qq && apt-get install -y build-essential libpq-dev node-gyp
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local deployment true && \
    bundle config set --local without "development test" && \
    bundle install --jobs 4
COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

# Stage 2: Runtime
FROM ruby:3.3-slim
RUN apt-get update -qq && apt-get install -y libpq5 curl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app /app
COPY --from=build /usr/local/bundle /usr/local/bundle
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
```

### Multi-Stage Build (Node.js)

```dockerfile
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production && cp -R node_modules /tmp/node_modules
RUN npm ci
COPY . .
RUN npm run build

FROM node:20-alpine
RUN apk add --no-cache curl
WORKDIR /app
COPY --from=build /tmp/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/package.json .
EXPOSE 3000
USER node
CMD ["node", "dist/server.js"]
```

### Dockerfile with Build Secrets

```dockerfile
# syntax=docker/dockerfile:1
FROM ruby:3.3-slim AS build
RUN --mount=type=secret,id=BUNDLE_ENTERPRISE__CONTRIBSYS__COM \
    BUNDLE_ENTERPRISE__CONTRIBSYS__COM=$(cat /run/secrets/BUNDLE_ENTERPRISE__CONTRIBSYS__COM) \
    bundle install
```

```yaml
# deploy.yml
builder:
  secrets:
    - BUNDLE_ENTERPRISE__CONTRIBSYS__COM
```

---

## Multi-Architecture Builds

### Building for amd64 from Apple Silicon (arm64)

```yaml
builder:
  arch:
    - amd64                    # Target server architecture
```

Kamal uses Docker buildx with QEMU emulation. Slower but works anywhere.

### Native Multi-Arch with Remote Builder

```yaml
builder:
  arch:
    - amd64
    - arm64
  remote:
    arch: amd64
    host: ssh://builder@amd64-build-server
  local:
    arch: arm64                # Build arm64 locally (native on Apple Silicon)
```

### Dedicated Remote Builder

```yaml
builder:
  remote:
    arch: amd64
    host: ssh://builder@ci-builder.internal
  cache:
    type: registry
    image: ghcr.io/org/myapp-build-cache
```

### Build Arguments

```yaml
builder:
  args:
    RUBY_VERSION: "3.3.0"
    NODE_VERSION: "20"
    BUNDLER_VERSION: "2.5.0"
  dockerfile: Dockerfile.production   # Custom Dockerfile path
  context: .
```

### Build Cache Optimization

```yaml
builder:
  cache:
    type: registry
    image: ghcr.io/org/myapp-build-cache
    options: mode=max           # Cache all layers, not just final
```

Registry-based caching persists across CI runs, dramatically speeding up builds.
