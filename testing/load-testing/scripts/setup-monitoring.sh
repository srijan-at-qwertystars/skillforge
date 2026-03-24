#!/bin/bash
# =============================================================================
# setup-monitoring.sh — Set up InfluxDB + Grafana monitoring for k6 load tests
#
# Usage:
#   ./setup-monitoring.sh [command]
#
# Commands:
#   up        Start the monitoring stack (default)
#   down      Stop the monitoring stack
#   restart   Restart the monitoring stack
#   status    Show status of monitoring services
#   logs      Show logs from monitoring services
#   clean     Stop and remove all data volumes
#   dashboard Import k6 Grafana dashboard
#
# Prerequisites:
#   - Docker and Docker Compose v2+
#
# After setup:
#   - Grafana:  http://localhost:3000 (admin/admin)
#   - InfluxDB: http://localhost:8086
#   - Run k6:   k6 run --out influxdb=http://localhost:8086/k6 your-test.js
# =============================================================================

set -euo pipefail

# --- Config ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITORING_DIR="${SCRIPT_DIR}/../monitoring"
COMPOSE_FILE="${MONITORING_DIR}/docker-compose.yml"
GRAFANA_URL="http://localhost:3000"
GRAFANA_USER="admin"
GRAFANA_PASS="admin"
INFLUXDB_URL="http://localhost:8086"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Check prerequisites ---
check_prereqs() {
  if ! command -v docker &>/dev/null; then
    error "Docker is not installed. Install from https://docs.docker.com/get-docker/"
  fi

  if ! docker compose version &>/dev/null 2>&1; then
    error "Docker Compose v2 is required. Update Docker Desktop or install compose plugin."
  fi

  if ! docker info &>/dev/null 2>&1; then
    error "Docker daemon is not running. Start Docker first."
  fi
}

