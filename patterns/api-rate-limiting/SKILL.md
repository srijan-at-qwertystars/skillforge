---
name: api-rate-limiting
description: |
  Implement API rate limiting: algorithms (token bucket, leaky bucket, sliding window log/counter, fixed window), Redis-backed distributed limiting with Lua scripts, HTTP headers (RateLimit-Limit/Remaining/Reset, Retry-After), per-user/IP/API-key/tiered strategies, middleware for Express/Fastify/Django/FastAPI/Go, reverse proxy configs (Nginx/Envoy/Traefik), API gateway limiting (Kong/AWS API Gateway), client-side retry with exponential backoff, 429 responses, cost-based limiting, and burst handling.
  Triggers: "rate limiting", "throttling API", "429 responses", "token bucket", "leaky bucket", "sliding window rate limit", "API quota", "request throttling", "too many requests", "rate limiter middleware", "Retry-After header", "RateLimit header", "burst limiting", "cost-based rate limit".
  NOT for: circuit breakers, load balancing, DDoS protection at network level, connection pooling, caching strategies, authentication/authorization logic.
---

# API Rate Limiting

## Algorithm Selection

Pick the algorithm that matches your traffic profile:

### Fixed Window Counter
Use for simple limits where boundary bursts are acceptable (login throttling, basic quotas).
- Divide time into fixed intervals. Increment counter per request. Reject when counter > limit.
- Flaw: 2x burst possible at window boundary (e.g., 100 requests at :59, 100 more at :00).

### Sliding Window Log
Use when exact accuracy is required (billing, compliance, audit trails).
- Store each request timestamp in a sorted set. Remove expired entries. Count remaining.
- Trade-off: O(n) memory per key. Not viable for high-traffic anonymous endpoints.

### Sliding Window Counter
Use as the default general-purpose algorithm. Best accuracy-to-memory ratio.
- Keep counters for current and previous windows. Interpolate:
  `count = prev_window_count * overlap_fraction + current_window_count`
- Near-exact with only 2 keys per client.

### Token Bucket
Use when burst tolerance is needed with an average rate cap (SaaS APIs, public endpoints).
- Bucket holds tokens (max = burst capacity). Tokens refill at fixed rate. Each request costs 1+ tokens.
- Allows short bursts if tokens have accumulated.

### Leaky Bucket
Use for strict steady-rate enforcement (payment processing, third-party API proxying).
- Requests enter a queue that drains at a fixed rate. Queue full = reject.
- No burst capacity. Guarantees smooth outbound traffic.

### Quick Reference

| Algorithm              | Burst | Memory  | Accuracy   | Best For                    |
|------------------------|-------|---------|------------|-----------------------------|
| Fixed Window           | High  | O(1)    | Poor edge  | Simple quotas, login limits |
| Sliding Window Log     | None  | O(n)    | Exact      | Billing, compliance         |
| Sliding Window Counter | Low   | O(1)    | Very good  | General-purpose API limits  |
| Token Bucket           | High  | O(1)    | Good       | Public APIs, SaaS tiers     |
| Leaky Bucket           | None  | O(1)    | Exact      | Payment, upstream proxying  |

## Redis Implementation

### Fixed Window (INCR + EXPIRE)

```redis
-- Atomic via MULTI/EXEC or Lua
MULTI
INCR ratelimit:{user_id}:{window_key}
EXPIRE ratelimit:{user_id}:{window_key} {window_seconds}
EXEC
```

### Sliding Window Log (Sorted Set + Lua)

```lua
-- sliding_window.lua
local key = KEYS[1]
local window = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local request_id = ARGV[4]

redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
local count = redis.call('ZCARD', key)
if count >= limit then
  return 0
end
redis.call('ZADD', key, now, request_id)
redis.call('EXPIRE', key, window)
return limit - count - 1  -- remaining
```

### Token Bucket (Hash + Lua)

```lua
-- token_bucket.lua
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])  -- tokens per second
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4]) or 1

local bucket = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(bucket[1]) or capacity
local last_refill = tonumber(bucket[2]) or now

local elapsed = math.max(0, now - last_refill)
tokens = math.min(capacity, tokens + elapsed * refill_rate)

if tokens < cost then
  redis.call('HSET', key, 'tokens', tokens, 'last_refill', now)
  redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) + 1)
  return -1  -- rejected
end

tokens = tokens - cost
redis.call('HSET', key, 'tokens', tokens, 'last_refill', now)
redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) + 1)
return tokens  -- remaining
```

