-- rate-limit.lua — Redis Lua scripts for atomic rate limiting.
-- Load these scripts via EVALSHA for production use.
--
-- Scripts included:
--   1. Token Bucket (with burst + configurable cost)
--   2. Sliding Window Counter (weighted previous + current window)
--   3. Fixed Window (simple atomic counter)
--   4. Sliding Window Log (sorted set timestamps)
--   5. Concurrent Request Limiter (in-flight tracking)

--------------------------------------------------------------------------------
-- 1. TOKEN BUCKET
--------------------------------------------------------------------------------
-- KEYS[1]: rate limit key (e.g., "rl:tb:user:123")
-- ARGV[1]: bucket capacity (max tokens)
-- ARGV[2]: refill rate (tokens per second)
-- ARGV[3]: current timestamp (seconds, float OK)
-- ARGV[4]: cost per request (default 1)
--
-- Returns: {allowed (0/1), remaining_tokens, retry_after_seconds}
--------------------------------------------------------------------------------

--[[
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4]) or 1

local data = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(data[1]) or capacity
local last_refill = tonumber(data[2]) or now

-- Refill tokens based on elapsed time
local elapsed = math.max(0, now - last_refill)
tokens = math.min(capacity, tokens + elapsed * refill_rate)

local allowed = 0
local retry_after = 0

if tokens >= cost then
    tokens = tokens - cost
    allowed = 1
else
    retry_after = math.ceil((cost - tokens) / refill_rate)
end

redis.call('HMSET', key, 'tokens', tokens, 'last_refill', now)
redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) * 2)

return {allowed, math.floor(tokens), retry_after}
--]]

--------------------------------------------------------------------------------
-- 2. SLIDING WINDOW COUNTER
--------------------------------------------------------------------------------
-- KEYS[1]: current window key (e.g., "rl:sw:user:123:1700000000")
-- KEYS[2]: previous window key (e.g., "rl:sw:user:123:1699999940")
-- ARGV[1]: request limit per window
-- ARGV[2]: window size in seconds
-- ARGV[3]: current timestamp (integer seconds)
-- ARGV[4]: cost per request (default 1)
--
-- Returns: {allowed (0/1), remaining, retry_after, reset_at}
--------------------------------------------------------------------------------

--[[
local key = KEYS[1]
local prev_key = KEYS[2]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4]) or 1

local window_start = now - (now % window)
local elapsed = now - window_start
local weight = (window - elapsed) / window

local prev_count = tonumber(redis.call('GET', prev_key) or '0')
local curr_count = tonumber(redis.call('GET', key) or '0')
local effective = prev_count * weight + curr_count

if effective + cost > limit then
    local retry_after = math.ceil(window - elapsed)
    return {0, math.max(0, math.floor(limit - effective)), retry_after, window_start + window}
end

redis.call('INCRBY', key, cost)
redis.call('EXPIRE', key, window * 2)

local new_effective = prev_count * weight + curr_count + cost
local remaining = math.max(0, math.floor(limit - new_effective))
return {1, remaining, 0, window_start + window}
--]]

--------------------------------------------------------------------------------
-- 3. FIXED WINDOW
--------------------------------------------------------------------------------
-- KEYS[1]: window key (e.g., "rl:fw:user:123:28333")
-- ARGV[1]: request limit
-- ARGV[2]: window size in seconds
-- ARGV[3]: cost per request (default 1)
--
-- Returns: {allowed (0/1), remaining, ttl_seconds}
--------------------------------------------------------------------------------

--[[
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local cost = tonumber(ARGV[3]) or 1

local current = tonumber(redis.call('GET', key) or '0')

if current + cost > limit then
    local ttl = redis.call('TTL', key)
    if ttl < 0 then ttl = window end
    return {0, math.max(0, limit - current), ttl}
end

local new_count = redis.call('INCRBY', key, cost)
if new_count == cost then
    redis.call('EXPIRE', key, window)
end

local ttl = redis.call('TTL', key)
if ttl < 0 then ttl = window end

return {1, math.max(0, limit - new_count), ttl}
--]]

