/**
 * Express Rate Limit Middleware — Configurable strategies, key extraction,
 * and proper rate limit headers (RFC draft RateLimit fields).
 *
 * Usage:
 *   import { rateLimitMiddleware } from './rate-limit-middleware';
 *   app.use('/api', rateLimitMiddleware({ ... }));
 */

import type { Request, Response, NextFunction, RequestHandler } from 'express';
import type { Redis } from 'ioredis';
import { createRateLimiter, type RateLimiterConfig, type RateLimiter, type RateLimitResult } from './rate-limiter';

// ─── Types ──────────────────────────────────────────────────────────────────────

export type KeyExtractor = (req: Request) => string | Promise<string>;
export type SkipFunction = (req: Request) => boolean | Promise<boolean>;
export type CostFunction = (req: Request) => number;

export interface TierConfig {
  match: (req: Request) => boolean;
  limiterConfig: RateLimiterConfig;
}

export interface RateLimitMiddlewareOptions {
  redis: Redis;
  limiterConfig: RateLimiterConfig;

  /** Extract the rate limit key from the request. Default: req.ip */
  keyExtractor?: KeyExtractor;

  /** Skip rate limiting for certain requests. Default: never skip */
  skip?: SkipFunction;

  /** Determine the cost of a request (tokens consumed). Default: 1 */
  cost?: CostFunction;

  /** Custom response when rate limited */
  onLimited?: (req: Request, res: Response, result: RateLimitResult) => void;

  /** Called on every rate limit check (for logging/metrics) */
  onCheck?: (req: Request, result: RateLimitResult) => void;

  /** Include standard rate limit headers. Default: true */
  headers?: boolean;

  /** Include debug headers (non-production). Default: false */
  debugHeaders?: boolean;

  /** Per-tier overrides (matched in order, first match wins) */
  tiers?: TierConfig[];

  /** Behavior when the rate limit store is unavailable. Default: 'allow' */
  failMode?: 'allow' | 'deny';

  /** Message included in the 429 response body */
  message?: string;

  /** URL to rate limit documentation */
  docsUrl?: string;
}

// ─── Default Key Extractors ─────────────────────────────────────────────────────

/**
 * Extract client IP, respecting trusted proxies.
 * Uses Express's req.ip which honors the 'trust proxy' setting.
 */
export const keyByIP: KeyExtractor = (req) => `ip:${req.ip}`;

/**
 * Extract authenticated user ID. Falls back to IP if unauthenticated.
 */
export const keyByUser: KeyExtractor = (req) => {
  const user = (req as Record<string, unknown>).user as { id?: string } | undefined;
  return user?.id ? `user:${user.id}` : `ip:${req.ip}`;
};

/**
 * Extract API key from header. Falls back to IP if no key present.
 */
export const keyByApiKey: KeyExtractor = (req) => {
  const apiKey = req.headers['x-api-key'] as string | undefined;
  return apiKey ? `key:${apiKey}` : `ip:${req.ip}`;
};

/**
 * Composite key: user ID + endpoint for per-user-per-endpoint limiting.
 */
export const keyByUserAndEndpoint: KeyExtractor = (req) => {
  const user = (req as Record<string, unknown>).user as { id?: string } | undefined;
  const identity = user?.id || req.ip;
  return `${identity}:${req.method}:${req.path}`;
};

// ─── Default Cost Functions ─────────────────────────────────────────────────────

/** All requests cost 1 token */
export const uniformCost: CostFunction = () => 1;

/** Write operations cost more than reads */
export const methodBasedCost: CostFunction = (req) => {
  const costs: Record<string, number> = {
    GET: 1,
    HEAD: 1,
    OPTIONS: 0,
    POST: 5,
    PUT: 5,
    PATCH: 3,
    DELETE: 5,
  };
  return costs[req.method] ?? 1;
};

// ─── Middleware Factory ─────────────────────────────────────────────────────────

