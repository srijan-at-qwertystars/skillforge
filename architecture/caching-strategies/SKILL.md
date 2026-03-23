---
name: caching-strategies
description:
  positive: "Use when user implements application-level caching, asks about cache-aside, write-through, write-behind, cache invalidation, TTL strategies, distributed caching, multi-layer caching, or cache warming."
  negative: "Do NOT use for HTTP/CDN caching (use http-caching skill), Redis data structures (use redis-patterns skill), or browser caching."
---

# Application Caching Strategies

## Caching Fundamentals

**Cache hit**: requested data found in cache. **Cache miss**: data absent, must fetch from origin.

**Hit ratio** = hits / (hits + misses). Target ≥95% for hot-path caches.

Core trade-off: **latency vs consistency**. Aggressive caching reduces latency but increases staleness risk. Conservative caching maintains freshness but adds origin load.

**When to cache:**
- Data is read far more often than written (read:write ratio ≥10:1)
- Origin fetch is expensive (DB query, API call, computation)
- Staleness is tolerable for the use case

**When NOT to cache:**
- Data changes on every request
- Strong consistency is non-negotiable and invalidation cost exceeds origin cost
- Data is security-sensitive and cache layer lacks equivalent access controls

## Caching Patterns

### Cache-Aside (Lazy Loading)

Application manages cache reads and writes explicitly. Default starting pattern.

```python
# Python — cache-aside
def get_user(user_id: str) -> User:
    cached = cache.get(f"user:{user_id}")
    if cached is not None:
        return deserialize(cached)
    user = db.query("SELECT * FROM users WHERE id = %s", user_id)
    cache.set(f"user:{user_id}", serialize(user), ex=300)
    return user

def update_user(user_id: str, data: dict) -> None:
    db.execute("UPDATE users SET ... WHERE id = %s", user_id)
    cache.delete(f"user:{user_id}")  # invalidate, don't update
```

- Prefer **delete-on-write** over update-on-write to avoid race conditions.
- Only caches data that is actually requested (no wasted memory).
- Risk: cache stampede on popular keys after expiry.

### Read-Through

Cache itself loads from origin on miss. Application only talks to cache.

```java
// Java — read-through with Caffeine
LoadingCache<String, User> cache = Caffeine.newBuilder()
    .maximumSize(10_000)
    .expireAfterWrite(Duration.ofMinutes(5))
    .build(userId -> userRepository.findById(userId));

User user = cache.get(userId); // auto-loads on miss
```

- Simplifies application code — single call site.
- Requires cache library/provider that supports loader functions.

### Write-Through

Writes go to cache and origin synchronously. Cache always reflects latest state.

```typescript
// TypeScript — write-through
async function saveProduct(product: Product): Promise<void> {
  await db.products.update(product.id, product);
  await cache.set(`product:${product.id}`, JSON.stringify(product), { EX: 600 });
}
```

- Guarantees cache consistency on writes.
- Higher write latency — blocked on both cache and DB.
- Pair with read-through for a fully transparent caching layer.

### Write-Behind (Write-Back)

Writes go to cache first, then asynchronously flush to origin in batches.

```python
# Python — write-behind with buffered flush
write_queue: queue.Queue = queue.Queue()

def save_metric(key: str, value: float) -> None:
    cache.set(f"metric:{key}", value)
    write_queue.put((key, value))

def flush_worker():
    while True:
        batch = []
        while not write_queue.empty() and len(batch) < 100:
            batch.append(write_queue.get_nowait())
        if batch:
            db.bulk_insert("metrics", batch)
        time.sleep(1)
```

- Dramatically reduces write latency and DB load.
- Risk of data loss if cache node crashes before flush.
- Use for analytics, counters, logs — not financial transactions.

### Refresh-Ahead

Proactively refresh cache entries before they expire.

```java
// Java — refresh-ahead with Caffeine
LoadingCache<String, Config> cache = Caffeine.newBuilder()
    .maximumSize(1_000)
    .refreshAfterWrite(Duration.ofMinutes(4))  // refresh at 4 min
    .expireAfterWrite(Duration.ofMinutes(5))   // hard expire at 5 min
    .build(key -> configService.load(key));
```

