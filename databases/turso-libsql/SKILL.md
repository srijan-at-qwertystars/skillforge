---
name: turso-libsql
description: >
  Build apps with Turso and libSQL — the edge-hosted, SQLite-compatible database platform. TRIGGER when: code imports `@libsql/client`, `libsql`, `go-libsql`, or `libsql` crate; user mentions Turso, libSQL, embedded replicas, sqld, or edge SQLite; turso CLI commands appear; user asks about database-per-tenant with SQLite; user wants vector search in SQLite. DO NOT TRIGGER when: user works with plain SQLite without Turso/libSQL; user uses Cloudflare D1, PlanetScale, Supabase, or other non-Turso databases; user works with PostgreSQL, MySQL, or MongoDB; general SQL questions not specific to libSQL extensions or Turso platform.
---

# Turso & libSQL

## Architecture

Turso is a managed edge database platform built on libSQL (open-source fork of SQLite). Core components:

- **Primary database**: Single writer, source of truth, hosted in one region.
- **Edge replicas** (legacy): Read-only copies at global edge locations. Deprecated for new users — use embedded replicas instead.
- **Embedded replicas**: Local SQLite file that syncs from a remote primary. All reads are local (sub-ms). Writes route to primary then sync back. Works offline.
- **sqld** (server-mode libSQL): Runs libSQL as a networked server, exposing HTTP/WebSocket endpoints. Powers Turso's managed service. Self-hostable.
- **Groups**: Logical containers for databases sharing the same primary location. All databases in a group share replication topology.

Data flow: App → embedded replica (local reads) → primary (writes) → sync back to replica.

## CLI Setup

Install:
```bash
# macOS
brew install tursodatabase/tap/turso
# Linux
curl -sSfL https://get.tur.so/install.sh | bash
```

Authenticate and create:
```bash
turso auth login                      # Browser-based GitHub auth
turso auth signup                     # New account
turso auth token                      # Print current auth token
turso auth api-tokens mint mytoken    # Create API token for CI/CD

turso db create myapp                 # Create database (auto-selects nearest region)
turso db create myapp --location lhr  # Create in London
turso db create myapp --group prod    # Create in existing group
turso db list                         # List all databases
turso db show myapp                   # Show URL, region, group info
turso db shell myapp                  # Interactive SQL shell
turso db shell myapp "SELECT 1"       # Run inline query
turso db destroy myapp                # Delete database
turso db inspect myapp                # Show storage, row counts, top tables
```

## Groups, Locations, Replicas

```bash
turso group create prod --location ord      # Create group in Chicago
turso group locations add prod lhr           # Add London replica location
turso group locations remove prod lhr        # Remove location
turso group list                             # List groups
turso group show prod                        # Show group details

turso db locations                           # List all available locations
turso db create myapp --group prod           # DB inherits group's locations
```

Groups share auth tokens — all databases in a group accept the same group token:
```bash
turso group tokens create prod               # Create group-level auth token
turso db tokens create myapp                 # Create database-level auth token
```

## Client SDKs

### TypeScript / JavaScript

```bash
npm install @libsql/client
```

**Remote connection** (direct to Turso):
```typescript
import { createClient } from "@libsql/client";

const client = createClient({
  url: "libsql://myapp-myorg.turso.io",
  authToken: process.env.TURSO_AUTH_TOKEN,
});

const rs = await client.execute("SELECT * FROM users WHERE id = ?", [42]);
// rs.rows = [{ id: 42, name: "Alice", email: "alice@example.com" }]
// rs.columns = ["id", "name", "email"]
// rs.rowsAffected = 0
```

**Embedded replica** (local reads, remote writes):
```typescript
import { createClient } from "@libsql/client";

const client = createClient({
  url: "file:local.db",
  syncUrl: "libsql://myapp-myorg.turso.io",
  authToken: process.env.TURSO_AUTH_TOKEN,
  syncInterval: 60,  // seconds — auto-sync period
});

await client.sync();  // Manual sync
const rs = await client.execute("SELECT * FROM users");  // Reads from local file
```

