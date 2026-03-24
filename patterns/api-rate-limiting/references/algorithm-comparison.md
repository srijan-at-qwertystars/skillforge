# Rate Limiting Algorithm Deep Comparison

## Table of Contents
- [Overview](#overview)
- [Fixed Window Counter](#1-fixed-window-counter)
- [Sliding Window Log](#2-sliding-window-log)
- [Sliding Window Counter](#3-sliding-window-counter)
- [Token Bucket](#4-token-bucket)
- [Leaky Bucket](#5-leaky-bucket)
- [Head-to-Head Comparison](#head-to-head-comparison)
- [Decision Flowchart](#decision-flowchart)
- [Redis Implementation Complexity](#redis-implementation-complexity)
- [Benchmark Characteristics](#benchmark-characteristics)

---

## Overview

| Algorithm              | Burst Tolerance | Memory/Key | Accuracy     | Redis Ops/Check | Impl. Complexity |
|------------------------|-----------------|------------|--------------|-----------------|------------------|
| Fixed Window           | Worst (2x)      | O(1)       | Poor at edge | 2               | Trivial          |
| Sliding Window Log     | None            | O(n)       | Exact        | 4               | Moderate         |
| Sliding Window Counter | Low             | O(1)       | ~99.7%       | 3-5             | Moderate         |
| Token Bucket           | Configurable    | O(1)       | Exact        | 3               | Moderate         |
| Leaky Bucket           | None            | O(1)       | Exact        | 3               | Moderate         |

---

## 1. Fixed Window Counter

### How It Works
Divide time into fixed intervals (e.g., every minute at :00). Maintain a counter per key per window. Increment on each request. Reject when counter exceeds limit.

```
Window 1 (0:00-0:59)    Window 2 (1:00-1:59)
████████░░ (80/100)      ██░░░░░░░░ (20/100)
```

### Redis Implementation
```lua
-- fixed_window.lua
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])

local count = redis.call('INCR', key)
if count == 1 then
    redis.call('EXPIRE', key, window)
end
if count > limit then
    return -1
end
return limit - count
```

**Redis ops**: 1 INCR + 1 conditional EXPIRE = 2 ops.
**Keys**: 1 key per client per window. Auto-expires.

### Pros
- Simplest to implement and understand
- Lowest Redis overhead (2 ops, 1 key)
- Predictable memory usage

### Cons
- **Boundary burst**: At :59 a client uses 100 requests, at :00 another 100 — 200 in 2 seconds while the limit is "100 per minute"
- Unfair to users who start requests mid-window
- Reset cliff: all capacity returns instantly at window boundary

### When to Use
- Login attempt throttling (security doesn't need sub-minute precision)
- Internal service limits where simplicity > accuracy
- Prototype/MVP rate limiting

---

## 2. Sliding Window Log

### How It Works
Store the timestamp of every request in a sorted set. On each check, remove entries older than the window. Count remaining entries. Allow if count < limit.

```
Now = T100, Window = 60s
Log: [T41, T55, T67, T72, T88, T95, T99]
Remove < T40: [T41, T55, T67, T72, T88, T95, T99] → 7 entries
Limit = 10 → allowed (7 < 10)
```

### Redis Implementation
```lua
-- sliding_window_log.lua
local key = KEYS[1]
local window = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local request_id = ARGV[4]

-- Remove expired entries
redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
local count = redis.call('ZCARD', key)

if count >= limit then
    local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
    local retry_after = oldest[2] and (tonumber(oldest[2]) + window - now) or window
    return cjson.encode({allowed=false, remaining=0, retry_after=math.ceil(retry_after)})
end

redis.call('ZADD', key, now, request_id)
redis.call('EXPIRE', key, window + 1)
return cjson.encode({allowed=true, remaining=limit - count - 1})
```

**Redis ops**: ZREMRANGEBYSCORE + ZCARD + conditional ZADD + EXPIRE = 4 ops.
**Keys**: 1 sorted set per client. Size grows with request count.

### Pros
- Perfect accuracy — no approximation, no boundary issues
- Naturally sliding — each request has its own expiry
- Can calculate exact retry_after from the oldest entry

### Cons
- **Memory**: O(n) per key where n = requests in window. A client at 10,000 req/hour stores 10,000 timestamps
- **Latency**: ZREMRANGEBYSCORE is O(log(n) + m) where m = removed entries
- Not viable for high-volume anonymous endpoints (memory explosion)

### When to Use
- Billing-critical limits where every request must be counted exactly
- Compliance/audit endpoints requiring per-request logging
- Low-volume, high-value operations (payments, exports)

---

## 3. Sliding Window Counter

### How It Works
Combine two fixed-window counters (current and previous) with weighted interpolation to approximate a sliding window.

```
Previous window: 84 requests (12:00-12:59)
Current window:  15 requests (13:00-now)
Current time: 13:15 (25% into current window)
Weighted count = 84 × 0.75 + 15 = 78
Limit 100 → allowed
```

Formula: `count = prev_count × (1 - elapsed_fraction) + curr_count`

### Redis Implementation
```lua
-- sliding_window_counter.lua
local curr_key = KEYS[1]
local prev_key = KEYS[2]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])

local curr_window = math.floor(now / window)
local prev_window = curr_window - 1
local elapsed = (now % window) / window  -- fraction of current window elapsed

local curr_count = tonumber(redis.call('GET', curr_key) or "0")
local prev_count = tonumber(redis.call('GET', prev_key) or "0")
local weighted = prev_count * (1 - elapsed) + curr_count

if weighted >= limit then
    return -1
end

redis.call('INCR', curr_key)
redis.call('EXPIRE', curr_key, window * 2)
return math.floor(limit - weighted - 1)
```

**Redis ops**: 2 GETs + 1 INCR + 1 EXPIRE = 4 ops (but simple ops).
**Keys**: 2 counters per client. Constant memory.

### Pros
- O(1) memory — just 2 counters regardless of traffic
- ~99.7% accuracy (Cloudflare's analysis) compared to sliding log
- No boundary burst problem (smooths the transition)
- Simple math, fast execution

### Cons
- Approximate — weighted count can be off by a small amount
- Requires two keys per client (minor concern)
- Slightly more complex than fixed window

### When to Use
- **Default choice for most APIs** — best accuracy-to-memory ratio
- General-purpose rate limiting at any scale
- High-traffic public endpoints where log-based approaches are too expensive

---

## 4. Token Bucket

### How It Works
Each client has a "bucket" holding tokens (max = burst capacity). Tokens refill at a steady rate. Each request consumes one or more tokens. If insufficient tokens, reject.

```
Capacity: 10 tokens, Refill: 2/sec
Time 0:  [██████████] 10 tokens → request costs 1 → 9 left
Time 0:  [█████████░]  9 tokens → burst of 5 → 4 left
Time 3:  [██████████] 10 tokens (refilled 6, capped at 10)
```

### Redis Implementation
```lua
-- token_bucket.lua (see assets/token-bucket.lua for full version)
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])  -- tokens/sec
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4]) or 1

local data = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(data[1]) or capacity
local last = tonumber(data[2]) or now

-- Refill based on elapsed time
local elapsed = math.max(0, now - last)
tokens = math.min(capacity, tokens + elapsed * refill_rate)

if tokens < cost then
    redis.call('HSET', key, 'tokens', tokens, 'last_refill', now)
    redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) + 1)
    local wait = (cost - tokens) / refill_rate
    return cjson.encode({allowed=false, remaining=0, retry_after=math.ceil(wait)})
end

tokens = tokens - cost
redis.call('HSET', key, 'tokens', tokens, 'last_refill', now)
redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) + 1)
return cjson.encode({allowed=true, remaining=math.floor(tokens)})
```

**Redis ops**: HMGET + HSET + EXPIRE = 3 ops.
**Keys**: 1 hash per client (2 fields).

### Pros
- **Burst-friendly**: Accumulated tokens allow short bursts, then rate-caps
- O(1) memory — hash with 2 fields
- Natural fit for variable-cost operations (pass `cost` param)
- Can calculate exact retry_after: `(cost - tokens) / refill_rate`
- Widely understood — used by AWS, Stripe, GitHub APIs

### Cons
- Slightly more math than fixed window
- Refill calculation must be atomic (Lua required)
- Burst capacity may surprise users ("I got 100 requests instantly, then was throttled for a minute")

### When to Use
- Public SaaS APIs with burst tolerance
- Variable-cost endpoints (cost-based limiting)
- When you want smooth rate enforcement with burst accommodation
- Mobile/frontend clients that make bursty requests on app open

---

## 5. Leaky Bucket

### How It Works
Requests enter a queue that "leaks" (drains) at a constant rate. If the queue is full, reject. Two modes:
- **As a meter** (policing): count outflow rate, drop excess — no actual queue
- **As a queue** (shaping): buffer requests, process at fixed rate — adds latency

```
Capacity: 5, Drain rate: 1/sec
[█████] full → new request → REJECTED
[████░] 4 queued → new request → accepted, queued → [█████]
After 1s: [████░] → one drained
```

### Redis Implementation (as a meter)
```lua
-- leaky_bucket.lua
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local leak_rate = tonumber(ARGV[2])  -- requests/sec drained
local now = tonumber(ARGV[3])

local data = redis.call('HMGET', key, 'water', 'last_leak')
local water = tonumber(data[1]) or 0
local last = tonumber(data[2]) or now

-- Drain based on elapsed time
local elapsed = math.max(0, now - last)
water = math.max(0, water - elapsed * leak_rate)

if water >= capacity then
    redis.call('HSET', key, 'water', water, 'last_leak', now)
    redis.call('EXPIRE', key, math.ceil(capacity / leak_rate) + 1)
    return -1  -- rejected
end

water = water + 1
redis.call('HSET', key, 'water', water, 'last_leak', now)
redis.call('EXPIRE', key, math.ceil(capacity / leak_rate) + 1)
return capacity - water  -- remaining
```

### Pros
- Guarantees smooth, even output — no bursts ever
- O(1) memory
- Ideal for upstream API proxying (match their rate exactly)
- Simple mental model: "X requests per second, period"

### Cons
- No burst tolerance — punishes legitimate bursty usage
- Queue-mode adds latency (requests wait instead of being served immediately)
- Less flexible than token bucket for variable-cost operations

### When to Use
- Payment processing (must not exceed upstream provider's rate)
- Third-party API proxying (match their rate limit exactly)
- Background job processing at steady throughput
- Any scenario where burst prevention is explicitly desired

---

## Head-to-Head Comparison

### Accuracy Under Boundary Conditions

| Scenario                              | Fixed Window | Sliding Log | Sliding Counter | Token Bucket | Leaky Bucket |
|---------------------------------------|:------------:|:-----------:|:---------------:|:------------:|:------------:|
| Limit=100/min, 100 req at :58-:00     | 200 pass ✗   | 100 pass ✓  | ~105 pass ≈     | 100 pass ✓   | 100 pass ✓   |
| Steady 1.5 req/sec (limit=100/min)    | Pass ✓       | Pass ✓      | Pass ✓          | Pass ✓       | Pass ✓       |
| Burst of 50 then silence              | Pass ✓       | Pass ✓      | Pass ✓          | Pass ✓       | Partial ✗    |
| 10 clients, 10 req/min each, overlapping | Inaccurate  | Exact       | Very good       | Exact        | Exact        |

### Memory at Scale

For 1M unique clients, limit=1000/hour:

| Algorithm          | Memory per Client | Total Memory (1M clients) |
|--------------------|-------------------|---------------------------|
| Fixed Window       | ~80 bytes         | ~80 MB                    |
| Sliding Window Log | ~24 KB (1K entries)| ~24 GB                   |
| Sliding Window Counter | ~160 bytes    | ~160 MB                   |
| Token Bucket       | ~120 bytes        | ~120 MB                   |
| Leaky Bucket       | ~120 bytes        | ~120 MB                   |

Sliding Window Log is 150-300x more expensive in memory. At scale, this alone can disqualify it.

### Latency Characteristics

| Algorithm          | Best Case | Worst Case       | Notes                                |
|--------------------|-----------|------------------|--------------------------------------|
| Fixed Window       | ~0.1ms    | ~0.2ms           | Always fast — just INCR              |
| Sliding Window Log | ~0.2ms    | ~5ms             | ZREMRANGEBYSCORE on large sets       |
| Sliding Window Counter | ~0.2ms | ~0.3ms          | Simple GETs and math                 |
| Token Bucket       | ~0.2ms    | ~0.3ms           | HMGET + math + HSET                  |
| Leaky Bucket       | ~0.2ms    | ~0.3ms           | Same as token bucket                 |

---

## Decision Flowchart

```
Need rate limiting?
│
├─ Is burst tolerance needed?
│  ├─ YES → Token Bucket
│  │         (set capacity = max burst, refill_rate = avg rate)
│  └─ NO → Must enforce constant rate?
│           ├─ YES → Leaky Bucket
│           └─ NO → continue below
│
├─ Is exact per-request accuracy required?
│  ├─ YES → Can afford O(n) memory per client?
│  │         ├─ YES → Sliding Window Log
│  │         └─ NO → Sliding Window Counter (~99.7% accuracy)
│  └─ NO → continue below
│
├─ Is simplicity the top priority?
│  ├─ YES → Fixed Window Counter
│  └─ NO → Sliding Window Counter (default recommendation)
```

---

## Redis Implementation Complexity

### Lines of Lua (approximate)

| Algorithm              | Lua Lines | External State | Atomic Ops     |
|------------------------|-----------|----------------|----------------|
| Fixed Window           | 5-8       | 1 string key   | INCR, EXPIRE   |
| Sliding Window Log     | 10-15     | 1 sorted set   | ZADD, ZREMRANGEBYSCORE, ZCARD |
| Sliding Window Counter | 12-18     | 2 string keys  | GET, INCR, EXPIRE |
| Token Bucket           | 15-20     | 1 hash (2 fields)| HMGET, HSET, EXPIRE |
| Leaky Bucket           | 15-20     | 1 hash (2 fields)| HMGET, HSET, EXPIRE |

### Operational Complexity

| Concern                     | Fixed Window | Sliding Log | Sliding Counter | Token Bucket | Leaky Bucket |
|-----------------------------|:------------:|:-----------:|:---------------:|:------------:|:------------:|
| Key expiry management       | Auto         | Manual+Auto | Auto            | Auto         | Auto         |
| Memory monitoring needed    | No           | **Yes**     | No              | No           | No           |
| Clock sensitivity           | Low          | **High**    | Medium          | **High**     | **High**     |
| Debugging difficulty        | Easy         | Medium      | Medium          | Medium       | Medium       |
| Migration complexity        | Trivial      | Medium      | Easy            | Easy         | Easy         |

---

## Benchmark Characteristics

### Throughput (ops/sec on Redis 7, single thread)

Typical benchmarks on commodity hardware:

| Algorithm              | ops/sec (single key) | ops/sec (distributed keys) |
|------------------------|----------------------|----------------------------|
| Fixed Window           | ~150,000             | ~300,000                   |
| Sliding Window Log     | ~50,000              | ~120,000                   |
| Sliding Window Counter | ~120,000             | ~250,000                   |
| Token Bucket           | ~100,000             | ~220,000                   |
| Leaky Bucket           | ~100,000             | ~220,000                   |

Sliding Window Log is 2-3x slower due to sorted set operations. All others are comparable.

### Recommendation Summary

| Priority                  | Best Algorithm         | Runner-Up               |
|---------------------------|------------------------|-------------------------|
| General-purpose API       | Sliding Window Counter | Token Bucket            |
| Burst-tolerant API        | Token Bucket           | Fixed Window            |
| Exact counting            | Sliding Window Log     | Sliding Window Counter  |
| Smooth rate enforcement   | Leaky Bucket           | Token Bucket (low cap)  |
| Simplicity                | Fixed Window           | Sliding Window Counter  |
| Memory-constrained        | Fixed Window           | Token Bucket            |
| Variable-cost operations  | Token Bucket           | Sliding Window Counter  |
