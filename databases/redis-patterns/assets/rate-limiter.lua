--[[
Sliding Window Rate Limiter — Lua script for Redis

Algorithm: Combines the current and previous fixed windows using a weighted
sliding window approach. More accurate than fixed windows, cheaper than
sorted-set-based sliding logs.

KEYS[1] = rate limit key (e.g., "ratelimit:{user_id}" or "ratelimit:{ip}")
ARGV[1] = max requests allowed in the window
ARGV[2] = window size in seconds
ARGV[3] = current timestamp (Unix epoch seconds, float OK)

Returns: {allowed (0 or 1), remaining requests, retry_after_seconds, current_count}
  - allowed: 1 if request is permitted, 0 if rate limited
  - remaining: how many requests remain in the current window
  - retry_after: seconds to wait before retrying (0 if allowed)
  - current_count: weighted request count in the sliding window

Usage:
  EVALSHA <sha> 1 ratelimit:user:1001 100 60 1705334400.5
  -- 100 requests per 60 seconds

Load with:
  redis-cli SCRIPT LOAD "$(cat rate-limiter.lua)"
--]]

local key = KEYS[1]
local max_requests = tonumber(ARGV[1])
local window_size = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

-- Calculate current and previous window boundaries
local current_window = math.floor(now / window_size) * window_size
local previous_window = current_window - window_size

-- Keys for current and previous windows
local current_key = key .. ":" .. current_window
local previous_key = key .. ":" .. previous_window

-- Get counts for both windows
local current_count = tonumber(redis.call('GET', current_key) or '0')
local previous_count = tonumber(redis.call('GET', previous_key) or '0')

-- Calculate weighted count using sliding window approximation
-- Weight of previous window = proportion of previous window still in our sliding range
local elapsed_in_current = now - current_window
local weight = math.max(0, (window_size - elapsed_in_current) / window_size)
local weighted_count = math.floor(previous_count * weight) + current_count

if weighted_count >= max_requests then
    -- Rate limited
    local retry_after = window_size - elapsed_in_current
    if retry_after <= 0 then retry_after = 1 end
    return {0, 0, math.ceil(retry_after), weighted_count}
end

-- Allowed: increment current window counter
local new_count = redis.call('INCR', current_key)

-- Set expiry on the current window key (2x window to cover sliding calculation)
redis.call('EXPIRE', current_key, window_size * 2)

-- Recalculate with the new count
local new_weighted = math.floor(previous_count * weight) + new_count
local remaining = math.max(0, max_requests - new_weighted)

return {1, remaining, 0, new_weighted}
