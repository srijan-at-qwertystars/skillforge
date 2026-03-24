#!/usr/bin/env bash
# redis-ratelimit.sh — Test Redis-based rate limiting with Lua scripts.
#
# This script:
#   1. Verifies Redis connectivity
#   2. Loads rate limiting Lua scripts into Redis
#   3. Runs validation tests for token bucket, sliding window, and fixed window
#   4. Reports pass/fail for each test case
#
# Usage:
#   ./redis-ratelimit.sh [OPTIONS]
#
# Options:
#   -h, --host HOST    Redis host (default: localhost)
#   -p, --port PORT    Redis port (default: 6379)
#   -a, --auth PASS    Redis password (default: none)
#   -d, --db NUM       Redis database number (default: 15, to avoid conflicts)
#   --no-cleanup       Don't flush test keys after running
#   --help             Show this help message

set -euo pipefail

# Defaults
REDIS_HOST="localhost"
REDIS_PORT="6379"
REDIS_AUTH=""
REDIS_DB="15"
CLEANUP=true
PASS_COUNT=0
FAIL_COUNT=0
TEST_PREFIX="rl_test"

usage() {
    sed -n '3,16p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--host) REDIS_HOST="$2"; shift 2 ;;
        -p|--port) REDIS_PORT="$2"; shift 2 ;;
        -a|--auth) REDIS_AUTH="$2"; shift 2 ;;
        -d|--db) REDIS_DB="$2"; shift 2 ;;
        --no-cleanup) CLEANUP=false; shift ;;
        --help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Build redis-cli command
RCLI="redis-cli -h $REDIS_HOST -p $REDIS_PORT -n $REDIS_DB"
if [[ -n "$REDIS_AUTH" ]]; then
    RCLI="$RCLI -a $REDIS_AUTH"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
    echo -e "  ${GREEN}✓ PASS${NC}: $1"
    ((PASS_COUNT++))
}

fail() {
    echo -e "  ${RED}✗ FAIL${NC}: $1 (expected: $2, got: $3)"
    ((FAIL_COUNT++))
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc" "$expected" "$actual"
    fi
}

# ============================================
# Check Redis connectivity
# ============================================
echo "============================================"
echo "  Redis Rate Limiter Test Suite"
echo "============================================"
echo ""
echo -n "Connecting to Redis at $REDIS_HOST:$REDIS_PORT (db $REDIS_DB)... "

if ! $RCLI PING 2>/dev/null | grep -q "PONG"; then
    echo -e "${RED}FAILED${NC}"
    echo "Cannot connect to Redis. Ensure Redis is running:"
    echo "  docker run -d -p 6379:6379 redis:alpine"
    echo "  # or: redis-server --daemonize yes"
    exit 1
fi
echo -e "${GREEN}OK${NC}"
echo ""

# Clean up test keys
$RCLI KEYS "${TEST_PREFIX}:*" 2>/dev/null | xargs -r $RCLI DEL 2>/dev/null || true

# ============================================
# Lua Scripts
# ============================================

FIXED_WINDOW_LUA='
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])

local current = redis.call("INCR", key)
if current == 1 then
    redis.call("EXPIRE", key, window)
end

if current > limit then
    return 0
end
return 1
'

SLIDING_WINDOW_LUA='
local key = KEYS[1]
local prev_key = KEYS[2]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local window_start = now - (now % window)
local elapsed = now - window_start
local weight = (window - elapsed) / window

local prev_count = tonumber(redis.call("GET", prev_key) or "0")
local curr_count = tonumber(redis.call("GET", key) or "0")
local effective = prev_count * weight + curr_count

if effective >= limit then
    return 0
end

redis.call("INCR", key)
redis.call("EXPIRE", key, window * 2)
return 1
'

TOKEN_BUCKET_LUA='
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local data = redis.call("HMGET", key, "tokens", "last_refill")
local tokens = tonumber(data[1]) or capacity
local last_refill = tonumber(data[2]) or now

local elapsed = math.max(0, now - last_refill)
tokens = math.min(capacity, tokens + elapsed * refill_rate)

if tokens < 1 then
    redis.call("HMSET", key, "tokens", tokens, "last_refill", now)
    redis.call("EXPIRE", key, math.ceil(capacity / refill_rate) * 2)
    return 0
end

tokens = tokens - 1
redis.call("HMSET", key, "tokens", tokens, "last_refill", now)
redis.call("EXPIRE", key, math.ceil(capacity / refill_rate) * 2)
return 1
'

