/**
 * Valkey/Redis Connection Template (ioredis)
 *
 * Production-ready connection patterns:
 *   - Standalone with retry and health checks
 *   - Cluster mode with read replicas
 *   - Sentinel mode with automatic failover
 *   - Pub/Sub with reconnection handling
 *   - Connection pooling via separate instances
 *
 * Install: npm install ioredis
 */

import Redis, { Cluster, RedisOptions, ClusterOptions } from "ioredis";

// =============================================================================
// Configuration
// =============================================================================

interface RedisConfig {
  host: string;
  port: number;
  password?: string;
  db?: number;
  tls?: boolean;
  keyPrefix?: string;
  commandTimeout?: number;
  connectTimeout?: number;
  maxRetries?: number;
}

interface SentinelConfig {
  sentinels: Array<{ host: string; port: number }>;
  name: string;
  password?: string;
  sentinelPassword?: string;
  db?: number;
}

interface ClusterConfig {
  nodes: Array<{ host: string; port: number }>;
  password?: string;
  readFromReplicas?: boolean;
  keyPrefix?: string;
}

const DEFAULT_CONFIG: RedisConfig = {
  host: process.env.REDIS_HOST || "127.0.0.1",
  port: parseInt(process.env.REDIS_PORT || "6379", 10),
  password: process.env.REDIS_PASSWORD || undefined,
  db: parseInt(process.env.REDIS_DB || "0", 10),
  tls: process.env.REDIS_TLS === "true",
  commandTimeout: 2000,
  connectTimeout: 5000,
  maxRetries: 3,
};

// =============================================================================
// Standalone Connection
// =============================================================================

export function createStandaloneClient(
  config: Partial<RedisConfig> = {}
): Redis {
  const cfg = { ...DEFAULT_CONFIG, ...config };

  const options: RedisOptions = {
    host: cfg.host,
    port: cfg.port,
    password: cfg.password,
    db: cfg.db,
    keyPrefix: cfg.keyPrefix,

    // Timeouts
    connectTimeout: cfg.connectTimeout,
    commandTimeout: cfg.commandTimeout,

    // Retry strategy with exponential backoff
    retryStrategy(times: number): number | null {
      if (times > (cfg.maxRetries ?? 3) * 10) {
        console.error(
          `[Redis] Max reconnection attempts reached (${times}). Giving up.`
        );
        return null; // stop retrying
      }
      const delay = Math.min(times * 200, 5000);
      console.warn(`[Redis] Reconnecting in ${delay}ms (attempt ${times})`);
      return delay;
    },

    maxRetriesPerRequest: cfg.maxRetries,

    // TLS
    ...(cfg.tls && {
      tls: {
        rejectUnauthorized: true,
      },
    }),

    // Health checks
    enableReadyCheck: true,

    // Don't queue commands before connection is ready
    enableOfflineQueue: true,
    offlineQueue: true,

    // Reconnect on error (READONLY = failover in progress)
    reconnectOnError(err: Error): boolean | 1 | 2 {
      const targetErrors = ["READONLY", "ECONNRESET", "ETIMEDOUT"];
      if (targetErrors.some((e) => err.message.includes(e))) {
        return true;
      }
      return false;
    },
  };

  const client = new Redis(options);

  // Event handlers
  client.on("connect", () => console.log("[Redis] Connected"));
  client.on("ready", () => console.log("[Redis] Ready"));
  client.on("error", (err) => console.error("[Redis] Error:", err.message));
  client.on("close", () => console.warn("[Redis] Connection closed"));
  client.on("reconnecting", (ms: number) =>
    console.warn(`[Redis] Reconnecting in ${ms}ms`)
  );

  return client;
}

// =============================================================================
// Sentinel Connection (High Availability)
// =============================================================================

export function createSentinelClient(config: SentinelConfig): Redis {
  const options: RedisOptions = {
    sentinels: config.sentinels,
    name: config.name,
    password: config.password,
    sentinelPassword: config.sentinelPassword,
    db: config.db,

    connectTimeout: 5000,
    commandTimeout: 2000,
    maxRetriesPerRequest: 3,
    enableReadyCheck: true,
    enableOfflineQueue: true,

    retryStrategy(times: number): number | null {
      if (times > 30) return null;
      return Math.min(times * 200, 5000);
    },

    // Automatically reconnect on failover
    reconnectOnError(err: Error): boolean | 1 | 2 {
      if (err.message.includes("READONLY")) {
        return 2; // reconnect and resend failed command
      }
      return false;
    },

    // Enable NAT mapping if using Docker/Kubernetes
    // natMap: {
    //   "internal-ip:6379": { host: "external-ip", port: 6379 },
    // },
  };

  const client = new Redis(options);

  client.on("connect", () =>
    console.log(`[Sentinel] Connected to master "${config.name}"`)
  );
  client.on("error", (err) =>
    console.error("[Sentinel] Error:", err.message)
  );
  client.on("+switch-master", (data) =>
    console.log("[Sentinel] Master switched:", data)
  );

  return client;
}

// =============================================================================
// Cluster Connection
// =============================================================================

