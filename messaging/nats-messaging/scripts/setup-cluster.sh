#!/usr/bin/env bash
###############################################################################
# setup-cluster.sh — Deploy a 3-node NATS cluster with JetStream
#
# Usage:
#   ./setup-cluster.sh [OPTIONS]
#
# Options:
#   --docker           Deploy using Docker Compose (default)
#   --bare-metal       Deploy using local nats-server binaries
#   --nodes N          Number of nodes (default: 3, must be odd)
#   --image IMAGE      Docker image (default: nats:2-alpine)
#   --data-dir DIR     Data directory (default: ./nats-cluster-data)
#   --base-port PORT   Starting client port (default: 4222)
#   --clean            Tear down cluster and remove data
#   --help             Show this help message
#
# Examples:
#   ./setup-cluster.sh                         # 3-node Docker cluster
#   ./setup-cluster.sh --nodes 5               # 5-node Docker cluster
#   ./setup-cluster.sh --bare-metal             # Local binary cluster
#   ./setup-cluster.sh --clean                  # Tear down
#
# Port mappings (3-node default):
#   Node    Client   Monitor   Cluster
#   nats-1  4222     8222      6222
#   nats-2  4223     8223      6223
#   nats-3  4224     8224      6224
###############################################################################
set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
MODE="docker"
NUM_NODES=3
NATS_IMAGE="nats:2-alpine"
DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nats-cluster-data"
BASE_CLIENT_PORT=4222
BASE_MONITOR_PORT=8222
BASE_CLUSTER_PORT=6222
CLUSTER_NAME="nats-cluster"
HEALTH_TIMEOUT=60
HEALTH_INTERVAL=2

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*" >&2; }

# ─── Parse arguments ────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --docker)      MODE="docker";       shift ;;
            --bare-metal)  MODE="bare-metal";   shift ;;
            --nodes)       NUM_NODES="$2";       shift 2 ;;
            --image)       NATS_IMAGE="$2";      shift 2 ;;
            --data-dir)    DATA_DIR="$2";        shift 2 ;;
            --base-port)   BASE_CLIENT_PORT="$2"; shift 2 ;;
            --clean)       clean; exit 0 ;;
            --help|-h)     sed -n '2,/^###*$/{ s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
            *)             err "Unknown option: $1"; exit 1 ;;
        esac
    done

    if (( NUM_NODES % 2 == 0 )); then
        err "Node count must be odd (got $NUM_NODES). Use 3 or 5."
        exit 1
    fi
}

# ─── Check prerequisites ────────────────────────────────────────────────────
check_docker() {
    command -v docker &>/dev/null || { err "Docker not found"; exit 2; }
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        err "Docker Compose not available"; exit 2
    fi
    ok "Docker and Compose available"
}

check_bare_metal() {
    command -v nats-server &>/dev/null || {
        err "nats-server not found in PATH"
        err "Install: https://github.com/nats-io/nats-server/releases"
        exit 2
    }
    ok "nats-server $(nats-server --version 2>&1 | head -1) found"
}

# ─── Generate NATS config for a single node ─────────────────────────────────
generate_config() {
    local node_id="$1"
    local cfg_dir="${DATA_DIR}/config"
    mkdir -p "$cfg_dir"

    # Build route list
    local routes=""
    for i in $(seq 1 "$NUM_NODES"); do
        if [[ "$MODE" == "docker" ]]; then
            routes+="        nats-route://nats-${i}:6222"$'\n'
        else
            local cport=$((BASE_CLUSTER_PORT + i - 1))
            routes+="        nats-route://127.0.0.1:${cport}"$'\n'
        fi
    done

    local listen_port=4222
    local monitor_port=8222
    local cluster_port=6222

    if [[ "$MODE" == "bare-metal" ]]; then
        listen_port=$((BASE_CLIENT_PORT + node_id - 1))
        monitor_port=$((BASE_MONITOR_PORT + node_id - 1))
        cluster_port=$((BASE_CLUSTER_PORT + node_id - 1))
    fi

    cat > "${cfg_dir}/nats-${node_id}.conf" <<NODECONF
server_name: nats-${node_id}
listen: 0.0.0.0:${listen_port}

jetstream {
    store_dir: /data/jetstream
    max_mem:   256MB
    max_file:  1GB
}

http_port: ${monitor_port}

cluster {
    name: ${CLUSTER_NAME}
    listen: 0.0.0.0:${cluster_port}
    routes = [
${routes}    ]
    connect_retries: 30
}

max_payload: 8MB
max_connections: 1024
ping_interval: 20
ping_max: 3
write_deadline: "10s"
NODECONF

    ok "Config generated: nats-${node_id}"
}

