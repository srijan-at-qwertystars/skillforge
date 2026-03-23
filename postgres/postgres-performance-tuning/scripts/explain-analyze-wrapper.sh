#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# explain-analyze-wrapper.sh — Safe EXPLAIN ANALYZE wrapper for PostgreSQL
#
# Usage:
#   explain-analyze-wrapper.sh [OPTIONS] "SELECT ..."
#   echo "SELECT ..." | explain-analyze-wrapper.sh [OPTIONS]
#   explain-analyze-wrapper.sh [OPTIONS] -f query.sql
#
# Options:
#   -f, --file FILE       Read SQL from file instead of argument
#   -j, --json            Output in JSON format (for external tools)
#   -n, --no-execute      Run EXPLAIN only (no ANALYZE — plan without execution)
#   -c, --conn STRING     Connection string (alternative to PG env vars)
#   -t, --threshold MS    Threshold in ms to highlight slow nodes (default: 100)
#   -h, --help            Show this help message
#
# Connects using standard PG environment variables (PGHOST, PGPORT,
# PGDATABASE, PGUSER, PGPASSWORD) or via -c / --conn.
#
# Examples:
#   explain-analyze-wrapper.sh "SELECT * FROM users WHERE email = 'a@b.com'"
#   explain-analyze-wrapper.sh --no-execute "UPDATE users SET active = true"
#   explain-analyze-wrapper.sh -j "SELECT * FROM orders" > plan.json
#   echo "SELECT 1" | explain-analyze-wrapper.sh
#   explain-analyze-wrapper.sh -f complex-query.sql -t 50
#
# Safety:
#   EXPLAIN ANALYZE actually executes the query.  This script wraps the
#   execution inside a transaction that is ALWAYS rolled back, making it
#   safe even for INSERT / UPDATE / DELETE statements.
#
# Highlighting:
#   - Nodes taking longer than --threshold (default 100 ms) are highlighted
#   - Sequential scans on large tables (>10 000 rows) are flagged
#
# This script is read-only — all changes are rolled back.
##############################################################################

# ---------------------------------------------------------------------------
# Defaults & argument parsing
# ---------------------------------------------------------------------------
OUTPUT_JSON=false
NO_EXECUTE=false
PSQL_CONN=""
THRESHOLD_MS=100
SQL_QUERY=""
SQL_FILE=""

usage() {
  sed -n '3,/^##*$/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)       SQL_FILE="$2"; shift 2 ;;
    -j|--json)       OUTPUT_JSON=true; shift ;;
    -n|--no-execute) NO_EXECUTE=true; shift ;;
    -c|--conn)       PSQL_CONN="$2"; shift 2 ;;
    -t|--threshold)  THRESHOLD_MS="$2"; shift 2 ;;
    -h|--help)       usage ;;
    -*)              echo "Unknown option: $1" >&2; exit 1 ;;
    *)               SQL_QUERY="$1"; shift ;;
  esac
done

# Read from file, argument, or stdin
if [[ -n "$SQL_FILE" ]]; then
  if [[ ! -f "$SQL_FILE" ]]; then
    echo "ERROR: File not found: $SQL_FILE" >&2
    exit 1
  fi
  SQL_QUERY=$(cat "$SQL_FILE")
elif [[ -z "$SQL_QUERY" ]]; then
  if [[ -t 0 ]]; then
    echo "ERROR: No SQL query provided. Pass as argument, -f file, or pipe via stdin." >&2
    exit 1
  fi
  SQL_QUERY=$(cat)
fi

if [[ -z "$SQL_QUERY" ]]; then
  echo "ERROR: Empty SQL query." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "$OUTPUT_JSON" == "false" ]]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  BOLD='\033[1m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED='' YELLOW='' GREEN='' BOLD='' CYAN='' NC=''
fi

# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------
run_psql() {
  if [[ -n "$PSQL_CONN" ]]; then
    psql "$PSQL_CONN" -X "$@" 2>&1
  else
    psql -X "$@" 2>&1
  fi
}

# Verify connectivity
if ! run_psql -At -c "SELECT 1;" >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to PostgreSQL. Check connection parameters." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build the EXPLAIN command
# ---------------------------------------------------------------------------
if [[ "$OUTPUT_JSON" == "true" ]]; then
  if [[ "$NO_EXECUTE" == "true" ]]; then
    EXPLAIN_PREFIX="EXPLAIN (FORMAT JSON, BUFFERS, VERBOSE)"
  else
    EXPLAIN_PREFIX="EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON, VERBOSE)"
  fi
