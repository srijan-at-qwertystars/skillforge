#!/usr/bin/env bash
# redis-benchmark.sh — Run redis-benchmark with common patterns and report results
#
# Usage:
#   ./redis-benchmark.sh [host:port] [test-type] [password]
#
# Test types:
#   quick       (default) Fast subset: SET, GET, INCR, LPUSH, LPOP (10K requests)
#   standard    Standard benchmark: all default commands (100K requests)
#   pipeline    Pipeline benchmark: batch sizes 1, 10, 50, 100
#   throughput  Throughput test: increasing clients (1, 10, 50, 100, 200)
#   latency     Latency-focused: single client, measure p50/p99
#   data-sizes  Test with various value sizes (64B, 256B, 1KB, 4KB, 16KB)
#   all         Run all test types
#
# Examples:
#   ./redis-benchmark.sh                              # localhost:6379, quick test
#   ./redis-benchmark.sh 10.0.0.5:6379 standard
#   ./redis-benchmark.sh redis.host:6379 all secret

set -euo pipefail

HOSTPORT="${1:-localhost:6379}"
HOST="${HOSTPORT%%:*}"
PORT="${HOSTPORT##*:}"
TEST_TYPE="${2:-quick}"
PASSWORD="${3:-}"

AUTH_ARGS=""
if [ -n "$PASSWORD" ]; then
  AUTH_ARGS="-a $PASSWORD"
fi

BENCH="redis-benchmark -h $HOST -p $PORT $AUTH_ARGS -q"

header() { printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$*"; }
info()   { printf '\033[0;33m%s\033[0m\n' "$*"; }
result() { printf '%s\n' "$*"; }

# Check connectivity first
if ! redis-cli -h "$HOST" -p "$PORT" $AUTH_ARGS PING &>/dev/null; then
  printf '\033[0;31mError: Cannot connect to %s:%s\033[0m\n' "$HOST" "$PORT"
  exit 1
fi

VERSION=$(redis-cli -h "$HOST" -p "$PORT" $AUTH_ARGS INFO server 2>/dev/null | grep redis_version | tr -d '\r' | cut -d: -f2)
info "Redis $VERSION at $HOST:$PORT — Test: $TEST_TYPE"
info "Started: $(date)"
echo ""

run_quick() {
  header "Quick Benchmark (10K requests, 50 clients)"
  $BENCH -n 10000 -c 50 -t set,get,incr,lpush,lpop,sadd,spop,hset,mset
}

run_standard() {
  header "Standard Benchmark (100K requests, 50 clients)"
  $BENCH -n 100000 -c 50
}

run_pipeline() {
  header "Pipeline Benchmark (100K requests, varying pipeline depth)"
  for P in 1 10 50 100; do
    info "Pipeline depth: $P"
    $BENCH -n 100000 -c 50 -P "$P" -t set,get
    echo ""
  done
}

run_throughput() {
  header "Throughput Benchmark (100K requests, varying clients)"
  for C in 1 10 50 100 200; do
    info "Clients: $C"
    $BENCH -n 100000 -c "$C" -t set,get
    echo ""
  done
}

run_latency() {
  header "Latency Benchmark (10K requests, 1 client, detailed)"
  info "Single-client latency (best case):"
  $BENCH -n 10000 -c 1 -t get,set --csv 2>/dev/null || $BENCH -n 10000 -c 1 -t get,set
  echo ""
  info "50-client latency:"
  $BENCH -n 50000 -c 50 -t get,set --csv 2>/dev/null || $BENCH -n 50000 -c 50 -t get,set
}

run_data_sizes() {
  header "Data Size Benchmark (50K requests, varying value sizes)"
  for SIZE in 64 256 1024 4096 16384; do
    if [ "$SIZE" -lt 1024 ]; then
      LABEL="${SIZE}B"
    else
      LABEL="$((SIZE / 1024))KB"
    fi
    info "Value size: $LABEL"
    $BENCH -n 50000 -c 50 -d "$SIZE" -t set,get
    echo ""
  done
}

# Run requested test(s)
case "$TEST_TYPE" in
  quick)
    run_quick
    ;;
  standard)
    run_standard
    ;;
  pipeline)
    run_pipeline
    ;;
  throughput)
    run_throughput
    ;;
  latency)
    run_latency
    ;;
  data-sizes|data_sizes|datasizes)
    run_data_sizes
    ;;
  all)
    run_quick
    run_standard
    run_pipeline
    run_throughput
    run_latency
    run_data_sizes
    ;;
  *)
    printf '\033[0;31mUnknown test type: %s\033[0m\n' "$TEST_TYPE"
    echo "Available: quick, standard, pipeline, throughput, latency, data-sizes, all"
    exit 1
    ;;
esac

echo ""
info "Completed: $(date)"
