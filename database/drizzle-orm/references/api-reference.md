# Drizzle ORM — API Reference

> Complete reference for table builders, column types, query methods, operators, relational API, and drizzle-kit.

## Table of Contents

- [Table Builders](#table-builders)
- [Column Types — PostgreSQL](#column-types--postgresql)
- [Column Types — MySQL](#column-types--mysql)
- [Column Types — SQLite](#column-types--sqlite)
- [Column Modifiers](#column-modifiers)
- [Indexes & Constraints](#indexes--constraints)
- [Enums](#enums)
- [Relations](#relations)
- [Query Builder — Select](#query-builder--select)
- [Query Builder — Insert](#query-builder--insert)
- [Query Builder — Update](#query-builder--update)
- [Query Builder — Delete](#query-builder--delete)
- [Query Builder — Upsert](#query-builder--upsert)
- [Joins](#joins)
- [Subqueries](#subqueries)
- [Operators & Filters](#operators--filters)
- [sql Template Tag](#sql-template-tag)
- [Relational Query API](#relational-query-api)
- [Transactions](#transactions)
- [Prepared Statements](#prepared-statements)
- [Batch API](#batch-api)
- [Views](#views)
- [Schemas (Namespaces)](#schemas-namespaces)
- [Type Inference Helpers](#type-inference-helpers)
- [Custom Types](#custom-types)
- [drizzle-kit Config](#drizzle-kit-config)
- [drizzle-kit Commands](#drizzle-kit-commands)
- [Programmatic Migration](#programmatic-migration)
- [Database Client Initialization](#database-client-initialization)

---

## Table Builders

```ts
import { pgTable } from 'drizzle-orm/pg-core';        // PostgreSQL
import { mysqlTable } from 'drizzle-orm/mysql-core';   // MySQL
import { sqliteTable } from 'drizzle-orm/sqlite-core'; // SQLite
```

**Signature** (all dialects):
```ts
const table = pgTable('table_name', {
  // column definitions
}, (table) => [
  // indexes, constraints (returned as array)
]);
```

---

## Column Types — PostgreSQL

Import from `drizzle-orm/pg-core`:

| Function | SQL Type | TS Type | Notes |
|----------|----------|---------|-------|
| `serial('col')` | `SERIAL` | `number` | Auto-increment (legacy, prefer `identity`) |
| `bigserial('col')` | `BIGSERIAL` | `number \| bigint` | Use `{ mode: 'number' }` for JS number |
| `integer('col')` | `INTEGER` | `number` | |
| `bigint('col')` | `BIGINT` | `number \| bigint` | Use `{ mode: 'number' }` |
| `smallint('col')` | `SMALLINT` | `number` | |
| `real('col')` | `REAL` | `number` | 4-byte float |
| `doublePrecision('col')` | `DOUBLE PRECISION` | `number` | 8-byte float |
| `numeric('col', { precision, scale })` | `NUMERIC` | `string` | Exact decimal |
| `text('col')` | `TEXT` | `string` | Unbounded text |
| `varchar('col', { length })` | `VARCHAR(n)` | `string` | |
| `char('col', { length })` | `CHAR(n)` | `string` | Fixed-length |
| `boolean('col')` | `BOOLEAN` | `boolean` | |
| `timestamp('col')` | `TIMESTAMP` | `Date` | Use `{ withTimezone: true }` for TIMESTAMPTZ |
| `timestamp('col', { mode: 'string' })` | `TIMESTAMP` | `string` | Returns ISO string |
| `date('col')` | `DATE` | `string` | |
| `time('col')` | `TIME` | `string` | |
| `interval('col')` | `INTERVAL` | `string` | |
| `json('col')` | `JSON` | `unknown` | Use `.$type<T>()` |
| `jsonb('col')` | `JSONB` | `unknown` | Use `.$type<T>()` |
| `uuid('col')` | `UUID` | `string` | Use `.defaultRandom()` for auto-gen |
| `inet('col')` | `INET` | `string` | IP address |
| `cidr('col')` | `CIDR` | `string` | |
| `macaddr('col')` | `MACADDR` | `string` | |
| `point('col')` | `POINT` | `[number, number]` | Geographic point |
| `line('col')` | `LINE` | `string` | |
| `vector('col', { dimensions })` | `VECTOR(n)` | `number[]` | pgvector extension |

---

## Column Types — MySQL

Import from `drizzle-orm/mysql-core`:

| Function | SQL Type | TS Type | Notes |
|----------|----------|---------|-------|
| `serial('col')` | `SERIAL` | `number` | Auto-increment bigint unsigned |
| `int('col')` | `INT` | `number` | |
| `bigint('col')` | `BIGINT` | `number \| bigint` | Use `{ mode: 'number' }` |
| `smallint('col')` | `SMALLINT` | `number` | |
| `mediumint('col')` | `MEDIUMINT` | `number` | |
| `tinyint('col')` | `TINYINT` | `number` | |
| `float('col')` | `FLOAT` | `number` | |
| `double('col')` | `DOUBLE` | `number` | |
| `decimal('col', { precision, scale })` | `DECIMAL` | `string` | |
| `varchar('col', { length })` | `VARCHAR(n)` | `string` | **Required** length |
| `char('col', { length })` | `CHAR(n)` | `string` | |
| `text('col')` | `TEXT` | `string` | |
| `boolean('col')` | `BOOLEAN` | `boolean` | Maps to TINYINT(1) |
| `timestamp('col')` | `TIMESTAMP` | `Date` | |
| `datetime('col')` | `DATETIME` | `Date` | |
| `date('col')` | `DATE` | `string` | |
| `time('col')` | `TIME` | `string` | |
| `year('col')` | `YEAR` | `number` | |
| `json('col')` | `JSON` | `unknown` | Use `.$type<T>()` |
| `binary('col', { length })` | `BINARY(n)` | `string` | |
| `varbinary('col', { length })` | `VARBINARY(n)` | `string` | |
| `mysqlEnum('col', [...])` | `ENUM(...)` | union type | |

---

## Column Types — SQLite

Import from `drizzle-orm/sqlite-core`:

| Function | SQL Type | TS Type | Notes |
|----------|----------|---------|-------|
| `integer('col')` | `INTEGER` | `number` | Default numeric |
| `integer('col', { mode: 'boolean' })` | `INTEGER` | `boolean` | 0/1 mapping |
| `integer('col', { mode: 'timestamp' })` | `INTEGER` | `Date` | Unix timestamp |
| `integer('col', { mode: 'timestamp_ms' })` | `INTEGER` | `Date` | Unix ms |
| `real('col')` | `REAL` | `number` | Float |
| `text('col')` | `TEXT` | `string` | |
| `text('col', { enum: [...] })` | `TEXT` | union type | Type-safe enum |
| `text('col', { mode: 'json' })` | `TEXT` | `unknown` | JSON stored as text |
| `blob('col')` | `BLOB` | `Buffer` | Binary |
| `blob('col', { mode: 'json' })` | `BLOB` | `unknown` | |

---

## Column Modifiers

Available on all column types across all dialects:

```ts
column
  .primaryKey()                    // PRIMARY KEY
  .notNull()                       // NOT NULL
  .default(value)                  // DEFAULT <value>
  .defaultNow()                    // DEFAULT NOW() / CURRENT_TIMESTAMP
  .defaultRandom()                 // DEFAULT gen_random_uuid() (PG uuid)
  .$defaultFn(() => value)         // App-level default (runs in JS)
  .$onUpdate(() => new Date())     // App-level value on UPDATE
  .unique()                        // UNIQUE constraint
  .unique('constraint_name')       // Named UNIQUE
  .references(() => other.id)      // FOREIGN KEY
  .references(() => other.id, {
    onDelete: 'cascade',           // CASCADE | SET NULL | SET DEFAULT | RESTRICT | NO ACTION
    onUpdate: 'cascade',
  })
  .$type<CustomType>()             // Override TypeScript type
  .generatedAlwaysAs(sql`...`)     // Generated column (PG/MySQL)
```

---

## Indexes & Constraints

Returned as an array from the third argument of table builders:

```ts
import { index, uniqueIndex, primaryKey, unique, foreignKey, check } from 'drizzle-orm/pg-core';

const table = pgTable('example', { /* columns */ }, (t) => [
  index('name_idx').on(t.name),
  index('composite_idx').on(t.col1, t.col2),
  uniqueIndex('email_unique_idx').on(t.email),
  primaryKey({ columns: [t.col1, t.col2] }),
  unique('unique_combo').on(t.col1, t.col2),
  foreignKey({ columns: [t.parentId], foreignColumns: [t.id] }),
  check('positive_amount', sql`${t.amount} > 0`),
]);
```

### Partial indexes (PostgreSQL)

```ts
index('active_users_idx').on(t.email).where(sql`${t.isActive} = true`)
```

---

## Enums

### PostgreSQL

```ts
import { pgEnum } from 'drizzle-orm/pg-core';
export const roleEnum = pgEnum('role', ['admin', 'user', 'guest']);

// Usage in table
role: roleEnum('role').default('user')

// Extract TS type
type Role = (typeof roleEnum.enumValues)[number]; // 'admin' | 'user' | 'guest'
```

### MySQL

```ts
import { mysqlEnum } from 'drizzle-orm/mysql-core';
role: mysqlEnum('role', ['admin', 'user']).default('user')
```

### SQLite (text enum)

```ts
role: text('role', { enum: ['admin', 'user'] as const }).default('user')
```

---

## Relations

Define separately from table schemas. Required for the relational query API.

```ts
import { relations } from 'drizzle-orm';

// One-to-many
export const usersRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

// Many-to-one (inverse)
export const postsRelations = relations(posts, ({ one, many }) => ({
  author: one(users, {
    fields: [posts.authorId],
    references: [users.id],
  }),
  comments: many(comments),
}));

// Many-to-many (via junction table)
export const postsToTags = pgTable('posts_to_tags', {
  postId: integer('post_id').notNull().references(() => posts.id),
  tagId: integer('tag_id').notNull().references(() => tags.id),
}, (t) => [primaryKey({ columns: [t.postId, t.tagId] })]);

export const postsToTagsRelations = relations(postsToTags, ({ one }) => ({
  post: one(posts, { fields: [postsToTags.postId], references: [posts.id] }),
  tag: one(tags, { fields: [postsToTags.tagId], references: [tags.id] }),
}));
```

---

## Query Builder — Select

```ts
import { eq, desc, count, sum, avg, min, max, sql } from 'drizzle-orm';

db.select().from(table)                              // SELECT *
db.select({ col1: t.col1, col2: t.col2 }).from(t)   // SELECT col1, col2
db.select().from(t).where(condition)                  // WHERE
db.select().from(t).where(and(c1, c2))               // WHERE c1 AND c2
db.select().from(t).orderBy(asc(t.col))              // ORDER BY
db.select().from(t).orderBy(desc(t.col))
db.select().from(t).limit(10)                         // LIMIT
db.select().from(t).offset(20)                        // OFFSET
db.select().from(t).groupBy(t.col)                    // GROUP BY
db.select().from(t).having(gt(count(), 5))            // HAVING

// Aggregations
db.select({ total: count() }).from(t)
db.select({ sum: sum(t.amount) }).from(t)
db.select({ avg: avg(t.price) }).from(t)
db.select({ min: min(t.price), max: max(t.price) }).from(t)

// Distinct
db.selectDistinct().from(t)
db.selectDistinctOn([t.col]).from(t)                  // PG only
```

---

## Query Builder — Insert

```ts
db.insert(table).values({ col: value })                    // Single row
db.insert(table).values([{ col: v1 }, { col: v2 }])       // Multiple rows
db.insert(table).values(data).returning()                  // RETURNING * (PG/SQLite)
db.insert(table).values(data).returning({ id: table.id })  // RETURNING specific cols
```

---

## Query Builder — Update

```ts
db.update(table).set({ col: newValue }).where(condition)
db.update(table).set({ col: newValue }).where(condition).returning()
```

---

## Query Builder — Delete

```ts
db.delete(table).where(condition)
db.delete(table).where(condition).returning()
```

---

## Query Builder — Upsert

### PostgreSQL / SQLite (ON CONFLICT)

```ts
db.insert(table).values(data)
  .onConflictDoNothing()                               // Ignore
  .onConflictDoNothing({ target: table.email })        // Ignore on specific column

db.insert(table).values(data)
  .onConflictDoUpdate({
    target: table.email,                               // Conflict column(s)
    set: { name: sql`excluded.name` },                 // Use excluded row values
    setWhere: sql`excluded.updated_at > ${table.updatedAt}`, // Conditional update
  })
```

### MySQL (ON DUPLICATE KEY)

```ts
db.insert(table).values(data)
  .onDuplicateKeyUpdate({ set: { name: sql`VALUES(name)` } })
```

---

## Joins

```ts
db.select().from(a).innerJoin(b, eq(a.id, b.aId))    // INNER JOIN
db.select().from(a).leftJoin(b, eq(a.id, b.aId))     // LEFT JOIN
db.select().from(a).rightJoin(b, eq(a.id, b.aId))    // RIGHT JOIN
db.select().from(a).fullJoin(b, eq(a.id, b.aId))     // FULL OUTER JOIN
db.select().from(a).crossJoin(b)                       // CROSS JOIN

// Multi-table
db.select().from(a)
  .innerJoin(b, eq(a.id, b.aId))
  .leftJoin(c, eq(b.id, c.bId))
```

---

## Subqueries

```ts
const sq = db.select({ id: users.id })
  .from(users)
  .where(eq(users.isActive, true))
  .as('active_users');                                 // .as() makes it a subquery

const result = await db.select()
  .from(posts)
  .innerJoin(sq, eq(posts.authorId, sq.id));
```

---

## Operators & Filters

All imported from `'drizzle-orm'`:

### Comparison

| Function | SQL | Example |
|----------|-----|---------|
| `eq(col, val)` | `= val` | `eq(users.id, 1)` |
| `ne(col, val)` | `<> val` | `ne(users.role, 'admin')` |
| `gt(col, val)` | `> val` | `gt(users.age, 18)` |
| `gte(col, val)` | `>= val` | `gte(users.age, 18)` |
| `lt(col, val)` | `< val` | `lt(users.age, 65)` |
| `lte(col, val)` | `<= val` | `lte(users.age, 65)` |

### Pattern & Range

| Function | SQL | Example |
|----------|-----|---------|
| `like(col, pattern)` | `LIKE` | `like(users.name, '%john%')` |
| `ilike(col, pattern)` | `ILIKE` (PG) | `ilike(users.name, '%john%')` |
| `notLike(col, pattern)` | `NOT LIKE` | |
| `notIlike(col, pattern)` | `NOT ILIKE` | |
| `between(col, a, b)` | `BETWEEN a AND b` | `between(users.age, 18, 65)` |
| `notBetween(col, a, b)` | `NOT BETWEEN` | |

### List & Null

| Function | SQL | Example |
|----------|-----|---------|
| `inArray(col, [...])` | `IN (...)` | `inArray(users.id, [1,2,3])` |
| `notInArray(col, [...])` | `NOT IN (...)` | |
| `isNull(col)` | `IS NULL` | `isNull(users.deletedAt)` |
| `isNotNull(col)` | `IS NOT NULL` | |

### Logical

| Function | SQL | Example |
|----------|-----|---------|
| `and(c1, c2, ...)` | `c1 AND c2 AND ...` | `and(eq(a, 1), gt(b, 2))` |
| `or(c1, c2, ...)` | `c1 OR c2 OR ...` | `or(eq(a, 1), eq(a, 2))` |
| `not(condition)` | `NOT condition` | `not(eq(a, 1))` |

### Existence & Array (PostgreSQL)

| Function | SQL | Example |
|----------|-----|---------|
| `exists(subquery)` | `EXISTS (subquery)` | `exists(db.select()...)` |
| `notExists(subquery)` | `NOT EXISTS` | |
| `arrayContains(col, val)` | `@>` | `arrayContains(t.tags, ['a'])` |
| `arrayContained(col, val)` | `<@` | |
| `arrayOverlaps(col, val)` | `&&` | `arrayOverlaps(t.tags, ['a','b'])` |

---

## sql Template Tag

```ts
import { sql } from 'drizzle-orm';

// Parameterized expression (safe from injection)
sql`lower(${users.name})`                         // References column
sql`${users.createdAt} > NOW() - INTERVAL '7 days'`
sql<number>`count(*)`                              // Typed result

// Named alias
sql<number>`count(*)`.as('total')

// Raw (unparameterized — use carefully)
sql.raw('NOW()')

// Join fragments
sql.join([sql`a = 1`, sql`b = 2`], sql` AND `)

// Empty SQL (useful for conditional building)
sql.empty()

// Full raw query execution
await db.execute(sql`SELECT * FROM users WHERE id = ${userId}`)
```

---

## Relational Query API

Requires `{ schema }` passed to `drizzle()`.

```ts
import * as schema from './schema';
const db = drizzle(pool, { schema });

// findMany
const users = await db.query.users.findMany();
const usersWithPosts = await db.query.users.findMany({
  with: { posts: true },
});

// Nested with filtering
const filtered = await db.query.users.findMany({
  columns: { id: true, name: true },           // Select columns
  with: {
    posts: {
      columns: { title: true },
      where: eq(schema.posts.published, true),
      orderBy: [desc(schema.posts.createdAt)],
      limit: 5,
      with: { comments: true },                // Deep nesting
    },
  },
  where: eq(schema.users.isActive, true),
  orderBy: [asc(schema.users.name)],
  limit: 10,
  offset: 0,
});

// findFirst
const user = await db.query.users.findFirst({
  where: eq(schema.users.id, 1),
  with: { posts: true },
});

// Exclude columns
const noEmail = await db.query.users.findMany({
  columns: { email: false },
});

// Extras (computed columns)
const withExtra = await db.query.users.findMany({
  extras: {
    lowerName: sql<string>`lower(${schema.users.name})`.as('lower_name'),
  },
});
```

---

## Transactions

```ts
// Basic
const result = await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ name: 'Alice' }).returning();
  await tx.insert(posts).values({ title: 'Hello', authorId: user.id });
  return user;
});

// Rollback
await db.transaction(async (tx) => {
  await tx.insert(users).values({ name: 'Bob' });
  tx.rollback(); // Aborts entire transaction
});

// Nested savepoints
await db.transaction(async (tx) => {
  await tx.insert(users).values({ name: 'Alice' });
  await tx.transaction(async (tx2) => {
    await tx2.insert(posts).values({ title: 'Post' });
    // tx2.rollback() only rolls back this savepoint
  });
});

// Transaction config (PostgreSQL)
await db.transaction(async (tx) => { /* ... */ }, {
  isolationLevel: 'serializable',     // 'read committed' | 'repeatable read' | 'serializable'
  accessMode: 'read write',           // 'read only' | 'read write'
});
```

---

## Prepared Statements

```ts
import { placeholder } from 'drizzle-orm';

const stmt = db.select().from(users)
  .where(eq(users.email, placeholder('email')))
  .prepare('get_by_email');

const result = await stmt.execute({ email: 'alice@test.com' });
```

---

## Batch API

Available for LibSQL, Neon, D1:

```ts
const [users, posts, count] = await db.batch([
  db.insert(usersTable).values({ name: 'Alice' }).returning(),
  db.select().from(postsTable),
  db.select({ count: sql`count(*)` }).from(usersTable),
]);
```

---

## Views

```ts
import { pgView } from 'drizzle-orm/pg-core';
import { mysqlView } from 'drizzle-orm/mysql-core';
import { sqliteView } from 'drizzle-orm/sqlite-core';

// Query builder (schema auto-inferred)
export const activeUsers = pgView('active_users').as((qb) =>
  qb.select().from(users).where(eq(users.isActive, true))
);

// Existing view (declare schema manually, Drizzle won't create it)
export const legacyView = pgView('legacy_report', {
  id: integer('id'),
  total: integer('total'),
}).existing();

// Query views like tables
const result = await db.select().from(activeUsers);
```

---

## Schemas (Namespaces)

PostgreSQL only:

```ts
import { pgSchema } from 'drizzle-orm/pg-core';

const tenantSchema = pgSchema('tenant');
const invoices = tenantSchema.table('invoices', {
  id: serial('id').primaryKey(),
  amount: integer('amount'),
});
// SQL: SELECT * FROM "tenant"."invoices"
```

---

## Type Inference Helpers

```ts
type User = typeof users.$inferSelect;       // Full row type (SELECT)
type NewUser = typeof users.$inferInsert;     // Insert type (optional defaults)

// Use in function signatures
async function createUser(data: NewUser): Promise<User> {
  const [user] = await db.insert(users).values(data).returning();
  return user;
}
```

---

## Custom Types

```ts
import { customType } from 'drizzle-orm/pg-core';

const citext = customType<{ data: string }>({
  dataType() { return 'citext'; },
});

const tsVector = customType<{ data: string }>({
  dataType() { return 'tsvector'; },
});
```

---

## drizzle-kit Config

`drizzle.config.ts`:

```ts
import { defineConfig } from 'drizzle-kit';

export default defineConfig({
  dialect: 'postgresql',                  // 'postgresql' | 'mysql' | 'sqlite' | 'turso'
  schema: './src/db/schema.ts',           // Path or glob: './src/db/schema/*.ts'
  out: './drizzle',                       // Migration output directory
  dbCredentials: {
    url: process.env.DATABASE_URL!,       // Connection string
  },
  verbose: true,                          // Log SQL during operations
  strict: true,                           // Prompt for destructive changes
  schemaFilter: ['public'],              // Filter schemas (PG)
  tablesFilter: ['users', 'posts'],       // Filter specific tables (optional)
  migrations: {
    table: '__drizzle_migrations',        // Custom migration tracking table
    schema: 'public',                     // Schema for migration table
  },
});
```

---

## drizzle-kit Commands

```bash
npx drizzle-kit generate     # Generate SQL migration files from schema diff
npx drizzle-kit migrate      # Apply pending migrations
npx drizzle-kit push         # Push schema directly (dev only, no migration files)
npx drizzle-kit pull         # Introspect DB → generate schema TypeScript files
npx drizzle-kit studio       # Launch visual DB browser (https://local.drizzle.studio)
npx drizzle-kit check        # Verify migration consistency
npx drizzle-kit up           # Upgrade migration snapshot format to latest
npx drizzle-kit drop         # Drop a migration (interactive selection)
```

---

## Programmatic Migration

```ts
// PostgreSQL (node-postgres)
import { migrate } from 'drizzle-orm/node-postgres/migrator';
await migrate(db, { migrationsFolder: './drizzle' });

// PostgreSQL (postgres.js)
import { migrate } from 'drizzle-orm/postgres-js/migrator';
await migrate(db, { migrationsFolder: './drizzle' });

// MySQL
import { migrate } from 'drizzle-orm/mysql2/migrator';
await migrate(db, { migrationsFolder: './drizzle' });

// SQLite (better-sqlite3)
import { migrate } from 'drizzle-orm/better-sqlite3/migrator';
migrate(db, { migrationsFolder: './drizzle' }); // Synchronous

// LibSQL / Turso
import { migrate } from 'drizzle-orm/libsql/migrator';
await migrate(db, { migrationsFolder: './drizzle' });
```

---

## Database Client Initialization

```ts
// PostgreSQL — node-postgres
import { drizzle } from 'drizzle-orm/node-postgres';
import { Pool } from 'pg';
const db = drizzle(new Pool({ connectionString: url }), { schema });

// PostgreSQL — postgres.js
import { drizzle } from 'drizzle-orm/postgres-js';
import postgres from 'postgres';
const db = drizzle(postgres(url), { schema });

// MySQL — mysql2
import { drizzle } from 'drizzle-orm/mysql2';
import mysql from 'mysql2/promise';
const db = drizzle(mysql.createPool({ uri: url }), { schema, mode: 'default' });

// SQLite — better-sqlite3
import { drizzle } from 'drizzle-orm/better-sqlite3';
import Database from 'better-sqlite3';
const db = drizzle(new Database('sqlite.db'), { schema });

// SQLite — Bun
import { drizzle } from 'drizzle-orm/bun-sqlite';
import { Database } from 'bun:sqlite';
const db = drizzle(new Database('sqlite.db'), { schema });

// Turso / libSQL
import { drizzle } from 'drizzle-orm/libsql';
import { createClient } from '@libsql/client';
const db = drizzle(createClient({ url, authToken }), { schema });

// Neon Serverless
import { drizzle } from 'drizzle-orm/neon-http';
import { neon } from '@neondatabase/serverless';
const db = drizzle(neon(url), { schema });

// Cloudflare D1
import { drizzle } from 'drizzle-orm/d1';
const db = drizzle(env.DB, { schema });

// Vercel Postgres
import { drizzle } from 'drizzle-orm/vercel-postgres';
import { sql as vercelSql } from '@vercel/postgres';
const db = drizzle(vercelSql, { schema });
```
