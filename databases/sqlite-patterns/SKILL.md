---
name: sqlite-patterns
description: >
  Expert guidance for SQLite, sqlite3, and embedded single-file database development.
  Covers WAL mode, PRAGMA tuning, STRICT tables, JSON/JSONB, FTS5 full-text search,
  window functions, CTEs, generated columns, concurrent access, connection pooling,
  backup strategies, extensions (spatialite, sqlite-vec, sqlean), schema migrations,
  and language bindings (Python, Node.js, Go, Rust). TRIGGER when: code uses sqlite3,
  better-sqlite3, rusqlite, go-sqlite3, SQLAlchemy with SQLite, or user asks about
  embedded database, single-file database, WAL mode, PRAGMA settings, SQLite performance,
  SQLite JSON, FTS5, or SQLite vs PostgreSQL. DO NOT trigger for: PostgreSQL-only features
  (LISTEN/NOTIFY, logical replication), MySQL/MariaDB, MongoDB, Redis, or general SQL
  unrelated to SQLite.
---

# SQLite Patterns

SQLite (current stable: 3.46+) is a self-contained, serverless, zero-configuration
embedded SQL database engine. The entire database is a single cross-platform file.

## When to Use SQLite

Use SQLite for: embedded/edge/mobile apps, CLI tools, local caches, test databases,
single-server web apps under ~100K requests/day, data analysis pipelines, IoT devices,
desktop applications, prototyping. Do NOT use SQLite for: high-write-concurrency
multi-server deployments, apps requiring row-level locking, or client-server architectures
with many concurrent writers.

## Production PRAGMA Settings

Apply these at every connection open, before any queries:

```sql
PRAGMA journal_mode = WAL;          -- write-ahead logging, concurrent reads
PRAGMA synchronous = NORMAL;        -- safe with WAL, 2x faster than FULL
PRAGMA foreign_keys = ON;           -- enforce FK constraints (off by default!)
PRAGMA busy_timeout = 5000;         -- wait 5s on lock instead of failing immediately
PRAGMA cache_size = -64000;         -- 64MB page cache (negative = KiB)
PRAGMA mmap_size = 268435456;       -- 256MB memory-mapped I/O
PRAGMA temp_store = MEMORY;         -- store temp tables in memory
PRAGMA auto_vacuum = INCREMENTAL;   -- reclaim space without full vacuum
```

## WAL Mode and Journal Modes

**WAL (Write-Ahead Logging)** is the recommended journal mode. It enables concurrent
readers during writes and significantly improves read performance.

| Mode     | Behavior                                          |
|----------|---------------------------------------------------|
| DELETE   | Default. Rollback journal deleted after commit.   |
| WAL      | Append-only log. Readers don't block writers.     |
| WAL2     | Experimental. Two WAL files for higher concurrency. Not production-ready. |
| TRUNCATE | Truncate journal file instead of deleting.        |
| MEMORY   | Journal in memory. Fast but not crash-safe.       |
| OFF      | No journal. No rollback. Never use in production. |

WAL caveats: only one writer at a time. WAL file can grow large under sustained writes—
run `PRAGMA wal_checkpoint(TRUNCATE)` periodically. WAL does not work over network
filesystems (NFS, SMB). Set WAL mode once; it persists in the database file.

## STRICT Tables and Type Affinity

Standard SQLite uses type affinity (any value in any column). STRICT tables enforce types:

```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL,
    age INTEGER,
    balance REAL,
    avatar BLOB,
    metadata ANY               -- opt out of strict typing for this column
) STRICT;
```

Supported STRICT types: `INTEGER`, `REAL`, `TEXT`, `BLOB`, `ANY`.
Inserting wrong type into a STRICT column raises an error instead of silently coercing.
Use STRICT for all new tables. Combine with `WITHOUT ROWID` for clustered primary keys
on non-integer PKs.

## JSON and JSONB Support

SQLite has built-in JSON since 3.38. JSONB (binary JSON, since 3.45) stores as BLOB
for ~3x faster parsing and ~10% smaller storage.

