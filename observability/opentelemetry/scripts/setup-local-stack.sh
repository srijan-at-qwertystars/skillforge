#!/usr/bin/env bash
# setup-local-stack.sh — Set up a local OpenTelemetry observability stack
#
# Creates a Docker Compose stack with:
#   - OpenTelemetry Collector (contrib, ports 4317/4318)
#   - Jaeger (traces, UI on :16686)
#   - Prometheus (metrics, UI on :9090)
#   - Grafana (dashboards, UI on :3000)
#
# Usage:
#   ./setup-local-stack.sh [up|down|status|clean]
#
# Requirements: docker, docker compose (v2)

set -euo pipefail

STACK_DIR="${OTEL_STACK_DIR:-./otel-local-stack}"
COMPOSE_PROJECT="otel-dev"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_prereqs() {
  local missing=0
  for cmd in docker; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command not found: $cmd"
      missing=1
    fi
  done

  if ! docker compose version &>/dev/null 2>&1; then
    log_error "docker compose v2 is required. Install: https://docs.docker.com/compose/install/"
    missing=1
  fi

  if ! docker info &>/dev/null 2>&1; then
    log_error "Docker daemon is not running"
    missing=1
  fi

  if [ "$missing" -eq 1 ]; then
    exit 1
  fi
}

create_collector_config() {
  cat > "$STACK_DIR/collector-config.yaml" << 'YAML'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    send_batch_size: 1024
    timeout: 2s

exporters:
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true
  prometheus:
    endpoint: 0.0.0.0:8889
    resource_to_telemetry_conversion:
      enabled: true
  debug:
    verbosity: basic

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679

service:
  extensions: [health_check, zpages]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/jaeger, debug]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [debug]
YAML
}

create_prometheus_config() {
  cat > "$STACK_DIR/prometheus.yml" << 'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'otel-collector'
    static_configs:
      - targets: ['otel-collector:8889']

  - job_name: 'otel-collector-internal'
    static_configs:
      - targets: ['otel-collector:8888']
YAML
}

create_grafana_datasources() {
  mkdir -p "$STACK_DIR/grafana/provisioning/datasources"
  cat > "$STACK_DIR/grafana/provisioning/datasources/datasources.yaml" << 'YAML'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true

  - name: Jaeger
    type: jaeger
    access: proxy
    url: http://jaeger:16686
    editable: true

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
YAML
}

create_docker_compose() {
  cat > "$STACK_DIR/docker-compose.yml" << 'YAML'
services:
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    container_name: otel-collector
    command: ["--config=/etc/otelcol/config.yaml"]
    volumes:
      - ./collector-config.yaml:/etc/otelcol/config.yaml:ro
    ports:
      - "4317:4317"     # OTLP gRPC
      - "4318:4318"     # OTLP HTTP
      - "8889:8889"     # Prometheus metrics
      - "13133:13133"   # Health check
      - "55679:55679"   # zpages
    depends_on:
      - jaeger
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:13133/"]
      interval: 10s
      timeout: 5s
      retries: 3

  jaeger:
    image: jaegertracing/all-in-one:latest
    container_name: jaeger
    environment:
      - COLLECTOR_OTLP_ENABLED=true
    ports:
      - "16686:16686"   # Jaeger UI
      - "14268:14268"   # Jaeger HTTP collector
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=24h'
      - '--web.enable-lifecycle'
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports:
      - "9090:9090"     # Prometheus UI
    depends_on:
      - otel-collector
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - grafana-data:/var/lib/grafana
    ports:
      - "3000:3000"     # Grafana UI
    depends_on:
      - prometheus
      - jaeger
    restart: unless-stopped

volumes:
  prometheus-data:
  grafana-data:
YAML
}

cmd_up() {
  log_info "Creating stack directory: $STACK_DIR"
  mkdir -p "$STACK_DIR"

  log_info "Generating configurations..."
  create_collector_config
  create_prometheus_config
  create_grafana_datasources
  create_docker_compose

  log_info "Starting observability stack..."
  cd "$STACK_DIR"
  docker compose -p "$COMPOSE_PROJECT" up -d

  echo ""
  log_info "Stack is starting. Services:"
  echo "  • OTel Collector gRPC:  http://localhost:4317"
  echo "  • OTel Collector HTTP:  http://localhost:4318"
  echo "  • Jaeger UI:            http://localhost:16686"
  echo "  • Prometheus UI:        http://localhost:9090"
  echo "  • Grafana UI:           http://localhost:3000  (admin/admin)"
  echo "  • Collector zpages:     http://localhost:55679/debug/tracez"
  echo "  • Collector health:     http://localhost:13133"
  echo ""
  log_info "Configure your app: export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317"
}

cmd_down() {
  if [ ! -f "$STACK_DIR/docker-compose.yml" ]; then
    log_error "Stack not found at $STACK_DIR"
    exit 1
  fi
  log_info "Stopping observability stack..."
  cd "$STACK_DIR"
  docker compose -p "$COMPOSE_PROJECT" down
  log_info "Stack stopped."
}

cmd_status() {
  if [ ! -f "$STACK_DIR/docker-compose.yml" ]; then
    log_error "Stack not found at $STACK_DIR"
    exit 1
  fi
  cd "$STACK_DIR"
  docker compose -p "$COMPOSE_PROJECT" ps
}

cmd_clean() {
  cmd_down 2>/dev/null || true
  log_info "Removing stack directory and volumes..."
  cd "$STACK_DIR" && docker compose -p "$COMPOSE_PROJECT" down -v 2>/dev/null || true
  cd - > /dev/null
  rm -rf "$STACK_DIR"
  log_info "Clean complete."
}

usage() {
  echo "Usage: $0 [up|down|status|clean]"
  echo ""
  echo "Commands:"
  echo "  up      Create and start the observability stack"
  echo "  down    Stop the stack (preserves data)"
  echo "  status  Show container status"
  echo "  clean   Stop and remove everything (including data)"
  echo ""
  echo "Environment:"
  echo "  OTEL_STACK_DIR  Stack directory (default: ./otel-local-stack)"
}

case "${1:-up}" in
  up)     check_prereqs; cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  clean)  cmd_clean ;;
  -h|--help) usage ;;
  *)      log_error "Unknown command: $1"; usage; exit 1 ;;
esac
