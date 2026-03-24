---
name: redis-patterns
description: >
  Production Redis patterns covering data structures, caching strategies, pub/sub, streams,
  transactions, Lua scripting, pipelining, distributed locks, rate limiting, session management,
  cluster sharding, Sentinel HA, persistence, and memory optimization. Use when user needs Redis
  caching, pub/sub, streams, distributed locks, session management, rate limiting with Redis,
  key design, or Redis cluster architecture. NOT for other caches like Memcached, NOT for message
  queues like RabbitMQ/Kafka unless comparing, NOT for relational database queries, NOT for
  general SQL or NoSQL document stores like MongoDB.
---

# Redis Patterns Reference

## Key Naming Conventions

Use colon-delimited hierarchical names. Keep keys short but descriptive.

```
# Pattern: <entity>:<id>:<field>
user:1001:profile
session:abc123
cache:api:/users/42
rate:ip:10.0.0.1
lock:order:7890
stream:events:signup
```

Rules:
- Lowercase, colon-separated namespaces
- Prefix with purpose (`cache:`, `lock:`, `rate:`, `queue:`)
- Never use spaces or newlines in keys
- Use `SCAN` (not `KEYS *`) in production to iterate keys

## Data Structures

### Strings
Counters, caching serialized objects, flags, short-lived values.

```redis
SET user:1001:name "Alice"            # simple value
INCR page:home:views                  # → 1 (atomic counter)
SETEX session:abc 3600 '{"uid":1}'    # expires in 1 hour
SETNX lock:resource "owner1"         # set-if-not-exists
MGET key1 key2 key3                   # batch read
```

### Hashes
Objects with fields. Memory-efficient via ziplist encoding under `hash-max-ziplist-entries`.

```redis
HSET user:1001 name "Bob" age 34 email "bob@x.com"
HGET user:1001 name                   # → "Bob"
HINCRBY user:1001 balance 100         # atomic field increment
```

Prefer hashes over serialized JSON when you need field-level reads/writes.

### Lists
Queues (FIFO), stacks (LIFO), activity feeds, bounded logs.

```redis
RPUSH queue:emails "msg1" "msg2"      # enqueue
BRPOP queue:emails 30                 # blocking dequeue, 30s timeout
LRANGE feed:user:1 0 9               # latest 10 items
LTRIM feed:user:1 0 99               # cap to 100 items
```

### Sets
Unique collections for tags, memberships, deduplication.

```redis
SADD post:1:tags "redis" "database" "cache"
SISMEMBER post:1:tags "redis"         # → 1 (true)
SINTER group:1:users group:2:users    # intersection
SCARD post:1:tags                     # count → 3
```

### Sorted Sets
Ordered by score. Leaderboards, priority queues, time-series indexes, sliding windows.

```redis
ZADD leaderboard 1500 "player:1" 2000 "player:2"
ZREVRANGE leaderboard 0 9 WITHSCORES           # top 10
ZINCRBY leaderboard 50 "player:1"               # bump score
ZRANGEBYSCORE leaderboard 1000 2000             # score range
ZREMRANGEBYSCORE events 0 1700000000            # prune old
```

### Streams
Append-only log with consumer groups for event sourcing, reliable messaging, audit trails.

```redis
XADD events * type signup user_id 42            # auto-ID
XADD events MAXLEN ~1000 * type login user_id 5 # capped stream
XRANGE events - + COUNT 10                      # first 10 entries
```

### HyperLogLog
Probabilistic cardinality (~0.81% error, 12KB/key). Unique visitor counts at scale.

```redis
PFADD unique:visitors "user1" "user2" "user3"
PFCOUNT unique:visitors                # → 3 (approx)
PFMERGE unique:total unique:day1 unique:day2
```

### Bitmaps
Bit-level ops. Feature flags, daily active users, presence tracking.

```redis
SETBIT user:logins:2024-01-15 1001 1  # user 1001 logged in
BITCOUNT user:logins:2024-01-15       # total logins that day
BITOP AND active_both day1 day2       # users active both days
```

### Geospatial
Geo indexing via sorted sets. Proximity searches, location features.

```redis
GEOADD places -122.4194 37.7749 "SF" -73.9857 40.7484 "NYC"
GEODIST places "SF" "NYC" km              # → "4129.0861"
GEOSEARCH places FROMMEMBER "SF" BYRADIUS 100 km ASC
```

## Caching Patterns

### Cache-Aside (Lazy Loading)
Default for read-heavy workloads. App checks cache → miss → query DB → populate cache.

