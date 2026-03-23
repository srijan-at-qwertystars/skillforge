# Docker to containerd/nerdctl Migration Guide

## Table of Contents

- [Overview](#overview)
- [CLI Command Mapping](#cli-command-mapping)
- [Dockerfile Compatibility](#dockerfile-compatibility)
- [Compose File Differences](#compose-file-differences)
- [Volume Migration](#volume-migration)
- [Network Migration](#network-migration)
- [Registry Auth Migration](#registry-auth-migration)
- [CI/CD Pipeline Updates](#cicd-pipeline-updates)
- [Feature Parity Gaps](#feature-parity-gaps)
- [Step-by-Step Migration Plan](#step-by-step-migration-plan)

---

## Overview

Migrating from Docker (dockerd + Docker CLI) to containerd + nerdctl eliminates the Docker daemon dependency while retaining a familiar CLI experience. containerd is the same runtime Docker uses internally, so container behavior remains identical.

### Why Migrate?

- Kubernetes deprecated dockershim — containerd is the standard CRI runtime
- Reduced attack surface (no Docker daemon socket)
- Lower resource overhead (one less daemon)
- Direct access to containerd features (namespaces, snapshotters, lazy pulling)
- nerdctl provides Docker CLI compatibility plus containerd-native extras

### Migration Scope

| Component | Docker | containerd + nerdctl |
|---|---|---|
| Runtime daemon | dockerd | containerd |
| CLI | docker | nerdctl |
| Build | Docker BuildKit | BuildKit (standalone) |
| Compose | docker compose | nerdctl compose |
| Networking | libnetwork | CNI plugins |
| Storage driver | overlay2, devicemapper | overlayfs, devmapper, btrfs, zfs |
| Registry auth | ~/.docker/config.json | ~/.docker/config.json (shared) |
| Socket | /var/run/docker.sock | /run/containerd/containerd.sock |

---

## CLI Command Mapping

### Container Management

| Docker | nerdctl | Differences |
|---|---|---|
| `docker run` | `nerdctl run` | Identical flags |
| `docker start` | `nerdctl start` | Identical |
| `docker stop` | `nerdctl stop` | Identical |
| `docker restart` | `nerdctl restart` | Identical |
| `docker rm` | `nerdctl rm` | Identical |
| `docker ps` | `nerdctl ps` | Identical flags |
| `docker exec` | `nerdctl exec` | Identical |
| `docker attach` | `nerdctl attach` | Identical |
| `docker logs` | `nerdctl logs` | Identical |
| `docker inspect` | `nerdctl inspect` | Identical output format |
| `docker cp` | `nerdctl cp` | Identical |
| `docker top` | `nerdctl top` | Identical |
| `docker stats` | `nerdctl stats` | Identical |
| `docker wait` | `nerdctl wait` | Identical |
| `docker kill` | `nerdctl kill` | Identical |
| `docker rename` | `nerdctl rename` | Identical |
| `docker diff` | Not available | No equivalent |
| `docker port` | `nerdctl port` | Identical |
| `docker pause` | `nerdctl pause` | Identical |
| `docker unpause` | `nerdctl unpause` | Identical |

### Image Management

| Docker | nerdctl | Differences |
|---|---|---|
| `docker pull` | `nerdctl pull` | nerdctl requires fully qualified names by default |
| `docker push` | `nerdctl push` | Identical |
| `docker build` | `nerdctl build` | Requires standalone BuildKit daemon |
| `docker images` | `nerdctl images` | Identical |
| `docker rmi` | `nerdctl rmi` | Identical |
| `docker tag` | `nerdctl tag` | Identical |
| `docker save` | `nerdctl save` | Identical |
| `docker load` | `nerdctl load` | Identical |
| `docker history` | `nerdctl history` | Identical |
| `docker image prune` | `nerdctl image prune` | Identical |
| `docker search` | Not available | Use registry API directly |
| `docker manifest` | `nerdctl manifest` | Identical |

### Network Management

| Docker | nerdctl | Differences |
|---|---|---|
| `docker network create` | `nerdctl network create` | Uses CNI, fewer driver options |
| `docker network ls` | `nerdctl network ls` | Identical |
| `docker network rm` | `nerdctl network rm` | Identical |
| `docker network inspect` | `nerdctl network inspect` | Different output (CNI format) |
| `docker network connect` | `nerdctl network connect` | May require container restart |
| `docker network disconnect` | `nerdctl network disconnect` | May require container restart |

### Volume Management

| Docker | nerdctl | Differences |
|---|---|---|
| `docker volume create` | `nerdctl volume create` | Identical |
| `docker volume ls` | `nerdctl volume ls` | Identical |
| `docker volume rm` | `nerdctl volume rm` | Identical |
| `docker volume inspect` | `nerdctl volume inspect` | Identical |
| `docker volume prune` | `nerdctl volume prune` | Identical |

### System Commands

| Docker | nerdctl | Differences |
|---|---|---|
| `docker info` | `nerdctl info` | Different output format |
| `docker version` | `nerdctl version` | Different output |
| `docker system df` | `nerdctl system df` | Identical |
| `docker system prune` | `nerdctl system prune` | Identical |
| `docker login` | `nerdctl login` | Shares ~/.docker/config.json |
| `docker logout` | `nerdctl logout` | Identical |
| `docker events` | `nerdctl events` | Identical |
| `docker context` | Not available | Use `--host` flag or `CONTAINERD_ADDRESS` env |

### Quick Migration: Shell Alias

For teams wanting immediate compatibility:

```bash
# Add to ~/.bashrc or ~/.zshrc
alias docker=nerdctl

# Or for system-wide (creates symlink)
sudo ln -sf /usr/local/bin/nerdctl /usr/local/bin/docker
```

**Caveats:** The alias works for most commands but will fail for Docker-specific features (Swarm, `docker context`, some plugin commands).

---

## Dockerfile Compatibility

nerdctl uses BuildKit for building, which is also the default builder in modern Docker. Dockerfile syntax is fully compatible.

### Fully Supported

- All `FROM`, `RUN`, `COPY`, `ADD`, `CMD`, `ENTRYPOINT`, `ENV`, `ARG`, `EXPOSE`, `VOLUME`, `WORKDIR`, `USER`, `LABEL` instructions
- Multi-stage builds
- BuildKit frontend directives (`# syntax=`)
- Build arguments and variable substitution
- `.dockerignore` files
- `HEALTHCHECK` instruction
- `SHELL` instruction
- `ONBUILD` triggers
- Heredoc syntax (`RUN <<EOF`)

### BuildKit-Specific Features (Work in Both)

```dockerfile
# syntax=docker/dockerfile:1

# Cache mounts (shared across builds)
RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements.txt

# Secret mounts (not persisted in image)
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm install

# SSH mounts (for private repos)
RUN --mount=type=ssh git clone git@github.com:private/repo.git

# Bind mounts from build context
RUN --mount=type=bind,source=package.json,target=/app/package.json npm install
```

### Key Difference: BuildKit Daemon Required

```bash
# Docker: BuildKit is integrated
docker build -t myapp .

# nerdctl: requires standalone buildkitd
sudo systemctl start buildkit
nerdctl build -t myapp .

# Check BuildKit is running
sudo systemctl status buildkit
```

---

## Compose File Differences

nerdctl compose is compatible with Docker Compose v2 YAML files. Most applications work without changes.

### Fully Supported Compose Features

```yaml
# These work identically in nerdctl compose
version: "3.8"
services:
  web:
    image: nginx:alpine
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8080:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
      - data:/data
    environment:
      - NODE_ENV=production
    env_file:
      - .env
    networks:
      - frontend
    depends_on:
      - db
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "10m"
    deploy:
      replicas: 1
      resources:
        limits:
          memory: 256M
          cpus: "0.5"

  db:
    image: postgres:16
    volumes:
      - pgdata:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD: secret

volumes:
  data:
  pgdata:

networks:
  frontend:
```

### Not Supported / Differences

| Feature | Docker Compose | nerdctl compose | Notes |
|---|---|---|---|
| `deploy.replicas` | Swarm mode | Local only | nerdctl supports `--scale` |
| `deploy.placement` | Swarm mode | Not supported | Swarm-specific |
| `configs` | Swarm configs | Not supported | Use volumes or env vars |
| `secrets` (Swarm) | Swarm secrets | Not supported | Use file-based secrets |
| `network_mode: service:X` | Supported | Partial support | May not work in all cases |
| `links` | Deprecated in Docker | Not supported | Use networks instead |
| `extends` | Supported | Supported | Works the same |
| `profiles` | Supported | Supported | Works the same |

### nerdctl Compose Extras

```yaml
# nerdctl-specific: IPFS image support
services:
  app:
    image: ipfs://bafybei...

# nerdctl-specific: specify containerd namespace
# Use: nerdctl --namespace myns compose up
```

---

## Volume Migration

### Export Docker Volumes

```bash
# List Docker volumes
docker volume ls

# Export a volume to a tar archive
docker run --rm -v myvolume:/data -v $(pwd):/backup alpine \
  tar czf /backup/myvolume.tar.gz -C /data .

# Export all volumes
for vol in $(docker volume ls -q); do
  echo "Exporting $vol..."
  docker run --rm -v "$vol":/data -v "$(pwd)/backups":/backup alpine \
    tar czf "/backup/${vol}.tar.gz" -C /data .
done
```

### Import Volumes into nerdctl

```bash
# Create volume in nerdctl
nerdctl volume create myvolume

# Import data
nerdctl run --rm -v myvolume:/data -v $(pwd):/backup alpine \
  sh -c "cd /data && tar xzf /backup/myvolume.tar.gz"

# Import all volumes
for archive in backups/*.tar.gz; do
  vol=$(basename "$archive" .tar.gz)
  echo "Importing $vol..."
  nerdctl volume create "$vol"
  nerdctl run --rm -v "$vol":/data -v "$(pwd)/backups":/backup alpine \
    sh -c "cd /data && tar xzf /backup/${vol}.tar.gz"
done
```

### Volume Storage Locations

```bash
# Docker volumes
/var/lib/docker/volumes/

# nerdctl volumes (default namespace)
/var/lib/nerdctl/default/volumes/

# nerdctl volumes (custom namespace)
/var/lib/nerdctl/<namespace>/volumes/
```

### Bind Mounts

Bind mounts work identically — no migration needed:

```bash
# Same syntax in both
docker run -v /host/path:/container/path myimage
nerdctl run -v /host/path:/container/path myimage
```

---

## Network Migration

### Key Differences

| Aspect | Docker (libnetwork) | nerdctl (CNI) |
|---|---|---|
| Plugin system | Docker network plugins | CNI plugins |
| Default bridge | docker0 | nerdctl0 |
| Default subnet | 172.17.0.0/16 | 10.4.0.0/24 |
| Config files | N/A (API-driven) | /etc/cni/net.d/*.conflist |
| DNS | Embedded DNS server | CNI DNS plugin |
| Network drivers | bridge, overlay, macvlan, host, none | bridge, macvlan, ipvlan, host, none |
| Overlay networks | Built-in (Swarm) | Not supported (use k8s CNI) |

### Recreate Networks

```bash
# List Docker networks
docker network ls
docker network inspect mynetwork

# Recreate in nerdctl
nerdctl network create --subnet 172.20.0.0/16 mynetwork

# Custom bridge with gateway
nerdctl network create --subnet 10.0.0.0/24 --gateway 10.0.0.1 mynetwork
```

### Docker Compose Network Migration

Networks defined in compose files work automatically:

```yaml
# Works in both docker compose and nerdctl compose
networks:
  backend:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
```

### Port Mapping Changes

Port mapping syntax is identical, but the underlying mechanism differs (CNI portmap vs Docker proxy):

```bash
# Same syntax
nerdctl run -p 8080:80 nginx
nerdctl run -p 127.0.0.1:8080:80 nginx
nerdctl run -p 8080:80/udp nginx
```

**Note:** Docker's `docker-proxy` user-space proxy is not used. CNI's portmap plugin uses iptables directly, which is generally more performant.

---

## Registry Auth Migration

### Shared Credential File

Both Docker and nerdctl use `~/.docker/config.json` for registry credentials. No migration is needed for basic auth.

```bash
# Verify existing credentials work with nerdctl
cat ~/.docker/config.json | jq '.auths | keys'
nerdctl pull myregistry.io/myimage:tag
```

### Credential Helpers

Docker credential helpers work with nerdctl:

```json
// ~/.docker/config.json
{
  "credHelpers": {
    "123456789.dkr.ecr.us-east-1.amazonaws.com": "ecr-login",
    "gcr.io": "gcr",
    "us-docker.pkg.dev": "gcloud"
  }
}
```

Ensure the helper binaries are installed:

```bash
# Verify credential helpers are in PATH
which docker-credential-ecr-login
which docker-credential-gcr
which docker-credential-gcloud
```

### Kubernetes CRI Registry Auth

For Kubernetes nodes, containerd CRI uses a different auth path:

```bash
# Docker: kubelet uses docker config
# containerd CRI: configure in config.toml or use hosts.toml

# Option 1: reference docker config in containerd
# In kubelet config:
# imageCredentialProviderConfigFile: /etc/kubernetes/credential-providers.yaml

# Option 2: hosts.toml with inline auth
sudo mkdir -p /etc/containerd/certs.d/myregistry.io
cat <<EOF | sudo tee /etc/containerd/certs.d/myregistry.io/hosts.toml
server = "https://myregistry.io"
[host."https://myregistry.io"]
  capabilities = ["pull", "resolve", "push"]
  # TLS certs if needed
  ca = "/etc/containerd/certs.d/myregistry.io/ca.crt"
EOF
```

### Mirror Configuration Differences

```bash
# Docker: /etc/docker/daemon.json
{
  "registry-mirrors": ["https://mirror.example.com"]
}

# containerd: /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"
[host."https://mirror.example.com"]
  capabilities = ["pull", "resolve"]
```

---

## CI/CD Pipeline Updates

### GitHub Actions

```yaml
# Before (Docker)
- name: Build and push
  uses: docker/build-push-action@v5
  with:
    push: true
    tags: myregistry.io/myapp:latest

# After (nerdctl) — use shell commands
- name: Install nerdctl
  run: |
    wget -q https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-full-2.2.1-linux-amd64.tar.gz
    sudo tar -C /usr/local -xzf nerdctl-full-2.2.1-linux-amd64.tar.gz
    sudo systemctl start containerd buildkit

- name: Build and push
  run: |
    nerdctl login -u ${{ secrets.REGISTRY_USER }} -p ${{ secrets.REGISTRY_PASS }} myregistry.io
    nerdctl build -t myregistry.io/myapp:latest .
    nerdctl push myregistry.io/myapp:latest
```

**Note:** Many CI systems still use Docker natively. Consider whether migration is necessary in CI — containerd migration is most impactful on Kubernetes nodes and production servers.

### GitLab CI

```yaml
# Before (Docker-in-Docker)
build:
  image: docker:24
  services:
    - docker:24-dind
  script:
    - docker build -t myapp .
    - docker push myapp

# After (nerdctl)
build:
  image: ubuntu:22.04
  before_script:
    - apt-get update && apt-get install -y wget
    - wget -q https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-full-2.2.1-linux-amd64.tar.gz
    - tar -C /usr/local -xzf nerdctl-full-2.2.1-linux-amd64.tar.gz
    - containerd &
    - buildkitd &
    - sleep 3
  script:
    - nerdctl build -t myapp .
    - nerdctl push myapp
```

### Jenkins

```groovy
// Before (Docker Pipeline plugin)
pipeline {
    agent any
    stages {
        stage('Build') {
            steps {
                script {
                    docker.build('myapp:latest')
                    docker.withRegistry('https://myregistry.io', 'registry-creds') {
                        docker.image('myapp:latest').push()
                    }
                }
            }
        }
    }
}

// After (nerdctl via shell)
pipeline {
    agent any
    stages {
        stage('Build') {
            steps {
                sh 'nerdctl build -t myregistry.io/myapp:latest .'
                withCredentials([usernamePassword(credentialsId: 'registry-creds', usernameVariable: 'USER', passwordVariable: 'PASS')]) {
                    sh 'nerdctl login -u $USER -p $PASS myregistry.io'
                    sh 'nerdctl push myregistry.io/myapp:latest'
                }
            }
        }
    }
}
```

### Script Migration Pattern

```bash
# Generic find-and-replace for simple scripts
# (Review each change — not all are direct replacements)
sed -i 's/\bdocker\b/nerdctl/g' deploy.sh

# Better: create a wrapper that logs deprecated usage
cat > /usr/local/bin/docker-wrapper <<'EOF'
#!/bin/bash
echo "[WARN] docker CLI is deprecated. Use nerdctl instead." >&2
echo "[WARN] Command: nerdctl $*" >&2
exec nerdctl "$@"
EOF
chmod +x /usr/local/bin/docker-wrapper
# Symlink to catch docker calls
sudo mv /usr/local/bin/docker /usr/local/bin/docker.bak
sudo ln -s /usr/local/bin/docker-wrapper /usr/local/bin/docker
```

---

## Feature Parity Gaps

### Features NOT Available in nerdctl

| Docker Feature | Status in nerdctl | Alternative |
|---|---|---|
| Docker Swarm | Not supported | Use Kubernetes |
| `docker context` | Not supported | Use `--host` flag or env vars |
| `docker search` | Not supported | Use registry API or web UI |
| `docker diff` | Not supported | Use `ctr snapshots diff` |
| `docker plugin` (managed plugins) | Not supported | Use CNI / snapshotter plugins |
| Docker Desktop | Not applicable | Use Lima, Colima, or Rancher Desktop |
| Docker Extensions | Not supported | N/A |
| Docker Scout | Not supported | Use Trivy, Grype |
| Docker Build Cloud | Not supported | Use self-hosted BuildKit |
| `/var/run/docker.sock` mounting | Not available | Mount containerd socket or use nerdctl API |
| `DOCKER_HOST` env var | Not supported | Use `CONTAINERD_ADDRESS` |
| Docker log drivers (syslog, gelf, fluentd) | Limited | Use json-file or journald, pipe to fluentd |
| Docker health check in `docker ps` | Supported | Works the same |

### nerdctl Features NOT in Docker

| Feature | Description |
|---|---|
| Namespaces | Isolate resources across namespaces |
| Lazy pulling (stargz/nydus) | Start containers before full image download |
| Image encryption (OCIcrypt) | Encrypt container images natively |
| Image signing (cosign) | Verify image signatures at pull time |
| IPFS image distribution | Pull images from IPFS |
| Image conversion | Convert between formats (estargz, nydus, OCI) |
| Rootless by design | First-class rootless support |
| FreeBSD support | Experimental FreeBSD containers |

### Docker Socket Dependency

Applications that mount `/var/run/docker.sock` (monitoring tools, CI runners, etc.) need special attention:

```bash
# Common tools that mount Docker socket:
# - Portainer
# - Traefik (Docker provider)
# - Watchtower
# - GitLab Runner (Docker executor)
# - Jenkins (Docker agent)

# Options:
# 1. Use nerdctl API (limited)
# 2. Use containerd socket with compatible tools
# 3. Keep Docker alongside containerd for these specific tools
# 4. Switch to Kubernetes-native alternatives
```

---

## Step-by-Step Migration Plan

### Phase 1: Preparation (1-2 weeks)

```bash
# 1. Audit current Docker usage
docker info
docker ps -a
docker images
docker volume ls
docker network ls

# 2. Document all Docker socket mounts
grep -r "docker.sock" /etc/ ~/
grep -r "docker.sock" /opt/ 2>/dev/null

# 3. List all Docker-dependent CI/CD pipelines
# Review .github/workflows/, .gitlab-ci.yml, Jenkinsfile, etc.

# 4. Test nerdctl compatibility in a dev environment
# Install nerdctl alongside Docker and verify key workflows
```

### Phase 2: Install containerd + nerdctl (Day 1)

```bash
# 1. Install containerd and nerdctl
wget https://github.com/containerd/nerdctl/releases/download/v2.2.1/nerdctl-full-2.2.1-linux-amd64.tar.gz
sudo tar -C /usr/local -xzf nerdctl-full-2.2.1-linux-amd64.tar.gz
sudo systemctl enable --now containerd buildkit

# 2. Verify installation
nerdctl version
nerdctl info
nerdctl run --rm alpine echo "containerd works"
```

### Phase 3: Migrate Data (Day 1-2)

```bash
# 1. Export Docker images
docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' > image-list.txt
docker save $(cat image-list.txt | tr '\n' ' ') -o all-images.tar

# 2. Import into containerd
nerdctl load -i all-images.tar

# 3. Migrate volumes (see Volume Migration section)

# 4. Migrate networks (see Network Migration section)
```

### Phase 4: Switch Workloads (Day 2-3)

```bash
# 1. Stop Docker containers
docker compose down  # for each compose project

# 2. Start with nerdctl
nerdctl compose up -d  # same compose files

# 3. Verify services
nerdctl ps
nerdctl logs <container>
curl http://localhost:<port>  # test endpoints
```

### Phase 5: Cleanup (Day 3-5)

```bash
# 1. Verify everything works on containerd
# Monitor for 24-48 hours

# 2. Stop and disable Docker
sudo systemctl stop docker docker.socket
sudo systemctl disable docker docker.socket

# 3. Optional: remove Docker
sudo apt-get purge docker-ce docker-ce-cli
sudo rm -rf /var/lib/docker

# 4. Set up alias for team convenience
echo 'alias docker=nerdctl' | sudo tee /etc/profile.d/nerdctl.sh
```

### Rollback Plan

```bash
# If issues arise, re-enable Docker:
sudo systemctl start docker
docker compose up -d

# nerdctl and Docker can coexist temporarily
# Docker uses "moby" namespace in containerd
# nerdctl uses "default" namespace
```
