# Advanced Rate Limiting Patterns

## Table of Contents
- [Distributed Rate Limiting with Redis Cluster](#distributed-rate-limiting-with-redis-cluster)
- [Consistent Hashing for Rate Limit Keys](#consistent-hashing-for-rate-limit-keys)
- [Multi-Tier Rate Limits](#multi-tier-rate-limits)
- [Cost-Based / Weighted Rate Limiting](#cost-based--weighted-rate-limiting)
- [Adaptive Rate Limiting](#adaptive-rate-limiting)
- [Rate Limiting WebSocket Connections](#rate-limiting-websocket-connections)
- [GraphQL Query Cost Rate Limiting](#graphql-query-cost-rate-limiting)
- [Sidecar Pattern in Microservices](#sidecar-pattern-in-microservices)
- [Quota Management Systems](#quota-management-systems)

---

## Distributed Rate Limiting with Redis Cluster

Single-node Redis becomes a SPOF. Redis Cluster distributes keys across shards for HA and throughput.

### Architecture

```
┌──────────┐     ┌──────────┐     ┌──────────┐
│ App Node │     │ App Node │     │ App Node │
└────┬─────┘     └────┬─────┘     └────┬─────┘
     │                │                │
     └────────┬───────┴────────┬───────┘
              │                │
     ┌────────▼──┐      ┌─────▼───────┐
     │Redis Shard│      │Redis Shard  │
     │  (0-8191) │      │ (8192-16383)│
     └───────────┘      └─────────────┘
```

### Key Rules for Redis Cluster

- **Hash tags**: Use `{user_id}` in keys so all rate limit data for one user lands on the same shard: `rl:{user123}:minute`, `rl:{user123}:hour`.
- **Lua script locality**: Lua scripts run on a single shard. All `KEYS[]` in one script must hash to the same slot. Use hash tags to guarantee this.
- **Cross-slot operations**: Never call `KEYS` or `SCAN` across slots. Track keys per-user with hash-tagged sets if you need enumeration.

### Local + Sync Hybrid

For lowest latency, keep local token caches per app instance and periodically sync to Redis:

```python
class HybridRateLimiter:
    def __init__(self, redis, key, global_limit, sync_interval=5):
        self.local_tokens = global_limit // num_instances
        self.redis = redis
        self.key = key
        self.sync_interval = sync_interval

    def allow(self):
        if self.local_tokens > 0:
            self.local_tokens -= 1
            return True
        # Fallback: try to acquire from global pool
        remaining = self.redis.eval(TOKEN_BUCKET_LUA, 1, self.key, ...)
        return remaining >= 0

    def sync(self):
        """Called periodically — push local unused tokens back, pull fresh allocation."""
        self.redis.eval(SYNC_LUA, 1, self.key, self.local_tokens)
        self.local_tokens = self.redis.eval(ALLOCATE_LUA, 1, self.key, num_instances)
```

Trade-off: eventual consistency — total allowed requests may slightly exceed the global limit between sync intervals. Acceptable for non-billing limits.

---

## Consistent Hashing for Rate Limit Keys

When you shard rate limiters across multiple Redis instances (not Redis Cluster), use consistent hashing to:

1. **Distribute keys evenly** — prevents hot nodes.
2. **Minimize re-mapping on node add/remove** — only ~1/n keys move.
3. **Support weighted nodes** — assign more virtual nodes to beefier machines.

```python
import hashlib

class ConsistentHash:
    def __init__(self, nodes, replicas=150):
        self.ring = {}
        self.sorted_keys = []
        for node in nodes:
            for i in range(replicas):
                key = hashlib.md5(f"{node}:{i}".encode()).hexdigest()
                self.ring[key] = node
                self.sorted_keys.append(key)
        self.sorted_keys.sort()

    def get_node(self, rate_limit_key):
        h = hashlib.md5(rate_limit_key.encode()).hexdigest()
        for k in self.sorted_keys:
            if h <= k:
                return self.ring[k]
        return self.ring[self.sorted_keys[0]]
```

---

## Multi-Tier Rate Limits

Enforce multiple overlapping windows simultaneously. Users must stay under ALL tiers:

| Tier       | Window  | Limit  | Purpose                    |
|------------|---------|--------|----------------------------|
| Burst      | 1s      | 20     | Prevent spike abuse        |
| Short-term | 1min    | 200    | Normal usage cap           |
| Hourly     | 1hr     | 5,000  | Sustained usage cap        |
| Daily      | 24hr    | 50,000 | Billing/quota alignment    |

### Implementation: Check All Tiers Atomically

```lua
-- multi_tier_check.lua — check and increment all tiers in one call
local user_key = KEYS[1]
local now = tonumber(ARGV[1])
local tiers = cjson.decode(ARGV[2])
-- tiers = [{"window":1,"limit":20},{"window":60,"limit":200},...]

for _, tier in ipairs(tiers) do
    local k = user_key .. ":" .. tier.window
    local count = tonumber(redis.call('GET', k) or "0")
    if count >= tier.limit then
        return cjson.encode({allowed=false, tier=tier.window, retry_after=redis.call('TTL', k)})
    end
end

-- All tiers passed — increment all
for _, tier in ipairs(tiers) do
    local k = user_key .. ":" .. tier.window
    local c = redis.call('INCR', k)
    if c == 1 then redis.call('EXPIRE', k, tier.window) end
end

return cjson.encode({allowed=true})
```

Return which tier was hit in 429 responses so clients know the specific constraint.

---

## Cost-Based / Weighted Rate Limiting

Flat per-request limits are unfair when operations have vastly different costs.

### Cost Assignment Strategies

| Method             | Example                              | Pros                  | Cons                    |
|--------------------|--------------------------------------|-----------------------|-------------------------|
| Static per-route   | `GET /users: 1, POST /import: 50`    | Simple, predictable   | Doesn't reflect reality |
| Response-time      | Cost = ceil(response_ms / 100)       | Reflects actual load  | Retrospective only      |
| Payload size       | Cost = ceil(body_bytes / 1024)       | Fair for uploads      | Gameable                |
| DB query count     | Cost = num_queries                   | Maps to backend load  | Tight coupling          |
| Composite          | Weighted average of above            | Most accurate         | Complex                 |

### Implementation

Use token bucket with variable cost parameter:
```javascript
const cost = ENDPOINT_COSTS[`${req.method} ${req.path}`] || 1;
const remaining = await redis.eval(TOKEN_BUCKET_LUA, 1, key, capacity, refillRate, now, cost);
```

Expose cost in response headers: `RateLimit-Cost: 10` so clients can plan.

---

## Adaptive Rate Limiting

Dynamically adjust limits based on system health. Protect backends without static over-provisioning.

### Feedback Signals

| Signal            | Tighten When          | Relax When           |
|-------------------|-----------------------|----------------------|
| Error rate (5xx)  | > 5%                  | < 1%                 |
| P99 latency       | > 500ms               | < 100ms              |
| CPU utilization   | > 80%                 | < 50%                |
| Queue depth       | > 1000                | < 100                |

### PID Controller Approach

```python
class AdaptiveRateLimiter:
    def __init__(self, base_rate, min_rate, max_rate):
        self.current_rate = base_rate
        self.base_rate = base_rate
        self.min_rate = min_rate
        self.max_rate = max_rate
        self.error_integral = 0

    def adjust(self, error_rate, latency_p99):
        # Simple proportional-integral controller
        error = error_rate - 0.02  # target 2% error rate
        self.error_integral += error

        Kp, Ki = 0.5, 0.1
        adjustment = 1.0 - (Kp * error + Ki * self.error_integral)
        self.current_rate = max(self.min_rate,
                                min(self.max_rate,
                                    self.base_rate * adjustment))
```

Run `adjust()` every 10–30 seconds based on collected metrics. Push new rate to Redis so all nodes pick it up.

---

## Rate Limiting WebSocket Connections

WebSockets require two levels of rate limiting:

### 1. Connection Rate Limiting
```python
# Limit new connections per IP per minute
async def on_connect(websocket):
    key = f"ws:conn:{websocket.remote_address[0]}"
    conns = await redis.incr(key)
    if conns == 1:
        await redis.expire(key, 60)
    if conns > 10:  # max 10 new connections/minute/IP
        await websocket.close(1008, "Connection rate limit exceeded")
        return
```

### 2. Message Rate Limiting (per connection)
```python
# Token bucket per connection for message throughput
async def on_message(websocket, message):
    key = f"ws:msg:{websocket.id}"
    remaining = await redis.eval(TOKEN_BUCKET_LUA, 1, key,
                                  capacity=30, refill_rate=5, now=time.time(), cost=1)
    if remaining < 0:
        await websocket.send(json.dumps({"error": "message_rate_limited", "retry_ms": 200}))
        return
    await handle_message(message)
```

### 3. Bandwidth Limiting
Track bytes sent/received per connection per window. Useful for binary WebSocket protocols.

---

## GraphQL Query Cost Rate Limiting

A single GraphQL query can be trivially cheap or devastatingly expensive. Per-request counting is meaningless.

### Static Query Cost Analysis

Calculate cost before execution based on the query AST:

```typescript
function calculateQueryCost(ast: DocumentNode, costMap: CostMap): number {
  let cost = 0;
  visit(ast, {
    Field(node) {
      const fieldCost = costMap[node.name.value] || 1;
      // Multiply by pagination argument if present
      const first = node.arguments?.find(a => a.name.value === 'first');
      const multiplier = first ? parseInt((first.value as IntValueNode).value) : 1;
      cost += fieldCost * multiplier;
    }
  });
  return cost;
}

// Cost map
const COST_MAP = {
  user: 1, users: 2, posts: 3,
  comments: 2, search: 10, analytics: 20,
};
```

### Cost Budget Per Request

```
Query { users(first: 50) { posts(first: 10) { comments { text } } } }
Cost = users(2) × 50 + posts(3) × 50 × 10 + comments(2) × 50 × 10 = 1700
```

Reject if cost > max_query_cost (e.g., 2000). Rate limit on cost sum per window.

### Response Header

```
X-GraphQL-Cost: 1700
X-GraphQL-Cost-Remaining: 8300
X-GraphQL-Cost-Reset: 45
```

---

## Sidecar Pattern in Microservices

Decouple rate limiting from application code by running it as a sidecar proxy.

### Architecture

```
┌─────────────────────────────┐
│           Pod               │
│  ┌──────────┐  ┌─────────┐ │
│  │ App      │  │ Sidecar │ │
│  │ Container│◄─┤ (Envoy) │◄├── Incoming traffic
│  │ :8080    │  │ :8443   │ │
│  └──────────┘  └────┬────┘ │
│                     │      │
└─────────────────────┼──────┘
                      │
                ┌─────▼─────┐
                │   Redis   │
                │  (shared) │
                └───────────┘
```

### Benefits
- **Language-agnostic**: Works for Go, Python, Java, Node — anything.
- **Consistent policy**: One config for all services.
- **Independent scaling**: Update rate limit rules without redeploying apps.
- **Observability**: Sidecar emits metrics (allowed/blocked/error counts).

### Envoy Rate Limit Service Config

```yaml
# Envoy filter config
http_filters:
  - name: envoy.filters.http.ratelimit
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.ratelimit.v3.RateLimit
      domain: my-api
      rate_limit_service:
        grpc_service:
          envoy_grpc:
            cluster_name: rate_limit_service
        transport_api_version: V3
```

The rate limit service (e.g., `envoyproxy/ratelimit`) connects to Redis and evaluates descriptors.

---

## Quota Management Systems

Quotas differ from rate limits: they enforce cumulative budgets (monthly API calls, storage, bandwidth) rather than instantaneous rates.

### Quota vs Rate Limit

| Aspect       | Rate Limit              | Quota                       |
|--------------|-------------------------|-----------------------------|
| Window       | Seconds/minutes         | Days/months/billing cycles  |
| Reset        | Rolling or fixed        | Calendar or manual          |
| Enforcement  | Immediate reject        | Soft warn → hard block      |
| Tracking     | Redis counters          | Persistent DB + Redis cache |
| Overage      | Retry later             | Upgrade plan or wait        |

### Implementation Pattern

```python
class QuotaManager:
    def __init__(self, db, redis):
        self.db = db
        self.redis = redis

    async def check_and_decrement(self, user_id, cost=1):
        cache_key = f"quota:{user_id}:{current_billing_period()}"

        # Fast path: check Redis cache
        remaining = await self.redis.get(cache_key)
        if remaining is not None and int(remaining) >= cost:
            await self.redis.decrby(cache_key, cost)
            return True

        # Slow path: reload from DB
        quota = await self.db.get_quota(user_id)
        used = await self.db.get_usage(user_id, current_billing_period())
        remaining = quota.limit - used

        if remaining < cost:
            return False

        await self.db.increment_usage(user_id, cost)
        await self.redis.set(cache_key, remaining - cost, ex=3600)
        return True
```

### Quota Notifications
Send alerts at 80%, 90%, 100% of quota. Include upgrade CTAs. Log overages for billing reconciliation.

### Grace Periods and Overdraft
Allow small overages (e.g., 5%) to avoid cutting off requests mid-operation. Bill overages separately.
