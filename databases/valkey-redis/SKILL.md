---
name: valkey-redis
description: >
  Use when working with Valkey, Redis, or any Redis-compatible datastore.
  TRIGGER: code imports ioredis, redis, redis-py, valkey-py, go-redis, jedis,
  lettuce, or valkey-glide; Dockerfile/compose uses redis or valkey image;
  user mentions caching layer, session store, pub/sub, rate limiting with
  Redis/Valkey, streams, consumer groups, sorted sets, distributed locking,
  Redlock, ElastiCache, MemoryDB, Dragonfly, KeyDB, or any RESP-protocol store.
  DO NOT TRIGGER for general SQL databases, MongoDB, DynamoDB, Memcached
  (without Redis mention), or message brokers like RabbitMQ/Kafka unless
  explicitly compared to Redis/Valkey.
---

# Valkey / Redis Patterns

## Valkey–Redis Relationship

Valkey is a BSD-3 licensed fork of Redis 7.2.4, created March 2024 after Redis switched to RSALv2/SSPLv1. Maintained by Linux Foundation. Valkey 7.x/8.x are drop-in replacements for Redis ≤7.2.4—same protocol (RESP2/RESP3), same data formats, same client libraries. Valkey 8+ adds multi-threaded command execution. Redis 7.4+ diverges under source-available licensing. All patterns below apply to both unless noted.

Use `valkey-server` / `valkey-cli` as direct replacements for `redis-server` / `redis-cli`. Existing client libraries (ioredis, redis-py, go-redis, Jedis, Lettuce) work unchanged. Valkey-native clients: `valkey-py`, `valkey-go`, `valkey-glide`.

## Data Structures

### Strings
General-purpose: counters, serialized objects, flags.

```
SET user:1001:name "Alice" EX 3600    # set with 1-hour TTL
GET user:1001:name                     # => "Alice"
INCR request_count                     # => 1 (atomic increment)
MSET k1 "v1" k2 "v2"                  # multi-set (batch)
MGET k1 k2                            # => ["v1", "v2"]
SETNX lock:order:42 "owner-abc"       # set-if-not-exists (basic lock)
```

### Hashes
Use for objects. More memory-efficient than serialized JSON in a string when accessing individual fields.

```
HSET user:1001 name "Alice" email "a@x.com" plan "pro"
HGET user:1001 email                   # => "a@x.com"
HGETALL user:1001                      # => {name: "Alice", email: "a@x.com", plan: "pro"}
HINCRBY user:1001 login_count 1        # atomic field increment
```

### Lists
Ordered by insertion. Use for queues, recent-items, activity feeds.

```
LPUSH queue:emails "msg-1" "msg-2"     # push left
RPOP queue:emails                      # pop right => "msg-1" (FIFO)
BRPOP queue:emails 5                   # blocking pop, 5s timeout
LRANGE recent:posts 0 9               # last 10 items
LTRIM recent:posts 0 99               # cap at 100 entries
```

### Sets
Unordered unique members. Use for tags, unique visitors, feature flags.

```
SADD online:users "u1" "u2" "u3"
SISMEMBER online:users "u2"            # => 1 (true)
SINTER online:users premium:users      # intersection
SCARD online:users                     # => 3 (cardinality)
```

### Sorted Sets
Ordered by score. Use for leaderboards, priority queues, time-series indexes.

```
ZADD leaderboard 1500 "alice" 1200 "bob" 1800 "carol"
ZREVRANGE leaderboard 0 2 WITHSCORES  # top 3 descending
# => ["carol", 1800, "alice", 1500, "bob", 1200]
ZRANGEBYSCORE leaderboard 1300 1600   # score range => ["alice"]
ZINCRBY leaderboard 100 "bob"         # bump score atomically
ZRANK leaderboard "bob"               # 0-based rank ascending
```

### Streams
Append-only log. Use for event sourcing, message queues, audit trails.

```
XADD orders * product "widget" qty 3  # => "1700000000000-0" (auto ID)
XLEN orders                           # => 1
XRANGE orders - +                     # all entries
XREAD COUNT 10 BLOCK 2000 STREAMS orders 0  # read from start, block 2s
```

### HyperLogLog
Probabilistic cardinality estimation. 12KB per key regardless of set size. 0.81% standard error.

```
PFADD unique:visitors "ip1" "ip2" "ip3"
PFCOUNT unique:visitors                # => 3 (approximate)
PFMERGE daily:uv weekly:uv            # merge counts
```

### Bitmaps
Bit-level operations on strings. Use for feature flags, bloom filters, daily active users.

