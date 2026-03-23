---
name: database-indexing
description: |
  Use when user designs database indexes, asks about B-tree, hash, GIN, GiST, covering indexes, partial indexes, composite index ordering, or index performance analysis (EXPLAIN).
  Do NOT use for Elasticsearch indexing (use elasticsearch-patterns skill), full-text search architecture, or general SQL query optimization (use sql-query-optimization skill).
---

# Database Indexing Strategies

## Index Fundamentals

Indexes trade write overhead and storage for faster reads. Without an index, the database performs a sequential scan. An index creates a sorted structure that narrows the search space.

**B-Tree structure**: keys stored in sorted order across balanced tree nodes (pages). Internal nodes hold keys + child pointers. Leaf nodes hold keys + heap tuple pointers. Height is typically 3–4 levels for millions of rows.

**Cardinality**: number of distinct values. **Selectivity**: `NDV / total_rows`.
- High selectivity (email, UUID) → index effective.
- Low selectivity (boolean, status) → planner prefers sequential scan.
- Rule: index columns where queries filter to <10–15% of rows.

---

## Index Types

### B-Tree (Default)

Best for equality (`=`), range (`<`, `>`, `BETWEEN`), sorting, and `IS NULL`.

```sql
CREATE INDEX idx_orders_created ON orders (created_at);
SELECT * FROM orders WHERE created_at > '2025-01-01' ORDER BY created_at;
```

### Hash

Equality-only (`=`). Smaller than B-tree for equality lookups. Not for ranges or sorting.

```sql
CREATE INDEX idx_sessions_token ON sessions USING hash (session_token);
```

### GIN (Generalized Inverted Index)

Best for multi-valued columns: arrays, JSONB, full-text (`tsvector`). Maps each element to the set of rows containing it. Slower writes — tune `gin_pending_list_limit` for write-heavy tables.

```sql
CREATE INDEX idx_tags ON articles USING gin (tags);
SELECT * FROM articles WHERE tags @> ARRAY['postgresql', 'indexing'];
```

### GiST (Generalized Search Tree)

Supports geometric, range, and nearest-neighbor queries. Used by PostGIS, `pg_trgm`, range types.

```sql
CREATE INDEX idx_locations ON stores USING gist (geom);
SELECT name FROM stores ORDER BY geom <-> ST_MakePoint(-73.99, 40.73) LIMIT 5;
```

### SP-GiST (Space-Partitioned GiST)

Optimized for naturally clustered data: IP addresses, phone numbers, quad-trees, k-d trees.

```sql
CREATE INDEX idx_ip ON access_log USING spgist (client_ip inet_ops);
```

### BRIN (Block Range Index)

Stores min/max per block range. Tiny footprint (<1% of equivalent B-tree). Effective only when values correlate with physical row order (append-only, time-series). Do not use on randomly-ordered columns.

```sql
CREATE INDEX idx_events_ts ON events USING brin (created_at) WITH (pages_per_range = 32);
SELECT * FROM events WHERE created_at BETWEEN '2025-06-01' AND '2025-06-02';
```

### Bloom Filter Index

Equality queries on many columns via signature-based approach. Requires `bloom` extension.

```sql
CREATE EXTENSION bloom;
CREATE INDEX idx_bloom ON products USING bloom (color, size, brand, category)
  WITH (length = 80, col1 = 2, col2 = 2, col3 = 2, col4 = 2);
```

---

## Composite Indexes

### Column Order and Left-Prefix Rule

A composite index `(a, b, c)` supports queries on `(a)`, `(a, b)`, and `(a, b, c)`. It does NOT support queries on `(b)` or `(b, c)` alone.

### Equality-Then-Range Rule

Place equality columns first, range columns next, sort columns last.

```sql
CREATE INDEX idx_orders_cust_date ON orders (customer_id, created_at);
```

```
EXPLAIN ANALYZE SELECT * FROM orders
  WHERE customer_id = 42 AND created_at > '2025-01-01' ORDER BY created_at;
-- Index Scan using idx_orders_cust_date on orders
--   Index Cond: (customer_id = 42 AND created_at > '2025-01-01')
--   Planning Time: 0.12 ms  Execution Time: 0.45 ms
```

Wrong order — range column first defeats equality seek:

```sql
-- BAD: CREATE INDEX idx_bad ON orders (created_at, customer_id);
```

---

## Covering Indexes

Store extra columns in index leaf pages to enable index-only scans (no heap lookup).

### PostgreSQL (INCLUDE)

```sql
CREATE INDEX idx_orders_covering ON orders (customer_id, created_at)
  INCLUDE (total_amount, status);

EXPLAIN ANALYZE SELECT customer_id, created_at, total_amount, status
  FROM orders WHERE customer_id = 42 AND created_at > '2025-01-01';
-- Index Only Scan using idx_orders_covering on orders
--   Heap Fetches: 0
```