Always use Lua scripts (EVAL/EVALSHA) for atomicity. Never use separate GET+SET—race conditions under concurrency will allow limit bypass.

## HTTP Response Headers

### Standard Headers (IETF draft-ietf-httpapi-ratelimit-headers)

Include on ALL responses, not just 429s:

```
RateLimit-Limit: 100        # max requests in window
RateLimit-Remaining: 42     # requests left
RateLimit-Reset: 30         # seconds until window resets
```

### 429 Response

```http
HTTP/1.1 429 Too Many Requests
Content-Type: application/json
RateLimit-Limit: 100
RateLimit-Remaining: 0
RateLimit-Reset: 30
Retry-After: 30

{"error": "rate_limit_exceeded", "message": "Rate limit exceeded. Retry after 30 seconds.", "retry_after": 30}
```

Rules:
- Always include `Retry-After` on 429 responses (RFC 6585).
- Use seconds (integer) for `Retry-After`, not HTTP-date, for machine parsing.
- Return `RateLimit-*` headers on every response so clients can self-throttle.
- For legacy compatibility, also emit `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`.

## Rate Limiting Strategies

### Key Selection

| Strategy    | Key Format                        | Use Case                              |
|-------------|-----------------------------------|---------------------------------------|
| Per-user    | `rl:{user_id}`                    | Authenticated APIs, SaaS billing      |
| Per-IP      | `rl:{client_ip}`                  | Public/anonymous endpoints            |
| Per-API-key | `rl:{api_key}`                    | Partner integrations, M2M             |
| Per-route   | `rl:{user_id}:{method}:{path}`    | Expensive endpoints (search, export)  |
| Composite   | `rl:{api_key}:{endpoint}:{tier}`  | Multi-tenant with tiered plans        |

### Tiered Limits

```python
TIER_LIMITS = {
    "free":       {"requests": 100,   "window": 3600, "burst": 10},
    "starter":    {"requests": 1000,  "window": 3600, "burst": 50},
    "pro":        {"requests": 10000, "window": 3600, "burst": 200},
    "enterprise": {"requests": 100000,"window": 3600, "burst": 1000},
}
```

Resolve tier from the authenticated user/API key before applying limits. Store tier config externally (DB/config), not hardcoded.

### Cost-Based Limiting

Assign weights to operations instead of flat per-request counting:

```python
ENDPOINT_COSTS = {
    "GET /api/users":       1,
    "POST /api/users":      5,
    "GET /api/reports":     10,
    "POST /api/bulk-import": 50,
}
# Deduct cost from token bucket instead of 1
```

Use token bucket algorithm with variable `cost` parameter. Pass cost to the Lua script.

## Middleware Implementations

### Express (Node.js)

```javascript
const Redis = require('ioredis');
const redis = new Redis();

function rateLimit({ limit = 100, window = 60, keyFn }) {
  return async (req, res, next) => {
    const key = `rl:${keyFn(req)}`;
    const current = await redis.incr(key);
    if (current === 1) await redis.expire(key, window);
    const remaining = Math.max(0, limit - current);
    const ttl = await redis.ttl(key);

    res.set('RateLimit-Limit', limit);
    res.set('RateLimit-Remaining', remaining);
    res.set('RateLimit-Reset', ttl);

    if (current > limit) {
      res.set('Retry-After', ttl);
      return res.status(429).json({
        error: 'rate_limit_exceeded',
        retry_after: ttl,
      });
    }
    next();
  };
}

app.use('/api/', rateLimit({
  limit: 100, window: 60,
  keyFn: (req) => req.user?.id || req.ip,
}));
```

### FastAPI (Python)

