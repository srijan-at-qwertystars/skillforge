---
name: caching-strategies
description: >
  Guide for implementing caching strategies across application layers. Use when: designing caching layers, implementing cache-aside/read-through/write-through/write-behind patterns, configuring Redis or Memcached, setting HTTP cache headers (Cache-Control, ETag, stale-while-revalidate), CDN edge caching, cache invalidation, TTL and eviction policies (LRU, LFU), preventing cache stampede/thundering herd, multi-layer caching, cache warming, or optimizing cache hit ratios. Do NOT use for: rate limiting, message queuing or pub/sub, database indexing or query optimization, session storage without caching concerns, real-time streaming data that cannot tolerate staleness, authentication/authorization logic, or job scheduling.
---

# Caching Strategies

## Cache Patterns

### Cache-Aside (Lazy Loading)

Application manages cache reads and writes explicitly. On read, check cache first; on miss, fetch from datastore, populate cache, return result. On write, update datastore and invalidate or delete the cache entry.

```python
def get_user(user_id):
    cached = redis.get(f"user:{user_id}")
    if cached:
        return json.loads(cached)
    user = db.query("SELECT * FROM users WHERE id = %s", user_id)
    redis.setex(f"user:{user_id}", 3600, json.dumps(user))
    return user

def update_user(user_id, data):
    db.execute("UPDATE users SET ... WHERE id = %s", user_id)
    redis.delete(f"user:{user_id}")  # invalidate, not update
```

Use cache-aside when: read-heavy workloads, tolerance for eventual consistency, need fine-grained control. Avoid updating cache on write—delete it to prevent race conditions between concurrent writes.

### Read-Through

Cache itself loads data on miss via a configured loader. Application only interacts with cache. Simplifies application code but couples logic to cache provider.

```java
// Caffeine read-through cache (Java)
LoadingCache<String, User> cache = Caffeine.newBuilder()
    .maximumSize(10_000)
    .expireAfterWrite(Duration.ofMinutes(30))
    .build(key -> userRepository.findById(key));

User user = cache.get("user:123"); // auto-loads on miss
```

### Write-Through

Write to cache and datastore synchronously in the same operation. Cache always holds fresh data. Use for strong-consistency requirements. Trade-off: higher write latency.

```python
def save_product(product):
    db.save(product)
    redis.setex(f"product:{product.id}", 3600, json.dumps(product.to_dict()))
    return product
```

### Write-Behind (Write-Back)

Write to cache immediately, flush to datastore asynchronously in batches. Reduces write latency and database load. Risk: data loss if cache node fails before flush.

```python
# Conceptual write-behind with background flush
write_buffer = {}

def save_order(order):
    redis.set(f"order:{order.id}", json.dumps(order.to_dict()))
    write_buffer[order.id] = order

# Background task flushes every 5 seconds
async def flush_writes():
    while True:
        if write_buffer:
            db.bulk_insert(list(write_buffer.values()))
            write_buffer.clear()
        await asyncio.sleep(5)
```

Use write-behind for: analytics ingestion, logging, high-throughput writes where brief data loss is acceptable.

### Refresh-Ahead

Proactively reload cache entries before they expire. Predict which keys will be accessed and refresh them in the background. Eliminates cache misses for hot data.

```python
# Refresh entries at 80% of TTL
def refresh_ahead(key, ttl, loader):
    remaining = redis.ttl(key)
    if remaining < ttl * 0.2:  # less than 20% TTL remaining
        threading.Thread(target=lambda: redis.setex(key, ttl, loader())).start()
    return redis.get(key)
```

## Eviction Policies

Select based on access pattern:

