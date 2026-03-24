---
name: rate-limiting
description: >
  Use when implementing rate limiting, throttling, API quotas, request limiting,
  DDoS protection, token bucket algorithms, sliding window counters, Redis rate
  limiters, leaky bucket patterns, or fixed window counters. Covers algorithm
  selection, Redis Lua scripts for atomic operations, Node.js and Python
  middleware, API gateway configuration, distributed rate limiting, rate limit
  headers, client-side backoff, per-user/per-IP/per-key strategies, graceful
  degradation with 429 responses, and testing approaches.
  Do NOT use for circuit breaker patterns, load balancing configuration, caching
  strategies, authentication or authorization flows, or simple request validation
  without rate concerns.
---

# Rate Limiting

## Algorithm Reference

### Fixed Window

Count requests in discrete time intervals (e.g., per minute). Reset the counter at each boundary.

```
Window: [00:00 - 01:00] → counter = 0
Request at 00:15 → counter = 1 (allow)
Request at 00:45 → counter = 100 (limit reached, reject)
Window: [01:00 - 02:00] → counter resets to 0
```

**Trade-offs:** Simplest to implement. Suffers from boundary burst — a user can send 2x the limit across two adjacent window edges. Use for non-critical quotas, login attempt throttling, or internal services.

### Sliding Window Log

Store a timestamp for every request in a sorted set. On each request, remove entries older than the window, then count remaining entries.

```
Window size: 60s, Limit: 5
Timestamps: [t-55, t-30, t-10, t-5, t-2]  → count=5 → REJECT next
After 6s: evict t-55 → [t-30, t-10, t-5, t-2] → count=4 → ALLOW
```

**Trade-offs:** Perfectly accurate. Memory grows with request volume (O(n) per key). Use for security-sensitive endpoints, audit-required APIs, or billing enforcement.

### Sliding Window Counter

Maintain counters for the current and previous windows. Compute a weighted count:

```
effective_count = prev_count * overlap_ratio + current_count
overlap_ratio = (window_size - elapsed_in_current) / window_size

Example: window=60s, limit=100, elapsed=20s
  prev_count=80, current_count=30
  effective = 80 * (40/60) + 30 = 53.3 + 30 = 83.3 → ALLOW
```

**Trade-offs:** Near-exact accuracy with only two counters per key. Best default choice for most APIs. Eliminates boundary burst without the memory cost of sliding log.

### Token Bucket

Maintain a bucket with capacity `max_tokens`. Refill at `refill_rate` tokens/second. Each request consumes one token.

```
Bucket: capacity=10, refill_rate=2/sec
t=0:  tokens=10 → request consumes 1 → tokens=9
t=0:  tokens=9  → request consumes 1 → tokens=8
t=5:  tokens=8 + (5*2)=18, capped to 10 → request → tokens=9
t=5:  burst of 9 requests → tokens=0 → next request REJECTED
```

**Trade-offs:** Allows controlled bursts up to bucket capacity while enforcing a sustained rate. Use for APIs that tolerate occasional spikes, streaming, or user-facing endpoints.

### Leaky Bucket

Requests enter a FIFO queue that drains at a fixed rate. If the queue is full, reject.

```
Queue capacity=5, drain_rate=1/sec
t=0: 5 requests arrive → queue=[r1,r2,r3,r4,r5]
t=0: 6th request → queue full → REJECT
t=1: r1 drained → queue=[r2,r3,r4,r5] → slot available
```

**Trade-offs:** Produces perfectly smooth output rate. No bursts allowed. Use for ingestion pipelines, webhook delivery, or systems requiring constant throughput.

### Algorithm Selection Guide

| Requirement | Algorithm |
|---|---|
| Simple quota, low stakes | Fixed window |
| Accurate counting, audit trail | Sliding window log |
| General API rate limiting | Sliding window counter |
| Burst-tolerant user-facing API | Token bucket |
| Smooth constant-rate output | Leaky bucket |

## Redis Implementations

Use Lua scripts to guarantee atomicity. All check-and-update operations must execute in a single EVAL call to prevent race conditions.

### Fixed Window (Redis Lua)

```lua
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])

local current = redis.call('INCR', key)
if current == 1 then
  redis.call('EXPIRE', key, window)
end

if current > limit then
  return 0  -- rejected
end
return 1  -- allowed
```

