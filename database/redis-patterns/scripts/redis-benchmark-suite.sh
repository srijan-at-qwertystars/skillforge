#!/usr/bin/env bash
# =============================================================================
# redis-benchmark-suite.sh — Redis Benchmark Suite
# =============================================================================
# Usage: ./redis-benchmark-suite.sh [-h HOST] [-p PORT] [-a PASSWORD] [-n REQUESTS] [-c CLIENTS]
#
# Tests various operations (GET/SET/LPUSH/ZADD/XADD), compares pipeline vs
# non-pipeline performance, and reports throughput summary.
#
# Examples:
#   ./redis-benchmark-suite.sh
#   ./redis-benchmark-suite.sh -h redis.example.com -p 6380 -n 500000
#   ./redis-benchmark-suite.sh -c 200 -n 1000000
# =============================================================================

set -euo pipefail

# Defaults
HOST="127.0.0.1"
PORT="6379"
AUTH=""
REQUESTS=100000
CLIENTS=50
DATA_SIZE=256
KEY_RANGE=100000

while getopts "h:p:a:n:c:d:" opt; do
    case "$opt" in
        h) HOST="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        a) AUTH="$OPTARG" ;;
        n) REQUESTS="$OPTARG" ;;
        c) CLIENTS="$OPTARG" ;;
        d) DATA_SIZE="$OPTARG" ;;
        *) echo "Usage: $0 [-h host] [-p port] [-a password] [-n requests] [-c clients] [-d data_size]" >&2; exit 1 ;;
    esac
done

BENCH_CMD="redis-benchmark -h $HOST -p $PORT -r $KEY_RANGE"
[ -n "$AUTH" ] && BENCH_CMD="$BENCH_CMD -a $AUTH"

REDIS_CLI="redis-cli -h $HOST -p $PORT"
[ -n "$AUTH" ] && REDIS_CLI="$REDIS_CLI -a $AUTH --no-auth-warning"

# Check connectivity
if ! $REDIS_CLI PING 2>/dev/null | grep -q "PONG"; then
    echo "ERROR: Cannot connect to Redis at $HOST:$PORT" >&2
    exit 1
fi

REDIS_VERSION=$($REDIS_CLI INFO server 2>/dev/null | grep "redis_version:" | cut -d: -f2 | tr -d '[:space:]')

divider() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════"
}

header() {
    echo ""
    echo "--- $1 ---"
}

echo "Redis Benchmark Suite — $(date '+%Y-%m-%d %H:%M:%S')"
echo "Target:    $HOST:$PORT (Redis $REDIS_VERSION)"
echo "Requests:  $REQUESTS per test"
echo "Clients:   $CLIENTS concurrent"
echo "Data Size: $DATA_SIZE bytes"
echo "Key Range: $KEY_RANGE random keys"

# ═══════════════════════════════════════════════════════
# SECTION 1: Individual Operation Benchmarks
# ═══════════════════════════════════════════════════════
divider "INDIVIDUAL OPERATION BENCHMARKS (no pipeline)"

declare -A RESULTS_NOPIPE

for op in SET GET INCR LPUSH RPUSH LPOP SADD SPOP ZADD ZPOPMIN HSET LRANGE_100 LRANGE_600 MSET; do
    result=$($BENCH_CMD -t "$op" -n "$REQUESTS" -c "$CLIENTS" -d "$DATA_SIZE" -q 2>/dev/null | head -1)
    throughput=$(echo "$result" | grep -oP '[\d.]+(?= requests per second)' || echo "N/A")
    printf "  %-15s %s req/s\n" "$op:" "$throughput"
    RESULTS_NOPIPE[$op]="$throughput"
done

# ═══════════════════════════════════════════════════════
# SECTION 2: Pipeline Comparison
# ═══════════════════════════════════════════════════════
divider "PIPELINE COMPARISON"

PIPELINE_SIZES=(1 8 16 32 64)
OPS_TO_PIPELINE=(SET GET LPUSH ZADD)

printf "  %-10s" "Pipeline"
for op in "${OPS_TO_PIPELINE[@]}"; do
    printf "  %-15s" "$op"
done
echo ""
printf "  %-10s" "--------"
for op in "${OPS_TO_PIPELINE[@]}"; do
    printf "  %-15s" "---------------"