**Local file only** (dev/testing):
```typescript
const client = createClient({ url: "file:dev.db" });
```

### Python

```bash
pip install libsql-experimental
```

```python
import libsql_experimental as libsql

# Remote
conn = libsql.connect("libsql://myapp-myorg.turso.io",
                       auth_token=os.environ["TURSO_AUTH_TOKEN"])

# Embedded replica
conn = libsql.connect("local.db",
                       sync_url=os.environ["TURSO_DATABASE_URL"],
                       auth_token=os.environ["TURSO_AUTH_TOKEN"])
conn.sync()

conn.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
conn.execute("INSERT INTO users (name) VALUES (?)", ["Alice"])
conn.commit()
rows = conn.execute("SELECT * FROM users").fetchall()
# [(1, 'Alice')]
```

### Rust

```toml
# Cargo.toml
[dependencies]
libsql = "0.6"
```

```rust
use libsql::Builder;

// Remote
let db = Builder::new_remote("libsql://myapp-myorg.turso.io".into(), token)
    .build().await?;

// Embedded replica
let db = Builder::new_remote_replica("local.db", "libsql://myapp-myorg.turso.io", token)
    .sync_interval(std::time::Duration::from_secs(60))
    .build().await?;

let conn = db.connect()?;
let rows = conn.query("SELECT * FROM users WHERE id = ?1", [42]).await?;
```

### Go

```go
import "github.com/tursodatabase/go-libsql"

// Embedded replica
connector, err := libsql.NewEmbeddedReplicaConnector("local.db",
    "libsql://myapp-myorg.turso.io",
    libsql.WithAuthToken(token),
    libsql.WithSyncInterval(time.Minute),
)
defer connector.Close()
db := sql.OpenDB(connector)
```

## Transactions and Batches

### Interactive Transactions (TypeScript)

```typescript
const tx = await client.transaction("write");
try {
  await tx.execute("INSERT INTO orders (user_id, total) VALUES (?, ?)", [1, 99.99]);
  const rs = await tx.execute("SELECT last_insert_rowid()");
  const orderId = rs.rows[0][0];
  await tx.execute("INSERT INTO order_items (order_id, product_id) VALUES (?, ?)", [orderId, 5]);
  await tx.commit();
} catch (e) {
  await tx.rollback();
  throw e;
}
```

### Batches (atomic, single round-trip)

```typescript
const results = await client.batch([
  { sql: "INSERT INTO users (name) VALUES (?)", args: ["Bob"] },
  { sql: "INSERT INTO users (name) VALUES (?)", args: ["Carol"] },
  { sql: "SELECT count(*) FROM users", args: [] },
], "write");
// results[2].rows[0][0] = new count
```

Batch mode options: `"write"` (deferred tx), `"read"` (read-only), `"deferred"`.

### Python Transactions

```python
with conn:
    conn.execute("INSERT INTO users (name) VALUES (?)", ["Bob"])
    conn.execute("INSERT INTO users (name) VALUES (?)", ["Carol"])
# Auto-commits on exit, rolls back on exception
```

## Schema Design

libSQL is SQLite-compatible. Use SQLite types and syntax:

```sql
CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  metadata TEXT  -- Store JSON as TEXT, query with json_extract()
);

-- Strict tables (enforce type checking — recommended)
CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  type TEXT NOT NULL,
  payload TEXT NOT NULL,
  ts REAL NOT NULL
) STRICT;

-- Indexes
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_events_type_ts ON events(type, ts);
```

Strict tables reject type mismatches at write time. Use them for production schemas.

## Vector Search

libSQL has native vector support. No extensions to load — built into Turso.

```sql
-- Create table with vector column (1536 dimensions for OpenAI embeddings)
CREATE TABLE documents (
  id INTEGER PRIMARY KEY,
  content TEXT NOT NULL,
  embedding F32_BLOB(1536)
);

-- Create vector index
CREATE INDEX idx_docs_embedding ON documents(libsql_vector_idx(embedding));

-- Insert with vector
INSERT INTO documents (content, embedding)
VALUES ('Hello world', vector('[0.1, 0.2, ...]'));

-- Similarity search (cosine distance, returns nearest 10)
SELECT id, content, distance
FROM vector_top_k('idx_docs_embedding', vector('[0.1, 0.2, ...]'), 10)
JOIN documents ON documents.rowid = id;
```

