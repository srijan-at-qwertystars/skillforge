#!/usr/bin/env bash
# Deploy a Ray Serve application: create deployment, configure autoscaling, health check.
# Usage: ./deploy-ray-serve.sh <config_file> [--address ADDRESS] [--health-check] [--wait SECONDS]
#
# Examples:
#   ./deploy-ray-serve.sh serve_config.yaml
#   ./deploy-ray-serve.sh serve_config.yaml --address ray://10.0.0.1:10001 --health-check
#   ./deploy-ray-serve.sh serve_config.yaml --wait 120

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
CONFIG_FILE=""
RAY_ADDRESS=""
HEALTH_CHECK=false
WAIT_TIMEOUT=60
SERVE_HOST="http://127.0.0.1:8000"
DASHBOARD_URL="http://127.0.0.1:8265"

# ─── Parse arguments ────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <config_file> [--address ADDRESS] [--health-check] [--wait SECONDS]"
    echo ""
    echo "Options:"
    echo "  <config_file>        Ray Serve config YAML file"
    echo "  --address ADDRESS    Ray cluster address (default: auto-detect)"
    echo "  --health-check       Run health check after deployment"
    echo "  --wait SECONDS       Wait timeout for deployment to become healthy (default: 60)"
    echo "  --serve-host URL     Serve endpoint URL (default: http://127.0.0.1:8000)"
    exit 1
fi

CONFIG_FILE="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --address)      RAY_ADDRESS="$2";  shift 2 ;;
        --health-check) HEALTH_CHECK=true; shift   ;;
        --wait)         WAIT_TIMEOUT="$2"; shift 2 ;;
        --serve-host)   SERVE_HOST="$2";   shift 2 ;;
        -h|--help)
            echo "Usage: $0 <config_file> [--address ADDRESS] [--health-check] [--wait SECONDS]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── Validation ──────────────────────────────────────────────────────────────
if [[ ! -f "${CONFIG_FILE}" ]]; then
    err "Config file not found: ${CONFIG_FILE}"
    exit 1
fi

info "Validating config file: ${CONFIG_FILE}"
if ! python3 -c "import yaml; yaml.safe_load(open('${CONFIG_FILE}'))" 2>/dev/null; then
    err "Invalid YAML in ${CONFIG_FILE}"
    exit 1
fi
ok "Config file is valid YAML"

# ─── Check Ray connection ───────────────────────────────────────────────────
info "Checking Ray cluster connection..."
if [[ -n "${RAY_ADDRESS}" ]]; then
    export RAY_ADDRESS="${RAY_ADDRESS}"
fi

if ! ray status >/dev/null 2>&1; then
    err "Cannot connect to Ray cluster. Start a cluster first or specify --address."
    exit 1
fi
ok "Connected to Ray cluster"

# ─── Display deployment plan ────────────────────────────────────────────────
info "Deployment plan:"
python3 -c "
import yaml, sys
with open('${CONFIG_FILE}') as f:
    config = yaml.safe_load(f)

apps = config.get('applications', [])
for app in apps:
    name = app.get('name', 'unnamed')
    prefix = app.get('route_prefix', '/')
    print(f'  Application: {name} (route: {prefix})')
    for dep in app.get('deployments', []):
        dep_name = dep.get('name', 'unnamed')
        replicas = dep.get('num_replicas', 'auto')
        asc = dep.get('autoscaling_config', {})
        if asc:
            min_r = asc.get('min_replicas', '?')
            max_r = asc.get('max_replicas', '?')
            print(f'    Deployment: {dep_name} (replicas: {min_r}-{max_r}, autoscaling)')
        else:
            print(f'    Deployment: {dep_name} (replicas: {replicas})')
"
echo ""

# ─── Deploy ──────────────────────────────────────────────────────────────────
info "Deploying Ray Serve application..."
serve deploy "${CONFIG_FILE}"
ok "Deployment submitted"

# ─── Wait for deployment to be healthy ───────────────────────────────────────
info "Waiting for deployment to become healthy (timeout: ${WAIT_TIMEOUT}s)..."

ELAPSED=0
INTERVAL=5
while [[ ${ELAPSED} -lt ${WAIT_TIMEOUT} ]]; do
    STATUS=$(serve status 2>/dev/null || echo "UNKNOWN")

    if echo "${STATUS}" | grep -q "RUNNING"; then
        ok "All deployments are RUNNING"
        break
    elif echo "${STATUS}" | grep -q "DEPLOY_FAILED"; then
        err "Deployment failed!"
        echo "${STATUS}"
        exit 1
    fi

    sleep "${INTERVAL}"
    ELAPSED=$((ELAPSED + INTERVAL))
    info "Still waiting... (${ELAPSED}s/${WAIT_TIMEOUT}s)"
done

if [[ ${ELAPSED} -ge ${WAIT_TIMEOUT} ]]; then
    warn "Timed out waiting for deployment. Current status:"
    serve status
fi

# ─── Display status ─────────────────────────────────────────────────────────
echo ""
info "Current deployment status:"
serve status
echo ""

# ─── Health check ────────────────────────────────────────────────────────────
if [[ "${HEALTH_CHECK}" == true ]]; then
    info "Running health checks..."
    echo ""

    # Check Serve HTTP endpoint
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${SERVE_HOST}/-/healthz" 2>/dev/null || echo "000")
    if [[ "${HTTP_STATUS}" == "200" ]]; then
        ok "HTTP health check passed (${SERVE_HOST}/-/healthz → ${HTTP_STATUS})"
    else
        warn "HTTP health check returned ${HTTP_STATUS} (may not have /-/healthz route)"
    fi

    # Check Ray Dashboard
    DASH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${DASHBOARD_URL}/api/version" 2>/dev/null || echo "000")
    if [[ "${DASH_STATUS}" == "200" ]]; then
        ok "Dashboard is accessible (${DASHBOARD_URL})"
    else
        warn "Dashboard returned ${DASH_STATUS}"
    fi

    # Check Serve API
    SERVE_API_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${DASHBOARD_URL}/api/serve/applications/" 2>/dev/null || echo "000")
    if [[ "${SERVE_API_STATUS}" == "200" ]]; then
        ok "Serve API is accessible"
    else
        warn "Serve API returned ${SERVE_API_STATUS}"
    fi

    echo ""
fi

# ─── Summary ────────────────────────────────────────────────────────────────
ok "Deployment complete!"
echo ""
info "Endpoints:"
echo "    Serve:     ${SERVE_HOST}"
echo "    Dashboard: ${DASHBOARD_URL}"
echo ""
info "Useful commands:"
echo "    serve status          # Check deployment status"
echo "    serve config          # View active config"
echo "    serve shutdown        # Shut down all deployments"
echo "    serve deploy <file>   # Update deployment"