- Eliminates cache misses for hot keys.
- Background refresh keeps data fresh without blocking readers.
- Only effective for frequently accessed keys.

## Cache Invalidation Strategies

### TTL (Time-to-Live)

Set expiration on every cache entry. Simplest and most common.

```python
cache.set("product:42", data, ex=300)      # 5 minutes
cache.set("config:global", data, ex=3600)  # 1 hour for slow-changing data
```

- Add jitter to avoid mass expiry: `ttl = base_ttl + random(0, base_ttl * 0.1)`.
- Short TTL (seconds) for volatile data. Long TTL (hours) for reference data.

### Event-Driven Invalidation

Invalidate on data change events. Strongest consistency without polling. Publish invalidation events from write path. Use message brokers (Kafka, RabbitMQ, Redis Pub/Sub) for cross-service invalidation.

```python
def on_order_updated(event: OrderEvent) -> None:
    cache.delete(f"order:{event.order_id}")
    cache.delete(f"user_orders:{event.user_id}")
```

### Version-Based Invalidation

Embed version in cache keys. Change version to invalidate all entries at once.

```typescript
const CACHE_VERSION = "v3";
const key = `${CACHE_VERSION}:product:${productId}`;
// Deploy with CACHE_VERSION = "v4" → all old keys become orphaned and expire
```

- Useful for schema changes or deployments.
- Old keys expire naturally via TTL — no explicit purge needed.

### Tag-Based Invalidation

Group related keys under tags. Invalidate all keys with a given tag. Maintain tag→key mappings as sets in the cache.

```python
def invalidate_tenant(tenant_id: str) -> None:
    tagged_keys = cache.smembers(f"tag:tenant:{tenant_id}")
    if tagged_keys:
        cache.delete(*tagged_keys, f"tag:tenant:{tenant_id}")
```

## Cache Key Design

Follow consistent conventions to avoid collisions and enable debugging.

```
{namespace}:{version}:{entity}:{id}:{variant}
```

**Rules:**
- **Namespace** by service/module: `orders:v2:order:12345`
- **Normalize inputs**: lowercase, sort query params, trim whitespace before hashing
- **Hash long keys**: SHA-256 for keys derived from complex queries
- **Include tenant/locale**: `tenant:acme:product:42:en-US`
- **Max 256 bytes** — long keys waste memory and slow lookups

```python
def cache_key(query: str, params: dict) -> str:
    normalized = query.strip().lower()
    param_str = "&".join(f"{k}={v}" for k, v in sorted(params.items()))
    return f"query:{hashlib.sha256(f'{normalized}?{param_str}'.encode()).hexdigest()[:16]}"
```

## Multi-Layer Caching

Stack caches for optimal latency and capacity.

```
Request → L1 (in-process) → L2 (distributed) → L3 (CDN/origin cache) → Origin
```

| Layer | Technology | Latency | Capacity | Scope |
|-------|-----------|---------|----------|-------|
| L1 | In-process (Caffeine, node-cache) | <1ms | Small (MB) | Per-instance |
| L2 | Distributed (Redis, Memcached) | 1-5ms | Large (GB-TB) | Shared across instances |
| L3 | CDN / reverse proxy | 5-50ms | Very large | Global edge |

```java
// Java — two-layer cache
public User getUser(String userId) {
    // L1: in-process
    User user = localCache.getIfPresent(userId);
    if (user != null) return user;

    // L2: distributed
    String json = redis.get("user:" + userId);
    if (json != null) {
        user = deserialize(json);
        localCache.put(userId, user);
        return user;
    }

    // Origin
    user = userRepository.findById(userId);
    redis.setex("user:" + userId, 300, serialize(user));
    localCache.put(userId, user);
    return user;
}
```

**Invalidation in multi-layer**: invalidate L2 first, broadcast to L1 instances via pub/sub.

