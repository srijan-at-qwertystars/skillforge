-- =============================================================================
-- distributed-lock.lua — Safe Distributed Lock Operations
-- =============================================================================
-- Provides atomic lock acquire, release, and extend operations.
-- Uses owner tokens to prevent accidental release by wrong clients.
--
-- Operation is determined by ARGV[1]:
--   "acquire" — Try to acquire the lock
--   "release" — Release the lock (only if owned)
--   "extend"  — Extend lock TTL (only if owned)
--
-- =============================================================================

local key = KEYS[1]
local operation = ARGV[1]

-- =============================================================================
-- ACQUIRE: SET key owner NX EX ttl
-- =============================================================================
-- KEYS[1] = lock key (e.g., "lock:order:42")
-- ARGV[1] = "acquire"
-- ARGV[2] = owner token (UUID or unique identifier)
-- ARGV[3] = TTL in seconds
--
-- Returns: 1 if acquired, 0 if lock is held by another owner
-- =============================================================================
if operation == "acquire" then
    local owner = ARGV[2]
    local ttl = tonumber(ARGV[3])

    -- Try to set the lock
    local result = redis.call('SET', key, owner, 'NX', 'EX', ttl)
    if result then
        return 1  -- lock acquired
    end

    -- Check if we already own it (idempotent acquire)
    local current_owner = redis.call('GET', key)
    if current_owner == owner then
        -- Refresh TTL for our own lock
        redis.call('EXPIRE', key, ttl)
        return 1  -- already owned by us
    end

    return 0  -- lock held by another owner

-- =============================================================================
-- RELEASE: Delete key only if owned by caller
-- =============================================================================
-- KEYS[1] = lock key
-- ARGV[1] = "release"
-- ARGV[2] = owner token
--
-- Returns: 1 if released, 0 if not owned or not found
-- =============================================================================
elseif operation == "release" then
    local owner = ARGV[2]

    local current_owner = redis.call('GET', key)
    if current_owner == owner then
        redis.call('DEL', key)
        return 1  -- released
    end
    return 0  -- not owned by caller (or expired)

-- =============================================================================
-- EXTEND: Refresh TTL only if owned
-- =============================================================================
-- KEYS[1] = lock key
-- ARGV[1] = "extend"
-- ARGV[2] = owner token
-- ARGV[3] = new TTL in seconds
--
-- Returns: 1 if extended, 0 if not owned or not found
-- =============================================================================
elseif operation == "extend" then
    local owner = ARGV[2]
    local ttl = tonumber(ARGV[3])

    local current_owner = redis.call('GET', key)
    if current_owner == owner then
        redis.call('EXPIRE', key, ttl)
        return 1  -- extended
    end
    return 0  -- not owned or expired

else
    return redis.error_reply("ERR unknown operation: " .. tostring(operation) ..
        ". Use 'acquire', 'release', or 'extend'")
end

-- =============================================================================
-- Usage Examples:
-- =============================================================================
--
-- Acquire a lock:
--   EVAL "..." 1 lock:order:42 acquire "owner-uuid-abc123" 30
--
-- Release a lock:
--   EVAL "..." 1 lock:order:42 release "owner-uuid-abc123"
--
-- Extend a lock:
--   EVAL "..." 1 lock:order:42 extend "owner-uuid-abc123" 30
--
-- Python example:
--   import redis, uuid
--   r = redis.Redis()
--   script = r.register_script(open('distributed-lock.lua').read())
--
--   owner = str(uuid.uuid4())
--   acquired = script(keys=['lock:order:42'], args=['acquire', owner, 30])
--   if acquired:
--       try:
--           # do work...
--           pass
--       finally:
--           script(keys=['lock:order:42'], args=['release', owner])
--
-- Redis Functions (Redis 7+):
--   #!lua name=locklib
--   redis.register_function('lock_acquire', function(keys, args)
--       -- same logic with keys[1], args[1]=owner, args[2]=ttl
--   end)
-- =============================================================================
