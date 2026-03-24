---
name: prisma-orm
description: >
  Prisma ORM expertise for TypeScript/JavaScript projects. Use when: writing schema.prisma files,
  generating Prisma Client, building CRUD APIs with Prisma, running migrations (prisma migrate),
  configuring connection pooling or Prisma Accelerate, deploying to edge/serverless with Prisma,
  introspecting existing databases, seeding data, writing raw SQL via Prisma, setting up
  Prisma extensions, resolving N+1 queries, handling BigInt serialization, or testing with Prisma.
  Do NOT use for: Sequelize, TypeORM, Drizzle ORM, Knex, MikroORM, raw SQL without Prisma,
  MongoDB Mongoose, Django ORM, SQLAlchemy, or any non-Prisma database tool.
  Do NOT use for general TypeScript/Node.js questions unrelated to database access.
---

# Prisma ORM

## Setup

```bash
npm install prisma --save-dev && npm install @prisma/client
npx prisma init --datasource-provider postgresql
```

Creates `prisma/schema.prisma` and `.env` with `DATABASE_URL`.

### Singleton Client (required for Next.js / hot-reload / serverless)

```typescript
import { PrismaClient } from '@prisma/client';
const globalForPrisma = globalThis as unknown as { prisma: PrismaClient };
export const prisma = globalForPrisma.prisma ?? new PrismaClient();
if (process.env.NODE_ENV !== 'production') globalForPrisma.prisma = prisma;
```

Always use a singleton — multiple instances exhaust the connection pool.

## Schema Definition

```prisma
datasource db {
  provider = "postgresql" // postgresql | mysql | sqlite | sqlserver | cockroachdb | mongodb
  url      = env("DATABASE_URL")
}

generator client {
  provider = "prisma-client-js"
  output   = "../node_modules/.prisma/client"
}

model User {
  id        Int       @id @default(autoincrement())
  email     String    @unique
  name      String?
  role      Role      @default(USER)
  posts     Post[]
  profile   Profile?
  createdAt DateTime  @default(now())
  updatedAt DateTime  @updatedAt
  @@index([email])
  @@map("users")
}

enum Role {
  USER
  ADMIN
  MODERATOR
}
```

**Field attributes:** `@id`, `@unique`, `@default(...)`, `@updatedAt`, `@map("col")`, `@db.VarChar(255)`, `@db.Text`.
**Model attributes:** `@@id([...])` (composite PK), `@@unique([...])`, `@@index([...])`, `@@map("table")`.

### Composite Types (MongoDB only)

```prisma
type Address { street String; city String; zip String }
model User {
  id      String  @id @default(auto()) @map("_id") @db.ObjectId
  address Address
}
```

## Relations

### One-to-One

```prisma
model User {
  id      Int      @id @default(autoincrement())
  profile Profile?
}
model Profile {
  id     Int  @id @default(autoincrement())
  user   User @relation(fields: [userId], references: [id], onDelete: Cascade)
  userId Int  @unique
}
```

### One-to-Many

```prisma
model User {
  id    Int    @id @default(autoincrement())
  posts Post[]
}
model Post {
  id       Int  @id @default(autoincrement())
  author   User @relation(fields: [authorId], references: [id])
  authorId Int
}
```

### Many-to-Many (implicit — Prisma auto-creates join table)

```prisma
model Post {
  id         Int        @id @default(autoincrement())
  categories Category[]
}
model Category {
  id    Int    @id @default(autoincrement())
  posts Post[]
}
```

### Many-to-Many (explicit — when join table needs extra fields)

```prisma
model CategoriesOnPosts {
  post       Post     @relation(fields: [postId], references: [id])
  postId     Int
  category   Category @relation(fields: [categoryId], references: [id])
  categoryId Int
  assignedAt DateTime @default(now())
  @@id([postId, categoryId])
}
```

### Self-Relations

```prisma
model Employee {
  id        Int        @id @default(autoincrement())
  manager   Employee?  @relation("Mgmt", fields: [managerId], references: [id])
  managerId Int?
  reports   Employee[] @relation("Mgmt")
}
```

## Prisma Client — CRUD

After schema changes: `npx prisma generate`

### Create

```typescript
const user = await prisma.user.create({
  data: { email: "a@b.com", name: "Alice" },
});
// Nested create
const userWithPosts = await prisma.user.create({
  data: { email: "a@b.com", posts: { create: [{ title: "Post 1" }, { title: "Post 2" }] } },
  include: { posts: true },
});
// Bulk
const count = await prisma.user.createMany({
  data: [{ email: "a@b.com" }, { email: "b@b.com" }],
  skipDuplicates: true,
});
```

### Read

```typescript
const user = await prisma.user.findUnique({ where: { email: "a@b.com" } });
const user = await prisma.user.findUniqueOrThrow({ where: { id: 1 } });
const first = await prisma.user.findFirst({ where: { role: "ADMIN" } });
const users = await prisma.user.findMany({
  where: { name: { contains: "Ali", mode: "insensitive" } },
  orderBy: { createdAt: "desc" },
  include: { posts: true },
});
```

