# Prisma Performance Optimization Guide

## Table of Contents

- [Query Analysis with Logging](#query-analysis-with-logging)
- [N+1 Detection and Fixes](#n1-detection-and-fixes)
- [Batch Operations](#batch-operations)
- [Transaction Strategies](#transaction-strategies)
- [Connection Pool Tuning](#connection-pool-tuning)
- [Prisma Accelerate](#prisma-accelerate)
- [Query Caching Strategies](#query-caching-strategies)
- [Index Recommendations](#index-recommendations)

---

## Query Analysis with Logging

### Enable Query Logging

```typescript
const prisma = new PrismaClient({
  log: [
    { level: 'query', emit: 'event' },
    { level: 'warn', emit: 'stdout' },
    { level: 'error', emit: 'stdout' },
  ],
});

// Log all queries with duration
prisma.$on('query', (e) => {
  console.log(`Query: ${e.query}`);
  console.log(`Params: ${e.params}`);
  console.log(`Duration: ${e.duration}ms`);
});
```

### Structured Query Logging

```typescript
interface QueryLog {
  query: string;
  params: string;
  duration: number;
  timestamp: Date;
}

const queryLogs: QueryLog[] = [];

prisma.$on('query', (e) => {
  queryLogs.push({
    query: e.query,
    params: e.params,
    duration: e.duration,
    timestamp: new Date(e.timestamp),
  });
});

// Analyze slow queries
function getSlowQueries(thresholdMs = 100): QueryLog[] {
  return queryLogs.filter((q) => q.duration > thresholdMs)
    .sort((a, b) => b.duration - a.duration);
}

// Find N+1 patterns (repeated similar queries)
function detectRepeatedQueries(): Map<string, number> {
  const counts = new Map<string, number>();
  for (const log of queryLogs) {
    const normalized = log.query.replace(/\$\d+/g, '?');
    counts.set(normalized, (counts.get(normalized) ?? 0) + 1);
  }
  return new Map([...counts.entries()].filter(([, c]) => c > 3));
}
```

### Using EXPLAIN

```typescript
// Analyze query plan for specific operations
const plan = await prisma.$queryRaw`
  EXPLAIN ANALYZE
  SELECT * FROM users
  WHERE email LIKE '%@company.com'
  ORDER BY created_at DESC
  LIMIT 100
`;
console.log(plan);

// Wrap around Prisma queries by enabling logging and running EXPLAIN on captured SQL
```

---

## N+1 Detection and Fixes

### The Problem

```typescript
// ❌ N+1: 1 query for users + N queries for posts
const users = await prisma.user.findMany();
for (const user of users) {
  const posts = await prisma.post.findMany({
    where: { authorId: user.id },
  });
  console.log(`${user.name}: ${posts.length} posts`);
}
// Result: 1 + N queries (100 users = 101 queries)
```

### Fix 1: `include` (Eager Loading)

```typescript
// ✅ 2 queries total: one for users, one for all their posts
const users = await prisma.user.findMany({
  include: { posts: true },
});
users.forEach((u) => console.log(`${u.name}: ${u.posts.length} posts`));
```

### Fix 2: `select` (Only Needed Fields)

```typescript
// ✅ 2 queries, minimal data transfer
const users = await prisma.user.findMany({
  select: {
    name: true,
    posts: {
      select: { title: true, createdAt: true },
      where: { published: true },
      take: 5,
      orderBy: { createdAt: 'desc' },
    },
  },
});
```

### Fix 3: Fluent API for Single Records

```typescript
// ✅ For loading relations on a single record
const posts = await prisma.user
  .findUnique({ where: { id: 1 } })
  .posts({ where: { published: true } });
```

### When `include` is Not Enough

For complex aggregations, use raw SQL or `groupBy`:

```typescript
// ❌ Loading all posts just to count them
const users = await prisma.user.findMany({ include: { posts: true } });
users.map((u) => ({ ...u, postCount: u.posts.length }));

// ✅ Use _count
const users = await prisma.user.findMany({
  include: { _count: { select: { posts: true } } },
});
users.map((u) => ({ ...u, postCount: u._count.posts }));

// ✅ Use groupBy for aggregate queries
const postCounts = await prisma.post.groupBy({
  by: ['authorId'],
  _count: true,
  orderBy: { _count: { id: 'desc' } },
});
```

### Nested Include Depth Limits

```typescript
// ⚠ Deep nesting creates large JOINs — limit depth to 2-3 levels
// BAD
const deep = await prisma.user.findMany({
  include: {
    posts: {
      include: {
        comments: {
          include: {
            author: { include: { profile: true } },
          },
        },
      },
    },
  },
});

// BETTER — separate queries for deep data
const users = await prisma.user.findMany({ include: { posts: true } });
const postIds = users.flatMap((u) => u.posts.map((p) => p.id));
const comments = await prisma.comment.findMany({
  where: { postId: { in: postIds } },
  include: { author: true },
});
```

---

## Batch Operations

### createMany

```typescript
// ✅ Single INSERT statement with multiple rows
const result = await prisma.user.createMany({
  data: users.map((u) => ({ email: u.email, name: u.name })),
  skipDuplicates: true,  // silently skip P2002 violations
});
console.log(`Created ${result.count} users`);
```

**Limitations:**
- Returns count only, not created records
- No nested creates (no `include`)
- Not supported on SQLite

For records back after insert:
```typescript
// Workaround: createManyAndReturn (Prisma 5.14.0+)
const created = await prisma.user.createManyAndReturn({
  data: users.map((u) => ({ email: u.email, name: u.name })),
  select: { id: true, email: true },
});
```

### updateMany / deleteMany

```typescript
// ✅ Single UPDATE/DELETE with WHERE clause
await prisma.user.updateMany({
  where: { role: 'USER', lastLoginAt: { lt: sixMonthsAgo } },
  data: { status: 'INACTIVE' },
});

await prisma.post.deleteMany({
  where: { published: false, createdAt: { lt: oneYearAgo } },
});
```

### Batch with $transaction

For operations that need atomicity with different models:

```typescript
// ✅ Batch independent queries in parallel via batch transaction
const [userCount, postCount, recentPosts] = await prisma.$transaction([
  prisma.user.count(),
  prisma.post.count(),
  prisma.post.findMany({ take: 10, orderBy: { createdAt: 'desc' } }),
]);
```

### Chunked Bulk Operations

For very large datasets, process in chunks:

```typescript
async function bulkCreate<T>(
  data: T[],
  createFn: (chunk: T[]) => Promise<any>,
  chunkSize = 1000
) {
  const results = [];
  for (let i = 0; i < data.length; i += chunkSize) {
    const chunk = data.slice(i, i + chunkSize);
    results.push(await createFn(chunk));
  }
  return results;
}

// Usage
await bulkCreate(
  tenThousandUsers,
  (chunk) => prisma.user.createMany({ data: chunk, skipDuplicates: true }),
  500
);
```

---

## Transaction Strategies

### Sequential (Batch) Transactions

```typescript
// All queries execute sequentially in a single transaction
// Use for independent operations that need atomicity
const [users, posts] = await prisma.$transaction([
  prisma.user.findMany(),
  prisma.post.findMany(),
]);
```

**Characteristics:**
- Queries execute in order
- Single database round trip
- All succeed or all fail
- No inter-query logic possible

### Interactive Transactions

```typescript
// Use when you need logic between queries
const result = await prisma.$transaction(async (tx) => {
  const user = await tx.user.findUniqueOrThrow({ where: { id: userId } });

  if (user.balance < amount) {
    throw new Error('Insufficient funds');
  }

  const updated = await tx.user.update({
    where: { id: userId },
    data: { balance: { decrement: amount } },
  });

  await tx.transaction.create({
    data: { userId, amount, type: 'DEBIT' },
  });

  return updated;
}, {
  maxWait: 5000,    // max wait to acquire connection
  timeout: 10000,   // max transaction duration
  isolationLevel: Prisma.TransactionIsolationLevel.ReadCommitted,
});
```

**Performance tips for interactive transactions:**
- Keep transactions short — hold locks briefly
- Don't do I/O (HTTP calls, file reads) inside transactions
- Use `ReadCommitted` (default) unless you need stronger isolation
- Set appropriate `timeout` — too long holds connections

### When NOT to Use Transactions

```typescript
// ❌ Don't wrap read-only queries in transactions
await prisma.$transaction(async (tx) => {
  const users = await tx.user.findMany();  // no benefit
  return users;
});

// ✅ Just query directly
const users = await prisma.user.findMany();
```

---

## Connection Pool Tuning

### URL Parameters

```env
# PostgreSQL connection pool configuration
DATABASE_URL="postgresql://user:pass@host:5432/db?connection_limit=10&pool_timeout=10&connect_timeout=5"
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `connection_limit` | `num_cpus * 2 + 1` | Max connections in pool |
| `pool_timeout` | `10` (seconds) | Max wait for available connection |
| `connect_timeout` | `5` (seconds) | Max time to establish new connection |
| `socket_timeout` | none | Max time for query response |
| `statement_cache_size` | `100` | Prepared statement cache (PostgreSQL) |

### Environment-Specific Settings

```env
# Development (generous limits)
DATABASE_URL="...?connection_limit=10&pool_timeout=30"

# Production server (scale with cores)
DATABASE_URL="...?connection_limit=20&pool_timeout=10"

# Serverless / Lambda (minimal)
DATABASE_URL="...?connection_limit=1&pool_timeout=10"

# High-concurrency API
DATABASE_URL="...?connection_limit=50&pool_timeout=5"
```

### Calculating Pool Size

```
Rule of thumb:
  pool_size = (number_of_app_instances * connection_limit) ≤ max_db_connections

Example:
  3 server instances × 10 connections = 30
  PostgreSQL max_connections = 100
  Leaves 70 for other services, migrations, monitoring
```

### Using PgBouncer

For high-concurrency or serverless, add PgBouncer between Prisma and PostgreSQL:

```env
# Prisma connects to PgBouncer
DATABASE_URL="postgresql://user:pass@pgbouncer-host:6432/db?pgbouncer=true&connection_limit=5"

# Direct URL for migrations (bypass PgBouncer)
DIRECT_DATABASE_URL="postgresql://user:pass@db-host:5432/db"
```

```prisma
datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")
  directUrl = env("DIRECT_DATABASE_URL")
}
```

**`pgbouncer=true`** tells Prisma to:
- Disable prepared statements (incompatible with PgBouncer transaction mode)
- Avoid features that require persistent connections

---

## Prisma Accelerate

### Setup

```bash
npm install @prisma/extension-accelerate
```

```prisma
datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")        // Accelerate connection string
  directUrl = env("DIRECT_DATABASE_URL") // Direct DB for migrations
}
```

```typescript
import { PrismaClient } from '@prisma/client/edge';
import { withAccelerate } from '@prisma/extension-accelerate';

const prisma = new PrismaClient().$extends(withAccelerate());
```

### Connection Pooling

Accelerate provides global connection pooling — critical for serverless:
- No pool exhaustion from cold starts
- Connections managed externally
- Works with edge runtimes (no TCP required)

### Per-Query Caching

```typescript
// Cache for 60 seconds
const users = await prisma.user.findMany({
  cacheStrategy: { ttl: 60 },
});

// Stale-while-revalidate: serve stale for 120s while refreshing
const posts = await prisma.post.findMany({
  where: { published: true },
  cacheStrategy: { ttl: 60, swr: 120 },
});

// No cache for this query
const sensitive = await prisma.user.findUnique({
  where: { id: userId },
  // omit cacheStrategy = no caching
});

// Tags for invalidation
const cachedPosts = await prisma.post.findMany({
  cacheStrategy: { ttl: 300, swr: 600, tags: ['posts'] },
});

// Invalidate by tag
await prisma.$accelerate.invalidate({ tags: ['posts'] });
```

### Cache Strategy by Use Case

| Use Case | ttl | swr | Notes |
|----------|-----|-----|-------|
| User profile | 60 | 120 | Moderate freshness needed |
| Blog post list | 300 | 600 | Stale data acceptable |
| Product catalog | 3600 | 7200 | Rarely changes |
| Dashboard stats | 30 | 60 | Near-real-time |
| Auth/session | 0 | 0 | Never cache |

---

## Query Caching Strategies

### Application-Level Cache with Redis

```typescript
import Redis from 'ioredis';

const redis = new Redis(process.env.REDIS_URL);

async function cachedQuery<T>(
  key: string,
  ttlSeconds: number,
  queryFn: () => Promise<T>
): Promise<T> {
  const cached = await redis.get(key);
  if (cached) return JSON.parse(cached) as T;

  const result = await queryFn();
  await redis.setex(key, ttlSeconds, JSON.stringify(result));
  return result;
}

// Usage
const users = await cachedQuery(
  'users:active',
  300,
  () => prisma.user.findMany({ where: { status: 'ACTIVE' } })
);

// Cache invalidation on write
await prisma.user.update({ where: { id: 1 }, data: { status: 'INACTIVE' } });
await redis.del('users:active');
```

### Request-Scoped Cache (DataLoader Pattern)

```typescript
import DataLoader from 'dataloader';

function createLoaders() {
  return {
    userById: new DataLoader<number, User | null>(async (ids) => {
      const users = await prisma.user.findMany({
        where: { id: { in: [...ids] } },
      });
      const userMap = new Map(users.map((u) => [u.id, u]));
      return ids.map((id) => userMap.get(id) ?? null);
    }),

    postsByAuthor: new DataLoader<number, Post[]>(async (authorIds) => {
      const posts = await prisma.post.findMany({
        where: { authorId: { in: [...authorIds] } },
      });
      const grouped = new Map<number, Post[]>();
      for (const post of posts) {
        const list = grouped.get(post.authorId) ?? [];
        list.push(post);
        grouped.set(post.authorId, list);
      }
      return authorIds.map((id) => grouped.get(id) ?? []);
    }),
  };
}

// Create per-request in Express middleware
app.use((req, res, next) => {
  req.loaders = createLoaders();
  next();
});
```

### Prisma Client Extension for Caching

```typescript
const prisma = new PrismaClient().$extends({
  query: {
    $allModels: {
      async findMany({ model, args, query }) {
        const cacheKey = `${model}:findMany:${JSON.stringify(args)}`;
        const cached = await redis.get(cacheKey);
        if (cached) return JSON.parse(cached);

        const result = await query(args);
        await redis.setex(cacheKey, 60, JSON.stringify(result));
        return result;
      },
    },
  },
});
```

---

## Index Recommendations

### Query Pattern → Index Mapping

| Query Pattern | Index Type | Schema |
|--------------|------------|--------|
| `where: { email }` | Unique | `@unique` |
| `where: { status, createdAt }` | Composite | `@@index([status, createdAt])` |
| `orderBy: { createdAt: 'desc' }` | Sort | `@@index([createdAt(sort: Desc)])` |
| `where: { title: { contains: 'x' } }` | Full-text | `@@fulltext([title])` (MySQL) |
| `where: { tenantId, email }` | Composite unique | `@@unique([tenantId, email])` |
| Relation filter: `posts: { some: ... }` | FK index | `@@index([authorId])` |

### Common Indexes to Add

```prisma
model User {
  id        Int      @id @default(autoincrement())
  email     String   @unique
  status    String
  role      String
  createdAt DateTime @default(now())

  // Single-column indexes for frequent lookups
  @@index([status])
  @@index([role])

  // Composite index for filtered + sorted queries
  @@index([status, createdAt(sort: Desc)])

  // Composite index for multi-condition filters
  @@index([role, status])
}

model Post {
  id        Int      @id @default(autoincrement())
  authorId  Int
  published Boolean
  createdAt DateTime @default(now())
  title     String

  // FK index (Prisma doesn't auto-create these for PostgreSQL)
  @@index([authorId])

  // Common query pattern: published posts by date
  @@index([published, createdAt(sort: Desc)])
}
```

### Index Anti-Patterns

```prisma
// ❌ Over-indexing — each index slows writes
model User {
  @@index([email])        // redundant — @unique already creates an index
  @@index([a, b])
  @@index([a, b, c])      // redundant — [a, b] is a prefix of this
  @@index([a])             // redundant — [a, b] covers single-column lookups on `a`
}

// ✅ Minimal effective indexes
model User {
  email String @unique     // unique constraint = unique index
  @@index([a, b, c])       // covers: WHERE a, WHERE a AND b, WHERE a AND b AND c
}
```

### Detecting Missing Indexes

```typescript
// 1. Enable query logging
prisma.$on('query', (e) => {
  if (e.duration > 100) {
    console.warn(`Slow query (${e.duration}ms): ${e.query}`);
  }
});

// 2. Run EXPLAIN on slow queries
const plan = await prisma.$queryRaw`
  EXPLAIN (ANALYZE, BUFFERS)
  SELECT * FROM posts WHERE author_id = 1 AND published = true
  ORDER BY created_at DESC LIMIT 10
`;
// Look for "Seq Scan" — indicates missing index
// Look for "Index Scan" or "Index Only Scan" — index is being used

// 3. PostgreSQL: find unused indexes
const unused = await prisma.$queryRaw`
  SELECT schemaname, tablename, indexname, idx_scan
  FROM pg_stat_user_indexes
  WHERE idx_scan = 0
  ORDER BY pg_relation_size(indexrelid) DESC
`;
```

### Partial Indexes (via Raw Migration)

When you frequently filter by a condition, a partial index is smaller and faster:

```sql
-- In a migration SQL file
CREATE INDEX idx_published_posts ON posts (created_at DESC)
WHERE published = true;

-- Only indexes published posts — much smaller than a full index
-- Perfect for: SELECT * FROM posts WHERE published = true ORDER BY created_at DESC
```

To use partial indexes with Prisma, create them via `prisma migrate dev --create-only` and add the raw SQL to the migration file, or use `$executeRaw` in a custom migration script.