done
echo ""

for psize in "${PIPELINE_SIZES[@]}"; do
    printf "  P=%-7s" "$psize"
    for op in "${OPS_TO_PIPELINE[@]}"; do
        result=$($BENCH_CMD -t "$op" -n "$REQUESTS" -c "$CLIENTS" -d "$DATA_SIZE" -P "$psize" -q 2>/dev/null | head -1)
        throughput=$(echo "$result" | grep -oP '[\d.]+(?= requests per second)' || echo "N/A")
        printf "  %-15s" "${throughput} req/s"
    done
    echo ""
done

# ═══════════════════════════════════════════════════════
# SECTION 3: Streams Benchmark
# ═══════════════════════════════════════════════════════
divider "STREAMS BENCHMARK"

header "XADD (no pipeline)"
result=$($BENCH_CMD -n "$REQUESTS" -c "$CLIENTS" -q \
    -- XADD stream:bench '*' field1 value1 field2 value2 2>/dev/null | head -1)
throughput=$(echo "$result" | grep -oP '[\d.]+(?= requests per second)' || echo "N/A")
printf "  XADD:         %s req/s\n" "$throughput"

header "XADD (pipeline=16)"
result=$($BENCH_CMD -n "$REQUESTS" -c "$CLIENTS" -P 16 -q \
    -- XADD stream:bench2 '*' field1 value1 field2 value2 2>/dev/null | head -1)
throughput=$(echo "$result" | grep -oP '[\d.]+(?= requests per second)' || echo "N/A")
printf "  XADD (P=16):  %s req/s\n" "$throughput"

# Cleanup benchmark streams
$REDIS_CLI DEL stream:bench stream:bench2 >/dev/null 2>&1 || true

# ═══════════════════════════════════════════════════════
# SECTION 4: Data Size Impact
# ═══════════════════════════════════════════════════════
divider "DATA SIZE IMPACT (SET with pipeline=16)"

for size in 64 256 1024 4096 16384; do
    result=$($BENCH_CMD -t SET -n "$REQUESTS" -c "$CLIENTS" -d "$size" -P 16 -q 2>/dev/null | head -1)
    throughput=$(echo "$result" | grep -oP '[\d.]+(?= requests per second)' || echo "N/A")
    printf "  %6d bytes:  %s req/s\n" "$size" "$throughput"
done

# ═══════════════════════════════════════════════════════
# SECTION 5: Latency Snapshot
# ═══════════════════════════════════════════════════════
divider "LATENCY SNAPSHOT"

echo "  Sampling latency for 5 seconds..."
LATENCY_OUTPUT=$($REDIS_CLI --latency -i 1 2>/dev/null &
    LPID=$!
    sleep 5
    kill $LPID 2>/dev/null
    wait $LPID 2>/dev/null || true
)
if [ -n "$LATENCY_OUTPUT" ]; then
    echo "  $LATENCY_OUTPUT"
else
    echo "  (latency test completed — check manually with: redis-cli --latency)"
fi

# ═══════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════
divider "SUMMARY"
echo ""
echo "  Benchmark completed at $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "  Key Findings:"
echo "  • SET (no pipeline):  ${RESULTS_NOPIPE[SET]:-N/A} req/s"
echo "  • GET (no pipeline):  ${RESULTS_NOPIPE[GET]:-N/A} req/s"

# Pipeline improvement calculation
if command -v bc &>/dev/null; then
    SET_NOPIPE="${RESULTS_NOPIPE[SET]:-0}"
    SET_P16=$($BENCH_CMD -t SET -n "$REQUESTS" -c "$CLIENTS" -P 16 -q 2>/dev/null | head -1 | grep -oP '[\d.]+(?= requests per second)' || echo "0")
    if [ "$SET_NOPIPE" != "N/A" ] && [ "$SET_NOPIPE" != "0" ] && [ -n "$SET_P16" ] && [ "$SET_P16" != "0" ]; then
        IMPROVEMENT=$(echo "scale=1; $SET_P16 / $SET_NOPIPE" | bc 2>/dev/null || echo "N/A")
        echo "  • Pipeline speedup:   ${IMPROVEMENT}x (P=16 vs no pipeline)"
    fi
fi

echo ""
echo "  Tip: Run with -n 1000000 for more stable measurements"
echo ""