- **LRU (Least Recently Used)**: Evict the entry not accessed for the longest time. Best general-purpose policy. Use Redis `allkeys-lru` or `volatile-lru`.
- **LFU (Least Frequently Used)**: Evict entries with the fewest accesses. Better for skewed distributions with stable hot keys. Use Redis `allkeys-lfu`.
- **FIFO (First In, First Out)**: Evict oldest inserted entry regardless of access. Simple but poor hit ratio for most workloads.
- **TTL-based**: Entries expire after a fixed duration. Combine with LRU/LFU for hybrid eviction. Set TTL based on data volatility.
- **Random**: Evict a random entry. Low overhead, surprisingly effective for uniform access patterns.

Redis eviction configuration:
```
maxmemory 2gb
maxmemory-policy allkeys-lru
```

## HTTP Caching

### Cache-Control Headers

```
# Immutable static assets (hashed filenames)
Cache-Control: public, max-age=31536000, immutable

# API responses with revalidation
Cache-Control: private, max-age=0, must-revalidate

# CDN-cacheable with stale serving
Cache-Control: public, max-age=60, s-maxage=300, stale-while-revalidate=30, stale-if-error=86400
```

Directives:
- `public`: Any cache (CDN, proxy) may store the response.
- `private`: Only browser cache; not CDN/proxy.
- `max-age`: Freshness lifetime in seconds for the client.
- `s-maxage`: Overrides `max-age` for shared caches (CDN/proxy).
- `no-cache`: Must revalidate with origin before using cached copy.
- `no-store`: Do not cache at all—use for sensitive data.
- `immutable`: Content will never change; skip revalidation.
- `stale-while-revalidate`: Serve stale content while refreshing in background.
- `stale-if-error`: Serve stale content if origin returns 5xx.

### ETag and Conditional Requests

```python
# Server generates ETag
from hashlib import md5
etag = md5(response_body).hexdigest()
# Response: ETag: "a1b2c3"

# Client sends: If-None-Match: "a1b2c3"
# Server returns 304 Not Modified if unchanged
```

### Vary Header

Tell caches which request headers affect the response:
```
Vary: Accept-Encoding, Authorization
```
Omit `Vary: *` — it disables caching. Keep Vary headers minimal; each unique combination creates a separate cache entry.

## CDN Caching

### Edge Caching Strategy

- Set long `s-maxage` for static assets with content-hashed filenames.
- Use short `s-maxage` (30-60s) for dynamic content with `stale-while-revalidate`.
- Configure origin shield (single mid-tier cache) to reduce origin load during cache misses across multiple edge PoPs.

### Cache Keys

Default cache key is URL. Customize to include:
- Query parameters (whitelist relevant ones, ignore tracking params like `utm_*`).
- Headers (e.g., `Accept-Language` for localized content).
- Cookies (only when necessary; broad cookie-based keys destroy hit ratio).

### Purge Strategies

- **Instant purge**: API call to CDN to invalidate specific URLs/paths. Use for content corrections.
- **Tag-based purge**: Assign surrogate keys/tags to responses. Purge all responses matching a tag. Use for content types or entity-based invalidation.
- **Wildcard purge**: Purge by URL pattern. Use sparingly—expensive on most CDNs.
- **Soft purge**: Mark content stale rather than deleting. CDN serves stale while refetching from origin.

```bash
# Fastly surrogate key purge
curl -X POST "https://api.fastly.com/service/{id}/purge/{surrogate-key}" \
  -H "Fastly-Key: $API_TOKEN"
```

## Application-Level Caching

### In-Memory Caches

Use for single-instance or per-process caching (L1 cache):

```javascript
// Node.js with node-cache
const NodeCache = require("node-cache");
const cache = new NodeCache({ stdTTL: 300, checkperiod: 60 });

function getConfig(key) {
  let val = cache.get(key);
  if (val) return val;
  val = db.fetchConfig(key);
  cache.set(key, val);
  return val;
}
```

```java
// Java with Caffeine
Cache<String, Object> cache = Caffeine.newBuilder()
    .maximumSize(50_000)
    .expireAfterAccess(Duration.ofMinutes(10))
    .recordStats()  // enable hit/miss metrics
    .build();
```

