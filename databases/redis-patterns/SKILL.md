---
name: redis-patterns
description: |
  USE when writing code that uses Redis (the original Redis Ltd / Redis Community Edition, NOT Valkey fork), configuring Redis servers, designing caching layers, implementing pub/sub or streams, building rate limiters, distributed locks, session stores, leaderboards, or any Redis data structure usage. TRIGGER on imports of ioredis, redis, redis-py, go-redis, Jedis, Lettuce, or redis-cli commands. TRIGGER on mentions of Redis Cluster, Sentinel, RDB, AOF, ZADD, XADD, Lua scripting with EVAL, or Redis Stack modules (RedisJSON, RediSearch, RedisTimeSeries). DO NOT trigger for Valkey-specific forks, Memcached, DynamoDB, or general database design unrelated to Redis.
---

# Redis Patterns — Production Reference

## Architecture Fundamentals

Redis is single-threaded for command execution (event loop). All commands are atomic. Since Redis 6, I/O threading handles network reads/writes on multiple threads, but command execution remains single-threaded. Redis 7.x continues this model.

- **In-memory**: All data lives in RAM. Persistence is async to disk.
- **Single-threaded execution**: No lock contention. One command completes before the next starts.
- **Persistence**: RDB snapshots, AOF log, or hybrid (both). See Persistence section.
- **Replication**: Async primary→replica. Replicas are read-only by default.
- **Eviction**: When `maxmemory` is hit, eviction policy decides what to remove.

## Data Structures and Core Commands

### Strings
Binary-safe. Max 512MB. Use for counters, flags, serialized objects, cached responses.

```redis
SET user:1001:name "Alice" EX 3600    -- set with 1h expiry
GET user:1001:name                     -- "Alice"
MSET k1 "v1" k2 "v2" k3 "v3"         -- atomic multi-set
MGET k1 k2 k3                         -- ["v1", "v2", "v3"]
INCR page:views:home                   -- atomically increment; returns new value
INCRBY cart:total 2500                 -- increment by amount
SETNX lock:order:42 "owner-uuid"       -- set only if not exists; returns 1 or 0
SET lock:order:42 "uuid" NX EX 30      -- combined NX + expiry for locks
```

### Lists
Doubly linked list. O(1) push/pop at ends. Use for queues, recent-items, feeds.

```redis
LPUSH queue:emails "msg1" "msg2"       -- push left; returns new length
RPOP queue:emails                      -- pop right; "msg1" (FIFO)
BRPOP queue:emails 5                   -- blocking pop, 5s timeout
LRANGE recent:posts 0 9               -- get first 10 items
LTRIM recent:posts 0 99               -- keep only first 100
LLEN queue:emails                      -- length of list
```

### Sets
Unordered, unique members. Use for tags, unique visitors, membership checks.

```redis
SADD tags:article:55 "redis" "cache" "db"
SMEMBERS tags:article:55               -- {"redis", "cache", "db"}
SISMEMBER tags:article:55 "redis"      -- 1 (true)
SINTER tags:article:55 tags:article:72 -- intersection
SCARD tags:article:55                  -- 3 (cardinality)
SRANDMEMBER tags:article:55 2          -- 2 random members
```

### Sorted Sets
Ordered by score. Use for leaderboards, priority queues, time-indexed data.

```redis
ZADD leaderboard 1500 "alice" 1200 "bob" 1800 "carol"
ZRANGE leaderboard 0 -1 WITHSCORES    -- all, ascending by score
ZREVRANGE leaderboard 0 2 WITHSCORES  -- top 3, descending
ZRANK leaderboard "alice"              -- 0-based rank (ascending)
ZINCRBY leaderboard 100 "bob"          -- increment score; returns new score
ZRANGEBYSCORE leaderboard 1000 2000    -- members with score in range
ZREMRANGEBYRANK leaderboard 0 -4       -- keep only top 3
```

### Hashes
Field-value pairs under one key. Use for objects, user profiles, configs.

```redis
HSET user:1001 name "Alice" email "a@b.com" age 30
HGET user:1001 name                    -- "Alice"
HMGET user:1001 name email             -- ["Alice", "a@b.com"]
HGETALL user:1001                      -- {name: "Alice", email: "a@b.com", age: "30"}
HINCRBY user:1001 age 1               -- 31
HDEL user:1001 email                   -- remove field
HEXPIRE user:1001 3600 FIELDS 1 email  -- Redis 7.4+: per-field expiry
```

