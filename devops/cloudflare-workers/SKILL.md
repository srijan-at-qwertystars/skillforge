---
name: cloudflare-workers
description: >
  Use when building, deploying, or debugging Cloudflare Workers, Pages Functions,
  or any code targeting the Workers runtime. Triggers on wrangler CLI usage,
  wrangler.toml/wrangler.json config, Workers KV, Durable Objects, D1, R2, Queues,
  Workers AI, cron triggers, email workers, service bindings, Hono on Workers, or
  Miniflare/vitest-pool-workers testing. Also triggers on edge compute, serverless
  edge functions on Cloudflare, or migration from other edge runtimes to Workers.
  Do NOT trigger for generic Node.js/Deno/Bun server code, AWS Lambda, Vercel
  Edge Functions, or Fastly Compute unless explicitly targeting Cloudflare.
---

# Cloudflare Workers

## Worker Formats

### ES Modules (default, required for Durable Objects/Queues/etc.)
```ts
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    ctx.waitUntil(logAsync(request)); // fire-and-forget background work
    return new Response("Hello");
  },
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(doWork());
  },
  async queue(batch: MessageBatch, env: Env, ctx: ExecutionContext) {
    for (const msg of batch.messages) { /* process */ msg.ack(); }
  },
  async email(message: EmailMessage, env: Env, ctx: ExecutionContext) {
    await message.forward("dest@example.com");
  },
};
```

### Service Worker Format (legacy — avoid for new projects)
```js
addEventListener("fetch", (event) => {
  event.respondWith(handleRequest(event.request));
});
```

## Wrangler CLI

```bash
# Project lifecycle
npx wrangler init my-worker          # scaffold project
npx wrangler dev                     # local dev server (uses Miniflare)
npx wrangler deploy                  # deploy to production
npx wrangler deploy --env staging    # deploy to named environment
npx wrangler tail                    # stream live logs

# Secrets
npx wrangler secret put API_KEY      # set secret (prompted for value)
npx wrangler secret list             # list secrets
npx wrangler secret delete API_KEY   # remove secret

# KV
npx wrangler kv namespace create MY_KV
npx wrangler kv key put --binding MY_KV "key" "value"

# D1
npx wrangler d1 create my-db
npx wrangler d1 execute my-db --local --file=./schema.sql
npx wrangler d1 migrations apply my-db

# R2
npx wrangler r2 bucket create my-bucket

# Pages
npx wrangler pages deploy ./dist --project-name my-site
```

## wrangler.toml Configuration

```toml
name = "my-worker"
main = "src/index.ts"
compatibility_date = "2024-09-01"
compatibility_flags = ["nodejs_compat"]

# Environment variables (non-sensitive only)
[vars]
API_HOST = "https://api.example.com"

# Named environment
[env.staging]
name = "my-worker-staging"
[env.staging.vars]
API_HOST = "https://staging-api.example.com"

# KV binding
[[kv_namespaces]]
binding = "CACHE"
id = "abc123"

# D1 binding
[[d1_databases]]
binding = "DB"
database_name = "my-db"
database_id = "def456"

# R2 binding
[[r2_buckets]]
binding = "BUCKET"
bucket_name = "my-bucket"

# Durable Objects
[[durable_objects.bindings]]
name = "COUNTER"
class_name = "CounterObject"

[[migrations]]
tag = "v1"
new_classes = ["CounterObject"]

# Queues
[[queues.producers]]
binding = "MY_QUEUE"
queue = "my-queue"

[[queues.consumers]]
queue = "my-queue"
max_batch_size = 10
max_batch_timeout = 5

# Cron triggers
[triggers]
crons = ["0 * * * *", "*/5 * * * *"]

# Service bindings
[[services]]
binding = "AUTH_SERVICE"
service = "auth-worker"

# Workers AI
[ai]
binding = "AI"
```

Use `.dev.vars` for local secrets (dotenv format). Never commit this file.

## Runtime APIs

```ts
// Request / Response / URL
const url = new URL(request.url);          // url.pathname, url.searchParams
const body = await request.json();         // .text(), .arrayBuffer(), .formData()
const ct = request.headers.get("Content-Type");
return new Response(JSON.stringify({ ok: true }), {
  status: 200, headers: { "Content-Type": "application/json" },
});
// Response.json({ ok: true }) also works (shorthand)
// Response.redirect(url, 301)

// Crypto
const key = await crypto.subtle.importKey(
  "raw", encodedKey, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
const uuid = crypto.randomUUID();

// Streams
const { readable, writable } = new TransformStream();
const writer = writable.getWriter();
ctx.waitUntil((async () => { await writer.write(encoder.encode("chunk")); await writer.close(); })());
return new Response(readable);
```

