-- sliding-window.lua — Redis Lua script for sliding window counter rate limiting
--
-- KEYS[1] = current window key (e.g., "rl:{user_id}:{current_window}")
-- KEYS[2] = previous window key (e.g., "rl:{user_id}:{previous_window}")
-- ARGV[1] = max requests per window
-- ARGV[2] = window size in seconds
-- ARGV[3] = current timestamp (seconds, float)
--
-- Returns JSON: {allowed: bool, remaining: int, retry_after: int}
--
-- Usage:
--   local now=$(date +%s)
--   local window=60
--   local curr_win=$((now / window))
--   local prev_win=$((curr_win - 1))
--   redis-cli EVAL "$(cat sliding-window.lua)" 2 \
--     "rl:user123:$curr_win" "rl:user123:$prev_win" 100 60 "$now"

local curr_key = KEYS[1]
local prev_key = KEYS[2]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

-- Calculate current window position
local curr_window_start = math.floor(now / window) * window
local elapsed_in_window = now - curr_window_start
local weight = 1 - (elapsed_in_window / window)  -- previous window's weight

-- Get counts from both windows
local curr_count = tonumber(redis.call('GET', curr_key) or "0")
local prev_count = tonumber(redis.call('GET', prev_key) or "0")

-- Weighted count: interpolate between previous and current windows
local weighted_count = math.floor(prev_count * weight + curr_count)

if weighted_count >= limit then
    -- Calculate retry_after: when enough previous-window weight decays
    local retry_after = math.ceil(elapsed_in_window + 1)
    return cjson.encode({
        allowed = false,
        remaining = 0,
        retry_after = retry_after
    })
end

-- Increment current window counter
local new_count = redis.call('INCR', curr_key)
if new_count == 1 then
    -- Set TTL to 2x window so previous window data persists
    redis.call('EXPIRE', curr_key, window * 2)
end

local remaining = math.max(0, limit - math.floor(prev_count * weight + new_count))

return cjson.encode({
    allowed = true,
    remaining = remaining,
    retry_after = 0
})