### Distributed Caches (Redis / Memcached)

Use when multiple application instances must share cached data. Redis advantages over Memcached: data structures, persistence, pub/sub, Lua scripting, cluster mode.

## Redis Caching Patterns

### String (Simple Key-Value)
```redis
SET user:1001 '{"name":"Alice","email":"a@b.com"}' EX 3600
GET user:1001
```

### Hash (Structured Objects)
```redis
HSET product:500 name "Widget" price "29.99" stock "142"
HGET product:500 price
HINCRBY product:500 stock -1
```
Use hashes for partial reads/updates without deserializing the entire object.

### Sorted Set (Leaderboards / Rankings)
```redis
ZADD leaderboard 9500 "player:42"
ZADD leaderboard 8700 "player:17"
ZREVRANGE leaderboard 0 9 WITHSCORES   # top 10
ZRANK leaderboard "player:42"           # rank of specific player
```

### Pipeline for Bulk Operations
```python
pipe = redis.pipeline()
for user_id in user_ids:
    pipe.get(f"user:{user_id}")
results = pipe.execute()  # single round-trip for N commands
```
Pipelines reduce network round-trips from N to 1. Use for batch reads, bulk invalidation, or warming.

## Cache Invalidation Strategies

### TTL-Based
Set expiration on every cached entry. Simple and prevents unbounded staleness. Choose TTL based on data change frequency:
- Static config: 24h+
- User profiles: 5-30min
- Product listings: 1-5min
- Real-time pricing: 5-15s

### Event-Driven
Invalidate on data mutation events. Use database triggers, application events, or change data capture (CDC):
```python
# After order status change
def on_order_updated(order_id):
    redis.delete(f"order:{order_id}")
    redis.delete(f"user_orders:{order.user_id}")
    cdn.purge(f"/api/orders/{order_id}")
```

### Version-Based
Embed a version in cache keys. Increment version to invalidate all entries:
```python
VERSION = redis.get("cache:version") or "1"
cache_key = f"products:v{VERSION}:category:electronics"
# To invalidate all product caches:
redis.incr("cache:version")
```

### Tag-Based
Associate cache entries with tags. Invalidate all entries sharing a tag:
```python
def cache_set_with_tags(key, value, tags, ttl):
    redis.setex(key, ttl, value)
    for tag in tags:
        redis.sadd(f"tag:{tag}", key)

def invalidate_tag(tag):
    keys = redis.smembers(f"tag:{tag}")
    if keys:
        redis.delete(*keys)
    redis.delete(f"tag:{tag}")

# Usage
cache_set_with_tags("product:100", data, ["category:shoes", "brand:nike"], 3600)
invalidate_tag("brand:nike")  # clears all Nike products
```

## Multi-Layer Caching

Implement L1 (local) → L2 (distributed) → L3 (CDN) layers:

```
Request → CDN Edge (L3) → App In-Memory (L1) → Redis (L2) → Database
```

- **L1 (in-memory)**: Sub-millisecond reads, per-instance, short TTL (30-120s). Reduces L2 load.
- **L2 (Redis/Memcached)**: Shared across instances, medium TTL (5-60min). Single source of truth for cached data.
- **L3 (CDN)**: Edge-distributed, long TTL for static content, short TTL + stale-while-revalidate for dynamic.

```python
def get_data(key):
    # L1: local in-memory
    val = local_cache.get(key)
    if val: return val
    # L2: distributed
    val = redis.get(key)
    if val:
        local_cache.set(key, val, ttl=60)
        return val
    # Origin
    val = db.fetch(key)
    redis.setex(key, 1800, val)
    local_cache.set(key, val, ttl=60)
    return val
```

Invalidation in multi-layer: invalidate from outermost layer inward (CDN → Redis → local). Use pub/sub to notify all app instances to clear L1 entries.

## Cache Stampede Prevention