## KV Storage

```ts
await env.CACHE.put("key", "value", {
  expirationTtl: 3600, metadata: { version: 2 },  // or expiration: <unix timestamp>
});
const value = await env.CACHE.get("key");                    // string (default)
const json = await env.CACHE.get("key", { type: "json" });   // parsed JSON
const { value: v, metadata } = await env.CACHE.getWithMetadata("key");
await env.CACHE.delete("key");
const list = await env.CACHE.list({ prefix: "user:", limit: 100, cursor: prev });
// list.keys=[{name, expiration?, metadata?}], list.list_complete, list.cursor
```

KV is eventually consistent. Writes propagate globally within ~60s. Use for read-heavy, write-infrequent data.

## Durable Objects

```ts
export class CounterObject extends DurableObject {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.count = (await ctx.storage.get<number>("count")) ?? 0;
    });
  }
  async fetch(request: Request): Promise<Response> {
    this.count++;
    await this.ctx.storage.put("count", this.count);
    return new Response(String(this.count));
  }
  // Alarms — schedule future execution
  async alarm(): Promise<void> { await this.cleanup(); }
  async scheduleAlarm() { await this.ctx.storage.setAlarm(Date.now() + 60_000); }
}
// Access from Worker
const id = env.COUNTER.idFromName("my-counter");
const stub = env.COUNTER.get(id);
const resp = await stub.fetch("https://dummy/increment");
```

### WebSocket Hibernation (scalable pub/sub)
```ts
export class ChatRoom extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }
  async webSocketMessage(ws: WebSocket, msg: string) {
    for (const c of this.ctx.getWebSockets()) c.send(msg);
  }
  async webSocketClose(ws: WebSocket) { /* cleanup */ }
}
```

## D1 Database

```ts
const { results } = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(userId).all();
const user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(userId).first();
await env.DB.prepare("INSERT INTO users (name, email) VALUES (?, ?)").bind("Alice", "a@b.com").run();
// Batch = implicit transaction (all-or-nothing)
await env.DB.batch([
  env.DB.prepare("INSERT INTO users (name) VALUES (?)").bind("Bob"),
  env.DB.prepare("INSERT INTO logs (action) VALUES (?)").bind("user_created"),
]);
// Migrations: wrangler d1 migrations create my-db "add_users"
// Apply: wrangler d1 migrations apply my-db
```

## R2 Object Storage

```ts
// Put with metadata
await env.BUCKET.put("images/photo.jpg", imageBody, {
  httpMetadata: { contentType: "image/jpeg" },
  customMetadata: { uploadedBy: "user-1" },
});
// Get
const obj = await env.BUCKET.get("images/photo.jpg");
if (obj) return new Response(obj.body, {
  headers: { "Content-Type": obj.httpMetadata?.contentType ?? "" },
});
// Head / Delete / List
const head = await env.BUCKET.head("images/photo.jpg");
await env.BUCKET.delete("images/photo.jpg");
const listed = await env.BUCKET.list({ prefix: "images/", limit: 100 });
// Multipart upload
const upload = await env.BUCKET.createMultipartUpload("large.zip");
const p1 = await upload.uploadPart(1, chunk1);
const p2 = await upload.uploadPart(2, chunk2);
await upload.complete([p1, p2]);
```

## Queues

```ts
// Producer
await env.MY_QUEUE.send({ userId: 123, action: "welcome_email" });
await env.MY_QUEUE.sendBatch([{ body: { task: "a" } }, { body: { task: "b" } }]);
// Consumer
export default {
  async queue(batch: MessageBatch<any>, env: Env) {
    for (const msg of batch.messages) {
      try { await processMessage(msg.body); msg.ack(); }
      catch { msg.retry({ delaySeconds: 30 }); }
    }
  },
};
```

Configure dead letter queue in wrangler.toml:
```toml
[[queues.consumers]]
queue = "my-queue"
dead_letter_queue = "my-dlq"
max_retries = 3
```

## Workers AI

