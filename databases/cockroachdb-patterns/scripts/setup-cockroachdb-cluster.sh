#!/usr/bin/env bash
#
# setup-cockroachdb-cluster.sh
# Sets up a 3-node CockroachDB cluster using Docker, initializes it,
# creates a database, and verifies connectivity via SQL shell.
#
# Usage: ./setup-cockroachdb-cluster.sh [database_name]
#   database_name: Name of the database to create (default: "appdb")

set -euo pipefail

DATABASE_NAME="${1:-appdb}"
CRDB_VERSION="${CRDB_VERSION:-cockroachdb/cockroach:latest}"
NETWORK_NAME="crdb-net"
NODE_PREFIX="crdb-node"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

cleanup() {
    log_warn "Cleaning up existing cluster containers and network..."
    for i in 1 2 3; do
        docker rm -f "${NODE_PREFIX}${i}" 2>/dev/null || true
    done
    docker network rm "${NETWORK_NAME}" 2>/dev/null || true
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    if ! docker info &>/dev/null; then
        log_error "Docker daemon is not running. Please start Docker."
        exit 1
    fi
    log_info "Docker is available."
}

create_network() {
    log_info "Creating Docker network: ${NETWORK_NAME}"
    docker network create "${NETWORK_NAME}" 2>/dev/null || {
        log_warn "Network ${NETWORK_NAME} already exists, reusing."
    }
}

start_nodes() {
    log_info "Starting 3-node CockroachDB cluster (image: ${CRDB_VERSION})..."

    local join_list="${NODE_PREFIX}1:26257,${NODE_PREFIX}2:26257,${NODE_PREFIX}3:26257"

    for i in 1 2 3; do
        local sql_port=$((26256 + i))
        local http_port=$((8079 + i))
        local node_name="${NODE_PREFIX}${i}"

        log_info "Starting ${node_name} (SQL: ${sql_port}, HTTP: ${http_port})..."

        docker run -d \
            --name "${node_name}" \
            --hostname "${node_name}" \
            --network "${NETWORK_NAME}" \
            -p "${sql_port}:26257" \
            -p "${http_port}:8080" \
            -v "${node_name}-data:/cockroach/cockroach-data" \
            "${CRDB_VERSION}" start \
            --insecure \
            --join="${join_list}" \
            --advertise-addr="${node_name}:26257" \
            --http-addr="0.0.0.0:8080"

        log_info "${node_name} started."
    done
}

init_cluster() {
    log_info "Waiting for nodes to be ready..."
    sleep 5

    local max_attempts=30
    for attempt in $(seq 1 "${max_attempts}"); do
        if docker exec "${NODE_PREFIX}1" cockroach init --insecure --host="${NODE_PREFIX}1:26257" 2>/dev/null; then
            log_info "Cluster initialized successfully."
            return 0
        fi
        # Cluster may already be initialized
        if docker exec "${NODE_PREFIX}1" cockroach sql --insecure \
            --host="${NODE_PREFIX}1:26257" \
            -e "SELECT 1;" &>/dev/null; then
            log_info "Cluster is already initialized."
            return 0
        fi
        log_warn "Waiting for cluster to be ready... (attempt ${attempt}/${max_attempts})"
        sleep 2
    done

    log_error "Cluster failed to initialize after ${max_attempts} attempts."
    exit 1
}

create_database() {
    log_info "Creating database: ${DATABASE_NAME}"
    docker exec "${NODE_PREFIX}1" cockroach sql --insecure \
        --host="${NODE_PREFIX}1:26257" \
        -e "CREATE DATABASE IF NOT EXISTS ${DATABASE_NAME};"
    log_info "Database '${DATABASE_NAME}' created."
}

verify_cluster() {
    log_info "Verifying cluster health..."

    echo ""
    echo "=== Node Status ==="
    docker exec "${NODE_PREFIX}1" cockroach node status --insecure \
        --host="${NODE_PREFIX}1:26257"

    echo ""
    echo "=== Databases ==="
    docker exec "${NODE_PREFIX}1" cockroach sql --insecure \
        --host="${NODE_PREFIX}1:26257" \
        -e "SHOW DATABASES;"

    echo ""
    echo "=== Cluster Version ==="
    docker exec "${NODE_PREFIX}1" cockroach sql --insecure \
        --host="${NODE_PREFIX}1:26257" \
        -e "SELECT crdb_internal.node_executable_version();"

    echo ""
    log_info "Cluster is ready!"
    echo ""
    echo "Connection details:"
    echo "  SQL (node 1): postgresql://root@localhost:26257/${DATABASE_NAME}?sslmode=disable"
    echo "  SQL (node 2): postgresql://root@localhost:26258/${DATABASE_NAME}?sslmode=disable"
    echo "  SQL (node 3): postgresql://root@localhost:26259/${DATABASE_NAME}?sslmode=disable"
    echo "  DB Console:   http://localhost:8080"
    echo ""
    echo "Connect with: cockroach sql --insecure --host=localhost:26257 --database=${DATABASE_NAME}"
    echo ""
    echo "To stop the cluster:"
    echo "  docker rm -f ${NODE_PREFIX}1 ${NODE_PREFIX}2 ${NODE_PREFIX}3"
    echo "  docker network rm ${NETWORK_NAME}"
}

main() {
    echo "============================================"
    echo " CockroachDB 3-Node Cluster Setup (Docker)"
    echo "============================================"
    echo ""

    check_docker
    cleanup
    create_network
    start_nodes
    init_cluster
    create_database
    verify_cluster
}

main
