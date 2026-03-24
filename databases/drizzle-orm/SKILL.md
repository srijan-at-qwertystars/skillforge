---
name: drizzle-orm
description: >
  Build type-safe SQL with Drizzle ORM in TypeScript. TRIGGER when: code imports
  'drizzle-orm', 'drizzle-orm/pg-core', 'drizzle-orm/mysql-core',
  'drizzle-orm/sqlite-core', 'drizzle-kit', or user mentions Drizzle ORM,
  pgTable, sqliteTable, mysqlTable, drizzle schema, drizzle migrations,
  drizzle-kit generate/push/migrate/studio/introspect, or drizzle.config.ts.
  Also trigger for drizzle relations, drizzle query builder, drizzle prepared
  statements, drizzle transactions. DO NOT TRIGGER for: Prisma, TypeORM, Kysely,
  Sequelize, Knex, MikroORM, or generic SQL/database questions without Drizzle
  context. DO NOT TRIGGER for MongoDB, Mongoose, or NoSQL databases.
---

# Drizzle ORM

## Philosophy

Drizzle is a TypeScript ORM that looks and feels like SQL. Zero runtime overhead, no code generation step, no binary engine. Schema lives in TypeScript — import it, query it, infer types from it. Bundle is <8KB gzipped with zero dependencies. First-class serverless and edge support (Neon, PlanetScale, Turso, Cloudflare D1, Vercel Postgres, AWS Data API).

Two query APIs: SQL-like query builder (select/insert/update/delete with joins, subqueries, CTEs) and relational query API (Prisma-style `findMany`/`findFirst` with `with` for nested loading). Use both in the same project.

## Setup

Install core packages per dialect:

```bash
# PostgreSQL
npm i drizzle-orm postgres        # or pg, @neondatabase/serverless, @vercel/postgres
npm i -D drizzle-kit

# MySQL
npm i drizzle-orm mysql2
npm i -D drizzle-kit

# SQLite
npm i drizzle-orm better-sqlite3  # or @libsql/client for Turso, bun:sqlite
npm i -D drizzle-kit
```

Initialize the client — always pass `{ schema }` to enable the relational query API:

```typescript
// PostgreSQL with postgres-js
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from './schema';
export const db = drizzle(postgres(process.env.DATABASE_URL!), { schema });

// SQLite with better-sqlite3
import { drizzle } from 'drizzle-orm/better-sqlite3';
import Database from 'better-sqlite3';
export const db = drizzle(new Database('local.db'), { schema });

// MySQL with mysql2
import { drizzle } from 'drizzle-orm/mysql2';
import mysql from 'mysql2/promise';
export const db = drizzle(await mysql.createPool(process.env.DATABASE_URL!), { schema });
```

## Schema Definition

Define tables with dialect-specific helpers. Each column call takes the DB column name as argument.

```typescript
// src/db/schema.ts
import { pgTable, serial, text, integer, timestamp, boolean, varchar, index, uniqueIndex, pgEnum } from 'drizzle-orm/pg-core';

// Enums (Postgres only)
export const roleEnum = pgEnum('role', ['user', 'admin', 'moderator']);

export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  name: text('name').notNull(),
  email: varchar('email', { length: 255 }).unique().notNull(),
  role: roleEnum('role').default('user'),
  createdAt: timestamp('created_at').defaultNow().notNull(),
  isActive: boolean('is_active').default(true),
}, (table) => [
  uniqueIndex('email_idx').on(table.email),
]);

export const posts = pgTable('posts', {
  id: serial('id').primaryKey(),
  title: text('title').notNull(),
  content: text('content'),
  published: boolean('published').default(false),
  authorId: integer('author_id').references(() => users.id, { onDelete: 'cascade' }).notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
}, (table) => [
  index('author_idx').on(table.authorId),
]);

export const comments = pgTable('comments', {
  id: serial('id').primaryKey(),
  text: text('text').notNull(),
  postId: integer('post_id').references(() => posts.id, { onDelete: 'cascade' }).notNull(),
  authorId: integer('author_id').references(() => users.id).notNull(),
});
```

For SQLite use `sqliteTable`, `integer`, `text`, `blob`, `real`. For MySQL use `mysqlTable`, `int`, `varchar`, `mysqlEnum`, `datetime`.

### Composite Keys and Constraints

