# Advanced Dockerfile Patterns

## Table of Contents

- [Multi-Platform Builds](#multi-platform-builds)
- [ARG Scoping Rules and Gotchas](#arg-scoping-rules-and-gotchas)
- [Build Context Optimization](#build-context-optimization)
- [Docker Init](#docker-init)
- [ONBUILD Triggers](#onbuild-triggers)
- [Conditional Logic in Dockerfiles](#conditional-logic-in-dockerfiles)
- [Slim/Debug Image Variants](#slimdebug-image-variants)
- [OCI Labels and Annotations](#oci-labels-and-annotations)
- [Container-Optimized Init Systems](#container-optimized-init-systems)
- [Caching Strategies for Monorepo Builds](#caching-strategies-for-monorepo-builds)
- [Reproducible Builds](#reproducible-builds)

---

## Multi-Platform Builds

### Setup: buildx and QEMU

```bash
# Create a multi-platform builder instance
docker buildx create --name multiarch --driver docker-container --bootstrap --use

# Install QEMU user-static for cross-architecture emulation
docker run --privileged --rm tonistiigi/binfmt --install all

# Verify available platforms
docker buildx inspect --bootstrap
```

### Building for Multiple Platforms

```bash
# Build and push for linux/amd64 + linux/arm64 simultaneously
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag registry.example.com/myapp:1.0 \
  --push .

# Build and load into local Docker (single platform only)
docker buildx build --platform linux/arm64 --load -t myapp:arm64 .

# Build without pushing (useful for CI validation)
docker buildx build --platform linux/amd64,linux/arm64 .
```

This creates a **manifest list** — a single tag pointing to platform-specific images. `docker pull` automatically selects the correct image for the host architecture.

### Platform-Aware Dockerfiles

Docker injects automatic build args: `TARGETPLATFORM`, `TARGETOS`, `TARGETARCH`, `TARGETVARIANT`, `BUILDPLATFORM`, `BUILDOS`, `BUILDARCH`.

```dockerfile
# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS builder
ARG TARGETARCH
ARG TARGETOS
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Cross-compile for the target platform using Go's built-in support
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w" -o /app ./cmd/server

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /app /app
ENTRYPOINT ["/app"]
```

Key insight: `FROM --platform=$BUILDPLATFORM` runs the build stage natively (fast), while the final stage runs on `$TARGETPLATFORM`. This avoids QEMU emulation for compilation — only the final image targets the foreign arch.

### Platform-Specific Dependencies

```dockerfile
FROM --platform=$BUILDPLATFORM ubuntu:24.04 AS builder
ARG TARGETARCH

# Download architecture-specific binaries
RUN case ${TARGETARCH} in \
      amd64) ARCH="x86_64" ;; \
      arm64) ARCH="aarch64" ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    curl -fsSL "https://example.com/bin-${ARCH}.tar.gz" | tar xz -C /usr/local/bin/
```

### Manifest Inspection

```bash
# Inspect manifest list for a multi-platform image
docker manifest inspect registry.example.com/myapp:1.0

# Check which platforms an image supports
docker buildx imagetools inspect registry.example.com/myapp:1.0
```

---

## ARG Scoping Rules and Gotchas

### Global vs Stage-Local ARGs

ARGs declared **before the first FROM** are global — available in FROM lines only. ARGs declared **after a FROM** are stage-local.

```dockerfile
# syntax=docker/dockerfile:1

# Global ARG — only usable in FROM lines
ARG BASE_IMAGE=node:22-alpine
ARG APP_VERSION=1.0.0

FROM ${BASE_IMAGE} AS builder
# APP_VERSION is NOT available here yet — must redeclare
ARG APP_VERSION
RUN echo "Building version ${APP_VERSION}"

FROM ${BASE_IMAGE} AS production
# Must redeclare again — each stage is independent
ARG APP_VERSION
LABEL version="${APP_VERSION}"
```

### Gotcha: ARG Before FROM Doesn't Persist

```dockerfile
ARG MY_VAR=hello
FROM ubuntu:24.04
# MY_VAR is empty here — this is the #1 ARG mistake
RUN echo "${MY_VAR}"  # prints empty string

# Fix: redeclare it (the default carries over)
ARG MY_VAR
RUN echo "${MY_VAR}"  # prints "hello"
```

### Gotcha: ARG Invalidates Cache

Every unique ARG value creates a new cache branch. Placing a volatile ARG (like `BUILD_NUMBER` or `GIT_SHA`) early invalidates all subsequent layers.

```dockerfile
# BAD: ARG early = cache-busting everything below
ARG GIT_SHA
FROM node:22-alpine
COPY . .
RUN npm ci  # re-runs every build because GIT_SHA changed

# GOOD: declare volatile ARGs as late as possible
FROM node:22-alpine
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ARG GIT_SHA
LABEL git.sha="${GIT_SHA}"
```

### Gotcha: ARG in ENV Persists, Bare ARG Does Not

```dockerfile
ARG VERSION=1.0
FROM ubuntu:24.04
ARG VERSION

# ARG alone: available at build time, NOT in running container
RUN echo "Build: ${VERSION}"

# ENV persists into the running container
ENV APP_VERSION=${VERSION}
CMD echo "Runtime: ${APP_VERSION}"
```

### ARG + Default Overrides

```bash
# Override at build time
docker build --build-arg BASE_IMAGE=node:20-slim --build-arg APP_VERSION=2.0 .

# ARG with no default becomes mandatory if referenced
```

---

## Build Context Optimization

### Sending Dockerfile via stdin (No Context)

For builds that don't need local files (e.g., downloading everything):

```bash
docker build -t myapp - <<'EOF'
FROM alpine:3.21
RUN apk add --no-cache curl && curl -fsSL https://example.com/app -o /app
CMD ["/app"]
EOF
```

### Sending Dockerfile via stdin with Context

```bash
# Dockerfile from stdin, context from current directory
docker build -t myapp -f- . <<'EOF'
FROM node:22-alpine
WORKDIR /app
COPY . .
RUN npm ci && npm run build
EOF
```

### Remote Build Contexts

```bash
# Build from a Git repository (clones it as context)
docker build -t myapp https://github.com/org/repo.git#main

# Build from a specific subdirectory of a repo
docker build -t myapp https://github.com/org/repo.git#main:docker/

# Build from a tarball URL
docker build -t myapp https://example.com/context.tar.gz
```

### Reducing Context Size

```bash
# Check your build context size
du -sh --exclude=.git .

# Use .dockerignore (see SKILL.md)

# Use a subdirectory as context instead of repo root
docker build -t myapp -f Dockerfile ./src/

# Compare sizes
docker build --no-cache . 2>&1 | grep "transferring context"
```

### BuildKit Named Contexts

```bash
# Replace a base image with a local one
docker buildx build \
  --build-context mybase=docker-image://ubuntu:24.04 \
  --build-context configs=./config-dir/ \
  .
```

```dockerfile
FROM mybase AS builder
COPY --from=configs /app.conf /etc/app.conf
```

---

## Docker Init

`docker init` generates a Dockerfile, compose.yaml, and .dockerignore optimized for your project. Available since Docker Desktop 4.18+.

```bash
# Run in your project root — interactive wizard
docker init

# It detects your language/framework and generates:
# - Dockerfile (multi-stage, non-root, health check)
# - compose.yaml (with best-practice settings)
# - .dockerignore
```

### Supported Languages

Go, Node.js, Python, Rust, Java, .NET, PHP, and generic.

### When to Use

- **Starting a new project**: Run `docker init` first, then customize.
- **Dockerizing an existing project**: Use as a baseline, then adapt.
- **Learning**: Generated files follow current best practices.

### Customization After Init

The generated files are meant to be edited. Common adjustments:
- Add BuildKit cache mounts for your package manager.
- Adjust health check endpoints.
- Add build arguments for CI.
- Add secret mounts if private dependencies exist.

---

## ONBUILD Triggers

ONBUILD defers an instruction to execute when the image is used as a base. Useful for framework/base images.

```dockerfile
# Base image: myorg/node-base:22
FROM node:22-alpine
WORKDIR /app
RUN addgroup -S app && adduser -S app -G app -u 1001

# These run when a child image builds FROM this image
ONBUILD COPY package.json package-lock.json ./
ONBUILD RUN npm ci --ignore-scripts
ONBUILD COPY . .
ONBUILD RUN npm run build
ONBUILD USER app
```

Child Dockerfile becomes minimal:

```dockerfile
FROM myorg/node-base:22
EXPOSE 3000
CMD ["node", "dist/index.js"]
```

### When ONBUILD Is Useful

- **Organizational base images**: Enforce consistent build steps across teams.
- **Framework images**: Standardize build patterns (e.g., Rails, Django base images).
- **Builder images**: Provide preconfigured toolchains.

### ONBUILD Caveats

- ONBUILD instructions are **invisible** to users of the base image unless they inspect it (`docker inspect` or `docker history`).
- Cannot chain ONBUILD: `ONBUILD ONBUILD` is invalid.
- ONBUILD triggers only fire on the **immediate** child, not grandchildren.
- Avoid ONBUILD ADD/COPY if the base image is used in varied contexts — the expected files may not exist.

---

## Conditional Logic in Dockerfiles

### Conditional on Target Architecture

```dockerfile
FROM ubuntu:24.04
ARG TARGETARCH

RUN if [ "${TARGETARCH}" = "arm64" ]; then \
      apt-get update && apt-get install -y libfoo-arm64; \
    else \
      apt-get update && apt-get install -y libfoo-amd64; \
    fi
```

### Feature Flags with Build Args

```dockerfile
ARG ENABLE_METRICS=false
ARG ENABLE_DEBUG=false

FROM node:22-alpine AS builder
WORKDIR /app
COPY . .
ARG ENABLE_METRICS
ARG ENABLE_DEBUG

RUN if [ "${ENABLE_METRICS}" = "true" ]; then \
      npm install prom-client; \
    fi

RUN if [ "${ENABLE_DEBUG}" = "true" ]; then \
      npm run build:debug; \
    else \
      npm run build; \
    fi
```

```bash
docker build --build-arg ENABLE_METRICS=true --build-arg ENABLE_DEBUG=false .
```

### Conditional COPY with Wildcard Trick

You cannot use `if` with COPY. Use a wildcard trick instead:

```dockerfile
# Copy the file only if it exists — the trailing dot handles the missing case
COPY package-lock.json* yarn.lock* ./
```

### Multi-Stage Conditional: Pick a Target

```dockerfile
FROM node:22-alpine AS base
WORKDIR /app
COPY . .

FROM base AS with-metrics
RUN npm install prom-client && npm run build

FROM base AS without-metrics
RUN npm run build

# Default target
FROM without-metrics AS production
```

```bash
# Build with metrics
docker build --target with-metrics -t myapp:metrics .
# Build without metrics
docker build --target production -t myapp:slim .
```

---

## Slim/Debug Image Variants

Use multi-stage targets to produce different image variants from one Dockerfile.

```dockerfile
# syntax=docker/dockerfile:1

FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .

# Production build: stripped, static
FROM builder AS build-production
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o /app ./cmd/server

# Debug build: with debug symbols and race detector
FROM builder AS build-debug
RUN CGO_ENABLED=1 go build -race -gcflags="all=-N -l" -o /app ./cmd/server

# --- Slim production image ---
FROM gcr.io/distroless/static:nonroot AS production
COPY --from=build-production /app /app
ENTRYPOINT ["/app"]

# --- Debug image with shell, curl, delve ---
FROM alpine:3.21 AS debug
RUN apk add --no-cache curl busybox-extras
COPY --from=build-debug /app /app
# Install delve debugger
COPY --from=golang:1.23-alpine /usr/local/go/bin/dlv /usr/local/bin/dlv
EXPOSE 8080 40000
ENTRYPOINT ["/app"]
```

```bash
# CI/production
docker build --target production -t myapp:1.0 .
# Developer debugging
docker build --target debug -t myapp:debug .
```

---

## OCI Labels and Annotations

### Standard OCI Labels

Use the `org.opencontainers.image.*` label namespace for interoperable metadata.

```dockerfile
# syntax=docker/dockerfile:1

ARG GIT_SHA
ARG BUILD_DATE

FROM node:22-alpine
ARG GIT_SHA
ARG BUILD_DATE

LABEL org.opencontainers.image.title="My Application" \
      org.opencontainers.image.description="Production API server" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/org/repo" \
      org.opencontainers.image.url="https://example.com" \
      org.opencontainers.image.documentation="https://docs.example.com" \
      org.opencontainers.image.vendor="My Organization" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="node:22-alpine"
```

```bash
docker build \
  --build-arg GIT_SHA=$(git rev-parse HEAD) \
  --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  -t myapp:1.0 .
```

### BuildKit Annotations (Manifest-Level)

```bash
# Annotations on the manifest (not image config) — visible in registries
docker buildx build \
  --annotation "org.opencontainers.image.description=Production API" \
  --annotation "manifest:org.opencontainers.image.source=https://github.com/org/repo" \
  --push -t registry.example.com/myapp:1.0 .
```

### Querying Labels

```bash
docker inspect --format '{{json .Config.Labels}}' myapp:1.0 | jq .
```

---

## Container-Optimized Init Systems

### Why PID 1 Matters

The process running as PID 1 inside a container has special responsibilities:
1. **Signal handling**: PID 1 does NOT get default signal handlers. A bare `SIGTERM` is ignored unless the process explicitly handles it. This means `docker stop` hangs for 10s then SIGKILLs.
2. **Zombie reaping**: PID 1 must reap zombie (defunct) child processes. If it doesn't, zombies accumulate.

### The Problem: Shell Form ENTRYPOINT

```dockerfile
# BAD: shell form — /bin/sh is PID 1, your app is PID >1
ENTRYPOINT node server.js
# docker stop sends SIGTERM to sh, not to node. App gets SIGKILL after timeout.

# BETTER: exec form — your app IS PID 1
ENTRYPOINT ["node", "server.js"]
# But your app still needs to handle SIGTERM and reap zombies.
```

### Solution: tini

[tini](https://github.com/krallin/tini) is a minimal init system purpose-built for containers (~30KB).

```dockerfile
FROM node:22-alpine
RUN apk add --no-cache tini
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "server.js"]
```

What tini does:
- Forwards signals (SIGTERM, SIGINT, etc.) to child processes.
- Reaps zombie processes.
- Exits with the child's exit code.

### Solution: dumb-init

```dockerfile
FROM python:3.13-slim
RUN pip install --no-cache-dir dumb-init
ENTRYPOINT ["dumb-init", "--"]
CMD ["gunicorn", "app:app"]
```

### Docker's Built-In --init Flag

```bash
# Use Docker's built-in tini without modifying the Dockerfile
docker run --init myapp
```

In compose:

```yaml
services:
  app:
    image: myapp
    init: true
```

### When You Need an Init System

| Scenario | Need init? |
|---|---|
| Single process, handles SIGTERM (e.g., Go with signal.Notify) | No |
| Single process, doesn't handle signals (many scripting languages) | Yes |
| Process spawns children (e.g., worker pools, shell scripts) | Yes |
| Using exec form ENTRYPOINT with signal-aware app | No |
| Using shell form ENTRYPOINT | Yes (or switch to exec form) |

---

## Caching Strategies for Monorepo Builds

### Problem

In a monorepo, changing any file in the repo root invalidates the COPY layer for all services. A change to `services/auth/handler.go` shouldn't rebuild `services/payments/`.

### Strategy 1: Selective COPY with .dockerignore per Service

```bash
# Project structure:
# monorepo/
#   services/auth/
#   services/payments/
#   libs/shared/
#   go.mod go.sum

# Build from repo root with service-specific context
docker build -f services/auth/Dockerfile .
```

```dockerfile
# services/auth/Dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /src

# Copy only dependency files first (shared across services)
COPY go.mod go.sum ./
RUN go mod download

# Copy only this service and its shared libs
COPY libs/shared/ ./libs/shared/
COPY services/auth/ ./services/auth/

RUN CGO_ENABLED=0 go build -o /app ./services/auth/cmd
```

### Strategy 2: Turbo/Nx Pruned Context (JS Monorepos)

```dockerfile
FROM node:22-alpine AS pruner
RUN npm i -g turbo
WORKDIR /app
COPY . .
# Turbo prunes the monorepo to only include the target package and its dependencies
RUN turbo prune --scope=@myorg/api --docker

FROM node:22-alpine AS installer
WORKDIR /app
# Only lockfile and package.jsons for the pruned subset
COPY --from=pruner /app/out/json/ .
COPY --from=pruner /app/out/package-lock.json ./
RUN npm ci

FROM installer AS builder
COPY --from=pruner /app/out/full/ .
RUN turbo run build --filter=@myorg/api

FROM node:22-alpine AS production
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/apps/api/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
CMD ["node", "dist/index.js"]
```

### Strategy 3: BuildKit Cache Mounts + go mod

```dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -o /app ./services/auth/cmd
```

The go build cache (`/root/.cache/go-build`) avoids recompiling unchanged packages even when the COPY layer changes.

### Strategy 4: Docker Bake for Multiple Services

```hcl
# docker-bake.hcl
group "default" {
  targets = ["auth", "payments", "gateway"]
}

target "auth" {
  dockerfile = "services/auth/Dockerfile"
  context    = "."
  tags       = ["registry.example.com/auth:latest"]
}

target "payments" {
  dockerfile = "services/payments/Dockerfile"
  context    = "."
  tags       = ["registry.example.com/payments:latest"]
}

target "gateway" {
  dockerfile = "services/gateway/Dockerfile"
  context    = "."
  tags       = ["registry.example.com/gateway:latest"]
}
```

```bash
# Build all services in parallel, sharing cache
docker buildx bake --push
```

---

## Reproducible Builds

### The Problem

Two builds of the same Dockerfile from the same source can produce different images due to: timestamps in files, non-deterministic package managers, floating tags, random ordering.

### SOURCE_DATE_EPOCH

Sets the timestamp for all files in the image to a fixed value. Supported by BuildKit 0.11+.

```bash
# Use the Git commit timestamp for reproducibility
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
docker buildx build \
  --build-arg SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
  -t myapp:1.0 .
```

BuildKit respects `SOURCE_DATE_EPOCH` automatically when set, clamping file timestamps.

### --no-cache-filter: Selective Cache Busting

Invalidate specific stages without discarding the entire cache.

```dockerfile
FROM ubuntu:24.04 AS base
RUN apt-get update && apt-get install -y curl  # expensive, rarely changes

FROM base AS app
COPY . .
RUN make build
```

```bash
# Only invalidate the 'app' stage — 'base' stays cached
docker buildx build --no-cache-filter app -t myapp .

# Invalidate multiple stages
docker buildx build --no-cache-filter app,tests -t myapp .
```

### Pinning Everything

```dockerfile
# Pin base image by digest
FROM node:22.12.0-alpine3.21@sha256:abcdef1234567890...

# Pin apt packages by version
RUN apt-get update && apt-get install -y \
    curl=7.88.1-10+deb12u8 \
    ca-certificates=20230311

# Pin pip packages (use pip-compile or pip freeze)
COPY requirements.lock .
RUN pip install --no-cache-dir --no-deps -r requirements.lock

# Pin npm packages (lockfile committed)
COPY package-lock.json ./
RUN npm ci  # ci respects lockfile exactly
```

### Verifying Reproducibility

```bash
# Build twice and compare digests
docker buildx build --metadata-file meta1.json -t test1 .
docker buildx build --metadata-file meta2.json -t test2 .
diff <(jq -r '.["containerimage.digest"]' meta1.json) \
     <(jq -r '.["containerimage.digest"]' meta2.json)
```

### Deterministic apt-get

```dockerfile
# Snapshot-based Debian repos for deterministic installs
RUN echo "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/20240101T000000Z bookworm main" \
    > /etc/apt/sources.list && \
    apt-get -o Acquire::Check-Valid-Until=false update && \
    apt-get install -y --no-install-recommends curl
```
