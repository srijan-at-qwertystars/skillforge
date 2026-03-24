/**
 * Redis caching library with cache-aside, write-through, stampede protection
 * (mutex + probabilistic), and multi-layer support.
 */

import { createClient, RedisClientType } from "redis";

// ─── Types ───────────────────────────────────────────────────────────────────

export interface CacheOptions {
  ttl: number; // seconds
  prefix?: string;
  serialize?: (value: unknown) => string;
  deserialize?: (raw: string) => unknown;
}

export interface StampedeOptions {
  /** Mutex lock TTL in seconds (default: 10) */
  lockTtl?: number;
  /** XFetch beta parameter — higher = more aggressive early refresh (default: 1.0) */
  beta?: number;
  /** Strategy: 'mutex' | 'probabilistic' | 'both' (default: 'both') */
  strategy?: "mutex" | "probabilistic" | "both";
}

export interface MultiLayerConfig {
  l1: L1Cache;
  l2: RedisCache;
  /** L1 TTL in seconds — should be short (default: 30) */
  l1Ttl?: number;
}

export interface L1Cache {
  get(key: string): unknown | undefined;
  set(key: string, value: unknown, ttlMs: number): void;
  delete(key: string): void;
  clear(): void;
}

interface XFetchEntry {
  value: unknown;
  delta: number; // recomputation time in ms
  storedAt: number; // timestamp in ms
}

type Loader<T> = () => Promise<T>;

// ─── In-Memory L1 Cache ─────────────────────────────────────────────────────

export class InMemoryL1Cache implements L1Cache {
  private store = new Map<string, { value: unknown; expiresAt: number }>();
  private maxSize: number;

  constructor(maxSize = 1000) {
    this.maxSize = maxSize;
  }

  get(key: string): unknown | undefined {
    const entry = this.store.get(key);
    if (!entry) return undefined;
    if (Date.now() > entry.expiresAt) {
      this.store.delete(key);
      return undefined;
    }
    return entry.value;
  }

  set(key: string, value: unknown, ttlMs: number): void {
    if (this.store.size >= this.maxSize) {
      const firstKey = this.store.keys().next().value;
      if (firstKey !== undefined) {
        this.store.delete(firstKey);
      }
    }
    this.store.set(key, { value, expiresAt: Date.now() + ttlMs });
  }

  delete(key: string): void {
    this.store.delete(key);
  }

  clear(): void {
    this.store.clear();
  }
}

// ─── Redis Cache ────────────────────────────────────────────────────────────

export class RedisCache {
  private client: RedisClientType;
  private prefix: string;
  private defaultTtl: number;
  private serialize: (value: unknown) => string;
  private deserialize: (raw: string) => unknown;

  constructor(client: RedisClientType, options: CacheOptions) {
    this.client = client;
    this.prefix = options.prefix ?? "";
    this.defaultTtl = options.ttl;
    this.serialize = options.serialize ?? JSON.stringify;
    this.deserialize = options.deserialize ?? JSON.parse;
  }

  private key(k: string): string {
    return this.prefix ? `${this.prefix}:${k}` : k;
  }

  // ─── Cache-Aside ────────────────────────────────────────────────────────

  async getOrLoad<T>(
    key: string,
    loader: Loader<T>,
    ttl?: number,
  ): Promise<T> {
    const fullKey = this.key(key);
    const cached = await this.client.get(fullKey);

    if (cached !== null) {
      return this.deserialize(cached) as T;
    }

    const value = await loader();
    await this.client.setEx(fullKey, ttl ?? this.defaultTtl, this.serialize(value));
    return value;
  }

  async get<T>(key: string): Promise<T | null> {
    const raw = await this.client.get(this.key(key));
    return raw !== null ? (this.deserialize(raw) as T) : null;
  }

  async set(key: string, value: unknown, ttl?: number): Promise<void> {
    await this.client.setEx(
      this.key(key),
      ttl ?? this.defaultTtl,
      this.serialize(value),
    );
  }

  async delete(key: string): Promise<void> {
    await this.client.del(this.key(key));
  }

