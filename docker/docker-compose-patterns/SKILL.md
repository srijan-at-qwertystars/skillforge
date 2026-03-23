---
name: docker-compose-patterns
description:
  positive: "Use when user writes docker-compose.yml, asks about multi-container development, Compose services, networks, volumes, healthchecks, profiles, watch mode, or Compose for development environments."
  negative: "Do NOT use for Dockerfile writing (use dockerfile-best-practices skill), Kubernetes deployments (use helm-chart-patterns skill), or Docker Swarm."
---

# Docker Compose Patterns & Best Practices

## Compose v2 Fundamentals

Use `docker compose` (space, not hyphen). The legacy `docker-compose` binary is deprecated.

Preferred filename: `compose.yaml` (also accepts `compose.yml`, `docker-compose.yml`). Omit the top-level `version` field — deprecated in Compose v2. Minimal structure:

```yaml
services:
  app:
    image: node:22-alpine
    ports:
      - "3000:3000"
```

## Service Configuration

```yaml
services:
  api:
    image: myapp:latest          # use prebuilt image
    build:                       # OR build from source
      context: .
      dockerfile: Dockerfile
      target: production         # multi-stage target
      args:
        NODE_ENV: production
    ports:
      - "127.0.0.1:8080:8080"   # bind to localhost only
    environment:
      DATABASE_URL: postgres://db:5432/app
    env_file:
      - .env
      - .env.local
    command: ["node", "server.js"]
    entrypoint: ["/docker-entrypoint.sh"]
    working_dir: /app
    user: "1000:1000"            # run as non-root
    restart: unless-stopped
```

Always quote port mappings. Bind to `127.0.0.1` in development to avoid LAN exposure.

## Networking

Every Compose project creates a default bridge network. Services resolve each other by name.

```yaml
services:
  api:
    networks:
      - frontend
      - backend
  db:
    networks:
      backend:
        aliases:
          - database
          - postgres

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true    # no external access
```

**Network modes:** `bridge` (default, isolated with DNS) · `host` (share host stack, use sparingly) · `none` (no networking).

**Cross-stack communication** — use external networks:

```yaml
networks:
  shared:
    external: true
    name: my-shared-network
```

Never hardcode container IPs. Use service names or network aliases.

## Volumes

### Named Volumes (persistent data)

```yaml
services:
  db:
    image: postgres:17
    volumes:
      - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
    driver: local
```

### Bind Mounts (development)

```yaml
volumes:
  - ./src:/app/src
  - /app/node_modules       # anonymous volume to isolate deps
```

### Tmpfs and Read-Only Mounts

```yaml
tmpfs:
  - /tmp:size=100M
volumes:
  - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
```

Use named volumes for database data. Use bind mounts for source code in dev only. Never bind-mount over installed dependencies (`node_modules`, `vendor`).

## Healthchecks

```yaml
services:
  api:
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/health || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 30s
```

Database-specific checks:

```yaml
# PostgreSQL
healthcheck:
  test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
  interval: 10s
  retries: 5
  start_period: 20s

# MySQL
healthcheck:
  test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
  interval: 10s
  retries: 5

# Redis
healthcheck:
  test: ["CMD", "redis-cli", "ping"]
  interval: 10s
  retries: 3
```

Use `$$` (double-dollar) in healthcheck commands to defer variable expansion to runtime.

## Dependencies

```yaml
services:
  db:
    image: postgres:17
    healthcheck:
      test: ["CMD-SHELL", "pg_isready"]
      interval: 10s
      retries: 5
      start_period: 20s

  migrate:
    build: .
    command: npm run migrate
    depends_on:
      db:
        condition: service_healthy

  app:
    build: .
    depends_on:
      db:
        condition: service_healthy
      migrate:
        condition: service_completed_successfully
```

**Conditions:** `service_started` (default, container start only) · `service_healthy` (requires `healthcheck`) · `service_completed_successfully` (exit code 0, for migrations/seeds).

Always pair `service_healthy` with a defined `healthcheck`. Without it, the condition is never met.

## Environment Management

### .env file (auto-loaded from project root)

```dotenv
POSTGRES_USER=app
POSTGRES_PASSWORD=secret
POSTGRES_DB=mydb
APP_PORT=3000
```

### Variable interpolation in compose.yaml

```yaml
services:
  db:
    image: postgres:${POSTGRES_VERSION:-17}
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "${DB_PORT:-5432}:5432"
```

### Precedence (highest to lowest)

1. CLI `-e VAR=val` → 2. `environment:` block → 3. `env_file:` → 4. `.env` (interpolation only) → 5. Dockerfile `ENV`

### Multiple env files

```yaml
env_file:
  - .env
  - .env.${ENVIRONMENT:-development}
```

Never commit secrets to `.env`. Add `.env` to `.gitignore`. Use `.env.example` as a template.

## Profiles

Assign services to profiles to selectively start them.

```yaml
services:
  app:
    build: .
    ports:
      - "3000:3000"

  db:
    image: postgres:17
    profiles: [dev, test]

  mailhog:
    image: mailhog/mailhog
    profiles: [dev]
    ports:
      - "8025:8025"

  test-runner:
    build: .
    command: npm test
    profiles: [test]
    depends_on:
      db:
        condition: service_healthy
```

