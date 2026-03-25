---
name: drizzle-orm
description: >
  Use when working with Drizzle ORM: defining schemas (pgTable, mysqlTable, sqliteTable),
  writing type-safe queries (select, insert, update, delete), configuring relations (one, many),
  using the relational query API (query.findFirst, query.findMany with), running drizzle-kit
  commands (generate, migrate, push, pull, studio), setting up database drivers (node-postgres,
  mysql2, better-sqlite3, @libsql/client), connection pooling, edge runtime support (Cloudflare
  Workers, Vercel Edge, Bun), type inference ($inferSelect, $inferInsert), custom types, pgEnum,
  upserts (onConflictDoUpdate), prepared statements, transactions, joins, subqueries, and SQL
  template literals. Also use for Drizzle with Next.js, Bun, or Cloudflare Workers.
  Do NOT use for: Prisma schema or Prisma Client, TypeORM or Sequelize, SQLAlchemy, raw SQL
  without an ORM layer, MongoDB/Mongoose, Knex.js query building without Drizzle.
---

# Drizzle ORM

Drizzle is a TypeScript-first SQL ORM with zero runtime dependencies (~7.4 KB gzipped). It supports PostgreSQL, MySQL, SQLite, and Turso/libSQL. It provides a SQL-like query builder AND a relational query API.

## Installation

Always install both `drizzle-orm` and `drizzle-kit`:
```bash
npm i drizzle-orm pg                   # PostgreSQL (swap pg for: mysql2 | better-sqlite3 | @libsql/client)
npm i -D drizzle-kit @types/pg         # @types/better-sqlite3 for SQLite
```

## Database Connection

```ts
// PostgreSQL (node-postgres)
import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';
const db = drizzle(new Pool({ connectionString: process.env.DATABASE_URL }));

// PostgreSQL (postgres.js — edge-compatible)
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
const db = drizzle(postgres(process.env.DATABASE_URL!));

// MySQL
import { drizzle } from 'drizzle-orm/mysql2';
import mysql from 'mysql2/promise';
const db = drizzle(mysql.createPool({ uri: process.env.DATABASE_URL }));

// SQLite (better-sqlite3)
import { drizzle } from 'drizzle-orm/better-sqlite3';
import Database from 'better-sqlite3';
const db = drizzle(new Database('sqlite.db'));

// Turso / libSQL
import { drizzle } from 'drizzle-orm/libsql';
import { createClient } from '@libsql/client';
const db = drizzle(createClient({ url: process.env.TURSO_URL!, authToken: process.env.TURSO_TOKEN }));

// Cloudflare D1: const db = drizzle(env.DB);
// Neon Serverless: import { neon } from '@neondatabase/serverless'; const db = drizzle(neon(url));
```

Pass schema for relational queries: `const db = drizzle(pool, { schema });`

## Schema Definition

### PostgreSQL
```ts
import { pgTable, pgEnum, serial, integer, text, varchar, boolean, timestamp,
  jsonb, uuid, index, uniqueIndex } from 'drizzle-orm/pg-core';

export const roleEnum = pgEnum('role', ['admin', 'user', 'guest']);

export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  name: text('name').notNull(),
  email: varchar('email', { length: 320 }).notNull().unique(),
  role: roleEnum('role').default('user'),
  isActive: boolean('is_active').default(true),
  metadata: jsonb('metadata').$type<{ plan: string }>(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
}, (t) => [
  index('email_idx').on(t.email),
]);
```

### MySQL
```ts
import { mysqlTable, serial, int, varchar, boolean, timestamp, json,
  mysqlEnum, index } from 'drizzle-orm/mysql-core';
export const users = mysqlTable('users', {
  id: serial('id').primaryKey(),
  name: varchar('name', { length: 255 }).notNull(),
  email: varchar('email', { length: 320 }).notNull().unique(),
  role: mysqlEnum('role', ['admin', 'user']).default('user'),
  metadata: json('metadata'),
  createdAt: timestamp('created_at').defaultNow(),
}, (t) => [index('email_idx').on(t.email)]);
```

