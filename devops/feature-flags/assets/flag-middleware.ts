/**
 * @fileoverview Express/Fastify middleware for feature flag evaluation.
 *
 * Provides request-scoped flag evaluation with caching, metrics, and
 * graceful degradation when the flag service is unavailable.
 *
 * @example Express
 * ```ts
 * import express from "express";
 * import { featureFlagMiddleware, InMemoryFlagEvaluator } from "./flag-middleware";
 *
 * const app = express();
 * const evaluator = new InMemoryFlagEvaluator(defaultFlags);
 * app.use(featureFlagMiddleware({ evaluator, flags: ["dark-mode", "beta-ui"] }));
 *
 * app.get("/dashboard", (req, res) => {
 *   if (req.featureFlags["beta-ui"]) {
 *     return res.render("dashboard-beta");
 *   }
 *   res.render("dashboard");
 * });
 * ```
 *
 * @example Fastify
 * ```ts
 * import Fastify from "fastify";
 * import { featureFlagPlugin, InMemoryFlagEvaluator } from "./flag-middleware";
 *
 * const app = Fastify();
 * const evaluator = new InMemoryFlagEvaluator(defaultFlags);
 * app.register(featureFlagPlugin, { evaluator, flags: ["dark-mode"] });
 *
 * app.get("/dashboard", async (request, reply) => {
 *   if (request.featureFlags["dark-mode"]) {
 *     return { theme: "dark" };
 *   }
 *   return { theme: "light" };
 * });
 * ```
 */

import type { Request, Response, NextFunction, RequestHandler } from "express";
import type {
  FastifyPluginCallback,
  FastifyRequest,
  FastifyReply,
  FastifyInstance,
} from "fastify";
import fp from "fastify-plugin";

// ---------------------------------------------------------------------------
// Type Augmentation
// ---------------------------------------------------------------------------

/** Resolved flag values attached to every request. */
export type FlagValues = Record<string, boolean | string | number | null>;

declare module "express-serve-static-core" {
  interface Request {
    featureFlags: FlagValues;
  }
}

declare module "fastify" {
  interface FastifyRequest {
    featureFlags: FlagValues;
  }
}

// ---------------------------------------------------------------------------
// Core Interfaces
// ---------------------------------------------------------------------------

/** Contextual information extracted from an inbound request. */
export interface EvaluationContext {
  /** Authenticated user identifier. */
  userId?: string;
  /** ISO-3166 region code derived from headers or geo-IP. */
  region?: string;
  /** Arbitrary attributes forwarded to the flag evaluator. */
  attributes: Record<string, string | number | boolean>;
}

/** A single flag definition understood by the built-in evaluator. */
export interface FlagDefinition {
  /** Unique flag key (e.g. "dark-mode"). */
  key: string;
  /** Whether the flag is currently active. */
  enabled: boolean;
  /** Value returned when the flag is enabled. Defaults to `true`. */
  value?: boolean | string | number;
  /**
   * Optional targeting rules evaluated in order.
   * The first matching rule wins; if none match the top-level value is used.
   */
  rules?: TargetingRule[];
}

/** A single targeting rule attached to a flag definition. */
export interface TargetingRule {
  /** Human-readable label. */
  name?: string;
  /** Context attribute to match against. */
  attribute: string;
  /** Operator used for comparison. */
  operator: "eq" | "neq" | "in" | "nin" | "gt" | "lt" | "gte" | "lte";
  /** Value(s) to compare with. Use an array for `in` / `nin`. */
  value: string | number | boolean | (string | number | boolean)[];
  /** Value to return when the rule matches. */
  returnValue: boolean | string | number;
}

/** Minimal contract every flag evaluator must implement. */
export interface FlagEvaluator {
  /**
   * Evaluate a single flag for the given context.
   *
   * @returns The resolved value, or `null` if the flag is unknown.
   */
  evaluate(
    flagKey: string,
    context: EvaluationContext,
  ): Promise<boolean | string | number | null>;
}

