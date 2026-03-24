/**
 * Rate Limiter Library — Token Bucket, Sliding Window Counter, and Fixed Window
 * implementations backed by Redis for distributed rate limiting.
 *
 * Usage:
 *   import { createRateLimiter } from './rate-limiter';
 *   const limiter = createRateLimiter(redisClient, { algorithm: 'token-bucket', ... });
 *   const result = await limiter.consume('user:123');
 *   if (!result.allowed) { /* reject with 429 *\/ }
 */

import type { Redis } from 'ioredis';

// ─── Types ──────────────────────────────────────────────────────────────────────

export interface RateLimitResult {
  allowed: boolean;
  limit: number;
  remaining: number;
  resetAt: number; // Unix timestamp (seconds)
  retryAfter: number; // Seconds until next allowed request (0 if allowed)
}

export interface TokenBucketConfig {
  algorithm: 'token-bucket';
  capacity: number;
  refillRate: number; // tokens per second
  keyPrefix?: string;
}

export interface SlidingWindowConfig {
  algorithm: 'sliding-window';
  limit: number;
  windowSeconds: number;
  keyPrefix?: string;
}

export interface FixedWindowConfig {
  algorithm: 'fixed-window';
  limit: number;
  windowSeconds: number;
  keyPrefix?: string;
}

export type RateLimiterConfig =
  | TokenBucketConfig
  | SlidingWindowConfig
  | FixedWindowConfig;

export interface RateLimiter {
  consume(key: string, cost?: number): Promise<RateLimitResult>;
  peek(key: string): Promise<RateLimitResult>;
  reset(key: string): Promise<void>;
}

// ─── Lua Scripts ────────────────────────────────────────────────────────────────

const TOKEN_BUCKET_LUA = `
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4])

local data = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(data[1]) or capacity
local last_refill = tonumber(data[2]) or now

local elapsed = math.max(0, now - last_refill)
tokens = math.min(capacity, tokens + elapsed * refill_rate)

local allowed = 0
if tokens >= cost then
  tokens = tokens - cost
  allowed = 1
end

redis.call('HMSET', key, 'tokens', tokens, 'last_refill', now)
redis.call('EXPIRE', key, math.ceil(capacity / refill_rate) * 2)

local retry_after = 0
if allowed == 0 then
  retry_after = math.ceil((cost - tokens) / refill_rate)
end

return {allowed, math.floor(tokens), retry_after}
`;

const SLIDING_WINDOW_LUA = `
local key = KEYS[1]
local prev_key = KEYS[2]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4])

local window_start = now - (now % window)
local elapsed = now - window_start
local weight = (window - elapsed) / window

local prev_count = tonumber(redis.call('GET', prev_key) or '0')
local curr_count = tonumber(redis.call('GET', key) or '0')
local effective = prev_count * weight + curr_count

if effective + cost > limit then
  local retry_after = math.ceil(window - elapsed)
  return {0, math.floor(limit - effective), retry_after, window_start + window}
end

redis.call('INCRBY', key, cost)
redis.call('EXPIRE', key, window * 2)

local new_effective = prev_count * weight + curr_count + cost
local remaining = math.max(0, math.floor(limit - new_effective))
return {1, remaining, 0, window_start + window}
`;

const FIXED_WINDOW_LUA = `
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local cost = tonumber(ARGV[3])

local current = tonumber(redis.call('GET', key) or '0')

if current + cost > limit then
  local ttl = redis.call('TTL', key)
  if ttl < 0 then ttl = window end
  return {0, math.max(0, limit - current), ttl}
end

local new_count = redis.call('INCRBY', key, cost)
if new_count == cost then
  redis.call('EXPIRE', key, window)
end

local ttl = redis.call('TTL', key)
if ttl < 0 then ttl = window end

return {1, math.max(0, limit - new_count), ttl}
`;

// ─── Token Bucket ───────────────────────────────────────────────────────────────

class TokenBucketLimiter implements RateLimiter {
  constructor(
    private redis: Redis,
    private config: TokenBucketConfig
  ) {}

  private fullKey(key: string): string {
    return `${this.config.keyPrefix || 'rl:tb'}:${key}`;
  }

  async consume(key: string, cost = 1): Promise<RateLimitResult> {
    const now = Date.now() / 1000;
    const result = (await this.redis.eval(
      TOKEN_BUCKET_LUA,
      1,
      this.fullKey(key),
      this.config.capacity,
      this.config.refillRate,
      now,
      cost
    )) as [number, number, number];

    const [allowed, remaining, retryAfter] = result;

    return {
      allowed: allowed === 1,
      limit: this.config.capacity,
      remaining,
      resetAt: Math.ceil(now + this.config.capacity / this.config.refillRate),
      retryAfter,
    };
  }

  async peek(key: string): Promise<RateLimitResult> {
    const now = Date.now() / 1000;
    const data = await this.redis.hmget(this.fullKey(key), 'tokens', 'last_refill');
    let tokens = data[0] !== null ? parseFloat(data[0]) : this.config.capacity;
    const lastRefill = data[1] !== null ? parseFloat(data[1]) : now;

    const elapsed = Math.max(0, now - lastRefill);
    tokens = Math.min(this.config.capacity, tokens + elapsed * this.config.refillRate);

    return {
      allowed: tokens >= 1,
      limit: this.config.capacity,
      remaining: Math.floor(tokens),
      resetAt: Math.ceil(now + this.config.capacity / this.config.refillRate),
      retryAfter: tokens >= 1 ? 0 : Math.ceil((1 - tokens) / this.config.refillRate),
    };
  }