Supported types: `F32_BLOB(N)`, `F64_BLOB(N)`. Use `vector()` to convert JSON array to blob. Use `vector_extract()` to read back.

## Platform Integrations

### Vercel (Next.js)

Set env vars in Vercel dashboard: `TURSO_DATABASE_URL`, `TURSO_AUTH_TOKEN`. Use embedded replicas in serverless:
```typescript
// app/lib/turso.ts
import { createClient } from "@libsql/client";

export const turso = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});
```

### Cloudflare Workers

Use remote mode (no filesystem in Workers):
```typescript
import { createClient } from "@libsql/client/web";

export default {
  async fetch(request, env) {
    const client = createClient({
      url: env.TURSO_URL,
      authToken: env.TURSO_AUTH_TOKEN,
    });
    const rs = await client.execute("SELECT 1");
    return Response.json(rs.rows);
  },
};
```

Import from `@libsql/client/web` for Workers (uses `fetch` transport, no Node dependencies).

### Fly.io

Place Turso primary in same region as Fly app. Use embedded replicas for multi-region Fly deployments — each instance keeps a local `.db` file.

### Netlify

Same pattern as Vercel. Set env vars via Netlify UI. Use `@libsql/client` in serverless functions.

## Multi-Tenancy (Database-per-Tenant)

Turso supports 10,000+ databases per account. Provision one database per tenant:

```typescript
// Provision tenant DB (via Turso Platform API)
const res = await fetch("https://api.turso.tech/v1/organizations/myorg/databases", {
  method: "POST",
  headers: {
    Authorization: `Bearer ${TURSO_API_TOKEN}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    name: `tenant-${tenantId}`,
    group: "prod",
  }),
});

