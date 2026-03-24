---
name: mysql-tuning
description: >
  MySQL and InnoDB performance tuning, query optimization, and production configuration.
  Use when: MySQL slow queries, MySQL performance issues, InnoDB tuning, MySQL indexing strategy,
  query optimization with EXPLAIN, MySQL configuration variables, slow query log analysis,
  MySQL replication tuning, MySQL connection pooling, MySQL schema optimization, MySQL buffer pool,
  MySQL thread management, MySQL anti-patterns, my.cnf tuning, mysqldumpslow, pt-query-digest.
  Do NOT use when: PostgreSQL tuning, MongoDB performance, Redis optimization, general SQL syntax
  questions, database design unrelated to MySQL, SQLite issues, MariaDB-specific features,
  NoSQL databases, or application-level caching strategies not involving MySQL.
---

# MySQL Performance Tuning

## InnoDB Buffer Pool

Set `innodb_buffer_pool_size` to 60–80% of total RAM on dedicated MySQL servers. This is the single most impactful variable.

```ini
# 64GB RAM dedicated server
innodb_buffer_pool_size = 48G
innodb_buffer_pool_instances = 16
innodb_buffer_pool_chunk_size = 256M
```

Check buffer pool hit ratio — target >99%:

```sql
SELECT
  (1 - (Innodb_buffer_pool_reads / Innodb_buffer_pool_read_requests)) * 100
  AS hit_ratio
FROM (
  SELECT
    VARIABLE_VALUE AS Innodb_buffer_pool_reads
  FROM performance_schema.global_status
  WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads'
) r,
(
  SELECT
    VARIABLE_VALUE AS Innodb_buffer_pool_read_requests
  FROM performance_schema.global_status
  WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests'
) rr;
```

If hit ratio < 99%, increase buffer pool size. If already at 80% RAM, investigate query patterns pulling excessive data.

Set `innodb_buffer_pool_instances` to 8–16 for pools > 1GB to reduce mutex contention. Ensure `innodb_buffer_pool_size` is evenly divisible by instances × chunk_size.

Enable `innodb_buffer_pool_dump_at_shutdown = ON` and `innodb_buffer_pool_load_at_startup = ON` to warm the pool after restarts.

## Query Optimization and EXPLAIN

Always prefix suspect queries with `EXPLAIN` or `EXPLAIN ANALYZE` (MySQL 8.0.18+):

```sql
EXPLAIN ANALYZE
SELECT o.id, o.total, c.name
FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE o.created_at > '2024-01-01'
  AND o.status = 'completed'
ORDER BY o.created_at DESC
LIMIT 100;
```

**Key EXPLAIN columns to inspect:**

| Column | Red flag | Action |
|--------|----------|--------|
| type | ALL (full table scan) | Add index on WHERE/JOIN columns |
| type | index (full index scan) | Narrow scan with composite index |
| rows | High relative to result | Index missing or non-selective |
| Extra | Using filesort | Add index matching ORDER BY |
| Extra | Using temporary | Rewrite query or add covering index |
| key | NULL | No usable index found — create one |

**Rewrite anti-patterns:**

```sql
-- BAD: function on indexed column prevents index use
SELECT * FROM users WHERE YEAR(created_at) = 2024;

-- GOOD: range scan uses index
SELECT * FROM users
WHERE created_at >= '2024-01-01' AND created_at < '2025-01-01';

-- BAD: SELECT * pulls unnecessary data
SELECT * FROM orders WHERE customer_id = 42;

-- GOOD: select only needed columns, enables covering index
SELECT id, total, status FROM orders WHERE customer_id = 42;

-- BAD: OR on different columns defeats index
SELECT * FROM products WHERE name = 'Widget' OR category_id = 5;

-- GOOD: UNION ALL uses separate indexes
SELECT * FROM products WHERE name = 'Widget'
UNION ALL
SELECT * FROM products WHERE category_id = 5 AND name != 'Widget';
```

## Index Strategies

### Composite Indexes

Order columns by: equality filters first, then range filters, then ORDER BY/GROUP BY (the "ERO" rule).

```sql
-- Query pattern
SELECT id, total FROM orders
WHERE status = 'shipped' AND customer_id = 42
AND created_at > '2024-01-01'
ORDER BY created_at DESC;

-- Optimal composite index: equality(status, customer_id), range+sort(created_at)
ALTER TABLE orders ADD INDEX idx_status_cust_created
  (status, customer_id, created_at);
```

### Covering Indexes

Include all columns referenced in SELECT, WHERE, ORDER BY so the query never touches the table:

```sql
-- Covering index for the query above
ALTER TABLE orders ADD INDEX idx_covering
  (status, customer_id, created_at, id, total);

-- EXPLAIN will show "Using index" in Extra — no table lookup
```

### Prefix Indexes

Use on long VARCHAR/TEXT columns to reduce index size:

```sql
-- Index first 20 chars of email (check selectivity first)
SELECT COUNT(DISTINCT LEFT(email, 20)) / COUNT(*) FROM users;
-- If > 0.95, prefix length 20 is selective enough
ALTER TABLE users ADD INDEX idx_email_prefix (email(20));
```

### Index Maintenance

Detect unused indexes:

```sql
SELECT s.TABLE_SCHEMA, s.TABLE_NAME, s.INDEX_NAME,
       s.SEQ_IN_INDEX, s.COLUMN_NAME
FROM information_schema.STATISTICS s
LEFT JOIN performance_schema.table_io_waits_summary_by_index_usage w
  ON s.TABLE_SCHEMA = w.OBJECT_SCHEMA
  AND s.TABLE_NAME = w.OBJECT_NAME
  AND s.INDEX_NAME = w.INDEX_NAME
WHERE w.COUNT_READ = 0
  AND s.INDEX_NAME != 'PRIMARY'
  AND s.TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema');
```

Detect duplicate indexes:

```sql
SELECT TABLE_SCHEMA, TABLE_NAME, GROUP_CONCAT(INDEX_NAME) AS duplicate_indexes,
       GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS index_columns
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema')
GROUP BY TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME
HAVING COUNT(*) > 1;
```

Drop unused and duplicate indexes — they slow writes and waste memory.

## Slow Query Log Analysis

Enable and configure the slow query log:

```ini
slow_query_log = ON
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 0.5
log_queries_not_using_indexes = ON
log_slow_admin_statements = ON
min_examined_row_limit = 100
```

Analyze with `pt-query-digest` (preferred) or `mysqldumpslow`:

```bash
# Top 10 worst queries by total time
pt-query-digest /var/log/mysql/slow.log --limit=10

# Filter by database
pt-query-digest /var/log/mysql/slow.log --filter '$event->{db} eq "myapp"'

# Quick summary with built-in tool
mysqldumpslow -s t -t 10 /var/log/mysql/slow.log
```

Key metrics from pt-query-digest output:
- **Response time**: total and per-call — prioritize highest total time
- **Rows examined vs rows sent**: ratio > 10:1 signals missing index
- **Lock time**: high values indicate contention — check table locks or row locks

## Connection Pooling and Thread Management

### Key Variables

```ini
max_connections = 300
thread_cache_size = 128
wait_timeout = 600
interactive_timeout = 600
max_connect_errors = 1000000
```

### Sizing max_connections

Calculate based on app pool sizes: `max_connections ≥ (app_servers × pool_size) + admin_reserve + replication_threads`.

Monitor actual usage:

```sql
SHOW GLOBAL STATUS LIKE 'Max_used_connections';
SHOW GLOBAL STATUS LIKE 'Threads_connected';
SHOW GLOBAL STATUS LIKE 'Threads_created';
-- If Threads_created/Uptime > 1, increase thread_cache_size
```

### Connection Pooling with ProxySQL

Use ProxySQL or application-level pools (HikariCP, pgbouncer equivalent). Set app pool min/max sizes conservatively. Avoid per-request connections.

```ini
# ProxySQL example — connection multiplexing
mysql_variables = {
  max_connections = 2048
  default_query_timeout = 30000
  multiplexing = true
}
```

### Per-Connection Memory

Each connection allocates: `sort_buffer_size + read_buffer_size + read_rnd_buffer_size + join_buffer_size + thread_stack`. Keep these at defaults unless EXPLAIN shows specific needs. Increasing globally wastes RAM across idle connections.

```sql
-- Check per-connection memory risk
SELECT @@max_connections *
  (@@read_buffer_size + @@read_rnd_buffer_size +
   @@sort_buffer_size + @@join_buffer_size + @@thread_stack)
  / 1024 / 1024 / 1024 AS max_connection_memory_gb;
```

## Replication Tuning

### Source (Primary) Settings

```ini
binlog_format = ROW
sync_binlog = 1
innodb_flush_log_at_trx_commit = 1
binlog_row_image = MINIMAL
expire_logs_days = 7
```

### Replica Settings

```ini
# Parallel replication (MySQL 8.0+)
replica_parallel_workers = 8
replica_parallel_type = LOGICAL_CLOCK
replica_preserve_commit_order = ON

# Reduce replica disk I/O
innodb_flush_log_at_trx_commit = 2
sync_binlog = 0
log_replica_updates = ON
```

Monitor replication lag:

```sql
SHOW REPLICA STATUS\G
-- Check: Seconds_Behind_Source, Relay_Log_Space, Retrieved_Gtid_Set vs Executed_Gtid_Set
```

If lag persists: increase `replica_parallel_workers`, verify network bandwidth, check for long-running transactions on source.

## Schema Optimization

### Data Type Selection

Use the smallest sufficient data type. Every byte matters at scale.

| Instead of | Use | Savings |
|-----------|-----|---------|
| BIGINT for IDs < 4B | INT UNSIGNED | 4 bytes/row |
| VARCHAR(255) default | VARCHAR(actual_max) | Memory allocation |
| DATETIME | TIMESTAMP | 4 bytes vs 8 bytes |
| CHAR(36) for UUIDs | BINARY(16) | 20 bytes/row |
| TEXT for short strings | VARCHAR(N) | Avoids off-page storage |
| ENUM for booleans | TINYINT(1) | More flexible |
| FLOAT/DOUBLE for money | DECIMAL(10,2) | Precision |

### Partitioning

Use range partitioning for time-series data with large tables (>50M rows):

```sql
ALTER TABLE events PARTITION BY RANGE (YEAR(created_at)) (
  PARTITION p2022 VALUES LESS THAN (2023),
  PARTITION p2023 VALUES LESS THAN (2024),
  PARTITION p2024 VALUES LESS THAN (2025),
  PARTITION pmax VALUES LESS THAN MAXVALUE
);
```

Partition pruning only works when the partition key is in the WHERE clause. Verify with EXPLAIN showing `partitions: p2024` not `partitions: all`.

### Normalization vs Denormalization

Normalize to 3NF by default. Denormalize only with measured evidence of join bottlenecks. When denormalizing, use triggers or application logic to maintain consistency.

## Key MySQL Variables Reference

### Critical (tune first)

```ini
innodb_buffer_pool_size = <60-80% RAM>
innodb_log_file_size = <25-50% of buffer pool, 1G-4G typical>
innodb_flush_log_at_trx_commit = 1  # 2 for speed, 1 for safety
max_connections = <based on workload>
innodb_io_capacity = 2000           # SSD: 2000-10000, HDD: 200
innodb_io_capacity_max = 4000       # 2x innodb_io_capacity
```

### Important (tune second)

```ini
innodb_log_buffer_size = 64M        # 64-256M for write-heavy
innodb_write_io_threads = 8         # match CPU cores
innodb_read_io_threads = 8          # match CPU cores
innodb_flush_method = O_DIRECT      # avoid double buffering on Linux
innodb_file_per_table = ON          # always
table_open_cache = 4096             # increase if Opened_tables grows
table_definition_cache = 2048
tmp_table_size = 256M               # match max_heap_table_size
max_heap_table_size = 256M
```

