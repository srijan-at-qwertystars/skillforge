# Advanced Redis Patterns

## Table of Contents

- [Redis Functions (Replacing Lua EVAL)](#redis-functions-replacing-lua-eval)
- [Client-Side Caching with RESP3](#client-side-caching-with-resp3)
- [Probabilistic Data Structures](#probabilistic-data-structures)
  - [Bloom Filter](#bloom-filter)
  - [Count-Min Sketch](#count-min-sketch)
  - [Top-K](#top-k)
  - [t-digest](#t-digest)
- [Redis Search (Full-Text and Vector)](#redis-search-full-text-and-vector)
  - [FT.CREATE — Index Creation](#ftcreate--index-creation)
  - [FT.SEARCH — Querying](#ftsearch--querying)
  - [Vector Similarity Search](#vector-similarity-search)
- [Redis JSON Deep Dive](#redis-json-deep-dive)
  - [JSON.SET and JSON.GET](#jsonset-and-jsonget)
  - [Path Expressions (JSONPath)](#path-expressions-jsonpath)
  - [Atomic JSON Operations](#atomic-json-operations)
- [Redis TimeSeries](#redis-timeseries)
- [Pub/Sub vs Streams Comparison](#pubsub-vs-streams-comparison)
- [Sharded Pub/Sub (Redis 7.0+)](#sharded-pubsub-redis-70)
- [Keyspace Notifications](#keyspace-notifications)
- [Redis Modules Architecture](#redis-modules-architecture)

---

## Redis Functions (Replacing Lua EVAL)

Redis 7.0 introduced Redis Functions as a replacement for `EVAL`/`EVALSHA`. Functions are persistent, named, organized into libraries, and survive restarts.

### Why Functions Over EVAL

| Feature | EVAL/EVALSHA | Functions |
|---------|-------------|-----------|
| Persistence | Lost on restart | Stored in AOF/RDB |
| Naming | SHA1 hash only | Named functions |
| Organization | Flat scripts | Libraries with multiple functions |
| Replication | Script body in replication stream | Library replicated once |
| Upgradability | Replace everywhere | `FUNCTION LOAD REPLACE` |
| Engine | Lua only | Lua (extensible to others) |

### Creating and Using Functions

```redis
-- Load a library with functions
FUNCTION LOAD "#!lua name=mylib
redis.register_function('my_hset_ttl', function(keys, args)
  -- Atomically HSET + EXPIRE
  local key = keys[1]
  local ttl = tonumber(args[1])
  for i = 2, #args, 2 do
    redis.call('HSET', key, args[i], args[i+1])
  end
  redis.call('EXPIRE', key, ttl)
  return redis.call('HGETALL', key)
end)

redis.register_function('my_conditional_incr', function(keys, args)
  local val = tonumber(redis.call('GET', keys[1]) or '0')
  local limit = tonumber(args[1])
  if val < limit then
    return redis.call('INCR', keys[1])
  end
  return -1
end)
"

-- Call functions by name
FCALL my_hset_ttl 1 user:1001 3600 name Alice email a@b.com
FCALL my_conditional_incr 1 counter:api 1000

-- Read-only variant (safe on replicas)
FCALL_RO my_conditional_incr 1 counter:api 1000

-- Management
FUNCTION LIST                    -- list all libraries and functions
FUNCTION DUMP                    -- serialize all libraries (for backup)
FUNCTION RESTORE <payload>       -- restore from dump
FUNCTION DELETE mylib            -- remove a library
FUNCTION LOAD REPLACE "#!lua name=mylib ..."  -- upgrade in place
FUNCTION STATS                   -- execution statistics
```

### Migration from EVAL to Functions

```python
# Before: EVAL with raw script
r.eval("""
  local current = redis.call('GET', KEYS[1])
  if current == ARGV[1] then
    return redis.call('DEL', KEYS[1])
  end
  return 0
""", 1, "lock:resource", "owner-token")

# After: Load once, call by name
r.fcall("release_lock", 1, "lock:resource", "owner-token")
```

Best practice: Ship function libraries with your application deployment. Load with `FUNCTION LOAD REPLACE` during startup or migration.

---

## Client-Side Caching with RESP3

Redis 6.0+ supports server-assisted client-side caching via RESP3 protocol. The server tracks which keys each client has read and sends invalidation messages when those keys change.

### How It Works

1. Client switches to RESP3: `HELLO 3`
2. Client enables tracking: `CLIENT TRACKING ON`
3. Client reads keys — server remembers which client read which keys
4. When a tracked key is modified by any client, server pushes invalidation
5. Client evicts its local cache entry

### Tracking Modes

**Default mode**: Server tracks exact keys per client.

```redis
CLIENT TRACKING ON REDIRECT <client-id>
-- or with RESP3 push:
CLIENT TRACKING ON
```

**Broadcasting mode**: Client subscribes to key prefixes. Server broadcasts all invalidations for matching prefixes (no per-client tracking overhead).

```redis
CLIENT TRACKING ON BCAST PREFIX user: PREFIX session:
```

**OPTIN mode**: Only track keys explicitly opted in with `CLIENT CACHING YES` before the read.

```redis
CLIENT TRACKING ON OPTIN
CLIENT CACHING YES
GET user:1001:name
-- Only this key is tracked; other GETs are not
```

### Client Implementation Pattern

```python
import redis

# Using redis-py with RESP3 client-side caching
r = redis.Redis(host='localhost', port=6379, protocol=3)

# Enable tracking with local cache
# redis-py 5.x+ has built-in client cache support
from redis.cache import CacheConfig
r = redis.Redis(
    host='localhost', port=6379, protocol=3,
    cache_config=CacheConfig(max_size=10000)
)
# Reads are automatically cached locally and invalidated by server
val = r.get("user:1001")  # first call hits server
val = r.get("user:1001")  # served from local cache until invalidated
```

### When to Use

- High read-to-write ratio keys (configs, feature flags, user profiles)
- Latency-sensitive reads where even Redis RTT matters
- Reducing Redis load for frequently-accessed keys

### Caveats

- Broadcasting mode: lower server memory, but more invalidation messages
- Default mode: higher server memory (tracking table), fewer messages
- `FLUSHDB`/`FLUSHALL` invalidates everything
- Max tracking table size: `tracking-table-max-keys` config (default 0 = unlimited)

---

## Probabilistic Data Structures

All require Redis Stack (or loading RedisBloom module).

### Bloom Filter

Space-efficient set membership test. False positives possible, false negatives impossible.

```redis
-- Create with target error rate and capacity
BF.RESERVE filter:emails 0.001 1000000
-- 0.1% false positive rate, 1M expected items
-- Uses ~1.44MB (vs ~30MB for a SET of 1M emails)

BF.ADD filter:emails "alice@example.com"
BF.MADD filter:emails "bob@example.com" "carol@example.com"

BF.EXISTS filter:emails "alice@example.com"    -- 1 (yes or false positive)
BF.EXISTS filter:emails "unknown@example.com"  -- 0 (definitely not present)
BF.MEXISTS filter:emails "alice@example.com" "unknown@example.com"  -- [1, 0]

BF.INFO filter:emails
-- Capacity, Size, Number of filters, Items inserted, Expansion rate

-- Scalable Bloom (auto-expands with sub-filters)
BF.RESERVE filter:urls 0.01 100000 EXPANSION 2
-- Each sub-filter doubles capacity when previous fills
```

**Use cases**: Duplicate detection, cache penetration prevention, username availability pre-check.

**Sizing**: At 1% error rate, ~9.6 bits per element. At 0.1%, ~14.4 bits per element.

### Count-Min Sketch

Frequency estimation. Answers "approximately how many times has X been seen?" Overestimates, never underestimates.

```redis
-- Create: width (counters per row) x depth (hash functions)
CMS.INITBYPROB freq:pages 0.001 0.01
-- 0.1% error within 1% probability

CMS.INCRBY freq:pages "/home" 1 "/about" 3 "/api/users" 1

CMS.QUERY freq:pages "/home" "/about" "/missing"
-- Returns: [1, 3, 0]

CMS.INFO freq:pages
-- Width, Depth, Total count

-- Merge sketches (for distributed counting)
CMS.MERGE merged:freq 2 freq:pages:shard1 freq:pages:shard2
```

**Use cases**: Frequency counting without storing individual items, network traffic analysis, trending detection.

### Top-K

Probabilistic heavy hitters — track the K most frequent items without storing all items.

```redis
-- Track top 10 items with decay parameters
TOPK.RESERVE trending:queries 10 50 3 0.9
-- k=10, width=50, depth=3, decay=0.9

TOPK.ADD trending:queries "redis tutorial" "redis cluster" "redis pub/sub"
-- Returns items dropped from top-k (or nil if none dropped)

TOPK.QUERY trending:queries "redis tutorial" "python flask"
-- [1, 0] — is this item in the top-k?

TOPK.COUNT trending:queries "redis tutorial"
-- Approximate count

TOPK.LIST trending:queries WITHCOUNT
-- All k items with their approximate counts
```

**Use cases**: Trending topics, most-viewed pages, heaviest API consumers.

### t-digest

Percentile/quantile estimation on streaming data. Extremely accurate at the tails (p99, p99.9).

```redis
TDIGEST.CREATE latency:api COMPRESSION 100
-- Higher compression = more accuracy, more memory

TDIGEST.ADD latency:api 1.2 3.4 0.8 15.2 2.1 1.1
-- Add observed values

TDIGEST.QUANTILE latency:api 0.5 0.95 0.99 0.999
-- [1.65, 12.1, 15.2, 15.2] — p50, p95, p99, p99.9

TDIGEST.CDF latency:api 5.0
-- [0.72] — 72% of values are ≤ 5.0

TDIGEST.MIN latency:api    -- minimum observed
TDIGEST.MAX latency:api    -- maximum observed

TDIGEST.TRIMMED_MEAN latency:api 0.1 0.9
-- Mean excluding bottom 10% and top 10%

-- Merge digests from multiple servers
TDIGEST.MERGE merged:latency 2 latency:api:server1 latency:api:server2
```

**Use cases**: Latency percentiles (SLO monitoring), response time distributions, real-time percentile alerts.

---

## Redis Search (Full-Text and Vector)

Requires Redis Stack or RediSearch module.

### FT.CREATE — Index Creation

```redis
-- Index JSON documents
FT.CREATE idx:products ON JSON PREFIX 1 product:
  SCHEMA
    $.name AS name TEXT WEIGHT 2.0      -- boosted text field
    $.description AS desc TEXT
    $.category AS category TAG          -- exact match / filtering
    $.price AS price NUMERIC SORTABLE   -- numeric range queries
    $.brand AS brand TAG SEPARATOR ","  -- multi-value tag
    $.embedding AS embedding VECTOR FLAT -- vector field (see below)
      6 TYPE FLOAT32 DIM 384 DISTANCE_METRIC COSINE

-- Index Hash documents
FT.CREATE idx:users ON HASH PREFIX 1 user:
  SCHEMA
    name TEXT SORTABLE
    email TAG
    age NUMERIC SORTABLE
    bio TEXT
    location GEO                        -- geospatial queries

-- Manage indexes
FT.INFO idx:products                    -- index metadata and stats
FT.DROPINDEX idx:products               -- drop index (keeps data)
FT.DROPINDEX idx:products DD            -- drop index AND data
FT._LIST                               -- list all indexes
FT.ALTER idx:products SCHEMA ADD $.sku AS sku TAG  -- add field
```

### FT.SEARCH — Querying

```redis
-- Full-text search
FT.SEARCH idx:products "wireless headphones"
FT.SEARCH idx:products "wire* head*"                   -- prefix matching
FT.SEARCH idx:products "%%wireles%%" DIALECT 2          -- fuzzy (Levenshtein ≤1)
FT.SEARCH idx:products "\"noise cancelling\""           -- exact phrase

-- Field-specific search
FT.SEARCH idx:products "@name:headphones @category:{electronics}"
FT.SEARCH idx:products "@price:[50 200]"                -- numeric range
FT.SEARCH idx:products "@price:[(50 (200]"              -- exclusive range

-- Combining filters
FT.SEARCH idx:products "@name:headphones @category:{electronics} @price:[0 100]"
  SORTBY price ASC
  LIMIT 0 10
  RETURN 3 name price category

-- Aggregations
FT.AGGREGATE idx:products "*"
  GROUPBY 1 @category
  REDUCE COUNT 0 AS count
  REDUCE AVG 1 @price AS avg_price
  SORTBY 2 @count DESC
  LIMIT 0 10

-- Autocomplete / suggestions
FT.SUGADD autocomplete:products "wireless headphones" 100
FT.SUGADD autocomplete:products "wired earbuds" 80
FT.SUGGET autocomplete:products "wir" FUZZY MAX 5
```

### Vector Similarity Search

```redis
-- Create index with vector field
FT.CREATE idx:embeddings ON HASH PREFIX 1 doc:
  SCHEMA
    content TEXT
    embedding VECTOR HNSW 6
      TYPE FLOAT32
      DIM 768
      DISTANCE_METRIC COSINE
    category TAG

-- Store document with embedding
HSET doc:1 content "Redis is an in-memory database"
  category "databases"
  embedding <768-float binary blob>

-- KNN search (find 10 nearest neighbors)
FT.SEARCH idx:embeddings
  "*=>[KNN 10 @embedding $query_vec AS score]"
  PARAMS 2 query_vec <binary_vector>
  SORTBY score
  RETURN 3 content category score
  DIALECT 2

-- Hybrid: KNN + filter
FT.SEARCH idx:embeddings
  "(@category:{databases})=>[KNN 10 @embedding $query_vec AS score]"
  PARAMS 2 query_vec <binary_vector>
  SORTBY score
  DIALECT 2

-- Range search (all vectors within distance)
FT.SEARCH idx:embeddings
  "@embedding:[VECTOR_RANGE 0.2 $query_vec]"
  PARAMS 2 query_vec <binary_vector>
  DIALECT 2
```

**FLAT vs HNSW**: FLAT = brute force (exact, slower for large datasets). HNSW = approximate nearest neighbor (fast, tunable accuracy via `EF_CONSTRUCTION` and `M` parameters).

---

## Redis JSON Deep Dive

### JSON.SET and JSON.GET

```redis
-- Set root document
JSON.SET user:1001 $ '{"name":"Alice","age":30,"address":{"city":"NYC","zip":"10001"},"scores":[95,87,92]}'

-- Get entire document
JSON.GET user:1001 $                    -- full document
JSON.GET user:1001 $.name              -- ["Alice"]
JSON.GET user:1001 $.address.city      -- ["NYC"]
JSON.GET user:1001 $.scores[0]         -- [95]
JSON.GET user:1001 $.scores[-1]        -- [92] (last element)

-- Multi-path GET
JSON.GET user:1001 $.name $.age $.address.city
-- {"$.name":["Alice"],"$.age":[30],"$.address.city":["NYC"]}

-- Pretty print
JSON.GET user:1001 INDENT "\t" NEWLINE "\n" SPACE " " $
```

### Path Expressions (JSONPath)

```redis
-- Root: $
-- Child: $.field or $['field']
-- Array index: $.arr[0], $.arr[-1]
-- Array slice: $.arr[0:3]
-- Wildcard: $.* (all children), $.arr[*] (all elements)
-- Recursive descent: $..field (search all levels)
-- Filter: $.users[?(@.age>25)]

JSON.SET data $ '{"users":[{"name":"Alice","age":30},{"name":"Bob","age":22}]}'
JSON.GET data $.users[?(@.age>25)].name    -- ["Alice"]
JSON.GET data $..name                       -- ["Alice","Bob"]
JSON.GET data $.users[*].age               -- [30, 22]
```

### Atomic JSON Operations

```redis
-- Numeric operations
JSON.NUMINCRBY user:1001 $.age 1          -- [31]
JSON.NUMMULTBY stats $.factor 1.5         -- multiply

-- String operations
JSON.STRAPPEND user:1001 $.name '" Jr."'  -- [10] (new length)
JSON.STRLEN user:1001 $.name              -- [10]

-- Array operations
JSON.ARRAPPEND user:1001 $.scores 88      -- [4] (new length)
JSON.ARRINSERT user:1001 $.scores 0 100   -- insert at index 0
JSON.ARRINDEX user:1001 $.scores 87       -- [1] (index of value)
JSON.ARRPOP user:1001 $.scores -1         -- remove and return last
JSON.ARRLEN user:1001 $.scores            -- array length
JSON.ARRTRIM user:1001 $.scores 0 4       -- keep indices 0-4

-- Object operations
JSON.OBJKEYS user:1001 $.address          -- ["city","zip"]
JSON.OBJLEN user:1001 $.address           -- 2

-- Type and existence
JSON.TYPE user:1001 $.name                -- ["string"]
JSON.DEL user:1001 $.address.zip          -- 1 (deleted count)

-- Merge (Redis 7.4+)
JSON.MERGE user:1001 $ '{"email":"alice@example.com","address":{"state":"NY"}}'
```

---

## Redis TimeSeries

Optimized for time-stamped data: metrics, IoT sensor data, financial ticks.

```redis
-- Create time series with retention and labels
TS.CREATE cpu:server1 RETENTION 604800000 DUPLICATE_POLICY LAST
  LABELS host server1 metric cpu region us-east
-- 7-day retention, last-write-wins for duplicate timestamps

-- Add samples
TS.ADD cpu:server1 * 72.5                  -- * = auto timestamp
TS.ADD cpu:server1 1705334400000 68.2      -- explicit timestamp (ms)
TS.MADD cpu:server1 * 72.5 mem:server1 * 4096  -- multi-add

-- Query
TS.GET cpu:server1                         -- latest sample
TS.RANGE cpu:server1 - + COUNT 100         -- all samples (last 100)
TS.RANGE cpu:server1 1705334400000 1705420800000  -- time range
TS.REVRANGE cpu:server1 - + COUNT 10       -- newest first

-- Aggregations (downsampling)
TS.RANGE cpu:server1 - + AGGREGATION avg 60000   -- 1-min averages
TS.RANGE cpu:server1 - + AGGREGATION max 3600000 -- hourly max
-- Aggregations: avg, sum, min, max, range, count, first, last, std.p, std.s, var.p, var.s, twa

-- Compaction rules (automatic downsampling)
TS.CREATE cpu:server1:hourly RETENTION 2592000000 LABELS host server1 metric cpu agg hourly
TS.CREATERULE cpu:server1 cpu:server1:hourly AGGREGATION avg 3600000

-- Multi-key queries (by label filter)
TS.MGET FILTER metric=cpu region=us-east
TS.MRANGE - + AGGREGATION avg 60000 FILTER metric=cpu
TS.MRANGE - + FILTER metric=cpu GROUPBY host REDUCE avg

-- Delete range
TS.DEL cpu:server1 1705334400000 1705420800000

TS.INFO cpu:server1   -- metadata, retention, rules, labels, memory usage
```

**Use cases**: Server monitoring, IoT telemetry, financial tick data, SLO tracking, real-time dashboards.

**vs Sorted Sets for time data**: TimeSeries is 5-10x more memory efficient, has built-in aggregation/downsampling, label-based queries, and compaction rules.

---

## Pub/Sub vs Streams Comparison

| Feature | Pub/Sub | Streams |
|---------|---------|---------|
| Delivery | Fire-and-forget | Persistent, replayable |
| Persistence | None — messages lost if no subscriber | Written to AOF/RDB |
| Consumer groups | No | Yes — XREADGROUP, XACK |
| Message replay | Impossible | XRANGE from any ID |
| At-most-once | Yes | Default without ACK |
| At-least-once | No | Yes with consumer groups + XACK |
| Ordering | Per-channel | Global (ID-based) |
| Backpressure | None — slow consumers are disconnected | Consumer reads at own pace |
| Pattern matching | PSUBSCRIBE glob patterns | N/A (use multiple streams) |
| Max throughput | Higher (no persistence overhead) | Lower (writes to memory + disk) |
| Memory | Transient only | Grows until trimmed (XTRIM/MAXLEN) |
| Dead letter | N/A | XPENDING + XCLAIM for stuck messages |
| Fan-out | Built-in (all subscribers get message) | Multiple consumer groups |
| Blocking read | SUBSCRIBE blocks connection | XREAD BLOCK / XREADGROUP BLOCK |

### When to Use Pub/Sub

- Real-time notifications where loss is acceptable (typing indicators, live cursors)
- Cache invalidation broadcasts
- Chat rooms where history is not needed
- High-frequency events where persistence is overhead

### When to Use Streams

- Task queues / job processing
- Event sourcing / audit logs
- Reliable messaging (at-least-once delivery)
- Multi-consumer processing with consumer groups
- Any scenario requiring message replay or persistence

---

## Sharded Pub/Sub (Redis 7.0+)

Classic Pub/Sub broadcasts to ALL nodes in a cluster — every message hits every node regardless of subscriber location. Sharded Pub/Sub assigns channels to hash slots, so messages only go to the shard owning that slot.

```redis
-- Sharded publish/subscribe (slot-aware)
SSUBSCRIBE channel:order:updates       -- subscribe to sharded channel
SPUBLISH channel:order:updates "new order"  -- publish to sharded channel

-- Sharded pattern subscribe
SUNSUBSCRIBE channel:order:updates     -- unsubscribe
```

### Classic vs Sharded Pub/Sub

| Aspect | Classic Pub/Sub | Sharded Pub/Sub |
|--------|----------------|-----------------|
| Routing | All nodes | Slot-owning shard only |
| Scalability | O(N) nodes | O(1) shard |
| Command | SUBSCRIBE/PUBLISH | SSUBSCRIBE/SPUBLISH |
| Pattern sub | PSUBSCRIBE (yes) | Not supported |
| Cluster overhead | High (broadcast storm) | Low (targeted) |
| Failover | Resubscribe needed | Slot migration handles it |

**When to use**: High-throughput Pub/Sub in Redis Cluster. Especially when you have many channels and subscribers are sparse across nodes.

---

## Keyspace Notifications

Redis can notify clients when keys are modified or expire. Disabled by default (CPU overhead).

```redis
-- Enable via config
CONFIG SET notify-keyspace-events KEA
-- K = keyspace events (key name in channel)
-- E = keyevent events (event type in channel)
-- A = all commands
-- g = generic: DEL, EXPIRE, RENAME...
-- $ = string commands
-- l = list commands
-- s = set commands
-- h = hash commands
-- z = sorted set commands
-- x = expiration events
-- e = eviction events
-- t = stream commands

-- Subscribe to all events on a specific key
SUBSCRIBE __keyspace@0__:user:1001
-- Receive: "set", "expire", "del", etc.

-- Subscribe to all SET events across all keys
SUBSCRIBE __keyevent@0__:set
-- Receive: key name that was SET

-- Subscribe to all expirations in DB 0
SUBSCRIBE __keyevent@0__:expired
-- Receive: key name that expired

-- Pattern subscribe for a prefix
PSUBSCRIBE __keyspace@0__:session:*
-- Notified when any session:* key changes
```

**Use cases**: Cache invalidation triggers, session expiry handling, audit logging, real-time synchronization.

**Caveats**:
- Messages are fire-and-forget (like Pub/Sub) — no persistence or replay
- `expired` events fire when key is accessed after expiry OR during lazy/periodic cleanup, NOT at exact expiry time
- CPU overhead — only enable the event types you need
- In Cluster mode, notifications are node-local (subscribe on every node or use client library that handles this)

---

## Redis Modules Architecture

Redis modules extend Redis with custom data types, commands, and capabilities using the Modules API (C ABI).

### Module Lifecycle

1. Module exports `RedisModule_OnLoad()` — called when loaded
2. Registers commands via `RedisModule_CreateCommand()`
3. Optionally registers custom data types via `RedisModule_CreateDataType()`
4. Module can hook into: keyspace notifications, server events, cluster messages, ACL checks

### Loading Modules

```redis
-- redis.conf
loadmodule /path/to/redisbloom.so
loadmodule /path/to/rejson.so
loadmodule /path/to/redisearch.so PARTITIONS AUTO

-- Runtime loading
MODULE LOAD /path/to/module.so [args...]
MODULE UNLOAD mymodule
MODULE LIST                    -- list loaded modules
MODULE LOADEX /path/to/module.so CONFIG name value  -- load with config
```

### Redis Stack Modules

| Module | Commands Prefix | Purpose |
|--------|----------------|---------|
| RedisJSON | `JSON.*` | Native JSON document store |
| RediSearch | `FT.*` | Full-text search, secondary indexes, vector search |
| RedisTimeSeries | `TS.*` | Time series data ingestion and queries |
| RedisBloom | `BF.*`, `CF.*`, `CMS.*`, `TOPK.*`, `TDIGEST.*` | Probabilistic data structures |
| RedisGraph (EOL) | `GRAPH.*` | Graph database (deprecated — use FalkorDB fork) |
| RedisGears | `RG.*`, `TFUNCTION.*` | Serverside functions / triggers |

### Writing a Custom Module (C)

```c
#include "redismodule.h"

int MyCommand_Handler(RedisModuleCtx *ctx, RedisModuleString **argv, int argc) {
    if (argc != 2) return RedisModule_WrongArity(ctx);
    RedisModuleString *key_name = argv[1];
    RedisModuleKey *key = RedisModule_OpenKey(ctx, key_name, REDISMODULE_READ);
    // ... implement logic ...
    RedisModule_ReplyWithSimpleString(ctx, "OK");
    return REDISMODULE_OK;
}

int RedisModule_OnLoad(RedisModuleCtx *ctx, RedisModuleString **argv, int argc) {
    if (RedisModule_Init(ctx, "mymodule", 1, REDISMODULE_APIVER_1) == REDISMODULE_ERR)
        return REDISMODULE_ERR;
    RedisModule_CreateCommand(ctx, "mymodule.mycommand",
        MyCommand_Handler, "readonly", 1, 1, 1);
    return REDISMODULE_OK;
}
```

Modules execute in the same single-threaded context as Redis commands. Long-running module commands block the server — use `RedisModule_CreateTimer()` or thread-safe contexts (`RedisModule_GetThreadSafeContext()`) for background work.