  async reset(key: string): Promise<void> {
    await this.redis.del(this.fullKey(key));
  }
}

// ─── Sliding Window Counter ─────────────────────────────────────────────────────

class SlidingWindowLimiter implements RateLimiter {
  constructor(
    private redis: Redis,
    private config: SlidingWindowConfig
  ) {}

  private keys(key: string): { current: string; previous: string } {
    const prefix = this.config.keyPrefix || 'rl:sw';
    const now = Date.now() / 1000;
    const windowStart = now - (now % this.config.windowSeconds);
    const prevWindowStart = windowStart - this.config.windowSeconds;
    return {
      current: `${prefix}:${key}:${windowStart}`,
      previous: `${prefix}:${key}:${prevWindowStart}`,
    };
  }

  async consume(key: string, cost = 1): Promise<RateLimitResult> {
    const now = Date.now() / 1000;
    const { current, previous } = this.keys(key);

    const result = (await this.redis.eval(
      SLIDING_WINDOW_LUA,
      2,
      current,
      previous,
      this.config.limit,
      this.config.windowSeconds,
      Math.floor(now),
      cost
    )) as [number, number, number, number];

    const [allowed, remaining, retryAfter, resetAt] = result;

    return {
      allowed: allowed === 1,
      limit: this.config.limit,
      remaining: Math.max(0, remaining),
      resetAt,
      retryAfter,
    };
  }

  async peek(key: string): Promise<RateLimitResult> {
    const now = Date.now() / 1000;
    const { current, previous } = this.keys(key);

    const [prevCount, currCount] = await Promise.all([
      this.redis.get(previous).then((v) => parseInt(v || '0', 10)),
      this.redis.get(current).then((v) => parseInt(v || '0', 10)),
    ]);

    const windowStart = now - (now % this.config.windowSeconds);
    const elapsed = now - windowStart;
    const weight = (this.config.windowSeconds - elapsed) / this.config.windowSeconds;
    const effective = prevCount * weight + currCount;

    return {
      allowed: effective < this.config.limit,
      limit: this.config.limit,
      remaining: Math.max(0, Math.floor(this.config.limit - effective)),
      resetAt: windowStart + this.config.windowSeconds,
      retryAfter: effective >= this.config.limit ? Math.ceil(this.config.windowSeconds - elapsed) : 0,
    };
  }

  async reset(key: string): Promise<void> {
    const { current, previous } = this.keys(key);
    await this.redis.del(current, previous);
  }
}

// ─── Fixed Window ───────────────────────────────────────────────────────────────

class FixedWindowLimiter implements RateLimiter {
  constructor(
    private redis: Redis,
    private config: FixedWindowConfig
  ) {}

  private fullKey(key: string): string {
    const prefix = this.config.keyPrefix || 'rl:fw';
    const window = Math.floor(Date.now() / 1000 / this.config.windowSeconds);
    return `${prefix}:${key}:${window}`;
  }

  async consume(key: string, cost = 1): Promise<RateLimitResult> {
    const redisKey = this.fullKey(key);

    const result = (await this.redis.eval(
      FIXED_WINDOW_LUA,
      1,
      redisKey,
      this.config.limit,
      this.config.windowSeconds,
      cost
    )) as [number, number, number];

    const [allowed, remaining, ttl] = result;
    const resetAt = Math.ceil(Date.now() / 1000) + ttl;

    return {
      allowed: allowed === 1,
      limit: this.config.limit,
      remaining: Math.max(0, remaining),
      resetAt,
      retryAfter: allowed === 1 ? 0 : ttl,
    };
  }

  async peek(key: string): Promise<RateLimitResult> {
    const redisKey = this.fullKey(key);
    const [count, ttl] = await Promise.all([
      this.redis.get(redisKey).then((v) => parseInt(v || '0', 10)),
      this.redis.ttl(redisKey),
    ]);

    const remaining = Math.max(0, this.config.limit - count);
    const effectiveTtl = ttl > 0 ? ttl : this.config.windowSeconds;

    return {
      allowed: count < this.config.limit,
      limit: this.config.limit,
      remaining,
      resetAt: Math.ceil(Date.now() / 1000) + effectiveTtl,
      retryAfter: count >= this.config.limit ? effectiveTtl : 0,
    };
  }

  async reset(key: string): Promise<void> {
    await this.redis.del(this.fullKey(key));
  }
}

// ─── Factory ────────────────────────────────────────────────────────────────────

export function createRateLimiter(redis: Redis, config: RateLimiterConfig): RateLimiter {
  switch (config.algorithm) {
    case 'token-bucket':
      return new TokenBucketLimiter(redis, config);
    case 'sliding-window':
      return new SlidingWindowLimiter(redis, config);
    case 'fixed-window':
      return new FixedWindowLimiter(redis, config);
    default:
      throw new Error(`Unknown algorithm: ${(config as RateLimiterConfig).algorithm}`);
  }
}
