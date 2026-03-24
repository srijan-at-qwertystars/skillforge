#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Redis Cluster Bootstrap Script
# =============================================================================
# Sets up a Redis Cluster for local development or production environments.
#
# Usage:
#   ./setup-cluster.sh [OPTIONS]
#
# Modes:
#   --mode docker       Run each node as a Docker container (default)
#   --mode bare-metal   Run each node as a local redis-server process
#
# Options:
#   --masters N         Number of master nodes          (default: 3)
#   --replicas N        Replicas per master              (default: 1)
#   --port N            Starting port number             (default: 7000)
#   --bind ADDR         Bind address for nodes           (default: 127.0.0.1)
#   --production        Enable production hardening: AUTH password, conservative
#                       timeouts, maxmemory policy, and protected-mode
#   --password PASS     Redis AUTH password (auto-generated in --production if
#                       not supplied)
#   --cleanup           Tear down a previously created cluster and exit
#   --data-dir DIR      Base directory for node data     (default: ./redis-data)
#   -h, --help          Show this help message
#
# Examples:
#   ./setup-cluster.sh --mode docker --masters 3 --replicas 1
#   ./setup-cluster.sh --mode bare-metal --port 7100 --production
#   ./setup-cluster.sh --cleanup --mode docker
# =============================================================================

# --------------- defaults ---------------
MODE="docker"
MASTERS=3
REPLICAS=1
START_PORT=7000
BIND_ADDR="127.0.0.1"
PRODUCTION=false
PASSWORD=""
CLEANUP=false
DATA_DIR="./redis-data"
DOCKER_NET="redis-cluster-net"
CONTAINER_PREFIX="redis-node"
REDIS_IMAGE="redis:7-alpine"

# --------------- colors ---------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()     { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
header()  { printf "\n${CYAN}=== %s ===${NC}\n" "$*"; }

# --------------- arg parsing ---------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)        MODE="$2";       shift 2 ;;
        --masters)     MASTERS="$2";    shift 2 ;;
        --replicas)    REPLICAS="$2";   shift 2 ;;
        --port)        START_PORT="$2"; shift 2 ;;
        --bind)        BIND_ADDR="$2";  shift 2 ;;
        --production)  PRODUCTION=true; shift ;;
        --password)    PASSWORD="$2";   shift 2 ;;
        --cleanup)     CLEANUP=true;    shift ;;
        --data-dir)    DATA_DIR="$2";   shift 2 ;;
        -h|--help)     head -35 "$0" | tail -33; exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

TOTAL_NODES=$(( MASTERS * (1 + REPLICAS) ))

# --------------- prerequisite checks ---------------
check_prerequisites() {
    local missing=0
    if ! command -v redis-cli &>/dev/null; then
        err "redis-cli not found. Install Redis tools first."
        missing=1
    fi
    if [[ "$MODE" == "docker" ]] && ! command -v docker &>/dev/null; then
        err "docker not found. Install Docker or use --mode bare-metal."
        missing=1
    fi
    if [[ "$MODE" == "bare-metal" ]] && ! command -v redis-server &>/dev/null; then
        err "redis-server not found. Install Redis server."
        missing=1
    fi
    if [[ "$MODE" != "docker" && "$MODE" != "bare-metal" ]]; then
        err "Invalid mode '$MODE'. Use 'docker' or 'bare-metal'."
        missing=1
    fi
    (( missing )) && exit 1
}

# --------------- cleanup ---------------
do_cleanup() {
    header "Cleaning up Redis Cluster"
    if [[ "$MODE" == "docker" ]]; then
        for i in $(seq 0 $(( TOTAL_NODES - 1 ))); do
            local name="${CONTAINER_PREFIX}-$((START_PORT + i))"
            if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
                docker rm -f "$name" &>/dev/null && info "Removed container $name"
            fi
        done
        if docker network ls --format '{{.Name}}' | grep -qx "$DOCKER_NET"; then
            docker network rm "$DOCKER_NET" &>/dev/null && info "Removed network $DOCKER_NET"
        fi
    else
        for i in $(seq 0 $(( TOTAL_NODES - 1 ))); do
            local port=$((START_PORT + i))
            local pidfile="${DATA_DIR}/${port}/redis.pid"
            if [[ -f "$pidfile" ]]; then
                local pid
                pid=$(<"$pidfile")
                if kill -0 "$pid" 2>/dev/null; then
                    kill "$pid" && info "Stopped redis-server on port $port (pid $pid)"
                fi
            fi
        done
    fi
    if [[ -d "$DATA_DIR" ]]; then
        rm -rf "$DATA_DIR" && info "Removed data directory $DATA_DIR"
    fi
    info "Cleanup complete."
}

if $CLEANUP; then
    check_prerequisites
    do_cleanup
    exit 0
fi

# --------------- production defaults ---------------
if $PRODUCTION && [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)
    warn "Generated AUTH password: $PASSWORD"
fi