export function rateLimitMiddleware(options: RateLimitMiddlewareOptions): RequestHandler {
  const {
    redis,
    limiterConfig,
    keyExtractor = keyByIP,
    skip,
    cost = uniformCost,
    onLimited,
    onCheck,
    headers = true,
    debugHeaders = false,
    tiers,
    failMode = 'allow',
    message = 'Too many requests. Please try again later.',
    docsUrl,
  } = options;

  // Create the default limiter
  const defaultLimiter = createRateLimiter(redis, limiterConfig);

  // Create per-tier limiters
  const tierLimiters: Array<{ match: (req: Request) => boolean; limiter: RateLimiter }> =
    tiers?.map((tier) => ({
      match: tier.match,
      limiter: createRateLimiter(redis, tier.limiterConfig),
    })) ?? [];

  function getLimiter(req: Request): RateLimiter {
    for (const tier of tierLimiters) {
      if (tier.match(req)) return tier.limiter;
    }
    return defaultLimiter;
  }

  function setHeaders(res: Response, result: RateLimitResult): void {
    if (!headers) return;

    res.set({
      'RateLimit-Limit': String(result.limit),
      'RateLimit-Remaining': String(result.remaining),
      'RateLimit-Reset': String(result.resetAt),
    });

    if (!result.allowed) {
      res.set('Retry-After', String(result.retryAfter));
    }
  }

  function setDebugHeaders(res: Response, key: string, limiter: RateLimiter): void {
    if (!debugHeaders) return;
    res.set({
      'X-RateLimit-Key': key,
      'X-RateLimit-Algorithm': limiterConfig.algorithm,
    });
  }

  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      // Check skip condition
      if (skip && (await skip(req))) {
        next();
        return;
      }

      const key = await keyExtractor(req);
      const requestCost = cost(req);
      const limiter = getLimiter(req);

      let result: RateLimitResult;
      try {
        result = await limiter.consume(key, requestCost);
      } catch (err) {
        // Rate limit store is unavailable
        if (failMode === 'allow') {
          next();
          return;
        }
        res.status(503).json({
          error: 'service_unavailable',
          message: 'Rate limiting service is temporarily unavailable.',
        });
        return;
      }

      // Invoke check callback
      onCheck?.(req, result);

      // Set response headers
      setHeaders(res, result);
      setDebugHeaders(res, key, limiter);

      if (result.allowed) {
        next();
        return;
      }

      // Rate limited
      if (onLimited) {
        onLimited(req, res, result);
        return;
      }

      const body: Record<string, unknown> = {
        error: 'rate_limit_exceeded',
        message,
        retry_after: result.retryAfter,
      };
      if (docsUrl) {
        body.docs = docsUrl;
      }

      res.status(429).json(body);
    } catch (err) {
      next(err);
    }
  };
}

// ─── Layered Rate Limiting ──────────────────────────────────────────────────────

export interface LayeredRateLimitOptions {
  redis: Redis;
  layers: Array<{
    name: string;
    config: RateLimiterConfig;
    keyExtractor: KeyExtractor;
  }>;
  failMode?: 'allow' | 'deny';
  headers?: boolean;
}

/**
 * Apply multiple rate limiters in sequence. All layers must allow the request.
 * The most restrictive result is used for response headers.
 */
export function layeredRateLimitMiddleware(options: LayeredRateLimitOptions): RequestHandler {
  const { redis, layers, failMode = 'allow', headers: showHeaders = true } = options;

  const limiters = layers.map((layer) => ({
    name: layer.name,
    limiter: createRateLimiter(redis, layer.config),
    keyExtractor: layer.keyExtractor,
  }));

  return async (req: Request, res: Response, next: NextFunction): Promise<void> => {
    try {
      let mostRestrictive: RateLimitResult | null = null;

      for (const { limiter, keyExtractor } of limiters) {
        const key = await keyExtractor(req);
        let result: RateLimitResult;
        try {
          result = await limiter.consume(key);
        } catch {
          if (failMode === 'deny') {
            res.status(503).json({ error: 'service_unavailable' });
            return;
          }
          continue;
        }

        if (!result.allowed) {
          if (showHeaders) {
            res.set({
              'RateLimit-Limit': String(result.limit),
              'RateLimit-Remaining': '0',
              'RateLimit-Reset': String(result.resetAt),
              'Retry-After': String(result.retryAfter),
            });
          }
          res.status(429).json({
            error: 'rate_limit_exceeded',
            message: 'Too many requests.',
            retry_after: result.retryAfter,
          });
          return;
        }

        if (!mostRestrictive || result.remaining < mostRestrictive.remaining) {
          mostRestrictive = result;
        }
      }

      if (mostRestrictive && showHeaders) {
        res.set({
          'RateLimit-Limit': String(mostRestrictive.limit),
          'RateLimit-Remaining': String(mostRestrictive.remaining),
          'RateLimit-Reset': String(mostRestrictive.resetAt),
        });
      }

      next();
    } catch (err) {
      next(err);
    }
  };
}
