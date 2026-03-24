#!/usr/bin/env bash
#
# grafana-init.sh — Set up a local Grafana instance with Docker, provisioned
# data sources, and a sample dashboard.
#
# Usage:
#   ./grafana-init.sh                    # Grafana only (with testdata source)
#   ./grafana-init.sh prometheus         # Grafana + Prometheus
#   ./grafana-init.sh loki               # Grafana + Loki
#   ./grafana-init.sh postgres           # Grafana + PostgreSQL
#   ./grafana-init.sh all                # Grafana + Prometheus + Loki + Tempo (LGTM)
#
# Requirements: docker, docker compose (v2), curl
# Ports: Grafana=3000, Prometheus=9090, Loki=3100, Tempo=3200, PostgreSQL=5432
#
# The script creates a ./grafana-local/ directory with all configs and a
# docker-compose.yml. Data persists in Docker volumes.

set -euo pipefail

DATASOURCE="${1:-testdata}"
WORKDIR="./grafana-local"
COMPOSE_FILE="${WORKDIR}/docker-compose.yml"

# ─── Helpers ──────────────────────────────────────────────────────────────────

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

check_deps() {
  for cmd in docker curl; do
    command -v "$cmd" >/dev/null 2>&1 || error "Required command not found: $cmd"
  done
  docker compose version >/dev/null 2>&1 || error "docker compose v2 required"
}

# ─── Directory Setup ─────────────────────────────────────────────────────────

setup_dirs() {
  mkdir -p "${WORKDIR}/provisioning/datasources"
  mkdir -p "${WORKDIR}/provisioning/dashboards"
  mkdir -p "${WORKDIR}/dashboards"
  info "Created directory structure at ${WORKDIR}/"
}

# ─── Provisioning: Data Sources ──────────────────────────────────────────────

write_datasource_testdata() {
  cat > "${WORKDIR}/provisioning/datasources/testdata.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: TestData
    type: testdata
    access: proxy
    isDefault: true
YAML
}

write_datasource_prometheus() {
  cat > "${WORKDIR}/provisioning/datasources/prometheus.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      httpMethod: POST
      timeInterval: "15s"
YAML
}

write_datasource_loki() {
  cat > "${WORKDIR}/provisioning/datasources/loki.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
YAML
}

write_datasource_tempo() {
  cat > "${WORKDIR}/provisioning/datasources/tempo.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: Tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      nodeGraph:
        enabled: true
      tracesToLogsV2:
        datasourceUid: loki
        filterByTraceID: true
YAML
}

write_datasource_postgres() {
  cat > "${WORKDIR}/provisioning/datasources/postgres.yml" <<'YAML'
apiVersion: 1
datasources:
  - name: PostgreSQL
    type: postgres
    access: proxy
    url: postgres:5432
    user: grafana
    jsonData:
      database: grafana
      sslmode: disable
      maxOpenConns: 10
    secureJsonData:
      password: grafana
YAML
}

# ─── Provisioning: Dashboard Provider ────────────────────────────────────────

write_dashboard_provider() {
  cat > "${WORKDIR}/provisioning/dashboards/default.yml" <<'YAML'
apiVersion: 1
providers:
  - name: default
    folder: General
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
YAML
}

# ─── Sample Dashboard ────────────────────────────────────────────────────────

write_sample_dashboard() {
  cat > "${WORKDIR}/dashboards/sample.json" <<'JSON'
{
  "uid": "sample-health",
  "title": "Sample Health Dashboard",
  "tags": ["sample"],
  "schemaVersion": 39,
  "graphTooltip": 1,
  "time": {"from": "now-1h", "to": "now"},
  "refresh": "30s",
  "panels": [
    {
      "id": 1, "type": "stat", "title": "Status",
      "gridPos": {"x": 0, "y": 0, "w": 6, "h": 4},
      "datasource": {"type": "testdata", "uid": "testdata"},
      "targets": [{"scenarioId": "random_walk", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "short"}}
    },
    {
      "id": 2, "type": "timeseries", "title": "Random Walk",
      "gridPos": {"x": 6, "y": 0, "w": 18, "h": 8},
      "datasource": {"type": "testdata", "uid": "testdata"},
      "targets": [{"scenarioId": "random_walk", "refId": "A", "seriesCount": 3}],
      "fieldConfig": {"defaults": {"unit": "short"}}
    }
  ]
}
JSON
}

# ─── Prometheus Config ────────────────────────────────────────────────────────

write_prometheus_config() {
  cat > "${WORKDIR}/prometheus.yml" <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']

  - job_name: grafana
    static_configs:
      - targets: ['grafana:3000']
YAML
}

# ─── Loki Config ──────────────────────────────────────────────────────────────

