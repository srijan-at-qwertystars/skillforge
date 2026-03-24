# Advanced Rate Limiting Patterns

## Table of Contents

- [Adaptive Rate Limiting](#adaptive-rate-limiting)
- [Machine Learning-Based Anomaly Detection](#machine-learning-based-anomaly-detection)
- [Token Bucket with Burst Capacity](#token-bucket-with-burst-capacity)
- [Hierarchical Rate Limiting](#hierarchical-rate-limiting)
- [Rate Limiting in Microservices](#rate-limiting-in-microservices)
- [Fair Queuing](#fair-queuing)
- [Priority-Based Limiting](#priority-based-limiting)
- [Rate Limiting Webhooks and Callbacks](#rate-limiting-webhooks-and-callbacks)
- [API Monetization Tiers](#api-monetization-tiers)
- [GraphQL-Specific Rate Limiting](#graphql-specific-rate-limiting)

---

## Adaptive Rate Limiting

Adaptive rate limiting dynamically adjusts thresholds based on system health metrics rather than using static configurations. The goal is to maximize throughput when the system is healthy while protecting it under stress.

### Core Concept

Instead of a fixed `max_requests = 100/min`, the limit becomes a function of current system state:

```
effective_limit = base_limit × health_factor
health_factor = f(cpu_utilization, error_rate, response_latency, queue_depth)
```

### Implementation Approaches

**1. Load-Shedding Based on Latency**

Monitor P99 latency. When it exceeds a threshold, progressively reduce the rate limit:

```typescript
interface AdaptiveConfig {
  baseLimitPerSecond: number;
  latencyThresholds: { p99Ms: number; factor: number }[];
  minLimitPerSecond: number;
  adjustmentIntervalMs: number;
}

class AdaptiveRateLimiter {
  private currentFactor = 1.0;

  adjustFromMetrics(metrics: { p99LatencyMs: number; errorRate: number }): void {
    let factor = 1.0;
    for (const threshold of this.config.latencyThresholds) {
      if (metrics.p99LatencyMs > threshold.p99Ms) {
        factor = Math.min(factor, threshold.factor);
      }
    }
    // Smooth adjustment: don't swing wildly
    this.currentFactor = this.currentFactor * 0.7 + factor * 0.3;
  }

  get effectiveLimit(): number {
    return Math.max(
      this.config.minLimitPerSecond,
      Math.floor(this.config.baseLimitPerSecond * this.currentFactor)
    );
  }
}
```

**2. AIMD (Additive Increase, Multiplicative Decrease)**

Borrowed from TCP congestion control:

- **Additive Increase:** When system is healthy, increase limit by a constant `Δ` each interval.
- **Multiplicative Decrease:** When errors spike or latency exceeds thresholds, cut limit by a factor (e.g., halve it).

```python
class AIMDRateLimiter:
    def __init__(self, initial_limit=100, min_limit=10, max_limit=1000):
        self.limit = initial_limit
        self.min_limit = min_limit
        self.max_limit = max_limit
        self.additive_increase = 5
        self.multiplicative_decrease = 0.5

    def on_success(self):
        self.limit = min(self.max_limit, self.limit + self.additive_increase)

    def on_failure(self):
        self.limit = max(self.min_limit, int(self.limit * self.multiplicative_decrease))
```

**3. Feedback Loop with PID Controller**

Use a PID controller where the setpoint is a target error rate (e.g., 1%) and the output is the rate limit:

```
error = target_error_rate - current_error_rate
limit_adjustment = Kp * error + Ki * integral(error) + Kd * derivative(error)
new_limit = current_limit + limit_adjustment
```

This provides smooth, mathematically grounded adaptation. Tune Kp, Ki, Kd based on your system's response characteristics.

### When to Use Adaptive Limiting

- Multi-tenant platforms where traffic patterns are unpredictable
- Services with variable backend capacity (autoscaling, shared databases)
- During planned migrations or deployments when capacity changes
- Systems where over-provisioning static limits wastes resources

---

## Machine Learning-Based Anomaly Detection

ML-based anomaly detection identifies unusual request patterns that static rules miss, such as slow-and-low attacks, credential stuffing with rotating IPs, or automated scraping that mimics human behavior.

### Feature Engineering

Extract features from request streams per client key:

| Feature | Description |
|---|---|
| `req_rate_1m` | Requests per minute (rolling) |
| `req_rate_5m` | Requests per 5 minutes (rolling) |
| `unique_endpoints` | Distinct endpoints hit in window |
| `error_rate` | Fraction of 4xx/5xx responses |
| `payload_entropy` | Shannon entropy of request bodies |
| `inter_arrival_cv` | Coefficient of variation of request timing |
| `user_agent_changes` | Number of distinct User-Agents in window |
| `geo_distance_rate` | Rate of change in geolocation of IP |

### Model Approaches

**1. Statistical (No ML Infrastructure Required)**

Use z-score or IQR-based outlier detection on per-client request rates:

```python
import numpy as np

class StatisticalAnomalyDetector:
    def __init__(self, window_size=1000, z_threshold=3.0):
        self.observations = []
        self.z_threshold = z_threshold
        self.window_size = window_size

    def is_anomalous(self, value: float) -> bool:
        if len(self.observations) < 30:
            self.observations.append(value)
            return False
        mean = np.mean(self.observations[-self.window_size:])
        std = np.std(self.observations[-self.window_size:])
        if std == 0:
            return False
        z_score = abs(value - mean) / std
        self.observations.append(value)
        return z_score > self.z_threshold
```

**2. Isolation Forest**

Train on normal traffic patterns. Score each client's feature vector. High anomaly scores trigger stricter rate limits or CAPTCHAs:

```python
from sklearn.ensemble import IsolationForest

model = IsolationForest(contamination=0.01, random_state=42)
model.fit(normal_traffic_features)

# In request pipeline
score = model.decision_function([client_features])[0]
if score < anomaly_threshold:
    apply_strict_rate_limit(client_key)
```

**3. Time-Series Anomaly Detection**

Use Prophet, ARIMA, or exponential smoothing to model expected traffic per client or globally. Flag deviations beyond confidence intervals.

### Integration Architecture

```
Request → Feature Extractor → Feature Store (Redis)
                                    ↓
                            ML Scoring Service (async)
                                    ↓
                            Action: adjust rate limit / block / CAPTCHA
```

Keep scoring asynchronous to avoid adding latency. Update client classifications periodically (every 30s–5min) rather than per-request.

### Caution

- Start with simple statistical methods; add ML only when they fail
- Always have a manual override/allowlist mechanism
- Log all ML-driven enforcement decisions for audit
- Monitor false positive rate; ML models drift over time

---

## Token Bucket with Burst Capacity

The standard token bucket allows bursts up to bucket capacity. Advanced patterns add nuance to burst handling.

### Dual-Rate Token Bucket

Maintain two buckets: one for sustained rate, one for burst:

```typescript
interface DualRateBucket {
  sustained: { tokens: number; capacity: number; refillRate: number };
  burst: { tokens: number; capacity: number; refillRate: number };
}

function consumeDualRate(bucket: DualRateBucket): boolean {
  // Try sustained bucket first
  if (bucket.sustained.tokens >= 1) {
    bucket.sustained.tokens -= 1;
    return true;
  }
  // Fall back to burst bucket (more expensive for the client)
  if (bucket.burst.tokens >= 1) {
    bucket.burst.tokens -= 1;
    return true;
  }
  return false;
}
```

Use case: Allow `100 req/min` sustained with up to `200 req/min` burst, where burst capacity regenerates slowly (e.g., 1 token every 10 seconds).

### Token Cost Per Request

Not all requests are equal. Assign different token costs:

```typescript
const TOKEN_COSTS: Record<string, number> = {
  'GET /api/users': 1,
  'POST /api/users': 5,
  'GET /api/reports/generate': 50,
  'POST /api/bulk-import': 100,
};

function consumeWithCost(bucket: TokenBucket, endpoint: string): boolean {
  const cost = TOKEN_COSTS[endpoint] || 1;
  if (bucket.tokens >= cost) {
    bucket.tokens -= cost;
    return true;
  }
  return false;
}
```

### Burst Detection and Penalty

Track burst frequency. Clients that frequently exhaust their burst capacity get progressively tighter limits:

```python
class BurstTracker:
    def __init__(self, penalty_threshold=5, penalty_factor=0.8):
        self.burst_count = 0
        self.penalty_threshold = penalty_threshold
        self.penalty_factor = penalty_factor

    def on_burst_exhausted(self):
        self.burst_count += 1
        if self.burst_count >= self.penalty_threshold:
            return self.penalty_factor ** (self.burst_count - self.penalty_threshold)
        return 1.0  # no penalty yet
```

---

## Hierarchical Rate Limiting

Hierarchical rate limiting enforces limits at multiple levels: global → service → tenant/user → endpoint. Requests must pass all levels.

### Architecture

```
Global Limit (10,000 req/s across all services)
  └── Service Limit (2,000 req/s for Payment Service)
        └── Tenant Limit (500 req/s for TenantA)
              └── User Limit (50 req/s for User123)
                    └── Endpoint Limit (10 req/s for POST /charge)
```

### Implementation with Redis

Use a pipeline of Lua script calls, one per hierarchy level:

```lua
-- hierarchical_check.lua
-- KEYS: list of hierarchical keys (global, service, tenant, user, endpoint)
-- ARGV[1]: window size, ARGV[2+]: limits per level

local window = tonumber(ARGV[1])

for i, key in ipairs(KEYS) do
    local limit = tonumber(ARGV[i + 1])
    local current = tonumber(redis.call('GET', key) or '0')

    if current >= limit then
        return i  -- returns which level blocked (1=global, 2=service, etc.)
    end
end

-- All levels passed; increment all counters atomically
for i, key in ipairs(KEYS) do
    local val = redis.call('INCR', key)
    if val == 1 then
        redis.call('EXPIRE', key, window)
    end
end

return 0  -- allowed
```

### Key Design

```
rl:global                              → 10000/s
rl:svc:payment                         → 2000/s
rl:svc:payment:tenant:acme             → 500/s
rl:svc:payment:tenant:acme:user:u123   → 50/s
rl:svc:payment:tenant:acme:user:u123:POST:/charge → 10/s
```

### Quota Allocation

The sum of child limits should not exceed the parent limit. Use either:

- **Static allocation:** Manually assign quotas per tenant. Simple but inflexible.
- **Dynamic allocation:** Divide remaining parent capacity among active children proportionally.
- **Guaranteed minimum + burst:** Each child gets a guaranteed minimum; burst capacity is shared.

---

## Rate Limiting in Microservices

### Sidecar Pattern (Decentralized)

Deploy a rate limiting sidecar (e.g., Envoy proxy) alongside each service instance. The sidecar intercepts all inbound/outbound traffic and enforces limits locally.

**Pros:**
- No single point of failure
- Low latency (in-process or localhost)
- Service-agnostic (works with any language/framework)

**Cons:**
- Limits are per-instance, not global (unless syncing to a central store)
- Resource overhead per pod/container
- Configuration complexity at scale

```yaml
# Envoy rate limit filter configuration
http_filters:
  - name: envoy.filters.http.local_ratelimit
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
      stat_prefix: http_local_rate_limiter
      token_bucket:
        max_tokens: 100
        tokens_per_fill: 100
        fill_interval: 60s
```

### Centralized Pattern

A dedicated rate limiting service (e.g., Lyft's Ratelimit service) handles all checks. Services call it via gRPC before processing requests.

**Pros:**
- Global view of all traffic
- Consistent enforcement across services
- Single place to update configurations

**Cons:**
- Added latency per request (typically 1–5ms)
- Single point of failure (mitigate with replication + fail-open)
- Scaling the rate limit service itself

### Hybrid: Local + Global

Best of both worlds:

1. Each sidecar enforces a local limit = `global_limit / num_instances`
2. Periodically (every 1–5s), sync local counters to a central Redis
3. Adjust local limits based on actual global usage

```
Instance A: local_limit = 100/s, used = 60/s → reports 60
Instance B: local_limit = 100/s, used = 90/s → reports 90
Central: total = 150/s, global_limit = 300/s → 50% utilized
  → Rebalance: A gets 120/s, B gets 120/s (proportional to usage + headroom)
```

### Service Mesh Integration

In Istio/Linkerd, configure rate limiting at the mesh level:

```yaml
# Istio EnvoyFilter for rate limiting
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: rate-limit-filter
spec:
  workloadSelector:
    labels:
      app: api-gateway
  configPatches:
    - applyTo: HTTP_FILTER
      match:
        context: SIDECAR_INBOUND
      patch:
        operation: INSERT_BEFORE
        value:
          name: envoy.filters.http.ratelimit
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.ratelimit.v3.RateLimit
            domain: production
            rate_limit_service:
              grpc_service:
                envoy_grpc:
                  cluster_name: rate_limit_cluster
```

---

## Fair Queuing

Fair queuing ensures equitable resource distribution among clients, preventing any single client from monopolizing capacity.

### Weighted Fair Queuing (WFQ)

Assign weights to clients. Each client's share of throughput is proportional to its weight:

```python
import heapq
from dataclasses import dataclass, field

@dataclass(order=True)
class QueueEntry:
    virtual_finish_time: float
    client_id: str = field(compare=False)
    request: object = field(compare=False)

class WeightedFairQueue:
    def __init__(self):
        self.heap: list[QueueEntry] = []
        self.virtual_time = 0.0
        self.client_vft: dict[str, float] = {}

    def enqueue(self, client_id: str, request: object, weight: float = 1.0):
        start = max(self.virtual_time, self.client_vft.get(client_id, 0))
        finish = start + (1.0 / weight)
        self.client_vft[client_id] = finish
        heapq.heappush(self.heap, QueueEntry(finish, client_id, request))

    def dequeue(self) -> QueueEntry | None:
        if not self.heap:
            return None
        entry = heapq.heappop(self.heap)
        self.virtual_time = entry.virtual_finish_time
        return entry
```

### Max-Min Fairness

Allocate capacity equally. If a client doesn't use its share, redistribute to others:

```
Total capacity: 1000 req/s
Clients: A (wants 600), B (wants 200), C (wants 400)
Round 1: Equal share = 333 each
  B only wants 200 → surplus = 133
Round 2: Redistribute 133 among A, C → 66.5 each
  A gets 333 + 66.5 = 399.5
  C gets 333 + 66.5 = 399.5
  B gets 200
```

### Deficit Round Robin

Track a "deficit counter" per client. Each round, add a quantum to each client's deficit. Serve requests while deficit > 0, decrementing by request cost:

```go
type DRRScheduler struct {
    clients   map[string]*ClientQueue
    quantum   int
    deficits  map[string]int
    order     []string
}

func (d *DRRScheduler) Schedule() *Request {
    for _, id := range d.order {
        d.deficits[id] += d.quantum
        q := d.clients[id]
        for d.deficits[id] > 0 && q.Len() > 0 {
            req := q.Peek()
            if req.Cost <= d.deficits[id] {
                d.deficits[id] -= req.Cost
                return q.Dequeue()
            }
            break
        }
    }
    return nil
}
```

---

## Priority-Based Limiting

Assign priority tiers to requests. Higher-priority requests are served first; lower-priority requests are shed under load.

### Priority Classes

```typescript
enum RequestPriority {
  CRITICAL = 0,    // Health checks, auth token refresh
  HIGH = 1,        // Paid tier API calls
  NORMAL = 2,      // Free tier API calls
  LOW = 3,         // Background sync, analytics
  BULK = 4,        // Batch imports, data exports
}

interface PriorityLimits {
  [RequestPriority.CRITICAL]: { limit: Infinity, reserved: 0.1 };  // 10% reserved
  [RequestPriority.HIGH]:     { limit: 1000,     reserved: 0.3 };
  [RequestPriority.NORMAL]:   { limit: 500,      reserved: 0.2 };
  [RequestPriority.LOW]:      { limit: 200,      reserved: 0 };
  [RequestPriority.BULK]:     { limit: 50,       reserved: 0 };
}
```

### Load-Shed by Priority

When system load increases, progressively disable lower priorities:

```python
def should_accept(request, system_load: float) -> bool:
    """
    system_load: 0.0 (idle) to 1.0 (saturated)
    """
    thresholds = {
        Priority.CRITICAL: 1.0,   # always accept
        Priority.HIGH: 0.95,
        Priority.NORMAL: 0.80,
        Priority.LOW: 0.60,
        Priority.BULK: 0.40,
    }
    return system_load < thresholds[request.priority]
```

### Preemptive vs Non-Preemptive

- **Non-preemptive:** Once a request starts processing, it finishes regardless of priority. Higher-priority requests jump the queue but don't cancel in-flight work.
- **Preemptive:** Higher-priority requests can cancel lower-priority in-flight requests. Use only for streaming/long-running operations where partial work is disposable.

---

## Rate Limiting Webhooks and Callbacks

Outbound rate limiting for webhooks requires different strategies than inbound API limiting.

### Challenges

- **Receiver capacity unknown:** You don't know how much traffic the webhook consumer can handle.
- **Retry storms:** Failed deliveries with retries can amplify traffic.
- **Ordering requirements:** Some webhooks must be delivered in order per entity.

### Delivery Queue with Rate Limiting

```python
class WebhookDeliveryQueue:
    def __init__(self, default_rate=10, max_rate=100):
        self.client_rates: dict[str, int] = {}
        self.default_rate = default_rate
        self.max_rate = max_rate

    def get_rate(self, endpoint_id: str) -> int:
        return self.client_rates.get(endpoint_id, self.default_rate)

    def adjust_rate(self, endpoint_id: str, response_code: int, latency_ms: int):
        current = self.get_rate(endpoint_id)
        if response_code == 429 or response_code >= 500:
            # Back off: halve the rate
            self.client_rates[endpoint_id] = max(1, current // 2)
        elif latency_ms < 500 and response_code < 300:
            # Speed up: increase by 10%
            self.client_rates[endpoint_id] = min(self.max_rate, int(current * 1.1))
```

### Exponential Backoff for Retries

```
Attempt 1: immediate
Attempt 2: 10s delay
Attempt 3: 30s delay
Attempt 4: 2min delay
Attempt 5: 10min delay
Attempt 6: 1hr delay
Max attempts: 10, then dead-letter queue
```

### Per-Consumer Rate Discovery

Allow webhook consumers to specify their rate limit via:
1. Configuration at registration time
2. `RateLimit-Limit` header in their responses
3. Automatic detection based on 429 responses

---

## API Monetization Tiers

Rate limiting is the enforcement mechanism for API monetization tiers.

### Tier Structure

```typescript
interface ApiTier {
  name: string;
  rateLimit: { requests: number; windowSeconds: number };
  dailyQuota: number;
  monthlyQuota: number;
  burstLimit: number;
  concurrencyLimit: number;
  features: string[];
  price: number;
}

const TIERS: Record<string, ApiTier> = {
  free: {
    name: 'Free',
    rateLimit: { requests: 10, windowSeconds: 60 },
    dailyQuota: 1_000,
    monthlyQuota: 10_000,
    burstLimit: 20,
    concurrencyLimit: 2,
    features: ['basic-endpoints'],
    price: 0,
  },
  pro: {
    name: 'Professional',
    rateLimit: { requests: 100, windowSeconds: 60 },
    dailyQuota: 50_000,
    monthlyQuota: 1_000_000,
    burstLimit: 200,
    concurrencyLimit: 10,
    features: ['basic-endpoints', 'advanced-analytics', 'webhooks'],
    price: 49,
  },
  enterprise: {
    name: 'Enterprise',
    rateLimit: { requests: 1000, windowSeconds: 60 },
    dailyQuota: 1_000_000,
    monthlyQuota: 50_000_000,
    burstLimit: 5000,
    concurrencyLimit: 100,
    features: ['all'],
    price: 499,
  },
};
```

### Enforcement Architecture

```
Request → Auth (identify API key) → Tier Lookup (cache)
  → Rate Limit Check (per-second/minute)
  → Quota Check (daily/monthly)
  → Concurrency Check
  → Process Request
  → Meter Usage (for billing)
```

### Overage Handling

Options when a client exceeds their tier:
1. **Hard block:** Return 429. Simple but may lose customers.
2. **Soft limit with overage billing:** Allow traffic, bill per-request above quota.
3. **Throttle:** Reduce quality (slower responses, no caching) instead of blocking.
4. **Upgrade prompt:** Return 429 with upgrade URL in response body.

### Usage Tracking for Billing

```sql
-- Atomic usage increment with monthly rollover
INSERT INTO api_usage (api_key, month, request_count, last_updated)
VALUES (:key, :month, 1, NOW())
ON CONFLICT (api_key, month)
DO UPDATE SET
    request_count = api_usage.request_count + 1,
    last_updated = NOW();
```

---

## GraphQL-Specific Rate Limiting

GraphQL's single-endpoint nature makes traditional per-endpoint rate limiting insufficient. A single query can request vastly different amounts of data.

### Query Complexity Analysis

Assign a cost to each field and multiply by the cardinality of list fields:

```typescript
interface ComplexityConfig {
  defaultFieldCost: number;
  defaultListMultiplier: number;
  maxComplexity: number;
  overrides: Record<string, number>;
}

function calculateComplexity(
  query: DocumentNode,
  variables: Record<string, unknown>,
  config: ComplexityConfig
): number {
  let total = 0;

  visit(query, {
    Field(node) {
      const fieldName = node.name.value;
      const cost = config.overrides[fieldName] || config.defaultFieldCost;

      // Check for list arguments (first, last, limit)
      const listArg = node.arguments?.find(
        a => ['first', 'last', 'limit'].includes(a.name.value)
      );
      const multiplier = listArg
        ? getArgumentValue(listArg, variables)
        : 1;

      total += cost * multiplier;
    },
  });

  return total;
}
```

### Depth Limiting

Prevent deeply nested queries that cause exponential joins:

```typescript
function calculateDepth(query: DocumentNode): number {
  let maxDepth = 0;

  function traverse(selectionSet: SelectionSetNode, depth: number) {
    if (!selectionSet) return;
    maxDepth = Math.max(maxDepth, depth);
    for (const selection of selectionSet.selections) {
      if (selection.kind === 'Field' && selection.selectionSet) {
        traverse(selection.selectionSet, depth + 1);
      }
    }
  }

  // Start traversal from operation definitions
  for (const def of query.definitions) {
    if (def.kind === 'OperationDefinition') {
      traverse(def.selectionSet, 0);
    }
  }

  return maxDepth;
}
```

### Rate Limiting by Complexity Points

Instead of counting requests, consume complexity points from the rate limit budget:

```
Client budget: 10,000 complexity points per minute

Query 1: { users(first: 10) { name posts(first: 5) { title } } }
  Complexity: 1 + (10 × 1) + (10 × 5 × 1) = 61 points
  Remaining: 9,939

Query 2: { user(id: 1) { name } }
  Complexity: 2 points
  Remaining: 9,937
```

### Persisted Queries

For known, pre-approved queries, assign fixed costs at registration time. Reject unknown queries in production to prevent expensive ad-hoc queries:

```typescript
const PERSISTED_QUERY_COSTS: Record<string, number> = {
  'abc123': 10,   // GetUserProfile
  'def456': 50,   // ListOrdersWithItems
  'ghi789': 200,  // FullDashboardData
};

function getQueryCost(queryHash: string): number | null {
  return PERSISTED_QUERY_COSTS[queryHash] ?? null; // null = unknown query
}
```

### Combined Strategy

Best practice is to apply multiple limits simultaneously:

```typescript
interface GraphQLLimits {
  maxDepth: number;           // e.g., 10
  maxComplexity: number;      // e.g., 500 per query
  complexityBudget: number;   // e.g., 10,000 per minute
  maxRequests: number;        // e.g., 100 per minute (regardless of complexity)
  maxBatchSize: number;       // e.g., 10 queries per batch request
}
```

Enforce all limits. Return errors with details about which limit was exceeded and what the current usage is, so clients can adapt their queries.
