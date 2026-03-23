#!/usr/bin/env bash
# parquet-inspect.sh — Inspect Parquet file metadata using DuckDB
# Usage: ./parquet-inspect.sh <parquet_file> [--verbose]
#
# Shows: schema, row groups, compression, column statistics, file metadata.
# Requires: duckdb CLI in PATH.

set -euo pipefail

FILE="${1:?Usage: $0 <parquet_file> [--verbose]}"
VERBOSE="${2:-}"

if [[ ! -f "$FILE" ]]; then
    echo "Error: File not found: $FILE" >&2
    exit 1
fi

if ! command -v duckdb &>/dev/null; then
    echo "Error: duckdb CLI not found." >&2
    exit 1
fi

FILE_SIZE=$(du -h "$FILE" | cut -f1)

echo "═══════════════════════════════════════════════════════"
echo "  Parquet File Inspector"
echo "  File: $FILE"
echo "  Size: $FILE_SIZE"
echo "═══════════════════════════════════════════════════════"

duckdb -noheader -cmd ".mode line" <<SQL

-- Schema (column names, types, and Parquet-level details)
.print
.print ── SCHEMA ──────────────────────────────────────────
.mode table
SELECT name, type, converted_type, type_length, repetition_type
FROM parquet_schema('$FILE')
WHERE name != 'duckdb_schema'
ORDER BY schema_element_id;

-- File-level metadata
.print
.print ── FILE METADATA ───────────────────────────────────
SELECT
    count(DISTINCT row_group_id) AS num_row_groups,
    sum(num_values) AS total_values,
    count(DISTINCT path_in_schema) AS num_columns
FROM parquet_metadata('$FILE');

-- Row counts
.print
.print ── ROW COUNT ───────────────────────────────────────
SELECT count(*) AS total_rows FROM read_parquet('$FILE');

-- Row group details
.print
.print ── ROW GROUPS ──────────────────────────────────────
SELECT
    row_group_id,
    path_in_schema AS column_name,
    type AS data_type,
    compression AS codec,
    num_values,
    total_compressed_size AS compressed_bytes,
    total_uncompressed_size AS uncompressed_bytes,
    CASE WHEN total_uncompressed_size > 0
         THEN round(100.0 * (1.0 - total_compressed_size::DOUBLE / total_uncompressed_size), 1)
         ELSE 0 END AS compression_ratio_pct
FROM parquet_metadata('$FILE')
ORDER BY row_group_id, path_in_schema;

-- Compression summary
.print
.print ── COMPRESSION SUMMARY ─────────────────────────────
SELECT
    compression AS codec,
    count(*) AS num_chunks,
    sum(total_compressed_size) AS total_compressed,
    sum(total_uncompressed_size) AS total_uncompressed,
    round(avg(100.0 * (1.0 - total_compressed_size::DOUBLE / NULLIF(total_uncompressed_size, 0))), 1) AS avg_compression_pct
FROM parquet_metadata('$FILE')
GROUP BY compression
ORDER BY total_compressed DESC;

-- Column statistics (min/max from Parquet metadata — no data scanning)
.print
.print ── COLUMN STATISTICS (from metadata) ───────────────
SELECT
    path_in_schema AS column_name,
    type,
    stats_min AS min_value,
    stats_max AS max_value,
    stats_null_count AS null_count,
    stats_distinct_count AS distinct_count,
    num_values
FROM parquet_metadata('$FILE')
WHERE row_group_id = 0
ORDER BY path_in_schema;

.quit
SQL

# Verbose mode: additional details
if [[ "$VERBOSE" == "--verbose" ]]; then
    echo ""
    duckdb -noheader -cmd ".mode line" <<SQL

-- Key-value metadata
.print ── KEY-VALUE METADATA ──────────────────────────────
.mode table
SELECT key, value FROM parquet_kv_metadata('$FILE');

-- Detailed per-column size analysis
.print
.print ── COLUMN SIZE ANALYSIS ────────────────────────────
SELECT
    path_in_schema AS column_name,
    sum(total_compressed_size) AS total_compressed,
    sum(total_uncompressed_size) AS total_uncompressed,
    round(100.0 * sum(total_compressed_size)::DOUBLE /
          NULLIF((SELECT sum(total_compressed_size) FROM parquet_metadata('$FILE')), 0), 1) AS pct_of_file
FROM parquet_metadata('$FILE')
GROUP BY path_in_schema
ORDER BY total_compressed DESC;

.quit
SQL
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Inspection complete."
echo "  Tip: Use --verbose for key-value metadata and column size breakdown."
echo "═══════════════════════════════════════════════════════"