  async deleteByPattern(pattern: string): Promise<number> {
    let deleted = 0;
    let cursor = 0;
    do {
      const result = await this.client.scan(cursor, {
        MATCH: this.key(pattern),
        COUNT: 100,
      });
      cursor = result.cursor;
      if (result.keys.length > 0) {
        deleted += await this.client.del(result.keys);
      }
    } while (cursor !== 0);
    return deleted;
  }

  // ─── Write-Through ──────────────────────────────────────────────────────

  async writeThrough<T>(
    key: string,
    value: T,
    writer: (value: T) => Promise<void>,
    ttl?: number,
  ): Promise<void> {
    await writer(value);
    await this.set(key, value, ttl);
  }

  // ─── Stampede Protection: Mutex ──────────────────────────────────────────

  async getOrLoadWithMutex<T>(
    key: string,
    loader: Loader<T>,
    ttl?: number,
    opts?: Pick<StampedeOptions, "lockTtl">,
  ): Promise<T> {
    const fullKey = this.key(key);
    const lockKey = `lock:${fullKey}`;
    const lockTtl = opts?.lockTtl ?? 10;

    const cached = await this.client.get(fullKey);
    if (cached !== null) {
      return this.deserialize(cached) as T;
    }

    const acquired = await this.client.set(lockKey, "1", {
      NX: true,
      EX: lockTtl,
    });

    if (acquired) {
      try {
        const value = await loader();
        await this.client.setEx(
          fullKey,
          ttl ?? this.defaultTtl,
          this.serialize(value),
        );
        return value;
      } finally {
        await this.client.del(lockKey);
      }
    }

    // Wait for the lock holder to populate the cache
    for (let i = 0; i < 20; i++) {
      await sleep(50 * Math.min(1.5 ** i, 5));
      const retried = await this.client.get(fullKey);
      if (retried !== null) {
        return this.deserialize(retried) as T;
      }
    }

    // Fallback: compute ourselves
    return loader();
  }

  // ─── Stampede Protection: Probabilistic (XFetch) ────────────────────────

  async getOrLoadXFetch<T>(
    key: string,
    loader: Loader<T>,
    ttl?: number,
    beta = 1.0,
  ): Promise<T> {
    const fullKey = this.key(key);
    const effectiveTtl = ttl ?? this.defaultTtl;

    const raw = await this.client.get(fullKey);
    if (raw !== null) {
      try {
        const entry = JSON.parse(raw) as XFetchEntry;
        const remaining = await this.client.ttl(fullKey);

        // XFetch decision: recompute early with increasing probability
        const gap =
          (entry.delta / 1000) * beta * Math.log(Math.random());
        if (remaining + gap > 0) {
          return entry.value as T;
        }
      } catch {
        // Malformed entry — fall through to recompute
      }
    }

    const start = Date.now();
    const value = await loader();
    const delta = Date.now() - start;

    const entry: XFetchEntry = {
      value,
      delta,
      storedAt: Date.now(),
    };
    await this.client.setEx(fullKey, effectiveTtl, JSON.stringify(entry));
    return value;
  }

  // ─── Combined Stampede Protection ───────────────────────────────────────

  async getOrLoadProtected<T>(
    key: string,
    loader: Loader<T>,
    ttl?: number,
    opts?: StampedeOptions,
  ): Promise<T> {
    const strategy = opts?.strategy ?? "both";

    switch (strategy) {
      case "mutex":
        return this.getOrLoadWithMutex(key, loader, ttl, opts);
      case "probabilistic":
        return this.getOrLoadXFetch(key, loader, ttl, opts?.beta);
      case "both": {
        const fullKey = this.key(key);
        const effectiveTtl = ttl ?? this.defaultTtl;
        const beta = opts?.beta ?? 1.0;

        // Try probabilistic first (no lock needed if cache is warm)
        const raw = await this.client.get(fullKey);
        if (raw !== null) {
          try {
            const entry = JSON.parse(raw) as XFetchEntry;
            const remaining = await this.client.ttl(fullKey);
            const gap =
              (entry.delta / 1000) * beta * Math.log(Math.random());
            if (remaining + gap > 0) {
              return entry.value as T;
            }
          } catch {
            // fall through
          }
        }

        // Fall through to mutex-protected recomputation
        const lockKey = `lock:${fullKey}`;
        const lockTtl = opts?.lockTtl ?? 10;
        const acquired = await this.client.set(lockKey, "1", {
          NX: true,
          EX: lockTtl,
        });

        if (acquired) {
          try {
            const start = Date.now();
            const value = await loader();
            const delta = Date.now() - start;
            const entry: XFetchEntry = {
              value,
              delta,
              storedAt: Date.now(),
            };
            await this.client.setEx(
              fullKey,
              effectiveTtl,
              JSON.stringify(entry),
            );
            return value;
          } finally {
            await this.client.del(lockKey);
          }
        }

        // Wait for lock holder
        for (let i = 0; i < 20; i++) {
          await sleep(50 * Math.min(1.5 ** i, 5));
          const retried = await this.client.get(fullKey);
          if (retried !== null) {
            const entry = JSON.parse(retried) as XFetchEntry;
            return entry.value as T;
          }
        }
        return loader();
      }
    }
  }

