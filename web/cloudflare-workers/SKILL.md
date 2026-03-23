---
name: cloudflare-workers
description:
  positive: "Use when user builds on Cloudflare Workers, asks about Wrangler, KV namespace, R2 storage, D1 database, Durable Objects, Workers AI, or edge computing with Cloudflare."
  negative: "Do NOT use for AWS Lambda (use aws-lambda-patterns skill), Vercel Edge Functions, or Deno Deploy without Cloudflare context."
---

# Cloudflare Workers Skill

## Workers Fundamentals

Workers run on V8 isolates — lightweight sandboxes with sub-millisecond cold starts, single-threaded per request. No containers, no VMs. Always use module worker syntax:

```typescript
export interface Env {
  MY_KV: KVNamespace;
  MY_BUCKET: R2Bucket;
  DB: D1Database;
  API_KEY: string;
}
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return new Response("OK");
  },
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(doWork(env));
  },
  async queue(batch: MessageBatch<unknown>, env: Env, ctx: ExecutionContext): Promise<void> {
    for (const msg of batch.messages) { await processMessage(msg); msg.ack(); }
  },
};
```

- Use `ctx.waitUntil()` for post-response work (logging, cache writes).
- Never rely on global mutable state across requests — isolates are ephemeral.
- Place expensive immutable setup (compiled regexes, parsed config) in module scope.
- Generate typed env with `npx wrangler types` — never hand-write `Env`.

## Wrangler

```bash
npm create cloudflare@latest my-app    # scaffold project
npx wrangler dev                        # local dev (port 8787)
npx wrangler dev --remote               # dev against real bindings
npx wrangler deploy                     # deploy to production
npx wrangler deploy --env staging       # deploy named environment
npx wrangler secret put API_KEY         # set encrypted secret
npx wrangler tail                       # stream live logs
npx wrangler types                      # generate Env types
```

### wrangler.toml

```toml
name = "my-worker"
main = "src/index.ts"
compatibility_date = "2025-03-21"
compatibility_flags = ["nodejs_compat"]

[vars]
API_BASE = "https://api.example.com"

[[kv_namespaces]]
binding = "CACHE"
id = "abc123"

[[r2_buckets]]
binding = "ASSETS"
bucket_name = "my-assets"

[[d1_databases]]
binding = "DB"
database_name = "my-db"
database_id = "def456"

[placement]
mode = "smart"

[env.staging]
name = "my-worker-staging"
vars = { API_BASE = "https://staging-api.example.com" }
routes = [{ pattern = "staging.example.com/*", zone_name = "example.com" }]
```

- Update `compatibility_date` regularly for new runtime behavior.
- Enable `nodejs_compat` for Node built-ins (crypto, buffer, streams).
- Never put secrets in config — use `wrangler secret put`.
- Bindings must be repeated per environment if overridden.

## Request/Response Handling

```typescript
async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  const contentType = request.headers.get("Content-Type") ?? "";
  const cfData = request.cf; // country, colo, tlsVersion, ASN, bot score

  if (contentType.includes("application/json")) {
    const body = await request.json<{ name: string }>();
  }

  // Streaming response
  const { readable, writable } = new TransformStream();
  ctx.waitUntil(streamData(writable));
  return new Response(readable, { headers: { "Content-Type": "text/event-stream" } });
}
```

- Clone requests before reading body: `request.clone()`.
- Use `Response.json({ ok: true })` for JSON responses.
- Access geo/network info via `request.cf`.

## Routing

Use Hono for projects with more than 3-4 routes:

```typescript
import { Hono } from "hono";
import { cors } from "hono/cors";

type Bindings = { DB: D1Database; CACHE: KVNamespace };
const app = new Hono<{ Bindings: Bindings }>();
app.use("*", cors());

app.get("/users/:id", async (c) => {
  const result = await c.env.DB.prepare("SELECT * FROM users WHERE id = ?")
    .bind(c.req.param("id")).first();
  return result ? c.json(result) : c.json({ error: "Not found" }, 404);
});

app.post("/users", async (c) => {
  const { name, email } = await c.req.json<{ name: string; email: string }>();
  await c.env.DB.prepare("INSERT INTO users (name, email) VALUES (?, ?)").bind(name, email).run();
  return c.json({ created: true }, 201);
});

export default app;
```

Hono provides middleware, typed bindings, and validator support. Alternative: itty-router for minimal footprint.

## KV Namespace

Eventually consistent, globally replicated. Optimized for high-read, low-write.

```typescript
// Write with TTL and metadata
await env.CACHE.put("user:123", JSON.stringify(data), {
  expirationTtl: 3600, metadata: { version: "v2" },
});

// Read (auto-parse JSON, text, or arrayBuffer)
const value = await env.CACHE.get("user:123", "json");
const { value: v, metadata } = await env.CACHE.getWithMetadata<User>("user:123", "json");

// Delete
await env.CACHE.delete("user:123");

// List with prefix and cursor pagination
const list = await env.CACHE.list({ prefix: "user:", limit: 100, cursor });
```

