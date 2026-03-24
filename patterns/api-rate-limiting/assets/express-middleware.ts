/**
 * express-middleware.ts — Express rate limiting middleware with Redis backend
 *
 * Features:
 *   - Token bucket algorithm via Lua script (atomic, no race conditions)
 *   - Per-user (authenticated) or per-IP (anonymous) rate limiting
 *   - Tiered rate limits (free/pro/enterprise)
 *   - Proper RateLimit-* response headers on every response
 *   - Fail-open with in-memory fallback on Redis errors
 *   - Cost-based limiting for expensive endpoints
 *
 * Usage:
 *   import { createRateLimiter, rateLimitByTier } from './express-middleware';
 *   app.use('/api/', createRateLimiter({ capacity: 100, refillRate: 1.67 }));
 *   app.use('/api/search', createRateLimiter({ capacity: 20, refillRate: 0.33, cost: 5 }));
 *   app.use('/api/', rateLimitByTier());
 */

import { Request, Response, NextFunction } from "express";
import Redis from "ioredis";

// --- Configuration ---

interface RateLimitConfig {
  /** Max tokens (burst capacity) */
  capacity: number;
  /** Tokens added per second */
  refillRate: number;
  /** Tokens consumed per request (default: 1) */
  cost?: number;
  /** Extract rate limit key from request */
  keyFn?: (req: Request) => string;
  /** Allow requests when Redis is unavailable */
  failOpen?: boolean;
  /** Redis connection URL */
  redisUrl?: string;
}

interface TierConfig {
  capacity: number;
  refillRate: number;
}

const TIER_LIMITS: Record<string, TierConfig> = {
  free: { capacity: 100, refillRate: 1.67 },
  starter: { capacity: 500, refillRate: 8.33 },
  pro: { capacity: 2000, refillRate: 33.33 },
  enterprise: { capacity: 10000, refillRate: 166.67 },
};

// --- Token Bucket Lua Script ---

const TOKEN_BUCKET_LUA = `
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local cost = tonumber(ARGV[4]) or 1

local data = redis.call('HMGET', key, 'tokens', 'last_refill')
local tokens = tonumber(data[1]) or capacity
local last_refill = tonumber(data[2]) or now

local elapsed = math.max(0, now - last_refill)
tokens = math.min(capacity, tokens + elapsed * refill_rate)

local ttl = math.ceil(capacity / refill_rate) + 1

if tokens < cost then
    redis.call('HSET', key, 'tokens', tokens, 'last_refill', now)
    redis.call('EXPIRE', key, ttl)
    local retry_after = math.ceil((cost - tokens) / refill_rate)
    return cjson.encode({allowed=false, remaining=0, retry_after=retry_after})
end

tokens = tokens - cost
redis.call('HSET', key, 'tokens', tokens, 'last_refill', now)
redis.call('EXPIRE', key, ttl)
return cjson.encode({allowed=true, remaining=math.floor(tokens), retry_after=0})
`;

// --- Default Key Extraction ---

function defaultKeyFn(req: Request): string {
  const userId = (req as any).user?.id;
  if (userId) return `rl:user:${userId}`;
  const xff = req.headers["x-forwarded-for"];
  const ip = typeof xff === "string" ? xff.split(",")[0].trim() : req.ip;
  return `rl:ip:${ip}`;
}

// --- In-Memory Fallback (per-instance, not global) ---

const localCounters = new Map<string, { count: number; resetAt: number }>();

function localFallbackCheck(key: string, limit: number): boolean {
  const now = Date.now();
  const entry = localCounters.get(key);
  if (!entry || now > entry.resetAt) {
    localCounters.set(key, { count: 1, resetAt: now + 60_000 });
    return true;
  }
  entry.count += 1;
  return entry.count <= limit;
}

// Periodically clean stale local counters
setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of localCounters) {
    if (now > entry.resetAt) localCounters.delete(key);
  }
}, 60_000).unref();

// --- Main Middleware Factory ---

let sharedRedis: Redis | null = null;

function getRedis(url?: string): Redis {
  if (!sharedRedis) {
    sharedRedis = new Redis(url || process.env.REDIS_URL || "redis://localhost:6379", {
      maxRetriesPerRequest: 1,
      connectTimeout: 5000,
      commandTimeout: 100, // 100ms max per command
      enableReadyCheck: true,
      lazyConnect: true,
    });
    sharedRedis.connect().catch(() => {});
  }
  return sharedRedis;
}

export function createRateLimiter(config: RateLimitConfig) {
  const {
    capacity,
    refillRate,
    cost = 1,
    keyFn = defaultKeyFn,
    failOpen = true,
    redisUrl,
  } = config;

  const redis = getRedis(redisUrl);

  return async (req: Request, res: Response, next: NextFunction) => {
    const key = keyFn(req);
    const now = Date.now() / 1000;

    try {
      const raw = (await redis.eval(
        TOKEN_BUCKET_LUA,
        1,
        key,
        capacity,
        refillRate,
        now,
        cost
      )) as string;

      const result = JSON.parse(raw);

      // Set headers on every response
      res.set("RateLimit-Limit", String(capacity));
      res.set("RateLimit-Remaining", String(result.remaining));
      res.set("RateLimit-Reset", String(Math.ceil(capacity / refillRate)));

      // Legacy headers for backward compatibility
      res.set("X-RateLimit-Limit", String(capacity));
      res.set("X-RateLimit-Remaining", String(result.remaining));

      if (!result.allowed) {
        res.set("Retry-After", String(result.retry_after));
        return res.status(429).json({
          error: "rate_limit_exceeded",
          message: `Rate limit exceeded. Retry after ${result.retry_after} seconds.`,
          retry_after: result.retry_after,
        });
      }
    } catch (err) {
      console.error("[rate-limiter] Redis error, using fallback:", err);
      if (!failOpen) {
        return res.status(503).json({
          error: "service_unavailable",
          message: "Rate limiter unavailable.",
        });
      }
      // Fail-open: use local fallback
      if (!localFallbackCheck(key, capacity)) {
        return res.status(429).json({
          error: "rate_limit_exceeded",
          message: "Rate limit exceeded (local fallback).",
          retry_after: 60,
        });
      }
    }

    next();
  };
}

// --- Tiered Rate Limiting ---

export function rateLimitByTier(tiers: Record<string, TierConfig> = TIER_LIMITS) {
  const limiters = new Map<string, ReturnType<typeof createRateLimiter>>();

  for (const [tier, config] of Object.entries(tiers)) {
    limiters.set(tier, createRateLimiter({ ...config, keyFn: defaultKeyFn }));
  }

  return (req: Request, res: Response, next: NextFunction) => {
    const tier = (req as any).user?.tier || "free";
    const limiter = limiters.get(tier) || limiters.get("free")!;
    return limiter(req, res, next);
  };
}