### Update

```typescript
await prisma.user.update({ where: { id: 1 }, data: { name: "Bob" } });
// Upsert
await prisma.user.upsert({
  where: { email: "a@b.com" },
  update: { name: "Alice Updated" },
  create: { email: "a@b.com", name: "Alice" },
});
// Bulk
await prisma.user.updateMany({ where: { role: "USER" }, data: { role: "MODERATOR" } });
```

### Delete

```typescript
await prisma.user.delete({ where: { id: 1 } });
await prisma.user.deleteMany({ where: { role: "USER" } });
```

## Filtering

```typescript
const users = await prisma.user.findMany({
  where: {
    AND: [{ email: { endsWith: "@company.com" } }, { role: { in: ["ADMIN", "MODERATOR"] } }],
    OR: [{ name: { startsWith: "A" } }, { name: { startsWith: "B" } }],
    NOT: { email: { contains: "test" } },
    posts: { some: { published: true } },
    createdAt: { gte: new Date("2024-01-01") },
  },
});
```

**Operators:** `equals`, `not`, `in`, `notIn`, `lt`, `lte`, `gt`, `gte`, `contains`, `startsWith`, `endsWith`, `mode`.
**Relation filters:** `some`, `every`, `none`, `is`, `isNot`.

## Pagination

```typescript
// Offset-based
const page2 = await prisma.post.findMany({ skip: 10, take: 10 });
// Cursor-based (preferred for large datasets)
const next = await prisma.post.findMany({
  take: 10, skip: 1, cursor: { id: lastId }, orderBy: { id: "asc" },
});
```

## Select & Include

```typescript
// Select specific fields (returns only those fields)
const users = await prisma.user.findMany({
  select: { id: true, email: true, posts: { select: { title: true } } },
});
// Include relations (returns all scalar fields + specified relations)
const users = await prisma.user.findMany({
  include: { posts: true, profile: true },
});
```

Never combine `select` and `include` at the same level.

## Transactions

```typescript
// Interactive transaction
const result = await prisma.$transaction(async (tx) => {
  const user = await tx.user.create({ data: { email: "a@b.com" } });
  await tx.post.create({ data: { title: "Hi", authorId: user.id } });
  return user;
});
// Batch transaction
const [users, posts] = await prisma.$transaction([
  prisma.user.findMany(), prisma.post.findMany(),
]);
// With options
await prisma.$transaction(fn, { maxWait: 5000, timeout: 10000, isolationLevel: 'Serializable' });
```

## Raw Queries

```typescript
// Tagged template (auto-parameterized, injection-safe)
const users = await prisma.$queryRaw`SELECT * FROM users WHERE email = ${email}`;
// Execute (INSERT/UPDATE/DELETE → returns affected count)
const count = await prisma.$executeRaw`DELETE FROM users WHERE id = ${id}`;
// Unsafe (only for dynamic table/column names)
const result = await prisma.$queryRawUnsafe(`SELECT * FROM ${table}`);
```

Always prefer tagged templates over `$queryRawUnsafe`.

## Migrations

```bash
npx prisma migrate dev --name add_user_table    # dev: create + apply + generate
npx prisma migrate deploy                        # production: apply pending only
npx prisma migrate reset                         # drop + recreate + apply + seed
npx prisma migrate status                        # check pending migrations
npx prisma migrate dev --create-only             # generate SQL without applying
```

**Workflow:** edit schema → `migrate dev --name x` → review SQL in `prisma/migrations/` → commit → CI runs `migrate deploy`. Never edit applied migrations.

## Introspection

```bash
npx prisma db pull    # overwrite schema.prisma from existing DB
npx prisma generate   # regenerate client
```

Use `@map`/`@@map` to rename to idiomatic names after introspection.

## Seeding

```typescript
// prisma/seed.ts
import { PrismaClient } from '@prisma/client';
const prisma = new PrismaClient();
async function main() {
  await prisma.user.upsert({
    where: { email: "admin@test.com" },
    update: {},
    create: { email: "admin@test.com", name: "Admin", role: "ADMIN" },
  });
}
main().catch(console.error).finally(() => prisma.$disconnect());
```

In `package.json`: `{ "prisma": { "seed": "tsx prisma/seed.ts" } }`
Run: `npx prisma db seed`. Auto-runs on `prisma migrate reset`.

## Prisma Studio

```bash
npx prisma studio    # browser GUI on port 5555 for data browsing/editing
```

## Client Extensions

Extensions replace deprecated middleware. Use for soft deletes, audit logging, computed fields.

