# Prisma ORM — Troubleshooting Guide

## Table of Contents

- [Common Error Codes](#common-error-codes)
  - [P2002 — Unique Constraint Violation](#p2002--unique-constraint-violation)
  - [P2003 — Foreign Key Constraint Failed](#p2003--foreign-key-constraint-failed)
  - [P2025 — Record Not Found](#p2025--record-not-found)
  - [P2014 — Required Relation Violation](#p2014--required-relation-violation)
  - [P2021 — Table Does Not Exist](#p2021--table-does-not-exist)
  - [P2034 — Transaction Conflict (Write Conflict)](#p2034--transaction-conflict-write-conflict)
  - [PrismaClientValidationError](#prismaclientvalidationerror)
  - [PrismaClientInitializationError](#prismaclientinitializationerror)
- [Migration Issues](#migration-issues)
  - [Migration History Conflicts](#migration-history-conflicts)
  - [Drift Detection](#drift-detection)
  - [Failed Migrations in Production](#failed-migrations-in-production)
  - [Shadow Database Errors](#shadow-database-errors)
  - [Resolving Migration Lock](#resolving-migration-lock)
- [Performance Issues](#performance-issues)
  - [N+1 Problem with Nested Includes](#n1-problem-with-nested-includes)
  - [Connection Pool Exhaustion](#connection-pool-exhaustion)
  - [Slow Queries](#slow-queries)
  - [Memory Issues with Large Datasets](#memory-issues-with-large-datasets)
- [Prisma Client Generation Issues](#prisma-client-generation-issues)
- [Edge Runtime Compatibility](#edge-runtime-compatibility)
- [Long-Running Transactions](#long-running-transactions)
- [Database-Specific Issues](#database-specific-issues)

---

## Common Error Codes

### P2002 — Unique Constraint Violation

**Error:** `Unique constraint failed on the {constraint}`

**Causes:**
- Inserting a duplicate value for a `@unique` or `@@unique` field
- Race condition in concurrent upserts
- Seeding data that already exists

**Fix:**

```typescript
import { Prisma } from '@prisma/client'

try {
  await prisma.user.create({ data: { email: 'ada@prisma.io' } })
} catch (e) {
  if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
    const target = (e.meta?.target as string[]) ?? []
    console.error(`Duplicate value on fields: ${target.join(', ')}`)
    // Option 1: upsert instead
    await prisma.user.upsert({
      where: { email: 'ada@prisma.io' },
      update: {},
      create: { email: 'ada@prisma.io' },
    })
  }
}
```

**Prevention:**
- Use `upsert` when records may already exist
- Use `createMany({ skipDuplicates: true })` for bulk inserts
- Add application-level validation before insert

---

### P2003 — Foreign Key Constraint Failed

**Error:** `Foreign key constraint failed on the field: {field_name}`

**Causes:**
- Creating a record with a reference to a nonexistent parent
- Deleting a parent record that still has children (without `Cascade`)

**Fix:**

```typescript
try {
  await prisma.post.create({ data: { title: 'Hello', authorId: 9999 } })
} catch (e) {
  if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2003') {
    console.error(`Referenced record does not exist: ${e.meta?.field_name}`)
  }
}
```

**Prevention:**
- Verify parent record exists before creating child
- Use nested creates: `prisma.user.create({ data: { posts: { create: ... } } })`
- Set appropriate `onDelete` referential actions in schema:
  ```prisma
  author User @relation(fields: [authorId], references: [id], onDelete: Cascade)
  ```

---

### P2025 — Record Not Found

**Error:** `An operation failed because it depends on one or more records that were required but not found.`

**Causes:**
- `findUniqueOrThrow` / `findFirstOrThrow` with no matching record
- `update` / `delete` on nonexistent record
- Nested `connect` to nonexistent relation

**Fix:**

```typescript
try {
  await prisma.user.update({ where: { id: 9999 }, data: { name: 'New' } })
} catch (e) {
  if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2025') {
    console.error('Record not found:', e.meta?.cause)
    // Fallback: use upsert or check existence first
  }
}
```

**Note:** In Prisma 6, `NotFoundError` was removed — all not-found errors now throw `P2025`.

---

### P2014 — Required Relation Violation

**Error:** `The change you are trying to make would violate the required relation`

**Cause:** Trying to disconnect or nullify a required (non-optional) relation.

**Fix:** Either make the relation optional (`?`) or use `Cascade` delete.

---

### P2021 — Table Does Not Exist

**Error:** `The table {table} does not exist in the current database`

**Fix:**
```bash
npx prisma migrate dev    # Apply pending migrations
npx prisma db push        # Or push schema directly (prototyping)
```

---

### P2034 — Transaction Conflict (Write Conflict)

**Error:** `Transaction failed due to a write conflict or a deadlock`

**Fix:**
```typescript
async function withRetry<T>(fn: () => Promise<T>, retries = 3): Promise<T> {
  for (let i = 0; i < retries; i++) {
    try {
      return await fn()
    } catch (e) {
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2034') {
        if (i === retries - 1) throw e
        await new Promise(r => setTimeout(r, 100 * (i + 1))) // backoff
        continue
      }
      throw e
    }
  }
  throw new Error('Unreachable')
}
```

---

### PrismaClientValidationError

**Cause:** Query shape doesn't match schema — wrong field names, missing required fields, mixing `select` + `include` at same level.

**Fix:** Check query args match your schema. This error fires before the DB is contacted. Run `npx prisma generate` after schema changes.

---

### PrismaClientInitializationError

**Causes:**
- `DATABASE_URL` not set or invalid
- Database server unreachable
- SSL certificate issues

**Fix:**
```bash
# Verify connection
npx prisma db pull   # Quick connectivity check

# Common URL fixes
# Missing SSL: ?sslmode=require
# IPv6 issues: use hostname not IP
# Pooler mode: add &pgbouncer=true for PgBouncer
```

---

## Migration Issues

### Migration History Conflicts

**Symptom:** `The migration ... was modified after it was applied` or migrations won't apply.

**Causes:**
- Editing migration files after applying them
- Different migration history across team members
- Rebasing/merging branches with conflicting migrations

**Fix — Development:**
```bash
# Reset and reapply all migrations (DESTROYS DATA)
npx prisma migrate reset

# If you need to keep data, create a new baseline
npx prisma migrate resolve --applied "20240101000000_conflicting_migration"
```

**Fix — Team Workflow:**
1. Never edit applied migration files
2. When merging branches with migrations, create a new migration to reconcile
3. Use consistent naming timestamps to avoid collisions

---

### Drift Detection

**Symptom:** `Drift detected: Your database schema is not in sync with your migration history`

**Causes:**
- Manual database changes outside Prisma
- `db push` used alongside `migrate`
- Direct SQL modifications

**Fix:**
```bash
# See what differs
npx prisma migrate diff \
  --from-migrations ./prisma/migrations \
  --to-schema-datamodel ./prisma/schema.prisma

# Option 1: Bring schema in line with DB
npx prisma db pull    # Introspect DB → update schema

# Option 2: Create migration to align DB with schema
npx prisma migrate dev --name fix_drift

# Option 3: Mark drift as intentional (production)
npx prisma migrate resolve --applied "migration_name"
```

---

### Failed Migrations in Production

**Symptom:** Migration partially applied, database in inconsistent state.

**Fix:**
```bash
# 1. Check migration status
npx prisma migrate status

# 2. Manually fix the database to match the intended state

# 3. Mark the failed migration as rolled back
npx prisma migrate resolve --rolled-back "20240101000000_failed_migration"

# 4. Or mark as applied if you fixed it manually
npx prisma migrate resolve --applied "20240101000000_failed_migration"

# 5. Re-deploy
npx prisma migrate deploy
```

---

### Shadow Database Errors

**Symptom:** `prisma migrate dev` fails with shadow database errors.

**Cause:** Can't create/drop the shadow database (permissions or managed DB like Supabase/Neon).

**Fix:**
```prisma
datasource db {
  provider          = "postgresql"
  url               = env("DATABASE_URL")
  shadowDatabaseUrl = env("SHADOW_DATABASE_URL")  // separate DB for shadow
}
```

```bash
# Or disable shadow DB (use db push for prototyping)
npx prisma db push
```

---

### Resolving Migration Lock

**Symptom:** `Migration lock timeout` — another migration is running.

**Fix:**
```sql
-- PostgreSQL: check and release lock
SELECT * FROM _prisma_migrations WHERE finished_at IS NULL;
UPDATE _prisma_migrations SET finished_at = NOW() WHERE finished_at IS NULL;
```

---

## Performance Issues

### N+1 Problem with Nested Includes

**Problem:** Querying in a loop instead of using relations.

```typescript
// ❌ BAD — N+1 queries
const users = await prisma.user.findMany()
for (const user of users) {
  const posts = await prisma.post.findMany({ where: { authorId: user.id } })
}

// ✅ GOOD — single query with include
const users = await prisma.user.findMany({
  include: { posts: true },
})

// ✅ BETTER — fetch only needed fields
const users = await prisma.user.findMany({
  select: {
    id: true,
    name: true,
    posts: { select: { id: true, title: true }, take: 10 },
  },
})
```

**Deeply nested includes** can cause cartesian explosion:
```typescript
// ⚠️ Can be slow with large datasets
const data = await prisma.user.findMany({
  include: {
    posts: { include: { comments: { include: { author: true } } } },
  },
})

// ✅ Use relationLoadStrategy: 'query' for deep nesting
const data = await prisma.user.findMany({
  include: {
    posts: { include: { comments: { include: { author: true } } } },
  },
  relationLoadStrategy: 'query', // separate queries, avoids cartesian explosion
})
```

---

### Connection Pool Exhaustion

**Symptoms:**
- `Timed out fetching a new connection from the connection pool`
- Queries hang then fail
- Database reports too many connections

**Causes:**
- Multiple PrismaClient instances (especially during hot reload)
- Pool too small for workload
- Long-running transactions holding connections
- Not disconnecting in serverless functions

**Fixes:**

```typescript
// 1. Singleton pattern (prevents hot-reload leaks)
const globalForPrisma = globalThis as unknown as { prisma: PrismaClient }
export const prisma = globalForPrisma.prisma ?? new PrismaClient()
if (process.env.NODE_ENV !== 'production') globalForPrisma.prisma = prisma

// 2. Configure pool size via URL
// postgresql://user:pass@host/db?connection_limit=10&pool_timeout=30

// 3. For serverless: use external pooler
// PgBouncer, Prisma Accelerate, or Supabase pooler
// Add &pgbouncer=true to URL for PgBouncer
```

**Diagnostics — log pool events:**
```typescript
const prisma = new PrismaClient({
  log: [
    { level: 'query', emit: 'event' },
    { level: 'warn', emit: 'stdout' },
  ],
})
prisma.$on('query', (e) => {
  if (e.duration > 1000) console.warn(`Slow query (${e.duration}ms):`, e.query)
})
```

**Pool sizing formula:**
```
connection_limit = max(CPU_cores * 2 + 1, 10)
```

---

### Slow Queries

**Diagnosis:**
```typescript
// Enable query logging
const prisma = new PrismaClient({
  log: [{ level: 'query', emit: 'event' }],
})
prisma.$on('query', (e) => {
  if (e.duration > 200) {
    console.warn(`Slow query (${e.duration}ms):`, e.query)
    console.warn('Params:', e.params)
  }
})
```

**Common fixes:**
1. Add `@@index` on fields used in `where` / `orderBy`
2. Use `select` instead of `include` to reduce payload
3. Add cursor pagination for large datasets
4. Use `createMany` / `updateMany` for bulk ops
5. Check `EXPLAIN ANALYZE` via raw SQL:
```typescript
const plan = await prisma.$queryRaw`EXPLAIN ANALYZE SELECT * FROM "User" WHERE email = ${email}`
```

---

### Memory Issues with Large Datasets

```typescript
// ❌ Loading all records at once
const allUsers = await prisma.user.findMany() // 1M records = OOM

// ✅ Batch processing with cursor pagination
async function processAllUsers(batchSize = 1000) {
  let cursor: number | undefined
  while (true) {
    const users = await prisma.user.findMany({
      take: batchSize,
      skip: cursor ? 1 : 0,
      cursor: cursor ? { id: cursor } : undefined,
      orderBy: { id: 'asc' },
    })
    if (users.length === 0) break
    await processBatch(users)
    cursor = users[users.length - 1].id
  }
}
```

---

## Prisma Client Generation Issues

### `prisma generate` fails

**Common causes and fixes:**

```bash
# Schema syntax error — validate first
npx prisma validate

# Outdated or mismatched packages
npm ls prisma @prisma/client   # versions must match
npm install prisma@latest @prisma/client@latest

# Missing engine binaries (CI/Docker)
# Set in schema:
# generator client {
#   provider      = "prisma-client"
#   binaryTargets = ["native", "linux-musl-openssl-3.0.x"]
# }

# Clear cache and regenerate
rm -rf node_modules/.prisma
npx prisma generate
```

### Client out of sync with schema

**Symptom:** TypeScript errors for fields that exist in schema.

```bash
# Always regenerate after schema changes
npx prisma generate

# In watch mode / dev
npx prisma generate --watch
```

### Prisma 6 migration: new output path

```prisma
// Prisma 6 default: client generated outside node_modules
generator client {
  provider = "prisma-client"
  output   = "../src/generated/prisma"
}
```

```typescript
// Update imports
import { PrismaClient } from './generated/prisma'  // not '@prisma/client'
```

---

## Edge Runtime Compatibility

**Problem:** `PrismaClient is not configured to run in Vercel Edge Runtime / Cloudflare Workers`

**Cause:** Default Prisma Client uses Node.js native modules and TCP, not available in edge runtimes.

**Solutions:**

### Option 1: Prisma Accelerate (recommended)

```bash
npm install @prisma/extension-accelerate
```

```typescript
import { PrismaClient } from '@prisma/client'
import { withAccelerate } from '@prisma/extension-accelerate'

const prisma = new PrismaClient().$extends(withAccelerate())
// Set DATABASE_URL to Accelerate proxy URL
```

### Option 2: Driver adapters (Neon, PlanetScale)

```typescript
// Neon Serverless
import { Pool, neonConfig } from '@neondatabase/serverless'
import { PrismaNeon } from '@prisma/adapter-neon'

neonConfig.webSocketConstructor = ws
const pool = new Pool({ connectionString: process.env.DATABASE_URL })
const adapter = new PrismaNeon(pool)
const prisma = new PrismaClient({ adapter })
```

### Option 3: Keep Prisma on server, call via API

Use API routes (Node.js runtime) for database access, call from edge routes.

---

## Long-Running Transactions

**Problems:**
- Connection pool exhaustion (each transaction holds a connection)
- Database lock escalation
- Timeout errors

**Best practices:**

```typescript
// Set explicit timeouts
await prisma.$transaction(
  async (tx) => {
    // Keep it short — avoid external API calls inside transactions
    const user = await tx.user.update({ where: { id: 1 }, data: { balance: { decrement: 100 } } })
    if (user.balance < 0) throw new Error('Insufficient funds')
    await tx.user.update({ where: { id: 2 }, data: { balance: { increment: 100 } } })
  },
  {
    maxWait: 5000,    // max time to acquire connection from pool
    timeout: 10000,   // max transaction duration
    isolationLevel: Prisma.TransactionIsolationLevel.Serializable,
  }
)

// For long operations, break into multiple transactions
async function migrateData() {
  const batchSize = 100
  let processed = 0
  while (true) {
    const batch = await prisma.record.findMany({ take: batchSize, skip: processed })
    if (batch.length === 0) break
    await prisma.$transaction(
      batch.map(r => prisma.record.update({ where: { id: r.id }, data: { migrated: true } }))
    )
    processed += batch.length
  }
}
```

---

## Database-Specific Issues

### PostgreSQL: Prepared statement errors with PgBouncer

**Error:** `prepared statement "s0" already exists`

**Fix:**
```prisma
datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")        // pooler URL (?pgbouncer=true)
  directUrl = env("DIRECT_DATABASE_URL") // direct connection for migrations
}
```

### MySQL: `@@fulltext` index required

Full-text search requires explicit `@@fulltext` index in schema (unlike PostgreSQL).

### SQLite: Limited concurrent writes

SQLite only allows one writer at a time. Use `$transaction` carefully and keep transactions short.

### MongoDB: No native migrations

Use `db push` instead of `migrate`. No migration history for MongoDB.

```bash
npx prisma db push  # MongoDB schema sync
```
