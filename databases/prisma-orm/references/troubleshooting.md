# Prisma Troubleshooting Guide

## Table of Contents

- [Migration Issues](#migration-issues)
  - [Migration Drift](#migration-drift)
  - [Shadow Database Problems](#shadow-database-problems)
  - [Failed Migrations](#failed-migrations)
- [Connection Issues](#connection-issues)
  - [Connection Pool Exhaustion](#connection-pool-exhaustion)
  - [Connection Timeout](#connection-timeout)
- [Error Codes](#error-codes)
  - [P2002 — Unique Constraint Violation](#p2002--unique-constraint-violation)
  - [P2025 — Record Not Found](#p2025--record-not-found)
  - [P2003 — Foreign Key Constraint](#p2003--foreign-key-constraint)
  - [P2024 — Connection Pool Timeout](#p2024--connection-pool-timeout)
  - [P2034 — Transaction Conflict](#p2034--transaction-conflict)
  - [P1001 — Can't Reach Database](#p1001--cant-reach-database)
  - [P1008 — Operations Timed Out](#p1008--operations-timed-out)
- [Docker Deployment Issues](#docker-deployment-issues)
- [CI/CD Issues](#cicd-issues)
- [Binary Targets](#binary-targets)
- [Query Engine Memory Usage](#query-engine-memory-usage)
- [Schema Validation Errors](#schema-validation-errors)
- [@map / @@map Confusion](#map--map-confusion)

---

## Migration Issues

### Migration Drift

**Symptom:** `prisma migrate dev` warns about drift between schema and database.

**Diagnosis:**
```bash
# Show what's different
npx prisma migrate diff \
  --from-migrations ./prisma/migrations \
  --to-schema-datamodel ./prisma/schema.prisma

# Compare database state to schema
npx prisma migrate diff \
  --from-schema-datasource ./prisma/schema.prisma \
  --to-schema-datamodel ./prisma/schema.prisma
```

**Causes and Fixes:**

1. **Manual database changes** — Someone altered the DB directly:
   ```bash
   # Option A: Baseline — mark existing state as a migration
   npx prisma migrate diff \
     --from-empty \
     --to-schema-datasource ./prisma/schema.prisma \
     --script > prisma/migrations/<timestamp>_baseline/migration.sql
   npx prisma migrate resolve --applied <timestamp>_baseline

   # Option B: Re-introspect
   npx prisma db pull
   npx prisma migrate dev --name realign
   ```

2. **Edited applied migration files** — Never edit files in `prisma/migrations/` after they've been applied. If you must:
   ```bash
   npx prisma migrate reset   # DESTRUCTIVE: drops DB and re-applies all migrations
   ```

3. **Different environments diverged** — Lock migration files in version control. Use `prisma migrate deploy` in production (never `dev`).

### Shadow Database Problems

**Symptom:** `Error: P3014 — Could not create shadow database` or `permission denied to create database`.

The shadow database is a temporary database Prisma creates during `migrate dev` to detect drift.

**Fixes:**

1. **Hosted DB without CREATE DATABASE permission:**
   ```env
   # Provide a separate shadow database URL
   SHADOW_DATABASE_URL="postgresql://user:pass@host:5432/shadow_db"
   ```
   ```prisma
   datasource db {
     provider          = "postgresql"
     url               = env("DATABASE_URL")
     shadowDatabaseUrl = env("SHADOW_DATABASE_URL")
   }
   ```

2. **Docker/local:** Ensure the DB user has `CREATEDB` privilege:
   ```sql
   ALTER USER prisma_user CREATEDB;
   ```

3. **SQLite:** Shadow DB is just a temp file — rarely an issue. Check filesystem permissions.

### Failed Migrations

**Symptom:** A migration failed partway through, leaving the database in an inconsistent state.

```bash
# Check migration status
npx prisma migrate status

# If a migration is marked as "failed":
# 1. Fix the database manually to match what the migration intended
# 2. Mark it as rolled back
npx prisma migrate resolve --rolled-back <migration_name>

# OR mark it as applied if you fixed it manually
npx prisma migrate resolve --applied <migration_name>

# Then re-run
npx prisma migrate dev
```

**Prevention:** Always use `--create-only` to review SQL before applying:
```bash
npx prisma migrate dev --create-only --name risky_change
# Review prisma/migrations/<timestamp>_risky_change/migration.sql
# Then apply
npx prisma migrate dev
```

---

## Connection Issues

### Connection Pool Exhaustion

**Symptom:** `P2024: A value is required but not set` or hanging queries, or `Timed out fetching a new connection from the connection pool`.

**Causes:**

1. **Multiple PrismaClient instances** (common in Next.js hot reload):
   ```typescript
   // BAD — creates new client every hot reload
   const prisma = new PrismaClient();

   // GOOD — singleton pattern
   const globalForPrisma = globalThis as unknown as { prisma: PrismaClient };
   export const prisma = globalForPrisma.prisma ?? new PrismaClient();
   if (process.env.NODE_ENV !== 'production') globalForPrisma.prisma = prisma;
   ```

2. **Missing `$disconnect()` in scripts/tests:**
   ```typescript
   // Always disconnect in scripts, seed files, tests
   async function main() { /* ... */ }
   main().finally(() => prisma.$disconnect());
   ```

3. **Pool too small for workload:**
   ```env
   # Increase pool size (default: num_cpus * 2 + 1)
   DATABASE_URL="postgresql://user:pass@host:5432/db?connection_limit=20&pool_timeout=10"
   ```

4. **Serverless cold starts creating too many connections:**
   ```env
   # Use minimal pool for serverless
   DATABASE_URL="postgresql://user:pass@host:5432/db?connection_limit=1"
   ```
   Better: use Prisma Accelerate or PgBouncer.

### Connection Timeout

**Symptom:** `P1001: Can't reach database server` or `P1002: The database server was reached but timed out`.

**Checklist:**
```bash
# 1. Verify connectivity
pg_isready -h <host> -p <port>

# 2. Check DATABASE_URL format
# postgresql://USER:PASSWORD@HOST:PORT/DATABASE?schema=public
# ⚠ Special characters in password must be URL-encoded

# 3. Test with psql
psql "$DATABASE_URL"

# 4. Check firewall / security groups
# AWS: check VPC security group inbound rules
# Docker: ensure network connectivity between containers
```

**SSL Issues:**
```env
# Force SSL
DATABASE_URL="postgresql://user:pass@host:5432/db?sslmode=require"

# Accept self-signed certs
DATABASE_URL="postgresql://user:pass@host:5432/db?sslmode=require&sslaccept=accept_invalid_certs"
```

---

## Error Codes

### P2002 — Unique Constraint Violation

```typescript
import { Prisma } from '@prisma/client';

try {
  await prisma.user.create({ data: { email: 'existing@example.com' } });
} catch (e) {
  if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2002') {
    const fields = e.meta?.target as string[];
    // fields = ['email']
    throw new ConflictError(`Duplicate value for: ${fields.join(', ')}`);
  }
}
```

**Fix:** Use `upsert` for create-or-update scenarios:
```typescript
await prisma.user.upsert({
  where: { email: 'user@example.com' },
  update: { name: 'Updated' },
  create: { email: 'user@example.com', name: 'New' },
});
```

### P2025 — Record Not Found

Thrown by `update`, `delete`, `findUniqueOrThrow`, `findFirstOrThrow`.

```typescript
try {
  await prisma.user.update({ where: { id: 999 }, data: { name: 'X' } });
} catch (e) {
  if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2025') {
    throw new NotFoundError('User not found');
  }
}
```

**Fix:** Check existence first, or use `updateMany` (returns count, never throws):
```typescript
const { count } = await prisma.user.updateMany({
  where: { id: 999 },
  data: { name: 'X' },
});
if (count === 0) throw new NotFoundError('User not found');
```

### P2003 — Foreign Key Constraint

```typescript
// Trying to create a post with a non-existent authorId
try {
  await prisma.post.create({ data: { title: 'X', authorId: 999 } });
} catch (e) {
  if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2003') {
    const field = e.meta?.field_name; // 'authorId'
    throw new BadRequestError(`Invalid reference: ${field}`);
  }
}
```

### P2024 — Connection Pool Timeout

```typescript
// Catch pool exhaustion
try {
  await prisma.user.findMany();
} catch (e) {
  if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2024') {
    // Likely too many concurrent connections
    console.error('Connection pool exhausted. Current pool_timeout may be too low.');
    // Increase pool_timeout or connection_limit in DATABASE_URL
  }
}
```

### P2034 — Transaction Conflict

Occurs with `Serializable` or `RepeatableRead` isolation when concurrent transactions conflict.

```typescript
async function withTransactionRetry<T>(fn: () => Promise<T>, retries = 3): Promise<T> {
  for (let i = 0; i < retries; i++) {
    try {
      return await fn();
    } catch (e) {
      if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === 'P2034') {
        if (i === retries - 1) throw e;
        await new Promise((r) => setTimeout(r, Math.random() * 100 * (i + 1)));
        continue;
      }
      throw e;
    }
  }
  throw new Error('Unreachable');
}
```

### P1001 — Can't Reach Database

See [Connection Timeout](#connection-timeout) section.

### P1008 — Operations Timed Out

```env
# Increase query timeout (default 10s for interactive transactions)
DATABASE_URL="postgresql://user:pass@host:5432/db?connect_timeout=30"
```

```typescript
// For interactive transactions
await prisma.$transaction(fn, {
  maxWait: 10000,  // max time to acquire a connection (ms)
  timeout: 30000,  // max transaction duration (ms)
});
```

---

## Docker Deployment Issues

### Prisma Client Not Generated

```dockerfile
# Common mistake: missing generate step
# WRONG
FROM node:20-alpine
COPY . .
RUN npm install
CMD ["node", "dist/index.js"]

# CORRECT
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
COPY prisma ./prisma/
RUN npm ci
RUN npx prisma generate
COPY . .
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/package*.json ./
CMD ["node", "dist/index.js"]
```

### Database Connection from Docker

```yaml
# docker-compose.yml — common networking mistake
services:
  app:
    environment:
      # WRONG: localhost refers to the app container, not the DB
      DATABASE_URL: "postgresql://user:pass@localhost:5432/mydb"
      # CORRECT: use the service name
      DATABASE_URL: "postgresql://user:pass@db:5432/mydb"
  db:
    image: postgres:16
```

### Migration in Docker Entrypoint

```dockerfile
# entrypoint.sh
#!/bin/sh
set -e
npx prisma migrate deploy
exec "$@"
```

```dockerfile
COPY entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["node", "dist/index.js"]
```

### OpenSSL Mismatch

```
Error: libssl.so.1.1: cannot open shared object file
```

```dockerfile
# For Alpine-based images
RUN apk add --no-cache openssl

# Or specify the correct binary target in schema
generator client {
  provider      = "prisma-client-js"
  binaryTargets = ["native", "linux-musl-openssl-3.0.x"]
}
```

---

## CI/CD Issues

### Prisma Client Generation in CI

```yaml
# GitHub Actions example
- name: Install dependencies
  run: npm ci

- name: Generate Prisma Client
  run: npx prisma generate

# If using postinstall hook, ensure schema.prisma is available
# package.json
{
  "scripts": {
    "postinstall": "prisma generate"
  }
}
```

### Cache Prisma Engines

```yaml
# GitHub Actions — cache Prisma binaries
- uses: actions/cache@v4
  with:
    path: |
      node_modules/.prisma
      node_modules/@prisma/engines
    key: prisma-${{ hashFiles('prisma/schema.prisma') }}
```

### Migration in CI Pipeline

```yaml
# Apply migrations in staging/production
- name: Deploy migrations
  run: npx prisma migrate deploy
  env:
    DATABASE_URL: ${{ secrets.DATABASE_URL }}

# For PR checks — validate migration files
- name: Check migration status
  run: npx prisma migrate status
```

---

## Binary Targets

Prisma uses platform-specific query engine binaries. Mismatch causes:
```
Error: Unknown binaryTarget linux-arm64-openssl-3.0.x
```

### Common Targets

```prisma
generator client {
  provider      = "prisma-client-js"
  binaryTargets = [
    "native",                        // local development
    "linux-musl-openssl-3.0.x",     // Alpine Linux / Docker Alpine
    "linux-arm64-openssl-3.0.x",    // ARM64 Linux (AWS Graviton)
    "rhel-openssl-3.0.x",           // RHEL/Amazon Linux 2023
    "debian-openssl-3.0.x",         // Debian/Ubuntu
    "linux-arm64-openssl-1.1.x",    // ARM64 with OpenSSL 1.1
  ]
}
```

### Lambda / Serverless

```prisma
generator client {
  provider      = "prisma-client-js"
  binaryTargets = ["native", "rhel-openssl-3.0.x"]  // AWS Lambda uses Amazon Linux
}
```

**Reduce bundle size** — use only the engine you need:
```env
# Use only the library engine (smaller, no external binary)
PRISMA_CLIENT_ENGINE_TYPE=library
```

### Detecting Your Target

```bash
npx prisma -v
# Shows: Binary Targets: ["debian-openssl-3.0.x"]

# Inside a container
npx prisma -v | grep "Binary"
```

---

## Query Engine Memory Usage

### Symptoms
- Container OOM kills
- Increasing memory usage over time
- Lambda hitting memory limits

### Diagnosis

```typescript
// Log query engine metrics
const prisma = new PrismaClient({
  log: ['query', 'info', 'warn', 'error'],
});

// Enable metrics (preview feature)
// generator client {
//   previewFeatures = ["metrics"]
// }
const metrics = await prisma.$metrics.json();
console.log(JSON.stringify(metrics, null, 2));
```

### Fixes

1. **Disconnect after use in serverless:**
   ```typescript
   export async function handler(event: any) {
     try {
       return await prisma.user.findMany();
     } finally {
       await prisma.$disconnect();
     }
   }
   ```

2. **Limit result sets — never `findMany()` without limits:**
   ```typescript
   // BAD — loads entire table
   const all = await prisma.user.findMany();

   // GOOD — paginate
   const page = await prisma.user.findMany({ take: 100, skip: 0 });
   ```

3. **Use `select` to reduce payload:**
   ```typescript
   // BAD — fetches all columns + nested data
   const users = await prisma.user.findMany({ include: { posts: true } });

   // GOOD — only fetch what's needed
   const users = await prisma.user.findMany({
     select: { id: true, email: true },
   });
   ```

4. **Reduce connection pool for serverless:**
   ```env
   DATABASE_URL="...?connection_limit=1"
   ```

---

## Schema Validation Errors

### Common Validation Errors

**"Error validating model: Ambiguous relation detected"**
```prisma
// WRONG — Prisma can't determine which relation is which
model User {
  id       Int    @id
  sent     Message[]
  received Message[]
}
model Message {
  fromId Int
  toId   Int
  from   User @relation(fields: [fromId], references: [id])
  to     User @relation(fields: [toId], references: [id])
}

// FIXED — name the relations
model User {
  id       Int       @id
  sent     Message[] @relation("SentMessages")
  received Message[] @relation("ReceivedMessages")
}
model Message {
  fromId Int
  toId   Int
  from   User @relation("SentMessages", fields: [fromId], references: [id])
  to     User @relation("ReceivedMessages", fields: [toId], references: [id])
}
```

**"Error validating: The relation field must specify the `fields` argument"**
```prisma
// Every relation must have one side with `fields` + `references`
// The FK side holds the `@relation(fields: [...], references: [...])`
```

**"Error: The `@unique` attribute must be on the relation scalar field"**
```prisma
// For 1:1 relations, the FK field needs @unique
model Profile {
  userId Int  @unique  // Required for 1:1
  user   User @relation(fields: [userId], references: [id])
}
```

### Validation Commands

```bash
# Validate schema without touching the database
npx prisma validate

# Format schema file
npx prisma format
```

---

## @map / @@map Confusion

### Purpose

- `@map("column_name")` — maps a Prisma **field** to a database **column** with a different name
- `@@map("table_name")` — maps a Prisma **model** to a database **table** with a different name

### Common Mistakes

```prisma
// WRONG — using @map on the model level
model User {
  @map("users")  // ❌ This is a field attribute, not model attribute
}

// CORRECT
model User {
  id        Int    @id
  firstName String @map("first_name")  // field → column
  lastName  String @map("last_name")

  @@map("users")  // model → table
}
```

### When to Use

1. **After `prisma db pull`** — DB uses `snake_case`, Prisma prefers `camelCase`:
   ```prisma
   model UserAccount {
     id          Int    @id
     firstName   String @map("first_name")
     lastName    String @map("last_name")
     createdAt   DateTime @map("created_at")

     @@map("user_accounts")
   }
   ```

2. **Enum mapping:**
   ```prisma
   enum UserRole {
     ADMIN     @map("admin")
     MODERATOR @map("moderator")
     USER      @map("user")

     @@map("user_role")
   }
   ```

3. **Avoid reserved words:**
   ```prisma
   model Order {
     id   Int @id
     // "order" is reserved in SQL, use @@map to set the actual table name
     @@map("orders")
   }
   ```

### Key Rules

- `@map`/`@@map` only affect the **database** — Prisma Client always uses the Prisma name
- After renaming with `@map`, existing queries in your code don't need to change
- Migrations will generate `ALTER TABLE RENAME` if you add `@@map` to an existing model
- `@map` does NOT change the Prisma Client API — `user.firstName` stays the same regardless of `@map("first_name")`
