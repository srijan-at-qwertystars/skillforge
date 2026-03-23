---
name: drizzle-orm
description:
  positive: "Use when user works with Drizzle ORM, asks about drizzle schema, drizzle-kit migrations, relational queries, prepared statements, Drizzle with PostgreSQL/MySQL/SQLite, or Drizzle vs Prisma comparison."
  negative: "Do NOT use for Prisma (use prisma-orm skill), TypeORM, Sequelize, or Knex.js."
---

# Drizzle ORM Patterns and Best Practices

## Schema Definition

Define schemas in TypeScript. Use identity columns over `serial` for auto-incrementing IDs.

```typescript
import { pgTable, text, integer, boolean, timestamp, pgEnum, index, uniqueIndex } from "drizzle-orm/pg-core";

export const roleEnum = pgEnum("role", ["admin", "user", "moderator"]);

export const users = pgTable("users", {
  id: integer("id").primaryKey().generatedAlwaysAsIdentity(),
  email: text("email").notNull().unique(),
  name: text("name").notNull(),
  role: roleEnum("role").default("user").notNull(),
  isActive: boolean("is_active").default(true).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true, mode: "date" }).defaultNow().notNull(),
  updatedAt: timestamp("updated_at", { withTimezone: true, mode: "date" }).defaultNow().$onUpdate(() => new Date()),
}, (table) => [
  index("email_idx").on(table.email),
  index("role_active_idx").on(table.role, table.isActive),
]);
```

Centralize reusable column patterns:

```typescript
const timestamps = {
  createdAt: timestamp("created_at", { withTimezone: true, mode: "date" }).defaultNow().notNull(),
  updatedAt: timestamp("updated_at", { withTimezone: true, mode: "date" }).defaultNow().$onUpdate(() => new Date()),
};

export const posts = pgTable("posts", {
  id: integer("id").primaryKey().generatedAlwaysAsIdentity(),
  title: text("title").notNull(),
  content: text("content"),
  authorId: integer("author_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  ...timestamps,
});
```

### MySQL and SQLite Variants

```typescript
// MySQL
import { mysqlTable, int, varchar, mysqlEnum } from "drizzle-orm/mysql-core";
export const users = mysqlTable("users", {
  id: int("id").primaryKey().autoincrement(),
  name: varchar("name", { length: 255 }).notNull(),
  role: mysqlEnum("role", ["admin", "user"]).default("user"),
});

// SQLite
import { sqliteTable, integer, text } from "drizzle-orm/sqlite-core";
export const users = sqliteTable("users", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  name: text("name").notNull(),
});
```

## Relations

Define relations separately from table schemas. Relations power the relational query API but do not create foreign keys—use `.references()` for that.

```typescript
import { relations } from "drizzle-orm";

// One-to-many
export const userRelations = relations(users, ({ many }) => ({
  posts: many(posts),
}));

export const postRelations = relations(posts, ({ one, many }) => ({
  author: one(users, { fields: [posts.authorId], references: [users.id] }),
  comments: many(comments),
}));

// Many-to-many via junction table
export const postTags = pgTable("post_tags", {
  postId: integer("post_id").notNull().references(() => posts.id),
  tagId: integer("tag_id").notNull().references(() => tags.id),
}, (table) => [
  { pk: primaryKey({ columns: [table.postId, table.tagId] }) },
]);

export const postTagRelations = relations(postTags, ({ one }) => ({
  post: one(posts, { fields: [postTags.postId], references: [posts.id] }),
  tag: one(tags, { fields: [postTags.tagId], references: [tags.id] }),
}));

// Self-referencing
export const categories = pgTable("categories", {
  id: integer("id").primaryKey().generatedAlwaysAsIdentity(),
  name: text("name").notNull(),
  parentId: integer("parent_id"),
});

export const categoryRelations = relations(categories, ({ one, many }) => ({
  parent: one(categories, { fields: [categories.parentId], references: [categories.id], relationName: "parentChild" }),
  children: many(categories, { relationName: "parentChild" }),
}));
```

## SQL-Like Query Builder

### Select