--------------------------------------------------------------------------------
-- 4. SLIDING WINDOW LOG
--------------------------------------------------------------------------------
-- KEYS[1]: sorted set key (e.g., "rl:swl:user:123")
-- ARGV[1]: request limit
-- ARGV[2]: window size in seconds
-- ARGV[3]: current timestamp (seconds, float OK)
-- ARGV[4]: unique request ID (to avoid duplicate scores)
--
-- Returns: {allowed (0/1), current_count, retry_after}
--------------------------------------------------------------------------------

--[[
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local request_id = ARGV[4]

-- Remove entries outside the window
local window_start = now - window
redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)

-- Count current entries
local count = redis.call('ZCARD', key)

if count >= limit then
    -- Find the oldest entry to calculate retry_after
    local oldest = redis.call('ZRANGEBYSCORE', key, '-inf', '+inf', 'WITHSCORES', 'LIMIT', 0, 1)
    local retry_after = 0
    if #oldest >= 2 then
        local oldest_time = tonumber(oldest[2])
        retry_after = math.ceil((oldest_time + window) - now)
        if retry_after < 0 then retry_after = 0 end
    end
    return {0, count, retry_after}
end

-- Add the new request
redis.call('ZADD', key, now, now .. ':' .. request_id)
redis.call('EXPIRE', key, window + 1)

return {1, count + 1, 0}
--]]

--------------------------------------------------------------------------------
-- 5. CONCURRENT REQUEST LIMITER
--------------------------------------------------------------------------------
-- Limits the number of in-flight (concurrent) requests per client.
-- Uses a sorted set with TTL-based expiry for crash safety.
--
-- ACQUIRE:
-- KEYS[1]: sorted set key (e.g., "rl:conc:user:123")
-- ARGV[1]: max concurrent requests
-- ARGV[2]: current timestamp (seconds)
-- ARGV[3]: request TTL (max request duration in seconds)
-- ARGV[4]: unique request ID
--
-- Returns: {allowed (0/1), current_count}
--
-- RELEASE:
-- Call ZREM KEYS[1] ARGV[4] when the request completes.
--------------------------------------------------------------------------------

--[[
-- ACQUIRE
local key = KEYS[1]
local max_concurrent = tonumber(ARGV[1])
local now = tonumber(ARGV[2])
local request_ttl = tonumber(ARGV[3])
local request_id = ARGV[4]

-- Remove expired entries (requests that timed out without release)
redis.call('ZREMRANGEBYSCORE', key, '-inf', now - request_ttl)

-- Count active requests
local active = redis.call('ZCARD', key)

if active >= max_concurrent then
    return {0, active}
end

-- Add this request with its start time as score
redis.call('ZADD', key, now, request_id)
redis.call('EXPIRE', key, request_ttl * 2)

return {1, active + 1}
--]]

--[[
-- RELEASE (simple, no Lua needed — use direct command)
-- redis.call('ZREM', KEYS[1], ARGV[1])
--]]

--------------------------------------------------------------------------------
-- USAGE NOTES
-- 
-- Loading scripts with EVALSHA:
--   1. Use SCRIPT LOAD to load each script block and get its SHA1 hash
--   2. Use EVALSHA with the hash for subsequent calls (avoids re-parsing)
--   3. Handle NOSCRIPT errors by falling back to EVAL
--
-- Example (Node.js with ioredis):
--   const sha = await redis.scriptLoad(TOKEN_BUCKET_SCRIPT);
--   const result = await redis.evalsha(sha, 1, key, capacity, rate, now, cost);
--
-- Key naming conventions:
--   rl:tb:{identifier}          — Token bucket
--   rl:sw:{identifier}:{window} — Sliding window counter
--   rl:fw:{identifier}:{window} — Fixed window
--   rl:swl:{identifier}         — Sliding window log
--   rl:conc:{identifier}        — Concurrent request limiter
--
-- All scripts are idempotent regarding key creation and safe to retry.
-- All scripts set EXPIRE on keys to prevent unbounded memory growth.
--------------------------------------------------------------------------------
