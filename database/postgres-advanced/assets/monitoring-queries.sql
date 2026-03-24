-- =============================================================================
-- PostgreSQL Monitoring & Diagnostic Queries
-- =============================================================================
-- Copy-paste ready collection of queries for monitoring PostgreSQL health.
-- Each section is self-contained and can be run independently.
-- Compatible with PostgreSQL 13+
-- =============================================================================

-- =============================================================================
-- 1. CACHE HIT RATIO
-- =============================================================================
-- Overall database cache effectiveness. Target: >99% for OLTP.

-- Table cache hit ratio
SELECT
    'Table Cache' AS type,
    sum(heap_blks_hit) AS cache_hits,
    sum(heap_blks_read) AS disk_reads,
    round(sum(heap_blks_hit)::numeric /
          NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0) * 100, 2) AS hit_ratio_pct
FROM pg_statio_user_tables;

-- Index cache hit ratio
SELECT
    'Index Cache' AS type,
    sum(idx_blks_hit) AS cache_hits,
    sum(idx_blks_read) AS disk_reads,
    round(sum(idx_blks_hit)::numeric /
          NULLIF(sum(idx_blks_hit) + sum(idx_blks_read), 0) * 100, 2) AS hit_ratio_pct
FROM pg_statio_user_indexes;

-- Per-database cache hit ratio
SELECT
    datname,
    blks_hit,
    blks_read,
    round(blks_hit::numeric / NULLIF(blks_hit + blks_read, 0) * 100, 2) AS hit_ratio_pct,
    tup_returned,
    tup_fetched,
    tup_inserted,
    tup_updated,
    tup_deleted
FROM pg_stat_database
WHERE datname = current_database();


-- =============================================================================
-- 2. TABLE & INDEX BLOAT
-- =============================================================================

-- Table bloat estimation (dead tuples)
SELECT
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    n_live_tup,
    n_dead_tup,
    round(n_dead_tup::numeric / GREATEST(n_live_tup, 1) * 100, 2) AS dead_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;

-- Unused indexes (safe to drop candidates — verify with application team)
SELECT
    schemaname || '.' || indexrelname AS index_name,
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan AS times_used,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND pg_relation_size(indexrelid) > 1048576  -- > 1MB
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;

-- Index size vs table size ratio
SELECT
    t.schemaname || '.' || t.relname AS table_name,
    pg_size_pretty(pg_relation_size(t.relid)) AS table_size,
    pg_size_pretty(sum(pg_relation_size(i.indexrelid))) AS total_index_size,
    round(sum(pg_relation_size(i.indexrelid))::numeric /
          NULLIF(pg_relation_size(t.relid), 0) * 100, 1) AS index_to_table_pct,
    count(i.indexrelid) AS index_count
FROM pg_stat_user_tables t
LEFT JOIN pg_stat_user_indexes i ON t.relid = i.relid
GROUP BY t.schemaname, t.relname, t.relid
HAVING pg_relation_size(t.relid) > 10485760  -- > 10MB
ORDER BY index_to_table_pct DESC
LIMIT 20;


-- =============================================================================
-- 3. LOCK MONITORING
-- =============================================================================

-- Currently waiting locks (blocked queries)
SELECT
    blocked.pid AS blocked_pid,
    blocked.usename AS blocked_user,
    age(now(), blocked.query_start) AS blocked_duration,
    blocker.pid AS blocker_pid,
    blocker.usename AS blocker_user,
    blocker.state AS blocker_state,
    LEFT(blocked.query, 80) AS blocked_query,
    LEFT(blocker.query, 80) AS blocker_query
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

-- Lock summary by type
SELECT
    locktype,
    mode,
    count(*) AS lock_count,
    count(*) FILTER (WHERE granted) AS granted,
    count(*) FILTER (WHERE NOT granted) AS waiting
FROM pg_locks
GROUP BY locktype, mode
ORDER BY lock_count DESC;


-- =============================================================================
-- 4. REPLICATION MONITORING
-- =============================================================================

-- Streaming replication status (run on primary)
SELECT
    client_addr,
    application_name,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;

-- Replication slot status
SELECT
    slot_name,
    slot_type,
    active,
    xmin,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS pending_wal
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;

-- Replication lag (run on replica)
SELECT
    pg_is_in_recovery() AS is_replica,
    now() - pg_last_xact_replay_timestamp() AS replication_lag,
    pg_last_wal_receive_lsn() AS last_received_lsn,
    pg_last_wal_replay_lsn() AS last_replayed_lsn;


-- =============================================================================
-- 5. TABLE SIZES
-- =============================================================================

-- Top tables by total size (data + indexes + toast)
SELECT
    schemaname || '.' || tablename AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS data_size,
    pg_size_pretty(pg_indexes_size(
        (schemaname || '.' || tablename)::regclass)) AS index_size,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename) -
                   pg_relation_size(schemaname || '.' || tablename) -
                   pg_indexes_size(
                       (schemaname || '.' || tablename)::regclass)) AS toast_size,
    (SELECT count(*) FROM pg_indexes
     WHERE tablename = t.tablename AND schemaname = t.schemaname) AS index_count,
    n_live_tup AS row_estimate