```typescript
import { eq, and, or, like, gt, inArray, sql, desc, asc, count } from "drizzle-orm";

// Basic select
const allUsers = await db.select().from(users);

// Partial select — always prefer over select * in production
const userNames = await db.select({ id: users.id, name: users.name }).from(users);

// Filtering
const admins = await db.select().from(users).where(eq(users.role, "admin"));

const filtered = await db.select().from(users).where(
  and(eq(users.isActive, true), or(eq(users.role, "admin"), like(users.name, "%john%")))
);

// Joins
const postsWithAuthors = await db
  .select({ postTitle: posts.title, authorName: users.name })
  .from(posts)
  .innerJoin(users, eq(posts.authorId, users.id))
  .where(gt(posts.createdAt, new Date("2024-01-01")));

// Aggregation
const postCounts = await db
  .select({ authorId: posts.authorId, count: count() })
  .from(posts)
  .groupBy(posts.authorId);

// Subqueries
const sq = db.select({ authorId: posts.authorId, postCount: count().as("post_count") })
  .from(posts).groupBy(posts.authorId).as("sq");

const activeAuthors = await db
  .select({ name: users.name, postCount: sq.postCount })
  .from(users)
  .innerJoin(sq, eq(users.id, sq.authorId))
  .where(gt(sq.postCount, 5));

// Order and limit
const recentPosts = await db.select().from(posts).orderBy(desc(posts.createdAt)).limit(10).offset(0);
```

### Insert

```typescript
// Single insert
const [newUser] = await db.insert(users).values({ email: "a@b.com", name: "Alice" }).returning();

// Bulk insert
await db.insert(users).values([
  { email: "a@b.com", name: "Alice" },
  { email: "b@c.com", name: "Bob" },
]);

// Upsert (on conflict)
await db.insert(users).values({ email: "a@b.com", name: "Alice Updated" })
  .onConflictDoUpdate({ target: users.email, set: { name: "Alice Updated" } });
```

### Update and Delete

```typescript
await db.update(users).set({ isActive: false }).where(eq(users.id, 1));

await db.delete(posts).where(eq(posts.authorId, 1));
```

## Relational Queries

Use `db.query` for nested data fetching. Pass all schema + relations to `drizzle()`.

```typescript
import { drizzle } from "drizzle-orm/node-postgres";
import * as schema from "./schema";

const db = drizzle(pool, { schema });

// Find one with nested relations
const user = await db.query.users.findFirst({
  where: eq(users.id, 1),
  columns: { id: true, name: true, email: true },
  with: {
    posts: {
      columns: { id: true, title: true },
      with: { comments: true },
      orderBy: [desc(posts.createdAt)],
      limit: 5,
    },
  },
});

// Find many with filters on relations
const activeUsersWithPosts = await db.query.users.findMany({
  where: eq(users.isActive, true),
  with: { posts: { where: gt(posts.createdAt, new Date("2024-01-01")) } },
});
```

Relational queries generate a single optimized SQL statement. Use `EXPLAIN` on complex nested queries to verify performance.

## Drizzle Kit

Configure in `drizzle.config.ts`:

```typescript
import { defineConfig } from "drizzle-kit";

export default defineConfig({
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "postgresql",
  dbCredentials: { url: process.env.DATABASE_URL! },
});
```

Commands:
- `npx drizzle-kit generate` — generate SQL migration files from schema changes
- `npx drizzle-kit migrate` — apply pending migrations
- `npx drizzle-kit push` — push schema directly to DB (dev only, skips migration files)
- `npx drizzle-kit introspect` — generate schema from existing DB
- `npx drizzle-kit studio` — launch visual DB browser at https://local.drizzle.studio

Store migration files in version control. Never manually edit generated SQL. Use `push` for rapid prototyping; use `generate` + `migrate` for production.

## Transactions

```typescript
const result = await db.transaction(async (tx) => {
  const [user] = await tx.insert(users).values({ email: "a@b.com", name: "Alice" }).returning();
  await tx.insert(posts).values({ title: "First Post", authorId: user.id });
  return user;
});

// Nested transactions use savepoints
await db.transaction(async (tx) => {
  await tx.insert(users).values({ email: "outer@test.com", name: "Outer" });
  try {
    await tx.transaction(async (tx2) => {
      await tx2.insert(users).values({ email: "inner@test.com", name: "Inner" });
      throw new Error("rollback inner only");
    });
  } catch {
    // inner savepoint rolled back, outer continues
  }
});
```

