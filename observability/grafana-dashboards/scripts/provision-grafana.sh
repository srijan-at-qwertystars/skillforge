#!/usr/bin/env bash
#
# provision-grafana.sh — Spin up Grafana with Prometheus, Loki & Promtail via Docker Compose.
#
# Usage:
#   ./provision-grafana.sh [OPTIONS]
#
# Options:
#   --data-dir <DIR>         Persistent data directory (default: ./grafana-data)
#   --port <PORT>            Grafana HTTP port (default: 3000)
#   --prometheus-port <PORT> Prometheus HTTP port (default: 9090)
#   -h, --help               Show this help message
#
# Description:
#   Generates Docker Compose, Grafana provisioning, Prometheus, Loki, and
#   Promtail configuration files, then starts the stack with docker compose.
#   After launch it polls /api/health until Grafana is ready and prints
#   access URLs with default credentials.
#
# Dependencies: docker, docker compose
#

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DATA_DIR="./grafana-data"
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090

# ── Functions ─────────────────────────────────────────────────────────────────
usage() {
    sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
    exit 0
}

die() { echo "ERROR: $*" >&2; exit 1; }

check_deps() {
    command -v docker >/dev/null 2>&1 || die "'docker' is required but not found in PATH."
    docker compose version >/dev/null 2>&1 || die "'docker compose' plugin is required."
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-dir)         DATA_DIR="${2:?--data-dir requires a value}"; shift 2 ;;
        --port)             GRAFANA_PORT="${2:?--port requires a value}"; shift 2 ;;
        --prometheus-port)  PROMETHEUS_PORT="${2:?--prometheus-port requires a value}"; shift 2 ;;
        -h|--help)          usage ;;
        *)                  die "Unknown option: $1" ;;
    esac
done

# ── Validation ────────────────────────────────────────────────────────────────
check_deps

echo "Provisioning observability stack..."
echo "  Data directory    : ${DATA_DIR}"
echo "  Grafana port      : ${GRAFANA_PORT}"
echo "  Prometheus port   : ${PROMETHEUS_PORT}"
echo ""

# ── Create directory structure ────────────────────────────────────────────────
mkdir -p "${DATA_DIR}/provisioning/datasources"
mkdir -p "${DATA_DIR}/prometheus"
mkdir -p "${DATA_DIR}/loki"
mkdir -p "${DATA_DIR}/promtail"

# ── Generate docker-compose.yml ──────────────────────────────────────────────
cat > "${DATA_DIR}/docker-compose.yml" <<YAML
version: "3.8"

services:
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "${GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - grafana-storage:/var/lib/grafana
      - ./provisioning:/etc/grafana/provisioning
    depends_on:
      - prometheus
      - loki
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "${PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-storage:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--web.enable-lifecycle"
    restart: unless-stopped

  loki:
    image: grafana/loki:latest
    container_name: loki
    ports:
      - "3100:3100"
    volumes:
      - ./loki/loki-config.yml:/etc/loki/local-config.yaml:ro
      - loki-storage:/loki
    command: -config.file=/etc/loki/local-config.yaml
    restart: unless-stopped

  promtail:
    image: grafana/promtail:latest
    container_name: promtail
    volumes:
      - ./promtail/promtail-config.yml:/etc/promtail/config.yml:ro
      - /var/log:/var/log:ro
    command: -config.file=/etc/promtail/config.yml
    depends_on:
      - loki
    restart: unless-stopped

volumes:
  grafana-storage:
  prometheus-storage:
  loki-storage:
YAML

echo "✓ Generated docker-compose.yml"

# ── Generate Grafana data source provisioning ────────────────────────────────
cat > "${DATA_DIR}/provisioning/datasources/datasources.yml" <<YAML
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
    jsonData:
      timeInterval: "15s"

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
    jsonData:
      maxLines: 1000
YAML

echo "✓ Generated datasources provisioning"

# ── Generate prometheus.yml ──────────────────────────────────────────────────
cat > "${DATA_DIR}/prometheus/prometheus.yml" <<YAML
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "grafana"
    static_configs:
      - targets: ["grafana:3000"]
    metrics_path: /metrics
YAML

echo "✓ Generated prometheus.yml"

# ── Generate loki-config.yml ─────────────────────────────────────────────────
cat > "${DATA_DIR}/loki/loki-config.yml" <<YAML
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: "2020-10-24"
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h

analytics:
  reporting_enabled: false
YAML

echo "✓ Generated loki-config.yml"

# ── Generate promtail-config.yml ─────────────────────────────────────────────
cat > "${DATA_DIR}/promtail/promtail-config.yml" <<YAML
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          __path__: /var/log/*.log
YAML

echo "✓ Generated promtail-config.yml"

# ── Start the stack ──────────────────────────────────────────────────────────
echo ""
echo "Starting Docker Compose stack..."
(cd "${DATA_DIR}" && docker compose up -d) || die "docker compose up failed."

# ── Wait for Grafana to be healthy ───────────────────────────────────────────
echo ""
echo "Waiting for Grafana to become healthy..."
MAX_WAIT=90
ELAPSED=0
INTERVAL=3

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    if curl -fsSL "http://localhost:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
        echo "✓ Grafana is healthy!"
        break
    fi
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
    echo "  ... waiting (${ELAPSED}s / ${MAX_WAIT}s)"
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    echo "⚠ Grafana did not become healthy within ${MAX_WAIT}s."
    echo "  Check logs with: cd ${DATA_DIR} && docker compose logs grafana"
fi

# ── Print summary ────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Observability stack is running!"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  Grafana     : http://localhost:${GRAFANA_PORT}"
echo "  Prometheus  : http://localhost:${PROMETHEUS_PORT}"
echo "  Loki        : http://localhost:3100"
echo ""
echo "  Default credentials:"
echo "    Username  : admin"
echo "    Password  : admin"
echo ""
echo "  Pre-configured data sources:"
echo "    • Prometheus (default)"
echo "    • Loki"
echo ""
echo "  Manage the stack:"
echo "    cd ${DATA_DIR} && docker compose logs -f"
echo "    cd ${DATA_DIR} && docker compose down"
echo "═══════════════════════════════════════════════════════"