# ============================================
# Test 1: Fixed Window
# ============================================
echo -e "${YELLOW}Test Suite 1: Fixed Window${NC}"
echo "  Config: limit=5, window=60s"

KEY="${TEST_PREFIX}:fw:test1"
LIMIT=5
WINDOW=60

# Send requests up to the limit
for i in $(seq 1 $LIMIT); do
    result=$($RCLI EVAL "$FIXED_WINDOW_LUA" 1 "$KEY" "$LIMIT" "$WINDOW" 2>/dev/null)
    assert_eq "Request $i should be allowed" "1" "$result"
done

# Next request should be rejected
result=$($RCLI EVAL "$FIXED_WINDOW_LUA" 1 "$KEY" "$LIMIT" "$WINDOW" 2>/dev/null)
assert_eq "Request $((LIMIT + 1)) should be rejected" "0" "$result"

# Verify counter value
counter=$($RCLI GET "$KEY" 2>/dev/null)
assert_eq "Counter should be $((LIMIT + 1))" "$((LIMIT + 1))" "$counter"

# Verify TTL is set
ttl=$($RCLI TTL "$KEY" 2>/dev/null)
if [[ "$ttl" -gt 0 && "$ttl" -le "$WINDOW" ]]; then
    pass "TTL is set (${ttl}s)"
else
    fail "TTL should be between 1 and $WINDOW" "1-$WINDOW" "$ttl"
fi

echo ""

# ============================================
# Test 2: Fixed Window — Separate Keys
# ============================================
echo -e "${YELLOW}Test Suite 2: Fixed Window — Key Isolation${NC}"

KEY_A="${TEST_PREFIX}:fw:userA"
KEY_B="${TEST_PREFIX}:fw:userB"

# Fill user A's limit
for i in $(seq 1 $LIMIT); do
    $RCLI EVAL "$FIXED_WINDOW_LUA" 1 "$KEY_A" "$LIMIT" "$WINDOW" >/dev/null 2>&1
done

# User B should still have full quota
result=$($RCLI EVAL "$FIXED_WINDOW_LUA" 1 "$KEY_B" "$LIMIT" "$WINDOW" 2>/dev/null)
assert_eq "User B request should be allowed (independent of A)" "1" "$result"

# User A should be blocked
result=$($RCLI EVAL "$FIXED_WINDOW_LUA" 1 "$KEY_A" "$LIMIT" "$WINDOW" 2>/dev/null)
assert_eq "User A request should be rejected" "0" "$result"

echo ""

# ============================================
# Test 3: Token Bucket
# ============================================
echo -e "${YELLOW}Test Suite 3: Token Bucket${NC}"
echo "  Config: capacity=3, refill_rate=1/sec"

KEY="${TEST_PREFIX}:tb:test1"
CAPACITY=3
REFILL_RATE=1
NOW=1000000

# Consume all tokens
for i in $(seq 1 $CAPACITY); do
    result=$($RCLI EVAL "$TOKEN_BUCKET_LUA" 1 "$KEY" "$CAPACITY" "$REFILL_RATE" "$NOW" 2>/dev/null)
    assert_eq "Token $i should be granted" "1" "$result"
done

# Next should be rejected (no tokens left)
result=$($RCLI EVAL "$TOKEN_BUCKET_LUA" 1 "$KEY" "$CAPACITY" "$REFILL_RATE" "$NOW" 2>/dev/null)
assert_eq "Request with 0 tokens should be rejected" "0" "$result"

# Advance time by 2 seconds → 2 tokens refilled
NOW=$((NOW + 2))
result=$($RCLI EVAL "$TOKEN_BUCKET_LUA" 1 "$KEY" "$CAPACITY" "$REFILL_RATE" "$NOW" 2>/dev/null)
assert_eq "After 2s refill, request should be allowed" "1" "$result"

result=$($RCLI EVAL "$TOKEN_BUCKET_LUA" 1 "$KEY" "$CAPACITY" "$REFILL_RATE" "$NOW" 2>/dev/null)
assert_eq "Second request after refill should be allowed" "1" "$result"

result=$($RCLI EVAL "$TOKEN_BUCKET_LUA" 1 "$KEY" "$CAPACITY" "$REFILL_RATE" "$NOW" 2>/dev/null)
assert_eq "Third request should be rejected (only 2 refilled)" "0" "$result"

echo ""

