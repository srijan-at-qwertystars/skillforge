# Rate Limiting Troubleshooting Guide

## Table of Contents

- [Race Conditions in Distributed Setups](#race-conditions-in-distributed-setups)
- [Redis Cluster Key Distribution](#redis-cluster-key-distribution)
- [Clock Synchronization Problems](#clock-synchronization-problems)
- [Key Cardinality Explosion](#key-cardinality-explosion)
- [Memory Growth with Sliding Window Logs](#memory-growth-with-sliding-window-logs)
- [False Positives from Shared IPs](#false-positives-from-shared-ips)
- [Bypass via Header Spoofing](#bypass-via-header-spoofing)
- [Load Balancer Sticky Session Interaction](#load-balancer-sticky-session-interaction)
- [Debugging Rate Limit Decisions](#debugging-rate-limit-decisions)

---

## Race Conditions in Distributed Setups

### Symptom

Rate limits are exceeded — more requests are allowed than the configured maximum. The problem is intermittent and correlates with traffic volume.

### Root Cause

Non-atomic read-then-write patterns. Two app servers simultaneously read the counter as 99 (limit = 100), both increment to 100, and both allow the request — resulting in 101 total requests served.

```
Server A: GET counter → 99 (< 100, allow)
Server B: GET counter → 99 (< 100, allow)
Server A: SET counter → 100
Server B: SET counter → 100  ← lost update!
```

### Diagnosis

1. Compare actual request counts vs. expected limits:
   ```bash
   # Count requests served in a window
   grep "200 OK" access.log | awk -F'[' '{print $2}' | cut -d: -f1-2 | sort | uniq -c | sort -rn | head
   ```
2. Check if your rate limit code uses separate GET and SET commands.
3. Look for `MULTI`/`EXEC` without `WATCH` — Redis transactions without optimistic locking don't prevent races.

### Solution

**Use Lua scripts for atomicity:**

```lua
-- Atomic increment with limit check
local current = redis.call('INCR', KEYS[1])
if current == 1 then
    redis.call('EXPIRE', KEYS[1], ARGV[2])
end
if current > tonumber(ARGV[1]) then
    return 0
end
return 1
```

**Alternatively, use `INCR` and check afterward:**

```python
# INCR is atomic in Redis — no race condition
count = redis.incr(key)
if count == 1:
    redis.expire(key, window_seconds)
if count > limit:
    # Over limit, but the request was already counted.
    # Option: decrement to avoid polluting the counter
    return False
return True
```

**Avoid:** `GET` then `SET`, `SETNX` with manual expiry logic, or `WATCH`/`MULTI`/`EXEC` (which retries on contention and adds latency).

---

## Redis Cluster Key Distribution

### Symptom

Rate limiting is inconsistent: some clients face limits while others with similar traffic do not. Alternatively, Lua scripts fail with `CROSSSLOT` errors.

### Root Cause

In Redis Cluster, keys are distributed across slots (0–16383) using CRC16 hashing. If a Lua script references multiple keys, all keys must be in the same hash slot. Keys like `rl:user:123` and `rl:user:123:prev` may land on different nodes.

### Diagnosis

```bash
# Check which slot a key maps to
redis-cli CLUSTER KEYSLOT "rl:user:123"
redis-cli CLUSTER KEYSLOT "rl:user:123:prev"

# If different slots, Lua scripts referencing both will fail
```

Look for errors like:
```
CROSSSLOT Keys in request don't hash to the same slot
```

### Solution

**Use hash tags to force keys to the same slot:**

```
rl:{user:123}:current    → hash tag is "user:123"
rl:{user:123}:previous   → same hash tag, same slot
```

In code:
```typescript
const hashTag = `{${clientId}}`;
const currentKey = `rl:${hashTag}:current`;
const prevKey = `rl:${hashTag}:previous`;
```

**Use single-key designs where possible.** The token bucket pattern stores all state in one hash key (`HMGET`/`HMSET`), avoiding cross-key issues entirely.

**If you must use multiple keys**, ensure all keys in a Lua script share the same hash tag:

```lua
-- All KEYS must use the same hash tag
local current = KEYS[1]   -- rl:{user:123}:cur
local previous = KEYS[2]  -- rl:{user:123}:prev
-- This works because both hash to the same slot
```

---

## Clock Synchronization Problems

### Symptom

Rate limits behave erratically — sometimes too strict, sometimes too lenient. Window boundaries appear to shift. Clients report inconsistent `RateLimit-Reset` header values.

### Root Cause

Application servers have different system clocks. If Server A's clock is 2 seconds ahead of Server B's:

- Server A creates a window at `t=100`, expires at `t=160`
- Server B creates the "same" window at `t=98`, expires at `t=158`
- Requests in the 2-second gap may be counted in different windows

### Diagnosis

```bash
# Check clock skew across servers
for host in server1 server2 server3; do
    echo -n "$host: "
    ssh $host 'date +%s.%N'
done

# Check NTP status
timedatectl status
chronyc tracking  # or ntpq -p
```

Look for skew > 100ms between servers.

### Solution

**1. Use Redis server time in Lua scripts:**

```lua
local time = redis.call('TIME')
local now = tonumber(time[1]) + tonumber(time[2]) / 1000000
-- Use 'now' for all window calculations
```

**2. Use window IDs instead of timestamps:**

```python
import time

def get_window_id(window_seconds: int) -> int:
    """Discrete window ID that's consistent across servers."""
    return int(time.time()) // window_seconds

# Key becomes: rl:user:123:window:12345
# All servers agree on the window ID as long as clocks are within window_seconds
```

**3. Fix NTP synchronization:**

```bash
# Install and configure chrony (preferred over ntpd)
sudo apt install chrony
sudo systemctl enable chrony

# Verify sync
chronyc tracking
# Look for "System time" offset < 10ms
```

**4. Accept imprecision:** For most rate limiting, ±1 second of clock skew is acceptable. Don't over-engineer if your windows are 60s+.

---

## Key Cardinality Explosion

### Symptom

Redis memory usage grows rapidly. `DBSIZE` returns millions of keys. Redis starts evicting keys or OOMing. Rate limiting becomes slow.

### Root Cause

Overly granular key patterns create a combinatorial explosion:

```
rl:{ip}:{method}:{path}:{api_version}
→ 10,000 IPs × 5 methods × 200 paths × 3 versions = 30,000,000 keys
```

Each key consumes ~100–200 bytes of overhead in Redis, so 30M keys ≈ 3–6 GB of metadata alone.

### Diagnosis

```bash
# Count rate limit keys
redis-cli --scan --pattern 'rl:*' | wc -l

# Sample key TTLs — find keys without expiry
redis-cli --scan --pattern 'rl:*' | head -100 | while read key; do
    ttl=$(redis-cli TTL "$key")
    if [ "$ttl" = "-1" ]; then
        echo "NO EXPIRY: $key"
    fi
done

# Memory analysis
redis-cli INFO memory
redis-cli MEMORY USAGE "rl:some:key"
```

### Solution

**1. Always set TTLs on rate limit keys:**

```lua
redis.call('EXPIRE', key, window_seconds * 2)
```

**2. Reduce key granularity:**

```
-- Instead of per-IP-per-endpoint-per-method:
rl:ip:1.2.3.4:GET:/api/v1/users

-- Use per-IP with layered per-endpoint:
rl:ip:1.2.3.4          (global per-IP limit)
rl:ep:POST:/api/upload  (global per-endpoint limit)
```

**3. Use hash structures for per-user counters:**

```lua
-- Instead of individual keys per endpoint per user:
redis.call('HINCRBY', 'rl:user:123', 'GET:/api/users', 1)
redis.call('EXPIRE', 'rl:user:123', window_seconds * 2)
-- One key with N fields instead of N keys
```

**4. Implement key eviction monitoring:**

```bash
# Alert if key count exceeds threshold
KEY_COUNT=$(redis-cli DBSIZE | awk '{print $2}')
if [ "$KEY_COUNT" -gt 1000000 ]; then
    echo "ALERT: Redis has $KEY_COUNT keys" | notify
fi
```

---

## Memory Growth with Sliding Window Logs

### Symptom

Redis memory grows linearly with request volume. Specific keys for high-traffic clients become very large. `MEMORY USAGE` on a single rate limit key returns megabytes.

### Root Cause

Sliding window log stores a timestamp for every request in a sorted set. A client making 1000 req/s with a 60s window stores 60,000 entries per key. Each sorted set entry is ~64 bytes → 3.8 MB per active client.

### Diagnosis

```bash
# Check sorted set sizes for rate limit keys
redis-cli --scan --pattern 'rl:swl:*' | while read key; do
    size=$(redis-cli ZCARD "$key")
    mem=$(redis-cli MEMORY USAGE "$key")
    echo "$key: $size entries, $mem bytes"
done | sort -t: -k4 -rn | head -20
```

### Solution

**1. Switch to sliding window counter (recommended):**

Uses only 2 counters per key instead of N timestamps. See the main SKILL.md for the algorithm.

**2. If you must use sliding window log, cap the sorted set:**

```lua
-- After adding the timestamp
redis.call('ZADD', key, now, now .. ':' .. math.random())
-- Remove old entries
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
-- Safety cap: remove oldest entries if set is too large
local size = redis.call('ZCARD', key)
if size > max_entries then
    redis.call('ZREMRANGEBYRANK', key, 0, size - max_entries - 1)
end
```

**3. Use shorter windows for high-traffic keys:**

Instead of `1000 req/60s`, use `17 req/1s` (approximately equivalent). Shorter windows mean fewer timestamps stored.

**4. Monitor sorted set sizes:**

```python
# Periodic cleanup job
async def cleanup_large_sorted_sets(redis, pattern='rl:swl:*', max_size=10000):
    async for key in redis.scan_iter(match=pattern):
        size = await redis.zcard(key)
        if size > max_size:
            logger.warning(f"Trimming oversized rate limit key: {key} ({size} entries)")
            await redis.zremrangebyrank(key, 0, size - max_size - 1)
```

---

## False Positives from Shared IPs

### Symptom

Legitimate users are rate-limited despite making few requests. Complaints cluster from corporate offices, universities, or regions with carrier-grade NAT. Users behind VPNs or Tor exit nodes are disproportionately affected.

### Root Cause

Multiple users share a single IP address. A per-IP rate limit of 100 req/min may be consumed by 50 users making 2 requests each, blocking the 51st user entirely.

Common shared-IP scenarios:
- **Corporate NAT:** 1000+ employees behind a single public IP
- **Carrier-grade NAT (CGNAT):** ISPs sharing IPs across thousands of subscribers
- **VPN services:** Millions of users behind a few hundred exit IPs
- **University networks:** Entire campus behind one or a few IPs
- **Tor exit nodes:** ~1000 exit nodes serving all Tor traffic

### Diagnosis

```bash
# Find IPs hitting rate limits most often
grep "429" access.log | awk '{print $1}' | sort | uniq -c | sort -rn | head -20

# Check if top IPs are known NAT/VPN/Tor ranges
# Cross-reference with AS databases
whois 203.0.113.42 | grep -i "org\|netname\|descr"
```

### Solution

**1. Prefer authenticated identity over IP:**

```typescript
function extractRateLimitKey(req: Request): string {
  // Prefer user ID if authenticated
  if (req.user?.id) return `user:${req.user.id}`;
  // Fall back to API key
  if (req.headers['x-api-key']) return `key:${req.headers['x-api-key']}`;
  // Last resort: IP with higher limits
  return `ip:${req.ip}`;
}

function getLimitForKeyType(keyType: string): number {
  switch (keyType) {
    case 'user': return 100;
    case 'key': return 200;
    case 'ip': return 500;  // Higher limit for shared IPs
  }
}
```

**2. Use compound keys:**

Combine IP with additional signals to differentiate users behind the same IP:

```typescript
function compoundKey(req: Request): string {
  const ip = req.ip;
  const ua = req.headers['user-agent'] || 'unknown';
  const uaHash = crypto.createHash('md5').update(ua).digest('hex').slice(0, 8);
  return `rl:${ip}:${uaHash}`;
}
```

**3. Dynamic limits for known shared IPs:**

Maintain a list of known NAT/VPN IP ranges and apply higher limits:

```typescript
const KNOWN_SHARED_RANGES = [
  { cidr: '198.51.100.0/24', multiplier: 10, label: 'corporate-nat' },
  { cidr: '203.0.113.0/24', multiplier: 5, label: 'university' },
];

function getIPMultiplier(ip: string): number {
  for (const range of KNOWN_SHARED_RANGES) {
    if (isInCIDR(ip, range.cidr)) return range.multiplier;
  }
  return 1;
}
```

**4. Implement graduated responses:**

Instead of hard-blocking at the limit, use CAPTCHAs or challenges:

```
0-100 req/min: Allow freely
100-500 req/min: Require CAPTCHA every 10th request
500+ req/min: Block
```

---

## Bypass via Header Spoofing

### Symptom

Rate limits are ineffective. Attackers rotate identities rapidly. The `X-Forwarded-For` header contains implausible values (random IPs, `127.0.0.1`, or extremely long chains).

### Root Cause

The application uses the `X-Forwarded-For` or `X-Real-IP` header to identify clients, but these headers can be spoofed by the client. Without proper configuration, the rate limiter uses the attacker-supplied identity.

```
Attacker sends:
X-Forwarded-For: 1.2.3.4        ← spoofed, different each request
Actual source IP: 10.0.0.1      ← real IP, never used for limiting
```

### Diagnosis

```bash
# Look for suspicious X-Forwarded-For patterns
grep "X-Forwarded-For" access.log | awk -F'"' '{print $NF}' | sort | uniq -c | sort -rn

# Check for single source IPs with many different X-Forwarded-For values
awk '{print $1, $NF}' access.log | sort | uniq | awk '{print $1}' | sort | uniq -c | sort -rn
```

### Solution

**1. Trust only known proxy headers:**

Configure your framework to only trust `X-Forwarded-For` entries from known proxy IPs:

```typescript
// Express
app.set('trust proxy', ['10.0.0.0/8', '172.16.0.0/12']);
// Now req.ip correctly extracts the client IP from the trusted chain

// Nginx: set the real IP from trusted proxies only
set_real_ip_from 10.0.0.0/8;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

**2. Use the rightmost untrusted IP:**

```typescript
function extractClientIP(req: Request, trustedProxies: string[]): string {
  const forwarded = (req.headers['x-forwarded-for'] || '').split(',').map(s => s.trim());
  // Walk from right to left, stop at the first untrusted IP
  for (let i = forwarded.length - 1; i >= 0; i--) {
    if (!isTrustedProxy(forwarded[i], trustedProxies)) {
      return forwarded[i];
    }
  }
  // All are trusted (shouldn't happen), fall back to socket IP
  return req.socket.remoteAddress;
}
```

**3. Never trust leftmost IP:**

The leftmost IP in `X-Forwarded-For` is the one the client set. It's trivially spoofable. Always use the rightmost non-proxy IP or the direct TCP connection IP.

**4. Use alternative identification:**

For authenticated APIs, rate limit by API key or user ID instead of IP. For unauthenticated endpoints, combine IP with TLS fingerprinting (JA3/JA4) for stronger identification.

---

## Load Balancer Sticky Session Interaction

### Symptom

Rate limits are enforced unevenly. Some users hit limits much sooner than expected. Restarting an application server causes a burst of 429 responses. In-memory rate limiters show wildly different counts across instances.

### Root Cause

Sticky sessions (session affinity) route all requests from a client to the same backend instance. If using in-memory rate limiting, the full limit applies per-instance. If the load balancer redistributes sessions (e.g., after a server restart), clients suddenly face fresh or different counters.

With centralized (Redis) rate limiting, sticky sessions can still cause issues:
- All traffic for a heavy client hits one server, overloading its Redis connection pool
- Session redistribution causes counter resets if using in-memory components

### Diagnosis

```bash
# Check if sticky sessions are enabled
# AWS ALB
aws elbv2 describe-target-group-attributes --target-group-arn $TG_ARN | grep stickiness

# Nginx upstream
grep -A5 'upstream' /etc/nginx/nginx.conf | grep -i 'sticky\|hash\|ip_hash'

# Check request distribution across instances
awk '{print $1, $NF}' access.log | sort | uniq -c | sort -rn
```

### Solution

**1. Always use centralized rate limiting (Redis) with sticky sessions:**

Never rely on in-memory counters when sessions are sticky — the limits won't be globally consistent.

**2. If you must use in-memory limiting, disable sticky sessions:**

Use round-robin or least-connections load balancing so traffic distributes evenly. Divide the limit by the number of instances:

```typescript
const GLOBAL_LIMIT = 1000;
const NUM_INSTANCES = parseInt(process.env.NUM_INSTANCES || '4');
const PER_INSTANCE_LIMIT = Math.ceil(GLOBAL_LIMIT / NUM_INSTANCES);
```

**3. Handle session redistribution gracefully:**

When a server starts, it shouldn't assume all clients are new. Pre-warm counters from a central store:

```typescript
async function onServerStart() {
  // Sync local rate limit state from Redis
  const keys = await redis.scan('rl:*');
  for (const key of keys) {
    const count = await redis.get(key);
    localLimiter.setCounter(key, parseInt(count));
  }
}
```

---

## Debugging Rate Limit Decisions

### Adding Observability

**1. Structured logging for every rate limit decision:**

```typescript
interface RateLimitDecision {
  timestamp: string;
  clientKey: string;
  endpoint: string;
  algorithm: string;
  allowed: boolean;
  currentCount: number;
  limit: number;
  remaining: number;
  windowResetAt: string;
  latencyMs: number;
}

function logRateLimitDecision(decision: RateLimitDecision): void {
  logger.info('rate_limit_check', {
    ...decision,
    // Don't log full IP — hash it for privacy
    clientKeyHash: crypto.createHash('sha256').update(decision.clientKey).digest('hex').slice(0, 12),
  });
}
```

**2. Metrics to collect:**

```
rate_limit_checks_total{result="allowed|rejected", algorithm="token_bucket|sliding_window"}
rate_limit_remaining{client_tier="free|pro|enterprise"}
rate_limit_latency_seconds{backend="redis|memory"}
rate_limit_store_errors_total{error_type="timeout|connection|script"}
rate_limit_fallback_activations_total
```

**3. Debug headers (non-production):**

```typescript
if (process.env.RATE_LIMIT_DEBUG === 'true') {
  res.set({
    'X-RateLimit-Debug-Key': clientKey,
    'X-RateLimit-Debug-Algorithm': 'sliding_window_counter',
    'X-RateLimit-Debug-CurrentCount': String(currentCount),
    'X-RateLimit-Debug-WindowStart': String(windowStart),
    'X-RateLimit-Debug-WeightedPrev': String(weightedPrevCount),
  });
}
```

### Diagnostic Commands

**Check a client's current rate limit state in Redis:**

```bash
# For fixed window / sliding window counter
redis-cli GET "rl:user:12345"
redis-cli TTL "rl:user:12345"

# For token bucket
redis-cli HGETALL "rl:tb:user:12345"

# For sliding window log
redis-cli ZCARD "rl:swl:user:12345"
redis-cli ZRANGEBYSCORE "rl:swl:user:12345" "-inf" "+inf" WITHSCORES LIMIT 0 10
```

**Simulate a rate limit check without consuming capacity:**

```lua
-- dry_run_check.lua: Check if a request would be allowed, without incrementing
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local current = tonumber(redis.call('GET', key) or '0')
return current < limit and 1 or 0
```

**Trace a specific client's request history:**

```bash
# Extract all requests from a specific client in the last hour
grep "client_id=user:12345" /var/log/app/ratelimit.log | \
    awk -F'|' '{print $1, $3, $5}' | \
    tail -50
```

### Common Debugging Scenarios

**"Why was this request rejected?"**

1. Check the client's current counter: `redis-cli GET rl:user:12345`
2. Check the configured limit for their tier
3. Verify the key pattern matches expectations (wrong key = wrong counter)
4. Check clock skew if using time-based windows
5. Check if multiple rate limiters are stacked (global + per-user + per-endpoint)

**"Rate limits seem to reset too early/late"**

1. Compare `RateLimit-Reset` header with actual Redis key TTL
2. Check if window boundaries align with expectations: `redis-cli TTL rl:user:12345`
3. Verify time source: are you using client time or Redis `TIME`?
4. Check for key overwrites: another part of the app may be modifying the same key

**"Different servers give different rate limit counts"**

1. Verify all servers connect to the same Redis instance/cluster
2. Check for in-memory caching of rate limit results
3. Verify Lua scripts are identical across deployments (hash the script)
4. Check for local fallback rate limiters being active (Redis connection issues)
