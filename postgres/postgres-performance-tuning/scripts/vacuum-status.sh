#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# vacuum-status.sh — Vacuum health report for PostgreSQL
#
# Usage:
#   vacuum-status.sh [OPTIONS] [CONNECTION_STRING]
#
# Options:
#   -d, --dead-threshold PCT   Dead tuple % to flag as warning (default: 5)
#   -D, --dead-critical  PCT   Dead tuple % to flag as critical (default: 20)
#   -a, --age-warn       N     TXID age warning threshold (default: 500000000)
#   -A, --age-critical   N     TXID age critical threshold (default: 1000000000)
#   -s, --stale-hours    N     Hours since last autovacuum to warn (default: 24)
#   -h, --help                 Show this help message
#
# Connects using standard PG environment variables (PGHOST, PGPORT,
# PGDATABASE, PGUSER, PGPASSWORD) or accepts a libpq connection string
# as the last argument.
#
# Examples:
#   PGDATABASE=mydb vacuum-status.sh
#   vacuum-status.sh "postgresql://admin@localhost/mydb"
#   vacuum-status.sh -d 3 -D 15 --stale-hours 12
#
# Reports:
#   1. Tables with highest dead tuple ratios
#   2. Tables where autovacuum hasn't run recently
#   3. Currently running vacuum / autovacuum processes
#   4. Transaction ID age and wraparound risk (per table & database)
#
# Output is color-coded:
#   GREEN  = healthy
#   YELLOW = warning
#   RED    = critical
#
# This script is read-only and never modifies data.
##############################################################################

# ---------------------------------------------------------------------------
# Defaults & argument parsing
# ---------------------------------------------------------------------------
DEAD_WARN=5
DEAD_CRIT=20
AGE_WARN=500000000
AGE_CRIT=1000000000
STALE_HOURS=24
PSQL_CONN=""

usage() {
  sed -n '3,/^##*$/p' "$0" | head -n -1 | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dead-threshold) DEAD_WARN="$2"; shift 2 ;;
    -D|--dead-critical)  DEAD_CRIT="$2"; shift 2 ;;
    -a|--age-warn)       AGE_WARN="$2"; shift 2 ;;
    -A|--age-critical)   AGE_CRIT="$2"; shift 2 ;;
    -s|--stale-hours)    STALE_HOURS="$2"; shift 2 ;;
    -h|--help)           usage ;;
    -*)                  echo "Unknown option: $1" >&2; exit 1 ;;
    *)                   PSQL_CONN="$1"; shift ;;
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
  NC='\033[0m'
else
  RED='' YELLOW='' GREEN='' BOLD='' NC=''
fi

ok()     { printf "${GREEN}[OK]${NC}     %s\n" "$*"; }
warn()   { printf "${YELLOW}[WARN]${NC}   %s\n" "$*"; }
crit()   { printf "${RED}[CRIT]${NC}   %s\n" "$*"; }
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
PG_VERSION=$(run_sql "SHOW server_version;")
printf "${BOLD}Vacuum Status Report — %s (v%s)${NC}\n" "$DB_NAME" "$PG_VERSION"
printf "Report generated: %s\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
printf "Thresholds: dead_warn=%s%% dead_crit=%s%% stale=%sh age_warn=%s age_crit=%s\n" \
  "$DEAD_WARN" "$DEAD_CRIT" "$STALE_HOURS" "$AGE_WARN" "$AGE_CRIT"

# ---------------------------------------------------------------------------
# 1. Tables with highest dead tuple ratios
# ---------------------------------------------------------------------------
header "Dead Tuple Ratios (top 20)"