```typescript
export const postTags = pgTable('post_tags', {
  postId: integer('post_id').references(() => posts.id).notNull(),
  tagId: integer('tag_id').references(() => tags.id).notNull(),
}, (table) => [
  primaryKey({ columns: [table.postId, table.tagId] }),
]);
```

## Relations

Relations are declared separately from tables. They enable the relational query API but do NOT create foreign keys — use `.references()` on columns for FK constraints.

```typescript
import { relations } from 'drizzle-orm';

// One-to-many: user has many posts
export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

// Many-to-one: post belongs to user; one-to-many: post has many comments
export const postsRelations = relations(posts, ({ one, many }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
  comments: many(comments),
}));

// Many-to-one: comment belongs to post and user
export const commentsRelations = relations(comments, ({ one }) => ({
  post: one(posts, { fields: [comments.postId], references: [posts.id] }),
  author: one(users, { fields: [comments.authorId], references: [users.id] }),
}));
```

For many-to-many, define a junction table and two one-to-many relations through it:

```typescript
export const postTagsRelations = relations(postTags, ({ one }) => ({
  post: one(posts, { fields: [postTags.postId], references: [posts.id] }),
  tag: one(tags, { fields: [postTags.tagId], references: [tags.id] }),
}));
export const tagsRelations = relations(tags, ({ many }) => ({
  postTags: many(postTags),
}));
```

## Query Builder

### Select

```typescript
import { eq, ne, gt, gte, lt, lte, like, ilike, and, or, not, inArray, isNull, sql, desc, asc, count, sum, avg } from 'drizzle-orm';

// Basic select
const allUsers = await db.select().from(users);

// Where clause
const activeAdmins = await db.select()
  .from(users)
  .where(and(eq(users.role, 'admin'), eq(users.isActive, true)));

// Partial select (only requested columns returned — reduces payload)
const names = await db.select({ id: users.id, name: users.name }).from(users);
// => { id: number; name: string }[]

// With ordering and limit
const recent = await db.select().from(posts)
  .where(eq(posts.published, true))
  .orderBy(desc(posts.createdAt))
  .limit(10)
  .offset(20);

// Aggregations
const postCounts = await db.select({
  authorId: posts.authorId,
  count: count(),
}).from(posts).groupBy(posts.authorId);

// Subquery
const sq = db.select({ authorId: posts.authorId, postCount: count().as('post_count') })
  .from(posts).groupBy(posts.authorId).as('sq');

const usersWithCounts = await db.select({
  name: users.name,
  postCount: sq.postCount,
}).from(users).leftJoin(sq, eq(users.id, sq.authorId));
```

### Joins

```typescript
const postsWithAuthors = await db.select({
  postTitle: posts.title,
  authorName: users.name,
}).from(posts)
  .innerJoin(users, eq(posts.authorId, users.id))
  .where(eq(posts.published, true));
```

### Insert

```typescript
// Single insert
const [newUser] = await db.insert(users)
  .values({ name: 'Alice', email: 'alice@example.com' })
  .returning();  // .returning() is Postgres/SQLite only

// Bulk insert
await db.insert(posts).values([
  { title: 'Post 1', authorId: newUser.id },
  { title: 'Post 2', authorId: newUser.id },
]);

// Upsert (on conflict)
await db.insert(users)
  .values({ name: 'Alice', email: 'alice@example.com' })
  .onConflictDoUpdate({
    target: users.email,
    set: { name: 'Alice Updated' },
  });

await db.insert(users)
  .values({ name: 'Maybe', email: 'maybe@example.com' })
  .onConflictDoNothing();
```

### Update

```typescript
const [updated] = await db.update(users)
  .set({ isActive: false })
  .where(eq(users.id, 1))
  .returning();
```

### Delete

```typescript
await db.delete(posts).where(eq(posts.authorId, 1));
```

## Relational Query API

Requires `{ schema }` passed to `drizzle()`. Uses `db.query.<tableName>`.

```typescript
// Find many with nested relations
const usersWithPosts = await db.query.users.findMany({
  with: {
    posts: {
      with: { comments: true },
      where: (posts, { eq }) => eq(posts.published, true),
      orderBy: (posts, { desc }) => [desc(posts.createdAt)],
      limit: 5,
    },
  },
  where: (users, { eq }) => eq(users.isActive, true),
});
// => { id, name, email, posts: { id, title, comments: [...] }[] }[]

// Find first
const user = await db.query.users.findFirst({
  where: (users, { eq }) => eq(users.id, 1),
  columns: { id: true, name: true, email: true },  // partial select
  with: { posts: true },
});
```

