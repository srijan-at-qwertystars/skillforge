# Advanced MySQL Patterns

## Table of Contents

- [InnoDB Internals](#innodb-internals)
  - [Clustered Index Architecture](#clustered-index-architecture)
  - [MVCC and Undo Logs](#mvcc-and-undo-logs)
  - [Change Buffer](#change-buffer)
  - [Adaptive Hash Index](#adaptive-hash-index)
  - [Doublewrite Buffer](#doublewrite-buffer)
  - [Redo Log Tuning](#redo-log-tuning)
- [Partitioning Strategies](#partitioning-strategies)
  - [Range Partitioning](#range-partitioning)
  - [Hash Partitioning](#hash-partitioning)
  - [List Partitioning](#list-partitioning)
  - [Subpartitioning](#subpartitioning)
  - [Partition Maintenance](#partition-maintenance)
  - [Partition Pruning Verification](#partition-pruning-verification)
- [JSON Column Optimization](#json-column-optimization)
  - [Functional Indexes on JSON](#functional-indexes-on-json)
  - [Generated Columns from JSON](#generated-columns-from-json)
  - [Multi-Valued Indexes](#multi-valued-indexes)
  - [JSON vs Normalized Columns](#json-vs-normalized-columns)
  - [JSON Partial Updates](#json-partial-updates)
- [Window Functions Performance](#window-functions-performance)
  - [Window Function Execution Model](#window-function-execution-model)
  - [Optimizing Window Queries](#optimizing-window-queries)
  - [Common Window Patterns](#common-window-patterns)
- [CTE Optimization](#cte-optimization)
  - [Materialized vs Merged CTEs](#materialized-vs-merged-ctes)
  - [Recursive CTE Performance](#recursive-cte-performance)
  - [CTE Anti-Patterns](#cte-anti-patterns)
- [Optimizer Hints](#optimizer-hints)
  - [Index Hints](#index-hints)
  - [Join Order Hints](#join-order-hints)
  - [Subquery Hints](#subquery-hints)
  - [Resource Hints](#resource-hints)
  - [SET_VAR Hint](#set_var-hint)
- [Invisible Indexes](#invisible-indexes)
  - [Testing Index Removal Safely](#testing-index-removal-safely)
  - [Staged Index Rollout](#staged-index-rollout)
- [Histogram Statistics](#histogram-statistics)
  - [Creating Histograms](#creating-histograms)
  - [When Histograms Help](#when-histograms-help)
  - [Singleton vs Equi-Height](#singleton-vs-equi-height)
  - [Monitoring Histogram Usage](#monitoring-histogram-usage)

---

## InnoDB Internals

### Clustered Index Architecture

InnoDB stores data in a B+tree organized by the primary key (clustered index). Every secondary index leaf node stores the primary key value, not a row pointer. This means:

- **PK lookups are fastest**: a single B+tree traversal reaches the row.
- **Secondary index lookups require a double traversal**: secondary index → PK value → clustered index.
- **Wide PKs bloat every secondary index**. A `CHAR(36)` UUID PK adds 36 bytes to every secondary index entry. Use `BINARY(16)` or auto-increment.

```sql
-- Measure secondary index overhead from wide PKs
SELECT
  TABLE_NAME,
  INDEX_NAME,
  STAT_VALUE * @@innodb_page_size AS size_bytes
FROM mysql.innodb_index_stats
WHERE stat_name = 'size'
  AND database_name = 'mydb'
ORDER BY size_bytes DESC;
```

**Random vs sequential PKs**: Auto-increment inserts append to the end of the B+tree (fast, minimal page splits). UUID PKs insert randomly, causing page splits, fragmentation, and ~2-3x slower inserts. If UUIDs are required, use `UUID_TO_BIN(UUID(), 1)` (MySQL 8.0+) which reorders the time component for sequential behavior.

```sql
-- UUID v1 with time-reordering for sequential inserts
CREATE TABLE entities (
  id BINARY(16) PRIMARY KEY DEFAULT (UUID_TO_BIN(UUID(), 1)),
  name VARCHAR(255)
);
```

### MVCC and Undo Logs

InnoDB implements Multi-Version Concurrency Control (MVCC) via undo logs. Each row has hidden `DB_TRX_ID` and `DB_ROLL_PTR` columns. Read views use undo logs to reconstruct old row versions.

**Long-running transactions are dangerous**: They prevent undo log purging, causing the undo tablespace (History List Length) to grow unboundedly. This slows all queries as they must traverse longer version chains.

```sql
-- Monitor History List Length (should be < 100000)
SHOW ENGINE INNODB STATUS\G
-- Look for: History list length

-- Find long-running transactions
SELECT trx_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_seconds,
       trx_rows_modified, trx_tables_in_use
FROM information_schema.INNODB_TRX
ORDER BY trx_started ASC;
```

**Tuning undo purging**:

```ini
# Increase purge threads for write-heavy workloads
innodb_purge_threads = 4
# More aggressive purge batching
innodb_purge_batch_size = 300
```

### Change Buffer

The change buffer caches changes to secondary index pages that are not in the buffer pool. When the page is later read, changes are merged. This dramatically reduces random I/O for write-heavy workloads with many secondary indexes.

```ini
# Control what operations use the change buffer
# Options: none, inserts, deletes, changes, purges, all
innodb_change_buffering = all

# Limit change buffer to 25% of buffer pool (default)
innodb_change_buffer_max_size = 25
```

**When to disable**: If your workload is read-heavy or all indexes fit in the buffer pool, the change buffer adds overhead without benefit. Set `innodb_change_buffering = none`.

```sql
-- Monitor change buffer usage
SELECT NAME, COUNT FROM information_schema.INNODB_METRICS
WHERE NAME LIKE 'ibuf%';
```

### Adaptive Hash Index

InnoDB automatically builds hash indexes in memory for frequently accessed B+tree pages. This speeds up point lookups (`=` and `IN`) but NOT range scans.

```ini
# Enabled by default, disable if causing contention
innodb_adaptive_hash_index = ON
# Partition the AHI to reduce mutex contention (MySQL 8.0+)
innodb_adaptive_hash_index_parts = 8
```

**When to disable**: Monitor `SHOW ENGINE INNODB STATUS` — if you see high `btr_search` semaphore waits, the AHI lock is contended. Disable it. Workloads with many range scans or unpredictable access patterns benefit from disabling.

```sql
-- Check AHI hit rate
SELECT
  NAME, COUNT, AVG_COUNT
FROM information_schema.INNODB_METRICS
WHERE NAME IN ('adaptive_hash_searches', 'adaptive_hash_searches_btree');
-- If adaptive_hash_searches_btree is high relative to adaptive_hash_searches,
-- AHI is not helping — consider disabling.
```

### Doublewrite Buffer

InnoDB writes pages to a doublewrite buffer before writing them to their final location, protecting against partial page writes during crashes.

```ini
# MySQL 8.0.20+: configure doublewrite location
innodb_doublewrite_dir = /fast_ssd/doublewrite
innodb_doublewrite_pages = 64
innodb_doublewrite_batch_size = 16
```

**On ZFS or battery-backed RAID with atomic writes**: Disable doublewrite for ~5-10% write throughput improvement:

```ini
innodb_doublewrite = OFF
```

Only disable if your storage guarantees atomic 16KB writes.

### Redo Log Tuning

The redo log (WAL) records all modifications before they're flushed to data files. Size directly affects checkpoint frequency and write throughput.

```ini
# MySQL 8.0.30+: dynamic redo log sizing
innodb_redo_log_capacity = 8G  # replaces innodb_log_file_size / innodb_log_files_in_group

# Pre-8.0.30:
innodb_log_file_size = 2G
innodb_log_files_in_group = 2
```

**Sizing rule**: The redo log should hold ~1-2 hours of writes. If checkpoint activity is constant (visible in `SHOW ENGINE INNODB STATUS` as "Log sequence number" advancing rapidly toward "Last checkpoint at"), increase redo log size.

```sql
-- Calculate redo log write rate (bytes/second)
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_os_log_written') AS bytes_written,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Uptime') AS uptime_seconds;
-- redo_per_hour = bytes_written / uptime_seconds * 3600
-- Set innodb_redo_log_capacity to 1-2x redo_per_hour
```

---

## Partitioning Strategies

### Range Partitioning

Best for time-series data, log tables, and any table with a natural time-based retention policy.

```sql
-- Partition by month using RANGE with TO_DAYS for DATE columns
CREATE TABLE events (
  id BIGINT UNSIGNED AUTO_INCREMENT,
  event_type VARCHAR(50),
  payload JSON,
  created_at DATE NOT NULL,
  PRIMARY KEY (id, created_at),
  KEY idx_type (event_type, created_at)
) PARTITION BY RANGE (TO_DAYS(created_at)) (
  PARTITION p202401 VALUES LESS THAN (TO_DAYS('2024-02-01')),
  PARTITION p202402 VALUES LESS THAN (TO_DAYS('2024-03-01')),
  PARTITION p202403 VALUES LESS THAN (TO_DAYS('2024-04-01')),
  PARTITION p_future VALUES LESS THAN MAXVALUE
);
```

**Critical rule**: The partition key MUST be part of every unique key (including PRIMARY KEY). This is a MySQL requirement.

### Hash Partitioning

Distributes rows evenly across partitions. Useful for distributing hot-spot writes but does NOT support partition pruning for range queries.

```sql
-- Hash partition for even write distribution
CREATE TABLE sessions (
  id BINARY(16) PRIMARY KEY,
  user_id INT UNSIGNED,
  data JSON,
  expires_at TIMESTAMP
) PARTITION BY KEY(id) PARTITIONS 16;
```

Use `KEY` partitioning (MySQL-specific hash) for non-integer columns. Use `HASH` for integer columns.

### List Partitioning

For discrete, known value sets like regions or statuses:

```sql
CREATE TABLE orders (
  id BIGINT UNSIGNED AUTO_INCREMENT,
  region VARCHAR(10) NOT NULL,
  total DECIMAL(10,2),
  created_at DATETIME,
  PRIMARY KEY (id, region)
) PARTITION BY LIST COLUMNS(region) (
  PARTITION p_us VALUES IN ('us-east', 'us-west'),
  PARTITION p_eu VALUES IN ('eu-west', 'eu-central'),
  PARTITION p_ap VALUES IN ('ap-south', 'ap-east')
);
```

### Subpartitioning

Combine range + hash for large datasets needing both time-based pruning and write distribution:

```sql
CREATE TABLE metrics (
  id BIGINT UNSIGNED AUTO_INCREMENT,
  sensor_id INT UNSIGNED NOT NULL,
  value DOUBLE,
  recorded_at DATE NOT NULL,
  PRIMARY KEY (id, recorded_at, sensor_id)
) PARTITION BY RANGE (TO_DAYS(recorded_at))
  SUBPARTITION BY HASH(sensor_id)
  SUBPARTITIONS 8 (
    PARTITION p202401 VALUES LESS THAN (TO_DAYS('2024-02-01')),
    PARTITION p202402 VALUES LESS THAN (TO_DAYS('2024-03-01')),
    PARTITION p_future VALUES LESS THAN MAXVALUE
);
```

### Partition Maintenance

```sql
-- Add a new partition (split the catch-all)
ALTER TABLE events REORGANIZE PARTITION p_future INTO (
  PARTITION p202404 VALUES LESS THAN (TO_DAYS('2024-05-01')),
  PARTITION p_future VALUES LESS THAN MAXVALUE
);

-- Drop old data instantly (much faster than DELETE)
ALTER TABLE events DROP PARTITION p202401;

-- Rebuild fragmented partitions
ALTER TABLE events REBUILD PARTITION p202402, p202403;

-- Analyze partition statistics
ALTER TABLE events ANALYZE PARTITION p202403;
```

### Partition Pruning Verification

```sql
-- Verify pruning works — 'partitions' column should show specific partitions
EXPLAIN SELECT * FROM events WHERE created_at = '2024-03-15';
-- Good: partitions: p202403
-- Bad:  partitions: p202401,p202402,p202403,p_future (no pruning)
```

Pruning fails if: the partition key has a function applied, the WHERE clause uses OR across partitions with non-partition columns, or a JOIN prevents the optimizer from pushing down the predicate.

---

## JSON Column Optimization

### Functional Indexes on JSON

MySQL 8.0.13+ supports indexes on expressions, ideal for JSON fields:

```sql
-- Index a top-level JSON key
ALTER TABLE products
  ADD INDEX idx_brand ((CAST(attributes->>'$.brand' AS CHAR(100) COLLATE utf8mb4_bin)));

-- Index a nested numeric value
ALTER TABLE products
  ADD INDEX idx_weight ((CAST(attributes->>'$.specs.weight_kg' AS DECIMAL(8,2))));
```

Use `->>` (unquoting extraction) not `->` in functional indexes.

### Generated Columns from JSON

For complex or frequently accessed JSON paths, use stored generated columns:

```sql
ALTER TABLE products
  ADD COLUMN brand VARCHAR(100) GENERATED ALWAYS AS (attributes->>'$.brand') STORED,
  ADD INDEX idx_brand (brand);
```

**STORED vs VIRTUAL**: STORED columns are materialized on disk and can be indexed. VIRTUAL columns are computed on read and can only be indexed in InnoDB (with restrictions). Prefer STORED for indexed columns.

### Multi-Valued Indexes

MySQL 8.0.17+ supports indexes on JSON arrays — critical for tag/category searches:

```sql
-- JSON array: {"tags": ["electronics", "sale", "featured"]}
ALTER TABLE products
  ADD INDEX idx_tags ((CAST(attributes->'$.tags' AS UNSIGNED ARRAY)));

-- Query using MEMBER OF
SELECT * FROM products WHERE 'sale' MEMBER OF(attributes->'$.tags');

-- Query using JSON_OVERLAPS (any match)
SELECT * FROM products
WHERE JSON_OVERLAPS(attributes->'$.tags', CAST('["sale","featured"]' AS JSON));
```

### JSON vs Normalized Columns

| Scenario | Use JSON | Use Columns |
|----------|----------|-------------|
| Schema varies per row | ✅ | ❌ |
| Frequent filtering/sorting | ❌ | ✅ |
| Nested structures | ✅ | ❌ (complex JOINs) |
| Need referential integrity | ❌ | ✅ |
| High-write, low-read metadata | ✅ | ❌ |
| Reporting / analytics queries | ❌ | ✅ |

### JSON Partial Updates

MySQL 8.0+ can perform in-place updates to JSON documents when using `JSON_SET`, `JSON_REPLACE`, or `JSON_REMOVE`, IF the replacement is not larger than the original. This avoids rewriting the entire document.

```sql
-- Partial update (in-place, fast)
UPDATE products SET attributes = JSON_SET(attributes, '$.price', 29.99)
WHERE id = 42;

-- Full rewrite (slower — new value expands the document)
UPDATE products SET attributes = JSON_SET(attributes, '$.description', REPEAT('x', 10000))
WHERE id = 42;
```

Enable binary log optimization for JSON:

```ini
binlog_row_value_options = PARTIAL_JSON
```

---

## Window Functions Performance

### Window Function Execution Model

MySQL materializes the intermediate result set before applying window functions. The window function then scans the materialized set. This means:

1. All rows matching WHERE/JOIN are first resolved.
2. The result is sorted by PARTITION BY + ORDER BY.
3. The window function computes over the sorted result.

**Performance implications**: The cost is dominated by the materialization and sort, not the window function itself. Reduce input rows with WHERE filters before the window function.

### Optimizing Window Queries

```sql
-- SLOW: window over entire table
SELECT id, amount,
  SUM(amount) OVER (ORDER BY created_at) AS running_total
FROM transactions;

-- FAST: limit rows before windowing
SELECT id, amount,
  SUM(amount) OVER (ORDER BY created_at) AS running_total
FROM transactions
WHERE created_at >= '2024-01-01';

-- Index to support the window sort
ALTER TABLE transactions ADD INDEX idx_created (created_at, amount, id);
```

**Reuse windows** with named WINDOW clauses to avoid redundant sorts:

```sql
SELECT id,
  ROW_NUMBER() OVER w AS rn,
  SUM(amount) OVER w AS running_total,
  AVG(amount) OVER w AS running_avg
FROM transactions
WHERE created_at >= '2024-01-01'
WINDOW w AS (ORDER BY created_at);
```

### Common Window Patterns

**Top-N per group** (replace correlated subquery):

```sql
-- Find top 3 orders per customer
WITH ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY total DESC) AS rn
  FROM orders
)
SELECT * FROM ranked WHERE rn <= 3;

-- Supporting index
ALTER TABLE orders ADD INDEX idx_cust_total (customer_id, total DESC);
```

**Gap detection**:

```sql
SELECT id, created_at,
  LAG(created_at) OVER (ORDER BY created_at) AS prev_at,
  TIMESTAMPDIFF(MINUTE, LAG(created_at) OVER (ORDER BY created_at), created_at) AS gap_minutes
FROM events
HAVING gap_minutes > 60;
```

---

## CTE Optimization

### Materialized vs Merged CTEs

In MySQL 8.0, non-recursive CTEs can be either **merged** (inlined like a view) or **materialized** (computed once, stored in temp table). The optimizer chooses automatically.

```sql
-- Typically MERGED (simple, referenced once)
WITH active_users AS (
  SELECT id, name FROM users WHERE status = 'active'
)
SELECT * FROM active_users WHERE id = 42;
-- Equivalent to: SELECT id, name FROM users WHERE status = 'active' AND id = 42;

-- Typically MATERIALIZED (referenced multiple times)
WITH stats AS (
  SELECT department_id, AVG(salary) AS avg_sal FROM employees GROUP BY department_id
)
SELECT e.name, s.avg_sal
FROM employees e
JOIN stats s ON e.department_id = s.department_id
WHERE e.salary > s.avg_sal;
```

**Force materialization** when the CTE is expensive and referenced multiple times (avoids recomputation). In MySQL 8.0.35+, the optimizer usually gets this right.

### Recursive CTE Performance

Recursive CTEs are always materialized. Performance depends on recursion depth and rows per level.

```sql
-- Hierarchy traversal — index parent_id for performance
WITH RECURSIVE org_tree AS (
  SELECT id, name, manager_id, 0 AS depth
  FROM employees WHERE id = 1  -- root
  UNION ALL
  SELECT e.id, e.name, e.manager_id, ot.depth + 1
  FROM employees e
  JOIN org_tree ot ON e.manager_id = ot.id
  WHERE ot.depth < 10  -- ALWAYS set a depth limit
)
SELECT * FROM org_tree;

-- Critical index
ALTER TABLE employees ADD INDEX idx_manager (manager_id);
```

**Always set a depth limit** in recursive CTEs to prevent infinite recursion from cyclic data.

### CTE Anti-Patterns

```sql
-- ANTI-PATTERN: CTE used once where a subquery or JOIN is simpler
-- The CTE adds syntax overhead without optimization benefit
WITH x AS (SELECT * FROM orders WHERE status = 'pending')
SELECT COUNT(*) FROM x;
-- BETTER:
SELECT COUNT(*) FROM orders WHERE status = 'pending';

-- ANTI-PATTERN: chained CTEs hiding the real query plan
WITH a AS (...), b AS (SELECT ... FROM a), c AS (SELECT ... FROM b)
SELECT * FROM c;
-- Each materialized CTE creates a temp table. If the optimizer can't merge,
-- you get N temp tables with no indexes. Consider rewriting as JOINs.
```

---

## Optimizer Hints

MySQL 8.0 supports query-level optimizer hints using `/*+ ... */` syntax. These override the optimizer's decisions without affecting other queries.

### Index Hints

```sql
-- Force a specific index
SELECT /*+ INDEX(orders idx_status_created) */
  id, total FROM orders WHERE status = 'shipped' AND created_at > '2024-01-01';

-- Prevent an index (if optimizer picks a bad one)
SELECT /*+ NO_INDEX(orders idx_status) */
  id, total FROM orders WHERE status = 'shipped';

-- Force index merge (OR optimization)
SELECT /*+ INDEX_MERGE(products idx_name, idx_category) */
  * FROM products WHERE name = 'Widget' OR category_id = 5;
```

### Join Order Hints

```sql
-- Force join order (optimizer follows the FROM clause order)
SELECT /*+ JOIN_ORDER(c, o, oi) */
  c.name, o.total
FROM customers c
JOIN orders o ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id = o.id
WHERE c.region = 'US';

-- Force a specific join algorithm
SELECT /*+ HASH_JOIN(o, oi) BNL(c) */
  c.name, o.total
FROM customers c
JOIN orders o ON o.customer_id = c.id
JOIN order_items oi ON oi.order_id = o.id;
```

### Subquery Hints

```sql
-- Force subquery to use semi-join strategy
SELECT /*+ SEMIJOIN(@subq MATERIALIZATION) */
  * FROM orders
WHERE customer_id IN (SELECT /*+ QB_NAME(subq) */ id FROM customers WHERE vip = 1);

-- Force subquery to NOT use semi-join (use EXISTS strategy)
SELECT /*+ NO_SEMIJOIN(@subq) */
  * FROM orders
WHERE customer_id IN (SELECT /*+ QB_NAME(subq) */ id FROM customers WHERE vip = 1);
```

### Resource Hints

```sql
-- Limit resources for a query
SELECT /*+ MAX_EXECUTION_TIME(5000) */  -- 5 seconds max
  * FROM large_table WHERE indexed_col = 'value';

-- Control buffer pool usage (don't pollute cache with scan data)
SELECT /*+ SET_VAR(innodb_buffer_pool_dump_pct=0) */
  COUNT(*) FROM huge_reporting_table;
```

### SET_VAR Hint

Temporarily override session variables for a single statement:

```sql
-- Use a larger sort buffer for one complex query
SELECT /*+ SET_VAR(sort_buffer_size=16777216) */
  * FROM orders ORDER BY complex_expression LIMIT 100;

-- Use a different optimizer switch for one query
SELECT /*+ SET_VAR(optimizer_switch='index_merge=off') */
  * FROM products WHERE name = 'x' OR category_id = 5;
```

---

## Invisible Indexes

### Testing Index Removal Safely

Invisible indexes exist on disk and are maintained on writes, but the optimizer ignores them. This lets you test the impact of dropping an index without actually dropping it.

```sql
-- Make an index invisible (instant, no rebuild)
ALTER TABLE orders ALTER INDEX idx_old_status INVISIBLE;

-- Monitor query performance — if no degradation after 24-48 hours, drop it
ALTER TABLE orders DROP INDEX idx_old_status;

-- If performance degrades, make it visible again (instant)
ALTER TABLE orders ALTER INDEX idx_old_status VISIBLE;
```

### Staged Index Rollout

Use invisible indexes to build an index without affecting the query plan, then enable it during a maintenance window:

```sql
-- Build during off-peak (takes time but doesn't affect queries)
ALTER TABLE orders ADD INDEX idx_new_composite (status, region, created_at) INVISIBLE;

-- Enable when ready
ALTER TABLE orders ALTER INDEX idx_new_composite VISIBLE;
```

**Testing a specific query against an invisible index**:

```sql
-- Session-level override to see invisible indexes
SET SESSION optimizer_switch = 'use_invisible_indexes=on';
EXPLAIN SELECT * FROM orders WHERE status = 'shipped' AND region = 'US';
SET SESSION optimizer_switch = 'use_invisible_indexes=off';
```

---

## Histogram Statistics

### Creating Histograms

Histograms help the optimizer estimate row counts for columns without indexes. They're ideal for low-cardinality columns used in WHERE clauses.

```sql
-- Create a histogram with 100 buckets (default)
ANALYZE TABLE orders UPDATE HISTOGRAM ON status, region WITH 100 BUCKETS;

-- Drop a histogram
ANALYZE TABLE orders DROP HISTOGRAM ON status;
```

### When Histograms Help

- Columns with skewed data distribution (e.g., `status` where 95% are 'completed').
- Columns used in WHERE but not worth indexing (low selectivity, rarely filtered alone).
- Columns involved in JOIN cardinality estimation.
- After data distribution changes significantly (re-run ANALYZE).

### Singleton vs Equi-Height

MySQL chooses automatically:
- **Singleton**: One bucket per distinct value. Used when distinct values ≤ bucket count. Gives exact frequency.
- **Equi-height**: Values grouped into buckets of roughly equal cumulative frequency. Used for high-cardinality columns.

```sql
-- View histogram details
SELECT SCHEMA_NAME, TABLE_NAME, COLUMN_NAME,
       JSON_EXTRACT(HISTOGRAM, '$.\"histogram-type\"') AS type,
       JSON_EXTRACT(HISTOGRAM, '$.\"number-of-buckets-specified\"') AS buckets
FROM information_schema.COLUMN_STATISTICS
WHERE TABLE_NAME = 'orders';
```

### Monitoring Histogram Usage

```sql
-- Check if optimizer is using histograms (look for "histogram" in EXPLAIN)
EXPLAIN FORMAT=JSON SELECT * FROM orders WHERE status = 'pending' AND region = 'US';
-- In the JSON output, look for "filtering_effect" entries mentioning histogram

-- Verify histograms are up to date (compare with actual distribution)
SELECT status, COUNT(*) AS actual_count,
       COUNT(*) * 100.0 / SUM(COUNT(*)) OVER() AS actual_pct
FROM orders GROUP BY status;
```

Refresh histograms after major data changes (bulk loads, mass deletes):

```sql
ANALYZE TABLE orders UPDATE HISTOGRAM ON status, region WITH 100 BUCKETS;
```