```python
def get_user(user_id):
    cached = redis.get(f"cache:user:{user_id}")
    if cached: return json.loads(cached)
    user = db.query("SELECT * FROM users WHERE id = %s", user_id)
    redis.setex(f"cache:user:{user_id}", 300, json.dumps(user))
    return user

def update_user(user_id, data):
    db.update(user_id, data)
    redis.delete(f"cache:user:{user_id}")  # invalidate, don't update
```

### Write-Through / Write-Behind
- **Write-through**: write cache + DB synchronously. Strong consistency, higher write latency.
- **Write-behind**: write cache first, async drain to DB. High throughput, risk of data loss.

### TTL Strategies
- Short (30-300s): volatile data. Medium (5-60min): API responses. Long (hours+): config.
- Add jitter to prevent stampedes: `TTL + random(0, TTL * 0.1)`

### Cache Invalidation
- **Delete on write**: simplest, use with cache-aside
- **Tag-based**: prefix keys, `SCAN` + `UNLINK` to batch-delete
- **Event-driven**: publish invalidation via pub/sub or streams
- **Refresh-ahead**: proactively refresh hot keys before TTL expires

### Cache Stampede Prevention
Use lock-based fetch: `SET lock:{key} 1 NX EX 10`, first caller populates, others retry.

## Pub/Sub Messaging

Fire-and-forget broadcast. No persistence, no acknowledgement. Subscribers must be connected.

```redis
SUBSCRIBE channel:notifications       # consumer blocks
PUBLISH channel:notifications "hello"  # → delivers to all subscribers
PSUBSCRIBE channel:*                   # pattern subscribe
# Sharded Pub/Sub (Redis 7+) — routes to owning shard, reduces cross-node traffic:
SSUBSCRIBE channel:orders             # shard-aware subscribe
SPUBLISH channel:orders '{"id":1}'    # only hits relevant shard
```

Use for: real-time notifications, cache invalidation broadcasts, live dashboards.
Do NOT use for: reliable message delivery, event sourcing, job queues.

## Redis Streams (Reliable Messaging)

### Producer

```redis
XADD orders * product "widget" qty 5 user_id 42
# → "1700000000000-0" (auto-generated ID)
```

### Consumer Groups

```redis
XGROUP CREATE orders processing $ MKSTREAM     # create group
# Consumer reads undelivered messages:
XREADGROUP GROUP processing worker1 COUNT 10 BLOCK 2000 STREAMS orders >
# After processing, acknowledge:
XACK orders processing 1700000000000-0
```

### Dead Letter / Pending Recovery

```redis
XPENDING orders processing - + 10              # check pending
XCLAIM orders processing worker2 60000 1700000000000-0  # claim after 60s
XAUTOCLAIM orders processing worker2 60000 0-0 COUNT 10  # auto-claim
```

### Pub/Sub vs Streams Decision

| Need                    | Use Pub/Sub | Use Streams |
|-------------------------|-------------|-------------|
| Message persistence     | ✗           | ✓           |
| Consumer groups         | ✗           | ✓           |
| Message acknowledgement | ✗           | ✓           |
| Replay/history          | ✗           | ✓           |
| Low-latency fan-out     | ✓           | ○           |
| Simple broadcast        | ✓           | ○           |

## Transactions

### MULTI/EXEC
Queues commands, executes atomically (no interleaving). No rollback on runtime errors.

```redis
MULTI
DECRBY account:A 100
INCRBY account:B 100
EXEC
# → [OK, OK] both succeed or both queued
```

### WATCH (Optimistic Locking)
Abort transaction if watched key changes. Retry on conflict.

```redis
WATCH inventory:widget
val = GET inventory:widget      # read current value
MULTI
SET inventory:widget (val - 1)  # conditional update
EXEC
# → nil if another client modified inventory:widget
```

In Python, use `pipe.watch()` + `pipe.multi()` + `pipe.execute()`, catch `WatchError` to retry.

## Lua Scripting

Server-side atomic execution. No interleaving. Use for complex read-modify-write operations.

```redis
# Atomic compare-and-delete (safe unlock)
EVAL "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end" 1 lock:resource owner123
```

```redis
# Sliding window rate limiter
EVAL "
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
local count = redis.call('ZCARD', key)
if count < limit then
  redis.call('ZADD', key, now, now .. math.random())
  redis.call('EXPIRE', key, window)
  return 1
end
return 0
" 1 rate:user:42 100 60 1700000000
# → 1 (allowed) or 0 (rate limited)
```

### Redis Functions (Redis 7+)
Persistent server-side functions. Survive restarts, replicated to replicas.

