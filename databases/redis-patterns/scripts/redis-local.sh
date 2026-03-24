#!/usr/bin/env bash
# redis-local.sh — Start Redis locally with Docker
#
# Usage:
#   ./redis-local.sh [standalone|cluster|sentinel]
#
# Modes:
#   standalone  (default) Single Redis instance on port 6379
#   cluster     6-node Redis Cluster (3 primaries + 3 replicas) on ports 7001-7006
#   sentinel    1 primary + 2 replicas + 3 sentinels on ports 6379, 6380-6381, 26379-26381
#
# Prerequisites: Docker and docker compose (v2)
# All data is stored in named volumes. Use 'docker compose down -v' to remove.

set -euo pipefail

MODE="${1:-standalone}"
PROJECT_NAME="redis-local"

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;36m%s\033[0m\n' "$*"; }

check_docker() {
  if ! command -v docker &>/dev/null; then
    red "Error: docker not found. Install Docker first."
    exit 1
  fi
  if ! docker info &>/dev/null 2>&1; then
    red "Error: Docker daemon not running."
    exit 1
  fi
}

start_standalone() {
  info "Starting Redis standalone on port 6379..."
  docker run -d \
    --name "${PROJECT_NAME}-standalone" \
    -p 6379:6379 \
    -v "${PROJECT_NAME}-data:/data" \
    redis:7-alpine \
    redis-server \
      --appendonly yes \
      --maxmemory 256mb \
      --maxmemory-policy allkeys-lru \
      --save 60 1000 \
      --loglevel notice

  green "Redis standalone running on localhost:6379"
  info "Test: redis-cli -h 127.0.0.1 -p 6379 PING"
  info "Stop: docker rm -f ${PROJECT_NAME}-standalone"
}

start_cluster() {
  info "Starting 6-node Redis Cluster on ports 7001-7006..."

  NETWORK="${PROJECT_NAME}-cluster-net"
  docker network create "$NETWORK" 2>/dev/null || true

  for i in $(seq 1 6); do
    PORT=$((7000 + i))
    docker run -d \
      --name "${PROJECT_NAME}-node-${i}" \
      --net "$NETWORK" \
      -p "${PORT}:${PORT}" \
      -p "$((PORT + 10000)):$((PORT + 10000))" \
      redis:7-alpine \
      redis-server \
        --port "$PORT" \
        --cluster-enabled yes \
        --cluster-config-file nodes.conf \
        --cluster-node-timeout 5000 \
        --appendonly yes \
        --maxmemory 128mb \
        --maxmemory-policy allkeys-lru \
        --protected-mode no
  done

  info "Waiting for nodes to start..."
  sleep 3

  # Get container IPs for cluster creation
  HOSTS=""
  for i in $(seq 1 6); do
    IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${PROJECT_NAME}-node-${i}")
    PORT=$((7000 + i))
    HOSTS="$HOSTS $IP:$PORT"
  done

  info "Creating cluster..."
  docker exec "${PROJECT_NAME}-node-1" \
    redis-cli --cluster create $HOSTS \
    --cluster-replicas 1 --cluster-yes

  green "Redis Cluster running on ports 7001-7006"
  info "Test: redis-cli -c -p 7001 CLUSTER INFO"
  info "Stop: for i in \$(seq 1 6); do docker rm -f ${PROJECT_NAME}-node-\$i; done; docker network rm $NETWORK"
}

start_sentinel() {
  info "Starting Redis Sentinel setup (1 primary + 2 replicas + 3 sentinels)..."

  NETWORK="${PROJECT_NAME}-sentinel-net"
  docker network create "$NETWORK" 2>/dev/null || true

  # Start primary
  docker run -d \
    --name "${PROJECT_NAME}-primary" \
    --net "$NETWORK" \
    -p 6379:6379 \
    redis:7-alpine \
    redis-server \
      --appendonly yes \
      --maxmemory 256mb \
      --maxmemory-policy allkeys-lru \
      --protected-mode no

  sleep 1
  PRIMARY_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${PROJECT_NAME}-primary")

  # Start replicas
  for i in 1 2; do
    docker run -d \
      --name "${PROJECT_NAME}-replica-${i}" \
      --net "$NETWORK" \
      -p "$((6379 + i)):6379" \
      redis:7-alpine \
      redis-server \
        --appendonly yes \
        --replicaof "$PRIMARY_IP" 6379 \
        --protected-mode no
  done

  sleep 2

  # Start sentinels
  for i in 1 2 3; do
    SENTINEL_CONF=$(mktemp)
    cat > "$SENTINEL_CONF" <<EOF
port 26379
sentinel monitor mymaster $PRIMARY_IP 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 10000
sentinel parallel-syncs mymaster 1
protected-mode no
EOF
    docker run -d \
      --name "${PROJECT_NAME}-sentinel-${i}" \
      --net "$NETWORK" \
      -p "$((26378 + i)):26379" \
      -v "${SENTINEL_CONF}:/etc/sentinel.conf" \
      redis:7-alpine \
      redis-sentinel /etc/sentinel.conf
    rm -f "$SENTINEL_CONF"
  done

  green "Redis Sentinel setup running:"
  info "  Primary:    localhost:6379"
  info "  Replica 1:  localhost:6380"
  info "  Replica 2:  localhost:6381"
  info "  Sentinel 1: localhost:26379"
  info "  Sentinel 2: localhost:26380"
  info "  Sentinel 3: localhost:26381"
  info ""
  info "Test: redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster"
  info "Stop: docker rm -f ${PROJECT_NAME}-primary ${PROJECT_NAME}-replica-{1,2} ${PROJECT_NAME}-sentinel-{1,2,3}; docker network rm $NETWORK"
}

# Main
check_docker

case "$MODE" in
  standalone)
    start_standalone
    ;;
  cluster)
    start_cluster
    ;;
  sentinel)
    start_sentinel
    ;;
  *)
    red "Unknown mode: $MODE"
    echo "Usage: $0 [standalone|cluster|sentinel]"
    exit 1
    ;;
esac
