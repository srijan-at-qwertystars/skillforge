# Drizzle ORM — Advanced Patterns

## Table of Contents

- [Dynamic Query Building](#dynamic-query-building)
- [Conditional WHERE Clauses](#conditional-where-clauses)
- [Raw SQL with sql Template](#raw-sql-with-sql-template)
- [Custom Column Types](#custom-column-types)
- [JSON Columns](#json-columns)
- [Array Columns](#array-columns)
- [Generated Columns](#generated-columns)
- [Database Views](#database-views)
- [Subqueries in SELECT](#subqueries-in-select)
- [Common Table Expressions (CTEs)](#common-table-expressions-ctes)
- [Window Functions](#window-functions)
- [Full-Text Search](#full-text-search)
- [PostGIS with Drizzle](#postgis-with-drizzle)
- [Multi-Schema Support](#multi-schema-support)

## Dynamic Query Building

Use `.$dynamic()` to compose queries incrementally with reusable enhancers.

```typescript
import { SQL, and, gte, lte, eq, ilike } from 'drizzle-orm';

function buildUserQuery(filters: UserFilters) {
  let query = db.select().from(users).$dynamic();
  if (filters.role) query = query.where(eq(users.role, filters.role));
  if (filters.search) query = query.where(ilike(users.name, `%${filters.search}%`));
  return query;
}

// Reusable enhancer — must accept dialect type (PgSelect/MySqlSelect/SQLiteSelect)
function withPagination<T extends PgSelect>(query: T, page: number, pageSize = 20) {
  return query.limit(pageSize).offset((page - 1) * pageSize);
}

const result = await withPagination(buildUserQuery({ role: 'admin' }), 1, 25);
```

## Conditional WHERE Clauses

Build condition arrays and spread into `and()`/`or()`. `undefined` values are safely ignored.

```typescript
import { and, or, eq, gte, lte, ilike, SQL } from 'drizzle-orm';

async function findProducts(filters: ProductFilters) {
  const conditions: (SQL | undefined)[] = [];
  if (filters.category) conditions.push(eq(products.category, filters.category));
  if (filters.minPrice) conditions.push(gte(products.price, filters.minPrice));
  if (filters.maxPrice) conditions.push(lte(products.price, filters.maxPrice));
  if (filters.search) {
    conditions.push(or(
      ilike(products.name, `%${filters.search}%`),
      ilike(products.description, `%${filters.search}%`),
    ));
  }
  return db.select().from(products).where(and(...conditions));
}
```

## Raw SQL with sql Template

The `sql` tagged template is your escape hatch for anything Drizzle doesn't wrap natively.

```typescript
import { sql } from 'drizzle-orm';

const result = await db.select({
  id: users.id,
  nameLength: sql<number>`char_length(${users.name})`,
  upperName: sql<string>`upper(${users.name})`,
}).from(users);

// Raw SQL in WHERE
await db.select().from(users)
  .where(sql`${users.email} ~* ${'^admin@'}`);

// Entire raw queries with type safety
const rows = await db.execute<{ id: number; total: string }>(
  sql`SELECT id, SUM(amount)::text as total FROM orders GROUP BY id`
);

// sql.raw() — unescaped, use only for trusted static strings
await db.select().from(users).orderBy(sql.raw(`created_at DESC`));

// mapWith for driver-level type coercion
const totalSales = sql<number>`SUM(${orders.amount})`.mapWith(Number);
```

**Safety**: Column references inside `` sql`...` `` are parameterized. Use `sql.raw()` only for trusted, static SQL fragments.

## Custom Column Types

Define reusable custom column types with `customType`:

```typescript
import { customType } from 'drizzle-orm/pg-core';

const citext = customType<{ data: string }>({
  dataType() { return 'citext'; },
});

// Money stored as integer cents, exposed as number
const money = customType<{ data: number; driverData: string }>({
  dataType() { return 'integer'; },
  toDriver(value: number) { return Math.round(value * 100); },
  fromDriver(value: string) { return Number(value) / 100; },
});

export const products = pgTable('products', {
  name: citext('name').notNull(),
  price: money('price').notNull(),
});
```

## JSON Columns

PostgreSQL `json`/`jsonb` columns with typed access:

```typescript
import { pgTable, serial, jsonb, json } from 'drizzle-orm/pg-core';

type Address = { street: string; city: string; zip: string; country: string };

export const profiles = pgTable('profiles', {
  id: serial('id').primaryKey(),
  address: jsonb('address').$type<Address>(),
  metadata: jsonb('metadata').$type<{ tags: string[] }>().default({}),
  rawData: json('raw_data'), // json (not jsonb) — stored as text
});

// Querying JSON fields
await db.select().from(profiles)
  .where(sql`${profiles.metadata}->>'tags' @> '["vip"]'`);

await db.select({
  id: profiles.id,
  city: sql<string>`${profiles.address}->>'city'`,
}).from(profiles);
```

## Array Columns

PostgreSQL array columns with operators:

```typescript
import { pgTable, serial, text, integer } from 'drizzle-orm/pg-core';
import { arrayContains, arrayContained, arrayOverlaps } from 'drizzle-orm';

export const articles = pgTable('articles', {
  id: serial('id').primaryKey(),
  title: text('title').notNull(),
  tags: text('tags').array().notNull().default(sql`'{}'::text[]`),
  scores: integer('scores').array(),
});

await db.insert(articles).values({
  title: 'Drizzle Guide',
  tags: ['typescript', 'orm', 'postgres'],
});

// Array operators: arrayContains (@>), arrayOverlaps (&&), arrayContained (<@)
await db.select().from(articles)
  .where(arrayContains(articles.tags, ['typescript']));
await db.select().from(articles)
  .where(arrayOverlaps(articles.tags, ['orm', 'prisma']));
```

## Generated Columns

Columns computed by the database engine (cannot be inserted/updated):

```typescript
export const products = pgTable('products', {
  id: serial('id').primaryKey(),
  priceInCents: integer('price_in_cents').notNull(),
  quantity: integer('quantity').notNull(),
  totalInCents: integer('total_in_cents').generatedAlwaysAs(
    (): SQL => sql`${products.priceInCents} * ${products.quantity}`
  ),
});
```

## Database Views

```typescript
import { pgView } from 'drizzle-orm/pg-core';

export const activeUsers = pgView('active_users').as((qb) =>
  qb.select().from(users).where(eq(users.isActive, true))
);

// View with explicit columns + raw SQL
export const userStats = pgView('user_stats', {
  userId: integer('user_id'),
  postCount: integer('post_count'),
  latestPost: timestamp('latest_post'),
}).as(
  sql`SELECT author_id as user_id, count(*) as post_count, max(created_at) as latest_post FROM posts GROUP BY author_id`
);

const stats = await db.select().from(userStats).where(gte(userStats.postCount, 5));
// Use .existing() for views Drizzle shouldn't manage (e.g., introspected)
```

## Subqueries in SELECT

```typescript
// Subquery as derived table (with .as())
const postCountSq = db
  .select({ authorId: posts.authorId, count: count().as('post_count') })
  .from(posts).groupBy(posts.authorId).as('post_counts');

const usersWithCounts = await db
  .select({ id: users.id, name: users.name, postCount: postCountSq.count })
  .from(users)
  .leftJoin(postCountSq, eq(users.id, postCountSq.authorId));

// Subquery in WHERE (EXISTS)
const usersWithPosts = await db.select().from(users)
  .where(sql`EXISTS (SELECT 1 FROM posts WHERE posts.author_id = ${users.id})`);

// Subquery in WHERE (IN)
const activeAuthorIds = db.select({ id: posts.authorId }).from(posts)
  .where(eq(posts.published, true));
const activeAuthors = await db.select().from(users)
  .where(inArray(users.id, activeAuthorIds));
```

## Common Table Expressions (CTEs)

Use `$with()` for readable, composable multi-step queries:

```typescript
const recentPosts = db.$with('recent_posts').as(
  db.select().from(posts)
    .where(gte(posts.createdAt, sql`now() - interval '7 days'`))
);

const result = await db.with(recentPosts)
  .select({ authorName: users.name, postTitle: recentPosts.title })
  .from(recentPosts)
  .innerJoin(users, eq(recentPosts.authorId, users.id));

// Multiple CTEs — pass all to db.with(cte1, cte2)

// Recursive CTE (e.g., org chart / tree)
const orgChart = await db.execute(sql`
  WITH RECURSIVE subordinates AS (
    SELECT id, name, manager_id, 0 as depth FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.id, e.name, e.manager_id, s.depth + 1
    FROM employees e INNER JOIN subordinates s ON e.manager_id = s.id
  )
  SELECT * FROM subordinates ORDER BY depth, name
`);
```

## Window Functions

Use window functions via `sql` template for analytics queries:

```typescript
// ROW_NUMBER
const ranked = await db.select({
  id: posts.id,
  title: posts.title,
  rowNum: sql<number>`row_number() over (order by ${posts.createdAt} desc)`.as('row_num'),
}).from(posts);

// Running totals with SUM OVER
const runningTotals = await db.select({
  date: orders.date,
  amount: orders.amount,
  runningTotal: sql<number>`sum(${orders.amount}) over (order by ${orders.date})`.as('running_total'),
}).from(orders);

// Partitioned window — rank(), lag(), lead(), avg() also work
const perCategory = await db.select({
  id: products.id,
  category: products.category,
  categoryRank: sql<number>`row_number() over (partition by ${products.category} order by ${products.price} desc)`.as('cat_rank'),
  categoryAvg: sql<number>`avg(${products.price}) over (partition by ${products.category})`.as('cat_avg'),
}).from(products);
```

## Full-Text Search

```typescript
const tsvector = customType<{ data: string }>({
  dataType() { return 'tsvector'; },
});

export const articles = pgTable('articles', {
  id: serial('id').primaryKey(),
  title: text('title').notNull(),
  body: text('body').notNull(),
  search: tsvector('search').generatedAlwaysAs(
    (): SQL => sql`
      setweight(to_tsvector('english', coalesce(${articles.title}, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(${articles.body}, '')), 'B')
    `
  ),
}, (table) => [
  index('articles_search_idx').using('gin', table.search),
]);

async function searchArticles(query: string, limit = 20) {
  const tsquery = sql`plainto_tsquery('english', ${query})`;
  return db.select({
    id: articles.id,
    title: articles.title,
    rank: sql<number>`ts_rank(${articles.search}, ${tsquery})`.as('rank'),
    headline: sql<string>`ts_headline('english', ${articles.body}, ${tsquery}, 'StartSel=<b>, StopSel=</b>, MaxWords=50')`.as('headline'),
  })
  .from(articles)
  .where(sql`${articles.search} @@ ${tsquery}`)
  .orderBy(sql`ts_rank(${articles.search}, ${tsquery}) DESC`)
  .limit(limit);
}
// Also: phraseto_tsquery(), websearch_to_tsquery() for phrase/boolean search
```

## PostGIS with Drizzle

Use custom types or the `drizzle-postgis` community package:

```typescript
const point = customType<{ data: { lat: number; lng: number }; driverData: string }>({
  dataType() { return 'geometry(Point, 4326)'; },
  toDriver(value) { return `SRID=4326;POINT(${value.lng} ${value.lat})`; },
  fromDriver(value) {
    const match = value.match(/POINT\(([^ ]+) ([^ ]+)\)/);
    return match ? { lng: parseFloat(match[1]), lat: parseFloat(match[2]) } : { lat: 0, lng: 0 };
  },
});

export const locations = pgTable('locations', {
  id: serial('id').primaryKey(),
  name: text('name').notNull(),
  coords: point('coords').notNull(),
}, (table) => [
  index('locations_coords_idx').using('gist', table.coords),
]);

async function findNearby(lat: number, lng: number, radiusMeters: number) {
  return db.select().from(locations)
    .where(sql`ST_DWithin(${locations.coords}::geography,
      ST_SetSRID(ST_MakePoint(${lng}, ${lat}), 4326)::geography, ${radiusMeters})`)
    .orderBy(sql`ST_Distance(${locations.coords}::geography,
      ST_SetSRID(ST_MakePoint(${lng}, ${lat}), 4326)::geography)`);
}
```

**Note**: Run `CREATE EXTENSION IF NOT EXISTS postgis;` before table migrations.

## Multi-Schema Support

```typescript
import { pgTable, pgSchema, serial, text } from 'drizzle-orm/pg-core';

const authSchema = pgSchema('auth');
const billingSchema = pgSchema('billing');

export const authUsers = authSchema.table('users', {
  id: serial('id').primaryKey(),
  email: text('email').notNull().unique(),
  passwordHash: text('password_hash').notNull(),
});

export const subscriptions = billingSchema.table('subscriptions', {
  id: serial('id').primaryKey(),
  userId: integer('user_id').references(() => authUsers.id).notNull(),
  plan: text('plan').notNull(),
});

// Public schema uses regular pgTable (default)
```

In `drizzle.config.ts`, include all schemas: `schemaFilter: ['public', 'auth', 'billing']`. Cross-schema queries work transparently — Drizzle generates fully qualified table names.
