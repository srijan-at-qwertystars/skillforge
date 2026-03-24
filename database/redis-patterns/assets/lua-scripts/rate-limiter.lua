-- =============================================================================
-- rate-limiter.lua — Sliding Window Rate Limiter
-- =============================================================================
-- Atomic sliding window rate limiter using sorted sets.
-- Each request is recorded with its timestamp as both score and member.
-- Old entries outside the window are pruned on each call.
--
-- KEYS[1] = rate limit key (e.g., "rate:user:42")
-- ARGV[1] = max requests allowed in window
-- ARGV[2] = window size in seconds
-- ARGV[3] = current timestamp (Unix seconds, can be fractional)
--
-- Returns: 1 if allowed, 0 if rate limited
--
-- Usage:
--   EVALSHA <sha> 1 rate:user:42 100 60 1700000000.123
--   FCALL rate_limit 1 rate:user:42 100 60 1700000000.123
--
-- Redis Functions version (Redis 7+):
--   Load this file as part of a function library, or use EVAL directly.
-- =============================================================================

local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

-- Remove entries outside the sliding window
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)

-- Count remaining entries
local current = redis.call('ZCARD', key)

if current < limit then
    -- Add new entry with unique member (timestamp + random suffix)
    local member = tostring(now) .. ':' .. tostring(math.random(1, 1000000))
    redis.call('ZADD', key, now, member)
    -- Set key expiry slightly beyond window to auto-cleanup
    redis.call('EXPIRE', key, math.ceil(window) + 1)
    return 1  -- allowed
end

return 0  -- rate limited