```bash
docker compose --profile dev up                     # app + db + mailhog
docker compose --profile test up                    # app + db + test-runner
docker compose --profile dev --profile test up      # all
```

Services without a `profiles` key start with every `docker compose up`. Assign profiles to optional or environment-specific services only.

## Watch Mode

Available in Compose v2.22+. Automatically syncs, rebuilds, or restarts services on file changes.

```yaml
services:
  web:
    build: .
    ports:
      - "3000:3000"
    develop:
      watch:
        - action: sync
          path: ./src
          target: /app/src
          ignore:
            - "**/*.test.js"
        - action: sync+restart
          path: ./config
          target: /app/config
        - action: rebuild
          path: ./package.json
```

```bash
docker compose watch          # or: docker compose up --watch
```

**Actions:** `sync` (copy files, for hot-reload source) · `sync+restart` (copy + restart, for config) · `rebuild` (full rebuild, for dependency changes).

Use `ignore` patterns to skip `node_modules`, `.git`, test files. The container must have `stat`, `mkdir`, `rmdir` available.

## Multi-Stage Development

### Override files

Compose auto-loads `compose.override.yaml` alongside `compose.yaml`.

```yaml
# compose.yaml — base config
services:
  app:
    build:
      context: .
      target: production
    restart: always
```

```yaml
# compose.override.yaml — dev overrides (auto-loaded)
services:
  app:
    build:
      target: development
    volumes:
      - ./src:/app/src
    environment:
      DEBUG: "true"
    restart: "no"
```

### Explicit multi-file composition

```bash
docker compose -f compose.yaml -f compose.prod.yaml up -d
```

Files merge: later files override earlier ones. Use base + environment-specific overlays.

## Database Services

### PostgreSQL with init script

```yaml
services:
  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER}"]
      interval: 10s
      retries: 5
      start_period: 20s

volumes:
  pgdata:
```

### Redis

```yaml
services:
  redis:
    image: redis:7-alpine
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$${REDIS_PASSWORD}", "ping"]
      interval: 10s
      retries: 3

volumes:
  redis-data:
```

### MongoDB

```yaml
services:
  mongo:
    image: mongo:8
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_USER}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASSWORD}
    volumes:
      - mongo-data:/data/db
      - ./mongo-init.js:/docker-entrypoint-initdb.d/init.js:ro
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      retries: 5

volumes:
  mongo-data:
```

Mount init scripts as read-only. Use Alpine image variants to reduce size.

## Common Stacks

### Web + Database + Cache

```yaml
services:
  app:
    build: .
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      DATABASE_URL: postgres://postgres:5432/app
      REDIS_URL: redis://redis:6379
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  postgres:
    image: postgres:17-alpine
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready"]
      interval: 10s
      retries: 5

  redis:
    image: redis:7-alpine
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 3

volumes:
  pgdata:
  redis-data:
```

For full-stack (frontend + backend + db), follow the same pattern: separate build contexts per service, `depends_on` with `service_healthy` for the database, and `develop.watch` for each service's source directory.

## Resource Limits

```yaml
services:
  app:
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
        reservations:
          cpus: "0.25"
          memory: 128M
      replicas: 2
    restart: unless-stopped
```

**Restart policies:** `no` | `always` | `on-failure` | `unless-stopped`. Use `unless-stopped` in production, `no` or `on-failure` in development.

## Debugging

```bash
docker compose ps -a                   # list services (include stopped)
docker compose logs -f --tail=100 api  # follow + tail logs
docker compose exec api sh             # shell into running container
docker compose run --rm api npm test   # one-off command
docker compose events                  # real-time events
docker compose config                  # validate and render final config
docker compose build --no-cache        # rebuild without cache
docker compose down -v                 # stop + remove volumes
docker compose up --force-recreate     # recreate all containers
```

Use `docker compose config` to validate interpolation and file merging before starting.

## Anti-Patterns

| Anti-Pattern | Fix |
|---|---|
| Hardcoded ports without localhost binding | Use `127.0.0.1:PORT:PORT` |
| Missing healthchecks on stateful services | Add `healthcheck` to every database and queue |
| Running as root in containers | Set `user: "1000:1000"` or use non-root in Dockerfile |
| No `.dockerignore` | Create `.dockerignore` with `.git`, `node_modules`, `*.md` |
| Storing secrets in compose.yaml | Use `env_file`, Docker secrets, or external vault |
| Using `latest` tag | Pin specific image versions (`postgres:17-alpine`) |
| Bind-mounting over dependencies | Use anonymous volumes to isolate `node_modules` |
| No restart policy in production | Set `restart: unless-stopped` |
| Using `depends_on` without conditions | Add `condition: service_healthy` |
| Skipping `start_period` in healthchecks | Set `start_period` for slow-starting services |
| Using legacy `version` field | Omit it — deprecated in Compose v2 |
| Using `docker-compose` (hyphen) | Use `docker compose` (space) — v2 CLI |
