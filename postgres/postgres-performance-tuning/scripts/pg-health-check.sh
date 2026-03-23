#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# pg-health-check.sh — Comprehensive PostgreSQL Health Check
#
# Usage:
#   pg-health-check.sh [CONNECTION_STRING]
#
# Connects using standard PG environment variables (PGHOST, PGPORT,
# PGDATABASE, PGUSER, PGPASSWORD) or accepts a libpq connection string
# as the first argument.
#
# Examples:
#   PGHOST=localhost PGDATABASE=mydb pg-health-check.sh
#   pg-health-check.sh "host=localhost dbname=mydb user=admin"
#   pg-health-check.sh "postgresql://admin@localhost/mydb"
#
# Checks performed:
#   - Cache hit ratio
#   - Connection count vs max_connections
#   - Longest running query
#   - Dead tuple ratio (top tables)
#   - Index usage ratio
#   - Replication lag (if applicable)
#   - Database age / transaction ID wraparound risk
#   - Temp file usage
#
# Output is color-coded:
#   GREEN  = healthy
#   YELLOW = warning, investigate soon
#   RED    = critical, action required
#
# This script is read-only and never modifies data. Safe for cron or
# manual use.
##############################################################################

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

ok()   { printf "${GREEN}[OK]${NC}     %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC}   %s\n" "$*"; }
crit() { printf "${RED}[CRIT]${NC}   %s\n" "$*"; }
header() { printf "\n${BOLD}=== %s ===${NC}\n" "$*"; }