- Writes propagate globally in ~60s. Never depend on read-after-write consistency.
- Max value: 25 MiB. Max key: 512 bytes. Use R2 for large objects.
- Use metadata for lightweight indexing without reading values.

## R2 Object Storage

S3-compatible, zero egress fees.

```typescript
await env.ASSETS.put("images/photo.jpg", imageData, {
  httpMetadata: { contentType: "image/jpeg" },
  customMetadata: { uploadedBy: "user-123" },
});

const object = await env.ASSETS.get("images/photo.jpg");
if (object) {
  return new Response(object.body, {
    headers: { "Content-Type": object.httpMetadata?.contentType ?? "application/octet-stream" },
  });
}

const head = await env.ASSETS.head("images/photo.jpg");
const listed = await env.ASSETS.list({ prefix: "images/", limit: 50 });
await env.ASSETS.delete("images/photo.jpg");

// Multipart for large files (>100 MiB)
const upload = await env.ASSETS.createMultipartUpload("large.zip");
const p1 = await upload.uploadPart(1, chunk1);
const p2 = await upload.uploadPart(2, chunk2);
await upload.complete([p1, p2]);
```

- Max object: 5 TiB. Set `contentType` on upload — R2 does not auto-detect.
- Use presigned URLs for direct client uploads/downloads bypassing the Worker.

## D1 Database

SQLite-based serverless database with read replicas.

```typescript
const user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(userId).first<User>();

const result = await env.DB.prepare("INSERT INTO users (name, email) VALUES (?, ?)")
  .bind(name, email).run();

// Batch = transaction
const results = await env.DB.batch([
  env.DB.prepare("INSERT INTO orders (user_id, total) VALUES (?, ?)").bind(userId, total),
  env.DB.prepare("UPDATE users SET order_count = order_count + 1 WHERE id = ?").bind(userId),
]);

const { results: rows } = await env.DB.prepare("SELECT * FROM users WHERE active = 1").all<User>();
```

```bash
npx wrangler d1 migrations create my-db create-users-table
npx wrangler d1 migrations apply my-db           # production
npx wrangler d1 migrations apply my-db --local    # local dev
```

- Always use `.bind()` — never interpolate SQL. Use `batch()` for transactions.
- Max DB: 10 GB. Reads via replicas globally; writes route to primary.

## Durable Objects

Single-threaded, globally unique objects for strong consistency.

```typescript
export class RateLimiter implements DurableObject {
  private requests: number[] = [];
  constructor(private state: DurableObjectState, private env: Env) {}

  async fetch(request: Request): Promise<Response> {
    const now = Date.now();
    this.requests = this.requests.filter((t) => t > now - 60_000);
    if (this.requests.length >= 100) return new Response("Rate limited", { status: 429 });
    this.requests.push(now);
    return new Response("OK");
  }

  async alarm(): Promise<void> {
    await this.cleanup();
    await this.state.storage.setAlarm(Date.now() + 60_000);
  }
}

// Invoke from Worker
const id = env.RATE_LIMITER.idFromName(request.headers.get("CF-Connecting-IP")!);
const stub = env.RATE_LIMITER.get(id);
return stub.fetch(request);
```

```toml
[[durable_objects.bindings]]
name = "RATE_LIMITER"
class_name = "RateLimiter"

[[migrations]]
tag = "v1"
new_classes = ["RateLimiter"]
```

- Requests serialize automatically per instance. Use `state.storage` for persistence.
- Use in-memory fields for transient state, alarms for scheduled work.
- Use `idFromName()` for deterministic routing. Use cases: rate limiting, WebSocket rooms, locks, counters.

## Queues

```typescript
// Producer
await env.MY_QUEUE.send({ userId: "123", action: "process" });
await env.MY_QUEUE.sendBatch([{ body: { task: "a" } }, { body: { task: "b" } }]);

// Consumer
async queue(batch: MessageBatch<{ userId: string }>, env: Env): Promise<void> {
  for (const msg of batch.messages) {
    try { await processTask(msg.body, env); msg.ack(); }
    catch { msg.retry({ delaySeconds: 30 }); }
  }
}
```

```toml
[[queues.producers]]
binding = "MY_QUEUE"
queue = "my-queue"

[[queues.consumers]]
queue = "my-queue"
max_batch_size = 10
max_batch_timeout = 5
max_retries = 3
dead_letter_queue = "my-dlq"
```

- Always configure a dead letter queue. Acknowledge messages explicitly.
- Use for decoupled work: email, webhooks, batch processing.

## Workers AI

```typescript
// Text generation (streaming)
const response = await env.AI.run("@cf/meta/llama-3.1-8b-instruct", {
  messages: [
    { role: "system", content: "You are a helpful assistant." },
    { role: "user", content: userPrompt },
  ],
  max_tokens: 512, stream: true,
});
return new Response(response, { headers: { "Content-Type": "text/event-stream" } });

// Embeddings
const embeddings = await env.AI.run("@cf/baai/bge-base-en-v1.5", { text: ["chunk1", "chunk2"] });
```

