-- =============================================================================
-- PostgreSQL Alerting Queries
-- =============================================================================
-- Each query returns a single numeric value suitable for threshold-based
-- alerting in monitoring systems (Prometheus postgres_exporter, Datadog,
-- Grafana, Zabbix, Nagios, etc.).
--
-- Integration patterns:
--   • Prometheus postgres_exporter: add as custom queries in queries.yaml
--   • Datadog: use as custom queries in the PostgreSQL integration config
--   • Direct: run via psql/cron and feed to your alerting pipeline
--
-- All queries are safe to run on replicas (read-only) unless noted.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Cache Hit Ratio
-- ---------------------------------------------------------------------------
-- What:  Fraction of block reads served from shared_buffers vs disk.
-- Why:   A low ratio means PostgreSQL is reading too much from disk.
--        This usually indicates shared_buffers is too small or the working
--        set exceeds available memory.
-- Threshold:  WARN < 0.99 (99%)  |  CRIT < 0.95 (95%)
-- Returns:    0.0 – 1.0  (1.0 = 100% cache hits)

SELECT
    CASE WHEN (blks_hit + blks_read) > 0
         THEN blks_hit::numeric / (blks_hit + blks_read)
         ELSE 1.0
    END AS cache_hit_ratio
FROM
    pg_stat_database
WHERE
    datname = current_database();


-- ---------------------------------------------------------------------------
-- 2. Connection Saturation
-- ---------------------------------------------------------------------------
-- What:  Percentage of max_connections currently in use.
-- Why:   When connections approach max_connections, new clients get
--        "FATAL: too many connections" errors.  High usage also indicates
--        connection pooling may be needed.
-- Threshold:  WARN > 0.80 (80%)  |  CRIT > 0.95 (95%)
-- Returns:    0.0 – 1.0

SELECT
    count(*)::numeric / current_setting('max_connections')::numeric
        AS connection_utilization
FROM
    pg_stat_activity;


-- ---------------------------------------------------------------------------
-- 3. Dead Tuple Buildup (worst table)
-- ---------------------------------------------------------------------------
-- What:  Ratio of dead tuples to live tuples for the most-bloated table.
-- Why:   Dead tuples are left behind by UPDATE/DELETE until VACUUM reclaims
--        them.  High ratios cause table bloat, slower sequential scans, and
--        wasted I/O.  Usually means autovacuum is falling behind.
-- Threshold:  WARN > 0.10 (10%)  |  CRIT > 0.30 (30%)
-- Returns:    0.0 – N  (ratio; 0.1 = 10% dead tuples)

SELECT
    coalesce(
        max(
            CASE WHEN n_live_tup > 0
                 THEN n_dead_tup::numeric / n_live_tup
                 ELSE 0
            END
        ),
        0
    ) AS worst_dead_tup_ratio
FROM
    pg_stat_user_tables
WHERE
    n_live_tup > 1000;          -- ignore tiny tables


-- ---------------------------------------------------------------------------
-- 4. Transaction ID Wraparound Warning
-- ---------------------------------------------------------------------------
-- What:  How close the oldest unfrozen transaction ID is to the 2-billion
--        wraparound limit.  When the limit is reached, PostgreSQL shuts
--        down to prevent data corruption.
-- Why:   If autovacuum cannot freeze old rows fast enough (e.g., long-running
--        transactions, disabled autovacuum), the age climbs toward the limit.
-- Threshold:  WARN > 500,000,000  |  CRIT > 1,000,000,000
--             (PostgreSQL forces shutdown at ~2,146,483,647)
-- Returns:    integer (transaction age)

SELECT
    max(age(datfrozenxid))::bigint AS max_txid_age
FROM
    pg_database
WHERE
    datallowconn;


-- ---------------------------------------------------------------------------
-- 5. Long-Running Queries
-- ---------------------------------------------------------------------------
-- What:  Number of queries running longer than 5 minutes.
-- Why:   Long-running queries hold locks, consume resources, prevent
--        autovacuum from cleaning up, and may indicate missing indexes
--        or runaway application logic.
-- Threshold:  WARN > 0  |  CRIT > 3
-- Returns:    integer (count)
-- Note:  Excludes autovacuum and replication processes.

