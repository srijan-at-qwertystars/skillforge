# Advanced Docker Compose Patterns

## Table of Contents

- [Include Directive](#include-directive)
- [Develop Watch Configuration](#develop-watch-configuration)
- [GPU Passthrough](#gpu-passthrough)
- [Init Containers](#init-containers)
- [Sidecar Patterns](#sidecar-patterns)
- [Advanced Networking](#advanced-networking)
- [tmpfs and Bind Mount Optimization](#tmpfs-and-bind-mount-optimization)
- [Multi-Platform Builds](#multi-platform-builds)
- [BuildKit Secrets](#buildkit-secrets)
- [Compose Plugins and Bake](#compose-plugins-and-bake)

---

## Include Directive

Requires Compose v2.20+. Splits monolithic configs into reusable modules.

### Short syntax

```yaml
include:
  - ./services/database.yml
  - ./services/monitoring.yml
```

### Long syntax (with env and project directory)

```yaml
include:
  - path: ./services/cache.yml
  - path: ./services/backend.yml
    project_directory: ../
    env_file: ./backend.env
```

### Key behaviors

- Each included file is a standalone Compose app — relative paths resolve from its own location.
- Included services, networks, volumes merge into the main project.
- Recursive: included files can themselves `include:` other files.
- Name collisions between included and main resources cause errors — use clear naming.
- `include` runs before all other top-level keys are evaluated.

### Pattern: environment-based includes

```yaml
include:
  - path: ./services/frontend.yml
  - path: ./services/backend.yml
  - path: ${COMPOSE_ENV:-./environments/dev.yml}
```

### Pattern: OCI / remote includes

```yaml
include:
  - oci://docker.io/myorg/shared-compose:latest
```

---

## Develop Watch Configuration

Eliminates manual rebuild/restart cycles during development.

### Actions

| Action         | Behavior                                     | Use case                         |
|----------------|----------------------------------------------|----------------------------------|
| `sync`         | Copy changed files into running container    | Source code (hot-reload frameworks)|
| `rebuild`      | Rebuild image and recreate container         | Dependency files, Dockerfile     |
| `sync+restart` | Sync files then restart container process    | Config files without hot-reload  |
| `sync+exec`    | Sync files then run a command in container   | Trigger compilation / scripts    |

### Full example

```yaml
services:
  api:
    build: .
    ports: ["3000:3000"]
    develop:
      watch:
        - action: sync
          path: ./src
          target: /app/src
          ignore:
            - "*.pyc"
            - __pycache__/
            - node_modules/
            - "*.swp"
        - action: rebuild
          path: ./package.json
        - action: rebuild
          path: ./Dockerfile
        - action: sync+restart
          path: ./config
          target: /app/config
```

### Ignore patterns

Follow `.dockerignore` syntax. Always ignore:
- `node_modules/`, `vendor/`, `.venv/` — dependency dirs
- `dist/`, `build/` — build output
- `*.swp`, `.DS_Store`, `*.tmp` — editor artifacts

### Tips

- `sync` requires the framework to support hot-reload (Next.js, Flask debug, nodemon).
- `rebuild` is expensive — only use for files that change the image (deps, Dockerfile).
- Run with `docker compose watch` (not `up`).
- Set `initial_sync: true` (default) to sync all files on startup.

---

## GPU Passthrough

### NVIDIA (requires nvidia-container-toolkit)

```yaml
services:
  ml-training:
    image: nvidia/cuda:12.9.0-base-ubuntu22.04
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all        # or integer: 1, 2
              capabilities: [gpu]
```

Select specific GPUs:

```yaml
devices:
  - driver: nvidia
    device_ids: ["0", "2"]    # mutually exclusive with count
    capabilities: [gpu]
```

### AMD (requires amd-container-toolkit)

```yaml
services:
  inference:
    image: rocm/pytorch
    runtime: amd
    environment:
      AMD_VISIBLE_DEVICES: "0"   # "all", "0,1", or "none"
```

### Intel (direct device passthrough)

```yaml
services:
  transcode:
    image: jellyfin/jellyfin
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "render"
```

---

## Init Containers

Run one-time setup tasks before the main app starts.

```yaml
services:
  migrate:
    image: myapp:latest
    command: ["python", "manage.py", "migrate"]
    depends_on:
      db: { condition: service_healthy }
    restart: "no"

  seed:
    image: myapp:latest
    command: ["python", "manage.py", "seed"]
    depends_on:
      migrate: { condition: service_completed_successfully }
    restart: "no"

  app:
    image: myapp:latest
    depends_on:
      seed: { condition: service_completed_successfully }
      db: { condition: service_healthy }
```

### Conditions

| Condition                        | Waits for                          |
|----------------------------------|------------------------------------|
| `service_started`                | Container started (not ready)      |
| `service_healthy`                | Healthcheck passing                |
| `service_completed_successfully` | Container exited with code 0       |

---

## Sidecar Patterns

### Log forwarder sidecar

```yaml
services:
  app:
    image: myapp
    volumes:
      - app-logs:/var/log/app

  log-forwarder:
    image: fluent/fluent-bit
    volumes:
      - app-logs:/var/log/app:ro
    depends_on: [app]

volumes:
  app-logs:
```

### TLS termination sidecar

```yaml
services:
  app:
    image: myapp
    expose: ["3000"]
    networks: [internal]

  tls-proxy:
    image: nginx:alpine
    ports: ["443:443"]
    volumes:
      - ./certs:/etc/nginx/certs:ro
      - ./nginx-tls.conf:/etc/nginx/nginx.conf:ro
    depends_on: [app]
    networks: [internal, public]

networks:
  internal: { internal: true }
  public: {}
```

### Database backup sidecar

```yaml
services:
  db-backup:
    image: postgres:16-alpine
    entrypoint: >
      sh -c 'while true; do
        pg_dump -h db -U app appdb > /backups/$$(date +%Y%m%d_%H%M%S).sql;
        find /backups -mtime +7 -delete;
        sleep 86400;
      done'
    depends_on:
      db: { condition: service_healthy }
    volumes:
      - db-backups:/backups
```

---

## Advanced Networking

### Custom bridge with IPAM

```yaml
networks:
  app-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
          ip_range: 172.28.5.0/24
          gateway: 172.28.0.1
```

### Macvlan (containers on physical LAN)

```yaml
services:
  pihole:
    image: pihole/pihole
    networks:
      lan:
        ipv4_address: 192.168.1.53

networks:
  lan:
    driver: macvlan
    driver_opts:
      parent: eth0
    ipam:
      config:
        - subnet: 192.168.1.0/24
          gateway: 192.168.1.1
          ip_range: 192.168.1.48/28
```

**Macvlan caveats:** Containers cannot reach the host by default. Create a macvlan interface on the host for host↔container communication. No DHCP — always assign static IPs.

### Internal-only network (no external access)

```yaml
networks:
  db-net:
    internal: true
```

### Pre-existing external network

```yaml
networks:
  shared:
    external: true
    name: my-existing-network
```

### Network aliases

```yaml
services:
  api:
    networks:
      backend:
        aliases:
          - api.local
          - backend-service
```

---

## tmpfs and Bind Mount Optimization

### tmpfs (RAM-backed, ephemeral)

```yaml
services:
  app:
    tmpfs:
      - /tmp
      - /run:size=64M,uid=1000
```

Use for: temp files, caches, session data, test artifacts. Data is lost on container stop.

### Bind mount options

```yaml
volumes:
  - type: bind
    source: ./src
    target: /app/src
    read_only: true          # prevent container writes
    bind:
      create_host_path: true  # auto-create dir on host
```

### Cached/delegated (macOS performance)

```yaml
volumes:
  - ./src:/app/src:cached     # host authoritative (faster reads)
  - ./logs:/app/logs:delegated # container authoritative (faster writes)
```

### Named volume with driver options

```yaml
volumes:
  db-data:
    driver: local
    driver_opts:
      type: nfs
      o: addr=10.0.0.5,rw,nfsvers=4
      device: ":/exports/db-data"
```

---

## Multi-Platform Builds

### In compose.yaml

```yaml
services:
  api:
    build:
      context: .
      platforms:
        - linux/amd64
        - linux/arm64
    image: myregistry/api:latest
```

### Using docker-bake.hcl

```hcl
group "default" {
  targets = ["api", "worker"]
}

target "api" {
  context    = "./api"
  platforms  = ["linux/amd64", "linux/arm64"]
  tags       = ["myregistry/api:latest"]
}

target "worker" {
  context    = "./worker"
  platforms  = ["linux/amd64", "linux/arm64"]
  tags       = ["myregistry/worker:latest"]
}
```

```bash
docker buildx bake --push
```

**Requires:** `docker buildx create --use` (multi-platform builder instance).

---

## BuildKit Secrets

Pass secrets securely at build time — never baked into the image.

### Dockerfile

```dockerfile
# syntax=docker/dockerfile:1
FROM node:20-alpine
RUN --mount=type=secret,id=npm_token \
    NPM_TOKEN=$(cat /run/secrets/npm_token) npm install
```

### compose.yaml

```yaml
services:
  app:
    build:
      context: .
      secrets:
        - npm_token

secrets:
  npm_token:
    file: ./secrets/npm_token.txt
```

### SSH agent forwarding

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=ssh git clone git@github.com:private/repo.git
```

```bash
docker compose build --ssh default
```

### Cache mounts (faster installs)

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt
```

---

## Compose Plugins and Bake

### Dry-run mode

```bash
docker compose --dry-run up    # preview what would happen
```

### Convert to other formats

```bash
docker compose config          # resolved YAML
docker compose convert         # alias for config
```

### Build with Bake from Compose

```bash
docker buildx bake --file compose.yaml    # use compose as bake input
```

### Useful CLI flags

```bash
docker compose up --wait           # block until services are healthy
docker compose up --watch          # start + watch mode
docker compose up --remove-orphans # clean up removed services
docker compose build --parallel    # build services concurrently
docker compose pull --ignore-pull-failures  # continue on pull errors
```
