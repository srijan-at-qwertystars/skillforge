#!/usr/bin/env bash
# =============================================================================
# pg-slow-query-report.sh — PostgreSQL Slow Query Report
# =============================================================================
# Usage: ./pg-slow-query-report.sh [-h HOST] [-p PORT] [-d DATABASE] [-U USER]
#                                  [-n TOP_N] [-m MIN_CALLS]
#
# Generates a comprehensive slow query report from pg_stat_statements:
#   - Top queries by total execution time
#   - Top queries by mean execution time
#   - Queries with worst cache hit ratio
#   - Queries generating the most temp file I/O
#   - Queries with most rows processed
#   - Recommendations for each problem query
#
# Requirements:
#   - psql client
#   - pg_stat_statements extension enabled
# =============================================================================

set -euo pipefail

# Defaults
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-postgres}"
PGUSER="${PGUSER:-postgres}"
TOP_N=10
MIN_CALLS=5

# Parse arguments
while getopts "h:p:d:U:n:m:" opt; do
    case $opt in
        h) PGHOST="$OPTARG" ;;
        p) PGPORT="$OPTARG" ;;
        d) PGDATABASE="$OPTARG" ;;
        U) PGUSER="$OPTARG" ;;
        n) TOP_N="$OPTARG" ;;
        m) MIN_CALLS="$OPTARG" ;;
        *) echo "Usage: $0 [-h HOST] [-p PORT] [-d DATABASE] [-U USER] [-n TOP_N] [-m MIN_CALLS]"
           exit 1 ;;
    esac
done

PSQL="psql -h $PGHOST -p $PGPORT -d $PGDATABASE -U $PGUSER -X"

header() {
    echo ""
    echo "============================================================================="
    echo "  $1"
    echo "============================================================================="
}

# Check if pg_stat_statements is available
EXT_CHECK=$($PSQL --no-align --tuples-only -c \
    "SELECT count(*) FROM pg_extension WHERE extname = 'pg_stat_statements';" 2>/dev/null)

if [ "$EXT_CHECK" != "1" ]; then
    echo "ERROR: pg_stat_statements extension is not installed."
    echo ""
    echo "To install:"
    echo "  1. Add to postgresql.conf: shared_preload_libraries = 'pg_stat_statements'"
    echo "  2. Restart PostgreSQL"
    echo "  3. Run: CREATE EXTENSION pg_stat_statements;"
    exit 1
fi

echo "============================================================================="
echo "  PostgreSQL Slow Query Report"
echo "  Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "  Server: $PGHOST:$PGPORT/$PGDATABASE"
echo "============================================================================="

# --- Overview ---
header "QUERY STATISTICS OVERVIEW"
$PSQL -c "
SELECT
    count(*) AS tracked_queries,
    sum(calls) AS total_calls,
    round(sum(total_exec_time)::numeric / 1000, 2) AS total_exec_seconds,
    round(avg(mean_exec_time)::numeric, 2) AS avg_mean_ms,
    round(max(mean_exec_time)::numeric, 2) AS max_mean_ms,
    sum(rows) AS total_rows_processed
FROM pg_stat_statements
WHERE calls >= $MIN_CALLS;
"

# --- Top by Total Time ---
header "TOP $TOP_N QUERIES BY TOTAL EXECUTION TIME"
echo "  (These consume the most database time overall)"
$PSQL -c "
SELECT
    queryid,
    calls,
    round(total_exec_time::numeric / 1000, 2) AS total_sec,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    rows,
    round((shared_blks_hit::numeric /
           NULLIF(shared_blks_hit + shared_blks_read, 0)) * 100, 1) AS cache_hit_pct,
    LEFT(query, 100) AS query
FROM pg_stat_statements
WHERE calls >= $MIN_CALLS
ORDER BY total_exec_time DESC
LIMIT $TOP_N;
"
echo ""
echo "  RECOMMENDATIONS:"
echo "  → Focus on reducing total_sec for the top queries"
echo "  → High total with low mean = called too frequently (cache or batch)"
echo "  → High total with high mean = slow query (add indexes, rewrite)"

# --- Top by Mean Time ---
header "TOP $TOP_N QUERIES BY MEAN EXECUTION TIME"
echo "  (These are the slowest individual queries)"
$PSQL -c "
SELECT
    queryid,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(min_exec_time::numeric, 2) AS min_ms,
    round(max_exec_time::numeric, 2) AS max_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    rows,
    LEFT(query, 100) AS query
FROM pg_stat_statements
WHERE calls >= $MIN_CALLS
ORDER BY mean_exec_time DESC
LIMIT $TOP_N;
"
echo ""
echo "  RECOMMENDATIONS:"
echo "  → Queries with mean > 100ms need EXPLAIN ANALYZE investigation"
echo "  → High stddev = inconsistent performance (check parameter sniffing)"
echo "  → Check if missing indexes cause sequential scans"