else
  if [[ "$NO_EXECUTE" == "true" ]]; then
    EXPLAIN_PREFIX="EXPLAIN (BUFFERS, VERBOSE)"
  else
    EXPLAIN_PREFIX="EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT, VERBOSE)"
  fi
fi

# ---------------------------------------------------------------------------
# Execute inside a rolled-back transaction
# ---------------------------------------------------------------------------
# Build a full SQL block: BEGIN, EXPLAIN, ROLLBACK.
# The ROLLBACK ensures mutations are never committed.
FULL_SQL="BEGIN;
${EXPLAIN_PREFIX}
${SQL_QUERY};
ROLLBACK;"

if [[ "$OUTPUT_JSON" == "true" ]]; then
  # JSON output — emit raw, no decoration
  run_psql -At -c "$FULL_SQL"
  exit 0
fi

# ---------------------------------------------------------------------------
# Text output with highlighting
# ---------------------------------------------------------------------------
printf "${BOLD}Query:${NC}\n"
printf "${CYAN}%s${NC}\n\n" "$SQL_QUERY"

if [[ "$NO_EXECUTE" == "true" ]]; then
  printf "${BOLD}Plan (estimated, no execution):${NC}\n"
else
  printf "${BOLD}Plan (analyzed with actual timings):${NC}\n"
fi

OUTPUT=$(run_psql --pset=footer=off -c "$FULL_SQL" 2>&1)

# Strip BEGIN/ROLLBACK noise
OUTPUT=$(echo "$OUTPUT" | grep -v "^BEGIN$" | grep -v "^ROLLBACK$")

# Process line by line for highlighting
while IFS= read -r line; do
  highlighted=false

  # Highlight slow nodes (actual time > threshold)
  if [[ "$NO_EXECUTE" == "false" ]] && echo "$line" | grep -qoP 'actual time=[\d.]+\.\.(\K[\d.]+)' 2>/dev/null; then
    actual_time=$(echo "$line" | grep -oP 'actual time=[\d.]+\.\.\K[\d.]+' 2>/dev/null || true)
    if [[ -n "$actual_time" ]] && (( $(echo "$actual_time > $THRESHOLD_MS" | bc -l 2>/dev/null || echo 0) )); then
      printf "${RED}⚠ SLOW ${NC}%s\n" "$line"
      highlighted=true
    fi
  fi

  # Highlight sequential scans
  if [[ "$highlighted" == "false" ]] && echo "$line" | grep -qi "Seq Scan"; then
    # Try to extract rows from the line
    rows=$(echo "$line" | grep -oP 'rows=\K\d+' | head -1 2>/dev/null || true)
    if [[ -n "$rows" ]] && (( rows > 10000 )); then
      printf "${YELLOW}⚠ SEQ  ${NC}%s\n" "$line"
      highlighted=true
    elif echo "$line" | grep -qi "Seq Scan"; then
      printf "${YELLOW}  SEQ  ${NC}%s\n" "$line"
      highlighted=true
    fi
  fi

  if [[ "$highlighted" == "false" ]]; then
    printf "       %s\n" "$line"
  fi
done <<< "$OUTPUT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$NO_EXECUTE" == "false" ]]; then
  # Extract total execution time
  EXEC_TIME=$(echo "$OUTPUT" | grep -oP 'Execution Time: \K[\d.]+' | tail -1 || true)
  PLAN_TIME=$(echo "$OUTPUT" | grep -oP 'Planning Time: \K[\d.]+' | tail -1 || true)

  printf "\n${BOLD}Summary:${NC}\n"
  if [[ -n "$PLAN_TIME" ]]; then
    printf "  Planning time:  %s ms\n" "$PLAN_TIME"
  fi
  if [[ -n "$EXEC_TIME" ]]; then
    printf "  Execution time: %s ms\n" "$EXEC_TIME"
    if (( $(echo "$EXEC_TIME > $THRESHOLD_MS" | bc -l 2>/dev/null || echo 0) )); then
      printf "  ${RED}⚠ Execution time exceeds threshold (%s ms)${NC}\n" "$THRESHOLD_MS"
    fi
  fi

  # Count seq scans
  SEQ_COUNT=$(echo "$OUTPUT" | grep -ci "Seq Scan" || true)
  if (( SEQ_COUNT > 0 )); then
    printf "  ${YELLOW}Sequential scans detected: %d${NC}\n" "$SEQ_COUNT"
  fi
fi

printf "\n${BOLD}Done.${NC} All changes were rolled back.\n"
