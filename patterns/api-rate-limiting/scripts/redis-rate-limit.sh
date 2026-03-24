#!/usr/bin/env bash
# redis-rate-limit.sh — Set up Redis with rate limiting Lua scripts and test concurrency
#
# Usage:
#   ./redis-rate-limit.sh setup         Load Lua scripts into Redis
#   ./redis-rate-limit.sh test-token    Test token bucket with concurrent requests
#   ./redis-rate-limit.sh test-sliding  Test sliding window counter
#   ./redis-rate-limit.sh test-race     Demonstrate race condition protection
#   ./redis-rate-limit.sh cleanup       Remove test keys from Redis
#
# Requirements: redis-cli, bash 4+
# Optional: GNU parallel or xargs for concurrency tests
#
# Environment:
#   REDIS_HOST  (default: 127.0.0.1)
#   REDIS_PORT  (default: 6379)
#   REDIS_AUTH  (default: empty)

set -euo pipefail

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_AUTH="${REDIS_AUTH:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Redis CLI wrapper
rcli() {
    local auth_args=()
    if [[ -n "$REDIS_AUTH" ]]; then
        auth_args=(-a "$REDIS_AUTH" --no-auth-warning)
    fi
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "${auth_args[@]}" "$@"
}

# Check Redis connectivity
check_redis() {
    if ! rcli PING | grep -q PONG; then
        echo "ERROR: Cannot connect to Redis at $REDIS_HOST:$REDIS_PORT"
        echo "Start Redis: docker run -d -p 6379:6379 redis:7-alpine"
        exit 1
    fi
    echo "✓ Redis connected at $REDIS_HOST:$REDIS_PORT"
}

# Load a Lua script and return its SHA
load_script() {
    local script_file="$1"
    local script_name="$2"
    if [[ ! -f "$script_file" ]]; then
        echo "ERROR: Script not found: $script_file"
        exit 1
    fi
    local sha
    sha=$(rcli SCRIPT LOAD "$(cat "$script_file")")
    echo "✓ Loaded $script_name: SHA=$sha"
    echo "$sha"
}

# --- Commands ---

cmd_setup() {
    echo "=== Setting up Redis Rate Limiting Scripts ==="
    check_redis

    echo ""
    echo "Loading Lua scripts from assets/..."

    TOKEN_BUCKET_SHA=$(load_script "$SCRIPT_DIR/assets/token-bucket.lua" "token-bucket")
    SLIDING_WINDOW_SHA=$(load_script "$SCRIPT_DIR/assets/sliding-window.lua" "sliding-window")

    echo ""
    echo "Scripts loaded. Use EVALSHA to call them:"
    echo "  Token Bucket:    EVALSHA $TOKEN_BUCKET_SHA 1 <key> <capacity> <refill_rate> <now> [cost]"
    echo "  Sliding Window:  EVALSHA $SLIDING_WINDOW_SHA 2 <curr_key> <prev_key> <limit> <window> <now>"
}

cmd_test_token() {
    echo "=== Token Bucket Concurrency Test ==="
    check_redis

    local lua_script
    lua_script=$(cat "$SCRIPT_DIR/assets/token-bucket.lua")
    local test_key="rl:test:token-bucket"
    local capacity=10
    local refill_rate=2
    local total_requests=30
    local allowed=0
    local rejected=0

    # Clean slate
    rcli DEL "$test_key" > /dev/null

    echo "Config: capacity=$capacity, refill_rate=$refill_rate tokens/sec"
    echo "Sending $total_requests requests as fast as possible..."
    echo ""

    for i in $(seq 1 $total_requests); do
        local now
        now=$(date +%s.%N 2>/dev/null || date +%s)
        local result
        result=$(rcli EVAL "$lua_script" 1 "$test_key" "$capacity" "$refill_rate" "$now" 1)
        local is_allowed
        is_allowed=$(echo "$result" | grep -o '"allowed":[a-z]*' | cut -d: -f2)
        local remaining
        remaining=$(echo "$result" | grep -o '"remaining":[0-9]*' | cut -d: -f2)

        if [[ "$is_allowed" == "true" ]]; then
            allowed=$((allowed + 1))
            printf "  Request %2d: ✓ ALLOWED (remaining: %s)\n" "$i" "$remaining"
        else
            rejected=$((rejected + 1))
            printf "  Request %2d: ✗ REJECTED\n" "$i"
        fi
    done

    echo ""
    echo "Results: $allowed allowed, $rejected rejected (expected ~$capacity allowed for burst)"

    # Cleanup
    rcli DEL "$test_key" > /dev/null
}

