# Prisma ORM — Advanced Patterns

## Table of Contents

- [Client Extensions ($extends)](#client-extensions-extends)
  - [Result Extensions — Computed Fields](#result-extensions--computed-fields)
  - [Model Extensions — Custom Methods](#model-extensions--custom-methods)
  - [Client Extensions — Top-Level Methods](#client-extensions--top-level-methods)
  - [Query Extensions — Interception](#query-extensions--interception)
  - [Composing Multiple Extensions](#composing-multiple-extensions)
- [Soft Delete](#soft-delete)
- [Audit Logging](#audit-logging)
- [Multi-Tenancy](#multi-tenancy)
  - [Row-Level Tenancy](#row-level-tenancy)
  - [Schema-Level Tenancy (PostgreSQL)](#schema-level-tenancy-postgresql)
  - [Database-Level Tenancy](#database-level-tenancy)
- [Polymorphic Relations Workarounds](#polymorphic-relations-workarounds)
- [Full-Text Search](#full-text-search)
- [JSON Field Queries](#json-field-queries)
- [Composite Types (MongoDB)](#composite-types-mongodb)
- [Views Support](#views-support)
- [Database Functions](#database-functions)
- [Relation Load Strategies](#relation-load-strategies)

---

## Client Extensions ($extends)

Extensions replace legacy `$use` middleware. They are composable, type-safe, and isolated — each extended client is independent.

### Result Extensions — Computed Fields

Add virtual fields computed from persisted data. Use `needs` to declare required fields.

```typescript
const prisma = new PrismaClient().$extends({
  result: {
    user: {
      fullName: {
        needs: { firstName: true, lastName: true },
        compute(user) {
          return `${user.firstName} ${user.lastName}`
        },
      },
      isAdmin: {
        needs: { role: true },
        compute(user) {
          return user.role === 'ADMIN'
        },
      },
    },
  },
})

const user = await prisma.user.findFirst()
// user.fullName => "Ada Lovelace"
// user.isAdmin  => true
```

**Computed fields referencing other computed fields:**

```typescript
const base = prisma.$extends({
  result: {
    user: {
      fullName: {
        needs: { firstName: true, lastName: true },
        compute(user) { return `${user.firstName} ${user.lastName}` },
      },
    },
  },
})

const extended = base.$extends({
  result: {
    user: {
      displayLabel: {
        needs: { fullName: true, email: true },
        compute(user) { return `${user.fullName} <${user.email}>` },
      },
    },
  },
})
```

### Model Extensions — Custom Methods

Add domain-specific methods directly to models.

```typescript
const prisma = new PrismaClient().$extends({
  model: {
    user: {
      async findActive() {
        return prisma.user.findMany({ where: { active: true } })
      },
      async findByEmail(email: string) {
        return prisma.user.findUnique({ where: { email } })
      },
      async softDelete(id: number) {
        return prisma.user.update({
          where: { id },
          data: { deletedAt: new Date() },
        })
      },
    },
    // Apply to all models
    $allModels: {
      async exists<T>(this: T, where: Record<string, unknown>): Promise<boolean> {
        const ctx = Prisma.getExtensionContext(this) as any
        const count = await ctx.count({ where })
        return count > 0
      },
    },
  },
})

await prisma.user.findActive()
await prisma.user.exists({ email: 'ada@prisma.io' })
await prisma.post.exists({ id: 42 })
```

### Client Extensions — Top-Level Methods

Add methods to the PrismaClient instance itself.

```typescript
const prisma = new PrismaClient().$extends({
  client: {
    async $log(message: string) {
      console.log(`[Prisma] ${new Date().toISOString()}: ${message}`)
    },
    $getConnectionUrl() {
      return process.env.DATABASE_URL ?? 'not set'
    },
  },
})

await prisma.$log('Application started')
```

### Query Extensions — Interception

Intercept and modify any query before execution. Replacement for deprecated `$use` middleware.

```typescript
const prisma = new PrismaClient().$extends({
  query: {
    // Specific model
    user: {
      async findMany({ args, query }) {
        args.where = { ...args.where, active: true }
        return query(args)
      },
    },
    // All models — add timing
    $allModels: {
      async $allOperations({ operation, model, args, query }) {
        const start = performance.now()
        const result = await query(args)
        const duration = performance.now() - start
        console.log(`${model}.${operation} took ${duration.toFixed(2)}ms`)
        return result
      },
    },
  },
})
```

### Composing Multiple Extensions

Extensions chain left-to-right. Later extensions see results of earlier ones.

```typescript
import { Prisma } from '@prisma/client'

const softDeleteExt = Prisma.defineExtension({
  name: 'soft-delete',
  query: {
    $allModels: {
      async findMany({ args, query }) {
        args.where = { ...args.where, deletedAt: null }
        return query(args)
      },
      async delete({ args, query }) {
        return (query as any)({
          ...args,
          data: { deletedAt: new Date() },
        } as any)
      },
    },
  },
})

const loggingExt = Prisma.defineExtension({
  name: 'logging',
  query: {
    $allModels: {
      async $allOperations({ operation, model, args, query }) {
        console.log(`[${model}.${operation}]`, JSON.stringify(args))
        return query(args)
      },
    },
  },
})

const prisma = new PrismaClient()
  .$extends(softDeleteExt)
  .$extends(loggingExt)
```

---

## Soft Delete

Full soft-delete pattern with transparent filtering:

```typescript
const softDelete = Prisma.defineExtension({
  name: 'soft-delete',
  model: {
    $allModels: {
      async softDelete<T>(this: T, where: Record<string, unknown>) {
        const ctx = Prisma.getExtensionContext(this) as any
        return ctx.update({ where, data: { deletedAt: new Date() } })
      },
      async restore<T>(this: T, where: Record<string, unknown>) {
        const ctx = Prisma.getExtensionContext(this) as any
        return ctx.update({ where, data: { deletedAt: null } })
      },
    },
  },
  query: {
    $allModels: {
      async findMany({ args, query }) {
        args.where = { ...args.where, deletedAt: null }
        return query(args)
      },
      async findFirst({ args, query }) {
        args.where = { ...args.where, deletedAt: null }
        return query(args)
      },
      async count({ args, query }) {
        args.where = { ...args.where, deletedAt: null }
        return query(args)
      },
    },
  },
})
```

**Schema requirement** — add to models that need soft delete:
```prisma
model User {
  // ... other fields
  deletedAt DateTime?
  @@index([deletedAt])
}
```

---

## Audit Logging

Capture who changed what and when using query extensions:

```typescript
// Schema for audit log table
// model AuditLog {
//   id        Int      @id @default(autoincrement())
//   model     String
//   action    String   // create | update | delete
//   recordId  String
//   before    Json?
//   after     Json?
//   userId    String?
//   timestamp DateTime @default(now())
//   @@index([model, recordId])
//   @@index([userId])
// }

function createAuditExtension(getCurrentUserId: () => string | null) {
  return Prisma.defineExtension({
    query: {
      $allModels: {
        async create({ model, args, query }) {
          const result = await query(args)
          await logAudit(model, 'create', String((result as any).id), null, result, getCurrentUserId())
          return result
        },
        async update({ model, args, query }) {
          const ctx = Prisma.getExtensionContext(this) as any
          const before = await ctx.findUnique({ where: args.where })
          const result = await query(args)
          await logAudit(model, 'update', String((result as any).id), before, result, getCurrentUserId())
          return result
        },
        async delete({ model, args, query }) {
          const ctx = Prisma.getExtensionContext(this) as any
          const before = await ctx.findUnique({ where: args.where })
          const result = await query(args)
          await logAudit(model, 'delete', String((result as any).id), before, null, getCurrentUserId())
          return result
        },
      },
    },
  })
}

async function logAudit(
  model: string, action: string, recordId: string,
  before: unknown, after: unknown, userId: string | null
) {
  const { PrismaClient } = await import('@prisma/client')
  const auditPrisma = new PrismaClient()
  await auditPrisma.auditLog.create({
    data: { model, action, recordId, before: before as any, after: after as any, userId },
  })
  await auditPrisma.$disconnect()
}
```

**Per-request context pattern (e.g. Express):**
```typescript
app.use((req, res, next) => {
  req.prisma = basePrisma.$extends(
    createAuditExtension(() => req.user?.id ?? null)
  )
  next()
})
```

---

## Multi-Tenancy

### Row-Level Tenancy

All tenants share tables; queries are scoped by `tenantId`.

```prisma
model User {
  id       Int    @id @default(autoincrement())
  tenantId String
  email    String
  @@unique([tenantId, email])
  @@index([tenantId])
}
```

```typescript
function forTenant(tenantId: string) {
  return basePrisma.$extends({
    query: {
      $allModels: {
        async findMany({ args, query }) {
          args.where = { ...args.where, tenantId }
          return query(args)
        },
        async findFirst({ args, query }) {
          args.where = { ...args.where, tenantId }
          return query(args)
        },
        async create({ args, query }) {
          args.data = { ...args.data, tenantId }
          return query(args)
        },
        async update({ args, query }) {
          args.where = { ...args.where, tenantId }
          return query(args)
        },
        async delete({ args, query }) {
          args.where = { ...args.where, tenantId }
          return query(args)
        },
      },
    },
  })
}

// Usage — in middleware
app.use((req, res, next) => {
  req.prisma = forTenant(req.headers['x-tenant-id'] as string)
  next()
})
```

### Schema-Level Tenancy (PostgreSQL)

Each tenant gets its own Postgres schema. Share one connection pool.

```typescript
async function forTenantSchema(tenantSchema: string) {
  const prisma = new PrismaClient()
  // Set search_path per connection
  await prisma.$executeRawUnsafe(`SET search_path TO "${tenantSchema}"`)
  return prisma
}

// Provision new tenant
async function provisionTenant(schema: string) {
  const prisma = new PrismaClient()
  await prisma.$executeRawUnsafe(`CREATE SCHEMA IF NOT EXISTS "${schema}"`)
  // Run migrations against the new schema via directUrl + search_path
  await prisma.$disconnect()
}
```

### Database-Level Tenancy

Separate databases per tenant. Map tenant → connection string.

```typescript
const tenantClients = new Map<string, PrismaClient>()

function getClient(tenantId: string): PrismaClient {
  if (!tenantClients.has(tenantId)) {
    const url = getTenantDatabaseUrl(tenantId) // your mapping logic
    tenantClients.set(tenantId, new PrismaClient({
      datasourceUrl: url,
    }))
  }
  return tenantClients.get(tenantId)!
}
```

---

## Polymorphic Relations Workarounds

Prisma does not natively support polymorphic relations. Common patterns:

### Pattern 1: Shared table with nullable FKs

```prisma
model Comment {
  id       Int   @id @default(autoincrement())
  body     String
  postId   Int?
  post     Post?   @relation(fields: [postId], references: [id])
  videoId  Int?
  video    Video?  @relation(fields: [videoId], references: [id])
  @@index([postId])
  @@index([videoId])
}
```

### Pattern 2: Separate join tables (preferred — enforces integrity)

```prisma
model PostComment {
  id        Int    @id @default(autoincrement())
  body      String
  postId    Int
  post      Post   @relation(fields: [postId], references: [id])
}
model VideoComment {
  id        Int    @id @default(autoincrement())
  body      String
  videoId   Int
  video     Video  @relation(fields: [videoId], references: [id])
}
```

### Pattern 3: Generic relation via type + ID columns

```prisma
model Comment {
  id             Int    @id @default(autoincrement())
  body           String
  commentableType String  // "Post" | "Video"
  commentableId   Int
  @@index([commentableType, commentableId])
}
```

```typescript
// Query helper
async function getCommentsFor(type: string, id: number) {
  return prisma.comment.findMany({
    where: { commentableType: type, commentableId: id },
  })
}
```

---

## Full-Text Search

### MySQL (GA)

```prisma
model Post {
  id    Int    @id @default(autoincrement())
  title String @db.VarChar(255)
  body  String @db.Text
  @@fulltext([title, body])
}
```

```typescript
const results = await prisma.post.findMany({
  where: { title: { search: 'prisma database' } },
})
```

### PostgreSQL (Preview)

Enable in schema:
```prisma
generator client {
  provider        = "prisma-client"
  previewFeatures = ["fullTextSearchPostgres"]
}
```

```typescript
const results = await prisma.post.findMany({
  where: { body: { search: 'cat & dog' } },
  orderBy: { _relevance: { fields: ['body'], search: 'cat & dog', sort: 'desc' } },
})
```

### Raw SQL for advanced search (PostgreSQL)

```typescript
const results = await prisma.$queryRaw`
  SELECT id, title,
    ts_rank(to_tsvector('english', body), plainto_tsquery('english', ${term})) AS rank
  FROM "Post"
  WHERE to_tsvector('english', body) @@ plainto_tsquery('english', ${term})
  ORDER BY rank DESC
  LIMIT 20
`
```

---

## JSON Field Queries

### Write

```typescript
await prisma.user.create({
  data: {
    metadata: { theme: 'dark', notifications: { email: true, sms: false } },
  },
})
```

### Read & Filter (PostgreSQL)

```typescript
// Exact match
await prisma.user.findMany({
  where: { metadata: { equals: { theme: 'dark' } } },
})

// Path-based filtering
await prisma.user.findMany({
  where: {
    metadata: {
      path: ['notifications', 'email'],
      equals: true,
    },
  },
})

// String contains at path
await prisma.user.findMany({
  where: {
    metadata: {
      path: ['theme'],
      string_contains: 'dark',
    },
  },
})

// Array contains
await prisma.user.findMany({
  where: {
    metadata: {
      path: ['tags'],
      array_contains: ['prisma'],
    },
  },
})
```

### JSON operators (PostgreSQL)

- `equals`, `not` — exact match
- `string_contains`, `string_starts_with`, `string_ends_with`
- `array_contains`, `array_starts_with`, `array_ends_with`
- `path` — drill into nested keys

### Advanced JSON queries via raw SQL

```typescript
await prisma.$queryRaw`
  SELECT * FROM "User"
  WHERE metadata->>'theme' = 'dark'
    AND metadata->'notifications'->>'email' = 'true'
`
```

---

## Composite Types (MongoDB)

Only supported for MongoDB. Define with `type` blocks:

```prisma
datasource db {
  provider = "mongodb"
  url      = env("DATABASE_URL")
}

type Address {
  street String
  city   String
  state  String
  zip    String
}

type SocialProfile {
  platform String
  url      String
}

model User {
  id       String          @id @default(auto()) @map("_id") @db.ObjectId
  email    String          @unique
  address  Address?
  socials  SocialProfile[]
}
```

```typescript
// Create with composite
await prisma.user.create({
  data: {
    email: 'ada@prisma.io',
    address: { set: { street: '123 Main', city: 'SF', state: 'CA', zip: '94105' } },
    socials: { set: [{ platform: 'github', url: 'https://github.com/ada' }] },
  },
})

// Filter on composite fields
await prisma.user.findMany({
  where: { address: { is: { city: 'SF' } } },
})

// Update composite
await prisma.user.update({
  where: { email: 'ada@prisma.io' },
  data: { address: { update: { city: 'Los Angeles' } } },
})
```

---

## Views Support

Database views are read-only models. Create the view in SQL, then map it in schema:

```sql
-- Migration SQL
CREATE VIEW "UserPostStats" AS
SELECT u.id AS "userId", u.name, COUNT(p.id) AS "postCount",
       MAX(p."createdAt") AS "lastPostAt"
FROM "User" u LEFT JOIN "Post" p ON p."authorId" = u.id
GROUP BY u.id, u.name;
```

```prisma
// Mark as a view (Prisma 5.x+)
view UserPostStats {
  userId    Int      @unique
  name      String?
  postCount Int
  lastPostAt DateTime?
}
```

```typescript
const stats = await prisma.userPostStats.findMany({
  where: { postCount: { gt: 5 } },
})
```

**Notes:**
- Use `view` keyword, not `model`
- Views are read-only — no create/update/delete
- Introspect existing views with `npx prisma db pull`
- Must have at least one `@unique` field for Prisma to track

---

## Database Functions

### Default values from DB functions

```prisma
model Post {
  id        Int      @id @default(autoincrement())
  slug      String   @default(dbgenerated("gen_random_uuid()"))
  createdAt DateTime @default(dbgenerated("NOW()"))
}
```

### Using functions in queries via raw SQL

```typescript
// PostgreSQL: generate UUID
const uuid = await prisma.$queryRaw`SELECT gen_random_uuid() AS id`

// Call stored procedure
await prisma.$executeRaw`CALL refresh_materialized_view('user_stats')`

// Window functions
const ranked = await prisma.$queryRaw`
  SELECT id, name, score,
    RANK() OVER (ORDER BY score DESC) AS rank
  FROM "User"
  WHERE active = true
`
```

### Stored procedures

```typescript
// Call a stored procedure
await prisma.$executeRaw`CALL archive_old_posts(${cutoffDate})`

// Call a function that returns data
const result = await prisma.$queryRaw`SELECT calculate_shipping(${weight}, ${zip}) AS cost`
```

---

## Relation Load Strategies

Prisma 6 lets you choose between database-level JOINs and application-level loading:

```typescript
// Database-level JOIN (single query, good for small relation sets)
const users = await prisma.user.findMany({
  include: { posts: true },
  relationLoadStrategy: 'join', // default in Prisma 6
})

// Application-level (separate queries, good for large/many relations)
const users = await prisma.user.findMany({
  include: { posts: true },
  relationLoadStrategy: 'query',
})
```

**When to use `query` strategy:**
- Loading many deeply nested relations
- Relations with large datasets (avoids cartesian explosion)
- When you need different connection pools for reads