/**
 * Custom function that pulls additional context out of a request.
 * Returned attributes are merged into the base {@link EvaluationContext}.
 */
export type ContextExtractor = (
  req: ContextSourceRequest,
) => Record<string, string | number | boolean>;

/** Minimal request shape accepted by context extractors. */
export interface ContextSourceRequest {
  headers: Record<string, string | string[] | undefined>;
  query: Record<string, string | string[] | undefined>;
  /** Set by upstream auth middleware (e.g. passport, express-jwt). */
  user?: { id?: string; sub?: string; [k: string]: unknown };
}

// ---------------------------------------------------------------------------
// Middleware / Plugin Options
// ---------------------------------------------------------------------------

/** Options shared by both the Express middleware and the Fastify plugin. */
export interface FeatureFlagOptions {
  /** Flag evaluator instance. */
  evaluator: FlagEvaluator;

  /** Flags to pre-evaluate for every request. */
  flags: string[];

  /**
   * Optional evaluation cache.
   * When provided, flag values are cached and reused across requests.
   */
  cache?: FlagCache;

  /**
   * Extra context extractors appended after the built-in ones.
   * They run in order; later extractors overwrite earlier attributes.
   */
  extractors?: ContextExtractor[];

  /**
   * Optional metrics collector.
   * When provided, evaluation count, latency and cache stats are recorded.
   */
  metrics?: MetricsCollector;

  /**
   * Default flag values returned when evaluation fails.
   * Keys not listed here resolve to `null` on error.
   */
  defaults?: FlagValues;

  /**
   * Called when a flag evaluation throws.
   * Defaults to `console.error`.
   */
  onError?: (flagKey: string, error: unknown) => void;
}

/** Per-route overrides (Express only). */
export interface RouteFlagOptions {
  /** Flags to evaluate for this specific route, *replacing* the global list. */
  flags: string[];
}

// ---------------------------------------------------------------------------
// Caching Layer
// ---------------------------------------------------------------------------

/** Cache key is `"global:<flag>"` or `"user:<userId>:<flag>"`. */
export interface FlagCache {
  get(key: string): Promise<CacheEntry | undefined>;
  set(key: string, entry: CacheEntry): Promise<void>;
  invalidate(pattern: string): Promise<void>;
  stats(): CacheStats;
}

export interface CacheEntry {
  value: boolean | string | number | null;
  expiresAt: number;
}

export interface CacheStats {
  hits: number;
  misses: number;
  size: number;
  evictions: number;
}

/**
 * LRU in-memory flag cache with configurable TTL and max size.
 *
 * Entries are evicted in least-recently-used order once `maxSize` is reached.
 * Cache invalidation supports glob-style prefix matching (e.g. `"user:42:*"`).
 */
export class LRUFlagCache implements FlagCache {
  private readonly map = new Map<string, CacheEntry>();
  private readonly maxSize: number;
  private readonly ttlMs: number;
  private _hits = 0;
  private _misses = 0;
  private _evictions = 0;

  constructor(options: { maxSize?: number; ttlMs?: number } = {}) {
    this.maxSize = options.maxSize ?? 10_000;
    this.ttlMs = options.ttlMs ?? 60_000;
  }

  async get(key: string): Promise<CacheEntry | undefined> {
    const entry = this.map.get(key);
    if (!entry) {
      this._misses++;
      return undefined;
    }
    if (Date.now() > entry.expiresAt) {
      this.map.delete(key);
      this._misses++;
      return undefined;
    }
    // Move to end (most-recently-used)
    this.map.delete(key);
    this.map.set(key, entry);
    this._hits++;
    return entry;
  }

