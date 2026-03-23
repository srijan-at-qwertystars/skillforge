# Turso & libSQL Troubleshooting Guide

## Table of Contents

- [Connection Issues](#connection-issues)
  - [Connection Timeouts](#connection-timeouts)
  - [Retry Strategies](#retry-strategies)
  - [WebSocket vs HTTP Transport](#websocket-vs-http-transport)
- [Embedded Replica Issues](#embedded-replica-issues)
  - [Sync Failures](#sync-failures)
  - [Stale Data After Writes](#stale-data-after-writes)
  - [Replica File Corruption](#replica-file-corruption)
  - [Disk Space and File Location](#disk-space-and-file-location)
- [Authentication Issues](#authentication-issues)
  - [Token Expiration and Rotation](#token-expiration-and-rotation)
  - [Token Scope Mismatches](#token-scope-mismatches)
  - [API Token vs Database Token](#api-token-vs-database-token)
- [Database Size and Storage](#database-size-and-storage)
  - [Storage Limits by Plan](#storage-limits-by-plan)
  - [Identifying Large Tables](#identifying-large-tables)
  - [Storage Optimization](#storage-optimization)
  - [Row Read/Write Quotas](#row-readwrite-quotas)
- [Migration from SQLite Gotchas](#migration-from-sqlite-gotchas)
  - [Unsupported Features](#unsupported-features)
  - [Connection String Differences](#connection-string-differences)
  - [Driver Compatibility](#driver-compatibility)
- [Platform-Specific Deployment Issues](#platform-specific-deployment-issues)
  - [Vercel / Next.js](#vercel--nextjs)
  - [Cloudflare Workers](#cloudflare-workers)
  - [Docker / Containers](#docker--containers)
  - [Fly.io](#flyio)
- [Performance Debugging](#performance-debugging)
  - [Using turso db inspect](#using-turso-db-inspect)
  - [Slow Query Analysis](#slow-query-analysis)
  - [Index Optimization](#index-optimization)
  - [Batch vs Individual Queries](#batch-vs-individual-queries)

---

## Connection Issues

### Connection Timeouts

**Symptom**: `TURSO_CONNECTION_TIMEOUT` or `fetch failed` errors.

**Causes and fixes**:

1. **Wrong URL protocol**: Use `libsql://` for remote connections, not `https://` or `wss://`.
   ```typescript
   // ✗ Wrong
   const client = createClient({ url: "https://myapp-myorg.turso.io" });

   // ✓ Correct
   const client = createClient({ url: "libsql://myapp-myorg.turso.io" });
   ```

2. **Network/firewall blocking**: Turso uses HTTPS (port 443) and WebSocket. Ensure outbound connections are allowed.

3. **Region latency**: If your app is in `us-east-1` but your Turso primary is in `lhr` (London), expect higher latency. Check with:
   ```bash
   turso db show myapp  # Shows primary location
   ```

4. **Cold start on free plan**: Free-plan databases may sleep after inactivity. First request may take 1–3 seconds.

### Retry Strategies

The `@libsql/client` does not retry automatically. Implement retries for transient failures:

```typescript
async function executeWithRetry(
  client: Client,
  sql: string,
  args: any[] = [],
  maxRetries = 3
) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await client.execute({ sql, args });
    } catch (err: any) {
      const isTransient =
        err.message?.includes("fetch failed") ||
        err.message?.includes("TIMEOUT") ||
        err.message?.includes("network");

      if (!isTransient || attempt === maxRetries) throw err;

      const delay = Math.min(1000 * 2 ** (attempt - 1), 10000);
      console.warn(`Retry ${attempt}/${maxRetries} after ${delay}ms`);
      await new Promise((r) => setTimeout(r, delay));
    }
  }
}
```

### WebSocket vs HTTP Transport

The client auto-selects transport based on environment:

| Environment | Import | Transport |
|------------|--------|-----------|
| Node.js / Bun | `@libsql/client` | WebSocket (persistent) |
| Cloudflare Workers | `@libsql/client/web` | HTTP (per-request) |
| Vercel Edge | `@libsql/client/web` | HTTP (per-request) |
| Deno | `@libsql/client/web` | HTTP (per-request) |
| Browser | `@libsql/client/web` | HTTP (per-request) |

**Common mistake**: Using `@libsql/client` (Node import) in Workers/Edge:
```
Error: globalThis.WebSocket is not a constructor
```
**Fix**: Import from `@libsql/client/web`.

---

## Embedded Replica Issues

### Sync Failures

**Symptom**: `sync()` throws or `syncInterval` stops working.

**Common causes**:

1. **Auth token expired**: Tokens are JWTs with expiration. Generate a new one:
   ```bash
   turso db tokens create myapp --expiration 365d
   ```

2. **Network interruption**: `sync()` requires network access to the primary. Handle gracefully:
   ```typescript
   try {
     await client.sync();
   } catch (err) {
     console.warn("Sync failed, using stale local data:", err.message);
     // App continues with cached data
   }
   ```

3. **Primary database deleted or renamed**: Verify the database still exists:
   ```bash
   turso db show myapp
   ```

4. **Wrong syncUrl**: Must match the primary's URL exactly:
   ```typescript
   // ✗ Missing org suffix
   syncUrl: "libsql://myapp.turso.io"
   // ✓ Correct format
   syncUrl: "libsql://myapp-myorg.turso.io"
   ```

### Stale Data After Writes

**Symptom**: Writes succeed but subsequent reads return old data.

**Cause**: Writes go to the primary, but reads come from the local replica. The replica hasn't synced yet.

**Fix**: Call `sync()` after writes when read-your-writes is needed:
```typescript
await client.execute("INSERT INTO users (name) VALUES (?)", ["Alice"]);
await client.sync(); // Pull the new write back to local
const result = await client.execute("SELECT * FROM users WHERE name = 'Alice'");
// Now result.rows contains Alice
```

**Alternative**: Use `syncInterval` with a short interval (5–10s) if eventual consistency is acceptable.

### Replica File Corruption

**Symptom**: `SQLITE_CORRUPT` or `database disk image is malformed`.

**Fixes**:
1. Delete the local replica file and re-sync:
   ```bash
   rm local-replica.db local-replica.db-wal local-replica.db-shm
   ```
   The client will recreate it on next `sync()`.

2. Ensure the replica file isn't shared between processes. Each process should have its own replica file path.

3. Ensure the filesystem supports proper locking (NFS and some network filesystems don't).

### Disk Space and File Location

**Symptom**: `SQLITE_FULL` or write errors on the local replica.

**Fixes**:
- Ensure the directory for the local replica is writable and has sufficient disk space.
- On serverless platforms (Vercel, Netlify), `/tmp` is the only writable directory — but it is ephemeral:
  ```typescript
  const client = createClient({
    url: "file:/tmp/replica.db", // Ephemeral — re-syncs each cold start
    syncUrl: "libsql://myapp-myorg.turso.io",
    authToken: process.env.TURSO_AUTH_TOKEN,
  });
  ```
- On long-running servers, use a persistent volume for the replica file.

---

## Authentication Issues

### Token Expiration and Rotation

**Symptom**: `PERMISSION_DENIED` or `401 Unauthorized` errors that start happening after the app has been running.

**Diagnosing**:
```bash
# Check if your token is expired (tokens are JWTs)
echo "$TURSO_AUTH_TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .exp
# Convert Unix timestamp to readable date
date -d @<timestamp>
```

**Generating long-lived tokens**:
```bash
turso db tokens create myapp --expiration 365d   # 1 year
turso group tokens create prod --expiration 365d  # Group-level, 1 year
```

**Rotation strategy**:
1. Generate new token before old one expires.
2. Update environment variables (Vercel, Cloudflare, etc.).
3. Redeploy or restart the application.
4. Revoke old token (tokens cannot be revoked individually — rotate group/db tokens to invalidate all existing tokens).

> **Warning**: `turso db tokens create` generates a new token but does NOT invalidate previous tokens. To invalidate all tokens, rotate the group's JWT signing key:
> ```bash
> turso group tokens invalidate prod  # Invalidates ALL tokens for the group
> ```

### Token Scope Mismatches

| Token Type | Created With | Scope | Use Case |
|-----------|-------------|-------|----------|
| Database token | `turso db tokens create <db>` | Single database | Single-app deployments |
| Group token | `turso group tokens create <group>` | All DBs in group | Multi-tenant, multiple databases |
| API token | `turso auth api-tokens mint <name>` | Turso Platform API | CI/CD, provisioning |

**Common mistake**: Using an API token as `authToken` in the SDK client:
```typescript
// ✗ API tokens are for the Platform API, not database access
const client = createClient({
  url: "libsql://myapp-myorg.turso.io",
  authToken: TURSO_API_TOKEN, // Wrong!
});

// ✓ Use a database or group token
const client = createClient({
  url: "libsql://myapp-myorg.turso.io",
  authToken: TURSO_DB_TOKEN,
});
```

### API Token vs Database Token

**Platform API** (managing databases, groups, orgs):
```bash
# Create API token
turso auth api-tokens mint my-ci-token

# Use with Platform API
curl -H "Authorization: Bearer $API_TOKEN" \
  https://api.turso.tech/v1/organizations/myorg/databases
```

**Database access** (reading/writing data):
```bash
# Create database token
turso db tokens create myapp

# Use with SDK client
export TURSO_AUTH_TOKEN="<database-token>"
```

---

## Database Size and Storage

### Storage Limits by Plan

| Plan | Total Storage | Per-Database Limit |
|------|--------------|-------------------|
| Free | 5 GB | 5 GB (shared) |
| Scaler | 9 GB | 9 GB (shared) |
| Pro | 50 GB | 50 GB (shared) |

Storage is measured across ALL databases in the account.

### Identifying Large Tables

```bash
# Show storage breakdown by table
turso db inspect myapp --verbose
```

Output:
```
Database: myapp
Total size: 142.5 MB

Table           Rows        Size
──────────────────────────────────
events          1,234,567   98.2 MB
users           45,000      12.1 MB
sessions        890,000     28.4 MB
_migrations     15          0.1 MB
```

### Storage Optimization

1. **Delete old data**:
   ```sql
   DELETE FROM events WHERE created_at < datetime('now', '-90 days');
   ```

2. **Vacuum after bulk deletes** (reclaims space):
   ```bash
   turso db shell myapp "VACUUM"
   ```

3. **Use strict tables** to prevent type bloat:
   ```sql
   CREATE TABLE events (
     id INTEGER PRIMARY KEY,
     type TEXT NOT NULL,
     data TEXT NOT NULL
   ) STRICT;
   ```

4. **Compress JSON data** before storing:
   ```typescript
   import { gzipSync, gunzipSync } from "zlib";
   // Store compressed
   const compressed = gzipSync(JSON.stringify(data)).toString("base64");
   await client.execute("INSERT INTO blobs (data) VALUES (?)", [compressed]);
   ```

5. **Normalize repeated values**: Use foreign keys instead of duplicating strings.

### Row Read/Write Quotas

**Row reads**: Every row *scanned* (not just returned) counts. A `SELECT * FROM users WHERE name = 'Alice'` without an index on `name` scans ALL rows.

**Reduce row reads**:
- Add indexes for filtered columns
- Use `LIMIT` clauses
- Use embedded replicas (local reads are free)
- Use batch queries instead of N+1 patterns

**Monitor usage**:
```bash
turso org billing   # Shows current period usage
turso plan show     # Plan limits
```

---

## Migration from SQLite Gotchas

### Unsupported Features

libSQL is a SQLite superset — nearly everything works. Known differences:

| Feature | SQLite | libSQL/Turso | Notes |
|---------|--------|-------------|-------|
| `ATTACH DATABASE` | ✓ | ✗ (remote mode) | Works with local/embedded only |
| Custom C extensions | ✓ | ✗ | Use libSQL native extensions instead |
| `load_extension()` | ✓ | ✗ | Disabled for security |
| WAL2 mode | ✗ | ✓ | libSQL extension |
| Vector columns | ✗ | ✓ | libSQL extension |
| File size > 100 GB | ✓ | Limited by plan | See storage limits |

### Connection String Differences

```
# SQLite
sqlite:///path/to/db.sqlite
file:db.sqlite
./db.sqlite

# Turso remote
libsql://dbname-orgname.turso.io

# Turso embedded replica
file:local.db (with syncUrl)

# Local development (pure libSQL)
file:dev.db
```

### Driver Compatibility

| Original Driver | Turso Replacement | Notes |
|----------------|-------------------|-------|
| `better-sqlite3` | `@libsql/client` | Async API (not sync) |
| `sqlite3` (Node) | `@libsql/client` | Different API shape |
| `sql.js` | `@libsql/client/web` | For browser/edge |
| `rusqlite` | `libsql` crate | API similar to rusqlite |
| `python sqlite3` | `libsql-experimental` | Drop-in compatible API |
| `database/sql` (Go) | `go-libsql` | Implements `database/sql` |

---

## Platform-Specific Deployment Issues

### Vercel / Next.js

**Issue**: `Dynamic server usage` error with Turso in static pages.

**Fix**: Mark the page as dynamic:
```typescript
export const dynamic = "force-dynamic";
// or
export const revalidate = 0;
```

**Issue**: Embedded replica file lost between invocations.

**Explanation**: Vercel serverless functions are stateless. The replica file in `/tmp` is ephemeral. Each cold start re-creates it. This is expected — use `sync()` at startup:
```typescript
const client = createClient({
  url: "file:/tmp/turso-replica.db",
  syncUrl: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});
await client.sync();
```

**Issue**: Build-time database access fails.

**Fix**: Guard database calls to run only at runtime:
```typescript
if (process.env.TURSO_DATABASE_URL) {
  // Safe to use at runtime
}
```

### Cloudflare Workers

**Issue**: `TypeError: globalThis.WebSocket is not a constructor`

**Fix**: Use the web-compatible import:
```typescript
// ✗
import { createClient } from "@libsql/client";
// ✓
import { createClient } from "@libsql/client/web";
```

**Issue**: `Cannot use embedded replicas` in Workers.

**Explanation**: Workers have no filesystem. Use remote mode only.

**Issue**: `Subrequest limit exceeded` (50 subrequests per invocation on free plan).

**Fix**: Use batch operations to reduce HTTP requests:
```typescript
// ✗ 10 separate requests
for (const item of items) {
  await client.execute("INSERT INTO items (name) VALUES (?)", [item.name]);
}

// ✓ 1 batch request
await client.batch(
  items.map((item) => ({
    sql: "INSERT INTO items (name) VALUES (?)",
    args: [item.name],
  })),
  "write"
);
```

### Docker / Containers

**Issue**: Embedded replica file lost when container restarts.

**Fix**: Mount a persistent volume:
```yaml
# docker-compose.yml
services:
  app:
    volumes:
      - turso-data:/app/data
volumes:
  turso-data:
```

```typescript
const client = createClient({
  url: "file:/app/data/replica.db",
  syncUrl: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});
```

**Issue**: `turso` CLI not available in container.

**Fix**: Install in Dockerfile:
```dockerfile
RUN curl -sSfL https://get.tur.so/install.sh | bash
ENV PATH="/root/.turso:${PATH}"
```

### Fly.io

**Issue**: Replica file lost on deployment.

**Fix**: Use Fly Volumes for persistent replica storage:
```toml
# fly.toml
[[mounts]]
  source = "turso_data"
  destination = "/data"
```

```bash
fly volumes create turso_data --region ord --size 1
```

**Issue**: Multi-region writes routing to wrong primary.

**Fix**: Place Turso primary in the same region as Fly's primary. Replicas at other Fly regions handle reads locally.

---

## Performance Debugging

### Using turso db inspect

```bash
# Basic inspection — total size
turso db inspect myapp

# Verbose — per-table breakdown with row counts
turso db inspect myapp --verbose

# Check overall account usage
turso org billing
```

**Interpreting output**:
- High storage with few rows = large TEXT/BLOB columns or missing VACUUM
- High row reads vs rows returned = missing indexes (full table scans)

### Slow Query Analysis

libSQL supports `EXPLAIN QUERY PLAN` (same as SQLite):

```sql
-- Check if a query uses indexes
EXPLAIN QUERY PLAN SELECT * FROM users WHERE email = 'alice@example.com';
-- Look for: SEARCH users USING INDEX idx_users_email
-- Bad sign: SCAN users (full table scan)
```

Run via Turso shell:
```bash
turso db shell myapp "EXPLAIN QUERY PLAN SELECT * FROM users WHERE email = 'alice@example.com'"
```

### Index Optimization

```sql
-- Find tables without indexes (potential full-scan targets)
SELECT name FROM sqlite_master WHERE type = 'table'
EXCEPT
SELECT DISTINCT tbl_name FROM sqlite_master WHERE type = 'index';

-- Create covering index (includes all needed columns — avoids table lookup)
CREATE INDEX idx_users_email_name ON users(email, name);

-- Partial index (smaller, faster — only indexes matching rows)
CREATE INDEX idx_active_users ON users(email) WHERE active = 1;

-- Check index usage
EXPLAIN QUERY PLAN SELECT name FROM users WHERE email = 'test@example.com';
-- With covering index: SEARCH users USING COVERING INDEX idx_users_email_name
```

### Batch vs Individual Queries

**Problem**: N+1 query pattern causes excessive round-trips and row reads.

```typescript
// ✗ N+1 — one request per user (slow, expensive)
const users = await client.execute("SELECT * FROM users LIMIT 100");
for (const user of users.rows) {
  const orders = await client.execute(
    "SELECT * FROM orders WHERE user_id = ?", [user.id]
  );
}

// ✓ Single JOIN query
const result = await client.execute(`
  SELECT u.*, o.id AS order_id, o.total
  FROM users u
  LEFT JOIN orders o ON o.user_id = u.id
  ORDER BY u.id
  LIMIT 100
`);

// ✓ Batch — multiple queries in one round-trip
const userIds = users.rows.map((u) => u.id);
const results = await client.batch(
  userIds.map((id) => ({
    sql: "SELECT * FROM orders WHERE user_id = ?",
    args: [id],
  })),
  "read"
);
```

**Performance comparison** (100 users, remote mode):
| Pattern | Round-trips | Row reads | Latency |
|---------|------------|-----------|---------|
| N+1 | 101 | ~10,000+ | ~5–10s |
| JOIN | 1 | ~200 | ~50ms |
| Batch | 1 | ~200 | ~60ms |
