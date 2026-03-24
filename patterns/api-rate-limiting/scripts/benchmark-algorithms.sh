#!/usr/bin/env bash
# benchmark-algorithms.sh — Benchmark rate limiting algorithms: accuracy vs memory vs speed
#
# Usage:
#   ./benchmark-algorithms.sh [algorithm]
#   ./benchmark-algorithms.sh all            Run all benchmarks
#   ./benchmark-algorithms.sh fixed-window   Benchmark fixed window only
#   ./benchmark-algorithms.sh token-bucket   Benchmark token bucket only
#   ./benchmark-algorithms.sh sliding-log    Benchmark sliding window log only
#   ./benchmark-algorithms.sh sliding-counter Benchmark sliding window counter only
#   ./benchmark-algorithms.sh compare        Side-by-side summary of all algorithms
#
# Requirements: redis-cli, bash 4+, bc (for floating point math)
#
# Environment:
#   REDIS_HOST       (default: 127.0.0.1)
#   REDIS_PORT       (default: 6379)
#   REDIS_AUTH       (default: empty)
#   BENCH_REQUESTS   (default: 1000)
#   BENCH_LIMIT      (default: 100)

set -euo pipefail

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_AUTH="${REDIS_AUTH:-}"
BENCH_REQUESTS="${BENCH_REQUESTS:-1000}"
BENCH_LIMIT="${BENCH_LIMIT:-100}"

rcli() {
    local auth_args=()
    if [[ -n "$REDIS_AUTH" ]]; then
        auth_args=(-a "$REDIS_AUTH" --no-auth-warning)
    fi
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "${auth_args[@]}" "$@"
}

check_redis() {
    if ! rcli PING 2>/dev/null | grep -q PONG; then
        echo "ERROR: Redis not available at $REDIS_HOST:$REDIS_PORT"
        exit 1
    fi
}

cleanup_keys() {
    local pattern="$1"
    local keys
    keys=$(rcli --no-headers KEYS "$pattern" 2>/dev/null || true)
    if [[ -n "$keys" ]]; then
        echo "$keys" | xargs -r redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL > /dev/null 2>&1 || true
    fi
}

# --- Lua Scripts ---

FIXED_WINDOW_LUA='
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local count = redis.call("INCR", key)
if count == 1 then redis.call("EXPIRE", key, window) end
if count > limit then return -1 end
return limit - count
'

SLIDING_LOG_LUA='
local key = KEYS[1]
local window = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local id = ARGV[4]
redis.call("ZREMRANGEBYSCORE", key, 0, now - window)
local count = redis.call("ZCARD", key)
if count >= limit then return -1 end
redis.call("ZADD", key, now, id)
redis.call("EXPIRE", key, window + 1)
return limit - count - 1
'

SLIDING_COUNTER_LUA='
local curr_key = KEYS[1]
local prev_key = KEYS[2]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local curr_start = math.floor(now / window) * window
local elapsed = (now - curr_start) / window
local weight = 1 - elapsed
local curr = tonumber(redis.call("GET", curr_key) or "0")
local prev = tonumber(redis.call("GET", prev_key) or "0")
local weighted = math.floor(prev * weight + curr)
if weighted >= limit then return -1 end
local c = redis.call("INCR", curr_key)
if c == 1 then redis.call("EXPIRE", curr_key, window * 2) end
return limit - math.floor(prev * weight + c)
'

TOKEN_BUCKET_LUA='
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4]) or 1
local data = redis.call("HMGET", key, "tokens", "ts")
local tokens = tonumber(data[1]) or capacity
local last = tonumber(data[2]) or now
local elapsed = math.max(0, now - last)
tokens = math.min(capacity, tokens + elapsed * refill)
if tokens < cost then
    redis.call("HSET", key, "tokens", tokens, "ts", now)
    redis.call("EXPIRE", key, math.ceil(capacity / refill) + 1)
    return -1
end
tokens = tokens - cost
redis.call("HSET", key, "tokens", tokens, "ts", now)
redis.call("EXPIRE", key, math.ceil(capacity / refill) + 1)
return math.floor(tokens)
'

# --- Benchmark Functions ---

