#!/usr/bin/env bash
# cache-benchmark.sh — Redis cache benchmark: throughput, latency, memory for different data structures
set -euo pipefail

# --- Configuration ---
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
REQUESTS="${REQUESTS:-100000}"
CLIENTS="${CLIENTS:-50}"
DATA_SIZE="${DATA_SIZE:-256}"
KEY_PATTERN="${KEY_PATTERN:-benchmark}"
PIPELINE="${PIPELINE:-1}"

# --- Helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[BENCH]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Redis cache benchmark — tests throughput, latency, and memory usage
for different data structures and access patterns.

Options:
  -h, --host HOST        Redis host (default: 127.0.0.1)
  -p, --port PORT        Redis port (default: 6379)
  -a, --password PASS    Redis password
  -n, --requests N       Number of requests per test (default: 100000)
  -c, --clients N        Number of concurrent clients (default: 50)
  -d, --data-size N      Value size in bytes (default: 256)
  -P, --pipeline N       Pipeline N commands (default: 1)
  --quick                Run a quick benchmark (10000 requests, 10 clients)
  --help                 Show this help

Environment variables:
  REDIS_HOST, REDIS_PORT, REDIS_PASSWORD, REQUESTS, CLIENTS, DATA_SIZE

Examples:
  $(basename "$0") --quick
  $(basename "$0") -n 500000 -c 100 -d 1024
  $(basename "$0") -h redis.example.com -p 6380 -a mypassword
EOF
    exit 0
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--host)     REDIS_HOST="$2"; shift 2 ;;
        -p|--port)     REDIS_PORT="$2"; shift 2 ;;
        -a|--password) REDIS_PASSWORD="$2"; shift 2 ;;
        -n|--requests) REQUESTS="$2"; shift 2 ;;
        -c|--clients)  CLIENTS="$2"; shift 2 ;;
        -d|--data-size) DATA_SIZE="$2"; shift 2 ;;
        -P|--pipeline) PIPELINE="$2"; shift 2 ;;
        --quick)       REQUESTS=10000; CLIENTS=10; shift ;;
        --help)        usage ;;
        *)             err "Unknown option: $1"; usage ;;
    esac
done

# --- Build redis-cli and redis-benchmark base args ---
CLI_ARGS=(-h "$REDIS_HOST" -p "$REDIS_PORT")
BENCH_ARGS=(-h "$REDIS_HOST" -p "$REDIS_PORT" -n "$REQUESTS" -c "$CLIENTS" -P "$PIPELINE" -q)
if [[ -n "$REDIS_PASSWORD" ]]; then
    CLI_ARGS+=(-a "$REDIS_PASSWORD")
    BENCH_ARGS+=(-a "$REDIS_PASSWORD")
fi

redis_cli() { redis-cli "${CLI_ARGS[@]}" "$@" 2>/dev/null; }

# --- Preflight checks ---
check_redis() {
    if ! command -v redis-benchmark &>/dev/null; then
        err "redis-benchmark not found. Install redis-tools."
        exit 1
    fi
    if ! redis_cli PING | grep -q PONG; then
        err "Cannot connect to Redis at ${REDIS_HOST}:${REDIS_PORT}"
        exit 1
    fi
    ok "Connected to Redis at ${REDIS_HOST}:${REDIS_PORT}"
}

# --- Memory snapshot ---
memory_snapshot() {
    redis_cli INFO memory 2>/dev/null | grep -E "used_memory_human|used_memory_peak_human|mem_fragmentation_ratio" | tr -d '\r'
}

# --- Benchmark sections ---

bench_strings() {
    log "=== STRING operations (SET/GET) ==="
    log "Requests: $REQUESTS | Clients: $CLIENTS | Value size: ${DATA_SIZE}B | Pipeline: $PIPELINE"
    echo ""

    log "SET benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -t set -d "$DATA_SIZE" 2>/dev/null
    echo ""

    log "GET benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -t get 2>/dev/null
    echo ""

    log "SETEX (with TTL) benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -r 100000 \
        -c "$CLIENTS" -n "$REQUESTS" \
        eval "redis.call('SETEX','bench:__rand_int__',3600,'$(head -c "$DATA_SIZE" /dev/urandom | base64 | head -c "$DATA_SIZE")')" 0 2>/dev/null || \
        warn "SETEX eval benchmark skipped (eval not supported in this mode)"
    echo ""

    log "MSET (batch write, 10 keys per call):"
    redis-benchmark "${BENCH_ARGS[@]}" -r 100000 \
        -t mset -d "$DATA_SIZE" 2>/dev/null || warn "MSET benchmark skipped"
    echo ""
}

bench_hashes() {
    log "=== HASH operations ==="
    echo ""

    log "HSET benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -r 100000 \
        -t hset 2>/dev/null
    echo ""

    log "HGET benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -r 100000 \
        eval "redis.call('HGET','myhash','__rand_int__')" 0 2>/dev/null || \
        warn "HGET eval benchmark skipped"
    echo ""

    log "HMSET (multiple fields) benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -r 100000 \
        hmset "bench:hash:__rand_int__" field1 value1 field2 value2 field3 value3 2>/dev/null || \
        warn "HMSET benchmark skipped"
    echo ""
}

bench_sorted_sets() {
    log "=== SORTED SET operations ==="
    echo ""

    log "ZADD benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -r 100000 \
        -t zadd 2>/dev/null || \
        redis-benchmark "${BENCH_ARGS[@]}" -r 100000 \
        zadd "bench:zset" "__rand_int__" "member:__rand_int__" 2>/dev/null
    echo ""

    log "ZRANGEBYSCORE benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -r 100000 \
        zrangebyscore "bench:zset" 0 100 2>/dev/null || \
        warn "ZRANGEBYSCORE benchmark skipped"
    echo ""
}

