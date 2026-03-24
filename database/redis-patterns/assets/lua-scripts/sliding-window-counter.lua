-- =============================================================================
-- sliding-window-counter.lua — Fixed + Sliding Window Hybrid Counter
-- =============================================================================
-- Combines fixed window counters with weighted interpolation for a smooth
-- sliding window effect. More memory-efficient than sorted set approach.
--
-- Uses two fixed windows (current + previous) and interpolates based on
-- how far into the current window we are.
--
-- KEYS[1] = counter key prefix (e.g., "counter:api:endpoint")
-- ARGV[1] = max count allowed in window
-- ARGV[2] = window size in seconds
-- ARGV[3] = current timestamp (Unix seconds)
--
-- Returns: { allowed (0/1), current_count, remaining }
--
-- Usage:
--   EVAL "..." 1 counter:api:/users 1000 60 1700000000
--
-- How it works:
--   Window W=60s, current time=1700000045 (45s into current window)
--   Current window:  counter:api:/users:28333333  (window_id = floor(ts/W))
--   Previous window: counter:api:/users:28333332
--   Weight = 1 - (45/60) = 0.25 (25% of previous window counts)
--   Estimated count = prev_count * 0.25 + current_count
-- =============================================================================

local prefix = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

-- Calculate window identifiers
local current_window = math.floor(now / window)
local previous_window = current_window - 1

-- Keys for current and previous windows
local current_key = prefix .. ':' .. tostring(current_window)
local previous_key = prefix .. ':' .. tostring(previous_window)

-- Get counts
local current_count = tonumber(redis.call('GET', current_key) or 0)
local previous_count = tonumber(redis.call('GET', previous_key) or 0)

-- Calculate position within current window (0.0 to 1.0)
local position = (now % window) / window

-- Weighted estimate: more weight on previous window early in current window
local weight = 1 - position
local estimated = previous_count * weight + current_count

if estimated >= limit then
    -- Rate limited
    local remaining = math.max(0, math.floor(limit - estimated))
    return {0, math.floor(estimated), remaining}
end

-- Allowed — increment current window counter
redis.call('INCR', current_key)
-- Set expiry on current window (2x window to cover overlap)
redis.call('EXPIRE', current_key, window * 2 + 1)

local remaining = math.max(0, math.floor(limit - estimated - 1))
return {1, math.floor(estimated + 1), remaining}