cmd_test_sliding() {
    echo "=== Sliding Window Counter Test ==="
    check_redis

    local lua_script
    lua_script=$(cat "$SCRIPT_DIR/assets/sliding-window.lua")
    local limit=5
    local window=10
    local total_requests=10
    local allowed=0
    local rejected=0

    echo "Config: limit=$limit requests per ${window}s window"
    echo "Sending $total_requests requests..."
    echo ""

    for i in $(seq 1 $total_requests); do
        local now
        now=$(date +%s)
        local curr_win=$((now / window))
        local prev_win=$((curr_win - 1))
        local curr_key="rl:test:sw:$curr_win"
        local prev_key="rl:test:sw:$prev_win"

        local result
        result=$(rcli EVAL "$lua_script" 2 "$curr_key" "$prev_key" "$limit" "$window" "$now")
        local is_allowed
        is_allowed=$(echo "$result" | grep -o '"allowed":[a-z]*' | cut -d: -f2)
        local remaining
        remaining=$(echo "$result" | grep -o '"remaining":[0-9]*' | cut -d: -f2)

        if [[ "$is_allowed" == "true" ]]; then
            allowed=$((allowed + 1))
            printf "  Request %2d: ✓ ALLOWED (remaining: %s)\n" "$i" "$remaining"
        else
            rejected=$((rejected + 1))
            printf "  Request %2d: ✗ REJECTED\n" "$i"
        fi
    done

    echo ""
    echo "Results: $allowed allowed, $rejected rejected (expected $limit allowed)"

    # Cleanup
    local now
    now=$(date +%s)
    local curr_win=$((now / window))
    local prev_win=$((curr_win - 1))
    rcli DEL "rl:test:sw:$curr_win" "rl:test:sw:$prev_win" > /dev/null
}

cmd_test_race() {
    echo "=== Race Condition Test ==="
    check_redis

    local lua_script
    lua_script=$(cat "$SCRIPT_DIR/assets/token-bucket.lua")
    local test_key="rl:test:race"
    local capacity=10
    local refill_rate=0  # No refill — once tokens are gone, they're gone
    local concurrency=20

    rcli DEL "$test_key" > /dev/null

    echo "Config: capacity=$capacity, refill=0 (no replenishment)"
    echo "Firing $concurrency concurrent requests..."
    echo ""

    # Fire concurrent requests using background subshells
    local tmpdir
    tmpdir=$(mktemp -d)
    for i in $(seq 1 $concurrency); do
        (
            local now
            now=$(date +%s.%N 2>/dev/null || date +%s)
            local result
            result=$(rcli EVAL "$lua_script" 1 "$test_key" "$capacity" "$refill_rate" "$now" 1)
            echo "$result" > "$tmpdir/$i"
        ) &
    done
    wait

    local allowed=0
    local rejected=0
    for i in $(seq 1 $concurrency); do
        local result
        result=$(cat "$tmpdir/$i")
        local is_allowed
        is_allowed=$(echo "$result" | grep -o '"allowed":[a-z]*' | cut -d: -f2)
        if [[ "$is_allowed" == "true" ]]; then
            allowed=$((allowed + 1))
        else
            rejected=$((rejected + 1))
        fi
    done

    rm -rf "$tmpdir"
    rcli DEL "$test_key" > /dev/null

    echo "Results: $allowed allowed, $rejected rejected"
    if [[ $allowed -le $capacity ]]; then
        echo "✓ PASS: No race condition — exactly $capacity or fewer requests allowed"
    else
        echo "✗ FAIL: Race condition detected — $allowed > $capacity allowed"
    fi
}

cmd_cleanup() {
    echo "=== Cleaning up test keys ==="
    check_redis
    local keys
    keys=$(rcli --no-headers KEYS "rl:test:*" 2>/dev/null || true)
    if [[ -n "$keys" ]]; then
        echo "$keys" | while read -r key; do
            rcli DEL "$key" > /dev/null
            echo "  Deleted: $key"
        done
    else
        echo "  No test keys found"
    fi
    echo "✓ Cleanup complete"
}

# --- Main ---

case "${1:-help}" in
    setup)       cmd_setup ;;
    test-token)  cmd_test_token ;;
    test-sliding) cmd_test_sliding ;;
    test-race)   cmd_test_race ;;
    cleanup)     cmd_cleanup ;;
    *)
        echo "Usage: $0 {setup|test-token|test-sliding|test-race|cleanup}"
        echo ""
        echo "Commands:"
        echo "  setup         Load Lua scripts into Redis"
        echo "  test-token    Test token bucket with burst requests"
        echo "  test-sliding  Test sliding window counter"
        echo "  test-race     Verify atomic Lua prevents race conditions"
        echo "  cleanup       Remove test keys from Redis"
        exit 1
        ;;
esac