bench_lists() {
    log "=== LIST operations ==="
    echo ""

    log "LPUSH benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -t lpush -d "$DATA_SIZE" 2>/dev/null
    echo ""

    log "LPOP benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" -t lpop 2>/dev/null
    echo ""

    log "LRANGE (first 100 elements) benchmark:"
    redis-benchmark "${BENCH_ARGS[@]}" \
        lrange "bench:list" 0 99 2>/dev/null || warn "LRANGE benchmark skipped"
    echo ""
}

bench_pipeline_comparison() {
    log "=== Pipeline comparison ==="
    echo ""

    for p in 1 10 50 100; do
        log "Pipeline=$p (SET):"
        redis-benchmark -h "$REDIS_HOST" -p "$REDIS_PORT" \
            ${REDIS_PASSWORD:+-a "$REDIS_PASSWORD"} \
            -n "$REQUESTS" -c "$CLIENTS" -P "$p" -q -t set -d "$DATA_SIZE" 2>/dev/null
    done
    echo ""
}

bench_mixed_workload() {
    log "=== Mixed workload (80% GET / 20% SET) ==="
    log "Simulating typical cache-aside pattern..."
    echo ""

    local total=$REQUESTS
    local gets=$((total * 80 / 100))
    local sets=$((total * 20 / 100))

    log "GET phase ($gets requests):"
    redis-benchmark "${BENCH_ARGS[@]}" -t get -n "$gets" 2>/dev/null

    log "SET phase ($sets requests):"
    redis-benchmark "${BENCH_ARGS[@]}" -t set -n "$sets" -d "$DATA_SIZE" 2>/dev/null
    echo ""
}

bench_memory_efficiency() {
    log "=== Memory efficiency comparison ==="
    echo ""

    local test_count=10000

    # Clean up any previous benchmark keys
    redis_cli EVAL "local keys = redis.call('KEYS','memtest:*') for _,k in ipairs(keys) do redis.call('DEL',k) end return #keys" 0 >/dev/null 2>&1 || true

    local mem_before
    mem_before=$(redis_cli INFO memory | grep "used_memory:" | cut -d: -f2 | tr -d '\r')

    # Test 1: Individual string keys
    log "Writing $test_count string keys..."
    for i in $(seq 1 "$test_count"); do
        redis_cli SET "memtest:str:$i" "{\"id\":$i,\"name\":\"user$i\",\"email\":\"user$i@example.com\"}" >/dev/null
    done
    local mem_strings
    mem_strings=$(redis_cli INFO memory | grep "used_memory:" | cut -d: -f2 | tr -d '\r')
    local string_mem=$((mem_strings - mem_before))

    # Cleanup strings
    redis_cli EVAL "local keys = redis.call('KEYS','memtest:str:*') for _,k in ipairs(keys) do redis.call('DEL',k) end return #keys" 0 >/dev/null 2>&1 || true

    local mem_cleaned
    mem_cleaned=$(redis_cli INFO memory | grep "used_memory:" | cut -d: -f2 | tr -d '\r')

    # Test 2: Hash keys
    log "Writing $test_count hash keys..."
    for i in $(seq 1 "$test_count"); do
        redis_cli HSET "memtest:hash:$i" id "$i" name "user$i" email "user$i@example.com" >/dev/null
    done
    local mem_hashes
    mem_hashes=$(redis_cli INFO memory | grep "used_memory:" | cut -d: -f2 | tr -d '\r')
    local hash_mem=$((mem_hashes - mem_cleaned))

    ok "String keys: ~$((string_mem / 1024)) KB for $test_count entries (~$((string_mem / test_count)) bytes/entry)"
    ok "Hash keys:   ~$((hash_mem / 1024)) KB for $test_count entries (~$((hash_mem / test_count)) bytes/entry)"

    # Cleanup
    redis_cli EVAL "local keys = redis.call('KEYS','memtest:*') for _,k in ipairs(keys) do redis.call('DEL',k) end return #keys" 0 >/dev/null 2>&1 || true
    echo ""
}

# --- Cleanup benchmark keys ---
cleanup() {
    log "Cleaning up benchmark keys..."
    redis_cli EVAL "local keys = redis.call('KEYS','bench:*') for _,k in ipairs(keys) do redis.call('DEL',k) end return #keys" 0 >/dev/null 2>&1 || true
    redis_cli EVAL "local keys = redis.call('KEYS','memtest:*') for _,k in ipairs(keys) do redis.call('DEL',k) end return #keys" 0 >/dev/null 2>&1 || true
    redis_cli DEL mylist myhash myset key:__rand_int__ counter:__rand_int__ >/dev/null 2>&1 || true
}

# --- Main ---
main() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║        Redis Cache Benchmark Suite           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    check_redis

    echo ""
    log "Memory before benchmarks:"
    memory_snapshot
    echo ""

    bench_strings
    bench_hashes
    bench_sorted_sets
    bench_lists
    bench_pipeline_comparison
    bench_mixed_workload

    # Memory efficiency test (slower, uses individual commands)
    if [[ "$REQUESTS" -le 100000 ]]; then
        bench_memory_efficiency
    else
        warn "Skipping memory efficiency test (too many requests). Use --quick for memory tests."
    fi

    echo ""
    log "Memory after benchmarks:"
    memory_snapshot
    echo ""

    cleanup

    echo ""
    ok "Benchmark complete!"
    echo ""
}

trap cleanup EXIT
main