```python
import time, redis.asyncio as aioredis
from fastapi import Request, HTTPException
from starlette.middleware.base import BaseHTTPMiddleware

class RateLimitMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, redis_url="redis://localhost", limit=100, window=60):
        super().__init__(app)
        self.redis = aioredis.from_url(redis_url)
        self.limit = limit
        self.window = window

    async def dispatch(self, request: Request, call_next):
        key = f"rl:{request.client.host}"
        current = await self.redis.incr(key)
        if current == 1:
            await self.redis.expire(key, self.window)
        ttl = await self.redis.ttl(key)
        remaining = max(0, self.limit - current)

        if current > self.limit:
            raise HTTPException(
                status_code=429,
                detail={"error": "rate_limit_exceeded", "retry_after": ttl},
                headers={"Retry-After": str(ttl), "RateLimit-Remaining": "0"},
            )
        response = await call_next(request)
        response.headers["RateLimit-Limit"] = str(self.limit)
        response.headers["RateLimit-Remaining"] = str(remaining)
        response.headers["RateLimit-Reset"] = str(ttl)
        return response
```

### Go (net/http middleware)

```go
func RateLimit(redis *redis.Client, limit int, window time.Duration) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            key := fmt.Sprintf("rl:%s", r.RemoteAddr)
            ctx := r.Context()

            count, _ := redis.Incr(ctx, key).Result()
            if count == 1 {
                redis.Expire(ctx, key, window)
            }
            ttl, _ := redis.TTL(ctx, key).Result()
            remaining := max(0, limit-int(count))

            w.Header().Set("RateLimit-Limit", strconv.Itoa(limit))
            w.Header().Set("RateLimit-Remaining", strconv.Itoa(remaining))
            w.Header().Set("RateLimit-Reset", strconv.Itoa(int(ttl.Seconds())))

            if int(count) > limit {
                w.Header().Set("Retry-After", strconv.Itoa(int(ttl.Seconds())))
                w.WriteHeader(http.StatusTooManyRequests)
                json.NewEncoder(w).Encode(map[string]any{
                    "error": "rate_limit_exceeded", "retry_after": ttl.Seconds(),
                })
                return
            }
            next.ServeHTTP(w, r)
        })
    }
}
```

### Django Middleware

Same pattern as FastAPI: use `django-redis` backend, `INCR`+`EXPIRE` in `__call__`, extract client IP from `HTTP_X_FORWARDED_FOR` or `REMOTE_ADDR`, return `JsonResponse(status=429)` with `Retry-After` header when limit exceeded.

## Reverse Proxy Configuration

### Nginx

```nginx
http {
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

    server {
        location /api/ {
            limit_req zone=api burst=20 nodelay;
            limit_req_status 429;
            proxy_pass http://backend;
        }
    }
}
```

- `rate=10r/s`: 10 requests/second per IP. Use `$http_x_api_key` for per-key limiting.
- `burst=20 nodelay`: Allow 20-request bursts without queuing delay.
- Set `limit_req_status 429` explicitly (default is 503).

### Traefik

```yaml
http:
  middlewares:
    api-ratelimit:
      rateLimit:
        average: 100
        period: 1s
        burst: 200
  routers:
    api:
      middlewares:
        - api-ratelimit
```

### Envoy

Use the `envoy.filters.http.ratelimit` filter with an external rate limit service (typically Redis-backed). Configure descriptors per route for granular control.

## API Gateway Configuration

### Kong

```yaml
plugins:
  - name: rate-limiting
    config:
      minute: 100
      policy: redis
      redis_host: redis-host
      redis_port: 6379
```

### AWS API Gateway

Configure via Usage Plans:
- Set `rateLimit` (steady-state requests/second) and `burstLimit` (max concurrent).
- Attach plans to API keys for per-consumer limits.
- Default: 10,000 req/s, 5,000 burst. Request increases via AWS Support.

## Client-Side Retry with Exponential Backoff

```python
import time, random

def call_with_backoff(fn, max_retries=5, base_delay=1.0, max_delay=60.0):
    for attempt in range(max_retries):
        response = fn()
        if response.status_code != 429:
            return response

        # Prefer server-specified delay
        retry_after = response.headers.get("Retry-After")
        if retry_after:
            delay = float(retry_after)
        else:
            delay = min(base_delay * (2 ** attempt), max_delay)

        # Add jitter to prevent thundering herd
        jitter = random.uniform(0, delay * 0.5)
        time.sleep(delay + jitter)

    raise Exception("Max retries exceeded")
```

Rules:
- Always respect `Retry-After` header when present.
- Add jitter (random 0–50% of delay) to decorrelate retries across clients.
- Cap maximum delay (e.g., 60s). Cap total retries (e.g., 5).
- Only retry on 429 and 5xx. Never retry 4xx (except 429) or 3xx.

## Distributed Rate Limiting

