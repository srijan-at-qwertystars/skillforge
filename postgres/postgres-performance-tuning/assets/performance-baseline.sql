-- =============================================================================
-- Performance Baseline Capture
-- =============================================================================
-- Run this script periodically (daily, weekly, or before/after changes) to
-- snapshot key performance metrics.  Compare snapshots over time to detect
-- regressions, validate tuning changes, and identify emerging problems.
--
-- Prerequisites:
--   • pg_stat_statements extension loaded (shared_preload_libraries)
--   • track_io_timing = on  (for I/O timing in pg_stat_statements)
--   • Superuser or pg_monitor role for full visibility
--
-- Usage:
--   psql -d mydb -f performance-baseline.sql
--
-- Each run creates a timestamped snapshot.  Query the baseline tables to
-- compare any two points in time.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- Step 1: Create the baseline schema and tables (idempotent)
-- ---------------------------------------------------------------------------
-- All baseline data lives in a dedicated schema to avoid polluting public.

CREATE SCHEMA IF NOT EXISTS perf_baseline;

-- Snapshot metadata — one row per capture run.
CREATE TABLE IF NOT EXISTS perf_baseline.snapshots (
    snapshot_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    captured_at     timestamptz NOT NULL DEFAULT now(),
    pg_version      text,
    description     text                    -- optional: "before index change", etc.
);

-- Top queries from pg_stat_statements.
CREATE TABLE IF NOT EXISTS perf_baseline.top_queries (
    snapshot_id         bigint NOT NULL REFERENCES perf_baseline.snapshots(snapshot_id),
    queryid             bigint,
    query               text,
    calls               bigint,
    total_exec_time_ms  double precision,   -- total execution time across all calls
    mean_exec_time_ms   double precision,
    max_exec_time_ms    double precision,
    stddev_exec_time_ms double precision,
    rows_returned       bigint,
    shared_blks_hit     bigint,
    shared_blks_read    bigint,
    blk_read_time_ms    double precision,   -- requires track_io_timing = on
    blk_write_time_ms   double precision,
    temp_blks_read      bigint,
    temp_blks_written   bigint,
    cache_hit_ratio     double precision
);

-- Table-level statistics.
CREATE TABLE IF NOT EXISTS perf_baseline.table_stats (
    snapshot_id         bigint NOT NULL REFERENCES perf_baseline.snapshots(snapshot_id),
    schema_name         text,
    table_name          text,
    table_size          bigint,             -- bytes (table only, no indexes/toast)
    total_size          bigint,             -- bytes (table + indexes + toast)
    row_estimate        real,
    seq_scan            bigint,
    seq_tup_read        bigint,
    idx_scan            bigint,
    idx_tup_fetch       bigint,
    n_tup_ins           bigint,
    n_tup_upd           bigint,
    n_tup_del           bigint,
    n_live_tup          bigint,
    n_dead_tup          bigint,
    dead_tup_ratio      double precision,
    last_vacuum         timestamptz,
    last_autovacuum     timestamptz,
    last_analyze        timestamptz,
    last_autoanalyze    timestamptz
);

-- Index usage statistics.
CREATE TABLE IF NOT EXISTS perf_baseline.index_stats (
    snapshot_id         bigint NOT NULL REFERENCES perf_baseline.snapshots(snapshot_id),
    schema_name         text,
    table_name          text,
    index_name          text,
    index_size          bigint,             -- bytes
    idx_scan            bigint,             -- number of index scans initiated
    idx_tup_read        bigint,             -- index entries returned by scans
    idx_tup_fetch       bigint,             -- live rows fetched by index scans
    is_unique           boolean,
    is_primary          boolean,
    is_valid            boolean
);

-- Database-wide aggregate metrics.
CREATE TABLE IF NOT EXISTS perf_baseline.database_stats (
    snapshot_id         bigint NOT NULL REFERENCES perf_baseline.snapshots(snapshot_id),
    database_name       text,
    cache_hit_ratio     double precision,
    xact_commit         bigint,
    xact_rollback       bigint,
    blks_read           bigint,
    blks_hit            bigint,
    tup_returned        bigint,
    tup_fetched         bigint,
    tup_inserted        bigint,
    tup_updated         bigint,
    tup_deleted         bigint,
    conflicts           bigint,
    temp_files          bigint,
    temp_bytes          bigint,
    deadlocks           bigint,
    db_size             bigint
);


-- ---------------------------------------------------------------------------
-- Step 2: Create a new snapshot
-- ---------------------------------------------------------------------------

INSERT INTO perf_baseline.snapshots (pg_version)
VALUES (version());

-- Store the snapshot ID for use in subsequent INSERTs.
-- Using a CTE approach so the entire script runs in one pass.

