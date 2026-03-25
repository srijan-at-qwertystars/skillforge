---
name: prisma-orm
description: >
  Use when working with Prisma ORM: writing or editing schema.prisma files, Prisma Client queries
  (CRUD, filtering, relations, transactions, aggregations), Prisma Migrate, database modeling with
  Prisma models and relations, raw SQL via $queryRaw/$executeRaw/TypedSQL, Prisma middleware and
  client extensions ($extends), type-safe database access, connection pooling, Prisma Accelerate,
  seeding, and testing with Prisma. Do NOT use for: SQLAlchemy, Django ORM, TypeORM, Drizzle ORM,
  Sequelize, Knex, raw SQL without Prisma, MongoDB native driver, general database administration
  without an ORM context, or non-Prisma query builders.
---

# Prisma ORM Skill

## Setup
```bash
npm install prisma --save-dev && npm install @prisma/client
npx prisma init --datasource-provider postgresql
```
Creates `prisma/schema.prisma` + `.env` with `DATABASE_URL`. After schema changes: `npx prisma generate`.

## Schema: Datasource & Generator
```prisma
datasource db {
  provider  = "postgresql"  // postgresql | mysql | sqlite | sqlserver | mongodb | cockroachdb
  url       = env("DATABASE_URL")
  directUrl = env("DIRECT_DATABASE_URL")  // for migrations behind pooler
}
generator client {
  provider        = "prisma-client-js"
  previewFeatures = ["typedSql"]
}
```

## Models & Types
```prisma
model User {
  id        Int       @id @default(autoincrement())
  email     String    @unique
  name      String?
  role      Role      @default(USER)
  score     Float     @default(0)
  active    Boolean   @default(true)
  metadata  Json?
  avatar    Bytes?          // returns Uint8Array in Prisma 6
  createdAt DateTime  @default(now())
  updatedAt DateTime  @updatedAt
  posts     Post[]
  @@index([email, role])
  @@map("users")
}
enum Role { USER  ADMIN  MODERATOR }
```
**Scalar types:** `String`, `Int`, `BigInt`, `Float`, `Decimal`, `Boolean`, `DateTime`, `Json`, `Bytes`.
**Key attributes:** `@id`, `@unique`, `@@unique([a,b])`, `@default(autoincrement()|uuid()|cuid()|now())`, `@updatedAt`, `@map("col")`, `@@map("table")`, `@db.VarChar(255)`, `@@index([field])`.
**Prisma 6:** Min Node 18.18, TS 5.1. `Bytes` → `Uint8Array`. `NotFoundError` removed — use `P2025`.

## Relations

### One-to-One
```prisma
model User    { id Int @id @default(autoincrement()); profile Profile? }
model Profile { id Int @id @default(autoincrement()); bio String?
  userId Int @unique; user User @relation(fields: [userId], references: [id], onDelete: Cascade) }
```

### One-to-Many
```prisma
model User { id Int @id @default(autoincrement()); posts Post[] }
model Post { id Int @id @default(autoincrement()); title String
  authorId Int; author User @relation(fields: [authorId], references: [id])
  @@index([authorId]) }
```

### Many-to-Many (Implicit) — Prisma auto-creates join table
```prisma
model Post     { id Int @id @default(autoincrement()); categories Category[] }
model Category { id Int @id @default(autoincrement()); name String @unique; posts Post[] }
```

### Many-to-Many (Explicit) — custom join table with extra fields
```prisma
model PostCategory {
  postId Int; categoryId Int; assignedAt DateTime @default(now())
  post Post @relation(fields: [postId], references: [id])
  category Category @relation(fields: [categoryId], references: [id])
  @@id([postId, categoryId]) }
```

### Self-Relation
```prisma
model Employee { id Int @id @default(autoincrement()); managerId Int?
  manager Employee? @relation("Mgmt", fields: [managerId], references: [id])
  reports Employee[] @relation("Mgmt") }
```
**Rules:** Define both sides. Use `@relation(name:)` for multiple relations between same models. Add `@@index` on FK fields. **Referential actions** (`onDelete`/`onUpdate`): `Cascade`, `Restrict`, `NoAction`, `SetNull`, `SetDefault`.

