#!/usr/bin/env bash
# setup-prometheus.sh — Set up Prometheus monitoring stack locally or via Docker Compose.
#
# Deploys Prometheus, Grafana, Alertmanager, and node-exporter with sensible defaults.
# Supports both Docker Compose and local binary installation modes.
#
# Usage:
#   ./setup-prometheus.sh [mode]
#
# Modes:
#   docker    — Deploy full stack via Docker Compose (default)
#   local     — Download and run Prometheus binary locally
#   clean     — Stop and remove all containers and volumes
#
# Environment variables:
#   PROM_VERSION       — Prometheus version (default: 2.53.0)
#   GRAFANA_VERSION    — Grafana version (default: 11.1.0)
#   AM_VERSION         — Alertmanager version (default: 0.27.0)
#   NODE_EXP_VERSION   — Node exporter version (default: 1.8.1)
#   DATA_DIR           — Data directory (default: ./prom-stack-data)
#   PROM_PORT          — Prometheus port (default: 9090)
#   GRAFANA_PORT       — Grafana port (default: 3000)
#   AM_PORT            — Alertmanager port (default: 9093)
#
# Examples:
#   ./setup-prometheus.sh docker
#   PROM_PORT=9091 ./setup-prometheus.sh docker
#   ./setup-prometheus.sh local
#   ./setup-prometheus.sh clean

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

PROM_VERSION="${PROM_VERSION:-2.53.0}"
GRAFANA_VERSION="${GRAFANA_VERSION:-11.1.0}"
AM_VERSION="${AM_VERSION:-0.27.0}"
NODE_EXP_VERSION="${NODE_EXP_VERSION:-1.8.1}"
DATA_DIR="${DATA_DIR:-./prom-stack-data}"
PROM_PORT="${PROM_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
AM_PORT="${AM_PORT:-9093}"
MODE="${1:-docker}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

# ─── Helpers ──────────────────────────────────────────────────────────────────

check_command() {
  if ! command -v "$1" &>/dev/null; then
    log_error "'$1' is required but not installed."
    return 1
  fi
}

wait_for_service() {
  local url="$1" name="$2" retries="${3:-30}" delay="${4:-2}"
  log_info "Waiting for ${name} at ${url}..."
  for ((i=1; i<=retries; i++)); do
    if curl -sf --max-time 2 "${url}" &>/dev/null; then
      log_info "${name} is ready!"
      return 0
    fi
    sleep "${delay}"
  done
  log_error "${name} did not become ready at ${url} after $((retries * delay))s"
  return 1
}

# ─── Generate configs ────────────────────────────────────────────────────────

generate_prometheus_config() {
  local config_dir="$1"
  cat > "${config_dir}/prometheus.yml" << 'PROM_CONF'
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s
  external_labels:
    cluster: local-dev
    environment: development

rule_files:
  - "/etc/prometheus/rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node-exporter"
    static_configs:
      - targets: ["node-exporter:9100"]

  - job_name: "alertmanager"
    static_configs:
      - targets: ["alertmanager:9093"]

  - job_name: "grafana"
    static_configs:
      - targets: ["grafana:3000"]
PROM_CONF
}

generate_alertmanager_config() {
  local config_dir="$1"
  cat > "${config_dir}/alertmanager.yml" << 'AM_CONF'
global:
  resolve_timeout: 5m

route:
  receiver: "default"
  group_by: ["alertname", "job"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: "default"
    webhook_configs:
      - url: "http://localhost:5001/"
        send_resolved: true
AM_CONF
}

generate_alerting_rules() {
  local rules_dir="$1"
  cat > "${rules_dir}/alerts.yml" << 'RULES'
groups:
  - name: basic_alerts
    rules:
      - alert: TargetDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "Target {{ $labels.instance }} ({{ $labels.job }}) is down"

      - alert: HighCPU
        expr: 1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) > 0.85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "CPU above 85% on {{ $labels.instance }}"

      - alert: HighMemory
        expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Memory above 90% on {{ $labels.instance }}"

      - alert: DiskSpaceLow
        expr: |
          1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} /
               node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) > 0.85
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "Disk above 85% on {{ $labels.instance }} ({{ $labels.mountpoint }})"
RULES
}

