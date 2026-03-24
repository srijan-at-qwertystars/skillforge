#!/usr/bin/env bash
# setup-cluster.sh — Set up a local Redis/Valkey cluster for development
#
# Usage:
#   ./setup-cluster.sh [--valkey|--redis] [--port-base PORT] [--dir DIR]
#
# Creates a 6-node cluster (3 masters + 3 replicas) on localhost.
# Default ports: 7000-7005. Data stored in ./cluster-data/ by default.
#
# Requirements: redis-server/valkey-server and redis-cli/valkey-cli in PATH
#
# Examples:
#   ./setup-cluster.sh                     # auto-detect, default ports
#   ./setup-cluster.sh --valkey            # force Valkey
#   ./setup-cluster.sh --port-base 8000    # use ports 8000-8005
#   ./setup-cluster.sh --dir /tmp/cluster  # custom data directory

set -euo pipefail

# --- Defaults ---
PORT_BASE=7000
NUM_MASTERS=3
NUM_REPLICAS=3
TOTAL_NODES=$((NUM_MASTERS + NUM_REPLICAS))
DATA_DIR="./cluster-data"
FORCE_ENGINE=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --valkey)   FORCE_ENGINE="valkey"; shift ;;
    --redis)    FORCE_ENGINE="redis"; shift ;;
    --port-base) PORT_BASE="$2"; shift 2 ;;
    --dir)      DATA_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/s/^# //p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Detect engine ---
detect_engine() {
  if [[ -n "$FORCE_ENGINE" ]]; then
    echo "$FORCE_ENGINE"
    return
  fi
  if command -v valkey-server &>/dev/null; then
    echo "valkey"
  elif command -v redis-server &>/dev/null; then
    echo "redis"
  else
    echo "ERROR: Neither valkey-server nor redis-server found in PATH" >&2
    exit 1
  fi
}

ENGINE=$(detect_engine)
SERVER_BIN="${ENGINE}-server"
CLI_BIN="${ENGINE}-cli"

echo "=== ${ENGINE^} Cluster Setup ==="
echo "Engine:    $SERVER_BIN ($(${SERVER_BIN} --version 2>/dev/null | head -1))"
echo "Nodes:     $TOTAL_NODES ($NUM_MASTERS masters + $NUM_REPLICAS replicas)"
echo "Ports:     $PORT_BASE - $((PORT_BASE + TOTAL_NODES - 1))"
echo "Data dir:  $DATA_DIR"
echo ""

# --- Check for existing cluster ---
for i in $(seq 0 $((TOTAL_NODES - 1))); do
  port=$((PORT_BASE + i))
  if lsof -i :"$port" &>/dev/null 2>&1 || ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    echo "ERROR: Port $port is already in use. Stop existing instances first." >&2
    echo "  Hint: ./setup-cluster.sh uses ports $PORT_BASE-$((PORT_BASE + TOTAL_NODES - 1))" >&2
    exit 1
  fi
done

# --- Create directories ---
mkdir -p "$DATA_DIR"
PIDS=()

cleanup() {
  echo ""
  echo "Shutting down cluster nodes..."
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  echo "Cluster stopped."
}
trap cleanup EXIT INT TERM

# --- Start nodes ---
echo "Starting $TOTAL_NODES nodes..."
for i in $(seq 0 $((TOTAL_NODES - 1))); do
  port=$((PORT_BASE + i))
  node_dir="$DATA_DIR/node-$port"
  mkdir -p "$node_dir"

  cat > "$node_dir/cluster-node.conf" <<EOF
port $port
bind 127.0.0.1
cluster-enabled yes
cluster-config-file nodes-$port.conf
cluster-node-timeout 5000
appendonly yes
appendfilename "appendonly-$port.aof"
dbfilename "dump-$port.rdb"
dir $node_dir
loglevel notice
logfile "$node_dir/server.log"
daemonize no
protected-mode no
save ""
EOF

  $SERVER_BIN "$node_dir/cluster-node.conf" &
  PIDS+=($!)
  echo "  Node $port started (PID ${PIDS[-1]})"
done

# --- Wait for nodes to be ready ---
echo ""
echo "Waiting for nodes to accept connections..."
for i in $(seq 0 $((TOTAL_NODES - 1))); do
  port=$((PORT_BASE + i))
  retries=30
  while ! $CLI_BIN -p "$port" PING &>/dev/null; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      echo "ERROR: Node on port $port failed to start. Check $DATA_DIR/node-$port/server.log" >&2
      exit 1
    fi
    sleep 0.2
  done
done
echo "All nodes responding to PING."

# --- Create cluster ---
echo ""
echo "Creating cluster with $NUM_MASTERS masters and $NUM_REPLICAS replicas..."
NODES=""
for i in $(seq 0 $((TOTAL_NODES - 1))); do
  port=$((PORT_BASE + i))
  NODES="$NODES 127.0.0.1:$port"
done

$CLI_BIN --cluster create $NODES \
  --cluster-replicas $((NUM_REPLICAS / NUM_MASTERS)) \
  --cluster-yes

echo ""
echo "=== Cluster Ready ==="
echo ""
echo "Connect to any node:"
echo "  $CLI_BIN -c -p $PORT_BASE"
echo ""
echo "Check cluster status:"
echo "  $CLI_BIN -c -p $PORT_BASE CLUSTER INFO"
echo "  $CLI_BIN -c -p $PORT_BASE CLUSTER NODES"
echo ""
echo "Test with:"
echo "  $CLI_BIN -c -p $PORT_BASE SET hello world"
echo "  $CLI_BIN -c -p $PORT_BASE GET hello"
echo ""
echo "Press Ctrl+C to stop the cluster."

# Keep running until interrupted
wait