## Client — CRUD
```typescript
import { PrismaClient } from '@prisma/client'
const prisma = new PrismaClient()
```
```typescript
// CREATE
const user = await prisma.user.create({
  data: { email: 'ada@prisma.io', name: 'Ada', posts: { create: { title: 'Hello' } } },
  include: { posts: true }
}) // => { id: 1, email: 'ada@prisma.io', posts: [{ id: 1, title: 'Hello' }] }

// CREATE MANY
await prisma.user.createMany({ data: [...users], skipDuplicates: true }) // => { count: N }

// READ
await prisma.user.findUnique({ where: { email: 'ada@prisma.io' } })
await prisma.user.findUniqueOrThrow({ where: { id: 1 } })  // throws P2025 if missing
await prisma.user.findFirst({ where: { active: true }, orderBy: { createdAt: 'desc' } })
await prisma.user.findMany({ where: { role: 'ADMIN' } })

// UPDATE — numeric ops: increment, decrement, multiply, divide, set
await prisma.user.update({ where: { id: 1 }, data: { score: { increment: 10 } } })

// UPSERT
await prisma.user.upsert({
  where: { email: 'ada@prisma.io' },
  update: { name: 'Ada Lovelace' },
  create: { email: 'ada@prisma.io', name: 'Ada Lovelace' }
})

// DELETE
await prisma.user.delete({ where: { id: 1 } })
await prisma.user.deleteMany({ where: { active: false } }) // => { count: N }
```

## Filtering
```typescript
await prisma.user.findMany({
  where: {
    email: { contains: 'prisma', mode: 'insensitive' },
    score: { gte: 10, lt: 100 },
    role: { in: ['ADMIN', 'MODERATOR'] },
    name: { not: null },
    OR: [{ active: true }, { role: 'ADMIN' }],
    posts: { some: { title: { startsWith: 'Hello' } } }  // relation filter
  }
})
```
**Operators:** `equals`, `not`, `in`, `notIn`, `lt`, `lte`, `gt`, `gte`, `contains`, `startsWith`, `endsWith`, `mode`.
**Relation filters:** `some`, `every`, `none`, `is`, `isNot`.

## Select & Include
```typescript
// select — pick specific fields (reduces payload)
await prisma.user.findUnique({
  where: { id: 1 },
  select: { id: true, email: true, posts: { select: { title: true } } }
})
// include — load relations with filtering
await prisma.user.findUnique({
  where: { id: 1 },
  include: { posts: { where: { published: true }, take: 5, orderBy: { createdAt: 'desc' } } }
})
```
Never mix `select` and `include` at the same query level.

## Pagination & Ordering
```typescript
// offset pagination
await prisma.user.findMany({ skip: 20, take: 10, orderBy: [{ role: 'asc' }, { createdAt: 'desc' }] })
// cursor pagination (preferred for large datasets)
await prisma.user.findMany({ cursor: { id: lastId }, skip: 1, take: 10, orderBy: { id: 'asc' } })
```

## Aggregation & GroupBy
```typescript
const stats = await prisma.user.aggregate({
  _count: true, _avg: { score: true }, _sum: { score: true },
  _min: { createdAt: true }, _max: { score: true }, where: { active: true }
}) // => { _count: 42, _avg: { score: 85.3 }, _sum: { score: 3583 }, ... }

const groups = await prisma.user.groupBy({
  by: ['role'], _count: true, _avg: { score: true },
  having: { score: { _avg: { gt: 50 } } }, orderBy: { _count: { role: 'desc' } }
}) // => [{ role: 'ADMIN', _count: 5, _avg: { score: 92.1 } }, ...]
```

## Transactions
```typescript
// batch — all-or-nothing array, single round-trip
const [user, post] = await prisma.$transaction([
  prisma.user.create({ data: { email: 'a@b.com', name: 'A' } }),
  prisma.post.create({ data: { title: 'First', authorId: 1 } })
])
// interactive — full control, auto-rollback on throw
await prisma.$transaction(async (tx) => {
  const sender = await tx.account.update({ where: { id: 1 }, data: { balance: { decrement: 100 } } })
  if (sender.balance < 0) throw new Error('Insufficient funds')
  await tx.account.update({ where: { id: 2 }, data: { balance: { increment: 100 } } })
}, { maxWait: 5000, timeout: 10000 })
```

## Raw Queries
```typescript
// tagged template — parameterized, injection-safe
const users = await prisma.$queryRaw`SELECT * FROM "User" WHERE role = ${role}`
const affected = await prisma.$executeRaw`UPDATE "User" SET active = false WHERE "createdAt" < ${cutoff}`
// => 12 (rows affected)

// unsafe variant (only for dynamic SQL)
await prisma.$queryRawUnsafe('SELECT * FROM "User" WHERE id = $1', userId)
```
### TypedSQL (Prisma 5.19+) — fully typed raw SQL
Create `prisma/sql/getActiveUsers.sql`:
```sql
-- @param {Int} $1:minScore
SELECT id, email, score FROM users WHERE active = true AND score > $1
```
```bash
npx prisma generate --sql
```
```typescript
import { getActiveUsers } from '@prisma/client/sql'
const users = await prisma.$queryRawTyped(getActiveUsers(50)) // fully typed result
```

