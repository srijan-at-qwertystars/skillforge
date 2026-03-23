#!/usr/bin/env bash
# duckdb-explore.sh — Quick data exploration for Parquet, CSV, and JSON files
# Usage: ./duckdb-explore.sh <file_path> [row_limit]
#
# Shows: schema, row count, sample rows, null counts, and basic statistics.
# Requires: duckdb CLI in PATH.

set -euo pipefail

FILE="${1:?Usage: $0 <file_path> [row_limit]}"
LIMIT="${2:-10}"

if [[ ! -f "$FILE" ]]; then
    echo "Error: File not found: $FILE" >&2
    exit 1
fi

if ! command -v duckdb &>/dev/null; then
    echo "Error: duckdb CLI not found. Install with: brew install duckdb / pip install duckdb-cli" >&2
    exit 1
fi

EXT="${FILE##*.}"
EXT_LOWER="$(echo "$EXT" | tr '[:upper:]' '[:lower:]')"

case "$EXT_LOWER" in
    parquet|pq)   READ_FN="read_parquet('$FILE')" ;;
    csv|tsv)      READ_FN="read_csv_auto('$FILE')" ;;
    json|jsonl|ndjson) READ_FN="read_json_auto('$FILE')" ;;
    *)
        echo "Error: Unsupported file type: .$EXT_LOWER (supported: parquet, csv, tsv, json, jsonl)" >&2
        exit 1
        ;;
esac

echo "═══════════════════════════════════════════════════════"
echo "  DuckDB Data Explorer"
echo "  File: $FILE"
echo "  Size: $(du -h "$FILE" | cut -f1)"
echo "═══════════════════════════════════════════════════════"

duckdb -noheader -cmd ".mode line" <<SQL

-- Schema
.print
.print ── SCHEMA ──────────────────────────────────────────
.mode table
DESCRIBE SELECT * FROM $READ_FN;

-- Row count
.print
.print ── ROW COUNT ───────────────────────────────────────
SELECT count(*) AS total_rows FROM $READ_FN;

-- Sample rows
.print
.print ── SAMPLE ROWS (first $LIMIT) ─────────────────────
SELECT * FROM $READ_FN LIMIT $LIMIT;

-- Null counts per column
.print
.print ── NULL COUNTS ─────────────────────────────────────
SELECT * FROM (SUMMARIZE SELECT * FROM $READ_FN)
ORDER BY column_name;

-- Basic statistics for numeric columns
.print
.print ── NUMERIC STATISTICS ──────────────────────────────
SELECT column_name, column_type, min, max, avg, std, q25, q50, q75, count, null_percentage
FROM (SUMMARIZE SELECT * FROM $READ_FN)
WHERE column_type IN ('TINYINT','SMALLINT','INTEGER','BIGINT','HUGEINT',
                       'FLOAT','DOUBLE','DECIMAL','UTINYINT','USMALLINT',
                       'UINTEGER','UBIGINT')
ORDER BY column_name;

-- Unique counts for string columns
.print
.print ── STRING COLUMN CARDINALITY ───────────────────────
SELECT column_name, column_type, approx_unique, min AS min_val, max AS max_val, null_percentage
FROM (SUMMARIZE SELECT * FROM $READ_FN)
WHERE column_type = 'VARCHAR'
ORDER BY approx_unique DESC;

.quit
SQL

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Exploration complete."
echo "═══════════════════════════════════════════════════════"