DO $$
DECLARE
    v_snap_id bigint;
BEGIN
    -- Get the snapshot we just created.
    SELECT max(snapshot_id) INTO v_snap_id FROM perf_baseline.snapshots;

    -- -----------------------------------------------------------------
    -- Section A: Top Queries (pg_stat_statements)
    -- -----------------------------------------------------------------
    -- Captures the top 100 queries by total execution time.
    -- These are the queries consuming the most database resources.
    -- Compare across snapshots to catch regressions.

    INSERT INTO perf_baseline.top_queries
    SELECT
        v_snap_id,
        s.queryid,
        left(s.query, 2000),                       -- truncate very long queries
        s.calls,
        s.total_exec_time       AS total_exec_time_ms,
        s.mean_exec_time        AS mean_exec_time_ms,
        s.max_exec_time         AS max_exec_time_ms,
        s.stddev_exec_time      AS stddev_exec_time_ms,
        s.rows,
        s.shared_blks_hit,
        s.shared_blks_read,
        s.blk_read_time         AS blk_read_time_ms,
        s.blk_write_time        AS blk_write_time_ms,
        s.temp_blks_read,
        s.temp_blks_written,
        CASE WHEN (s.shared_blks_hit + s.shared_blks_read) > 0
             THEN s.shared_blks_hit::double precision
                  / (s.shared_blks_hit + s.shared_blks_read)
             ELSE 1.0
        END AS cache_hit_ratio
    FROM
        pg_stat_statements s
    ORDER BY
        s.total_exec_time DESC
    LIMIT 100;

    -- -----------------------------------------------------------------
    -- Section B: Table Statistics
    -- -----------------------------------------------------------------
    -- Captures size, row counts, scan patterns, and dead tuple info
    -- for every user table.  Use this to:
    --   • Spot tables with high dead tuple ratios (need VACUUM tuning)
    --   • Identify tables doing mostly seq scans (may need indexes)
    --   • Track table growth over time

    INSERT INTO perf_baseline.table_stats
    SELECT
        v_snap_id,
        n.nspname                                       AS schema_name,
        c.relname                                       AS table_name,
        pg_table_size(c.oid)                            AS table_size,
        pg_total_relation_size(c.oid)                   AS total_size,
        c.reltuples                                     AS row_estimate,
        coalesce(s.seq_scan, 0),
        coalesce(s.seq_tup_read, 0),
        coalesce(s.idx_scan, 0),
        coalesce(s.idx_tup_fetch, 0),
        coalesce(s.n_tup_ins, 0),
        coalesce(s.n_tup_upd, 0),
        coalesce(s.n_tup_del, 0),
        coalesce(s.n_live_tup, 0),
        coalesce(s.n_dead_tup, 0),
        CASE WHEN coalesce(s.n_live_tup, 0) > 0
             THEN coalesce(s.n_dead_tup, 0)::double precision / s.n_live_tup
             ELSE 0
        END                                             AS dead_tup_ratio,
        s.last_vacuum,
        s.last_autovacuum,
        s.last_analyze,
        s.last_autoanalyze
    FROM
        pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_stat_user_tables s
            ON s.relid = c.oid
    WHERE
        c.relkind = 'r'                                 -- ordinary tables
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'perf_baseline');

    -- -----------------------------------------------------------------
    -- Section C: Index Usage Statistics
    -- -----------------------------------------------------------------
    -- Captures scan counts and sizes for every index.  Use this to:
    --   • Find unused indexes (idx_scan = 0) that waste write I/O and space
    --   • Find heavily-used indexes that may benefit from being smaller
    --   • Track index growth over time

    INSERT INTO perf_baseline.index_stats
    SELECT
        v_snap_id,
        n.nspname                                       AS schema_name,
        t.relname                                       AS table_name,
        i.relname                                       AS index_name,
        pg_relation_size(i.oid)                         AS index_size,
        coalesce(s.idx_scan, 0),
        coalesce(s.idx_tup_read, 0),
        coalesce(s.idx_tup_fetch, 0),
        ix.indisunique                                  AS is_unique,
        ix.indisprimary                                 AS is_primary,
        ix.indisvalid                                   AS is_valid
    FROM
        pg_class i
        JOIN pg_namespace n ON n.oid = i.relnamespace
        JOIN pg_index ix ON ix.indexrelid = i.oid
        JOIN pg_class t ON t.oid = ix.indrelid
        LEFT JOIN pg_stat_user_indexes s
            ON s.indexrelid = i.oid
    WHERE
        i.relkind = 'i'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'perf_baseline');

    -- -----------------------------------------------------------------
    -- Section D: Database-Wide Aggregate Metrics
    -- -----------------------------------------------------------------
    -- High-level database health metrics.
    -- Cache hit ratio < 99% suggests shared_buffers may be too small.

    INSERT INTO perf_baseline.database_stats
    SELECT
        v_snap_id,
        d.datname,
        CASE WHEN (s.blks_hit + s.blks_read) > 0
             THEN s.blks_hit::double precision / (s.blks_hit + s.blks_read)
             ELSE 1.0
        END                                             AS cache_hit_ratio,
        s.xact_commit,
        s.xact_rollback,
        s.blks_read,
        s.blks_hit,
        s.tup_returned,
        s.tup_fetched,
        s.tup_inserted,
        s.tup_updated,
        s.tup_deleted,
        s.conflicts,
        s.temp_files,
        s.temp_bytes,
        s.deadlocks,
        pg_database_size(d.oid)                         AS db_size
    FROM
        pg_stat_database s
        JOIN pg_database d ON d.oid = s.datid
    WHERE
        d.datname = current_database();

    RAISE NOTICE 'Performance baseline snapshot % captured at %',
        v_snap_id, now();