### Streams
Append-only log with consumer groups. Use for event sourcing, message queues, activity feeds.

```redis
XADD events * user_id 1001 action "login" ip "10.0.0.1"
-- returns "1234567890123-0" (auto-generated ID)
XLEN events                            -- number of entries
XRANGE events - + COUNT 10            -- first 10 entries
XREAD COUNT 5 BLOCK 2000 STREAMS events $  -- read new entries, block 2s
```

### HyperLogLog
Probabilistic cardinality estimation. ~0.81% error. 12KB per key max.

```redis
PFADD unique:visitors:2024-01 "user1" "user2" "user3"
PFCOUNT unique:visitors:2024-01        -- ~3
PFMERGE unique:visitors:q1 unique:visitors:2024-01 unique:visitors:2024-02
```

### Bitmaps
Bit-level operations on strings. Use for feature flags, daily active users.
```redis
SETBIT active:2024-01-15 1001 1        -- mark user 1001 active
GETBIT active:2024-01-15 1001          -- 1
BITCOUNT active:2024-01-15             -- count of set bits
BITOP AND active:both day1 day2        -- users active both days
```

### Geospatial
Longitude/latitude indexing built on sorted sets.
```redis
GEOADD stores -73.935242 40.730610 "nyc" -118.243685 34.052234 "la"
GEODIST stores "nyc" "la" km           -- distance in km
GEOSEARCH stores FROMLONLAT -73.9 40.7 BYRADIUS 50 km ASC COUNT 5
```

## Key Patterns

### Naming Convention
Use colon-separated namespaces: `{entity}:{id}:{field}`. Examples:
- `user:1001:profile`
- `session:abc123`
- `cache:api:/users?page=2`
- `rate:ip:10.0.0.1:minute`

### Expiration and TTL
```redis
EXPIRE key 300                         -- expire in 5 min
PEXPIRE key 1500                       -- expire in 1500ms
TTL key                                -- seconds remaining (-1 = no expiry, -2 = gone)
PERSIST key                            -- remove expiry
EXPIREAT key 1735689600                -- expire at Unix timestamp
```

### Key Scanning
Never use `KEYS *` in production — it blocks. Use `SCAN` instead:
```redis
SCAN 0 MATCH "user:*" COUNT 100       -- returns [cursor, [keys]]
-- repeat with returned cursor until cursor is "0"
HSCAN user:1001 0 MATCH "addr*" COUNT 10
SSCAN myset 0 MATCH "prefix*" COUNT 50
```

## Pub/Sub

Fire-and-forget messaging. No persistence, no replay. Use Streams if durability needed.

```redis
SUBSCRIBE chat:room:42                 -- blocks, receives messages
PUBLISH chat:room:42 "hello world"     -- returns number of subscribers who received
PSUBSCRIBE chat:room:*                 -- pattern subscribe
UNSUBSCRIBE chat:room:42
```

Pub/Sub clients cannot run other commands while subscribed. Use a dedicated connection.

## Streams — Consumer Groups

Durable, replayable message processing with consumer groups:
```redis
XGROUP CREATE events mygroup 0 MKSTREAM          -- create consumer group
XREADGROUP GROUP mygroup consumer1 COUNT 10 BLOCK 5000 STREAMS events >  -- read
XACK events mygroup "1234567890123-0"             -- acknowledge
XPENDING events mygroup - + 10                    -- check pending
XCLAIM events mygroup consumer2 60000 "1234567890123-0"  -- claim stale
XAUTOCLAIM events mygroup consumer2 60000 0-0 COUNT 10   -- auto-claim (6.2+)
XTRIM events MAXLEN ~ 10000                       -- trim to ~10K entries
```

Pattern: Use `>` to read only new messages. Use specific IDs to re-read pending messages.

## Transactions and Scripting

### MULTI/EXEC
Batch commands atomically. No rollback — all execute or none (on EXEC failure).

```redis
MULTI
SET user:1001:balance 500
INCR user:1001:tx_count
EXEC  -- returns [OK, 5]
```

### WATCH (Optimistic Locking)
```redis
WATCH user:1001:balance
val = GET user:1001:balance
MULTI
SET user:1001:balance (val - 100)
EXEC  -- returns nil if key changed between WATCH and EXEC
```

### Lua Scripting
Atomic execution, access to multiple keys, conditional logic.

