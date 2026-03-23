# PostgreSQL Production Monitoring Queries

A comprehensive collection of SQL queries for monitoring PostgreSQL in production. Each query includes what to look for and actionable thresholds.

---

## Table of Contents

1. [Database-Level Monitoring](#database-level-monitoring)
2. [Table-Level Monitoring](#table-level-monitoring)
3. [Index-Level Monitoring](#index-level-monitoring)
4. [Query-Level Monitoring](#query-level-monitoring)
5. [Lock Monitoring](#lock-monitoring)
6. [Replication Monitoring](#replication-monitoring)
7. [WAL and Checkpoint Monitoring](#wal-and-checkpoint-monitoring)
8. [Autovacuum Monitoring](#autovacuum-monitoring)

---

## Database-Level Monitoring

### Database Sizes

```sql
SELECT datname,
       pg_size_pretty(pg_database_size(datname)) AS size,
       pg_database_size(datname) AS size_bytes
FROM pg_database
WHERE datistemplate = false
ORDER BY pg_database_size(datname) DESC;
```

**What to look for:** Unexpected growth. Track daily and alert on >10% growth in 24h.

### Database Age (Transaction ID)

```sql
SELECT datname,
       age(datfrozenxid) AS xid_age,
       CASE
           WHEN age(datfrozenxid) > 1200000000 THEN 'CRITICAL'
           WHEN age(datfrozenxid) > 500000000  THEN 'WARNING'
           ELSE 'OK'
       END AS status,
       pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
WHERE datistemplate = false
ORDER BY age(datfrozenxid) DESC;
```

**Thresholds:**
| XID Age | Action |
|---------|--------|
| < 500M | Normal |
| 500M–1.2B | Warning — investigate autovacuum |
| > 1.2B | Critical — immediate VACUUM FREEZE |

### Connection Summary

```sql
SELECT datname,
       count(*) AS total,
       count(*) FILTER (WHERE state = 'active') AS active,
       count(*) FILTER (WHERE state = 'idle') AS idle,
       count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_txn,
       count(*) FILTER (WHERE state = 'idle in transaction (aborted)') AS idle_in_txn_aborted,
       count(*) FILTER (WHERE wait_event_type = 'Lock') AS waiting_on_lock,
       (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_conn
FROM pg_stat_activity
GROUP BY datname
ORDER BY total DESC;
```

**Thresholds:**
| Metric | Warning | Critical |
|--------|---------|----------|
| total / max_conn | > 70% | > 85% |
| idle_in_txn | > 5 | > 20 |
| idle_in_txn_aborted | > 0 | > 0 (always fix) |

### Cache Hit Ratio

```sql
SELECT datname,
       blks_hit,
       blks_read,
       CASE WHEN blks_hit + blks_read > 0
           THEN round(100.0 * blks_hit / (blks_hit + blks_read), 2)
           ELSE 100
       END AS cache_hit_ratio
FROM pg_stat_database
WHERE datistemplate = false
AND datname IS NOT NULL
ORDER BY cache_hit_ratio;
```

**Thresholds:**
| Ratio | Status |
|-------|--------|
| > 99% | Excellent |
| 95–99% | Good |
| 90–95% | Consider increasing `shared_buffers` |
| < 90% | Investigate — likely undersized `shared_buffers` or working set too large |

### Transaction Rates and Conflicts

```sql
SELECT datname,
       xact_commit AS commits,
       xact_rollback AS rollbacks,
       CASE WHEN xact_commit + xact_rollback > 0
           THEN round(100.0 * xact_rollback / (xact_commit + xact_rollback), 2)
           ELSE 0
       END AS rollback_pct,
       conflicts,
       deadlocks,
       temp_files,
       pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database
WHERE datistemplate = false
AND datname IS NOT NULL
ORDER BY xact_commit DESC;
```

**What to look for:**
- `rollback_pct` > 5% — high error rate, investigate application
- `deadlocks` > 0 — indicates lock ordering issues
- `temp_files` growing — need higher `work_mem`
- `conflicts` > 0 — standby query conflicts with WAL replay

---

## Table-Level Monitoring

### Table Bloat Estimation

```sql
SELECT schemaname, relname,
       n_live_tup,
       n_dead_tup,
       CASE WHEN n_live_tup > 0
           THEN round(100.0 * n_dead_tup / n_live_tup, 1)
           ELSE 0
       END AS dead_pct,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       pg_size_pretty(pg_relation_size(relid)) AS table_size,
       pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) AS index_size,
       last_vacuum,
       last_autovacuum,
       last_analyze,
       last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 30;
```

**Thresholds:**
| dead_pct | Action |
|----------|--------|
| < 5% | Normal |
| 5–20% | Monitor, check autovacuum is running |
| 20–50% | Tune autovacuum for this table |
| > 50% | Manual VACUUM or pg_repack needed |

### Sequential Scan Ratio

```sql
SELECT schemaname, relname,
       seq_scan,
       idx_scan,
       CASE WHEN seq_scan + idx_scan > 0
           THEN round(100.0 * seq_scan / (seq_scan + idx_scan), 1)
           ELSE 0
       END AS seq_scan_pct,
       seq_tup_read,
       idx_tup_fetch,
       pg_size_pretty(pg_relation_size(relid)) AS size,
       n_live_tup
FROM pg_stat_user_tables
WHERE seq_scan + idx_scan > 100  -- filter out rarely-accessed tables
AND pg_relation_size(relid) > 10 * 1024 * 1024  -- > 10MB
ORDER BY seq_tup_read DESC
LIMIT 30;
```

**What to look for:** Large tables (>10MB) with high `seq_scan_pct` and high `seq_tup_read`. These likely need indexes. Small tables with seq scans are fine — seq scan on a small table is faster than an index scan.

### Table I/O (Buffer Cache vs Disk)

```sql
SELECT schemaname, relname,
       heap_blks_hit,
       heap_blks_read,
       CASE WHEN heap_blks_hit + heap_blks_read > 0
           THEN round(100.0 * heap_blks_hit / (heap_blks_hit + heap_blks_read), 2)
           ELSE 100
       END AS hit_ratio,
       idx_blks_hit,
       idx_blks_read,
       CASE WHEN idx_blks_hit + idx_blks_read > 0
           THEN round(100.0 * idx_blks_hit / (idx_blks_hit + idx_blks_read), 2)
           ELSE 100
       END AS idx_hit_ratio
FROM pg_statio_user_tables
WHERE heap_blks_hit + heap_blks_read > 1000
ORDER BY heap_blks_read DESC
LIMIT 20;
```

**What to look for:** Tables with `hit_ratio` < 95% are frequently reading from disk. Either increase `shared_buffers` or investigate if full table scans are occurring unnecessarily.

### Tables Needing VACUUM Most Urgently

```sql
SELECT schemaname, relname,
       n_dead_tup,
       n_live_tup,
       age(relfrozenxid) AS xid_age,
       last_autovacuum,
       last_vacuum,
       now() - COALESCE(last_autovacuum, last_vacuum, '1970-01-01'::timestamp) AS since_last_vacuum,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_stat_user_tables t
JOIN pg_class c ON t.relid = c.oid
WHERE n_dead_tup > 10000
   OR age(relfrozenxid) > 500000000
ORDER BY GREATEST(n_dead_tup, age(relfrozenxid)) DESC
LIMIT 20;
```

---

## Index-Level Monitoring

### Unused Indexes

```sql
SELECT schemaname, relname AS table, indexrelname AS index,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
       idx_scan,
       idx_tup_read,
       idx_tup_fetch
FROM pg_stat_user_indexes
WHERE idx_scan = 0
AND pg_relation_size(indexrelid) > 1024 * 1024  -- > 1MB
AND NOT EXISTS (  -- exclude unique/PK indexes (enforcing constraints)
    SELECT 1 FROM pg_index
    WHERE pg_index.indexrelid = pg_stat_user_indexes.indexrelid
    AND (pg_index.indisunique OR pg_index.indisprimary)
)
ORDER BY pg_relation_size(indexrelid) DESC;
```

**What to look for:** Non-unique, non-primary-key indexes with `idx_scan = 0` since the last statistics reset. These waste disk space and slow down writes.

**Before dropping:** Check `pg_stat_reset()` time and ensure sufficient observation period (at least a full business cycle — weekly/monthly reports may use indexes rarely):

```sql
SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();
```

### Duplicate Indexes

```sql
SELECT pg_size_pretty(sum(pg_relation_size(idx))::bigint) AS total_wasted,
       array_agg(idx) AS indexes,
       (array_agg(indexdef))[1] AS definition_sample
FROM (
    SELECT indexrelid::regclass AS idx,
           pg_get_indexdef(indexrelid) AS indexdef,
           (indrelid::regclass || E'\n' ||
            indclass::text || E'\n' ||
            indkey::text || E'\n' ||
            COALESCE(indexprs::text, '') || E'\n' ||
            COALESCE(indpred::text, '')) AS index_signature
    FROM pg_index
    JOIN pg_class ON pg_class.oid = pg_index.indexrelid
    WHERE indisvalid
) sub
GROUP BY index_signature
HAVING count(*) > 1
ORDER BY sum(pg_relation_size(idx)) DESC;
```

**What to look for:** Multiple indexes with the same signature — these are exact duplicates. Drop all but one.

### Indexes That Are Prefixes of Others

```sql
-- Find indexes where one is a left-prefix of another (the shorter one may be redundant)
SELECT
    a.indexrelid::regclass AS shorter_index,
    b.indexrelid::regclass AS longer_index,
    pg_size_pretty(pg_relation_size(a.indexrelid)) AS shorter_size,
    pg_get_indexdef(a.indexrelid) AS shorter_def,
    pg_get_indexdef(b.indexrelid) AS longer_def
FROM pg_index a
JOIN pg_index b ON a.indrelid = b.indrelid
    AND a.indexrelid != b.indexrelid
    AND a.indkey::text = (
        SELECT string_agg(x::text, ' ')
        FROM unnest((b.indkey::int[])[1:array_length(a.indkey, 1)]) x
    )
WHERE a.indpred IS NOT DISTINCT FROM b.indpred  -- same partial predicate
AND array_length(a.indkey, 1) < array_length(b.indkey, 1)
AND pg_relation_size(a.indexrelid) > 1024 * 1024;  -- > 1MB
```

### Index Bloat

```sql
-- Requires pgstattuple extension
CREATE EXTENSION IF NOT EXISTS pgstattuple;

SELECT indexrelname AS index,
       relname AS table,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
       idx_scan,
       s.leaf_fragmentation,
       s.avg_leaf_density
FROM pg_stat_user_indexes
CROSS JOIN LATERAL pgstatindex(indexrelid::regclass) s
WHERE pg_relation_size(indexrelid) > 10 * 1024 * 1024  -- > 10MB
ORDER BY s.leaf_fragmentation DESC
LIMIT 20;
```

**Thresholds:**
| leaf_fragmentation | avg_leaf_density | Action |
|-------------------|------------------|--------|
| < 10% | > 70% | Healthy |
| 10–30% | 50–70% | Monitor |
| > 30% | < 50% | REINDEX CONCURRENTLY |

### Missing Indexes (Tables with High Seq Scan on Large Data)

```sql
SELECT schemaname, relname,
       seq_scan,
       seq_tup_read,
       idx_scan,
       CASE WHEN seq_scan > 0
           THEN seq_tup_read / seq_scan
           ELSE 0
       END AS avg_tup_per_seq_scan,
       n_live_tup,
       pg_size_pretty(pg_relation_size(relid)) AS table_size
FROM pg_stat_user_tables
WHERE seq_scan > 50
AND seq_tup_read > 100000
AND pg_relation_size(relid) > 50 * 1024 * 1024  -- > 50MB
AND (idx_scan = 0 OR seq_scan > idx_scan * 10)   -- seq scans dominate
ORDER BY seq_tup_read DESC
LIMIT 20;
```

**What to look for:** Tables where `avg_tup_per_seq_scan` is high (reading many rows per seq scan) and `seq_scan` count is significant. Cross-reference with `pg_stat_statements` to find which queries are causing the scans.

---

## Query-Level Monitoring

**Prerequisite:** `pg_stat_statements` must be enabled:
```sql
-- In postgresql.conf
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = 'all'        -- top, all, or none
pg_stat_statements.max = 10000          -- max tracked queries
```

### Top Queries by Total Time

```sql
SELECT queryid,
       LEFT(query, 150) AS query,
       calls,
       round(total_exec_time::numeric, 1) AS total_time_ms,
       round(mean_exec_time::numeric, 1) AS mean_time_ms,
       round(stddev_exec_time::numeric, 1) AS stddev_ms,
       round(min_exec_time::numeric, 1) AS min_ms,
       round(max_exec_time::numeric, 1) AS max_ms,
       rows
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC
LIMIT 20;
```

**What to look for:** Queries with the highest `total_time_ms` are where optimization effort gives the biggest ROI. A query running 1ms but called 1M times = 1000s total.

### Top Queries by Mean Time (Slowest Individual Queries)

```sql
SELECT queryid,
       LEFT(query, 150) AS query,
       calls,
       round(mean_exec_time::numeric, 1) AS mean_time_ms,
       round(max_exec_time::numeric, 1) AS max_ms,
       rows / GREATEST(calls, 1) AS avg_rows
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
AND calls > 10  -- filter out one-off queries
ORDER BY mean_exec_time DESC
LIMIT 20;
```

### Top Queries by I/O (Buffer Reads)

```sql
SELECT queryid,
       LEFT(query, 150) AS query,
       calls,
       shared_blks_hit,
       shared_blks_read,
       shared_blks_dirtied,
       shared_blks_written,
       CASE WHEN shared_blks_hit + shared_blks_read > 0
           THEN round(100.0 * shared_blks_hit / (shared_blks_hit + shared_blks_read), 1)
           ELSE 100
       END AS hit_ratio,
       temp_blks_read + temp_blks_written AS temp_blks_total
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
AND shared_blks_read > 1000
ORDER BY shared_blks_read DESC
LIMIT 20;
```

**What to look for:** Queries with low `hit_ratio` are reading from disk. Queries with high `temp_blks_total` are spilling to temp files (increase `work_mem` or optimize query).

### Slow Query Identification (High Variance)

```sql
SELECT queryid,
       LEFT(query, 150) AS query,
       calls,
       round(mean_exec_time::numeric, 1) AS mean_ms,
       round(stddev_exec_time::numeric, 1) AS stddev_ms,
       round(min_exec_time::numeric, 1) AS min_ms,
       round(max_exec_time::numeric, 1) AS max_ms,
       round(stddev_exec_time / NULLIF(mean_exec_time, 0), 2) AS cv  -- coefficient of variation
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
AND calls > 100
AND mean_exec_time > 10  -- at least 10ms mean
ORDER BY stddev_exec_time / NULLIF(mean_exec_time, 0) DESC NULLS LAST
LIMIT 20;
```

**What to look for:** High `cv` (coefficient of variation) indicates inconsistent performance — likely plan flips, lock contention, or resource competition.

### Query Planning Time vs Execution Time

```sql
SELECT queryid,
       LEFT(query, 100) AS query,
       calls,
       round(total_plan_time::numeric, 1) AS total_plan_ms,
       round(total_exec_time::numeric, 1) AS total_exec_ms,
       round(mean_plan_time::numeric, 1) AS mean_plan_ms,
       round(mean_exec_time::numeric, 1) AS mean_exec_ms,
       CASE WHEN total_exec_time > 0
           THEN round(100.0 * total_plan_time / total_exec_time, 1)
           ELSE 0
       END AS plan_pct_of_exec
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
AND calls > 100
AND total_plan_time > 1000  -- planning time > 1s total
ORDER BY total_plan_time DESC
LIMIT 15;
```

**What to look for:** If `plan_pct_of_exec` > 50%, consider using prepared statements to avoid re-planning. This is common for complex queries on tables with many indexes or partitions.

### Reset Statistics (Do Periodically)

```sql
-- Reset pg_stat_statements counters (do weekly/monthly for fresh data)
SELECT pg_stat_statements_reset();

-- Check when stats were last reset
SELECT stats_reset FROM pg_stat_database WHERE datname = current_database();
```

---

## Lock Monitoring

### Current Lock Waits

```sql
SELECT
    blocked_activity.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    LEFT(blocked_activity.query, 100) AS blocked_query,
    now() - blocked_activity.query_start AS blocked_duration,
    blocking_activity.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    LEFT(blocking_activity.query, 100) AS blocking_query,
    blocking_activity.state AS blocking_state
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity
    ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks
    ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity
    ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted
ORDER BY blocked_activity.query_start;
```

### Full Blocking Chain (Recursive)

```sql
WITH RECURSIVE lock_chain AS (
    -- Base: blocked processes
    SELECT
        blocked.pid,
        blocked.pid AS root_blocker_pid,
        blocked.query,
        1 AS depth,
        ARRAY[blocked.pid] AS chain
    FROM pg_locks blocked
    JOIN pg_stat_activity act ON act.pid = blocked.pid
    WHERE NOT blocked.granted

    UNION ALL

    -- Recursive: find who's blocking the blocker
    SELECT
        blocker.pid,
        lc.root_blocker_pid,
        blocker_act.query,
        lc.depth + 1,
        lc.chain || blocker.pid
    FROM lock_chain lc
    JOIN pg_locks blocked ON blocked.pid = lc.pid AND NOT blocked.granted
    JOIN pg_locks blocker ON blocker.granted
        AND blocker.locktype = blocked.locktype
        AND blocker.relation IS NOT DISTINCT FROM blocked.relation
        AND blocker.pid != blocked.pid
    JOIN pg_stat_activity blocker_act ON blocker_act.pid = blocker.pid
    WHERE NOT blocker.pid = ANY(lc.chain)  -- prevent cycles
    AND lc.depth < 10
)
SELECT pid, depth, LEFT(query, 100) AS query, chain
FROM lock_chain
ORDER BY root_blocker_pid, depth;
```

### Deadlock History

```sql
-- Deadlocks are logged by PostgreSQL. Check pg_stat_database for counts:
SELECT datname, deadlocks
FROM pg_stat_database
WHERE deadlocks > 0;

-- For details, search PostgreSQL log files:
-- grep "deadlock detected" /var/log/postgresql/*.log
```

**What to look for:** Increasing deadlock count. Fix by ensuring consistent lock ordering in application code.

### Advisory Lock Usage

```sql
SELECT classid, objid, mode, granted, pid,
       LEFT(query, 80) AS query
FROM pg_locks
JOIN pg_stat_activity USING (pid)
WHERE locktype = 'advisory'
ORDER BY classid, objid;
```

---

## Replication Monitoring

### Streaming Replication Status (Run on Primary)

```sql
SELECT client_addr,
       state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)) AS write_lag,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, flush_lsn)) AS flush_lag,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag,
       write_lag AS write_lag_interval,
       flush_lag AS flush_lag_interval,
       replay_lag AS replay_lag_interval,
       sync_state
FROM pg_stat_replication;
```

**Thresholds:**
| replay_lag | Status |
|-----------|--------|
| < 1MB | Healthy |
| 1–100MB | Monitor — may be transient |
| 100MB–1GB | Warning — replica falling behind |
| > 1GB | Critical — investigate immediately |

### Replication Slot Status

```sql
SELECT slot_name,
       slot_type,
       active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS wal_retained_bytes,
       CASE
           WHEN NOT active AND pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 1073741824
           THEN 'CRITICAL: inactive slot retaining > 1GB WAL'
           WHEN NOT active
           THEN 'WARNING: inactive slot'
           ELSE 'OK'
       END AS status
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

**Critical:** Inactive replication slots prevent WAL file recycling and can fill the disk. Always monitor and drop abandoned slots.

### Replication Lag from Replica's Perspective

```sql
-- Run on REPLICA
SELECT CASE
           WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn()
           THEN '0 seconds'
           ELSE extract(epoch FROM now() - pg_last_xact_replay_timestamp())::text || ' seconds'
       END AS replication_lag;
```

---

## WAL and Checkpoint Monitoring

### Checkpoint Statistics

```sql
SELECT checkpoints_timed,
       checkpoints_req,
       CASE WHEN checkpoints_timed + checkpoints_req > 0
           THEN round(100.0 * checkpoints_req / (checkpoints_timed + checkpoints_req), 1)
           ELSE 0
       END AS requested_pct,
       pg_size_pretty(buffers_checkpoint * 8192::bigint) AS data_written_checkpoints,
       pg_size_pretty(buffers_clean * 8192::bigint) AS data_written_bgwriter,
       pg_size_pretty(buffers_backend * 8192::bigint) AS data_written_backends,
       buffers_backend_fsync,
       maxwritten_clean,
       checkpoint_write_time / 1000 AS checkpoint_write_sec,
       checkpoint_sync_time / 1000 AS checkpoint_sync_sec,
       stats_reset
FROM pg_stat_bgwriter;
```

**What to look for:**
| Metric | Healthy | Problem |
|--------|---------|---------|
| `requested_pct` | < 10% | > 30% — WAL filling too fast, increase `max_wal_size` |
| `buffers_backend` | < 10% of total writes | > 30% — bgwriter not keeping up, tune `bgwriter_*` |
| `buffers_backend_fsync` | 0 | > 0 — critical: backends forced to fsync (very slow) |
| `maxwritten_clean` | 0 | > 0 — bgwriter hitting `bgwriter_lru_maxpages` limit |

### WAL Generation Rate

```sql
-- Current WAL position
SELECT pg_current_wal_lsn() AS current_lsn,
       pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file;

-- WAL generated in last interval (run twice, diff)
-- Or use pg_stat_wal (PG 14+):
SELECT wal_records, wal_fpi, wal_bytes,
       pg_size_pretty(wal_bytes) AS wal_generated,
       wal_buffers_full,
       wal_write, wal_sync,
       wal_write_time / 1000 AS write_time_sec,
       wal_sync_time / 1000 AS sync_time_sec,
       stats_reset
FROM pg_stat_wal;
```

### WAL Directory Size

```sql
-- Check WAL directory size (useful for disk capacity planning)
SELECT count(*) AS wal_files,
       pg_size_pretty(sum(size)) AS total_wal_size
FROM pg_ls_waldir();
```

**What to look for:** If WAL files accumulate beyond `max_wal_size × 2`, an inactive replication slot or archive failure is likely retaining them.

---

## Autovacuum Monitoring

### Currently Running Autovacuum Workers

```sql
SELECT pid, datname, relid::regclass AS table_name,
       phase,
       heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
       CASE WHEN heap_blks_total > 0
           THEN round(100.0 * heap_blks_vacuumed / heap_blks_total, 1)
           ELSE 0
       END AS pct_complete,
       index_vacuum_count,
       max_dead_tuples,
       num_dead_tuples
FROM pg_stat_progress_vacuum;
```

### Autovacuum Worker Utilization

```sql
SELECT count(*) AS active_workers,
       (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_max_workers') AS max_workers
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker';
```

**What to look for:** If `active_workers = max_workers` consistently, autovacuum is saturated. Increase `autovacuum_max_workers` (but each worker uses `maintenance_work_mem`).

### Tables Lagging Behind Autovacuum

```sql
SELECT schemaname, relname,
       n_dead_tup,
       n_live_tup,
       CASE WHEN n_live_tup > 0
           THEN round(100.0 * n_dead_tup / n_live_tup, 1)
           ELSE 0
       END AS dead_pct,
       last_autovacuum,
       last_autoanalyze,
       n_mod_since_analyze,
       -- Calculate when autovacuum should trigger
       (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_vacuum_threshold')
       + (SELECT setting::float FROM pg_settings WHERE name = 'autovacuum_vacuum_scale_factor')
         * n_live_tup AS vacuum_trigger_threshold,
       n_dead_tup > (
           (SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_vacuum_threshold')
           + (SELECT setting::float FROM pg_settings WHERE name = 'autovacuum_vacuum_scale_factor')
             * n_live_tup
       ) AS needs_vacuum_now,
       pg_size_pretty(pg_relation_size(relid)) AS table_size
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 30;
```

**What to look for:**
- Tables with `needs_vacuum_now = true` and no recent `last_autovacuum` — autovacuum is blocked or too slow
- Tables with very high `n_mod_since_analyze` — statistics are stale, affecting plan quality

### Autovacuum Settings Per Table

```sql
SELECT c.relname,
       c.reloptions,
       pg_size_pretty(pg_relation_size(c.oid)) AS size,
       s.n_dead_tup,
       s.last_autovacuum
FROM pg_class c
JOIN pg_stat_user_tables s ON c.oid = s.relid
WHERE c.reloptions IS NOT NULL
AND c.reloptions::text LIKE '%autovacuum%'
ORDER BY pg_relation_size(c.oid) DESC;
```

### Autovacuum Effectiveness Over Time

```sql
-- Compare dead tuple counts before/after autovacuum
-- Use pg_stat_user_tables snapshots or this point-in-time view:
SELECT relname,
       n_live_tup,
       n_dead_tup,
       CASE WHEN n_live_tup > 0
           THEN round(100.0 * n_dead_tup / n_live_tup, 1)
           ELSE 0
       END AS dead_pct,
       last_autovacuum,
       last_vacuum,
       vacuum_count + autovacuum_count AS total_vacuums,
       analyze_count + autoanalyze_count AS total_analyzes
FROM pg_stat_user_tables
WHERE n_live_tup > 10000
ORDER BY n_dead_tup DESC
LIMIT 20;
```

**Healthy indicators:**
- Dead tuple percentage stays below 10% on all tables
- All tables have been auto-vacuumed within the last 24 hours (or since their last significant writes)
- `autovacuum_count` is increasing steadily
- No tables with XID age > 200M