## Distributed Caching

### Consistency

- Most distributed caches are **eventually consistent**.
- Use Redis Cluster or Memcached with consistent hashing for sharding.
- For strong consistency needs, use leader-based replication or accept higher latency.

### Partitioning

Distribute keys across nodes using consistent hashing to minimize reshuffling on node add/remove.

```
hash(key) → ring position → assigned node
```

- Virtual nodes improve balance: each physical node owns multiple ring positions.
- Monitor key distribution — hot keys on a single shard cause bottlenecks.

### Replication

- **Read replicas**: scale reads, tolerate node failure.
- **Async replication**: risk of stale reads after failover.
- Configure `replica-read` only for data tolerant of slight staleness.

### Cache Clusters — Operational Concerns

- Plan for **node failure**: application must handle cache unavailability gracefully (fall through to origin).
- Use **connection pooling** — creating connections per request is expensive.
- Set **timeouts** aggressively (50-200ms). A slow cache is worse than no cache.

## In-Process Caching

Use bounded, eviction-capable caches for hot data in the application process.

### Eviction Policies

| Policy | Description | Best For |
|--------|------------|----------|
| LRU | Evict least recently used | General purpose |
| LFU | Evict least frequently used | Skewed access patterns |
| W-TinyLFU | Window + frequency (Caffeine) | Best hit ratio in benchmarks |
| FIFO | Evict oldest entry | Simple, predictable |

### Language-Specific Libraries

```java
// Java — Caffeine (best-in-class for JVM)
Cache<String, Product> cache = Caffeine.newBuilder()
    .maximumSize(10_000)
    .expireAfterAccess(Duration.ofMinutes(10))
    .recordStats()
    .build();
```

```python
# Python — functools.lru_cache for simple memoization
from functools import lru_cache

@lru_cache(maxsize=1024)
def compute_score(user_id: int, category: str) -> float:
    return expensive_computation(user_id, category)

# Python — cachetools for more control
from cachetools import TTLCache
cache = TTLCache(maxsize=5000, ttl=300)
```

```typescript
// Node.js — node-cache
import NodeCache from "node-cache";
const cache = new NodeCache({ stdTTL: 300, maxKeys: 5000, checkperiod: 60 });
cache.set("key", value);
const result = cache.get<MyType>("key");
```

**Always set a max size.** Unbounded in-process caches cause OOM crashes.

## Cache Stampede Prevention

When a hot key expires, many concurrent requests rush to rebuild it.

### Mutex/Lock-Based

```python
import threading

_locks: dict[str, threading.Lock] = {}

def get_with_lock(key: str, loader, ttl: int = 300):
    value = cache.get(key)
    if value is not None:
        return value
    lock = _locks.setdefault(key, threading.Lock())
    if lock.acquire(timeout=5):
        try:
            value = cache.get(key)  # double-check
            if value is None:
                value = loader()
                cache.set(key, value, ex=ttl)
        finally:
            lock.release()
    else:
        value = cache.get(key)  # wait expired, try cache again
    return value
```

### Probabilistic Early Expiration (XFetch)

Randomly refresh before TTL expires. Higher traffic → earlier refresh.

```python
import math, random, time

def xfetch(key: str, loader, ttl: int, beta: float = 1.0):
    value, expiry = cache.get_with_expiry(key)
    remaining = expiry - time.time()
    if value is None or remaining - beta * math.log(random.random()) * (-1) <= 0:
        value = loader()
        cache.set(key, value, ex=ttl)
    return value
```

### Stale-While-Revalidate

Serve stale data immediately, refresh in background. If entry exists but is past soft TTL, return stale value and trigger async reload.

## Cache Warming and Preloading

### Startup Warming

Pre-populate cache on application start for known hot data.

```python
def warm_cache_on_startup():
    popular_products = db.query("SELECT * FROM products ORDER BY view_count DESC LIMIT 1000")
    with cache.pipeline() as pipe:
        for p in popular_products:
            pipe.set(f"product:{p.id}", serialize(p), ex=600)
        pipe.execute()
```

