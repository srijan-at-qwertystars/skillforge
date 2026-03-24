-- =============================================================================
-- Sliding Window Rate Limiter (Lua script for Redis/Valkey)
-- =============================================================================
-- Implements a precise sliding window rate limiter using sorted sets.
--
-- KEYS[1] = rate limit key (e.g., "ratelimit:api:user:1001")
--
-- ARGV[1] = window size in seconds (e.g., 60)
-- ARGV[2] = maximum requests allowed in window (e.g., 100)
-- ARGV[3] = current timestamp in seconds (float, e.g., 1700000000.123)
-- ARGV[4] = unique request ID (e.g., UUID or timestamp-based)
--
-- Returns: { allowed (0|1), remaining, retry_after_seconds, total_in_window }
--   allowed:      1 if request is allowed, 0 if rate limited
--   remaining:    number of requests remaining in the window
--   retry_after:  seconds until the oldest entry expires (0 if allowed)
--   total:        total requests currently in the window
--
-- Usage (redis-cli):
--   EVALSHA <sha> 1 ratelimit:api:user:1001 60 100 1700000000.123 "req-uuid-1"
--
-- Usage (ioredis):
--   const [allowed, remaining, retryAfter, total] = await redis.evalsha(
--     sha, 1, "ratelimit:api:user:1001", 60, 100, Date.now()/1000, uuid()
--   );
--
-- Usage (redis-py):
--   allowed, remaining, retry_after, total = r.evalsha(
--       sha, 1, "ratelimit:api:user:1001", 60, 100, time.time(), str(uuid4())
--   )
-- =============================================================================

local key = KEYS[1]
local window = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local request_id = ARGV[4]

-- Remove entries outside the sliding window
local window_start = now - window
redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

-- Count current entries in window
local current_count = redis.call('ZCARD', key)

if current_count < limit then
    -- Under limit: add this request and allow
    redis.call('ZADD', key, now, request_id)
    -- Set key expiry to auto-cleanup (window + small buffer)
    redis.call('EXPIRE', key, window + 1)

    local remaining = limit - current_count - 1
    return {1, remaining, 0, current_count + 1}
else
    -- Over limit: calculate retry-after from oldest entry
    local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
    local retry_after = 0
    if #oldest >= 2 then
        retry_after = math.ceil((tonumber(oldest[2]) + window) - now)
        if retry_after < 0 then retry_after = 0 end
    end

    return {0, 0, retry_after, current_count}
end
