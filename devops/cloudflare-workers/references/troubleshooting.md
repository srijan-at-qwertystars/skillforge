# Cloudflare Workers Troubleshooting

## Table of Contents

- [CPU Time Exceeded](#cpu-time-exceeded)
- [Memory Limits](#memory-limits)
- [Subrequest Limits](#subrequest-limits)
- [KV Eventual Consistency](#kv-eventual-consistency)
- [Durable Object Billing Surprises](#durable-object-billing-surprises)
- [D1 Row and Size Limits](#d1-row-and-size-limits)
- [Wrangler Deploy Errors](#wrangler-deploy-errors)
- [Local Dev vs Production (Miniflare)](#local-dev-vs-production-miniflare)
- [CORS in Workers](#cors-in-workers)
- [Debugging with wrangler tail](#debugging-with-wrangler-tail)

---

## CPU Time Exceeded

**Error:** `Error 1102: Worker exceeded CPU time limit`

CPU time is active JS execution only — async I/O waiting does NOT count. Limits: 10ms (free), 30s (paid Bundled), 5min (paid Unbound).

**Diagnosis:**
```bash
# Check CPU time per request
npx wrangler tail --format json | jq '.outcome, .cpuTime'
```

**Common causes and fixes:**

1. **JSON.parse/stringify on large payloads**
   ```ts
   // BAD: parsing a 5MB JSON blob eats CPU
   const data = JSON.parse(await response.text());
   // BETTER: stream and parse incrementally
   const stream = response.body!.pipeThrough(new TextDecoderStream());
   ```

2. **Regex on untrusted input (ReDoS)**
   ```ts
   // BAD: catastrophic backtracking
   const re = /^(a+)+$/;
   // GOOD: use simple patterns, set limits
   const re = /^a{1,100}$/;
   ```

3. **Synchronous crypto operations**
   ```ts
   // BAD: bcrypt in Worker (CPU-bound)
   // GOOD: use Web Crypto API (async, hardware-accelerated)
   const hash = await crypto.subtle.digest("SHA-256", data);
   ```

4. **Tight loops over large datasets**
   ```ts
   // BAD: sort 100K items in Worker
   // GOOD: paginate at the data source, push heavy compute to D1/DO
   const { results } = await env.DB.prepare(
     "SELECT * FROM items ORDER BY score DESC LIMIT 100"
   ).all();
   ```

5. **Move to Unbound usage model for heavy compute:**
   ```toml
   # wrangler.toml
   usage_model = "unbound"  # 400K GB-s free, then $12.50/M GB-s
   ```

---

## Memory Limits

**Error:** `Error 1102: Worker exceeded memory limit` (128MB for all plans)

**Common causes:**

1. **Accumulating response bodies in memory**
   ```ts
   // BAD: buffering entire response
   const body = await response.text(); // 50MB string in memory

   // GOOD: stream through
   return new Response(response.body, { headers: response.headers });
   ```

2. **Large module bundles**
   ```bash
   # Check bundle size
   npx wrangler deploy --dry-run --outdir dist
   ls -lh dist/
   # If >10MB, tree-shake dependencies
   ```

3. **Global caches that grow unbounded**
   ```ts
   // BAD: unbounded global cache
   const cache = new Map<string, Data>();

   // GOOD: use LRU or rely on KV/Cache API
   const cached = await caches.default.match(request);
   if (cached) return cached;
   ```

4. **TextDecoder accumulation on large streams**
   ```ts
   // Process chunks without accumulating
   const reader = response.body!.getReader();
   while (true) {
     const { done, value } = await reader.read();
     if (done) break;
     await processChunk(value); // Don't store, just process
   }
   ```

---

## Subrequest Limits

**Limit:** 50 subrequests/request (free), 1,000 (paid — increased from 50 on Bundled plans).

Subrequests include: `fetch()`, KV reads/writes, D1 queries, R2 operations, service binding calls.

**Error:** `Error 1101: Worker threw exception — Too many subrequests`

**Fixes:**

1. **Batch D1 queries**
   ```ts
   // BAD: N+1 queries
   for (const id of userIds) {
     await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(id).first();
   }

   // GOOD: single query with IN clause
   const placeholders = userIds.map(() => "?").join(",");
   const { results } = await env.DB.prepare(
     `SELECT * FROM users WHERE id IN (${placeholders})`
   ).bind(...userIds).all();
   ```

2. **Use D1 batch() for multi-statement operations**
   ```ts
   // BAD: 10 separate queries = 10 subrequests
   // GOOD: 1 batch = 1 subrequest
   await env.DB.batch([
     env.DB.prepare("INSERT INTO users (name) VALUES (?)").bind("Alice"),
     env.DB.prepare("INSERT INTO logs (action) VALUES (?)").bind("created"),
   ]);
   ```

3. **Cache upstream API responses**
   ```ts
   const cacheKey = new Request(apiUrl, { method: "GET" });
   const cached = await caches.default.match(cacheKey);
   if (cached) return cached;

   const resp = await fetch(apiUrl);
   const response = new Response(resp.body, resp);
   response.headers.set("Cache-Control", "s-maxage=300");
   ctx.waitUntil(caches.default.put(cacheKey, response.clone()));
   return response;
   ```

4. **Aggregate service binding calls**
   ```ts
   // BAD: 5 separate service calls
   // GOOD: batch endpoint in downstream service
   const resp = await env.DATA_SERVICE.fetch(
     new Request("https://svc/batch", {
       method: "POST",
       body: JSON.stringify({ ids: [1, 2, 3, 4, 5] }),
     })
   );
   ```

---

## KV Eventual Consistency

KV is eventually consistent — writes propagate globally within ~60 seconds. This causes subtle bugs.

**Symptoms:**
- User updates profile, refreshes, sees old data.
- Counter increments are lost under concurrent writes.
- Cache invalidation doesn't take effect immediately.

**Solutions:**

1. **Read-after-write in same colo:** KV is strongly consistent in the colo that performed the write. If the user is likely to read from the same colo, the read will see the latest value immediately.

2. **Use Cache-Control headers for staleness tolerance:**
   ```ts
   const value = await env.KV.get("key", { cacheTtl: 60 });
   // cacheTtl: seconds to cache at the edge. Lower = fresher but more origin reads.
   ```

3. **Switch to Durable Objects for strong consistency:**
   ```ts
   // DO storage is strongly consistent — use for counters, sessions, etc.
   const count = await this.ctx.storage.get<number>("count") ?? 0;
   await this.ctx.storage.put("count", count + 1); // Guaranteed read-your-writes
   ```

4. **Optimistic UI with server reconciliation:**
   ```ts
   // Return the written value directly in the response — don't re-read from KV
   await env.KV.put("user:123", JSON.stringify(updatedUser));
   return Response.json(updatedUser); // Use this, not a KV.get()
   ```

5. **Add version stamps for conflict detection:**
   ```ts
   const existing = await env.KV.get("doc:123", { type: "json" }) as Doc;
   if (existing.version !== expectedVersion) {
     return Response.json({ error: "conflict" }, { status: 409 });
   }
   await env.KV.put("doc:123", JSON.stringify({ ...update, version: expectedVersion + 1 }));
   ```

---

## Durable Object Billing Surprises

DO billing is based on **duration** (wall-clock time the DO is active), not just CPU time.

**Cost model:**
- $0.15/million requests
- $12.50/million GB-s (duration × memory)
- A DO is "active" from first request until 10-30s after the last request (or until alarm fires)
- WebSocket connections keep the DO active the entire time

**Common surprises:**

1. **WebSocket rooms that never sleep:** A chat room with 1 persistent connection keeps the DO alive 24/7.
   - **Fix:** Use WebSocket Hibernation API — `ctx.acceptWebSocket()` instead of manual `addEventListener`.
   - Hibernated DOs don't bill for duration between messages.

2. **Alarms that re-schedule indefinitely:**
   ```ts
   // BAD: alarm every second = DO never sleeps
   async alarm() {
     await this.doWork();
     await this.ctx.storage.setAlarm(Date.now() + 1000);
   }
   // GOOD: only schedule if there's actual work
   async alarm() {
     const pending = await this.ctx.storage.get<number>("pendingWork");
     if (pending && pending > 0) {
       await this.doWork();
       await this.ctx.storage.setAlarm(Date.now() + 60_000);
     }
   }
   ```

3. **Too many DO instances:** Each unique ID = separate billable instance.
   ```ts
   // BAD: per-request DO
   const id = env.RATE_LIMITER.idFromName(request.url);
   // GOOD: per-user or per-IP DO (bounded cardinality)
   const id = env.RATE_LIMITER.idFromName(userId);
   ```

4. **Storage costs:** $0.20/GB-month. `storage.list()` on large datasets is also billable per read.
   - Use `storage.deleteAll()` when resetting state.
   - Prune old data with scheduled alarms.

---

## D1 Row and Size Limits

| Limit | Value |
|-------|-------|
| Max database size | 10GB (paid), 500MB (free) |
| Max row size | 1MB |
| Max SQL statement size | 100KB |
| Max bound parameters | 100 |
| Max batch statements | 100 |
| Reads per day (free) | 5M |
| Writes per day (free) | 100K |
| Max databases (free) | 10 |
| Max databases (paid) | 50,000 |

**Common issues:**

1. **Row too large (>1MB):**
   ```ts
   // BAD: storing large blobs in D1
   await env.DB.prepare("INSERT INTO files (data) VALUES (?)").bind(largeBlob).run();
   // GOOD: store in R2, reference in D1
   await env.BUCKET.put(`files/${id}`, largeBlob);
   await env.DB.prepare("INSERT INTO files (r2_key) VALUES (?)").bind(`files/${id}`).run();
   ```

2. **Too many bound parameters (>100):**
   ```ts
   // BAD: IN clause with 200+ values
   // GOOD: chunk into batches
   const chunks = chunkArray(ids, 90);
   const results = [];
   for (const chunk of chunks) {
     const placeholders = chunk.map(() => "?").join(",");
     const { results: r } = await env.DB.prepare(
       `SELECT * FROM users WHERE id IN (${placeholders})`
     ).bind(...chunk).all();
     results.push(...r);
   }
   ```

3. **Slow queries without indexes:**
   ```bash
   # Check query plan
   npx wrangler d1 execute my-db --command "EXPLAIN QUERY PLAN SELECT * FROM users WHERE email = 'a@b.com'"
   # Add index if showing "SCAN TABLE"
   ```

---

## Wrangler Deploy Errors

### `Authentication error`
```bash
npx wrangler login              # Re-authenticate
npx wrangler whoami             # Verify identity
# Or use API token
export CLOUDFLARE_API_TOKEN="your-token"
```

### `Script too large` (>10MB compressed for paid, >3MB for free)
```bash
# Check compressed size
npx wrangler deploy --dry-run --outdir dist
gzip -k dist/index.js && ls -lh dist/index.js.gz
# Fix: tree-shake, externalize large deps, use KV for static assets
```

### `Binding not found`
Ensure wrangler.toml bindings match code. Common mistake: bindings not redeclared in environment sections.
```toml
# Must redeclare bindings in each environment
[env.staging]
name = "my-worker-staging"
[[env.staging.kv_namespaces]]
binding = "CACHE"
id = "staging-kv-id"
```

### `Compatibility date too old`
```toml
# Update to recent date for latest APIs
compatibility_date = "2024-09-23"
compatibility_flags = ["nodejs_compat"]
```

### `Migration error` (Durable Objects)
```toml
# Migrations must be append-only and ordered
[[migrations]]
tag = "v1"
new_classes = ["MyObject"]
[[migrations]]
tag = "v2"
renamed_classes = [{ from = "MyObject", to = "MyNewObject" }]
# NEVER remove or reorder existing migration entries
```

### `Could not resolve` build errors
```bash
# Common: importing Node.js-only modules
# Fix: use Workers-compatible alternatives or enable nodejs_compat
compatibility_flags = ["nodejs_compat"]
# Or alias in wrangler.toml
[alias]
"node:crypto" = "./src/crypto-polyfill.ts"
```

---

## Local Dev vs Production (Miniflare)

`wrangler dev` uses Miniflare (local Workers simulator). Key differences from production:

| Behavior | Miniflare (local) | Production |
|----------|-------------------|------------|
| Subrequest limit | NOT enforced | 50 (free) / 1,000 (paid) |
| CPU time limit | NOT enforced | 10ms / 30s / 5min |
| Memory limit | Node.js default (~4GB) | 128MB |
| KV consistency | Immediate | Eventually consistent (~60s) |
| DO location | Local | Nearest colo to first request |
| Cron triggers | Manual via `/__scheduled` | Automatic |
| Cache API | Local in-memory | Global CDN |
| `request.cf` object | Mocked/partial | Full CF properties |

**Testing with `--remote`:**
```bash
# Use remote resources (real KV, D1, R2) with local code
npx wrangler dev --remote
# Test cron triggers locally
curl "http://localhost:8787/__scheduled?cron=*+*+*+*+*"
```

**Catching production-only issues:**
```bash
# Test with real limits — deploy to staging
npx wrangler deploy --env staging
# Then run integration tests against staging URL
```

**Miniflare persistence (local state between restarts):**
```bash
# State persists in .wrangler/state/ by default
npx wrangler dev --persist-to .wrangler/state
# Clear local state
rm -rf .wrangler/state/
```

---

## CORS in Workers

### Complete CORS handler

```ts
const ALLOWED_ORIGINS = ["https://app.example.com", "https://staging.example.com"];

function corsHeaders(request: Request): Headers {
  const origin = request.headers.get("Origin") ?? "";
  const headers = new Headers();

  if (ALLOWED_ORIGINS.includes(origin)) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Vary", "Origin");
  }

  headers.set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
  headers.set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Request-Id");
  headers.set("Access-Control-Max-Age", "86400");
  headers.set("Access-Control-Allow-Credentials", "true");

  return headers;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Handle preflight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }

    // Handle actual request
    const response = await handleRequest(request, env);

    // Clone response to add CORS headers (Response may be immutable)
    const newHeaders = new Headers(response.headers);
    for (const [key, value] of corsHeaders(request)) {
      newHeaders.set(key, value);
    }

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: newHeaders,
    });
  },
};
```

**Common CORS mistakes:**
1. **Forgetting OPTIONS handler** — browser preflight fails, no error in Worker logs.
2. **Wildcard origin with credentials** — `Access-Control-Allow-Origin: *` does NOT work with `credentials: "include"`. Must echo the specific origin.
3. **Missing `Vary: Origin`** — CDN caches response for one origin, serves to another.
4. **Not including `Content-Type` in `Allow-Headers`** — POST with JSON body fails preflight.

---

## Debugging with wrangler tail

```bash
# Basic tail — stream live logs
npx wrangler tail

# JSON format for scripting
npx wrangler tail --format json

# Filter by status
npx wrangler tail --status error     # Only errors
npx wrangler tail --status ok        # Only successes

# Filter by method
npx wrangler tail --method POST

# Filter by search string (in logs)
npx wrangler tail --search "user-123"

# Filter by IP
npx wrangler tail --ip 203.0.113.50

# Tail a specific environment
npx wrangler tail --env staging

# Tail a Durable Object
npx wrangler tail --env production my-worker

# Pipe to jq for analysis
npx wrangler tail --format json | jq 'select(.outcome != "ok") | {url: .event.request.url, outcome, exceptions}'
```

**Structured logging for better tail output:**
```ts
function log(level: string, msg: string, data?: Record<string, unknown>) {
  console[level as "log" | "error" | "warn"](
    JSON.stringify({ level, msg, ...data, ts: Date.now() })
  );
}

// In your handler
log("info", "request received", { path: url.pathname, method: request.method });
log("error", "db query failed", { query: "SELECT...", error: String(err) });
```

**Production debugging checklist:**
1. `wrangler tail --status error` — see what's failing.
2. Check `outcome` field: `exceededCpu`, `exceededMemory`, `exception`, `canceled`.
3. Look at `exceptions` array for stack traces.
4. Add structured `console.log()` to narrow down the issue.
5. Test with `wrangler dev --remote` to reproduce with real bindings.
6. Check Cloudflare Dashboard → Workers → Analytics for error rate trends.
