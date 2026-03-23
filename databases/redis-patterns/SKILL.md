---
name: redis-patterns
description:
  positive: "Use when user implements Redis caching, asks about Redis data structures (strings, hashes, sets, sorted sets, streams, HyperLogLog), pub/sub, Lua scripting, distributed locks, rate limiting, or Redis cluster/sentinel."
  negative: "Do NOT use for Memcached, general database design, PostgreSQL/MySQL, or application-level caching frameworks (unless Redis-backed)."
---

# Redis Data Structure Patterns

## Data Structure Selection Guide

Pick the narrowest type that fits the access pattern:

| Use Case | Type | Why |
|---|---|---|
| Simple value, counter, flag | String | `SET`, `INCR`, `DECR` — O(1) |
| Object with fields (user profile) | Hash | Partial read/write with `HGET`/`HSET` — less overhead than JSON strings |
| Queue, stack, recent items | List | `LPUSH`/`RPOP` for FIFO; `LRANGE` for bounded lists |
| Unique membership, tags | Set | `SADD`, `SISMEMBER`, `SINTER` for intersections |
| Leaderboard, ranked feed, priority queue | Sorted Set | `ZADD`, `ZRANGEBYSCORE`, `ZRANK` — O(log N) |
| Unique visitor count (approx) | HyperLogLog | `PFADD`/`PFCOUNT` — 12 KB per key regardless of cardinality |
| Binary state tracking (daily active) | Bitmap | `SETBIT`/`BITCOUNT` — 1 bit per user |
| Event log, message queue | Stream | `XADD`/`XREADGROUP` — persistent, replayable |
| Geospatial queries | Geo | `GEOADD`/`GEOSEARCH` — backed by sorted set |

Rules:
- Store objects as Hashes, not serialized JSON Strings, when you need partial field access.
- Use Sorted Sets over Lists when you need ranked access or score-based filtering.
- Use HyperLogLog when exact counts are unnecessary and memory matters.

## Key Naming Conventions

Use colon-delimited, lowercase, hierarchical names:

```
{service}:{entity}:{id}:{attribute}
```

Examples:
```
cache:api:user:1001           # cached user object
session:abc123                # session data
rate:ip:10.0.0.1              # rate limit counter
lock:order:5678               # distributed lock
stream:events:payments        # event stream
```

Rules:
- Keep keys under 40 characters when practical.
- Never use spaces or mixed delimiters.
- Prefix by purpose (`cache:`, `session:`, `lock:`, `temp:`, `rate:`).
- Use hash tags for cluster slot co-location: `{user:1001}:cart`, `{user:1001}:prefs`.

## Caching Patterns

### Cache-Aside (Lazy Loading)

Most common pattern. Application manages cache explicitly.

```python
def get_user(user_id):
    data = redis.get(f"cache:user:{user_id}")
    if data:
        return deserialize(data)
    data = db.query("SELECT * FROM users WHERE id = %s", user_id)
    redis.setex(f"cache:user:{user_id}", 3600, serialize(data))
    return data
```

### Write-Through

Write to cache and database together. Guarantees cache freshness at cost of write latency.

```python
def update_user(user_id, fields):
    db.update("users", user_id, fields)
    redis.hset(f"cache:user:{user_id}", mapping=fields)
    redis.expire(f"cache:user:{user_id}", 3600)
```

### Write-Behind (Write-Back)

Write to Redis first; flush to database asynchronously via a background worker. Use Streams as a durable buffer:

```
XADD stream:db-writes * table users id 1001 op update payload '{"name":"Jo"}'
```

A consumer group processes the stream and writes to the database.

### Cache Stampede Prevention

Prevent thundering herd on cache miss:

1. **Singleflight with lock**: Only one caller regenerates; others wait.
```
SET cache:lock:user:1001 owner NX EX 5
# If acquired, regenerate and populate cache
# If not, poll or use stale value
```

2. **Jittered TTL**: Randomize expiry to prevent synchronized invalidation.
```python
ttl = base_ttl + random.randint(0, jitter_seconds)
redis.setex(key, ttl, value)
```

3. **Soft TTL / Background Refresh**: Store a logical expiry inside the value. Serve stale data while a background task refreshes.

## TTL Strategies and Eviction Policies

Set TTL on every cache key. Never rely on eviction alone.

```
SETEX cache:product:99 3600 '{"name":"Widget"}'
EXPIRE session:abc123 1800
```

### Eviction Policies (`maxmemory-policy`)

| Policy | Behavior | Use When |
|---|---|---|
| `allkeys-lru` | Evict least recently used across all keys | General cache workload |
| `allkeys-lfu` | Evict least frequently used | Popularity-skewed access |
| `volatile-lru` | LRU among keys with TTL only | Mix of cache + persistent keys |
| `volatile-ttl` | Evict keys nearest to expiry | Short-lived data priority |
| `noeviction` | Reject writes when full | Critical persistent data only |