  async set(key: string, entry: CacheEntry): Promise<void> {
    if (this.map.has(key)) {
      this.map.delete(key);
    } else if (this.map.size >= this.maxSize) {
      // Evict least-recently-used (first key)
      const oldest = this.map.keys().next().value as string;
      this.map.delete(oldest);
      this._evictions++;
    }
    this.map.set(key, entry);
  }

  /**
   * Invalidate entries matching a prefix pattern.
   *
   * Supports trailing wildcard: `"user:42:*"` removes all keys starting with
   * `"user:42:"`. An exact key (no wildcard) removes only that entry.
   */
  async invalidate(pattern: string): Promise<void> {
    if (pattern.endsWith("*")) {
      const prefix = pattern.slice(0, -1);
      for (const key of [...this.map.keys()]) {
        if (key.startsWith(prefix)) {
          this.map.delete(key);
        }
      }
    } else {
      this.map.delete(pattern);
    }
  }

  stats(): CacheStats {
    return {
      hits: this._hits,
      misses: this._misses,
      size: this.map.size,
      evictions: this._evictions,
    };
  }
}

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

export interface MetricsCollector {
  /** Increment a counter. */
  inc(name: string, labels?: Record<string, string>): void;
  /** Record a timing observation in milliseconds. */
  observe(name: string, value: number, labels?: Record<string, string>): void;
}

/**
 * Prometheus-compatible in-process metrics store.
 *
 * Counters and histograms are stored in memory and rendered in the
 * Prometheus text exposition format via {@link PrometheusMetrics.serialize}.
 */
export class PrometheusMetrics implements MetricsCollector {
  private counters = new Map<string, number>();
  private histograms = new Map<string, number[]>();

  /** Build a deterministic metric key from name + sorted labels. */
  private labelKey(
    name: string,
    labels?: Record<string, string>,
  ): string {
    if (!labels || Object.keys(labels).length === 0) return name;
    const sorted = Object.entries(labels)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([k, v]) => `${k}="${v}"`)
      .join(",");
    return `${name}{${sorted}}`;
  }

  inc(name: string, labels?: Record<string, string>): void {
    const key = this.labelKey(name, labels);
    this.counters.set(key, (this.counters.get(key) ?? 0) + 1);
  }

  observe(
    name: string,
    value: number,
    labels?: Record<string, string>,
  ): void {
    const key = this.labelKey(name, labels);
    const bucket = this.histograms.get(key) ?? [];
    bucket.push(value);
    this.histograms.set(key, bucket);
  }

  /**
   * Render all collected metrics as Prometheus text exposition format.
   *
   * @example
   * ```
   * feature_flag_evaluations_total{flag="dark-mode"} 42
   * feature_flag_evaluation_duration_ms_sum{flag="dark-mode"} 127.5
   * feature_flag_evaluation_duration_ms_count{flag="dark-mode"} 42
   * feature_flag_cache_hits_total 318
   * ```
   */
  serialize(): string {
    const lines: string[] = [];

    for (const [key, count] of this.counters) {
      lines.push(`${key} ${count}`);
    }

    for (const [key, values] of this.histograms) {
      const sum = values.reduce((a, b) => a + b, 0);
      lines.push(`${key}_sum ${sum}`);
      lines.push(`${key}_count ${values.length}`);
    }

    return lines.join("\n") + "\n";
  }

  /** Express-compatible handler that serves `/metrics`. */
  metricsHandler(): RequestHandler {
    return (_req: Request, res: Response) => {
      res.setHeader("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
      res.end(this.serialize());
    };
  }
}

// ---------------------------------------------------------------------------
// Built-in Flag Evaluator
// ---------------------------------------------------------------------------

/**
 * Simple in-memory flag evaluator driven by static {@link FlagDefinition}s.
 *
 * Suitable for development, testing, or small-scale deployments.
 * For production, replace with a remote evaluator backed by LaunchDarkly,
 * Unleash, Flagsmith, or a similar service.
 */
export class InMemoryFlagEvaluator implements FlagEvaluator {
  private flags: Map<string, FlagDefinition>;

