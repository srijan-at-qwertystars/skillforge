#!/usr/bin/env bash
# ch-slow-query-report.sh — Report slow queries from system.query_log
# Usage: ./ch-slow-query-report.sh [--threshold MS] [--days N] [--limit N] [--user USER]

set -euo pipefail

HOST="${CH_HOST:-localhost}"
PORT="${CH_PORT:-9000}"
USER="${CH_USER:-default}"
PASSWORD="${CH_PASSWORD:-}"
SECURE=""
THRESHOLD_MS=1000
DAYS=1
LIMIT=20
FILTER_USER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --secure) SECURE="--secure"; shift ;;
        --threshold) THRESHOLD_MS="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --filter-user) FILTER_USER="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --host HOST         ClickHouse host (default: localhost, env: CH_HOST)"
            echo "  --port PORT         ClickHouse port (default: 9000, env: CH_PORT)"
            echo "  --user USER         ClickHouse user (default: default, env: CH_USER)"
            echo "  --password PASS     ClickHouse password (env: CH_PASSWORD)"
            echo "  --secure            Use TLS"
            echo "  --threshold MS      Slow query threshold in milliseconds (default: 1000)"
            echo "  --days N            Look back N days (default: 1)"
            echo "  --limit N           Max results per section (default: 20)"
            echo "  --filter-user USER  Filter to a specific ClickHouse user"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

CH_CLIENT="clickhouse-client --host ${HOST} --port ${PORT} --user ${USER} ${SECURE}"
if [[ -n "$PASSWORD" ]]; then
    CH_CLIENT="${CH_CLIENT} --password ${PASSWORD}"
fi

query() {
    ${CH_CLIENT} --query "$1" 2>/dev/null
}

section() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════"
}

USER_FILTER=""
if [[ -n "${FILTER_USER}" ]]; then
    USER_FILTER="AND user = '${FILTER_USER}'"
fi

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║              CLICKHOUSE SLOW QUERY REPORT                    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
echo "Host:       ${HOST}:${PORT}"
echo "Threshold:  ${THRESHOLD_MS}ms"
echo "Period:     last ${DAYS} day(s)"
echo "Generated:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# 1. Summary Statistics
section "SUMMARY"
query "
SELECT
    count() AS total_queries,
    countIf(query_duration_ms > ${THRESHOLD_MS}) AS slow_queries,
    round(countIf(query_duration_ms > ${THRESHOLD_MS}) * 100.0 / count(), 2) AS slow_pct,
    round(avg(query_duration_ms), 0) AS avg_ms,
    max(query_duration_ms) AS max_ms,
    quantile(0.50)(query_duration_ms) AS p50_ms,
    quantile(0.95)(query_duration_ms) AS p95_ms,
    quantile(0.99)(query_duration_ms) AS p99_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - ${DAYS}
  AND query_kind = 'Select'
  ${USER_FILTER}
FORMAT Vertical
"

# 2. Top Slow Queries by Duration
section "TOP SLOW QUERIES (by duration)"
query "
SELECT
    query_start_time,
    user,
    query_duration_ms AS duration_ms,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS peak_memory,
    read_rows,
    result_rows,
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 120) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - ${DAYS}
  AND query_duration_ms > ${THRESHOLD_MS}
  AND query_kind = 'Select'
  ${USER_FILTER}
ORDER BY query_duration_ms DESC
LIMIT ${LIMIT}
FORMAT PrettyCompact
"

# 3. Top Queries by Data Read
section "TOP QUERIES BY DATA SCANNED"
query "
SELECT
    query_start_time,
    user,
    query_duration_ms AS duration_ms,
    formatReadableSize(read_bytes) AS data_read,
    read_rows,
    formatReadableSize(memory_usage) AS peak_memory,
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 120) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - ${DAYS}
  AND query_kind = 'Select'
  ${USER_FILTER}
ORDER BY read_bytes DESC
LIMIT ${LIMIT}
FORMAT PrettyCompact
"

# 4. Top Queries by Memory Usage
section "TOP QUERIES BY MEMORY USAGE"
query "
SELECT
    query_start_time,
    user,
    query_duration_ms AS duration_ms,
    formatReadableSize(memory_usage) AS peak_memory,
    formatReadableSize(read_bytes) AS data_read,
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 120) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - ${DAYS}
  AND query_kind = 'Select'
  ${USER_FILTER}
ORDER BY memory_usage DESC
LIMIT ${LIMIT}
FORMAT PrettyCompact
"

# 5. Most Frequent Slow Query Patterns
section "MOST FREQUENT SLOW QUERY PATTERNS"
query "
SELECT
    normalized_query_hash,
    count() AS executions,
    round(avg(query_duration_ms)) AS avg_ms,
    max(query_duration_ms) AS max_ms,
    round(avg(read_rows)) AS avg_rows_read,
    formatReadableSize(avg(memory_usage)) AS avg_memory,
    substring(replaceRegexpAll(any(query), '\\s+', ' '), 1, 120) AS sample_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - ${DAYS}
  AND query_duration_ms > ${THRESHOLD_MS}
  AND query_kind = 'Select'
  ${USER_FILTER}
GROUP BY normalized_query_hash
ORDER BY executions DESC
LIMIT ${LIMIT}
FORMAT PrettyCompact
"

# 6. Slow Queries by Hour
section "SLOW QUERY DISTRIBUTION BY HOUR"
query "
SELECT
    toStartOfHour(query_start_time) AS hour,
    count() AS total_queries,
    countIf(query_duration_ms > ${THRESHOLD_MS}) AS slow_queries,
    round(avg(query_duration_ms)) AS avg_ms,
    max(query_duration_ms) AS max_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_date >= today() - ${DAYS}
  AND query_kind = 'Select'
  ${USER_FILTER}
GROUP BY hour
ORDER BY hour
FORMAT PrettyCompact
"

# 7. Failed Queries
section "RECENT FAILED QUERIES"
query "
SELECT
    query_start_time,
    user,
    exception_code,
    substring(exception, 1, 100) AS error,
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 100) AS query_preview
FROM system.query_log
WHERE type = 'ExceptionWhileProcessing'
  AND event_date >= today() - ${DAYS}
  ${USER_FILTER}
ORDER BY query_start_time DESC
LIMIT 10
FORMAT PrettyCompact
"

echo ""
echo "Report complete."