```sql
-- Extract values
SELECT json_extract(data, '$.name') FROM events;
SELECT data->>'$.name' FROM events;           -- ->> returns SQL text
SELECT data->'$.tags' FROM events;            -- -> returns JSON

-- Query arrays
SELECT e.id, j.value
FROM events e, json_each(e.data, '$.tags') j
WHERE j.value = 'urgent';

-- Build JSON
SELECT json_object('id', id, 'name', name) FROM users;
SELECT json_group_array(json_object('id', id)) FROM users;

-- JSONB storage (use jsonb() to store, automatic for reads)
INSERT INTO events (data) VALUES (jsonb('{"type":"click","x":100}'));

-- Index JSON fields via generated columns
ALTER TABLE events ADD COLUMN event_type TEXT
    GENERATED ALWAYS AS (data->>'$.type') STORED;
CREATE INDEX idx_event_type ON events(event_type);
```

## Full-Text Search (FTS5)

Use FTS5 for text search. Never use `LIKE '%term%'` on large datasets.

```sql
-- Create FTS5 virtual table
CREATE VIRTUAL TABLE docs_fts USING fts5(title, body, content=docs, content_rowid=id);

-- Keep in sync with triggers
CREATE TRIGGER docs_ai AFTER INSERT ON docs BEGIN
    INSERT INTO docs_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
CREATE TRIGGER docs_ad AFTER DELETE ON docs BEGIN
    INSERT INTO docs_fts(docs_fts, rowid, title, body)
        VALUES ('delete', old.id, old.title, old.body);
END;
CREATE TRIGGER docs_au AFTER UPDATE ON docs BEGIN
    INSERT INTO docs_fts(docs_fts, rowid, title, body)
        VALUES ('delete', old.id, old.title, old.body);
    INSERT INTO docs_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;

-- Search with ranking
SELECT d.*, bm25(docs_fts) AS rank
FROM docs_fts f
JOIN docs d ON d.id = f.rowid
WHERE docs_fts MATCH 'sqlite AND performance'
ORDER BY rank;

-- Highlight matches
SELECT highlight(docs_fts, 1, '<b>', '</b>') FROM docs_fts WHERE docs_fts MATCH 'query';

-- Optimize periodically
INSERT INTO docs_fts(docs_fts) VALUES ('optimize');
```

## Window Functions

```sql
-- Running total
SELECT date, amount,
    SUM(amount) OVER (ORDER BY date) AS running_total
FROM transactions;

-- Rank within groups
SELECT department, name, salary,
    RANK() OVER (PARTITION BY department ORDER BY salary DESC) AS dept_rank
FROM employees;

-- Moving average
SELECT date, value,
    AVG(value) OVER (ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS ma_7d
FROM metrics;

-- Lead/lag
SELECT date, value,
    value - LAG(value) OVER (ORDER BY date) AS daily_change
FROM metrics;
```

## Common Table Expressions (CTEs)

```sql
-- Recursive CTE: tree traversal
WITH RECURSIVE tree AS (
    SELECT id, name, parent_id, 0 AS depth
    FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.name, c.parent_id, t.depth + 1
    FROM categories c JOIN tree t ON c.parent_id = t.id
)
SELECT * FROM tree ORDER BY depth, name;

-- Non-recursive CTE: readability
WITH active_users AS (
    SELECT * FROM users WHERE last_login > date('now', '-30 days')
),
user_orders AS (
    SELECT user_id, COUNT(*) AS order_count FROM orders GROUP BY user_id
)
SELECT a.name, COALESCE(o.order_count, 0) AS orders
FROM active_users a
LEFT JOIN user_orders o ON a.id = o.user_id;
```

## Generated Columns

```sql
CREATE TABLE products (
    id INTEGER PRIMARY KEY,
    price_cents INTEGER NOT NULL,
    quantity INTEGER NOT NULL,
    -- Virtual: computed on read, not stored
    price_dollars REAL GENERATED ALWAYS AS (price_cents / 100.0) VIRTUAL,
    -- Stored: computed on write, indexable
    total_cents INTEGER GENERATED ALWAYS AS (price_cents * quantity) STORED
);

CREATE INDEX idx_total ON products(total_cents);
```