  constructor(definitions: FlagDefinition[]) {
    this.flags = new Map(definitions.map((d) => [d.key, d]));
  }

  /** Replace the full flag set (e.g. after a config reload). */
  setDefinitions(definitions: FlagDefinition[]): void {
    this.flags = new Map(definitions.map((d) => [d.key, d]));
  }

  async evaluate(
    flagKey: string,
    context: EvaluationContext,
  ): Promise<boolean | string | number | null> {
    const def = this.flags.get(flagKey);
    if (!def) return null;
    if (!def.enabled) return false;

    if (def.rules) {
      for (const rule of def.rules) {
        if (this.matchesRule(rule, context)) {
          return rule.returnValue;
        }
      }
    }

    return def.value ?? true;
  }

  private matchesRule(rule: TargetingRule, ctx: EvaluationContext): boolean {
    const actual =
      rule.attribute === "userId"
        ? ctx.userId
        : rule.attribute === "region"
          ? ctx.region
          : ctx.attributes[rule.attribute];

    if (actual === undefined) return false;

    switch (rule.operator) {
      case "eq":
        return actual === rule.value;
      case "neq":
        return actual !== rule.value;
      case "in":
        return Array.isArray(rule.value) && rule.value.includes(actual as never);
      case "nin":
        return Array.isArray(rule.value) && !rule.value.includes(actual as never);
      case "gt":
        return typeof actual === "number" && actual > (rule.value as number);
      case "lt":
        return typeof actual === "number" && actual < (rule.value as number);
      case "gte":
        return typeof actual === "number" && actual >= (rule.value as number);
      case "lte":
        return typeof actual === "number" && actual <= (rule.value as number);
      default:
        return false;
    }
  }
}

// ---------------------------------------------------------------------------
// Request Context Builder
// ---------------------------------------------------------------------------

/**
 * Build an {@link EvaluationContext} from an inbound request.
 *
 * Built-in extraction order:
 * 1. JWT `sub` / `id` claim from `req.user` (set by auth middleware).
 * 2. `X-User-ID` header.
 * 3. `X-Region` header.
 * 4. Query parameters prefixed with `ff_` (e.g. `?ff_beta=true`).
 * 5. Custom extractors supplied via {@link FeatureFlagOptions.extractors}.
 */
export function buildContext(
  req: ContextSourceRequest,
  extractors: ContextExtractor[] = [],
): EvaluationContext {
  const attributes: Record<string, string | number | boolean> = {};

  // 1. JWT / auth user
  const userId =
    req.user?.id?.toString() ??
    req.user?.sub?.toString() ??
    headerString(req.headers["x-user-id"]);

  // 2. Region header
  const region = headerString(req.headers["x-region"]);

  // 3. ff_ query params
  if (req.query) {
    for (const [key, raw] of Object.entries(req.query)) {
      if (key.startsWith("ff_") && raw !== undefined) {
        const attrName = key.slice(3);
        const val = Array.isArray(raw) ? raw[0] : raw;
        if (val !== undefined) {
          attributes[attrName] = coerce(val);
        }
      }
    }
  }

  // 4. Custom extractors
  for (const extractor of extractors) {
    Object.assign(attributes, extractor(req));
  }

  return { userId, region, attributes };
}

function headerString(h: string | string[] | undefined): string | undefined {
  if (Array.isArray(h)) return h[0];
  return h;
}

function coerce(val: string): string | number | boolean {
  if (val === "true") return true;
  if (val === "false") return false;
  const num = Number(val);
  if (!Number.isNaN(num) && val.length > 0) return num;
  return val;
}

// ---------------------------------------------------------------------------
// Core Evaluation Engine (shared by Express & Fastify)
// ---------------------------------------------------------------------------

/**
 * Evaluate a list of flags for a given context, using the cache and recording
 * metrics when available. Results are written into a mutable `FlagValues` map.
 */