Key pattern: `ratelimit:{identifier}:{window_timestamp}`

### Sliding Window Counter (Redis Lua)

```lua
local key = KEYS[1]
local prev_key = KEYS[2]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local window_start = now - (now % window)
local elapsed = now - window_start
local weight = (window - elapsed) / window

local prev_count = tonumber(redis.call('GET', prev_key) or '0')
local curr_count = tonumber(redis.call('GET', key) or '0')
local effective = prev_count * weight + curr_count

if effective >= limit then
  return 0
end

redis.call('INCR', key)
redis.call('EXPIRE', key, window * 2)
return 1
```

### Token Bucket (Redis Lua)

```lua
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local data = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(data[1]) or capacity
local last_refill = tonumber(data[2]) or now

local elapsed = math.max(0, now - last_refill)
tokens = math.min(capacity, tokens + elapsed * refill_rate)

if tokens < 1 then
  return 0
end

tokens = tokens - 1
redis.call('HMSET', key, 'tokens', tokens, 'last_refill', now)
redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) * 2)
return 1
```

## Node.js Implementations

### express-rate-limit (Quick Setup)

```js
const rateLimit = require('express-rate-limit');
const RedisStore = require('rate-limit-redis');
const Redis = require('ioredis');

const limiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,   // RateLimit-* headers
  legacyHeaders: false,
  store: new RedisStore({ sendCommand: (...args) => redisClient.call(...args) }),
  message: { error: 'Too many requests', retryAfter: 900 },
  keyGenerator: (req) => req.user?.id || req.ip,
});
app.use('/api/', limiter);
```

### rate-limiter-flexible (Production)

```js
const { RateLimiterRedis } = require('rate-limiter-flexible');

const limiter = new RateLimiterRedis({
  storeClient: redisClient,
  keyPrefix: 'rl',
  points: 100,        // requests
  duration: 60,        // per 60 seconds
  blockDuration: 300,  // block 5 min on exceed
});

async function rateLimitMiddleware(req, res, next) {
  try {
    const result = await limiter.consume(req.ip);
    res.set({
      'RateLimit-Limit': '100',
      'RateLimit-Remaining': String(result.remainingPoints),
      'RateLimit-Reset': String(Math.ceil(result.msBeforeNext / 1000)),
    });
    next();
  } catch (rlResult) {
    res.set({ 'Retry-After': String(Math.ceil(rlResult.msBeforeNext / 1000)) });
    res.status(429).json({ error: 'Rate limit exceeded' });
  }
}
```

### Custom Token Bucket (Node.js + Redis)

```js
async function checkRateLimit(redisClient, userId, capacity, refillRate) {
  const result = await redisClient.eval(
    TOKEN_BUCKET_LUA_SCRIPT,
    1,
    `ratelimit:${userId}`,
    capacity,
    refillRate,
    Date.now() / 1000
  );
  return result === 1;
}
```

## Python Implementations

### slowapi (FastAPI)

```python
from fastapi import FastAPI, Request
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded

limiter = Limiter(key_func=get_remote_address, storage_uri="redis://localhost:6379")
app = FastAPI()
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

@app.get("/api/resource")
@limiter.limit("30/minute")
async def get_resource(request: Request):
    return {"data": "value"}

# Per-user limiting
@app.get("/api/premium")
@limiter.limit("100/minute", key_func=lambda req: req.state.user_id)
async def premium_endpoint(request: Request):
    return {"data": "premium"}
```

### Flask-Limiter

```python
from flask import Flask
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

app = Flask(__name__)
limiter = Limiter(
    get_remote_address,
    app=app,
    default_limits=["200 per day", "50 per hour"],
    storage_uri="redis://localhost:6379",
)

@app.route("/api/data")
@limiter.limit("10/minute")
def get_data():
    return {"data": "value"}

@app.route("/api/upload")
@limiter.limit("5/minute", key_func=lambda: request.headers.get("X-API-Key"))
def upload():
    return {"status": "ok"}
```

## API Gateway Rate Limiting

### Nginx

```nginx
http {
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $http_x_api_key zone=apikey:10m rate=100r/s;

    server {
        location /api/ {
            limit_req zone=api burst=20 nodelay;
            limit_req_status 429;
            proxy_pass http://backend;
        }
        location /api/heavy {
            limit_req zone=api burst=5;
            limit_req_status 429;
        }
    }
}
```