  // ─── Bulk Operations ────────────────────────────────────────────────────

  async mget<T>(keys: string[]): Promise<(T | null)[]> {
    const fullKeys = keys.map((k) => this.key(k));
    const results = await this.client.mGet(fullKeys);
    return results.map((r) =>
      r !== null ? (this.deserialize(r) as T) : null,
    );
  }

  async mset(
    entries: Array<{ key: string; value: unknown }>,
    ttl?: number,
  ): Promise<void> {
    const effectiveTtl = ttl ?? this.defaultTtl;
    const multi = this.client.multi();
    for (const { key, value } of entries) {
      multi.setEx(this.key(key), effectiveTtl, this.serialize(value));
    }
    await multi.exec();
  }

  // ─── Negative Caching ──────────────────────────────────────────────────

  async getOrLoadWithNegativeCache<T>(
    key: string,
    loader: Loader<T | null>,
    ttl?: number,
    negativeTtl = 60,
  ): Promise<T | null> {
    const fullKey = this.key(key);
    const raw = await this.client.get(fullKey);

    if (raw === "__NULL__") return null;
    if (raw !== null) return this.deserialize(raw) as T;

    const value = await loader();
    if (value === null) {
      await this.client.setEx(fullKey, negativeTtl, "__NULL__");
    } else {
      await this.client.setEx(
        fullKey,
        ttl ?? this.defaultTtl,
        this.serialize(value),
      );
    }
    return value;
  }
}

// ─── Multi-Layer Cache ──────────────────────────────────────────────────────

export class MultiLayerCache {
  private l1: L1Cache;
  private l2: RedisCache;
  private l1TtlMs: number;

  constructor(config: MultiLayerConfig) {
    this.l1 = config.l1;
    this.l2 = config.l2;
    this.l1TtlMs = (config.l1Ttl ?? 30) * 1000;
  }

  async get<T>(key: string, loader: Loader<T>, ttl?: number): Promise<T> {
    // L1
    const l1Val = this.l1.get(key);
    if (l1Val !== undefined) return l1Val as T;

    // L2
    const l2Val = await this.l2.get<T>(key);
    if (l2Val !== null) {
      this.l1.set(key, l2Val, this.l1TtlMs);
      return l2Val;
    }

    // Origin
    const value = await loader();
    await this.l2.set(key, value, ttl);
    this.l1.set(key, value, this.l1TtlMs);
    return value;
  }

  async invalidate(key: string): Promise<void> {
    this.l1.delete(key);
    await this.l2.delete(key);
  }

  async set(key: string, value: unknown, ttl?: number): Promise<void> {
    await this.l2.set(key, value, ttl);
    this.l1.set(key, value, this.l1TtlMs);
  }

  clearL1(): void {
    this.l1.clear();
  }
}

// ─── Factory ────────────────────────────────────────────────────────────────

export async function createRedisCache(
  url: string,
  options: CacheOptions,
): Promise<RedisCache> {
  const client = createClient({ url }) as RedisClientType;
  await client.connect();
  return new RedisCache(client, options);
}

export function createMultiLayerCache(
  redisCache: RedisCache,
  l1MaxSize = 1000,
  l1TtlSeconds = 30,
): MultiLayerCache {
  return new MultiLayerCache({
    l1: new InMemoryL1Cache(l1MaxSize),
    l2: redisCache,
    l1Ttl: l1TtlSeconds,
  });
}

// ─── Utilities ──────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
