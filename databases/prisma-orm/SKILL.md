---
name: prisma-orm
description:
  positive: "Use when user works with Prisma ORM, asks about Prisma schema, migrations, Prisma Client queries, relations, transactions, raw queries, Prisma with Next.js, or Prisma performance optimization."
  negative: "Do NOT use for TypeORM, Drizzle ORM, Sequelize, SQLAlchemy, or raw SQL without Prisma context."
---

# Prisma ORM Patterns and Best Practices

## Schema Design

Use PascalCase models (singular), camelCase fields. Map to DB names with `@map`/`@@map`. Use native type annotations for optimal columns.

```prisma
model UserProfile {
  id        Int      @id @default(autoincrement())
  email     String   @unique @db.VarChar(255)
  name      String?
  balance   Decimal  @db.Decimal(10, 2)
  role      Role     @default(USER)
  isActive  Boolean  @default(true)
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt
  @@map("user_profiles")
}

enum Role { USER ADMIN MODERATOR }
```

Index fields used in `where`, `orderBy`, and foreign keys. Use composite indexes for multi-column queries.

```prisma
model Post {
  id        Int      @id @default(autoincrement())
  title     String
  published Boolean  @default(false)
  authorId  Int
  author    User     @relation(fields: [authorId], references: [id])
  @@index([authorId])
  @@index([published, createdAt])
  @@unique([authorId, title])
}
```

Split large schemas across files with `prismaSchemaFolder` preview feature (Prisma 6+). Place models in `prisma/schema/*.prisma`.

## Relations

```prisma
// One-to-one: unique FK on child side
model User    { id Int @id @default(autoincrement()); profile Profile? }
model Profile { id Int @id @default(autoincrement()); userId Int @unique; user User @relation(fields: [userId], references: [id]) }

// One-to-many: FK on child, array on parent
model User { id Int @id @default(autoincrement()); posts Post[] }
model Post { id Int @id @default(autoincrement()); authorId Int; author User @relation(fields: [authorId], references: [id]); @@index([authorId]) }

// Many-to-many implicit: Prisma manages join table
model Post     { id Int @id @default(autoincrement()); tags Tag[] }
model Tag      { id Int @id @default(autoincrement()); posts Post[] }

// Many-to-many explicit: use when join table needs data
model PostTag {
  postId Int; tagId Int; assignedAt DateTime @default(now())
  post Post @relation(fields: [postId], references: [id])
  tag  Tag  @relation(fields: [tagId], references: [id])
  @@id([postId, tagId])
}

// Self-relation
model Employee {
  id Int @id @default(autoincrement()); managerId Int?
  manager Employee?  @relation("Mgmt", fields: [managerId], references: [id])
  reports Employee[] @relation("Mgmt")
}
```

Prefer explicit join tables when the relation carries metadata. Always `@@index` foreign key fields.

## Migrations

```bash
npx prisma migrate dev --name add-user-table   # dev: create + apply + generate
npx prisma migrate deploy                       # prod: apply pending, no prompts
npx prisma migrate reset                        # drop + recreate + seed
npx prisma migrate status                       # check pending migrations
```

Seed via `package.json`:

```json
{ "prisma": { "seed": "tsx prisma/seed.ts" } }
```

```typescript
import { PrismaClient } from '@prisma/client';
const prisma = new PrismaClient();
async function main() {
  await prisma.user.upsert({
    where: { email: 'admin@example.com' },
    update: {},
    create: { email: 'admin@example.com', name: 'Admin', role: 'ADMIN' },
  });
}
main().catch(e => { console.error(e); process.exit(1); }).finally(() => prisma.$disconnect());
```

Keep `prisma/migrations/` in version control. Never edit past migration files. Name descriptively. Use `prisma migrate diff` to preview. Use `prisma migrate deploy` in CI/CD, never `migrate dev`.

## Prisma Client Queries

```typescript
// Create
const user = await prisma.user.create({ data: { email: 'a@b.com', name: 'Alice' } });
// Read
const u = await prisma.user.findUnique({ where: { id: 1 } });
const u2 = await prisma.user.findUniqueOrThrow({ where: { id: 1 } }); // throws if missing
const all = await prisma.user.findMany({ where: { isActive: true } });
// Update / Delete
await prisma.user.update({ where: { id: 1 }, data: { name: 'Bob' } });
await prisma.user.delete({ where: { id: 1 } });
// Bulk
await prisma.user.createMany({ data: [{email:'a@b.com'},{email:'c@d.com'}], skipDuplicates: true });
await prisma.user.updateMany({ where: { isActive: false }, data: { deletedAt: new Date() } });
```

