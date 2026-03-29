---
name: earthly
description: |
  Build automation with Dockerfile-like syntax. Use for reproducible builds.
  NOT for simple single-step builds.
---

# Earthly

Build automation tool with Dockerfile-like syntax. Reproducible, cache-efficient builds with native monorepo support.

## When to Use

**USE:** Multi-step builds, monorepos, cross-platform images, complex dependency chains, CI/CD pipelines
**DON'T USE:** Single `docker build` commands, trivial one-off scripts

## Installation

```bash
# macOS/Linux
sudo /bin/sh -c 'wget https://github.com/earthly/earthly/releases/latest/download/earthly-linux-amd64 -O /usr/local/bin/earthly && chmod +x /usr/local/bin/earthly'

# Verify
earthly --version
```

## Earthfile Structure

```dockerfile
VERSION 0.8

# Global arguments (available in all targets)
ARG --global GO_VERSION=1.21
ARG --global REGISTRY=ghcr.io/myorg

# Base target - inherited by others
base:
    FROM golang:${GO_VERSION}-alpine
    WORKDIR /app
    RUN apk add --no-cache git ca-certificates

# Build target
build:
    FROM +base
    COPY go.mod go.sum ./
    RUN go mod download
    COPY . .
    RUN go build -o bin/app ./cmd/app
    SAVE ARTIFACT bin/app AS LOCAL build/app

# Docker image target
docker:
    FROM alpine:3.19
    COPY +build/app /usr/local/bin/app
    ENTRYPOINT ["/usr/local/bin/app"]
    SAVE IMAGE ${REGISTRY}/app:latest
```

## Core Syntax

### VERSION

Must be first line. Use latest stable:

```dockerfile
VERSION 0.8
```

### FROM

Base images or other targets:

```dockerfile
# Docker image
FROM golang:1.21-alpine

# Another target (cross-target dependency)
FROM +build

# With platform
FROM --platform=linux/amd64 alpine:3.19
```

### COPY

Copy from local or other targets:

```dockerfile
# Local files
COPY src ./src
COPY go.mod go.sum ./

# From another target (artifact reference)
COPY +build/binary /usr/local/bin/
COPY +generate/proto/*.pb.go ./proto/

# With permissions
COPY --chmod=755 +build/script /usr/local/bin/
```

### RUN

Execute commands with caching options:

```dockerfile
# Basic
RUN go build ./...

# With cache mount (persists between builds)
RUN --mount=type=cache,target=/go/pkg/mod go mod download

# With secret
RUN --mount=type=secret,id=api_key cat /run/secrets/api_key

# With SSH agent
RUN --mount=type=ssh git clone git@github.com:org/repo.git

# No cache (always execute)
RUN --no-cache date > /build-time.txt
```

### ARG

Variables with scopes:

```dockerfile
ARG VERSION=1.0.0
```

## Build Targets

### Defining Targets

```dockerfile
# Default target (run with: earthly +build)
build:
    FROM golang:1.21
    COPY . .
    RUN go build -o app .
    SAVE ARTIFACT app

# Test target
 test:
    FROM +build
    COPY . .
    RUN go test ./...

# Lint target
lint:
    FROM golangci/golangci-lint:v1.55
    COPY . .
    RUN golangci-lint run
```

### Target Dependencies

```dockerfile
# Sequential: build runs, then docker uses its artifacts
docker:
    FROM alpine
    COPY +build/app /bin/
    SAVE IMAGE myapp:latest

# Parallel: test and lint run concurrently
ci:
    BUILD +lint
    BUILD +test
    BUILD +build

# Conditional: only build if tests pass
ci-gated:
    FROM +test
    BUILD +docker
```

### Cross-Target References

```dockerfile
# Reference artifacts from other directories
COPY ../api+generate/openapi.yaml ./
COPY ./services/user+build/binary /usr/local/bin/user

# Reference with variables
ARG SERVICE=user
COPY ./services/${SERVICE}+build/binary /bin/
```

## Multi-Platform Builds

### Platform Selection

```dockerfile
VERSION 0.8

build:
    FROM --platform=linux/amd64 golang:1.21
    # ...

# Multi-platform image
docker:
    FROM alpine
    COPY +build/app /bin/
    SAVE IMAGE --push myapp:latest
```

### CLI Platform Flags

```bash
# Build for specific platform
earthly --platform=linux/arm64 +docker

# Multiple platforms
earthly --platform=linux/amd64 --platform=linux/arm64 +docker

# All supported
earthly --platform=linux/amd64 --platform=linux/arm64 --platform=linux/arm/v7 +docker
```

### Native Cross-Compilation

```dockerfile
# Use native platform for build, target for final
build:
    FROM --platform=$BUILDPLATFORM golang:1.21
    ARG TARGETOS TARGETARCH
    RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o app .
    SAVE ARTIFACT app

docker:
    FROM --platform=$TARGETPLATFORM alpine
    COPY +build/app /bin/
    SAVE IMAGE myapp:latest
```

## Secrets

### Secrets

```dockerfile
# Use secret in build
RUN --mount=type=secret,id=api_key,target=/run/secrets/api_key \
    API_KEY=$(cat /run/secrets/api_key) go build ./...

# Multiple secrets
RUN --mount=type=secret,id=aws_key \
    --mount=type=secret,id=aws_secret \
    AWS_ACCESS_KEY_ID=$(cat /run/secrets/aws_key) \
    AWS_SECRET_ACCESS_KEY=$(cat /run/secrets/aws_secret) \
    aws s3 sync ./dist s3://bucket/
```

