# syntax=docker/dockerfile:1

# =============================================================================
# Production-Ready Go Dockerfile
# =============================================================================
# Multi-stage build:
#   1. Builder  — compiles a fully static binary (CGO_ENABLED=0)
#   2. Runtime  — distroless image with only the binary
#
# The final image contains no shell, no package manager, and no libc —
# the smallest possible attack surface.
#
# Build with BuildKit enabled:
#   DOCKER_BUILDKIT=1 docker build -t myapp .
#
# Pin your base image digest for reproducibility:
#   golang:1.23-alpine@sha256:<digest>
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build the static Go binary
# ---------------------------------------------------------------------------
FROM golang:1.23-alpine AS builder
# Pin digest: @sha256:<paste-digest-here>

WORKDIR /src

# Copy go.mod and go.sum first for dependency layer caching
COPY go.mod go.sum ./

# Use BuildKit cache mounts for Go module and build caches
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download && go mod verify

# Copy the rest of the source code
COPY . .

# Build a fully static binary:
#   CGO_ENABLED=0  — pure Go, no cgo, no dynamic linking
#   -trimpath      — remove local file paths from binary (reproducibility)
#   -ldflags       — strip debug info (-s) and symbol table (-w) for smaller binary
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /app/server \
      ./cmd/server

# ---------------------------------------------------------------------------
# Stage 2: Minimal distroless runtime
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot AS runtime
# Pin digest: @sha256:<paste-digest-here>
#
# distroless/static contains:
#   - CA certificates
#   - /etc/passwd (nonroot user)
#   - timezone data
# It does NOT contain: shell, package manager, libc

# Metadata labels following OCI image spec
LABEL org.opencontainers.image.source="https://github.com/your-org/your-repo" \
      org.opencontainers.image.description="Production Go application" \
      org.opencontainers.image.licenses="MIT"

# Copy the compiled binary from builder
COPY --from=builder /app/server /server

# Expose the application port
EXPOSE 8080

# Health check — uses the binary itself since there's no shell in distroless
# The app must handle a --health or /healthz endpoint
# NOTE: HEALTHCHECK requires a shell; for distroless, rely on orchestrator
# health checks (Kubernetes livenessProbe, ECS health check, etc.)
# If you need HEALTHCHECK in Docker, use a minimal base like alpine instead.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/server", "--health-check"]

# Run as non-root user (65534 = nonroot in distroless)
USER nonroot:nonroot

ENTRYPOINT ["/server"]
