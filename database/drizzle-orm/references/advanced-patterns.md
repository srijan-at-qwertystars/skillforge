# Drizzle ORM — Advanced Patterns

> Dense reference for dynamic queries, CTEs, window functions, views, multi-schema, seeding, migrations, and connection pooling.

## Table of Contents

- [Dynamic Query Building](#dynamic-query-building)
- [Complex Joins](#complex-joins)
- [Common Table Expressions (CTEs)](#common-table-expressions-ctes)
- [Window Functions](#window-functions)
- [Raw SQL Fragments](#raw-sql-fragments)
- [Custom Column Types](#custom-column-types)
- [Database Views](#database-views)
- [Materialized Views](#materialized-views)
- [Multi-Schema](#multi-schema)
- [Seeding Strategies](#seeding-strategies)
- [Migration Patterns](#migration-patterns)
- [Connection Pool Tuning](#connection-pool-tuning)
- [Batch API](#batch-api)
- [Row-Level Security (RLS)](#row-level-security-rls)
- [Prepared Statements & Performance](#prepared-statements--performance)

---

## Dynamic Query Building

Build queries conditionally by composing filter arrays:

```ts
import { eq, and, or, gte, lte, ilike, SQL } from 'drizzle-orm';

interface UserFilters {
  role?: string;
  active?: boolean;
  search?: string;
  createdAfter?: Date;
  createdBefore?: Date;
}

function findUsers(filters: UserFilters) {
  const conditions: SQL[] = [];

  if (filters.role)          conditions.push(eq(users.role, filters.role));
  if (filters.active !== undefined) conditions.push(eq(users.isActive, filters.active));
  if (filters.search)        conditions.push(ilike(users.name, `%${filters.search}%`));
  if (filters.createdAfter)  conditions.push(gte(users.createdAt, filters.createdAfter));
  if (filters.createdBefore) conditions.push(lte(users.createdAt, filters.createdBefore));

  return db.select().from(users)
    .where(conditions.length ? and(...conditions) : undefined)
    .orderBy(desc(users.createdAt));
}
```

### Dynamic column selection

```ts
function selectFields(includeEmail: boolean) {
  const columns: Record<string, any> = { id: users.id, name: users.name };
  if (includeEmail) columns.email = users.email;
  return db.select(columns).from(users);
}
```

### Dynamic ordering

```ts
import { asc, desc } from 'drizzle-orm';

type SortField = 'name' | 'createdAt';
type SortDir = 'asc' | 'desc';

function sortedUsers(field: SortField, dir: SortDir) {
  const col = field === 'name' ? users.name : users.createdAt;
  const orderFn = dir === 'asc' ? asc : desc;
  return db.select().from(users).orderBy(orderFn(col));
}
```

---

## Complex Joins

### Multi-table join with aliased columns

```ts
const result = await db
  .select({
    postId: posts.id,
    postTitle: posts.title,
    authorName: users.name,
    commentCount: sql<number>`count(${comments.id})`.as('comment_count'),
  })
  .from(posts)
  .innerJoin(users, eq(posts.authorId, users.id))
  .leftJoin(comments, eq(posts.id, comments.postId))
  .groupBy(posts.id, posts.title, users.name);
```

### Self-join

```ts
import { alias } from 'drizzle-orm';

const managers = alias(users, 'managers');

const employeesWithManagers = await db
  .select({
    employee: users.name,
    manager: managers.name,
  })
  .from(users)
  .leftJoin(managers, eq(users.managerId, managers.id));
```

### Full outer join (PostgreSQL)

```ts
const result = await db
  .select()
  .from(tableA)
  .fullJoin(tableB, eq(tableA.id, tableB.aId));
```

---

## Common Table Expressions (CTEs)

Use `db.$with()` to define CTEs and `.with()` to consume them:

```ts
// Simple CTE
const recentUsers = db.$with('recent_users').as(
  db.select().from(users).where(gte(users.createdAt, lastWeek))
);

const result = await db.with(recentUsers)
  .select()
  .from(recentUsers);
```

### Multiple CTEs

```ts
const activeUsers = db.$with('active_users').as(
  db.select({ id: users.id }).from(users).where(eq(users.isActive, true))
);

const userPosts = db.$with('user_posts').as(
  db.select({
    authorId: posts.authorId,
    postCount: sql<number>`count(*)`.as('post_count'),
  }).from(posts).groupBy(posts.authorId)
);

const result = await db
  .with(activeUsers, userPosts)
  .select({
    userId: activeUsers.id,
    postCount: userPosts.postCount,
  })
  .from(activeUsers)
  .leftJoin(userPosts, eq(activeUsers.id, userPosts.authorId));
```

### Recursive CTE (raw SQL)

```ts
const hierarchy = await db.execute(sql`
  WITH RECURSIVE org_tree AS (
    SELECT id, name, manager_id, 1 AS depth
    FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.id, e.name, e.manager_id, ot.depth + 1
    FROM employees e
    JOIN org_tree ot ON e.manager_id = ot.id
  )
  SELECT * FROM org_tree ORDER BY depth
`);
```

---

## Window Functions

Drizzle exposes window functions via `sql` template fragments:

```ts
// ROW_NUMBER
const ranked = await db.select({
  id: users.id,
  name: users.name,
  rowNum: sql<number>`ROW_NUMBER() OVER (ORDER BY ${users.createdAt} DESC)`,
}).from(users);

// RANK with PARTITION
const partitioned = await db.select({
  id: posts.id,
  title: posts.title,
  authorId: posts.authorId,
  rank: sql<number>`RANK() OVER (PARTITION BY ${posts.authorId} ORDER BY ${posts.createdAt} DESC)`,
}).from(posts);

// Running total
const runningTotal = await db.select({
  id: orders.id,
  amount: orders.amount,
  cumulative: sql<number>`SUM(${orders.amount}) OVER (ORDER BY ${orders.createdAt})`,
}).from(orders);

// LAG / LEAD
const withPrev = await db.select({
  id: orders.id,
  amount: orders.amount,
  prevAmount: sql<number>`LAG(${orders.amount}) OVER (ORDER BY ${orders.createdAt})`,
}).from(orders);
```

---

## Raw SQL Fragments

The `sql` template tag interpolates columns and values safely (parameterized):

```ts
import { sql } from 'drizzle-orm';

// Type-cast the result
const lower = sql<string>`lower(${users.name})`;
const result = await db.select({ id: users.id, lowerName: lower }).from(users);

// Use in WHERE
const recent = await db.select().from(users)
  .where(sql`${users.createdAt} > NOW() - INTERVAL '7 days'`);

// Raw execute
const raw = await db.execute(sql`SELECT NOW()`);

// Embed table/column references safely
const counted = await db.execute(
  sql`SELECT ${users.role}, count(*) as cnt FROM ${users} GROUP BY ${users.role}`
);

// sql.raw() for unparameterized fragments (use carefully)
const tableName = 'users';
await db.execute(sql`SELECT * FROM ${sql.raw(tableName)} LIMIT 10`);
```

### sql.join() for dynamic IN-lists or fragments

```ts
const ids = [1, 2, 3];
const placeholders = sql.join(ids.map(id => sql`${id}`), sql`, `);
const result = await db.execute(sql`SELECT * FROM ${users} WHERE id IN (${placeholders})`);
```

---

## Custom Column Types

```ts
import { customType } from 'drizzle-orm/pg-core';

// Case-insensitive text (citext extension)
const citext = customType<{ data: string }>({
  dataType() { return 'citext'; },
});

// PostGIS geometry
const point = customType<{ data: { x: number; y: number }; driverData: string }>({
  dataType() { return 'geometry(Point, 4326)'; },
  toDriver(value) { return `SRID=4326;POINT(${value.x} ${value.y})`; },
  fromDriver(value) {
    const match = value.match(/POINT\((.+) (.+)\)/);
    return { x: parseFloat(match![1]), y: parseFloat(match![2]) };
  },
});

// Money stored as integer cents
const money = customType<{ data: number; driverData: number }>({
  dataType() { return 'integer'; },
  toDriver(value) { return Math.round(value * 100); },
  fromDriver(value) { return value / 100; },
});

// Usage
const locations = pgTable('locations', {
  id: serial('id').primaryKey(),
  name: text('name').notNull(),
  position: point('position'),
  email: citext('email').notNull(),
  price: money('price_cents'),
});
```

---

## Database Views

### PostgreSQL views

```ts
import { pgView } from 'drizzle-orm/pg-core';

// Inferred schema from query builder
export const activeUsersView = pgView('active_users').as((qb) =>
  qb.select({
    id: users.id,
    name: users.name,
    email: users.email,
  }).from(users).where(eq(users.isActive, true))
);

// Query the view like a table
const activeUsers = await db.select().from(activeUsersView);
```

### MySQL views

```ts
import { mysqlView } from 'drizzle-orm/mysql-core';

export const userStatsView = mysqlView('user_stats').as((qb) =>
  qb.select({
    userId: users.id,
    postCount: sql<number>`count(${posts.id})`.as('post_count'),
  }).from(users)
    .leftJoin(posts, eq(users.id, posts.authorId))
    .groupBy(users.id)
);
```

### SQLite views

```ts
import { sqliteView } from 'drizzle-orm/sqlite-core';

export const recentPostsView = sqliteView('recent_posts').as((qb) =>
  qb.select().from(posts)
    .where(gte(posts.createdAt, sql`datetime('now', '-30 days')`))
);
```

### Existing views (no management by Drizzle)

```ts
// Reference a view that already exists in the DB
export const existingView = pgView('legacy_report', {
  id: integer('id'),
  total: integer('total'),
}).existing();
```

---

## Materialized Views

Drizzle supports `pgMaterializedView` for PostgreSQL:

```ts
import { pgMaterializedView } from 'drizzle-orm/pg-core';

export const monthlyStats = pgMaterializedView('monthly_stats').as((qb) =>
  qb.select({
    month: sql<string>`date_trunc('month', ${orders.createdAt})`.as('month'),
    revenue: sql<number>`sum(${orders.amount})`.as('revenue'),
    orderCount: sql<number>`count(*)`.as('order_count'),
  }).from(orders).groupBy(sql`date_trunc('month', ${orders.createdAt})`)
);

// Query it like a table
const stats = await db.select().from(monthlyStats);

// Refresh via raw SQL (drizzle-kit won't manage refresh)
await db.execute(sql`REFRESH MATERIALIZED VIEW CONCURRENTLY monthly_stats`);
```

For MySQL/SQLite: use raw SQL migrations to create materialized views (not natively supported by those DBs).

---

## Multi-Schema

### PostgreSQL schema namespaces

```ts
import { pgSchema } from 'drizzle-orm/pg-core';

const billingSchema = pgSchema('billing');
const authSchema = pgSchema('auth');

export const invoices = billingSchema.table('invoices', {
  id: serial('id').primaryKey(),
  userId: integer('user_id').notNull(),
  amount: integer('amount').notNull(),
  paidAt: timestamp('paid_at'),
});

export const sessions = authSchema.table('sessions', {
  id: uuid('id').primaryKey().defaultRandom(),
  userId: integer('user_id').notNull(),
  expiresAt: timestamp('expires_at').notNull(),
});

// Generates: SELECT * FROM "billing"."invoices"
const allInvoices = await db.select().from(invoices);
```

### Cross-schema joins

```ts
const result = await db
  .select({ sessionId: sessions.id, invoiceAmount: invoices.amount })
  .from(sessions)
  .innerJoin(invoices, eq(sessions.userId, invoices.userId));
```

### drizzle-kit config for multi-schema

```ts
export default defineConfig({
  schema: './src/db/schema/*.ts',
  schemaFilter: ['public', 'billing', 'auth'],
  // ...
});
```

---

## Seeding Strategies

### Manual seed script

```ts
// seed.ts
import { db } from './db';
import { users, posts, tags } from './schema';

async function seed() {
  await db.transaction(async (tx) => {
    // Clear tables (order matters for FK constraints)
    await tx.delete(posts);
    await tx.delete(users);

    const [alice, bob] = await tx.insert(users).values([
      { name: 'Alice', email: 'alice@example.com', role: 'admin' },
      { name: 'Bob', email: 'bob@example.com', role: 'user' },
    ]).returning();

    await tx.insert(posts).values([
      { title: 'First Post', content: 'Hello world', authorId: alice.id },
      { title: 'Second Post', content: 'Drizzle is great', authorId: bob.id },
    ]);
  });
  console.log('Seeded successfully');
}

seed().catch(console.error).finally(() => process.exit());
```

### Using drizzle-seed (official package)

```bash
npm i drizzle-seed
```

```ts
import { seed } from 'drizzle-seed';

await seed(db, { users, posts }).refine((f) => ({
  users: {
    count: 50,
    columns: {
      name: f.fullName(),
      email: f.email(),
    },
  },
  posts: {
    count: 200,
    columns: {
      title: f.loremIpsum({ sentenceCount: 1 }),
    },
  },
}));
```

### Environment-gated seeding

```ts
// In app startup
if (process.env.NODE_ENV === 'development') {
  const { seed } = await import('./seed');
  await seed();
}
```

---

## Migration Patterns

### generate vs push

| Aspect          | `drizzle-kit generate` + `migrate` | `drizzle-kit push`       |
|-----------------|-------------------------------------|--------------------------|
| Migration files | ✅ Versioned SQL files              | ❌ None                  |
| Audit trail     | ✅ Git-tracked                      | ❌ No history            |
| Team-safe       | ✅ Reproducible                     | ❌ Solo dev only         |
| Speed           | Slightly slower                     | ✅ Instant               |
| Rollback        | Manual (reverse SQL)                | ❌ Not possible          |
| Best for        | Staging, production, teams          | Prototyping, local dev   |

### Recommended workflow

```bash
# Development: iterate fast
npx drizzle-kit push

# Pre-commit: generate migration files
npx drizzle-kit generate

# Review generated SQL in ./drizzle/

# CI/CD or production: apply migrations
npx drizzle-kit migrate
# OR programmatically:
```

```ts
import { migrate } from 'drizzle-orm/node-postgres/migrator';
await migrate(db, { migrationsFolder: './drizzle' });
```

### Brownfield (existing database)

```bash
npx drizzle-kit pull    # Introspect DB → generate schema.ts
# Review and adjust generated schema
npx drizzle-kit generate  # Now track changes going forward
```

### Handling merge conflicts in migrations

1. Accept incoming changes to `meta/_journal.json` and snapshot files
2. Delete your conflicting migration files
3. Re-run `npx drizzle-kit generate` to regenerate from current schema
4. Verify with `npx drizzle-kit check`

---

## Connection Pool Tuning

Drizzle delegates pooling to the underlying driver. Configure per-database:

### PostgreSQL (node-postgres / pg)

```ts
import { Pool } from 'pg';
import { drizzle } from 'drizzle-orm/node-postgres';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,                    // Max connections (default: 10)
  idleTimeoutMillis: 30000,   // Close idle connections after 30s
  connectionTimeoutMillis: 5000, // Fail if can't connect in 5s
  allowExitOnIdle: true,      // Allow process exit when pool idle
});

const db = drizzle(pool, { schema });

// Graceful shutdown
process.on('SIGTERM', () => pool.end());
```

### PostgreSQL (postgres.js)

```ts
import postgres from 'postgres';

const client = postgres(process.env.DATABASE_URL!, {
  max: 10,
  idle_timeout: 20,
  connect_timeout: 10,
  prepare: true,  // Use prepared statements (faster repeated queries)
});

const db = drizzle(client, { schema });

// Shutdown
process.on('SIGTERM', () => client.end());
```

### MySQL (mysql2)

```ts
import mysql from 'mysql2/promise';

const pool = mysql.createPool({
  uri: process.env.DATABASE_URL,
  connectionLimit: 10,
  queueLimit: 0,
  waitForConnections: true,
  enableKeepAlive: true,
  keepAliveInitialDelay: 10000,
});

const db = drizzle(pool, { schema, mode: 'default' });
```

### Serverless / Edge guidelines

- **Neon**: Use `@neondatabase/serverless` — HTTP-based, no pool needed
- **PlanetScale**: Use `@planetscale/database` — serverless driver
- **Cloudflare D1**: Binding-based, no pool
- **Turso**: `@libsql/client` — HTTP, no pool
- Pool size in serverless: keep low (1–5) or use external pooler (PgBouncer, Neon pooler)

---

## Batch API

Execute multiple operations in a single round-trip (LibSQL, Neon, D1):

```ts
const [insertedUsers, allPosts, updatedCount] = await db.batch([
  db.insert(users).values({ name: 'Alice', email: 'alice@test.com' }).returning(),
  db.select().from(posts),
  db.update(users).set({ isActive: false }).where(lt(users.createdAt, cutoff)),
]);
```

> **Note**: Batch is transactional on supported drivers. If one query fails, all roll back.

---

## Row-Level Security (RLS)

Implement RLS patterns with Drizzle for multi-tenant apps:

```ts
// Set tenant context per request
async function withTenant<T>(tenantId: string, fn: (db: typeof db) => Promise<T>) {
  return db.transaction(async (tx) => {
    await tx.execute(sql`SET LOCAL app.tenant_id = ${tenantId}`);
    return fn(tx as any);
  });
}

// PostgreSQL RLS policy (apply via migration)
// CREATE POLICY tenant_isolation ON orders
//   USING (tenant_id = current_setting('app.tenant_id')::uuid);
```

---

## Prepared Statements & Performance

```ts
import { placeholder } from 'drizzle-orm';

// Prepare once, execute many (reuses query plan)
const findByRole = db.select().from(users)
  .where(eq(users.role, placeholder('role')))
  .prepare('find_by_role');

const admins = await findByRole.execute({ role: 'admin' });
const guests = await findByRole.execute({ role: 'guest' });

// Prepared with multiple placeholders
const findInRange = db.select().from(orders)
  .where(and(
    gte(orders.createdAt, placeholder('start')),
    lte(orders.createdAt, placeholder('end')),
  ))
  .prepare('find_in_range');

const q1Orders = await findInRange.execute({
  start: new Date('2024-01-01'),
  end: new Date('2024-03-31'),
});
```
