# Drizzle ORM — Troubleshooting Guide

> Common errors, performance pitfalls, drizzle-kit issues, edge runtime gotchas, and TypeScript strict mode problems.

## Table of Contents

- [Type Mismatches](#type-mismatches)
- [Migration Conflicts](#migration-conflicts)
- [Driver Issues](#driver-issues)
- [Performance Pitfalls](#performance-pitfalls)
- [drizzle-kit Issues](#drizzle-kit-issues)
- [Edge Runtime Gotchas](#edge-runtime-gotchas)
- [TypeScript Strict Mode Issues](#typescript-strict-mode-issues)
- [Common Error Messages](#common-error-messages)
- [Debugging Techniques](#debugging-techniques)

---

## Type Mismatches

### Insert type errors with default values

**Symptom**: TypeScript complains about missing fields that have `.default()` or `.defaultNow()`.

**Cause**: Drizzle's `$inferInsert` type may not properly exclude defaulted fields in some versions.

**Fix**:
```ts
// Option 1: Use Partial for defaulted fields
type NewUser = typeof users.$inferInsert;
// All defaulted fields are already optional in $inferInsert

// Option 2: If still failing, explicitly type
await db.insert(users).values({
  name: 'Alice',
  email: 'alice@test.com',
  // Don't include fields with defaults unless overriding
} satisfies typeof users.$inferInsert);
```

### Relation type inference broken

**Symptom**: TypeScript error when using relational queries like `db.query.users.findMany({ with: { posts: true } })`.

**Causes & Fixes**:
1. **Schema not passed to drizzle()**: Must include `{ schema }` in drizzle init
   ```ts
   import * as schema from './schema';
   const db = drizzle(pool, { schema }); // Required for relational queries
   ```
2. **Table name collision**: If two tables share similar names, rename one
3. **Circular relation definitions**: Ensure relations are defined after all tables

### Column type vs runtime type mismatch

**Symptom**: Data comes back as string when you expect number (e.g., `bigint` columns).

**Fix**: PostgreSQL `bigint` returns as string in JS. Use mode or explicit casting:
```ts
// Option 1: Use integer if values fit
id: integer('id')

// Option 2: Use mode
amount: bigint('amount', { mode: 'number' }) // Coerces to JS number

// Option 3: Use sql cast
sql<number>`CAST(${column} AS INTEGER)`
```

### JSON/JSONB type inference

**Symptom**: JSONB columns return `unknown` type.

**Fix**: Use `$type<>()` to specify the shape:
```ts
metadata: jsonb('metadata').$type<{ plan: string; features: string[] }>(),
```

---

## Migration Conflicts

### Merge conflicts in journal.json

**Symptom**: Git merge conflicts in `drizzle/meta/_journal.json` or snapshot files when multiple branches add migrations.

**Resolution**:
1. Accept the incoming (main branch) version of `_journal.json` and all `meta/` snapshot files
2. Delete your branch's conflicting migration SQL files from `drizzle/`
3. Re-run `npx drizzle-kit generate` — it will regenerate from the current schema diff
4. Verify with `npx drizzle-kit check`

### Migration applied out of order

**Symptom**: `migrate()` fails because a migration was already applied or skipped.

**Fix**: Check the `__drizzle_migrations` table in your DB:
```sql
SELECT * FROM __drizzle_migrations ORDER BY created_at;
```
Ensure migration files in `drizzle/` match what's recorded. Remove orphaned entries if needed.

### Schema drift after using push

**Symptom**: `generate` produces unexpected migrations after using `push` in development.

**Fix**: Never mix `push` and `generate` without resynchronizing:
```bash
npx drizzle-kit pull    # Sync schema from current DB state
npx drizzle-kit generate  # Generate clean baseline
```

---

## Driver Issues

### node-postgres (pg) — Prepared statement already exists

**Symptom**: `error: prepared statement "X" already exists`

**Fix**: This happens when connection pooling reuses a connection with a stale prepared statement. Options:
```ts
// Option 1: Disable prepared statements in pool config
const pool = new Pool({ ...config, statement_timeout: 0 });

// Option 2: Use postgres.js instead, which handles this automatically
```

### postgres.js — "Cannot use pool after calling end"

**Symptom**: Queries fail after calling `client.end()`.

**Fix**: Only call `end()` on shutdown. Don't end the client and then try to reuse it:
```ts
// Correct pattern
process.on('SIGTERM', async () => {
  await client.end();
  process.exit(0);
});
```

### mysql2 — ER_NOT_SUPPORTED_AUTH_MODE

**Symptom**: Authentication failure connecting to MySQL 8+.

**Fix**: MySQL 8 defaults to `caching_sha2_password`. Either:
```sql
ALTER USER 'user'@'%' IDENTIFIED WITH mysql_native_password BY 'password';
```
Or use mysql2 version ≥ 3.x which supports `caching_sha2_password` natively.

### better-sqlite3 — Cannot find module

**Symptom**: Build/runtime error finding the native module.

**Fix**: It's a native C++ addon. Rebuild:
```bash
npm rebuild better-sqlite3
# Or for specific Node version:
npx node-pre-gyp rebuild --build-from-source
```

### Version mismatch between drizzle-orm and drizzle-kit

**Symptom**: Various cryptic errors during migration or schema operations.

**Fix**: Always keep both packages aligned:
```bash
npm ls drizzle-orm drizzle-kit
npm i drizzle-orm@latest drizzle-kit@latest
```

---

## Performance Pitfalls

### N+1 queries with relational API

**Symptom**: Slow page loads with many related records.

**Cause**: Drizzle's relational query API (`db.query.users.findMany({ with: { posts: true } })`) actually executes efficient SQL (uses lateral joins or subqueries). The N+1 problem occurs when you manually loop:

```ts
// ❌ BAD: N+1 — one query per user
const users = await db.select().from(usersTable);
for (const user of users) {
  const posts = await db.select().from(postsTable).where(eq(postsTable.authorId, user.id));
}

// ✅ GOOD: Single query with join
const usersWithPosts = await db.query.users.findMany({ with: { posts: true } });

// ✅ GOOD: Manual join if you need specific columns
const result = await db.select().from(usersTable)
  .leftJoin(postsTable, eq(usersTable.id, postsTable.authorId));
```

### Missing indexes

**Symptom**: Slow queries on filtered/joined columns.

**Fix**: Add indexes for frequently queried columns:
```ts
export const posts = pgTable('posts', {
  id: serial('id').primaryKey(),
  authorId: integer('author_id').notNull().references(() => users.id),
  status: text('status').notNull(),
  createdAt: timestamp('created_at').defaultNow().notNull(),
}, (t) => [
  index('posts_author_idx').on(t.authorId),
  index('posts_status_idx').on(t.status),
  index('posts_created_idx').on(t.createdAt),
]);
```

### Selecting all columns unnecessarily

```ts
// ❌ Fetches everything including large text columns
const all = await db.select().from(posts);

// ✅ Select only what you need
const titles = await db.select({ id: posts.id, title: posts.title }).from(posts);
```

### Not using prepared statements for hot paths

```ts
// ✅ Prepare once for repeated queries
const getUser = db.select().from(users)
  .where(eq(users.id, placeholder('id')))
  .prepare('get_user');

// Reuses query plan on each call
const user = await getUser.execute({ id: userId });
```

### Unbounded queries

```ts
// ❌ Returns entire table
const all = await db.select().from(logs);

// ✅ Always paginate
const page = await db.select().from(logs)
  .orderBy(desc(logs.createdAt))
  .limit(50)
  .offset(0);
```

---

## drizzle-kit Issues

### push vs generate tradeoffs

| Scenario | Use `push` | Use `generate` |
|----------|-----------|---------------|
| Solo prototyping | ✅ | Overkill |
| Team project | ❌ Unsafe | ✅ Required |
| CI/CD pipeline | ❌ | ✅ Required |
| Production deploy | ❌ Never | ✅ Always |
| Quick schema test | ✅ | Slower |

**Key rule**: Never use `push` on production databases. Always use `generate` → review SQL → `migrate`.

### "There is not enough information to represent migration"

**Cause**: Drizzle-kit can't infer the migration (e.g., column rename looks like drop + add).

**Fix**: Edit the generated SQL manually or use drizzle-kit's interactive prompt to clarify:
```bash
npx drizzle-kit generate
# It may ask: "Is this a rename from X to Y?" — answer correctly
```

### Studio fails to start

**Checklist**:
1. `drizzle.config.ts` has valid `dbCredentials`
2. Database is reachable from your machine
3. No port conflict on 4983 (default studio port)
4. Try: `npx drizzle-kit studio --port 4984`
5. Check: `npx drizzle-kit studio --verbose` for detailed errors

### drizzle-kit check fails

**Symptom**: `check` reports inconsistencies between schema and migrations.

**Fix**:
```bash
npx drizzle-kit up       # Upgrade snapshot format
npx drizzle-kit generate # Regenerate any missing migrations
npx drizzle-kit check    # Verify again
```

### Slow migration generation

**Cause**: Large schema with many tables or complex relations.

**Fix**: Split schema into multiple files and use glob in config:
```ts
export default defineConfig({
  schema: './src/db/schema/*.ts',  // Glob pattern
  // ...
});
```

---

## Edge Runtime Gotchas

### Cloudflare Workers

- **No TCP connections**: Can't use `pg` or `mysql2`. Use HTTP-based drivers:
  - PostgreSQL: `@neondatabase/serverless` or Hyperdrive
  - SQLite: D1 binding (`drizzle(env.DB)`)
- **No Node.js APIs**: `fs`, `path`, `crypto` unavailable — affects migration tooling
- **Programmatic migration**: Must run outside Workers; pre-migrate before deploy
- **Cold start**: Keep pool size minimal or use connection-per-request

### Vercel Edge Functions

- **Driver limitation**: Only `@vercel/postgres` or `@neondatabase/serverless`
- **Timeout**: Edge functions have 30s execution limit
- **No file system**: Can't use `better-sqlite3` or file-based SQLite

### Bun runtime

- **SQLite**: Use `bun:sqlite` instead of `better-sqlite3`:
  ```ts
  import { drizzle } from 'drizzle-orm/bun-sqlite';
  import { Database } from 'bun:sqlite';
  const db = drizzle(new Database('sqlite.db'));
  ```
- **postgres.js works**: Bun supports `postgres` package natively
- **Compatibility**: Some `drizzle-kit` commands may need `--bun` flag

### Deno

- **Use postgres.js**: Compatible with Deno
- **Import maps**: May need `npm:` specifiers:
  ```ts
  import { drizzle } from 'npm:drizzle-orm/postgres-js';
  ```

---

## TypeScript Strict Mode Issues

### "Type 'X' is not assignable to type 'never'"

**Cause**: TypeScript strict mode narrows union types too aggressively.

**Fix**: Add explicit type annotations:
```ts
// ❌ Fails in strict mode
const conditions = [];
conditions.push(eq(users.name, 'Alice'));

// ✅ Explicit type
const conditions: SQL[] = [];
conditions.push(eq(users.name, 'Alice'));
```

### "Implicit any" on query results

**Fix**: Ensure `tsconfig.json` has proper settings:
```json
{
  "compilerOptions": {
    "strict": true,
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "skipLibCheck": true
  }
}
```

### exactOptionalPropertyTypes conflicts

**Symptom**: Errors when passing `undefined` for optional fields.

**Fix**: Either disable `exactOptionalPropertyTypes` or explicitly omit undefined fields:
```ts
// ❌ Fails with exactOptionalPropertyTypes
await db.insert(users).values({ name: 'Alice', role: undefined });

// ✅ Omit the field entirely
const values: typeof users.$inferInsert = { name: 'Alice' };
await db.insert(users).values(values);
```

---

## Common Error Messages

| Error | Cause | Fix |
|-------|-------|-----|
| `"relation 'X' does not exist"` | Table not created / wrong schema | Run migrations or check schema name |
| `"column 'X' does not exist"` | Column renamed/removed | Re-run `generate` + `migrate` |
| `"there is not enough information"` | Ambiguous schema change | Use interactive `generate` prompt |
| `"prepared statement already exists"` | Connection pool reuse | Use fresh connections or disable prepare |
| `"Cannot find module 'drizzle-orm/X'"` | Wrong import path for driver | Check docs for correct subpath import |
| `"No transaction is active"` | Driver/version mismatch | Update drizzle-orm and driver |
| `"maximum call stack size exceeded"` | Circular relations defined wrong | Check relation definitions for cycles |
| `DrizzleTypeError` | Schema type mismatch | Review column types match query types |

---

## Debugging Techniques

### Enable query logging

```ts
const db = drizzle(pool, {
  schema,
  logger: true, // Logs all SQL to console
});

// Custom logger
const db = drizzle(pool, {
  schema,
  logger: {
    logQuery(query: string, params: unknown[]) {
      console.log('SQL:', query);
      console.log('Params:', params);
    },
  },
});
```

### Inspect generated SQL without executing

```ts
const query = db.select().from(users).where(eq(users.role, 'admin'));
const { sql: sqlStr, params } = query.toSQL();
console.log(sqlStr);   // SELECT ... FROM "users" WHERE "role" = $1
console.log(params);   // ['admin']
```

### Check migration state

```sql
-- PostgreSQL
SELECT * FROM "__drizzle_migrations" ORDER BY created_at;

-- See what drizzle-kit would generate
npx drizzle-kit generate --dry-run
```

### Validate schema matches database

```bash
npx drizzle-kit pull --out=./drizzle-check
# Compare pulled schema with your source schema
diff src/db/schema.ts drizzle-check/schema.ts
```