async function evaluateFlags(
  flagKeys: string[],
  context: EvaluationContext,
  options: FeatureFlagOptions,
  out: FlagValues,
): Promise<void> {
  const { evaluator, cache, metrics, defaults, onError } = options;
  const errorHandler = onError ?? defaultErrorHandler;

  await Promise.all(
    flagKeys.map(async (key) => {
      // Skip if already evaluated for this request (deduplication).
      if (key in out) return;

      const cacheKey = context.userId
        ? `user:${context.userId}:${key}`
        : `global:${key}`;

      const start = performance.now();
      let source: "cache" | "eval" = "eval";

      try {
        // Check cache first
        if (cache) {
          const cached = await cache.get(cacheKey);
          if (cached) {
            out[key] = cached.value;
            source = "cache";
            metrics?.inc("feature_flag_cache_hits_total", { flag: key });
            return;
          }
          metrics?.inc("feature_flag_cache_misses_total", { flag: key });
        }

        const value = await evaluator.evaluate(key, context);
        out[key] = value;

        if (cache) {
          const ttlMs = (cache as LRUFlagCache)?.["ttlMs"] ?? 60_000;
          await cache.set(cacheKey, {
            value,
            expiresAt: Date.now() + ttlMs,
          });
        }
      } catch (err) {
        errorHandler(key, err);
        out[key] = defaults?.[key] ?? null;
      } finally {
        const elapsed = performance.now() - start;
        metrics?.inc("feature_flag_evaluations_total", {
          flag: key,
          source,
        });
        metrics?.observe("feature_flag_evaluation_duration_ms", elapsed, {
          flag: key,
        });
        // Track value distribution
        metrics?.inc("feature_flag_values_total", {
          flag: key,
          value: String(out[key]),
        });
      }
    }),
  );
}

function defaultErrorHandler(flagKey: string, error: unknown): void {
  console.error(`[feature-flags] evaluation failed for "${flagKey}":`, error);
}

// ---------------------------------------------------------------------------
// Express Middleware
// ---------------------------------------------------------------------------

/**
 * Express middleware that pre-evaluates feature flags and attaches them to
 * `req.featureFlags`.
 *
 * @example Global middleware
 * ```ts
 * app.use(featureFlagMiddleware({
 *   evaluator,
 *   flags: ["dark-mode", "new-checkout"],
 * }));
 * ```
 *
 * @example Per-route overrides
 * ```ts
 * const checkoutFlags = featureFlagMiddleware({
 *   evaluator,
 *   flags: ["new-checkout", "express-shipping"],
 * });
 * app.post("/checkout", checkoutFlags, checkoutHandler);
 * ```
 */
export function featureFlagMiddleware(
  options: FeatureFlagOptions,
): RequestHandler {
  return async (req: Request, res: Response, next: NextFunction) => {
    req.featureFlags = req.featureFlags ?? {};
    const context = buildContext(req as unknown as ContextSourceRequest, options.extractors);

    try {
      await evaluateFlags(options.flags, context, options, req.featureFlags);
    } catch (err) {
      (options.onError ?? defaultErrorHandler)("*", err);
    }

    next();
  };
}

/**
 * Create a per-route Express middleware that evaluates a different set of
 * flags, reusing the same evaluator and cache.
 *
 * @example
 * ```ts
 * const base = { evaluator, cache, flags: [] };
 * app.get("/beta", routeFlags(base, { flags: ["beta-ui"] }), betaHandler);
 * ```
 */
export function routeFlags(
  base: FeatureFlagOptions,
  route: RouteFlagOptions,
): RequestHandler {
  return featureFlagMiddleware({ ...base, flags: route.flags });
}

// ---------------------------------------------------------------------------
// Fastify Plugin
// ---------------------------------------------------------------------------