END $$;


-- ---------------------------------------------------------------------------
-- Step 3: Useful comparison queries (run manually)
-- ---------------------------------------------------------------------------

-- Compare top queries between two snapshots (e.g., snapshot 1 vs 2):
--
-- SELECT
--     coalesce(a.queryid, b.queryid)      AS queryid,
--     left(coalesce(a.query, b.query), 80) AS query_preview,
--     a.calls                              AS calls_before,
--     b.calls                              AS calls_after,
--     a.mean_exec_time_ms                  AS mean_ms_before,
--     b.mean_exec_time_ms                  AS mean_ms_after,
--     round((b.mean_exec_time_ms - a.mean_exec_time_ms)
--           / nullif(a.mean_exec_time_ms, 0) * 100, 1) AS pct_change
-- FROM
--     perf_baseline.top_queries a
--     FULL OUTER JOIN perf_baseline.top_queries b
--         ON a.queryid = b.queryid
-- WHERE
--     a.snapshot_id = 1
--     AND b.snapshot_id = 2
-- ORDER BY
--     b.total_exec_time_ms DESC NULLS LAST
-- LIMIT 20;

-- Find tables with growing dead tuple ratios:
--
-- SELECT
--     a.schema_name, a.table_name,
--     a.dead_tup_ratio AS ratio_before,
--     b.dead_tup_ratio AS ratio_after
-- FROM
--     perf_baseline.table_stats a
--     JOIN perf_baseline.table_stats b
--         ON a.schema_name = b.schema_name
--         AND a.table_name = b.table_name
-- WHERE
--     a.snapshot_id = 1 AND b.snapshot_id = 2
--     AND b.dead_tup_ratio > a.dead_tup_ratio
-- ORDER BY
--     b.dead_tup_ratio DESC;

-- Find unused indexes across snapshots (never scanned):
--
-- SELECT
--     schema_name, table_name, index_name,
--     pg_size_pretty(index_size) AS size,
--     is_unique, is_primary
-- FROM
--     perf_baseline.index_stats
-- WHERE
--     snapshot_id = (SELECT max(snapshot_id) FROM perf_baseline.snapshots)
--     AND idx_scan = 0
--     AND NOT is_primary
--     AND NOT is_unique
-- ORDER BY
--     index_size DESC;

-- Track database cache hit ratio over time:
--
-- SELECT
--     s.captured_at,
--     d.cache_hit_ratio,
--     pg_size_pretty(d.db_size) AS db_size,
--     d.deadlocks,
--     d.temp_files
-- FROM
--     perf_baseline.database_stats d
--     JOIN perf_baseline.snapshots s ON s.snapshot_id = d.snapshot_id
-- ORDER BY
--     s.captured_at;


-- ---------------------------------------------------------------------------
-- Maintenance: Clean up old snapshots
-- ---------------------------------------------------------------------------
-- Delete baseline data older than 180 days to prevent unbounded growth.
--
-- DELETE FROM perf_baseline.top_queries
-- WHERE snapshot_id IN (
--     SELECT snapshot_id FROM perf_baseline.snapshots
--     WHERE captured_at < now() - interval '180 days'
-- );
-- DELETE FROM perf_baseline.table_stats    WHERE snapshot_id IN (...);
-- DELETE FROM perf_baseline.index_stats    WHERE snapshot_id IN (...);
-- DELETE FROM perf_baseline.database_stats WHERE snapshot_id IN (...);
-- DELETE FROM perf_baseline.snapshots      WHERE captured_at < now() - interval '180 days';
