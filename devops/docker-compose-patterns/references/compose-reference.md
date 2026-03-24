# Docker Compose Specification Reference

## Table of Contents

- [Top-Level Keys](#top-level-keys)
- [Service Keys — Build](#service-keys--build)
- [Service Keys — Runtime](#service-keys--runtime)
- [Service Keys — Networking](#service-keys--networking)
- [Service Keys — Volumes and Storage](#service-keys--volumes-and-storage)
- [Service Keys — Deploy](#service-keys--deploy)
- [Service Keys — Healthcheck](#service-keys--healthcheck)
- [Service Keys — Logging](#service-keys--logging)
- [Service Keys — Dependencies](#service-keys--dependencies)
- [Service Keys — Security](#service-keys--security)
- [Configs and Secrets](#configs-and-secrets)
- [Networks Top-Level](#networks-top-level)
- [Volumes Top-Level](#volumes-top-level)
- [Extension Fields](#extension-fields)
- [Variable Interpolation](#variable-interpolation)

---

## Top-Level Keys

```yaml
name: my-project          # Project name (overrides directory name)
services: {}              # Required — container definitions
networks: {}              # Custom networks
volumes: {}               # Named volumes
configs: {}               # Non-sensitive configuration files
secrets: {}               # Sensitive data
include: []               # Include other compose files (v2.20+)
```

---

## Service Keys — Build

```yaml
services:
  app:
    build:
      context: ./app                  # Build context directory
      dockerfile: Dockerfile.prod     # Dockerfile path (relative to context)
      dockerfile_inline: |            # Inline Dockerfile (alternative to file)
        FROM node:20-alpine
        COPY . .
      target: production              # Multi-stage build target
      args:                           # Build arguments
        NODE_ENV: production
      labels:                         # Image metadata
        com.example.version: "1.0"
      cache_from:                     # External cache sources
        - type=registry,ref=myregistry/app:cache
      cache_to:                       # Export cache
        - type=inline
      secrets:                        # BuildKit secrets available at build
        - npm_token
      ssh:                            # SSH agent forwarding
        - default
      platforms:                      # Multi-platform targets
        - linux/amd64
        - linux/arm64
      shm_size: 256mb                 # /dev/shm size during build
      extra_hosts:                    # Extra /etc/hosts entries during build
        - "api.local:192.168.1.100"
      network: host                   # Build network mode
      no_cache: false                 # Disable cache for this build
      pull: true                      # Always pull base image
      tags:                           # Additional tags
        - myregistry/app:v1.2.3
    image: myregistry/app:latest      # Tag built image (also used for pull if no build)
```

---

## Service Keys — Runtime

```yaml
services:
  app:
    image: node:20-alpine
    container_name: my-app          # Custom container name (breaks scaling)
    hostname: app-host              # Container hostname
    domainname: example.com         # Container domain name
    command: ["node", "server.js"]  # Override CMD
    entrypoint: ["/entrypoint.sh"]  # Override ENTRYPOINT
    working_dir: /app               # Working directory
    user: "1000:1000"               # Run as UID:GID
    restart: unless-stopped         # no | on-failure[:max-retries] | always | unless-stopped
    init: true                      # Run tini as PID 1 (reaps zombies)
    stop_signal: SIGTERM            # Signal to stop container
    stop_grace_period: 30s          # Time before SIGKILL
    tty: true                       # Allocate pseudo-TTY
    stdin_open: true                # Keep stdin open
    read_only: true                 # Read-only root filesystem
    privileged: false               # Full host privileges (avoid)
    pid: host                       # Share host PID namespace
    ipc: host                       # Share host IPC namespace
    userns_mode: host               # User namespace mode

    environment:                    # Environment variables (map or list)
      NODE_ENV: production
      DB_HOST: db
    # or list form:
    # environment:
    #   - NODE_ENV=production

    env_file:                       # Load env from files
      - ./common.env
      - path: ./optional.env
        required: false             # Don't error if missing

    labels:                         # Container metadata
      com.example.service: api

    annotations:                    # OCI annotations
      com.example.team: backend

    extra_hosts:                    # Add /etc/hosts entries
      - "api.local:192.168.1.100"

    dns:                            # Custom DNS servers
      - 8.8.8.8
      - 8.8.4.4
    dns_search:                     # DNS search domains
      - example.com

    profiles:                       # Only start with --profile
      - dev
      - debug

    extends:                        # Inherit from another service
      service: base-service
      file: ./base.yaml             # Optional — defaults to same file

    scale: 3                        # Number of instances (prefer deploy.replicas)

    runtime: nvidia                 # Container runtime (nvidia, amd, etc.)
```

---

## Service Keys — Networking

```yaml
services:
  app:
    ports:                          # Port mappings
      - "80:80"                     # host:container
      - "127.0.0.1:8443:443"       # bind to localhost only
      - target: 3000                # long syntax
        published: "3000-3005"      # port range
        protocol: tcp
        mode: host
        app_protocol: http          # application protocol hint

    expose:                         # Expose to other containers only (no host)
      - "3000"
      - "9229"

    network_mode: bridge            # bridge | host | none | service:<name> | container:<name>

    networks:                       # Attach to specific networks
      frontend:
        aliases: [web, app]         # DNS aliases on this network
        ipv4_address: 172.28.0.10   # Static IP
        ipv6_address: 2001:db8::10
        priority: 100               # Network connection priority
        mac_address: "02:42:ac:11:65:43"
      backend: {}

    mac_address: "02:42:ac:11:65:43" # Container MAC address
```

---

## Service Keys — Volumes and Storage

```yaml
services:
  app:
    volumes:
      - ./src:/app/src              # Short syntax (bind mount)
      - app-data:/data              # Named volume
      - /container/only             # Anonymous volume

      - type: bind                  # Long syntax
        source: ./src
        target: /app/src
        read_only: true
        bind:
          create_host_path: true    # Create host dir if missing
          selinux: z                # SELinux label: z (shared) or Z (private)

      - type: volume                # Named volume long syntax
        source: db-data
        target: /var/lib/data
        volume:
          nocopy: true              # Don't copy container data into volume

      - type: tmpfs                 # tmpfs long syntax
        target: /tmp
        tmpfs:
          size: 67108864            # 64MB in bytes
          mode: 1777                # Permission mode

    tmpfs:                          # Quick tmpfs mounts
      - /tmp
      - /run:size=64M

    devices:                        # Device mappings
      - "/dev/sda:/dev/xvdc:rwm"
```

---

## Service Keys — Deploy

```yaml
services:
  app:
    deploy:
      mode: replicated              # replicated | global
      replicas: 3                   # Number of instances

      resources:
        limits:
          cpus: "2.0"               # Max CPU
          memory: 1G                # Max memory
          pids: 100                 # Max processes
        reservations:
          cpus: "0.5"               # Guaranteed CPU
          memory: 256M              # Guaranteed memory
          devices:                  # GPU / device reservations
            - driver: nvidia
              count: 1
              capabilities: [gpu]

      restart_policy:               # Swarm restart policy
        condition: on-failure       # none | on-failure | any
        delay: 5s
        max_attempts: 3
        window: 120s

      update_config:                # Rolling update settings
        parallelism: 1
        delay: 10s
        order: start-first          # start-first | stop-first

      rollback_config:
        parallelism: 1
        delay: 5s

      placement:
        constraints:
          - node.role == worker
        preferences:
          - spread: datacenter

      endpoint_mode: vip            # vip | dnsrr

      labels:
        com.example.version: "1.0"
```

---

## Service Keys — Healthcheck

```yaml
services:
  app:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      # or shell form:
      # test: ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"]
      interval: 30s                 # Time between checks
      timeout: 10s                  # Max time for single check
      retries: 3                    # Failures before unhealthy
      start_period: 15s             # Grace period at startup
      start_interval: 5s            # Interval during start_period (Compose v2.20+)

    # Disable inherited healthcheck:
    # healthcheck:
    #   disable: true
```

### Test formats

| Format          | Example                                                   |
|-----------------|-----------------------------------------------------------|
| `CMD`           | `["CMD", "pg_isready", "-U", "postgres"]`                 |
| `CMD-SHELL`     | `["CMD-SHELL", "curl -f http://localhost/ \|\| exit 1"]`  |
| `NONE`          | `["NONE"]` — disables healthcheck                         |

---

## Service Keys — Logging

```yaml
services:
  app:
    logging:
      driver: json-file             # json-file | syslog | journald | fluentd | none
      options:
        max-size: "10m"             # Max log file size
        max-file: "3"               # Max number of log files
        tag: "{{.Name}}/{{.ID}}"    # Log tag template
        compress: "true"            # Compress rotated files
        # Syslog options:
        # syslog-address: "tcp://syslog:514"
        # syslog-facility: "daemon"
        # Fluentd options:
        # fluentd-address: "fluentd:24224"
        # fluentd-async: "true"
```

---

## Service Keys — Dependencies

```yaml
services:
  app:
    depends_on:
      db:
        condition: service_healthy                # Wait for healthcheck
        restart: true                             # Restart app if db restarts
        required: true                            # Fail if db can't start
      migrate:
        condition: service_completed_successfully # Wait for exit code 0
      cache:
        condition: service_started                # Just wait for container start
```

---

## Service Keys — Security

```yaml
services:
  app:
    cap_add:                        # Add Linux capabilities
      - NET_ADMIN
      - SYS_PTRACE
    cap_drop:                       # Drop capabilities
      - ALL
    security_opt:                   # Security options
      - no-new-privileges:true
      - seccomp:./seccomp-profile.json
      - apparmor:docker-default
    sysctls:                        # Kernel parameters
      net.core.somaxconn: 1024
      net.ipv4.tcp_syncookies: 0
    ulimits:                        # Resource limits
      nofile:
        soft: 65536
        hard: 65536
      nproc: 65535
    cgroup_parent: /docker/custom   # Parent cgroup
    isolation: default              # Windows: default | hyperv | process
```

---

## Configs and Secrets

```yaml
# Top-level definitions
configs:
  nginx_conf:
    file: ./nginx/nginx.conf        # File-based config
  app_conf:
    content: |                      # Inline content
      server.port=8080
  external_conf:
    external: true                  # Pre-existing config
    name: my-existing-config

secrets:
  db_password:
    file: ./secrets/db_password.txt
  api_key:
    environment: API_KEY            # From environment variable
  external_secret:
    external: true

# Service-level usage
services:
  app:
    configs:
      - source: nginx_conf
        target: /etc/nginx/nginx.conf
        uid: "103"
        gid: "103"
        mode: 0440
    secrets:
      - db_password                 # Mounted at /run/secrets/db_password
      - source: api_key
        target: /run/secrets/my_api_key
        uid: "1000"
        gid: "1000"
        mode: 0400
```

---

## Networks Top-Level

```yaml
networks:
  frontend:
    driver: bridge                  # bridge | overlay | macvlan | none | host
    driver_opts:
      com.docker.network.bridge.name: br-frontend
      parent: eth0                  # macvlan: host interface
    enable_ipv6: true
    internal: true                  # No external connectivity
    attachable: true                # Allow manual container attachment
    labels:
      com.example.network: frontend

    ipam:
      driver: default
      config:
        - subnet: 172.28.0.0/16
          ip_range: 172.28.5.0/24
          gateway: 172.28.0.1
          aux_addresses:
            host1: 172.28.1.5

  existing:
    external: true                  # Use pre-existing network
    name: my-shared-network         # Actual network name
```

---

## Volumes Top-Level

```yaml
volumes:
  db-data:                          # Simple named volume
  
  nfs-data:                         # NFS mount
    driver: local
    driver_opts:
      type: nfs
      o: "addr=10.0.0.5,rw,nfsvers=4"
      device: ":/exports/data"

  cifs-data:                        # CIFS/SMB mount
    driver: local
    driver_opts:
      type: cifs
      o: "username=user,password=pass,addr=10.0.0.5"
      device: "//10.0.0.5/share"

  tmpfs-vol:                        # tmpfs volume
    driver: local
    driver_opts:
      type: tmpfs
      device: tmpfs
      o: "size=100m,uid=1000"

  external-vol:                     # Pre-existing volume
    external: true
    name: my-existing-volume

  labeled-vol:
    labels:
      com.example.backup: "daily"
```

---

## Extension Fields

Any top-level key starting with `x-` is ignored by Compose. Use with YAML anchors for DRY config.

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

x-healthcheck: &default-healthcheck
  interval: 10s
  timeout: 5s
  retries: 3
  start_period: 15s

x-common: &common-service
  restart: unless-stopped
  logging: *default-logging

services:
  api:
    <<: *common-service
    image: myapi
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      <<: *default-healthcheck

  worker:
    <<: *common-service
    image: myworker
    healthcheck:
      test: ["CMD", "worker-check"]
      <<: *default-healthcheck
```

Extension fields can be nested inside services too:

```yaml
services:
  app:
    x-metadata:
      team: backend
      oncall: "@backend-team"
```

---

## Variable Interpolation

### Syntax

```yaml
# Basic substitution
image: myapp:${TAG}

# Default value (if unset or empty)
image: myapp:${TAG:-latest}

# Default value (only if unset)
image: myapp:${TAG-latest}

# Error if unset or empty
image: myapp:${TAG:?TAG must be set}

# Error only if unset
image: myapp:${TAG?TAG must be set}

# Alternative value (use ALT if VAR is set)
image: myapp:${TAG:+custom}

# Escape literal $
command: echo $$HOME
```

### Source precedence (highest to lowest)

1. `docker compose run -e VAR=val`
2. `environment:` in compose.yaml
3. Shell environment
4. `--env-file` flag
5. `.env` file in project directory
6. `env_file:` directive
7. Dockerfile `ENV`

### .env file rules

- Located in the project directory (where compose.yaml is).
- Each line: `KEY=value` — no `export`, no spaces around `=`.
- Lines starting with `#` are comments.
- Quotes are preserved literally: `KEY="value"` → value is `"value"` (with quotes).
- Override location with `--env-file path/to/.env`.