CLI usage:
```bash
earthly --secret api_key=$(cat api.key) +build
earthly --secret-file api_key=./secrets/key.txt +build
```

### SSH Agent

```dockerfile
# Clone private repo
RUN --mount=type=ssh git clone git@github.com:org/private.git

# Multiple SSH keys
RUN --mount=type=ssh,id=github git clone git@github.com:org/repo1.git
RUN --mount=type=ssh,id=gitlab git clone git@gitlab.com:org/repo2.git
```

CLI usage:
```bash
earthly --ssh-agent +build
earthly --ssh-agent-id=github +build
```

## Best Practices
## Monorepo Patterns

### Root Earthfile

```dockerfile
VERSION 0.8

# Shared base across all services
base:
    FROM golang:1.21-alpine
    WORKDIR /app
    RUN apk add --no-cache git ca-certificates

# Run all tests
all-tests:
    BUILD ./libs/shared+test
    BUILD ./services/api+test
    BUILD ./services/worker+test

# Build all
all-docker:
    BUILD ./services/api+docker
    BUILD ./services/worker+docker
```

### Service Earthfile

```dockerfile
VERSION 0.8

deps:
    FROM ../+base
    COPY go.mod go.sum ./
    RUN --mount=type=cache,target=/go/pkg/mod go mod download

build:
    FROM +deps
    COPY . .
    RUN go build -o bin/api ./cmd/api
    SAVE ARTIFACT bin/api

docker:
    FROM alpine:3.19
    COPY +build/api /usr/local/bin/
    EXPOSE 8080
    ENTRYPOINT ["/usr/local/bin/api"]
    SAVE IMAGE api:latest

ci:
    BUILD +lint
    BUILD +test
    BUILD +docker
```

## Best Practices

### DO

```dockerfile
# Use specific versions
FROM golang:1.21.5-alpine3.19

# Leverage cache mounts for package managers
RUN --mount=type=cache,target=/go/pkg/mod go mod download

# Order COPY by change frequency
COPY go.mod go.sum ./      # Stable
RUN go mod download        # Cacheable
COPY . .                   # Volatile

# Use --platform for cross-compilation
FROM --platform=$BUILDPLATFORM golang:1.21
ARG TARGETOS TARGETARCH
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go build .

# Save artifacts for debugging
SAVE ARTIFACT coverage.out AS LOCAL ./coverage.out
```

### DON'T

```dockerfile
# Don't use 'latest' tag
FROM golang:latest  # BAD

# Don't copy everything at once
COPY . .            # BAD - invalidates cache constantly
RUN go mod download # BAD - runs after COPY

# Don't run tests in image build target
docker:
    FROM alpine
    COPY . .
    RUN go test ./...  # BAD - tests should be separate target
    RUN go build .

# Don't hardcode secrets
RUN curl -H "Authorization: bearer hardcoded_token" ...  # BAD
```

## Common Patterns

### Go Application

```dockerfile
VERSION 0.8

deps:
    FROM golang:1.21-alpine
    WORKDIR /app
    COPY go.mod go.sum ./
    RUN --mount=type=cache,target=/go/pkg/mod go mod download

build:
    FROM +deps
    COPY . .
    RUN go build -ldflags="-s -w" -o bin/app ./cmd/app
    SAVE ARTIFACT bin/app

test:
    FROM +deps
    COPY . .
    RUN go test -v -coverprofile=coverage.out ./...
    SAVE ARTIFACT coverage.out AS LOCAL ./coverage.out

lint:
    FROM golangci/golangci-lint:v1.55-alpine
    WORKDIR /app
    COPY . .
    RUN golangci-lint run

docker:
    FROM gcr.io/distroless/static:nonroot
    COPY +build/app /usr/local/bin/
    USER nonroot:nonroot
    ENTRYPOINT ["/usr/local/bin/app"]
    SAVE IMAGE --push ghcr.io/org/app:${VERSION}
```

### Node.js Application

```dockerfile
VERSION 0.8

deps:
    FROM node:20-alpine
    WORKDIR /app
    COPY package*.json ./
    RUN --mount=type=cache,target=/root/.npm npm ci

build:
    FROM +deps
    COPY . .
    RUN npm run build
    SAVE ARTIFACT dist/

docker:
    FROM node:20-alpine
    WORKDIR /app
    COPY package*.json ./
    RUN --mount=type=cache,target=/root/.npm npm ci --production
    COPY +build/dist ./dist
    EXPOSE 3000
    CMD ["node", "dist/main.js"]
    SAVE IMAGE app:latest
```

### Multi-Service Build

```dockerfile
VERSION 0.8

# Build all services in parallel
all:
    BUILD +api
    BUILD +worker
    BUILD +scheduler

# Individual services
api:
    FROM ./services/api+build
    SAVE ARTIFACT bin/api

worker:
    FROM ./services/worker+build
    SAVE ARTIFACT bin/worker

scheduler:
    FROM ./services/scheduler+build
    SAVE ARTIFACT bin/scheduler

# Docker compose build
docker-compose:
    FROM +api
    SAVE IMAGE api:latest
    FROM +worker
    SAVE IMAGE worker:latest
```

<!-- QA Status: tested | 2025-03-29 | Score: 4.0/5 -->
