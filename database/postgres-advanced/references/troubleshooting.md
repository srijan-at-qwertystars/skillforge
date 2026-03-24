# PostgreSQL Troubleshooting Guide

## Table of Contents

- [Slow Query Diagnosis](#slow-query-diagnosis)
  - [pg_stat_statements](#pg_stat_statements)
  - [auto_explain](#auto_explain)
  - [EXPLAIN ANALYZE Deep Dive](#explain-analyze-deep-dive)
- [Bloat Detection and Remediation](#bloat-detection-and-remediation)
  - [Table Bloat](#table-bloat)
  - [Index Bloat](#index-bloat)
  - [Remediation Strategies](#remediation-strategies)
- [Lock Contention Analysis](#lock-contention-analysis)
  - [Finding Blocked Queries](#finding-blocked-queries)
  - [Lock Dependency Trees](#lock-dependency-trees)
  - [Deadlock Debugging](#deadlock-debugging)
- [Connection Exhaustion](#connection-exhaustion)
- [OOM Debugging](#oom-debugging)
- [WAL Growth Issues](#wal-growth-issues)
- [Vacuum Problems](#vacuum-problems)
  - [Autovacuum Not Running](#autovacuum-not-running)
  - [Autovacuum Too Slow](#autovacuum-too-slow)
  - [XID Wraparound Prevention](#xid-wraparound-prevention)
- [Replication Lag Diagnosis](#replication-lag-diagnosis)
  - [Streaming Replication Lag](#streaming-replication-lag)
  - [Logical Replication Issues](#logical-replication-issues)

---

## Slow Query Diagnosis

### pg_stat_statements

The single most important extension for query performance analysis.

**Setup:**
```sql
-- postgresql.conf (requires restart)
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all        -- track nested statements too
pg_stat_statements.max = 10000        -- number of statements tracked
pg_stat_statements.track_utility = on -- track DDL/utility commands

-- After restart:
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

**Top queries by total execution time:**
```sql
SELECT
    queryid,
    LEFT(query, 80) AS query_preview,
    calls,
    round(total_exec_time::numeric, 2) AS total_ms,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    rows,
    round((shared_blks_hit::numeric / NULLIF(shared_blks_hit + shared_blks_read, 0)) * 100, 2)
        AS cache_hit_pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

**Queries with worst cache hit ratio (I/O bound):**
```sql
SELECT
    LEFT(query, 80) AS query_preview,
    calls,
    shared_blks_read AS blocks_from_disk,
    shared_blks_hit AS blocks_from_cache,
    round((shared_blks_hit::numeric / NULLIF(shared_blks_hit + shared_blks_read, 0)) * 100, 2)
        AS cache_hit_pct
FROM pg_stat_statements
WHERE shared_blks_read > 1000
ORDER BY cache_hit_pct ASC
LIMIT 20;
```

**Queries with most rows scanned vs returned (bad selectivity):**
```sql
SELECT
    LEFT(query, 80) AS query_preview,
    calls,
    rows AS rows_returned,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round((shared_blks_hit + shared_blks_read)::numeric / NULLIF(rows, 0), 2)
        AS blocks_per_row
FROM pg_stat_statements
WHERE rows > 0 AND calls > 10
ORDER BY blocks_per_row DESC
LIMIT 20;
```

**Reset periodically** to get fresh data:
```sql
SELECT pg_stat_statements_reset();
```

### auto_explain

Automatically logs execution plans for slow queries — invaluable for intermittent issues.

**Setup:**
```sql
-- postgresql.conf (requires restart for shared_preload_libraries)
shared_preload_libraries = 'pg_stat_statements,auto_explain'

-- These can be changed without restart:
auto_explain.log_min_duration = '500ms'  -- log plans for queries > 500ms
auto_explain.log_analyze = on            -- include actual timing
auto_explain.log_buffers = on            -- include buffer usage
auto_explain.log_timing = on             -- include per-node timing
auto_explain.log_nested_statements = on  -- include nested statements
auto_explain.log_format = 'json'         -- structured format for parsing
auto_explain.log_verbose = on            -- show output column lists
auto_explain.log_triggers = on           -- include trigger execution time
```

**Session-level activation (no restart needed):**
```sql
-- Enable for current session only (useful for debugging)
LOAD 'auto_explain';
SET auto_explain.log_min_duration = '100ms';
SET auto_explain.log_analyze = on;
-- Run your problematic query, then check the PostgreSQL log
```

### EXPLAIN ANALYZE Deep Dive

**Red flags in EXPLAIN output:**

| Signal | Problem | Fix |
|--------|---------|-----|
| `Seq Scan` on large table | Missing index | Create appropriate index |
| `Rows Removed by Filter: 50000` | Index not selective | Better index, partial index |
| `actual rows=100000` vs `rows=100` | Stale statistics | `ANALYZE tablename` |
| `Sort Method: external merge` | `work_mem` too low | Increase `work_mem` |
| `Buffers: shared read=10000` | Cold cache / table too big | Increase `shared_buffers`, check query |
| `Nested Loop` with high rows | Wrong join strategy | Increase `work_mem`, check stats |
| `Hash Batches: 8` | Hash doesn't fit in memory | Increase `work_mem` |
| `Heap Fetches: 5000` | Visibility map stale | `VACUUM tablename` |

**Template for thorough analysis:**
```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS, TIMING, VERBOSE, FORMAT TEXT)
<your query here>;
```

---

## Bloat Detection and Remediation

### Table Bloat

Bloat occurs when dead tuples accumulate and VACUUM can't reclaim space effectively.

**Estimate table bloat:**
```sql
SELECT
    schemaname || '.' || tablename AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
    n_dead_tup,
    n_live_tup,
    round(n_dead_tup::numeric / GREATEST(n_live_tup, 1) * 100, 2) AS dead_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 10000
ORDER BY n_dead_tup DESC;
```

**Detailed bloat estimation using pgstattuple:**
```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;

SELECT
    table_len,
    tuple_count,
    tuple_len,
    dead_tuple_count,
    dead_tuple_len,
    round(dead_tuple_len::numeric / NULLIF(table_len, 0) * 100, 2) AS dead_space_pct,
    free_space,
    round(free_space::numeric / NULLIF(table_len, 0) * 100, 2) AS free_space_pct
FROM pgstattuple('public.orders');
```

### Index Bloat

```sql
-- Check index bloat ratio
SELECT
    schemaname || '.' || indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan AS times_used,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;

-- Detailed index bloat with pgstattuple
SELECT * FROM pgstatindex('idx_orders_created_at');
-- Look at: avg_leaf_density (should be >70%), leaf_pages, deleted_pages
```

### Remediation Strategies

**Option 1: VACUUM (non-blocking, doesn't reclaim disk space to OS)**
```sql
VACUUM VERBOSE orders;
```

**Option 2: VACUUM FULL (exclusive lock — use only for emergencies)**
```sql
-- WARNING: takes ACCESS EXCLUSIVE lock, blocks all queries
VACUUM FULL orders;
```

**Option 3: pg_repack (online, no exclusive lock — preferred)**
```bash
# Install pg_repack extension
pg_repack --table orders --no-superuser-check -d mydb
# Rebuilds table online with minimal locking
```

**Option 4: REINDEX CONCURRENTLY (for index bloat only)**
```sql
REINDEX INDEX CONCURRENTLY idx_orders_created_at;
-- Or rebuild all indexes on a table:
REINDEX TABLE CONCURRENTLY orders;
```

---

## Lock Contention Analysis

### Finding Blocked Queries

```sql
-- Show all blocked queries and what's blocking them
SELECT
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocked.wait_event_type,
    blocked.wait_event,
    age(now(), blocked.query_start) AS blocked_duration,
    blocker.pid AS blocker_pid,
    blocker.query AS blocker_query,
    blocker.state AS blocker_state,
    age(now(), blocker.xact_start) AS blocker_xact_duration
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted
JOIN pg_locks gl ON gl.locktype = bl.locktype
    AND gl.database IS NOT DISTINCT FROM bl.database
    AND gl.relation IS NOT DISTINCT FROM bl.relation
    AND gl.page IS NOT DISTINCT FROM bl.page
    AND gl.tuple IS NOT DISTINCT FROM bl.tuple
    AND gl.virtualxid IS NOT DISTINCT FROM bl.virtualxid
    AND gl.transactionid IS NOT DISTINCT FROM bl.transactionid
    AND gl.classid IS NOT DISTINCT FROM bl.classid
    AND gl.objid IS NOT DISTINCT FROM bl.objid
    AND gl.objsubid IS NOT DISTINCT FROM bl.objsubid
    AND gl.pid <> bl.pid
    AND gl.granted
JOIN pg_stat_activity blocker ON blocker.pid = gl.pid
ORDER BY blocked_duration DESC;
```

### Lock Dependency Trees

```sql
-- Recursive lock tree: who is blocking whom
WITH RECURSIVE lock_tree AS (
    SELECT
        pid,
        query,
        state,
        0 AS depth,
        ARRAY[pid] AS path
    FROM pg_stat_activity
    WHERE pid IN (
        SELECT gl.pid FROM pg_locks bl
        JOIN pg_locks gl ON gl.locktype = bl.locktype
            AND gl.relation IS NOT DISTINCT FROM bl.relation
            AND gl.pid <> bl.pid AND gl.granted AND NOT bl.granted
    )
    AND pid NOT IN (
        SELECT bl.pid FROM pg_locks bl WHERE NOT bl.granted
    )

    UNION ALL

    SELECT
        sa.pid,
        sa.query,
        sa.state,
        lt.depth + 1,
        lt.path || sa.pid
    FROM pg_stat_activity sa
    JOIN pg_locks bl ON bl.pid = sa.pid AND NOT bl.granted
    JOIN pg_locks gl ON gl.locktype = bl.locktype
        AND gl.relation IS NOT DISTINCT FROM bl.relation
        AND gl.pid <> bl.pid AND gl.granted
    JOIN lock_tree lt ON lt.pid = gl.pid
    WHERE sa.pid <> ALL(lt.path)
)
SELECT
    repeat('  ', depth) || pid AS tree_pid,
    LEFT(query, 60) AS query,
    state,
    depth
FROM lock_tree
ORDER BY path;
```

### Deadlock Debugging

```sql
-- postgresql.conf: enable deadlock logging
log_lock_waits = on              -- log when queries wait > deadlock_timeout
deadlock_timeout = '1s'          -- time before checking for deadlocks

-- Check recent deadlocks in logs:
-- grep "deadlock detected" /var/log/postgresql/postgresql-*.log
```

**Prevention patterns:**
- Always access tables in the same order across transactions
- Keep transactions short
- Use `SELECT ... FOR UPDATE SKIP LOCKED` for queue-like patterns
- Use `NOWAIT` to fail fast: `SELECT ... FOR UPDATE NOWAIT`

---

## Connection Exhaustion

**Diagnosis:**
```sql
-- Current connection count by state
SELECT state, count(*), usename, application_name
FROM pg_stat_activity
GROUP BY state, usename, application_name
ORDER BY count(*) DESC;

-- Check max connections vs current
SELECT
    current_setting('max_connections')::int AS max_connections,
    current_setting('superuser_reserved_connections')::int AS reserved,
    (SELECT count(*) FROM pg_stat_activity) AS current_connections,
    current_setting('max_connections')::int - (SELECT count(*) FROM pg_stat_activity)
        AS available;
```

**Find idle-in-transaction sessions (connection hogs):**
```sql
SELECT pid, usename, application_name, state,
       age(now(), xact_start) AS xact_duration,
       age(now(), state_change) AS idle_duration,
       LEFT(query, 80) AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_start;
```

**Remediation:**
```sql
-- Kill specific idle-in-transaction sessions
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND state_change < now() - interval '10 minutes';

-- Set timeouts to prevent future issues
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';
ALTER SYSTEM SET statement_timeout = '60s';  -- for web apps
SELECT pg_reload_conf();
```

**Long-term fix:** Use PgBouncer with transaction pooling.

---

## OOM Debugging

**Common causes:**
1. `work_mem` too high × many concurrent sorts/hashes
2. `maintenance_work_mem` during concurrent VACUUM/CREATE INDEX
3. Runaway queries with huge hash joins or sorts
4. Too many connections (each has ~5-10MB base overhead)

**Diagnostic steps:**

```bash
# 1. Check kernel OOM killer logs
dmesg | grep -i "out of memory\|oom-killer"
journalctl -k | grep -i "oom"

# 2. Check PostgreSQL total memory potential
# max_mem ≈ shared_buffers + (max_connections × work_mem × ~3) + maintenance_work_mem × autovacuum_max_workers
```

```sql
-- 3. Estimate worst-case memory usage
SELECT
    current_setting('shared_buffers') AS shared_buffers,
    current_setting('work_mem') AS work_mem,
    current_setting('max_connections') AS max_connections,
    current_setting('maintenance_work_mem') AS maintenance_work_mem,
    current_setting('autovacuum_max_workers') AS autovacuum_workers;

-- 4. Find memory-hungry queries (sorts spilling to disk)
SELECT
    LEFT(query, 80) AS query,
    temp_blks_read + temp_blks_written AS temp_blocks,
    calls
FROM pg_stat_statements
WHERE temp_blks_read + temp_blks_written > 0
ORDER BY temp_blocks DESC
LIMIT 10;
```

**Prevention:**
```sql
-- Set conservative work_mem globally, boost per-session for analytics
ALTER SYSTEM SET work_mem = '8MB';             -- safe default
-- For analytics queries:
SET work_mem = '256MB';                         -- session-level

-- Limit total memory with Linux cgroups or resource limits
-- Set vm.overcommit_memory = 2 to prevent OOM killer
```

---

## WAL Growth Issues

**Diagnosis:**
```bash
# Check pg_wal directory size
du -sh /var/lib/postgresql/data/pg_wal/
ls -la /var/lib/postgresql/data/pg_wal/ | wc -l
```

```sql
-- Check for inactive replication slots (most common cause)
SELECT slot_name, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;

-- Check archiver status
SELECT * FROM pg_stat_archiver;
-- If last_failed_time is recent, archive_command is failing

-- Check for long-running transactions holding WAL
SELECT pid, xact_start, age(now(), xact_start) AS duration, state, query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start
LIMIT 5;

-- Check WAL configuration
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('wal_keep_size', 'max_wal_size', 'min_wal_size',
               'checkpoint_timeout', 'archive_mode', 'archive_command',
               'max_slot_wal_keep_size');
```

**Remediation:**
```sql
-- Drop inactive replication slots
SELECT pg_drop_replication_slot('unused_slot_name');

-- Set slot WAL retention limit (PG13+)
ALTER SYSTEM SET max_slot_wal_keep_size = '10GB';
SELECT pg_reload_conf();

-- Force a checkpoint to recycle WAL
CHECKPOINT;
```

---

## Vacuum Problems

### Autovacuum Not Running

```sql
-- Check if autovacuum is enabled
SHOW autovacuum;

-- Check per-table autovacuum settings overrides
SELECT relname, reloptions
FROM pg_class
WHERE reloptions::text LIKE '%autovacuum%';

-- Tables that need vacuum but haven't been vacuumed
SELECT
    schemaname || '.' || relname AS table_name,
    n_dead_tup,
    n_live_tup,
    last_autovacuum,
    last_autoanalyze,
    -- Calculate autovacuum threshold
    (current_setting('autovacuum_vacuum_threshold')::int +
     current_setting('autovacuum_vacuum_scale_factor')::float * n_live_tup)::bigint
        AS vacuum_threshold,
    CASE WHEN n_dead_tup > (current_setting('autovacuum_vacuum_threshold')::int +
         current_setting('autovacuum_vacuum_scale_factor')::float * n_live_tup)
         THEN 'NEEDS VACUUM' ELSE 'OK' END AS status
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

-- Check if autovacuum workers are busy
SELECT pid, datname, relid::regclass, phase,
       heap_blks_total, heap_blks_scanned, heap_blks_vacuumed
FROM pg_stat_progress_vacuum;
```

### Autovacuum Too Slow

```sql
-- Increase autovacuum aggressiveness
ALTER SYSTEM SET autovacuum_max_workers = 6;             -- default: 3
ALTER SYSTEM SET autovacuum_vacuum_cost_limit = 1000;    -- default: 200
ALTER SYSTEM SET autovacuum_vacuum_cost_delay = '2ms';   -- default: 2ms (PG12+: was 20ms)
ALTER SYSTEM SET autovacuum_naptime = '15s';             -- default: 1min
SELECT pg_reload_conf();

-- Per-table tuning for hot tables
ALTER TABLE hot_table SET (
    autovacuum_vacuum_scale_factor = 0.01,    -- 1% dead rows triggers vacuum
    autovacuum_vacuum_cost_delay = 0,         -- no throttling
    autovacuum_analyze_scale_factor = 0.005
);
```

### XID Wraparound Prevention

```sql
-- CRITICAL: Monitor transaction ID age
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    current_setting('autovacuum_freeze_max_age')::bigint AS freeze_max_age,
    round(age(datfrozenxid)::numeric /
          current_setting('autovacuum_freeze_max_age')::numeric * 100, 2) AS pct_to_wraparound
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- Tables closest to wraparound
SELECT
    c.oid::regclass AS table_name,
    age(c.relfrozenxid) AS xid_age,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS table_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;

-- Alert threshold: > 500 million → urgent
-- > 1 billion → critical, approaching forced wraparound VACUUM
-- 2 billion → database shuts down to prevent data loss
```

**Emergency wraparound vacuum:**
```sql
-- If approaching wraparound, run aggressive VACUUM FREEZE
VACUUM (FREEZE, VERBOSE) problematic_table;

-- For very large tables, increase maintenance_work_mem first
SET maintenance_work_mem = '2GB';
VACUUM (FREEZE, VERBOSE, PARALLEL 4) very_large_table;
```

---

## Replication Lag Diagnosis

### Streaming Replication Lag

**On primary:**
```sql
SELECT
    client_addr,
    application_name,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) AS write_lag,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn)) AS flush_lag,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag,
    write_lag AS write_lag_time,
    flush_lag AS flush_lag_time,
    replay_lag AS replay_lag_time
FROM pg_stat_replication;
```

**On replica:**
```sql
-- Time-based lag
SELECT
    now() - pg_last_xact_replay_timestamp() AS replication_lag,
    pg_is_in_recovery() AS is_replica,
    pg_last_wal_receive_lsn() AS last_received,
    pg_last_wal_replay_lsn() AS last_replayed,
    pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
        AS receive_replay_diff_bytes;
```

**Common causes and fixes:**

| Cause | Diagnosis | Fix |
|-------|-----------|-----|
| Network latency | Large write_lag | Better network, closer replica |
| Slow replica disk | Large flush_lag - write_lag | Faster storage on replica |
| Long query on replica | Large replay_lag, `hot_standby_feedback` | Cancel query, tune `max_standby_streaming_delay` |
| WAL sender bottleneck | High `wal_sender_timeout` events | Increase `max_wal_senders` |
| Replica under load | replay_lag grows during peak | Reduce read load, add replicas |

### Logical Replication Issues

```sql
-- Check subscription status
SELECT subname, subenabled, subconninfo,
       pid, received_lsn, latest_end_lsn,
       pg_size_pretty(pg_wal_lsn_diff(latest_end_lsn, received_lsn)) AS lag
FROM pg_stat_subscription;

-- Check replication slot status on publisher
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE slot_type = 'logical';

-- Common issues:
-- 1. Conflict on subscriber (unique violation): check subscriber logs
-- 2. Missing table: ALTER SUBSCRIPTION ... REFRESH PUBLICATION;
-- 3. Schema mismatch: DDL is not replicated in logical replication
```