### SQLite
```ts
import { sqliteTable, integer, text, index } from 'drizzle-orm/sqlite-core';
export const users = sqliteTable('users', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  name: text('name').notNull(),
  email: text('email').notNull().unique(),
  role: text('role', { enum: ['admin', 'user'] }).default('user'),
  createdAt: integer('created_at', { mode: 'timestamp' }).$defaultFn(() => new Date()),
}, (t) => [index('email_idx').on(t.email)]);
```

### Column Types Quick Reference
| PostgreSQL | MySQL | SQLite |
|---|---|---|
| `serial`, `integer`, `bigint` | `serial`, `int`, `bigint` | `integer` |
| `text`, `varchar({length})` | `varchar({length})`, `text` | `text` |
| `boolean` | `boolean` | `integer({mode:'boolean'})` |
| `timestamp`, `date` | `timestamp`, `datetime` | `integer({mode:'timestamp'})` |
| `jsonb`, `json` | `json` | `text({mode:'json'})` |
| `uuid` | — | — |
| `real`, `doublePrecision` | `float`, `double` | `real` |

### Composite Primary Keys and Unique Constraints
```ts
import { primaryKey, unique } from 'drizzle-orm/pg-core';

export const userRoles = pgTable('user_roles', {
  userId: integer('user_id').notNull(),
  roleId: integer('role_id').notNull(),
}, (t) => [
  primaryKey({ columns: [t.userId, t.roleId] }),
  unique('uniq_user_role').on(t.userId, t.roleId),
]);
```

## Relations

Define relations separately from schema. Required for the relational query API.

```ts
import { relations } from 'drizzle-orm';

export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  name: text('name').notNull(),
});

export const posts = pgTable('posts', {
  id: serial('id').primaryKey(),
  title: text('title').notNull(),
  content: text('content'),
  authorId: integer('author_id').notNull().references(() => users.id),
});

export const comments = pgTable('comments', {
  id: serial('id').primaryKey(),
  text: text('text').notNull(),
  postId: integer('post_id').notNull().references(() => posts.id),
  authorId: integer('author_id').notNull().references(() => users.id),
});

// One-to-many: user has many posts
export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
  comments: many(comments),
}));

// Many-to-one: post belongs to user; one-to-many: post has many comments
export const postsRelations = relations(posts, ({ one, many }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
  comments: many(comments),
}));

export const commentsRelations = relations(comments, ({ one }) => ({
  post: one(posts, { fields: [comments.postId], references: [posts.id] }),
  author: one(users, { fields: [comments.authorId], references: [users.id] }),
}));
```

## Query Builder (CRUD)

### Select
```ts
import { eq, ne, gt, lt, gte, lte, like, ilike, and, or, not,
  inArray, isNull, between, sql, asc, desc, count } from 'drizzle-orm';

const allUsers = await db.select().from(users);
const admins = await db.select().from(users).where(eq(users.role, 'admin'));
const names = await db.select({ name: users.name }).from(users);

// Multiple conditions
const result = await db.select().from(users).where(
  and(eq(users.role, 'user'), gte(users.createdAt, new Date('2024-01-01')))
);
// OR, IN, LIKE
const mixed = await db.select().from(users).where(or(eq(users.role, 'admin'), eq(users.role, 'user')));
const specific = await db.select().from(users).where(inArray(users.id, [1, 2, 3]));
const search = await db.select().from(users).where(ilike(users.name, '%john%'));

// Pagination and aggregation
const page = await db.select().from(users).orderBy(desc(users.createdAt)).limit(10).offset(20);
const [{ total }] = await db.select({ total: count() }).from(users);
```

