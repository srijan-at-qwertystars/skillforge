#!/usr/bin/env bash
#
# setup-grafana.sh — Set up Grafana with Docker, configure provisioning directories,
#                     and create initial datasources.
#
# Usage:
#   ./setup-grafana.sh                          # Defaults: port 3000, ./grafana-data
#   ./setup-grafana.sh --port 3001              # Custom port
#   ./setup-grafana.sh --data-dir /opt/grafana  # Custom data directory
#   ./setup-grafana.sh --prometheus-url http://prometheus:9090
#   ./setup-grafana.sh --loki-url http://loki:3100
#   ./setup-grafana.sh --admin-password secret  # Set admin password (default: admin)
#   ./setup-grafana.sh --grafana-version 11.3.0 # Specific Grafana version
#
# Prerequisites: docker
#
# What this script does:
#   1. Creates provisioning directory structure (datasources, dashboards, alerting)
#   2. Generates datasource provisioning YAML (Prometheus, Loki if URLs provided)
#   3. Generates dashboard provider YAML
#   4. Starts Grafana container with provisioning volumes mounted
#   5. Waits for Grafana to be healthy
#   6. Prints access URL and credentials
#
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
DATA_DIR="${DATA_DIR:-./grafana-data}"
PROMETHEUS_URL="${PROMETHEUS_URL:-}"
LOKI_URL="${LOKI_URL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
GRAFANA_VERSION="${GRAFANA_VERSION:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-grafana}"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)            GRAFANA_PORT="$2"; shift 2 ;;
    --data-dir)        DATA_DIR="$2"; shift 2 ;;
    --prometheus-url)  PROMETHEUS_URL="$2"; shift 2 ;;
    --loki-url)        LOKI_URL="$2"; shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="$2"; shift 2 ;;
    --grafana-version) GRAFANA_VERSION="$2"; shift 2 ;;
    --container-name)  CONTAINER_NAME="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,16p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "==> Setting up Grafana ${GRAFANA_VERSION}"
echo "    Data directory: ${DATA_DIR}"
echo "    Port: ${GRAFANA_PORT}"

# ── Create directory structure ────────────────────────────────────────────────
echo "==> Creating provisioning directories..."
mkdir -p "${DATA_DIR}/provisioning/datasources"
mkdir -p "${DATA_DIR}/provisioning/dashboards"
mkdir -p "${DATA_DIR}/provisioning/alerting"
mkdir -p "${DATA_DIR}/dashboards/infrastructure"
mkdir -p "${DATA_DIR}/dashboards/application"
mkdir -p "${DATA_DIR}/data"

# ── Generate datasource provisioning ─────────────────────────────────────────
echo "==> Generating datasource provisioning..."
cat > "${DATA_DIR}/provisioning/datasources/datasources.yaml" <<DSEOF
apiVersion: 1
datasources:
DSEOF

# Always add Prometheus datasource (use provided URL or default)
PROM_URL="${PROMETHEUS_URL:-http://prometheus:9090}"
cat >> "${DATA_DIR}/provisioning/datasources/datasources.yaml" <<DSEOF
  - name: Prometheus
    type: prometheus
    uid: prometheus-main
    access: proxy
    url: ${PROM_URL}
    isDefault: true
    editable: true
    jsonData:
      timeInterval: "15s"
      httpMethod: POST
DSEOF

# Add Loki if URL provided
if [[ -n "${LOKI_URL}" ]]; then
  cat >> "${DATA_DIR}/provisioning/datasources/datasources.yaml" <<DSEOF
  - name: Loki
    type: loki
    uid: loki-main
    access: proxy
    url: ${LOKI_URL}
    editable: true
    jsonData:
      maxLines: 1000
DSEOF
  echo "    Added Loki datasource: ${LOKI_URL}"
fi

echo "    Added Prometheus datasource: ${PROM_URL}"

# ── Generate dashboard provider ───────────────────────────────────────────────
echo "==> Generating dashboard provider..."
cat > "${DATA_DIR}/provisioning/dashboards/default.yaml" <<'DPEOF'
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
DPEOF

# ── Check for existing container ─────────────────────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "==> Stopping existing container '${CONTAINER_NAME}'..."
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1
fi

# ── Start Grafana container ──────────────────────────────────────────────────
echo "==> Starting Grafana container..."
docker run -d \
  --name "${CONTAINER_NAME}" \
  -p "${GRAFANA_PORT}:3000" \
  -e "GF_SECURITY_ADMIN_PASSWORD=${ADMIN_PASSWORD}" \
  -e "GF_USERS_ALLOW_SIGN_UP=false" \
  -v "$(cd "${DATA_DIR}" && pwd)/provisioning:/etc/grafana/provisioning" \
  -v "$(cd "${DATA_DIR}" && pwd)/dashboards:/var/lib/grafana/dashboards" \
  -v "$(cd "${DATA_DIR}" && pwd)/data:/var/lib/grafana" \
  "grafana/grafana-oss:${GRAFANA_VERSION}" >/dev/null

# ── Wait for Grafana to be ready ─────────────────────────────────────────────
echo "==> Waiting for Grafana to start..."
MAX_WAIT=30
for i in $(seq 1 $MAX_WAIT); do
  if curl -s "http://localhost:${GRAFANA_PORT}/api/health" | grep -q '"database":"ok"'; then
    echo "==> Grafana is ready!"
    break
  fi
  if [[ $i -eq $MAX_WAIT ]]; then
    echo "WARNING: Grafana did not become ready within ${MAX_WAIT}s. Check logs with:"
    echo "  docker logs ${CONTAINER_NAME}"
  fi
  sleep 1
done

# ── Print summary ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo "  Grafana is running!"
echo "  URL:      http://localhost:${GRAFANA_PORT}"
echo "  Login:    admin / ${ADMIN_PASSWORD}"
echo "  Data dir: ${DATA_DIR}"
echo ""
echo "  Provisioning:"
echo "    Datasources: ${DATA_DIR}/provisioning/datasources/"
echo "    Dashboards:  ${DATA_DIR}/provisioning/dashboards/"
echo "    JSON files:  ${DATA_DIR}/dashboards/"
echo ""
echo "  Useful commands:"
echo "    docker logs ${CONTAINER_NAME} --follow"
echo "    docker exec -it ${CONTAINER_NAME} grafana cli plugins ls"
echo "    docker rm -f ${CONTAINER_NAME}"
echo "════════════════════════════════════════════════════"
