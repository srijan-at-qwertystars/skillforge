# Advanced Redis Patterns

Comprehensive guide to Redis modules, Redis Functions, sharded pub/sub, client-side caching,
keyspace notifications, event sourcing with streams, and RESP3 protocol features.

---

## Table of Contents

1. [Redis Stack & Modules](#redis-stack--modules)
   - [RediSearch](#redisearch)
   - [RedisJSON](#redisjson)
   - [RedisTimeSeries](#redistimeseries)
   - [RedisGraph](#redisgraph)
   - [RedisBloom](#redisbloom)
2. [Redis Functions (Redis 7+)](#redis-functions-redis-7)
3. [Sharded Pub/Sub](#sharded-pubsub)
4. [Client-Side Caching](#client-side-caching)
5. [Keyspace Notifications](#keyspace-notifications)
6. [Redis as a Primary Database](#redis-as-a-primary-database)
7. [Event Sourcing with Streams](#event-sourcing-with-streams)
8. [RESP3 Protocol Features](#resp3-protocol-features)

---

## Redis Stack & Modules

Redis Stack bundles the core Redis engine with several powerful modules. These can also be
loaded individually in open-source Redis via `MODULE LOAD` or at startup in `redis.conf`:

```
loadmodule /path/to/redisearch.so
loadmodule /path/to/rejson.so
```

### RediSearch

Full-text search, secondary indexing, and vector similarity on Redis data.

**Key Commands:**
```redis
# Create an index on hash keys with prefix "product:"
FT.CREATE idx:products ON HASH PREFIX 1 product: SCHEMA
  name TEXT WEIGHT 5.0
  description TEXT
  price NUMERIC SORTABLE
  category TAG
  location GEO
  embedding VECTOR FLAT 6 DIM 384 TYPE FLOAT32 DISTANCE_METRIC COSINE

# Full-text search with filtering
FT.SEARCH idx:products "@name:wireless @category:{electronics}" LIMIT 0 10

# Aggregation pipeline
FT.AGGREGATE idx:products "*"
  GROUPBY 1 @category
  REDUCE AVG 1 @price AS avg_price
  SORTBY 2 @avg_price DESC

# Vector similarity (KNN) for AI/ML embeddings
FT.SEARCH idx:products "*=>[KNN 5 @embedding $vec AS score]"
  PARAMS 2 vec "\x00\x00..." DIALECT 2

# Auto-complete suggestions
FT.SUGADD autocomplete "wireless headphones" 100
FT.SUGGET autocomplete "wire" FUZZY MAX 5
```

**Use Cases:** Product catalogs, site search, analytics dashboards, semantic/AI search,
geo-spatial queries ("restaurants near me"), secondary indexes on unstructured data.

### RedisJSON

Native JSON document storage with path-based access and atomic partial updates.

**Key Commands:**
```redis
# Store a JSON document
JSON.SET user:1001 $ '{"name":"Alice","age":30,"address":{"city":"NYC"},"tags":["admin","active"]}'

# Read nested fields without deserializing the whole object
JSON.GET user:1001 $.name $.address.city
# → '{"$.name":["Alice"],"$.address.city":["NYC"]}'

# Atomic partial update
JSON.NUMINCRBY user:1001 $.age 1
JSON.ARRAPPEND user:1001 $.tags '"vip"'

# Combine with RediSearch for querying JSON documents
FT.CREATE idx:users ON JSON PREFIX 1 user: SCHEMA
  $.name AS name TEXT
  $.age AS age NUMERIC
  $.address.city AS city TAG
```

**Use Cases:** NoSQL document store, flexible API payloads, microservice configuration,
real-time analytics on JSON data, replacing MongoDB for simpler use cases.

### RedisTimeSeries

Purpose-built time-series data structure with automatic downsampling and retention.

**Key Commands:**
```redis
# Create a time series with labels and retention
TS.CREATE sensor:temp:1
  RETENTION 86400000
  LABELS device_id 1 type temperature location warehouse-A

# Add data points (timestamp in ms, or * for auto)
TS.ADD sensor:temp:1 * 23.5
TS.MADD sensor:temp:1 1700000000000 22.1 sensor:temp:2 1700000000000 19.8

# Range query with aggregation
TS.RANGE sensor:temp:1 1700000000000 1700086400000
  AGGREGATION avg 3600000    # hourly averages

# Multi-key query by labels
TS.MRANGE - + WITHLABELS
  FILTER type=temperature location=warehouse-A
  AGGREGATION max 60000      # per-minute max

# Create downsampling rule (auto-compact)
TS.CREATERULE sensor:temp:1 sensor:temp:1:hourly
  AGGREGATION avg 3600000
```

**Use Cases:** IoT sensor data, application metrics, DevOps monitoring, financial tick data,
anomaly detection, historical trend analysis.

### RedisGraph

Property graph database using the Cypher query language.

> **Note:** RedisGraph has been deprecated as of Redis Stack 7.2. Consider alternatives
> like FalkorDB (a fork) or Neo4j for new graph workloads.

**Key Commands:**
```redis
# Create nodes and relationships
GRAPH.QUERY social "CREATE (:User {name:'Alice', age:30})-[:FOLLOWS]->(:User {name:'Bob', age:25})"

# Pattern matching
GRAPH.QUERY social "MATCH (a:User)-[:FOLLOWS]->(b:User) WHERE a.name = 'Alice' RETURN b.name"

# Shortest path
GRAPH.QUERY social "MATCH p=shortestPath((a:User {name:'Alice'})-[*]-(b:User {name:'Charlie'})) RETURN p"

# Aggregation
GRAPH.QUERY social "MATCH (u:User) RETURN u.age, count(u) ORDER BY u.age"
```

**Use Cases:** Social networks, recommendation engines, fraud detection, knowledge graphs,
dependency analysis.

### RedisBloom

Probabilistic data structures for memory-efficient membership testing and frequency analysis.

**Bloom Filter** — Set membership with tunable false positive rate:
```redis
# Create with target error rate and capacity
BF.RESERVE user_seen 0.001 1000000     # 0.1% FP, 1M capacity
BF.ADD user_seen "user:42"
BF.EXISTS user_seen "user:42"           # → 1
BF.EXISTS user_seen "user:99"           # → 0 (definitely not present)
BF.MADD user_seen "user:1" "user:2" "user:3"
```

**Cuckoo Filter** — Like Bloom but supports deletion:
```redis
CF.RESERVE visitors 1000000
CF.ADD visitors "user:42"
CF.DEL visitors "user:42"               # deletion supported
CF.EXISTS visitors "user:42"            # → 0
```

**Count-Min Sketch** — Frequency estimation:
```redis
CMS.INITBYDIM page_views 2000 5
CMS.INCRBY page_views "/home" 1 "/about" 3
CMS.QUERY page_views "/home"            # → approximate count
```

**Top-K** — Track most frequent items:
```redis
TOPK.RESERVE trending 10 50 3 0.9
TOPK.ADD trending "item:A" "item:B" "item:A"
TOPK.LIST trending                      # → top 10 items
```

**Use Cases:** Deduplication (ad impressions, log entries), cache existence checks,
trending/heavy hitter detection, real-time analytics.

---

## Redis Functions (Redis 7+)

Redis Functions replace `EVAL`/`EVALSHA` with persistent, named, modular server-side logic.

### Why Functions Over EVAL

| Aspect       | EVAL Scripts                      | Redis Functions                    |
|------------- |-----------------------------------|------------------------------------|
| Persistence  | Not persisted; resend each deploy | Persisted in DB, survives restart  |
| Replication  | Scripts replicated as commands    | Functions replicated as DB data    |
| Invocation   | `EVAL`/`EVALSHA` + SHA1           | `FCALL function_name`              |
| Modularity   | One script per call               | Libraries with multiple functions  |
| Management   | Client-managed SHA hashes         | Server-managed, `FUNCTION LIST`    |

### Defining a Function Library

```lua
-- mylib.lua
#!lua name=mylib

-- Helper (not exposed as a function)
local function validate_key(keys)
  if #keys ~= 1 then
    return redis.error_reply("ERR exactly one key required")
  end
end

-- Atomic increment with ceiling
redis.register_function('increment_capped', function(keys, args)
  validate_key(keys)
  local key = keys[1]
  local cap = tonumber(args[1])
  local current = tonumber(redis.call('GET', key) or 0)
  if current >= cap then
    return current
  end
  return redis.call('INCR', key)
end)

-- Conditional set with TTL refresh
redis.register_function('set_if_lower', function(keys, args)
  validate_key(keys)
  local key = keys[1]
  local new_val = tonumber(args[1])
  local ttl = tonumber(args[2])
  local current = tonumber(redis.call('GET', key))
  if current == nil or new_val < current then
    redis.call('SET', key, new_val, 'EX', ttl)
    return 1
  end
  return 0
end)
```

### Loading and Managing

```bash
# Load or replace a library
cat mylib.lua | redis-cli -x FUNCTION LOAD REPLACE

# List loaded functions
redis-cli FUNCTION LIST

# Dump all functions (for backup/migration)
redis-cli FUNCTION DUMP > functions.rdb

# Restore on another instance
redis-cli FUNCTION RESTORE < functions.rdb

# Delete a library
redis-cli FUNCTION DELETE mylib
```

### Invoking Functions

```redis
FCALL increment_capped 1 counter:page_views 10000
FCALL set_if_lower 1 min:temperature 18.5 3600

# Read-only variant (safe on replicas)
FCALL_RO my_read_function 1 mykey
```

### Migration Strategy from EVAL

1. Group related EVAL scripts into logical libraries
2. Convert standalone scripts to `redis.register_function()` calls
3. Load with `FUNCTION LOAD REPLACE`
4. Update client code: `EVAL` → `FCALL`, remove SHA management
5. Remove client-side script caching logic

---

## Sharded Pub/Sub

Introduced in Redis 7 for cluster deployments. Messages route to the shard owning the
channel's hash slot, eliminating cross-node broadcast overhead.

### Regular vs Sharded Pub/Sub

| Feature               | Regular Pub/Sub        | Sharded Pub/Sub (Redis 7+)  |
|-----------------------|------------------------|-----------------------------|
| Cluster behavior      | Broadcast to all nodes | Routed to owning shard      |
| Commands              | SUBSCRIBE/PUBLISH      | SSUBSCRIBE/SPUBLISH         |
| Pattern subscribe     | PSUBSCRIBE supported   | Not supported               |
| Cross-node traffic    | High in clusters       | Minimal                     |
| Channel slot          | N/A                    | CRC16(channel) % 16384      |

### Usage

```redis
# Subscriber (connects to the shard owning channel's slot)
SSUBSCRIBE orders:region:us-east

# Publisher
SPUBLISH orders:region:us-east '{"order_id":42,"action":"created"}'

# Unsubscribe
SUNSUBSCRIBE orders:region:us-east
```

### When to Use

- **Sharded:** High-throughput per-channel messaging in cluster mode, per-entity events
- **Regular:** Fan-out to all nodes, pattern matching, non-cluster deployments

### Hash Tag Colocating

Use `{hashtag}` in channel names to control shard placement:
```redis
SSUBSCRIBE {user:1001}:notifications    # same shard as user:1001 data
SSUBSCRIBE {user:1001}:activity         # colocated
```

---

## Client-Side Caching

Server-assisted client-side caching (Redis 6+, best with RESP3) keeps frequently accessed
values in application memory with automatic invalidation.

### How It Works

1. Client enables tracking: `CLIENT TRACKING ON`
2. Client reads a key → Redis remembers which client read which key
3. When a tracked key is modified, Redis sends an invalidation push message
4. Client evicts stale value from local cache
5. Next read fetches fresh data from Redis and resumes tracking

### Tracking Modes

**Default (per-client tracking):**
```redis
CLIENT TRACKING ON
GET user:1001:profile    # Redis now tracks this key for this client
# If another client modifies user:1001:profile, this client receives:
# Push: ["invalidate", ["user:1001:profile"]]
```

**Broadcast mode** — subscribe to key prefixes:
```redis
CLIENT TRACKING ON BCAST PREFIX user: PREFIX session:
# Receives invalidations for ALL keys matching these prefixes
```

**Opt-in mode** — only track keys after explicit signal:
```redis
CLIENT TRACKING ON OPTIN
CLIENT CACHING YES       # next read command will be tracked
GET user:1001:profile    # tracked
GET user:1002:profile    # NOT tracked (no preceding CACHING YES)
```

**NOLOOP** — don't invalidate your own writes:
```redis
CLIENT TRACKING ON NOLOOP
# Writes from this client won't trigger invalidations to itself
```

### Client Library Examples

```python
# Python (redis-py with RESP3)
import redis
from redis.cache import CacheConfig

r = redis.Redis(host='localhost', port=6379, protocol=3,
                cache_config=CacheConfig(max_size=10000))
val = r.get("user:1001")  # cached locally after first fetch
```

```javascript
// Node.js (node-redis with RESP3)
const client = createClient({
  RESP: 3,
  clientSideCache: { ttl: 60000, maxEntries: 5000, evictPolicy: "LRU" }
});
```

### Considerations

- Requires RESP3 for push notifications on the same connection
- Invalidation is whole-key granularity (modifying one hash field invalidates the entire key)
- Broadcast mode uses less server memory but generates more invalidation messages
- Client must handle reconnection (re-enable tracking, flush local cache)

---

## Keyspace Notifications

Subscribe to data change events on keys. Useful for reactive triggers, cache invalidation
hooks, and audit logging.

### Configuration

Disabled by default. Enable via `notify-keyspace-events` in `redis.conf` or dynamically:

```redis
CONFIG SET notify-keyspace-events KEA
```

**Flags:**
| Flag | Events                                              |
|------|-----------------------------------------------------|
| K    | Keyspace events (`__keyspace@<db>__:<key>` channels) |
| E    | Keyevent events (`__keyevent@<db>__:<event>` channels) |
| g    | Generic: DEL, EXPIRE, RENAME, ...                   |
| $    | String commands: SET, APPEND, INCR, ...              |
| l    | List commands: LPUSH, RPOP, ...                      |
| s    | Set commands: SADD, SREM, ...                        |
| h    | Hash commands: HSET, HDEL, ...                       |
| z    | Sorted set commands: ZADD, ZREM, ...                 |
| x    | Expired events (key reached TTL)                     |
| e    | Evicted events (maxmemory policy)                    |
| t    | Stream commands                                       |
| A    | Alias for "g$lshzxet" (all events)                   |

### Subscribing

```redis
# Watch all events on a specific key
SUBSCRIBE __keyspace@0__:user:1001

# Watch all SET events across all keys
SUBSCRIBE __keyevent@0__:set

# Pattern subscribe for all expired keys
PSUBSCRIBE __keyevent@0__:expired
```

### Example: Expire Notification Handler

```python
import redis

r = redis.Redis()
pubsub = r.pubsub()
pubsub.psubscribe('__keyevent@0__:expired')

for message in pubsub.listen():
    if message['type'] == 'pmessage':
        expired_key = message['data'].decode()
        print(f"Key expired: {expired_key}")
        # Trigger cleanup, refresh, or alert
```

### Limitations

- **No values:** Notifications only carry key name and event type, not the data
- **Fire-and-forget:** Uses pub/sub internally — missed if subscriber disconnects
- **Cluster:** Notifications emit from the node hosting the key; subscribe on all primaries
- **Performance:** Enabling notifications adds overhead; enable only needed event types

---

## Redis as a Primary Database

Redis can serve as the primary data store for specific workloads where ultra-low latency
and simplicity outweigh traditional RDBMS guarantees.

### When It Works

- **Session stores:** User sessions with sliding TTL
- **Real-time features:** Leaderboards, counters, presence, activity feeds
- **Configuration/feature flags:** Fast reads, infrequent writes
- **Rate limiting and quota management:** Atomic counters with TTL
- **Time-series data:** With RedisTimeSeries module
- **Document storage:** With RedisJSON + RediSearch for querying

### Durability Configuration for Primary Use

```
# redis.conf for primary database use
appendonly yes
appendfsync always          # fsync every write (safest, ~50% perf hit)
# OR: appendfsync everysec  # acceptable 1s data loss window
aof-use-rdb-preamble yes    # hybrid AOF for faster recovery
save 900 1                  # RDB snapshots as secondary backup
```

### Data Modeling Patterns

```redis
# Entity storage (hash per entity)
HSET user:1001 name "Alice" email "alice@example.com" plan "pro" created_at 1700000000

# Secondary index (sorted set)
ZADD idx:users:by_created 1700000000 "user:1001"

# Unique constraint (set)
SADD idx:users:emails "alice@example.com"

# Relationships (sets)
SADD user:1001:followers "user:1002" "user:1003"
SADD user:1002:following "user:1001"
```

### Limitations to Understand

- No ad-hoc SQL queries (use RediSearch for indexing/searching)
- Manual index maintenance (no automatic secondary indexes without RediSearch)
- Single-threaded command execution limits write throughput on one instance
- Complex transactions require Lua scripts or Functions
- Backup/restore is less flexible than traditional databases

---

## Event Sourcing with Streams

Redis Streams provide an append-only log ideal for event sourcing architectures.

### Architecture Pattern

```
Producers → XADD → Stream (event log) → Consumer Groups → Projections/Views
                                       → Consumer Groups → Side Effects
                                       → XRANGE         → Event Replay
```

### Implementation

**Event Producer:**
```python
def emit_event(stream, event_type, entity_id, data):
    event = {
        "type": event_type,
        "entity_id": entity_id,
        "timestamp": str(time.time()),
        **data
    }
    event_id = redis.xadd(f"stream:{stream}", event, maxlen=100000)
    return event_id

# Usage
emit_event("orders", "order_created", "order:42",
           {"customer": "user:1001", "total": "59.99"})
emit_event("orders", "order_paid", "order:42",
           {"payment_id": "pay:789", "method": "card"})
```

**State Reconstruction (replay):**
```python
def rebuild_order_state(order_id):
    state = {}
    events = redis.xrange(f"stream:orders", "-", "+")
    for event_id, fields in events:
        if fields.get("entity_id") == order_id:
            event_type = fields["type"]
            if event_type == "order_created":
                state = {"status": "created", "customer": fields["customer"],
                          "total": fields["total"]}
            elif event_type == "order_paid":
                state["status"] = "paid"
                state["payment_id"] = fields["payment_id"]
            elif event_type == "order_shipped":
                state["status"] = "shipped"
                state["tracking"] = fields["tracking"]
    return state
```

**Materialized View (consumer group projection):**
```python
def order_projection_worker():
    group = "order_projections"
    consumer = f"worker-{os.getpid()}"
    try:
        redis.xgroup_create("stream:orders", group, "0", mkstream=True)
    except redis.ResponseError:
        pass  # group already exists

    while True:
        entries = redis.xreadgroup(group, consumer, {"stream:orders": ">"},
                                    count=10, block=5000)
        for stream, messages in entries:
            for msg_id, fields in messages:
                update_projection(fields)
                redis.xack("stream:orders", group, msg_id)

def update_projection(event):
    entity_id = event["entity_id"]
    if event["type"] == "order_created":
        redis.hset(f"view:{entity_id}", mapping={
            "status": "created", "customer": event["customer"],
            "total": event["total"]
        })
    elif event["type"] == "order_paid":
        redis.hset(f"view:{entity_id}", "status", "paid")
```

### Stream Key Strategies

```
stream:global              # single global stream (simple, ordering)
stream:entity:order:42     # per-entity (isolated, no cross-entity ordering)
stream:type:order_created  # per-event-type (fast filtering)
stream:domain:orders       # per-domain/aggregate (balanced)
```

### Stream Management

```redis
# Cap stream length (approximate for performance)
XADD stream:orders MAXLEN ~ 100000 * type order_created ...

# Trim old events
XTRIM stream:orders MINID 1700000000000-0

# Monitor consumer lag
XINFO GROUPS stream:orders
XINFO CONSUMERS stream:orders order_projections
XPENDING stream:orders order_projections - + 10
```

---

## RESP3 Protocol Features

RESP3 (Redis Serialization Protocol v3) was introduced in Redis 6 and provides richer
data types and push notifications.

### Key Improvements Over RESP2

| Feature                | RESP2                    | RESP3                         |
|------------------------|--------------------------|-------------------------------|
| Data types             | 5 (string, error, int, bulk, array) | 13+ (adds map, set, double, bool, null, etc.) |
| Push notifications     | Separate pub/sub conn    | Inline on same connection     |
| Client-side caching    | Not supported            | Full support via tracking     |
| Type disambiguation    | Strings for everything   | Native maps, sets, doubles    |
| Attribute metadata     | Not available            | Command metadata in response  |

### Enabling RESP3

```redis
# Switch connection to RESP3
HELLO 3

# With authentication
HELLO 3 AUTH username password
```

### Client Configuration

```python
# Python
r = redis.Redis(host='localhost', port=6379, protocol=3)

# Node.js
const client = createClient({ RESP: 3 });

# Go (go-redis v9+)
rdb := redis.NewClient(&redis.Options{Protocol: 3})
```

### Benefits in Practice

- **Maps returned as dicts:** `HGETALL` returns a proper map instead of flat array
- **Booleans:** Commands like `EXISTS` return true/false instead of 0/1
- **Push messages:** Invalidation events, pub/sub messages arrive on same connection
- **Doubles:** `ZSCORE` returns actual floating point, not string
- **Verbatim strings:** Distinguish between plain text and formatted responses
