#!/usr/bin/env bash
#
# setup-keycloak.sh — Sets up Keycloak via Docker Compose with PostgreSQL
#
# Usage:
#   ./setup-keycloak.sh                     # Start with defaults
#   ./setup-keycloak.sh --import realm.json # Start and import a realm config
#   ./setup-keycloak.sh --stop              # Stop and remove containers
#   ./setup-keycloak.sh --reset             # Stop, remove volumes, and restart fresh
#
# Environment variables (override defaults):
#   KC_VERSION          Keycloak version (default: 25.0)
#   KC_ADMIN            Admin username (default: admin)
#   KC_ADMIN_PASSWORD   Admin password (default: admin)
#   KC_HTTP_PORT        HTTP port (default: 8080)
#   KC_HTTPS_PORT       HTTPS port (default: 8443)
#   PG_VERSION          PostgreSQL version (default: 16)
#   PG_PASSWORD         PostgreSQL password (default: keycloak)
#   COMPOSE_PROJECT     Docker Compose project name (default: keycloak-dev)
#
# Prerequisites:
#   - Docker and Docker Compose (v2) installed
#   - Ports 8080 and 5432 available (or override via env vars)
#
# This script is self-contained: it generates a docker-compose.yml in a temp
# directory, starts the stack, waits for Keycloak to be healthy, and optionally
# imports a realm configuration file.

set -euo pipefail

# --- Configuration ---
KC_VERSION="${KC_VERSION:-25.0}"
KC_ADMIN="${KC_ADMIN:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"
KC_HTTP_PORT="${KC_HTTP_PORT:-8080}"
KC_HTTPS_PORT="${KC_HTTPS_PORT:-8443}"
PG_VERSION="${PG_VERSION:-16}"
PG_PASSWORD="${PG_PASSWORD:-keycloak}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-keycloak-dev}"

WORK_DIR="${HOME}/.keycloak-setup/${COMPOSE_PROJECT}"
COMPOSE_FILE="${WORK_DIR}/docker-compose.yml"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Functions ---

check_prerequisites() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    if ! docker compose version &>/dev/null 2>&1; then
        log_error "Docker Compose v2 is not available. Please install docker-compose-plugin."
        exit 1
    fi
}

generate_compose_file() {
    mkdir -p "${WORK_DIR}"
    cat > "${COMPOSE_FILE}" <<YAML
version: "3.9"

services:
  postgres:
    image: postgres:${PG_VERSION}-alpine
    container_name: ${COMPOSE_PROJECT}-postgres
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: ${PG_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak -d keycloak"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - keycloak-net

  keycloak:
    image: quay.io/keycloak/keycloak:${KC_VERSION}
    container_name: ${COMPOSE_PROJECT}-keycloak
    command: start-dev --import-realm
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: ${PG_PASSWORD}
      KEYCLOAK_ADMIN: ${KC_ADMIN}
      KEYCLOAK_ADMIN_PASSWORD: ${KC_ADMIN_PASSWORD}
      KC_HEALTH_ENABLED: "true"
      KC_METRICS_ENABLED: "true"
      KC_LOG_LEVEL: INFO
      KC_FEATURES: "token-exchange,admin-fine-grained-authz,organization"
    ports:
      - "${KC_HTTP_PORT}:8080"
      - "${KC_HTTPS_PORT}:8443"
    volumes:
      - ${WORK_DIR}/import:/opt/keycloak/data/import:ro
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "exec 3<>/dev/tcp/localhost/9000 && echo -e 'GET /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3 && cat <&3 | grep -q '\"status\":\"UP\"'"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 30s
    networks:
      - keycloak-net

volumes:
  pgdata:

networks:
  keycloak-net:
    driver: bridge
YAML
    log_info "Generated docker-compose.yml at ${COMPOSE_FILE}"
}

start_stack() {
    log_info "Starting Keycloak stack (project: ${COMPOSE_PROJECT})..."
    docker compose -f "${COMPOSE_FILE}" -p "${COMPOSE_PROJECT}" up -d

    log_info "Waiting for Keycloak to be healthy..."
    local retries=0
    local max_retries=60
    while [ $retries -lt $max_retries ]; do
        if curl -sf "http://localhost:${KC_HTTP_PORT}/health/ready" &>/dev/null; then
            log_info "Keycloak is ready!"
            echo ""
            echo "  Admin Console: http://localhost:${KC_HTTP_PORT}/admin"
            echo "  Username:      ${KC_ADMIN}"
            echo "  Password:      ${KC_ADMIN_PASSWORD}"
            echo "  Metrics:       http://localhost:${KC_HTTP_PORT}/metrics"
            echo "  Health:        http://localhost:${KC_HTTP_PORT}/health"
            echo ""
            return 0
        fi
        retries=$((retries + 1))
        sleep 5
    done

    log_error "Keycloak did not become healthy within $((max_retries * 5)) seconds."
    log_error "Check logs with: docker compose -f ${COMPOSE_FILE} -p ${COMPOSE_PROJECT} logs keycloak"
    exit 1
}

stop_stack() {
    log_info "Stopping Keycloak stack..."
    if [ -f "${COMPOSE_FILE}" ]; then
        docker compose -f "${COMPOSE_FILE}" -p "${COMPOSE_PROJECT}" down
        log_info "Stack stopped."
    else
        log_warn "No compose file found at ${COMPOSE_FILE}. Nothing to stop."
    fi
}

reset_stack() {
    log_info "Resetting Keycloak stack (removing volumes)..."
    if [ -f "${COMPOSE_FILE}" ]; then
        docker compose -f "${COMPOSE_FILE}" -p "${COMPOSE_PROJECT}" down -v
    fi
    rm -rf "${WORK_DIR}/import"
    log_info "Stack reset. Run the script again to start fresh."
}

import_realm() {
    local realm_file="$1"
    if [ ! -f "${realm_file}" ]; then
        log_error "Realm file not found: ${realm_file}"
        exit 1
    fi

    mkdir -p "${WORK_DIR}/import"
    cp "${realm_file}" "${WORK_DIR}/import/"
    log_info "Copied realm config to import directory: ${realm_file}"
}

# --- Main ---

check_prerequisites

IMPORT_FILE=""
ACTION="start"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --import)
            IMPORT_FILE="$2"
            shift 2
            ;;
        --stop)
            ACTION="stop"
            shift
            ;;
        --reset)
            ACTION="reset"
            shift
            ;;
        --help|-h)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

case "${ACTION}" in
    start)
        mkdir -p "${WORK_DIR}/import"
        if [ -n "${IMPORT_FILE}" ]; then
            import_realm "${IMPORT_FILE}"
        fi
        generate_compose_file
        start_stack
        ;;
    stop)
        stop_stack
        ;;
    reset)
        reset_stack
        ;;
esac
