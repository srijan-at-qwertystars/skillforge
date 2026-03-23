#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# find-missing-indexes.sh — Identify tables that likely need indexes
#
# Usage:
#   find-missing-indexes.sh [OPTIONS] [CONNECTION_STRING]
#
# Options:
#   -m, --min-size SIZE   Minimum table size in MB to consider (default: 1)
#   -s, --seq-threshold N Minimum sequential scans to flag (default: 100)
#   -h, --help            Show this help message
#
# Connects using standard PG environment variables (PGHOST, PGPORT,
# PGDATABASE, PGUSER, PGPASSWORD) or accepts a libpq connection string
# as the last argument.
#
# Examples:
#   PGDATABASE=mydb find-missing-indexes.sh
#   find-missing-indexes.sh -m 10 "postgresql://admin@localhost/mydb"
#   find-missing-indexes.sh --min-size 5 --seq-threshold 50
#
# What it does:
#   1. Finds tables with high sequential scan rates vs index scans
#   2. Finds large tables with no indexes at all
#   3. Identifies tables with heavy seq scans that would benefit from indexes
#   4. Suggests CREATE INDEX statements where possible
#
# This script is read-only and never modifies data.
##############################################################################

# ---------------------------------------------------------------------------
# Defaults & argument parsing
# ---------------------------------------------------------------------------
MIN_SIZE_MB=1
SEQ_THRESHOLD=100
PSQL_CONN=""

usage() {
  sed -n '3,/^##*$/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--min-size)     MIN_SIZE_MB="$2"; shift 2 ;;
    -s|--seq-threshold) SEQ_THRESHOLD="$2"; shift 2 ;;
    -h|--help)         usage ;;
    *)                 PSQL_CONN="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  BOLD='\033[1m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED='' YELLOW='' GREEN='' BOLD='' CYAN='' NC=''
fi

header() { printf "\n${BOLD}=== %s ===${NC}\n" "$*"; }

# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------
run_sql() {
  if [[ -n "$PSQL_CONN" ]]; then
    psql "$PSQL_CONN" -XAt -F$'\t' -c "$1" 2>/dev/null
  else
    psql -XAt -F$'\t' -c "$1" 2>/dev/null
  fi
}

run_sql_with_header() {
  if [[ -n "$PSQL_CONN" ]]; then
    psql "$PSQL_CONN" -X --pset=footer=off -c "$1" 2>/dev/null
  else
    psql -X --pset=footer=off -c "$1" 2>/dev/null
  fi
}

if ! run_sql "SELECT 1;" >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to PostgreSQL. Check connection parameters." >&2
  exit 1
fi

DB_NAME=$(run_sql "SELECT current_database();")
printf "${BOLD}Missing Index Analysis — %s${NC}\n" "$DB_NAME"
printf "Min table size: %s MB | Seq scan threshold: %s\n" "$MIN_SIZE_MB" "$SEQ_THRESHOLD"
printf "Report generated: %s\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ---------------------------------------------------------------------------
# 1. Tables with high sequential scan ratio
# ---------------------------------------------------------------------------
header "Tables With High Sequential Scan Ratio"
printf "Tables where sequential scans greatly outnumber index scans:\n\n"