```redis
FUNCTION LOAD "#!lua name=mylib\nredis.register_function('myfunc', function(keys, args) return redis.call('GET', keys[1]) end)"
FCALL myfunc 1 mykey
```

Prefer Functions over EVAL for reusable logic in Redis 7+.

## Pipelining

Batch commands to reduce network round-trips. No atomicity guarantee.

```python
pipe = redis.pipeline(transaction=False)  # pipelining, not transaction
for user_id in user_ids:
    pipe.hgetall(f"user:{user_id}")
results = pipe.execute()  # single round-trip for all commands
```

Expect 5-10x throughput improvement over sequential commands. Combine with MULTI for atomic batches.

## Session Store

Store sessions as JSON strings with `SETEX` + sliding expiration via `EXPIRE` on access.
Use hashes for sessions needing field-level access. Set `maxmemory-policy volatile-lru`
to auto-evict expired sessions under memory pressure.

```redis
SETEX session:abc123 3600 '{"user_id":1001,"created":1700000000}'
GET session:abc123           # read session
EXPIRE session:abc123 3600   # sliding expiration on access
DEL session:abc123           # destroy
```

## Rate Limiting

### Fixed Window

```python
def is_allowed(user_id, limit=100, window=60):
    key = f"rate:{user_id}:{int(time.time()) // window}"
    count = redis.incr(key)
    if count == 1:
        redis.expire(key, window)
    return count <= limit
```

### Sliding Window (Sorted Set)
Use ZADD with timestamp as score, ZREMRANGEBYSCORE to prune, ZCARD to count.
See `assets/lua-scripts/rate-limiter.lua` for atomic Lua implementation.

### Token Bucket (Lua)
Track tokens and last-refill timestamp in two keys. Refill based on elapsed time.
See `assets/lua-scripts/sliding-window-counter.lua` for hybrid counter approach.

## Distributed Locks

### Simple Lock (Single Instance)

```python
def acquire_lock(name, owner, ttl=10):
    return redis.set(f"lock:{name}", owner, nx=True, ex=ttl)

def release_lock(name, owner):
    # Atomic check-and-delete via Lua
    script = "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end"
    return redis.eval(script, 1, f"lock:{name}", owner)
```

### Redlock (Multi-Instance)
For fault-tolerant locking across N independent Redis nodes (typically 5):
1. Generate unique lock value (UUID)
2. Try `SET lock NX EX ttl` on each node with short timeout
3. Lock acquired if majority (N/2+1) succeed within validity time
4. Effective TTL = original TTL - acquisition time
5. Release on ALL nodes (even those that failed)

Use established libraries: Redisson (Java), node-redlock (Node.js), pottery (Python).

**Caution**: Redlock is NOT suitable for strict mutual exclusion with correctness guarantees. Layer with fencing tokens or DB constraints for safety-critical operations.

## Redis Cluster

- 16,384 hash slots distributed across master nodes
- Keys map to slots via `CRC16(key) % 16384`
- Use `{hashtag}` to colocate keys: `user:{1001}:profile` and `user:{1001}:settings` share slot
- Multi-key commands (MGET, transactions) require all keys in same slot
- Automatic failover: replicas promote when master fails

```redis
CLUSTER INFO                          # cluster state
CLUSTER SLOTS                         # slot→node mapping
CLUSTER KEYSLOT mykey                 # which slot for key
```

## Redis Sentinel (HA without Cluster)

Monitors master/replica sets, handles automatic failover for standalone Redis.

```
sentinel monitor mymaster 127.0.0.1 6379 2    # quorum=2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
```

Connect via Sentinel-aware clients that auto-discover the current master.

## Persistence

| Mode   | Mechanism                   | Durability        | Performance |
|--------|----------------------------|-------------------|-------------|
| RDB    | Point-in-time snapshots    | Minutes of loss   | Fast        |
| AOF    | Append every write         | Seconds of loss   | Slower      |
| Hybrid | RDB snapshot + AOF tail    | Best durability   | Balanced    |

```
# redis.conf
save 900 1          # RDB: snapshot if 1 key changed in 900s
save 300 10         # snapshot if 10 keys changed in 300s
appendonly yes      # enable AOF
appendfsync everysec  # fsync every second (recommended)
aof-use-rdb-preamble yes  # hybrid mode
```

## Memory Optimization

### Encoding Types
Redis auto-selects compact encodings for small data:
- Hashes < `hash-max-ziplist-entries` (128) → ziplist (memory efficient)
- Lists < `list-max-ziplist-size` → quicklist/listpack
- Sets of integers < `set-max-intset-entries` (512) → intset
- Sorted sets < `zset-max-ziplist-entries` (128) → listpack

