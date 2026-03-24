/**
 * HTTP caching middleware for Express/Koa with ETag, Cache-Control,
 * conditional requests (If-None-Match / If-Modified-Since), and
 * optional Redis-backed response caching.
 */

import { createHash } from "crypto";
import type { Request, Response, NextFunction, RequestHandler } from "express";

// ─── Types ───────────────────────────────────────────────────────────────────

export interface CacheControlOptions {
  /** Cache visibility: 'public' for CDN/proxy, 'private' for browser-only */
  visibility?: "public" | "private";
  /** Max age in seconds for the client (browser) */
  maxAge?: number;
  /** Max age in seconds for shared caches (CDN/proxy) — overrides maxAge there */
  sMaxAge?: number;
  /** Allow serving stale content while revalidating in background (seconds) */
  staleWhileRevalidate?: number;
  /** Allow serving stale content on upstream errors (seconds) */
  staleIfError?: number;
  /** Content will never change — skip revalidation */
  immutable?: boolean;
  /** Must revalidate with origin before using cached copy */
  mustRevalidate?: boolean;
  /** Do not cache at all (sensitive data) */
  noStore?: boolean;
  /** Always revalidate before using cached copy */
  noCache?: boolean;
}

export interface ETagOptions {
  /** Generate weak ETags (W/"...") — suitable for semantically equivalent responses */
  weak?: boolean;
  /** Custom ETag generator. Receives response body, returns ETag string. */
  generator?: (body: string | Buffer) => string;
}

export interface ResponseCacheOptions {
  /** TTL in seconds for cached responses */
  ttl: number;
  /** Key generator — receives the request, returns cache key */
  keyGenerator?: (req: Request) => string;
  /** Skip caching for specific requests */
  shouldCache?: (req: Request, res: Response) => boolean;
  /** Redis client for response storage */
  store: ResponseCacheStore;
  /** Status codes to cache (default: [200]) */
  cacheableStatuses?: number[];
}

export interface ResponseCacheStore {
  get(key: string): Promise<CachedResponse | null>;
  set(key: string, value: CachedResponse, ttl: number): Promise<void>;
  delete(key: string): Promise<void>;
}

export interface CachedResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
  cachedAt: number;
}

export interface VaryOptions {
  /** Request headers that affect the response — added to Vary header */
  headers: string[];
}

// ─── Cache-Control Middleware ────────────────────────────────────────────────

/**
 * Sets Cache-Control headers on the response.
 *
 * @example
 * // Immutable static assets
 * app.use('/static', cacheControl({ visibility: 'public', maxAge: 31536000, immutable: true }));
 *
 * // API with CDN caching + stale serving
 * app.use('/api', cacheControl({
 *   visibility: 'public', maxAge: 60, sMaxAge: 300,
 *   staleWhileRevalidate: 30, staleIfError: 86400
 * }));
 *
 * // Sensitive data — no caching
 * app.use('/account', cacheControl({ noStore: true }));
 */
export function cacheControl(options: CacheControlOptions): RequestHandler {
  const directives = buildCacheControlDirectives(options);
  const headerValue = directives.join(", ");

  return (_req: Request, res: Response, next: NextFunction): void => {
    res.setHeader("Cache-Control", headerValue);
    next();
  };
}

function buildCacheControlDirectives(options: CacheControlOptions): string[] {
  const directives: string[] = [];

  if (options.noStore) {
    directives.push("no-store");
    return directives;
  }

  if (options.noCache) {
    directives.push("no-cache");
  }

  if (options.visibility) {
    directives.push(options.visibility);
  }

  if (options.maxAge !== undefined) {
    directives.push(`max-age=${options.maxAge}`);
  }

  if (options.sMaxAge !== undefined) {
    directives.push(`s-maxage=${options.sMaxAge}`);
  }

  if (options.staleWhileRevalidate !== undefined) {
    directives.push(`stale-while-revalidate=${options.staleWhileRevalidate}`);
  }

  if (options.staleIfError !== undefined) {
    directives.push(`stale-if-error=${options.staleIfError}`);
  }

  if (options.immutable) {
    directives.push("immutable");
  }

  if (options.mustRevalidate) {
    directives.push("must-revalidate");
  }

  return directives;
}