DEAD_TUPLES=$(run_sql "
  SELECT schemaname,
         relname,
         n_live_tup,
         n_dead_tup,
         CASE WHEN n_live_tup + n_dead_tup > 0
              THEN ROUND(n_dead_tup * 100.0 / (n_live_tup + n_dead_tup), 2)
              ELSE 0
         END AS dead_pct,
         pg_size_pretty(pg_relation_size(relid)) AS table_size,
         COALESCE(last_autovacuum::text, 'never') AS last_autovacuum,
         COALESCE(last_vacuum::text, 'never') AS last_vacuum
  FROM pg_stat_user_tables
  WHERE n_live_tup + n_dead_tup > 0
  ORDER BY n_dead_tup DESC
  LIMIT 20;
")

if [[ -z "$DEAD_TUPLES" ]]; then
  ok "No dead tuples found in any user table"
else
  printf "%-15s %-25s %10s %10s %8s %10s\n" \
    "SCHEMA" "TABLE" "LIVE" "DEAD" "DEAD %" "SIZE"
  printf "%-15s %-25s %10s %10s %8s %10s\n" \
    "------" "-----" "----" "----" "------" "----"

  while IFS=$'\t' read -r schema tbl live dead pct size last_auto last_vac; do
    color="$GREEN"
    if (( $(echo "$pct >= $DEAD_CRIT" | bc -l) )); then
      color="$RED"
    elif (( $(echo "$pct >= $DEAD_WARN" | bc -l) )); then
      color="$YELLOW"
    fi
    printf "${color}%-15s %-25s %10s %10s %7s%% %10s${NC}\n" \
      "$schema" "$tbl" "$live" "$dead" "$pct" "$size"
  done <<< "$DEAD_TUPLES"
fi

# ---------------------------------------------------------------------------
# 2. Tables where autovacuum hasn't run recently
# ---------------------------------------------------------------------------
header "Stale Autovacuum (not run in >${STALE_HOURS}h)"

STALE=$(run_sql "
  SELECT schemaname,
         relname,
         n_live_tup,
         n_dead_tup,
         COALESCE(last_autovacuum::text, 'never') AS last_autovacuum,
         COALESCE(last_vacuum::text, 'never') AS last_vacuum,
         CASE
           WHEN last_autovacuum IS NULL AND last_vacuum IS NULL THEN -1
           ELSE EXTRACT(EPOCH FROM now() -
                GREATEST(COALESCE(last_autovacuum, '1970-01-01'),
                         COALESCE(last_vacuum, '1970-01-01')))::int / 3600
         END AS hours_since
  FROM pg_stat_user_tables
  WHERE n_live_tup > 100
    AND (
      (last_autovacuum IS NULL AND last_vacuum IS NULL)
      OR GREATEST(COALESCE(last_autovacuum, '1970-01-01'),
                  COALESCE(last_vacuum, '1970-01-01'))
         < now() - interval '${STALE_HOURS} hours'
    )
  ORDER BY n_dead_tup DESC
  LIMIT 20;
")

if [[ -z "$STALE" ]]; then
  ok "All tables have been vacuumed within the last ${STALE_HOURS} hours"
else
  while IFS=$'\t' read -r schema tbl live dead last_auto last_vac hours; do
    if [[ "$hours" == "-1" ]]; then
      crit "${schema}.${tbl} — NEVER vacuumed (${live} live, ${dead} dead)"
    else
      warn "${schema}.${tbl} — last vacuum ${hours}h ago (${dead} dead tuples)"
    fi
  done <<< "$STALE"
fi

# ---------------------------------------------------------------------------
# 3. Currently running vacuum / autovacuum processes
# ---------------------------------------------------------------------------
header "Running Vacuum Processes"

RUNNING=$(run_sql "
  SELECT pid,
         query,
         now() - query_start AS duration,
         wait_event_type,
         wait_event
  FROM pg_stat_activity
  WHERE query ILIKE '%vacuum%'
    AND state = 'active'
    AND pid <> pg_backend_pid();
")

if [[ -z "$RUNNING" ]]; then
  ok "No vacuum processes currently running"
else
  printf "%-8s %-12s %-15s %s\n" "PID" "DURATION" "WAIT" "QUERY"
  printf "%-8s %-12s %-15s %s\n" "---" "--------" "----" "-----"
  while IFS=$'\t' read -r pid query duration wait_type wait_event; do
    wait_info="${wait_type:-none}/${wait_event:-none}"
    printf "%-8s %-12s %-15s %s\n" "$pid" "$duration" "$wait_info" \
      "$(echo "$query" | head -c 80)"
  done <<< "$RUNNING"
fi

# Autovacuum worker count
AV_WORKERS=$(run_sql "
  SELECT count(*)
  FROM pg_stat_activity
  WHERE query ILIKE 'autovacuum:%';
")
AV_MAX=$(run_sql "SHOW autovacuum_max_workers;")
printf "\nAutovacuum workers: %s / %s\n" "$AV_WORKERS" "$AV_MAX"
if [[ "$AV_WORKERS" == "$AV_MAX" ]]; then
  warn "All autovacuum workers are busy — autovacuum may be falling behind"
fi

# ---------------------------------------------------------------------------
# 4. Transaction ID age — per-table wraparound risk
# ---------------------------------------------------------------------------
header "Transaction ID Age (per table)"

TABLE_AGE=$(run_sql "
  SELECT n.nspname AS schema,
         c.relname AS table_name,
         age(c.relfrozenxid) AS xid_age,
         pg_size_pretty(pg_relation_size(c.oid)) AS table_size
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r'
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  ORDER BY age(c.relfrozenxid) DESC
  LIMIT 20;
")

if [[ -z "$TABLE_AGE" ]]; then
  ok "No user tables found"
else
  printf "%-15s %-30s %15s %12s %s\n" \
    "SCHEMA" "TABLE" "XID AGE" "SIZE" "STATUS"
  printf "%-15s %-30s %15s %12s %s\n" \
    "------" "-----" "-------" "----" "------"

  while IFS=$'\t' read -r schema tbl age size; do
    if (( age >= AGE_CRIT )); then
      status="${RED}CRITICAL${NC}"
    elif (( age >= AGE_WARN )); then
      status="${YELLOW}WARNING${NC}"
    else
      status="${GREEN}OK${NC}"
    fi
    printf "%-15s %-30s %15s %12s " "$schema" "$tbl" "$age" "$size"
    printf "${status}\n"
  done <<< "$TABLE_AGE"
fi

# ---------------------------------------------------------------------------
# 5. Database-level age
# ---------------------------------------------------------------------------
header "Transaction ID Age (per database)"

DB_AGE=$(run_sql "
  SELECT datname,
         age(datfrozenxid) AS xid_age
  FROM pg_database
  WHERE datallowconn
  ORDER BY age(datfrozenxid) DESC;
")

while IFS=$'\t' read -r db age; do
  if (( age >= AGE_CRIT )); then
    crit "Database '${db}': age=${age} — WRAPAROUND RISK! Run VACUUM FREEZE"
  elif (( age >= AGE_WARN )); then
    warn "Database '${db}': age=${age} — schedule VACUUM FREEZE"
  else
    ok "Database '${db}': age=${age}"
  fi
done <<< "$DB_AGE"

# ---------------------------------------------------------------------------
# 6. Autovacuum settings summary
# ---------------------------------------------------------------------------
header "Autovacuum Configuration"

run_sql_with_header "
  SELECT name, setting, unit, short_desc
  FROM pg_settings
  WHERE name LIKE 'autovacuum%'
  ORDER BY name;
"

printf "\n${BOLD}Vacuum status report complete.${NC}\n"