Tune thresholds to match your data profile.

### Maxmemory Policies

```
maxmemory 4gb
maxmemory-policy allkeys-lru    # evict least recently used (any key)
# Other policies:
# volatile-lru     - LRU among keys with TTL
# allkeys-lfu      - least frequently used
# volatile-ttl     - evict shortest TTL first
# noeviction       - return errors on write (safest for critical data)
```

### Memory Tips
- Use hashes for small objects (ziplist encoding saves ~10x vs string keys)
- Set TTLs aggressively on cache keys
- Use `OBJECT ENCODING key` to verify compact encoding
- Use `MEMORY USAGE key` to check per-key memory
- Enable `activedefrag yes` for long-running instances
- Use `UNLINK` instead of `DEL` for async non-blocking deletion
- Avoid storing large values (>100KB); chunk or use external storage

## Additional Resources

### Reference Guides (`references/`)

Deep-dive documentation for advanced topics, troubleshooting, and performance:

- **`advanced-patterns.md`** — Redis modules (RediSearch, RedisJSON, RedisTimeSeries,
  RedisGraph, RedisBloom), Redis Functions (Redis 7+ replacement for EVAL), sharded
  pub/sub, client-side caching with RESP3, keyspace notifications, Redis as primary
  database patterns, event sourcing with streams, RESP3 protocol features.

- **`troubleshooting.md`** — Production debugging: SLOWLOG configuration and analysis,
  latency monitoring (LATENCY DOCTOR/LATEST/HISTORY), memory fragmentation diagnosis,
  big key and hot key detection, connection issues (maxclients, timeouts), replication
  lag and buffer overflow, cluster split-brain and slot migration, AOF rewrite failures,
  RDB fork issues, eviction policy behavior, full diagnostic command reference.

- **`performance-tuning.md`** — Performance optimization: pipelining vs MULTI/EXEC,
  connection pooling and multiplexing, memory optimization (listpack/intset thresholds,
  hash bucketing, bitmaps), maxmemory policy selection guide, persistence impact on
  latency, fork() overhead table, io-threads multi-threading (Redis 6+), TCP/network
  tuning, kernel tuning (vm.overcommit_memory, THP, file descriptors, CPU affinity),
  benchmarking methodology, production checklist.

### Executable Scripts (`scripts/`)

Production-ready diagnostic and analysis tools:

- **`redis-health-check.sh`** — Comprehensive health check: memory usage and fragmentation,
  connected clients vs maxclients, cache hit ratio, throughput stats, replication status
  with lag detection, persistence status, slow log entries, big keys scan. Usage:
  `./redis-health-check.sh [-h HOST] [-p PORT] [-a PASSWORD]`

- **`redis-benchmark-suite.sh`** — Benchmark suite: tests GET/SET/LPUSH/ZADD/streams,
  compares pipeline sizes (1/8/16/32/64), measures data size impact, reports throughput
  with pipeline speedup ratio. Usage:
  `./redis-benchmark-suite.sh [-h HOST] [-p PORT] [-n REQUESTS] [-c CLIENTS]`

- **`redis-key-analyzer.py`** — Key namespace analyzer (Python/redis-py): distribution
  by prefix, TTL analysis (with/without TTL counts, avg/min/max), memory usage per
  prefix with biggest key identification, idle time stats, encoding distribution.
  Production-safe SCAN-based. Usage:
  `./redis-key-analyzer.py [-H HOST] [-p PORT] [--prefix-depth 2] [--sample-size 100000]`

### Configuration Assets (`assets/`)

Copy-paste ready templates and setup guides:

- **`redis.conf`** — Production Redis 7+ configuration template with security (ACLs,
  renamed commands), persistence (hybrid AOF+RDB), memory management (eviction, defrag,
  lazy freeing), encoding thresholds, I/O threads, slow log, and latency monitoring.

- **`sentinel.conf`** — Redis Sentinel HA configuration with monitoring, failover tuning,
  notification scripts, and client connection examples (Python, Node.js).

- **`redis-cluster-setup.md`** — Step-by-step 6-node cluster deployment: architecture,
  per-node configuration, cluster creation command, verification, client configuration
  (Python/Node.js/Java), operations (failover, resharding, rebalancing), adding/removing
  nodes, monitoring, and troubleshooting.

- **`lua-scripts/`** — Atomic Lua scripts for common patterns:
  - `rate-limiter.lua` — Sliding window rate limiter using sorted sets
  - `sliding-window-counter.lua` — Fixed+sliding window hybrid (memory-efficient)
  - `distributed-lock.lua` — Safe lock with acquire/release/extend operations