generate_grafana_provisioning() {
  local grafana_dir="$1"
  mkdir -p "${grafana_dir}/provisioning/datasources" "${grafana_dir}/provisioning/dashboards"

  cat > "${grafana_dir}/provisioning/datasources/prometheus.yml" << 'DS'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
DS

  cat > "${grafana_dir}/provisioning/dashboards/dashboards.yml" << 'DASH'
apiVersion: 1
providers:
  - name: "default"
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
DASH
}

generate_docker_compose() {
  local dir="$1"
  cat > "${dir}/docker-compose.yml" << COMPOSE
services:
  prometheus:
    image: prom/prometheus:v${PROM_VERSION}
    container_name: prom-stack-prometheus
    restart: unless-stopped
    ports:
      - "${PROM_PORT}:9090"
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./config/rules:/etc/prometheus/rules:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=15d"
      - "--storage.tsdb.wal-compression"
      - "--web.enable-lifecycle"
      - "--web.enable-admin-api"
    networks: [monitoring]
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:9090/-/healthy"]
      interval: 10s
      timeout: 5s
      retries: 3

  alertmanager:
    image: prom/alertmanager:v${AM_VERSION}
    container_name: prom-stack-alertmanager
    restart: unless-stopped
    ports:
      - "${AM_PORT}:9093"
    volumes:
      - ./config/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager_data:/alertmanager
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
    networks: [monitoring]

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: prom-stack-grafana
    restart: unless-stopped
    ports:
      - "${GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - grafana_data:/var/lib/grafana
      - ./config/grafana/provisioning:/etc/grafana/provisioning:ro
    networks: [monitoring]
    depends_on:
      prometheus:
        condition: service_healthy

  node-exporter:
    image: prom/node-exporter:v${NODE_EXP_VERSION}
    container_name: prom-stack-node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--path.rootfs=/rootfs"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\\$\\$|/)"
    networks: [monitoring]
    pid: host

networks:
  monitoring:
    driver: bridge

volumes:
  prometheus_data:
  alertmanager_data:
  grafana_data:
COMPOSE
}

# ─── Docker Mode ──────────────────────────────────────────────────────────────

setup_docker() {
  log_step "Setting up Prometheus stack via Docker Compose"

  check_command docker || exit 1
  check_command curl || exit 1

  mkdir -p "${DATA_DIR}/config/rules" "${DATA_DIR}/config/grafana"
  log_info "Created directory structure at ${DATA_DIR}"

  log_step "Generating configuration files..."
  generate_prometheus_config "${DATA_DIR}/config"
  generate_alertmanager_config "${DATA_DIR}/config"
  generate_alerting_rules "${DATA_DIR}/config/rules"
  generate_grafana_provisioning "${DATA_DIR}/config/grafana"
  generate_docker_compose "${DATA_DIR}"
  log_info "Configuration files generated"

  log_step "Starting Docker Compose stack..."
  cd "${DATA_DIR}"
  docker compose up -d

  echo ""
  log_info "Stack is starting up. Endpoints:"
  echo -e "  Prometheus:    ${BLUE}http://localhost:${PROM_PORT}${NC}"
  echo -e "  Grafana:       ${BLUE}http://localhost:${GRAFANA_PORT}${NC}  (admin/admin)"
  echo -e "  Alertmanager:  ${BLUE}http://localhost:${AM_PORT}${NC}"
  echo -e "  Node Exporter: ${BLUE}http://localhost:9100/metrics${NC}"
  echo ""

  wait_for_service "http://localhost:${PROM_PORT}/-/healthy" "Prometheus" 30 2 || true
  wait_for_service "http://localhost:${GRAFANA_PORT}/api/health" "Grafana" 30 2 || true

  log_info "Setup complete! Run './setup-prometheus.sh clean' to tear down."
}

# ─── Local Binary Mode ───────────────────────────────────────────────────────

