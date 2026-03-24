# Caching Troubleshooting Guide

## Table of Contents

- [Cache Stampede / Thundering Herd](#cache-stampede--thundering-herd)
- [Stale Data Serving](#stale-data-serving)
- [Cache Poisoning](#cache-poisoning)
- [Memory Pressure and OOM](#memory-pressure-and-oom)
- [Redis Connection Pool Exhaustion](#redis-connection-pool-exhaustion)
- [Serialization / Deserialization Errors](#serialization--deserialization-errors)
- [Cache Key Collision](#cache-key-collision)
- [Inconsistent Cache Across Nodes](#inconsistent-cache-across-nodes)
- [TTL Too Short or Too Long](#ttl-too-short-or-too-long)
- [Debugging Cache Behavior](#debugging-cache-behavior)

---

## Cache Stampede / Thundering Herd

### Symptoms

- Sudden spike in database queries after a popular cache entry expires.
- CPU/memory spike on origin servers.
- Latency increases across all requests, not just the affected key.
- Redis `INFO stats` shows a burst in `keyspace_misses`.

### Root Causes

1. A high-traffic key expires and hundreds of concurrent requests all miss simultaneously.
2. Cache flush or restart without warming.
3. Identical TTLs on related keys cause synchronized expiration.

### Solutions

**Mutex lock** — Only one request recomputes; others wait:

```python
def get_with_mutex(key, ttl, loader, lock_ttl=10):
    value = redis.get(key)
    if value is not None:
        return json.loads(value)

    lock_key = f"lock:{key}"
    if redis.set(lock_key, "1", nx=True, ex=lock_ttl):
        try:
            value = loader()
            redis.setex(key, ttl, json.dumps(value))
            return value
        finally:
            redis.delete(lock_key)
    else:
        # Spin-wait with backoff
        for i in range(20):
            time.sleep(0.05 * (1.5 ** min(i, 5)))
            value = redis.get(key)
            if value is not None:
                return json.loads(value)
        return loader()  # fallback
```

**Stale-while-revalidate** — Serve stale data while refreshing in background:

```python
def get_with_stale(key, ttl, stale_ttl, loader):
    raw = redis.get(key)
    if raw:
        entry = json.loads(raw)
        if entry["expires_at"] > time.time():
            return entry["value"]  # fresh
        # Stale but usable—trigger background refresh
        threading.Thread(target=lambda: refresh(key, ttl, stale_ttl, loader)).start()
        return entry["value"]
    return refresh(key, ttl, stale_ttl, loader)

def refresh(key, ttl, stale_ttl, loader):
    value = loader()
    entry = {"value": value, "expires_at": time.time() + ttl}
    redis.setex(key, ttl + stale_ttl, json.dumps(entry))
    return value
```

**TTL jitter** — Add randomness to prevent synchronized expiration:

```python
import random

def set_with_jitter(key, value, base_ttl, jitter_pct=0.1):
    jitter = int(base_ttl * jitter_pct * (2 * random.random() - 1))
    redis.setex(key, base_ttl + jitter, value)
```

---

## Stale Data Serving

### Symptoms

- Users see outdated information after updates (e.g., old profile picture, wrong price).
- Data is correct in the database but incorrect in the application.
- Inconsistency resolves itself after some time (TTL expiry).

### Root Causes

1. Cache not invalidated after database write.
2. Race condition: cache populated from a read before a concurrent write commits.
3. Multiple cache layers (L1 + L2) with different invalidation timing.
4. CDN serving cached response with long `s-maxage`.

### Diagnostic Steps

```bash
# Check if the stale value is in Redis
redis-cli GET "user:12345"

# Check the TTL remaining
redis-cli TTL "user:12345"

# Check what the DB has
psql -c "SELECT * FROM users WHERE id = 12345"

# Compare timestamps
redis-cli OBJECT IDLETIME "user:12345"
```

### Solutions

1. **Always invalidate on write** — Delete cache entries after successful DB commits, never before.
2. **Use event-driven invalidation** — Publish DB change events and have cache subscribers react.
3. **Add a write-through path** for critical data that must be immediately consistent.
4. **Shorten TTL** for frequently-updated data.
5. **Implement read-your-writes consistency** — Bypass cache for the writing user's session (see advanced-patterns.md).

---

## Cache Poisoning

### Symptoms

- Incorrect, malformed, or malicious data served from cache.
- Error responses or partial data cached and served repeatedly.
- All users see the same broken content for the key's TTL duration.

### Root Causes

1. Error response (500, timeout) cached with a normal TTL.
2. Malformed input used as part of cache key, causing cross-user contamination.
3. User-controlled input influences cache key without sanitization.
4. Upstream API returns garbage during an outage, which gets cached.

### Solutions

**Never cache error responses with normal TTLs:**

```python
def safe_cache_fetch(key, ttl, loader):
    cached = redis.get(key)
    if cached is not None:
        return json.loads(cached)
    try:
        result = loader()
        if result is not None:
            redis.setex(key, ttl, json.dumps(result))
        return result
    except Exception:
        # Do NOT cache the error
        # Optionally set a short negative cache to prevent repeated failures
        redis.setex(key, 5, json.dumps({"__error__": True}))
        raise
```

**Validate data before caching:**

```python
def cache_with_validation(key, value, ttl, validator):
    if not validator(value):
        logger.warning(f"Rejecting invalid cache value for {key}")
        return
    redis.setex(key, ttl, json.dumps(value))
```

**Sanitize cache keys:**

```python
import re

def safe_cache_key(*parts):
    sanitized = [re.sub(r'[^a-zA-Z0-9_:-]', '', str(p)) for p in parts]
    return ":".join(sanitized)
```

---

## Memory Pressure and OOM

### Symptoms

- Redis `used_memory` approaching or exceeding `maxmemory`.
- High eviction count (`evicted_keys` in `INFO stats`).
- `OOM command not allowed when used memory > 'maxmemory'` errors.
- Increased latency due to active key eviction during writes.

### Diagnostic Commands

```bash
# Memory overview
redis-cli INFO memory

# Key metrics to check:
# used_memory_human: actual memory used
# maxmemory_human: configured limit
# mem_fragmentation_ratio: > 1.5 indicates fragmentation
# evicted_keys: keys removed due to memory pressure

# Find large keys
redis-cli --bigkeys

# Memory usage of a specific key
redis-cli MEMORY USAGE "my:large:key"

# Sample-based memory analysis
redis-cli --memkeys --memkeys-samples 100
```

### Solutions

1. **Set appropriate maxmemory and eviction policy:**
   ```
   CONFIG SET maxmemory 4gb
   CONFIG SET maxmemory-policy allkeys-lru
   ```

2. **Reduce value sizes:**
   - Use MessagePack or Protobuf instead of JSON.
   - Compress large values with zstd/lz4.
   - Use Redis hashes for small objects (ziplist encoding is memory-efficient).

3. **Audit key expiration:**
   ```bash
   # Find keys without TTL (potential memory leaks)
   redis-cli --scan --pattern "*" | while read key; do
     ttl=$(redis-cli TTL "$key")
     if [ "$ttl" = "-1" ]; then
       echo "NO TTL: $key ($(redis-cli MEMORY USAGE "$key") bytes)"
     fi
   done
   ```

4. **Address memory fragmentation:**
   ```bash
   # Check fragmentation ratio
   redis-cli INFO memory | grep mem_fragmentation_ratio
   # If > 1.5, consider:
   # - Redis 4.0+: CONFIG SET activedefrag yes
   # - Or restart Redis during maintenance window
   ```

---

## Redis Connection Pool Exhaustion

### Symptoms

- `redis.exceptions.ConnectionError: Error connecting to Redis` or similar.
- Application threads blocking on connection acquisition.
- Timeouts when performing Redis operations.
- `INFO clients` shows `connected_clients` near the `maxclients` limit.

### Diagnostic Steps

```bash
# Check connected clients
redis-cli INFO clients
# connected_clients: current connections
# blocked_clients: clients in blocking calls
# maxclients: configured limit (default 10000)

# List all client connections with details
redis-cli CLIENT LIST

# Check for idle connections
redis-cli CLIENT LIST | awk -F'[ =]' '{for(i=1;i<=NF;i++) if($i=="idle") print $(i+1)}' | sort -n | tail
```

### Solutions

1. **Tune connection pool size:**
   ```python
   # Python (redis-py)
   pool = redis.ConnectionPool(
       host='redis-host',
       port=6379,
       max_connections=50,       # match expected concurrency
       socket_connect_timeout=5,
       socket_timeout=5,
       retry_on_timeout=True,
   )
   client = redis.Redis(connection_pool=pool)
   ```

2. **Set client timeout on Redis server:**
   ```
   CONFIG SET timeout 300       # close idle connections after 5 min
   CONFIG SET tcp-keepalive 60  # TCP keepalive probe interval
   ```

3. **Implement connection health checks:**
   ```python
   pool = redis.ConnectionPool(
       host='redis-host',
       max_connections=50,
       health_check_interval=30,  # ping every 30s
   )
   ```

4. **Monitor and alert** on `connected_clients` approaching `maxclients`.

---

## Serialization / Deserialization Errors

### Symptoms

- `json.decoder.JSONDecodeError` or similar parsing errors on cache reads.
- Type mismatch errors after reading from cache.
- Application crashes when deserializing cached objects.
- Errors appear after deployments that change data models.

### Root Causes

1. Schema change (added/removed fields) makes old cached values incompatible.
2. Encoding mismatch (bytes vs string, Unicode issues).
3. Corrupted data in cache (partial write, network error).
4. Mixed serialization formats (JSON in some code paths, MessagePack in others).

### Solutions

**Use versioned serialization:**

```python
import json

CACHE_SCHEMA_VERSION = 3

def serialize(value):
    return json.dumps({"v": CACHE_SCHEMA_VERSION, "d": value})

def deserialize(raw):
    if raw is None:
        return None
    try:
        wrapper = json.loads(raw)
        if wrapper.get("v") != CACHE_SCHEMA_VERSION:
            return None  # version mismatch; treat as cache miss
        return wrapper["d"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return None  # corrupted; treat as cache miss
```

**Always handle deserialization failures gracefully:**

```python
def safe_cache_get(key, loader, ttl):
    raw = redis.get(key)
    if raw is not None:
        try:
            return deserialize(raw)
        except Exception as e:
            logger.warning(f"Cache deserialization failed for {key}: {e}")
            redis.delete(key)  # remove corrupted entry
    value = loader()
    redis.setex(key, ttl, serialize(value))
    return value
```

---

## Cache Key Collision

### Symptoms

- Users see data belonging to other users.
- Cached values don't match expected data for the entity.
- Intermittent: occurs only when two distinct entities happen to hash to the same key.

### Root Causes

1. Insufficient key specificity: using `cache:{id}` instead of `cache:{entity}:{id}`.
2. Hashing user input to a short hash that can collide.
3. Multi-tenant system using shared cache without tenant prefix.
4. Parameter ordering: `search:color=red&size=L` vs `search:size=L&color=red`.

### Solutions

**Use structured, explicit cache keys:**

```python
def build_cache_key(entity: str, id: str, tenant: str = None, **params) -> str:
    parts = []
    if tenant:
        parts.append(f"t:{tenant}")
    parts.append(entity)
    parts.append(str(id))
    if params:
        # Sort parameters for deterministic keys
        sorted_params = sorted(params.items())
        param_str = "&".join(f"{k}={v}" for k, v in sorted_params)
        parts.append(hashlib.sha256(param_str.encode()).hexdigest()[:12])
    return ":".join(parts)

# Examples:
# build_cache_key("user", "123", tenant="acme")        → "t:acme:user:123"
# build_cache_key("search", "products", q="red shoes") → "search:products:a1b2c3d4e5f6"
```

**Avoid short hashes for cache keys** — Use at least 12 hex chars if hashing is necessary.

---

## Inconsistent Cache Across Nodes

### Symptoms

- Different application instances return different data for the same request.
- Behavior changes depending on which server handles the request (load-balancer dependent).
- L1 (local) caches across pods are out of sync.

### Root Causes

1. Local (in-process) caches not invalidated when shared cache is updated.
2. Race condition during cache population across instances.
3. Network partition causing some nodes to miss invalidation events.
4. Clock skew affecting TTL-based expiration.

### Solutions

**Pub/Sub-based L1 invalidation:**

```python
import threading

class CoherentCache:
    def __init__(self, redis_client, local_cache):
        self.redis = redis_client
        self.local = local_cache
        self._start_invalidation_listener()

    def _start_invalidation_listener(self):
        def listener():
            pubsub = self.redis.pubsub()
            pubsub.subscribe("cache:invalidate")
            for msg in pubsub.listen():
                if msg["type"] == "message":
                    key = msg["data"].decode()
                    self.local.delete(key)
        threading.Thread(target=listener, daemon=True).start()

    def invalidate(self, key):
        self.redis.delete(key)
        self.local.delete(key)
        self.redis.publish("cache:invalidate", key)

    def get(self, key, loader, ttl):
        val = self.local.get(key)
        if val is not None:
            return val
        val = self.redis.get(key)
        if val is not None:
            self.local.set(key, val, ttl=min(ttl, 30))
            return val
        val = loader()
        self.redis.setex(key, ttl, val)
        self.local.set(key, val, ttl=min(ttl, 30))
        return val
```

**Keep L1 TTLs very short** (5-30s) to limit inconsistency window.

---

## TTL Too Short or Too Long

### Symptoms

**TTL too short:**
- Low cache hit ratio (<80%).
- High database/origin load despite caching layer.
- Redis `keyspace_misses` disproportionately high.

**TTL too long:**
- Users seeing stale data after updates.
- Memory usage growing because stale entries aren't evicted.
- Manual cache purges needed frequently.

### Diagnostic Process

```bash
# Sample actual TTLs across key patterns
redis-cli --scan --pattern "user:*" | head -100 | while read key; do
  echo "$key TTL=$(redis-cli TTL "$key")"
done

# Check hit/miss ratio
redis-cli INFO stats | grep keyspace
# keyspace_hits:12345678
# keyspace_misses:1234567
# hit_ratio = hits / (hits + misses)
```

### TTL Selection Framework

| Data Type | Change Frequency | Staleness Tolerance | Recommended TTL |
|-----------|-----------------|---------------------|-----------------|
| App config / feature flags | Rarely | Minutes | 5-60 min |
| User profile | Occasionally | Seconds | 5-15 min |
| Product catalog | Daily | Minutes | 5-30 min |
| Search results | Per-query | Minutes | 1-5 min |
| API rate limit counters | Per-second | None | Match window exactly |
| Session data | Per-request | None | Session duration |
| Real-time pricing | Continuous | Seconds | 5-30 sec |
| Static assets (versioned) | Never | N/A | 1 year (immutable) |

### Dynamic TTL Based on Access Patterns

```python
def adaptive_ttl(key: str, base_ttl: int, min_ttl: int = 30) -> int:
    """Increase TTL for frequently accessed keys, decrease for rare ones."""
    freq = redis.object("freq", key) or 0
    if freq > 200:
        return base_ttl * 2
    if freq > 50:
        return base_ttl
    return max(min_ttl, base_ttl // 2)
```

---

## Debugging Cache Behavior

### Hit/Miss Logging

**Application-level logging:**

```python
import logging
import functools

logger = logging.getLogger("cache")

def cache_instrumented(key: str, loader, ttl: int):
    cached = redis.get(key)
    if cached is not None:
        logger.debug(f"CACHE HIT key={key} ttl_remaining={redis.ttl(key)}")
        return json.loads(cached)

    logger.info(f"CACHE MISS key={key}")
    start = time.monotonic()
    value = loader()
    duration = time.monotonic() - start
    logger.info(f"CACHE FILL key={key} load_time={duration:.3f}s ttl={ttl}")
    redis.setex(key, ttl, json.dumps(value))
    return value
```

**Redis MONITOR (use sparingly in production):**

```bash
# Watch all Redis commands in real-time (high overhead!)
redis-cli MONITOR | grep -E "GET|SET|DEL" | head -100

# Filter for specific key patterns
redis-cli MONITOR | grep "user:" | head -50
```

**Redis SLOWLOG:**

```bash
# View slow queries (default threshold: 10ms)
redis-cli SLOWLOG GET 20

# Set threshold to 5ms
redis-cli CONFIG SET slowlog-log-slower-than 5000

# Get count of slow queries
redis-cli SLOWLOG LEN
```

### Metrics to Instrument

```python
from prometheus_client import Counter, Histogram

cache_ops = Counter(
    "cache_operations_total",
    "Cache operations by type and result",
    ["operation", "result", "key_prefix"]
)

cache_latency = Histogram(
    "cache_latency_seconds",
    "Cache operation latency",
    ["operation", "key_prefix"],
    buckets=[0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.5]
)

def instrumented_get(key: str):
    prefix = key.split(":")[0]
    with cache_latency.labels("get", prefix).time():
        value = redis.get(key)
    if value is not None:
        cache_ops.labels("get", "hit", prefix).inc()
    else:
        cache_ops.labels("get", "miss", prefix).inc()
    return value
```

### Useful Redis Debug Commands

```bash
# Key inspection
redis-cli TYPE "my:key"              # data type
redis-cli OBJECT ENCODING "my:key"   # internal encoding
redis-cli OBJECT IDLETIME "my:key"   # seconds since last access
redis-cli OBJECT FREQ "my:key"       # access frequency (LFU mode)
redis-cli DEBUG OBJECT "my:key"      # detailed internal info
redis-cli MEMORY USAGE "my:key"      # bytes consumed

# Keyspace analysis
redis-cli DBSIZE                     # total key count
redis-cli --scan --pattern "user:*" | wc -l   # count by pattern
redis-cli INFO keyspace              # per-database key counts

# Latency diagnostics
redis-cli --latency                  # continuous latency sampling
redis-cli --latency-history          # latency over time
redis-cli --intrinsic-latency 5      # baseline system latency (5s test)

# Client diagnostics
redis-cli CLIENT LIST                # all connections
redis-cli CLIENT GETNAME             # current client name
redis-cli INFO clients               # client stats summary
```

### Common Debugging Checklist

1. **Is the key in the cache?** `EXISTS key` → 0 means miss.
2. **What's the TTL?** `TTL key` → -2 means expired/doesn't exist, -1 means no expiry.
3. **Is the value correct?** `GET key` and compare with DB.
4. **When was it last accessed?** `OBJECT IDLETIME key`.
5. **Is it being evicted?** Check `evicted_keys` in `INFO stats`.
6. **Is something else deleting it?** `redis-cli MONITOR | grep DEL`.
7. **Is the connection healthy?** `redis-cli PING` → should return `PONG`.
8. **Is there replication lag?** `INFO replication` → check `master_repl_offset` vs replica offsets.
