# Drizzle ORM — Troubleshooting Guide

## Table of Contents

- [Type Inference Issues](#type-inference-issues)
- [Migration Conflicts](#migration-conflicts)
- [Push vs Migrate Gotchas](#push-vs-migrate-gotchas)
- [Connection Pool Exhaustion](#connection-pool-exhaustion)
- [Prepared Statement Caching](#prepared-statement-caching)
- [Column Type Mismatches](#column-type-mismatches)
- [Relation Query N+1](#relation-query-n1)
- [Circular Reference Errors](#circular-reference-errors)
- [drizzle-kit Introspect Issues](#drizzle-kit-introspect-issues)
- [ESM/CJS Module Issues](#esmcjs-module-issues)

---

## Type Inference Issues

### Problem: `$inferSelect` / `$inferInsert` produce `any` or wrong types

Requires TypeScript 5.0+, `strict: true`, and matching drizzle-orm/drizzle-kit versions.

```jsonc
// tsconfig.json — required settings
{
  "compilerOptions": {
    "strict": true,
    "target": "ES2020",
    "moduleResolution": "bundler" // or "node16" / "nodenext"
  }
}
```

```bash
npm i drizzle-orm@latest drizzle-kit@latest
```

### Problem: Complex select infers `unknown` for computed columns

Always type `sql` template expressions explicitly:

```typescript
// BAD — infers unknown
const result = await db.select({
  total: sql`sum(${orders.amount})`,
}).from(orders);

// GOOD — explicit type parameter + mapWith
const result = await db.select({
  total: sql<number>`sum(${orders.amount})`.mapWith(Number),
}).from(orders);
```

### Problem: Relation query types don't include nested data

Ensure relations are defined and schema is passed to `drizzle()`:

```typescript
import * as schema from './schema'; // exports tables + relations
const db = drizzle(client, { schema });
// Now db.query.users.findMany({ with: { posts: true } }) is typed
```

### Problem: JSONB column typed as `unknown`

Use `$type<T>()`: `metadata: jsonb('metadata').$type<{ tags: string[] }>()`

---

## Migration Conflicts

### Problem: Merge conflicts in migration files after branch merge

1. Accept the incoming branch's `_journal.json` and snapshot files
2. Delete YOUR branch's conflicting migration SQL file
3. Run `npx drizzle-kit generate` to regenerate, review, and commit

### Problem: "Migration hash mismatch" error

The `__drizzle_migrations` table stores hashes. If a file was edited after applying:
- **Dev**: Drop and recreate the database, re-run all migrations
- **Production**: Never edit applied migrations — create a corrective migration instead

### Problem: "Column already exists" on migrate

Usually caused by running `push` then `migrate` on the same database.

**Fix**: Reset the database before switching to `migrate`, or mark the migration as applied:
```sql
INSERT INTO __drizzle_migrations (hash, created_at) VALUES ('<hash_from_journal>', NOW());
```

**CI tip**: Run `npx drizzle-kit check` in CI to catch drift between schema and migrations.

---

## Push vs Migrate Gotchas

| Scenario | Use |
|----------|-----|
| Local dev, prototyping | `push` |
| Staging / production | `generate` → `migrate` |
| CI/CD pipeline | `migrate` |
| After introspecting legacy DB | `push` to sync, then switch to `migrate` |

### Problem: `push` drops data

If you renamed a column, Drizzle sees "drop old + add new" — data is lost. For column renames, use `generate` + manually edit the SQL to `ALTER COLUMN ... RENAME`. Never use `push` on production data.

### Problem: `push` succeeds but `generate` shows changes

`push` modifies the DB but does NOT create migration files. After prototyping with `push`, run `generate` to capture all changes, then commit.

### Problem: `push` fails with "column is not nullable"

When adding a `.notNull()` column to a table with existing data:
1. Add column as nullable, `push`
2. Backfill: `UPDATE table SET new_col = 'default' WHERE new_col IS NULL`
3. Change to `.notNull()`, `push` again

---

## Connection Pool Exhaustion

**Symptoms**: `too many clients already`, `remaining connection slots are reserved`, requests hanging.

**Cause 1: Multiple pool instances (HMR / hot reload)**

```typescript
// BAD — new pool on every hot reload
export const db = drizzle(new Pool({ connectionString: url }));

// GOOD — singleton pattern
const globalForDb = globalThis as unknown as { pool: Pool };
const pool = globalForDb.pool ?? new Pool({ connectionString: url, max: 10 });
if (process.env.NODE_ENV !== 'production') globalForDb.pool = pool;
export const db = drizzle(pool);
```

**Cause 2: Pool size too large for serverless**

```typescript
// Serverless: keep pool tiny or use HTTP drivers
const pool = new Pool({ connectionString: url, max: 1 });
// Or: drizzle(neon(url)) for HTTP-based, no-pool requests
```

**Cause 3: Unreleased connections** — always use `db.transaction()` which handles cleanup on error:

```typescript
// BAD — error leaves connection checked out
const conn = await pool.connect();
await conn.query('...'); // throws
conn.release(); // never reached!

// GOOD — db.transaction() handles cleanup
await db.transaction(async (tx) => {
  await tx.insert(users).values({ ... });
  // on throw: rolled back and connection released
});
```

**Monitoring**: `SELECT count(*) FROM pg_stat_activity WHERE datname = current_database();`

---

## Prepared Statement Caching

### Problem: "Prepared statement already exists" error

Use unique statement names or let the driver handle naming:

```typescript
const getUser = db.select().from(users)
  .where(eq(users.id, sql.placeholder('id')))
  .prepare('get_user_v1'); // bump version on schema changes
```

### Problem: Prepared statement becomes invalid after schema change

After `ALTER TABLE`, existing prepared statements may fail. Restart the application after migrations (postgres-js invalidates automatically on error).

### Problem: Memory usage grows with many prepared statements

Each statement is cached per connection. Only prepare hot-path queries. For serverless where statements aren't reused:
```typescript
const client = postgres(url, { prepare: false });
```

---

## Column Type Mismatches

### Problem: Number columns return strings

PostgreSQL `bigint`/`numeric`/`decimal` return strings to avoid JS precision loss.

```typescript
// Option 1: mapWith on queries
const result = await db.select({
  total: sql<number>`sum(${orders.amount})`.mapWith(Number),
}).from(orders);

// Option 2: mode on column definition (if values < 2^53)
amount: bigint('amount', { mode: 'number' }),

// Option 3: Handle in application code
const parsed = result.map(r => ({ ...r, total: Number(r.total) }));
```

### Problem: Timestamp columns return strings instead of Date

Be explicit about the `mode` — default depends on the driver:
```typescript
createdAt: timestamp('created_at', { mode: 'date' }).defaultNow(),  // Returns Date object
createdAt: timestamp('created_at', { mode: 'string' }).defaultNow(), // Returns ISO string
```

### Problem: Boolean columns return 0/1 in SQLite

SQLite has no native boolean. Drizzle handles the conversion:
```typescript
isActive: integer('is_active', { mode: 'boolean' }).default(true),
```

### Problem: Enum values not matching at runtime

Postgres enums are case-sensitive. Ensure values match exactly: `pgEnum('status', ['active', 'inactive'])` — insert `'Active'` will fail.

---

## Relation Query N+1

### Problem: Nested `with` causes multiple round-trips

The relational query API generates a **single SQL query** with lateral joins — it does NOT cause N+1. But manual loops do:

```typescript
// BAD — N+1 pattern
const users = await db.select().from(usersTable);
for (const user of users) {
  await db.select().from(postsTable).where(eq(postsTable.authorId, user.id));
}

// GOOD — relational query (single query)
const users = await db.query.users.findMany({ with: { posts: true } });

// GOOD — join
const result = await db.select().from(usersTable)
  .leftJoin(postsTable, eq(usersTable.id, postsTable.authorId));

// GOOD — batch with IN
const userIds = users.map(u => u.id);
const allPosts = await db.select().from(postsTable)
  .where(inArray(postsTable.authorId, userIds));
```

### Problem: Deep nesting causes slow queries

3+ levels deep still produces one query, but complex SQL. Limit nesting depth — for complex data loading, use multiple targeted queries and combine in application code.

---

## Circular Reference Errors

### Problem: "Cannot access 'X' before initialization"

Two tables referencing each other via `.references()` causes circular dependency at module evaluation time.

```typescript
// ERROR — circular at module evaluation time
export const posts = pgTable('posts', {
  authorId: integer('author_id').references(() => users.id), // users not defined yet
});
export const users = pgTable('users', {
  featuredPostId: integer('featured_post_id').references(() => posts.id),
});
```

**Fix 1**: Use relations (not FK constraints) for one direction:
```typescript
export const users = pgTable('users', {
  id: serial('id').primaryKey(),
  featuredPostId: integer('featured_post_id'), // no .references()
});
export const posts = pgTable('posts', {
  id: serial('id').primaryKey(),
  authorId: integer('author_id').references(() => users.id),
});
// Define bidirectional navigation via relations()
export const usersRelations = relations(users, ({ one, many }) => ({
  featuredPost: one(posts, { fields: [users.featuredPostId], references: [posts.id] }),
  posts: many(posts),
}));
```

**Fix 2**: Split schema files — avoid circular imports:
```
src/db/schema/users.ts  → exports users
src/db/schema/posts.ts  → imports users, exports posts
src/db/schema/index.ts  → re-exports everything
```

---

## drizzle-kit Introspect Issues

### Problem: `drizzle-kit pull` generates no tables

Wrong schema in connection or missing permissions. Specify schemas to scan:
```typescript
// drizzle.config.ts
export default defineConfig({
  dialect: 'postgresql',
  dbCredentials: { url: process.env.DATABASE_URL! },
  schemaFilter: ['public', 'auth'], // include all schemas with tables
});
```

### Problem: Relations not generated after introspect

Expected — `pull` generates table definitions but not `relations()`. Add them manually based on foreign keys, or use `--with-relations` flag if available.

### Problem: Complex types introspected as `unknown`

Enum arrays, multi-dimensional arrays, and custom domains may be introspected incorrectly. Review and manually correct:
```typescript
// Generated (wrong): features: unknown('features').array()
// Corrected:
features: pgEnum('feature', ['a', 'b', 'c'])('features').array(),
```

---

## ESM/CJS Module Issues

### Problem: "ERR_REQUIRE_ESM" or "require is not defined"

**Root cause**: Mixing ESM and CJS. Drizzle ORM and drizzle-kit are ESM-first.

Make your project ESM:

```jsonc
// package.json
{ "type": "module" }
// tsconfig.json
{ "compilerOptions": { "module": "ESNext", "moduleResolution": "bundler" } }
```

Or use `drizzle.config.ts` (not `.js`) — drizzle-kit handles TypeScript configs natively.

### Problem: drizzle-kit can't find schema file

Use relative paths from project root with explicit `.ts` extension:
```typescript
export default defineConfig({
  schema: './src/db/schema.ts',
  // For multiple schema files: schema: './src/db/schema/*.ts'
});
```

TypeScript path aliases (`@/db/schema`) are not resolved by drizzle-kit.

### Problem: "Cannot use import statement outside a module"

Happens when `drizzle-kit` loads your schema but project uses CJS. Update drizzle-kit (v0.21+ handles this internally):
```bash
npm i -D drizzle-kit@latest
```

Ensure `drizzle.config.ts` uses ESM syntax (`export default`) and schema files use `import`/`export`.