# --- Worst Cache Hit Ratio ---
header "TOP $TOP_N QUERIES WITH WORST CACHE HIT RATIO"
echo "  (These read the most data from disk)"
$PSQL -c "
SELECT
    queryid,
    calls,
    shared_blks_read AS disk_blocks,
    shared_blks_hit AS cache_blocks,
    round((shared_blks_hit::numeric /
           NULLIF(shared_blks_hit + shared_blks_read, 0)) * 100, 1) AS cache_hit_pct,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    LEFT(query, 100) AS query
FROM pg_stat_statements
WHERE calls >= $MIN_CALLS
  AND shared_blks_read > 100
ORDER BY
    (shared_blks_hit::numeric / NULLIF(shared_blks_hit + shared_blks_read, 0)) ASC
LIMIT $TOP_N;
"
echo ""
echo "  RECOMMENDATIONS:"
echo "  → Cache hit < 90% = consider increasing shared_buffers"
echo "  → Cache hit < 50% = likely missing index or scanning too much data"
echo "  → Add covering indexes (INCLUDE clause) for index-only scans"

# --- Temp File I/O ---
header "TOP $TOP_N QUERIES BY TEMP FILE I/O"
echo "  (These spill sorts/hashes to disk — increase work_mem or optimize)"
$PSQL -c "
SELECT
    queryid,
    calls,
    temp_blks_read + temp_blks_written AS temp_blocks_total,
    temp_blks_read,
    temp_blks_written,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    LEFT(query, 100) AS query
FROM pg_stat_statements
WHERE calls >= $MIN_CALLS
  AND (temp_blks_read + temp_blks_written) > 0
ORDER BY (temp_blks_read + temp_blks_written) DESC
LIMIT $TOP_N;
"
echo ""
echo "  RECOMMENDATIONS:"
echo "  → Increase work_mem for these queries (SET work_mem = '64MB' per-session)"
echo "  → Add indexes to avoid large sorts"
echo "  → Consider partial indexes to reduce dataset size"

# --- Most Rows Processed ---
header "TOP $TOP_N QUERIES BY ROWS PROCESSED"
echo "  (These touch the most data per call)"
$PSQL -c "
SELECT
    queryid,
    calls,
    rows AS total_rows,
    round(rows::numeric / calls, 0) AS rows_per_call,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round((shared_blks_hit + shared_blks_read)::numeric / NULLIF(calls, 0), 0)
        AS blocks_per_call,
    LEFT(query, 100) AS query
FROM pg_stat_statements
WHERE calls >= $MIN_CALLS
  AND rows > 0
ORDER BY (rows::numeric / calls) DESC
LIMIT $TOP_N;
"
echo ""
echo "  RECOMMENDATIONS:"
echo "  → High rows_per_call with high blocks_per_call = missing WHERE clause or index"
echo "  → Consider LIMIT clauses for pagination"
echo "  → Use materialized views for heavy aggregations"

# --- Queries with Most Calls ---
header "TOP $TOP_N MOST FREQUENTLY CALLED QUERIES"
echo "  (Optimize these for maximum overall impact)"
$PSQL -c "
SELECT
    queryid,
    calls,
    round(total_exec_time::numeric / 1000, 2) AS total_sec,
    round(mean_exec_time::numeric, 4) AS mean_ms,
    rows,
    LEFT(query, 100) AS query
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT $TOP_N;
"
echo ""
echo "  RECOMMENDATIONS:"
echo "  → Even small per-call improvements multiply across millions of calls"
echo "  → Consider caching results in application layer"
echo "  → Batch multiple calls into single queries where possible"

# --- Summary ---
header "GENERAL RECOMMENDATIONS"
cat << 'EOF'
  1. INDEXING: Run EXPLAIN ANALYZE on top queries. Add indexes for:
     - Columns in WHERE clauses with Seq Scan
     - JOIN columns missing indexes
     - ORDER BY columns (to avoid sorts)

  2. QUERY REWRITING:
     - Replace SELECT * with specific columns
     - Add LIMIT for pagination
     - Use EXISTS instead of IN for subqueries
     - Consider CTEs with MATERIALIZED hint for complex queries

  3. CONFIGURATION:
     - Increase work_mem if temp files are being generated
     - Increase shared_buffers if cache hit ratio < 99%
     - Set random_page_cost = 1.1 for SSD storage
     - Enable huge_pages for shared_buffers > 8GB

  4. MAINTENANCE:
     - Ensure autovacuum is running and keeping up
     - Run ANALYZE on tables with stale statistics
     - REINDEX CONCURRENTLY for bloated indexes
     - Use pg_repack for bloated tables

  5. MONITORING:
     - Reset pg_stat_statements periodically for fresh data:
       SELECT pg_stat_statements_reset();
     - Enable auto_explain for automatic plan logging
     - Set log_min_duration_statement for slow query logging
EOF

echo ""
echo "============================================================================="
echo "  Report complete — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================================="
