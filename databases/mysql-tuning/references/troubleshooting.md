# MySQL Troubleshooting Guide

## Table of Contents

- [Lock Waits and Deadlocks](#lock-waits-and-deadlocks)
  - [Diagnosing Lock Waits](#diagnosing-lock-waits)
  - [Finding the Blocking Transaction](#finding-the-blocking-transaction)
  - [Deadlock Analysis](#deadlock-analysis)
  - [Common Deadlock Patterns](#common-deadlock-patterns)
  - [Lock Wait Mitigation](#lock-wait-mitigation)
- [Replication Lag](#replication-lag)
  - [Measuring Lag Accurately](#measuring-lag-accurately)
  - [Common Lag Causes](#common-lag-causes)
  - [Fixing Replication Lag](#fixing-replication-lag)
  - [GTID Replication Diagnostics](#gtid-replication-diagnostics)
- [Disk I/O Bottlenecks](#disk-io-bottlenecks)
  - [Identifying I/O Problems](#identifying-io-problems)
  - [InnoDB I/O Tuning](#innodb-io-tuning)
  - [Reducing Unnecessary I/O](#reducing-unnecessary-io)
  - [Filesystem and Storage Tuning](#filesystem-and-storage-tuning)
- [Memory Pressure](#memory-pressure)
  - [MySQL Memory Model](#mysql-memory-model)
  - [Diagnosing OOM](#diagnosing-oom)
  - [Memory Reduction Strategies](#memory-reduction-strategies)
  - [Buffer Pool Resizing](#buffer-pool-resizing)
- [Connection Storms](#connection-storms)
  - [Symptoms](#symptoms)
  - [Emergency Response](#emergency-response)
  - [Root Cause Analysis](#root-cause-analysis)
  - [Prevention](#prevention)
- [Slow Query Patterns](#slow-query-patterns)
  - [Full Table Scans](#full-table-scans)
  - [Filesort and Temporary Tables](#filesort-and-temporary-tables)
  - [Subquery Performance Traps](#subquery-performance-traps)
  - [SELECT FOR UPDATE Bottlenecks](#select-for-update-bottlenecks)
  - [Schema Change Impact](#schema-change-impact)
- [Crash Recovery](#crash-recovery)
  - [InnoDB Recovery Process](#innodb-recovery-process)
  - [Recovery Mode Escalation](#recovery-mode-escalation)
  - [Corrupted Table Recovery](#corrupted-table-recovery)
  - [Binary Log Recovery](#binary-log-recovery)
  - [Post-Recovery Validation](#post-recovery-validation)

---

## Lock Waits and Deadlocks

### Diagnosing Lock Waits

When queries hang or timeout with `Lock wait timeout exceeded`:

```sql
-- Show all current lock waits (MySQL 8.0+)
SELECT
  r.trx_id AS waiting_trx,
  r.trx_mysql_thread_id AS waiting_thread,
  r.trx_query AS waiting_query,
  b.trx_id AS blocking_trx,
  b.trx_mysql_thread_id AS blocking_thread,
  b.trx_query AS blocking_query,
  b.trx_started AS blocking_since
FROM performance_schema.data_lock_waits w
JOIN information_schema.INNODB_TRX r ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
JOIN information_schema.INNODB_TRX b ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID;
```

### Finding the Blocking Transaction

```sql
-- Find what locks are held (MySQL 8.0+)
SELECT
  OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME,
  LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA,
  ENGINE_TRANSACTION_ID
FROM performance_schema.data_locks
WHERE ENGINE_TRANSACTION_ID IN (
  SELECT BLOCKING_ENGINE_TRANSACTION_ID FROM performance_schema.data_lock_waits
);

-- Find the process to kill
SELECT
  p.ID, p.USER, p.HOST, p.DB, p.TIME, p.STATE, p.INFO
FROM information_schema.PROCESSLIST p
WHERE p.ID = (
  SELECT trx_mysql_thread_id FROM information_schema.INNODB_TRX
  WHERE trx_id = '<blocking_trx_id>'
);

-- Kill the blocking connection (last resort)
KILL <blocking_thread_id>;
```

### Deadlock Analysis

```sql
-- Show the latest deadlock details
SHOW ENGINE INNODB STATUS\G
-- Look for: LATEST DETECTED DEADLOCK section
```

Parse the deadlock output for:
1. **Transaction 1**: Which row/index it held, which it was waiting for.
2. **Transaction 2**: Which row/index it held, which it was waiting for.
3. **Victim**: Which transaction was rolled back (lowest cost).

Enable deadlock logging to error log:

```ini
innodb_print_all_deadlocks = ON
```

### Common Deadlock Patterns

**Pattern 1: Opposing row order**

```sql
-- Session 1                          -- Session 2
UPDATE accounts SET bal=1 WHERE id=1; UPDATE accounts SET bal=2 WHERE id=2;
UPDATE accounts SET bal=2 WHERE id=2; UPDATE accounts SET bal=1 WHERE id=1;
-- DEADLOCK
```

**Fix**: Always access rows in the same order (e.g., sorted by PK).

**Pattern 2: Gap lock conflicts**

```sql
-- INSERT into a range where another transaction holds a gap lock
-- Tx1: SELECT ... WHERE id > 100 FOR UPDATE  (gap lock on id > 100)
-- Tx2: INSERT INTO ... (id = 105)  -- blocked by gap lock
-- Tx1: INSERT INTO ... (id = 102)  -- if Tx2 also holds a gap lock, deadlock
```

**Fix**: Use `READ COMMITTED` isolation to reduce gap locks, or use `INSERT ... ON DUPLICATE KEY UPDATE`.

**Pattern 3: Secondary index + clustered index**

Updates to indexed columns lock both the secondary index entry and the clustered index entry, in different orders depending on the query plan.

**Fix**: Keep transactions short, update fewer indexed columns per transaction.

### Lock Wait Mitigation

```ini
# Reduce lock wait timeout (fail fast, retry at app layer)
innodb_lock_wait_timeout = 5

# Use READ COMMITTED to reduce gap locking
transaction_isolation = READ-COMMITTED
```

Application-level strategies:
- Retry deadlocked transactions (detect error 1213, retry up to 3 times with exponential backoff).
- Acquire locks in a consistent global order.
- Keep transactions as short as possible — no user interaction inside transactions.
- Use `SELECT ... FOR UPDATE NOWAIT` (MySQL 8.0+) to fail immediately instead of waiting.
- Use `SELECT ... FOR UPDATE SKIP LOCKED` for queue-pattern tables.

---

## Replication Lag

### Measuring Lag Accurately

```sql
-- Basic lag measurement
SHOW REPLICA STATUS\G
-- Seconds_Behind_Source: seconds of lag (can be misleading)

-- More accurate: compare GTID sets
SELECT
  @@global.gtid_executed AS executed,
  (SELECT RECEIVED_TRANSACTION_SET
   FROM performance_schema.replication_connection_status) AS received;

-- Heartbeat-based lag measurement (most accurate)
-- Requires pt-heartbeat from Percona Toolkit
-- On source: pt-heartbeat --update --database heartbeat
-- On replica: pt-heartbeat --monitor --database heartbeat
```

`Seconds_Behind_Source` is unreliable because:
- It measures time between source event timestamp and replica processing time.
- If replication stops and resumes, it shows 0 during the stop.
- Multi-threaded replication can report lag for the slowest worker.

### Common Lag Causes

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| Large transactions | `SHOW REPLICA STATUS` shows single GTID for long time | Break into smaller transactions |
| Single-threaded apply | `replica_parallel_workers = 0` | Set to 4-16 |
| DDL on large table | `SHOW PROCESSLIST` shows ALTER on replica | Use pt-osc or gh-ost |
| Network latency | High `RECEIVED_TRANSACTION_SET` lag | Check network, use compression |
| Disk I/O on replica | High `iowait` on replica | Upgrade storage, tune I/O |
| Suboptimal queries | Slow queries on replica not on source | Add indexes on replica |
| Binary log format | STATEMENT format replays expensive queries | Use ROW format |

### Fixing Replication Lag

```ini
# Enable parallel replication (MySQL 8.0+)
replica_parallel_workers = 16
replica_parallel_type = LOGICAL_CLOCK
replica_preserve_commit_order = ON

# Reduce replica durability for speed (accept small crash risk)
innodb_flush_log_at_trx_commit = 2
sync_binlog = 0

# Enable binary log compression (MySQL 8.0.20+)
binlog_transaction_compression = ON

# Write set tracking for better parallelism
binlog_transaction_dependency_tracking = WRITESET
transaction_write_set_extraction = XXHASH64
```

### GTID Replication Diagnostics

```sql
-- Find errant transactions (executed on replica but not on source)
-- On source:
SELECT @@global.gtid_executed;
-- On replica:
SELECT @@global.gtid_executed;
-- Compare: replica should be a subset of source + its own server_uuid

-- Skip a problematic transaction (GTID mode)
SET GLOBAL sql_replica_skip_counter = 0;  -- Don't use this with GTID
-- Instead, inject an empty transaction:
SET GTID_NEXT = 'source_uuid:txn_number';
BEGIN; COMMIT;
SET GTID_NEXT = 'AUTOMATIC';
START REPLICA;
```

---

## Disk I/O Bottlenecks

### Identifying I/O Problems

```bash
# Check I/O wait percentage (should be < 10%)
iostat -xz 1 5

# Key columns:
# %util   - device utilization (>80% = saturated)
# await   - average I/O wait time (>10ms on SSD = problem)
# r/s,w/s - read/write IOPS
# rkB/s,wkB/s - throughput

# Check MySQL-specific I/O waits
mysql -e "SELECT EVENT_NAME, COUNT_STAR, SUM_TIMER_WAIT/1e12 AS total_seconds
FROM performance_schema.events_waits_summary_global_by_event_name
WHERE EVENT_NAME LIKE 'wait/io/file/%'
ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;"
```

```sql
-- InnoDB I/O statistics
SHOW GLOBAL STATUS LIKE 'Innodb_data_reads';
SHOW GLOBAL STATUS LIKE 'Innodb_data_writes';
SHOW GLOBAL STATUS LIKE 'Innodb_data_pending%';
-- Innodb_data_pending_reads/writes > 0 sustained = I/O bottleneck

-- OS-level file I/O from Performance Schema
SELECT FILE_NAME,
  COUNT_READ, SUM_NUMBER_OF_BYTES_READ / 1024 / 1024 AS read_mb,
  COUNT_WRITE, SUM_NUMBER_OF_BYTES_WRITE / 1024 / 1024 AS write_mb
FROM performance_schema.file_summary_by_instance
ORDER BY SUM_NUMBER_OF_BYTES_READ + SUM_NUMBER_OF_BYTES_WRITE DESC
LIMIT 10;
```

### InnoDB I/O Tuning

```ini
# Set I/O capacity to match storage capabilities
# SSD: 2000-20000, NVMe: 10000-50000, HDD: 100-200
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000

# Use O_DIRECT to bypass OS page cache (avoid double buffering)
innodb_flush_method = O_DIRECT

# Increase I/O threads for parallelism
innodb_read_io_threads = 8
innodb_write_io_threads = 8

# Enable AIO (asynchronous I/O)
innodb_use_native_aio = ON
```

### Reducing Unnecessary I/O

```sql
-- Find tables with excessive random I/O (large scans)
SELECT OBJECT_SCHEMA, OBJECT_NAME,
  COUNT_READ AS reads, COUNT_WRITE AS writes,
  COUNT_FETCH AS fetches,
  SUM_TIMER_WAIT / 1e12 AS total_wait_seconds
FROM performance_schema.table_io_waits_summary_by_table
ORDER BY SUM_TIMER_WAIT DESC LIMIT 20;
```

Strategies:
- Increase buffer pool to cache more data in memory.
- Add covering indexes to eliminate table lookups.
- Reduce `SELECT *` — only read needed columns.
- Use `LIMIT` on reporting queries.
- Move temp tables to tmpfs (`tmpdir = /dev/shm`).
- Separate redo logs and data files to different disks.

### Filesystem and Storage Tuning

```bash
# XFS recommended for MySQL (better than ext4 for large files)
# Mount options for MySQL data volume:
# noatime,nodiratime — skip access time updates
# nobarrier — if battery-backed RAID (else keep barriers)
# logbufs=8 — increase XFS log buffers

# Check current mount options
mount | grep mysql

# Verify scheduler (noop/none for SSD, deadline/mq-deadline for HDD)
cat /sys/block/sda/queue/scheduler
# Set: echo 'none' > /sys/block/sda/queue/scheduler
```

---

## Memory Pressure

### MySQL Memory Model

MySQL memory is split into:
1. **Global buffers**: `innodb_buffer_pool_size`, `key_buffer_size`, `innodb_log_buffer_size`, `query_cache_size` (pre-8.0).
2. **Per-connection buffers**: `sort_buffer_size`, `join_buffer_size`, `read_buffer_size`, `read_rnd_buffer_size`, `tmp_table_size`, `thread_stack`.
3. **Internal overhead**: Performance Schema, metadata caches, table cache.

**Worst-case memory**:

```
total_memory = innodb_buffer_pool_size
             + key_buffer_size
             + innodb_log_buffer_size
             + max_connections * (sort_buffer_size + join_buffer_size
                                 + read_buffer_size + read_rnd_buffer_size
                                 + thread_stack + net_buffer_length
                                 + tmp_table_size)
             + performance_schema memory
             + internal overhead (~200-500MB)
```

### Diagnosing OOM

```bash
# Check if MySQL was killed by OOM killer
dmesg | grep -i "out of memory"
dmesg | grep -i "killed process"
grep -i "oom" /var/log/syslog

# Check MySQL error log
grep -i "allocat" /var/log/mysql/error.log
```

```sql
-- Memory usage by component (MySQL 8.0+)
SELECT EVENT_NAME,
  CURRENT_NUMBER_OF_BYTES_USED / 1024 / 1024 AS current_mb,
  HIGH_NUMBER_OF_BYTES_USED / 1024 / 1024 AS peak_mb
FROM performance_schema.memory_summary_global_by_event_name
ORDER BY CURRENT_NUMBER_OF_BYTES_USED DESC LIMIT 20;

-- Total tracked memory
SELECT SUM(CURRENT_NUMBER_OF_BYTES_USED) / 1024 / 1024 / 1024 AS total_gb
FROM performance_schema.memory_summary_global_by_event_name;

-- Per-thread memory usage (find hungry connections)
SELECT THREAD_ID, EVENT_NAME,
  CURRENT_NUMBER_OF_BYTES_USED / 1024 / 1024 AS current_mb
FROM performance_schema.memory_summary_by_thread_by_event_name
ORDER BY CURRENT_NUMBER_OF_BYTES_USED DESC LIMIT 20;
```

### Memory Reduction Strategies

1. **Reduce buffer pool** if swapping occurs — a smaller pool in RAM outperforms a larger pool that swaps.
2. **Lower per-connection buffers** to defaults (256KB sort, 256KB join). Only increase per-session where needed.
3. **Reduce max_connections** to actual peak + 20%.
4. **Disable Performance Schema** if not needed (`performance_schema = OFF`) — saves 200-400MB.
5. **Reduce table_open_cache** if memory is tight.

```ini
# Conservative memory settings for constrained environments
innodb_buffer_pool_size = 1G
max_connections = 100
sort_buffer_size = 256K
join_buffer_size = 256K
read_buffer_size = 128K
read_rnd_buffer_size = 256K
tmp_table_size = 16M
max_heap_table_size = 16M
table_open_cache = 1024
performance_schema = OFF
```

### Buffer Pool Resizing

MySQL 8.0 supports online buffer pool resizing:

```sql
-- Resize dynamically (takes effect in chunks)
SET GLOBAL innodb_buffer_pool_size = 8 * 1024 * 1024 * 1024;  -- 8GB

-- Monitor resize progress
SHOW STATUS LIKE 'Innodb_buffer_pool_resize_status';
```

Resizing is done in `innodb_buffer_pool_chunk_size` increments. The new size is rounded to `chunk_size * instances`.

---

## Connection Storms

### Symptoms

- `Too many connections` errors (error 1040)
- `Threads_running` spikes to near `max_connections`
- Query response times degrade rapidly (thundering herd)
- Application health checks fail

### Emergency Response

```sql
-- Immediate: find and kill idle/long-running connections
SELECT ID, USER, HOST, DB, TIME, STATE, INFO
FROM information_schema.PROCESSLIST
WHERE COMMAND != 'Sleep' OR TIME > 300
ORDER BY TIME DESC;

-- Kill connections older than 5 minutes
SELECT CONCAT('KILL ', ID, ';')
FROM information_schema.PROCESSLIST
WHERE COMMAND = 'Sleep' AND TIME > 300;
-- Execute the output

-- Temporarily increase max_connections
SET GLOBAL max_connections = 500;
```

### Root Cause Analysis

```sql
-- Connection creation rate
SHOW GLOBAL STATUS LIKE 'Connections';
SHOW GLOBAL STATUS LIKE 'Threads_created';
-- High Threads_created = no connection pooling

-- Current connection distribution
SELECT USER, HOST, DB, COUNT(*) AS conn_count
FROM information_schema.PROCESSLIST
GROUP BY USER, HOST, DB
ORDER BY conn_count DESC;

-- Connection state distribution
SELECT STATE, COUNT(*) AS count
FROM information_schema.PROCESSLIST
GROUP BY STATE
ORDER BY count DESC;
```

### Prevention

```ini
# Limit connections per user
CREATE USER 'app'@'%' WITH MAX_USER_CONNECTIONS 50;

# Reduce wait timeout (close idle connections faster)
wait_timeout = 300
interactive_timeout = 300

# Reserve admin connections
admin_address = '127.0.0.1'
admin_port = 33062
# or MySQL 8.0.14+:
# mysqlx_admin_address = ...
```

Application layer:
- Use connection pooling (HikariCP, ProxySQL, PgBouncer equivalent).
- Set pool max size conservatively (5-20 per app instance).
- Implement circuit breakers to stop retry storms.
- Add connection timeout and retry with exponential backoff.

---

## Slow Query Patterns

### Full Table Scans

```sql
-- Find queries doing full table scans
SELECT DIGEST_TEXT, COUNT_STAR,
  SUM_ROWS_EXAMINED / COUNT_STAR AS avg_rows_examined,
  SUM_ROWS_SENT / COUNT_STAR AS avg_rows_sent,
  SUM_ROWS_EXAMINED / NULLIF(SUM_ROWS_SENT, 0) AS examine_to_send_ratio
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_ROWS_EXAMINED / NULLIF(SUM_ROWS_SENT, 0) > 100
ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;
```

High `examine_to_send_ratio` (>100:1) means the query examines far more rows than it returns — a missing or poorly selective index.

### Filesort and Temporary Tables

```sql
-- Queries using filesort or temp tables
SELECT DIGEST_TEXT, COUNT_STAR,
  SUM_SORT_MERGE_PASSES, SUM_SORT_ROWS,
  SUM_CREATED_TMP_TABLES, SUM_CREATED_TMP_DISK_TABLES
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_SORT_MERGE_PASSES > 0 OR SUM_CREATED_TMP_DISK_TABLES > 0
ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;
```

Fixes:
- Add composite index matching ORDER BY columns.
- Increase `sort_buffer_size` per-session for specific queries (not globally).
- Increase `tmp_table_size` and `max_heap_table_size` if temp tables spill to disk.
- Simplify GROUP BY / ORDER BY expressions.

### Subquery Performance Traps

```sql
-- SLOW: Dependent subquery (runs once per outer row)
SELECT * FROM orders o
WHERE o.total > (SELECT AVG(total) FROM orders WHERE customer_id = o.customer_id);

-- FAST: Rewrite as JOIN
SELECT o.*
FROM orders o
JOIN (SELECT customer_id, AVG(total) AS avg_total
      FROM orders GROUP BY customer_id) AS avgs
  ON o.customer_id = avgs.customer_id
WHERE o.total > avgs.avg_total;
```

Check for dependent subqueries in EXPLAIN: `select_type = DEPENDENT SUBQUERY`.

### SELECT FOR UPDATE Bottlenecks

```sql
-- PROBLEM: SELECT FOR UPDATE locks all examined rows, not just matching rows
SELECT * FROM tasks WHERE status = 'pending' ORDER BY priority LIMIT 1 FOR UPDATE;
-- Without an index on status, this scans and locks the entire table

-- FIX 1: Add index
ALTER TABLE tasks ADD INDEX idx_status_priority (status, priority);

-- FIX 2: Use SKIP LOCKED for queue pattern (MySQL 8.0+)
SELECT * FROM tasks WHERE status = 'pending'
ORDER BY priority LIMIT 1
FOR UPDATE SKIP LOCKED;
```

### Schema Change Impact

Large DDL operations (`ALTER TABLE`) can block writes and cause cascading timeouts.

```sql
-- Check for pending metadata locks (DDL waiting for transactions)
SELECT
  mdl.OBJECT_SCHEMA, mdl.OBJECT_NAME, mdl.LOCK_TYPE, mdl.LOCK_STATUS,
  t.PROCESSLIST_ID, t.PROCESSLIST_TIME, t.PROCESSLIST_INFO
FROM performance_schema.metadata_locks mdl
JOIN performance_schema.threads t ON mdl.OWNER_THREAD_ID = t.THREAD_ID
WHERE mdl.LOCK_STATUS = 'PENDING';

-- Use non-blocking DDL tools
-- pt-online-schema-change (Percona Toolkit):
-- pt-osc --alter "ADD COLUMN new_col INT" D=mydb,t=mytable
-- gh-ost (GitHub):
-- gh-ost --alter "ADD COLUMN new_col INT" --database mydb --table mytable --execute
```

---

## Crash Recovery

### InnoDB Recovery Process

On startup after a crash, InnoDB performs:
1. **Redo log replay**: Applies committed transactions from the redo log.
2. **Undo log rollback**: Rolls back uncommitted transactions using undo logs.
3. **Data dictionary recovery**: Rebuilds the data dictionary if needed.

Recovery time depends on redo log size and uncommitted transaction volume. Monitor in the error log:

```
InnoDB: Log scan progressed past the checkpoint lsn 123456789
InnoDB: Doing recovery: scanned up to log sequence number 234567890
InnoDB: 1 transaction(s) which must be rolled back
InnoDB: Rolling back trx with id 987654, 15000 rows to undo
```

### Recovery Mode Escalation

If normal recovery fails, use `innodb_force_recovery` (1-6, increasingly aggressive):

```ini
# Add to my.cnf, restart MySQL
[mysqld]
innodb_force_recovery = 1  # Start conservative
```

| Level | Behavior | When to use |
|-------|----------|-------------|
| 1 | Skip corrupt pages | Single page corruption |
| 2 | Don't run background purge | Purge thread crash |
| 3 | Don't roll back transactions | Undo log corruption |
| 4 | Don't compute INSERT buffer stats | Insert buffer corruption |
| 5 | Don't look at undo logs on startup | Undo log corruption |
| 6 | Don't do redo log roll-forward | Redo log corruption |

**Critical**: At levels ≥ 4, data may be inconsistent. Export data immediately with `mysqldump`, rebuild:

```bash
# At recovery level 4+, dump everything
mysqldump --all-databases --single-transaction --routines --triggers > full_dump.sql

# Rebuild: stop MySQL, remove data dir, reinitialize
systemctl stop mysql
mv /var/lib/mysql /var/lib/mysql.corrupted
mysqld --initialize
systemctl start mysql
mysql < full_dump.sql
```

### Corrupted Table Recovery

```sql
-- Check table for corruption
CHECK TABLE mytable EXTENDED;

-- Attempt repair (InnoDB tables)
ALTER TABLE mytable ENGINE=InnoDB;  -- Rebuilds the table

-- For MyISAM tables
REPAIR TABLE mytable EXTENDED;

-- If CHECK TABLE reports corruption but the table is accessible:
-- 1. Dump the table
-- mysqldump mydb mytable > mytable_backup.sql
-- 2. Drop and recreate from dump
-- DROP TABLE mytable;
-- mysql mydb < mytable_backup.sql
```

### Binary Log Recovery

Point-in-time recovery using binary logs:

```bash
# Find the position of the last good state
mysqlbinlog --start-datetime="2024-01-15 10:00:00" \
            --stop-datetime="2024-01-15 10:30:00" \
            /var/log/mysql/binlog.000042 | head -50

# Replay binlog from last backup to point before the problem
mysqlbinlog --start-position=154 --stop-position=12345 \
            /var/log/mysql/binlog.000042 | mysql -u root -p

# For GTID-based recovery
mysqlbinlog --include-gtids="uuid:1-100" \
            --exclude-gtids="uuid:50" \
            /var/log/mysql/binlog.000042 | mysql -u root -p
```

### Post-Recovery Validation

After any recovery, validate data integrity:

```sql
-- Check all InnoDB tables
SELECT CONCAT('CHECK TABLE ', TABLE_SCHEMA, '.', TABLE_NAME, ' EXTENDED;')
FROM information_schema.TABLES
WHERE ENGINE = 'InnoDB' AND TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema');
-- Execute the output

-- Verify row counts against application expectations
SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROWS
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'mydb'
ORDER BY TABLE_ROWS DESC;

-- Check for orphaned rows (foreign key violations)
SET FOREIGN_KEY_CHECKS = 1;
-- Run application-specific integrity checks

-- Verify replication (if applicable)
SHOW REPLICA STATUS\G
-- Ensure no errors, lag is catching up
```