### Filtering, Sorting, Pagination

```typescript
const users = await prisma.user.findMany({
  where: {
    AND: [{ email: { contains: '@co.com' } }, { createdAt: { gte: new Date('2024-01-01') } }],
    OR: [{ role: 'ADMIN' }, { role: 'MODERATOR' }],
    NOT: { isActive: false },
    posts: { some: { published: true } },  // relation filter
  },
  orderBy: [{ createdAt: 'desc' }, { name: 'asc' }],
  skip: 20, take: 10,  // offset pagination
});
// Cursor-based pagination (preferred for large datasets)
const page = await prisma.post.findMany({
  take: 10, cursor: { id: lastId }, skip: 1, orderBy: { id: 'asc' },
});
```

## Advanced Queries

```typescript
// Nested writes — create parent + children in one call
const user = await prisma.user.create({
  data: {
    email: 'alice@example.com',
    profile: { create: { bio: 'Hello' } },
    posts: { create: [{ title: 'First' }, { title: 'Second' }] },
  },
  include: { profile: true, posts: true },
});

// connectOrCreate — link existing or create new
await prisma.post.create({
  data: {
    title: 'Post',
    author: { connectOrCreate: { where: { email: 'a@b.com' }, create: { email: 'a@b.com', name: 'A' } } },
  },
});

// Upsert — update if exists, create if not
await prisma.user.upsert({
  where: { email: 'a@b.com' }, update: { name: 'Updated' }, create: { email: 'a@b.com', name: 'New' },
});

// Aggregations and groupBy
const stats = await prisma.post.aggregate({ _count: true, _avg: { views: true }, where: { published: true } });
const grouped = await prisma.post.groupBy({
  by: ['categoryId'], _count: { id: true }, _avg: { views: true },
  having: { views: { _avg: { gt: 100 } } },
});
```

## Transactions

```typescript
// Batch: atomic array of operations
const [user, post] = await prisma.$transaction([
  prisma.user.create({ data: { email: 'tx@a.com' } }),
  prisma.post.create({ data: { title: 'P', authorId: 1 } }),
]);

// Interactive: logic depending on intermediate results
const result = await prisma.$transaction(async (tx) => {
  const sender = await tx.account.update({ where: { id: senderId }, data: { balance: { decrement: amount } } });
  if (sender.balance < 0) throw new Error('Insufficient funds'); // rolls back
  await tx.account.update({ where: { id: receiverId }, data: { balance: { increment: amount } } });
  return sender;
}, { maxWait: 5000, timeout: 10000, isolationLevel: 'Serializable' });
```

Isolation levels per-transaction: `ReadUncommitted`, `ReadCommitted`, `RepeatableRead`, `Serializable`.

## Raw Queries

```typescript
// Tagged template — prevents SQL injection
const users = await prisma.$queryRaw<User[]>`SELECT * FROM "User" WHERE email = ${email}`;
const affected = await prisma.$executeRaw`UPDATE "User" SET "isActive" = false WHERE "lastLogin" < ${cutoff}`;

// Dynamic composition with Prisma.sql
import { Prisma } from '@prisma/client';
const ids = [1, 2, 3];
const result = await prisma.$queryRaw`SELECT * FROM "User" WHERE id IN (${Prisma.join(ids)})`;

// TypedSQL (5.19+): write .sql files in prisma/sql/, run `prisma generate --sql`
// prisma/sql/getUsersByRole.sql: SELECT id, email FROM "User" WHERE role = $1
import { getUsersByRole } from '@prisma/client/sql';
const admins = await prisma.$queryRawTyped(getUsersByRole('ADMIN')); // fully typed result
```

Never interpolate user input into `$queryRawUnsafe`/`$executeRawUnsafe`. Always use tagged templates.

## Performance

```typescript
// Select only needed fields
const users = await prisma.user.findMany({ select: { id: true, email: true } });
// Include with filters
const data = await prisma.user.findMany({ include: { posts: { where: { published: true }, take: 5 } } });
```

Do not mix `select` and `include` at the same level. Avoid N+1 — use `include` instead of looping queries.

