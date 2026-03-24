# Multi-stage Dockerfile: Application + Litestream in one container
# Litestream runs the app as a child process via -exec for signal forwarding.

# --- Stage 1: Litestream binary ---
FROM litestream/litestream:latest AS litestream

# --- Stage 2: Application build (example: Go app) ---
# Replace this stage with your application's build process.
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -o /app/server .

# --- Stage 3: Production image ---
FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    sqlite \
    ca-certificates \
    libc6-compat

# Copy Litestream binary
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream

# Copy application binary
COPY --from=builder /app/server /usr/local/bin/server

# Copy Litestream config
COPY litestream.yml /etc/litestream.yml

# Create data directory
RUN mkdir -p /data && chown nobody:nobody /data

# Entrypoint: restore on boot, then run app under Litestream supervision
COPY <<'ENTRYPOINT' /entrypoint.sh
#!/bin/bash
set -e

DB_PATH="${DB_PATH:-/data/app.db}"

# Restore database from replica on first boot (idempotent)
litestream restore -if-db-not-exists -if-replica-exists "$DB_PATH"

# Start Litestream with the application as a child process.
# Litestream handles signal forwarding (SIGTERM -> child).
exec litestream replicate -exec "server --db $DB_PATH --addr :8080"
ENTRYPOINT
RUN chmod +x /entrypoint.sh

EXPOSE 8080 9090
VOLUME ["/data"]

ENTRYPOINT ["/entrypoint.sh"]