# ─── Generate docker-compose.yml ────────────────────────────────────────────
generate_compose() {
    info "Generating docker-compose.yml..."
    local compose="${DATA_DIR}/docker-compose.yml"

    cat > "$compose" <<'HEADER'
# Auto-generated NATS cluster — do not edit manually
version: "3.9"

services:
HEADER

    for i in $(seq 1 "$NUM_NODES"); do
        local client_port=$((BASE_CLIENT_PORT + i - 1))
        local monitor_port=$((BASE_MONITOR_PORT + i - 1))
        local cluster_port=$((BASE_CLUSTER_PORT + i - 1))

        cat >> "$compose" <<SVCEOF
  nats-${i}:
    image: ${NATS_IMAGE}
    container_name: nats-${i}
    hostname: nats-${i}
    command: ["-c", "/config/nats-${i}.conf"]
    ports:
      - "${client_port}:4222"
      - "${monitor_port}:8222"
      - "${cluster_port}:6222"
    volumes:
      - ./config/nats-${i}.conf:/config/nats-${i}.conf:ro
      - nats-${i}-data:/data
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8222/healthz"]
      interval: 5s
      timeout: 3s
      retries: 12
    networks:
      - nats-net
    restart: unless-stopped

SVCEOF
    done

    echo "volumes:" >> "$compose"
    for i in $(seq 1 "$NUM_NODES"); do
        echo "  nats-${i}-data:" >> "$compose"
    done

    cat >> "$compose" <<'NETEOF'

networks:
  nats-net:
    driver: bridge
NETEOF

    ok "docker-compose.yml generated"
}

# ─── Wait for health ────────────────────────────────────────────────────────
wait_for_healthy() {
    info "Waiting for cluster health (up to ${HEALTH_TIMEOUT}s)..."
    local elapsed=0

    while (( elapsed < HEALTH_TIMEOUT )); do
        local all_ok=true
        for i in $(seq 1 "$NUM_NODES"); do
            local port=$((BASE_MONITOR_PORT + i - 1))
            if ! curl -sf "http://localhost:${port}/healthz" &>/dev/null; then
                all_ok=false
                break
            fi
        done

        if $all_ok; then
            ok "All ${NUM_NODES} nodes healthy (${elapsed}s)"
            return 0
        fi

        sleep "$HEALTH_INTERVAL"
        (( elapsed += HEALTH_INTERVAL ))
    done

    err "Cluster not healthy within ${HEALTH_TIMEOUT}s"
    return 1
}

# ─── Print status ───────────────────────────────────────────────────────────
print_status() {
    echo ""
    printf "${BOLD}${CYAN}NATS ${NUM_NODES}-Node Cluster Ready${NC}\n"
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "  %-8s  %-18s  %-18s  %-10s\n" "Node" "Client" "Monitor" "Cluster"
    for i in $(seq 1 "$NUM_NODES"); do
        local cp=$((BASE_CLIENT_PORT + i - 1))
        local mp=$((BASE_MONITOR_PORT + i - 1))
        local rp=$((BASE_CLUSTER_PORT + i - 1))
        printf "  %-8s  localhost:%-9s  localhost:%-9s  :%-8s\n" \
            "nats-${i}" "$cp" "$mp" "$rp"
    done
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "  Connect:  nats://localhost:${BASE_CLIENT_PORT}\n"
    printf "  Monitor:  http://localhost:${BASE_MONITOR_PORT}\n"
    echo ""

    if command -v nats &>/dev/null; then
        nats server report jetstream --server "nats://localhost:${BASE_CLIENT_PORT}" 2>/dev/null || true
    fi
}

# ─── Deploy with Docker ─────────────────────────────────────────────────────
deploy_docker() {
    check_docker
    for i in $(seq 1 "$NUM_NODES"); do generate_config "$i"; done
    generate_compose
    info "Starting ${NUM_NODES}-node cluster..."
    $COMPOSE_CMD -f "${DATA_DIR}/docker-compose.yml" up -d --force-recreate
    wait_for_healthy
    print_status
}

# ─── Deploy bare-metal ──────────────────────────────────────────────────────
deploy_bare_metal() {
    check_bare_metal
    for i in $(seq 1 "$NUM_NODES"); do
        generate_config "$i"
        local data_dir="${DATA_DIR}/node-${i}"
        mkdir -p "$data_dir"

        # Update store_dir in config for bare-metal
        sed -i "s|store_dir: /data/jetstream|store_dir: ${data_dir}/jetstream|" \
            "${DATA_DIR}/config/nats-${i}.conf"

        info "Starting nats-${i}..."
        nats-server -c "${DATA_DIR}/config/nats-${i}.conf" \
            -sd "${data_dir}" \
            -P "${data_dir}/nats.pid" &
        ok "nats-${i} started (PID: $!)"
    done

    wait_for_healthy
    print_status

    echo ""
    info "PID files in ${DATA_DIR}/node-*/nats.pid"
    info "Stop with: ./setup-cluster.sh --clean"
}

# ─── Clean up ────────────────────────────────────────────────────────────────
clean() {
    info "Tearing down cluster..."

    # Docker cleanup
    if [[ -f "${DATA_DIR}/docker-compose.yml" ]]; then
        if docker compose version &>/dev/null; then
            docker compose -f "${DATA_DIR}/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
        elif command -v docker-compose &>/dev/null; then
            docker-compose -f "${DATA_DIR}/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
        fi
    fi

    # Bare-metal cleanup: stop processes via PID files
    for pidfile in "${DATA_DIR}"/node-*/nats.pid; do
        [[ -f "$pidfile" ]] || continue
        local pid
        pid=$(<"$pidfile")
        if [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            ok "Stopped PID $pid"
        fi
    done

    [[ -d "$DATA_DIR" ]] && rm -rf "$DATA_DIR"
    ok "Cluster data removed"
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    info "Deploying ${NUM_NODES}-node NATS cluster (mode: ${MODE})"

    case "$MODE" in
        docker)     deploy_docker ;;
        bare-metal) deploy_bare_metal ;;
    esac
}

main "$@"
