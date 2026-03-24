#!/usr/bin/env bash
# Setup a local Ray cluster: install Ray, start head node, add workers, verify.
# Usage: ./setup-ray-cluster.sh [--workers N] [--head-cpus N] [--worker-cpus N]
#
# Examples:
#   ./setup-ray-cluster.sh                      # 2 workers, default resources
#   ./setup-ray-cluster.sh --workers 4          # 4 workers
#   ./setup-ray-cluster.sh --head-cpus 0        # No compute on head (production pattern)

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
NUM_WORKERS=2
HEAD_CPUS=""
WORKER_CPUS=""
RAY_VERSION="2.9.0"
HEAD_PORT=6379
DASHBOARD_PORT=8265
OBJECT_STORE_MEMORY=""

# ─── Parse arguments ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workers)       NUM_WORKERS="$2";          shift 2 ;;
        --head-cpus)     HEAD_CPUS="$2";            shift 2 ;;
        --worker-cpus)   WORKER_CPUS="$2";          shift 2 ;;
        --ray-version)   RAY_VERSION="$2";          shift 2 ;;
        --head-port)     HEAD_PORT="$2";            shift 2 ;;
        --dashboard-port) DASHBOARD_PORT="$2";      shift 2 ;;
        --object-store-memory) OBJECT_STORE_MEMORY="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--workers N] [--head-cpus N] [--worker-cpus N]"
            echo "       [--ray-version VER] [--head-port PORT] [--dashboard-port PORT]"
            echo "       [--object-store-memory BYTES]"
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

# ─── Step 1: Check / Install Ray ────────────────────────────────────────────
info "Checking Ray installation..."
if python3 -c "import ray; print(ray.__version__)" 2>/dev/null; then
    INSTALLED_VERSION=$(python3 -c "import ray; print(ray.__version__)")
    ok "Ray ${INSTALLED_VERSION} is already installed"
else
    info "Installing Ray ${RAY_VERSION}..."
    pip install "ray[default]==${RAY_VERSION}" --quiet
    ok "Ray ${RAY_VERSION} installed"
fi

# ─── Step 2: Stop any existing cluster ───────────────────────────────────────
info "Stopping any existing Ray cluster..."
ray stop --force 2>/dev/null || true
sleep 2
ok "Existing cluster stopped"

# ─── Step 3: Start head node ────────────────────────────────────────────────
info "Starting Ray head node on port ${HEAD_PORT}..."

HEAD_CMD="ray start --head --port=${HEAD_PORT} --dashboard-host=0.0.0.0 --dashboard-port=${DASHBOARD_PORT}"

if [[ -n "${HEAD_CPUS}" ]]; then
    HEAD_CMD="${HEAD_CMD} --num-cpus=${HEAD_CPUS}"
fi

if [[ -n "${OBJECT_STORE_MEMORY}" ]]; then
    HEAD_CMD="${HEAD_CMD} --object-store-memory=${OBJECT_STORE_MEMORY}"
fi

eval "${HEAD_CMD}"
sleep 3

HEAD_ADDRESS="127.0.0.1:${HEAD_PORT}"
ok "Head node started at ${HEAD_ADDRESS}"

# ─── Step 4: Start worker nodes ─────────────────────────────────────────────
if [[ "${NUM_WORKERS}" -gt 0 ]]; then
    info "Starting ${NUM_WORKERS} worker node(s)..."

    for i in $(seq 1 "${NUM_WORKERS}"); do
        WORKER_CMD="ray start --address=${HEAD_ADDRESS}"
        if [[ -n "${WORKER_CPUS}" ]]; then
            WORKER_CMD="${WORKER_CMD} --num-cpus=${WORKER_CPUS}"
        fi
        eval "${WORKER_CMD}"
        ok "Worker ${i}/${NUM_WORKERS} started"
    done
else
    info "Skipping workers (single-node cluster)"
fi

sleep 3

# ─── Step 5: Verify cluster ─────────────────────────────────────────────────
info "Verifying cluster status..."
echo ""
ray status
echo ""

# Quick health check with Python
python3 -c "
import ray
ray.init(address='auto', ignore_reinit_error=True)
nodes = ray.nodes()
alive = [n for n in nodes if n['Alive']]
resources = ray.cluster_resources()
print()
print(f'Cluster verified:')
print(f'  Nodes alive:   {len(alive)}')
print(f'  Total CPUs:    {resources.get(\"CPU\", 0):.0f}')
print(f'  Total GPUs:    {resources.get(\"GPU\", 0):.0f}')
print(f'  Object store:  {resources.get(\"object_store_memory\", 0) / 1e9:.1f} GB')
print(f'  Dashboard:     http://127.0.0.1:${DASHBOARD_PORT}')
print()
ray.shutdown()
"

ok "Ray cluster is healthy and ready"
echo ""
info "To connect from Python:"
echo "    import ray"
echo "    ray.init(address='auto')"
echo ""
info "To stop the cluster:"
echo "    ray stop"