### MySQL (Covering via composite)

In InnoDB, any index containing all referenced columns is "covering." Look for `Using index` in EXPLAIN Extra.

```sql
CREATE INDEX idx_covering ON orders (customer_id, created_at, total_amount, status);
```

**Trade-offs**: increases index size and write cost. INCLUDE columns cannot be used for filtering/ordering. Use for hot read paths; avoid on write-heavy tables.

---

## Partial Indexes

Index only rows matching a predicate. Reduce size, improve insert performance.

```sql
CREATE INDEX idx_active_orders ON orders (customer_id, created_at)
  WHERE status = 'active';
-- Query must include the predicate to use this index
SELECT * FROM orders WHERE status = 'active' AND customer_id = 42;
```

Conditional uniqueness:

```sql
CREATE UNIQUE INDEX idx_unique_active_email ON users (email)
  WHERE deleted_at IS NULL;
```

Sparse data — index only non-null values:

```sql
CREATE INDEX idx_referral_code ON users (referral_code)
  WHERE referral_code IS NOT NULL;
```

---

## Expression Indexes

Index computed values. Query must match the expression exactly.

```sql
CREATE INDEX idx_lower_email ON users (lower(email));
SELECT * FROM users WHERE lower(email) = 'alice@example.com';

CREATE INDEX idx_settings_theme ON users ((settings->>'theme'));
SELECT * FROM users WHERE settings->>'theme' = 'dark';
```

---

## Unique Indexes and Constraints

```sql
-- Unique constraint (creates a unique B-tree index)
ALTER TABLE users ADD CONSTRAINT uq_email UNIQUE (email);

-- Equivalent explicit index
CREATE UNIQUE INDEX idx_unique_email ON users (email);

-- Primary key = unique NOT NULL index (clustered in InnoDB)
ALTER TABLE users ADD PRIMARY KEY (id);

-- Partial unique (PostgreSQL)
CREATE UNIQUE INDEX idx_one_primary_addr ON addresses (user_id)
  WHERE is_primary = true;
```

---

## Full-Text Indexes

### PostgreSQL (tsvector / tsquery)

```sql
ALTER TABLE articles ADD COLUMN search_vector tsvector
  GENERATED ALWAYS AS (to_tsvector('english', title || ' ' || body)) STORED;
CREATE INDEX idx_fts ON articles USING gin (search_vector);
SELECT title FROM articles WHERE search_vector @@ to_tsquery('english', 'indexing & strategy');
```

### MySQL (FULLTEXT)

```sql
ALTER TABLE articles ADD FULLTEXT INDEX idx_ft (title, body);
SELECT title FROM articles WHERE MATCH(title, body) AGAINST('indexing strategy' IN BOOLEAN MODE);
```

---

## JSON/JSONB Indexes

### GIN on Entire JSONB Column

```sql
CREATE INDEX idx_meta ON products USING gin (metadata jsonb_path_ops);
SELECT * FROM products WHERE metadata @> '{"color": "red", "size": "L"}';
-- jsonb_path_ops: smaller and faster than default jsonb_ops, supports only @>
```

### Expression Index on Specific Key

```sql
CREATE INDEX idx_sku ON products ((metadata->>'sku'));
SELECT * FROM products WHERE metadata->>'sku' = 'ABC-123';
```

---

## Index Analysis

### EXPLAIN ANALYZE

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
  SELECT * FROM orders WHERE customer_id = 42;
-- GOOD: "Index Scan using idx_orders_cust on orders"
-- BAD:  "Seq Scan on orders" with Filter removing many rows
```

Key indicators:
- `Index Scan` / `Index Only Scan` → index used.
- `Bitmap Index Scan` → index used but many rows.
- `Seq Scan` → no index or planner chose scan (check selectivity).
- `Heap Fetches: 0` → index-only scan succeeded.

### Detecting Unused Indexes (PostgreSQL)

```sql
SELECT schemaname, relname AS table, indexrelname AS index,
       idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;
