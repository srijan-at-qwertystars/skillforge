-- token-bucket.lua — Redis Lua script for token bucket rate limiting
--
-- KEYS[1] = rate limit key (e.g., "rl:{user_id}")
-- ARGV[1] = bucket capacity (max tokens)
-- ARGV[2] = refill rate (tokens per second)
-- ARGV[3] = current timestamp (seconds, float)
-- ARGV[4] = cost per request (default 1)
--
-- Returns JSON: {allowed: bool, remaining: int, retry_after: float}
--
-- Usage:
--   redis-cli EVAL "$(cat token-bucket.lua)" 1 "rl:user123" 100 1.67 1719000000.123 1

local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4]) or 1

-- Fetch current bucket state
local data = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(data[1])
local last_refill = tonumber(data[2])

-- Initialize bucket on first use
if tokens == nil then
    tokens = capacity
    last_refill = now
end

-- Refill tokens based on elapsed time
local elapsed = math.max(0, now - last_refill)
tokens = math.min(capacity, tokens + elapsed * refill_rate)

-- Calculate TTL for key expiry (auto-cleanup idle keys)
local ttl = math.ceil(capacity / refill_rate) + 1

if tokens < cost then
    -- Insufficient tokens — reject and report when to retry
    redis.call('HSET', key, 'tokens', tokens, 'last_refill', now)
    redis.call('EXPIRE', key, ttl)
    local retry_after = (cost - tokens) / refill_rate
    return cjson.encode({
        allowed = false,
        remaining = 0,
        retry_after = math.ceil(retry_after)
    })
end

-- Deduct tokens and allow
tokens = tokens - cost
redis.call('HSET', key, 'tokens', tokens, 'last_refill', now)
redis.call('EXPIRE', key, ttl)

return cjson.encode({
    allowed = true,
    remaining = math.floor(tokens),
    retry_after = 0
})