Use STORED generated columns for indexing. Use VIRTUAL for display-only computed values.

## Concurrent Access and Locking

SQLite uses file-level locking with five lock states: UNLOCKED → SHARED → RESERVED →
PENDING → EXCLUSIVE. In WAL mode, readers never block writers and writers never block
readers. Only one writer at a time.

**Rules for concurrent access:**
- Always set `busy_timeout` (never rely on immediate `SQLITE_BUSY` errors)
- Keep write transactions short—seconds, not minutes
- Use `BEGIN IMMEDIATE` for write transactions to acquire lock early and fail fast
- Never hold a transaction open while waiting for user input
- Read-only queries don't need explicit transactions in WAL mode

```sql
BEGIN IMMEDIATE;  -- acquire write lock immediately, fail fast if busy
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
COMMIT;
```

## Connection Pooling

SQLite does not need traditional connection pooling like client-server databases.
Recommended patterns:

- **Single writer, multiple readers:** One long-lived write connection + pool of read
  connections (all in WAL mode). This is the optimal pattern.
- **Per-request connections:** Acceptable for low-traffic apps. Open/close is cheap (~μs).
- **Thread safety:** Use `SQLITE_OPEN_FULLMUTEX` or serialize access to a single connection.
  In WAL mode, separate connections can read concurrently.

```python
# Python: single writer + read pool
import sqlite3, threading

writer_lock = threading.Lock()
def get_read_conn():
    conn = sqlite3.connect('app.db', check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA query_only=ON")
    return conn

def write(sql, params):
    with writer_lock:
        conn = sqlite3.connect('app.db')
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute(sql, params)
        conn.commit()
        conn.close()
```

## Backup Strategies

```sql
-- Online backup via SQL (safe during concurrent access)
VACUUM INTO '/backups/app_backup.db';

-- sqlite3 CLI
-- .backup main /backups/app_backup.db
```

```python
# Python: sqlite3_backup API (incremental, non-blocking)
import sqlite3
src = sqlite3.connect('app.db')
dst = sqlite3.connect('/backups/app_backup.db')
with dst:
    src.backup(dst, pages=100, sleep=0.1)  # 100 pages at a time
dst.close()
src.close()
```

**Backup rules:** Never copy the database file while it's open (WAL files won't be
included). Always use `VACUUM INTO`, the backup API, or `.backup`. For point-in-time
recovery, use Litestream for continuous WAL shipping to S3.

## Extensions

| Extension    | Purpose                          | Install                         |
|--------------|----------------------------------|---------------------------------|
| spatialite   | Geospatial queries (PostGIS-like)| `.load mod_spatialite`          |
| sqlite-vec   | Vector similarity search (KNN)   | `.load vec0`                    |
| sqlean       | Math, stats, regex, crypto, uuid | `.load sqlean` or individual    |
| FTS5         | Full-text search                 | Built-in (compile flag)         |
| R-Tree       | Spatial indexing                 | Built-in (compile flag)         |

```sql
-- sqlite-vec: vector search
CREATE VIRTUAL TABLE vec_items USING vec0(embedding FLOAT[384]);
SELECT rowid, distance FROM vec_items
WHERE embedding MATCH ?
ORDER BY distance LIMIT 10;

-- sqlean: UUID generation
SELECT uuid4();  -- random UUID
SELECT uuid7();  -- time-sortable UUID
```

## Language Bindings Best Practices

### Python (sqlite3 / apsw)
```python
import sqlite3
conn = sqlite3.connect('app.db')
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA foreign_keys=ON")
conn.row_factory = sqlite3.Row      # dict-like access
# Always use parameterized queries
conn.execute("SELECT * FROM users WHERE id = ?", (user_id,))
# Use context manager for auto-commit/rollback
with conn:
    conn.execute("INSERT INTO users (name) VALUES (?)", (name,))
```

