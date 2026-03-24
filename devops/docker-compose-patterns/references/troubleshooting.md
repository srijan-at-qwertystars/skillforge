# Docker Compose Troubleshooting Guide

## Table of Contents

- [Port Conflicts](#port-conflicts)
- [Volume Permission Problems](#volume-permission-problems)
- [depends_on Timing vs Healthcheck](#depends_on-timing-vs-healthcheck)
- [Network Connectivity Between Containers](#network-connectivity-between-containers)
- [Build Cache Issues](#build-cache-issues)
- [.env File Not Loading](#env-file-not-loading)
- [Orphan Containers](#orphan-containers)
- [Compose V1 to V2 Migration](#compose-v1-to-v2-migration)
- [General Debugging Workflow](#general-debugging-workflow)

---

## Port Conflicts

### Symptom

```
Error starting userland proxy: Bind for 0.0.0.0:8080 failed: port is already allocated
```

### Diagnosis

```bash
# Find what's using the port
lsof -i :8080
# or
ss -tlnp | grep 8080
# Check Docker containers using the port
docker ps --format '{{.Names}} {{.Ports}}' | grep 8080
```

### Fixes

1. **Change host port mapping:** `"8081:80"` instead of `"8080:80"`.
2. **Use dynamic host ports:** `"80"` (no host port) — Docker picks a random available port.
3. **Bind to localhost only:** `"127.0.0.1:8080:80"` — avoids conflicts with services on other interfaces.
4. **Stop the conflicting process:** `kill <PID>` or `docker stop <container>`.
5. **Use environment variables for ports:**
   ```yaml
   ports:
     - "${APP_PORT:-8080}:80"
   ```

### Prevention

- Never hardcode ports. Use `.env` variables.
- Use `expose:` (not `ports:`) for internal-only services.
- Only map ports for services that need host access (reverse proxy, debug tools).

---

## Volume Permission Problems

### Symptom

```
PermissionError: [Errno 13] Permission denied: '/data/output.json'
```

### Diagnosis

```bash
# Check ownership inside container
docker compose exec app ls -la /data
# Check ownership on host
ls -la ./data
# Check what user the container runs as
docker compose exec app id
```

### Fixes

1. **Match UID/GID between host and container:**
   ```yaml
   services:
     app:
       user: "${UID:-1000}:${GID:-1000}"
   ```
   ```bash
   # In .env
   UID=1000
   GID=1000
   ```

2. **Fix host directory ownership:**
   ```bash
   sudo chown -R 1000:1000 ./data
   ```

3. **Use an init script to fix permissions at startup:**
   ```yaml
   services:
     app:
       entrypoint: >
         sh -c 'chown -R app:app /data && exec su-exec app "$@"'
   ```

4. **Named volumes** (Docker manages permissions — prefer over bind mounts for data dirs):
   ```yaml
   volumes:
     - app-data:/data   # Docker-managed, no host permission issues
   ```

5. **SELinux hosts** — add `:z` (shared) or `:Z` (private) label:
   ```yaml
   volumes:
     - ./data:/data:z
   ```

### Prevention

- Use named volumes for persistent data.
- Bind mounts: set `read_only: true` if the container shouldn't write.
- Document required UID/GID in `.env.example`.

---

## depends_on Timing vs Healthcheck

### The problem

Bare `depends_on` only waits for the container to **start**, not for the service inside to be **ready**.

```yaml
# BAD — API starts before DB is ready to accept connections
services:
  api:
    depends_on: [db]
```

```yaml
# GOOD — API waits until DB healthcheck passes
services:
  api:
    depends_on:
      db:
        condition: service_healthy
  db:
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 10s
```

### Common healthcheck tests

| Service      | Healthcheck command                                      |
|--------------|----------------------------------------------------------|
| PostgreSQL   | `pg_isready -U postgres`                                 |
| MySQL        | `mysqladmin ping -h localhost`                           |
| Redis        | `redis-cli ping`                                         |
| MongoDB      | `mongosh --eval "db.runCommand('ping')"`                 |
| Elasticsearch| `curl -f http://localhost:9200/_cluster/health`          |
| HTTP app     | `curl -f http://localhost:3000/health`                   |
| TCP port     | `nc -z localhost 5432`                                   |

### Debugging healthcheck

```bash
# Check health status
docker inspect --format='{{.State.Health.Status}}' <container>
# View healthcheck logs
docker inspect --format='{{range .State.Health.Log}}{{.Output}}{{end}}' <container>
```

### Tuning parameters

- `start_period`: Grace period before healthcheck failures count. Set high enough for slow-starting services (Java apps, Elasticsearch).
- `interval`: Time between checks. 2-5s for CI, 10-30s for production.
- `retries`: How many consecutive failures before `unhealthy`. 3-5 typical.

---

## Network Connectivity Between Containers

### Symptom

```
Could not connect to host "db" port 5432: Connection refused
```

### Diagnosis

```bash
# Verify services are on the same network
docker network inspect <project>_default
# Test connectivity from one container to another
docker compose exec api ping db
docker compose exec api nc -zv db 5432
# Check DNS resolution
docker compose exec api nslookup db
```

### Common causes and fixes

1. **Services on different networks:**
   ```yaml
   # Both must share a network
   services:
     api:
       networks: [backend]
     db:
       networks: [backend]
   networks:
     backend: {}
   ```

2. **Using `localhost` instead of service name:** Containers must use the service name (`db`, `redis`) as the hostname, not `localhost` or `127.0.0.1`.

3. **`network_mode: host`** bypasses Docker networking:
   ```yaml
   # This container uses host networking — other containers can't reach it by name
   services:
     app:
       network_mode: host
   ```

4. **Port not exposed:** The target port in `ports: "8080:3000"` is the container port (3000). Other containers connect to 3000, not 8080.

5. **Service not ready yet:** Use healthchecks + `condition: service_healthy`.

6. **Firewall / iptables:** Docker modifies iptables. Check `iptables -L -n` if connectivity fails.

---

## Build Cache Issues

### Symptom

Builds are slow, or changes aren't reflected in the built image.

### Force rebuild (no cache)

```bash
docker compose build --no-cache
docker compose up --build --force-recreate
```

### Cache-efficient Dockerfile ordering

```dockerfile
# GOOD — dependencies cached separately from source
COPY package.json package-lock.json ./
RUN npm ci
COPY . .

# BAD — any source change invalidates the npm install cache
COPY . .
RUN npm ci
```

### BuildKit cache mount (persists across builds)

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements.txt
```

### Prune build cache

```bash
docker builder prune              # remove unused build cache
docker builder prune --all        # remove all build cache
docker system df                  # check disk usage
```

### Stale layer debugging

```bash
docker compose build --progress=plain   # verbose build output
docker history <image>                  # inspect image layers
```

---

## .env File Not Loading

### Symptom

```
WARN[0000] The "DB_PASSWORD" variable is not set. Defaulting to a blank string.
```

### Checklist

1. **File location:** `.env` must be in the same directory where you run `docker compose` (the project directory).
2. **File name:** Exactly `.env` — not `env`, `.env.local`, or `.env.txt`.
3. **Syntax rules:**
   ```bash
   # .env file
   KEY=value              # correct
   KEY = value            # WRONG — spaces around =
   export KEY=value       # WRONG — no export keyword
   KEY="value with spaces" # correct — quotes for spaces
   KEY=                   # correct — empty value
   # comments start with #
   ```
4. **Verify interpolation:**
   ```bash
   docker compose config   # shows resolved values
   ```
5. **.env vs env_file:** `.env` interpolates compose.yaml at parse time. `env_file:` injects into container runtime. They are NOT the same.

### Override .env location

```bash
docker compose --env-file ./config/.env.staging up
```

### Precedence (highest wins)

1. CLI `-e VAR=val`
2. Shell environment
3. `--env-file` flag
4. `.env` file
5. `env_file:` directive
6. Dockerfile `ENV`

---

## Orphan Containers

### Symptom

```
WARN[0000] Found orphan containers ([project-old-service-1]) for this project.
```

### Cause

A service was removed from `compose.yaml` but its container still exists.

### Fix

```bash
# Remove orphans on next up
docker compose up --remove-orphans

# Remove all project containers
docker compose down --remove-orphans

# Nuclear option — remove everything for this project
docker compose down --remove-orphans --volumes --rmi local
```

### Prevention

- Always `docker compose down` before removing services from the file.
- Use `docker compose up --remove-orphans` as a habit.
- Set `COMPOSE_REMOVE_ORPHANS=true` in your `.env`.

---

## Compose V1 to V2 Migration

### Command changes

| V1 (deprecated)              | V2                            |
|------------------------------|-------------------------------|
| `docker-compose up`          | `docker compose up`           |
| `docker-compose -f file.yml` | `docker compose -f file.yml`  |
| `docker-compose exec -T`     | `docker compose exec -T`      |

### YAML changes

| V1                                | V2                                     |
|-----------------------------------|----------------------------------------|
| `version: "3.8"` (required)       | Omit `version:` (deprecated)           |
| `scale: 3`                        | `deploy: { replicas: 3 }`             |
| `links:` (for connectivity)       | Use shared networks (default)          |
| `volumes_from:`                   | Use named volumes                      |
| `net:` / `network_mode:`          | `network_mode:`                        |

### Behavioral differences

- **Container naming:** V2 uses `-` separator (`project-service-1`), V1 used `_` (`project_service_1`). Scripts parsing container names may break.
- **Default behavior:** V2 auto-detects `.env` and `compose.override.yaml` differently.
- **BuildKit:** V2 uses BuildKit by default. Set `DOCKER_BUILDKIT=0` to disable if builds break.
- **Parallel execution:** V2 starts/stops services in parallel by default.

### Migration checklist

1. Update all scripts: `docker-compose` → `docker compose`.
2. Remove `version:` from compose files.
3. Replace `scale:` with `deploy.replicas`.
4. Replace `links:` with shared networks.
5. Test container name patterns in scripts.
6. Run `docker compose down` with V1, then `docker compose up` with V2 to avoid orphans.

---

## General Debugging Workflow

```bash
# 1. Validate configuration
docker compose config

# 2. Check service status
docker compose ps -a

# 3. View logs (follow mode)
docker compose logs -f --tail=50

# 4. Shell into a container
docker compose exec <service> sh

# 5. Inspect a specific container
docker inspect <container_id>

# 6. Check events in real time
docker compose events

# 7. View resource usage
docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# 8. Check networks
docker network ls
docker network inspect <network>

# 9. Full cleanup and restart
docker compose down -v --remove-orphans
docker compose up --build --force-recreate
```
