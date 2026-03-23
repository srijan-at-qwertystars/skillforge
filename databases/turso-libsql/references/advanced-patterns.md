# Advanced Turso & libSQL Patterns

## Table of Contents

- [Embedded Replicas Deep Dive](#embedded-replicas-deep-dive)
  - [Sync Intervals and Strategies](#sync-intervals-and-strategies)
  - [Conflict Resolution](#conflict-resolution)
  - [Offline-First Architecture](#offline-first-architecture)
- [Multi-Tenancy Patterns](#multi-tenancy-patterns)
  - [Database-per-Tenant](#database-per-tenant)
  - [Schema-per-Tenant](#schema-per-tenant)
  - [Tenant Routing and Connection Management](#tenant-routing-and-connection-management)
- [libSQL Vector Search](#libsql-vector-search)
  - [Vector Column Types](#vector-column-types)
  - [Creating Vector Indexes](#creating-vector-indexes)
  - [Querying with vector_top_k](#querying-with-vector_top_k)
  - [Distance Functions](#distance-functions)
  - [RAG Application Patterns](#rag-application-patterns)
- [Platform-Specific Integration Patterns](#platform-specific-integration-patterns)
  - [Next.js (App Router)](#nextjs-app-router)
  - [SvelteKit](#sveltekit)
  - [Remix](#remix)
  - [Astro](#astro)
- [Edge Function Integration](#edge-function-integration)
  - [Cloudflare Workers](#cloudflare-workers)
  - [Vercel Edge Functions](#vercel-edge-functions)
  - [Deno Deploy](#deno-deploy)
- [Batch Operations and Transactions](#batch-operations-and-transactions)
  - [Batch Execution Modes](#batch-execution-modes)
  - [Conditional Batches](#conditional-batches)
  - [Interactive vs Batch Transactions](#interactive-vs-batch-transactions)
- [Schema Migration Strategies](#schema-migration-strategies)
  - [Drizzle Kit Migrations](#drizzle-kit-migrations)
  - [Raw SQL Migrations](#raw-sql-migrations)
  - [Multi-Tenant Migrations](#multi-tenant-migrations)
- [Connection Pooling and Management](#connection-pooling-and-management)
  - [Client Lifecycle](#client-lifecycle)
  - [Singleton Pattern](#singleton-pattern)
  - [Graceful Shutdown](#graceful-shutdown)

---

## Embedded Replicas Deep Dive

### Sync Intervals and Strategies

Embedded replicas maintain a local SQLite file that syncs from the remote primary. Sync behavior is configurable:

```typescript
import { createClient } from "@libsql/client";

// Auto-sync every 30 seconds
const client = createClient({
  url: "file:local-replica.db",
  syncUrl: "libsql://myapp-myorg.turso.io",
  authToken: process.env.TURSO_AUTH_TOKEN,
  syncInterval: 30, // seconds
});

// Manual sync — call after writes or when freshness matters
await client.sync();
```

**Choosing sync intervals:**

| Use Case | Interval | Rationale |
|----------|----------|-----------|
| Real-time dashboard | 5–10s | Need near-live data |
| Content site / blog | 60–300s | Stale reads acceptable |
| Offline-first mobile | Manual only | Sync on reconnect |
| Read-heavy API | 15–30s | Balance freshness and cost |
| Write-then-read flows | Manual after write | Consistency guarantee |

**Sync cost**: Each sync pulls the WAL (write-ahead log) delta from the primary. Frequent syncs with heavy write loads increase bandwidth. Monitor with `turso db inspect`.

**Write path**: Writes from an embedded replica are forwarded to the primary over the network. The local replica does not reflect writes until the next sync completes.

```typescript
// Pattern: write-then-sync for read-your-writes consistency
await client.execute("INSERT INTO posts (title) VALUES (?)", ["New Post"]);
await client.sync(); // Now local reads see the new post
const posts = await client.execute("SELECT * FROM posts ORDER BY id DESC LIMIT 1");
```

### Conflict Resolution

libSQL embedded replicas use a single-writer model — the primary is the sole authority:

- **No write-write conflicts**: All writes route to the primary. The primary serializes them as SQLite normally does.
- **Stale read windows**: Between syncs, the local replica may serve stale data. This is eventual consistency, not a conflict.
- **Sync replaces local state**: On sync, the local file receives the primary's WAL frames. There is no merge — the primary always wins.

**If the primary rejects a write** (constraint violation, etc.), the error propagates back to the client immediately. The local replica is not modified.

**Concurrent write handling**:

```typescript
// Two clients writing to the same primary — primary serializes both
// Client A
await clientA.execute("UPDATE counters SET val = val + 1 WHERE id = 1");
// Client B (concurrent)
await clientB.execute("UPDATE counters SET val = val + 1 WHERE id = 1");
// Both succeed — SQLite's WAL mode serializes at the primary
```

### Offline-First Architecture

Embedded replicas can operate fully offline for reads:

```typescript
const client = createClient({
  url: "file:offline.db",
  syncUrl: "libsql://myapp-myorg.turso.io",
  authToken: process.env.TURSO_AUTH_TOKEN,
  // No syncInterval — manual sync only
});

// Initial sync to populate local database
try {
  await client.sync();
} catch (err) {
  console.warn("Offline — using cached data");
}

// Reads always work (from local file)
const results = await client.execute("SELECT * FROM products");

// Writes fail if offline (they must reach the primary)
try {
  await client.execute("INSERT INTO cart (product_id) VALUES (?)", [1]);
} catch (err) {
  // Queue write for later retry
  await queueOfflineWrite("INSERT INTO cart (product_id) VALUES (?)", [1]);
}
```

**Offline write queue pattern**:

```typescript
// Simple offline write queue using a local-only table
await client.execute(`
  CREATE TABLE IF NOT EXISTS _offline_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sql TEXT NOT NULL,
    args TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
  )
`);

async function queueOfflineWrite(sql: string, args: any[]) {
  await client.execute(
    "INSERT INTO _offline_queue (sql, args) VALUES (?, ?)",
    [sql, JSON.stringify(args)]
  );
}

async function flushOfflineQueue() {
  const queued = await client.execute(
    "SELECT * FROM _offline_queue ORDER BY id"
  );
  for (const row of queued.rows) {
    try {
      await client.execute(row.sql as string, JSON.parse(row.args as string));
      await client.execute("DELETE FROM _offline_queue WHERE id = ?", [row.id]);
    } catch (err) {
      console.error(`Failed to replay queued write ${row.id}:`, err);
      break; // Stop on first failure to preserve order
    }
  }
  await client.sync();
}
```

---

## Multi-Tenancy Patterns

### Database-per-Tenant

Turso supports 10,000+ databases per account, making database-per-tenant viable:

```typescript
import { createClient, type Client } from "@libsql/client";

const TURSO_ORG = "myorg";
const TURSO_API_TOKEN = process.env.TURSO_API_TOKEN!;
const GROUP_TOKEN = process.env.TURSO_GROUP_TOKEN!;

// Provision a new tenant database via Platform API
async function createTenantDb(tenantId: string): Promise<string> {
  const res = await fetch(
    `https://api.turso.tech/v1/organizations/${TURSO_ORG}/databases`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${TURSO_API_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        name: `tenant-${tenantId}`,
        group: "prod",
        schema: "schema-db", // Optional: use a schema database as template
      }),
    }
  );
  if (!res.ok) throw new Error(`Failed to create tenant DB: ${res.statusText}`);
  const data = await res.json();
  return data.database.Hostname;
}

// Get client for a specific tenant
function getTenantClient(tenantId: string): Client {
  return createClient({
    url: `libsql://tenant-${tenantId}-${TURSO_ORG}.turso.io`,
    authToken: GROUP_TOKEN,
  });
}

// Run migrations across all tenants
async function migrateAllTenants(migrationSql: string) {
  const res = await fetch(
    `https://api.turso.tech/v1/organizations/${TURSO_ORG}/databases`,
    {
      headers: { Authorization: `Bearer ${TURSO_API_TOKEN}` },
    }
  );
  const { databases } = await res.json();

  const results = await Promise.allSettled(
    databases
      .filter((db: any) => db.Name.startsWith("tenant-"))
      .map(async (db: any) => {
        const client = createClient({
          url: `libsql://${db.Hostname}`,
          authToken: GROUP_TOKEN,
        });
        await client.execute(migrationSql);
      })
  );

  const failed = results.filter((r) => r.status === "rejected");
  if (failed.length > 0) {
    console.error(`${failed.length} tenant migrations failed`);
  }
}
```

**Schema databases**: Use a schema database as a template. New databases created in the group inherit the schema:

```bash
# Create a schema database
turso db create schema-db --group prod --type schema

# Apply schema to template
turso db shell schema-db < schema.sql

# New tenant databases inherit the schema
turso db create tenant-acme --group prod --schema schema-db
```

### Schema-per-Tenant

Alternative approach using a single database with per-tenant table prefixes or SQLite's ATTACH:

```typescript
// Table prefix approach (simpler, single connection)
async function createTenantSchema(client: Client, tenantId: string) {
  const prefix = `t_${tenantId}`;
  await client.batch([
    { sql: `CREATE TABLE IF NOT EXISTS ${prefix}_users (id INTEGER PRIMARY KEY, name TEXT)`, args: [] },
    { sql: `CREATE TABLE IF NOT EXISTS ${prefix}_orders (id INTEGER PRIMARY KEY, user_id INTEGER)`, args: [] },
  ], "write");
}

// Query tenant data
async function getTenantUsers(client: Client, tenantId: string) {
  return client.execute(`SELECT * FROM t_${tenantId}_users`);
}
```

> **Warning**: Schema-per-tenant in a single database has scaling limits. Table count affects SQLite performance at ~10,000+ tables. Prefer database-per-tenant for large deployments.

### Tenant Routing and Connection Management

```typescript
// LRU cache for tenant clients
const clientCache = new Map<string, { client: Client; lastUsed: number }>();
const MAX_CACHED_CLIENTS = 100;

function getTenantClient(tenantId: string): Client {
  const cached = clientCache.get(tenantId);
  if (cached) {
    cached.lastUsed = Date.now();
    return cached.client;
  }

  // Evict oldest if at capacity
  if (clientCache.size >= MAX_CACHED_CLIENTS) {
    let oldestKey = "";
    let oldestTime = Infinity;
    for (const [key, val] of clientCache) {
      if (val.lastUsed < oldestTime) {
        oldestTime = val.lastUsed;
        oldestKey = key;
      }
    }
    clientCache.delete(oldestKey);
  }

  const client = createClient({
    url: `libsql://tenant-${tenantId}-myorg.turso.io`,
    authToken: process.env.TURSO_GROUP_TOKEN!,
  });

  clientCache.set(tenantId, { client, lastUsed: Date.now() });
  return client;
}
```

---

## libSQL Vector Search

### Vector Column Types

libSQL supports native vector columns without extensions:

```sql
-- F32_BLOB: 32-bit floating point vectors (recommended for most use cases)
CREATE TABLE embeddings (
  id INTEGER PRIMARY KEY,
  content TEXT NOT NULL,
  embedding F32_BLOB(1536)  -- 1536 dimensions (OpenAI ada-002)
);

-- F64_BLOB: 64-bit floating point vectors (higher precision, 2x storage)
CREATE TABLE precise_embeddings (
  id INTEGER PRIMARY KEY,
  embedding F64_BLOB(768)  -- 768 dimensions
);
```

**Dimension sizing by model:**

| Model | Dimensions | Recommended Type |
|-------|-----------|-----------------|
| OpenAI text-embedding-ada-002 | 1536 | F32_BLOB(1536) |
| OpenAI text-embedding-3-small | 1536 | F32_BLOB(1536) |
| OpenAI text-embedding-3-large | 3072 | F32_BLOB(3072) |
| Cohere embed-v3 | 1024 | F32_BLOB(1024) |
| BGE-small | 384 | F32_BLOB(384) |

### Creating Vector Indexes

```sql
-- Basic vector index
CREATE INDEX idx_emb ON embeddings(libsql_vector_idx(embedding));

-- Vector index with custom parameters
CREATE INDEX idx_emb_custom ON embeddings(
  libsql_vector_idx(embedding, 'metric=cosine', 'compress_neighbors=float8', 'max_neighbors=64')
);
```

**Index parameters:**
- `metric`: Distance metric — `cosine` (default), `l2`.
- `compress_neighbors`: Compression for neighbor vectors — `float8`, `float1bit`. Reduces index size.
- `max_neighbors`: Max edges per node in the HNSW graph. Higher = better recall, more storage.

### Querying with vector_top_k

```sql
-- Basic k-nearest-neighbor search
SELECT d.id, d.content, v.distance
FROM vector_top_k('idx_emb', vector('[0.1, 0.2, ...]'), 10) AS v
JOIN embeddings d ON d.rowid = v.id;

-- With additional filtering (filter AFTER vector search)
SELECT d.id, d.content, d.category, v.distance
FROM vector_top_k('idx_emb', vector('[0.1, 0.2, ...]'), 50) AS v
JOIN embeddings d ON d.rowid = v.id
WHERE d.category = 'technology'
LIMIT 10;
```

> **Important**: `vector_top_k` returns `id` (rowid) and `distance`. Always JOIN with the source table to get other columns. Filter predicates go on the JOIN, not inside `vector_top_k`.

### Distance Functions

```sql
-- Cosine distance between two vectors
SELECT vector_distance_cos(
  (SELECT embedding FROM embeddings WHERE id = 1),
  (SELECT embedding FROM embeddings WHERE id = 2)
) AS similarity;

-- Use in queries for pairwise comparison
SELECT a.id, b.id, vector_distance_cos(a.embedding, b.embedding) AS distance
FROM embeddings a, embeddings b
WHERE a.id < b.id AND a.id IN (1, 2, 3);
```

### RAG Application Patterns

```typescript
// Full RAG pipeline with Turso vector search
import { createClient } from "@libsql/client";
import OpenAI from "openai";

const db = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});
const openai = new OpenAI();

// Ingest: embed and store documents
async function ingestDocument(content: string, metadata: Record<string, string>) {
  const embeddingRes = await openai.embeddings.create({
    model: "text-embedding-3-small",
    input: content,
  });
  const vector = JSON.stringify(embeddingRes.data[0].embedding);

  await db.execute({
    sql: `INSERT INTO documents (content, metadata, embedding)
          VALUES (?, ?, vector(?))`,
    args: [content, JSON.stringify(metadata), vector],
  });
}

// Query: search and generate
async function ragQuery(question: string): Promise<string> {
  // 1. Embed the question
  const embeddingRes = await openai.embeddings.create({
    model: "text-embedding-3-small",
    input: question,
  });
  const queryVector = JSON.stringify(embeddingRes.data[0].embedding);

  // 2. Vector search for relevant documents
  const results = await db.execute({
    sql: `SELECT d.content, v.distance
          FROM vector_top_k('idx_docs_embedding', vector(?), 5) AS v
          JOIN documents d ON d.rowid = v.id`,
    args: [queryVector],
  });

  // 3. Build context and generate answer
  const context = results.rows.map((r) => r.content).join("\n\n");
  const completion = await openai.chat.completions.create({
    model: "gpt-4o",
    messages: [
      { role: "system", content: `Answer using this context:\n\n${context}` },
      { role: "user", content: question },
    ],
  });

  return completion.choices[0].message.content!;
}
```

---

## Platform-Specific Integration Patterns

### Next.js (App Router)

```typescript
// lib/turso.ts — Singleton client for Next.js
import { createClient, type Client } from "@libsql/client";

let client: Client | null = null;

export function getTurso(): Client {
  if (client) return client;

  // Server Components & Route Handlers
  client = createClient({
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  });

  return client;
}
```

```typescript
// app/users/page.tsx — Server Component with Turso
import { getTurso } from "@/lib/turso";

export const revalidate = 60; // ISR: revalidate every 60s

export default async function UsersPage() {
  const db = getTurso();
  const result = await db.execute("SELECT * FROM users ORDER BY created_at DESC");

  return (
    <ul>
      {result.rows.map((user) => (
        <li key={user.id as number}>{user.name as string}</li>
      ))}
    </ul>
  );
}
```

```typescript
// app/api/users/route.ts — Route Handler
import { getTurso } from "@/lib/turso";
import { NextResponse } from "next/server";

export async function GET() {
  const db = getTurso();
  const result = await db.execute("SELECT * FROM users");
  return NextResponse.json(result.rows);
}

export async function POST(req: Request) {
  const { name, email } = await req.json();
  const db = getTurso();
  const result = await db.execute({
    sql: "INSERT INTO users (name, email) VALUES (?, ?) RETURNING *",
    args: [name, email],
  });
  return NextResponse.json(result.rows[0], { status: 201 });
}
```

### SvelteKit

```typescript
// src/lib/server/turso.ts
import { createClient } from "@libsql/client";
import { TURSO_DATABASE_URL, TURSO_AUTH_TOKEN } from "$env/static/private";

export const db = createClient({
  url: TURSO_DATABASE_URL,
  authToken: TURSO_AUTH_TOKEN,
});
```

```typescript
// src/routes/users/+page.server.ts
import { db } from "$lib/server/turso";
import type { PageServerLoad } from "./$types";

export const load: PageServerLoad = async () => {
  const result = await db.execute("SELECT * FROM users");
  return { users: result.rows };
};

// src/routes/users/+page.server.ts — Form action
import type { Actions } from "./$types";

export const actions: Actions = {
  create: async ({ request }) => {
    const data = await request.formData();
    const name = data.get("name") as string;
    await db.execute({ sql: "INSERT INTO users (name) VALUES (?)", args: [name] });
    return { success: true };
  },
};
```

### Remix

```typescript
// app/utils/turso.server.ts
import { createClient } from "@libsql/client";

export const db = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});
```

```typescript
// app/routes/users.tsx
import { json, type LoaderFunctionArgs, type ActionFunctionArgs } from "@remix-run/node";
import { useLoaderData, Form } from "@remix-run/react";
import { db } from "~/utils/turso.server";

export async function loader({ request }: LoaderFunctionArgs) {
  const result = await db.execute("SELECT * FROM users");
  return json({ users: result.rows });
}

export async function action({ request }: ActionFunctionArgs) {
  const formData = await request.formData();
  const name = formData.get("name") as string;
  await db.execute({ sql: "INSERT INTO users (name) VALUES (?)", args: [name] });
  return json({ ok: true });
}

export default function Users() {
  const { users } = useLoaderData<typeof loader>();
  return (
    <div>
      <ul>{users.map((u: any) => <li key={u.id}>{u.name}</li>)}</ul>
      <Form method="post">
        <input name="name" required />
        <button type="submit">Add User</button>
      </Form>
    </div>
  );
}
```

### Astro

```typescript
// src/lib/turso.ts
import { createClient } from "@libsql/client";

export const db = createClient({
  url: import.meta.env.TURSO_DATABASE_URL,
  authToken: import.meta.env.TURSO_AUTH_TOKEN,
});
```

```astro
---
// src/pages/users.astro
import { db } from "../lib/turso";

const result = await db.execute("SELECT * FROM users ORDER BY name");
const users = result.rows;
---

<html>
  <body>
    <h1>Users</h1>
    <ul>
      {users.map((user) => <li>{user.name}</li>)}
    </ul>
  </body>
</html>
```

For Astro SSR with API endpoints:

```typescript
// src/pages/api/users.ts
import type { APIRoute } from "astro";
import { db } from "../../lib/turso";

export const GET: APIRoute = async () => {
  const result = await db.execute("SELECT * FROM users");
  return new Response(JSON.stringify(result.rows), {
    headers: { "Content-Type": "application/json" },
  });
};
```

---

## Edge Function Integration

### Cloudflare Workers

```typescript
// src/index.ts — Cloudflare Worker with Turso
import { createClient } from "@libsql/client/web";

interface Env {
  TURSO_URL: string;
  TURSO_AUTH_TOKEN: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const client = createClient({
      url: env.TURSO_URL,
      authToken: env.TURSO_AUTH_TOKEN,
    });

    const url = new URL(request.url);

    if (url.pathname === "/users" && request.method === "GET") {
      const result = await client.execute("SELECT * FROM users");
      return Response.json(result.rows);
    }

    if (url.pathname === "/users" && request.method === "POST") {
      const body = await request.json<{ name: string }>();
      const result = await client.batch([
        { sql: "INSERT INTO users (name) VALUES (?)", args: [body.name] },
        { sql: "SELECT last_insert_rowid() AS id", args: [] },
      ], "write");
      return Response.json({ id: result[1].rows[0].id }, { status: 201 });
    }

    return new Response("Not Found", { status: 404 });
  },
};
```

```toml
# wrangler.toml
name = "my-turso-worker"
main = "src/index.ts"
compatibility_date = "2024-01-01"

[vars]
TURSO_URL = "libsql://myapp-myorg.turso.io"

# Use wrangler secret for auth token:
# wrangler secret put TURSO_AUTH_TOKEN
```

> **Critical**: Always use `@libsql/client/web` in Workers — the default export requires Node.js APIs not available in the Workers runtime.

### Vercel Edge Functions

```typescript
// app/api/users/route.ts — Next.js Edge Runtime
import { createClient } from "@libsql/client/web";

export const runtime = "edge";

const db = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});

export async function GET() {
  const result = await db.execute("SELECT * FROM users");
  return Response.json(result.rows);
}
```

> **Note**: Use `@libsql/client/web` for Edge Runtime. The standard `@libsql/client` works in Node.js runtime (default for Next.js Route Handlers).

### Deno Deploy

```typescript
// main.ts — Deno Deploy with Turso
import { createClient } from "npm:@libsql/client/web";

const db = createClient({
  url: Deno.env.get("TURSO_DATABASE_URL")!,
  authToken: Deno.env.get("TURSO_AUTH_TOKEN"),
});

Deno.serve(async (req) => {
  const url = new URL(req.url);

  if (url.pathname === "/users") {
    const result = await db.execute("SELECT * FROM users");
    return new Response(JSON.stringify(result.rows), {
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response("Not Found", { status: 404 });
});
```

---

## Batch Operations and Transactions

### Batch Execution Modes

Batches execute multiple statements atomically in a single HTTP round-trip:

```typescript
// "write" mode — deferred transaction, allows reads and writes
const results = await client.batch([
  { sql: "INSERT INTO users (name) VALUES (?)", args: ["Alice"] },
  { sql: "INSERT INTO users (name) VALUES (?)", args: ["Bob"] },
  { sql: "SELECT count(*) as total FROM users", args: [] },
], "write");
// results[0].rowsAffected = 1
// results[1].rowsAffected = 1
// results[2].rows[0].total = new count

// "read" mode — read-only transaction, rejects writes
const readResults = await client.batch([
  { sql: "SELECT count(*) FROM users", args: [] },
  { sql: "SELECT count(*) FROM orders", args: [] },
], "read");

// "deferred" mode — starts as read, upgrades to write on first write statement
const deferredResults = await client.batch([
  { sql: "SELECT count(*) FROM users", args: [] },
  { sql: "INSERT INTO audit_log (action) VALUES (?)", args: ["counted_users"] },
], "deferred");
```

### Conditional Batches

Use batch results to drive subsequent statements:

```typescript
// Transfer funds — atomic check-and-update
const results = await client.batch([
  {
    sql: "UPDATE accounts SET balance = balance - ? WHERE id = ? AND balance >= ?",
    args: [100, fromAccountId, 100],
  },
  {
    sql: "UPDATE accounts SET balance = balance + ? WHERE id = ?",
    args: [100, toAccountId],
  },
], "write");

// Check if debit succeeded (rowsAffected = 0 means insufficient funds)
if (results[0].rowsAffected === 0) {
  throw new Error("Insufficient funds");
}
```

### Interactive vs Batch Transactions

**Batches**: Single round-trip, atomic. Cannot branch based on intermediate results within the batch. Best for independent or pre-determined statements.

**Interactive transactions**: Multiple round-trips, can read and branch. Use when logic depends on intermediate query results:

```typescript
// Interactive: read-then-write with business logic
const tx = await client.transaction("write");
try {
  const inventory = await tx.execute(
    "SELECT quantity FROM products WHERE id = ?", [productId]
  );

  if ((inventory.rows[0].quantity as number) < requestedQty) {
    await tx.rollback();
    throw new Error("Out of stock");
  }

  await tx.execute(
    "UPDATE products SET quantity = quantity - ? WHERE id = ?",
    [requestedQty, productId]
  );
  await tx.execute(
    "INSERT INTO orders (product_id, quantity) VALUES (?, ?)",
    [productId, requestedQty]
  );
  await tx.commit();
} catch (e) {
  await tx.rollback();
  throw e;
}
```

---

## Schema Migration Strategies

### Drizzle Kit Migrations

Drizzle ORM has first-class Turso support:

```typescript
// drizzle.config.ts
import type { Config } from "drizzle-kit";

export default {
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "turso",
  dbCredentials: {
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  },
} satisfies Config;
```

```bash
# Generate migration files from schema changes
npx drizzle-kit generate

# Apply migrations to remote database
npx drizzle-kit migrate

# Push schema directly (dev only — no migration files)
npx drizzle-kit push
```

### Raw SQL Migrations

For projects without an ORM, maintain numbered SQL files:

```
migrations/
  001_create_users.sql
  002_add_email_to_users.sql
  003_create_orders.sql
```

```typescript
// migrate.ts — Simple migration runner
import { createClient } from "@libsql/client";
import { readdirSync, readFileSync } from "fs";

const client = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});

async function migrate() {
  // Create migrations tracking table
  await client.execute(`
    CREATE TABLE IF NOT EXISTS _migrations (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      applied_at TEXT DEFAULT (datetime('now'))
    )
  `);

  const applied = await client.execute("SELECT name FROM _migrations");
  const appliedSet = new Set(applied.rows.map((r) => r.name));

  const files = readdirSync("./migrations")
    .filter((f) => f.endsWith(".sql"))
    .sort();

  for (const file of files) {
    if (appliedSet.has(file)) continue;

    const sql = readFileSync(`./migrations/${file}`, "utf-8");
    console.log(`Applying ${file}...`);

    await client.batch([
      { sql, args: [] },
      { sql: "INSERT INTO _migrations (name) VALUES (?)", args: [file] },
    ], "write");
  }

  console.log("Migrations complete");
}

migrate().catch(console.error);
```

### Multi-Tenant Migrations

When using database-per-tenant, run migrations against all tenant databases:

```typescript
async function migrateTenants(migrationSql: string) {
  const res = await fetch(
    `https://api.turso.tech/v1/organizations/${ORG}/databases`,
    { headers: { Authorization: `Bearer ${API_TOKEN}` } }
  );
  const { databases } = await res.json();

  const tenantDbs = databases.filter((db: any) => db.Name.startsWith("tenant-"));
  const batchSize = 10; // Limit concurrency

  for (let i = 0; i < tenantDbs.length; i += batchSize) {
    const batch = tenantDbs.slice(i, i + batchSize);
    await Promise.allSettled(
      batch.map(async (db: any) => {
        const client = createClient({
          url: `libsql://${db.Hostname}`,
          authToken: GROUP_TOKEN,
        });
        await client.execute(migrationSql);
        console.log(`Migrated ${db.Name}`);
      })
    );
  }
}
```

---

## Connection Pooling and Management

### Client Lifecycle

The `@libsql/client` manages connections internally. Key behaviors:

- **Remote mode**: Uses HTTP or WebSocket. Each `execute()` is a single HTTP request. No persistent connection pool.
- **Embedded replica**: Opens a local SQLite file. Single connection to the file, single WebSocket to the primary for syncs.
- **Client is lightweight**: Creating a client is cheap. Reuse when possible but don't over-optimize.

### Singleton Pattern

```typescript
// lib/db.ts — Module-level singleton (Node.js / Bun)
import { createClient, type Client } from "@libsql/client";

let _client: Client | undefined;

export function getDb(): Client {
  if (!_client) {
    _client = createClient({
      url: process.env.TURSO_DATABASE_URL!,
      authToken: process.env.TURSO_AUTH_TOKEN,
    });
  }
  return _client;
}
```

```typescript
// For serverless (Vercel, Netlify): client per request is fine
// Each invocation is isolated — no shared state
export async function handler(event: any) {
  const db = createClient({
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  });
  const result = await db.execute("SELECT 1");
  return { statusCode: 200, body: JSON.stringify(result.rows) };
}
```

### Graceful Shutdown

```typescript
import { createClient } from "@libsql/client";

const client = createClient({
  url: "file:local.db",
  syncUrl: "libsql://myapp-myorg.turso.io",
  authToken: process.env.TURSO_AUTH_TOKEN,
  syncInterval: 30,
});

// Ensure final sync and cleanup on shutdown
process.on("SIGTERM", async () => {
  console.log("Shutting down — final sync...");
  try {
    await client.sync();
  } catch (err) {
    console.error("Final sync failed:", err);
  }
  client.close();
  process.exit(0);
});

process.on("SIGINT", async () => {
  client.close();
  process.exit(0);
});
```
