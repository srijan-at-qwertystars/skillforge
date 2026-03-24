---
name: podman-patterns
description: >
  Expert guidance for Podman container workflows including rootless containers, pod management,
  podman compose, Buildah image building, Skopeo image operations, Quadlet systemd integration,
  podman machine setup, Netavark networking, secrets management, auto-updates, multi-arch builds,
  and security hardening. Triggers on: Podman, podman compose, rootless containers, podman pod,
  podman generate systemd, podman machine, Buildah, Skopeo, Quadlet, Netavark, podman play kube,
  podman farm build, podman secret, podman auto-update, Containerfile.
  NOT for Docker-specific features (Docker Swarm, Docker Desktop licensing), Kubernetes pod
  management, or containerd/nerdctl without Podman context.
---

# Podman Patterns

## Core Concepts: Podman vs Docker

Podman is daemonless — each container runs as a child process, no root daemon required. CLI is
Docker-compatible (`alias docker=podman` works for most commands). Key differences:

- **No daemon**: `podman` forks directly; no `dockerd` service to manage.
- **Rootless by default**: Containers run under user namespaces without privilege escalation.
- **Pods**: First-class pod concept (shared namespaces) matching Kubernetes pod semantics.
- **Systemd integration**: Quadlet files (`.container`, `.pod`, `.volume`, `.network`) replace
  fragile hand-written unit files. `podman generate systemd` is legacy — prefer Quadlet.
- **Image tools**: Buildah (build), Skopeo (copy/inspect), Podman (run) — separation of concerns.
- **Storage**: SQLite backend (default in 5.x), replacing BoltDB.
- **Networking**: Netavark + Aardvark-DNS replaced CNI in 5.x. Rootless uses `pasta` (replaced
  slirp4netns).

## Rootless Containers

Prerequisites: user entries in `/etc/subuid` and `/etc/subgid` for UID/GID mapping.

```bash
# Check mappings
grep $USER /etc/subuid /etc/subgid

# Run rootless container
podman run --rm -p 8080:80 docker.io/library/nginx:alpine

# Rootless uses pasta networking by default (Podman 5.x)
# Ports < 1024 work via net.ipv4.ip_unprivileged_port_start=0
echo 'net.ipv4.ip_unprivileged_port_start=0' | sudo tee /etc/sysctl.d/podman-rootless.conf
sudo sysctl --system
```

Rootless storage lives in `~/.local/share/containers/storage/`. Config files:
- `~/.config/containers/containers.conf` — runtime config
- `~/.config/containers/registries.conf` — registry mirrors/search
- `~/.config/containers/storage.conf` — storage driver

## Pod Management

Pods share network namespace (localhost communication between containers).

```bash
# Create pod with port mapping
podman pod create --name webapp -p 8080:80 -p 5432:5432

# Add containers to pod
podman run -d --pod webapp --name web nginx:alpine
podman run -d --pod webapp --name db \
  -e POSTGRES_PASSWORD=secret postgres:16-alpine

# Containers in same pod communicate via localhost
podman exec web curl -s localhost:5432

# List / inspect / remove
podman pod ls
podman pod inspect webapp
podman pod stop webapp && podman pod rm webapp
```

## Podman Compose

`podman compose` (v1.x bundled, or via `podman-compose` Python package) reads standard
`docker-compose.yml` / `compose.yaml` files.

```bash
# Using built-in compose (requires compose provider)
podman compose up -d
podman compose logs -f
podman compose down

# Or standalone podman-compose
pip install podman-compose
podman-compose up -d
```

Podman compose maps services to a pod with shared networking. Set provider in
`containers.conf`:

```ini
[engine]
compose_providers = ["/usr/libexec/docker/cli-plugins/docker-compose"]
```

## Buildah: Image Building

Buildah builds OCI images without a daemon. Two modes:

### Dockerfile/Containerfile build
```bash
buildah bud -t myapp:latest -f Containerfile .
# Equivalent shorthand:
buildah build -t myapp:latest .
```