```

### MySQL Index Usage

```sql
SELECT * FROM sys.schema_unused_indexes WHERE object_schema = 'mydb';
SELECT * FROM sys.schema_redundant_indexes WHERE table_schema = 'mydb';
```

---

## Index Maintenance

### Bloat and REINDEX (PostgreSQL)

B-tree pages become sparse after heavy UPDATE/DELETE.

```sql
REINDEX INDEX CONCURRENTLY idx_orders_cust_date;
REINDEX TABLE CONCURRENTLY orders;
```

### VACUUM and Visibility Map

`VACUUM` marks dead tuples reusable and updates the visibility map (required for index-only scans). Tune for high-churn tables:

```sql
ALTER TABLE orders SET (
  autovacuum_vacuum_scale_factor = 0.01,
  autovacuum_analyze_scale_factor = 0.005
);
```

### Online DDL (MySQL)

```sql
ALTER TABLE orders ADD INDEX idx_status (status), ALGORITHM=INPLACE, LOCK=NONE;
```

### CONCURRENTLY (PostgreSQL)

Always use in production to avoid blocking reads/writes:

```sql
CREATE INDEX CONCURRENTLY idx_new ON orders (region, created_at);
```

---

## MySQL-Specific (InnoDB)

InnoDB stores table data ordered by primary key (clustered index). Every secondary index leaf stores the PK value, not a row pointer.

- Use compact PKs (auto-increment integer, not UUID).
- Secondary lookups require double B-tree traversal (secondary → clustered).
- Covering indexes eliminate the second lookup.

```sql
CREATE INDEX idx_email ON users (email);
-- Lookup: idx_email → get PK → clustered index → row data

-- Covering avoids second lookup:
CREATE INDEX idx_email_cov ON users (email, name, created_at);
SELECT email, name, created_at FROM users WHERE email = 'alice@example.com';
-- Extra: Using index
```

Index hints (use sparingly):

```sql
SELECT * FROM orders FORCE INDEX (idx_orders_cust_date)
  WHERE customer_id = 42 AND created_at > '2025-01-01';
```

---

## PostgreSQL-Specific

### GIN Fast Update

GIN buffers new entries in a pending list, then flushes in batch.

```sql
ALTER INDEX idx_tags SET (fastupdate = off);
-- Slower inserts but consistent read performance for real-time search
```

### BRIN for Time-Series

Combine with partitioning for large datasets:

```sql
CREATE TABLE metrics (ts timestamptz, device_id int, value numeric)
  PARTITION BY RANGE (ts);
CREATE INDEX idx_metrics_ts ON metrics USING brin (ts) WITH (pages_per_range = 16);
```

### HOT Updates (Heap-Only Tuples)

When UPDATE does not modify indexed columns and there is same-page space, PostgreSQL skips index maintenance. Maximize by lowering fillfactor and avoiding indexes on frequently-changed columns.

```sql
ALTER TABLE sessions SET (fillfactor = 80);
```

---

## Index Design Methodology

1. Collect top queries by frequency and latency (`pg_stat_statements`, slow query log).
2. For each query, identify WHERE, JOIN, ORDER BY, and SELECT columns.
3. Design index: equality columns → range columns → sort columns → INCLUDE remaining SELECT columns.
4. Validate with `EXPLAIN ANALYZE`.
5. Monitor with `pg_stat_user_indexes` or `sys.schema_index_statistics`.

### Read/Write Balance

- **Read-heavy** (analytics): more indexes acceptable; use covering and partial.
- **Write-heavy** (OLTP, ingestion): minimize index count; prefer partial; use BRIN for append-only.
- **Mixed**: index critical read paths, benchmark write impact.

### Workload Analysis Checklist

| Step | Action |
|------|--------|
| 1 | Identify top 10 slowest queries |
| 2 | Run EXPLAIN ANALYZE on each |
| 3 | Check existing indexes for redundancy |
| 4 | Design minimal index set covering all patterns |
| 5 | Deploy with CONCURRENTLY / ALGORITHM=INPLACE |
| 6 | Monitor idx_scan counts after 1 week |
| 7 | Drop indexes with zero scans |

---

## Anti-Patterns

**Over-indexing**: every index slows INSERT/UPDATE/DELETE and consumes storage. A table with 15 indexes suffers on writes. Audit regularly.

**Wrong column order**:

```sql
-- BAD: low-cardinality column first
CREATE INDEX idx_bad ON orders (status, customer_id);
-- GOOD: high-cardinality first, or use partial index
CREATE INDEX idx_good ON orders (customer_id) WHERE status = 'active';
```

**Indexing low-cardinality columns**: boolean/enum with 2–5 values rarely benefits from standalone index. Use partial index instead:

```sql
-- BAD:  CREATE INDEX idx_active ON users (is_active);
-- GOOD:
CREATE INDEX idx_active_users ON users (email) WHERE is_active = true;
```

**Missing CONCURRENTLY**:

```sql
-- DANGEROUS: locks the table
CREATE INDEX idx_big ON big_table (col);
-- SAFE:
CREATE INDEX CONCURRENTLY idx_big ON big_table (col);
```

**Redundant indexes**: index `(a, b)` makes standalone index `(a)` redundant. Drop the single-column index.

**Ignoring visibility map**: index-only scans require up-to-date visibility map. Tune autovacuum for hot tables or Heap Fetches will spike.