HIGH_SEQ=$(run_sql "
  SELECT s.schemaname,
         s.relname,
         s.seq_scan,
         s.idx_scan,
         CASE WHEN s.seq_scan + COALESCE(s.idx_scan, 0) > 0
              THEN ROUND(s.seq_scan * 100.0 /
                         (s.seq_scan + COALESCE(s.idx_scan, 0)), 1)
              ELSE 0
         END AS seq_pct,
         pg_size_pretty(pg_relation_size(s.relid)) AS table_size,
         pg_relation_size(s.relid) AS size_bytes
  FROM pg_stat_user_tables s
  WHERE s.seq_scan > ${SEQ_THRESHOLD}
    AND pg_relation_size(s.relid) > ${MIN_SIZE_MB} * 1024 * 1024
    AND (s.idx_scan IS NULL OR s.seq_scan > s.idx_scan * 2)
  ORDER BY s.seq_scan DESC
  LIMIT 20;
")

if [[ -z "$HIGH_SEQ" ]]; then
  printf "${GREEN}No tables with excessive sequential scans found.${NC}\n"
else
  printf "%-20s %-25s %12s %12s %8s %12s\n" \
    "SCHEMA" "TABLE" "SEQ_SCANS" "IDX_SCANS" "SEQ %" "SIZE"
  printf "%-20s %-25s %12s %12s %8s %12s\n" \
    "------" "-----" "---------" "---------" "-----" "----"
  while IFS=$'\t' read -r schema tbl seq idx pct size _bytes; do
    color="$NC"
    if (( $(echo "$pct > 90" | bc -l) )); then
      color="$RED"
    elif (( $(echo "$pct > 70" | bc -l) )); then
      color="$YELLOW"
    fi
    printf "${color}%-20s %-25s %12s %12s %7s%% %12s${NC}\n" \
      "$schema" "$tbl" "$seq" "${idx:-0}" "$pct" "$size"
  done <<< "$HIGH_SEQ"
fi

# ---------------------------------------------------------------------------
# 2. Large tables with no indexes
# ---------------------------------------------------------------------------
header "Large Tables With No Indexes"

NO_IDX=$(run_sql "
  SELECT schemaname,
         relname,
         pg_size_pretty(pg_relation_size(relid)) AS table_size,
         n_live_tup
  FROM pg_stat_user_tables
  WHERE relid NOT IN (
    SELECT indrelid FROM pg_index
  )
  AND pg_relation_size(relid) > ${MIN_SIZE_MB} * 1024 * 1024
  ORDER BY pg_relation_size(relid) DESC
  LIMIT 20;
")

if [[ -z "$NO_IDX" ]]; then
  printf "${GREEN}All tables above %s MB have at least one index.${NC}\n" "$MIN_SIZE_MB"
else
  printf "${RED}These tables have NO indexes at all:${NC}\n\n"
  printf "%-20s %-30s %12s %12s\n" "SCHEMA" "TABLE" "SIZE" "LIVE ROWS"
  printf "%-20s %-30s %12s %12s\n" "------" "-----" "----" "---------"
  while IFS=$'\t' read -r schema tbl size rows; do
    printf "${RED}%-20s %-30s %12s %12s${NC}\n" "$schema" "$tbl" "$size" "$rows"
  done <<< "$NO_IDX"
fi

# ---------------------------------------------------------------------------
# 3. Tables with indexes that are never used
# ---------------------------------------------------------------------------
header "Unused Indexes (candidates for removal)"

UNUSED_IDX=$(run_sql "
  SELECT s.schemaname,
         s.relname AS table_name,
         s.indexrelname AS index_name,
         pg_size_pretty(pg_relation_size(s.indexrelid)) AS index_size,
         s.idx_scan
  FROM pg_stat_user_indexes s
  JOIN pg_index i ON s.indexrelid = i.indexrelid
  WHERE s.idx_scan = 0
    AND NOT i.indisunique
    AND NOT i.indisprimary
    AND pg_relation_size(s.indexrelid) > 1024 * 1024
  ORDER BY pg_relation_size(s.indexrelid) DESC
  LIMIT 20;
")

if [[ -z "$UNUSED_IDX" ]]; then
  printf "${GREEN}No large unused indexes found.${NC}\n"
else
  printf "These indexes have never been used (since last stats reset) and waste space:\n\n"
  printf "%-15s %-25s %-30s %12s\n" "SCHEMA" "TABLE" "INDEX" "SIZE"
  printf "%-15s %-25s %-30s %12s\n" "------" "-----" "-----" "----"
  while IFS=$'\t' read -r schema tbl idx size _scans; do
    printf "${YELLOW}%-15s %-25s %-30s %12s${NC}\n" "$schema" "$tbl" "$idx" "$size"
  done <<< "$UNUSED_IDX"
fi

# ---------------------------------------------------------------------------
# 4. Suggested CREATE INDEX statements
# ---------------------------------------------------------------------------
header "Suggested Indexes"
printf "Based on foreign key columns that lack indexes:\n\n"

FK_NO_IDX=$(run_sql "
  SELECT
    tc.table_schema,
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS referenced_table
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
    AND tc.table_schema = kcu.table_schema
  JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name
    AND tc.table_schema = ccu.table_schema
  WHERE tc.constraint_type = 'FOREIGN KEY'
    AND NOT EXISTS (
      SELECT 1
      FROM pg_indexes pi
      WHERE pi.schemaname = tc.table_schema
        AND pi.tablename = tc.table_name
        AND pi.indexdef LIKE '%' || kcu.column_name || '%'
    )
  ORDER BY tc.table_schema, tc.table_name;
")

SUGGESTED=0
if [[ -n "$FK_NO_IDX" ]]; then
  while IFS=$'\t' read -r schema tbl col reftbl; do
    idx_name="idx_${tbl}_${col}"
    printf "${CYAN}-- FK %s.%s.%s -> %s (no covering index)${NC}\n" \
      "$schema" "$tbl" "$col" "$reftbl"
    printf "CREATE INDEX CONCURRENTLY %s ON %s.%s (%s);\n\n" \
      "$idx_name" "$schema" "$tbl" "$col"
    ((SUGGESTED++)) || true
  done <<< "$FK_NO_IDX"
fi

# Also suggest indexes for high-seq-scan tables based on most-filtered columns
HIGH_SEQ_TABLES=$(run_sql "
  SELECT s.schemaname, s.relname
  FROM pg_stat_user_tables s
  WHERE s.seq_scan > ${SEQ_THRESHOLD}
    AND pg_relation_size(s.relid) > ${MIN_SIZE_MB} * 1024 * 1024
    AND (s.idx_scan IS NULL OR s.seq_scan > s.idx_scan * 10)
    AND s.n_live_tup > 1000
  ORDER BY s.seq_scan DESC
  LIMIT 5;
")

if [[ -n "$HIGH_SEQ_TABLES" ]]; then
  printf "${CYAN}-- The following tables have very high seq_scan counts.${NC}\n"
  printf "${CYAN}-- Review queries against them and consider adding indexes:${NC}\n\n"
  while IFS=$'\t' read -r schema tbl; do
    printf "-- Analyze queries hitting %s.%s and add appropriate indexes.\n" \
      "$schema" "$tbl"
    printf "-- Example: CREATE INDEX CONCURRENTLY idx_%s_<column> ON %s.%s (<column>);\n\n" \
      "$tbl" "$schema" "$tbl"
    ((SUGGESTED++)) || true
  done <<< "$HIGH_SEQ_TABLES"
fi

if (( SUGGESTED == 0 )); then
  printf "${GREEN}No obvious missing indexes detected.${NC}\n"
else
  printf "${BOLD}Total suggestions: %d${NC}\n" "$SUGGESTED"
fi

printf "\n${BOLD}Analysis complete.${NC}\n"
