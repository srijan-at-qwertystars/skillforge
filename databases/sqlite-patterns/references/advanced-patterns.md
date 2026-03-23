# Advanced SQLite Patterns

## Table of Contents

- [Virtual Tables](#virtual-tables)
  - [FTS5 (Full-Text Search)](#fts5-full-text-search)
  - [R-Tree (Spatial Indexing)](#r-tree-spatial-indexing)
  - [CSV Virtual Table](#csv-virtual-table)
- [Custom Collations](#custom-collations)
- [Authorizer Callbacks](#authorizer-callbacks)
- [sqlite3_exec vs Prepared Statements](#sqlite3_exec-vs-prepared-statements)
- [Shared Cache Mode](#shared-cache-mode)
- [Memory-Mapped I/O](#memory-mapped-io)
- [VACUUM Strategies](#vacuum-strategies)
  - [Full VACUUM](#full-vacuum)
  - [auto_vacuum](#auto_vacuum)
  - [Incremental VACUUM](#incremental-vacuum)
  - [VACUUM INTO](#vacuum-into)
- [UPSERT Patterns](#upsert-patterns)
- [RETURNING Clause](#returning-clause)
- [Math Functions](#math-functions)
- [Date/Time Functions](#datetime-functions)
- [Aggregate Window Functions](#aggregate-window-functions)
- [SQLite Internals](#sqlite-internals)
  - [B-Tree Pages](#b-tree-pages)
  - [Overflow Pages](#overflow-pages)
  - [Page Size Tuning](#page-size-tuning)

---

## Virtual Tables

Virtual tables let SQLite query non-standard data sources using the standard SQL
interface. They are created with `CREATE VIRTUAL TABLE ... USING module(args)`.

### FTS5 (Full-Text Search)

FTS5 is the recommended full-text search module. It supports prefix queries, boolean
operators, phrase matching, column filters, and BM25 ranking.

```sql
-- Create an FTS5 table with column weights and a custom tokenizer
CREATE VIRTUAL TABLE articles_fts USING fts5(
    title,
    body,
    tags,
    content=articles,
    content_rowid=id,
    tokenize='porter unicode61 remove_diacritics 2'
);

-- Prefix queries
SELECT * FROM articles_fts WHERE articles_fts MATCH 'data*';

-- Boolean operators
SELECT * FROM articles_fts WHERE articles_fts MATCH 'sqlite AND (performance OR optimization)';

-- Phrase matching
SELECT * FROM articles_fts WHERE articles_fts MATCH '"write ahead log"';

-- Column filters (search only title)
SELECT * FROM articles_fts WHERE articles_fts MATCH 'title:sqlite';

-- BM25 ranking with column weights (title 10x, body 1x, tags 5x)
SELECT rowid, rank FROM articles_fts
WHERE articles_fts MATCH 'query'
ORDER BY bm25(articles_fts, 10.0, 1.0, 5.0);

-- Snippet extraction
SELECT snippet(articles_fts, 1, '<mark>', '</mark>', '...', 32)
FROM articles_fts WHERE articles_fts MATCH 'query';

-- Rebuild the entire FTS index
INSERT INTO articles_fts(articles_fts) VALUES ('rebuild');

-- Optimize the FTS index (merge segments)
INSERT INTO articles_fts(articles_fts) VALUES ('optimize');

-- Integrity check
INSERT INTO articles_fts(articles_fts, rank) VALUES ('integrity-check', 1);
```

**FTS5 tokenizers:**
- `unicode61` — Unicode-aware, folds case and removes diacritics. Default.
- `porter` — Wraps another tokenizer with Porter stemming (english → english, running → run).
- `ascii` — ASCII-only folding, faster for English-only text.
- `trigram` — Character trigrams for substring matching. Supports `LIKE` and `GLOB`.

```sql
-- Trigram tokenizer for substring search
CREATE VIRTUAL TABLE code_fts USING fts5(source, tokenize='trigram');
SELECT * FROM code_fts WHERE code_fts MATCH '"def __init__"';
```

### R-Tree (Spatial Indexing)

R-Tree indexes N-dimensional rectangles for spatial queries. Built-in (compile flag).

```sql
-- Create R-Tree for 2D bounding boxes
CREATE VIRTUAL TABLE spatial_idx USING rtree(
    id,
    min_x, max_x,
    min_y, max_y
);

-- Insert bounding boxes
INSERT INTO spatial_idx VALUES (1, -122.5, -122.4, 37.7, 37.8);

-- Range query: find all objects within a bounding box
SELECT s.id, d.name
FROM spatial_idx s
JOIN data d ON s.id = d.id
WHERE s.min_x >= -123.0 AND s.max_x <= -122.0
  AND s.min_y >= 37.0 AND s.max_y <= 38.0;

-- Nearest neighbor (use with auxiliary columns in 3.24+)
CREATE VIRTUAL TABLE geo_idx USING rtree(
    id,
    min_lat, max_lat,
    min_lon, max_lon,
    +name TEXT,          -- auxiliary column (stored, not indexed)
    +category TEXT
);
```

**R-Tree with auxiliary columns (3.24+):** Columns prefixed with `+` are stored in
the R-Tree but not spatially indexed. Avoids a join for simple lookups.

### CSV Virtual Table

Query CSV files directly without importing. Requires the csv extension.

```sql
-- Load csv extension
.load ./csv

-- Create virtual table from CSV file
CREATE VIRTUAL TABLE temp.data USING csv(
    filename='/path/to/data.csv',
    header=YES,
    columns=4
);

-- Query directly
SELECT * FROM temp.data WHERE column1 > 100;

-- Import into a real table
CREATE TABLE imported AS SELECT * FROM temp.data;
```

---

## Custom Collations

Collations define how text is compared and sorted. SQLite ships with BINARY (default),
NOCASE, and RTRIM. You can register custom collations via the C API or language bindings.

```python
# Python: register a case-insensitive, locale-aware collation
import sqlite3
import locale

def locale_collation(a, b):
    return locale.strcoll(a, b)

conn = sqlite3.connect('app.db')
conn.create_collation('LOCALE', locale_collation)
conn.execute("SELECT * FROM users ORDER BY name COLLATE LOCALE")
```

```python
# Python: natural sort (file1, file2, file10 instead of file1, file10, file2)
import re

def natural_sort_key(s):
    return [int(c) if c.isdigit() else c.lower() for c in re.split(r'(\d+)', s)]

def natural_collation(a, b):
    ka, kb = natural_sort_key(a), natural_sort_key(b)
    return (ka > kb) - (ka < kb)

conn.create_collation('NATURAL', natural_collation)
```

```sql
-- Use collation in CREATE TABLE
CREATE TABLE files (
    name TEXT COLLATE NOCASE,
    path TEXT COLLATE BINARY
);

-- Use collation in CREATE INDEX
CREATE INDEX idx_name ON files(name COLLATE NOCASE);

-- Use collation in ORDER BY
SELECT * FROM files ORDER BY name COLLATE NOCASE;
```

---

## Authorizer Callbacks

The authorizer callback is invoked during SQL compilation (not execution) to allow or
deny specific operations. Use for multi-tenant security, read-only enforcement, or
audit logging.

```python
# Python: restrict table access
import sqlite3

ALLOWED_TABLES = {'public_data', 'reports'}

def authorizer(action, arg1, arg2, db_name, trigger_name):
    # arg1 is table name for read/write operations
    if action in (sqlite3.SQLITE_READ, sqlite3.SQLITE_UPDATE,
                  sqlite3.SQLITE_INSERT, sqlite3.SQLITE_DELETE):
        if arg1 not in ALLOWED_TABLES:
            return sqlite3.SQLITE_DENY
    # Deny ATTACH/DETACH to prevent accessing other databases
    if action in (sqlite3.SQLITE_ATTACH, sqlite3.SQLITE_DETACH):
        return sqlite3.SQLITE_DENY
    # Deny pragmas that could change behavior
    if action == sqlite3.SQLITE_PRAGMA:
        safe_pragmas = {'query_only', 'table_info', 'index_list'}
        if arg1 not in safe_pragmas:
            return sqlite3.SQLITE_DENY
    return sqlite3.SQLITE_OK

conn = sqlite3.connect('app.db')
conn.set_authorizer(authorizer)
```

**Authorizer action codes:** `SQLITE_READ`, `SQLITE_UPDATE`, `SQLITE_INSERT`,
`SQLITE_DELETE`, `SQLITE_CREATE_TABLE`, `SQLITE_DROP_TABLE`, `SQLITE_PRAGMA`,
`SQLITE_ATTACH`, `SQLITE_DETACH`, `SQLITE_FUNCTION`, and more.

**Return values:**
- `SQLITE_OK` — Allow the operation.
- `SQLITE_DENY` — Abort the SQL statement with an error.
- `SQLITE_IGNORE` — Treat the column as NULL (for reads) or silently ignore (for writes).

---

## sqlite3_exec vs Prepared Statements

`sqlite3_exec()` compiles and executes SQL in one call. Prepared statements
(`sqlite3_prepare_v2` → `sqlite3_step` → `sqlite3_finalize`) separate compilation
from execution.

**Always prefer prepared statements:**

| Feature            | sqlite3_exec            | Prepared Statement            |
|--------------------|-------------------------|-------------------------------|
| SQL injection      | Vulnerable (string fmt) | Safe (bound parameters)       |
| Performance        | Recompiles every call   | Compile once, execute many    |
| Parameter binding  | Not supported           | `?`, `:name`, `$name`, `@name`|
| Result handling    | Callback-based          | Step-based iteration          |
| Error reporting    | Basic                   | Detailed (column-level)       |

```c
// C: prepared statement with parameter binding
sqlite3_stmt *stmt;
sqlite3_prepare_v2(db, "INSERT INTO users (name, age) VALUES (?, ?)", -1, &stmt, NULL);
for (int i = 0; i < count; i++) {
    sqlite3_bind_text(stmt, 1, names[i], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 2, ages[i]);
    sqlite3_step(stmt);
    sqlite3_reset(stmt);    // reset for reuse
    sqlite3_clear_bindings(stmt);
}
sqlite3_finalize(stmt);
```

**Use `sqlite3_exec` only for:** one-time DDL, PRAGMA configuration, scripts where
you control the SQL. Never use it with user-supplied input.

---

## Shared Cache Mode

Shared cache allows multiple connections within the same process to share a single
data and schema cache, reducing memory when many connections access the same database.

```c
// C: enable shared cache (per-process)
sqlite3_enable_shared_cache(1);

// Or per-connection via URI
sqlite3_open_v2("file:app.db?cache=shared", &db, SQLITE_OPEN_READWRITE, NULL);
```

**Shared cache trade-offs:**
- ✅ Lower memory usage with many connections.
- ✅ Enables table-level locking (finer than file-level).
- ❌ Increased lock contention between connections.
- ❌ Deprecated as of SQLite 3.41.0 — not recommended for new code.
- ❌ Cannot use WAL mode with shared cache across processes.

**Recommendation:** Avoid shared cache. Use WAL mode with separate connections instead.
It was useful pre-WAL but offers no advantage with modern SQLite.

---

## Memory-Mapped I/O

Memory-mapped I/O (`mmap`) maps the database file into the process address space,
allowing the OS to handle page caching instead of SQLite's internal page cache.

```sql
-- Enable memory-mapped I/O (256 MB limit)
PRAGMA mmap_size = 268435456;

-- Disable mmap
PRAGMA mmap_size = 0;

-- Query current mmap size
PRAGMA mmap_size;
```

**How it works:** When mmap is enabled, SQLite uses `mmap()` to map up to `mmap_size`
bytes of the database file. Read operations access memory directly (zero-copy).
Write operations still use the traditional path (write to WAL or journal, then to DB).

**Benefits:**
- Faster reads: eliminates `read()` system calls and an extra copy.
- Reduced memory: OS page cache is shared across processes.
- Typically 5-15% read performance improvement.

**Caveats:**
- Does not improve write performance.
- A corrupt database could cause SIGBUS/SIGSEGV (process crash instead of error code).
- Not beneficial if the database is larger than available RAM.
- On 32-bit systems, limited by address space (~2-3 GB max).
- Does not work with encrypted databases (SQLCipher).

**Recommended setting:** Set `mmap_size` to the smaller of database size or ~256 MB.
For databases > 1 GB, benchmark to verify benefit.

---

## VACUUM Strategies

### Full VACUUM

Rebuilds the entire database file from scratch: defragments, reclaims free pages,
and compacts the file.

```sql
VACUUM;
```

- Requires up to 2x database size in temporary disk space.
- Holds an exclusive lock for the entire duration — blocks all other access.
- Resets `auto_vacuum` mode and `page_size` if set before VACUUM.
- Run during maintenance windows or on offline databases.

### auto_vacuum

Automatically reclaims free pages when data is deleted. Must be set before creating
any tables (or use VACUUM to convert).

```sql
-- Set before creating tables
PRAGMA auto_vacuum = FULL;        -- reclaim pages immediately after delete
PRAGMA auto_vacuum = INCREMENTAL; -- reclaim pages on demand
PRAGMA auto_vacuum = NONE;        -- default, no auto-vacuum
```

**FULL vs INCREMENTAL:**
- `FULL` reclaims pages immediately but causes more I/O on every DELETE.
- `INCREMENTAL` stores freed pages on a freelist; you reclaim them manually.
- `INCREMENTAL` is preferred — gives you control over when the work happens.

### Incremental VACUUM

When `auto_vacuum = INCREMENTAL`, freed pages go to a freelist. Reclaim them manually:

```sql
-- Reclaim up to 500 pages from the freelist
PRAGMA incremental_vacuum(500);

-- Reclaim all free pages
PRAGMA incremental_vacuum;

-- Check freelist size
PRAGMA freelist_count;
```

**Incremental vacuum scheduling:**
- Run during idle periods or low-traffic times.
- Process a bounded number of pages per call to avoid long locks.
- Monitor `freelist_count` and vacuum when it exceeds a threshold (e.g., >1000 pages).

### VACUUM INTO

Creates a compacted copy of the database in a new file (3.27+). Non-destructive,
can run concurrently with reads.

```sql
VACUUM INTO '/backups/compacted.db';
```

Use cases: online backup + compaction, creating a clean copy for distribution,
reducing file size before deploying embedded databases.

---

## UPSERT Patterns

UPSERT (INSERT ... ON CONFLICT) was added in SQLite 3.24.

```sql
-- Basic upsert on primary key
INSERT INTO kv (key, value, updated_at)
VALUES ('config', '{"theme":"dark"}', datetime('now'))
ON CONFLICT(key) DO UPDATE SET
    value = excluded.value,
    updated_at = excluded.updated_at;

-- Upsert with conditional update (only update if new value differs)
INSERT INTO settings (key, value)
VALUES ('version', '2.0')
ON CONFLICT(key) DO UPDATE SET value = excluded.value
WHERE excluded.value != settings.value;

-- Upsert with increment
INSERT INTO counters (name, count)
VALUES ('page_views', 1)
ON CONFLICT(name) DO UPDATE SET count = count + excluded.count;

-- Multiple conflict targets
INSERT INTO tags (name, category, count)
VALUES ('sqlite', 'database', 1)
ON CONFLICT(name, category) DO UPDATE SET count = count + 1;

-- DO NOTHING: skip on conflict (idempotent insert)
INSERT OR IGNORE INTO users (email, name) VALUES ('a@b.com', 'Alice');
-- equivalent:
INSERT INTO users (email, name) VALUES ('a@b.com', 'Alice')
ON CONFLICT(email) DO NOTHING;
```

---

## RETURNING Clause

The RETURNING clause (3.35+) returns values from rows modified by INSERT, UPDATE,
or DELETE.

```sql
-- Return the auto-generated ID
INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')
RETURNING id;

-- Return multiple columns
INSERT INTO orders (user_id, total)
VALUES (1, 99.99)
RETURNING id, created_at;

-- Return updated rows
UPDATE products SET price = price * 1.1
WHERE category = 'electronics'
RETURNING id, name, price AS new_price;

-- Return deleted rows
DELETE FROM sessions
WHERE expires_at < datetime('now')
RETURNING id, user_id;

-- Use with UPSERT
INSERT INTO counters (name, count) VALUES ('hits', 1)
ON CONFLICT(name) DO UPDATE SET count = count + 1
RETURNING count;
```

---

## Math Functions

SQLite 3.35+ includes built-in math functions (previously required extensions).

```sql
-- Basic math
SELECT abs(-5), sign(-3), min(a, b), max(a, b);

-- Rounding
SELECT ceil(4.2), floor(4.8), round(4.567, 2), trunc(4.9);
-- Results: 5, 4, 4.57, 4

-- Powers and roots
SELECT pow(2, 10), sqrt(144), log(100), log2(1024), log10(1000);
-- Results: 1024, 12.0, 4.605, 10.0, 3.0

-- Trigonometry
SELECT sin(pi()/2), cos(0), tan(pi()/4), asin(1.0), acos(0.0), atan(1.0);

-- atan2 for angle calculation
SELECT degrees(atan2(1.0, 1.0));  -- 45.0

-- Modulo (works with floats, unlike %)
SELECT mod(10.5, 3);  -- 1.5

-- Random value in range [0, 1)
SELECT (abs(random()) % 1000000) / 1000000.0;
```

---

## Date/Time Functions

SQLite has no DATE/TIME types. Store dates as TEXT (ISO-8601), INTEGER (Unix epoch),
or REAL (Julian day).

```sql
-- Current date/time
SELECT date('now');                      -- 2024-01-15
SELECT time('now');                      -- 14:30:00
SELECT datetime('now');                  -- 2024-01-15 14:30:00
SELECT unixepoch('now');                 -- 1705329000 (integer)
SELECT julianday('now');                 -- 2460324.104166...
SELECT strftime('%Y-%m-%dT%H:%M:%SZ', 'now');  -- ISO-8601

-- Date arithmetic with modifiers
SELECT date('now', '+7 days');           -- 7 days from now
SELECT date('now', '-1 month');          -- 1 month ago
SELECT date('now', 'start of month');    -- first of current month
SELECT date('now', 'start of year', '+6 months', '-1 day');  -- last day of June
SELECT datetime('now', '+2 hours', '+30 minutes');

-- Extract components
SELECT strftime('%Y', '2024-01-15');     -- year: 2024
SELECT strftime('%m', '2024-01-15');     -- month: 01
SELECT strftime('%w', '2024-01-15');     -- day of week: 0=Sun
SELECT strftime('%j', '2024-01-15');     -- day of year: 015
SELECT strftime('%s', '2024-01-15');     -- Unix timestamp

-- Convert Unix timestamp to datetime
SELECT datetime(1705329000, 'unixepoch');
SELECT datetime(1705329000, 'unixepoch', 'localtime');

-- Age calculation
SELECT (julianday('now') - julianday('1990-05-15')) / 365.25 AS age_years;

-- Time zone conversion (SQLite stores UTC by default)
SELECT datetime('now', 'localtime');           -- UTC to local
SELECT datetime('2024-01-15 10:00:00', 'utc'); -- local to UTC

-- Group by date parts
SELECT date(created_at) AS day, count(*) AS count
FROM events
GROUP BY date(created_at)
ORDER BY day;

-- Date ranges
SELECT * FROM events
WHERE created_at BETWEEN '2024-01-01' AND '2024-01-31 23:59:59';

-- timediff (3.43+): human-readable time difference
SELECT timediff('2024-06-15', '2024-01-01');  -- +0000-05-14 00:00:00.000
```

---

## Aggregate Window Functions

Window functions operate over a set of rows related to the current row without
collapsing the result set like GROUP BY.

```sql
-- All aggregate functions can be used as window functions
SELECT id, amount,
    SUM(amount)   OVER w AS running_sum,
    AVG(amount)   OVER w AS running_avg,
    COUNT(*)      OVER w AS running_count,
    MIN(amount)   OVER w AS running_min,
    MAX(amount)   OVER w AS running_max,
    GROUP_CONCAT(id, ',') OVER w AS ids_so_far
FROM transactions
WINDOW w AS (ORDER BY created_at ROWS UNBOUNDED PRECEDING);

-- NTILE: divide into N roughly equal buckets
SELECT name, salary,
    NTILE(4) OVER (ORDER BY salary DESC) AS quartile
FROM employees;

-- PERCENT_RANK and CUME_DIST
SELECT name, salary,
    PERCENT_RANK() OVER (ORDER BY salary) AS pct_rank,
    CUME_DIST()    OVER (ORDER BY salary) AS cum_dist
FROM employees;

-- NTH_VALUE
SELECT date, value,
    NTH_VALUE(value, 1) OVER w AS first_value,
    NTH_VALUE(value, 3) OVER w AS third_value
FROM metrics
WINDOW w AS (ORDER BY date ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING);

-- FIRST_VALUE / LAST_VALUE
SELECT department, name, salary,
    FIRST_VALUE(name) OVER dept_w AS lowest_paid,
    LAST_VALUE(name)  OVER dept_w AS highest_paid
FROM employees
WINDOW dept_w AS (
    PARTITION BY department
    ORDER BY salary
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
);

-- Frame specifications
-- ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW      -- default
-- ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING               -- sliding window
-- RANGE BETWEEN INTERVAL ... PRECEDING AND CURRENT ROW   -- value-based
-- GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING              -- group-based

-- Multiple named windows
SELECT id, category, amount,
    SUM(amount) OVER by_cat AS cat_total,
    RANK()      OVER by_cat_ranked AS cat_rank,
    SUM(amount) OVER global AS global_total
FROM transactions
WINDOW
    by_cat AS (PARTITION BY category),
    by_cat_ranked AS (PARTITION BY category ORDER BY amount DESC),
    global AS ();

-- Compute deltas and rates
SELECT date, value,
    value - LAG(value, 1) OVER (ORDER BY date) AS daily_delta,
    CASE
        WHEN LAG(value, 1) OVER (ORDER BY date) > 0
        THEN round(100.0 * (value - LAG(value, 1) OVER (ORDER BY date))
             / LAG(value, 1) OVER (ORDER BY date), 2)
    END AS pct_change
FROM daily_metrics;
```

---

## SQLite Internals

### B-Tree Pages

SQLite stores all data in a B-tree structure within fixed-size pages. Understanding
this helps with performance tuning.

**Page types:**
1. **Interior table pages** — Hold keys and pointers to child pages (no data).
2. **Leaf table pages** — Hold row data (rowid + columns).
3. **Interior index pages** — Hold indexed column values and child pointers.
4. **Leaf index pages** — Hold indexed column values and rowids.

**Default page size:** 4096 bytes. Can be set before creating the database:

```sql
PRAGMA page_size = 8192;  -- must be set before VACUUM or database creation
VACUUM;                    -- apply new page size
```

**Page size selection:**
- 4096 (default): good for most workloads, matches most filesystem block sizes.
- 8192-16384: better for large BLOB/TEXT columns, large databases, or sequential scans.
- 32768-65536: maximum, for very large records or heavy sequential access.
- Smaller pages (1024-2048): better for small databases, random point lookups.

```sql
-- Inspect page usage
PRAGMA page_count;            -- total pages in database
PRAGMA page_size;             -- page size in bytes
PRAGMA freelist_count;        -- unused pages on freelist

-- Total database size = page_count × page_size
SELECT page_count * page_size AS db_size_bytes FROM pragma_page_count(), pragma_page_size();
```

### Overflow Pages

When a record is too large to fit in a single B-tree leaf page, SQLite stores the
excess in overflow pages (linked list of pages).

**Overflow threshold:** A record overflows when it exceeds approximately
`(page_size - 35) / 4` bytes. For a 4096-byte page, that's ~1015 bytes.

**Performance implications:**
- Overflow causes extra I/O: reading one row may require reading multiple pages.
- BLOB/TEXT columns are the usual culprits.
- Large records degrade B-tree fan-out (fewer rows per page = deeper tree).

**Strategies to avoid overflow:**
1. Increase `page_size` to accommodate typical record size.
2. Store large BLOBs in a separate table or external files.
3. Compress data before inserting.
4. Use `WITHOUT ROWID` for tables with large composite keys.

```sql
-- Check average row size
SELECT avg(length(data)) FROM documents;

-- If avg row size is near overflow threshold, increase page size
PRAGMA page_size = 8192;
VACUUM;
```

### Page Size Tuning

Match `page_size` to your workload:

| Workload Pattern               | Recommended Page Size |
|--------------------------------|----------------------|
| Small key-value lookups        | 4096 (default)       |
| JSON documents (1-5 KB)        | 8192                 |
| Large text/BLOBs (>10 KB)      | 16384-32768          |
| Analytical / sequential scans  | 8192-16384           |
| Embedded / memory-constrained  | 1024-4096            |

```sql
-- Analyze row size distribution to choose page size
SELECT
    min(length(data)) AS min_bytes,
    avg(length(data)) AS avg_bytes,
    max(length(data)) AS max_bytes,
    count(*) FILTER (WHERE length(data) > 1000) AS overflow_risk_rows
FROM documents;
```
