---
name: docker-compose-patterns
description: >
  Generate and review Docker Compose configurations for multi-container applications.
  Covers Compose V2 spec (compose.yaml), services, networks, volumes, configs, secrets,
  build context, multi-stage builds, depends_on with healthchecks, environment variables
  (.env, interpolation), profiles, extends, YAML anchors, watch mode, GPU support,
  multiple Compose files (override pattern), restart policies, resource limits, logging
  drivers, init containers, CI/CD patterns, and debugging.
  Triggers: "Docker Compose", "compose.yaml", "compose.yml", "multi-container Docker",
  "docker compose up", "docker compose build", "docker compose watch", "compose profiles",
  "compose healthcheck", "compose override".
  NOT for Kubernetes manifests, NOT for single Dockerfile without orchestration,
  NOT for Docker Swarm clustering without Compose, NOT for Podman-specific features.
---

# Docker Compose Patterns

## Core Rules

- Always use Compose V2 CLI: `docker compose` (space-separated). Never `docker-compose` (hyphenated, V1 deprecated).
- Omit the `version:` field — it is deprecated and triggers warnings.
- Prefer `compose.yaml` as the filename. `docker-compose.yml` still works but is legacy.
- Use named volumes for persistent data. Never rely on anonymous volumes in production.
- Always define healthchecks for services that other services depend on.
- Set restart policies and resource limits for every production service.
- Never hardcode secrets in compose files. Use Docker secrets, env_file, or CI injection.

## File Structure

```yaml
# compose.yaml — top-level keys
services:    # Required. Container definitions.
networks:    # Optional. Custom networks.
volumes:     # Optional. Named volumes.
configs:     # Optional. Non-sensitive config files.
secrets:     # Optional. Sensitive data (mounted at /run/secrets/).
```

## Services with Build Context

```yaml
services:
  api:
    build:
      context: ./api
      dockerfile: Dockerfile
      target: production        # Multi-stage build target
      args:
        NODE_ENV: production
    image: myregistry/api:${TAG:-latest}  # Tag built image for push
    ports:
      - "3000:3000"
```

When `image:` and `build:` coexist, Compose builds and tags the image with that name.

## depends_on with Healthchecks

Always use `condition: service_healthy` — bare `depends_on` only waits for container start, not readiness.

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
    volumes:
      - pgdata:/var/lib/postgresql/data
    secrets:
      - db_password

  api:
    build: ./api
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      DATABASE_URL: postgres://postgres@db:5432/app

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 3
```

## Environment Variables

### Interpolation in compose.yaml

```yaml
services:
  app:
    image: myapp:${TAG:-latest}                # Default value
    environment:
      DB_HOST: ${DB_HOST:?DB_HOST is required}  # Fail if unset
      LOG_LEVEL: ${LOG_LEVEL:-info}             # Default to "info"
```

### Precedence (highest to lowest)

1. CLI `docker compose run -e VAR=val`
2. Shell environment variables
3. `--env-file` flag
4. `.env` file in project directory
5. `env_file:` directive values
6. Dockerfile `ENV`

### .env vs env_file

- `.env` — interpolated into compose.yaml at parse time. NOT auto-injected into containers.
- `env_file:` — injected into the container runtime environment. No interpolation inside the file.

```yaml
services:
  app:
    env_file:
      - ./common.env
      - ./app.env
    environment:
      - OVERRIDE_VAR=takes_precedence
```

## Secrets and Configs

```yaml
secrets:
  db_password:
    file: ./secrets/db_password.txt   # File-based secret

configs:
  nginx_conf:
    file: ./nginx/nginx.conf

services:
  web:
    image: nginx:alpine
    configs:
      - source: nginx_conf
        target: /etc/nginx/nginx.conf
    secrets:
      - db_password   # Available at /run/secrets/db_password