RAG with Vectorize:
```typescript
const queryEmbed = await env.AI.run("@cf/baai/bge-base-en-v1.5", { text: [userQuery] });
const matches = await env.VECTORIZE.query(queryEmbed.data[0], { topK: 5 });
const context = await Promise.all(matches.matches.map((m) => env.DOCS_KV.get(m.id)));
const answer = await env.AI.run("@cf/meta/llama-3.1-8b-instruct", {
  messages: [
    { role: "system", content: `Answer using context:\n${context.join("\n")}` },
    { role: "user", content: userQuery },
  ],
});
```

- Always stream LLM responses to avoid timeout. Use AI Gateway for rate limiting and observability.
- Choose quantized models (INT4/FP8) for latency-sensitive paths. Configure: `[ai] binding = "AI"`.

## Caching

```typescript
const cache = caches.default;

async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const cacheKey = new Request(request.url, request);
  let response = await cache.match(cacheKey);
  if (response) return response;

  response = await fetch(request);
  response = new Response(response.body, response);
  response.headers.set("Cache-Control", "s-maxage=3600, stale-while-revalidate=300");
  ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return response;
}
```

- Use `s-maxage` for CDN-only TTL. Use `ctx.waitUntil()` for non-blocking cache writes.
- Implement stale-while-revalidate: serve cached, refresh in background via `ctx.waitUntil()`.
- Custom cache keys enable per-user or per-variant caching. Purge via API or dashboard.

## Environment Bindings

```toml
[vars]
APP_ENV = "production"

# wrangler secret put STRIPE_KEY

[[services]]
binding = "AUTH_SERVICE"
service = "auth-worker"
```

- Vars are visible in version control. Use `wrangler secret put` for credentials.
- Service bindings bypass the network for Worker-to-Worker calls.
- All bindings typed via `npx wrangler types`.

## Testing

```bash
npm install -D vitest @cloudflare/vitest-pool-workers
```

```typescript
// vitest.config.ts
import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";
export default defineWorkersProject({
  test: { poolOptions: { workers: { wrangler: { configPath: "./wrangler.toml" } } } },
});
```

```typescript
import { describe, it, expect } from "vitest";
import { SELF, fetchMock } from "cloudflare:test";

describe("Worker", () => {
  it("returns 200 on /health", async () => {
    const resp = await SELF.fetch("https://example.com/health");
    expect(resp.status).toBe(200);
  });

  it("mocks external API", async () => {
    fetchMock.activate();
    fetchMock.get("https://api.example.com").intercept({ path: "/data" }).reply(200, '{"ok":true}');
    const resp = await SELF.fetch("https://example.com/proxy");
    expect(resp.status).toBe(200);
    fetchMock.deactivate();
  });
});
```

- Tests run inside Workers runtime via Miniflare — high production fidelity.
- Match `compatibility_date` between test and production configs.
- Use `SELF.fetch()` for integration, direct imports for unit tests.

## Performance

| Limit          | Free          | Paid                  |
|----------------|---------------|-----------------------|
| CPU time       | 10 ms/req     | 30s (up to 5 min)     |
| Memory         | 128 MiB       | 128 MiB               |
| Subrequests    | 50 external   | 10,000 (configurable) |
| Script size    | 1 MiB         | 10 MiB                |

- Enable Smart Placement (`[placement] mode = "smart"`) to co-locate with backends.
- Stream responses — never buffer large bodies in memory.
- Defer non-critical work with `ctx.waitUntil()`.
- Batch D1 queries. Cache aggressively. Tree-shake dependencies.

## Anti-Patterns

- **Global scope blocking.** Never `await` request-dependent data at module level.
- **KV as a database.** KV is not ACID. Use D1 for relational data, DO for consistency.
- **Unhandled binding errors.** All KV/R2/D1/DO calls can throw — always wrap in try/catch.

```typescript
// BAD
const data = await env.CACHE.get("key", "json");
return Response.json(data);

// GOOD
try {
  const data = await env.CACHE.get("key", "json");
  if (!data) return Response.json({ error: "Not found" }, { status: 404 });
  return Response.json(data);
} catch { return Response.json({ error: "Storage error" }, { status: 500 }); }
```

- **Floating promises.** Always `await` or `ctx.waitUntil()`. Unhandled promises silently fail.
- **Mutable global state.** Isolates are ephemeral — use storage bindings for persistence.
- **Secrets in config/source.** Use `wrangler secret put`. Never commit `.dev.vars`.
- **Stale `compatibility_date`.** Update periodically to get fixes and new APIs.
- **Unstreamed LLM calls.** Workers AI without streaming risks CPU timeout.
- **D1 over-fetching.** Always use `WHERE` and `LIMIT` — D1 has row scan limits.