Set `maxmemory` to ~75% of available RAM. Reserve headroom for replication buffers, AOF rewrites, and fragmentation.

## Distributed Locking

### SET NX EX Pattern (Single Instance)

```
SET lock:order:5678 <unique-token> NX EX 10
```

Release with Lua to ensure only the owner deletes:

```lua
-- KEYS[1] = lock key, ARGV[1] = owner token
if redis.call("GET", KEYS[1]) == ARGV[1] then
    return redis.call("DEL", KEYS[1])
end
return 0
```

### Redlock (Multi-Instance)

For stronger guarantees across N independent Redis nodes (typically 5):

1. Record start time.
2. Attempt `SET key token NX PX ttl` on all N nodes.
3. Lock acquired if majority (N/2+1) succeed within a validity window.
4. Effective TTL = initial TTL − elapsed acquisition time.
5. On failure or expiry, release on all nodes.

### Fencing Tokens

Attach a monotonically increasing token to each lock grant. Downstream systems reject operations with stale tokens. Critical when lock holders may outlive their TTL due to GC pauses or network delays.

### Lock Best Practices

- Use exponential backoff with jitter on retry.
- Set lock TTL longer than expected critical section duration.
- Always release locks in `finally` blocks.
- Never use `SETNX` + separate `EXPIRE` — use `SET key val NX EX` atomically.

## Rate Limiting Patterns

### Fixed Window Counter

```
INCR rate:ip:10.0.0.1:202507141530
EXPIRE rate:ip:10.0.0.1:202507141530 60
```

Simple but allows burst at window boundaries.

### Sliding Window Log (Sorted Set)

```lua
-- Lua script: atomic sliding window rate limiter
local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])

redis.call("ZREMRANGEBYSCORE", key, 0, now - window)
local count = redis.call("ZCARD", key)
if count < limit then
    redis.call("ZADD", key, now, now .. ":" .. math.random())
    redis.call("EXPIRE", key, window)
    return 1
end
return 0
```

### Token Bucket

Store token count and last refill timestamp in a Hash. Refill tokens on each request up to the bucket capacity. Implement atomically with Lua.

```lua
local key = KEYS[1]
local rate = tonumber(ARGV[1])       -- tokens per second
local capacity = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local tokens = tonumber(redis.call("HGET", key, "tokens") or capacity)
local last = tonumber(redis.call("HGET", key, "ts") or now)

local elapsed = now - last
tokens = math.min(capacity, tokens + elapsed * rate)

if tokens >= 1 then
    tokens = tokens - 1
    redis.call("HSET", key, "tokens", tokens, "ts", now)
    redis.call("EXPIRE", key, capacity / rate + 1)
    return 1
end
redis.call("HSET", key, "tokens", tokens, "ts", now)
return 0
```

## Pub/Sub vs Streams

| Aspect | Pub/Sub | Streams |
|---|---|---|
| Persistence | None — fire-and-forget | Stored until trimmed or deleted |
| Missed messages | Lost if subscriber offline | Replayable from any offset |
| Consumer groups | No | Yes — `XREADGROUP`, `XACK` |
| Delivery guarantee | At-most-once | At-least-once (with ACK) |
| Use case | Cache invalidation, real-time notifications | Event sourcing, task queues, audit logs |

Use Pub/Sub when:
- Subscribers are always connected.
- Message loss is acceptable (cache invalidation signals).

Use Streams when:
- Messages must survive consumer downtime.
- You need load-balanced processing across workers.
- You require delivery acknowledgment and replay.

## Redis Streams for Event Sourcing

### Producing Events

```
XADD stream:orders * event_type order_created order_id 5678 user_id 1001 total 49.99
```

### Consumer Groups

```
XGROUP CREATE stream:orders order-processors 0 MKSTREAM
XREADGROUP GROUP order-processors worker-1 COUNT 10 BLOCK 2000 STREAMS stream:orders >
XACK stream:orders order-processors <message-id>
```

### Handling Failed Messages

Claim stale messages from failed consumers:

```
XAUTOCLAIM stream:orders order-processors worker-2 60000 0
```

Inspect pending entries:

```
XPENDING stream:orders order-processors - + 10
```

Move poison messages to a dead-letter stream after N retries.

### Stream Trimming

Cap streams to prevent unbounded growth:

```
XADD stream:orders MAXLEN ~ 10000 * event_type order_created ...
XTRIM stream:orders MAXLEN ~ 10000
```

Use `~` for approximate trimming (more efficient).

## Lua Scripting for Atomic Operations

Use Lua when you need read-then-write atomicity that `MULTI/EXEC` cannot provide (MULTI cannot branch on intermediate results).

### Compare-and-Swap

```lua
-- KEYS[1] = key, ARGV[1] = expected, ARGV[2] = new_value
local current = redis.call("GET", KEYS[1])
if current == ARGV[1] then
    redis.call("SET", KEYS[1], ARGV[2])
    return 1
end
return 0
```