```

Apps must read secrets from file, not env var: `POSTGRES_PASSWORD_FILE=/run/secrets/db_password`.

## Profiles

Selectively start services per environment. Services without a profile always start.

```yaml
services:
  app:
    image: myapp
    # No profile — always starts

  debug:
    image: busybox
    profiles: ["dev"]

  prometheus:
    image: prom/prometheus
    profiles: ["monitoring"]

  gpu-worker:
    image: myml:latest
    profiles: ["ml"]
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: [gpu]
```

```bash
docker compose --profile dev up           # app + debug
docker compose --profile monitoring up    # app + prometheus
docker compose --profile dev --profile monitoring up  # all three
```

## Extending Services & YAML Anchors

### extends keyword

```yaml
services:
  base-web:
    image: node:20-alpine
    environment: { NODE_ENV: production }
    restart: unless-stopped
  frontend:
    extends: { service: base-web }
    command: ["node", "frontend.js"]
    ports: ["3000:3000"]
  backend:
    extends: { service: base-web }
    command: ["node", "backend.js"]
    ports: ["4000:4000"]
```

### YAML anchors for DRY config

```yaml
x-common: &common
  restart: unless-stopped
  logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }

x-hc: &hc-defaults
  interval: 10s
  timeout: 5s
  retries: 3
  start_period: 15s

services:
  api:
    <<: *common
    image: myapi
    healthcheck: { test: ["CMD", "curl", "-f", "http://localhost:3000/health"], <<: *hc-defaults }
  worker:
    <<: *common
    image: myworker
    healthcheck: { test: ["CMD", "worker-healthcheck"], <<: *hc-defaults }
```

Use `x-` prefixed keys for extension fields — Compose ignores them as top-level directives.

## Multiple Compose Files (Override Pattern)

```bash
# compose.yaml          — base config
# compose.override.yaml — auto-loaded for dev
# compose.prod.yaml     — production overrides
docker compose up                                           # dev (auto-loads override)
docker compose -f compose.yaml -f compose.prod.yaml up -d   # production
```

Files merge top-down: later files override earlier ones. `compose.override.yaml` is auto-loaded.

## Watch Mode (Live Development)

```yaml
services:
  web:
    build: .
    develop:
      watch:
        - action: sync
          path: ./src
          target: /app/src
        - action: rebuild
          path: ./package.json
```

```bash
docker compose watch    # Auto-sync/rebuild on file changes
```

- `sync` — copies changed files into the running container (hot reload).
- `rebuild` — triggers full image rebuild when dependency files change.
- `sync+restart` — syncs files then restarts the container.

## GPU Support

```yaml
services:
  ml-training:
    image: pytorch/pytorch:latest
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all          # or specific count: 1
              capabilities: [gpu]
    environment:
      NVIDIA_VISIBLE_DEVICES: all
```

Requires NVIDIA Container Toolkit installed on the host.

## Production Patterns

Restart policies: `no` (default), `on-failure` (non-zero exit), `always` (survives reboot), `unless-stopped` (like always, respects manual stop). Use `unless-stopped` for most production services.

```yaml
services:
  app:
    restart: unless-stopped
    deploy:
      resources:
        limits: { cpus: "1.0", memory: 512M }
        reservations: { cpus: "0.25", memory: 128M }
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3", tag: "{{.Name}}" }
```

Always set `max-size`/`max-file` — unbounded logs fill disks in production.

## Networks

```yaml
services:
  frontend:
    networks: [public, backend-net]
  api:
    networks: [backend-net, db-net]
  db:
    networks: [db-net]   # Only api can reach db

networks:
  public:
  backend-net: { internal: true }   # No external access
  db-net: { internal: true }
```

Use `internal: true` to isolate sensitive services from external access.

## Init Container Pattern

```yaml
services:
  migrate:
    image: myapp:latest
    command: ["python", "manage.py", "migrate"]
    depends_on:
      db:
        condition: service_healthy
    restart: "no"    # Run once and exit

  app:
    image: myapp:latest
    depends_on:
      migrate:
        condition: service_completed_successfully
      db:
        condition: service_healthy
```

`service_completed_successfully` ensures migrations finish before the app starts.

## CI/CD Patterns

```yaml
# compose.ci.yaml
services:
  test:
    build:
      context: .
      target: test    # Multi-stage test target
    environment:
      CI: "true"
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16
    environment:
      POSTGRES_PASSWORD: test
    healthcheck:
      test: ["CMD-SHELL", "pg_isready"]
      interval: 2s
      timeout: 2s
      retries: 10