setup_local() {
  log_step "Setting up Prometheus locally (binary mode)"

  check_command curl || exit 1
  check_command tar || exit 1

  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)       log_error "Unsupported architecture: ${arch}"; exit 1 ;;
  esac

  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"

  local prom_tar="prometheus-${PROM_VERSION}.${os}-${arch}.tar.gz"
  local prom_url="https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/${prom_tar}"

  mkdir -p "${DATA_DIR}/bin" "${DATA_DIR}/config/rules" "${DATA_DIR}/data"

  generate_prometheus_config "${DATA_DIR}/config"
  sed -i 's/alertmanager:9093/localhost:9093/g; s/node-exporter:9100/localhost:9100/g; s/grafana:3000/localhost:3000/g' \
    "${DATA_DIR}/config/prometheus.yml"
  generate_alerting_rules "${DATA_DIR}/config/rules"

  if [[ ! -f "${DATA_DIR}/bin/prometheus" ]]; then
    log_step "Downloading Prometheus v${PROM_VERSION}..."
    curl -fSL "${prom_url}" -o "/tmp/${prom_tar}"
    tar xzf "/tmp/${prom_tar}" -C "/tmp/"
    cp "/tmp/prometheus-${PROM_VERSION}.${os}-${arch}/prometheus" "${DATA_DIR}/bin/"
    cp "/tmp/prometheus-${PROM_VERSION}.${os}-${arch}/promtool" "${DATA_DIR}/bin/"
    rm -rf "/tmp/${prom_tar}" "/tmp/prometheus-${PROM_VERSION}.${os}-${arch}"
    log_info "Downloaded Prometheus to ${DATA_DIR}/bin/"
  else
    log_info "Prometheus binary already exists at ${DATA_DIR}/bin/prometheus"
  fi

  log_step "Starting Prometheus on port ${PROM_PORT}..."
  "${DATA_DIR}/bin/prometheus" \
    --config.file="${DATA_DIR}/config/prometheus.yml" \
    --storage.tsdb.path="${DATA_DIR}/data" \
    --storage.tsdb.retention.time=15d \
    --web.listen-address=":${PROM_PORT}" \
    --web.enable-lifecycle \
    --web.enable-admin-api &

  local prom_pid=$!
  echo "${prom_pid}" > "${DATA_DIR}/prometheus.pid"
  log_info "Prometheus started with PID ${prom_pid}"
  log_info "Access at http://localhost:${PROM_PORT}"
  log_info "PID file: ${DATA_DIR}/prometheus.pid"
}

# ─── Clean Mode ───────────────────────────────────────────────────────────────

cleanup() {
  log_step "Cleaning up Prometheus stack..."

  if [[ -f "${DATA_DIR}/docker-compose.yml" ]]; then
    cd "${DATA_DIR}"
    docker compose down -v --remove-orphans 2>/dev/null || true
    log_info "Docker containers and volumes removed"
  fi

  if [[ -f "${DATA_DIR}/prometheus.pid" ]]; then
    local stored_pid
    stored_pid=$(cat "${DATA_DIR}/prometheus.pid" 2>/dev/null || echo "")
    if [[ -n "${stored_pid}" ]] && [[ "${stored_pid}" =~ ^[0-9]+$ ]]; then
      if ps -p "${stored_pid}" &>/dev/null; then
        log_info "Stopping Prometheus (PID ${stored_pid})"
      fi
    fi
    rm -f "${DATA_DIR}/prometheus.pid"
  fi

  log_info "Cleanup complete. Remove ${DATA_DIR} manually if desired."
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${MODE}" in
  docker)
    setup_docker
    ;;
  local)
    setup_local
    ;;
  clean|cleanup)
    cleanup
    ;;
  *)
    echo "Usage: $0 [docker|local|clean]"
    echo ""
    echo "Modes:"
    echo "  docker  — Deploy via Docker Compose (default)"
    echo "  local   — Download and run Prometheus binary"
    echo "  clean   — Stop and remove everything"
    exit 1
    ;;
esac