### Scripted (shell-based) builds
```bash
ctr=$(buildah from registry.access.redhat.com/ubi9/ubi-minimal:latest)
buildah run $ctr -- microdnf install -y python3 && microdnf clean all
buildah copy $ctr ./app /opt/app
buildah config --workingdir /opt/app --cmd "python3 main.py" $ctr
buildah commit $ctr myapp:latest
buildah rm $ctr
```

### Multi-arch builds with `podman farm` or `buildah`
```bash
# Farm build across remote nodes
podman farm build -t quay.io/user/myapp:latest .

# Or with buildah manifest
buildah manifest create myapp:latest
buildah bud --platform linux/amd64 --manifest myapp:latest .
buildah bud --platform linux/arm64 --manifest myapp:latest .
buildah manifest push --all myapp:latest docker://quay.io/user/myapp:latest
```

## Skopeo: Image Management

Inspect and copy images between registries without pulling full layers.

```bash
# Inspect remote image (no pull)
skopeo inspect docker://docker.io/library/nginx:alpine

# Copy between registries
skopeo copy docker://quay.io/org/app:v1 docker://registry.internal/app:v1

# Copy to local dir (OCI layout)
skopeo copy docker://nginx:alpine oci:./nginx-local:latest

# Sync entire repo
skopeo sync --src docker --dest dir docker.io/library/nginx /backups/nginx

# Delete remote tag
skopeo delete docker://registry.internal/app:old-tag
```

## Quadlet: Systemd Integration (Preferred over `podman generate systemd`)

Place `.container`, `.pod`, `.volume`, `.network` files in:
- Rootless: `~/.config/containers/systemd/`
- Root: `/etc/containers/systemd/`

### Container unit
```ini
# ~/.config/containers/systemd/webapp.container
[Unit]
Description=Web application

[Container]
Image=docker.io/library/nginx:alpine
PublishPort=8080:80
Volume=webapp-data.volume:/usr/share/nginx/html:Z
Network=webapp.network
AutoUpdate=registry
Secret=app-tls-cert,type=mount,target=/certs/cert.pem

[Service]
Restart=always
TimeoutStartSec=120

[Install]
WantedBy=default.target
```

### Volume and Network units
```ini
# webapp-data.volume
[Volume]
User=1000
Group=1000

# webapp.network
[Network]
Subnet=10.89.1.0/24
Gateway=10.89.1.1
```

### Pod unit with linked containers
```ini
# fullstack.pod
[Pod]
PublishPort=8080:80
PublishPort=5432:5432

# fullstack-web.container
[Container]
Image=nginx:alpine
Pod=fullstack.pod

# fullstack-db.container
[Container]
Image=postgres:16-alpine
Pod=fullstack.pod
Environment=POSTGRES_PASSWORD=secret
```

Activate: `systemctl --user daemon-reload && systemctl --user start webapp`

## Podman Machine (macOS / Windows)

```bash
# Initialize VM (uses Apple Hypervisor on macOS, WSL2/HyperV on Windows)
podman machine init --cpus 4 --memory 4096 --disk-size 60

# Start / stop / SSH
podman machine start
podman machine stop
podman machine ssh

# Reset all VMs (required when upgrading from Podman 4.x to 5.x)
podman machine reset

# List machines
podman machine ls

# Set rootful mode (for binding ports < 1024)
podman machine set --rootful
```

macOS 5.x uses native Apple Hypervisor (applehv) with virtiofs for file sharing.
Windows uses WSL2 or HyperV backend.

## Networking (Netavark + Aardvark-DNS)

Netavark is the default network stack in Podman 5.x (replaced CNI). Aardvark provides
built-in DNS resolution by container name.

```bash
# Create custom network
podman network create --subnet 10.89.2.0/24 --gateway 10.89.2.1 mynet

# Run container on custom network
podman run -d --network mynet --name svc1 nginx:alpine

# Containers on same network resolve each other by name
podman run --rm --network mynet curlimages/curl curl http://svc1

# Connect running container to additional network
podman network connect mynet existing-container

# Inspect / list / remove
podman network inspect mynet
podman network ls
podman network rm mynet

# Rootless networking uses pasta (Podman 5.x default, replaced slirp4netns)
# For IPv6 in rootless: pasta supports it natively
```

