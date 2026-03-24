#!/usr/bin/env bash
# ==============================================================================
# event-store-setup.sh — Set up EventStoreDB locally via Docker with projections
#
# Usage:
#   ./event-store-setup.sh          # Start EventStoreDB (single node, insecure)
#   ./event-store-setup.sh stop     # Stop and remove the container
#   ./event-store-setup.sh status   # Check if EventStoreDB is running
#   ./event-store-setup.sh logs     # Tail container logs
#
# After starting:
#   - Admin UI:  http://localhost:2113
#   - gRPC:      localhost:2113 (shared port in insecure mode)
#   - All projections enabled, standard projections auto-started
#
# Requirements: Docker
# ==============================================================================
set -euo pipefail

CONTAINER_NAME="esdb-dev"
IMAGE="eventstore/eventstore:latest"
HTTP_PORT="${ESDB_HTTP_PORT:-2113}"
DATA_VOLUME="esdb-dev-data"
LOGS_VOLUME="esdb-dev-logs"

usage() {
  echo "Usage: $0 [start|stop|status|logs]"
  echo "  start   Start EventStoreDB (default)"
  echo "  stop    Stop and remove the container"
  echo "  status  Check if running and healthy"
  echo "  logs    Tail container logs"
}

check_docker() {
  if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is not installed or not in PATH." >&2
    exit 1
  fi
  if ! docker info &>/dev/null 2>&1; then
    echo "ERROR: Docker daemon is not running." >&2
    exit 1
  fi
}

start() {
  check_docker

  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "EventStoreDB is already running (container: ${CONTAINER_NAME})"
    echo "  Admin UI: http://localhost:${HTTP_PORT}"
    return 0
  fi

  # Remove stopped container if it exists
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

  echo "Starting EventStoreDB..."
  docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${HTTP_PORT}:2113" \
    -e EVENTSTORE_CLUSTER_SIZE=1 \
    -e EVENTSTORE_RUN_PROJECTIONS=All \
    -e EVENTSTORE_START_STANDARD_PROJECTIONS=true \
    -e EVENTSTORE_INSECURE=true \
    -e EVENTSTORE_ENABLE_ATOM_PUB_OVER_HTTP=true \
    -e EVENTSTORE_MEM_DB=false \
    -v "${DATA_VOLUME}:/var/lib/eventstore" \
    -v "${LOGS_VOLUME}:/var/log/eventstore" \
    "${IMAGE}"

  echo "Waiting for EventStoreDB to be ready..."
  local retries=30
  while [ $retries -gt 0 ]; do
    if curl -sf "http://localhost:${HTTP_PORT}/health/live" &>/dev/null; then
      echo "EventStoreDB is ready!"
      echo "  Admin UI: http://localhost:${HTTP_PORT}"
      echo "  gRPC:     localhost:${HTTP_PORT}"
      echo "  Projections: All enabled"
      return 0
    fi
    retries=$((retries - 1))
    sleep 1
  done

  echo "WARNING: EventStoreDB did not become healthy within 30s."
  echo "Check logs with: $0 logs"
  return 1
}

stop() {
  check_docker
  echo "Stopping EventStoreDB..."
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  echo "Stopped. Data persisted in Docker volumes: ${DATA_VOLUME}, ${LOGS_VOLUME}"
  echo "To remove data: docker volume rm ${DATA_VOLUME} ${LOGS_VOLUME}"
}

status() {
  check_docker
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "EventStoreDB is RUNNING"
    if curl -sf "http://localhost:${HTTP_PORT}/health/live" &>/dev/null; then
      echo "  Health: HEALTHY"
    else
      echo "  Health: NOT RESPONDING (may be starting up)"
    fi
    echo "  Admin UI: http://localhost:${HTTP_PORT}"
    docker ps --filter "name=${CONTAINER_NAME}" --format "table {{.Status}}\t{{.Ports}}"
  else
    echo "EventStoreDB is NOT RUNNING"
  fi
}

logs() {
  check_docker
  docker logs -f "${CONTAINER_NAME}"
}

case "${1:-start}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  logs)   logs ;;
  -h|--help) usage ;;
  *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac
