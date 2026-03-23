#!/usr/bin/env bash
# ch-table-stats.sh — Show ClickHouse table statistics
# Usage: ./ch-table-stats.sh [--database DB] [--table TABLE]

set -euo pipefail

HOST="${CH_HOST:-localhost}"
PORT="${CH_PORT:-9000}"
USER="${CH_USER:-default}"
PASSWORD="${CH_PASSWORD:-}"
SECURE=""
DATABASE=""
TABLE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --secure) SECURE="--secure"; shift ;;
        --database) DATABASE="$2"; shift 2 ;;
        --table) TABLE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --host HOST       ClickHouse host (default: localhost, env: CH_HOST)"
            echo "  --port PORT       ClickHouse port (default: 9000, env: CH_PORT)"
            echo "  --user USER       ClickHouse user (default: default, env: CH_USER)"
            echo "  --password PASS   ClickHouse password (env: CH_PASSWORD)"
            echo "  --secure          Use TLS"
            echo "  --database DB     Filter to a specific database"
            echo "  --table TABLE     Filter to a specific table (requires --database)"
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

DB_FILTER="AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')"
if [[ -n "${DATABASE}" ]]; then
    DB_FILTER="AND database = '${DATABASE}'"
fi

TABLE_FILTER=""
if [[ -n "${TABLE}" ]]; then
    TABLE_FILTER="AND table = '${TABLE}'"
fi

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║              CLICKHOUSE TABLE STATISTICS                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
echo "Host: ${HOST}:${PORT}"
echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# 1. Table Overview
section "TABLE OVERVIEW (row count, disk size, part count)"
query "
SELECT
    database,
    table,
    engine,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    sum(bytes_on_disk) AS disk_bytes,
    count() AS active_parts,
    min(min_time) AS oldest_data,
    max(max_time) AS newest_data
FROM system.parts
WHERE active
  ${DB_FILTER}
  ${TABLE_FILTER}
GROUP BY database, table, engine
ORDER BY disk_bytes DESC
FORMAT PrettyCompact
"

# 2. Column Compression Ratios (detailed for a specific table, or top-level summary)
if [[ -n "${TABLE}" && -n "${DATABASE}" ]]; then
    section "COLUMN COMPRESSION RATIOS — ${DATABASE}.${TABLE}"
    query "
    SELECT
        column,
        type,
        formatReadableSize(sum(column_data_compressed_bytes)) AS compressed,
        formatReadableSize(sum(column_data_uncompressed_bytes)) AS uncompressed,
        round(sum(column_data_uncompressed_bytes) / max(1, sum(column_data_compressed_bytes)), 2) AS ratio,
        round(sum(column_data_compressed_bytes) * 100.0 /
              max(1, (SELECT sum(column_data_compressed_bytes) FROM system.parts_columns
                      WHERE active AND database = '${DATABASE}' AND table = '${TABLE}')), 1) AS pct_of_table
    FROM system.parts_columns
    WHERE active AND database = '${DATABASE}' AND table = '${TABLE}'
    GROUP BY column, type
    ORDER BY sum(column_data_compressed_bytes) DESC
    FORMAT PrettyCompact
    "
else
    section "TOP TABLES BY COMPRESSION RATIO"
    query "
    SELECT
        database,
        table,
        formatReadableSize(sum(data_compressed_bytes)) AS compressed,
        formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
        round(sum(data_uncompressed_bytes) / max(1, sum(data_compressed_bytes)), 2) AS compression_ratio
    FROM system.parts
    WHERE active
      ${DB_FILTER}
      ${TABLE_FILTER}
    GROUP BY database, table
    HAVING sum(data_compressed_bytes) > 0
    ORDER BY sum(data_compressed_bytes) DESC
    LIMIT 20
    FORMAT PrettyCompact
    "
fi

# 3. Partition Details
section "PARTITION DETAILS"
query "
SELECT
    database,
    table,
    partition,
    count() AS parts,
    sum(rows) AS rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    min(modification_time) AS oldest_part,
    max(modification_time) AS newest_part
FROM system.parts
WHERE active
  ${DB_FILTER}
  ${TABLE_FILTER}
GROUP BY database, table, partition
ORDER BY database, table, partition
LIMIT 50
FORMAT PrettyCompact
"

# 4. Table Engines Summary
if [[ -z "${TABLE}" ]]; then
    section "TABLE ENGINE DISTRIBUTION"
    query "
    SELECT
        engine,
        count() AS table_count,
        formatReadableSize(sum(total_bytes)) AS total_size,
        sum(total_rows) AS total_rows
    FROM system.tables
    WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
      AND engine != ''
    GROUP BY engine
    ORDER BY sum(total_bytes) DESC
    FORMAT PrettyCompact
    "
fi

# 5. Tables with Potential Issues
section "POTENTIAL ISSUES"

echo ""
echo "Tables with high part count (>200):"
query "
SELECT database, table, count() AS parts
FROM system.parts
WHERE active ${DB_FILTER} ${TABLE_FILTER}
GROUP BY database, table
HAVING parts > 200
ORDER BY parts DESC
FORMAT PrettyCompact
" || echo "  None found."

echo ""
echo "Tables with poor compression (<2x):"
query "
SELECT
    database,
    table,
    round(sum(data_uncompressed_bytes) / max(1, sum(data_compressed_bytes)), 2) AS ratio,
    formatReadableSize(sum(data_compressed_bytes)) AS compressed_size
FROM system.parts
WHERE active ${DB_FILTER} ${TABLE_FILTER}
GROUP BY database, table
HAVING ratio < 2 AND sum(data_compressed_bytes) > 10485760
ORDER BY ratio ASC
LIMIT 10
FORMAT PrettyCompact
" || echo "  None found."

echo ""
echo "Report complete."