Extract transaction type for reusable functions:

```typescript
type Transaction = Parameters<Parameters<typeof db.transaction>[0]>[0];

async function createUserWithProfile(tx: Transaction, data: NewUser) {
  const [user] = await tx.insert(users).values(data).returning();
  await tx.insert(profiles).values({ userId: user.id });
  return user;
}
```

## Prepared Statements

Compile once, execute many times. Eliminates repeated parse/plan overhead.

```typescript
import { placeholder } from "drizzle-orm";

const getUserById = db.select().from(users).where(eq(users.id, placeholder("id"))).prepare("get_user_by_id");

// Reuse across requests
const user1 = await getUserById.execute({ id: 1 });
const user2 = await getUserById.execute({ id: 2 });

// Prepared with multiple params
const getUsersByRole = db.select().from(users)
  .where(and(eq(users.role, placeholder("role")), eq(users.isActive, placeholder("active"))))
  .prepare("get_users_by_role");

await getUsersByRole.execute({ role: "admin", active: true });
```

Use prepared statements for hot-path queries in APIs. Benefits are most significant with complex queries and high request volumes.

## Database Drivers

```typescript
// PostgreSQL — node-postgres
import { Pool } from "pg";
import { drizzle } from "drizzle-orm/node-postgres";
const db = drizzle(new Pool({ connectionString: process.env.DATABASE_URL }), { schema });

// PostgreSQL — Neon serverless
import { neon } from "@neondatabase/serverless";
import { drizzle } from "drizzle-orm/neon-http";
const db = drizzle(neon(process.env.DATABASE_URL!), { schema });

// MySQL — mysql2
import mysql from "mysql2/promise";
import { drizzle } from "drizzle-orm/mysql2";
const db = drizzle(await mysql.createConnection(process.env.DATABASE_URL!), { schema });

// SQLite — better-sqlite3
import Database from "better-sqlite3";
import { drizzle } from "drizzle-orm/better-sqlite3";
const db = drizzle(new Database("sqlite.db"), { schema });

// Turso (libSQL)
import { createClient } from "@libsql/client";
import { drizzle } from "drizzle-orm/libsql";
const db = drizzle(createClient({ url: process.env.TURSO_URL!, authToken: process.env.TURSO_TOKEN }), { schema });
```

## Type Safety

```typescript
// Infer select and insert types from schema
type User = typeof users.$inferSelect;       // { id: number; email: string; name: string; ... }
type NewUser = typeof users.$inferInsert;     // { email: string; name: string; role?: "admin" | "user"; ... }

// Use in application code
async function createUser(data: NewUser): Promise<User> {
  const [user] = await db.insert(users).values(data).returning();
  return user;
}

// Custom types for special columns
import { customType } from "drizzle-orm/pg-core";

const citext = customType<{ data: string }>({
  dataType() { return "citext"; },
});

export const emails = pgTable("emails", {
  address: citext("address").notNull(),
});
```

## Performance Patterns

### Partial Selects
Always select only needed columns. Avoid `select()` (SELECT *) in production:
```typescript
// Bad — fetches all columns
const users = await db.select().from(users);
// Good — fetches only what you need
const users = await db.select({ id: users.id, name: users.name }).from(users);
```

### Batch Queries
Use `Promise.all` for independent queries or `db.batch()` where supported:
```typescript
const [usersList, postsList] = await Promise.all([
  db.select().from(users).limit(10),
  db.select().from(posts).limit(10),
]);
```

### Connection Pooling
Always use connection pools in production. Configure pool size based on expected concurrency:
```typescript
import { Pool } from "pg";
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 20 });
const db = drizzle(pool, { schema });
```

### Indexing
Add indexes for columns used in WHERE, JOIN, and ORDER BY. Use composite indexes for multi-column filters. Prefer partial indexes for filtered subsets:
```typescript
export const orders = pgTable("orders", {
  id: integer("id").primaryKey().generatedAlwaysAsIdentity(),
  status: text("status").notNull(),
  customerId: integer("customer_id").notNull(),
  total: integer("total").notNull(),
}, (table) => [
  index("status_idx").on(table.status),
  index("customer_status_idx").on(table.customerId, table.status),
]);
```

