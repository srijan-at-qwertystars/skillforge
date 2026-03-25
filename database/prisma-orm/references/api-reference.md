# Prisma Client API Reference

## Table of Contents

- [Model Operations](#model-operations)
  - [findUnique / findUniqueOrThrow](#findunique--finduniqueorthrow)
  - [findFirst / findFirstOrThrow](#findfirst--findfirstorthrow)
  - [findMany](#findmany)
  - [create](#create)
  - [createMany / createManyAndReturn](#createmany--createmanyandreturn)
  - [update](#update)
  - [updateMany](#updatemany)
  - [upsert](#upsert)
  - [delete](#delete)
  - [deleteMany](#deletemany)
  - [count](#count)
  - [aggregate](#aggregate)
  - [groupBy](#groupby)
- [Filter Operators](#filter-operators)
  - [Scalar Filters](#scalar-filters)
  - [Relation Filters](#relation-filters)
  - [Logical Operators](#logical-operators)
- [Relation Queries](#relation-queries)
  - [select & include](#select--include)
  - [Nested Writes](#nested-writes)
  - [Fluent API](#fluent-api)
  - [Relation Load Strategy](#relation-load-strategy)
- [Pagination & Ordering](#pagination--ordering)
- [Raw Queries](#raw-queries)
  - [$queryRaw](#queryraw)
  - [$executeRaw](#executeraw)
  - [$queryRawUnsafe / $executeRawUnsafe](#queryrawunsafe--executerawunsafe)
  - [$queryRawTyped (TypedSQL)](#queryrawtyped-typedsql)
- [Transaction API](#transaction-api)
  - [Sequential (Batch) Transactions](#sequential-batch-transactions)
  - [Interactive Transactions](#interactive-transactions)
  - [Isolation Levels](#isolation-levels)
- [Event System & Logging](#event-system--logging)
- [Client Lifecycle](#client-lifecycle)
- [Client Constructor Options](#client-constructor-options)

---

## Model Operations

### findUnique / findUniqueOrThrow

Returns a single record by a unique identifier (`@id`, `@unique`, `@@unique`).

```typescript
// Returns User | null
const user = await prisma.user.findUnique({
  where: { id: 1 },
  // OR compound unique:
  // where: { tenantId_email: { tenantId: 'acme', email: 'ada@prisma.io' } },
  select: { id: true, email: true },           // optional
  include: { posts: true },                     // optional (cannot mix with select at same level)
  relationLoadStrategy: 'join',                 // optional: 'join' | 'query'
})

// Throws PrismaClientKnownRequestError (P2025) if not found
const user = await prisma.user.findUniqueOrThrow({
  where: { id: 1 },
})
```

---

### findFirst / findFirstOrThrow

Returns the first matching record. Unlike `findUnique`, works with non-unique fields and supports ordering.

```typescript
const user = await prisma.user.findFirst({
  where: { active: true, role: 'ADMIN' },
  orderBy: { createdAt: 'desc' },
  skip: 0,                                      // optional: offset
  select: { id: true, email: true },            // optional
  include: { posts: true },                      // optional
  distinct: ['role'],                            // optional: distinct on fields
  relationLoadStrategy: 'join',                  // optional
})

// Throws P2025 if no match
const user = await prisma.user.findFirstOrThrow({ where: { id: 1 } })
```

---

### findMany

Returns a list of records matching the filters.

```typescript
const users = await prisma.user.findMany({
  where: { active: true },                      // optional: filters
  orderBy: [{ role: 'asc' }, { name: 'desc' }], // optional: sorting
  skip: 20,                                      // optional: offset pagination
  take: 10,                                      // optional: limit
  cursor: { id: 100 },                           // optional: cursor pagination
  select: { id: true, email: true },             // optional
  include: { posts: true },                       // optional
  distinct: ['role'],                             // optional
  relationLoadStrategy: 'join',                   // optional
})
```

---

### create

Creates a new record. Supports nested creates/connects.

```typescript
const user = await prisma.user.create({
  data: {
    email: 'ada@prisma.io',
    name: 'Ada',
    role: 'ADMIN',
    // Nested create
    posts: {
      create: [
        { title: 'First Post' },
        { title: 'Second Post' },
      ],
    },
    // Connect existing relation
    profile: {
      connect: { id: 1 },
    },
    // Create or connect
    department: {
      connectOrCreate: {
        where: { name: 'Engineering' },
        create: { name: 'Engineering' },
      },
    },
  },
  select: { id: true, email: true, posts: true },  // optional
  include: { posts: true },                          // optional
})
```

---

### createMany / createManyAndReturn

Bulk insert. Faster than individual creates. Does not support nested creates.

```typescript
// Returns count only
const result = await prisma.user.createMany({
  data: [
    { email: 'a@test.com', name: 'A' },
    { email: 'b@test.com', name: 'B' },
    { email: 'c@test.com', name: 'C' },
  ],
  skipDuplicates: true,  // optional: skip records that violate unique constraints
})
// result => { count: 3 }

// Returns created records (Prisma 5.14+)
const users = await prisma.user.createManyAndReturn({
  data: [
    { email: 'd@test.com', name: 'D' },
    { email: 'e@test.com', name: 'E' },
  ],
  select: { id: true, email: true },  // optional
})
```

---

### update

Updates a single record by unique field. Throws P2025 if not found.

```typescript
const user = await prisma.user.update({
  where: { id: 1 },
  data: {
    name: 'Ada Lovelace',
    // Numeric operations
    score: { increment: 10 },    // also: decrement, multiply, divide, set
    // Relation updates
    posts: {
      create: { title: 'New Post' },
      connect: { id: 5 },
      disconnect: { id: 3 },
      update: { where: { id: 2 }, data: { title: 'Updated' } },
      delete: { id: 4 },
      set: [{ id: 1 }, { id: 2 }],   // replace entire relation set
      updateMany: { where: { published: false }, data: { published: true } },
      deleteMany: { where: { createdAt: { lt: cutoff } } },
    },
  },
  select: { id: true, name: true },
  include: { posts: true },
})
```

**Numeric update operations:**
- `increment` — add to current value
- `decrement` — subtract from current value
- `multiply` — multiply current value
- `divide` — divide current value
- `set` — set to exact value

---

### updateMany

Bulk update. Returns count, not records. No nested relation updates.

```typescript
const result = await prisma.user.updateMany({
  where: { active: false, createdAt: { lt: cutoff } },
  data: { deletedAt: new Date() },
})
// result => { count: 42 }
```

---

### upsert

Update if exists, create if not. Requires a unique field in `where`.

```typescript
const user = await prisma.user.upsert({
  where: { email: 'ada@prisma.io' },
  update: { name: 'Ada Lovelace', lastLoginAt: new Date() },
  create: { email: 'ada@prisma.io', name: 'Ada Lovelace' },
  select: { id: true, email: true },
  include: { posts: true },
})
```

---

### delete

Deletes a single record by unique field. Throws P2025 if not found.

```typescript
const user = await prisma.user.delete({
  where: { id: 1 },
  select: { id: true, email: true },  // returns deleted record data
  include: { posts: true },
})
```

---

### deleteMany

Bulk delete. Returns count.

```typescript
const result = await prisma.user.deleteMany({
  where: { active: false },
})
// result => { count: 15 }

// Delete all records in table
await prisma.user.deleteMany()
// => { count: N }
```

---

### count

Count records matching a filter.

```typescript
const total = await prisma.user.count()
// => 42

const filtered = await prisma.user.count({
  where: { active: true, role: 'ADMIN' },
})

// Count with select — count specific fields (excludes nulls)
const counts = await prisma.user.count({
  select: { _all: true, name: true, email: true },
})
// => { _all: 42, name: 40, email: 42 }
```

---

### aggregate

Perform aggregate calculations on numeric fields.

```typescript
const stats = await prisma.user.aggregate({
  where: { active: true },              // optional filter
  _count: true,                          // or { _all: true }
  _avg: { score: true, age: true },
  _sum: { score: true },
  _min: { score: true, createdAt: true },
  _max: { score: true, createdAt: true },
  cursor: { id: 1 },                    // optional
  take: 100,                             // optional
  skip: 0,                              // optional
  orderBy: { score: 'desc' },           // optional
})
// => {
//   _count: 42,
//   _avg: { score: 85.3, age: 28.5 },
//   _sum: { score: 3583 },
//   _min: { score: 10, createdAt: '2024-01-01T...' },
//   _max: { score: 100, createdAt: '2024-12-01T...' },
// }
```

---

### groupBy

Group records by fields and aggregate per group.

```typescript
const groups = await prisma.user.groupBy({
  by: ['role', 'active'],                // group by these fields
  where: { createdAt: { gte: cutoff } }, // optional pre-filter
  _count: { _all: true },
  _avg: { score: true },
  _sum: { score: true },
  _min: { score: true },
  _max: { score: true },
  having: {                              // optional post-filter on aggregates
    score: { _avg: { gt: 50 } },
  },
  orderBy: { _count: { role: 'desc' } }, // optional
  skip: 0,                               // optional
  take: 10,                              // optional
})
// => [
//   { role: 'ADMIN', active: true, _count: { _all: 5 }, _avg: { score: 92 }, ... },
//   { role: 'USER', active: true, _count: { _all: 37 }, _avg: { score: 78 }, ... },
// ]
```

---

## Filter Operators

### Scalar Filters

| Operator        | Types                    | Example                                        |
|-----------------|--------------------------|-------------------------------------------------|
| `equals`        | All                      | `{ email: { equals: 'a@b.com' } }` or `{ email: 'a@b.com' }` |
| `not`           | All                      | `{ email: { not: 'a@b.com' } }` or `{ name: { not: null } }` |
| `in`            | All                      | `{ role: { in: ['ADMIN', 'MOD'] } }`            |
| `notIn`         | All                      | `{ role: { notIn: ['BANNED'] } }`               |
| `lt`            | Int, Float, DateTime     | `{ score: { lt: 100 } }`                        |
| `lte`           | Int, Float, DateTime     | `{ score: { lte: 100 } }`                       |
| `gt`            | Int, Float, DateTime     | `{ score: { gt: 0 } }`                          |
| `gte`           | Int, Float, DateTime     | `{ createdAt: { gte: new Date('2024-01-01') } }`|
| `contains`      | String                   | `{ email: { contains: 'prisma' } }`             |
| `startsWith`    | String                   | `{ name: { startsWith: 'Ada' } }`               |
| `endsWith`      | String                   | `{ email: { endsWith: '.io' } }`                |
| `mode`          | String (with above)      | `{ email: { contains: 'ADA', mode: 'insensitive' } }` |
| `search`        | String (fulltext)        | `{ title: { search: 'prisma & orm' } }`         |
| `isEmpty`       | List (scalar)            | `{ tags: { isEmpty: true } }`                   |
| `has`           | List (scalar)            | `{ tags: { has: 'typescript' } }`                |
| `hasEvery`      | List (scalar)            | `{ tags: { hasEvery: ['ts', 'prisma'] } }`       |
| `hasSome`       | List (scalar)            | `{ tags: { hasSome: ['ts', 'prisma'] } }`        |

### Relation Filters

| Operator   | Description                          | Example                                             |
|------------|--------------------------------------|-----------------------------------------------------|
| `some`     | At least one related record matches  | `{ posts: { some: { published: true } } }`          |
| `every`    | All related records match            | `{ posts: { every: { published: true } } }`         |
| `none`     | No related records match             | `{ posts: { none: { published: true } } }`          |
| `is`       | Related record matches (to-one)      | `{ author: { is: { name: 'Ada' } } }`               |
| `isNot`    | Related record doesn't match (to-one)| `{ author: { isNot: { role: 'BANNED' } } }`         |

### Logical Operators

```typescript
where: {
  AND: [{ active: true }, { role: 'ADMIN' }],
  OR:  [{ email: { endsWith: '.io' } }, { role: 'ADMIN' }],
  NOT: [{ email: { contains: 'test' } }],
}
```

---

## Relation Queries

### select & include

```typescript
// select — pick specific fields, exclude all others
const user = await prisma.user.findUnique({
  where: { id: 1 },
  select: {
    id: true,
    email: true,
    posts: {
      select: { id: true, title: true },
      where: { published: true },
      orderBy: { createdAt: 'desc' },
      take: 5,
    },
  },
})

// include — load all model fields PLUS relations
const user = await prisma.user.findUnique({
  where: { id: 1 },
  include: {
    posts: {
      where: { published: true },
      orderBy: { createdAt: 'desc' },
      take: 5,
      include: { comments: true },  // nested include
    },
    profile: true,
  },
})
```

**Rule:** Never mix `select` and `include` at the same query level.

### Nested Writes

Available on `create` and `update`:

| Operation          | Create | Update | Description                              |
|--------------------|--------|--------|------------------------------------------|
| `create`           | ✅     | ✅     | Create related record                    |
| `createMany`       | ✅     | ✅     | Bulk create related records              |
| `connect`          | ✅     | ✅     | Link to existing record by unique field  |
| `connectOrCreate`  | ✅     | ✅     | Connect if exists, create otherwise      |
| `disconnect`       | —      | ✅     | Unlink related record                    |
| `set`              | —      | ✅     | Replace entire relation set              |
| `update`           | —      | ✅     | Update specific related record           |
| `updateMany`       | —      | ✅     | Bulk update related records              |
| `delete`           | —      | ✅     | Delete specific related record           |
| `deleteMany`       | —      | ✅     | Bulk delete related records              |
| `upsert`           | —      | ✅     | Update or create related record          |

### Fluent API

Chain model accessors for relation traversal:

```typescript
const posts = await prisma.user.findUnique({ where: { id: 1 } }).posts()
const author = await prisma.post.findUnique({ where: { id: 1 } }).author()
```

### Relation Load Strategy

```typescript
// 'join' (default in Prisma 6) — single SQL query with JOIN
const users = await prisma.user.findMany({
  include: { posts: true },
  relationLoadStrategy: 'join',
})

// 'query' — separate queries (better for deeply nested or large relations)
const users = await prisma.user.findMany({
  include: { posts: { include: { comments: true } } },
  relationLoadStrategy: 'query',
})
```

---

## Pagination & Ordering

```typescript
// Offset pagination — simple, good for known page numbers
const page2 = await prisma.user.findMany({
  skip: 10,
  take: 10,
  orderBy: { createdAt: 'desc' },
})

// Cursor pagination — performant for infinite scroll / large datasets
const nextPage = await prisma.user.findMany({
  cursor: { id: lastSeenId },
  skip: 1,        // skip the cursor record itself
  take: 10,
  orderBy: { id: 'asc' },
})

// Multi-field ordering
const sorted = await prisma.user.findMany({
  orderBy: [
    { role: 'asc' },
    { createdAt: 'desc' },
    { name: 'asc' },
  ],
})

// Order by relation aggregate
const usersWithMostPosts = await prisma.user.findMany({
  orderBy: { posts: { _count: 'desc' } },
})

// Order by relevance (full-text search)
const results = await prisma.post.findMany({
  orderBy: { _relevance: { fields: ['title'], search: 'prisma', sort: 'desc' } },
})
```

---

## Raw Queries

### $queryRaw

Returns data. Uses tagged template for SQL injection safety.

```typescript
// Tagged template — parameterized, type-safe
const users = await prisma.$queryRaw<User[]>`
  SELECT id, email, name FROM "User"
  WHERE role = ${role} AND active = true
  ORDER BY "createdAt" DESC
  LIMIT ${limit}
`

// Dynamic table/column names require $queryRawUnsafe
```

### $executeRaw

Returns affected row count. For INSERT/UPDATE/DELETE/DDL.

```typescript
const count = await prisma.$executeRaw`
  UPDATE "User" SET active = false
  WHERE "lastLoginAt" < ${cutoff}
`
// count => 12
```

### $queryRawUnsafe / $executeRawUnsafe

For dynamic SQL. **Use parameterized placeholders** — never concatenate user input.

```typescript
// PostgreSQL uses $1, $2, etc.
const users = await prisma.$queryRawUnsafe(
  'SELECT * FROM "User" WHERE role = $1 AND active = $2',
  'ADMIN',
  true
)

// MySQL uses ?
const users = await prisma.$queryRawUnsafe(
  'SELECT * FROM User WHERE role = ? AND active = ?',
  'ADMIN',
  true
)
```

### $queryRawTyped (TypedSQL)

Fully type-safe raw SQL. Define SQL files, generate types.

```sql
-- prisma/sql/getUsersByRole.sql
-- @param {String} $1:role
SELECT id, email, name, "createdAt"
FROM "User"
WHERE role = $1::text AND active = true
ORDER BY "createdAt" DESC
```

```bash
npx prisma generate --sql
```

```typescript
import { getUsersByRole } from '@prisma/client/sql'
const admins = await prisma.$queryRawTyped(getUsersByRole('ADMIN'))
// admins is fully typed: { id: number, email: string, name: string | null, createdAt: Date }[]
```

---

## Transaction API

### Sequential (Batch) Transactions

All operations execute in a single transaction, single database round-trip.

```typescript
const [newUser, newPost, updatedStats] = await prisma.$transaction([
  prisma.user.create({ data: { email: 'ada@prisma.io', name: 'Ada' } }),
  prisma.post.create({ data: { title: 'Hello', authorId: 1 } }),
  prisma.stats.update({ where: { id: 1 }, data: { userCount: { increment: 1 } } }),
])
```

### Interactive Transactions

Full control with logic between queries. Auto-rollback on any thrown error.

```typescript
const transfer = await prisma.$transaction(async (tx) => {
  // tx is a transaction-scoped PrismaClient — use it for all queries
  const sender = await tx.account.update({
    where: { id: senderId },
    data: { balance: { decrement: amount } },
  })
  if (sender.balance < 0) throw new Error('Insufficient funds') // rollback

  const receiver = await tx.account.update({
    where: { id: receiverId },
    data: { balance: { increment: amount } },
  })

  return { sender, receiver }
}, {
  maxWait: 5000,     // ms to wait for pool connection
  timeout: 10000,    // ms max transaction duration
  isolationLevel: Prisma.TransactionIsolationLevel.Serializable,
})
```

### Isolation Levels

```typescript
Prisma.TransactionIsolationLevel.ReadUncommitted
Prisma.TransactionIsolationLevel.ReadCommitted
Prisma.TransactionIsolationLevel.RepeatableRead
Prisma.TransactionIsolationLevel.Serializable
Prisma.TransactionIsolationLevel.Snapshot     // SQL Server only
```

---

## Event System & Logging

### Constructor-based logging

```typescript
const prisma = new PrismaClient({
  log: ['query', 'info', 'warn', 'error'],  // log to stdout
})

// Or with emit control
const prisma = new PrismaClient({
  log: [
    { level: 'query', emit: 'event' },     // emit as event
    { level: 'info', emit: 'stdout' },      // print to stdout
    { level: 'warn', emit: 'stdout' },
    { level: 'error', emit: 'event' },
  ],
})
```

### Event listeners

```typescript
// Query events — includes SQL, params, duration
prisma.$on('query', (e) => {
  console.log(`Query: ${e.query}`)
  console.log(`Params: ${e.params}`)
  console.log(`Duration: ${e.duration}ms`)
  console.log(`Timestamp: ${e.timestamp}`)
})

// Error events
prisma.$on('error', (e) => {
  console.error(`Error: ${e.message}`)
  console.error(`Target: ${e.target}`)
})

// Info events
prisma.$on('info', (e) => {
  console.log(`Info: ${e.message}`)
})

// Warn events
prisma.$on('warn', (e) => {
  console.warn(`Warning: ${e.message}`)
})
```

### Log levels

| Level   | Description                                    |
|---------|------------------------------------------------|
| `query` | All SQL queries with parameters and duration   |
| `info`  | General informational messages                 |
| `warn`  | Warnings about potential issues                |
| `error` | Error messages                                 |

### Emit modes

| Mode     | Description                                      |
|----------|--------------------------------------------------|
| `stdout` | Print to standard output (default for all levels)|
| `event`  | Emit as client event, subscribe with `$on()`     |

---

## Client Lifecycle

```typescript
const prisma = new PrismaClient()

// Explicit connect (optional — auto-connects on first query)
await prisma.$connect()

// Disconnect — important for scripts, tests, serverless
await prisma.$disconnect()

// Shutdown hook for graceful cleanup
process.on('beforeExit', async () => {
  await prisma.$disconnect()
})
```

---

## Client Constructor Options

```typescript
const prisma = new PrismaClient({
  // Override datasource URL at runtime
  datasourceUrl: 'postgresql://user:pass@host/db',

  // Or override datasources object
  datasources: {
    db: { url: 'postgresql://user:pass@host/db' },
  },

  // Logging configuration
  log: ['query', 'warn', 'error'],

  // Error formatting
  errorFormat: 'pretty',   // 'pretty' | 'colorless' | 'minimal'

  // Driver adapter (Prisma 6)
  adapter: new PrismaPg({ connectionString: '...' }),
})
```
