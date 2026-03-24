-- ============================================================================
-- MySQL Monitoring & Diagnostic Queries
-- ============================================================================
-- A collection of production-ready queries for monitoring MySQL health.
-- Run these periodically or integrate into your monitoring system.
--
-- Sections:
--   1. Server Overview
--   2. InnoDB Buffer Pool
--   3. Connection & Thread Monitoring
--   4. Query Performance
--   5. Lock & Contention Monitoring
--   6. Replication Health
--   7. Table & Index Analysis
--   8. Disk & I/O Monitoring
--   9. Memory Tracking
--  10. Alerting Thresholds
-- ============================================================================


-- ============================================================================
-- 1. SERVER OVERVIEW
-- ============================================================================

-- Server version and uptime
SELECT
  VERSION() AS version,
  @@hostname AS hostname,
  @@port AS port,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Uptime') AS uptime_seconds,
  (SELECT ROUND(VARIABLE_VALUE / 86400, 1) FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Uptime') AS uptime_days;

-- Key global counters (QPS, TPS)
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Questions') AS total_questions,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Com_select') AS total_selects,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Com_insert') AS total_inserts,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Com_update') AS total_updates,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Com_delete') AS total_deletes;

-- Queries per second (instantaneous)
SELECT
  ROUND(
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Questions')
    /
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Uptime'),
    1
  ) AS avg_qps;


-- ============================================================================
-- 2. INNODB BUFFER POOL
-- ============================================================================

-- Buffer pool hit ratio (target: >99%)
SELECT
  ROUND(
    (1 - (
      (SELECT VARIABLE_VALUE FROM performance_schema.global_status
       WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads')
      /
      NULLIF((SELECT VARIABLE_VALUE FROM performance_schema.global_status
       WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests'), 0)
    )) * 100,
    4
  ) AS buffer_pool_hit_ratio_pct;

-- Buffer pool usage summary
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_total') AS pages_total,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_data') AS pages_data,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_dirty') AS pages_dirty,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_free') AS pages_free,
  ROUND(
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_dirty')
    /
    NULLIF((SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Innodb_buffer_pool_pages_total'), 0)
    * 100, 2
  ) AS dirty_pct;

-- Buffer pool wait-free reads vs disk reads
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests') AS logical_reads,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') AS disk_reads,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_buffer_pool_wait_free') AS wait_free;


-- ============================================================================
-- 3. CONNECTION & THREAD MONITORING
-- ============================================================================

-- Connection utilization
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_variables
   WHERE VARIABLE_NAME = 'max_connections') AS max_connections,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Threads_connected') AS current_connected,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Threads_running') AS currently_running,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Max_used_connections') AS peak_connections,
  ROUND(
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Max_used_connections')
    /
    (SELECT VARIABLE_VALUE FROM performance_schema.global_variables
     WHERE VARIABLE_NAME = 'max_connections')
    * 100, 1
  ) AS peak_utilization_pct;

-- Connections by user and host
SELECT USER, HOST, DB, COUNT(*) AS connections,
  SUM(CASE WHEN COMMAND = 'Sleep' THEN 1 ELSE 0 END) AS sleeping,
  SUM(CASE WHEN COMMAND != 'Sleep' THEN 1 ELSE 0 END) AS active
FROM information_schema.PROCESSLIST
GROUP BY USER, HOST, DB
ORDER BY connections DESC;

-- Thread cache efficiency
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Threads_created') AS threads_created,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Connections') AS total_connections,
  ROUND(
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Threads_created')
    /
    NULLIF((SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Connections'), 0)
    * 100, 2
  ) AS thread_cache_miss_pct;

-- Long-running queries (>30 seconds)
SELECT ID, USER, HOST, DB, TIME AS seconds, STATE,
  LEFT(INFO, 200) AS query_preview
FROM information_schema.PROCESSLIST
WHERE COMMAND != 'Sleep' AND TIME > 30
ORDER BY TIME DESC;


-- ============================================================================
-- 4. QUERY PERFORMANCE
-- ============================================================================

-- Top 10 queries by total execution time
SELECT
  LEFT(DIGEST_TEXT, 120) AS query_pattern,
  COUNT_STAR AS exec_count,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_sec,
  ROUND(AVG_TIMER_WAIT / 1e12, 4) AS avg_sec,
  ROUND(MAX_TIMER_WAIT / 1e12, 2) AS max_sec,
  SUM_ROWS_EXAMINED AS rows_examined,
  SUM_ROWS_SENT AS rows_sent
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME IS NOT NULL
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

-- Queries with worst rows examined to rows sent ratio
SELECT
  LEFT(DIGEST_TEXT, 120) AS query_pattern,
  COUNT_STAR AS exec_count,
  SUM_ROWS_EXAMINED,
  SUM_ROWS_SENT,
  ROUND(SUM_ROWS_EXAMINED / NULLIF(SUM_ROWS_SENT, 0)) AS examine_ratio,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_sec
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_ROWS_SENT > 0
ORDER BY SUM_ROWS_EXAMINED / NULLIF(SUM_ROWS_SENT, 0) DESC
LIMIT 10;

-- Queries creating temporary tables on disk
SELECT
  LEFT(DIGEST_TEXT, 120) AS query_pattern,
  COUNT_STAR AS exec_count,
  SUM_CREATED_TMP_TABLES AS tmp_tables,
  SUM_CREATED_TMP_DISK_TABLES AS disk_tmp_tables,
  ROUND(SUM_TIMER_WAIT / 1e12, 2) AS total_sec
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_CREATED_TMP_DISK_TABLES > 0
ORDER BY SUM_CREATED_TMP_DISK_TABLES DESC
LIMIT 10;

-- Slow query rate
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Slow_queries') AS slow_queries,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Questions') AS total_queries,
  ROUND(
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Slow_queries')
    /
    NULLIF((SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Questions'), 0)
    * 100, 4
  ) AS slow_query_pct;


-- ============================================================================
-- 5. LOCK & CONTENTION MONITORING
-- ============================================================================

-- Current lock waits
SELECT
  r.trx_id AS waiting_trx,
  r.trx_mysql_thread_id AS waiting_pid,
  LEFT(r.trx_query, 100) AS waiting_query,
  b.trx_id AS blocking_trx,
  b.trx_mysql_thread_id AS blocking_pid,
  LEFT(b.trx_query, 100) AS blocking_query,
  TIMESTAMPDIFF(SECOND, r.trx_wait_started, NOW()) AS wait_seconds
FROM performance_schema.data_lock_waits w
JOIN information_schema.INNODB_TRX r
  ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
JOIN information_schema.INNODB_TRX b
  ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID;

-- InnoDB row lock statistics
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_row_lock_waits') AS row_lock_waits,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_row_lock_time') AS total_lock_time_ms,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_row_lock_time_avg') AS avg_lock_time_ms,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_row_lock_time_max') AS max_lock_time_ms;

-- Long-running transactions (>60 seconds)
SELECT
  trx_id, trx_state,
  TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_seconds,
  trx_rows_modified, trx_tables_in_use, trx_tables_locked,
  LEFT(trx_query, 100) AS current_query
FROM information_schema.INNODB_TRX
WHERE TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 60
ORDER BY trx_started ASC;

-- Deadlock count
SELECT COUNT AS deadlocks_total
FROM information_schema.INNODB_METRICS
WHERE NAME = 'lock_deadlocks';

-- History list length (undo log purge lag)
SELECT COUNT AS history_list_length
FROM information_schema.INNODB_METRICS
WHERE NAME = 'trx_rseg_history_len';


-- ============================================================================
-- 6. REPLICATION HEALTH
-- ============================================================================

-- Replication lag and status (run on replica)
-- SHOW REPLICA STATUS\G

-- GTID-based replication progress
SELECT
  @@global.gtid_executed AS executed_gtids,
  (SELECT RECEIVED_TRANSACTION_SET
   FROM performance_schema.replication_connection_status
   LIMIT 1) AS received_gtids;

-- Per-worker replication status
SELECT
  WORKER_ID,
  LAST_APPLIED_TRANSACTION,
  APPLYING_TRANSACTION,
  LAST_APPLIED_TRANSACTION_END_APPLY_TIMESTAMP,
  LAST_ERROR_NUMBER,
  LAST_ERROR_MESSAGE
FROM performance_schema.replication_applier_status_by_worker
ORDER BY WORKER_ID;


-- ============================================================================
-- 7. TABLE & INDEX ANALYSIS
-- ============================================================================

-- Largest tables by data + index size
SELECT
  TABLE_SCHEMA,
  TABLE_NAME,
  TABLE_ROWS,
  ROUND(DATA_LENGTH / 1024 / 1024, 2) AS data_mb,
  ROUND(INDEX_LENGTH / 1024 / 1024, 2) AS index_mb,
  ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS total_mb,
  ROUND(DATA_FREE / 1024 / 1024, 2) AS fragmented_mb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
ORDER BY DATA_LENGTH + INDEX_LENGTH DESC
LIMIT 20;

-- Unused indexes (safe to drop)
SELECT
  s.TABLE_SCHEMA, s.TABLE_NAME, s.INDEX_NAME,
  s.COLUMN_NAME, s.SEQ_IN_INDEX
FROM information_schema.STATISTICS s
LEFT JOIN performance_schema.table_io_waits_summary_by_index_usage w
  ON s.TABLE_SCHEMA = w.OBJECT_SCHEMA
  AND s.TABLE_NAME = w.OBJECT_NAME
  AND s.INDEX_NAME = w.INDEX_NAME
WHERE w.COUNT_READ = 0
  AND s.INDEX_NAME != 'PRIMARY'
  AND s.TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema')
ORDER BY s.TABLE_SCHEMA, s.TABLE_NAME, s.INDEX_NAME;

-- Tables with no primary key (anti-pattern)
SELECT
  t.TABLE_SCHEMA, t.TABLE_NAME, t.ENGINE, t.TABLE_ROWS
FROM information_schema.TABLES t
LEFT JOIN information_schema.TABLE_CONSTRAINTS c
  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA
  AND t.TABLE_NAME = c.TABLE_NAME
  AND c.CONSTRAINT_TYPE = 'PRIMARY KEY'
WHERE c.CONSTRAINT_NAME IS NULL
  AND t.TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema', 'information_schema')
  AND t.TABLE_TYPE = 'BASE TABLE';

-- Auto-increment approaching limit
SELECT
  TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME,
  DATA_TYPE, COLUMN_TYPE,
  CASE DATA_TYPE
    WHEN 'tinyint' THEN IF(COLUMN_TYPE LIKE '%unsigned%', 255, 127)
    WHEN 'smallint' THEN IF(COLUMN_TYPE LIKE '%unsigned%', 65535, 32767)
    WHEN 'mediumint' THEN IF(COLUMN_TYPE LIKE '%unsigned%', 16777215, 8388607)
    WHEN 'int' THEN IF(COLUMN_TYPE LIKE '%unsigned%', 4294967295, 2147483647)
    WHEN 'bigint' THEN IF(COLUMN_TYPE LIKE '%unsigned%', 18446744073709551615, 9223372036854775807)
  END AS max_value,
  AUTO_INCREMENT AS current_value,
  ROUND(AUTO_INCREMENT /
    CASE DATA_TYPE
      WHEN 'int' THEN IF(COLUMN_TYPE LIKE '%unsigned%', 4294967295, 2147483647)
      WHEN 'bigint' THEN IF(COLUMN_TYPE LIKE '%unsigned%', 18446744073709551615, 9223372036854775807)
      ELSE 2147483647
    END * 100, 2
  ) AS usage_pct
FROM information_schema.COLUMNS c
JOIN information_schema.TABLES t USING (TABLE_SCHEMA, TABLE_NAME)
WHERE c.EXTRA LIKE '%auto_increment%'
  AND t.AUTO_INCREMENT IS NOT NULL
  AND t.TABLE_SCHEMA NOT IN ('mysql', 'sys', 'performance_schema')
ORDER BY usage_pct DESC;


-- ============================================================================
-- 8. DISK & I/O MONITORING
-- ============================================================================

-- InnoDB data I/O rates
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_data_reads') AS data_reads,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_data_writes') AS data_writes,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_data_read') AS bytes_read,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_data_written') AS bytes_written,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_data_pending_reads') AS pending_reads,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_data_pending_writes') AS pending_writes;