```redis
-- Atomic compare-and-delete (for lock release)
EVAL "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end" 1 lock:order:42 "owner-uuid"

-- Cache with EVALSHA for performance: first load script
SCRIPT LOAD "return redis.call('get',KEYS[1])"  -- returns SHA
EVALSHA <sha> 1 mykey                            -- execute by SHA
```

Use `redis.call()` (propagates errors) vs `redis.pcall()` (catches errors). All Lua scripts are atomic — no other command runs while a script executes.

## Pipelining and Batching

Pipeline sends multiple commands without waiting for each response. Reduces round-trips.

```python
# Python (redis-py)
pipe = r.pipeline(transaction=False)
for i in range(1000):
    pipe.set(f"key:{i}", f"value:{i}")
pipe.execute()  # one round-trip for 1000 commands
```

```javascript
// Node.js (ioredis)
const pipeline = redis.pipeline();
for (let i = 0; i < 1000; i++) {
  pipeline.set(`key:${i}`, `value:${i}`);
}
await pipeline.exec();
```

Pipeline is NOT atomic unless wrapped in MULTI/EXEC. Use `pipeline(transaction=True)` in redis-py for atomic pipelines.

## Client Libraries

| Language   | Library         | Notes                                    |
|------------|-----------------|------------------------------------------|
| Node.js    | ioredis         | Cluster-aware, Lua scripting, pipelining |
| Node.js    | redis (node-redis) | Official, redesigned in v4+           |
| Python     | redis-py        | Async support via `redis.asyncio`        |
| Go         | go-redis/v9     | Context-aware, pipelining, Cluster       |
| Java       | Jedis           | Simple, thread-safe with pooling         |
| Java       | Lettuce         | Async/reactive, Netty-based, Cluster     |
| Rust       | fred / redis-rs | Cluster, pipelining                      |

Always configure: connection pooling, reconnect with backoff, read/write timeouts, and Cluster mode if applicable.

## Caching Patterns

### Cache-Aside (Lazy Loading)
```
1. Check cache: GET cache:user:1001
2. Cache miss → query database
3. Write to cache: SET cache:user:1001 <data> EX 300
4. Return data
```
Pros: only caches what is requested. Cons: first request always misses; stale data risk.

### Write-Through
Write to cache AND database on every write. Guarantees consistency at cost of write latency.

### Write-Behind (Write-Back)
Write to cache immediately, async flush to database. Higher throughput, risk of data loss on crash.

### Cache Invalidation
- **TTL-based**: Set expiry on all cache keys. Simple, eventual consistency.
- **Event-driven**: Publish invalidation events on write. Use Pub/Sub or Streams.
- **Tag-based**: Track cache keys by tag set, invalidate all keys in a tag.

Anti-pattern: Never cache without TTL. Unbounded caches cause OOM. See [`assets/cache-patterns.py`](assets/cache-patterns.py) for implementations.

## Rate Limiting

### Fixed Window
```redis
INCR rate:ip:10.0.0.1:minute:202401151430
EXPIRE rate:ip:10.0.0.1:minute:202401151430 60
-- check: if value > 100, reject
```

### Sliding Window (Sorted Set)
```redis
ZADD rate:user:1001 1705334400.123 "req-uuid-1"
ZREMRANGEBYSCORE rate:user:1001 0 1705334340.123
ZCARD rate:user:1001  -- if > 100, reject
EXPIRE rate:user:1001 60
```

See [`assets/rate-limiter.lua`](assets/rate-limiter.lua) for a production sliding-window Lua implementation.

## Distributed Locks

### Simple Lock (SET NX EX)
```redis
-- Acquire: NX = only if not exists, EX = auto-expire
SET lock:resource:42 "uuid-owner-token" NX EX 30
-- returns OK if acquired, nil if held by someone else

-- Release: Lua script for atomic check-and-delete
EVAL "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end" 1 lock:resource:42 "uuid-owner-token"
```

Always: unique token per client, always set TTL, release with Lua (not plain DEL).

### Redlock (Multi-Instance)
For stronger guarantees across failures, use Redlock with 5 independent Redis masters:
1. Generate unique token. Record start time.
2. Try `SET lock NX EX` on all 5 instances sequentially with short timeout.
3. Lock acquired if majority (3+) succeed AND total time < TTL.
4. On failure or expiry, release lock on ALL instances.