```
SETBIT user:1001:features 0 1         # enable feature 0
GETBIT user:1001:features 0           # => 1
BITCOUNT active:2024-01-15            # count set bits
```

### Geospatial
Geo-indexed data built on sorted sets.

```
GEOADD locations -122.4194 37.7749 "sf" -73.9857 40.7484 "nyc"
GEODIST locations "sf" "nyc" km       # => "4139.4516"
GEOSEARCH locations FROMMEMBER "sf" BYRADIUS 500 km ASC
```

## Key Naming Conventions

Use colon-delimited namespaces: `{entity}:{id}:{field}`. Keep keys short in high-volume scenarios.

```
user:1001:profile          # hash of user data
session:abc123             # session data
cache:api:v2:/users?page=1 # cached API response
queue:emails:pending       # list as queue
lock:order:42              # distributed lock
rate:api:user:1001         # rate limiter counter
```

Use hash tags `{...}` to co-locate keys on the same cluster slot: `{user:1001}:profile` and `{user:1001}:settings` share slot.

## Expiration & Eviction

Set TTL at write time. Never store cache data without expiration.

```
SET key "val" EX 3600       # seconds
SET key "val" PX 60000      # milliseconds
EXPIRE key 300              # set TTL on existing key
TTL key                     # => remaining seconds (-1 = no TTL, -2 = missing)
PERSIST key                 # remove TTL
```

Eviction policies (set via `maxmemory-policy`):
- `allkeys-lru` — Recommended for caches. Evicts least-recently-used across all keys.
- `volatile-lru` — LRU only among keys with TTL set.
- `allkeys-lfu` — Least-frequently-used. Better for skewed access patterns.
- `noeviction` — Return errors when memory full. Use for queues/persistent data.
- `volatile-ttl` — Evict keys with shortest remaining TTL first.

Set `maxmemory` to 75% of available RAM. Reserve rest for fork operations (RDB/AOF rewrite).

## Pub/Sub

Fire-and-forget messaging. No persistence—messages lost if no subscriber is listening.

```
# Subscriber
SUBSCRIBE notifications:user:1001
PSUBSCRIBE notifications:*           # pattern subscribe

# Publisher
PUBLISH notifications:user:1001 '{"type":"order","id":42}'
# => (integer) 1  (number of receivers)
```

Use Streams instead of Pub/Sub when you need: message persistence, replay, consumer groups, or at-least-once delivery.

## Streams (Advanced)

### Consumer Groups
Distribute stream processing across multiple consumers with acknowledgment tracking.

```
# Create consumer group starting from beginning
XGROUP CREATE orders mygroup 0 MKSTREAM

# Consumer reads (blocks 5s, gets up to 10 messages)
XREADGROUP GROUP mygroup consumer-1 COUNT 10 BLOCK 5000 STREAMS orders >

# Acknowledge processed message
XACK orders mygroup "1700000000000-0"

# Check pending (unacknowledged) messages
XPENDING orders mygroup - + 10

# Claim stale messages from dead consumers (idle > 60s)
XAUTOCLAIM orders mygroup consumer-2 60000 0-0 COUNT 10

# Trim stream to cap memory
XTRIM orders MAXLEN ~ 10000          # ~ allows approximate for performance
```

### Dead Letter Pattern
Monitor `XPENDING`, count delivery attempts. After N retries, move to `dead-letter:orders` stream via `XADD` + `XACK` the original.

## Transactions

### MULTI/EXEC
Batch commands atomically. No rollback—all commands execute or none (if EXEC fails).

```
MULTI
SET account:1001:balance 900
SET account:1002:balance 1100
EXEC
# => [OK, OK]  (both applied atomically)
```

### Optimistic Locking with WATCH
Abort transaction if watched key changes between WATCH and EXEC.

```
WATCH account:1001:balance
val = GET account:1001:balance        # read current value
MULTI
SET account:1001:balance (val - 100)
EXEC
# => nil if another client modified the key (retry the operation)
```

## Lua Scripting

Execute atomically on server. No other commands run while script executes.

```
# Atomic compare-and-delete (safe lock release)
EVAL "if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
else return 0 end" 1 lock:order:42 "owner-abc"
# => 1 (deleted) or 0 (not owner)
```

Cache scripts for repeated use:
```
SCRIPT LOAD "return redis.call('GET', KEYS[1])"  # => SHA hash
EVALSHA <sha> 1 mykey                             # execute by SHA
```

