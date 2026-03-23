#!/usr/bin/env bash
# duckdb-benchmark.sh — Benchmark DuckDB query performance
# Usage: ./duckdb-benchmark.sh <db_or_file> <sql_query> [iterations] [warmup]
#
# Runs a query multiple times and reports min/avg/max/median execution times.
# Requires: duckdb CLI in PATH.

set -euo pipefail

DB_OR_FILE="${1:?Usage: $0 <db_or_file> <sql_query> [iterations] [warmup]}"
QUERY="${2:?Usage: $0 <db_or_file> <sql_query> [iterations] [warmup]}"
ITERATIONS="${3:-5}"
WARMUP="${4:-1}"

if ! command -v duckdb &>/dev/null; then
    echo "Error: duckdb CLI not found." >&2
    exit 1
fi

# Determine if input is a database file or a data file to query
DB_FLAG=""
if [[ -f "$DB_OR_FILE" ]]; then
    EXT="${DB_OR_FILE##*.}"
    EXT_LOWER="$(echo "$EXT" | tr '[:upper:]' '[:lower:]')"
    case "$EXT_LOWER" in
        duckdb|db) DB_FLAG="$DB_OR_FILE" ;;
        *)         DB_FLAG="" ;;  # Use in-memory; query references the file directly
    esac
else
    DB_FLAG="$DB_OR_FILE"
fi

echo "═══════════════════════════════════════════════════════"
echo "  DuckDB Query Benchmark"
echo "  Database: ${DB_FLAG:-:memory:}"
echo "  Iterations: $ITERATIONS (warmup: $WARMUP)"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Query:"
echo "  $QUERY"
echo ""

TIMES=()

# Warmup runs
for ((i = 1; i <= WARMUP; i++)); do
    echo -n "  Warmup $i/$WARMUP... "
    if [[ -n "$DB_FLAG" ]]; then
        duckdb "$DB_FLAG" -noheader -csv -c "$QUERY" > /dev/null 2>&1
    else
        duckdb -noheader -csv -c "$QUERY" > /dev/null 2>&1
    fi
    echo "done"
done

# Timed runs
for ((i = 1; i <= ITERATIONS; i++)); do
    START_NS=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
    if [[ -n "$DB_FLAG" ]]; then
        duckdb "$DB_FLAG" -noheader -csv -c "$QUERY" > /dev/null 2>&1
    else
        duckdb -noheader -csv -c "$QUERY" > /dev/null 2>&1
    fi
    END_NS=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")

    ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
    TIMES+=("$ELAPSED_MS")
    printf "  Run %d/%d: %d ms\n" "$i" "$ITERATIONS" "$ELAPSED_MS"
done

echo ""
echo "── Results ────────────────────────────────────────────"

# Calculate statistics using sort and awk
IFS=$'\n' SORTED=($(sort -n <<<"${TIMES[*]}")); unset IFS

MIN="${SORTED[0]}"
MAX="${SORTED[$((${#SORTED[@]} - 1))]}"

# Calculate average
SUM=0
for t in "${TIMES[@]}"; do
    SUM=$((SUM + t))
done
AVG=$((SUM / ${#TIMES[@]}))

# Calculate median
MID=$(( ${#SORTED[@]} / 2 ))
if (( ${#SORTED[@]} % 2 == 0 )); then
    MEDIAN=$(( (SORTED[MID - 1] + SORTED[MID]) / 2 ))
else
    MEDIAN="${SORTED[$MID]}"
fi

# Calculate standard deviation
SUM_SQ=0
for t in "${TIMES[@]}"; do
    DIFF=$((t - AVG))
    SUM_SQ=$((SUM_SQ + DIFF * DIFF))
done
VARIANCE=$((SUM_SQ / ${#TIMES[@]}))
# Integer sqrt approximation
STDDEV=$(python3 -c "import math; print(int(math.sqrt($VARIANCE)))" 2>/dev/null || echo "N/A")

printf "  Min:     %d ms\n" "$MIN"
printf "  Max:     %d ms\n" "$MAX"
printf "  Avg:     %d ms\n" "$AVG"
printf "  Median:  %d ms\n" "$MEDIAN"
printf "  StdDev:  %s ms\n" "$STDDEV"
printf "  Total:   %d ms (%d iterations)\n" "$SUM" "${#TIMES[@]}"
echo ""
echo "═══════════════════════════════════════════════════════"