Caveats: Redlock does NOT provide strict mutual exclusion under clock drift or long GC pauses. Use fencing tokens for critical paths. For strict coordination, consider ZooKeeper or etcd.

## Session Storage

```python
# Store session as hash with TTL
r.hset("session:abc123", mapping={
    "user_id": "1001",
    "role": "admin",
    "csrf_token": "xyz789"
})
r.expire("session:abc123", 1800)  # 30 min

# Retrieve
session = r.hgetall("session:abc123")

# Extend on activity (sliding expiration)
r.expire("session:abc123", 1800)
```

Use hash per session. Avoid storing large blobs — serialize selectively. Set TTL always.

## Redis Cluster

16,384 hash slots distributed across master nodes. Key slot = `CRC16(key) % 16384`.

- **Hash tags**: Force keys to same slot with `{tag}`. `user:{1001}:profile` and `user:{1001}:settings` share slot.
- **MOVED**: Permanent redirect — update client slot map. `(error) MOVED 3999 10.0.0.2:6379`
- **ASK**: Temporary redirect during migration — send `ASKING` then retry. Do NOT update slot map.
- **Multi-key commands**: Only work if all keys map to same slot. Use hash tags.
- **Resharding**: `redis-cli --cluster reshard <host>:<port>` moves slots between nodes live.

```redis
CLUSTER INFO          -- cluster state, slots assigned, known nodes
CLUSTER NODES         -- all nodes with slot ranges
CLUSTER KEYSLOT mykey -- which slot a key maps to
```

## Sentinel (High Availability)

Sentinel monitors Redis primaries, handles automatic failover, provides service discovery.

```
sentinel monitor mymaster 10.0.0.1 6379 2   -- quorum of 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000
```

Clients connect to Sentinel to discover current primary. Use Sentinel-aware client libraries. Sentinel does NOT shard — use Cluster for horizontal scaling.

## Persistence

### RDB (Snapshots)
Point-in-time snapshots via `BGSAVE`. Fast restarts, but data loss between snapshots.
```
save 900 1      -- snapshot if 1+ key changed in 900s
save 300 10     -- snapshot if 10+ keys changed in 300s
```

### AOF (Append-Only File)
Logs every write. Three fsync policies:
- `always`: fsync every write. Safest, slowest.
- `everysec`: fsync every second. Good balance (default recommended).
- `no`: OS decides. Fastest, riskiest.

```
appendonly yes
appendfsync everysec
```

### Hybrid (Redis 4.0+)
RDB snapshot at start of AOF file, then AOF delta. Fast restarts + minimal data loss.
```
aof-use-rdb-preamble yes   -- enabled by default in Redis 7
```

## Memory Optimization

### Maxmemory Policies
```
maxmemory 4gb
maxmemory-policy allkeys-lru   -- evict least recently used across all keys
```

| Policy             | Behavior                                        |
|--------------------|-------------------------------------------------|
| `noeviction`       | Return error on writes when full                |
| `allkeys-lru`      | Evict LRU keys (most common for caches)         |
| `allkeys-lfu`      | Evict least frequently used (Redis 4.0+)        |
| `volatile-lru`     | Evict LRU among keys with TTL set               |
| `volatile-lfu`     | Evict LFU among keys with TTL set               |
| `volatile-ttl`     | Evict keys with shortest TTL                    |
| `allkeys-random`   | Evict random keys                               |
| `volatile-random`  | Evict random keys with TTL set                  |

### Memory Analysis
```redis
MEMORY USAGE mykey                     -- bytes used by key
INFO memory                            -- overall memory stats
MEMORY DOCTOR                          -- diagnostic advice
OBJECT ENCODING mykey                  -- internal encoding (listpack, skiplist...)
```

Use `redis-cli --bigkeys` and `redis-cli --memkeys` to find large keys.

## Redis Stack Modules

Redis Stack bundles modules on top of core Redis (Redis 7+):

### RedisJSON
```redis
JSON.SET user:1001 $ '{"name":"Alice","age":30,"tags":["admin"]}'
JSON.GET user:1001 $.name              -- "\"Alice\""
JSON.NUMINCRBY user:1001 $.age 1       -- 31
JSON.ARRAPPEND user:1001 $.tags '"editor"'
```

### RediSearch
```redis
FT.CREATE idx:users ON JSON PREFIX 1 user: SCHEMA $.name AS name TEXT $.age AS age NUMERIC
FT.SEARCH idx:users "@name:Alice @age:[25 35]"
```