Rules: keep scripts short (<1ms). All keys accessed must be in KEYS array (required for cluster mode). Avoid non-deterministic calls (`TIME`, `RANDOMKEY`). Use `redis.log()` for debugging.

## Pipelining

Batch commands to reduce round trips. Not atomic—use MULTI/EXEC if atomicity needed.

```python
# Python (redis-py)
pipe = r.pipeline(transaction=False)
for i in range(1000):
    pipe.set(f"key:{i}", f"val:{i}")
pipe.execute()  # single round trip for 1000 commands
```

```javascript
// Node.js (ioredis)
const pipeline = redis.pipeline();
for (let i = 0; i < 1000; i++) {
  pipeline.set(`key:${i}`, `val:${i}`);
}
await pipeline.exec(); // single round trip
```

Expect 5-10x throughput improvement over sequential commands.

## Client Libraries

| Language   | Library       | Notes                                          |
|------------|---------------|-------------------------------------------------|
| Node.js    | ioredis       | Cluster-aware, Lua scripting, pipeline support  |
| Node.js    | redis (node-redis) | Official, supports RESP3                   |
| Python     | redis-py      | Sync + async, cluster support                   |
| Python     | valkey-py     | Fork of redis-py for Valkey-native features     |
| Go         | go-redis      | Context support, cluster, sentinel              |
| Go         | valkey-go     | Valkey-native, client-side caching              |
| Java       | Jedis         | Simple, synchronous                             |
| Java       | Lettuce       | Async/reactive, cluster-aware, connection pooling|
| Multi-lang | valkey-glide  | Valkey official, multiplexed connections         |

Always configure: connection pooling, timeouts (connect: 5s, command: 2s), retry with exponential backoff, health checks.

## Caching Patterns

### Cache-Aside (Lazy Loading)
Most common. Application manages cache reads and writes.

```python
def get_user(user_id):
    cached = redis.get(f"user:{user_id}")
    if cached:
        return json.loads(cached)
    user = db.query("SELECT * FROM users WHERE id = %s", user_id)
    redis.setex(f"user:{user_id}", 3600, json.dumps(user))
    return user
```

### Write-Through
Write to cache and DB together. Cache always fresh but higher write latency.

```python
def update_user(user_id, data):
    db.update("UPDATE users SET ... WHERE id = %s", user_id, data)
    redis.setex(f"user:{user_id}", 3600, json.dumps(data))
```

### Write-Behind (Write-Back)
Write to cache immediately, async flush to DB. Lower latency, risk of data loss.

Use for: high-write-throughput counters, analytics, non-critical data.

### Cache Stampede Prevention
Use `SET key value NX EX <short-ttl>` as mutex. One caller regenerates cache, others wait or serve stale.

```python
def get_with_lock(key, ttl=3600):
    val = redis.get(key)
    if val: return val
    if redis.set(f"lock:{key}", "1", nx=True, ex=30):
        val = expensive_query()
        redis.setex(key, ttl, val)
        redis.delete(f"lock:{key}")
        return val
    time.sleep(0.1)           # wait for regeneration
    return redis.get(key)     # retry
```

## Rate Limiting

### Sliding Window Counter
```python
def is_rate_limited(user_id, limit=100, window=60):
    key = f"rate:{user_id}"
    now = time.time()
    pipe = redis.pipeline()
    pipe.zremrangebyscore(key, 0, now - window)  # prune old
    pipe.zadd(key, {str(now): now})               # add current
    pipe.zcard(key)                                # count
    pipe.expire(key, window)                       # auto-cleanup
    _, _, count, _ = pipe.execute()
    return count > limit
```

### Token Bucket (Lua)
```lua
-- KEYS[1]=bucket, ARGV[1]=capacity, ARGV[2]=refill_rate, ARGV[3]=now, ARGV[4]=requested
local bucket = KEYS[1]
local data = redis.call('HMGET', bucket, 'tokens', 'last_refill')
local tokens = tonumber(data[1]) or tonumber(ARGV[1])
local last = tonumber(data[2]) or tonumber(ARGV[3])
local elapsed = tonumber(ARGV[3]) - last
tokens = math.min(tonumber(ARGV[1]), tokens + elapsed * tonumber(ARGV[2]))
if tokens >= tonumber(ARGV[4]) then
  tokens = tokens - tonumber(ARGV[4])
  redis.call('HMSET', bucket, 'tokens', tokens, 'last_refill', ARGV[3])
  return 1
end
return 0
```

## Session Storage

Store sessions as hashes. Set TTL matching session expiry.

