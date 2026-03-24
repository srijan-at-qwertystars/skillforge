# Migrating from PostgreSQL to CockroachDB

## Table of Contents

- [Overview](#overview)
- [Compatible vs Incompatible Features](#compatible-vs-incompatible-features)
  - [Fully Compatible Features](#fully-compatible-features)
  - [Partially Compatible Features](#partially-compatible-features)
  - [Incompatible Features](#incompatible-features)
  - [CockroachDB-Specific Features](#cockroachdb-specific-features)
- [Schema Conversion Tips](#schema-conversion-tips)
  - [Primary Keys](#primary-keys)
  - [Sequences](#sequences)
  - [Data Types](#data-types)
  - [Constraints and Indexes](#constraints-and-indexes)
  - [Stored Procedures and Functions](#stored-procedures-and-functions)
  - [Triggers](#triggers)
  - [Temp Tables](#temp-tables)
  - [System Catalogs](#system-catalogs)
- [MOLT Migration Tools](#molt-migration-tools)
  - [MOLT Fetch](#molt-fetch)
  - [MOLT Verify](#molt-verify)
  - [MOLT LDR (Live Data Replication)](#molt-ldr-live-data-replication)
- [Data Import with IMPORT INTO](#data-import-with-import-into)
  - [CSV Import](#csv-import)
  - [PostgreSQL Dump Import](#postgresql-dump-import)
  - [Pgdump Import](#pgdump-import)
  - [COPY FROM](#copy-from)
  - [Bulk Insert Strategies](#bulk-insert-strategies)
- [Application Code Changes](#application-code-changes)
  - [Connection Strings](#connection-strings)
  - [Transaction Retry Logic](#transaction-retry-logic)
  - [Query Compatibility Adjustments](#query-compatibility-adjustments)
  - [Error Handling Differences](#error-handling-differences)
- [ORM Compatibility](#orm-compatibility)
  - [ActiveRecord (Ruby/Rails)](#activerecord-rubyrails)
  - [SQLAlchemy (Python)](#sqlalchemy-python)
  - [GORM (Go)](#gorm-go)
  - [Prisma (Node.js/TypeScript)](#prisma-nodejs-typescript)
  - [Django ORM (Python)](#django-orm-python)
  - [Hibernate (Java)](#hibernate-java)
- [Migration Checklist](#migration-checklist)
- [Rollback Strategy](#rollback-strategy)

---

## Overview

CockroachDB is wire-compatible with PostgreSQL, meaning most PostgreSQL client
libraries, ORMs, and tools work without modification. However, there are
important differences in feature support, transaction semantics, and schema
design best practices.

**Key migration principle**: CockroachDB is *not* a drop-in replacement for
PostgreSQL. Plan for schema changes (especially primary keys), application code
changes (retry logic), and feature gaps (stored procedures, extensions).

## Compatible vs Incompatible Features

### Fully Compatible Features

These PostgreSQL features work identically in CockroachDB:

| Feature                 | Notes                                        |
|-------------------------|----------------------------------------------|
| SQL syntax (DML)        | SELECT, INSERT, UPDATE, DELETE, UPSERT       |
| JOINs                   | INNER, LEFT, RIGHT, FULL, CROSS, LATERAL     |
| CTEs                    | WITH, WITH RECURSIVE                         |
| Window functions        | ROW_NUMBER, RANK, DENSE_RANK, NTILE, etc.    |
| Subqueries              | Correlated and non-correlated                |
| JSONB                   | Full JSONB support including operators        |
| Arrays                  | Array types and operations                   |
| ENUM types              | User-defined enums                           |
| GIN indexes             | Inverted indexes on JSONB, arrays, text      |
| Partial indexes         | CREATE INDEX ... WHERE condition              |
| Expression indexes      | CREATE INDEX ... ON (expression)             |
| Views                   | Regular and materialized views               |
| pg_catalog              | Most system catalog tables                   |
| information_schema      | Standard information_schema views            |
| COPY                    | COPY FROM/TO for bulk data                   |
| Prepared statements     | Server-side prepared statements              |
| Transaction savepoints  | SAVEPOINT, RELEASE, ROLLBACK TO              |

### Partially Compatible Features

| Feature                 | CockroachDB Status                           |
|-------------------------|----------------------------------------------|
| Sequences               | Supported but generate unique_rowid() values; not gap-free; caching differs |
| Stored procedures       | Limited PL/pgSQL support (v23.1+); no `OUT` params, limited control flow |
| User-defined functions  | Supported (v23.1+) with limitations          |
| Triggers                | Basic support (v24.1+); limited to row-level AFTER triggers |
| Foreign keys            | Supported but cross-region can add latency   |
| Partitioning            | Different syntax — uses REGIONAL BY ROW or manual range partitioning |
| Full-text search        | Supported via full-text indexes (v23.1+)     |
| `pg_stat_*` views       | Partially populated; use `crdb_internal` instead |
| `SERIAL` type           | Maps to `unique_rowid()` not sequences; produces 64-bit ints |
| `TEMP TABLE`            | Session-scoped temp tables supported but implementation differs |
| Schemas (namespaces)    | Supported — CREATE SCHEMA works normally     |

### Incompatible Features

| Feature                 | Alternative in CockroachDB                   |
|-------------------------|----------------------------------------------|
| Extensions (PostGIS, etc.) | PostGIS partially supported (v23.1+); most extensions unavailable |
| `LISTEN`/`NOTIFY`       | Use changefeeds or external message queues   |
| Advisory locks          | No equivalent — redesign using FOR UPDATE or external coordination |
| XA transactions         | Not supported — use application-level sagas  |
| Custom operators        | Not supported                                |
| Custom aggregates       | Not supported                                |
| Table inheritance       | Not supported — use application logic or views |
| `CREATE RULE`           | Not supported — use triggers or app logic    |
| `DOMAIN` types          | Not supported — use CHECK constraints        |
| Row-level security      | Not supported natively — implement in app    |
| `VACUUM`/`ANALYZE`      | Automatic — no manual invocation needed      |
| Tablespaces             | Not supported — use zone configs for placement |
| Large objects (`lo`)    | Not supported — store as BYTES or external   |
| `pg_trgm`               | Not available — use full-text search or app-level |
| Logical replication     | Not supported — use changefeeds for CDC      |

### CockroachDB-Specific Features

Features available in CockroachDB but not PostgreSQL:

- Multi-region table localities (REGIONAL BY ROW, GLOBAL)
- Follower reads (`AS OF SYSTEM TIME`)
- Changefeeds (CDC)
- Hash-sharded indexes
- Online schema changes (no locks)
- Built-in backup/restore to cloud storage
- Automatic range-based sharding

## Schema Conversion Tips

### Primary Keys

**Most critical change**: Replace sequential integer PKs with UUIDs.

```sql
-- PostgreSQL
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE
);

-- CockroachDB
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email STRING(255) UNIQUE
);
```

If you must preserve integer keys, use hash-sharded indexes:

```sql
CREATE TABLE events (
    id INT PRIMARY KEY DEFAULT unique_rowid(),
    data JSONB
) USING HASH WITH (bucket_count = 16);
```

### Sequences

PostgreSQL sequences work in CockroachDB but behave differently:

```sql
-- PostgreSQL: gap-free, cache-1 sequences
CREATE SEQUENCE order_seq;
SELECT nextval('order_seq');  -- 1, 2, 3, ...

-- CockroachDB: sequences may have larger gaps due to distributed caching
-- Each node reserves a block of sequence values
CREATE SEQUENCE order_seq CACHE 1;  -- Minimize gaps (slower)
CREATE SEQUENCE order_seq CACHE 32; -- Better performance (more gaps)
```

**Recommendation**: Avoid sequences for primary keys. Use `gen_random_uuid()`
or `unique_rowid()` instead.

### Data Types

| PostgreSQL Type         | CockroachDB Equivalent           | Notes           |
|-------------------------|----------------------------------|-----------------|
| `SERIAL`                | `INT DEFAULT unique_rowid()`     | Not a sequence  |
| `BIGSERIAL`             | `INT8 DEFAULT unique_rowid()`    | Same caveat     |
| `VARCHAR(n)`            | `STRING(n)` or `VARCHAR(n)`      | Both work       |
| `TEXT`                   | `STRING`                        | Identical       |
| `BYTEA`                 | `BYTES`                          | Both work       |
| `BOOLEAN`               | `BOOL`                          | Both work       |
| `MONEY`                 | `DECIMAL(19,2)`                  | MONEY not supported |
| `CITEXT`                | `STRING` + collation             | No CITEXT extension |
| `HSTORE`                | `JSONB`                          | Convert to JSON |
| `XML`                   | `STRING` (no XML functions)      | Parse in app    |
| `INET`/`CIDR`           | `INET`                          | Supported       |
| `TSQUERY`/`TSVECTOR`    | Full-text index types            | Different API   |
| `INTERVAL`              | `INTERVAL`                       | Supported       |
| `POINT`/`POLYGON`/etc.  | Spatial types (limited PostGIS)  | Partial support |

### Constraints and Indexes

```sql
-- PostgreSQL: EXCLUDE constraints (not supported in CRDB)
CREATE TABLE bookings (
    room_id INT,
    during TSRANGE,
    EXCLUDE USING GIST (room_id WITH =, during WITH &&)
);

-- CockroachDB alternative: Use CHECK constraints or application logic
CREATE TABLE bookings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id INT NOT NULL,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ NOT NULL,
    CHECK (end_time > start_time)
);
-- Enforce non-overlap in application code or with SELECT FOR UPDATE
```

Index differences:
```sql
-- PostgreSQL: BRIN, GIST, SP-GIST indexes
-- CockroachDB: Only B-tree and inverted (GIN) indexes are supported

-- PostgreSQL: CREATE INDEX CONCURRENTLY
-- CockroachDB: All CREATE INDEX operations are online by default
CREATE INDEX idx_users_email ON users (email);  -- Always non-blocking
```

### Stored Procedures and Functions

```sql
-- PostgreSQL PL/pgSQL (complex)
CREATE OR REPLACE FUNCTION transfer(src UUID, dst UUID, amount DECIMAL)
RETURNS VOID AS $$
BEGIN
    IF (SELECT balance FROM accounts WHERE id = src) < amount THEN
        RAISE EXCEPTION 'Insufficient funds';
    END IF;
    UPDATE accounts SET balance = balance - amount WHERE id = src;
    UPDATE accounts SET balance = balance + amount WHERE id = dst;
END;
$$ LANGUAGE plpgsql;

-- CockroachDB (v23.1+ limited PL/pgSQL)
-- Simple functions work; complex control flow may not
CREATE OR REPLACE FUNCTION transfer(src UUID, dst UUID, amount DECIMAL)
RETURNS VOID AS $$
BEGIN
    UPDATE accounts SET balance = balance - amount WHERE id = src;
    UPDATE accounts SET balance = balance + amount WHERE id = dst;
END;
$$ LANGUAGE PLpgSQL;

-- For complex logic, move to application code with retry logic
```

### Triggers

```sql
-- PostgreSQL: Full trigger support
CREATE TRIGGER audit_trigger
    AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION audit_log_fn();

-- CockroachDB (v24.1+): Limited trigger support
-- Row-level AFTER triggers are supported
-- BEFORE triggers and statement-level triggers are not
-- Alternative: Use changefeeds for event-driven processing
```

### Temp Tables

```sql
-- PostgreSQL: ON COMMIT DROP/DELETE ROWS/PRESERVE ROWS
CREATE TEMP TABLE staging (data JSONB) ON COMMIT DROP;

-- CockroachDB: Session-scoped temp tables
-- ON COMMIT DROP is supported; temp tables are session-scoped
SET experimental_enable_temp_tables = on;
CREATE TEMP TABLE staging (data JSONB);
```

### System Catalogs

```sql
-- PostgreSQL: pg_stat_user_tables for table stats
SELECT relname, n_live_tup, n_dead_tup
FROM pg_stat_user_tables;

-- CockroachDB: Use crdb_internal
SELECT table_name, estimated_row_count
FROM crdb_internal.table_row_statistics;

-- PostgreSQL: pg_stat_activity for connections
SELECT pid, state, query FROM pg_stat_activity;

-- CockroachDB: crdb_internal.cluster_sessions
SELECT node_id, status, active_queries
FROM crdb_internal.cluster_sessions;
```

## MOLT Migration Tools

CockroachDB provides the **MOLT** (Migrate Off Legacy Technology) toolset.

### MOLT Fetch

Bulk data migration from PostgreSQL to CockroachDB:

```bash
# Install molt
curl -L https://binaries.cockroachdb.com/molt/molt-latest.linux-amd64.tgz | tar xz

# Fetch data from PostgreSQL to CockroachDB
molt fetch \
  --source "postgres://user:pass@pg-host:5432/mydb?sslmode=require" \
  --target "postgres://user:pass@crdb-host:26257/mydb?sslmode=require" \
  --table-filter "public.*" \
  --direct-copy \
  --concurrency 4
```

Options:
- `--direct-copy`: Stream directly from source to target (no intermediate files)
- `--concurrency`: Number of parallel table copies
- `--table-filter`: Regex to select tables
- `--flush-rows`: Batch size for inserts (default 10000)

### MOLT Verify

Validate data consistency after migration:

```bash
molt verify \
  --source "postgres://user:pass@pg-host:5432/mydb" \
  --target "postgres://user:pass@crdb-host:26257/mydb" \
  --table-filter "public.*" \
  --concurrency 4
```

Verify compares:
- Row counts
- Column values (sampling or full comparison)
- Schema structure

### MOLT LDR (Live Data Replication)

For zero-downtime migrations, use Live Data Replication to replicate changes
from PostgreSQL to CockroachDB during cutover:

```bash
# Start live replication from PostgreSQL
molt ldr \
  --source "postgres://user:pass@pg-host:5432/mydb?sslmode=require" \
  --target "postgres://user:pass@crdb-host:26257/mydb?sslmode=require" \
  --replication-slot "molt_replication" \
  --publication "molt_pub"
```

Prerequisites on PostgreSQL:
```sql
-- Set wal_level to logical
ALTER SYSTEM SET wal_level = logical;
-- Restart PostgreSQL

-- Create publication
CREATE PUBLICATION molt_pub FOR ALL TABLES;
```

## Data Import with IMPORT INTO

### CSV Import

```sql
-- Create table first
CREATE TABLE customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name STRING NOT NULL,
    email STRING NOT NULL
);

-- Import CSV from cloud storage
IMPORT INTO customers (name, email)
CSV DATA ('gs://my-bucket/customers.csv')
WITH delimiter = ',', skip = '1', nullif = '';

-- Import from multiple files
IMPORT INTO customers (name, email)
CSV DATA (
    'gs://my-bucket/customers_01.csv',
    'gs://my-bucket/customers_02.csv',
    'gs://my-bucket/customers_03.csv'
);

-- Import from HTTP endpoint
IMPORT INTO customers (name, email)
CSV DATA ('http://data-server/customers.csv');

-- Import from local node filesystem
IMPORT INTO customers (name, email)
CSV DATA ('nodelocal://1/customers.csv');
```

### PostgreSQL Dump Import

```bash
# Export from PostgreSQL
pg_dump --no-owner --no-privileges --format=plain mydb > mydb.sql

# Clean up the dump for CockroachDB compatibility
# Remove unsupported features: extensions, PLs, GRANTs, etc.
sed -i '/^CREATE EXTENSION/d' mydb.sql
sed -i '/^COMMENT ON EXTENSION/d' mydb.sql
sed -i '/^SET /d' mydb.sql
```

### Pgdump Import

```sql
-- Import a pg_dump file
IMPORT PGDUMP 'nodelocal://1/mydb.sql'
WITH ignore_unsupported_statements;

-- Import specific tables from a dump
IMPORT TABLE customers
FROM PGDUMP 'nodelocal://1/mydb.sql'
WITH ignore_unsupported_statements;
```

### COPY FROM

For smaller datasets, COPY is compatible:

```sql
-- From stdin (via cockroach sql or psql)
COPY customers (name, email) FROM STDIN;
Alice	alice@example.com
Bob	bob@example.com
\.

-- From CSV file (via psql)
\copy customers (name, email) FROM 'customers.csv' WITH CSV HEADER;
```

### Bulk Insert Strategies

```sql
-- Multi-row INSERT (100-500 rows per batch for best performance)
INSERT INTO customers (name, email) VALUES
    ('Alice', 'alice@example.com'),
    ('Bob', 'bob@example.com'),
    ('Charlie', 'charlie@example.com');

-- Use UPSERT for idempotent loads
UPSERT INTO customers (id, name, email) VALUES ($1, $2, $3);
```

## Application Code Changes

### Connection Strings

```
# PostgreSQL
postgresql://user:pass@localhost:5432/mydb?sslmode=disable

# CockroachDB (same format)
postgresql://user:pass@localhost:26257/mydb?sslmode=verify-full

# CockroachDB Cloud
postgresql://user:pass@free-tier.gcp-us-central1.cockroachlabs.cloud:26257/mydb?sslmode=verify-full&sslrootcert=/path/to/ca.crt
```

### Transaction Retry Logic

**This is the most important application change.** CockroachDB's serializable
isolation requires client-side retry logic for `40001` errors.

```python
# Python with psycopg2
import psycopg2
import time
import random

def run_transaction(conn, fn, max_retries=10):
    """Execute fn(conn) with automatic retry on serialization failure."""
    for attempt in range(max_retries):
        try:
            result = fn(conn)
            conn.commit()
            return result
        except psycopg2.errors.SerializationFailure:
            conn.rollback()
            sleep_time = (2 ** attempt) * 0.01 * (1 + random.random())
            time.sleep(min(sleep_time, 5.0))
    raise Exception(f"Transaction failed after {max_retries} retries")
```

```go
// Go with pgx
func runTransaction(ctx context.Context, db *pgxpool.Pool, fn func(pgx.Tx) error) error {
    for attempt := 0; attempt < 10; attempt++ {
        tx, err := db.Begin(ctx)
        if err != nil {
            return err
        }
        err = fn(tx)
        if err != nil {
            tx.Rollback(ctx)
            if pgErr, ok := err.(*pgconn.PgError); ok && pgErr.Code == "40001" {
                time.Sleep(time.Duration(math.Pow(2, float64(attempt))) * 10 * time.Millisecond)
                continue
            }
            return err
        }
        return tx.Commit(ctx)
    }
    return fmt.Errorf("transaction failed after max retries")
}
```

### Query Compatibility Adjustments

```sql
-- PostgreSQL: ILIKE for case-insensitive search
SELECT * FROM users WHERE name ILIKE '%alice%';
-- CockroachDB: Works, but consider using LOWER() for index usage
SELECT * FROM users WHERE lower(name) LIKE '%alice%';

-- PostgreSQL: DISTINCT ON
SELECT DISTINCT ON (customer_id) * FROM orders ORDER BY customer_id, created_at DESC;
-- CockroachDB: Supported (v22.2+)

-- PostgreSQL: TABLESAMPLE
SELECT * FROM large_table TABLESAMPLE BERNOULLI(10);
-- CockroachDB: Not supported — sample in application

-- PostgreSQL: generate_series with timestamp
SELECT generate_series('2024-01-01', '2024-12-31', '1 month'::INTERVAL);
-- CockroachDB: Supported

-- PostgreSQL: UPDATE ... RETURNING
UPDATE orders SET status = 'shipped' WHERE id = $1 RETURNING *;
-- CockroachDB: Supported
```

### Error Handling Differences

```python
# PostgreSQL-only errors you won't see in CockroachDB
# - DeadlockDetected (40P01) → CockroachDB uses 40001 (serialization failure)
# - LockNotAvailable → CockroachDB queues lock waiters

# New CockroachDB-specific error handling
try:
    cursor.execute(query)
except psycopg2.errors.SerializationFailure:
    # MUST retry — this is expected behavior
    pass
except psycopg2.errors.ReadCommittedModeNotSupported:
    # If you set isolation level incorrectly
    pass
```

## ORM Compatibility

### ActiveRecord (Ruby/Rails)

```ruby
# Gemfile
gem 'activerecord-cockroachdb-adapter'

# config/database.yml
production:
  adapter: cockroachdb
  host: localhost
  port: 26257
  database: myapp_production
  username: root
  sslmode: verify-full
  sslrootcert: /path/to/ca.crt

# Migration changes: Use UUID primary keys
class CreateUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :users, id: :uuid do |t|
      t.string :email, null: false
      t.string :name
      t.timestamps
    end
    add_index :users, :email, unique: true
  end
end

# Configure retry logic in application.rb
config.active_record.retry_on_serialization_failure = true
```

### SQLAlchemy (Python)

```python
# pip install sqlalchemy-cockroachdb

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

# Use cockroachdb:// scheme
engine = create_engine(
    "cockroachdb://root@localhost:26257/mydb?sslmode=disable",
    pool_size=20,
    max_overflow=10,
)

Session = sessionmaker(bind=engine)

# Use UUID PKs in models
import uuid
from sqlalchemy import Column, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import DeclarativeBase

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = 'users'
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email = Column(String, unique=True, nullable=False)
    name = Column(String)

# Transaction retry decorator
from sqlalchemy.exc import OperationalError
import time

def retry_transaction(session, fn, max_retries=10):
    for attempt in range(max_retries):
        try:
            result = fn(session)
            session.commit()
            return result
        except OperationalError as e:
            session.rollback()
            if "40001" in str(e.orig):
                time.sleep(min(0.01 * (2 ** attempt), 5.0))
                continue
            raise
    raise Exception("Max retries exceeded")
```

### GORM (Go)

```go
// go get gorm.io/driver/postgres

import (
    "gorm.io/driver/postgres"
    "gorm.io/gorm"
)

dsn := "host=localhost port=26257 user=root dbname=mydb sslmode=disable"
db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})

// Use UUID PKs
type User struct {
    ID    uuid.UUID `gorm:"type:uuid;primaryKey;default:gen_random_uuid()"`
    Email string    `gorm:"uniqueIndex;not null"`
    Name  string
}

// Auto-migrate (creates tables)
db.AutoMigrate(&User{})

// Transaction with retry
func WithRetry(db *gorm.DB, fn func(tx *gorm.DB) error) error {
    for i := 0; i < 10; i++ {
        err := db.Transaction(fn)
        if err == nil {
            return nil
        }
        if strings.Contains(err.Error(), "40001") {
            time.Sleep(time.Duration(math.Pow(2, float64(i))) * 10 * time.Millisecond)
            continue
        }
        return err
    }
    return fmt.Errorf("transaction failed after retries")
}
```

### Prisma (Node.js/TypeScript)

```prisma
// schema.prisma
datasource db {
  provider = "cockroachdb"
  url      = env("DATABASE_URL")
}

generator client {
  provider = "prisma-client-js"
}

model User {
  id    String @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  email String @unique
  name  String?
  orders Order[]
}

model Order {
  id     String  @id @default(dbgenerated("gen_random_uuid()")) @db.Uuid
  userId String  @db.Uuid
  total  Decimal @db.Decimal(10, 2)
  user   User    @relation(fields: [userId], references: [id])
}
```

```typescript
// Retry middleware for Prisma
import { Prisma, PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

async function withRetry<T>(fn: () => Promise<T>, maxRetries = 10): Promise<T> {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error) {
      if (
        error instanceof Prisma.PrismaClientKnownRequestError &&
        error.code === 'P2034' // Transaction conflict
      ) {
        await new Promise(r => setTimeout(r, Math.min(10 * 2 ** attempt, 5000)));
        continue;
      }
      throw error;
    }
  }
  throw new Error('Transaction failed after max retries');
}

// Usage
await withRetry(() =>
  prisma.$transaction([
    prisma.account.update({ where: { id: src }, data: { balance: { decrement: 100 } } }),
    prisma.account.update({ where: { id: dst }, data: { balance: { increment: 100 } } }),
  ])
);
```

### Django ORM (Python)

```python
# pip install django-cockroachdb

# settings.py
DATABASES = {
    'default': {
        'ENGINE': 'django_cockroachdb',
        'NAME': 'mydb',
        'USER': 'root',
        'HOST': 'localhost',
        'PORT': '26257',
        'OPTIONS': {
            'sslmode': 'verify-full',
            'sslrootcert': '/path/to/ca.crt',
        },
    }
}

# models.py — Use UUIDField for PKs
import uuid
from django.db import models

class User(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    email = models.EmailField(unique=True)
    name = models.CharField(max_length=255)
```

### Hibernate (Java)

```java
// application.properties
spring.datasource.url=jdbc:postgresql://localhost:26257/mydb?sslmode=disable
spring.datasource.driver-class-name=org.postgresql.Driver
spring.jpa.database-platform=org.hibernate.dialect.CockroachDialect

// Entity with UUID
@Entity
@Table(name = "users")
public class User {
    @Id
    @GeneratedValue(strategy = GenerationType.AUTO)
    @Column(columnDefinition = "UUID DEFAULT gen_random_uuid()")
    private UUID id;

    @Column(unique = true, nullable = false)
    private String email;

    private String name;
}

// Retry interceptor
@Aspect
@Component
public class RetryOnSerializationFailure {
    @Around("@annotation(Retryable)")
    public Object retry(ProceedingJoinPoint joinPoint) throws Throwable {
        int maxRetries = 10;
        for (int i = 0; i < maxRetries; i++) {
            try {
                return joinPoint.proceed();
            } catch (Exception e) {
                if (e.getMessage() != null && e.getMessage().contains("40001") && i < maxRetries - 1) {
                    Thread.sleep((long) Math.min(Math.pow(2, i) * 10, 5000));
                    continue;
                }
                throw e;
            }
        }
        throw new RuntimeException("Max retries exceeded");
    }
}
```

## Migration Checklist

### Pre-Migration

- [ ] Audit PostgreSQL features in use (extensions, stored procs, triggers)
- [ ] Identify incompatible features and plan alternatives
- [ ] Convert schema: UUID PKs, remove unsupported types/constraints
- [ ] Set up CockroachDB cluster with appropriate topology
- [ ] Add transaction retry logic to application code
- [ ] Configure ORM for CockroachDB dialect
- [ ] Test with representative workload in staging

### During Migration

- [ ] Export schema from PostgreSQL (pg_dump --schema-only)
- [ ] Convert and apply schema to CockroachDB
- [ ] Run MOLT Fetch or IMPORT to load data
- [ ] Verify data with MOLT Verify
- [ ] Run application test suite against CockroachDB
- [ ] Performance test with production-like load
- [ ] Set up monitoring (DB Console, Prometheus)

### Post-Migration

- [ ] Monitor transaction retry rates
- [ ] Check for full table scans (SHOW FULL TABLE SCANS)
- [ ] Verify index usage (crdb_internal.index_usage_statistics)
- [ ] Tune query performance with EXPLAIN ANALYZE
- [ ] Set up backup schedules
- [ ] Configure alerting for cluster health
- [ ] Document operational runbooks

## Rollback Strategy

Always maintain a rollback plan during migration:

1. **Keep PostgreSQL running** during cutover period
2. **Use changefeeds** to replicate CockroachDB changes back to PostgreSQL
3. **Application feature flags** to switch between database backends
4. **DNS-based switching** — update connection endpoints to roll back
5. **Test rollback procedure** before production migration

```
Migration Timeline:
Day 1-7:    Schema conversion + testing
Day 8-14:   Data migration + verification
Day 15-21:  Application testing on CockroachDB
Day 22:     Cutover (during maintenance window)
Day 22-29:  Monitoring period (keep PG as fallback)
Day 30:     Decommission PostgreSQL
```