### Kong

```yaml
plugins:
  - name: rate-limiting
    config:
      minute: 100
      hour: 5000
      policy: redis
      redis_host: redis-server
      redis_port: 6379
      limit_by: consumer    # or ip, header, credential
      fault_tolerant: true  # allow traffic if Redis is down
```

### AWS API Gateway

Set throttling in Usage Plans: `rate: 100 req/sec, burst: 200`. Associate plans with API keys for per-client limits. Use stage-level throttling for global defaults.

### Cloudflare

Configure via dashboard or API: match URI path pattern, set threshold (e.g., 50 req/10s per IP), action = block/challenge, response code = 429.

## Distributed Rate Limiting

### Strategies

1. **Centralized store (Redis):** Single source of truth. All nodes call Redis. Simple but adds latency and creates a single point of failure.
2. **Local + global hybrid:** Each node enforces a local limit (total_limit / num_nodes). Periodically sync to a central store. Reduces Redis calls but allows slight over-limit.
3. **Consistent hashing:** Route rate limit checks for the same key to the same node. Avoids central store but complicates scaling.

### Handling Redis Failures

```js
async function rateLimitWithFallback(key, limit) {
  try {
    return await redisRateLimit(key, limit);
  } catch (err) {
    logger.warn('Redis unavailable, using local fallback', { error: err.message });
    return localRateLimit(key, Math.ceil(limit / NODE_COUNT));
  }
}
```

Decide a fail-open (allow traffic) or fail-closed (reject traffic) policy based on risk tolerance. Most APIs fail-open to preserve availability.

### Clock Drift Mitigation

Use Redis server time (`redis.call('TIME')`) inside Lua scripts instead of client timestamps. Synchronize node clocks via NTP with ≤50ms drift tolerance.

## Rate Limit Headers

Return these headers on every response per RFC 9110 and the RateLimit header fields draft:

```
RateLimit-Limit: 100
RateLimit-Remaining: 42
RateLimit-Reset: 1625097600    # Unix timestamp when window resets
```

On 429 responses, always include:

```
HTTP/1.1 429 Too Many Requests
Retry-After: 30               # seconds until client should retry
RateLimit-Limit: 100
RateLimit-Remaining: 0
RateLimit-Reset: 1625097630
Content-Type: application/json

{"error": "rate_limit_exceeded", "message": "Too many requests", "retry_after": 30}
```

## Client-Side Rate Limiting and Backoff

### Exponential Backoff with Jitter

```js
async function requestWithBackoff(fn, maxRetries = 5) {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    const response = await fn();
    if (response.status !== 429) return response;

    const retryAfter = parseInt(response.headers.get('Retry-After') || '1', 10);
    const backoff = Math.min(retryAfter * 1000, 2 ** attempt * 1000);
    const jitter = Math.random() * 1000;
    await new Promise(r => setTimeout(r, backoff + jitter));
  }
  throw new Error('Rate limit exceeded after max retries');
}
```

### Client-Side Token Bucket

```python
import time, threading

class ClientRateLimiter:
    def __init__(self, rate, capacity):
        self.rate = rate
        self.capacity = capacity
        self.tokens = capacity
        self.last_refill = time.monotonic()
        self.lock = threading.Lock()

    def acquire(self):
        with self.lock:
            now = time.monotonic()
            self.tokens = min(self.capacity, self.tokens + (now - self.last_refill) * self.rate)
            self.last_refill = now
            if self.tokens >= 1:
                self.tokens -= 1
                return True
            return False
```

## Key Design Strategies

### Per-User vs Per-IP vs Per-API-Key

| Strategy | Key Pattern | Use Case |
|---|---|---|
| Per-IP | `rl:ip:{ip}` | Unauthenticated endpoints, brute-force prevention |
| Per-user | `rl:user:{user_id}` | Authenticated APIs, fair usage per account |
| Per-API-key | `rl:key:{api_key}` | Third-party integrations, tiered plans |
| Per-endpoint | `rl:{method}:{path}:{id}` | Protect expensive operations individually |
| Composite | `rl:{user_id}:{endpoint}` | Granular per-user-per-resource limits |

Apply layered limits: a global per-IP limit AND a per-user limit AND a per-endpoint limit. The most restrictive wins.

## Graceful Degradation