// Connect to tenant DB
function getTenantClient(tenantId: string) {
  return createClient({
    url: `libsql://tenant-${tenantId}-myorg.turso.io`,
    authToken: GROUP_AUTH_TOKEN,  // Group tokens work for all DBs in group
  });
}
```

Use group tokens to authenticate across all tenant databases. Run migrations per-tenant by iterating databases.

## Migration from SQLite

1. Dump existing SQLite: `sqlite3 old.db .dump > dump.sql`
2. Create Turso DB: `turso db create myapp`
3. Load dump: `turso db shell myapp < dump.sql`
4. Update connection code: replace `better-sqlite3` / `sqlite3` imports with `@libsql/client`

libSQL is a superset of SQLite — all SQLite SQL works. No schema changes needed.

## Authentication

- **Database tokens**: Scoped to single database. Created with `turso db tokens create <db>`.
- **Group tokens**: Scoped to all databases in a group. Created with `turso group tokens create <group>`.
- **API tokens**: For Turso Platform API. Created with `turso auth api-tokens mint <name>`.
- **Token expiration**: Add `--expiration 7d` to token creation commands.
- Tokens are JWTs. Pass as `authToken` in SDK clients.

```bash
turso db tokens create myapp --expiration 30d    # Expires in 30 days
turso db tokens create myapp --read-only         # Read-only token
```

## Monitoring and Usage

```bash
turso db inspect myapp          # Storage size, table-level breakdown
turso db inspect myapp --verbose # Row counts per table
turso org billing               # Current usage vs plan limits
turso plan show                 # Current plan details
```

Turso dashboard (turso.tech) shows: row reads/writes consumed, storage used, databases active.

## Pricing Considerations

| Plan   | Databases | Storage | Reads/mo   | Writes/mo | Price      |
|--------|-----------|---------|------------|-----------|------------|
| Free   | 100       | 5 GB    | 500M rows  | 10M rows  | $0         |
| Scaler | 500       | 9 GB    | 2.5B rows  | 25M rows  | ~$25/mo    |
| Pro    | 10,000    | 50 GB   | 250B rows  | 250M rows | ~$417/mo   |

Embedded replicas reduce row reads against Turso (local reads are free). Batch operations count as fewer row reads than individual queries. Overage pricing: ~$1/billion extra reads, ~$1/million extra writes.

## Common Pitfalls

- **Forgetting `client.sync()`**: Embedded replicas serve stale data until synced. Set `syncInterval` or call `sync()` after writes.
- **Using `@libsql/client` in Workers**: Import from `@libsql/client/web` — the default export requires Node APIs.
- **Write conflicts**: All writes go to the primary. Embedded replicas do not support local-only writes in production mode unless `offline: true` is set (experimental).
- **Large transactions**: SQLite/libSQL locks the entire database during writes. Keep write transactions short.
- **Not using batches**: Each `execute()` is a network round-trip in remote mode. Use `batch()` for multiple statements.
- **Token expiration**: Tokens expire silently. Monitor and rotate. Use group tokens when managing many databases.
- **Row read counting**: Each row scanned (not just returned) counts against quota. Add indexes to avoid full table scans.
- **Embedded replica file location**: Ensure the path is writable and persists across deployments (not `/tmp` on serverless).
- **Schema migrations**: No built-in migration tool. Use Drizzle ORM (`drizzle-kit push`) or run SQL files via `turso db shell`.

## Additional Resources

### Reference Guides (`references/`)

- **[advanced-patterns.md](references/advanced-patterns.md)** — Deep dive into embedded replicas (sync intervals, conflict resolution, offline-first), multi-tenancy patterns (database-per-tenant, schema-per-tenant, tenant routing), libSQL vector search (indexes, `vector_top_k`, distance functions, RAG pipelines), platform integration (Next.js, SvelteKit, Remix, Astro), edge functions (Cloudflare Workers, Vercel Edge, Deno Deploy), batch operations, schema migrations, and connection management.

- **[troubleshooting.md](references/troubleshooting.md)** — Connection timeouts and retry strategies, embedded replica sync failures and stale data, auth token expiration and rotation, storage limits and optimization, SQLite migration gotchas, platform-specific deployment issues (Vercel, Workers, Docker, Fly.io), and performance debugging with `turso db inspect` and `EXPLAIN QUERY PLAN`.

- **[sqlite-migration.md](references/sqlite-migration.md)** — Complete SQLite-to-Turso migration guide: compatibility matrix (what works, what doesn't, new libSQL features), connection string changes, ORM integration updates (Drizzle, Prisma, SQLAlchemy, Kysely), testing strategies (local SQLite vs Turso test DB, CI/CD), and data migration procedures (small DBs, large DBs, zero-downtime).

### Scripts (`scripts/`)

- **[setup-turso.sh](scripts/setup-turso.sh)** — Initialize a Turso project: authenticate, create group and database, generate auth token, print `.env` values. Usage: `./scripts/setup-turso.sh <db-name> [group] [location]`.

- **[db-management.sh](scripts/db-management.sh)** — Common Turso CLI operations: list, info, inspect, shell, replicate, unreplicate, destroy, token generation, usage stats. Usage: `./scripts/db-management.sh <command> [args]`.

- **[migrate-from-sqlite.sh](scripts/migrate-from-sqlite.sh)** — Migrate an existing SQLite database to Turso: validates source, creates Turso DB, imports data, verifies row counts. Usage: `./scripts/migrate-from-sqlite.sh <sqlite-file> <turso-db-name> [group]`.

### Asset Templates (`assets/`)

- **[typescript-client.ts](assets/typescript-client.ts)** — TypeScript client template with auto-detection of remote/replica/local mode, retry logic, sync helpers, and graceful shutdown.

- **[python-client.py](assets/python-client.py)** — Python client template with `libsql-experimental`, singleton connection, retry logic, and transaction context manager.

- **[drizzle-config.ts](assets/drizzle-config.ts)** — Drizzle ORM configuration for Turso with example schema and client setup.

- **[docker-compose.yml](assets/docker-compose.yml)** — Local `sqld` development setup. Run `docker compose up -d` for a local libSQL server on port 8080 — no Turso account required.

<!-- tested: needs-fix -->
