#!/usr/bin/env bash
#
# init-swarm.sh — Initialize a Docker Swarm cluster
#
# Usage:
#   ./init-swarm.sh --advertise-addr <IP> [OPTIONS]
#
# Options:
#   --advertise-addr <IP>   Manager advertise address (required)
#   --workers <IP,IP,...>   Comma-separated worker IPs to join via SSH
#   --autolock               Enable autolock (require unlock key on restart)
#   --overlay-network <NAME> Create an overlay network after init (default: app-net)
#   --cert-expiry <DURATION> Certificate expiry duration (default: 720h)
#   --drain-manager          Set manager availability to drain (no app workloads)
#   --help                   Show this help message
#
set -euo pipefail

# --- Defaults ---
ADVERTISE_ADDR=""
WORKERS=""
AUTOLOCK=false
OVERLAY_NETWORK="app-net"
CERT_EXPIRY="720h"
DRAIN_MANAGER=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --advertise-addr) ADVERTISE_ADDR="$2"; shift 2 ;;
        --workers)        WORKERS="$2"; shift 2 ;;
        --autolock)       AUTOLOCK=true; shift ;;
        --overlay-network) OVERLAY_NETWORK="$2"; shift 2 ;;
        --cert-expiry)    CERT_EXPIRY="$2"; shift 2 ;;
        --drain-manager)  DRAIN_MANAGER=true; shift ;;
        --help|-h)        usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# --- Validation ---
if [[ -z "$ADVERTISE_ADDR" ]]; then
    log_error "--advertise-addr is required"
    usage
fi

if ! command -v docker &>/dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

# Check if already in a swarm
if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
    log_warn "This node is already part of a swarm"
    docker node ls
    exit 0
fi

# --- Initialize Swarm ---
log_info "Initializing Docker Swarm with advertise address: ${ADVERTISE_ADDR}"
docker swarm init --advertise-addr "${ADVERTISE_ADDR}" --cert-expiry "${CERT_EXPIRY}"

if [[ $? -ne 0 ]]; then
    log_error "Swarm initialization failed"
    exit 1
fi

log_info "Swarm initialized successfully"

# --- Enable autolock ---
if [[ "$AUTOLOCK" == true ]]; then
    log_info "Enabling autolock..."
    UNLOCK_KEY=$(docker swarm update --autolock=true 2>&1)
    log_warn "SAVE THIS UNLOCK KEY SECURELY:"
    echo "$UNLOCK_KEY"
    echo ""
    log_warn "Without this key, manager data cannot be accessed after a Docker restart."
fi

# --- Drain manager (prevent app scheduling on manager) ---
if [[ "$DRAIN_MANAGER" == true ]]; then
    MANAGER_NODE_ID=$(docker node ls --filter "role=manager" -q | head -1)
    log_info "Setting manager node to drain mode (no application workloads)"
    docker node update --availability drain "${MANAGER_NODE_ID}"
fi

# --- Create overlay network ---
if [[ -n "$OVERLAY_NETWORK" ]]; then
    log_info "Creating overlay network: ${OVERLAY_NETWORK}"
    docker network create --driver overlay --attachable "${OVERLAY_NETWORK}" 2>/dev/null || \
        log_warn "Network '${OVERLAY_NETWORK}' already exists"
fi

# --- Retrieve join tokens ---
WORKER_TOKEN=$(docker swarm join-token worker -q)
MANAGER_TOKEN=$(docker swarm join-token manager -q)

echo ""
log_info "=== Join Tokens ==="
echo "Worker token:  ${WORKER_TOKEN}"
echo "Manager token: ${MANAGER_TOKEN}"
echo ""
echo "To join a worker:   docker swarm join --token ${WORKER_TOKEN} ${ADVERTISE_ADDR}:2377"
echo "To join a manager:  docker swarm join --token ${MANAGER_TOKEN} ${ADVERTISE_ADDR}:2377"

# --- Join workers via SSH ---
if [[ -n "$WORKERS" ]]; then
    IFS=',' read -ra WORKER_NODES <<< "$WORKERS"
    for worker_ip in "${WORKER_NODES[@]}"; do
        worker_ip=$(echo "$worker_ip" | xargs)  # trim whitespace
        log_info "Joining worker node: ${worker_ip}"
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            "root@${worker_ip}" \
            "docker swarm join --token ${WORKER_TOKEN} ${ADVERTISE_ADDR}:2377" 2>/dev/null; then
            log_info "Worker ${worker_ip} joined successfully"
        else
            log_warn "Failed to join worker ${worker_ip} — join manually with:"
            echo "  ssh root@${worker_ip} 'docker swarm join --token ${WORKER_TOKEN} ${ADVERTISE_ADDR}:2377'"
        fi
    done
fi

# --- Summary ---
echo ""
log_info "=== Cluster Summary ==="
docker node ls
echo ""
log_info "=== Networks ==="
docker network ls --filter driver=overlay
echo ""
log_info "Swarm cluster initialization complete"