```
HSET session:abc123 user_id 1001 role "admin" csrf "tok42"
EXPIRE session:abc123 1800          # 30-minute session
HGET session:abc123 user_id         # fast field access
```

Rotate session IDs on privilege changes. Use `RENAME` atomically:
```
RENAME session:old-id session:new-id
```

## Distributed Locking (Redlock)

### Single-Instance Lock
```
SET lock:resource "unique-id-abc" NX PX 30000
# => OK (acquired) or nil (already held)
```

Release with Lua to prevent releasing another client's lock:
```
EVAL "if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('DEL',KEYS[1]) else return 0 end" 1 lock:resource "unique-id-abc"
```

### Multi-Node Redlock
1. Get current time.
2. Acquire lock on N (≥5) independent nodes with same key, value, and TTL.
3. Lock acquired if majority (N/2+1) succeed and elapsed time < TTL.
4. If failed, release all locks immediately.
5. Use random jitter on retries to prevent thundering herd.

Use client libraries: `redlock-py`, `redlock` (Node), `redsync` (Go).

## Cluster Mode

16384 hash slots distributed across master nodes. Key slot = CRC16(key) mod 16384.

```
# Check slot for key
CLUSTER KEYSLOT mykey                  # => 5649

# Force keys to same slot with hash tags
SET {user:1001}:profile "..."
SET {user:1001}:prefs "..."            # same slot as above
```

Rules: multi-key commands (MGET, pipeline) must target same slot. Use hash tags to co-locate related keys. Cross-slot operations require application-level coordination.

Resharding: use `valkey-cli --cluster reshard` to migrate slots between nodes with zero downtime.

## Sentinel (High Availability)

Monitors masters, promotes replicas on failure, notifies clients.

```
# sentinel.conf
sentinel monitor mymaster 10.0.0.1 6379 2   # quorum of 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 60000

# Client connects via Sentinel (ioredis)
const redis = new Redis({
  sentinels: [{ host: "10.0.0.1", port: 26379 }],
  name: "mymaster"
});
```

Deploy ≥3 Sentinel nodes across failure domains. Use Cluster mode for horizontal scaling; Sentinel for HA without sharding.

## Persistence

### RDB (Snapshots)
Point-in-time snapshots. Fast restarts, compact files. Data loss between snapshots.
```
save 900 1       # snapshot if ≥1 key changed in 900s
save 300 10      # snapshot if ≥10 keys changed in 300s
```

### AOF (Append-Only File)
Logs every write. Safer but larger files, slower restarts.
```
appendonly yes
appendfsync everysec    # fsync every second (recommended balance)
# Options: always (safest, slowest), everysec, no (OS decides)
```

### Hybrid (Recommended for Production)
```
aof-use-rdb-preamble yes   # RDB for bulk + AOF for recent writes
```

Fastest restart + minimal data loss. Use this for production deployments.

## Memory Optimization

- Use hashes for small objects (auto-ziplist encoding when entries < `hash-max-ziplist-entries` [128 default]).
- Prefer integers over strings for numeric values (shared integer pool 0-9999).
- Use `OBJECT ENCODING key` to verify compact encoding.
- Set `maxmemory` and a suitable eviction policy.
- Monitor with `INFO memory`, `MEMORY USAGE key`, `MEMORY DOCTOR`.
- Use `SCAN` (not `KEYS *`) for iteration in production—`KEYS` blocks the server.
- Compress large values client-side (gzip/lz4) before storing.
- Use `UNLINK` instead of `DEL` for large keys (async deletion, non-blocking).

## Common Pitfalls

1. **`KEYS *` in production** — Blocks server. Use `SCAN` with cursor iteration.
2. **Missing TTL on cache keys** — Unbounded memory growth. Always set expiration.
3. **Hot keys** — Single key receiving disproportionate traffic. Shard with suffixes: `counter:{hash(id) % N}`, merge reads.
4. **Large keys** — Strings >1MB, sets >10K members. Split into chunks or use streams.
5. **Thundering herd on cache miss** — Use mutex pattern or stale-while-revalidate.
6. **Blocking commands in cluster** — `BRPOP`, `BLPOP` only work on keys in same slot.
7. **Pub/Sub message loss** — No persistence. Switch to Streams for reliable delivery.
8. **Single-threaded bottleneck** — Pipeline commands, use cluster mode, or Valkey 8+ multi-threading.
9. **Fork latency on large datasets** — RDB saves fork the process. Monitor `latest_fork_usec`. Use `aof-use-rdb-preamble yes`.
10. **No connection pooling** — Creates connection per request. Always pool. Size pool to `num_threads * 2`.