```typescript
// Soft delete
const prisma = new PrismaClient().$extends({
  query: {
    user: {
      async findMany({ args, query }) {
        args.where = { ...args.where, deletedAt: null };
        return query(args);
      },
    },
  },
});
// Computed field
const prisma = new PrismaClient().$extends({
  result: {
    user: {
      fullName: {
        needs: { firstName: true, lastName: true },
        compute(user) { return `${user.firstName} ${user.lastName}`; },
      },
    },
  },
});
```

## Logging

```typescript
const prisma = new PrismaClient({
  log: [{ level: 'query', emit: 'event' }, { level: 'error', emit: 'stdout' }],
});
prisma.$on('query', (e) => console.log(`${e.query} — ${e.duration}ms`));
```

## Prisma Accelerate & Connection Pooling

Connection pool via URL: `?connection_limit=10&pool_timeout=10`. Serverless: keep limit 1–5.

For production serverless/edge, use Prisma Accelerate:

```bash
npm install @prisma/extension-accelerate
```

```prisma
datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")        // Accelerate URL
  directUrl = env("DIRECT_DATABASE_URL") // direct DB URL for migrations
}
```

```typescript
import { PrismaClient } from '@prisma/client/edge';
import { withAccelerate } from '@prisma/extension-accelerate';
const prisma = new PrismaClient().$extends(withAccelerate());

const users = await prisma.user.findMany({
  cacheStrategy: { ttl: 60, swr: 120 },  // cache 60s, stale-while-revalidate 120s
});
```

Provides: global connection pooling, HTTP-based edge queries, per-query caching.

## Edge & Serverless Deployment

Edge runtimes lack TCP sockets. Use Accelerate or a driver adapter:

```typescript
import { Pool } from '@neondatabase/serverless';
import { PrismaNeon } from '@prisma/adapter-neon';
import { PrismaClient } from '@prisma/client';
const prisma = new PrismaClient({ adapter: new PrismaNeon(new Pool({ connectionString: env.DATABASE_URL })) });
```

Adapters: `@prisma/adapter-neon`, `@prisma/adapter-planetscale`, `@prisma/adapter-d1`, `@prisma/adapter-libsql`.

## Multi-File Schema

```prisma
generator client {
  provider        = "prisma-client-js"
  previewFeatures = ["prismaSchemaFolder"]
}
```

Organize as `prisma/schema/{base,user,post,enums}.prisma`.

## Testing — Unit (Mock Client)

```typescript
import { mockDeep } from 'jest-mock-extended';
import { PrismaClient } from '@prisma/client';
const prismaMock = mockDeep<PrismaClient>();
prismaMock.user.findMany.mockResolvedValue([{ id: 1, email: "a@b.com" }]);
```

### Integration Tests — Isolated Database```typescript
const prisma = new PrismaClient(); // uses TEST_DATABASE_URL
beforeEach(async () => {
  await prisma.$transaction([prisma.post.deleteMany(), prisma.user.deleteMany()]);
});
afterAll(() => prisma.$disconnect());
```

Run `prisma migrate deploy` before suite. Use separate `DATABASE_URL`.

## Common Gotchas

### N+1 Queries

```typescript
// BAD — N+1: one query per user for posts
const users = await prisma.user.findMany();
for (const u of users) {
  await prisma.post.findMany({ where: { authorId: u.id } });
}
// GOOD — single query with include
const users = await prisma.user.findMany({ include: { posts: true } });
```

Enable query logging to detect N+1 patterns.

### BigInt Serialization

`JSON.stringify` throws on BigInt fields. Fix with a client extension:

```typescript
const prisma = new PrismaClient().$extends({
  result: {
    $allModels: {
      toJSON: {
        compute(data) {
          return () => JSON.parse(JSON.stringify(data, (_, v) =>
            typeof v === 'bigint' ? v.toString() : v));
        },
      },
    },
  },
});
```

### Relation Loading

- Prisma does NOT lazy-load — always declare `include`/`select` upfront
- Avoid deep nesting; paginate nested relations: `include: { posts: { take: 5 } }`
- Never mix `select` and `include` at the same level

### Key Pitfalls

- **`@updatedAt`**: only fires on Prisma Client writes, not raw SQL or direct DB edits
- **Decimal fields**: returned as `Prisma.Decimal`, not `number` — call `.toNumber()`
- **Implicit m:n**: join table is Prisma-managed, cannot add extra columns — use explicit model
- **Hot reload**: creates new clients causing pool exhaustion — always use singleton
- **Schema drift**: detect with `prisma migrate diff`
- **Enum changes**: adding values is safe; removing/renaming requires data migration first

### Error Handling

```typescript
import { Prisma } from '@prisma/client';
try {
  await prisma.user.create({ data: { email: "dup@test.com" } });
} catch (e) {
  if (e instanceof Prisma.PrismaClientKnownRequestError) {
    if (e.code === 'P2002') console.log('Unique violation:', e.meta?.target);
    if (e.code === 'P2025') console.log('Record not found');
  }
}
```

Common codes: `P2002` (unique), `P2003` (FK), `P2025` (not found), `P2024` (pool timeout).