FROM pg_tables t
JOIN pg_stat_user_tables s USING (schemaname, tablename)
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
LIMIT 20;

-- Database sizes
SELECT
    datname,
    pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
WHERE NOT datistemplate
ORDER BY pg_database_size(datname) DESC;


-- =============================================================================
-- 6. ACTIVE SESSIONS & QUERIES
-- =============================================================================

-- All active queries with timing
SELECT
    pid,
    usename,
    application_name,
    client_addr,
    state,
    wait_event_type,
    wait_event,
    age(now(), query_start) AS query_duration,
    age(now(), xact_start) AS xact_duration,
    LEFT(query, 120) AS query
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid != pg_backend_pid()
ORDER BY query_start;

-- Connection count by state, user, application
SELECT
    state,
    usename,
    application_name,
    count(*) AS connections
FROM pg_stat_activity
GROUP BY state, usename, application_name
ORDER BY connections DESC;

-- Long-running transactions (risk for bloat and lock issues)
SELECT
    pid,
    usename,
    state,
    age(now(), xact_start) AS xact_duration,
    LEFT(query, 100) AS query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND state != 'idle'
ORDER BY xact_start
LIMIT 10;


-- =============================================================================
-- 7. VACUUM & MAINTENANCE STATUS
-- =============================================================================

-- Tables most in need of vacuum
SELECT
    schemaname || '.' || relname AS table_name,
    n_dead_tup,
    n_live_tup,
    round(n_dead_tup::numeric / GREATEST(n_live_tup, 1) * 100, 2) AS dead_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    vacuum_count + autovacuum_count AS total_vacuums
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;

-- Autovacuum workers currently running
SELECT
    pid,
    datname,
    relid::regclass AS table_name,
    phase,
    heap_blks_total,
    heap_blks_scanned,
    heap_blks_vacuumed,
    round(heap_blks_vacuumed::numeric / NULLIF(heap_blks_total, 0) * 100, 1) AS pct_complete,
    index_vacuum_count,
    num_dead_tuples
FROM pg_stat_progress_vacuum;

-- XID wraparound risk per database
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    round(age(datfrozenxid)::numeric / 2000000000 * 100, 2) AS pct_to_wraparound,
    CASE
        WHEN age(datfrozenxid) > 1200000000 THEN 'CRITICAL'
        WHEN age(datfrozenxid) > 500000000 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM pg_database
ORDER BY age(datfrozenxid) DESC;

-- XID wraparound risk per table
SELECT
    c.oid::regclass AS table_name,
    age(c.relfrozenxid) AS xid_age,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 20;


-- =============================================================================
-- 8. CHECKPOINT & BGWRITER STATS
-- =============================================================================

SELECT
    checkpoints_timed,
    checkpoints_req AS checkpoints_forced,
    round(checkpoints_req::numeric /
          NULLIF(checkpoints_timed + checkpoints_req, 0) * 100, 2) AS forced_pct,
    buffers_checkpoint,
    buffers_clean AS bgwriter_buffers,
    buffers_backend AS backend_writes,
    buffers_alloc,
    maxwritten_clean AS bgwriter_limit_stops,
    stats_reset
FROM pg_stat_bgwriter;


-- =============================================================================
-- 9. WAL STATISTICS
-- =============================================================================

-- WAL generation rate (PG14+)
SELECT
    wal_records,
    wal_fpi,
    pg_size_pretty(wal_bytes) AS wal_generated,
    wal_buffers_full,
    wal_write,
    wal_sync,
    stats_reset
FROM pg_stat_wal;

-- Current WAL position
SELECT
    pg_current_wal_lsn() AS current_lsn,
    pg_walfile_name(pg_current_wal_lsn()) AS current_wal_file;


-- =============================================================================
-- 10. CONFIGURATION OVERVIEW
-- =============================================================================

-- Key performance-related settings
SELECT name, setting, unit, source, short_desc
FROM pg_settings
WHERE name IN (
    'shared_buffers', 'work_mem', 'maintenance_work_mem',
    'effective_cache_size', 'wal_buffers',
    'max_connections', 'max_wal_size', 'min_wal_size',
    'checkpoint_timeout', 'checkpoint_completion_target',
    'random_page_cost', 'effective_io_concurrency',
    'autovacuum_max_workers', 'autovacuum_vacuum_scale_factor',
    'autovacuum_vacuum_cost_delay', 'autovacuum_vacuum_cost_limit',
    'shared_preload_libraries', 'huge_pages',
    'max_parallel_workers_per_gather', 'max_parallel_workers',
    'default_statistics_target', 'log_min_duration_statement'
)
ORDER BY name;