### RedisTimeSeries
```redis
TS.CREATE temp:sensor:1 RETENTION 86400000 LABELS location "nyc"
TS.ADD temp:sensor:1 * 72.5
TS.RANGE temp:sensor:1 - + AGGREGATION avg 3600000  -- hourly averages
```

### Probabilistic (Bloom, Cuckoo, Count-Min, Top-K)
```redis
BF.ADD filter:emails "user@example.com"
BF.EXISTS filter:emails "user@example.com"    -- 1 (probably exists)
BF.EXISTS filter:emails "other@example.com"   -- 0 (definitely not)
```

## Common Pitfalls

1. **KEYS in production**: Blocks server. Use SCAN with cursor iteration.
2. **Unbounded collections**: Always LTRIM lists, XTRIM streams, set TTLs.
3. **Large keys (>10KB values, >1000 hash fields)**: Cause latency spikes. Break up.
4. **Missing TTL on cache keys**: OOM inevitable. Always set expiry.
5. **Single long Lua script**: Blocks all clients. Keep scripts short (<100ms).
6. **Not using pipelines**: 1000 round-trips vs 1. Always batch independent commands.
7. **Pub/Sub without Streams for durability**: Pub/Sub drops messages if subscriber is down.
8. **Hot keys**: Single keys with extreme traffic bottleneck the thread. Shard with hash tags or replicate reads.
9. **Forgetting UNWATCH**: After failed WATCH/MULTI, always UNWATCH or start new MULTI.
10. **DEL on large keys**: Blocks server. Use UNLINK (async delete) for keys >1000 members.
11. **No connection pooling**: Creating connections per request kills performance.
12. **Ignoring SLOWLOG**: `SLOWLOG GET 10` — review slow commands regularly.

## Additional Resources

### References (Deep-Dive Guides)

| File | Topics |
|------|--------|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | Redis Functions (replacing EVAL), client-side caching (RESP3), probabilistic data structures (Bloom, CMS, Top-K, t-digest), RediSearch + vector similarity, RedisJSON paths, TimeSeries, pub/sub vs Streams, sharded pub/sub, keyspace notifications, modules architecture |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Memory pressure/eviction, slow commands, connection pool exhaustion, replication lag, cluster slot migration, AOF rewrite failures, hot keys, big keys, latency spikes (fork, fsync, swap), client output buffer overflow, Sentinel failover, split-brain, memory fragmentation |
| [`references/operations-guide.md`](references/operations-guide.md) | Deployment topologies (standalone/Sentinel/Cluster), capacity planning, memory estimation, CONFIG tuning, OS tuning, monitoring (INFO, SLOWLOG, LATENCY, Prometheus), backup strategies, upgrades, security hardening (ACLs, TLS, network), Docker/K8s patterns |

### Scripts (Ready-to-Run)

| Script | Purpose | Usage |
|--------|---------|-------|
| [`scripts/redis-local.sh`](scripts/redis-local.sh) | Start Redis locally with Docker | `./redis-local.sh [standalone\|cluster\|sentinel]` |
| [`scripts/redis-health-check.sh`](scripts/redis-health-check.sh) | Check Redis health: memory, connections, replication, keyspace, slow log | `./redis-health-check.sh [host:port] [password]` |
| [`scripts/redis-benchmark.sh`](scripts/redis-benchmark.sh) | Run redis-benchmark with common patterns | `./redis-benchmark.sh [host:port] [quick\|standard\|pipeline\|throughput\|latency\|data-sizes\|all]` |

### Assets (Templates and Code)

| File | Description |
|------|-------------|
| [`assets/docker-compose.yml`](assets/docker-compose.yml) | Redis Stack dev environment with RedisInsight UI |
| [`assets/redis-cluster-compose.yml`](assets/redis-cluster-compose.yml) | 6-node Redis Cluster docker-compose |
| [`assets/redis.conf`](assets/redis.conf) | Production redis.conf with tuned settings, ACLs, persistence, lazy-free |
| [`assets/rate-limiter.lua`](assets/rate-limiter.lua) | Sliding window rate limiter Lua script |
| [`assets/cache-patterns.py`](assets/cache-patterns.py) | Python: cache-aside, write-through, distributed lock, cached decorator |

<!-- tested: pass -->
