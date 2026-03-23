#!/usr/bin/env bash
# ch-health-check.sh — ClickHouse server health check
# Usage: ./ch-health-check.sh [--host HOST] [--port PORT] [--user USER] [--password PASS]

set -euo pipefail

HOST="${CH_HOST:-localhost}"
PORT="${CH_PORT:-9000}"
USER="${CH_USER:-default}"
PASSWORD="${CH_PASSWORD:-}"
SECURE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --secure) SECURE="--secure"; shift ;;
        -h|--help)
            echo "Usage: $0 [--host HOST] [--port PORT] [--user USER] [--password PASS] [--secure]"
            echo "Environment: CH_HOST, CH_PORT, CH_USER, CH_PASSWORD"
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

# 1. Server Status
section "SERVER STATUS"
VERSION=$(query "SELECT version()" 2>/dev/null) || { echo "CRITICAL: Cannot connect to ClickHouse at ${HOST}:${PORT}"; exit 1; }
UPTIME=$(query "SELECT formatReadableTimeDelta(uptime())")
echo "Version:  ${VERSION}"
echo "Uptime:   ${UPTIME}"
echo "Status:   RUNNING"

# 2. Server Metrics
section "SERVER METRICS"
query "
SELECT
    (SELECT value FROM system.metrics WHERE metric = 'Query') AS running_queries,
    (SELECT value FROM system.metrics WHERE metric = 'Merge') AS active_merges,
    (SELECT value FROM system.metrics WHERE metric = 'ReplicatedSend') AS repl_sends,
    (SELECT value FROM system.metrics WHERE metric = 'ReplicatedFetch') AS repl_fetches,
    (SELECT formatReadableSize(value) FROM system.asynchronous_metrics
     WHERE metric = 'MemoryTracking') AS memory_used
FORMAT Vertical
"

# 3. Replication Status
section "REPLICATION STATUS"
READONLY_COUNT=$(query "SELECT countIf(is_readonly) FROM system.replicas")
LAGGING_COUNT=$(query "SELECT countIf(absolute_delay > 300) FROM system.replicas")
TOTAL_REPLICATED=$(query "SELECT count() FROM system.replicas")

echo "Replicated tables: ${TOTAL_REPLICATED}"
echo "Readonly tables:   ${READONLY_COUNT}"
echo "Lagging (>5min):   ${LAGGING_COUNT}"

if [[ "${READONLY_COUNT}" != "0" ]]; then
    echo ""
    echo "WARNING: Readonly tables detected:"
    query "
    SELECT database, table, is_leader, total_replicas, active_replicas, queue_size, absolute_delay
    FROM system.replicas
    WHERE is_readonly = 1
    FORMAT PrettyCompact
    "
fi

if [[ "${LAGGING_COUNT}" != "0" ]]; then
    echo ""
    echo "WARNING: Lagging replicas detected:"
    query "
    SELECT database, table, absolute_delay, queue_size, inserts_in_queue, merges_in_queue
    FROM system.replicas
    WHERE absolute_delay > 300
    ORDER BY absolute_delay DESC
    FORMAT PrettyCompact
    "
fi

# 4. Merge Activity
section "MERGE ACTIVITY"
MERGE_COUNT=$(query "SELECT count() FROM system.merges")
echo "Active merges: ${MERGE_COUNT}"

if [[ "${MERGE_COUNT}" != "0" ]]; then
    query "
    SELECT
        database,
        table,
        round(elapsed, 1) AS elapsed_sec,
        round(progress * 100, 1) AS progress_pct,
        num_parts,
        formatReadableSize(total_size_bytes_compressed) AS size,
        formatReadableSize(memory_usage) AS memory
    FROM system.merges
    ORDER BY elapsed DESC
    LIMIT 10
    FORMAT PrettyCompact
    "
fi

# 5. Disk Usage
section "DISK USAGE"
query "
SELECT
    name AS disk,
    path,
    formatReadableSize(total_space) AS total,
    formatReadableSize(free_space) AS free,
    round((1 - free_space / total_space) * 100, 1) AS used_pct
FROM system.disks
FORMAT PrettyCompact
"

# 6. Running Queries
section "RUNNING QUERIES (top 10 by elapsed time)"
RUNNING=$(query "SELECT count() FROM system.processes WHERE is_initial_query")
echo "Total running: ${RUNNING}"

if [[ "${RUNNING}" != "0" ]]; then
    query "
    SELECT
        query_id,
        user,
        round(elapsed, 1) AS elapsed_sec,
        formatReadableSize(read_bytes) AS data_read,
        formatReadableSize(memory_usage) AS memory,
        substring(query, 1, 80) AS query_preview
    FROM system.processes
    WHERE is_initial_query
    ORDER BY elapsed DESC
    LIMIT 10
    FORMAT PrettyCompact
    "
fi

# 7. Parts Count Per Table (tables with >100 active parts)
section "TABLES WITH HIGH PART COUNT (>100)"
query "
SELECT
    database,
    table,
    count() AS active_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size
FROM system.parts
WHERE active AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
HAVING active_parts > 100
ORDER BY active_parts DESC
LIMIT 20
FORMAT PrettyCompact
"

# 8. Pending Mutations
section "PENDING MUTATIONS"
MUTATION_COUNT=$(query "SELECT count() FROM system.mutations WHERE is_done = 0")
echo "Pending mutations: ${MUTATION_COUNT}"

if [[ "${MUTATION_COUNT}" != "0" ]]; then
    query "
    SELECT
        database,
        table,
        mutation_id,
        command,
        create_time,
        parts_to_do,
        latest_fail_reason
    FROM system.mutations
    WHERE is_done = 0
    ORDER BY create_time
    FORMAT PrettyCompact
    "
fi

# 9. Summary
section "HEALTH SUMMARY"
ISSUES=0
[[ "${READONLY_COUNT}" != "0" ]] && echo "⚠ ${READONLY_COUNT} table(s) in READONLY mode" && ISSUES=$((ISSUES+1))
[[ "${LAGGING_COUNT}" != "0" ]] && echo "⚠ ${LAGGING_COUNT} replica(s) lagging >5 minutes" && ISSUES=$((ISSUES+1))
[[ "${MUTATION_COUNT}" != "0" ]] && echo "⚠ ${MUTATION_COUNT} mutation(s) pending" && ISSUES=$((ISSUES+1))

DISK_WARN=$(query "SELECT countIf((1 - free_space / total_space) > 0.85) FROM system.disks")
[[ "${DISK_WARN}" != "0" ]] && echo "⚠ ${DISK_WARN} disk(s) above 85% usage" && ISSUES=$((ISSUES+1))

if [[ ${ISSUES} -eq 0 ]]; then
    echo "✓ All checks passed. ClickHouse is healthy."
else
    echo ""
    echo "Found ${ISSUES} issue(s) requiring attention."
fi
