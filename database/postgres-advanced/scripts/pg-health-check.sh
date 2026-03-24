#!/usr/bin/env bash
# =============================================================================
# pg-health-check.sh — PostgreSQL Health Check Script
# =============================================================================
# Usage: ./pg-health-check.sh [-h HOST] [-p PORT] [-d DATABASE] [-U USER]
#
# Performs a comprehensive health check including:
#   - Database size and growth
#   - Table bloat analysis
#   - Index usage statistics
#   - Cache hit ratio
#   - Long-running queries
#   - Replication status
#   - Connection usage
#   - Vacuum status
#
# Requirements: psql client, access to pg_stat_* views
# =============================================================================

set -euo pipefail

# Defaults
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-postgres}"
PGUSER="${PGUSER:-postgres}"

# Parse arguments
while getopts "h:p:d:U:" opt; do
    case $opt in
        h) PGHOST="$OPTARG" ;;
        p) PGPORT="$OPTARG" ;;
        d) PGDATABASE="$OPTARG" ;;
        U) PGUSER="$OPTARG" ;;
        *) echo "Usage: $0 [-h HOST] [-p PORT] [-d DATABASE] [-U USER]"; exit 1 ;;
    esac
done

PSQL="psql -h $PGHOST -p $PGPORT -d $PGDATABASE -U $PGUSER -X --no-align --tuples-only"
PSQL_PRETTY="psql -h $PGHOST -p $PGPORT -d $PGDATABASE -U $PGUSER -X"

header() {
    echo ""
    echo "============================================================================="
    echo "  $1"
    echo "============================================================================="
}

# --- Server Info ---
header "SERVER INFORMATION"
$PSQL_PRETTY -c "
SELECT
    version() AS postgresql_version;
"
$PSQL_PRETTY -c "
SELECT
    pg_postmaster_start_time() AS server_started,
    age(now(), pg_postmaster_start_time()) AS uptime,
    current_setting('max_connections') AS max_connections,
    (SELECT count(*) FROM pg_stat_activity) AS current_connections;
"

# --- Database Size ---
header "DATABASE SIZES"
$PSQL_PRETTY -c "
SELECT
    datname AS database,
    pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
WHERE NOT datistemplate
ORDER BY pg_database_size(datname) DESC;
"

# --- Top 10 Largest Tables ---
header "TOP 10 LARGEST TABLES"
$PSQL_PRETTY -c "
SELECT
    schemaname || '.' || tablename AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename) -
                   pg_relation_size(schemaname || '.' || tablename)) AS index_size
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
LIMIT 10;
"

# --- Table Bloat ---
header "TABLE BLOAT (tables with >10% dead tuples)"
$PSQL_PRETTY -c "
SELECT
    schemaname || '.' || relname AS table_name,
    n_live_tup,
    n_dead_tup,
    CASE WHEN n_live_tup > 0
         THEN round(n_dead_tup::numeric / n_live_tup * 100, 2)
         ELSE 0 END AS dead_pct,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
  AND (n_live_tup = 0 OR n_dead_tup::numeric / n_live_tup > 0.1)
ORDER BY n_dead_tup DESC
LIMIT 15;
"

# --- Index Usage ---
header "UNUSED INDEXES (0 scans, >1MB)"
$PSQL_PRETTY -c "
SELECT
    schemaname || '.' || indexrelname AS index_name,
    schemaname || '.' || relname AS table_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan AS scans
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND pg_relation_size(indexrelid) > 1048576
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 15;
"

# --- Index Hit Ratio ---
header "INDEX USAGE RATIO BY TABLE"
$PSQL_PRETTY -c "
SELECT
    schemaname || '.' || relname AS table_name,
    seq_scan,
    idx_scan,
    CASE WHEN (seq_scan + idx_scan) > 0
         THEN round(idx_scan::numeric / (seq_scan + idx_scan) * 100, 2)
         ELSE 0 END AS idx_usage_pct,
    n_live_tup AS row_count
FROM pg_stat_user_tables
WHERE (seq_scan + idx_scan) > 100
ORDER BY idx_usage_pct ASC
LIMIT 15;
"

