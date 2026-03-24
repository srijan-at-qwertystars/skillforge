# Advanced Caching Patterns

## Table of Contents

- [Consistent Hashing for Cache Distribution](#consistent-hashing-for-cache-distribution)
- [Cache-Aside with Write-Through Hybrid](#cache-aside-with-write-through-hybrid)
- [Cache Warming Strategies](#cache-warming-strategies)
- [Probabilistic Early Expiration (XFetch)](#probabilistic-early-expiration-xfetch)
- [Request Coalescing and Deduplication](#request-coalescing-and-deduplication)
- [Negative Caching](#negative-caching)
- [Cache Versioning with Key Prefixes](#cache-versioning-with-key-prefixes)
- [Hot Key Detection and Mitigation](#hot-key-detection-and-mitigation)
- [Read-Your-Writes Consistency](#read-your-writes-consistency)
- [Cache Topology Patterns](#cache-topology-patterns)

---

## Consistent Hashing for Cache Distribution

### The Problem

Naive modular hashing (`hash(key) % N`) redistributes nearly all keys when a node is added or removed. With N=10 nodes losing one node, ~90% of keys remap, causing a cache avalanche.

### How Consistent Hashing Works

Nodes and keys are mapped onto a fixed hash ring (0 to 2^32-1). Each key is assigned to the first node encountered clockwise on the ring. Adding or removing a node only affects keys between it and its predecessor.

```
Ring positions (simplified):

     Node A (pos 100)
    /                \
Node D (pos 350)    Node B (pos 180)
    \                /
     Node C (pos 270)

Key with hash 150 → routes to Node B (first node clockwise)
Key with hash 300 → routes to Node D
```

### Virtual Nodes (Vnodes)

Physical nodes are mapped to multiple virtual positions on the ring. This ensures even distribution even when nodes have different capacities.

```python
import hashlib
from bisect import bisect_right

class ConsistentHash:
    def __init__(self, nodes=None, replicas=150):
        self.replicas = replicas
        self.ring = {}
        self.sorted_keys = []
        if nodes:
            for node in nodes:
                self.add_node(node)

    def _hash(self, key: str) -> int:
        return int(hashlib.md5(key.encode()).hexdigest(), 16)

    def add_node(self, node: str):
        for i in range(self.replicas):
            vnode_key = self._hash(f"{node}:vnode{i}")
            self.ring[vnode_key] = node
            self.sorted_keys.append(vnode_key)
        self.sorted_keys.sort()

    def remove_node(self, node: str):
        for i in range(self.replicas):
            vnode_key = self._hash(f"{node}:vnode{i}")
            del self.ring[vnode_key]
            self.sorted_keys.remove(vnode_key)

    def get_node(self, key: str) -> str:
        if not self.ring:
            raise ValueError("No nodes in ring")
        h = self._hash(key)
        idx = bisect_right(self.sorted_keys, h) % len(self.sorted_keys)
        return self.ring[self.sorted_keys[idx]]
```

### Practical Considerations

- **Replica count**: 100-200 vnodes per physical node provides good balance. Fewer vnodes = more variance in key distribution.
- **Weighted nodes**: Assign more vnodes to higher-capacity nodes.
- **Replication**: Store keys on N consecutive nodes clockwise for redundancy.
- **Jump consistent hash**: Alternative to ring-based hashing—faster, zero memory overhead, but only works when nodes are numbered sequentially (no arbitrary removal).

```python
# Jump consistent hash (Google, 2014)
def jump_consistent_hash(key: int, num_buckets: int) -> int:
    b, j = -1, 0
    while j < num_buckets:
        b = j
        key = ((key * 2862933555777941757) + 1) & 0xFFFFFFFFFFFFFFFF
        j = int((b + 1) * (1 << 31) / ((key >> 33) + 1))
    return b
```

---

## Cache-Aside with Write-Through Hybrid

### Motivation

Pure cache-aside risks serving stale data between a write and the next read-miss. Pure write-through adds latency to every write. A hybrid selects the strategy per data category.

### Pattern

```python
class HybridCache:
    """
    Uses write-through for high-read, low-write data (e.g., user profiles)
    and cache-aside for everything else.
    """
    WRITE_THROUGH_PREFIXES = {"user:", "config:", "product:"}

    def __init__(self, redis_client, db):
        self.redis = redis_client
        self.db = db

    def get(self, key: str):
        cached = self.redis.get(key)
        if cached is not None:
            return deserialize(cached)
        value = self.db.fetch(key)
        if value is not None:
            self.redis.setex(key, self._ttl_for(key), serialize(value))
        return value

    def set(self, key: str, value):
        self.db.save(key, value)
        if self._is_write_through(key):
            self.redis.setex(key, self._ttl_for(key), serialize(value))
        else:
            self.redis.delete(key)  # cache-aside: invalidate

    def _is_write_through(self, key: str) -> bool:
        return any(key.startswith(p) for p in self.WRITE_THROUGH_PREFIXES)

    def _ttl_for(self, key: str) -> int:
        if key.startswith("config:"):
            return 86400
        if key.startswith("user:"):
            return 1800
        return 300
```

### When to Use

| Criteria | Write-Through | Cache-Aside (invalidate) |
|----------|--------------|--------------------------|
| Read:write ratio | >100:1 | <100:1 |
| Consistency need | Strong | Eventual OK |
| Write latency tolerance | Higher | Lower |
| Cache miss cost | Very high | Moderate |

---

## Cache Warming Strategies

### Lazy Warming

Populate cache entries on first access (standard cache-aside behavior). Simple but causes cold-start latency spikes after deployments or cache flushes.

**Best for**: Long-tail data with unpredictable access patterns.

### Eager Warming

Pre-populate cache before traffic arrives. Load known hot data from the database or a snapshot.

```python
async def eager_warm(redis, db, batch_size=500):
    """Warm cache with top-accessed entities before deployment routes traffic."""
    hot_keys = await db.query(
        "SELECT id, data FROM products ORDER BY access_count DESC LIMIT 10000"
    )
    pipe = redis.pipeline()
    for i, row in enumerate(hot_keys):
        pipe.setex(f"product:{row['id']}", 3600, serialize(row['data']))
        if (i + 1) % batch_size == 0:
            await pipe.execute()
            pipe = redis.pipeline()
    await pipe.execute()
```

**Best for**: Deployments, cache node replacements, known traffic spikes.

### Scheduled Warming

Background jobs periodically refresh cache entries that will expire soon. Prevents expiration-driven misses entirely for critical data.

```python
import asyncio

async def scheduled_warmer(redis, db, interval=60):
    """Continuously refresh entries expiring within the next 2 minutes."""
    while True:
        expiring_keys = await find_expiring_keys(redis, threshold_seconds=120)
        for key in expiring_keys:
            entity_type, entity_id = parse_cache_key(key)
            fresh_data = await db.fetch(entity_type, entity_id)
            if fresh_data:
                await redis.setex(key, get_ttl(entity_type), serialize(fresh_data))
        await asyncio.sleep(interval)
```

**Best for**: Critical data paths where any cache miss is unacceptable (e.g., pricing, config).

### Comparison

| Strategy | Cold-start impact | Complexity | DB load | Best use case |
|----------|------------------|------------|---------|---------------|
| Lazy | High | Low | Spiky | Long-tail data |
| Eager | None | Medium | Burst at start | Deployments |
| Scheduled | None | High | Continuous low | Mission-critical data |

---

## Probabilistic Early Expiration (XFetch)

### Deep Dive

The XFetch algorithm (Vattani et al., 2015) prevents cache stampedes by having each request independently decide whether to recompute before the entry expires.

### The Math

The probability of recomputing increases exponentially as TTL approaches zero:

```
shouldRecompute = (currentTime - (expiryTime - ttl * beta * log(rand()))) >= 0
```

- `beta` controls aggressiveness (higher = earlier refresh).
- `log(rand())` is always negative, creating a probabilistic window.
- As `remaining TTL → 0`, the probability of refresh → 1.

### Production Implementation

```python
import math
import random
import time
import json
from dataclasses import dataclass
from typing import Any, Callable, Optional

@dataclass
class XFetchEntry:
    value: Any
    delta: float  # time to recompute in seconds
    created_at: float

class XFetchCache:
    def __init__(self, redis_client, beta: float = 1.0):
        self.redis = redis_client
        self.beta = beta

    def get_or_recompute(
        self,
        key: str,
        ttl: int,
        loader: Callable[[], Any],
        beta_override: Optional[float] = None,
    ) -> Any:
        beta = beta_override or self.beta
        raw = self.redis.get(key)

        if raw is not None:
            entry = json.loads(raw)
            remaining = self.redis.ttl(key)
            # XFetch probabilistic check
            gap = entry["delta"] * beta * math.log(random.random())
            if remaining + gap > 0:
                return entry["value"]

        # Recompute
        start = time.monotonic()
        value = loader()
        delta = time.monotonic() - start

        entry = {"value": value, "delta": delta, "created_at": time.time()}
        self.redis.setex(key, ttl, json.dumps(entry))
        return value
```

### Tuning Beta

- `beta = 0.5`: Conservative. Refresh mostly happens close to expiry. Lower overhead.
- `beta = 1.0`: Balanced. Good default for most workloads.
- `beta = 2.0`: Aggressive. Refresh starts earlier. Use for expensive computations.
- For computations taking >1s, use lower beta to avoid excessive early refreshes.

---

## Request Coalescing and Deduplication

### In-Process Coalescing (Single-Flight)

Multiple concurrent requests for the same cache key share a single backend fetch.

```typescript
class SingleFlight<T> {
  private inflight = new Map<string, Promise<T>>();

  async do(key: string, fn: () => Promise<T>): Promise<T> {
    const existing = this.inflight.get(key);
    if (existing) return existing;

    const promise = fn().finally(() => {
      this.inflight.delete(key);
    });
    this.inflight.set(key, promise);
    return promise;
  }
}

// Usage
const flight = new SingleFlight<User>();
async function getUser(id: string): Promise<User> {
  const cacheKey = `user:${id}`;
  return flight.do(cacheKey, async () => {
    const cached = await redis.get(cacheKey);
    if (cached) return JSON.parse(cached);
    const user = await db.findUser(id);
    await redis.setex(cacheKey, 3600, JSON.stringify(user));
    return user;
  });
}
```

### Cross-Process Coalescing (Distributed)

Use a distributed lock so that across all application instances, only one fetches the data:

```python
def coalesced_fetch(key: str, ttl: int, loader, wait_ms=50, max_retries=20):
    """Cross-process request coalescing using Redis locks."""
    value = redis.get(key)
    if value is not None:
        return json.loads(value)

    lock_key = f"lock:{key}"
    acquired = redis.set(lock_key, "1", nx=True, ex=10)

    if acquired:
        try:
            result = loader()
            redis.setex(key, ttl, json.dumps(result))
            return result
        finally:
            redis.delete(lock_key)
    else:
        # Another process is computing; poll for result
        for _ in range(max_retries):
            time.sleep(wait_ms / 1000)
            value = redis.get(key)
            if value is not None:
                return json.loads(value)
        # Fallback: compute ourselves
        return loader()
```

---

## Negative Caching

### Why Cache Misses

Without negative caching, repeated requests for non-existent data always hit the database. Common in user-facing search, 404 pages, or enumeration attacks.

### Implementation

```python
NEGATIVE_SENTINEL = "__NULL__"
NEGATIVE_TTL = 60  # short TTL for negative entries

def get_with_negative_cache(key: str, ttl: int, loader):
    cached = redis.get(key)
    if cached == NEGATIVE_SENTINEL:
        return None  # known miss
    if cached is not None:
        return json.loads(cached)

    result = loader()
    if result is None:
        redis.setex(key, NEGATIVE_TTL, NEGATIVE_SENTINEL)
    else:
        redis.setex(key, ttl, json.dumps(result))
    return result
```

### Bloom Filter for Existence Checks

For large keyspaces, use a Bloom filter to avoid cache and DB lookups entirely:

```python
from pybloom_live import BloomFilter

# Initialize with expected items and false positive rate
existence_filter = BloomFilter(capacity=1_000_000, error_rate=0.001)

def get_with_bloom(key: str, ttl: int, loader):
    entity_id = key.split(":")[-1]
    if entity_id not in existence_filter:
        return None  # definitely doesn't exist

    cached = redis.get(key)
    if cached is not None:
        return json.loads(cached)

    result = loader()
    if result is not None:
        redis.setex(key, ttl, json.dumps(result))
    return result
```

### Guidelines

- Keep negative TTL short (30-120s) to avoid masking newly created entities.
- Use distinct sentinel values (not empty string or `"null"`) to differentiate from real data.
- Monitor negative cache ratio—a high ratio may indicate an upstream issue.

---

## Cache Versioning with Key Prefixes

### Namespace-Level Versioning

Invalidate an entire namespace by incrementing a version counter:

```python
class VersionedCache:
    def __init__(self, redis_client, namespace: str):
        self.redis = redis_client
        self.namespace = namespace
        self.version_key = f"version:{namespace}"

    def _build_key(self, key: str) -> str:
        version = self.redis.get(self.version_key) or "0"
        return f"{self.namespace}:v{version}:{key}"

    def get(self, key: str):
        return self.redis.get(self._build_key(key))

    def set(self, key: str, value, ttl: int):
        self.redis.setex(self._build_key(key), ttl, value)

    def invalidate_all(self):
        """Invalidate all entries in this namespace. Old keys expire via TTL."""
        self.redis.incr(self.version_key)
```

### Schema-Aware Versioning

Embed the serialization schema version in keys to handle format migrations:

```python
SCHEMA_VERSION = "v3"  # bump when serialization format changes

def cache_key(entity: str, id: str) -> str:
    return f"{entity}:{SCHEMA_VERSION}:{id}"

# Old "user:v2:123" entries naturally expire
# New reads populate "user:v3:123"
```

### Benefits

- Zero-downtime cache migrations during deployments.
- Old entries expire naturally via TTL—no explicit purge needed.
- Schema version prevents deserialization errors after format changes.

---

## Hot Key Detection and Mitigation

### Detection

```python
# Redis 4.0+ LFU-based hot key detection
# Enable LFU: CONFIG SET maxmemory-policy allkeys-lfu

def detect_hot_keys(redis_client, sample_size=1000, threshold=100):
    """Sample keys and identify those with high access frequency."""
    hot_keys = []
    for _ in range(sample_size):
        key = redis_client.randomkey()
        if key:
            freq = redis_client.object("freq", key)
            if freq and freq > threshold:
                hot_keys.append((key, freq))
    return sorted(hot_keys, key=lambda x: x[1], reverse=True)
```

Use `redis-cli --hotkeys` (Redis 4.0+) for ad-hoc detection, or monitor `OBJECT FREQ <key>` for specific keys.

### Mitigation Strategies

**1. Local Cache (L1) for Hot Keys**

```python
from cachetools import TTLCache

local_hot_cache = TTLCache(maxsize=100, ttl=5)

def get_with_hot_key_protection(key: str, loader):
    if key in local_hot_cache:
        return local_hot_cache[key]
    value = redis.get(key)
    if value is None:
        value = loader()
        redis.setex(key, 300, serialize(value))
    local_hot_cache[key] = value
    return value
```

**2. Key Replication (Fan-Out Reads)**

```python
import random

REPLICAS = 3

def set_replicated(key: str, value, ttl: int):
    pipe = redis.pipeline()
    for i in range(REPLICAS):
        pipe.setex(f"{key}:r{i}", ttl, value)
    pipe.execute()

def get_replicated(key: str):
    replica = random.randint(0, REPLICAS - 1)
    return redis.get(f"{key}:r{replica}")
```

**3. Rate-Limit Cache Reads**

If a single key receives extreme QPS, implement client-side rate limiting to prevent overwhelming the cache node.

---

## Read-Your-Writes Consistency

### The Problem

After a user writes data, subsequent reads may hit a stale cache, showing old data. This is confusing in interactive UIs.

### Session-Aware Cache Bypass

```python
class ReadYourWritesCache:
    def __init__(self, redis_client, db):
        self.redis = redis_client
        self.db = db

    def write(self, key: str, value, session_id: str):
        self.db.save(key, value)
        self.redis.delete(key)
        # Mark this key as recently written by this session
        self.redis.setex(f"dirty:{session_id}:{key}", 10, "1")

    def read(self, key: str, session_id: str):
        # If this session recently wrote this key, bypass cache
        if self.redis.exists(f"dirty:{session_id}:{key}"):
            return self.db.fetch(key)
        cached = self.redis.get(key)
        if cached is not None:
            return json.loads(cached)
        value = self.db.fetch(key)
        if value is not None:
            self.redis.setex(key, 300, json.dumps(value))
        return value
```

### Write-Timestamp Approach

```python
def read_with_min_freshness(key: str, min_write_time: float):
    """Ensure cached data is at least as fresh as min_write_time."""
    cached = redis.hgetall(f"cache:{key}")
    if cached and float(cached.get("written_at", 0)) >= min_write_time:
        return json.loads(cached["value"])
    # Cache is stale relative to caller's write; fetch from DB
    value = db.fetch(key)
    redis.hset(f"cache:{key}", mapping={
        "value": json.dumps(value),
        "written_at": str(time.time()),
    })
    redis.expire(f"cache:{key}", 300)
    return value
```

---

## Cache Topology Patterns

### Replicated Cache

Every node holds a full copy of the cache. Reads are local and fast. Writes must propagate to all replicas.

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│  Node A  │  │  Node B  │  │  Node C  │
│ (full    │  │ (full    │  │ (full    │
│  copy)   │  │  copy)   │  │  copy)   │
└──────────┘  └──────────┘  └──────────┘
     │              │              │
     └──────── pub/sub ────────────┘
```

**Pros**: Fastest reads, resilient to single node failure.
**Cons**: Write amplification, memory inefficient (N copies), eventual consistency.
**Use when**: Small dataset, read-heavy, low write frequency (e.g., config, feature flags).

### Partitioned (Sharded) Cache

Data is distributed across nodes using consistent hashing. Each key lives on one node.

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│  Node A  │  │  Node B  │  │  Node C  │
│ keys     │  │ keys     │  │ keys     │
│ [A-H]    │  │ [I-P]    │  │ [Q-Z]    │
└──────────┘  └──────────┘  └──────────┘
```

**Pros**: Linear scalability, memory efficient.
**Cons**: Cross-partition queries impossible, node failure loses data slice.
**Use when**: Large dataset, need horizontal scaling (Redis Cluster).

### Hierarchical (Tiered)

L1 (local, per-process) → L2 (shared, distributed) → origin.

```
┌─────────────────────────────────┐
│         Application Pod         │
│  ┌───────────┐                  │
│  │ L1 Cache  │ (in-memory,     │
│  │           │  per-process)    │
│  └─────┬─────┘                  │
│        │ miss                   │
│        ▼                        │
│  ┌───────────┐                  │
│  │ L2 Cache  │ (Redis,         │
│  │           │  shared)         │
│  └─────┬─────┘                  │
│        │ miss                   │
│        ▼                        │
│  ┌───────────┐                  │
│  │ Database  │                  │
│  └───────────┘                  │
└─────────────────────────────────┘
```

**Pros**: Minimizes network calls, absorbs traffic spikes at L1.
**Cons**: L1 consistency lag, more complex invalidation.
**Use when**: High-throughput services, latency-sensitive paths.

### Near-Cache (Client-Side + Server-Side)

Client (browser/mobile) caches API responses. Server caches at application layer. Both caches are independently managed.

**Pros**: Eliminates network calls for repeat requests, offline-capable.
**Cons**: Hardest to invalidate, stale data risk highest.
**Use when**: Mobile apps, SPAs with predictable data access.

### Choosing a Topology

| Factor | Replicated | Partitioned | Hierarchical |
|--------|-----------|-------------|--------------|
| Dataset size | Small (<1GB) | Large (>1GB) | Any |
| Read latency | Lowest | Low | Lowest (L1 hit) |
| Write throughput | Low | High | Medium |
| Memory efficiency | Poor | Good | Good |
| Consistency | Eventual | Strong (per-key) | Eventual |
| Complexity | Medium | Medium | High |