bench_fixed_window() {
    local name="Fixed Window"
    local key="bench:fw"
    local allowed=0
    local rejected=0

    cleanup_keys "bench:fw*"

    echo "--- $name ---"
    echo "Config: limit=$BENCH_LIMIT/60s, requests=$BENCH_REQUESTS"

    local start_time
    start_time=$(date +%s%N)

    for i in $(seq 1 "$BENCH_REQUESTS"); do
        local result
        result=$(rcli EVAL "$FIXED_WINDOW_LUA" 1 "$key" "$BENCH_LIMIT" 60)
        if [[ "$result" != "-1" ]]; then
            allowed=$((allowed + 1))
        else
            rejected=$((rejected + 1))
        fi
    done

    local end_time
    end_time=$(date +%s%N)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))
    local memory
    memory=$(rcli MEMORY USAGE "$key" 2>/dev/null || echo "N/A")

    echo "  Allowed:    $allowed"
    echo "  Rejected:   $rejected"
    echo "  Duration:   ${duration_ms}ms"
    echo "  Memory/key: ${memory} bytes"
    echo "  Ops/sec:    $(echo "scale=0; $BENCH_REQUESTS * 1000 / $duration_ms" | bc 2>/dev/null || echo "N/A")"
    echo ""

    cleanup_keys "bench:fw*"
    echo "$name|$allowed|$rejected|$duration_ms|$memory"
}

bench_sliding_log() {
    local name="Sliding Window Log"
    local key="bench:swl"
    local allowed=0
    local rejected=0

    cleanup_keys "bench:swl*"

    echo "--- $name ---"
    echo "Config: limit=$BENCH_LIMIT/60s, requests=$BENCH_REQUESTS"

    local start_time
    start_time=$(date +%s%N)
    local base_time
    base_time=$(date +%s)

    for i in $(seq 1 "$BENCH_REQUESTS"); do
        local now
        now=$(echo "$base_time + $i * 0.001" | bc)
        local result
        result=$(rcli EVAL "$SLIDING_LOG_LUA" 1 "$key" 60 "$BENCH_LIMIT" "$now" "req:$i")
        if [[ "$result" != "-1" ]]; then
            allowed=$((allowed + 1))
        else
            rejected=$((rejected + 1))
        fi
    done

    local end_time
    end_time=$(date +%s%N)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))
    local memory
    memory=$(rcli MEMORY USAGE "$key" 2>/dev/null || echo "N/A")

    echo "  Allowed:    $allowed"
    echo "  Rejected:   $rejected"
    echo "  Duration:   ${duration_ms}ms"
    echo "  Memory/key: ${memory} bytes"
    echo "  Ops/sec:    $(echo "scale=0; $BENCH_REQUESTS * 1000 / $duration_ms" | bc 2>/dev/null || echo "N/A")"
    echo ""

    cleanup_keys "bench:swl*"
    echo "$name|$allowed|$rejected|$duration_ms|$memory"
}

bench_sliding_counter() {
    local name="Sliding Window Counter"
    local allowed=0
    local rejected=0

    cleanup_keys "bench:swc*"

    echo "--- $name ---"
    echo "Config: limit=$BENCH_LIMIT/60s, requests=$BENCH_REQUESTS"

    local start_time
    start_time=$(date +%s%N)
    local now
    now=$(date +%s)
    local window=60
    local curr_win=$((now / window))
    local prev_win=$((curr_win - 1))

    for i in $(seq 1 "$BENCH_REQUESTS"); do
        local result
        result=$(rcli EVAL "$SLIDING_COUNTER_LUA" 2 \
            "bench:swc:$curr_win" "bench:swc:$prev_win" \
            "$BENCH_LIMIT" "$window" "$now")
        if [[ "$result" != "-1" ]]; then
            allowed=$((allowed + 1))
        else
            rejected=$((rejected + 1))
        fi
    done

    local end_time
    end_time=$(date +%s%N)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))
    local memory
    memory=$(rcli MEMORY USAGE "bench:swc:$curr_win" 2>/dev/null || echo "N/A")

    echo "  Allowed:    $allowed"
    echo "  Rejected:   $rejected"
    echo "  Duration:   ${duration_ms}ms"
    echo "  Memory/key: ${memory} bytes (x2 keys)"
    echo "  Ops/sec:    $(echo "scale=0; $BENCH_REQUESTS * 1000 / $duration_ms" | bc 2>/dev/null || echo "N/A")"
    echo ""

    cleanup_keys "bench:swc*"
    echo "$name|$allowed|$rejected|$duration_ms|$memory"
}