# --- Cache Hit Ratio ---
header "CACHE HIT RATIO"
$PSQL_PRETTY -c "
SELECT
    'Table Cache' AS type,
    sum(heap_blks_hit) AS hits,
    sum(heap_blks_read) AS reads,
    round(sum(heap_blks_hit)::numeric /
          NULLIF(sum(heap_blks_hit) + sum(heap_blks_read), 0) * 100, 2) AS hit_ratio
FROM pg_statio_user_tables
UNION ALL
SELECT
    'Index Cache' AS type,
    sum(idx_blks_hit) AS hits,
    sum(idx_blks_read) AS reads,
    round(sum(idx_blks_hit)::numeric /
          NULLIF(sum(idx_blks_hit) + sum(idx_blks_read), 0) * 100, 2) AS hit_ratio
FROM pg_statio_user_indexes;
"

# --- Long-Running Queries ---
header "LONG-RUNNING QUERIES (>60 seconds)"
$PSQL_PRETTY -c "
SELECT
    pid,
    usename,
    application_name,
    state,
    age(now(), query_start) AS duration,
    LEFT(query, 100) AS query
FROM pg_stat_activity
WHERE state != 'idle'
  AND query NOT ILIKE '%pg_stat_activity%'
  AND age(now(), query_start) > interval '60 seconds'
ORDER BY query_start
LIMIT 10;
"

# --- Idle in Transaction ---
header "IDLE IN TRANSACTION SESSIONS"
$PSQL_PRETTY -c "
SELECT
    pid,
    usename,
    application_name,
    age(now(), xact_start) AS transaction_duration,
    age(now(), state_change) AS idle_duration,
    LEFT(query, 100) AS last_query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY xact_start
LIMIT 10;
"

# --- Connection Usage ---
header "CONNECTION USAGE"
$PSQL_PRETTY -c "
SELECT
    state,
    count(*) AS connections,
    round(count(*)::numeric /
          current_setting('max_connections')::numeric * 100, 1) AS pct_of_max
FROM pg_stat_activity
GROUP BY state
ORDER BY connections DESC;
"

# --- Replication Status ---
header "REPLICATION STATUS"
REPL_COUNT=$($PSQL -c "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null || echo "0")
if [ "$REPL_COUNT" -gt 0 ] 2>/dev/null; then
    $PSQL_PRETTY -c "
    SELECT
        client_addr,
        application_name,
        state,
        sync_state,
        pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replay_lag_bytes,
        replay_lag AS replay_lag_time
    FROM pg_stat_replication;
    "
else
    echo "  No active replication connections."
fi

# --- Replication Slots ---
SLOT_COUNT=$($PSQL -c "SELECT count(*) FROM pg_replication_slots;" 2>/dev/null || echo "0")
if [ "$SLOT_COUNT" -gt 0 ] 2>/dev/null; then
    header "REPLICATION SLOTS"
    $PSQL_PRETTY -c "
    SELECT
        slot_name,
        slot_type,
        active,
        pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
    FROM pg_replication_slots
    ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
    "
fi

# --- XID Wraparound ---
header "TRANSACTION ID WRAPAROUND STATUS"
$PSQL_PRETTY -c "
SELECT
    datname,
    age(datfrozenxid) AS xid_age,
    round(age(datfrozenxid)::numeric / 2000000000 * 100, 2) AS pct_to_wraparound,
    CASE
        WHEN age(datfrozenxid) > 1000000000 THEN 'CRITICAL'
        WHEN age(datfrozenxid) > 500000000 THEN 'WARNING'
        ELSE 'OK'
    END AS status
FROM pg_database
WHERE NOT datistemplate
ORDER BY age(datfrozenxid) DESC;
"

# --- Checkpoint Stats ---
header "CHECKPOINT STATISTICS"
$PSQL_PRETTY -c "
SELECT
    checkpoints_timed,
    checkpoints_req AS checkpoints_forced,
    buffers_checkpoint,
    buffers_clean AS bgwriter_buffers,
    buffers_backend AS backend_buffers,
    maxwritten_clean AS bgwriter_stops,
    CASE WHEN checkpoints_timed + checkpoints_req > 0
         THEN round(checkpoints_req::numeric /
                     (checkpoints_timed + checkpoints_req) * 100, 2)
         ELSE 0 END AS forced_pct
FROM pg_stat_bgwriter;
"

header "HEALTH CHECK COMPLETE"
echo "  Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""