// ─── ETag Middleware ────────────────────────────────────────────────────────

/**
 * Adds ETag generation and conditional request handling (If-None-Match).
 * Responds with 304 Not Modified when the client's ETag matches.
 *
 * @example
 * app.use(etag());
 * app.use(etag({ weak: true }));
 * app.use(etag({ generator: (body) => myCustomHash(body) }));
 */
export function etag(options: ETagOptions = {}): RequestHandler {
  const { weak = false, generator } = options;

  return (req: Request, res: Response, next: NextFunction): void => {
    const originalJson = res.json.bind(res);
    const originalSend = res.send.bind(res);

    const addEtag = (body: string | Buffer): void => {
      if (req.method !== "GET" && req.method !== "HEAD") return;

      const bodyStr =
        typeof body === "string" ? body : body.toString("utf-8");
      const etagValue = generator
        ? generator(body)
        : generateETag(bodyStr, weak);

      res.setHeader("ETag", etagValue);

      const ifNoneMatch = req.headers["if-none-match"];
      if (ifNoneMatch && ifNoneMatch === etagValue) {
        res.status(304).end();
        return;
      }
    };

    res.json = function (body: unknown): Response {
      const serialized = JSON.stringify(body);
      addEtag(serialized);
      if (res.writableEnded) return res;
      return originalJson(body);
    };

    res.send = function (body: unknown): Response {
      if (typeof body === "string" || Buffer.isBuffer(body)) {
        addEtag(body);
      }
      if (res.writableEnded) return res;
      return originalSend(body);
    };

    next();
  };
}

function generateETag(content: string, weak: boolean): string {
  const hash = createHash("md5").update(content).digest("hex");
  return weak ? `W/"${hash}"` : `"${hash}"`;
}

// ─── Conditional Request Middleware ─────────────────────────────────────────

/**
 * Handles If-Modified-Since conditional requests.
 * Use alongside a Last-Modified header set by your route handler.
 *
 * @example
 * app.use(conditionalGet());
 * app.get('/data', (req, res) => {
 *   const lastModified = getLastModifiedDate();
 *   res.setHeader('Last-Modified', lastModified.toUTCString());
 *   res.json(data);
 * });
 */
export function conditionalGet(): RequestHandler {
  return (req: Request, res: Response, next: NextFunction): void => {
    const originalJson = res.json.bind(res);

    res.json = function (body: unknown): Response {
      if (req.method !== "GET" && req.method !== "HEAD") {
        return originalJson(body);
      }

      const ifModifiedSince = req.headers["if-modified-since"];
      const lastModified = res.getHeader("Last-Modified") as
        | string
        | undefined;

      if (ifModifiedSince && lastModified) {
        const ifModifiedDate = new Date(ifModifiedSince).getTime();
        const lastModifiedDate = new Date(lastModified).getTime();

        if (lastModifiedDate <= ifModifiedDate) {
          res.status(304).end();
          return res;
        }
      }

      return originalJson(body);
    };

    next();
  };
}

// ─── Vary Header Middleware ─────────────────────────────────────────────────

/**
 * Sets the Vary header to inform caches which request headers affect the response.
 *
 * @example
 * app.use(vary({ headers: ['Accept-Encoding', 'Accept-Language'] }));
 */
export function vary(options: VaryOptions): RequestHandler {
  const varyValue = options.headers.join(", ");

  return (_req: Request, res: Response, next: NextFunction): void => {
    const existing = res.getHeader("Vary") as string | undefined;
    if (existing) {
      const existingHeaders = existing.split(",").map((h) => h.trim().toLowerCase());
      const newHeaders = options.headers.filter(
        (h) => !existingHeaders.includes(h.toLowerCase()),
      );
      if (newHeaders.length > 0) {
        res.setHeader("Vary", `${existing}, ${newHeaders.join(", ")}`);
      }
    } else {
      res.setHeader("Vary", varyValue);
    }
    next();
  };
}

// ─── Full Response Cache Middleware ──────────────────────────────────────────