/**
 * Fastify plugin that pre-evaluates feature flags in an `onRequest` hook and
 * decorates `request.featureFlags`.
 *
 * @example
 * ```ts
 * import Fastify from "fastify";
 * import { featureFlagPlugin, InMemoryFlagEvaluator } from "./flag-middleware";
 *
 * const app = Fastify();
 * const evaluator = new InMemoryFlagEvaluator([
 *   { key: "dark-mode", enabled: true },
 * ]);
 *
 * app.register(featureFlagPlugin, { evaluator, flags: ["dark-mode"] });
 *
 * app.get("/", async (request) => {
 *   return { darkMode: request.featureFlags["dark-mode"] };
 * });
 * ```
 *
 * Route-level configuration:
 * ```ts
 * app.get("/beta", {
 *   config: { featureFlags: ["beta-dashboard"] },
 *   handler: async (request) => ({ beta: request.featureFlags["beta-dashboard"] }),
 * });
 * ```
 */
const featureFlagPluginCallback: FastifyPluginCallback<FeatureFlagOptions> = (
  fastify: FastifyInstance,
  options: FeatureFlagOptions,
  done: (err?: Error) => void,
) => {
  // Decorate request with an empty flags object so Fastify's reference
  // type system knows the property exists.
  fastify.decorateRequest("featureFlags", null as unknown as FlagValues);

  fastify.addHook(
    "onRequest",
    async (request: FastifyRequest, _reply: FastifyReply) => {
      request.featureFlags = {};

      const context = buildContext(
        request as unknown as ContextSourceRequest,
        options.extractors,
      );

      // Prefer route-level flag list, fall back to plugin-level list.
      const routeConfig = (request.routeOptions?.config as unknown as Record<string, unknown>) ?? {};
      const flagKeys =
        (routeConfig.featureFlags as string[] | undefined) ?? options.flags;

      try {
        await evaluateFlags(flagKeys, context, options, request.featureFlags);
      } catch (err) {
        (options.onError ?? defaultErrorHandler)("*", err);
      }
    },
  );

  done();
};

/**
 * Wrapped Fastify plugin with `fastify-plugin` so decorations are visible
 * in the enclosing scope (not encapsulated).
 */
export const featureFlagPlugin = fp(featureFlagPluginCallback, {
  fastify: ">=4.0.0",
  name: "feature-flag-plugin",
});

// ---------------------------------------------------------------------------
// Usage Examples
// ---------------------------------------------------------------------------