# ============================================
# Test 4: Token Bucket — Capacity Cap
# ============================================
echo -e "${YELLOW}Test Suite 4: Token Bucket — Capacity Cap${NC}"

KEY="${TEST_PREFIX}:tb:test2"
CAPACITY=5
REFILL_RATE=10
NOW=2000000

# Initial request (full capacity)
result=$($RCLI EVAL "$TOKEN_BUCKET_LUA" 1 "$KEY" "$CAPACITY" "$REFILL_RATE" "$NOW" 2>/dev/null)
assert_eq "Initial request allowed" "1" "$result"

# Advance time by 100s → would refill 1000 tokens, but capped at 5
NOW=$((NOW + 100))

for i in $(seq 1 $CAPACITY); do
    result=$($RCLI EVAL "$TOKEN_BUCKET_LUA" 1 "$KEY" "$CAPACITY" "$REFILL_RATE" "$NOW" 2>/dev/null)
    assert_eq "Request $i after long wait should be allowed" "1" "$result"
done

result=$($RCLI EVAL "$TOKEN_BUCKET_LUA" 1 "$KEY" "$CAPACITY" "$REFILL_RATE" "$NOW" 2>/dev/null)
assert_eq "Request after capacity exhausted should be rejected" "0" "$result"

echo ""

# ============================================
# Test 5: Sliding Window Counter
# ============================================
echo -e "${YELLOW}Test Suite 5: Sliding Window Counter${NC}"
echo "  Config: limit=5, window=60s"

LIMIT=5
WINDOW=60
NOW=3000060  # Align to window boundary for predictable behavior

CUR_KEY="${TEST_PREFIX}:sw:cur"
PREV_KEY="${TEST_PREFIX}:sw:prev"

# Send requests up to the limit
for i in $(seq 1 $LIMIT); do
    result=$($RCLI EVAL "$SLIDING_WINDOW_LUA" 2 "$CUR_KEY" "$PREV_KEY" "$LIMIT" "$WINDOW" "$NOW" 2>/dev/null)
    assert_eq "Sliding window request $i should be allowed" "1" "$result"
done

# Next should be rejected
result=$($RCLI EVAL "$SLIDING_WINDOW_LUA" 2 "$CUR_KEY" "$PREV_KEY" "$LIMIT" "$WINDOW" "$NOW" 2>/dev/null)
assert_eq "Sliding window request $((LIMIT + 1)) should be rejected" "0" "$result"

echo ""

# ============================================
# Test 6: Sliding Window — Previous Window Weight
# ============================================
echo -e "${YELLOW}Test Suite 6: Sliding Window — Weighted Previous Window${NC}"
echo "  Testing that previous window counter influences current decision"

CUR_KEY2="${TEST_PREFIX}:sw:cur2"
PREV_KEY2="${TEST_PREFIX}:sw:prev2"
LIMIT=10
WINDOW=60

# Simulate previous window had 8 requests
$RCLI SET "$PREV_KEY2" "8" >/dev/null 2>&1
$RCLI EXPIRE "$PREV_KEY2" 120 >/dev/null 2>&1

# At the start of a new window (elapsed=0), weight=1.0
# effective = 8 * 1.0 + 0 = 8, under limit of 10
NOW=3060000  # Aligned to window boundary

result=$($RCLI EVAL "$SLIDING_WINDOW_LUA" 2 "$CUR_KEY2" "$PREV_KEY2" "$LIMIT" "$WINDOW" "$NOW" 2>/dev/null)
assert_eq "With prev=8, weight=1.0, should allow (eff=8)" "1" "$result"

result=$($RCLI EVAL "$SLIDING_WINDOW_LUA" 2 "$CUR_KEY2" "$PREV_KEY2" "$LIMIT" "$WINDOW" "$NOW" 2>/dev/null)
assert_eq "With prev=8, cur=1, should allow (eff=9)" "1" "$result"

echo ""

# ============================================
# Summary
# ============================================
echo "============================================"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo -e "  Results: ${GREEN}${PASS_COUNT} passed${NC}, ${RED}${FAIL_COUNT} failed${NC}, ${TOTAL} total"
echo "============================================"

# Cleanup
if [[ "$CLEANUP" == true ]]; then
    echo ""
    echo -n "Cleaning up test keys... "
    $RCLI KEYS "${TEST_PREFIX}:*" 2>/dev/null | xargs -r $RCLI DEL 2>/dev/null || true
    echo "done."
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
