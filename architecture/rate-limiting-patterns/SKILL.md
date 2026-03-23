---
name: rate-limiting-patterns
description:
  positive: "Use when user implements rate limiting, asks about token bucket, sliding window, leaky bucket algorithms, API rate limit headers, distributed rate limiting with Redis, or throttling/backoff strategies."
  negative: "Do NOT use for circuit breakers (use event-driven-architecture skill), load balancing, or network bandwidth throttling."
---

# Rate Limiting Patterns

## Fundamentals

Rate limiting controls how many requests a client can make in a time window. Apply it to protect backend resources, enforce fair usage, prevent abuse, and maintain SLA guarantees.

**Where to apply:**
- **Edge/gateway** — first line of defense, stops traffic before it reaches app servers.
- **Application middleware** — per-route or per-action granularity.
- **Service-to-service** — prevent internal cascading overload.

**Client vs server rate limiting:**
- Server-side is authoritative. Never trust the client to self-throttle.
- Client-side is cooperative. Implement backoff and respect server headers to avoid wasted requests.

## Algorithms

### Fixed Window Counter
Divide time into fixed intervals. Increment a counter per interval. Reject when counter exceeds limit.

- **Pros:** Simple, low memory (one counter per key).
- **Cons:** Boundary burst — a client can fire 2× the limit across two adjacent window edges.

### Sliding Window Log
Store a timestamp for every request. Count entries within the trailing window.

- **Pros:** Exact enforcement, no boundary burst.
- **Cons:** O(N) memory per client where N = requests in window. Expensive at scale.

### Sliding Window Counter
Combine two fixed windows. Weight the previous window's count by overlap percentage.

```
effective_count = prev_window_count * overlap_pct + current_window_count
```

- **Pros:** Near-exact, O(1) memory per key.
- **Cons:** Approximate, but good enough for most APIs.

### Token Bucket
A bucket holds tokens up to a max capacity. Tokens refill at a steady rate. Each request consumes one token.

```python
class TokenBucket:
    def __init__(self, capacity: int, refill_rate: float):
        self.capacity = capacity
        self.tokens = capacity
        self.refill_rate = refill_rate  # tokens per second
        self.last_refill = time.monotonic()

    def allow(self) -> bool:
        now = time.monotonic()
        elapsed = now - self.last_refill
        self.tokens = min(self.capacity, self.tokens + elapsed * self.refill_rate)
        self.last_refill = now
        if self.tokens >= 1:
            self.tokens -= 1
            return True
        return False
```

- **Pros:** Allows controlled bursts. O(1) memory. Most popular for public APIs.
- **Cons:** Burst can exhaust tokens quickly.

### Leaky Bucket
Requests enter a FIFO queue. The queue drains at a constant rate. Overflow is rejected.

- **Pros:** Perfectly smooth output rate.
- **Cons:** Adds latency. Cannot absorb bursts. Old queued requests block newer ones.

### GCRA (Generic Cell Rate Algorithm)
Mathematical equivalent of leaky bucket without an explicit queue. Store one timestamp (Theoretical Arrival Time) per client.

```
if now >= TAT:
    allow; TAT = now + interval
else if TAT - now <= burst_tolerance:
    allow; TAT = TAT + interval
else:
    deny; retry_after = TAT - now
```

- **Pros:** Minimal state (single timestamp). Precise. Used by NGINX and Envoy.
- **Cons:** More complex to reason about.

## HTTP Rate Limit Headers

Follow the IETF draft standard (`draft-ietf-httpapi-ratelimit-headers`):

```http
HTTP/1.1 200 OK
RateLimit-Limit: 100
RateLimit-Remaining: 42
RateLimit-Reset: 1718035200
```

| Header | Purpose |
|---|---|
| `RateLimit-Limit` | Max requests allowed in the window |
| `RateLimit-Remaining` | Requests left in current window |
| `RateLimit-Reset` | Unix timestamp when the window resets |
| `Retry-After` | Seconds (or HTTP-date) to wait before retrying after 429 |
| `RateLimit-Policy` | Structured description of quota policy (limit, window, partitions) |

Always return **429 Too Many Requests** when the limit is exceeded. Include `Retry-After`. Drop legacy `X-RateLimit-*` prefixed headers in new APIs.

## Server-Side Implementation

### Middleware Pattern (Express)

```javascript
import rateLimit from 'express-rate-limit';

const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,   // RateLimit-* headers
  legacyHeaders: false,
  keyGenerator: (req) => req.user?.id || req.ip,
  handler: (req, res) => {
    res.status(429).json({
      error: 'Too many requests',
      retryAfter: Math.ceil(req.rateLimit.resetTime / 1000),
    });
  },
});
app.use('/api/', apiLimiter);
```