# ---------------------------------------------------------------------------
# Connection handling
# ---------------------------------------------------------------------------
PSQL_CONN=""
if [[ $# -ge 1 ]]; then
  PSQL_CONN="$1"
fi

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

# Verify connectivity
if ! run_sql "SELECT 1;" >/dev/null 2>&1; then
  echo "ERROR: Cannot connect to PostgreSQL. Check connection parameters." >&2
  exit 1
fi

DB_NAME=$(run_sql "SELECT current_database();")
PG_VERSION=$(run_sql "SHOW server_version;")
printf "${BOLD}PostgreSQL Health Check — %s (v%s)${NC}\n" "$DB_NAME" "$PG_VERSION"
printf "Report generated: %s\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ---------------------------------------------------------------------------
# 1. Cache Hit Ratio
# ---------------------------------------------------------------------------
header "Cache Hit Ratio"
CACHE_HIT=$(run_sql "
  SELECT ROUND(
    COALESCE(
      SUM(blks_hit) * 100.0 / NULLIF(SUM(blks_hit) + SUM(blks_read), 0),
      0
    ), 2
  )
  FROM pg_stat_database
  WHERE datname = current_database();
")

if (( $(echo "$CACHE_HIT >= 99" | bc -l) )); then
  ok "Cache hit ratio: ${CACHE_HIT}%"
elif (( $(echo "$CACHE_HIT >= 95" | bc -l) )); then
  warn "Cache hit ratio: ${CACHE_HIT}% (consider increasing shared_buffers)"
else
  crit "Cache hit ratio: ${CACHE_HIT}% (low — increase shared_buffers or add RAM)"
fi

# ---------------------------------------------------------------------------
# 2. Connection Count vs max_connections
# ---------------------------------------------------------------------------
header "Connections"
read -r CONN_COUNT MAX_CONN <<< "$(run_sql "
  SELECT count(*), current_setting('max_connections')::int
  FROM pg_stat_activity;
" | tr '\t' ' ')"

CONN_PCT=$(echo "scale=1; $CONN_COUNT * 100 / $MAX_CONN" | bc)

if (( $(echo "$CONN_PCT < 70" | bc -l) )); then
  ok "Connections: ${CONN_COUNT}/${MAX_CONN} (${CONN_PCT}%)"
elif (( $(echo "$CONN_PCT < 90" | bc -l) )); then
  warn "Connections: ${CONN_COUNT}/${MAX_CONN} (${CONN_PCT}%) — approaching limit"
else
  crit "Connections: ${CONN_COUNT}/${MAX_CONN} (${CONN_PCT}%) — near exhaustion!"
fi

# ---------------------------------------------------------------------------
# 3. Longest Running Query
# ---------------------------------------------------------------------------
header "Longest Running Query"
LONGEST=$(run_sql "
  SELECT COALESCE(
    (SELECT EXTRACT(EPOCH FROM (now() - query_start))::int
     FROM pg_stat_activity
     WHERE state = 'active'
       AND query NOT ILIKE '%pg_stat_activity%'
       AND pid <> pg_backend_pid()
     ORDER BY query_start ASC
     LIMIT 1),
    0
  );
")

if (( LONGEST < 60 )); then
  ok "Longest active query: ${LONGEST}s"
elif (( LONGEST < 300 )); then
  warn "Longest active query: ${LONGEST}s — may need investigation"
else
  crit "Longest active query: ${LONGEST}s — likely stuck or blocking!"
fi

if (( LONGEST > 0 )); then
  run_sql_with_header "
    SELECT pid,
           now() - query_start AS duration,
           LEFT(query, 100) AS query_preview
    FROM pg_stat_activity
    WHERE state = 'active'
      AND query NOT ILIKE '%pg_stat_activity%'
      AND pid <> pg_backend_pid()
    ORDER BY query_start ASC
    LIMIT 3;
  "
fi

# ---------------------------------------------------------------------------
# 4. Dead Tuple Ratio (top tables)
# ---------------------------------------------------------------------------
header "Dead Tuple Ratio (top 10 tables)"
DEAD_INFO=$(run_sql "
  SELECT relname,
         n_dead_tup,
         n_live_tup,
         CASE WHEN n_live_tup + n_dead_tup > 0
              THEN ROUND(n_dead_tup * 100.0 / (n_live_tup + n_dead_tup), 2)
              ELSE 0
         END AS dead_pct
  FROM pg_stat_user_tables
  WHERE n_dead_tup > 0
  ORDER BY n_dead_tup DESC
  LIMIT 10;
")

if [[ -z "$DEAD_INFO" ]]; then
  ok "No dead tuples detected"
else
  while IFS=$'\t' read -r tbl ndead nlive pct; do
    if (( $(echo "$pct < 5" | bc -l) )); then
      ok "${tbl}: ${pct}% dead (${ndead} dead / ${nlive} live)"
    elif (( $(echo "$pct < 20" | bc -l) )); then
      warn "${tbl}: ${pct}% dead (${ndead} dead / ${nlive} live)"
    else
      crit "${tbl}: ${pct}% dead (${ndead} dead / ${nlive} live) — needs VACUUM"
    fi
  done <<< "$DEAD_INFO"
fi

# ---------------------------------------------------------------------------
# 5. Index Usage Ratio
# ---------------------------------------------------------------------------
header "Index Usage Ratio"
IDX_RATIO=$(run_sql "
  SELECT ROUND(
    COALESCE(
      SUM(idx_scan) * 100.0 / NULLIF(SUM(idx_scan) + SUM(seq_scan), 0),
      100
    ), 2
  )
  FROM pg_stat_user_tables;
")

if (( $(echo "$IDX_RATIO >= 95" | bc -l) )); then
  ok "Index usage ratio: ${IDX_RATIO}%"
elif (( $(echo "$IDX_RATIO >= 80" | bc -l) )); then
  warn "Index usage ratio: ${IDX_RATIO}% — some queries may benefit from indexes"
else
  crit "Index usage ratio: ${IDX_RATIO}% — heavy sequential scanning detected"
fi

# ---------------------------------------------------------------------------
# 6. Replication Lag (if applicable)
# ---------------------------------------------------------------------------
header "Replication"
IS_PRIMARY=$(run_sql "SELECT pg_is_in_recovery();")
if [[ "$IS_PRIMARY" == "f" ]]; then
  REPLICA_COUNT=$(run_sql "SELECT count(*) FROM pg_stat_replication;")
  if (( REPLICA_COUNT > 0 )); then
    run_sql "
      SELECT client_addr,
             state,
             EXTRACT(EPOCH FROM replay_lag)::int AS replay_lag_sec
      FROM pg_stat_replication;
    " | while IFS=$'\t' read -r addr state lag; do
      lag=${lag:-0}
      if (( lag < 10 )); then
        ok "Replica ${addr}: lag=${lag}s state=${state}"
      elif (( lag < 60 )); then
        warn "Replica ${addr}: lag=${lag}s state=${state}"
      else
        crit "Replica ${addr}: lag=${lag}s state=${state}"
      fi
    done
  else
    ok "Primary with no replicas"
  fi
else
  RECV_LAG=$(run_sql "
    SELECT CASE
      WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
      ELSE EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())::int
    END;
  " || echo "N/A")
  if [[ "$RECV_LAG" == "N/A" ]]; then
    warn "Replica — could not determine lag"
  elif (( RECV_LAG < 10 )); then
    ok "Replica replay lag: ${RECV_LAG}s"
  elif (( RECV_LAG < 60 )); then
    warn "Replica replay lag: ${RECV_LAG}s"
  else
    crit "Replica replay lag: ${RECV_LAG}s"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Database Age / Transaction ID Wraparound Risk
# ---------------------------------------------------------------------------
header "Transaction ID Wraparound Risk"
DB_AGE=$(run_sql "
  SELECT age(datfrozenxid)
  FROM pg_database
  WHERE datname = current_database();
")
# Wraparound happens at 2^31 (~2.1 billion). Warn at 500M, crit at 1B.
if (( DB_AGE < 500000000 )); then
  ok "Database age: ${DB_AGE} transactions (limit ~2.1B)"
elif (( DB_AGE < 1000000000 )); then
  warn "Database age: ${DB_AGE} — schedule preventive VACUUM FREEZE"
else
  crit "Database age: ${DB_AGE} — wraparound risk! Run VACUUM FREEZE immediately"
fi

# ---------------------------------------------------------------------------
# 8. Temp File Usage
# ---------------------------------------------------------------------------
header "Temp File Usage"
read -r TEMP_FILES TEMP_BYTES <<< "$(run_sql "
  SELECT temp_files, temp_bytes
  FROM pg_stat_database
  WHERE datname = current_database();
" | tr '\t' ' ')"

TEMP_MB=$(echo "scale=1; ${TEMP_BYTES:-0} / 1048576" | bc)

if (( ${TEMP_FILES:-0} == 0 )); then
  ok "No temp files used"
elif (( $(echo "$TEMP_MB < 100" | bc -l) )); then
  ok "Temp files: ${TEMP_FILES} (${TEMP_MB} MB) — consider increasing work_mem if frequent"
elif (( $(echo "$TEMP_MB < 1024" | bc -l) )); then
  warn "Temp files: ${TEMP_FILES} (${TEMP_MB} MB) — increase work_mem"
else
  crit "Temp files: ${TEMP_FILES} (${TEMP_MB} MB) — heavy disk sorting, increase work_mem"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\n${BOLD}Health check complete.${NC}\n"