Return informative 429 responses. Never silently drop requests.

```js
function handleRateLimitExceeded(req, res, retryAfterSec) {
  res.status(429).json({
    error: 'rate_limit_exceeded',
    message: 'Request rate limit reached. Please slow down.',
    retry_after: retryAfterSec,
    docs: 'https://api.example.com/docs/rate-limits',
  });
}
```

For tiered services, degrade gracefully: serve cached/stale data instead of rejecting outright, or queue low-priority requests for later processing.

## Testing Rate Limiters

Test these scenarios: (1) requests within capacity are allowed, (2) requests exceeding capacity return 429, (3) tokens/counters refill after the window elapses, (4) RateLimit-Remaining header decrements correctly, (5) Retry-After header is present on 429 responses, (6) concurrent requests don't exceed the limit (race condition check), (7) behavior when Redis/store is unavailable (fallback path).

Use `autocannon`, `k6`, or `wrk` for load testing:

```bash
npx autocannon -c 50 -d 10 -R 200 http://localhost:3000/api/test
```

## Common Pitfalls

1. **Race conditions:** Never use separate GET-then-SET. Use Lua scripts or atomic INCR operations in Redis. In-memory limiters need mutex/lock.
2. **Clock drift:** In distributed setups, don't rely on client wall-clock time for window boundaries. Use Redis TIME or a shared time source.
3. **Key cardinality explosion:** Avoid overly granular keys (per-IP-per-endpoint-per-method) without TTLs. Set Redis key expiry to 2x the window size.
4. **Missing headers:** Always return RateLimit-* headers so clients can self-throttle. Missing headers cause unnecessary retries.
5. **Ignoring IPv6:** IPv6 addresses should be normalized (strip zone IDs, consider /64 prefix grouping) to prevent bypass via address rotation.
6. **No fallback on store failure:** Define fail-open or fail-closed behavior. Log rate limiter store failures as alerts.
7. **Static limits for all tiers:** Implement tiered limits (free/pro/enterprise) using key-specific configurations, not one-size-fits-all.
8. **Testing only happy path:** Test boundary conditions — window edges, exact-limit requests, burst patterns, concurrent requests, and store unavailability.

## References

- **[Advanced Patterns](references/advanced-patterns.md):** Adaptive rate limiting, ML-based anomaly detection, token bucket with burst capacity, hierarchical rate limiting (global→service→user→endpoint), microservices patterns (sidecar vs centralized), fair queuing, priority-based limiting, webhook rate limiting, API monetization tiers, and GraphQL query complexity limiting.
- **[Troubleshooting](references/troubleshooting.md):** Race conditions in distributed setups, Redis cluster key distribution (`CROSSSLOT` errors), clock synchronization, key cardinality explosion, memory growth with sliding window logs, false positives from shared IPs (NAT/VPN), header spoofing bypass (`X-Forwarded-For`), load balancer sticky session interaction, and debugging rate limit decisions.

## Scripts

- **[benchmark-ratelimiter.sh](scripts/benchmark-ratelimiter.sh):** Load test a rate-limited endpoint using `wrk` or `hey`. Configurable concurrency, duration, target rate. Outputs status code distribution with rate limit analysis. Run: `./scripts/benchmark-ratelimiter.sh -u http://localhost:3000/api/test`
- **[redis-ratelimit.sh](scripts/redis-ratelimit.sh):** Validates Redis Lua rate limiting scripts. Runs token bucket / sliding window / fixed window Lua scripts and asserts correct allow/reject behavior. Run: `./scripts/redis-ratelimit.sh`

## Assets

- **[rate-limiter.ts](assets/rate-limiter.ts):** TypeScript rate limiter library with token bucket, sliding window counter, and fixed window implementations. Redis Lua scripts for atomicity. Provides `consume()`, `peek()`, and `reset()` with typed `RateLimitResult`.
- **[rate-limit-middleware.ts](assets/rate-limit-middleware.ts):** Express middleware with configurable strategies, pluggable key extractors (IP, user, API key, composite), cost functions, per-tier overrides, layered limiting, fail-open/closed modes, and `RateLimit-*` headers.
- **[rate-limit.lua](assets/rate-limit.lua):** Redis Lua scripts for atomic rate limiting — token bucket, sliding window counter, fixed window, sliding window log, and concurrent request limiter.
<!-- tested: pass -->