### Mutex / Distributed Lock
Only one process recomputes on miss; others wait or get stale data:
```python
def get_with_lock(key, ttl, loader):
    val = redis.get(key)
    if val: return val
    lock_key = f"lock:{key}"
    if redis.set(lock_key, "1", nx=True, ex=10):  # acquire lock
        try:
            val = loader()
            redis.setex(key, ttl, val)
            return val
        finally:
            redis.delete(lock_key)
    else:
        time.sleep(0.1)  # wait and retry
        return redis.get(key)
```

### Probabilistic Early Expiration (XFetch)
Each request has an increasing probability of triggering a refresh as TTL approaches zero. Spreads recomputation across time:
```python
import math, random, time

def xfetch(key, ttl, beta, loader):
    val, expiry = redis.get_with_expiry(key)
    remaining = expiry - time.time()
    if val is None or remaining - beta * math.log(random.random()) <= 0:
        val = loader()
        redis.setex(key, ttl, val)
    return val
# beta=1.0 is a good starting point; increase for earlier refresh
```

### Request Coalescing (Single-Flight)
Deduplicate concurrent requests for the same key. Only one fetch executes; others receive the same result:
```go
// Go singleflight
var group singleflight.Group
val, err, _ := group.Do(cacheKey, func() (interface{}, error) {
    return fetchFromDB(id)
})
```

## Cache Warming and Preloading

Populate cache before traffic arrives to avoid cold-start misses:

```python
def warm_cache():
    # Preload top 1000 products
    products = db.query("SELECT * FROM products ORDER BY views DESC LIMIT 1000")
    pipe = redis.pipeline()
    for p in products:
        pipe.setex(f"product:{p.id}", 3600, json.dumps(p.to_dict()))
    pipe.execute()
```

Trigger warming on: deployment, cache flush, scheduled intervals, predictable traffic spikes. Use pipelines for bulk loading.

## Monitoring

Track these metrics to maintain cache health:

- **Hit ratio**: Target >90% for most workloads. Below 80% indicates misconfigured TTL, key design issues, or insufficient memory.
- **Miss rate by key pattern**: Identify which data categories miss most frequently.
- **Latency (p50, p95, p99)**: L1 < 1ms, Redis < 5ms, CDN < 50ms. Investigate spikes.
- **Eviction count**: High evictions signal memory pressure. Increase `maxmemory` or reduce cached data.
- **Memory usage**: Monitor fragmentation ratio in Redis (`INFO memory`). Keep `mem_fragmentation_ratio` between 1.0-1.5.
- **Connection count**: Redis is single-threaded; too many connections cause queuing.

```redis
INFO stats       # hit/miss counts: keyspace_hits, keyspace_misses
INFO memory      # used_memory, fragmentation ratio
INFO clients     # connected_clients
```

Calculate hit ratio: `keyspace_hits / (keyspace_hits + keyspace_misses) * 100`

## Common Pitfalls and Anti-Patterns

- **Caching without TTL**: Leads to unbounded memory growth and stale data. Always set TTL.
- **Cache-then-database race**: Updating cache before DB commit risks caching uncommitted data. Delete cache after DB write, not before.
- **Over-caching**: Caching infrequently accessed data wastes memory. Cache hot data only.
- **Mega-keys**: Storing huge objects (>1MB) in a single key causes latency spikes. Break into smaller keys or use hashes.
- **Missing error handling**: Cache failures should fall through to origin, not crash the application. Treat cache as optional.
- **Ignoring serialization cost**: JSON/protobuf serialization can dominate latency for large objects. Profile and choose efficient formats (MessagePack, protobuf).
- **Dog-piling on cold start**: Deploying without cache warming causes all requests to hit origin simultaneously. Always warm critical caches.
- **Inconsistent key naming**: Use a consistent convention like `{entity}:{id}:{field}`. Document the schema.
- **Caching errors/nulls**: Avoid caching `null` results or error responses with long TTL. Use short TTL (30-60s) for negative caching to prevent repeated DB hits for missing data.