### Key Strategies
- **By IP** — basic protection, easy to bypass with proxies.
- **By authenticated user/API key** — preferred for APIs with auth.
- **By endpoint** — stricter limits on expensive operations (search, export).
- **Tiered limits** — free: 100/hr, pro: 10,000/hr, enterprise: custom.

### Tiered Limit Example

```python
TIERS = {
    "free":       {"rpm": 60,    "rpd": 1_000},
    "pro":        {"rpm": 600,   "rpd": 50_000},
    "enterprise": {"rpm": 6_000, "rpd": 500_000},
}

def get_limit(user):
    return TIERS.get(user.plan, TIERS["free"])
```

## Redis-Based Distributed Rate Limiting

Single-instance counters break in multi-node deployments. Use Redis as a shared store.

### Sliding Window with Lua (Atomic)

```lua
local key = KEYS[1]
local window = tonumber(ARGV[1]) * 1000
local limit = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
local count = redis.call('ZCARD', key)

if count < limit then
    redis.call('ZADD', key, now, now .. ':' .. math.random(1000000))
    redis.call('PEXPIRE', key, window)
    return 1  -- allowed
else
    return 0  -- denied
end
```

Call from application code:

```javascript
const allowed = await redis.eval(luaScript, 1,
  `ratelimit:${userId}`, windowSeconds, maxRequests, Date.now()
);
```

### Why Lua Over MULTI/EXEC
`MULTI/EXEC` is not a lock — other clients can interleave between queued commands. Lua scripts execute atomically within the Redis event loop. Always prefer Lua for rate limiting logic.

### Token Bucket in Redis

```lua
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local data = redis.call('HMGET', key, 'tokens', 'last')
local tokens = tonumber(data[1]) or capacity
local last = tonumber(data[2]) or now

local elapsed = math.max(0, now - last)
tokens = math.min(capacity, tokens + elapsed * refill_rate / 1000)

if tokens >= 1 then
    tokens = tokens - 1
    redis.call('HMSET', key, 'tokens', tokens, 'last', now)
    redis.call('PEXPIRE', key, capacity / refill_rate * 1000 + 1000)
    return 1
else
    redis.call('HMSET', key, 'tokens', tokens, 'last', now)
    return 0
end
```

## Language Implementations

### Node.js
- **express-rate-limit** — in-memory, simple setup. Add `rate-limit-redis` store for distributed.
- **rate-limiter-flexible** — supports Redis, Mongo, MySQL backends. Per-key, per-route, insurance points.
- **@upstash/ratelimit** — serverless-friendly. Sliding window over Upstash Redis. Zero config for Vercel/Cloudflare Workers.

```javascript
import { Ratelimit } from '@upstash/ratelimit';
import { Redis } from '@upstash/redis';

const ratelimit = new Ratelimit({
  redis: Redis.fromEnv(),
  limiter: Ratelimit.slidingWindow(10, '10 s'),
});

const { success, remaining, reset } = await ratelimit.limit(identifier);
```

### Python
- **slowapi** — built on `limits` library. Use with FastAPI or Starlette.
- **django-ratelimit** — decorator-based. Supports Redis backend.

```python
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address)
app.state.limiter = limiter

@app.get("/api/resource")
@limiter.limit("5/minute")
async def resource(request: Request):
    return {"data": "ok"}
```

### Go
- **golang.org/x/time/rate** — stdlib token bucket. Single-process only.
- **go-redis/redis_rate** — distributed GCRA over Redis.

```go
limiter := rate.NewLimiter(rate.Every(time.Second), 10) // 10 req/s, burst 10

if !limiter.Allow() {
    http.Error(w, "rate limited", http.StatusTooManyRequests)
    return
}
```

## API Gateway Rate Limiting

### NGINX

```nginx
http {
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

    server {
        location /api/ {
            limit_req zone=api burst=20 nodelay;
            limit_req_status 429;
        }
    }
}
```

### Kong
Use the `rate-limiting-advanced` plugin. Supports sliding window, Redis backend, consumer/route/service scoping.

### AWS API Gateway
Set usage plans with throttle (rate + burst) and quota (daily/monthly). Attach to API keys. Returns 429 automatically.

### Cloudflare
Use Rate Limiting Rules in the WAF. Match on path, method, headers. Supports challenge or block actions. Pairs with Bot Management for adaptive enforcement.