# --- Create compose file if it doesn't exist ---
ensure_compose_file() {
  if [ -f "${COMPOSE_FILE}" ]; then
    return
  fi

  info "Creating monitoring stack configuration..."
  mkdir -p "${MONITORING_DIR}/grafana/provisioning/datasources"
  mkdir -p "${MONITORING_DIR}/grafana/provisioning/dashboards"
  mkdir -p "${MONITORING_DIR}/grafana/dashboards"

  cat > "${COMPOSE_FILE}" << 'COMPOSE'
services:
  influxdb:
    image: influxdb:1.8
    container_name: k6-influxdb
    ports:
      - "8086:8086"
    environment:
      - INFLUXDB_DB=k6
      - INFLUXDB_HTTP_MAX_BODY_SIZE=0
      - INFLUXDB_HTTP_WRITE_TRACING=false
    volumes:
      - influxdb-data:/var/lib/influxdb
    healthcheck:
      test: ["CMD", "influx", "-execute", "SHOW DATABASES"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: k6-grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_INSTALL_PLUGINS=
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
    depends_on:
      influxdb:
        condition: service_healthy
    restart: unless-stopped

volumes:
  influxdb-data:
  grafana-data:
COMPOSE

  # InfluxDB datasource
  cat > "${MONITORING_DIR}/grafana/provisioning/datasources/influxdb.yml" << 'DS'
apiVersion: 1
datasources:
  - name: InfluxDB
    type: influxdb
    access: proxy
    url: http://influxdb:8086
    database: k6
    isDefault: true
    editable: true
DS

  # Dashboard provider
  cat > "${MONITORING_DIR}/grafana/provisioning/dashboards/dashboard.yml" << 'DP'
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: 'Load Testing'
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
DP

  info "Monitoring configuration created"
}

# --- Import k6 dashboard ---
import_dashboard() {
  info "Importing k6 Grafana dashboard..."

  # Wait for Grafana to be ready
  local retries=30
  while ! curl -sf "${GRAFANA_URL}/api/health" &>/dev/null; do
    retries=$((retries - 1))
    if [ ${retries} -le 0 ]; then
      warn "Grafana not responding. Dashboard import skipped — import manually (Dashboard ID: 2587)"
      return
    fi
    sleep 2
  done

  # Import dashboard from Grafana.com (ID: 2587 = k6 Load Testing Results)
  local dashboard_json
  dashboard_json=$(curl -sf "https://grafana.com/api/dashboards/2587/revisions/3/download" 2>/dev/null || true)

  if [ -z "${dashboard_json}" ]; then
    warn "Could not download dashboard from Grafana.com. Import manually: Dashboard ID 2587"
    return
  fi

  # Wrap in import payload
  local import_payload
  import_payload=$(echo "${dashboard_json}" | jq '{
    dashboard: .,
    overwrite: true,
    inputs: [{
      name: "DS_INFLUXDB",
      type: "datasource",
      pluginId: "influxdb",
      value: "InfluxDB"
    }],
    folderId: 0
  }')

  local result
  result=$(curl -sf -X POST "${GRAFANA_URL}/api/dashboards/import" \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
    -d "${import_payload}" 2>/dev/null || true)

  if echo "${result}" | jq -e '.uid' &>/dev/null; then
    local uid
    uid=$(echo "${result}" | jq -r '.uid')
    info "Dashboard imported: ${GRAFANA_URL}/d/${uid}"
  else
    warn "Dashboard import may have failed. Import manually: Grafana → + → Import → ID: 2587"
  fi
}

# --- Commands ---
cmd_up() {
  check_prereqs
  ensure_compose_file

  info "Starting monitoring stack..."
  docker compose -f "${COMPOSE_FILE}" up -d

  # Wait for services
  info "Waiting for services to be ready..."
  local retries=30
  while ! curl -sf "${INFLUXDB_URL}/ping" &>/dev/null; do
    retries=$((retries - 1))
    if [ ${retries} -le 0 ]; then
      warn "InfluxDB not responding after 60s"
      break
    fi
    sleep 2
  done

  import_dashboard

  echo ""
  info "✅ Monitoring stack is running"
  echo ""
  echo "  Grafana:     ${GRAFANA_URL} (admin/admin)"
  echo "  InfluxDB:    ${INFLUXDB_URL}"
  echo ""
  echo "  Run k6 with monitoring:"
  echo "    k6 run --out influxdb=${INFLUXDB_URL}/k6 your-test.js"
  echo ""
}

cmd_down() {
  check_prereqs
  info "Stopping monitoring stack..."
  docker compose -f "${COMPOSE_FILE}" down
  info "Monitoring stack stopped"
}

cmd_restart() {
  cmd_down
  cmd_up
}

cmd_status() {
  check_prereqs
  echo ""
  docker compose -f "${COMPOSE_FILE}" ps
  echo ""

  if curl -sf "${INFLUXDB_URL}/ping" &>/dev/null; then
    info "InfluxDB: ✅ Running (${INFLUXDB_URL})"
  else
    warn "InfluxDB: ❌ Not responding"
  fi

  if curl -sf "${GRAFANA_URL}/api/health" &>/dev/null; then
    info "Grafana:  ✅ Running (${GRAFANA_URL})"
  else
    warn "Grafana:  ❌ Not responding"
  fi
  echo ""
}

cmd_logs() {
  check_prereqs
  docker compose -f "${COMPOSE_FILE}" logs --tail=50 -f
}

cmd_clean() {
  check_prereqs
  warn "This will remove all monitoring data (InfluxDB + Grafana)."
  read -rp "Are you sure? [y/N] " -n 1 reply
  echo
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    docker compose -f "${COMPOSE_FILE}" down -v
    info "Monitoring stack and data removed"
  else
    info "Cancelled"
  fi
}

cmd_dashboard() {
  import_dashboard
}

# --- Main ---
COMMAND="${1:-up}"

case "${COMMAND}" in
  up)        cmd_up ;;
  down)      cmd_down ;;
  restart)   cmd_restart ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  clean)     cmd_clean ;;
  dashboard) cmd_dashboard ;;
  -h|--help)
    head -20 "$0" | tail -17
    ;;
  *)
    error "Unknown command: ${COMMAND}. Options: up|down|restart|status|logs|clean|dashboard"
    ;;
esac