```ts
// Text generation
const resp = await env.AI.run("@cf/meta/llama-3-8b-instruct", {
  messages: [{ role: "system", content: "You are helpful." }, { role: "user", content: "Explain edge computing." }],
});  // resp.response = "Edge computing is..."
// Streaming
const stream = await env.AI.run("@cf/meta/llama-3-8b-instruct", {
  messages: [{ role: "user", content: "Tell me a story." }], stream: true,
});
return new Response(stream, { headers: { "content-type": "text/event-stream" } });
// Embeddings
const emb = await env.AI.run("@cf/baai/bge-base-en-v1.5", {
  text: ["Cloudflare Workers run at the edge"],
});  // emb.data = [[0.012, -0.034, ...]]
```

## Cron Triggers

```ts
export default {
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    switch (event.cron) {
      case "0 * * * *":   await env.DB.prepare("DELETE FROM sessions WHERE expires < ?").bind(Date.now()).run(); break;
      case "0 0 * * *":   ctx.waitUntil(generateReport(env)); break;
    }
  },
};
```
Configure: `[triggers] crons = ["0 * * * *", "0 0 * * *"]` in wrangler.toml.

## Email Workers

```ts
export default {
  async email(message: EmailMessage, env: Env, ctx: ExecutionContext) {
    if (message.from === "spam@example.com") { message.setReject("Rejected"); return; }
    const rawEmail = await new Response(message.raw).text();
    await message.forward("support@example.com");
  },
};
```
Requires Email Routing configured in Cloudflare dashboard.

## Service Bindings

```ts
// In calling worker — env.AUTH_SERVICE is bound to another worker
const authResp = await env.AUTH_SERVICE.fetch("https://auth/verify", {
  method: "POST",
  body: JSON.stringify({ token }),
});
// No network round-trip — direct in-process call
```

## Hono Framework Integration

```ts
import { Hono } from "hono";
import { cors } from "hono/cors";
import { bearerAuth } from "hono/bearer-auth";

type Bindings = { DB: D1Database; CACHE: KVNamespace; AI: Ai };
const app = new Hono<{ Bindings: Bindings }>();

// Middleware
app.use("/api/*", cors({ origin: "https://example.com" }));
app.use("/admin/*", bearerAuth({ token: "secret" }));

// Routes
app.get("/", (c) => c.text("OK"));
app.get("/users/:id", async (c) => {
  const user = await c.env.DB.prepare("SELECT * FROM users WHERE id = ?")
    .bind(c.req.param("id")).first();
  return user ? c.json(user) : c.notFound();
});

// Sub-router
const api = new Hono<{ Bindings: Bindings }>();
api.post("/ask", async (c) => {
  const { question } = await c.req.json();
  const answer = await c.env.AI.run("@cf/meta/llama-3-8b-instruct", {
    messages: [{ role: "user", content: question }],
  });
  return c.json(answer);
});
app.route("/api", api);

export default app;
```

## Middleware Patterns (vanilla)

```ts
// Rate limiting with KV
async function rateLimit(req: Request, env: Env): Promise<Response | null> {
  const ip = req.headers.get("CF-Connecting-IP") ?? "unknown";
  const cur = parseInt(await env.CACHE.get(`rl:${ip}`) ?? "0");
  if (cur >= 100) return new Response("Too Many Requests", { status: 429 });
  await env.CACHE.put(`rl:${ip}`, String(cur + 1), { expirationTtl: 60 });
  return null;
}
// CORS preflight + headers
function handleCors(req: Request, resp: Response): Response {
  const headers = new Headers(resp.headers);
  headers.set("Access-Control-Allow-Origin", "*");
  headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  headers.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  if (req.method === "OPTIONS") return new Response(null, { headers });
  return new Response(resp.body, { ...resp, headers });
}
```

## Testing

### vitest-pool-workers (recommended)
```bash
npm install -D vitest @cloudflare/vitest-pool-workers
```
```ts
// vitest.config.ts
import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";
export default defineWorkersProject({
  test: { poolOptions: { workers: { wrangler: { configPath: "./wrangler.toml" } } } },
});
```
```ts
// test/index.test.ts
import { env, createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker from "../src/index";

describe("Worker", () => {
  it("returns 200", async () => {
    const req = new Request("https://example.com/");
    const ctx = createExecutionContext();
    const resp = await worker.fetch(req, env, ctx);
    await waitOnExecutionContext(ctx);
    expect(resp.status).toBe(200);
  });
});
```