### Rules for Lua Scripts

- All keys accessed must be declared in `KEYS[]`. Required for cluster compatibility.
- Keep scripts short. Redis blocks all commands during execution.
- Use `EVALSHA` with `SCRIPT LOAD` to avoid retransmitting script text.
- Use `redis.log()` for debugging; remove in production.
- In cluster mode, all `KEYS[]` must hash to the same slot. Use hash tags: `{user:1001}:balance`.

## Pipelining and Transactions

### Pipelining

Batch commands to reduce round trips. No atomicity guarantee — commands execute independently.

```python
pipe = redis.pipeline(transaction=False)
for uid in user_ids:
    pipe.get(f"cache:user:{uid}")
results = pipe.execute()
```

### MULTI/EXEC Transactions

Atomic execution of a command block. No conditional logic — all commands execute or none do.

```
MULTI
DECRBY account:1001:balance 100
INCRBY account:1002:balance 100
EXEC
```

Use `WATCH` for optimistic locking:

```
WATCH account:1001:balance
val = GET account:1001:balance
MULTI
SET account:1001:balance <new_val>
EXEC
# Returns nil if key changed between WATCH and EXEC
```

Prefer Lua scripts over `WATCH`/`MULTI`/`EXEC` when you need conditional branching.

## Memory Optimization

### Encoding Awareness

Redis uses compact encodings for small structures:
- Hashes with ≤ `hash-max-ziplist-entries` (default 128) fields use ziplist encoding.
- Sets with ≤ `set-max-intset-entries` integer members use intset encoding.
- Sorted Sets with ≤ `zset-max-ziplist-entries` use ziplist.

Stay under these thresholds for memory savings. Check encoding:

```
OBJECT ENCODING mykey
DEBUG OBJECT mykey
```

### Memory Commands

```
MEMORY USAGE cache:user:1001
MEMORY DOCTOR
INFO memory
```

### Optimization Checklist

- Set TTL on all cache keys.
- Use Hashes for objects instead of serialized Strings.
- Compress large values (>1 KB) client-side before storing.
- Avoid storing values >100 KB — split into chunks or use external storage.
- Monitor fragmentation ratio: `INFO memory` → `mem_fragmentation_ratio`. Restart or use `MEMORY PURGE` if >1.5.
- Use `UNLINK` instead of `DEL` for large keys (non-blocking deletion).

## Cluster and Sentinel Patterns

### Redis Cluster

- 16,384 hash slots distributed across master nodes.
- Automatic sharding and failover.
- Multi-key operations require all keys in the same hash slot. Use hash tags: `{order:123}:items`, `{order:123}:total`.
- `MGET`/`MSET` work only for co-located keys.

Cluster deployment rules:
- Minimum 3 masters with 1 replica each (6 nodes).
- Monitor slot coverage. Missing slots mean unavailable key ranges.
- Handle `MOVED` and `ASK` redirections in client libraries.

### Redis Sentinel

- Monitors master/replica health and performs automatic failover.
- Use when you need HA without sharding.
- Minimum 3 Sentinel instances for quorum.
- Clients connect to Sentinel first, which returns the current master address.

Choose Sentinel for: single-shard HA.
Choose Cluster for: HA + horizontal scaling.

## Common Anti-Patterns

### Hot Keys

A single key receiving disproportionate traffic saturates one node/slot.

Mitigations:
- Shard the key: `counter:{shard_id}` → sum across shards on read.
- Cache hot reads client-side with short local TTL.
- Use read replicas for read-heavy hot keys.

### Large Values

Values >10 KB cause latency spikes and block other operations.

Mitigations:
- Compress before storing.
- Split into multiple keys or Hash fields.
- Move blobs to object storage; store only references in Redis.

### Missing TTLs

Keys without TTLs accumulate indefinitely, leading to OOM.

Fix: Set TTL on every non-permanent key. Use `volatile-lru` or `volatile-ttl` eviction as a safety net. Audit with:

```
redis-cli --bigkeys
redis-cli --memkeys
```

### Other Anti-Patterns

- **`KEYS *` in production**: Blocks the server. Use `SCAN` with `COUNT` instead.
- **Unbounded collections**: Always cap Lists (`LTRIM`), Streams (`MAXLEN`), Sorted Sets (`ZREMRANGEBYRANK`).
- **Separate `SETNX` + `EXPIRE`**: Not atomic. Use `SET key val NX EX seconds`.
- **Ignoring cluster slot alignment**: Multi-key Lua scripts fail across slots. Use hash tags.
- **Storing sessions without TTL**: Sessions pile up. Always `EXPIRE`.
- **Using Redis as primary database without persistence**: Enable AOF (`appendonly yes`) or RDB snapshots if data must survive restarts.

<!-- tested: pass -->
