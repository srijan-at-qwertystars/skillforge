---
name: dockerfile-best-practices
description: >
  Use when writing, reviewing, or optimizing Dockerfiles, docker-compose files, or container images.
  Trigger on mentions of Docker layer caching, multi-stage builds, image size reduction, container
  security hardening, BuildKit, .dockerignore, HEALTHCHECK, distroless, alpine, scratch base images,
  non-root containers, Docker build secrets, or CI/CD container pipelines.
  Do NOT use for Kubernetes manifests, Helm charts, Docker Swarm orchestration, container runtime
  configuration (containerd/CRI-O), or general Linux system administration.
---

# Dockerfile Best Practices

## Multi-Stage Builds

Use multi-stage builds to separate build dependencies from the runtime image. Never ship compilers, SDKs, or package managers in production.

### Pattern: Compiled Language (Go)

```dockerfile
# syntax=docker/dockerfile:1

FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app ./cmd/server

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

### Pattern: Node.js with Asset Compilation

```dockerfile
# syntax=docker/dockerfile:1

FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

FROM deps AS build
COPY . .
RUN npm run build

FROM node:22-alpine AS production
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup -S app && adduser -S app -G app -u 1001
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
USER app
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "dist/index.js"]
```

### Pattern: Python with Virtual Environment

```dockerfile
# syntax=docker/dockerfile:1

FROM python:3.13-slim AS builder
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-compile -r requirements.txt

FROM python:3.13-slim
WORKDIR /app
RUN groupadd -r app && useradd -r -g app -u 1001 app
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY --chown=app:app . .
USER app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"
CMD ["gunicorn", "app:app", "--bind", "0.0.0.0:8000"]
```

## Layer Optimization

### Order Instructions by Change Frequency

Place least-changing instructions first. Docker invalidates all layers after the first changed layer.

```dockerfile
# GOOD: dependencies cached separately from source
COPY package.json package-lock.json ./
RUN npm ci
COPY . .

# BAD: any source change invalidates npm ci cache
COPY . .
RUN npm ci
```

### Combine RUN Commands

Merge related operations into one RUN to reduce layers and prevent leftover artifacts.

```dockerfile
# GOOD: single layer, cache cleaned
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      curl \
      ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# BAD: cleanup in separate layer doesn't reduce image size