export function createClusterClient(config: ClusterConfig): Cluster {
  const options: ClusterOptions = {
    // Read from replicas to reduce master load
    scaleReads: config.readFromReplicas ? "slave" : "master",

    // Retry on MOVED/ASK redirections
    maxRedirections: 16,

    // Retry on cluster down
    clusterRetryStrategy(times: number): number | null {
      if (times > 30) return null;
      return Math.min(times * 300, 5000);
    },

    // Per-node Redis options
    redisOptions: {
      password: config.password,
      connectTimeout: 5000,
      commandTimeout: 2000,
      maxRetriesPerRequest: 3,
      enableReadyCheck: true,
      enableOfflineQueue: true,
    },

    // Don't rediscover cluster topology too aggressively
    slotsRefreshTimeout: 2000,
    slotsRefreshInterval: 5000,

    // Key prefix
    keyPrefix: config.keyPrefix,

    // Enable NAT mapping if using Docker
    enableAutoPipelining: true,
    // natMap: {
    //   "internal-ip:7001": { host: "localhost", port: 7001 },
    // },
  };

  const cluster = new Redis.Cluster(
    config.nodes.map((n) => ({ host: n.host, port: n.port })),
    options
  );

  cluster.on("connect", () => console.log("[Cluster] Connected to node"));
  cluster.on("ready", () => console.log("[Cluster] Ready"));
  cluster.on("error", (err) =>
    console.error("[Cluster] Error:", err.message)
  );
  cluster.on("+node", (node) =>
    console.log(`[Cluster] Node added: ${node.options.host}:${node.options.port}`)
  );
  cluster.on("-node", (node) =>
    console.warn(`[Cluster] Node removed: ${node.options.host}:${node.options.port}`)
  );

  return cluster;
}

// =============================================================================
// Pub/Sub Client
// =============================================================================

export interface PubSubHandler {
  subscriber: Redis;
  publisher: Redis;
  subscribe(channel: string, handler: (message: string) => void): void;
  psubscribe(pattern: string, handler: (channel: string, message: string) => void): void;
  publish(channel: string, message: string): Promise<number>;
  unsubscribe(channel: string): void;
  shutdown(): Promise<void>;
}

export function createPubSubClient(
  config: Partial<RedisConfig> = {}
): PubSubHandler {
  // Pub/Sub requires dedicated connections — subscriber can't send regular commands
  const subscriber = createStandaloneClient(config);
  const publisher = createStandaloneClient(config);

  const handlers = new Map<string, (message: string) => void>();
  const patternHandlers = new Map<
    string,
    (channel: string, message: string) => void
  >();

  subscriber.on("message", (channel: string, message: string) => {
    const handler = handlers.get(channel);
    if (handler) handler(message);
  });

  subscriber.on(
    "pmessage",
    (pattern: string, channel: string, message: string) => {
      const handler = patternHandlers.get(pattern);
      if (handler) handler(channel, message);
    }
  );

  return {
    subscriber,
    publisher,

    subscribe(channel: string, handler: (message: string) => void): void {
      handlers.set(channel, handler);
      subscriber.subscribe(channel);
    },

    psubscribe(
      pattern: string,
      handler: (channel: string, message: string) => void
    ): void {
      patternHandlers.set(pattern, handler);
      subscriber.psubscribe(pattern);
    },

    async publish(channel: string, message: string): Promise<number> {
      return publisher.publish(channel, message);
    },

    unsubscribe(channel: string): void {
      handlers.delete(channel);
      subscriber.unsubscribe(channel);
    },

    async shutdown(): Promise<void> {
      subscriber.disconnect();
      publisher.disconnect();
    },
  };
}

// =============================================================================
// Graceful Shutdown Helper
// =============================================================================

export function setupGracefulShutdown(...clients: (Redis | Cluster)[]): void {
  const shutdown = async (signal: string) => {
    console.log(`\n[Redis] Received ${signal}. Shutting down connections...`);
    await Promise.allSettled(
      clients.map((client) => {
        client.disconnect();
        return new Promise<void>((resolve) => {
          client.once("close", resolve);
          setTimeout(resolve, 2000); // force resolve after 2s
        });
      })
    );
    console.log("[Redis] All connections closed.");
    process.exit(0);
  };

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

// =============================================================================
// Usage Examples
// =============================================================================

/*
// --- Standalone ---
const redis = createStandaloneClient({
  host: "127.0.0.1",
  port: 6379,
  password: "secret",
});
setupGracefulShutdown(redis);

await redis.set("key", "value", "EX", 3600);
const val = await redis.get("key");

// --- Sentinel ---
const sentinelClient = createSentinelClient({
  sentinels: [
    { host: "10.0.0.1", port: 26379 },
    { host: "10.0.0.2", port: 26379 },
    { host: "10.0.0.3", port: 26379 },
  ],
  name: "mymaster",
  password: "secret",
});

// --- Cluster ---
const cluster = createClusterClient({
  nodes: [
    { host: "10.0.0.1", port: 7001 },
    { host: "10.0.0.2", port: 7002 },
    { host: "10.0.0.3", port: 7003 },
  ],
  password: "secret",
  readFromReplicas: true,
});
setupGracefulShutdown(cluster);

// --- Pub/Sub ---
const pubsub = createPubSubClient();
pubsub.subscribe("notifications", (msg) => {
  console.log("Received:", msg);
});
await pubsub.publish("notifications", JSON.stringify({ type: "alert" }));

// --- Pipeline ---
const pipeline = redis.pipeline();
pipeline.set("k1", "v1");
pipeline.set("k2", "v2");
pipeline.get("k1");
pipeline.get("k2");
const results = await pipeline.exec();
*/