- Warm from read replicas to avoid loading the primary DB.
- Limit warming set size — only genuinely hot data.

### Predictive Warming

Track access patterns and refresh entries approaching expiry for the top-N hottest keys. Run as a periodic background job.

## Serialization

Choose format based on speed, size, and schema evolution needs.

| Format | Speed | Size | Schema Evolution | Language Support |
|--------|-------|------|-----------------|-----------------|
| JSON | Medium | Large | Flexible | Universal |
| MessagePack | Fast | Small | Flexible | Wide |
| Protocol Buffers | Fast | Smallest | Excellent | Wide |
| Pickle (Python) | Fast | Medium | Poor (security risk) | Python only |

**Rules:**
- Never cache language-specific serialization (Pickle, Java Serialization) in shared caches.
- Compress large values (>1KB) with LZ4 or zstd: `cache.set(key, zstd.compress(data))`.
- Include a schema version byte prefix to handle evolution: `b"\x02" + payload`.

## Monitoring

Track these metrics. Alert on deviations.

| Metric | Target | Alert When |
|--------|--------|-----------|
| Hit ratio | ≥95% | Drops below 90% |
| Miss rate | Low, stable | Sudden spikes |
| Eviction rate | Near zero | Sustained increase (cache too small) |
| Latency p99 | <5ms (distributed) | Exceeds 20ms |
| Memory usage | <80% capacity | Exceeds 90% |
| Connection pool usage | <70% | Exceeds 90% |

```python
stats = cache.stats()
log.info("hit_ratio=%.3f evictions=%d p99_ms=%.1f",
         stats.hit_ratio, stats.eviction_count, stats.avg_load_penalty_ms)
```

Set up dashboards showing hit ratio over time. A declining ratio signals changed access patterns or insufficient cache size.

## Framework-Specific Patterns

### Spring Boot (@Cacheable)

```java
@Cacheable(value = "products", key = "#id", unless = "#result == null")
public Product findById(String id) {
    return productRepository.findById(id).orElse(null);
}

@CacheEvict(value = "products", key = "#product.id")
public void update(Product product) { productRepository.save(product); }
```

```yaml
spring:
  cache:
    type: caffeine
    caffeine:
      spec: maximumSize=10000,expireAfterWrite=300s
```

### Django Cache Framework

```python
from django.core.cache import cache
from django.views.decorators.cache import cache_page

cache.set("my_key", value, timeout=300)
value = cache.get("my_key", default=None)

@cache_page(60 * 5)
def product_detail(request, product_id):
    return render(request, "detail.html", {"product": Product.objects.get(id=product_id)})
```

### NestJS CacheModule

```typescript
@Module({
  imports: [CacheModule.register({ store: redisStore, ttl: 300, max: 1000 })],
})
export class AppModule {}

@Controller("products")
@UseInterceptors(CacheInterceptor)
export class ProductController {
  constructor(@Inject(CACHE_MANAGER) private cache: Cache) {}

  @Get(":id")
  @CacheTTL(600)
  async findOne(@Param("id") id: string) { return this.productService.findById(id); }

  @Put(":id")
  async update(@Param("id") id: string, @Body() dto: UpdateProductDto) {
    await this.cache.del(`products:${id}`);
    return this.productService.update(id, dto);
  }
}
```

## Anti-Patterns

### Caching Mutable Session Data
Do not store rapidly mutating state (shopping carts, form drafts) in shared caches as primary storage.

### Unbounded Caches
Every in-process cache **must** have a `maxSize`. Every distributed cache entry **must** have a TTL.

### Cache as Source of Truth
Cache is ephemeral. Always ensure the origin can rebuild any cached entry. Test with cache fully cleared.

### Ignoring Cold Start
Plan for empty caches after deployments or failures. Implement warming strategies. Load-test with empty caches.

### Inconsistent Invalidation
If you update the DB in multiple code paths, ensure **all** paths invalidate the cache. Centralize writes behind a service layer.