### Insert
```ts
await db.insert(users).values({ name: 'Alice', email: 'alice@example.com' });
await db.insert(users).values([{ name: 'Bob', email: 'bob@example.com' }, { name: 'Carol', email: 'carol@example.com' }]);
const [newUser] = await db.insert(users).values({ name: 'Dave', email: 'dave@example.com' }).returning();
const [{ id }] = await db.insert(users).values({ name: 'Eve', email: 'eve@example.com' }).returning({ id: users.id });
```

### Update
```ts
await db.update(users).set({ isActive: false }).where(eq(users.id, 5));
const [updated] = await db.update(users).set({ role: 'admin' }).where(eq(users.email, 'alice@example.com')).returning();
```

### Delete
```ts
await db.delete(users).where(eq(users.id, 5));
const [deleted] = await db.delete(users).where(eq(users.id, 5)).returning();
```

### Upsert (onConflict)
```ts
// Insert or do nothing
await db.insert(users).values({ name: 'Alice', email: 'alice@example.com' })
  .onConflictDoNothing({ target: users.email });

// Insert or update
await db.insert(users).values({ name: 'Alice', email: 'alice@example.com' })
  .onConflictDoUpdate({
    target: users.email,
    set: { name: 'Alice Updated', isActive: true },
  });
```

## Joins
```ts
const result = await db.select({ postTitle: posts.title, authorName: users.name })
  .from(posts).innerJoin(users, eq(posts.authorId, users.id));

const withComments = await db.select().from(posts)
  .leftJoin(comments, eq(posts.id, comments.postId)).where(eq(posts.id, 1));

// Multi-table
const full = await db.select().from(posts)
  .innerJoin(users, eq(posts.authorId, users.id))
  .leftJoin(comments, eq(posts.id, comments.postId));
```

## Subqueries
```ts
const activeSq = db.select({ id: users.id }).from(users).where(eq(users.isActive, true)).as('active_users');
const activePosts = await db.select().from(posts).innerJoin(activeSq, eq(posts.authorId, activeSq.id));
```

## Relational Query API

Requires passing `{ schema }` to `drizzle()`. Provides Prisma-like nested reads.

```ts
// Find many with relations
const usersWithPosts = await db.query.users.findMany({
  with: { posts: true },
});
// => [{ id: 1, name: 'Alice', posts: [{ id: 1, title: '...' }] }]

// Nested relations
const deep = await db.query.users.findMany({
  with: {
    posts: {
      with: { comments: true },
      where: eq(posts.published, true),
      orderBy: [desc(posts.createdAt)],
      limit: 5,
    },
  },
});

// Find first
const user = await db.query.users.findFirst({
  where: eq(users.id, 1),
  with: { posts: true },
});

// Select specific columns
const partial = await db.query.users.findMany({
  columns: { id: true, name: true },
  with: { posts: { columns: { title: true } } },
});
```

## Transactions
```ts
const result = await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ name: 'Alice', email: 'a@b.com' }).returning();
  await tx.insert(posts).values({ title: 'First Post', authorId: user.id });
  return user;
});
// Nested savepoints supported: tx.transaction(async (tx2) => { ... })
// Rollback: call tx.rollback() inside the callback to abort
```

## Prepared Statements
```ts
import { placeholder } from 'drizzle-orm';

const getByEmail = db.select().from(users)
  .where(eq(users.email, placeholder('email')))
  .prepare('get_user_by_email');

// Execute with parameters — reuses query plan
const user = await getByEmail.execute({ email: 'alice@example.com' });
```

## Raw SQL
```ts
import { sql } from 'drizzle-orm';
const result = await db.select({ id: users.id, lower: sql<string>`lower(${users.name})` }).from(users);
const raw = await db.execute(sql`SELECT NOW()`);
const recent = await db.select().from(users).where(sql`${users.createdAt} > NOW() - INTERVAL '7 days'`);
```

## Type Inference
```ts
type User = typeof users.$inferSelect;    // Full row type for reads
type NewUser = typeof users.$inferInsert;  // Insert type (optionals for defaults)

async function createUser(data: NewUser): Promise<User> {
  const [user] = await db.insert(users).values(data).returning();
  return user;
}
```