### Consistency Approaches

| Approach           | Consistency | Performance | Complexity |
|--------------------|-------------|-------------|------------|
| Single Redis       | Strong      | Medium      | Low        |
| Redis Cluster      | Strong      | High        | Medium     |
| Local + sync       | Eventual    | Highest     | High       |
| Sticky sessions    | Per-node    | High        | Low        |

### Fail-Open vs Fail-Closed

- **Fail-open**: If Redis is unavailable, allow requests. Use for non-critical limits. Prevents outages from cascading.
- **Fail-closed**: If Redis is unavailable, reject requests. Use for billing-critical or abuse-prevention limits.

```python
try:
    allowed = check_rate_limit(redis, key, limit)
except RedisError:
    allowed = FAIL_OPEN  # True for fail-open, False for fail-closed
```

Always log rate limiter failures. Monitor Redis health. Set reasonable timeouts on Redis calls (e.g., 50–100ms) to prevent middleware from becoming a bottleneck.

## Examples

### Example 1: "Add rate limiting to my Express API"

**Input:** User asks to add rate limiting to an Express.js REST API.

**Output:** Apply token bucket with Redis backend:

```javascript
// middleware/rateLimit.js
const Redis = require('ioredis');
const redis = new Redis(process.env.REDIS_URL);

const LUA_TOKEN_BUCKET = `
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local bucket = redis.call('HMGET', key, 'tokens', 'ts')
local tokens = tonumber(bucket[1]) or capacity
local last = tonumber(bucket[2]) or now
tokens = math.min(capacity, tokens + (now - last) * refill_rate)
if tokens < 1 then
  redis.call('HSET', key, 'tokens', tokens, 'ts', now)
  redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) + 1)
  return -1
end
tokens = tokens - 1
redis.call('HSET', key, 'tokens', tokens, 'ts', now)
redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) + 1)
return tokens
`;

module.exports = function({ capacity = 100, refillRate = 1.67 }) {
  return async (req, res, next) => {
    const key = `rl:${req.user?.id || req.ip}`;
    try {
      const remaining = await redis.eval(
        LUA_TOKEN_BUCKET, 1, key, capacity, refillRate, Date.now() / 1000
      );
      res.set('RateLimit-Limit', capacity);
      res.set('RateLimit-Remaining', Math.max(0, remaining));
      if (remaining < 0) {
        res.set('Retry-After', '60');
        return res.status(429).json({ error: 'rate_limit_exceeded' });
      }
    } catch (err) {
      console.error('Rate limiter error:', err);
      // fail-open
    }
    next();
  };
};
```

### Example 2: "Handle 429 responses in my Python client"

**Input:** User needs retry logic for a third-party API that returns 429s.

**Output:** Use exponential backoff with jitter, respecting `Retry-After`:

```python
import httpx, time, random

def request_with_retry(client, method, path, max_retries=5, **kw):
    for attempt in range(max_retries):
        resp = client.request(method, path, **kw)
        if resp.status_code != 429:
            return resp
        delay = float(resp.headers.get("Retry-After", 2 ** attempt))
        time.sleep(min(delay + random.uniform(0, delay * 0.3), 120))
    raise Exception("Rate limited after max retries")
```

## Supplemental Files

**References:** `references/algorithm-comparison.md` (5-algorithm deep comparison: memory, accuracy, Redis complexity) · `references/advanced-patterns.md` (distributed, multi-tier, cost-based, adaptive, WebSocket, GraphQL cost, sidecar, quotas) · `references/troubleshooting.md` (race conditions, clock skew, Redis failures, header spoofing, IPv6, hot keys, monitoring)

**Scripts:** `scripts/redis-rate-limit.sh` (load Lua scripts, test token bucket/sliding window/race conditions) · `scripts/benchmark-algorithms.sh` (benchmark accuracy vs speed vs memory) · `scripts/check-headers.sh` (audit RateLimit-*/Retry-After headers)

**Assets:** `assets/token-bucket.lua` · `assets/sliding-window.lua` (production Redis Lua scripts) · `assets/express-middleware.ts` (Express + Redis + tiered limits + fail-open) · `assets/nginx-rate-limit.conf` (per-IP/per-key zones, burst, 429 page) · `assets/kong-rate-limit.yaml` (per-consumer tiers, per-route, Redis backend)

<!-- tested: pass -->