/*
 * ========================================================================
 *  USAGE EXAMPLE — Express
 * ========================================================================
 *
 * ```ts
 * import express from "express";
 * import {
 *   featureFlagMiddleware,
 *   routeFlags,
 *   InMemoryFlagEvaluator,
 *   LRUFlagCache,
 *   PrometheusMetrics,
 * } from "./flag-middleware";
 *
 * // 1. Define flags
 * const evaluator = new InMemoryFlagEvaluator([
 *   { key: "dark-mode", enabled: true, value: true },
 *   {
 *     key: "beta-ui",
 *     enabled: true,
 *     value: false,
 *     rules: [
 *       {
 *         name: "beta-testers",
 *         attribute: "userId",
 *         operator: "in",
 *         value: ["user-1", "user-2"],
 *         returnValue: true,
 *       },
 *     ],
 *   },
 *   {
 *     key: "premium-feature",
 *     enabled: true,
 *     value: false,
 *     rules: [
 *       {
 *         name: "premium-users",
 *         attribute: "plan",
 *         operator: "eq",
 *         value: "premium",
 *         returnValue: true,
 *       },
 *     ],
 *   },
 * ]);
 *
 * // 2. Set up cache + metrics
 * const cache = new LRUFlagCache({ maxSize: 5_000, ttlMs: 30_000 });
 * const metrics = new PrometheusMetrics();
 *
 * // 3. Custom context extractor (e.g. pull "plan" from JWT)
 * const planExtractor = (req) => {
 *   return { plan: req.user?.plan ?? "free" };
 * };
 *
 * const app = express();
 *
 * // 4. Global middleware — pre-evaluates dark-mode for every request
 * app.use(
 *   featureFlagMiddleware({
 *     evaluator,
 *     cache,
 *     metrics,
 *     flags: ["dark-mode"],
 *     extractors: [planExtractor],
 *     defaults: { "dark-mode": false, "beta-ui": false },
 *   }),
 * );
 *
 * // 5. Route-specific flags
 * const betaMiddleware = featureFlagMiddleware({
 *   evaluator,
 *   cache,
 *   metrics,
 *   flags: ["beta-ui", "premium-feature"],
 *   extractors: [planExtractor],
 * });
 *
 * app.get("/dashboard", betaMiddleware, (req, res) => {
 *   res.json({
 *     darkMode: req.featureFlags["dark-mode"],
 *     betaUi: req.featureFlags["beta-ui"],
 *     premium: req.featureFlags["premium-feature"],
 *   });
 * });
 *
 * // 6. Prometheus metrics endpoint
 * app.get("/metrics", metrics.metricsHandler());
 *
 * app.listen(3000);
 * ```
 *
 * ========================================================================
 *  USAGE EXAMPLE — Fastify
 * ========================================================================
 *
 * ```ts
 * import Fastify from "fastify";
 * import {
 *   featureFlagPlugin,
 *   InMemoryFlagEvaluator,
 *   LRUFlagCache,
 *   PrometheusMetrics,
 * } from "./flag-middleware";
 *
 * const evaluator = new InMemoryFlagEvaluator([
 *   { key: "dark-mode", enabled: true },
 *   {
 *     key: "new-checkout",
 *     enabled: true,
 *     value: false,
 *     rules: [
 *       {
 *         name: "eu-rollout",
 *         attribute: "region",
 *         operator: "in",
 *         value: ["DE", "FR", "NL"],
 *         returnValue: true,
 *       },
 *     ],
 *   },
 * ]);
 *
 * const cache = new LRUFlagCache({ maxSize: 10_000, ttlMs: 60_000 });
 * const metrics = new PrometheusMetrics();
 *
 * const app = Fastify({ logger: true });
 *
 * // Register plugin — flags evaluated on every request
 * app.register(featureFlagPlugin, {
 *   evaluator,
 *   cache,
 *   metrics,
 *   flags: ["dark-mode"],
 *   defaults: { "dark-mode": false },
 * });
 *
 * // Global route
 * app.get("/", async (request) => {
 *   return { darkMode: request.featureFlags["dark-mode"] };
 * });
 *
 * // Route-level flag override via route config
 * app.get(
 *   "/checkout",
 *   { config: { featureFlags: ["dark-mode", "new-checkout"] } },
 *   async (request) => {
 *     return {
 *       darkMode: request.featureFlags["dark-mode"],
 *       newCheckout: request.featureFlags["new-checkout"],
 *     };
 *   },
 * );
 *
 * // Prometheus metrics
 * app.get("/metrics", async (_request, reply) => {
 *   reply.header("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
 *   return metrics.serialize();
 * });
 *
 * app.listen({ port: 3000 });
 * ```
 *
 * ========================================================================
 *  CACHE INVALIDATION
 * ========================================================================
 *
 * ```ts
 * // Invalidate all cached values for a specific user
 * await cache.invalidate("user:42:*");
 *
 * // Invalidate a single global flag
 * await cache.invalidate("global:dark-mode");
 *
 * // Listen for flag change events (e.g. from a webhook or message queue)
 * flagChangeEmitter.on("flag:updated", async (flagKey: string) => {
 *   await cache.invalidate(`global:${flagKey}`);
 *   // For a full purge of per-user caches you would need a broader pattern
 *   // or simply let the TTL expire.
 * });
 * ```
 */