## Volumes and Mounts

```bash
# Named volume
podman volume create appdata
podman run -v appdata:/data myapp

# Bind mount with SELinux relabeling
podman run -v ./src:/app:Z myapp        # :Z = private relabel, :z = shared

# tmpfs mount
podman run --mount type=tmpfs,destination=/tmp,tmpfs-size=64M myapp

# Mount propagation for nested containers
podman run -v /var/lib/containers:/var/lib/containers:rslave ...
```

## Secrets Management

```bash
# Create from stdin
printf 'db-password-value' | podman secret create db_pass -

# Create from file
podman secret create tls_cert ./server.crt

# Create from env var
export API_KEY=abc123
podman secret create --env api_key API_KEY

# Use as file (default: /run/secrets/<name>)
podman run --secret db_pass -e DB_PASS_FILE=/run/secrets/db_pass myapp

# Use as environment variable
podman run --secret db_pass,type=env,target=DB_PASSWORD myapp

# List / inspect / remove
podman secret ls
podman secret inspect db_pass    # shows metadata only, never the value
podman secret rm db_pass
```

In Quadlet, reference with: `Secret=db_pass,type=env,target=DB_PASSWORD`

## Auto-Update

```bash
# Label container for auto-update
podman run -d --label io.containers.autoupdate=registry \
  --name webapp docker.io/library/nginx:latest

# Or in Quadlet: AutoUpdate=registry

# Check for updates (dry run)
podman auto-update --dry-run

# Apply updates
podman auto-update

# Enable systemd timer for scheduled updates
systemctl --user enable --now podman-auto-update.timer
```

Auto-update pulls newer image from registry, recreates container with same config.

## Podman Play Kube

Deploy Kubernetes YAML directly on Podman (no cluster needed).

```bash
# Deploy from YAML
podman kube play deployment.yaml

# Deploy with configmap and down
podman kube play pod.yaml --configmap configmap.yaml
podman kube down pod.yaml

# Generate Kube YAML from running pod/container
podman kube generate webapp > webapp-pod.yaml

# Apply with replace (update existing)
podman kube play --replace deployment.yaml
```

## Security Hardening

```bash
# Drop all capabilities, add only needed
podman run --cap-drop=ALL --cap-add=NET_BIND_SERVICE myapp

# Read-only root filesystem
podman run --read-only --tmpfs /tmp myapp

# Custom seccomp profile
podman run --security-opt seccomp=custom-profile.json myapp

# No new privileges
podman run --security-opt no-new-privileges:true myapp

# SELinux: use :Z/:z for volume labels, or disable per-container
podman run --security-opt label=disable myapp

# Run with specific user
podman run --user 1000:1000 myapp

# Limit resources
podman run --memory 512m --cpus 1.5 --pids-limit 100 myapp

# Inspect capabilities of running container
podman inspect --format '{{.EffectiveCaps}}' <container>
```

## References

Deep-dive guides in `references/`:

- **[Advanced Patterns](references/advanced-patterns.md)** — Quadlet deep dive (`.container`,
  `.volume`, `.network`, `.kube`, `.image`, `.pod` units), podman farm multi-arch, pasta
  networking, HyperV/Apple Hypervisor, machine customization, health checks, pod resource
  limits, init/infra containers.

- **[Troubleshooting](references/troubleshooting.md)** — Rootless networking (slirp4netns vs
  pasta), SELinux denials (`:Z`/`:z`), cgroup v2, storage drivers (overlay vs fuse-overlayfs),
  machine disk/memory, Docker migration, permission errors, DNS resolution.

- **[Buildah & Skopeo Guide](references/buildah-skopeo-guide.md)** — Buildah (multi-stage,
  scratch, mount/copy/run), Skopeo (copy, inspect, sync, login), image signing (sigstore, GPG),
  registry mirroring, CI/CD integration (GitHub Actions, GitLab CI, Jenkins, Tekton).

## Scripts

Ready-to-use scripts in `scripts/` (all `chmod +x`):

- **[migrate-from-docker.sh](scripts/migrate-from-docker.sh)** — Migrate Docker images, volumes,
  containers to Podman. Flags: `--all`, `--images`, `--volumes`, `--containers`, `--dry-run`.
