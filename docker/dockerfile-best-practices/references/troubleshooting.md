# Dockerfile Troubleshooting Guide

## Table of Contents

- [Build Cache Not Working as Expected](#build-cache-not-working-as-expected)
- [No Space Left on Device During Builds](#no-space-left-on-device-during-builds)
- [Permission Denied Errors](#permission-denied-errors)
- [Network Issues During Build](#network-issues-during-build)
- [Build Context Too Large](#build-context-too-large)
- [Multi-Stage Build: COPY --from Failed](#multi-stage-build-copy---from-failed)
- [Platform Mismatch Errors](#platform-mismatch-errors)
- [BuildKit vs Legacy Builder Differences](#buildkit-vs-legacy-builder-differences)
- [Container Exits Immediately After Start](#container-exits-immediately-after-start)
- [OOM Kills During Build](#oom-kills-during-build)
- [Debugging Tools and Techniques](#debugging-tools-and-techniques)
- [Layer Already Exists Push Errors](#layer-already-exists-push-errors)
- [Health Check Failing in Orchestrator but Working Locally](#health-check-failing-in-orchestrator-but-working-locally)

---

## Build Cache Not Working as Expected

### Symptom

Layers rebuild even though you didn't change anything relevant.

### Causes and Fixes

**1. File metadata change (timestamp, permissions)**

Docker compares file checksums AND metadata for COPY/ADD. A file touched by CI or git clone gets a new timestamp, invalidating the cache.

```bash
# Diagnosis: check if git is changing timestamps
git diff --stat

# Fix: in CI, use --mount=type=cache instead of relying on layer cache
# Or: normalize timestamps before COPY
find . -name "*.py" -exec touch -t 202401010000 {} +
```

**2. ARG declared before a cacheable layer**

```dockerfile
# BAD: any change to GIT_SHA invalidates npm ci cache
ARG GIT_SHA
FROM node:22-alpine
COPY package.json ./
RUN npm ci           # re-runs every build

# GOOD: move volatile ARGs after expensive steps
FROM node:22-alpine
COPY package.json ./
RUN npm ci           # cached
ARG GIT_SHA          # only invalidates layers below
LABEL sha=${GIT_SHA}
```

**3. ADD with remote URL always re-fetches**

ADD with a URL invalidates cache every time (Docker can't checksum remote resources reliably). Use `RUN curl` or `RUN wget` instead.

**4. Buildx builder not sharing cache with docker build**

Different builders maintain separate caches. `docker build` uses the default builder; `docker buildx build` may use a different one.

```bash
# Check which builder is active
docker buildx ls

# Use the default docker builder with buildx
docker buildx build --builder default .
```

**5. Cache lost between CI runs**

```bash
# Export/import cache with GitHub Actions cache backend
docker buildx build \
  --cache-from type=gha \
  --cache-to type=gha,mode=max \
  -t myapp .

# Or use registry-based cache
docker buildx build \
  --cache-from type=registry,ref=registry.example.com/myapp:cache \
  --cache-to type=registry,ref=registry.example.com/myapp:cache,mode=max \
  -t myapp .
```

**6. Inline cache not exported**

```bash
# When pushing, also export inline cache metadata
docker buildx build --cache-to type=inline --push -t myapp:latest .
# Then subsequent builds can use:
docker buildx build --cache-from type=registry,ref=myapp:latest .
```

### Debug: Trace Cache Decisions

```bash
# Show which layers are cached vs rebuilt
docker buildx build --progress=plain . 2>&1 | grep -E "CACHED|RUN"
```

---

## No Space Left on Device During Builds

### Diagnosis

```bash
# Check Docker disk usage
docker system df
docker system df -v  # detailed

# Check filesystem
df -h /var/lib/docker
```

### Fixes

```bash
# Remove all stopped containers, unused images, build cache
docker system prune -a --volumes

# Remove only build cache
docker builder prune -a

# Remove only dangling images
docker image prune

# Remove only stopped containers
docker container prune

# Remove volumes (WARNING: destroys data)
docker volume prune
```

### Prevention

```bash
# Limit BuildKit cache size
docker buildx prune --filter "until=72h"

# Set a build cache limit in buildkitd.toml
# [worker.oci]
#   max-parallelism = 4
#   gckeepstorage = 10000  # 10GB in MB

# In CI: always prune before builds
docker builder prune --force --filter "until=24h"
```

### Inside the Build: Large Layers

```dockerfile
# BAD: downloads 500MB, layer keeps both tarball AND extracted files
RUN curl -fsSL https://example.com/big.tar.gz -o /tmp/big.tar.gz && \
    tar xzf /tmp/big.tar.gz -C /opt/
# /tmp/big.tar.gz is still in this layer!

# GOOD: single RUN, cleanup in same layer
RUN curl -fsSL https://example.com/big.tar.gz | tar xz -C /opt/

# GOOD: use a throwaway stage
FROM alpine AS downloader
RUN curl -fsSL https://example.com/big.tar.gz | tar xz -C /opt/

FROM production-base
COPY --from=downloader /opt/tool /opt/tool
```

---

## Permission Denied Errors

### Symptom: COPY Fails at Build Time

```
COPY --chown=app:app . . => ERROR: failed to solve: failed to compute cache key: "/some/path" not found
```

### Symptom: Permission Denied at Runtime

```
Error: EACCES: permission denied, open '/app/data/file.txt'
```

### Causes and Fixes

**1. USER directive before COPY/RUN that needs root**

```dockerfile
# BAD: user 'app' can't write to /app
RUN adduser -S app
USER app
RUN mkdir -p /app/data  # permission denied

# GOOD: create dirs as root, then switch
RUN adduser -S app && mkdir -p /app/data && chown -R app:app /app
USER app
```

**2. File copied with root ownership**

```dockerfile
# BAD: files owned by root, app user can't read
USER app
COPY . .  # files are root:root

# GOOD: use --chown
COPY --chown=app:app . .

# GOOD: use --chmod (BuildKit)
COPY --chmod=755 entrypoint.sh /entrypoint.sh
```

**3. Volume permissions mismatch**

When a host-mounted volume has different UID/GID than the container user:

```dockerfile
# Ensure container user UID matches host user UID
ARG UID=1001
ARG GID=1001
RUN groupadd -g ${GID} app && useradd -u ${UID} -g ${GID} app
```

```bash
docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) .
```

**4. Read-only filesystem with tmpfs**

```bash
# Container runs read-only but app needs to write somewhere
docker run --read-only --tmpfs /tmp --tmpfs /app/cache myapp
```

**5. npm/pip needs write access to cache dirs**

```dockerfile
# npm tries to write to /root/.npm or /home/app/.npm
ENV npm_config_cache=/tmp/.npm
RUN npm ci

# pip tries to write to /root/.cache/pip
RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements.txt
```

---

## Network Issues During Build

### DNS Resolution Failures

```
Could not resolve 'archive.ubuntu.com'
```

```bash
# Set DNS for the build
docker build --network=host .
# Or configure Docker daemon DNS in /etc/docker/daemon.json:
# { "dns": ["8.8.8.8", "8.8.4.4"] }
```

### Corporate Proxy

```dockerfile
# Set proxy as build args (don't hardcode — pass at build time)
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
# Docker automatically uses these ARGs without explicit declaration
# but declaring them makes intent clear

RUN apt-get update && apt-get install -y curl
```

```bash
docker build \
  --build-arg HTTP_PROXY=http://proxy.corp:8080 \
  --build-arg HTTPS_PROXY=http://proxy.corp:8080 \
  --build-arg NO_PROXY=localhost,127.0.0.1,.corp.internal \
  .
```

Important: Docker treats `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, `FTP_PROXY` as predefined ARGs. They are **not** persisted in the image (unlike regular ARGs used in ENV).

### TLS/Certificate Errors

```dockerfile
# Add corporate CA certificates
COPY corp-ca.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

# For pip specifically
ENV PIP_CERT=/usr/local/share/ca-certificates/corp-ca.crt

# For npm
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/corp-ca.crt

# For Alpine (different path)
COPY corp-ca.crt /usr/local/share/ca-certificates/
RUN apk add --no-cache ca-certificates && update-ca-certificates
```

### Network Not Available in RUN

If using `--network=none` (some CI environments):

```bash
# Explicitly allow network for build
docker build --network=default .
```

---

## Build Context Too Large

### Symptom

```
Sending build context to Docker daemon  2.5GB
```

Build takes minutes before any layers run.

### Diagnosis

```bash
# See what's being sent
du -sh --exclude=.git .
du -sh * | sort -hr | head -20

# Check if .dockerignore exists and is correct
cat .dockerignore

# See exactly what's included in context
# (using a minimal Dockerfile)
docker build --no-cache -f- . <<'EOF'
FROM busybox
COPY . /ctx
RUN du -sh /ctx && find /ctx -type f | head -50
EOF
```

### Fixes

```bash
# 1. Create/fix .dockerignore
cat > .dockerignore <<'EOF'
.git
node_modules
dist
*.log
.env*
tests/
coverage/
EOF

# 2. Use a subdirectory as context
docker build -f Dockerfile -t myapp ./src/

# 3. Use BuildKit (sends only needed files, not entire context)
DOCKER_BUILDKIT=1 docker build .
```

BuildKit transfers context lazily — only the files referenced by COPY/ADD are sent. This is a major improvement over the legacy builder which sends everything upfront.

---

## Multi-Stage Build: COPY --from Failed

### Symptom

```
COPY --from=builder /app/dist ./dist
ERROR: failed to solve: failed to compute cache key: "/app/dist" not found
```

### Causes and Fixes

**1. Stage name typo**

```dockerfile
FROM node:22-alpine AS bilder    # typo
# ...
COPY --from=builder /app/dist .  # "builder" not found
```

**2. Build target stops before the needed stage**

```bash
# This only builds up to 'deps', never runs 'builder'
docker build --target deps .
```

**3. Path doesn't exist in the source stage**

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
RUN npm run build  # outputs to /app/build, NOT /app/dist

# This fails — wrong path
COPY --from=builder /app/dist ./dist

# Fix: use the correct output path
COPY --from=builder /app/build ./dist
```

**4. Conditional build didn't produce output**

```dockerfile
FROM node:22-alpine AS builder
WORKDIR /app
COPY . .
RUN if [ -f "tsconfig.json" ]; then npm run build; fi
# If tsconfig.json doesn't exist, /app/dist is never created
```

Fix: ensure the directory exists regardless:

```dockerfile
RUN mkdir -p /app/dist && \
    if [ -f "tsconfig.json" ]; then npm run build; fi
```

### Debugging: Inspect a Stage

```bash
# Build only the target stage and inspect it
docker build --target builder -t debug-builder .
docker run --rm debug-builder ls -la /app/
docker run --rm debug-builder find /app -type f
```

---

## Platform Mismatch Errors

### Symptom

```
WARNING: The requested image's platform (linux/amd64) does not match
the detected host platform (linux/arm64/v8)
exec format error
```

### Causes and Fixes

**1. Pulling images built for wrong architecture**

```bash
# Force pull for correct platform
docker pull --platform linux/arm64 node:22-alpine

# Check image platform
docker inspect node:22-alpine | jq '.[0].Architecture'
```

**2. Base image doesn't support your platform**

```bash
# Check available platforms for an image
docker manifest inspect node:22-alpine | jq '.manifests[].platform'
```

Some images (especially third-party) only publish `linux/amd64`. Options:
- Build from source in your Dockerfile.
- Use `--platform linux/amd64` and accept QEMU emulation overhead.
- Find an alternative image with multi-arch support.

**3. M1/M2 Mac building amd64 images for Linux deployment**

```bash
# Explicitly target linux/amd64 on Apple Silicon
docker buildx build --platform linux/amd64 -t myapp .

# Or set default platform
export DOCKER_DEFAULT_PLATFORM=linux/amd64
```

**4. Multi-stage with mixed platforms**

```dockerfile
# Build natively, run on target platform
FROM --platform=$BUILDPLATFORM golang:1.23 AS builder
ARG TARGETOS TARGETARCH
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /app

# This stage runs on the target platform
FROM alpine:3.21
COPY --from=builder /app /app
```

---

## BuildKit vs Legacy Builder Differences

### How to Check Which Builder You're Using

```bash
# Check Docker version and BuildKit status
docker info | grep -i buildkit
# BuildKit is default since Docker 23.0

# Force legacy builder (if available)
DOCKER_BUILDKIT=0 docker build .

# Force BuildKit
DOCKER_BUILDKIT=1 docker build .
```

### Features Only in BuildKit

| Feature | BuildKit | Legacy |
|---|---|---|
| `RUN --mount=type=cache` | ✅ | ❌ Syntax error |
| `RUN --mount=type=secret` | ✅ | ❌ Syntax error |
| `RUN --mount=type=ssh` | ✅ | ❌ Syntax error |
| Heredocs (`<<EOF`) | ✅ | ❌ Syntax error |
| `COPY --chmod` | ✅ | ❌ Ignored |
| `COPY --link` | ✅ | ❌ Ignored |
| `--cache-from`/`--cache-to` | ✅ Full support | ⚠️ Limited |
| Parallel stage builds | ✅ | ❌ Sequential |
| `# syntax=` directive | ✅ | ❌ Ignored |

### Common Breakage Scenarios

**1. `# syntax=docker/dockerfile:1` ignored on legacy builder**

The `# syntax=` line is a BuildKit directive. Legacy builder treats it as a comment, so `RUN --mount=...` becomes a syntax error.

Fix: ensure BuildKit is enabled:

```dockerfile
# syntax=docker/dockerfile:1
# This line MUST be the first line. Even a blank line before it breaks it.
```

**2. Output format differences**

BuildKit default output is `auto` (compact). Use `--progress=plain` for verbose output matching legacy behavior.

**3. `COPY --link` behavioral difference**

With `--link`, COPY creates independent layers that don't depend on previous layers. This speeds up cache reuse but changes layer ordering.

```dockerfile
# With BuildKit --link: this COPY doesn't depend on the USER or WORKDIR above
COPY --link --from=builder /app/dist ./dist
```

**4. Build context transfer**

Legacy: sends entire context upfront.
BuildKit: transfers lazily, only files referenced by COPY/ADD.

This means BuildKit builds start faster but may fail later if a COPY references a file excluded by .dockerignore that the legacy builder would have sent.

---

## Container Exits Immediately After Start

### Symptom

```bash
docker run myapp
# Container exits immediately, status 0 or non-zero
docker ps -a  # shows "Exited (1) 2 seconds ago"
```

### Causes and Fixes

**1. Shell form CMD runs and exits**

```dockerfile
# BAD: shell form — sh -c "echo hello" runs and exits
CMD echo "Server starting" && node server.js
# If node server.js backgrounds itself, sh exits

# GOOD: exec form — node is PID 1, stays in foreground
CMD ["node", "server.js"]
```

**2. App runs in background/daemon mode**

Many apps (nginx, redis) default to daemon mode. Force foreground:

```dockerfile
# nginx
CMD ["nginx", "-g", "daemon off;"]

# redis
CMD ["redis-server", "--daemonize", "no"]

# Apache httpd
CMD ["httpd", "-D", "FOREGROUND"]
```

**3. Missing executable or wrong path**

```bash
# Debug: check the filesystem
docker run --rm --entrypoint=sh myapp -c "ls -la /app/"
docker run --rm --entrypoint=sh myapp -c "which node"
```

**4. Exec format error (wrong platform or missing shebang)**

```bash
# Check: is the binary for the right architecture?
docker run --rm --entrypoint=sh myapp -c "file /app/server"
# Expected: ELF 64-bit LSB executable, x86-64
# Problem: ELF 64-bit LSB executable, ARM aarch64
```

**5. App crashes on startup — check logs**

```bash
docker logs $(docker ps -alq)
# Or run interactively
docker run -it myapp
```

**6. ENTRYPOINT + CMD interaction**

```dockerfile
# If ENTRYPOINT is set, CMD becomes arguments to ENTRYPOINT
ENTRYPOINT ["python"]
CMD ["app.py"]
# Runs: python app.py

# Common mistake: ENTRYPOINT shell form ignores CMD
ENTRYPOINT python    # shell form — CMD is ignored!
CMD ["app.py"]       # never used
```

---

## OOM Kills During Build

### Symptom

```
ERROR: process "/bin/sh -c npm run build" did not complete successfully: killed
# or
Killed
```

The word "Killed" with no other error typically means OOM killer.

### Diagnosis

```bash
# Check Docker memory limits
docker info | grep -i memory
docker stats --no-stream

# Check system OOM events
dmesg | grep -i "out of memory" | tail -5
journalctl -k | grep -i oom
```

### Fixes

**1. Increase Docker memory limit**

Docker Desktop: Settings → Resources → Memory → Increase.

```bash
# For docker buildx with docker-container driver
docker buildx create --name bigbuilder \
  --driver docker-container \
  --driver-opt "memory=8g" \
  --use
```

**2. Reduce build parallelism**

```dockerfile
# Node.js: limit webpack/esbuild parallelism
ENV NODE_OPTIONS="--max-old-space-size=2048"
RUN npm run build

# Go: limit parallel compilation
RUN GOMAXPROCS=2 go build ./...

# Rust: limit codegen units and linker memory
RUN CARGO_BUILD_JOBS=2 cargo build --release

# C/C++: limit make parallelism
RUN make -j2 instead of make -j$(nproc)
```

**3. Use swap during build (not recommended for production)**

```bash
# Increase swap on the host
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

**4. Split the offending RUN into stages**

```dockerfile
# BAD: one massive build step
RUN npm ci && npm run build && npm run test

# BETTER: separate stages, each has full memory
FROM node:22-alpine AS deps
COPY package.json package-lock.json ./
RUN npm ci

FROM deps AS build
COPY . .
RUN npm run build  # gets full memory without npm ci overhead
```

---

## Debugging Tools and Techniques

### docker build --progress=plain

Shows full output of every RUN command instead of the compact default.

```bash
docker buildx build --progress=plain -t myapp . 2>&1 | tee build.log
```

### docker history

Shows layers, sizes, and the commands that created them.

```bash
docker history myapp:latest
docker history --no-trunc myapp:latest  # full commands

# Find largest layers
docker history myapp:latest --format "{{.Size}}\t{{.CreatedBy}}" | sort -hr | head
```

### dive — Interactive Layer Explorer

```bash
# Install
# https://github.com/wagoodman/dive
brew install dive      # macOS
apt install dive       # Debian (from repo)

# Analyze an image
dive myapp:latest
# Shows: layer-by-layer filesystem changes, wasted space, efficiency score
```

### Inspect a Failed Build Step

```bash
# With BuildKit, use --target to stop at a specific stage
docker build --target builder -t debug .
docker run -it --rm debug sh

# Debug a specific RUN step by adding a temporary stage
# before the failing step:
```

```dockerfile
FROM base AS pre-fail
COPY . .
RUN some-step-that-works
# Debug here:
# docker build --target pre-fail -t debug . && docker run -it debug sh
RUN the-failing-step
```

### Print Environment During Build

```dockerfile
RUN echo "=== Debug ===" && \
    env | sort && \
    echo "=== Files ===" && \
    ls -la /app/ && \
    echo "=== Disk ===" && \
    df -h
```

### Check Image Contents Without Running

```bash
# Export filesystem to tar
docker create --name tmp myapp:latest
docker export tmp | tar tf - | grep -i config
docker rm tmp

# Or use crane (from google/go-containerregistry)
crane export myapp:latest - | tar tf -
```

---

## Layer Already Exists Push Errors

### Symptom

```
layer already exists
blob upload unknown
```

### Causes and Fixes

**1. Concurrent pushes of same tag**

Two CI jobs pushing `myapp:latest` simultaneously. One wins, the other gets a conflict.

Fix: use unique tags (git SHA, build number), then update `latest` tag separately.

```bash
# Push with unique tag first
docker push myapp:${GITHUB_SHA}
# Then re-tag and push latest
docker tag myapp:${GITHUB_SHA} myapp:latest
docker push myapp:latest
```

**2. Registry corruption or partial upload**

```bash
# Delete the tag and re-push
# For Docker Hub:
# Use the Hub API or UI to delete the tag

# For private registries with garbage collection:
# Delete the manifest, run GC, re-push
```

**3. Cross-repository mount failures**

When pushing to a registry that shares blob storage:

```bash
# Disable mount optimization
docker push --disable-content-trust myapp:latest
```

**4. Registry storage backend issues**

```bash
# Check registry logs
docker logs registry-container

# Verify blob integrity
# Run registry garbage collection
docker exec registry bin/registry garbage-collect /etc/docker/registry/config.yml
```

---

## Health Check Failing in Orchestrator but Working Locally

### Symptom

Container works fine with `docker run`, but health check fails in Kubernetes, ECS, or Docker Swarm. Pod keeps restarting.

### Causes and Fixes

**1. Health check runs before app is ready**

```dockerfile
# BAD: no start period — checks immediately
HEALTHCHECK --interval=5s --timeout=3s \
  CMD curl -f http://localhost:8080/health || exit 1

# GOOD: give app time to start
HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1
```

For Kubernetes, use separate probes:

```yaml
# Startup probe: generous timeout for slow starts
startupProbe:
  httpGet:
    path: /health
    port: 8080
  failureThreshold: 30
  periodSeconds: 10
# Liveness probe: fast checks after startup
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  periodSeconds: 10
  timeoutSeconds: 3
# Readiness probe: traffic routing
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  periodSeconds: 5
```

**2. curl/wget not installed in the image**

```dockerfile
# If using distroless or minimal images, curl isn't available
# Option A: use a built-in health endpoint
HEALTHCHECK CMD ["/app", "--healthcheck"]

# Option B: use a static health check binary
COPY --from=builder /healthcheck /healthcheck
HEALTHCHECK CMD ["/healthcheck"]

# Option C: use shell built-ins (if shell exists)
HEALTHCHECK CMD ["sh", "-c", "exec 3<>/dev/tcp/localhost/8080 || exit 1"]
```

**3. Listening on wrong interface**

```bash
# App binds to 127.0.0.1 — health check from orchestrator can't reach it
# Fix: bind to 0.0.0.0
CMD ["node", "server.js", "--host", "0.0.0.0"]
```

```dockerfile
# Health check inside container should always use localhost
HEALTHCHECK CMD curl -f http://localhost:8080/health || exit 1
# NOT the container IP or service name
```

**4. DNS resolution in health check command**

```dockerfile
# BAD: relies on DNS which may not work inside container
HEALTHCHECK CMD curl -f http://myapp.service/health || exit 1

# GOOD: always use localhost for in-container health checks
HEALTHCHECK CMD curl -f http://localhost:8080/health || exit 1
```

**5. Resource limits causing health check timeout**

Under CPU throttling, the health check command itself may timeout:

```yaml
# Increase timeout, or ensure health check is lightweight
resources:
  limits:
    cpu: "0.5"
    memory: "256Mi"
  requests:
    cpu: "0.25"
    memory: "128Mi"
```

```dockerfile
# Use a lightweight health check
# BAD: spawns a full curl process
HEALTHCHECK CMD curl -f http://localhost:8080/health || exit 1
# BETTER: use wget (smaller footprint on Alpine)
HEALTHCHECK CMD wget -qO- http://localhost:8080/health || exit 1
# BEST: use the app's built-in health check
HEALTHCHECK CMD ["/app", "-health"]
```

**6. Different network namespace in orchestrator**

In Kubernetes, sidecar containers share the network namespace. If a sidecar proxy intercepts health checks:

```yaml
# Use the container port directly, not through the proxy
livenessProbe:
  httpGet:
    path: /health
    port: 8080
    # NOT the proxy port
```

**7. Health check passes but readiness fails**

The health endpoint (`/health`) returns 200 but the app isn't ready to serve traffic. Separate liveness from readiness:

```dockerfile
# Docker HEALTHCHECK maps to liveness-like behavior
# For orchestrators, define both endpoints in your app:
# /health  → "process is alive" (liveness)
# /ready   → "ready to accept traffic" (readiness)
```
