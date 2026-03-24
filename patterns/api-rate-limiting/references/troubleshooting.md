# Rate Limiting Troubleshooting Guide

## Table of Contents
- [Race Conditions in Distributed Rate Limiting](#race-conditions-in-distributed-rate-limiting)
- [Clock Skew](#clock-skew)
- [Redis Connection Failures: Fail-Open vs Fail-Closed](#redis-connection-failures-fail-open-vs-fail-closed)
- [Rate Limit Bypass via Header Spoofing](#rate-limit-bypass-via-header-spoofing)
- [IPv6 Rate Limiting](#ipv6-rate-limiting)
- [Hot Key Problem](#hot-key-problem)
- [Monitoring Rate Limit Effectiveness](#monitoring-rate-limit-effectiveness)

---

## Race Conditions in Distributed Rate Limiting

### The Problem

Non-atomic read-check-write sequences allow concurrent requests to bypass limits:

```
Time    Server A                Server B
────    ────────                ────────
T1      GET counter → 99       GET counter → 99
T2      99 < 100? → allow      99 < 100? → allow
T3      SET counter 100        SET counter 100
        ✗ Both allowed — limit is 100 but 101 requests passed
```

### Root Cause
Separate GET and SET operations are not atomic. Under concurrency, multiple workers read the same value before any writes land.

### Fixes

**1. Lua scripts (recommended)**
All operations execute atomically on Redis's single-threaded event loop:
```lua
local count = redis.call('INCR', KEYS[1])
if count == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
if count > tonumber(ARGV[2]) then return 0 end
return 1
```

**2. Redis INCR (for simple counters)**
`INCR` is atomic. Check the return value — don't do a separate GET:
```python
count = redis.incr(key)
if count == 1:
    redis.expire(key, window)
if count > limit:
    reject()
```

**3. Never do this:**
```python
# WRONG — race condition
count = redis.get(key)           # T1: read
if int(count or 0) < limit:     # T2: check
    redis.incr(key)              # T3: write (too late)
```

### Testing for Race Conditions
Fire 100 concurrent requests with `ab` or `wrk`. If more than `limit` succeed, you have a race:
```bash
wrk -t10 -c100 -d1s http://localhost:3000/api/test
# Check: should see exactly $limit 200s, rest 429s
```

---

## Clock Skew

### The Problem
Sliding window and token bucket algorithms use timestamps. If app servers have different clocks, the same request gets different window calculations on different servers.

**Impact**: Users see inconsistent limits. Requests allowed on Server A are rejected on Server B. Token refill calculations differ by the skew amount.

### How Bad Is It?
| Skew     | Effect on 1-minute window         |
|----------|-----------------------------------|
| < 100ms  | Negligible                        |
| 1s       | ~1.7% inaccuracy                  |
| 10s      | ~17% inaccuracy                   |
| > 30s    | Effectively broken                |

### Fixes

**1. Use Redis server time (recommended)**
```lua
-- Inside Lua script: use Redis's own clock
local now = redis.call('TIME')
local timestamp = tonumber(now[1]) + tonumber(now[2]) / 1000000
```
All nodes see the same time because all time operations happen on Redis.

**2. NTP synchronization**
Ensure all servers run `chrony` or `ntpd`. Target < 10ms skew:
```bash
chronyc tracking  # Check offset
```

**3. Use monotonic window keys**
Instead of timestamps, use sequential window IDs: `floor(redis_time / window_size)`. Even with slight skew, windows align.

---

## Redis Connection Failures: Fail-Open vs Fail-Closed

### Decision Matrix

| Scenario                    | Recommendation | Rationale                                    |
|-----------------------------|----------------|----------------------------------------------|
| Public API, non-billing     | Fail-open      | Availability > accuracy                      |
| Billing/metered API         | Fail-closed    | Financial accuracy is critical               |
| Login/auth throttling       | Fail-closed    | Security — brute force protection essential  |
| Internal microservice       | Fail-open      | Don't cascade Redis failure to all services  |
| DDoS protection layer       | Fail-closed    | Attackers would exploit fail-open            |

### Implementation Pattern

```python
import time
from redis.exceptions import RedisError

class ResilientRateLimiter:
    def __init__(self, redis, fail_open=True, local_fallback_limit=50,
                 circuit_break_threshold=5, circuit_break_duration=30):
        self.redis = redis
        self.fail_open = fail_open
        self.local_fallback_limit = local_fallback_limit
        self.consecutive_failures = 0
        self.circuit_open_until = 0
        self.local_counters = {}  # fallback

    def is_allowed(self, key, limit, window):
        # Circuit breaker: skip Redis if recently failing
        if time.time() < self.circuit_open_until:
            return self._local_check(key, limit)

        try:
            result = self._redis_check(key, limit, window)
            self.consecutive_failures = 0
            return result
        except RedisError as e:
            self.consecutive_failures += 1
            if self.consecutive_failures >= self.circuit_break_threshold:
                self.circuit_open_until = time.time() + self.circuit_break_duration
            log.error(f"Rate limiter Redis error: {e}")
            metrics.increment("rate_limiter.redis_failure")

            if self.fail_open:
                return self._local_check(key, self.local_fallback_limit)
            return False  # fail-closed

    def _local_check(self, key, limit):
        """In-memory fallback — per-instance, not global."""
        now = int(time.time())
        window_key = f"{key}:{now // 60}"
        self.local_counters[window_key] = self.local_counters.get(window_key, 0) + 1
        # Periodically clean old keys
        return self.local_counters[window_key] <= limit
```

### Critical: Always Log Failures
If fail-open fires, you're unprotected. Alert immediately:
```python
if using_fallback:
    alert.page("Rate limiter Redis down — running fail-open, abuse possible")
```

---

## Rate Limit Bypass via Header Spoofing

### The Vulnerability

If your rate limiter keys on `X-Forwarded-For` and you trust it unconditionally:
```python
# VULNERABLE — attacker sends random X-Forwarded-For each request
client_ip = request.headers.get('X-Forwarded-For', request.remote_addr)
key = f"rl:{client_ip}"
```

An attacker rotates the header value per-request, getting a fresh rate limit window every time.

### Fixes

**1. Only trust proxy headers from known proxies**
```python
TRUSTED_PROXIES = {'10.0.0.0/8', '172.16.0.0/12'}

def get_client_ip(request):
    if request.remote_addr in TRUSTED_PROXIES:
        # Take the rightmost untrusted IP from X-Forwarded-For
        xff = request.headers.get('X-Forwarded-For', '')
        ips = [ip.strip() for ip in xff.split(',')]
        for ip in reversed(ips):
            if ip not in TRUSTED_PROXIES:
                return ip
    return request.remote_addr
```

**2. Prefer authenticated identifiers**
Rate limit by API key or user ID when available — these can't be spoofed without valid credentials:
```python
key = f"rl:{request.user.id}" if request.user else f"rl:{get_client_ip(request)}"
```

**3. Nginx: set X-Real-IP at the edge**
```nginx
# At the outermost proxy only
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```
Application reads `X-Real-IP`, which the outer proxy sets from the actual TCP connection.

**4. Cloudflare / CDN headers**
Use `CF-Connecting-IP` or `True-Client-IP` — these are set by the CDN from the real connection and can't be spoofed by the client (the CDN strips/overwrites them).

---

## IPv6 Rate Limiting

### The Problem

IPv6 gives each host a /128, each subnet a /64, and ISPs commonly assign /48 or /56 prefixes. A single user can rotate through 2^64 addresses trivially, making per-IP rate limiting useless.

### The /64 Problem

```
ISP assigns:  2001:db8:1234:5600::/56 (256 /64 subnets)
User rotates: 2001:db8:1234:5600::1
              2001:db8:1234:5600::2
              2001:db8:1234:5601::1
              ... 2^72 possible addresses
```

### Fixes

**1. Rate limit on /48 or /56 prefix**
```python
import ipaddress

def get_rate_limit_key(ip_str):
    ip = ipaddress.ip_address(ip_str)
    if isinstance(ip, ipaddress.IPv6Address):
        # Mask to /56 — covers typical ISP assignment
        network = ipaddress.IPv6Network(f"{ip}/56", strict=False)
        return f"rl:{network.network_address}"
    return f"rl:{ip}"  # IPv4: use full address
```

**2. Configurable prefix length**
Different networks need different masks. ISPs may assign /48 (enterprise) or /64 (residential):
```yaml
ipv6_rate_limit:
  residential: /56
  cloud_provider: /48
  known_vpn: /32
  default: /56
```

**3. Dual-stack considerations**
Users with both IPv4 and IPv6 get separate rate limit buckets unless you link them via authentication. For anonymous endpoints, accept this limitation.

---

## Hot Key Problem

### The Problem

When a single rate limit key receives extreme traffic (viral endpoint, popular user, attack), it saturates the Redis thread handling that key's hash slot, increasing latency for all keys on that shard.

### Symptoms
- Redis `SLOWLOG` shows repeated operations on one key
- P99 latency spikes on one shard while others are idle
- `redis-cli --hotkeys` shows heavily skewed access patterns

### Fixes

**1. Local token caching (best for hot keys)**
Pre-allocate tokens to each app instance. Only contact Redis to replenish:
```python
class LocalTokenCache:
    def __init__(self, redis, key, tokens_per_refill=100, refill_interval=10):
        self.local_tokens = 0
        self.redis = redis
        self.key = key
        self.tokens_per_refill = tokens_per_refill

    def allow(self):
        if self.local_tokens > 0:
            self.local_tokens -= 1
            return True
        return False  # Wait for next refill cycle

    async def refill(self):
        """Called every refill_interval seconds."""
        tokens = await self.redis.eval(
            ALLOCATE_TOKENS_LUA, 1, self.key, self.tokens_per_refill
        )
        self.local_tokens = int(tokens)
```

**2. Key sharding**
Split one hot key into N sub-keys, route requests randomly:
```python
import random
SHARDS = 8

def check_rate_limit(user_id, limit):
    shard = random.randint(0, SHARDS - 1)
    key = f"rl:{user_id}:s{shard}"
    per_shard_limit = limit // SHARDS
    return redis.eval(RATE_LIMIT_LUA, 1, key, per_shard_limit, window)
```
Trade-off: limit accuracy degrades proportionally to shard count.

**3. Probabilistic early rejection**
If a key has been over-limit recently, reject with high probability without hitting Redis:
```python
if key in recently_limited_cache:
    if random.random() < 0.95:  # 95% chance: skip Redis entirely
        return reject_429()
```

---

## Monitoring Rate Limit Effectiveness

### Essential Metrics

| Metric                             | What It Tells You                               | Alert Threshold       |
|------------------------------------|--------------------------------------------------|-----------------------|
| `rate_limit.allowed`               | Normal traffic volume                            | Baseline anomalies    |
| `rate_limit.rejected`              | Abuse attempts / tight limits                    | Sudden spikes         |
| `rate_limit.rejected_ratio`        | % of traffic being limited                       | > 10% (investigate)   |
| `rate_limit.redis_latency_p99`     | Rate limiter overhead                            | > 50ms                |
| `rate_limit.redis_errors`          | Redis connectivity issues                        | > 0 sustained         |
| `rate_limit.fallback_activations`  | Fail-open/local fallback in use                  | > 0 (page)            |
| `rate_limit.unique_limited_keys`   | How many distinct clients are hitting limits      | Trend analysis        |

### Prometheus Metrics Example

```python
from prometheus_client import Counter, Histogram

rate_limit_total = Counter('rate_limit_total', 'Rate limit decisions',
                           ['result', 'tier', 'endpoint'])
rate_limit_latency = Histogram('rate_limit_check_seconds',
                                'Time to check rate limit',
                                buckets=[.001, .005, .01, .025, .05, .1])

def check_rate_limit(key, limit, window, tier="default", endpoint="/api"):
    with rate_limit_latency.time():
        allowed = _do_check(key, limit, window)
    result = "allowed" if allowed else "rejected"
    rate_limit_total.labels(result=result, tier=tier, endpoint=endpoint).inc()
    return allowed
```

### Grafana Dashboard Panels
1. **Allowed vs Rejected** — stacked time series, per-endpoint
2. **Top 10 Limited Keys** — who's hitting limits most
3. **Redis Latency Heatmap** — rate limiter overhead
4. **Fallback Activation Timeline** — when Redis failed
5. **Rejection Rate by Tier** — are free-tier limits too aggressive?

### Effective Limits Audit
Periodically verify limits match actual usage:
```sql
-- Find users consistently near limits (may need increase)
SELECT user_id, avg(max_usage_pct) as avg_utilization
FROM rate_limit_metrics
WHERE period = 'last_7_days'
GROUP BY user_id
HAVING avg_utilization > 0.8
ORDER BY avg_utilization DESC;
```