## Client-Side Handling

### Exponential Backoff with Jitter

```javascript
async function fetchWithRetry(url, options = {}, maxRetries = 5) {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    const res = await fetch(url, options);
    if (res.status !== 429) return res;

    const retryAfter = res.headers.get('Retry-After');
    let delay;
    if (retryAfter) {
      delay = parseInt(retryAfter, 10) * 1000;
    } else {
      delay = Math.min(1000 * 2 ** attempt, 30000);
    }
    // Add jitter: ±25%
    delay *= 0.75 + Math.random() * 0.5;
    await new Promise(r => setTimeout(r, delay));
  }
  throw new Error('Rate limited after max retries');
}
```

### Key Rules
- Always honor `Retry-After` header — it overrides your own backoff calculation.
- Cap max delay (30-60s) and max retries (5-7).
- Add jitter to prevent thundering herd.
- Make requests idempotent so retries are safe.
- Track `RateLimit-Remaining` proactively — slow down before hitting 429.

### Retry Queue Pattern
Queue requests when rate-limited. Drain the queue at the server's advertised rate. Useful for batch operations and background syncs.

```python
import asyncio
from collections import deque

class RetryQueue:
    def __init__(self, rate_per_sec: float):
        self.queue = deque()
        self.interval = 1.0 / rate_per_sec

    async def submit(self, coro):
        self.queue.append(coro)

    async def drain(self):
        while self.queue:
            coro = self.queue.popleft()
            await coro
            await asyncio.sleep(self.interval)
```

## DDoS vs Rate Limiting

Rate limiting alone does not stop DDoS attacks. Layer defenses:

| Layer | Tool | Purpose |
|---|---|---|
| Edge | Cloudflare / AWS Shield | Absorb volumetric attacks |
| WAF | ModSecurity, AWS WAF | Block malicious patterns |
| Rate limiter | App middleware / Redis | Enforce per-client quotas |
| Bot detection | CAPTCHA, fingerprinting | Progressive challenges for suspicious traffic |

**Progressive challenge flow:**
1. Soft limit exceeded → return 429 with `Retry-After`.
2. Continued abuse → require CAPTCHA / proof-of-work.
3. Persistent abuse → block IP range at WAF level.

Integrate rate limiter metrics (rejection rates, top offenders) with WAF rules for adaptive blocking.

## Testing Rate Limits

### Load Testing
Use `k6`, `wrk`, or `locust` to verify limits hold under concurrent load:

```javascript
// k6 script
import http from 'k6/http';
import { check } from 'k6';

export const options = { vus: 50, duration: '30s' };

export default function () {
  const res = http.get('http://localhost:3000/api/resource');
  check(res, {
    'not server error': (r) => r.status < 500,
    'rate limited correctly': (r) => r.status === 200 || r.status === 429,
  });
}
```

### Edge Cases to Test
- Boundary burst: send requests at the exact window boundary.
- Clock skew: test with NTP drift between nodes.
- Key collision: verify distinct users get independent limits.
- Redis failover: confirm graceful degradation (fail-open or fail-closed).
- Header correctness: assert `RateLimit-Remaining` decrements properly.

### Time Manipulation
In tests, inject a clock abstraction. Never call `Date.now()` or `time.time()` directly in rate limiting code:

```typescript
interface Clock {
  now(): number;
}

class RateLimiter {
  constructor(private clock: Clock = { now: () => Date.now() }) {}
}

// In tests:
const fakeClock = { now: () => 1000 };
const limiter = new RateLimiter(fakeClock);
fakeClock.now = () => 2000; // advance time
```

## Anti-Patterns

**Per-instance limits without coordination** — each app server enforces its own counter. With N instances, the effective limit becomes N × configured limit. Use Redis or a shared store.

**No bypass for health checks** — load balancer health probes trigger rate limiting, causing cascading failures. Exempt `/health` and `/ready` endpoints.

**Overly broad keys** — rate limiting by IP behind a corporate NAT punishes all users sharing that IP. Prefer authenticated user keys when available.

**No graceful degradation on store failure** — if Redis goes down, decide policy: fail-open (allow all, log) or fail-closed (deny all). Document and test this.

**Missing headers on 429 responses** — clients cannot implement backoff without `Retry-After`. Always include it.

**Static limits without monitoring** — set alerts on rejection rate. If legitimate users are frequently throttled, the limits are too aggressive or the architecture needs scaling.

**Rate limiting internal service-to-service without quotas** — use per-service quotas so one runaway service cannot consume another's capacity.