## Drizzle Kit

### Configuration

```typescript
// drizzle.config.ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  schema: './src/db/schema.ts',
  out: './drizzle',
  dialect: 'postgresql',  // 'mysql' | 'sqlite' | 'turso'
  dbCredentials: {
    url: process.env.DATABASE_URL!,
  },
});
```

### Commands

```bash
npx drizzle-kit generate   # Generate SQL migration from schema diff
npx drizzle-kit migrate    # Apply pending migrations to database
npx drizzle-kit push       # Push schema directly (dev/prototyping only)
npx drizzle-kit pull       # Introspect DB → generate TypeScript schema
npx drizzle-kit studio     # Launch visual data browser (port 4983)
npx drizzle-kit check      # Verify migration consistency
npx drizzle-kit up         # Upgrade migration snapshots to latest format
```

### Migrations Workflow

**Production**: `generate` → review SQL → `migrate`. Always commit migration files.

```typescript
// Run migrations programmatically at app startup
import { migrate } from 'drizzle-orm/postgres-js/migrator';
await migrate(db, { migrationsFolder: './drizzle' });
```

**Development**: Use `push` for rapid iteration — applies schema directly without migration files. Switch to `generate`/`migrate` before shipping.

### Custom Migrations

Edit generated SQL files in `./drizzle/` to add data migrations alongside DDL.

## Prepared Statements

Use `sql.placeholder()` for parameterized queries that are parsed once and executed many times:

```typescript
const getUserById = db.select().from(users)
  .where(eq(users.id, sql.placeholder('id')))
  .prepare('get_user_by_id');

// Execute repeatedly with different params
const user1 = await getUserById.execute({ id: 1 });
const user2 = await getUserById.execute({ id: 2 });
```

## Transactions

```typescript
await db.transaction(async (tx) => {
  const [user] = await tx.insert(users)
    .values({ name: 'Bob', email: 'bob@example.com' })
    .returning();

  await tx.insert(posts).values({
    title: 'First Post',
    authorId: user.id,
  });

  // Explicit rollback
  if (someConditionFails) {
    tx.rollback();  // throws, aborts transaction
    return;
  }
});

// Nested transactions use savepoints
await db.transaction(async (tx) => {
  await tx.insert(users).values({ name: 'Outer', email: 'outer@e.com' });
  await tx.transaction(async (tx2) => { /* savepoint */ });
});
```

## Type Inference

```typescript
// Approach 1: Table property (preferred)
type User = typeof users.$inferSelect;       // Row returned by SELECT
type NewUser = typeof users.$inferInsert;     // Payload for INSERT

// Approach 2: Helper functions
import { InferSelectModel, InferInsertModel } from 'drizzle-orm';
type User = InferSelectModel<typeof users>;
type NewUser = InferInsertModel<typeof users>;
```

`$inferInsert` makes columns with defaults/nullables optional. `$inferSelect` includes all columns as non-optional (matching the DB row shape). Use these types in function signatures for end-to-end safety.

## Framework Integration

> **See [references/framework-integration.md](references/framework-integration.md)** for complete patterns for Next.js (Server Components, Server Actions, Edge), Remix, SvelteKit, Hono, tRPC, and all database providers.

### Next.js (App Router) — Singleton Pattern

```typescript
// src/db/index.ts — prevent connection leaks during HMR
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
import * as schema from './schema';

const globalForDb = globalThis as unknown as { db: ReturnType<typeof drizzle> };
export const db = globalForDb.db ?? drizzle(postgres(process.env.DATABASE_URL!), { schema });
if (process.env.NODE_ENV !== 'production') globalForDb.db = db;
```

### Edge Runtime

For edge routes, use HTTP-based drivers (no TCP on edge):

```typescript
import { neon } from '@neondatabase/serverless';
import { drizzle } from 'drizzle-orm/neon-http';
export const runtime = 'edge';
const db = drizzle(neon(process.env.DATABASE_URL!));
```

### Connection Pooling

- **Traditional server**: `postgres()` or `pg.Pool` with `max` limit.
- **Serverless/Edge**: Use HTTP drivers (Neon HTTP, PlanetScale, Vercel Postgres). Instantiate per-request.
- **Lambda**: Use poolers (PgBouncer, Neon pooled strings). Set `max: 1-5`.