```

```bash
# CI pipeline
docker compose -f compose.ci.yaml run --rm --build test
docker compose -f compose.ci.yaml down -v   # Clean up volumes
```

Key CI rules:
- Use `--rm` to remove containers after exit.
- Use `down -v` to clean up volumes.
- Set short healthcheck intervals for faster CI.
- Use `--exit-code-from <service>` to propagate test exit codes.

## Debugging

```bash
docker compose logs -f api              # Follow logs for a service
docker compose logs --tail=100 api db   # Last 100 lines, multiple services
docker compose exec api sh              # Shell into running container
docker compose exec -e DEBUG=1 api sh   # With env var
docker compose ps                       # Service status
docker compose top                      # Running processes
docker compose config                   # Validate and print resolved config
docker compose config --services        # List service names
docker compose events                   # Real-time container events
docker compose cp api:/app/log.txt .    # Copy file from container
```

## Example: Full Production Stack

**User asks:** "Create a compose file for a Node.js API with PostgreSQL, Redis, and nginx."

**Output:**

```yaml
x-common: &common
  restart: unless-stopped
  logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }

services:
  nginx:
    <<: *common
    image: nginx:alpine
    ports: ["80:80", "443:443"]
    volumes: ["./nginx/nginx.conf:/etc/nginx/nginx.conf:ro"]
    depends_on: { api: { condition: service_healthy } }
    networks: [public]

  api:
    <<: *common
    build: { context: ./api, target: production }
    environment:
      DATABASE_URL: postgres://app:${DB_PASSWORD}@db:5432/app
      REDIS_URL: redis://redis:6379
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://localhost:3000/health')"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s
    depends_on:
      db: { condition: service_healthy }
      redis: { condition: service_healthy }
    deploy: { resources: { limits: { cpus: "2.0", memory: 1G } } }
    networks: [public, backend]

  db:
    <<: *common
    image: postgres:16-alpine
    environment: { POSTGRES_DB: app, POSTGRES_USER: app, POSTGRES_PASSWORD_FILE: /run/secrets/db_password }
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U app"], interval: 5s, timeout: 3s, retries: 5, start_period: 10s }
    volumes: [pgdata:/var/lib/postgresql/data]
    secrets: [db_password]
    deploy: { resources: { limits: { cpus: "1.0", memory: 512M } } }
    networks: [backend]

  redis:
    <<: *common
    image: redis:7-alpine
    command: ["redis-server", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    healthcheck: { test: ["CMD", "redis-cli", "ping"], interval: 5s, timeout: 3s, retries: 3 }
    volumes: [redis-data:/data]
    deploy: { resources: { limits: { cpus: "0.5", memory: 300M } } }
    networks: [backend]

  migrate:
    image: myregistry/api:${TAG:-latest}
    command: ["npx", "prisma", "migrate", "deploy"]
    environment: { DATABASE_URL: "postgres://app:${DB_PASSWORD}@db:5432/app" }
    depends_on: { db: { condition: service_healthy } }
    restart: "no"
    networks: [backend]

volumes: { pgdata: {}, redis-data: {} }
networks: { public: {}, backend: { internal: true } }
secrets: { db_password: { file: ./secrets/db_password.txt } }
```

## Skill Resources

### references/
- `advanced-patterns.md` — include directive, develop.watch, GPU passthrough, init containers, sidecars, macvlan, tmpfs, multi-platform builds, BuildKit secrets, Compose plugins
- `troubleshooting.md` — port conflicts, volume permissions, depends_on timing, network connectivity, build cache, .env loading, orphan containers, V1→V2 migration
- `compose-reference.md` — complete Compose spec: all service keys, deploy, configs, secrets, healthcheck, logging, networks, volumes, extension fields, interpolation

### scripts/
- `compose-lint.sh` — validate syntax, detect anti-patterns (hardcoded secrets, missing healthchecks/restart/logging)
- `compose-cleanup.sh` — remove orphan containers, dangling images, unused volumes/networks, build cache
- `compose-debug.sh` — inspect healthcheck status, port mappings, DNS resolution, inter-container connectivity

### assets/
- `fullstack-compose.yaml` — production template: app + API + DB + Redis + Nginx + migrations
- `dev-compose.yaml` — development: watch mode, debug ports, hot reload, mailpit, adminer
- `ci-compose.yaml` — CI/CD: tmpfs-backed DB, fast healthchecks, exit code propagation
- `monitoring-compose.yaml` — Prometheus + Grafana + cAdvisor + node-exporter + alertmanager
- `.env.example` — documented environment variable template

<!-- tested: pass -->