write_loki_config() {
  cat > "${WORKDIR}/loki-config.yml" <<'YAML'
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
YAML
}

# ─── Tempo Config ─────────────────────────────────────────────────────────────

write_tempo_config() {
  cat > "${WORKDIR}/tempo-config.yml" <<'YAML'
server:
  http_listen_port: 3200
distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal
YAML
}

# ─── Docker Compose ───────────────────────────────────────────────────────────

write_compose() {
  local services_grafana services_extra

  services_grafana='
  grafana:
    image: grafana/grafana:11.1.0
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
    volumes:
      - grafana-data:/var/lib/grafana
      - ./provisioning:/etc/grafana/provisioning
      - ./dashboards:/var/lib/grafana/dashboards
    networks:
      - monitoring
    restart: unless-stopped'

  services_extra=""

  case "$DATASOURCE" in
    prometheus)
      services_extra='
  prometheus:
    image: prom/prometheus:v2.53.0
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=15d"
    networks:
      - monitoring
    restart: unless-stopped'
      ;;
    loki)
      services_extra='
  loki:
    image: grafana/loki:3.1.0
    ports:
      - "3100:3100"
    volumes:
      - ./loki-config.yml:/etc/loki/local-config.yaml
      - loki-data:/loki
    command: -config.file=/etc/loki/local-config.yaml
    networks:
      - monitoring
    restart: unless-stopped'
      ;;
    postgres)
      services_extra='
  postgres:
    image: postgres:16-alpine
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: grafana
      POSTGRES_PASSWORD: grafana
      POSTGRES_DB: grafana
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - monitoring
    restart: unless-stopped'
      ;;
    all)
      services_extra='
  prometheus:
    image: prom/prometheus:v2.53.0
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=15d"
    networks:
      - monitoring
    restart: unless-stopped

  loki:
    image: grafana/loki:3.1.0
    ports:
      - "3100:3100"
    volumes:
      - ./loki-config.yml:/etc/loki/local-config.yaml
      - loki-data:/loki
    command: -config.file=/etc/loki/local-config.yaml
    networks:
      - monitoring
    restart: unless-stopped

  tempo:
    image: grafana/tempo:2.5.0
    ports:
      - "3200:3200"
      - "4317:4317"
      - "4318:4318"
    volumes:
      - ./tempo-config.yml:/etc/tempo/config.yaml
      - tempo-data:/var/tempo
    command: -config.file=/etc/tempo/config.yaml
    networks:
      - monitoring
    restart: unless-stopped'
      ;;
  esac

  # Build volumes list
  local volumes="volumes:
  grafana-data:"
  case "$DATASOURCE" in
    prometheus) volumes="${volumes}
  prometheus-data:" ;;
    loki) volumes="${volumes}
  loki-data:" ;;
    postgres) volumes="${volumes}
  postgres-data:" ;;
    all) volumes="${volumes}
  prometheus-data:
  loki-data:
  tempo-data:" ;;
  esac

  cat > "$COMPOSE_FILE" <<EOF
# Auto-generated by grafana-init.sh — datasource: ${DATASOURCE}
services:${services_grafana}
${services_extra}

networks:
  monitoring:
    driver: bridge

${volumes}
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_deps
  info "Setting up Grafana with datasource: ${DATASOURCE}"

  setup_dirs
  write_datasource_testdata
  write_dashboard_provider
  write_sample_dashboard

  case "$DATASOURCE" in
    testdata)
      info "Using testdata source only"
      ;;
    prometheus)
      write_datasource_prometheus
      write_prometheus_config
      ;;
    loki)
      write_datasource_loki
      write_loki_config
      ;;
    postgres)
      write_datasource_postgres
      ;;
    all)
      write_datasource_prometheus
      write_datasource_loki
      write_datasource_tempo
      write_prometheus_config
      write_loki_config
      write_tempo_config
      ;;
    *)
      error "Unknown datasource: ${DATASOURCE}. Use: prometheus, loki, postgres, all, or omit for testdata."
      ;;
  esac

  write_compose

  info "Starting services with docker compose..."
  cd "$WORKDIR"
  docker compose up -d

  info "Waiting for Grafana to be ready..."
  local retries=30
  until curl -sf http://localhost:3000/api/health >/dev/null 2>&1; do
    retries=$((retries - 1))
    if [ "$retries" -le 0 ]; then
      warn "Grafana did not become ready in time. Check: docker compose logs grafana"
      exit 1
    fi
    sleep 2
  done

  info "Grafana is ready!"
  info "  URL:      http://localhost:3000"
  info "  Login:    admin / admin"
  info "  Config:   ${WORKDIR}/"
  info "  Stop:     cd ${WORKDIR} && docker compose down"
  info "  Destroy:  cd ${WORKDIR} && docker compose down -v"
}

main "$@"
