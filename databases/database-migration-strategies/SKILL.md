---
name: database-migration-strategies
description:
  positive: "Use when user manages database schema migrations, asks about Flyway, Alembic, Prisma Migrate, golang-migrate, Liquibase, zero-downtime migrations, expand-contract pattern, or backward-compatible schema changes."
  negative: "Do NOT use for database performance tuning (use postgres-performance-tuning skill), data migration/ETL pipelines, or database backup/restore."
---

# Database Migration Strategies

## Migration Tool Comparison

| Tool | Ecosystem | Format | Rollback | Strengths |
|------|-----------|--------|----------|-----------|
| **Flyway** | Java/JVM, CLI | SQL, Java | Paid only (undo) | Simple, linear versioning, Maven/Gradle integration |
| **Liquibase** | Java, CLI | SQL, XML, YAML, JSON | Yes (built-in) | 50+ DB support, changelog tracking, enterprise audit |
| **Alembic** | Python/SQLAlchemy | Python scripts | Yes (downgrade) | Autogenerate from models, branching support |
| **Prisma Migrate** | Node.js/TypeScript | Prisma schema DSL | Yes | Type-safe, declarative, auto-generated SQL |
| **golang-migrate** | Go, CLI | SQL, Go | Yes | Lightweight, no dependencies, embeddable |
| **Knex** | Node.js | JavaScript/TypeScript | Yes (down) | Query builder integration, simple API |

### When to pick what

- **JVM shop, simple needs** → Flyway.
- **Enterprise, multi-DB, compliance** → Liquibase.
- **Python + SQLAlchemy** → Alembic.
- **TypeScript full-stack** → Prisma Migrate.
- **Go services** → golang-migrate.
- **Node.js without Prisma** → Knex.

## Migration File Conventions

### Naming schemes

```
# Flyway — sequential version prefix
V1__create_users_table.sql
V2__add_email_to_users.sql

# Alembic — revision hash with description
abc123_create_users_table.py

# golang-migrate — timestamp with direction
20250115120000_create_users.up.sql
20250115120000_create_users.down.sql

# Prisma Migrate — timestamp directory
migrations/20250115120000_create_users/migration.sql

# Knex — timestamp prefix
20250115120000_create_users.js
```

### Rules

- Use timestamps over sequential integers to avoid merge conflicts.
- Always create up/down pairs. If a migration is irreversible, make the down script raise an error explicitly.
- One logical change per migration file. Never bundle unrelated changes.
- Keep migration files immutable once applied to any shared environment.

### Up/down pair example (golang-migrate)

```sql
-- 20250115120000_add_email.up.sql
ALTER TABLE users ADD COLUMN email VARCHAR(255);
CREATE INDEX CONCURRENTLY idx_users_email ON users (email);

-- 20250115120000_add_email.down.sql
DROP INDEX IF EXISTS idx_users_email;
ALTER TABLE users DROP COLUMN IF EXISTS email;
```

## Zero-Downtime Migration Patterns

### Expand-Contract Pattern

Safest approach for live systems. Three phases:

**1. Expand** — Add new structure alongside old:
```sql
ALTER TABLE users ADD COLUMN display_name TEXT;
```

**2. Migrate** — Backfill data and dual-write:
```sql
-- Backfill in batches
UPDATE users SET display_name = name
WHERE display_name IS NULL
AND id BETWEEN $start AND $end;
```

Application dual-writes during transition:
```python
def update_user(user_id, name):
    db.execute(
        "UPDATE users SET name = %s, display_name = %s WHERE id = %s",
        (name, name, user_id)
    )
```

**3. Contract** — Remove old structure after full cutover:
```sql
ALTER TABLE users DROP COLUMN name;
ALTER TABLE users ALTER COLUMN display_name SET NOT NULL;
```

### Dual-Write Pattern

Use when migrating between tables or databases:
1. Write to both old and new locations.
2. Backfill historical data to new location.
3. Switch reads to new location.
4. Stop writes to old location.
5. Drop old structure.

### Blue-Green Database Deployment

Run two database environments. Apply migrations to green, validate, then switch traffic:

1. Replicate blue → green.
2. Apply migrations to green.
3. Run validation suite against green.
4. Switch application traffic to green.
5. Green becomes the new blue.

Use logical replication or CDC (Debezium) to keep environments in sync during transition.

## Backward-Compatible Changes

### Safe operations (no downtime)

| Operation | Safe approach |
|-----------|--------------|
| Add column | `ADD COLUMN` with `NULL` default or server-side default |
| Add index | `CREATE INDEX CONCURRENTLY` (PostgreSQL) |
| Add table | Always safe |
| Add constraint | Use `NOT VALID` then `VALIDATE` separately |

### Rename column safely

Never use `ALTER TABLE RENAME COLUMN` on a live system. Use expand-contract:

```sql
-- Migration 1: expand
ALTER TABLE orders ADD COLUMN total_cents BIGINT;

-- Migration 2: backfill (run in batches)
UPDATE orders SET total_cents = total_price * 100
WHERE total_cents IS NULL AND id BETWEEN $1 AND $2;

-- Migration 3: contract (after app fully switched)
ALTER TABLE orders DROP COLUMN total_price;
```

### Drop column safely

1. Remove all application references to the column.
2. Deploy application change.
3. Wait for all old application instances to drain.
4. Drop the column in a subsequent migration.

```sql
-- Only after app no longer references the column
ALTER TABLE users DROP COLUMN IF EXISTS legacy_field;
```

## Dangerous Operations and Safe Alternatives

### Column type change

**Dangerous:**
```sql
-- Rewrites entire table, locks it
ALTER TABLE events ALTER COLUMN payload TYPE JSONB;
```

**Safe alternative:**
```sql
-- 1. Add new column
ALTER TABLE events ADD COLUMN payload_jsonb JSONB;
-- 2. Backfill in batches
UPDATE events SET payload_jsonb = payload::jsonb
WHERE payload_jsonb IS NULL AND id BETWEEN $1 AND $2;
-- 3. Swap in app, then drop old column
```

### Adding NOT NULL constraint

**Dangerous:**
```sql
-- Scans entire table while holding lock
ALTER TABLE users ALTER COLUMN email SET NOT NULL;
```

**Safe alternative (PostgreSQL):**
```sql
-- Add constraint without full scan
ALTER TABLE users ADD CONSTRAINT users_email_not_null
  CHECK (email IS NOT NULL) NOT VALID;
-- Validate in background without blocking writes
ALTER TABLE users VALIDATE CONSTRAINT users_email_not_null;
```

### Adding a default value

**PostgreSQL 11+** — `ADD COLUMN ... DEFAULT` is safe (metadata-only).

**Older PostgreSQL / MySQL:**
```sql
-- Add nullable column first
ALTER TABLE orders ADD COLUMN status TEXT;
-- Set default for new rows via app or trigger
-- Backfill existing rows in batches
```

### Locking index creation

**Dangerous:**
```sql
CREATE INDEX idx_orders_user ON orders (user_id); -- locks table
```

**Safe:**
```sql
CREATE INDEX CONCURRENTLY idx_orders_user ON orders (user_id);
```

Note: `CONCURRENTLY` cannot run inside a transaction block.

## Large Table Migrations

### Batched updates

Never update millions of rows in one statement:

```sql
-- Process 10,000 rows at a time
DO $$
DECLARE
  batch_size INT := 10000;
  max_id BIGINT;
  current_id BIGINT := 0;
BEGIN
  SELECT MAX(id) INTO max_id FROM events;
  WHILE current_id < max_id LOOP
    UPDATE events
    SET new_col = compute_value(old_col)
    WHERE id > current_id AND id <= current_id + batch_size
      AND new_col IS NULL;
    current_id := current_id + batch_size;
    COMMIT;
  END LOOP;
END $$;
```

### MySQL: pt-online-schema-change

```bash
pt-online-schema-change \
  --alter "ADD COLUMN email VARCHAR(255)" \
  --execute \
  --chunk-size=1000 \
  --max-lag=1s \
  D=mydb,t=users
```

Creates shadow table, copies data in chunks, swaps atomically.

### MySQL: gh-ost

```bash
gh-ost \
  --alter="ADD COLUMN email VARCHAR(255)" \
  --database=mydb \
  --table=users \
  --execute \
  --chunk-size=1000 \
  --max-lag-millis=1500
```

Uses binlog streaming instead of triggers. Preferred over pt-osc for high-traffic tables.

### PostgreSQL: pg_repack

```bash
# Reclaim bloat and rebuild table without locks
pg_repack --table users --jobs 4 mydb
```

## Data Migrations vs Schema Migrations

Keep them separate. Never mix DDL and large DML in the same migration.

| Aspect | Schema migration | Data migration |
|--------|-----------------|----------------|
| Content | DDL (CREATE, ALTER, DROP) | DML (INSERT, UPDATE, DELETE) |
| Speed | Fast (metadata changes) | Slow (row-by-row processing) |
| Reversibility | Usually reversible | Often irreversible |
| Timing | Run at deploy time | Run as background job |
| Transaction | Single transaction OK | Batch with commits |

### Pattern: separate migration files

```
V3__add_display_name_column.sql     -- schema: fast, in deploy
V4__backfill_display_name.sql       -- data: slow, run async
V5__set_display_name_not_null.sql   -- schema: after backfill completes
```

For large data migrations, use an application-level script or job runner instead of the migration tool:

```python
# run_backfill.py — executed separately from deploy
import time

BATCH = 5000
while True:
    updated = db.execute("""
        UPDATE users SET display_name = name
        WHERE display_name IS NULL
        LIMIT %s
    """, (BATCH,))
    if updated == 0:
        break
    time.sleep(0.1)  # throttle to avoid replica lag
```

## Environment Management

### Dev / Staging / Prod

- **Dev**: Recreate from scratch frequently. Use `migrate reset` or equivalent.
- **Staging**: Mirror prod schema. Apply migrations before prod to catch issues.
- **Prod**: Apply migrations through CI/CD only. Never run migrations manually.

### Seeding

Separate seed data from migrations:

```
migrations/          -- schema changes, tracked by tool
seeds/               -- test/dev data, NOT run in production
  dev_users.sql
  sample_orders.sql
```

### Baselining an existing database

When adopting a migration tool on an existing database:

```bash
# Flyway
flyway baseline -baselineVersion=1

# Alembic
alembic stamp head

# golang-migrate
migrate force 1
```

Create a baseline migration capturing current schema, mark it as applied, then track future changes normally.

### Configuration example (Flyway)

```properties
# flyway.conf
flyway.url=jdbc:postgresql://localhost:5432/myapp
flyway.schemas=public
flyway.locations=filesystem:./migrations
flyway.baselineOnMigrate=true
flyway.outOfOrder=false
flyway.validateMigrationNaming=true
```

## Rollback Strategies

### Reversible migrations

Write explicit down migrations for every up migration:

```sql
-- up
CREATE TABLE audit_log (
  id BIGSERIAL PRIMARY KEY,
  entity TEXT NOT NULL,
  action TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- down
DROP TABLE IF EXISTS audit_log;
```

### Forward-fix

When rollback is impractical (data already transformed), fix forward:

1. Deploy a new migration that corrects the issue.
2. Never roll back destructive changes (dropped columns, truncated data).
3. Prefer forward-fix over rollback in production for data-altering migrations.

### Snapshots

Before risky migrations:
```bash
# PostgreSQL
pg_dump --format=custom mydb > pre_migration_backup.dump

# MySQL
mysqldump --single-transaction mydb > pre_migration_backup.sql
```

Automate snapshot creation in CI/CD before the migration step.

### Decision matrix

| Scenario | Strategy |
|----------|----------|
| Schema-only, no data loss | Reverse migration (down script) |
| Data transformation applied | Forward-fix with corrective migration |
| Major structural change | Restore from snapshot |
| Multi-step expand-contract | Halt at current phase, fix, continue |
## CI/CD Integration

### Migration in deployment pipeline

```yaml
# GitHub Actions example
deploy:
  steps:
    - name: Run migration dry-run
      run: flyway validate -url=$DB_URL
    
    - name: Apply migrations
      run: flyway migrate -url=$DB_URL
    
    - name: Verify migration
      run: |
        CURRENT=$(flyway info -url=$DB_URL | grep 'Current' | awk '{print $NF}')
        EXPECTED="5"
        [ "$CURRENT" = "$EXPECTED" ] || exit 1
    
    - name: Deploy application
      run: kubectl rollout restart deployment/myapp
```

### Key principles

- Run migrations **before** deploying new application code.
- Use `validate` or `dry-run` to catch errors before apply.
- Gate deployments on migration success.
- Store migration files in the same repo as application code.
- Use separate DB credentials for migrations (DDL privileges) vs application (DML only).

### Verification queries

After migration, verify schema state:

```sql
-- PostgreSQL: check column exists
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'users' AND column_name = 'display_name';

-- Check migration version
SELECT * FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1;
-- or
SELECT * FROM alembic_version;
```

## Common Anti-Patterns

### 1. Irreversible migration without backup
Write a down migration or take a snapshot before every destructive change. Never drop a column or table without a recovery plan.

### 2. Mixing schema and data migrations
Separate DDL and large DML. A migration that adds a column AND backfills millions of rows will block deploys and time out.

### 3. Manual DDL in production
All schema changes go through migration files. Manual `ALTER TABLE` in production breaks version tracking and causes drift.

### 4. Editing applied migrations
Never modify a migration file after it has been applied to any environment. Create a new migration instead.

### 5. Running migrations during traffic peak
Schedule migrations during low-traffic windows. Even "safe" operations can cause replication lag under load.

### 6. Missing index for new foreign key
Add an index when adding a foreign key column:

```sql
ALTER TABLE orders ADD COLUMN customer_id BIGINT REFERENCES customers(id);
CREATE INDEX CONCURRENTLY idx_orders_customer_id ON orders (customer_id);
```

### 7. Ignoring migration order across services
In microservices, coordinate migration order. Consumers must handle both old and new schemas during rollout.

### 8. Skipping staging validation
Apply migrations to staging with production-like data before production.