- **[setup-quadlet.sh](scripts/setup-quadlet.sh)** — Generate Quadlet units from running
  containers. Flags: `--all`, `--with-volumes`, `--with-networks`, `--rootful`, `--dry-run`.
- **[podman-health-check.sh](scripts/podman-health-check.sh)** — Check Podman installation,
  storage, networking, cgroups, SELinux health. Flags: `--full`, `--quick`, `--fix`, `--json`.

## Assets

Templates in `assets/`:

- **`quadlet-templates/`** — `.container`, `.volume`, `.network`, `.pod` Quadlet templates
- **[podman-compose-template.yml](assets/podman-compose-template.yml)** — Production compose
  with health checks, resource limits, SELinux labels, secrets
- **[registries.conf](assets/registries.conf)** — Registry mirrors, search, aliases, blocking
- **[storage.conf](assets/storage.conf)** — Storage driver config (overlay, fuse-overlayfs)
- **[containers.conf](assets/containers.conf)** — Global Podman config (engine, network, machine)

## Quick Reference: Common Patterns

| Task | Command |
|------|---------|
| Migrate Docker Compose | `podman compose up -d` (reads compose.yaml) |
| Generate Quadlet from running | `podman generate systemd --new --files <ctr>` (legacy) |
| Run healthcheck | `podman healthcheck run <ctr>` |
| Export/import image | `podman save -o img.tar myapp` / `podman load -i img.tar` |
| Prune unused resources | `podman system prune --all --volumes` |
| Check rootless info | `podman info --format '{{.Host.Security.Rootless}}'` |
| Attach to running | `podman attach <ctr>` or `podman exec -it <ctr> /bin/sh` |
| View logs with timestamps | `podman logs -t --since 1h <ctr>` |
| Container resource stats | `podman stats --no-stream` |

## Examples

### Example 1: Rootless web app with Quadlet

**User input**: "Set up an nginx reverse proxy as a rootless systemd service using Podman"

**Output**:
```ini
# ~/.config/containers/systemd/nginx-proxy.container
[Unit]
Description=Nginx reverse proxy

[Container]
Image=docker.io/library/nginx:alpine
PublishPort=8080:80
Volume=%h/nginx/conf.d:/etc/nginx/conf.d:ro,Z
Volume=%h/nginx/certs:/etc/nginx/certs:ro,Z
AutoUpdate=registry

[Service]
Restart=always

[Install]
WantedBy=default.target
```
Then: `systemctl --user daemon-reload && systemctl --user enable --now nginx-proxy`

### Example 2: Multi-service pod with shared networking

**User input**: "Create a Podman pod with Redis and a Python API that talks to it"

**Output**:
```bash
podman pod create --name api-stack -p 8000:8000
podman run -d --pod api-stack --name redis redis:7-alpine
podman run -d --pod api-stack --name api \
  -e REDIS_HOST=localhost -e REDIS_PORT=6379 \
  myapi:latest
# Both containers share localhost — API reaches Redis at localhost:6379
```

### Example 3: Buildah CI pipeline image

**User input**: "Build a minimal Python image with Buildah in CI without Docker"

**Output**:
```bash
ctr=$(buildah from docker.io/library/python:3.12-slim)
buildah run $ctr -- pip install --no-cache-dir -r requirements.txt
buildah copy $ctr . /app
buildah config --workingdir /app --entrypoint '["python", "main.py"]' $ctr
buildah commit --squash $ctr myapp:latest
buildah push myapp:latest docker://ghcr.io/org/myapp:latest
```

### Example 4: Skopeo mirror + Secrets injection

```bash
# Mirror all architectures to private registry
skopeo copy --all docker://docker.io/library/nginx:alpine \
  docker://registry.internal:5000/library/nginx:alpine

# Pass secrets securely via podman secret
printf '%s' "$DB_PASSWORD" | podman secret create db_pass -
podman run -d --name mydb \
  --secret db_pass,type=env,target=POSTGRES_PASSWORD \
  postgres:16-alpine
```

<!-- tested: pass -->