### Node.js (better-sqlite3)
```javascript
const Database = require('better-sqlite3');
const db = new Database('app.db', { wal: true });
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');
db.pragma('busy_timeout = 5000');
// Synchronous API — better-sqlite3 is sync by design
const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
// Transactions
const transfer = db.transaction((from, to, amount) => {
    db.prepare('UPDATE accounts SET bal = bal - ? WHERE id = ?').run(amount, from);
    db.prepare('UPDATE accounts SET bal = bal + ? WHERE id = ?').run(amount, to);
});
transfer(1, 2, 100);
```

### Go (modernc.org/sqlite or mattn/go-sqlite3)
```go
import "database/sql"
import _ "modernc.org/sqlite"  // pure Go, no CGO
db, _ := sql.Open("sqlite", "file:app.db?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=ON")
db.SetMaxOpenConns(1)  // single writer
```

### Rust (rusqlite)
```rust
use rusqlite::Connection;
let conn = Connection::open("app.db")?;
conn.execute_batch("
    PRAGMA journal_mode=WAL;
    PRAGMA foreign_keys=ON;
    PRAGMA busy_timeout=5000;
")?;
```

## Schema Migrations

Use a version table and sequential numbered scripts:

```sql
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY);

-- Check current version
SELECT COALESCE(MAX(version), 0) FROM schema_version;

-- Apply migration (wrap in transaction)
BEGIN;
ALTER TABLE users ADD COLUMN avatar_url TEXT;
INSERT INTO schema_version (version) VALUES (2);
COMMIT;
```

**Migration rules:**
- Always wrap migrations in transactions (DDL is transactional in SQLite)
- SQLite `ALTER TABLE` only supports: `RENAME TABLE`, `RENAME COLUMN`, `ADD COLUMN`,
  `DROP COLUMN` (3.35+). For other changes, use the 12-step recreate pattern:
  create new table → copy data → drop old → rename new.
- Never use `ALTER TABLE` to change column types—recreate the table instead
- Test migrations against a copy of production data

## SQLite vs PostgreSQL Decision Guide

