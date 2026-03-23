# Migrating from SQLite to Turso/libSQL

## Table of Contents

- [Compatibility Matrix](#compatibility-matrix)
  - [Fully Compatible Features](#fully-compatible-features)
  - [Partially Compatible Features](#partially-compatible-features)
  - [Unsupported Features](#unsupported-features)
  - [libSQL Extensions (New Features)](#libsql-extensions-new-features)
- [Connection String Changes](#connection-string-changes)
  - [URL Formats](#url-formats)
  - [Environment Variables](#environment-variables)
  - [Development vs Production](#development-vs-production)
- [ORM Integration Updates](#orm-integration-updates)
  - [Drizzle ORM](#drizzle-orm)
  - [Prisma](#prisma)
  - [SQLAlchemy (Python)](#sqlalchemy-python)
  - [Other ORMs and Query Builders](#other-orms-and-query-builders)
- [Testing Strategies](#testing-strategies)
  - [Local SQLite for Tests](#local-sqlite-for-tests)
  - [Test Database on Turso](#test-database-on-turso)
  - [CI/CD Integration Testing](#cicd-integration-testing)
- [Data Migration Tools and Procedures](#data-migration-tools-and-procedures)
  - [Small Databases (< 100 MB)](#small-databases--100-mb)
  - [Large Databases (> 100 MB)](#large-databases--100-mb)
  - [Continuous Migration (Zero Downtime)](#continuous-migration-zero-downtime)
  - [Verification](#verification)

---

## Compatibility Matrix

### Fully Compatible Features

libSQL is a fork of SQLite. The following work identically:

| Feature | Status | Notes |
|---------|--------|-------|
| All SQL DML (SELECT, INSERT, UPDATE, DELETE) | ✓ | Identical syntax |
| CREATE TABLE, ALTER TABLE, DROP TABLE | ✓ | All column types supported |
| Indexes (B-tree, partial, expression) | ✓ | Same CREATE INDEX syntax |
| Triggers | ✓ | BEFORE, AFTER, INSTEAD OF |
| Views | ✓ | Regular and temp views |
| CTEs (WITH ... AS) | ✓ | Recursive CTEs too |
| Window functions | ✓ | ROW_NUMBER, RANK, etc. |
| JSON functions | ✓ | json_extract, json_each, etc. |
| Full-text search (FTS5) | ✓ | Same FTS5 syntax |
| WAL mode | ✓ | Default on Turso |
| STRICT tables | ✓ | Recommended for production |
| RETURNING clause | ✓ | `INSERT ... RETURNING *` |
| UPSERT (ON CONFLICT) | ✓ | Same syntax |
| Generated columns | ✓ | STORED and VIRTUAL |
| Foreign keys | ✓ | Must enable with PRAGMA |
| Type affinity | ✓ | Same SQLite type system |
| Aggregate functions | ✓ | Built-in and custom |
| Date/time functions | ✓ | datetime(), strftime(), etc. |
| Math functions | ✓ | abs(), round(), etc. |

### Partially Compatible Features

| Feature | Local/Embedded | Remote (Turso) | Notes |
|---------|---------------|----------------|-------|
| `ATTACH DATABASE` | ✓ | ✗ | No cross-database queries in remote mode |
| `PRAGMA` statements | ✓ (most) | Limited | Some PRAGMAs are no-ops remotely |
| Temp tables | ✓ | ✓ (per-connection) | Dropped when connection closes |
| `.dump` / `.import` | Via CLI | Via `turso db shell` | Different CLI interface |
| Backup API | ✓ (local) | Via Platform API | Use Turso's backup/export |

**PRAGMAs that work remotely**:
```sql
PRAGMA table_info(users);          -- ✓ Works
PRAGMA foreign_keys = ON;          -- ✓ Works
PRAGMA journal_mode;               -- ✓ Returns 'wal'
```

**PRAGMAs that are no-ops or restricted remotely**:
```sql
PRAGMA journal_mode = DELETE;      -- ✗ Ignored (WAL enforced)
PRAGMA page_size = 8192;           -- ✗ Ignored
PRAGMA cache_size = 10000;         -- ✗ Server-controlled
PRAGMA synchronous = OFF;          -- ✗ Ignored for safety
```

### Unsupported Features

| Feature | Why | Alternative |
|---------|-----|-------------|
| `load_extension()` | Security (remote execution) | Use libSQL built-in extensions (vectors, etc.) |
| Custom C functions | Cannot load native code | Use SQL or application-level logic |
| File-level locking control | Managed by Turso | N/A — Turso handles concurrency |
| Direct file access to `.db` | Database is remote | Use embedded replica for local file |
| Shared-cache mode | Not applicable in client-server | Each client has its own connection |

### libSQL Extensions (New Features)

These are available in libSQL/Turso but NOT in standard SQLite:

| Feature | Syntax | Description |
|---------|--------|-------------|
| Vector columns | `F32_BLOB(N)` | Native vector storage |
| Vector search | `vector_top_k()` | k-NN similarity search |
| Vector distance | `vector_distance_cos()` | Cosine distance function |
| `ALTER TABLE ... ADD COLUMN` with index | Standard | Enhanced ALTER TABLE |
| Random rowid | `RANDOM ROWID` | Non-sequential primary keys |

---

## Connection String Changes

### URL Formats

```
# Standard SQLite (file path)
./data/myapp.db
/absolute/path/to/myapp.db
file:myapp.db
sqlite:///path/to/myapp.db   (some ORMs)

# Turso remote
libsql://dbname-orgname.turso.io

# Turso embedded replica (local file + remote sync)
file:local-replica.db  (plus syncUrl config)

# Local libSQL server (sqld)
http://localhost:8080
ws://localhost:8080
```

### Environment Variables

Before (SQLite):
```bash
DATABASE_URL="./data/myapp.db"
# or
DATABASE_URL="file:./data/myapp.db"
```

After (Turso):
```bash
# Remote
TURSO_DATABASE_URL="libsql://myapp-myorg.turso.io"
TURSO_AUTH_TOKEN="eyJ..."

# Embedded replica
TURSO_DATABASE_URL="libsql://myapp-myorg.turso.io"
TURSO_AUTH_TOKEN="eyJ..."
TURSO_LOCAL_DB="file:local-replica.db"

# Local development (no auth needed)
TURSO_DATABASE_URL="file:dev.db"
```

### Development vs Production

Pattern: Use local SQLite file for development, Turso for production:

```typescript
import { createClient } from "@libsql/client";

function createDb() {
  if (process.env.NODE_ENV === "production") {
    return createClient({
      url: process.env.TURSO_DATABASE_URL!,
      authToken: process.env.TURSO_AUTH_TOKEN,
    });
  }
  // Local file for development — no Turso account needed
  return createClient({ url: "file:dev.db" });
}

export const db = createDb();
```

---

## ORM Integration Updates

### Drizzle ORM

**Before (SQLite with better-sqlite3)**:
```typescript
// drizzle.config.ts
import type { Config } from "drizzle-kit";

export default {
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "sqlite",
  dbCredentials: {
    url: "./data/myapp.db",
  },
} satisfies Config;
```

```typescript
// src/db/index.ts
import { drizzle } from "drizzle-orm/better-sqlite3";
import Database from "better-sqlite3";

const sqlite = new Database("./data/myapp.db");
export const db = drizzle(sqlite);
```

**After (Turso)**:
```typescript
// drizzle.config.ts
import type { Config } from "drizzle-kit";

export default {
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dialect: "turso",
  dbCredentials: {
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  },
} satisfies Config;
```

```typescript
// src/db/index.ts
import { drizzle } from "drizzle-orm/libsql";
import { createClient } from "@libsql/client";

const client = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});

export const db = drizzle(client);
```

**Schema files don't change** — Drizzle schema definitions are the same for SQLite and Turso:
```typescript
// src/db/schema.ts — unchanged
import { sqliteTable, text, integer } from "drizzle-orm/sqlite-core";

export const users = sqliteTable("users", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
});
```

**Migration commands**:
```bash
# Same commands, different target
npx drizzle-kit generate   # Generate migration SQL
npx drizzle-kit migrate    # Apply to Turso
npx drizzle-kit push       # Push schema directly (dev)
```

### Prisma

**Before (SQLite)**:
```prisma
// prisma/schema.prisma
datasource db {
  provider = "sqlite"
  url      = "file:./dev.db"
}
```

**After (Turso with @prisma/adapter-libsql)**:
```bash
npm install @prisma/adapter-libsql @libsql/client
```

```prisma
// prisma/schema.prisma
datasource db {
  provider = "sqlite"
  url      = "file:./dev.db"   // Still used for local dev / migrations
}

generator client {
  provider        = "prisma-client-js"
  previewFeatures = ["driverAdapters"]
}
```

```typescript
// src/db.ts
import { PrismaClient } from "@prisma/client";
import { PrismaLibSQL } from "@prisma/adapter-libsql";
import { createClient } from "@libsql/client";

const libsql = createClient({
  url: process.env.TURSO_DATABASE_URL!,
  authToken: process.env.TURSO_AUTH_TOKEN,
});

const adapter = new PrismaLibSQL(libsql);
export const prisma = new PrismaClient({ adapter });
```

**Prisma migrations with Turso**:
```bash
# Generate migration (uses local SQLite)
npx prisma migrate dev --name add_users

# Apply to Turso manually
turso db shell myapp < prisma/migrations/20240101_add_users/migration.sql

# Or use db push for prototyping
npx prisma db push
```

> **Note**: Prisma's `migrate deploy` doesn't support Turso directly yet. Apply migration SQL files to Turso via `turso db shell` or the SDK.

### SQLAlchemy (Python)

**Before (SQLite)**:
```python
from sqlalchemy import create_engine

engine = create_engine("sqlite:///myapp.db")
```

**After (Turso with libsql-experimental)**:
```bash
pip install sqlalchemy libsql-experimental
```

```python
from sqlalchemy import create_engine

# Remote Turso
engine = create_engine(
    "sqlite+libsql://myapp-myorg.turso.io",
    connect_args={
        "auth_token": os.environ["TURSO_AUTH_TOKEN"],
        "secure": True,
    },
)

# Embedded replica
engine = create_engine(
    "sqlite+libsql:///local-replica.db",
    connect_args={
        "sync_url": os.environ["TURSO_DATABASE_URL"],
        "auth_token": os.environ["TURSO_AUTH_TOKEN"],
    },
)

# Local development
engine = create_engine("sqlite:///dev.db")
```

**Key changes**:
- Connection string prefix: `sqlite:///` → `sqlite+libsql://`
- Auth token passed via `connect_args`
- Models and queries remain unchanged

### Other ORMs and Query Builders

**Kysely**:
```bash
npm install kysely @libsql/kysely-libsql
```

```typescript
import { Kysely } from "kysely";
import { LibsqlDialect } from "@libsql/kysely-libsql";

const db = new Kysely({
  dialect: new LibsqlDialect({
    url: process.env.TURSO_DATABASE_URL!,
    authToken: process.env.TURSO_AUTH_TOKEN,
  }),
});
```

**Knex.js**: Use `knex-libsql` adapter (community-maintained). Configuration similar to Kysely.

---

## Testing Strategies

### Local SQLite for Tests

The simplest approach — use a local SQLite file for tests (no Turso account needed):

```typescript
// test/setup.ts
import { createClient } from "@libsql/client";

export function createTestDb() {
  const client = createClient({ url: "file::memory:" }); // In-memory for speed
  return client;
}

// test/users.test.ts
import { createTestDb } from "./setup";

describe("Users", () => {
  let db: ReturnType<typeof createTestDb>;

  beforeEach(async () => {
    db = createTestDb();
    await db.execute(`
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT NOT NULL UNIQUE
      )
    `);
  });

  it("should insert a user", async () => {
    await db.execute({
      sql: "INSERT INTO users (name, email) VALUES (?, ?)",
      args: ["Alice", "alice@example.com"],
    });
    const result = await db.execute("SELECT * FROM users");
    expect(result.rows).toHaveLength(1);
    expect(result.rows[0].name).toBe("Alice");
  });
});
```

### Test Database on Turso

For integration tests that need to verify Turso-specific behavior:

```bash
# Create a dedicated test database
turso db create myapp-test --group test

# Get connection info
turso db show myapp-test --url
turso db tokens create myapp-test
```

```typescript
// test/integration/setup.ts
import { createClient, type Client } from "@libsql/client";

let testClient: Client;

export async function getTestClient(): Promise<Client> {
  if (!testClient) {
    testClient = createClient({
      url: process.env.TURSO_TEST_DATABASE_URL!,
      authToken: process.env.TURSO_TEST_AUTH_TOKEN!,
    });
  }
  return testClient;
}

export async function cleanTestDb() {
  const client = await getTestClient();
  const tables = await client.execute(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
  );
  for (const table of tables.rows) {
    await client.execute(`DELETE FROM ${table.name}`);
  }
}
```

### CI/CD Integration Testing

```yaml
# .github/workflows/test.yml
name: Tests
on: [push, pull_request]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npm test
        # Unit tests use in-memory SQLite — no Turso secrets needed

  integration-tests:
    runs-on: ubuntu-latest
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npm run test:integration
        env:
          TURSO_TEST_DATABASE_URL: ${{ secrets.TURSO_TEST_DATABASE_URL }}
          TURSO_TEST_AUTH_TOKEN: ${{ secrets.TURSO_TEST_AUTH_TOKEN }}
```

---

## Data Migration Tools and Procedures

### Small Databases (< 100 MB)

The simplest migration path — dump and load:

```bash
# 1. Dump existing SQLite database
sqlite3 myapp.db .dump > dump.sql

# 2. Create Turso database
turso db create myapp

# 3. Load the dump
turso db shell myapp < dump.sql

# 4. Verify
turso db shell myapp "SELECT count(*) FROM users"
turso db inspect myapp
```

### Large Databases (> 100 MB)

For large databases, use the Turso CLI's direct import:

```bash
# Direct database file upload (faster than SQL dump for large DBs)
turso db create myapp --from-file myapp.db

# Or create from a dump file
turso db create myapp --from-dump dump.sql
```

**Chunked migration** for very large databases:

```bash
#!/bin/bash
# Migrate table-by-table for databases > 1 GB

TABLES=$(sqlite3 old.db ".tables")
turso db create myapp

for table in $TABLES; do
  echo "Migrating $table..."

  # Dump schema
  sqlite3 old.db ".schema $table" | turso db shell myapp

  # Dump data in chunks
  ROW_COUNT=$(sqlite3 old.db "SELECT count(*) FROM $table")
  CHUNK_SIZE=10000
  OFFSET=0

  while [ $OFFSET -lt $ROW_COUNT ]; do
    sqlite3 old.db ".mode insert $table" \
      "SELECT * FROM $table LIMIT $CHUNK_SIZE OFFSET $OFFSET" \
      | turso db shell myapp
    OFFSET=$((OFFSET + CHUNK_SIZE))
    echo "  $OFFSET / $ROW_COUNT rows"
  done
done
```

### Continuous Migration (Zero Downtime)

For production systems that can't tolerate downtime:

1. **Create Turso database and load initial data**:
   ```bash
   turso db create myapp --from-file myapp.db
   ```

2. **Dual-write**: Update application to write to both SQLite and Turso:
   ```typescript
   async function insertUser(name: string) {
     // Write to both
     await Promise.all([
       sqliteDb.run("INSERT INTO users (name) VALUES (?)", [name]),
       tursoClient.execute({ sql: "INSERT INTO users (name) VALUES (?)", args: [name] }),
     ]);
   }
   ```

3. **Verify data consistency**:
   ```bash
   # Compare row counts
   sqlite3 myapp.db "SELECT count(*) FROM users"
   turso db shell myapp "SELECT count(*) FROM users"
   ```

4. **Switch reads to Turso**: Update read queries to use Turso client.

5. **Remove SQLite writes**: Once stable, remove dual-write code.

### Verification

After migration, verify data integrity:

```bash
# Compare table schemas
sqlite3 old.db ".schema users"
turso db shell myapp ".schema users"

# Compare row counts for each table
for table in users orders products; do
  OLD=$(sqlite3 old.db "SELECT count(*) FROM $table")
  NEW=$(turso db shell myapp "SELECT count(*) FROM $table" 2>/dev/null | tail -1)
  echo "$table: old=$OLD new=$NEW $([ "$OLD" = "$NEW" ] && echo '✓' || echo '✗ MISMATCH')"
done

# Spot-check data
sqlite3 old.db "SELECT * FROM users ORDER BY id LIMIT 5"
turso db shell myapp "SELECT * FROM users ORDER BY id LIMIT 5"

# Verify indexes exist
turso db shell myapp "SELECT name, tbl_name FROM sqlite_master WHERE type='index'"
```
