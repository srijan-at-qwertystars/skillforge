# MySQL Performance Schema & sys Schema Guide

## Table of Contents

- [Performance Schema Overview](#performance-schema-overview)
  - [Enabling and Configuring](#enabling-and-configuring)
  - [Architecture and Consumers](#architecture-and-consumers)
  - [Memory Overhead](#memory-overhead)
- [Key Tables Reference](#key-tables-reference)
  - [Statement Tables](#statement-tables)
  - [Wait Tables](#wait-tables)
  - [Stage Tables](#stage-tables)
  - [Transaction Tables](#transaction-tables)
  - [Lock Tables](#lock-tables)
  - [Memory Tables](#memory-tables)
  - [File I/O Tables](#file-io-tables)
  - [Replication Tables](#replication-tables)
- [Finding Bottlenecks](#finding-bottlenecks)
  - [Top Queries by Total Time](#top-queries-by-total-time)
  - [Top Queries by Rows Examined](#top-queries-by-rows-examined)
  - [Top Queries by Temp Tables](#top-queries-by-temp-tables)
  - [Full Table Scan Detection](#full-table-scan-detection)
  - [Index Usage Analysis](#index-usage-analysis)
  - [Table Access Patterns](#table-access-patterns)
- [Wait Analysis](#wait-analysis)
  - [Top Wait Events](#top-wait-events)
  - [I/O Wait Breakdown](#io-wait-breakdown)
  - [Lock Wait Analysis](#lock-wait-analysis)
  - [Mutex and RWLock Contention](#mutex-and-rwlock-contention)
- [Statement Analysis](#statement-analysis)
  - [Statement Digest Summary](#statement-digest-summary)
  - [Slow Query Identification](#slow-query-identification)
  - [Error Summary](#error-summary)
  - [Prepared Statement Analysis](#prepared-statement-analysis)
- [Memory Tracking](#memory-tracking)
  - [Global Memory by Component](#global-memory-by-component)
  - [Per-Thread Memory](#per-thread-memory)
  - [Memory Leak Detection](#memory-leak-detection)
  - [Buffer Pool Internals](#buffer-pool-internals)
- [sys Schema Shortcuts](#sys-schema-shortcuts)
  - [Statement Analysis Views](#statement-analysis-views)
  - [Host and User Summary](#host-and-user-summary)
  - [Schema Analysis](#schema-analysis)
  - [I/O Analysis](#io-analysis)
  - [Wait Analysis Views](#wait-analysis-views)
  - [Useful Procedures](#useful-procedures)

---

## Performance Schema Overview

### Enabling and Configuring

Performance Schema is enabled by default in MySQL 8.0. Verify:

```sql
SHOW VARIABLES LIKE 'performance_schema';
-- Should show ON
```

To enable at startup (cannot be changed at runtime):

```ini
[mysqld]
performance_schema = ON
```

Enable specific instruments and consumers at runtime:

```sql
-- Enable all statement instruments
UPDATE performance_schema.setup_instruments
SET ENABLED = 'YES', TIMED = 'YES'
WHERE NAME LIKE 'statement/%';

-- Enable all wait instruments
UPDATE performance_schema.setup_instruments
SET ENABLED = 'YES', TIMED = 'YES'
WHERE NAME LIKE 'wait/%';

-- Enable all memory instruments
UPDATE performance_schema.setup_instruments
SET ENABLED = 'YES'
WHERE NAME LIKE 'memory/%';

-- Enable consumers for current and history tables
UPDATE performance_schema.setup_consumers
SET ENABLED = 'YES'
WHERE NAME IN (
  'events_statements_current',
  'events_statements_history',
  'events_statements_history_long',
  'events_waits_current',
  'events_waits_history',
  'events_waits_history_long',
  'events_stages_current',
  'events_stages_history'
);
```

### Architecture and Consumers

Performance Schema uses a producer-consumer model:

- **Instruments** (producers): Code points that generate events (e.g., `statement/sql/select`, `wait/io/file/innodb/innodb_data_file`).
- **Consumers** (storage): Tables that store collected events.

Consumer hierarchy (enabling a parent enables its children):

```
global_instrumentation
  └── thread_instrumentation
       ├── events_waits_current
       │    ├── events_waits_history
       │    └── events_waits_history_long
       ├── events_stages_current
       │    ├── events_stages_history
       │    └── events_stages_history_long
       ├── events_statements_current
       │    ├── events_statements_history
       │    └── events_statements_history_long
       └── events_transactions_current
            ├── events_transactions_history
            └── events_transactions_history_long
```

### Memory Overhead

Performance Schema memory is pre-allocated at startup. Typical overhead: 200-400MB.

```sql
-- Check Performance Schema memory usage
SELECT * FROM sys.memory_global_by_current_bytes
WHERE event_name LIKE 'memory/performance_schema/%'
ORDER BY current_alloc DESC;
```

To reduce overhead, disable unused instruments:

```sql
-- Disable wait instruments if not debugging waits
UPDATE performance_schema.setup_instruments
SET ENABLED = 'NO'
WHERE NAME LIKE 'wait/synch/%';
```

---

## Key Tables Reference

### Statement Tables

| Table | Purpose | Use When |
|-------|---------|----------|
| `events_statements_current` | Currently executing statements | Real-time monitoring |
| `events_statements_history` | Last 10 statements per thread | Recent query debugging |
| `events_statements_history_long` | Last 10000 statements globally | Post-mortem analysis |
| `events_statements_summary_by_digest` | Aggregated stats per query pattern | Top-N query analysis |
| `events_statements_summary_by_user_by_event_name` | Per-user statement stats | User workload profiling |

### Wait Tables

| Table | Purpose |
|-------|---------|
| `events_waits_current` | Currently active waits |
| `events_waits_summary_global_by_event_name` | Aggregated wait stats |
| `events_waits_summary_by_instance` | Per-instance wait stats (specific files, mutexes) |

### Stage Tables

| Table | Purpose |
|-------|---------|
| `events_stages_current` | Current operation stage (e.g., "Sending data") |
| `events_stages_history` | Recent stages per thread |
| `events_stages_summary_global_by_event_name` | Aggregated stage durations |

### Transaction Tables

| Table | Purpose |
|-------|---------|
| `events_transactions_current` | Active transactions |
| `events_transactions_history` | Recent transactions per thread |
| `events_transactions_summary_global_by_event_name` | Transaction duration stats |

### Lock Tables

| Table | Purpose |
|-------|---------|
| `data_locks` | All current InnoDB data locks |
| `data_lock_waits` | Current lock wait relationships |
| `metadata_locks` | Current metadata (DDL) locks |
| `table_handles` | Currently open table handles and their locks |

### Memory Tables

| Table | Purpose |
|-------|---------|
| `memory_summary_global_by_event_name` | Memory by component |
| `memory_summary_by_thread_by_event_name` | Memory by thread |
| `memory_summary_by_account_by_event_name` | Memory by user@host |

### File I/O Tables

| Table | Purpose |
|-------|---------|
| `file_summary_by_event_name` | I/O stats by event type |
| `file_summary_by_instance` | I/O stats by specific file |

### Replication Tables

| Table | Purpose |
|-------|---------|
| `replication_connection_status` | Connection to source |
| `replication_applier_status` | Applier thread status |
| `replication_applier_status_by_worker` | Per-worker apply stats |

---

## Finding Bottlenecks

### Top Queries by Total Time

```sql
-- Top 10 queries consuming the most total time
SELECT
  DIGEST_TEXT,
  COUNT_STAR AS exec_count,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_seconds,
  ROUND(AVG_TIMER_WAIT / 1e12, 4) AS avg_seconds,
  ROUND(MAX_TIMER_WAIT / 1e12, 2) AS max_seconds,
  SUM_ROWS_EXAMINED,
  SUM_ROWS_SENT,
  FIRST_SEEN,
  LAST_SEEN
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME = 'mydb'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;
```

### Top Queries by Rows Examined

```sql
-- Queries examining the most rows (index optimization candidates)
SELECT
  DIGEST_TEXT,
  COUNT_STAR AS exec_count,
  SUM_ROWS_EXAMINED,
  SUM_ROWS_SENT,
  ROUND(SUM_ROWS_EXAMINED / NULLIF(SUM_ROWS_SENT, 0)) AS examine_ratio,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_seconds
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME = 'mydb'
  AND SUM_ROWS_SENT > 0
ORDER BY SUM_ROWS_EXAMINED DESC
LIMIT 10;
```

### Top Queries by Temp Tables

```sql
-- Queries creating the most temporary tables on disk
SELECT
  DIGEST_TEXT,
  COUNT_STAR,
  SUM_CREATED_TMP_TABLES AS tmp_tables,
  SUM_CREATED_TMP_DISK_TABLES AS tmp_disk_tables,
  ROUND(SUM_CREATED_TMP_DISK_TABLES / NULLIF(SUM_CREATED_TMP_TABLES, 0) * 100, 1) AS disk_pct,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_seconds
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_CREATED_TMP_DISK_TABLES > 0
ORDER BY SUM_CREATED_TMP_DISK_TABLES DESC
LIMIT 10;
```

### Full Table Scan Detection

```sql
-- Queries performing full table scans (no good index)
SELECT
  DIGEST_TEXT,
  COUNT_STAR,
  SUM_NO_GOOD_INDEX_USED AS no_good_index,
  SUM_NO_INDEX_USED AS no_index_used,
  SUM_ROWS_EXAMINED,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_seconds
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_NO_INDEX_USED > 0 OR SUM_NO_GOOD_INDEX_USED > 0
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;
```

### Index Usage Analysis

```sql
-- Tables with unused indexes (candidates for removal)
SELECT
  OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME,
  COUNT_READ, COUNT_WRITE, COUNT_FETCH,
  COUNT_INSERT, COUNT_UPDATE, COUNT_DELETE
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE OBJECT_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema')
  AND INDEX_NAME IS NOT NULL
  AND COUNT_READ = 0
ORDER BY OBJECT_SCHEMA, OBJECT_NAME;

-- Most used indexes (confirm critical indexes)
SELECT
  OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME,
  COUNT_READ, COUNT_FETCH,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_wait_seconds
FROM performance_schema.table_io_waits_summary_by_index_usage
WHERE OBJECT_SCHEMA = 'mydb'
  AND INDEX_NAME IS NOT NULL
ORDER BY COUNT_READ DESC
LIMIT 20;
```

### Table Access Patterns

```sql
-- Table I/O summary: reads vs writes, latency
SELECT
  OBJECT_SCHEMA, OBJECT_NAME,
  COUNT_READ, COUNT_WRITE,
  ROUND(SUM_TIMER_READ / 1e12, 2) AS read_seconds,
  ROUND(SUM_TIMER_WRITE / 1e12, 2) AS write_seconds,
  ROUND((SUM_TIMER_READ + SUM_TIMER_WRITE) / 1e12, 2) AS total_seconds
FROM performance_schema.table_io_waits_summary_by_table
WHERE OBJECT_SCHEMA = 'mydb'
ORDER BY SUM_TIMER_READ + SUM_TIMER_WRITE DESC
LIMIT 20;
```

---

## Wait Analysis

### Top Wait Events

```sql
-- What is MySQL spending time waiting on?
SELECT
  EVENT_NAME,
  COUNT_STAR,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_seconds,
  ROUND(AVG_TIMER_WAIT / 1e9, 2) AS avg_ms
FROM performance_schema.events_waits_summary_global_by_event_name
WHERE COUNT_STAR > 0
  AND EVENT_NAME NOT LIKE 'idle'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;
```

Common wait categories:
- `wait/io/file/*`: Disk I/O waits (buffer pool reads, redo log writes)
- `wait/synch/mutex/*`: Mutex contention (internal locks)
- `wait/synch/rwlock/*`: Read-write lock contention
- `wait/lock/table/*`: Table-level locks
- `wait/io/socket/*`: Network I/O

### I/O Wait Breakdown

```sql
-- I/O wait by file type
SELECT
  EVENT_NAME,
  COUNT_STAR,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_seconds,
  ROUND(AVG_TIMER_WAIT / 1e6, 2) AS avg_us,
  SUM_NUMBER_OF_BYTES_READ / 1024 / 1024 AS read_mb,
  SUM_NUMBER_OF_BYTES_WRITE / 1024 / 1024 AS write_mb
FROM performance_schema.file_summary_by_event_name
WHERE COUNT_STAR > 0
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

-- I/O wait by specific file (find hot files)
SELECT
  FILE_NAME,
  COUNT_READ, COUNT_WRITE,
  ROUND(SUM_TIMER_READ / 1e12, 2) AS read_seconds,
  ROUND(SUM_TIMER_WRITE / 1e12, 2) AS write_seconds,
  SUM_NUMBER_OF_BYTES_READ / 1024 / 1024 AS read_mb,
  SUM_NUMBER_OF_BYTES_WRITE / 1024 / 1024 AS write_mb
FROM performance_schema.file_summary_by_instance
ORDER BY SUM_TIMER_READ + SUM_TIMER_WRITE DESC
LIMIT 10;
```

### Lock Wait Analysis

```sql
-- Current data lock waits
SELECT
  w.REQUESTING_ENGINE_TRANSACTION_ID AS waiting_trx,
  w.BLOCKING_ENGINE_TRANSACTION_ID AS blocking_trx,
  rl.OBJECT_SCHEMA, rl.OBJECT_NAME,
  rl.LOCK_TYPE, rl.LOCK_MODE AS waiting_lock_mode,
  bl.LOCK_MODE AS blocking_lock_mode,
  rl.LOCK_DATA AS waiting_on_data,
  bl.LOCK_DATA AS blocking_data
FROM performance_schema.data_lock_waits w
JOIN performance_schema.data_locks rl
  ON w.REQUESTING_ENGINE_LOCK_ID = rl.ENGINE_LOCK_ID
JOIN performance_schema.data_locks bl
  ON w.BLOCKING_ENGINE_LOCK_ID = bl.ENGINE_LOCK_ID;

-- Metadata lock waits (DDL blocked by active queries)
SELECT
  OBJECT_TYPE, OBJECT_SCHEMA, OBJECT_NAME,
  LOCK_TYPE, LOCK_DURATION, LOCK_STATUS,
  OWNER_THREAD_ID, OWNER_EVENT_ID
FROM performance_schema.metadata_locks
WHERE LOCK_STATUS = 'PENDING'
ORDER BY OBJECT_SCHEMA, OBJECT_NAME;
```

### Mutex and RWLock Contention

```sql
-- Top mutex contention points
SELECT
  EVENT_NAME,
  COUNT_STAR,
  ROUND(SUM_TIMER_WAIT / 1e12, 4) AS total_seconds,
  ROUND(AVG_TIMER_WAIT / 1e9, 4) AS avg_ms
FROM performance_schema.events_waits_summary_global_by_event_name
WHERE EVENT_NAME LIKE 'wait/synch/mutex/%'
  AND COUNT_STAR > 0
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

-- Top read-write lock contention
SELECT
  EVENT_NAME,
  COUNT_STAR,
  ROUND(SUM_TIMER_WAIT / 1e12, 4) AS total_seconds
FROM performance_schema.events_waits_summary_global_by_event_name
WHERE EVENT_NAME LIKE 'wait/synch/rwlock/%'
  AND COUNT_STAR > 0
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;
```

---

## Statement Analysis

### Statement Digest Summary

```sql
-- Reset statement statistics (do this before a profiling window)
TRUNCATE TABLE performance_schema.events_statements_summary_by_digest;

-- After the profiling window, query the results:
SELECT
  SCHEMA_NAME,
  LEFT(DIGEST_TEXT, 100) AS query_pattern,
  COUNT_STAR AS exec_count,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_seconds,
  ROUND(AVG_TIMER_WAIT / 1e12, 4) AS avg_seconds,
  SUM_ROWS_EXAMINED,
  SUM_ROWS_SENT,
  SUM_SORT_ROWS,
  SUM_CREATED_TMP_DISK_TABLES
FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 20;
```

### Slow Query Identification

```sql
-- Queries with average execution time > 1 second
SELECT
  DIGEST_TEXT,
  COUNT_STAR,
  ROUND(AVG_TIMER_WAIT / 1e12, 3) AS avg_seconds,
  ROUND(MAX_TIMER_WAIT / 1e12, 3) AS max_seconds,
  SUM_ROWS_EXAMINED / COUNT_STAR AS avg_rows_examined
FROM performance_schema.events_statements_summary_by_digest
WHERE AVG_TIMER_WAIT > 1e12  -- > 1 second
ORDER BY AVG_TIMER_WAIT DESC
LIMIT 20;

-- Currently running slow queries
SELECT
  THREAD_ID, EVENT_NAME, SQL_TEXT,
  TIMER_WAIT / 1e12 AS elapsed_seconds,
  ROWS_EXAMINED, ROWS_SENT,
  CREATED_TMP_TABLES, CREATED_TMP_DISK_TABLES
FROM performance_schema.events_statements_current
WHERE TIMER_WAIT > 5e12  -- > 5 seconds
ORDER BY TIMER_WAIT DESC;
```

### Error Summary

```sql
-- Queries generating the most errors
SELECT
  DIGEST_TEXT,
  COUNT_STAR,
  SUM_ERRORS,
  SUM_WARNINGS,
  ROUND(SUM_ERRORS / COUNT_STAR * 100, 1) AS error_pct
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_ERRORS > 0
ORDER BY SUM_ERRORS DESC
LIMIT 10;
```

### Prepared Statement Analysis

```sql
-- Prepared statement usage
SELECT
  STATEMENT_NAME, SQL_TEXT,
  OWNER_THREAD_ID, OWNER_EVENT_ID,
  TIMER_PREPARE / 1e9 AS prepare_ms,
  COUNT_REPREPARE,
  COUNT_EXECUTE,
  SUM_TIMER_EXECUTE / 1e12 AS total_exec_seconds
FROM performance_schema.prepared_statements_instances
ORDER BY SUM_TIMER_EXECUTE DESC;
```

---

## Memory Tracking

### Global Memory by Component

```sql
-- Top memory consumers (global)
SELECT
  EVENT_NAME,
  CURRENT_COUNT_USED,
  ROUND(CURRENT_NUMBER_OF_BYTES_USED / 1024 / 1024, 2) AS current_mb,
  ROUND(HIGH_NUMBER_OF_BYTES_USED / 1024 / 1024, 2) AS peak_mb
FROM performance_schema.memory_summary_global_by_event_name
WHERE CURRENT_NUMBER_OF_BYTES_USED > 0
ORDER BY CURRENT_NUMBER_OF_BYTES_USED DESC
LIMIT 20;
```

Key memory events to watch:
- `memory/innodb/buf_buf_pool`: Buffer pool allocation
- `memory/innodb/log_buffer`: Redo log buffer
- `memory/sql/TABLE`: Table cache
- `memory/sql/sp_head::main_mem_root`: Stored procedures
- `memory/performance_schema/*`: Performance Schema itself

### Per-Thread Memory

```sql
-- Memory usage per connection/thread
SELECT
  t.PROCESSLIST_ID,
  t.PROCESSLIST_USER,
  t.PROCESSLIST_HOST,
  t.PROCESSLIST_DB,
  ROUND(SUM(m.CURRENT_NUMBER_OF_BYTES_USED) / 1024 / 1024, 2) AS current_mb
FROM performance_schema.memory_summary_by_thread_by_event_name m
JOIN performance_schema.threads t ON m.THREAD_ID = t.THREAD_ID
WHERE t.TYPE = 'FOREGROUND'
GROUP BY t.THREAD_ID
ORDER BY SUM(m.CURRENT_NUMBER_OF_BYTES_USED) DESC
LIMIT 20;
```

### Memory Leak Detection

```sql
-- Compare current vs high watermark — growing delta indicates leak
SELECT
  EVENT_NAME,
  CURRENT_COUNT_USED AS current_allocs,
  HIGH_COUNT_USED AS peak_allocs,
  ROUND(CURRENT_NUMBER_OF_BYTES_USED / 1024 / 1024, 2) AS current_mb,
  ROUND(HIGH_NUMBER_OF_BYTES_USED / 1024 / 1024, 2) AS peak_mb,
  ROUND((HIGH_NUMBER_OF_BYTES_USED - CURRENT_NUMBER_OF_BYTES_USED) / 1024 / 1024, 2) AS freed_mb
FROM performance_schema.memory_summary_global_by_event_name
WHERE HIGH_NUMBER_OF_BYTES_USED > 10 * 1024 * 1024  -- > 10MB peak
ORDER BY CURRENT_NUMBER_OF_BYTES_USED DESC
LIMIT 20;

-- Track over time: sample periodically, compare CURRENT_NUMBER_OF_BYTES_USED
-- If it consistently grows without returning, investigate that event_name
```

### Buffer Pool Internals

```sql
-- Buffer pool composition
SELECT
  PAGE_TYPE, SUM(NUMBER_RECORDS) AS records, COUNT(*) AS pages,
  ROUND(COUNT(*) * 16 / 1024, 2) AS size_mb
FROM information_schema.INNODB_BUFFER_PAGE
WHERE POOL_ID = 0
GROUP BY PAGE_TYPE
ORDER BY pages DESC;

-- Most cached tables (what's in the buffer pool?)
SELECT
  TABLE_NAME,
  COUNT(*) AS pages,
  ROUND(COUNT(*) * 16 / 1024, 2) AS size_mb,
  ROUND(SUM(IS_OLD = 'YES') / COUNT(*) * 100, 1) AS pct_old
FROM information_schema.INNODB_BUFFER_PAGE
WHERE TABLE_NAME IS NOT NULL AND TABLE_NAME != ''
GROUP BY TABLE_NAME
ORDER BY pages DESC
LIMIT 20;
```

⚠️ `INNODB_BUFFER_PAGE` is expensive to query on large buffer pools — it scans the entire pool. Use sparingly.

---

## sys Schema Shortcuts

The `sys` schema provides pre-built views that simplify Performance Schema queries.

### Statement Analysis Views

```sql
-- Top queries by total latency (most useful starting point)
SELECT * FROM sys.statement_analysis ORDER BY total_latency DESC LIMIT 10;

-- Top queries with full table scans
SELECT * FROM sys.statements_with_full_table_scans LIMIT 10;

-- Top queries creating temp tables on disk
SELECT * FROM sys.statements_with_temp_tables
WHERE disk_tmp_tables > 0
ORDER BY disk_tmp_tables DESC LIMIT 10;

-- Top queries with sorting
SELECT * FROM sys.statements_with_sorting ORDER BY total_latency DESC LIMIT 10;

-- Top queries with errors
SELECT * FROM sys.statements_with_errors_or_warnings
ORDER BY errors DESC LIMIT 10;
```

### Host and User Summary

```sql
-- Activity summary per host
SELECT * FROM sys.host_summary;

-- Activity summary per user
SELECT * FROM sys.user_summary;

-- Current connections with memory
SELECT * FROM sys.processlist
WHERE conn_id IS NOT NULL
ORDER BY current_memory DESC;
```

### Schema Analysis

```sql
-- Table statistics with read/write breakdown
SELECT * FROM sys.schema_table_statistics WHERE table_schema = 'mydb';

-- Tables with most I/O
SELECT * FROM sys.schema_table_statistics_with_buffer
WHERE table_schema = 'mydb'
ORDER BY io_read + io_write DESC;

-- Unused indexes (safe to drop)
SELECT * FROM sys.schema_unused_indexes WHERE object_schema = 'mydb';

-- Redundant indexes (one index is prefix of another)
SELECT * FROM sys.schema_redundant_indexes WHERE table_schema = 'mydb';

-- Auto-increment headroom (approaching max value?)
SELECT * FROM sys.schema_auto_increment_columns
WHERE auto_increment_ratio > 0.75;
```

### I/O Analysis

```sql
-- I/O by file (which files are hottest?)
SELECT * FROM sys.io_global_by_file_by_bytes ORDER BY total DESC LIMIT 10;

-- I/O by wait type
SELECT * FROM sys.io_global_by_wait_by_bytes ORDER BY total_requested DESC;

-- I/O latency by file
SELECT * FROM sys.io_global_by_file_by_latency ORDER BY total_latency DESC LIMIT 10;
```

### Wait Analysis Views

```sql
-- Top waits globally
SELECT * FROM sys.waits_global_by_latency LIMIT 20;

-- Waits by host
SELECT * FROM sys.waits_by_host_by_latency WHERE host = 'app-server-01';

-- Waits by user
SELECT * FROM sys.waits_by_user_by_latency WHERE user = 'app';
```

### Useful Procedures

```sql
-- Generate a diagnostic report
CALL sys.diagnostics(60, 30, 'current');
-- 60 second runtime, 30 second interval, include current values

-- Kill long-running queries (dry run first)
-- View what would be killed:
SELECT * FROM sys.processlist
WHERE command = 'Query' AND time > 300;
-- Then manually: KILL <conn_id>;

-- Create a statement performance report
CALL sys.statement_performance_analyzer('create_tmp', 'tmp_before', NULL);
-- ... wait for workload period ...
CALL sys.statement_performance_analyzer('create_tmp', 'tmp_after', NULL);
CALL sys.statement_performance_analyzer('save', 'tmp_after', 'tmp_before');
CALL sys.statement_performance_analyzer('overall', 'tmp_after', 'tmp_before');

-- Format bytes/time for readability
SELECT sys.format_bytes(innodb_buffer_pool_size) FROM performance_schema.global_variables
WHERE VARIABLE_NAME = 'innodb_buffer_pool_size';
SELECT sys.format_time(1234567890);

-- Reset all Performance Schema statistics
CALL sys.ps_truncate_all_tables(FALSE);
```