# --------------- config generation ---------------
generate_node_conf() {
    local port=$1 dir=$2
    mkdir -p "$dir"

    cat > "$dir/redis.conf" <<EOF
port ${port}
bind ${BIND_ADDR}
daemonize yes
pidfile ${dir}/redis.pid
logfile ${dir}/redis.log
dir ${dir}

# Cluster
cluster-enabled yes
cluster-config-file nodes-${port}.conf
cluster-node-timeout 5000

# Persistence
appendonly yes
appendfilename "appendonly-${port}.aof"
save 900 1
save 300 10
EOF

    if $PRODUCTION; then
        cat >> "$dir/redis.conf" <<EOF

# Production hardening
requirepass ${PASSWORD}
masterauth ${PASSWORD}
maxmemory 256mb
maxmemory-policy allkeys-lru
protected-mode yes
tcp-backlog 511
timeout 300
tcp-keepalive 60
cluster-node-timeout 15000
EOF
    else
        echo "protected-mode no" >> "$dir/redis.conf"
    fi
}

# --------------- wait for nodes ---------------
wait_for_nodes() {
    local auth_args=()
    if [[ -n "$PASSWORD" ]]; then
        auth_args=(-a "$PASSWORD" --no-auth-warning)
    fi

    info "Waiting for $TOTAL_NODES nodes to become ready..."
    for i in $(seq 0 $(( TOTAL_NODES - 1 ))); do
        local port=$((START_PORT + i))
        local retries=30
        while (( retries > 0 )); do
            if redis-cli -h "$BIND_ADDR" -p "$port" "${auth_args[@]}" PING 2>/dev/null | grep -qi pong; then
                break
            fi
            sleep 1
            (( retries-- ))
        done
        if (( retries == 0 )); then
            err "Node on port $port failed to start within 30 seconds."
            exit 1
        fi
    done
    info "All $TOTAL_NODES nodes are responding."
}

# --------------- Docker mode ---------------
start_docker_cluster() {
    header "Starting Redis Cluster (Docker mode)"

    if ! docker network ls --format '{{.Name}}' | grep -qx "$DOCKER_NET"; then
        docker network create "$DOCKER_NET" >/dev/null
        info "Created Docker network: $DOCKER_NET"
    fi

    local cluster_hosts=()
    for i in $(seq 0 $(( TOTAL_NODES - 1 ))); do
        local port=$((START_PORT + i))
        local name="${CONTAINER_PREFIX}-${port}"

        local cmd="redis-server --port $port --cluster-enabled yes \
            --cluster-config-file nodes.conf --cluster-node-timeout 5000 \
            --appendonly yes --bind 0.0.0.0 --protected-mode no"
        if $PRODUCTION; then
            cmd="$cmd --requirepass $PASSWORD --masterauth $PASSWORD \
                --maxmemory 256mb --maxmemory-policy allkeys-lru \
                --tcp-keepalive 60 --timeout 300 --cluster-node-timeout 15000"
        fi

        docker run -d --name "$name" --net "$DOCKER_NET" \
            -p "${port}:${port}" "$REDIS_IMAGE" $cmd >/dev/null
        info "Started container $name on port $port"

        cluster_hosts+=("${BIND_ADDR}:${port}")
    done

    CLUSTER_HOSTS=("${cluster_hosts[@]}")
}

# --------------- Bare-metal mode ---------------
start_bare_metal_cluster() {
    header "Starting Redis Cluster (bare-metal mode)"
    mkdir -p "$DATA_DIR"

    local cluster_hosts=()
    for i in $(seq 0 $(( TOTAL_NODES - 1 ))); do
        local port=$((START_PORT + i))
        local node_dir
        node_dir="$(cd "$DATA_DIR" && pwd)/${port}"
        generate_node_conf "$port" "$node_dir"

        redis-server "$node_dir/redis.conf"
        info "Started redis-server on port $port (data: $node_dir)"
        cluster_hosts+=("${BIND_ADDR}:${port}")
    done

    CLUSTER_HOSTS=("${cluster_hosts[@]}")
}

# --------------- create the cluster ---------------
create_cluster() {
    header "Creating cluster topology (${MASTERS}m × ${REPLICAS}r)"

    local auth_args=()
    if [[ -n "$PASSWORD" ]]; then
        auth_args=(-a "$PASSWORD" --no-auth-warning)
    fi

    redis-cli "${auth_args[@]}" --cluster create "${CLUSTER_HOSTS[@]}" \
        --cluster-replicas "$REPLICAS" --cluster-yes

    info "Cluster created successfully."
}

# --------------- summary ---------------
print_summary() {
    header "Cluster Summary"

    local auth_args=()
    if [[ -n "$PASSWORD" ]]; then
        auth_args=(-a "$PASSWORD" --no-auth-warning)
    fi

    redis-cli -h "$BIND_ADDR" -p "$START_PORT" "${auth_args[@]}" CLUSTER INFO 2>/dev/null \
        | head -5

    echo ""
    info "Nodes: $TOTAL_NODES  |  Masters: $MASTERS  |  Replicas per master: $REPLICAS"
    info "Ports: ${START_PORT}–$((START_PORT + TOTAL_NODES - 1))  |  Mode: $MODE"
    if $PRODUCTION; then
        info "Production mode enabled. AUTH password: $PASSWORD"
    fi
    info "To tear down:  $0 --mode $MODE --cleanup"
}

# --------------- main ---------------
main() {
    check_prerequisites

    header "Redis Cluster Setup"
    info "Mode: $MODE | Masters: $MASTERS | Replicas/master: $REPLICAS | Ports: ${START_PORT}–$((START_PORT + TOTAL_NODES - 1))"

    case "$MODE" in
        docker)     start_docker_cluster ;;
        bare-metal) start_bare_metal_cluster ;;
    esac

    wait_for_nodes
    create_cluster
    print_summary
}

main
