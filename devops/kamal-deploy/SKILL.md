---
name: kamal-deploy
description: >
  Generate Kamal 2.x deploy.yml configs, kamal-proxy setup, zero-downtime Docker
  deploys, accessories, secrets, hooks, and CI/CD pipelines for bare-metal/VPS.
  TRIGGER when user mentions Kamal, kamal-proxy, deploy.yml for Docker, MRSK,
  zero-downtime container deploys, Rails 8 deployment, kamal deploy/redeploy/rollback,
  .kamal/secrets, or deploying containers without Kubernetes. DO NOT TRIGGER for
  Kubernetes/k8s, Docker Compose standalone, Helm charts, Terraform, Ansible,
  AWS ECS/Fargate, or general Docker commands unrelated to Kamal.
---

# Kamal 2.x Deployment Skill

## Architecture

Kamal deploys Docker containers to bare-metal/VPS with zero downtime. No Kubernetes. SSH + Docker + kamal-proxy.

Components: **kamal-proxy** (HTTP proxy replacing Traefik in v2 — handles traffic routing, zero-downtime switchover, connection draining, auto Let's Encrypt SSL, host-based multi-app routing), **Docker** (app runs as containers — build, push to registry, pull on servers), **SSH** (all commands via SSH, no server agent).

Deploy flow: build image → push to registry → SSH pull on each server → start new container on Docker network → kamal-proxy health-checks → on pass: switch traffic, drain old connections, stop old container → retain N old containers for rollback.

## Installation and Setup

```bash
gem install kamal            # Requires Ruby 3.1+
# Or in Gemfile: gem "kamal", "~> 2.0"
kamal init                   # Generates config/deploy.yml, Dockerfile, .kamal/secrets
kamal setup                  # First deploy: installs Docker, kamal-proxy, deploys app
```

Server requirements: Linux with SSH access, ports 80/443 open. `kamal setup` installs Docker automatically.

## deploy.yml Configuration

Place at `config/deploy.yml`. Single source of truth for deployment.

### Minimal Config

```yaml
service: myapp
image: registry.example.com/myapp
servers:
  web:
    hosts:
      - 203.0.113.10
proxy:
  ssl: true
  host: myapp.example.com
  app_port: 3000
  healthcheck:
    path: /up
    interval: 3
    timeout: 30
registry:
  username: deployer
  password:
    - KAMAL_REGISTRY_PASSWORD
env:
  clear:
    RAILS_LOG_TO_STDOUT: "true"
  secret:
    - RAILS_MASTER_KEY
    - DATABASE_URL
builder:
  arch:
    - amd64
```

### Full Reference

```yaml
service: myapp
image: ghcr.io/org/myapp
minimum_version: 2.0.0

servers:
  web:
    hosts: [203.0.113.10, 203.0.113.11]
    options:
      "add-host": host.docker.internal:host-gateway
  job:
    hosts: [203.0.113.12]
    cmd: bin/jobs
    proxy:
      roles: []                   # No proxy for workers

proxy:
  ssl: true
  host: myapp.example.com
  app_port: 3000                  # Default: 80
  healthcheck:
    path: /up
    interval: 3
    timeout: 30
  response_timeout: 30
  forward_headers: true

registry:
  server: ghcr.io
  username: deployer
  password:
    - KAMAL_REGISTRY_PASSWORD

env:
  clear:
    RAILS_ENV: production
  secret:
    - RAILS_MASTER_KEY
    - DATABASE_URL

volumes:
  - "myapp_storage:/rails/storage"

asset_path: /rails/public/assets  # Bridges assets between old/new containers

builder:
  arch: [amd64, arm64]            # Multi-arch
  remote:
    arch: amd64
    host: ssh://builder@build-server
  args:
    RUBY_VERSION: "3.3.0"
  secrets:
    - BUNDLE_ENTERPRISE__CONTRIBSYS__COM

retain_containers: 5

ssh:
  user: deploy                    # Default: root
  proxy: bastion.example.com      # Jump host

accessories:
  db:
    image: postgres:16
    host: 203.0.113.10
    port: "5432:5432"
    env:
      secret:
        - POSTGRES_PASSWORD
    volumes:
      - "db_data:/var/lib/postgresql/data"
    options:
      shm-size: 256m
  redis:
    image: redis:7
    roles: [web]
    port: "6379:6379"
    cmd: redis-server --appendonly yes
    volumes:
      - "redis_data:/data"
```

## Deployment Commands

```bash
kamal deploy                      # Full: build, push, boot, health-check, switch
kamal redeploy                    # Skip setup, faster for subsequent deploys
kamal rollback <VERSION>          # Rollback to specific version tag
kamal deploy -d staging           # Deploy to destination
kamal lock acquire -m "Deploying" # Prevent concurrent deploys
kamal lock release

kamal app details                 # Show running containers
kamal app logs -f                 # Tail logs
kamal app logs -n 200 --roles=web # Last 200 lines, web role
kamal app exec "bin/rails console"  # Run command in container
kamal app exec -i bash            # Interactive shell

kamal accessory boot db           # Start accessory
kamal accessory reboot redis      # Restart accessory
kamal accessory exec db "psql -U postgres"

kamal proxy reboot                # Restart kamal-proxy
kamal proxy details               # Proxy status
kamal proxy logs                  # Proxy logs
kamal server bootstrap            # Install Docker on new server
kamal audit                       # Show deploy audit log
kamal config                      # Print resolved config
```

## kamal-proxy (Kamal 2)

Replaced Traefik entirely. Runs as single long-lived container per server on ports 80/443.

| Traefik (v1) | kamal-proxy (v2) |
|---|---|
| Docker labels, complex | `proxy:` block in deploy.yml |
| Manual drain config | Automatic connection draining |
| Separate ACME config | `ssl: true` — done |
| Label-based routing | Host-based routing |

Multi-app: each app sets different `host:` under `proxy:`. kamal-proxy routes by Host header.

## Secrets and Environment Variables

### File structure
```
.kamal/
├── secrets              # Default secrets
├── secrets-common       # Always loaded
├── secrets.production   # Destination-specific
└── secrets.staging
```

### .kamal/secrets format
```bash
KAMAL_REGISTRY_PASSWORD=ghp_xxxxxxxxxxxx
RAILS_MASTER_KEY=$RAILS_MASTER_KEY          # From shell env
RAILS_MASTER_KEY=$(op read "op://Vault/Item/Field")  # From 1Password
DB_PASSWORD=$(aws secretsmanager get-secret-value --secret-id myapp/db --query SecretString --output text | jq -r .password)
```

**Never commit `.kamal/secrets`** — add to `.gitignore`.

### Accessory secret aliasing
```yaml
accessories:
  db:
    env:
      secret:
        - POSTGRES_PASSWORD:DB_PASSWORD   # Container var:secrets var
```

## Accessories

Long-lived support containers. NOT redeployed on `kamal deploy`.

```yaml
accessories:
  postgres:
    image: postgres:16-alpine
    host: 203.0.113.10
    port: "5432:5432"
    env:
      clear: { POSTGRES_DB: myapp_production }
      secret: [POSTGRES_PASSWORD]
    volumes: ["pg_data:/var/lib/postgresql/data"]
  redis:
    image: redis:7-alpine
    roles: [web]                  # Deploy to all hosts in role
    port: "6379:6379"
    cmd: redis-server --appendonly yes
    volumes: ["redis_data:/data"]
```

Manage: `kamal accessory boot <name>`, `reboot`, `remove`, `logs`, `exec`.

## Multi-Server and Role-Based Deploys

```yaml
servers:
  web:
    hosts: [203.0.113.10, 203.0.113.11]
  job:
    hosts: [203.0.113.20]
    cmd: bundle exec sidekiq
    proxy: { roles: [] }          # No HTTP traffic
  cron:
    hosts: [203.0.113.20]
    cmd: supercronic /app/crontab
    proxy: { roles: [] }
```

Same Docker image, different CMD per role. Only roles with proxy config get traffic.

### Destinations (multi-environment)

Create `config/deploy.staging.yml` with overrides:
```yaml
servers:
  web:
    hosts: [10.0.0.5]
proxy:
  host: staging.myapp.example.com
```
Deploy: `kamal deploy -d staging`. Merges with base deploy.yml.

## SSL/TLS with Let's Encrypt

```yaml
proxy:
  ssl: true
  host: myapp.example.com
```

Prerequisites: DNS A record pointing to server before first deploy, ports 80/443 open. kamal-proxy handles ACME challenge and auto-renewal.

Multiple domains: use `hosts: [myapp.example.com, www.myapp.example.com]`.

## Health Checks

```yaml
proxy:
  healthcheck:
    path: /up          # Must return HTTP 200
    interval: 3        # Seconds between checks
    timeout: 30        # Max wait total
```

Deploy fails if timeout expires — old container keeps serving. Rails 7.1+ has built-in `/up`. Other frameworks: create lightweight 200 route.

## Asset Bridging

Prevents 404s during deploys when containers serve different asset fingerprints.

```yaml
asset_path: /rails/public/assets
```

Kamal copies assets to shared volume, keeping old assets available during drain. Use fingerprinted filenames.

## Hooks

Place executable scripts in `.kamal/hooks/`:

```
pre-connect, pre-build, pre-deploy, post-deploy, pre-proxy-reboot, post-proxy-reboot
```

Example `.kamal/hooks/post-deploy`:
```bash
#!/bin/bash
curl -X POST "$SLACK_WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"text\": \"Deployed ${KAMAL_SERVICE_NAME} v${KAMAL_VERSION} to ${KAMAL_HOSTS}\"}"
```

Available env vars: `KAMAL_SERVICE_NAME`, `KAMAL_VERSION`, `KAMAL_HOSTS`, `KAMAL_ROLE`, `KAMAL_DESTINATION`. Make hooks executable: `chmod +x .kamal/hooks/*`.

## CI/CD Integration (GitHub Actions)

```yaml
name: Deploy
on:
  push:
    branches: [main]
concurrency:
  group: deploy-production
  cancel-in-progress: false
jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.3"
          bundler-cache: true
      - uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_DEPLOY_KEY }}
      - uses: docker/setup-buildx-action@v3
      - run: bundle exec kamal deploy
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.KAMAL_REGISTRY_PASSWORD }}
          RAILS_MASTER_KEY: ${{ secrets.RAILS_MASTER_KEY }}
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

Multi-env: use `-d staging` on main branch, `-d production` on release tags.

## Comparison

| | Kamal | Kubernetes | Docker Compose | Capistrano |
|---|---|---|---|---|
| Target | VPS/bare-metal | Orchestrator cluster | Single host | Bare-metal (no containers) |
| Complexity | Low | Very high | Low | Low |
| Zero-downtime | Built-in | Built-in | Manual | Plugin-based |
| SSL | Auto Let's Encrypt | cert-manager | Manual | N/A |
| Multi-server | Native | Native | Swarm needed | Native |
| Best for | 1-20 servers, escape PaaS | Large-scale microservices | Dev/single host | Legacy non-container |

Use Kamal when: deploying to own servers, want PaaS simplicity without PaaS cost, running Docker without Kubernetes overhead.

## Common Pitfalls

1. **Port mismatch**: Kamal 2 defaults to port 80. Set `proxy.app_port: 3000` if app listens on 3000. Symptom: health check timeout.
2. **Missing health check endpoint**: Deploys hang without valid path returning 200.
3. **DNS not set before SSL deploy**: Let's Encrypt fails. Configure DNS A records first.
4. **Secrets committed to git**: `.kamal/secrets` must be in `.gitignore`.
5. **Skipping `kamal setup`**: `kamal deploy` assumes Docker/proxy installed. Use `setup` for first deploy.
6. **Accessory unnamed volumes**: `kamal accessory remove` destroys unnamed volumes. Always use named volumes.
7. **Arch mismatch**: Building on arm64 (Apple Silicon) for amd64 servers requires `builder.arch: [amd64]`.
8. **Concurrent deploys**: Use `kamal lock` or CI concurrency groups to serialize.
9. **Old Traefik config**: `traefik:` block ignored in Kamal 2. Migrate to `proxy:`.
10. **Firewall**: Ports 80, 443, and 22 must be open.

## Examples

### "Set up Kamal for Rails 8 on DigitalOcean"

```yaml
service: myapp
image: registry.digitalocean.com/myteam/myapp
servers:
  web:
    hosts: [164.90.XXX.XXX]
    options:
      "add-host": host.docker.internal:host-gateway
proxy:
  ssl: true
  host: myapp.example.com
  app_port: 3000
  healthcheck: { path: /up, interval: 3, timeout: 30 }
registry:
  server: registry.digitalocean.com
  username:
    - KAMAL_REGISTRY_USERNAME
  password:
    - KAMAL_REGISTRY_PASSWORD
env:
  clear: { RAILS_LOG_TO_STDOUT: "true" }
  secret: [RAILS_MASTER_KEY, DATABASE_URL]
volumes: ["myapp_storage:/rails/storage"]
asset_path: /rails/public/assets
builder: { arch: [amd64] }
accessories:
  db:
    image: postgres:16-alpine
    host: 164.90.XXX.XXX
    port: "5432:5432"
    env: { secret: [POSTGRES_PASSWORD] }
    volumes: ["db_data:/var/lib/postgresql/data"]
```

Then: `kamal setup` (first time), `kamal deploy` (subsequent).

### "Rollback a bad deploy"

```bash
kamal app details              # List versions
kamal rollback abc123def       # Rollback
kamal app logs -n 50           # Verify
```

### "Add Sidekiq worker role"

```yaml
servers:
  web:
    hosts: [203.0.113.10]
  job:
    hosts: [203.0.113.10]
    cmd: bundle exec sidekiq -C config/sidekiq.yml
    proxy: { roles: [] }
```

Same image, different CMD. `kamal deploy` handles both roles.