## Custom Types
```ts
import { customType } from 'drizzle-orm/pg-core';

const citext = customType<{ data: string }>({
  dataType() { return 'citext'; },
});

// Usage
export const emails = pgTable('emails', {
  address: citext('address').notNull().unique(),
});
```

## Dynamic Query Building
```ts
function buildUserQuery(filters: { role?: string; active?: boolean }) {
  const conditions = [];
  if (filters.role) conditions.push(eq(users.role, filters.role));
  if (filters.active !== undefined) conditions.push(eq(users.isActive, filters.active));

  return db.select().from(users)
    .where(conditions.length ? and(...conditions) : undefined)
    .orderBy(desc(users.createdAt));
}
```

## drizzle-kit Configuration and Commands

### drizzle.config.ts
```ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  dialect: 'postgresql',  // 'postgresql' | 'mysql' | 'sqlite' | 'turso'
  schema: './src/db/schema.ts',
  out: './drizzle',
  dbCredentials: {
    url: process.env.DATABASE_URL!,
  },
  verbose: true,
  strict: true,
});
```

### Commands
```bash
npx drizzle-kit generate   # Generate SQL migration files from schema diff
npx drizzle-kit migrate    # Apply pending migrations to database
npx drizzle-kit push       # Push schema directly (no migration files — dev only)
npx drizzle-kit pull       # Introspect DB and generate schema files
npx drizzle-kit studio     # Launch visual DB browser at https://local.drizzle.studio
npx drizzle-kit check      # Verify migration consistency
npx drizzle-kit up         # Upgrade migration snapshots to latest format
```

### Programmatic Migrations (production)
```ts
import { migrate } from 'drizzle-orm/node-postgres/migrator';
// or: 'drizzle-orm/mysql2/migrator', 'drizzle-orm/better-sqlite3/migrator'

await migrate(db, { migrationsFolder: './drizzle' });
```

### Migration Strategy
- **Development**: Use `drizzle-kit push` for rapid iteration.
- **Production**: Use `drizzle-kit generate` → commit SQL files → `drizzle-kit migrate` or programmatic `migrate()` in app startup.
- **Brownfield**: Use `drizzle-kit pull` to generate schema from existing DB, then switch to code-first.

## Edge Runtime & Serverless

Drizzle runs in Cloudflare Workers, Vercel Edge, Deno Deploy, and Bun.

| Runtime | PostgreSQL Driver | MySQL Driver | SQLite Driver |
|---|---|---|---|
| Node.js | `pg`, `postgres` | `mysql2` | `better-sqlite3` |
| Cloudflare Workers | `@neondatabase/serverless` | Hyperdrive | D1 binding |
| Vercel Edge | `@vercel/postgres`, `@neondatabase/serverless` | — | — |
| Bun | `postgres` | `mysql2` | `bun:sqlite` |
| Turso | — | — | `@libsql/client` |

Edge drivers use HTTP/WebSocket — no TCP pooling needed. For Node.js, configure pool size via the driver (`new Pool({ max: 20 })`).

## Common Patterns

### Soft Delete
```ts
export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  deletedAt: timestamp('deleted_at'),
});
// Query only active
const active = await db.select().from(users).where(isNull(users.deletedAt));
```

### Timestamps Mixin
```ts
const timestamps = {
  createdAt: timestamp('created_at').defaultNow().notNull(),
  updatedAt: timestamp('updated_at').defaultNow().notNull().$onUpdate(() => new Date()),
};

export const posts = pgTable('posts', {
  id: serial('id').primaryKey(),
  title: text('title').notNull(),
  ...timestamps,
});
```

### Type-safe Enum Values
```ts
export const statusEnum = pgEnum('status', ['draft', 'published', 'archived']);
type Status = (typeof statusEnum.enumValues)[number]; // 'draft' | 'published' | 'archived'
```