## Migrations
```bash
npx prisma migrate dev --name init       # create + apply (dev)
npx prisma migrate deploy                # apply pending (production)
npx prisma migrate reset                 # reset DB + reapply + seed
npx prisma migrate status                # check state
npx prisma db push                       # push without migration files (prototyping)
npx prisma db pull                       # introspect DB → schema
```
### Seeding — `prisma/seed.ts`
```typescript
import { PrismaClient } from '@prisma/client'
const prisma = new PrismaClient()
async function main() {
  await prisma.user.upsert({
    where: { email: 'admin@app.com' }, update: {},
    create: { email: 'admin@app.com', name: 'Admin', role: 'ADMIN' }
  })
}
main().catch(console.error).finally(() => prisma.$disconnect())
```
Add `"prisma": { "seed": "tsx prisma/seed.ts" }` to `package.json`. Run: `npx prisma db seed`.

## Client Extensions ($extends)
Extensions replace legacy `$use` middleware. Composable, type-safe, isolated.
```typescript
// Computed fields
const xprisma = prisma.$extends({
  result: { user: { fullName: {
    needs: { firstName: true, lastName: true },
    compute(user) { return `${user.firstName} ${user.lastName}` }
  }}}
})
await xprisma.user.findFirst() // => { ..., fullName: "Ada Lovelace" }

// Custom model methods
const xprisma = prisma.$extends({
  model: { user: { async findActive() { return prisma.user.findMany({ where: { active: true } }) } } }
})

// Query interception (soft delete)
const xprisma = prisma.$extends({
  query: { $allModels: {
    async findMany({ args, query }) { args.where = { ...args.where, deleted: false }; return query(args) }
  }}
})
```

## Error Handling
```typescript
import { Prisma } from '@prisma/client'
try { await prisma.user.create({ data: { email: 'dup@test.com' } }) }
catch (e) {
  if (e instanceof Prisma.PrismaClientKnownRequestError) {
    if (e.code === 'P2002') console.log('Unique violation on:', e.meta?.target)
    if (e.code === 'P2025') console.log('Record not found')
    if (e.code === 'P2003') console.log('FK constraint failed')
  }
  if (e instanceof Prisma.PrismaClientValidationError) console.log('Invalid query')
}
```
Key codes: `P2002` unique, `P2003` FK, `P2014` required relation, `P2025` not found.

## Connection Management — Singleton Pattern
```typescript
const globalForPrisma = globalThis as unknown as { prisma: PrismaClient }
export const prisma = globalForPrisma.prisma ?? new PrismaClient({ log: ['query', 'warn', 'error'] })
if (process.env.NODE_ENV !== 'production') globalForPrisma.prisma = prisma
```
Never instantiate per request. Use `$connect()` / `$disconnect()` for explicit lifecycle.
For serverless: use pooler (PgBouncer) or Prisma Accelerate. Set `connection_limit` in URL:
`postgresql://user:pass@host/db?connection_limit=10&pool_timeout=30`

## Performance Checklist
- Use `select` over `include` — fetch only needed fields.
- Add `@@index` on `where`/`orderBy`/FK fields.
- Cursor pagination for large datasets.
- Batch with `createMany`/`updateMany`/`deleteMany`.
- `$transaction([...])` batches multiple ops into one round-trip.
- Avoid N+1: use `include`/`select` with nested relations, not query loops.

## Testing
```typescript
// Integration: use separate test DB, reset before suite
import { execSync } from 'child_process'
execSync('npx prisma migrate reset --force', { env: { ...process.env, DATABASE_URL: testUrl } })

// Unit: mock with jest-mock-extended
import { mockDeep } from 'jest-mock-extended'
const prismaMock = mockDeep<PrismaClient>()
prismaMock.user.findMany.mockResolvedValue([{ id: 1, email: 'a@b.com', name: 'A' }])
```

## Next.js Integration
Use singleton above. Server Components query directly:
```typescript
// app/users/page.tsx
import { prisma } from '@/lib/prisma'
export default async function UsersPage() {
  const users = await prisma.user.findMany({ select: { id: true, name: true } })
  return <ul>{users.map(u => <li key={u.id}>{u.name}</li>)}</ul>
}
```

## NestJS Integration
```typescript
@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  async onModuleInit() { await this.$connect() }
  async onModuleDestroy() { await this.$disconnect() }
}
```

## Multi-Schema (PostgreSQL)
```prisma
datasource db { provider = "postgresql"; url = env("DATABASE_URL"); schemas = ["public", "auth"] }
model User { id Int @id @default(autoincrement()); @@schema("auth") }
model Post { id Int @id @default(autoincrement()); @@schema("public") }
```

## Prisma Accelerate — Global Pooling & Caching
```bash
npm install @prisma/extension-accelerate
```
```typescript
import { withAccelerate } from '@prisma/extension-accelerate'
const prisma = new PrismaClient().$extends(withAccelerate())
await prisma.user.findMany({ cacheStrategy: { ttl: 3600, swr: 600 } })
```
Set `DATABASE_URL` to Accelerate proxy. Keep `DIRECT_DATABASE_URL` for migrations.