### Hono testing shorthand
```ts
import { env } from "cloudflare:test";
import app from "../src/index";
it("GET /users/:id", async () => {
  const res = await app.request("/users/1", {}, env);
  expect(res.status).toBe(200);
});
```

## Common Gotchas

| Constraint | Free | Paid |
|---|---|---|
| CPU time / request | 10ms | 30s (up to 5min Unbound) |
| Memory | 128MB | 128MB |
| Script size (compressed) | 3MB | 10MB |
| Subrequests / request | 50 | 10,000 |
| Concurrent connections | 6 | 6 |
| KV value max size | 25MB | 25MB |
| Env variables | 64 | 128 |
| Cron triggers / worker | 5 | 250 |

**Critical rules:**
- CPU time ≠ wall time. Async I/O waiting does NOT count. Only active JS execution counts.
- No native Node.js APIs (fs, net, child_process). Enable `nodejs_compat` flag for polyfills of crypto, Buffer, util, assert, streams.
- Global variables do NOT persist reliably across requests — use KV/DO/D1 for state.
- `wrangler dev` (Miniflare) does NOT enforce subrequest limits — test in production with `--remote`.
- R2/KV/D1 bindings are NOT inherited by environments — redeclare in each `[env.X]` section.
- Always set `compatibility_date` to lock runtime behavior. Update deliberately.
- Use `ctx.waitUntil()` for background work — the response returns immediately but the promise keeps running.
- Durable Objects are single-threaded — design sharding for high-throughput scenarios.
- D1 `batch()` runs in a transaction — if any statement fails, all roll back.
- Secrets: use `wrangler secret put`, store local dev secrets in `.dev.vars`, never in `wrangler.toml`.

## Reference Docs

Deep-dive guides in `references/`:

| File | Topics |
|------|--------|
| [advanced-patterns.md](references/advanced-patterns.md) | DO actor model, WebSocket rooms, distributed locks, rate limiting, D1 migrations/schema, R2 multipart/presigned URLs, Queue retry/DLQ/fan-out, Service Bindings composition, Hyperdrive, Workers for Platforms, smart placement, tail workers |
| [troubleshooting.md](references/troubleshooting.md) | CPU time exceeded, memory limits, subrequest limits (50/req), KV eventual consistency, DO billing surprises, D1 row limits, wrangler deploy errors, Miniflare vs production, CORS headers, wrangler tail debugging |
| [hono-integration.md](references/hono-integration.md) | Hono routing, middleware, Zod validation, OpenAPI generation, RPC type-safe client, JWT auth, rate limiting, error handling, `app.request()` testing, monorepo patterns |

## Scripts

Executable helpers in `scripts/` (bash, `chmod +x`):

| Script | Purpose |
|--------|---------|
| [init-worker.sh](scripts/init-worker.sh) | Scaffold new Worker: npm init, wrangler.toml with selected bindings (KV/D1/R2/DO/Queue), typed Env, vitest config, optional Hono setup |
| [deploy-worker.sh](scripts/deploy-worker.sh) | Deploy workflow: lint → test → build → staging → smoke test → production. Includes `--rollback` and `--dry-run` |
| [migrate-d1.sh](scripts/migrate-d1.sh) | D1 migration helper: create, apply-local, apply-remote, list, schema, status, seed, reset-local, backup |

## Assets (Copy-Paste Templates)

Ready-to-use templates in `assets/`:

| File | Description |
|------|-------------|
| [wrangler-template.toml](assets/wrangler-template.toml) | Production wrangler.toml with all binding types, staging/production envs, routes, compatibility flags |
| [hono-app.ts](assets/hono-app.ts) | Hono app with typed bindings, middleware chain, CORS, error handling, Zod validation, CRUD routes |
| [durable-object.ts](assets/durable-object.ts) | Durable Object with WebSocket hibernation, tag-based user tracking, alarms, state management |
| [vitest-config.ts](assets/vitest-config.ts) | Vitest config for `@cloudflare/vitest-pool-workers` with mock bindings, coverage thresholds, test helpers |
| [github-actions.yml](assets/github-actions.yml) | CI/CD: lint, test, deploy staging on push, production on release, smoke tests, PR preview |
<!-- tested: pass -->