| Factor                    | Choose SQLite              | Choose PostgreSQL           |
|---------------------------|----------------------------|-----------------------------|
| Deployment                | Embedded / single server   | Multi-server / cloud        |
| Concurrent writers        | ≤1 (serialized)            | Many (MVCC)                 |
| Data size                 | < 1 TB typical             | Any size                    |
| Write throughput          | ~50K INSERT/s (batched)    | Higher sustained writes     |
| Replication               | Litestream / LiteFS        | Native streaming rep.       |
| Full-text search          | FTS5 (good)                | tsvector (excellent)        |
| JSON                      | Good (json/jsonb)          | Excellent (jsonb + GIN)     |
| Geospatial                | SpatiaLite                 | PostGIS (more mature)       |
| Extensions                | Limited ecosystem          | Rich ecosystem (pg_*)       |
| Ops complexity            | Zero (it's a file)         | Requires DBA knowledge      |
| Testing                   | Ideal (in-memory, fast)    | Requires running server     |

## Performance Optimization

### Indexes
```sql
-- Covering index: query answered entirely from index
CREATE INDEX idx_users_email_name ON users(email, name);

-- Partial index: index only matching rows
CREATE INDEX idx_active_users ON users(email) WHERE active = 1;

-- Expression index
CREATE INDEX idx_lower_email ON users(lower(email));

-- WITHOUT ROWID: clustered table on PK (good for non-integer PKs)
CREATE TABLE sessions (
    token TEXT PRIMARY KEY,
    user_id INTEGER,
    expires_at TEXT
) WITHOUT ROWID;
```

### Query Performance
```sql
-- Use EXPLAIN QUERY PLAN to check index usage
EXPLAIN QUERY PLAN SELECT * FROM users WHERE email = 'a@b.com';

-- Batch inserts in transactions (100x faster than individual inserts)
BEGIN;
INSERT INTO logs VALUES (?, ?, ?);  -- repeat N times
COMMIT;

-- Use INSERT OR REPLACE / UPSERT for idempotent writes
INSERT INTO kv (key, value) VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;

-- ANALYZE: update query planner statistics after bulk data changes
ANALYZE;
```

### VACUUM
```sql
-- Full vacuum: rebuild entire database, reclaim space
VACUUM;

-- Incremental vacuum (if auto_vacuum = INCREMENTAL)
PRAGMA incremental_vacuum(1000);  -- free up to 1000 pages

-- Vacuum into a new file (online backup + compact)
VACUUM INTO 'compacted.db';
```

## Common Anti-Patterns and Gotchas

| Anti-Pattern                          | Fix                                               |
|---------------------------------------|---------------------------------------------------|
| Using `LIKE '%term%'` for search      | Use FTS5 instead                                  |
| Missing `busy_timeout`                | Always set `PRAGMA busy_timeout = 5000`            |
| Not using WAL mode                    | Always set `PRAGMA journal_mode = WAL`             |
| Individual INSERTs without transaction| Wrap bulk inserts in `BEGIN`/`COMMIT`              |
| Storing dates as free-form text       | Use ISO-8601: `YYYY-MM-DD HH:MM:SS`               |
| Opening DB over network filesystem    | Never use SQLite on NFS/SMB/CIFS                   |
| Not enabling foreign keys             | `PRAGMA foreign_keys = ON` at every connection     |
| Using `SELECT *` in production        | Name columns explicitly for covering index benefit |
| Long-running write transactions       | Keep writes under 1 second; use `BEGIN IMMEDIATE`  |
| Not running ANALYZE after bulk loads  | Run `ANALYZE` to update planner statistics         |
| Ignoring WAL checkpoint               | Run `PRAGMA wal_checkpoint(TRUNCATE)` periodically |
| Using ORM without raw SQL escape hatch| Keep raw SQL available for complex queries         |
| Not testing with production data size | SQLite performance changes at scale—test with real data |

## Resources

### References

| File | Description |
|------|-------------|
| [references/advanced-patterns.md](references/advanced-patterns.md) | Virtual tables (FTS5, R-Tree, CSV), custom collations, authorizer callbacks, prepared statements, shared cache, mmap I/O, VACUUM strategies, UPSERT, RETURNING, math/date/window functions, B-tree internals |
| [references/troubleshooting.md](references/troubleshooting.md) | "Database is locked" errors, WAL checkpoint stalls, corruption detection/recovery, SQLITE_BUSY handling, performance cliffs, temp storage, index selection, platform issues (NFS, Android, Docker) |
| [references/language-bindings.md](references/language-bindings.md) | SQLite in Python (sqlite3, aiosqlite, SQLAlchemy), Node.js (better-sqlite3, sql.js, Drizzle), Go (modernc.org/sqlite, mattn/go-sqlite3), Rust (rusqlite, Diesel) with connection patterns, error handling, and migration tools |

### Scripts

| File | Description |
|------|-------------|
| [scripts/sqlite-health-check.sh](scripts/sqlite-health-check.sh) | Check database health: integrity, WAL status, page stats, freelist, schema version, table summary |
| [scripts/sqlite-optimize.sh](scripts/sqlite-optimize.sh) | Optimize database: ANALYZE, VACUUM, REINDEX, PRAGMA optimize, incremental vacuum, index recommendations |
| [scripts/sqlite-backup.sh](scripts/sqlite-backup.sh) | Safe online backup using `.backup` with optional verification, compression, and timestamping |

### Assets

| File | Description |
|------|-------------|
| [assets/production-pragmas.sql](assets/production-pragmas.sql) | Complete PRAGMA configuration for production use with detailed comments |
| [assets/fts5-setup.sql](assets/fts5-setup.sql) | FTS5 full-text search setup with content table, sync triggers, and example queries |
| [assets/migration-template.sql](assets/migration-template.sql) | Schema migration template with version tracking, up/down sections, and verification |
| [assets/connection-pool.py](assets/connection-pool.py) | Python connection pool: single writer + multiple readers with WAL mode and context managers |