### Deprecated/Removed in MySQL 8.0+

Do NOT set these:
- `query_cache_size` / `query_cache_type` — removed in 8.0
- `innodb_file_format` — removed in 8.0
- `innodb_large_prefix` — removed, always ON in 8.0

## Common Anti-Patterns and Fixes

### 1. N+1 Query Pattern

```sql
-- BAD: loop executes 1000 individual queries
-- App code: for each order, SELECT * FROM items WHERE order_id = ?

-- FIX: batch with IN or JOIN
SELECT i.* FROM items i
JOIN orders o ON o.id = i.order_id
WHERE o.customer_id = 42;
```

### 2. Missing LIMIT on exploratory queries

```sql
-- BAD: returns millions of rows
SELECT * FROM logs WHERE level = 'ERROR';

-- FIX: always LIMIT, paginate with keyset
SELECT * FROM logs WHERE level = 'ERROR' AND id > :last_seen_id
ORDER BY id LIMIT 100;
```

### 3. Implicit type conversion

```sql
-- BAD: phone is VARCHAR, but compared to INT — full scan
SELECT * FROM users WHERE phone = 5551234;

-- FIX: match types
SELECT * FROM users WHERE phone = '5551234';
```

### 4. Unbounded IN clauses

```sql
-- BAD: IN with 10000+ values
SELECT * FROM products WHERE id IN (1, 2, 3, ... 10000);

-- FIX: use temp table or JOIN
CREATE TEMPORARY TABLE tmp_ids (id INT PRIMARY KEY);
INSERT INTO tmp_ids VALUES (1), (2), ... ;
SELECT p.* FROM products p JOIN tmp_ids t ON p.id = t.id;
```

### 5. Missing WHERE on UPDATE/DELETE

Always use transactions and verify row count before COMMIT:

```sql
START TRANSACTION;
DELETE FROM orders WHERE status = 'cancelled' AND created_at < '2023-01-01';
-- Check affected rows. If unexpected, ROLLBACK.
SELECT ROW_COUNT();
COMMIT;
```

## Diagnostic Queries Cheat Sheet

```sql
-- Current running queries (kill long-runners)
SELECT ID, USER, HOST, DB, TIME, STATE, INFO
FROM information_schema.PROCESSLIST
WHERE COMMAND != 'Sleep' AND TIME > 5
ORDER BY TIME DESC;

-- Table sizes (find bloat)
SELECT TABLE_NAME,
  ROUND(DATA_LENGTH / 1024 / 1024) AS data_mb,
  ROUND(INDEX_LENGTH / 1024 / 1024) AS index_mb,
  TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'mydb'
ORDER BY DATA_LENGTH DESC LIMIT 20;

-- InnoDB status snapshot
SHOW ENGINE INNODB STATUS\G

-- Check for table lock contention
SHOW GLOBAL STATUS LIKE 'Table_locks%';

-- Temp tables going to disk (increase tmp_table_size if high)
SHOW GLOBAL STATUS LIKE 'Created_tmp_disk_tables';
SHOW GLOBAL STATUS LIKE 'Created_tmp_tables';
```

## Production Checklist

1. Set `innodb_buffer_pool_size` to 60-80% RAM and verify >99% hit ratio
2. Enable slow query log with `long_query_time = 0.5`
3. Run `pt-query-digest` weekly on slow log
4. Audit indexes: drop unused, add missing per EXPLAIN
5. Set `innodb_flush_log_at_trx_commit` based on durability needs
6. Configure connection pooling at app layer (HikariCP, ProxySQL)
7. Size `max_connections` from real `Max_used_connections` + 20% headroom
8. Set `innodb_io_capacity` matching storage IOPS
9. Enable `performance_schema` for ongoing monitoring
10. Use `innodb_dedicated_server = ON` on MySQL 8.0.14+ dedicated hosts