/**
 * Caches entire HTTP responses in a backing store (e.g., Redis).
 * Serves cached responses on cache hit; falls through on miss and caches the response.
 *
 * @example
 * const store = new RedisResponseCacheStore(redisClient);
 * app.use('/api/products', responseCache({
 *   ttl: 300,
 *   store,
 *   keyGenerator: (req) => `resp:${req.originalUrl}`,
 *   shouldCache: (req, res) => res.statusCode === 200,
 * }));
 */
export function responseCache(options: ResponseCacheOptions): RequestHandler {
  const {
    ttl,
    store,
    keyGenerator = defaultKeyGenerator,
    shouldCache = defaultShouldCache,
    cacheableStatuses = [200],
  } = options;

  return async (
    req: Request,
    res: Response,
    next: NextFunction,
  ): Promise<void> => {
    if (req.method !== "GET" && req.method !== "HEAD") {
      next();
      return;
    }

    const cacheKey = keyGenerator(req);

    // Try cache hit
    try {
      const cached = await store.get(cacheKey);
      if (cached) {
        res.setHeader("X-Cache", "HIT");
        res.setHeader("X-Cache-Age", String(Math.floor((Date.now() - cached.cachedAt) / 1000)));
        for (const [header, value] of Object.entries(cached.headers)) {
          res.setHeader(header, value);
        }
        res.status(cached.status).send(cached.body);
        return;
      }
    } catch {
      // Cache read failure — proceed without cache
    }

    // Cache miss — intercept the response
    res.setHeader("X-Cache", "MISS");
    const originalJson = res.json.bind(res);
    const originalSend = res.send.bind(res);

    const cacheAndSend = async (body: string): Promise<void> => {
      if (
        cacheableStatuses.includes(res.statusCode) &&
        shouldCache(req, res)
      ) {
        const headersToCache: Record<string, string> = {};
        const cacheHeaders = [
          "content-type",
          "etag",
          "last-modified",
          "cache-control",
          "vary",
        ];
        for (const h of cacheHeaders) {
          const val = res.getHeader(h);
          if (val) headersToCache[h] = String(val);
        }

        try {
          await store.set(
            cacheKey,
            {
              status: res.statusCode,
              headers: headersToCache,
              body,
              cachedAt: Date.now(),
            },
            ttl,
          );
        } catch {
          // Cache write failure — non-fatal
        }
      }
    };

    res.json = function (body: unknown): Response {
      const serialized = JSON.stringify(body);
      cacheAndSend(serialized).catch(() => {});
      return originalJson(body);
    };

    res.send = function (body: unknown): Response {
      if (typeof body === "string") {
        cacheAndSend(body).catch(() => {});
      }
      return originalSend(body);
    };

    next();
  };
}

function defaultKeyGenerator(req: Request): string {
  return `response:${req.method}:${req.originalUrl}`;
}

function defaultShouldCache(_req: Request, res: Response): boolean {
  return res.statusCode === 200;
}

// ─── Preset Configurations ──────────────────────────────────────────────────

/** Immutable static assets with long cache (1 year) */
export const STATIC_ASSETS: CacheControlOptions = {
  visibility: "public",
  maxAge: 31536000,
  immutable: true,
};

/** API responses with short browser cache and CDN caching */
export const API_RESPONSE: CacheControlOptions = {
  visibility: "public",
  maxAge: 0,
  sMaxAge: 300,
  staleWhileRevalidate: 60,
  staleIfError: 86400,
  mustRevalidate: true,
};

/** Private user-specific data — browser only, must revalidate */
export const PRIVATE_DATA: CacheControlOptions = {
  visibility: "private",
  maxAge: 0,
  mustRevalidate: true,
};

/** No caching — sensitive data */
export const NO_CACHE: CacheControlOptions = {
  noStore: true,
};

/** Short-lived CDN cache with stale serving for dynamic pages */
export const DYNAMIC_PAGE: CacheControlOptions = {
  visibility: "public",
  maxAge: 60,
  sMaxAge: 300,
  staleWhileRevalidate: 30,
  staleIfError: 3600,
};