bench_token_bucket() {
    local name="Token Bucket"
    local key="bench:tb"
    local allowed=0
    local rejected=0
    local capacity=$BENCH_LIMIT
    local refill_rate=$(echo "scale=4; $BENCH_LIMIT / 60" | bc)

    cleanup_keys "bench:tb*"

    echo "--- $name ---"
    echo "Config: capacity=$capacity, refill=${refill_rate}/s, requests=$BENCH_REQUESTS"

    local start_time
    start_time=$(date +%s%N)
    local base_time
    base_time=$(date +%s)

    for i in $(seq 1 "$BENCH_REQUESTS"); do
        local now
        now=$(echo "$base_time + $i * 0.001" | bc)
        local result
        result=$(rcli EVAL "$TOKEN_BUCKET_LUA" 1 "$key" "$capacity" "$refill_rate" "$now" 1)
        if [[ "$result" != "-1" ]]; then
            allowed=$((allowed + 1))
        else
            rejected=$((rejected + 1))
        fi
    done

    local end_time
    end_time=$(date +%s%N)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))
    local memory
    memory=$(rcli MEMORY USAGE "$key" 2>/dev/null || echo "N/A")

    echo "  Allowed:    $allowed"
    echo "  Rejected:   $rejected"
    echo "  Duration:   ${duration_ms}ms"
    echo "  Memory/key: ${memory} bytes"
    echo "  Ops/sec:    $(echo "scale=0; $BENCH_REQUESTS * 1000 / $duration_ms" | bc 2>/dev/null || echo "N/A")"
    echo ""

    cleanup_keys "bench:tb*"
    echo "$name|$allowed|$rejected|$duration_ms|$memory"
}

cmd_compare() {
    echo "=========================================="
    echo " Rate Limiting Algorithm Benchmark"
    echo " Requests: $BENCH_REQUESTS | Limit: $BENCH_LIMIT"
    echo "=========================================="
    echo ""

    local results=""
    results+="$(bench_fixed_window | tail -1)\n"
    results+="$(bench_token_bucket | tail -1)\n"
    results+="$(bench_sliding_counter | tail -1)\n"
    results+="$(bench_sliding_log | tail -1)\n"

    echo ""
    echo "=========================================="
    echo " COMPARISON SUMMARY"
    echo "=========================================="
    printf "%-24s %8s %8s %8s %10s\n" "Algorithm" "Allowed" "Rejected" "Time(ms)" "Mem(bytes)"
    printf "%-24s %8s %8s %8s %10s\n" "------------------------" "--------" "--------" "--------" "----------"
    echo -e "$results" | while IFS='|' read -r name allowed rejected duration memory; do
        [[ -z "$name" ]] && continue
        printf "%-24s %8s %8s %8s %10s\n" "$name" "$allowed" "$rejected" "$duration" "$memory"
    done
}

# --- Main ---

check_redis

case "${1:-help}" in
    all)              bench_fixed_window; bench_token_bucket; bench_sliding_counter; bench_sliding_log ;;
    fixed-window)     bench_fixed_window ;;
    token-bucket)     bench_token_bucket ;;
    sliding-log)      bench_sliding_log ;;
    sliding-counter)  bench_sliding_counter ;;
    compare)          cmd_compare ;;
    *)
        echo "Usage: $0 {all|fixed-window|token-bucket|sliding-log|sliding-counter|compare}"
        echo ""
        echo "Benchmarks rate limiting algorithms for accuracy, speed, and memory."
        echo ""
        echo "Environment variables:"
        echo "  BENCH_REQUESTS=$BENCH_REQUESTS  Total requests to send"
        echo "  BENCH_LIMIT=$BENCH_LIMIT     Rate limit per window"
        echo "  REDIS_HOST=$REDIS_HOST"
        echo "  REDIS_PORT=$REDIS_PORT"
        exit 1
        ;;
esac