Singleton PrismaClient (critical for Next.js dev hot reload):

```typescript
// lib/prisma.ts
import { PrismaClient } from '@prisma/client';
const g = globalThis as unknown as { prisma: PrismaClient };
export const prisma = g.prisma ?? new PrismaClient();
if (process.env.NODE_ENV !== 'production') g.prisma = prisma;
```

Tune pool via URL: `?connection_limit=10&pool_timeout=10`. Use Prisma Accelerate or PgBouncer for serverless.

## Type Safety Patterns

```typescript
import { Prisma, User } from '@prisma/client';
// Infer payload types
type UserWithPosts = Prisma.UserGetPayload<{ include: { posts: true } }>;
// Reusable validated query objects
const withPosts = Prisma.validator<Prisma.UserDefaultArgs>()({ include: { posts: true } });
const users = await prisma.user.findMany(withPosts);
// satisfies for compile-time checks
const data = { email: 'a@b.com', name: 'A' } satisfies Prisma.UserCreateInput;
```

## Middleware and Extensions

Prefer extensions over deprecated middleware. Three extension types:

```typescript
// Query extension — intercept/modify queries (e.g., soft delete)
const xprisma = prisma.$extends({
  query: { $allModels: {
    async findMany({ args, query }) { args.where = { ...args.where, deletedAt: null }; return query(args); },
    async delete({ args, query }) { return (query as any)({ ...args, data: { deletedAt: new Date() } }); },
  }},
});
// Result extension — computed fields
const xprisma2 = prisma.$extends({
  result: { user: { fullName: {
    needs: { firstName: true, lastName: true },
    compute: (u) => `${u.firstName} ${u.lastName}`,
  }}},
});
// Model extension — custom methods
const xprisma3 = prisma.$extends({
  model: { user: { async findByEmail(email: string) { return prisma.user.findUnique({ where: { email } }); } } },
});
```

## Multi-Schema / Multi-Database

Generate separate clients with different `output` paths for multiple databases. Use `multiSchema` preview feature for PostgreSQL multi-schema access:

```prisma
generator client { provider = "prisma-client-js"; previewFeatures = ["multiSchema"] }
datasource db { provider = "postgresql"; url = env("DATABASE_URL"); schemas = ["public", "auth"] }
model User { id Int @id @default(autoincrement()); @@schema("auth") }
```

## Testing

```typescript
// Mock with jest-mock-extended
import { mockDeep } from 'jest-mock-extended';
import { PrismaClient } from '@prisma/client';
const prismaMock = mockDeep<PrismaClient>();
prismaMock.user.create.mockResolvedValue({ id: 1, email: 'a@b.com' } as any);

// Integration: use separate test DB, truncate before tests
beforeAll(async () => { await prisma.$executeRaw`TRUNCATE TABLE "User" CASCADE`; });
afterAll(async () => { await prisma.$disconnect(); });
```

Set `DATABASE_URL` to a test database in `.env.test`. Run `prisma migrate deploy` before test suite.

## Deployment

```json
{ "scripts": {
  "postinstall": "prisma generate",
  "build": "prisma generate && next build",
  "migrate:deploy": "prisma migrate deploy"
}}
```

Edge/serverless (Prisma 6+) — use client engine with driver adapters:

```prisma
generator client { provider = "prisma-client-js"; engineType = "client" }
```

```typescript
import { PrismaClient } from '@prisma/client';
import { PrismaPg } from '@prisma/adapter-pg';
const adapter = new PrismaPg({ connectionString: process.env.DATABASE_URL });
const prisma = new PrismaClient({ adapter });
```

Set `connection_limit=1` for serverless. Use `prisma.config.ts` (Prisma 6+) to centralize configuration.

## Common Patterns and Anti-Patterns

**Do:** Use singleton PrismaClient · `select`/`include` to limit data · `createMany` with `skipDuplicates` · interactive `$transaction` for multi-step mutations · `@@index` on FKs · cursor pagination for large sets · `findUniqueOrThrow` to avoid null checks · `prisma migrate deploy` in CI/CD.

**Do not:** Instantiate `new PrismaClient()` per request · use `findFirst` without `orderBy` for deterministic results · mix `select` and `include` at same level · use `$queryRawUnsafe` with user input · edit past migration files · use `prisma db push` in production · fetch full relation trees when only IDs are needed · skip FK indexes.