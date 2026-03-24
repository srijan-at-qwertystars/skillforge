# Advanced Cloudflare Workers Patterns

## Table of Contents

- [Durable Objects Patterns](#durable-objects-patterns)
  - [Actor Model](#actor-model)
  - [WebSocket Rooms](#websocket-rooms)
  - [Rate Limiting with DO](#rate-limiting-with-do)
  - [Distributed Locks](#distributed-locks)
- [D1 Patterns](#d1-patterns)
  - [Migration Strategy](#migration-strategy)
  - [Schema Design](#schema-design)
  - [Query Patterns](#query-patterns)
- [R2 Patterns](#r2-patterns)
  - [Multipart Uploads](#multipart-uploads)
  - [Presigned URLs](#presigned-urls)
- [Queue Patterns](#queue-patterns)
  - [Retry Strategies](#retry-strategies)
  - [Dead Letter Queues](#dead-letter-queues)
  - [Fan-out / Fan-in](#fan-out--fan-in)
- [Service Bindings Composition](#service-bindings-composition)
- [Hyperdrive](#hyperdrive)
- [Workers for Platforms](#workers-for-platforms)
- [Smart Placement](#smart-placement)
- [Tail Workers](#tail-workers)

---

## Durable Objects Patterns

### Actor Model

Each Durable Object instance is a single-threaded actor with exclusive access to its state. Route requests by entity ID to co-locate state and logic.

```ts
// Entity-per-user pattern: each user gets their own DO instance
export class UserActor extends DurableObject {
  private profile: UserProfile | null = null;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.profile = await ctx.storage.get<UserProfile>("profile") ?? null;
    });
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    switch (`${request.method} ${url.pathname}`) {
      case "GET /profile":
        return Response.json(this.profile);
      case "PUT /profile": {
        this.profile = await request.json<UserProfile>();
        await this.ctx.storage.put("profile", this.profile);
        return Response.json(this.profile);
      }
      case "POST /action": {
        const action = await request.json<Action>();
        return this.handleAction(action);
      }
      default:
        return new Response("Not Found", { status: 404 });
    }
  }

  private async handleAction(action: Action): Promise<Response> {
    // All mutations are serialized — no race conditions
    const history = await this.ctx.storage.get<Action[]>("history") ?? [];
    history.push(action);
    await this.ctx.storage.put("history", history);
    return Response.json({ queued: history.length });
  }
}

// Router worker
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const userId = getUserIdFromAuth(request);
    const id = env.USER_ACTOR.idFromName(userId);
    const stub = env.USER_ACTOR.get(id);
    return stub.fetch(request);
  },
};
```

**Sharding for high throughput:** When a single actor becomes a bottleneck, shard by sub-entity:
```ts
// Shard counters: distribute writes across N shards, aggregate on read
const shardId = Math.floor(Math.random() * NUM_SHARDS);
const id = env.COUNTER.idFromName(`counter:${entityId}:shard:${shardId}`);
const stub = env.COUNTER.get(id);
await stub.fetch(new Request("https://do/increment"));

// Aggregate: fan out to all shards
async function getTotal(env: Env, entityId: string): Promise<number> {
  const results = await Promise.all(
    Array.from({ length: NUM_SHARDS }, (_, i) => {
      const id = env.COUNTER.idFromName(`counter:${entityId}:shard:${i}`);
      return env.COUNTER.get(id).fetch(new Request("https://do/value"))
        .then(r => r.json<{ count: number }>());
    })
  );
  return results.reduce((sum, r) => sum + r.count, 0);
}
```

### WebSocket Rooms

Full WebSocket room with hibernation, user tracking, and broadcast:

```ts
export class ChatRoom extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("Expected WebSocket", { status: 400 });
    }
    const url = new URL(request.url);
    const username = url.searchParams.get("user") ?? "anonymous";

    const pair = new WebSocketPair();
    // Attach metadata to the server socket — survives hibernation
    this.ctx.acceptWebSocket(pair[1], [username]);

    this.broadcast(JSON.stringify({
      type: "join", user: username,
      users: this.ctx.getWebSockets().map(ws => this.ctx.getTags(ws)[0]),
    }));

    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer) {
    const username = this.ctx.getTags(ws)[0];
    this.broadcast(JSON.stringify({
      type: "message", user: username, text: String(message),
      ts: Date.now(),
    }));
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string) {
    const username = this.ctx.getTags(ws)[0];
    ws.close(code, reason);
    this.broadcast(JSON.stringify({ type: "leave", user: username }));
  }

  async webSocketError(ws: WebSocket, error: unknown) {
    ws.close(1011, "Unexpected error");
  }

  private broadcast(message: string, exclude?: WebSocket) {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws !== exclude) {
        try { ws.send(message); } catch { /* socket already closed */ }
      }
    }
  }
}
```

**Key points:**
- Tags (3rd arg to `acceptWebSocket`) persist across hibernation — use for user identity.
- `getWebSockets()` returns only live connections.
- Hibernation means the DO sleeps between messages — you're not billed for idle time.
- Max ~32K concurrent WebSockets per DO instance.

### Rate Limiting with DO

Precise, per-key rate limiting using DO storage (not KV — needs strong consistency):

```ts
export class RateLimiter extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    const { key, limit, windowMs } = await request.json<{
      key: string; limit: number; windowMs: number;
    }>();

    const now = Date.now();
    const windowStart = now - windowMs;
    let timestamps = await this.ctx.storage.get<number[]>(`ts:${key}`) ?? [];

    // Prune expired entries
    timestamps = timestamps.filter(t => t > windowStart);

    if (timestamps.length >= limit) {
      const retryAfter = Math.ceil((timestamps[0] + windowMs - now) / 1000);
      return Response.json(
        { allowed: false, remaining: 0, retryAfter },
        { status: 429, headers: { "Retry-After": String(retryAfter) } }
      );
    }

    timestamps.push(now);
    await this.ctx.storage.put(`ts:${key}`, timestamps);

    return Response.json({
      allowed: true,
      remaining: limit - timestamps.length,
      resetAt: timestamps[0] + windowMs,
    });
  }
}
```

**Sliding window with alarm cleanup:**
```ts
async alarm(): Promise<void> {
  // Periodic cleanup of expired keys
  const allKeys = await this.ctx.storage.list<number[]>({ prefix: "ts:" });
  const now = Date.now();
  const deletes: string[] = [];
  for (const [key, timestamps] of allKeys) {
    const active = timestamps.filter(t => t > now - 60_000);
    if (active.length === 0) deletes.push(key);
    else await this.ctx.storage.put(key, active);
  }
  if (deletes.length) await this.ctx.storage.delete(deletes);
  // Re-schedule if keys remain
  if ((await this.ctx.storage.list({ prefix: "ts:", limit: 1 })).size > 0) {
    await this.ctx.storage.setAlarm(Date.now() + 60_000);
  }
}
```

### Distributed Locks

Use a DO as a distributed lock manager — single-threaded guarantees mutual exclusion:

```ts
export class LockManager extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const lockName = url.searchParams.get("lock")!;
    const ttlMs = parseInt(url.searchParams.get("ttl") ?? "30000");

    switch (url.pathname) {
      case "/acquire": {
        const existing = await this.ctx.storage.get<LockInfo>(`lock:${lockName}`);
        if (existing && existing.expiresAt > Date.now()) {
          return Response.json({ acquired: false, holder: existing.holder }, { status: 409 });
        }
        const holder = crypto.randomUUID();
        const lock: LockInfo = { holder, expiresAt: Date.now() + ttlMs };
        await this.ctx.storage.put(`lock:${lockName}`, lock);
        // Schedule alarm to auto-release expired locks
        await this.ctx.storage.setAlarm(Date.now() + ttlMs);
        return Response.json({ acquired: true, holder, expiresAt: lock.expiresAt });
      }
      case "/release": {
        const holder = url.searchParams.get("holder")!;
        const existing = await this.ctx.storage.get<LockInfo>(`lock:${lockName}`);
        if (!existing || existing.holder !== holder) {
          return Response.json({ released: false }, { status: 409 });
        }
        await this.ctx.storage.delete(`lock:${lockName}`);
        return Response.json({ released: true });
      }
      case "/renew": {
        const holder = url.searchParams.get("holder")!;
        const existing = await this.ctx.storage.get<LockInfo>(`lock:${lockName}`);
        if (!existing || existing.holder !== holder) {
          return Response.json({ renewed: false }, { status: 409 });
        }
        existing.expiresAt = Date.now() + ttlMs;
        await this.ctx.storage.put(`lock:${lockName}`, existing);
        return Response.json({ renewed: true, expiresAt: existing.expiresAt });
      }
      default:
        return new Response("Not Found", { status: 404 });
    }
  }

  async alarm(): Promise<void> {
    const locks = await this.ctx.storage.list<LockInfo>({ prefix: "lock:" });
    const now = Date.now();
    const expired: string[] = [];
    for (const [key, lock] of locks) {
      if (lock.expiresAt <= now) expired.push(key);
    }
    if (expired.length) await this.ctx.storage.delete(expired);
  }
}

interface LockInfo { holder: string; expiresAt: number; }
```

---

## D1 Patterns

### Migration Strategy

Structure migrations as sequential, versioned SQL files:

```
migrations/
├── 0001_create_users.sql
├── 0002_add_user_email_index.sql
├── 0003_create_posts.sql
└── 0004_add_posts_fts.sql
```

```bash
# Create migration
npx wrangler d1 migrations create my-db "add_user_roles"
# Apply locally first
npx wrangler d1 migrations apply my-db --local
# Apply to remote (production)
npx wrangler d1 migrations apply my-db --remote
# List applied migrations
npx wrangler d1 migrations list my-db --remote
```

**Migration rules:**
- Migrations are append-only — never edit an applied migration.
- Always test locally before applying to remote.
- D1 does NOT support `ALTER TABLE ... DROP COLUMN` — use create-copy-drop pattern.
- Wrap DDL and DML in the same migration when backfilling data.
- Keep migrations small and focused — one logical change per file.

### Schema Design

D1 is SQLite — design accordingly:

```sql
-- Use INTEGER PRIMARY KEY for rowid alias (fast)
CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  external_id TEXT NOT NULL UNIQUE,   -- UUID from app layer
  email TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  metadata TEXT,                       -- JSON column (use json_extract)
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Composite index for common queries
CREATE INDEX idx_users_created ON users(created_at DESC);

-- JSON extraction index
CREATE INDEX idx_users_plan ON users(json_extract(metadata, '$.plan'));

-- Full-text search
CREATE VIRTUAL TABLE users_fts USING fts5(name, email, content=users, content_rowid=id);

-- Triggers to keep FTS in sync
CREATE TRIGGER users_ai AFTER INSERT ON users BEGIN
  INSERT INTO users_fts(rowid, name, email) VALUES (new.id, new.name, new.email);
END;
CREATE TRIGGER users_ad AFTER DELETE ON users BEGIN
  INSERT INTO users_fts(users_fts, rowid, name, email) VALUES('delete', old.id, old.name, old.email);
END;
CREATE TRIGGER users_au AFTER UPDATE ON users BEGIN
  INSERT INTO users_fts(users_fts, rowid, name, email) VALUES('delete', old.id, old.name, old.email);
  INSERT INTO users_fts(rowid, name, email) VALUES (new.id, new.name, new.email);
END;
```

**D1-specific tips:**
- Max row size: 1MB. Max database size: 10GB (paid), 500MB (free).
- Use `TEXT` for dates (ISO 8601) — D1/SQLite has no native date type.
- `json_extract()` works but is slow at scale — extract hot fields into real columns.
- No foreign key enforcement by default — add `PRAGMA foreign_keys = ON` in your Worker.
- Batch operations (`db.batch()`) are implicit transactions — use for atomic multi-table writes.

### Query Patterns

```ts
// Pagination with cursor (more efficient than OFFSET)
async function paginateUsers(db: D1Database, cursor?: string, limit = 20) {
  const stmt = cursor
    ? db.prepare("SELECT * FROM users WHERE id > ? ORDER BY id LIMIT ?").bind(cursor, limit)
    : db.prepare("SELECT * FROM users ORDER BY id LIMIT ?").bind(limit);
  const { results } = await stmt.all<User>();
  const nextCursor = results.length === limit ? results[results.length - 1].id : null;
  return { results, nextCursor };
}

// Full-text search
async function searchUsers(db: D1Database, query: string) {
  return db.prepare(
    "SELECT u.* FROM users_fts f JOIN users u ON f.rowid = u.id WHERE f.users_fts MATCH ? ORDER BY rank"
  ).bind(query).all<User>();
}

// Upsert
async function upsertUser(db: D1Database, user: User) {
  return db.prepare(`
    INSERT INTO users (external_id, email, name) VALUES (?, ?, ?)
    ON CONFLICT(external_id) DO UPDATE SET email=excluded.email, name=excluded.name, updated_at=datetime('now')
  `).bind(user.externalId, user.email, user.name).run();
}
```

---

## R2 Patterns

### Multipart Uploads

For files >5MB, use multipart upload. Minimum part size is 5MB (except last part).

```ts
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/upload/init" && request.method === "POST") {
      const { key } = await request.json<{ key: string }>();
      const upload = await env.BUCKET.createMultipartUpload(key, {
        httpMetadata: { contentType: "application/octet-stream" },
      });
      return Response.json({ uploadId: upload.uploadId, key: upload.key });
    }

    if (url.pathname === "/upload/part" && request.method === "PUT") {
      const key = url.searchParams.get("key")!;
      const uploadId = url.searchParams.get("uploadId")!;
      const partNumber = parseInt(url.searchParams.get("part")!);

      const upload = env.BUCKET.resumeMultipartUpload(key, uploadId);
      const part = await upload.uploadPart(partNumber, request.body!);
      return Response.json({ partNumber: part.partNumber, etag: part.etag });
    }

    if (url.pathname === "/upload/complete" && request.method === "POST") {
      const { key, uploadId, parts } = await request.json<{
        key: string; uploadId: string;
        parts: { partNumber: number; etag: string }[];
      }>();
      const upload = env.BUCKET.resumeMultipartUpload(key, uploadId);
      await upload.complete(parts);
      return Response.json({ success: true });
    }

    return new Response("Not Found", { status: 404 });
  },
};
```

### Presigned URLs

Generate time-limited URLs for direct client uploads/downloads:

```ts
import { AwsClient } from "aws4fetch";

async function generatePresignedUrl(
  env: Env, key: string, method: "GET" | "PUT", expiresIn = 3600
): Promise<string> {
  const client = new AwsClient({
    accessKeyId: env.R2_ACCESS_KEY_ID,
    secretAccessKey: env.R2_SECRET_ACCESS_KEY,
  });

  const url = new URL(`https://${env.R2_BUCKET_NAME}.${env.ACCOUNT_ID}.r2.cloudflarestorage.com/${key}`);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));

  const signed = await client.sign(
    new Request(url, { method }),
    { aws: { signQuery: true } }
  );

  return signed.url;
}

// Usage in handler
app.post("/upload-url", async (c) => {
  const { filename, contentType } = await c.req.json();
  const key = `uploads/${crypto.randomUUID()}/${filename}`;
  const url = await generatePresignedUrl(c.env, key, "PUT");
  return c.json({ url, key });
});
```

---

## Queue Patterns

### Retry Strategies

```ts
export default {
  async queue(batch: MessageBatch<QueueMessage>, env: Env) {
    for (const msg of batch.messages) {
      try {
        await processMessage(msg.body, env);
        msg.ack();
      } catch (err) {
        // Exponential backoff: 10s, 30s, 90s
        const attempt = msg.attempts;
        if (attempt < 3) {
          const delay = 10 * Math.pow(3, attempt - 1);
          msg.retry({ delaySeconds: delay });
        } else {
          // Max retries exhausted — send to DLQ manually with context
          await env.DLQ.send({
            originalMessage: msg.body,
            error: String(err),
            attempts: attempt,
            failedAt: new Date().toISOString(),
          });
          msg.ack(); // Ack to prevent automatic DLQ (we handled it)
        }
      }
    }
  },
};
```

### Dead Letter Queues

```toml
# wrangler.toml — automatic DLQ after max_retries
[[queues.consumers]]
queue = "main-queue"
dead_letter_queue = "main-dlq"
max_retries = 3
max_batch_size = 10
max_batch_timeout = 5

[[queues.consumers]]
queue = "main-dlq"
max_batch_size = 1

[[queues.producers]]
binding = "MAIN_QUEUE"
queue = "main-queue"
```

```ts
// DLQ processor — log, alert, or retry with human review
export default {
  async queue(batch: MessageBatch<DLQMessage>, env: Env) {
    for (const msg of batch.messages) {
      // Store failed messages for inspection
      await env.DB.prepare(
        "INSERT INTO failed_jobs (payload, error, failed_at) VALUES (?, ?, ?)"
      ).bind(
        JSON.stringify(msg.body),
        msg.body.error ?? "unknown",
        new Date().toISOString()
      ).run();

      // Alert via external webhook
      await fetch(env.ALERT_WEBHOOK, {
        method: "POST",
        body: JSON.stringify({ text: `DLQ message: ${JSON.stringify(msg.body)}` }),
      });

      msg.ack();
    }
  },
};
```

### Fan-out / Fan-in

```ts
// Fan-out: split large jobs into sub-tasks
app.post("/process-batch", async (c) => {
  const { items } = await c.req.json<{ items: Item[] }>();
  const batchId = crypto.randomUUID();

  // Track batch progress in D1
  await c.env.DB.prepare(
    "INSERT INTO batches (id, total, completed) VALUES (?, ?, 0)"
  ).bind(batchId, items.length).run();

  // Send each item as a queue message
  await c.env.TASK_QUEUE.sendBatch(
    items.map(item => ({ body: { batchId, item } }))
  );

  return c.json({ batchId, total: items.length });
});

// Fan-in: each consumer updates progress
export default {
  async queue(batch: MessageBatch<TaskMessage>, env: Env) {
    for (const msg of batch.messages) {
      await processItem(msg.body.item);
      await env.DB.prepare(
        "UPDATE batches SET completed = completed + 1 WHERE id = ?"
      ).bind(msg.body.batchId).run();
      msg.ack();
    }
  },
};
```

---

## Service Bindings Composition

Decompose a monolith into cooperating Workers:

```ts
// Gateway worker — routes to internal services
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Auth check via service binding (no network hop)
    const authResp = await env.AUTH_SERVICE.fetch(
      new Request("https://auth/verify", {
        headers: { Authorization: request.headers.get("Authorization") ?? "" },
      })
    );
    if (!authResp.ok) return authResp;
    const user = await authResp.json<User>();

    // Route to appropriate service
    const headers = new Headers(request.headers);
    headers.set("X-User-Id", user.id);

    if (url.pathname.startsWith("/api/users")) {
      return env.USER_SERVICE.fetch(new Request(request.url, {
        method: request.method, headers, body: request.body,
      }));
    }
    if (url.pathname.startsWith("/api/billing")) {
      return env.BILLING_SERVICE.fetch(new Request(request.url, {
        method: request.method, headers, body: request.body,
      }));
    }

    return new Response("Not Found", { status: 404 });
  },
};
```

```toml
# wrangler.toml for gateway
[[services]]
binding = "AUTH_SERVICE"
service = "auth-worker"
[[services]]
binding = "USER_SERVICE"
service = "user-worker"
[[services]]
binding = "BILLING_SERVICE"
service = "billing-worker"
```

**Service bindings benefits:**
- Zero-latency calls (same process, no HTTP overhead).
- No egress charges.
- Type safety with shared interface packages.
- Each service deploys independently.

---

## Hyperdrive

Connect Workers to external PostgreSQL/MySQL databases with connection pooling and caching:

```toml
# wrangler.toml
[[hyperdrive]]
binding = "HYPERDRIVE"
id = "abc123"
```

```bash
# Create Hyperdrive config
npx wrangler hyperdrive create my-hyperdrive \
  --connection-string="postgres://user:pass@host:5432/db"
```

```ts
import { Client } from "pg";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const client = new Client(env.HYPERDRIVE.connectionString);
    await client.connect();
    try {
      const result = await client.query("SELECT * FROM users WHERE id = $1", [1]);
      return Response.json(result.rows[0]);
    } finally {
      // Connection returns to pool — don't worry about closing
      ctx.waitUntil(client.end());
    }
  },
};
```

**Hyperdrive tips:**
- Caches query results at the edge for read-heavy workloads.
- Set `caching.disabled = true` for write-heavy tables.
- Requires `nodejs_compat` compatibility flag.
- Supports PostgreSQL and MySQL.
- Connection pooling reduces cold start impact.

---

## Workers for Platforms

Multi-tenant architecture: let customers deploy their own Workers on your infrastructure.

```ts
// Dispatch worker — routes to tenant workers
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const tenantId = url.hostname.split(".")[0]; // e.g., tenant1.platform.com

    try {
      const tenantWorker = env.DISPATCHER.get(tenantId);
      return await tenantWorker.fetch(request);
    } catch (e) {
      if (e instanceof Error && e.message.includes("not found")) {
        return new Response("Tenant not found", { status: 404 });
      }
      throw e;
    }
  },
};
```

```toml
# wrangler.toml for dispatch worker
[[dispatch_namespaces]]
binding = "DISPATCHER"
namespace = "my-platform"
```

```bash
# Upload tenant script
npx wrangler dispatch-namespace script upload my-platform tenant-1 --module tenant-script.js
# List tenant scripts
npx wrangler dispatch-namespace script list my-platform
```

---

## Smart Placement

Let Cloudflare auto-place your Worker near its backend to reduce latency:

```toml
# wrangler.toml
[placement]
mode = "smart"
```

**When to use:**
- Worker makes multiple subrequests to a single backend (e.g., database, API).
- Backend is in a fixed location (e.g., us-east-1).
- Net latency reduction outweighs edge-to-user latency increase.

**When NOT to use:**
- Worker serves cached responses or uses KV/DO (already at the edge).
- Worker is CPU-bound (edge placement is fine).
- Multiple backends in different regions.

---

## Tail Workers

Observe and process logs from other Workers without impacting their performance:

```ts
// tail-worker.ts
interface TailEvent {
  scriptName: string;
  event: { request?: { url: string; method: string } };
  logs: { level: string; message: unknown[] }[];
  exceptions: { name: string; message: string }[];
  outcome: "ok" | "exception" | "exceededCpu" | "exceededMemory" | "canceled";
  eventTimestamp: number;
  diagnosticsChannelEvents: unknown[];
}

export default {
  async tail(events: TailEvent[], env: Env): Promise<void> {
    for (const event of events) {
      // Filter: only process errors and exceptions
      if (event.outcome !== "ok" || event.exceptions.length > 0) {
        await env.ERROR_QUEUE.send({
          worker: event.scriptName,
          url: event.event.request?.url,
          outcome: event.outcome,
          exceptions: event.exceptions,
          logs: event.logs.filter(l => l.level === "error"),
          timestamp: event.eventTimestamp,
        });
      }

      // Metrics: send all events to analytics
      await env.ANALYTICS.writeDataPoint({
        blobs: [event.scriptName, event.outcome],
        doubles: [event.logs.length, Date.now() - event.eventTimestamp],
        indexes: [event.scriptName],
      });
    }
  },
};
```

```toml
# wrangler.toml for the PRODUCER worker (the one being observed)
tail_consumers = [
  { service = "my-tail-worker" }
]

# wrangler.toml for the tail worker itself
name = "my-tail-worker"
main = "src/tail-worker.ts"
```

**Tail worker tips:**
- Tail workers receive batched events — not real-time per-request.
- They have their own CPU/memory limits — keep processing lightweight.
- Cannot modify the original Worker's response.
- Useful for: error tracking, audit logs, custom metrics, anomaly detection.
- Combine with Workers Analytics Engine for zero-cost observability.