RUN apt-get update
RUN apt-get install -y curl ca-certificates
RUN rm -rf /var/lib/apt/lists/*
```

### Pin Versions

Pin base images and packages for reproducible builds.

```dockerfile
# GOOD: pinned digest
FROM node:22.12.0-alpine3.21@sha256:abc123...

# GOOD: pinned package versions
RUN apk add --no-cache curl=8.12.1-r0

# BAD: floating tags
FROM node:latest
```

## Security

### Non-Root Users

Never run containers as root. Create a dedicated user with a fixed UID.

```dockerfile
# Alpine
RUN addgroup -S app && adduser -S app -G app -u 1001
USER app

# Debian/Ubuntu
RUN groupadd -r app && useradd -r -g app -u 1001 -s /bin/false app
USER app

# Distroless (already non-root)
FROM gcr.io/distroless/static:nonroot
USER nonroot:nonroot
```

### Minimal Base Images

Choose the smallest base that supports your runtime:

| Base Image | Size | Shell | Package Manager | Use Case |
|---|---|---|---|---|
| `scratch` | 0 MB | No | No | Static binaries (Go, Rust) |
| `distroless` | ~2 MB | No | No | Compiled apps needing libc |
| `alpine` | ~7 MB | Yes | apk | Apps needing shell/tools |
| `*-slim` | ~80 MB | Yes | apt | Apps needing glibc |

### Secret Handling with BuildKit

Never use ARG or ENV for secrets. Use BuildKit secret mounts.

```dockerfile
# syntax=docker/dockerfile:1

# Mount secret at build time — never stored in image layers
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm ci
```

Build command:

```bash
docker build --secret id=npmrc,src=$HOME/.npmrc .
```

### Drop Capabilities and Read-Only Filesystem

Apply at runtime, not in the Dockerfile:

```bash
docker run \
  --cap-drop=ALL \
  --cap-add=NET_BIND_SERVICE \
  --read-only \
  --tmpfs /tmp \
  --security-opt=no-new-privileges \
  myimage
```

## .dockerignore

Always create a `.dockerignore` to exclude unnecessary files from the build context.

```text
.git
.github
.vscode
node_modules
dist
*.md
!README.md
Dockerfile*
docker-compose*
.env*
__pycache__
*.pyc
.pytest_cache
coverage
.nyc_output
tests
```

Omitting `.dockerignore` sends the entire directory (including `.git`) as build context, slowing builds and risking secret leakage.

## Health Checks

Define HEALTHCHECK in every production Dockerfile. Orchestrators use it to determine container readiness.

```dockerfile
# HTTP check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

# TCP check (no curl available)
HEALTHCHECK --interval=30s --timeout=3s \
  CMD ["sh", "-c", "exec 3<>/dev/tcp/localhost/8080 || exit 1"]

# For distroless (no shell) — use the app itself
HEALTHCHECK --interval=30s --timeout=3s \
  CMD ["/app", "--healthcheck"]
```

## Common Anti-Patterns

| Anti-Pattern | Fix |
|---|---|
| `FROM ubuntu:latest` | Pin version + digest: `FROM ubuntu:24.04@sha256:abc...` |
| Running as root (no `USER`) | Create non-root user, add `USER app` |
| `COPY . .` before dep install | Copy lockfile first, install deps, then `COPY . .` |
| Secrets in `ARG`/`ENV` | Use `--mount=type=secret` (BuildKit) |
| Separate `RUN apt-get update` and `install` | Combine in one RUN with `rm -rf /var/lib/apt/lists/*` |
| Installing vim, wget, net-tools in prod | Use `--no-install-recommends`, only install what's needed |
| Missing `.dockerignore` | Always create one (see section above) |
| `ENTRYPOINT` with shell form | Use exec form: `ENTRYPOINT ["/app"]` |

## BuildKit Features

Enable BuildKit: `export DOCKER_BUILDKIT=1` (default in Docker 23.0+).

### Cache Mounts

Persist package manager caches across builds. Reduces rebuild time by 50–70%.

```dockerfile
# pip
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

# apt
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    apt-get update && apt-get install -y curl

# npm
RUN --mount=type=cache,target=/root/.npm \
    npm ci

# Go modules
RUN --mount=type=cache,target=/go/pkg/mod \
    go build -o /app .

# Maven
RUN --mount=type=cache,target=/root/.m2 \
    mvn package -DskipTests
```

### Secret Mounts

Inject secrets that never persist in image layers.

```dockerfile
# Single secret
RUN --mount=type=secret,id=aws_creds,target=/root/.aws/credentials \
    aws s3 cp s3://bucket/data /data

# Multiple secrets
RUN --mount=type=secret,id=gh_token \
    --mount=type=secret,id=npm_token \
    GH_TOKEN=$(cat /run/secrets/gh_token) \
    NPM_TOKEN=$(cat /run/secrets/npm_token) \
    npm ci
```

Build with:

```bash
docker build \
  --secret id=gh_token,src=./gh_token.txt \
  --secret id=npm_token,src=./npm_token.txt \
  .
```

### SSH Mounts

Clone private repos without copying keys into the image.

```dockerfile
RUN --mount=type=ssh \
    git clone git@github.com:org/private-repo.git /src
```

Build with:

```bash
eval $(ssh-agent) && ssh-add ~/.ssh/id_ed25519
docker build --ssh default .
```

### Heredocs

Inline multi-line scripts without shell gymnastics (BuildKit + dockerfile:1.4+).

```dockerfile
# syntax=docker/dockerfile:1

RUN <<EOF
  set -e
  apt-get update
  apt-get install -y --no-install-recommends curl
  rm -rf /var/lib/apt/lists/*
EOF

COPY <<EOF /etc/app/config.yaml
server:
  port: 8080
  host: 0.0.0.0
EOF
```

## docker-compose Best Practices

```yaml
# compose.yaml
services:
  api:
    build:
      context: .
      target: production
    restart: unless-stopped
    read_only: true
    tmpfs: [/tmp]
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
    env_file: [.env]
    depends_on:
      db:
        condition: service_healthy
    networks: [backend]

  db:
    image: postgres:17-alpine
    volumes: [pgdata:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
    networks: [backend]

volumes:
  pgdata:

networks:
  backend:
```

Key rules: set `restart: unless-stopped`; use `depends_on` with `condition: service_healthy`; set resource limits; use named volumes (not bind mounts) for persistent data; use `read_only: true` + `tmpfs`; pin all image versions.

## Image Scanning & CI Integration

### Scan in CI Before Push

```yaml
# GitHub Actions example
- name: Build image
  run: docker build -t myapp:${{ github.sha }} .

- name: Scan with Trivy
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: myapp:${{ github.sha }}
    severity: CRITICAL,HIGH
    exit-code: 1            # fail the build on findings

- name: Generate SBOM
  run: trivy image --format spdx-json -o sbom.json myapp:${{ github.sha }}
```

### Scan Locally

```bash
# Trivy (recommended)
trivy image --severity HIGH,CRITICAL myapp:latest

# Docker Scout (built-in)
docker scout cves myapp:latest

# Grype
grype myapp:latest
```

### Enforce Policies

- Block images with CRITICAL CVEs from deploying.
- Require SBOM generation for every image.
- Rebuild base images weekly to pick up upstream patches.
- Use `docker scout recommendations` to find lighter base images.
- Lint Dockerfiles with `hadolint`:

```bash
hadolint Dockerfile
# In CI:
docker run --rm -i hadolint/hadolint < Dockerfile
```

## Quick Reference: Dockerfile Template

```dockerfile
# syntax=docker/dockerfile:1

# --- Build stage ---
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npm run build

# --- Production stage ---
FROM node:22-alpine AS production
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup -S app && adduser -S app -G app -u 1001

COPY --from=build --chown=app:app /app/dist ./dist
COPY --from=build --chown=app:app /app/node_modules ./node_modules
COPY --from=build --chown=app:app /app/package.json ./

USER app
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "dist/index.js"]
```
