# Advanced Prisma Patterns

## Table of Contents

- [Client Extensions](#client-extensions)
- [Middleware Patterns (Legacy)](#middleware-patterns-legacy)
- [Custom Result Types](#custom-result-types)
- [Raw SQL Integration](#raw-sql-integration)
- [Multi-Tenant Patterns](#multi-tenant-patterns)
- [Soft Deletes](#soft-deletes)
- [Audit Logging](#audit-logging)
- [Prisma with GraphQL](#prisma-with-graphql)
- [Optimistic Concurrency Control](#optimistic-concurrency-control)
- [Composite Unique Constraints](#composite-unique-constraints)

---

## Client Extensions

Client extensions (`$extends`) are the modern replacement for middleware. They support four extension types: `query`, `result`, `model`, and `client`.

### Query Extensions

Intercept and modify any Prisma query before execution.

```typescript
const prisma = new PrismaClient().$extends({
  query: {
    // Apply to a specific model
    user: {
      async findMany({ args, query }) {
        args.where = { ...args.where, deletedAt: null };
        return query(args);
      },
      async create({ args, query }) {
        // Validate before create
        if (!args.data.email?.includes('@')) {
          throw new Error('Invalid email');
        }
        return query(args);
      },
    },
    // Apply to ALL models
    $allModels: {
      async findMany({ args, query }) {
        // Default ordering
        args.orderBy = args.orderBy ?? { createdAt: 'desc' };
        return query(args);
      },
    },
    // Apply to ALL operations on ALL models
    $allOperations({ model, operation, args, query }) {
      const start = performance.now();
      return query(args).finally(() => {
        const duration = performance.now() - start;
        console.log(`${model}.${operation} took ${duration.toFixed(2)}ms`);
      });
    },
  },
});
```

### Result Extensions (Computed Fields)

Add virtual/computed fields that don't exist in the database.

```typescript
const prisma = new PrismaClient().$extends({
  result: {
    user: {
      fullName: {
        needs: { firstName: true, lastName: true },
        compute(user) {
          return `${user.firstName} ${user.lastName}`;
        },
      },
      isActive: {
        needs: { lastLoginAt: true },
        compute(user) {
          const thirtyDaysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
          return user.lastLoginAt > thirtyDaysAgo;
        },
      },
    },
  },
});

// Usage — computed fields appear alongside DB fields
const user = await prisma.user.findFirst();
console.log(user.fullName); // "John Doe"
console.log(user.isActive); // true
```

### Model Extensions (Custom Methods)

Add custom methods to model namespaces.

```typescript
const prisma = new PrismaClient().$extends({
  model: {
    user: {
      async findByEmail(email: string) {
        return prisma.user.findUnique({ where: { email } });
      },
      async softDelete(id: number) {
        return prisma.user.update({
          where: { id },
          data: { deletedAt: new Date() },
        });
      },
      async exists(id: number): Promise<boolean> {
        const count = await prisma.user.count({ where: { id } });
        return count > 0;
      },
    },
    $allModels: {
      async exists<T>(this: T, where: Prisma.Args<T, 'findFirst'>['where']): Promise<boolean> {
        const ctx = Prisma.getExtensionContext(this);
        const result = await (ctx as any).findFirst({ where });
        return result !== null;
      },
    },
  },
});

// Usage
const user = await prisma.user.findByEmail('john@example.com');
const exists = await prisma.post.exists({ id: 1 });
```

### Client Extensions

Add methods to the top-level client.

```typescript
const prisma = new PrismaClient().$extends({
  client: {
    async $healthCheck() {
      try {
        await Prisma.getExtensionContext(this).$queryRaw`SELECT 1`;
        return { status: 'ok', timestamp: new Date() };
      } catch (error) {
        return { status: 'error', error: (error as Error).message };
      }
    },
  },
});

await prisma.$healthCheck(); // { status: 'ok', timestamp: ... }
```

### Composing Multiple Extensions

Extensions are chainable — each returns a new client instance.

```typescript
const base = new PrismaClient();
const withSoftDelete = base.$extends(softDeleteExtension);
const withAudit = withSoftDelete.$extends(auditExtension);
const withComputed = withAudit.$extends(computedFieldsExtension);
export const prisma = withComputed;
```

---

## Middleware Patterns (Legacy)

> **Note:** Middleware is deprecated in favor of client extensions. Use `$extends` for new code. This section covers migration from middleware.

```typescript
// LEGACY middleware pattern (deprecated)
prisma.$use(async (params, next) => {
  if (params.action === 'delete') {
    params.action = 'update';
    params.args.data = { deletedAt: new Date() };
  }
  return next(params);
});

// MODERN equivalent using client extensions
const prisma = new PrismaClient().$extends({
  query: {
    $allModels: {
      async delete({ args, query }) {
        return (query as any)({ ...args, data: { deletedAt: new Date() } });
      },
    },
  },
});
```

Key differences from middleware:
- Extensions are type-safe, middleware is not
- Extensions compose cleanly; middleware order matters and is fragile
- Extensions can target specific models; middleware intercepts everything
- Extensions support result/model/client; middleware only intercepts queries

---

## Custom Result Types

### Typed Raw Queries

```typescript
interface UserStats {
  role: string;
  count: bigint;
  avgPosts: number;
}

const stats = await prisma.$queryRaw<UserStats[]>`
  SELECT role, COUNT(*) as count, AVG(post_count) as "avgPosts"
  FROM users u
  LEFT JOIN (SELECT author_id, COUNT(*) as post_count FROM posts GROUP BY author_id) p
    ON u.id = p.author_id
  GROUP BY role
`;
```

### Validator with Result Extensions

```typescript
import { z } from 'zod';

const UserPublicSchema = z.object({
  id: z.number(),
  name: z.string(),
  email: z.string().email(),
});

type UserPublic = z.infer<typeof UserPublicSchema>;

const prisma = new PrismaClient().$extends({
  result: {
    user: {
      toPublic: {
        needs: { id: true, name: true, email: true },
        compute(user): UserPublic {
          return UserPublicSchema.parse(user);
        },
      },
    },
  },
});
```

### Payload Types (Prisma.validator)

```typescript
import { Prisma } from '@prisma/client';

// Reusable select/include definitions
const userWithPosts = Prisma.validator<Prisma.UserDefaultArgs>()({
  include: { posts: { where: { published: true }, take: 5 } },
});

type UserWithPosts = Prisma.UserGetPayload<typeof userWithPosts>;

// Function with typed return
async function getUser(id: number): Promise<UserWithPosts> {
  return prisma.user.findUniqueOrThrow({ where: { id }, ...userWithPosts });
}

// Satisfies pattern for input types
const userCreate = {
  email: 'test@example.com',
  name: 'Test',
} satisfies Prisma.UserCreateInput;
```

---

## Raw SQL Integration

### Tagged Templates (Safe)

```typescript
// Parameterized — injection-safe
const email = 'user@example.com';
const users = await prisma.$queryRaw`
  SELECT * FROM users WHERE email = ${email}
`;

// Prisma.sql for dynamic query building
import { Prisma } from '@prisma/client';

function buildQuery(filters: { role?: string; active?: boolean }) {
  const conditions: Prisma.Sql[] = [];
  if (filters.role) conditions.push(Prisma.sql`role = ${filters.role}`);
  if (filters.active !== undefined) conditions.push(Prisma.sql`active = ${filters.active}`);

  const whereClause = conditions.length > 0
    ? Prisma.sql`WHERE ${Prisma.join(conditions, ' AND ')}`
    : Prisma.empty;

  return prisma.$queryRaw`SELECT * FROM users ${whereClause}`;
}
```

### Dynamic Column/Table Names

```typescript
// ONLY use $queryRawUnsafe when you need dynamic identifiers
// ALWAYS validate/whitelist table and column names
const allowedColumns = ['name', 'email', 'created_at'] as const;
type AllowedColumn = typeof allowedColumns[number];

function sortUsers(column: AllowedColumn, direction: 'ASC' | 'DESC') {
  if (!allowedColumns.includes(column)) throw new Error('Invalid column');
  if (!['ASC', 'DESC'].includes(direction)) throw new Error('Invalid direction');
  return prisma.$queryRawUnsafe(
    `SELECT * FROM users ORDER BY "${column}" ${direction}`
  );
}
```

### Mixing Raw and Prisma Queries in Transactions

```typescript
await prisma.$transaction(async (tx) => {
  // Raw SQL for complex operations
  await tx.$executeRaw`
    UPDATE accounts SET balance = balance - ${amount}
    WHERE id = ${fromId} AND balance >= ${amount}
  `;

  // Prisma query for simple operations
  await tx.transferLog.create({
    data: { fromId, toId, amount, timestamp: new Date() },
  });
});
```

---

## Multi-Tenant Patterns

### Row-Level Security (Single Database)

Schema with tenant column:

```prisma
model User {
  id       Int    @id @default(autoincrement())
  email    String @unique
  tenantId String
  tenant   Tenant @relation(fields: [tenantId], references: [id])
  @@index([tenantId])
}

model Tenant {
  id    String @id @default(uuid())
  name  String
  users User[]
}
```

Tenant-scoped client extension:

```typescript
function forTenant(tenantId: string) {
  return new PrismaClient().$extends({
    query: {
      $allModels: {
        async findMany({ args, query }) {
          args.where = { ...args.where, tenantId };
          return query(args);
        },
        async findFirst({ args, query }) {
          args.where = { ...args.where, tenantId };
          return query(args);
        },
        async create({ args, query }) {
          args.data = { ...args.data, tenantId };
          return query(args);
        },
        async update({ args, query }) {
          args.where = { ...args.where, tenantId };
          return query(args);
        },
        async delete({ args, query }) {
          args.where = { ...args.where, tenantId };
          return query(args);
        },
      },
    },
  });
}

// Usage in middleware/request handler
app.use((req, res, next) => {
  req.prisma = forTenant(req.headers['x-tenant-id'] as string);
  next();
});
```

### PostgreSQL Row-Level Security (RLS)

```typescript
// Set the tenant context per-request using RLS
const prisma = new PrismaClient().$extends({
  query: {
    $allOperations({ args, query }) {
      return prisma.$transaction(async (tx) => {
        await tx.$executeRaw`SET LOCAL app.tenant_id = ${tenantId}`;
        return query(args);
      });
    },
  },
});

// PostgreSQL RLS policies (run as migration)
// CREATE POLICY tenant_isolation ON users
//   USING (tenant_id = current_setting('app.tenant_id')::uuid);
// ALTER TABLE users ENABLE ROW LEVEL SECURITY;
```

### Schema-Per-Tenant

```typescript
// Dynamically switch schemas per tenant
function createTenantClient(tenantSchema: string) {
  return new PrismaClient({
    datasources: {
      db: {
        url: `${process.env.DATABASE_URL}?schema=${tenantSchema}`,
      },
    },
  });
}

// Tenant client pool to reuse connections
const clientPool = new Map<string, PrismaClient>();

function getTenantClient(tenantId: string): PrismaClient {
  if (!clientPool.has(tenantId)) {
    clientPool.set(tenantId, createTenantClient(`tenant_${tenantId}`));
  }
  return clientPool.get(tenantId)!;
}
```

---

## Soft Deletes

Complete soft delete implementation via client extension:

```typescript
// Schema: add deletedAt to models that support soft delete
// model User {
//   ...
//   deletedAt DateTime?
// }

const softDeleteModels = ['User', 'Post', 'Comment'] as const;

const prisma = new PrismaClient().$extends({
  query: {
    $allModels: {
      async findMany({ model, args, query }) {
        if (softDeleteModels.includes(model as any)) {
          args.where = { ...args.where, deletedAt: null };
        }
        return query(args);
      },
      async findFirst({ model, args, query }) {
        if (softDeleteModels.includes(model as any)) {
          args.where = { ...args.where, deletedAt: null };
        }
        return query(args);
      },
      async findUnique({ model, args, query }) {
        if (softDeleteModels.includes(model as any)) {
          // findUnique doesn't support arbitrary where — use findFirst
          return (query as any)({ ...args, where: { ...args.where, deletedAt: null } });
        }
        return query(args);
      },
      async delete({ model, args, query }) {
        if (softDeleteModels.includes(model as any)) {
          return (prisma as any)[model[0].toLowerCase() + model.slice(1)].update({
            ...args,
            data: { deletedAt: new Date() },
          });
        }
        return query(args);
      },
      async deleteMany({ model, args, query }) {
        if (softDeleteModels.includes(model as any)) {
          return (prisma as any)[model[0].toLowerCase() + model.slice(1)].updateMany({
            ...args,
            data: { deletedAt: new Date() },
          });
        }
        return query(args);
      },
    },
  },
  model: {
    $allModels: {
      async findWithDeleted<T>(this: T, args?: any) {
        const ctx = Prisma.getExtensionContext(this);
        return (ctx as any).findMany(args);
      },
      async restore<T>(this: T, where: any) {
        const ctx = Prisma.getExtensionContext(this);
        return (ctx as any).update({ where, data: { deletedAt: null } });
      },
    },
  },
});
```

---

## Audit Logging

```typescript
// Schema for audit logs
// model AuditLog {
//   id        Int      @id @default(autoincrement())
//   model     String
//   action    String
//   recordId  String
//   before    Json?
//   after     Json?
//   userId    String?
//   timestamp DateTime @default(now())
//   @@index([model, recordId])
//   @@index([userId])
// }

import { AsyncLocalStorage } from 'async_hooks';
const userContext = new AsyncLocalStorage<{ userId: string }>();

const auditedModels = ['User', 'Post', 'Order'];
const auditedActions = ['create', 'update', 'delete'];

const prisma = new PrismaClient().$extends({
  query: {
    $allModels: {
      async $allOperations({ model, operation, args, query }) {
        if (!auditedModels.includes(model!) || !auditedActions.includes(operation)) {
          return query(args);
        }

        const ctx = userContext.getStore();
        let before: any = null;

        // Capture before state for update/delete
        if (['update', 'delete'].includes(operation) && args.where) {
          before = await (prisma as any)[model![0].toLowerCase() + model!.slice(1)]
            .findUnique({ where: args.where });
        }

        const result = await query(args);

        // Write audit log (fire-and-forget to avoid blocking)
        prisma.auditLog.create({
          data: {
            model: model!,
            action: operation,
            recordId: String(result?.id ?? args.where?.id ?? 'unknown'),
            before: before ? JSON.parse(JSON.stringify(before)) : null,
            after: ['delete'].includes(operation) ? null : JSON.parse(JSON.stringify(result)),
            userId: ctx?.userId ?? null,
          },
        }).catch(console.error);

        return result;
      },
    },
  },
});

// Set user context in request middleware
app.use((req, res, next) => {
  userContext.run({ userId: req.auth.userId }, next);
});
```

---

## Prisma with GraphQL

### Pothos (Recommended)

```typescript
import SchemaBuilder from '@pothos/core';
import PrismaPlugin from '@pothos/plugin-prisma';
import type PrismaTypes from '@pothos/plugin-prisma/generated';
import { prisma } from './db';

const builder = new SchemaBuilder<{
  PrismaTypes: PrismaTypes;
}>({
  plugins: [PrismaPlugin],
  prisma: { client: prisma },
});

// Define types from Prisma models
builder.prismaObject('User', {
  fields: (t) => ({
    id: t.exposeID('id'),
    email: t.exposeString('email'),
    name: t.exposeString('name', { nullable: true }),
    posts: t.relation('posts', {
      args: { take: t.arg.int({ defaultValue: 10 }) },
      query: (args) => ({ take: args.take ?? 10, orderBy: { createdAt: 'desc' } }),
    }),
  }),
});

// Queries with automatic dataloader batching
builder.queryField('users', (t) =>
  t.prismaField({
    type: ['User'],
    args: {
      take: t.arg.int({ defaultValue: 20 }),
      skip: t.arg.int({ defaultValue: 0 }),
    },
    resolve: (query, _root, args) =>
      prisma.user.findMany({ ...query, take: args.take!, skip: args.skip! }),
  })
);

// Mutations
builder.mutationField('createUser', (t) =>
  t.prismaField({
    type: 'User',
    args: {
      email: t.arg.string({ required: true }),
      name: t.arg.string(),
    },
    resolve: (query, _root, args) =>
      prisma.user.create({ ...query, data: { email: args.email, name: args.name } }),
  })
);
```

### Nexus

```typescript
import { makeSchema, objectType, queryType, mutationType } from 'nexus';
import { nexusPrisma } from 'nexus-plugin-prisma';

const User = objectType({
  name: 'User',
  definition(t) {
    t.model.id();
    t.model.email();
    t.model.name();
    t.model.posts({ pagination: true, ordering: true, filtering: true });
  },
});

const Query = queryType({
  definition(t) {
    t.crud.user();
    t.crud.users({ pagination: true, filtering: true, ordering: true });
  },
});

const schema = makeSchema({
  types: [User, Query],
  plugins: [nexusPrisma({ experimentalCRUD: true })],
  outputs: {
    schema: './generated/schema.graphql',
    typegen: './generated/typegen.ts',
  },
});
```

---

## Optimistic Concurrency Control

### Using a Version Field

```prisma
model Product {
  id      Int    @id @default(autoincrement())
  name    String
  price   Float
  stock   Int
  version Int    @default(0)
}
```

```typescript
async function updateProductPrice(id: number, newPrice: number, expectedVersion: number) {
  const result = await prisma.product.updateMany({
    where: { id, version: expectedVersion },
    data: { price: newPrice, version: { increment: 1 } },
  });

  if (result.count === 0) {
    throw new Error('Concurrent modification detected — reload and retry');
  }

  return prisma.product.findUnique({ where: { id } });
}

// Retry wrapper
async function withOptimisticRetry<T>(
  fn: () => Promise<T>,
  maxRetries = 3,
  delay = 100
): Promise<T> {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      if (attempt === maxRetries - 1) throw error;
      if ((error as Error).message.includes('Concurrent modification')) {
        await new Promise((r) => setTimeout(r, delay * (attempt + 1)));
        continue;
      }
      throw error;
    }
  }
  throw new Error('Max retries exceeded');
}
```

### Using updatedAt Timestamp

```typescript
async function updateIfUnchanged(id: number, data: any, lastKnownUpdate: Date) {
  return prisma.$transaction(async (tx) => {
    const current = await tx.product.findUniqueOrThrow({ where: { id } });
    if (current.updatedAt.getTime() !== lastKnownUpdate.getTime()) {
      throw new Error('Record has been modified since last read');
    }
    return tx.product.update({ where: { id }, data });
  });
}
```

---

## Composite Unique Constraints

### Definition

```prisma
model TeamMember {
  id     Int    @id @default(autoincrement())
  teamId Int
  userId Int
  role   String @default("member")
  team   Team   @relation(fields: [teamId], references: [id])
  user   User   @relation(fields: [userId], references: [id])

  @@unique([teamId, userId], name: "team_user")
  @@index([teamId])
}

model PostTag {
  postId Int
  tagId  Int
  post   Post @relation(fields: [postId], references: [id])
  tag    Tag  @relation(fields: [tagId], references: [id])

  @@id([postId, tagId])  // composite primary key
}
```

### Querying with Composite Keys

```typescript
// findUnique with composite key
const member = await prisma.teamMember.findUnique({
  where: {
    team_user: { teamId: 1, userId: 42 },  // uses @@unique name
  },
});

// Upsert with composite key
await prisma.teamMember.upsert({
  where: {
    team_user: { teamId: 1, userId: 42 },
  },
  update: { role: 'admin' },
  create: { teamId: 1, userId: 42, role: 'admin' },
});

// Composite primary key
const postTag = await prisma.postTag.findUnique({
  where: {
    postId_tagId: { postId: 1, tagId: 5 },
  },
});

// Delete with composite key
await prisma.postTag.delete({
  where: {
    postId_tagId: { postId: 1, tagId: 5 },
  },
});
```

### Composite Keys with Relations

```typescript
// Unique constraint across a relation boundary
// Use case: user can only review a product once
model Review {
  id        Int    @id @default(autoincrement())
  userId    Int
  productId Int
  rating    Int
  comment   String?

  @@unique([userId, productId])
}

// Query
const review = await prisma.review.findUnique({
  where: {
    userId_productId: { userId: 1, productId: 100 },
  },
});
```