## Framework Integration

### Next.js
```typescript
// src/db/index.ts
import { drizzle } from "drizzle-orm/node-postgres";
import { Pool } from "pg";
import * as schema from "./schema";

const pool = new Pool({ connectionString: process.env.DATABASE_URL });
export const db = drizzle(pool, { schema });

// In Server Components or Route Handlers
import { db } from "@/db";
const users = await db.query.users.findMany();
```

### Hono
```typescript
import { Hono } from "hono";
import { db } from "./db";
import { users } from "./schema";

const app = new Hono();
app.get("/users", async (c) => {
  const result = await db.select().from(users);
  return c.json(result);
});
```

### Express
```typescript
import express from "express";
import { db } from "./db";
import { users } from "./schema";

const app = express();
app.get("/users", async (req, res) => {
  const result = await db.select().from(users);
  res.json(result);
});
```

## Testing Patterns

Use a separate test database. Run migrations before test suites. Wrap tests in transactions and roll back:

```typescript
import { drizzle } from "drizzle-orm/node-postgres";
import { migrate } from "drizzle-orm/node-postgres/migrator";
import { Pool } from "pg";
import * as schema from "./schema";

let db: ReturnType<typeof drizzle>;
let pool: Pool;

beforeAll(async () => {
  pool = new Pool({ connectionString: process.env.TEST_DATABASE_URL });
  db = drizzle(pool, { schema });
  await migrate(db, { migrationsFolder: "./drizzle" });
});

afterAll(async () => { await pool.end(); });

// Option A: truncate tables between tests
afterEach(async () => {
  await db.delete(posts);
  await db.delete(users);
});

// Option B: use transactions for isolation
import { sql } from "drizzle-orm";
beforeEach(async () => { await db.execute(sql`BEGIN`); });
afterEach(async () => { await db.execute(sql`ROLLBACK`); });
```

## Drizzle vs Prisma

| Aspect | Drizzle | Prisma |
|---|---|---|
| Philosophy | SQL-first, thin abstraction | Abstraction-first, schema DSL |
| Schema | TypeScript code | `.prisma` file (custom DSL) |
| Type safety | Inferred from TS schema | Generated client from schema |
| Bundle size | ~few KB, no binary | ~1.5–8MB Rust query engine |
| Cold start | Near-zero | Heavy (improved with Accelerate) |
| Query style | SQL-like builder | Object-based fluent API |
| Raw SQL | First-class support | Supported but less ergonomic |
| Migrations | `drizzle-kit generate/migrate` | `prisma migrate` (more mature) |
| GUI | `drizzle-kit studio` | Prisma Studio (more polished) |
| Best for | SQL-savvy devs, edge/serverless | Teams wanting high-level abstraction |

Choose Drizzle when bundle size, cold starts, or SQL control matter. Choose Prisma when onboarding speed, mature tooling, and team standardization are priorities.

## Anti-Patterns

1. **SELECT * in production** — Use partial selects. Fetching unnecessary columns wastes bandwidth and memory.
2. **N+1 queries** — Use the relational query API (`db.query.table.findMany({ with: {...} })`) instead of manual loops with individual queries.
3. **Missing indexes** — Always index foreign keys, columns in WHERE/JOIN/ORDER BY clauses. Run `EXPLAIN ANALYZE` to verify query plans.
4. **Skipping connection pooling** — Always use `Pool` (not `Client`) in production. Set `max` based on concurrency.
5. **Manual migration edits** — Change schema files, then regenerate. Editing SQL migrations directly causes drift.
6. **Ignoring `$onUpdate`** — Use `$onUpdate(() => new Date())` on `updatedAt` columns instead of manual timestamp management.
7. **Not passing schema to `drizzle()`** — Relational queries require the schema object. Always pass `{ schema }` when initializing.
8. **Using `push` in production** — `push` skips migration history. Use `generate` + `migrate` for traceable, reversible deployments.

<!-- tested: pass -->