-- Redo log write rate
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_os_log_written') AS log_bytes_written,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_log_writes') AS log_writes,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Innodb_os_log_pending_writes') AS pending_log_writes;

-- Top files by I/O (Performance Schema)
SELECT
  FILE_NAME,
  COUNT_READ, COUNT_WRITE,
  ROUND(SUM_NUMBER_OF_BYTES_READ / 1024 / 1024, 2) AS read_mb,
  ROUND(SUM_NUMBER_OF_BYTES_WRITE / 1024 / 1024, 2) AS write_mb,
  ROUND(SUM_TIMER_READ / 1e12, 2) AS read_wait_sec,
  ROUND(SUM_TIMER_WRITE / 1e12, 2) AS write_wait_sec
FROM performance_schema.file_summary_by_instance
WHERE COUNT_READ + COUNT_WRITE > 0
ORDER BY SUM_TIMER_READ + SUM_TIMER_WRITE DESC
LIMIT 10;

-- Temp tables going to disk ratio
SELECT
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Created_tmp_tables') AS tmp_tables,
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Created_tmp_disk_tables') AS tmp_disk_tables,
  ROUND(
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Created_tmp_disk_tables')
    /
    NULLIF((SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Created_tmp_tables'), 0)
    * 100, 2
  ) AS disk_tmp_pct;


-- ============================================================================
-- 9. MEMORY TRACKING
-- ============================================================================

-- Top memory consumers
SELECT
  EVENT_NAME,
  CURRENT_COUNT_USED AS alloc_count,
  ROUND(CURRENT_NUMBER_OF_BYTES_USED / 1024 / 1024, 2) AS current_mb,
  ROUND(HIGH_NUMBER_OF_BYTES_USED / 1024 / 1024, 2) AS peak_mb
FROM performance_schema.memory_summary_global_by_event_name
WHERE CURRENT_NUMBER_OF_BYTES_USED > 1024 * 1024  -- > 1MB
ORDER BY CURRENT_NUMBER_OF_BYTES_USED DESC
LIMIT 15;

-- Total tracked memory usage
SELECT
  ROUND(SUM(CURRENT_NUMBER_OF_BYTES_USED) / 1024 / 1024 / 1024, 2)
    AS total_tracked_gb
FROM performance_schema.memory_summary_global_by_event_name;

-- Per-connection memory (top consumers)
SELECT
  t.PROCESSLIST_ID AS conn_id,
  t.PROCESSLIST_USER AS user,
  t.PROCESSLIST_HOST AS host,
  ROUND(SUM(m.CURRENT_NUMBER_OF_BYTES_USED) / 1024 / 1024, 2) AS current_mb
FROM performance_schema.memory_summary_by_thread_by_event_name m
JOIN performance_schema.threads t ON m.THREAD_ID = t.THREAD_ID
WHERE t.TYPE = 'FOREGROUND'
GROUP BY t.THREAD_ID
HAVING current_mb > 1
ORDER BY current_mb DESC
LIMIT 10;


-- ============================================================================
-- 10. ALERTING THRESHOLDS
-- ============================================================================
-- Use these queries in monitoring systems (Prometheus, Datadog, Zabbix, etc.)
-- to trigger alerts when thresholds are breached.

-- ALERT: Buffer pool hit ratio < 99%
SELECT IF(
  (1 - (
    (SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads')
    /
    NULLIF((SELECT VARIABLE_VALUE FROM performance_schema.global_status
     WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests'), 0)
  )) * 100 < 99,
  'ALERT: Buffer pool hit ratio below 99%',
  'OK'
) AS buffer_pool_check;

-- ALERT: Connection usage > 80%
SELECT IF(
  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
   WHERE VARIABLE_NAME = 'Threads_connected')
  /
  (SELECT VARIABLE_VALUE FROM performance_schema.global_variables
   WHERE VARIABLE_NAME = 'max_connections')
  > 0.8,
  'ALERT: Connection usage above 80%',
  'OK'
) AS connection_check;

-- ALERT: Replication lag > 30 seconds
-- (run on replica)
-- SELECT IF(
--   (SELECT VARIABLE_VALUE FROM performance_schema.global_status
--    WHERE VARIABLE_NAME = 'Seconds_Behind_Source') > 30,
--   'ALERT: Replication lag above 30 seconds',
--   'OK'
-- ) AS replication_check;

-- ALERT: History list length > 100000
SELECT IF(
  (SELECT COUNT FROM information_schema.INNODB_METRICS
   WHERE NAME = 'trx_rseg_history_len') > 100000,
  'ALERT: History list length above 100000 — long-running transactions?',
  'OK'
) AS history_list_check;

-- ALERT: Deadlocks in last interval
-- Track deadlock count between polling intervals
-- SELECT COUNT AS current_deadlocks
-- FROM information_schema.INNODB_METRICS
-- WHERE NAME = 'lock_deadlocks';