SELECT
    count(*)::bigint AS long_running_queries
FROM
    pg_stat_activity
WHERE
    state = 'active'
    AND query NOT ILIKE '%pg_stat_activity%'         -- exclude this monitoring query
    AND backend_type = 'client backend'
    AND now() - query_start > interval '5 minutes';


-- ---------------------------------------------------------------------------
-- 6. Replication Lag (bytes)
-- ---------------------------------------------------------------------------
-- What:  Replication lag in bytes between the primary's current WAL position
--        and the most-lagging replica's replay position.
-- Why:   Growing lag means the replica is falling behind, which can cause
--        stale reads (if queries hit the replica) and risks data loss if
--        the primary fails.
-- Threshold:  WARN > 50 MB (52428800)  |  CRIT > 500 MB (524288000)
-- Returns:    bigint (bytes); 0 if no replicas are connected
-- Note:  Run this on the PRIMARY server only.

SELECT
    coalesce(
        max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),
        0
    )::bigint AS max_replication_lag_bytes
FROM
    pg_stat_replication;


-- ---------------------------------------------------------------------------
-- 7. Replication Lag (seconds)  [bonus]
-- ---------------------------------------------------------------------------
-- What:  Replication lag expressed as wall-clock seconds on the REPLICA.
-- Why:   Byte-based lag doesn't account for write rate; a 100 MB lag could
--        be 1 second on a high-throughput system or 1 hour on a quiet one.
--        Time-based lag gives a truer picture of staleness.
-- Threshold:  WARN > 30 seconds  |  CRIT > 300 seconds (5 min)
-- Returns:    numeric (seconds); NULL if not a replica
-- Note:  Run this on the REPLICA server.

SELECT
    coalesce(
        extract(epoch FROM (now() - pg_last_xact_replay_timestamp())),
        0
    )::numeric AS replication_lag_seconds;


-- ---------------------------------------------------------------------------
-- 8. Unused Indexes (count)  [bonus]
-- ---------------------------------------------------------------------------
-- What:  Number of non-unique, non-primary indexes that have never been
--        scanned since the last stats reset.
-- Why:   Unused indexes waste disk space and slow down writes (every INSERT,
--        UPDATE, DELETE must maintain every index).  Periodically review
--        and drop them.
-- Threshold:  INFO > 5  |  WARN > 20
-- Returns:    integer (count)
-- Note:  Only meaningful if pg_stat_user_indexes has been accumulating
--        stats for a representative period (reset with pg_stat_reset()).

SELECT
    count(*)::bigint AS unused_index_count
FROM
    pg_stat_user_indexes ui
    JOIN pg_index i ON i.indexrelid = ui.indexrelid
WHERE
    ui.idx_scan = 0
    AND NOT i.indisunique
    AND NOT i.indisprimary;


-- ---------------------------------------------------------------------------
-- 9. Temporary File Usage (bytes)  [bonus]
-- ---------------------------------------------------------------------------
-- What:  Total bytes written to temporary files since the last stats reset.
-- Why:   Temp files are created when work_mem is too small for a sort or
--        hash operation.  Excessive temp file usage degrades performance.
--        Consider increasing work_mem or optimizing queries.
-- Threshold:  WARN > 1 GB (1073741824)  |  CRIT > 10 GB (10737418240)
--             per stats period
-- Returns:    bigint (bytes)

SELECT
    coalesce(temp_bytes, 0)::bigint AS temp_bytes_total
FROM
    pg_stat_database
WHERE
    datname = current_database();


-- ---------------------------------------------------------------------------
-- 10. Blocked Queries (waiting on locks)  [bonus]
-- ---------------------------------------------------------------------------
-- What:  Number of queries currently blocked waiting to acquire a lock.
-- Why:   Lock contention causes application latency and can cascade into
--        connection exhaustion if many sessions pile up waiting.
-- Threshold:  WARN > 5  |  CRIT > 20
-- Returns:    integer (count)

SELECT
    count(*)::bigint AS blocked_queries
FROM
    pg_stat_activity
WHERE
    wait_event_type = 'Lock'
    AND state = 'active';
