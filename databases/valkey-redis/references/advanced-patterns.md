# Advanced Valkey/Redis Patterns

## Table of Contents

- [Sorted Set Leaderboards](#sorted-set-leaderboards)
- [Time-Series with Streams](#time-series-with-streams)
- [Distributed Counting with HyperLogLog](#distributed-counting-with-hyperloglog)
- [Geospatial Queries](#geospatial-queries)
- [Bloom Filters (RedisBloom)](#bloom-filters-redisbloom)
- [Graph Patterns](#graph-patterns)
- [Full-Text Search (RediSearch)](#full-text-search-redisearch)
- [JSON Documents (RedisJSON)](#json-documents-redisjson)
- [Message Queues: Streams vs Pub/Sub](#message-queues-streams-vs-pubsub)
- [Request Deduplication](#request-deduplication)
- [Distributed State Machines](#distributed-state-machines)

---

## Sorted Set Leaderboards

### Basic Leaderboard

```redis
ZADD leaderboard 1500 "alice" 1200 "bob" 1800 "carol"
ZREVRANGE leaderboard 0 9 WITHSCORES       # top 10
ZREVRANK leaderboard "alice"                # 0-based rank (descending)
ZINCRBY leaderboard 50 "bob"                # atomic score bump
ZCOUNT leaderboard 1000 2000               # players in score range
```

### Paginated Leaderboard with Neighbor Context

```redis
ZREVRANK leaderboard "alice"                # => 42
ZREVRANGE leaderboard 37 47 WITHSCORES     # positions 38-48 (5 above, 5 below)
```

### Time-Bucketed Leaderboards

```redis
ZINCRBY lb:daily:2024-01-15 100 "alice"
EXPIRE lb:daily:2024-01-15 172800          # 48h TTL
ZUNIONSTORE lb:weekly:2024-w03 7 lb:daily:2024-01-15 lb:daily:2024-01-16 ...
```

Multi-dimensional: use separate sorted sets per metric, compute composite scores with Lua (`ZSCORE` each, `ZADD` result).

---

## Time-Series with Streams

### Ingesting Metrics

```redis
XADD metrics:cpu * host "web-01" value 72.5 unit "percent"
XADD metrics:cpu * host "web-02" value 45.3 unit "percent"
XADD metrics:cpu MAXLEN ~ 100000 * host "web-01" value 68.1 unit "percent"
```

### Range Queries by Time

```redis
-- Entries between two timestamps (millisecond epoch)
XRANGE metrics:cpu 1700000000000 1700003600000

-- Last 100 entries
XREVRANGE metrics:cpu + - COUNT 100
```

### Downsampling and Trimming

Use consumer groups to process raw events and write aggregates (Lua: `XRANGE` → compute avg → `XADD` to aggregate stream).

```redis
XTRIM metrics:cpu MAXLEN ~ 50000          # approximate trim (faster)
XTRIM metrics:cpu MINID 1700000000000     # remove entries older than timestamp
```

---

## Distributed Counting with HyperLogLog

### Basic Unique Counting

```redis
PFADD uv:2024-01-15 "user:1001" "user:1002" "user:1003"
PFCOUNT uv:2024-01-15                     # => 3 (±0.81%)
```

### Multi-Period Aggregation

```redis
-- Daily unique visitors
PFADD uv:daily:2024-01-15 "user:1001"
PFADD uv:daily:2024-01-16 "user:1001" "user:1004"

-- Weekly aggregate (union of daily HLLs)
PFMERGE uv:weekly:2024-w03 uv:daily:2024-01-15 uv:daily:2024-01-16 ...
PFCOUNT uv:weekly:2024-w03               # unique across entire week
```

### Feature-Specific Counting

```redis
PFADD feature:search:users "u1" "u2"     # who used search
PFADD feature:export:users "u2" "u3"     # who used export
PFCOUNT feature:search:users feature:export:users  # union count
```

**When NOT to use HyperLogLog**: need exact counts (sorted sets), membership checks (sets/bloom), listing members (sets), or cardinality <1000 (SET+SCARD).

---

## Geospatial Queries

```redis
GEOADD stores -122.4194 37.7749 "store:sf-downtown"
GEOADD stores -73.9857 40.7484 "store:nyc-midtown"

-- Proximity search
GEOSEARCH stores FROMLONLAT -122.42 37.78 BYRADIUS 5 km ASC COUNT 10 WITHCOORD WITHDIST
GEOSEARCH stores FROMLONLAT -122.42 37.78 BYBOX 10 10 km ASC

GEODIST stores "store:sf-downtown" "store:nyc-midtown" km  # => "4139.4516"
```

Enrich geo results with pipeline: `GEOSEARCH` → loop result IDs → `pipeline.hgetall(id)` → `exec()`.

---

## Bloom Filters (RedisBloom)

Requires the RedisBloom module (`BF.*` commands).

### Setup and Basic Use

```redis
-- Create bloom filter (error rate 1%, expected 1M items)
BF.RESERVE user:emails 0.01 1000000

-- Add items
BF.ADD user:emails "alice@example.com"
BF.MADD user:emails "bob@x.com" "carol@y.com"

-- Check membership (no false negatives, possible false positives)
BF.EXISTS user:emails "alice@example.com"   # => 1 (definitely or probably exists)
BF.EXISTS user:emails "unknown@z.com"       # => 0 (definitely does not exist)
```

### Use Cases

- **Email uniqueness**: Check before expensive DB query
- **URL deduplication**: Crawlers avoiding revisits
- **Username availability**: Fast pre-check
- **Ad impression dedup**: Don't show same ad twice

### Cuckoo Filters (Alternative)

```redis
CF.RESERVE unique:urls 1000000
CF.ADD unique:urls "https://example.com/page1"
CF.EXISTS unique:urls "https://example.com/page1"  # => 1
CF.DEL unique:urls "https://example.com/page1"     # supports deletion (bloom filters don't)
```

### Scaling Pattern

```python
# Application-level bloom filter check before DB
def is_new_email(email):
    if redis.execute_command("BF.EXISTS", "user:emails", email):
        # Might exist — check DB to confirm (handles false positives)
        return not db.query("SELECT 1 FROM users WHERE email = %s", email)
    # Definitely new — skip DB
    return True
```

---

## Graph Patterns

Model graphs using adjacency sets and sorted sets without the RedisGraph module.

### Social Graph (Adjacency Sets)

```redis
-- User 1001 follows 1002 and 1003
SADD following:1001 "1002" "1003"
SADD followers:1002 "1001"
SADD followers:1003 "1001"

-- Mutual friends
SINTER following:1001 following:1002

-- Friend-of-friend suggestions (2nd-degree connections)
SUNIONSTORE temp:fof following:1002 following:1003  # friends-of-friends
SDIFF temp:fof following:1001                        # exclude already-following
```

### Weighted Graphs (Sorted Sets)

```redis
ZADD graph:nodeA 1.5 "nodeB" 2.3 "nodeC"
ZRANGEBYSCORE graph:nodeA 0 +inf WITHSCORES   # neighbors by weight
```

For BFS/shortest-path: iterate `SMEMBERS` at application level with visited-set tracking, bounded by `max_depth`.

---

## Full-Text Search (RediSearch)

Requires the RediSearch module (`FT.*` commands).

### Index Creation

```redis
FT.CREATE idx:products ON HASH PREFIX 1 product:
  SCHEMA
    name TEXT WEIGHT 5.0
    description TEXT
    price NUMERIC SORTABLE
    category TAG
    location GEO
```

### Querying

```redis
FT.SEARCH idx:products "wireless mouse" LIMIT 0 10
FT.SEARCH idx:products "@category:{electronics} @price:[10 50]" SORTBY price ASC
FT.SEARCH idx:products "@location:[-122.42 37.78 10 km]"

FT.AGGREGATE idx:products "*"
  GROUPBY 1 @category REDUCE COUNT 0 AS count REDUCE AVG 1 @price AS avg_price
  SORTBY 2 @count DESC
```

---

## JSON Documents (RedisJSON)

Requires the RedisJSON module (`JSON.*` commands).

### Store and Retrieve JSON

```redis
JSON.SET user:1001 $ '{"name":"Alice","age":30,"address":{"city":"SF","zip":"94102"},"tags":["admin","beta"]}'
JSON.GET user:1001 $                              # full document
JSON.GET user:1001 $.name                         # => ["Alice"]
JSON.GET user:1001 $.address.city                 # => ["SF"]
```

### Partial Updates

```redis
JSON.SET user:1001 $.address.city '"NYC"'         # update nested field
JSON.NUMINCRBY user:1001 $.age 1                  # increment number
JSON.ARRAPPEND user:1001 $.tags '"vip"'           # append to array
JSON.ARRPOP user:1001 $.tags                      # pop from array
```

### Combine with RediSearch

```redis
FT.CREATE idx:users ON JSON PREFIX 1 user:
  SCHEMA
    $.name AS name TEXT
    $.age AS age NUMERIC
    $.address.city AS city TAG
    $.tags[*] AS tags TAG
```

---

## Message Queues: Streams vs Pub/Sub

### Decision Matrix

| Feature              | Pub/Sub           | Streams                        |
|----------------------|-------------------|--------------------------------|
| Persistence          | None              | Yes (append-only log)          |
| Replay               | No                | Yes (read from any ID)         |
| Consumer groups      | No                | Yes (XREADGROUP)               |
| Delivery guarantee   | At-most-once      | At-least-once (with XACK)      |
| Backpressure         | No (drops msgs)   | Yes (consumer controls pace)   |
| Fan-out              | Built-in          | Via multiple consumer groups    |
| Latency              | Lower             | Slightly higher                |
| Use case             | Real-time notifs  | Task queues, event sourcing    |

### Reliable Queue with Streams

```redis
-- Producer
XADD tasks * type "email" to "user@x.com" body "Welcome!"

-- Consumer group setup
XGROUP CREATE tasks workers 0 MKSTREAM

-- Consumer (blocking read)
XREADGROUP GROUP workers worker-1 COUNT 1 BLOCK 5000 STREAMS tasks >

-- Acknowledge after processing
XACK tasks workers "1700000000000-0"

-- Recover unacknowledged (dead consumer cleanup)
XAUTOCLAIM tasks workers worker-2 60000 0-0 COUNT 50
```

### Pub/Sub for Real-Time Events

```redis
-- Keyspace notifications (track key changes)
CONFIG SET notify-keyspace-events KEA
SUBSCRIBE __keyevent@0__:expired          # react to key expiration
```

---

## Request Deduplication

Prevent duplicate processing of the same request using idempotency keys.

### Simple Dedup with SET NX

```redis
-- Check+store idempotency key atomically
SET idemp:req:abc123 "processing" NX EX 3600
-- Returns OK if new request, nil if duplicate
```

### Dedup with Result Caching

```lua
-- KEYS[1] = idempotency key, ARGV[1] = TTL
-- Returns: [0, nil] if new, [1, cached_result] if duplicate
local exists = redis.call('EXISTS', KEYS[1])
if exists == 1 then
    local result = redis.call('GET', KEYS[1])
    return {1, result}
end
redis.call('SET', KEYS[1], 'pending', 'EX', ARGV[1], 'NX')
return {0, nil}
```

### Application Pattern

```python
def process_payment(request_id, payment_data):
    key = f"idemp:payment:{request_id}"
    cached = redis.get(key)
    if cached:
        return json.loads(cached)  # return cached result

    if not redis.set(key, "processing", nx=True, ex=3600):
        raise ConflictError("Request already in progress")

    try:
        result = payment_gateway.charge(payment_data)
        redis.setex(key, 86400, json.dumps(result))  # cache result 24h
        return result
    except Exception:
        redis.delete(key)  # allow retry on failure
        raise
```

---

## Distributed State Machines

Track entity state transitions atomically with Redis.

### State Machine with Hash + Lua

```lua
-- KEYS[1] = entity key
-- ARGV[1] = expected current state, ARGV[2] = new state, ARGV[3] = timestamp
local current = redis.call('HGET', KEYS[1], 'state')
if current ~= ARGV[1] then
    return {0, current or 'nil'}  -- transition rejected
end
redis.call('HMSET', KEYS[1], 'state', ARGV[2], 'updated_at', ARGV[3])
redis.call('RPUSH', KEYS[1] .. ':history', ARGV[3] .. ':' .. ARGV[1] .. '->' .. ARGV[2])
return {1, ARGV[2]}
```

### Application-Level Transition Validation

Store allowed transitions in app code (e.g., `TRANSITIONS["order"]["pending"] = ["confirmed","cancelled"]`). Validate before calling the Lua script. On conflict (script returns `{0, current_state}`), retry or raise error.

### Expiring States and Audit Trail

```redis
HSET order:42 state "awaiting_payment"
SET order:42:timeout "" EX 900           # 15-min payment window, detect via keyspace notifications
RPUSH order:42:history "1700000000:created->pending"
LRANGE order:42:history 0 -1            # full transition history
```