## Performance Patterns

- **Partial selects**: Select only needed columns to reduce I/O.
- **Batch inserts**: Use `.values([...])` for bulk inserts — single round-trip.
- **Indexes**: Define in table's third argument. Always index FKs and filtered columns.
- **Prepared statements**: Use for hot-path queries executed repeatedly.
- **Avoid N+1**: Use relational queries with `with` or explicit joins.
- **Selective returning**: `.returning({ id: users.id })` to avoid fetching all columns.

## Testing Patterns

### In-Memory SQLite for Unit Tests

```typescript
// test/setup.ts
import { drizzle } from 'drizzle-orm/better-sqlite3';
import Database from 'better-sqlite3';
import { migrate } from 'drizzle-orm/better-sqlite3/migrator';
import * as schema from '../src/db/schema';

export function createTestDb() {
  const sqlite = new Database(':memory:');
  const db = drizzle(sqlite, { schema });
  migrate(db, { migrationsFolder: './drizzle' });
  return db;
}

// test/users.test.ts
import { createTestDb } from './setup';
const db = createTestDb();
// Each test file gets a fresh in-memory database
```

### Transaction Rollback Isolation

Wrap each test in a rolled-back transaction for isolation, or truncate tables between tests.

### Docker/Testcontainers for Integration Tests

Use a real database per test suite via Testcontainers. Apply migrations with `push` or `migrate`.

## Common Pitfalls

1. **Missing `{ schema }` in `drizzle()` call**: Relational queries (`db.query.*`) silently fail or error. Always pass schema.
2. **Confusing relations with foreign keys**: `relations()` only enables the query API. Use `.references()` on columns for actual DB constraints.
3. **Using `push` in production**: `push` can drop columns/tables. Use `generate` + `migrate` for production.
4. **Forgetting `.notNull()`**: Columns are nullable by default. Explicitly mark required columns.
5. **Wrong column name string**: The string argument to column helpers (`text('name')`) must match the DB column name, not the JS property.
6. **Not indexing foreign keys**: Postgres does not auto-index FK columns. Add indexes explicitly.
7. **Singleton in dev with HMR**: Next.js/Vite hot reload creates multiple connections. Use the globalThis singleton pattern.
8. **Pool exhaustion in serverless**: Set low `max` connection limits. Use HTTP drivers or poolers for serverless.
9. **`.returning()` on MySQL**: MySQL does not support `RETURNING`. Use `insertId` from the result instead.
10. **Circular imports in schema files**: Split large schemas into multiple files but ensure no circular dependencies between table definitions.

## References

- **[Advanced Patterns](references/advanced-patterns.md)** — Dynamic query building, conditional WHERE, raw SQL, custom types, JSON/array columns, generated columns, views, subqueries, CTEs, window functions, full-text search, PostGIS, multi-schema support
- **[Troubleshooting](references/troubleshooting.md)** — Type inference fixes, migration conflicts, push vs migrate, pool exhaustion, prepared statements, column type mismatches, N+1, circular references, introspect issues, ESM/CJS
- **[Framework Integration](references/framework-integration.md)** — Next.js App Router (Server Components, Server Actions, Edge), Remix, SvelteKit, Hono, tRPC, Neon, Turso, PlanetScale, Supabase, Vercel Postgres, D1

## Scripts

- **[setup-drizzle.sh](scripts/setup-drizzle.sh)** — Initialize Drizzle in an existing project (detects package manager, installs deps, creates config and schema)
- **[generate-schema.sh](scripts/generate-schema.sh)** — Introspect an existing database and generate Drizzle schema files
- **[seed-database.ts](scripts/seed-database.ts)** — TypeScript seed script template with Drizzle and @faker-js/faker

## Assets

- **[drizzle.config.ts](assets/drizzle.config.ts)** — Complete config template with all options annotated
- **[schema-template.ts](assets/schema-template.ts)** — Schema file with users, posts, tags, comments, many-to-many, self-referencing, soft-delete
- **[db-client.ts](assets/db-client.ts)** — Database client setup for 11 driver variants (postgres-js, pg, Neon, Vercel, PlanetScale, mysql2, better-sqlite3, Turso, D1, Bun)
- **[docker-compose.yml](assets/docker-compose.yml)** — Docker Compose for local Postgres 16 + pgAdmin
