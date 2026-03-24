#!/usr/bin/env bash
# health-check.sh — Check Redis/Valkey instance health, memory, replication, and slow queries
#
# Usage:
#   ./health-check.sh [OPTIONS]
#
# Options:
#   -h, --host HOST       Server host (default: 127.0.0.1)
#   -p, --port PORT       Server port (default: 6379)
#   -a, --auth PASSWORD   Authentication password
#   --tls                 Connect via TLS
#   --json                Output in JSON format
#   --quiet               Only show warnings and errors
#   --help                Show this help message
#
# Exit codes:
#   0 — healthy
#   1 — warnings detected
#   2 — critical issues detected
#   3 — connection failed

set -euo pipefail

# --- Defaults ---
HOST="127.0.0.1"
PORT="6379"
AUTH=""
TLS_FLAG=""
JSON_OUTPUT=false
QUIET=false
WARNINGS=0
CRITICALS=0

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)    HOST="$2"; shift 2 ;;
    -p|--port)    PORT="$2"; shift 2 ;;
    -a|--auth)    AUTH="$2"; shift 2 ;;
    --tls)        TLS_FLAG="--tls"; shift ;;
    --json)       JSON_OUTPUT=true; shift ;;
    --quiet)      QUIET=true; shift ;;
    --help)
      sed -n '2,/^$/s/^# //p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 3 ;;
  esac
done

# --- Detect CLI ---
if command -v valkey-cli &>/dev/null; then
  CLI="valkey-cli"
elif command -v redis-cli &>/dev/null; then
  CLI="redis-cli"
else
  echo "ERROR: Neither valkey-cli nor redis-cli found" >&2
  exit 3
fi

CLI_ARGS=(-h "$HOST" -p "$PORT")
[[ -n "$AUTH" ]] && CLI_ARGS+=(-a "$AUTH" --no-auth-warning)
[[ -n "$TLS_FLAG" ]] && CLI_ARGS+=("$TLS_FLAG")

# --- Helper functions ---
rcli() {
  $CLI "${CLI_ARGS[@]}" "$@" 2>/dev/null
}

info_field() {
  local section="$1"
  local field="$2"
  rcli INFO "$section" | grep "^${field}:" | cut -d: -f2 | tr -d '[:space:]'
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  if [[ "$JSON_OUTPUT" != true ]]; then
    echo "  ⚠  WARNING: $1"
  fi
}

crit() {
  CRITICALS=$((CRITICALS + 1))
  if [[ "$JSON_OUTPUT" != true ]]; then
    echo "  ✗  CRITICAL: $1"
  fi
}

ok() {
  if [[ "$QUIET" != true && "$JSON_OUTPUT" != true ]]; then
    echo "  ✓  $1"
  fi
}

header() {
  if [[ "$JSON_OUTPUT" != true ]]; then
    echo ""
    echo "━━━ $1 ━━━"
  fi
}

# --- Connection test ---
if ! rcli PING | grep -q "PONG"; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    echo '{"status":"connection_failed","host":"'"$HOST"'","port":'"$PORT"'}'
  else
    echo "CRITICAL: Cannot connect to $HOST:$PORT"
  fi
  exit 3
fi

if [[ "$JSON_OUTPUT" != true ]]; then
  VERSION=$(info_field server "redis_version")
  UPTIME=$(info_field server "uptime_in_seconds")
  UPTIME_DAYS=$((UPTIME / 86400))
  echo "=== Health Check: $HOST:$PORT ==="
  echo "Server: $($CLI --version 2>/dev/null | head -1) | Version: $VERSION | Uptime: ${UPTIME_DAYS}d"
fi

# --- 1. Memory ---
header "Memory"

USED_MEM=$(info_field memory "used_memory")
USED_MEM_HR=$(info_field memory "used_memory_human")
MAX_MEM=$(info_field memory "maxmemory")
FRAG_RATIO=$(info_field memory "mem_fragmentation_ratio")

if [[ "$MAX_MEM" != "0" && -n "$MAX_MEM" ]]; then
  MEM_PCT=$((USED_MEM * 100 / MAX_MEM))
  MAX_MEM_HR=$(info_field memory "maxmemory_human")
  if [[ $MEM_PCT -ge 90 ]]; then
    crit "Memory usage: ${MEM_PCT}% ($USED_MEM_HR / $MAX_MEM_HR)"
  elif [[ $MEM_PCT -ge 75 ]]; then
    warn "Memory usage: ${MEM_PCT}% ($USED_MEM_HR / $MAX_MEM_HR)"
  else
    ok "Memory usage: ${MEM_PCT}% ($USED_MEM_HR / $MAX_MEM_HR)"
  fi
else
  warn "maxmemory not set (unlimited) — used: $USED_MEM_HR"
fi

if [[ -n "$FRAG_RATIO" ]]; then
  FRAG_INT=$(echo "$FRAG_RATIO" | cut -d. -f1)
  if [[ "$FRAG_INT" -ge 2 ]]; then
    crit "Memory fragmentation ratio: $FRAG_RATIO (>2.0, severe fragmentation)"
  elif [[ $(echo "$FRAG_RATIO > 1.5" | bc -l 2>/dev/null || echo 0) == "1" ]]; then
    warn "Memory fragmentation ratio: $FRAG_RATIO (>1.5, consider defrag)"
  else
    ok "Memory fragmentation ratio: $FRAG_RATIO"
  fi
fi

EVICTED=$(info_field stats "evicted_keys")
if [[ -n "$EVICTED" && "$EVICTED" != "0" ]]; then
  warn "Evicted keys: $EVICTED"
else
  ok "No evicted keys"
fi

# --- 2. Clients ---
header "Clients"

CONNECTED=$(info_field clients "connected_clients")
MAX_CLIENTS=$(rcli CONFIG GET maxclients | tail -1)
BLOCKED=$(info_field clients "blocked_clients")
REJECTED=$(info_field stats "rejected_connections")

if [[ -n "$MAX_CLIENTS" && "$MAX_CLIENTS" != "0" ]]; then
  CLIENT_PCT=$((CONNECTED * 100 / MAX_CLIENTS))
  if [[ $CLIENT_PCT -ge 90 ]]; then
    crit "Connected clients: $CONNECTED / $MAX_CLIENTS (${CLIENT_PCT}%)"
  elif [[ $CLIENT_PCT -ge 75 ]]; then
    warn "Connected clients: $CONNECTED / $MAX_CLIENTS (${CLIENT_PCT}%)"
  else
    ok "Connected clients: $CONNECTED / $MAX_CLIENTS (${CLIENT_PCT}%)"
  fi
fi

if [[ -n "$BLOCKED" && "$BLOCKED" != "0" ]]; then
  warn "Blocked clients: $BLOCKED"
fi

if [[ -n "$REJECTED" && "$REJECTED" != "0" ]]; then
  warn "Rejected connections (total): $REJECTED"
fi

# --- 3. Replication ---
header "Replication"

ROLE=$(info_field replication "role")
ok "Role: $ROLE"

if [[ "$ROLE" == "master" ]]; then
  NUM_SLAVES=$(info_field replication "connected_slaves")
  ok "Connected replicas: $NUM_SLAVES"

  for i in $(seq 0 $((NUM_SLAVES - 1))); do
    SLAVE_INFO=$(rcli INFO replication | grep "^slave${i}:" | tr -d '[:space:]')
    SLAVE_LAG=$(echo "$SLAVE_INFO" | grep -oP 'lag=\K[0-9]+' || echo "unknown")
    SLAVE_STATE=$(echo "$SLAVE_INFO" | grep -oP 'state=\K[a-z]+' || echo "unknown")
    SLAVE_IP=$(echo "$SLAVE_INFO" | grep -oP 'ip=\K[^,]+' || echo "unknown")
    SLAVE_PORT=$(echo "$SLAVE_INFO" | grep -oP 'port=\K[0-9]+' || echo "unknown")

    if [[ "$SLAVE_STATE" != "online" ]]; then
      crit "Replica $i ($SLAVE_IP:$SLAVE_PORT): state=$SLAVE_STATE"
    elif [[ "$SLAVE_LAG" != "unknown" && "$SLAVE_LAG" -gt 5 ]]; then
      warn "Replica $i ($SLAVE_IP:$SLAVE_PORT): lag=${SLAVE_LAG}s"
    else
      ok "Replica $i ($SLAVE_IP:$SLAVE_PORT): state=$SLAVE_STATE, lag=${SLAVE_LAG}s"
    fi
  done
elif [[ "$ROLE" == "slave" ]]; then
  LINK_STATUS=$(info_field replication "master_link_status")
  LAST_IO=$(info_field replication "master_last_io_seconds_ago")

  if [[ "$LINK_STATUS" != "up" ]]; then
    crit "Master link status: $LINK_STATUS"
  else
    ok "Master link status: up (last I/O: ${LAST_IO}s ago)"
  fi

  SYNC_PROGRESS=$(info_field replication "master_sync_in_progress")
  if [[ "$SYNC_PROGRESS" == "1" ]]; then
    warn "Full sync in progress"
  fi
fi

# --- 4. Persistence ---
header "Persistence"

AOF_ENABLED=$(info_field persistence "aof_enabled")
RDB_LAST_STATUS=$(info_field persistence "rdb_last_bgsave_status")
RDB_LAST_TIME=$(info_field persistence "rdb_last_save_time")

if [[ "$RDB_LAST_STATUS" != "ok" && -n "$RDB_LAST_STATUS" ]]; then
  crit "Last RDB save status: $RDB_LAST_STATUS"
else
  ok "Last RDB save status: ok"
fi

if [[ -n "$RDB_LAST_TIME" && "$RDB_LAST_TIME" != "0" ]]; then
  NOW=$(date +%s)
  RDB_AGE=$((NOW - RDB_LAST_TIME))
  RDB_AGE_HR=$((RDB_AGE / 3600))
  if [[ $RDB_AGE -gt 14400 ]]; then
    warn "Last RDB save: ${RDB_AGE_HR}h ago (>4h)"
  else
    ok "Last RDB save: ${RDB_AGE_HR}h ago"
  fi
fi

if [[ "$AOF_ENABLED" == "1" ]]; then
  AOF_STATUS=$(info_field persistence "aof_last_bgrewriteaof_status")
  AOF_REWRITE=$(info_field persistence "aof_rewrite_in_progress")
  ok "AOF enabled (last rewrite status: ${AOF_STATUS:-n/a})"
  if [[ "$AOF_REWRITE" == "1" ]]; then
    warn "AOF rewrite in progress"
  fi
else
  ok "AOF disabled"
fi

# --- 5. Slow Queries ---
header "Slow Queries"

SLOWLOG_LEN=$(rcli SLOWLOG LEN 2>/dev/null || echo "0")
if [[ -n "$SLOWLOG_LEN" && "$SLOWLOG_LEN" != "0" ]]; then
  warn "Slow log entries: $SLOWLOG_LEN"
  if [[ "$QUIET" != true && "$JSON_OUTPUT" != true ]]; then
    echo "  Recent slow queries:"
    rcli SLOWLOG GET 5 2>/dev/null | head -30 | sed 's/^/    /'
  fi
else
  ok "No slow queries in log"
fi

# --- 6. Key Statistics ---
header "Keyspace"

TOTAL_KEYS=$(rcli DBSIZE | grep -oP '\d+' || echo "0")
ok "Total keys: $TOTAL_KEYS"

HIT=$(info_field stats "keyspace_hits")
MISS=$(info_field stats "keyspace_misses")
if [[ -n "$HIT" && -n "$MISS" && $((HIT + MISS)) -gt 0 ]]; then
  HIT_RATIO=$((HIT * 100 / (HIT + MISS)))
  if [[ $HIT_RATIO -lt 80 ]]; then
    warn "Cache hit ratio: ${HIT_RATIO}% (hits=$HIT, misses=$MISS)"
  else
    ok "Cache hit ratio: ${HIT_RATIO}% (hits=$HIT, misses=$MISS)"
  fi
fi

OPS=$(info_field stats "instantaneous_ops_per_sec")
ok "Current ops/sec: $OPS"

# --- 7. Cluster (if enabled) ---
CLUSTER_ENABLED=$(info_field cluster "cluster_enabled")
if [[ "$CLUSTER_ENABLED" == "1" ]]; then
  header "Cluster"
  CLUSTER_STATE=$(rcli CLUSTER INFO | grep "cluster_state" | cut -d: -f2 | tr -d '[:space:]')
  CLUSTER_SLOTS_OK=$(rcli CLUSTER INFO | grep "cluster_slots_ok" | cut -d: -f2 | tr -d '[:space:]')
  CLUSTER_SLOTS_FAIL=$(rcli CLUSTER INFO | grep "cluster_slots_pfail\|cluster_slots_fail" | cut -d: -f2 | tr -d '[:space:]')

  if [[ "$CLUSTER_STATE" != "ok" ]]; then
    crit "Cluster state: $CLUSTER_STATE"
  else
    ok "Cluster state: ok (slots ok: $CLUSTER_SLOTS_OK)"
  fi

  if [[ -n "$CLUSTER_SLOTS_FAIL" && "$CLUSTER_SLOTS_FAIL" != "0" ]]; then
    crit "Failed cluster slots: $CLUSTER_SLOTS_FAIL"
  fi
fi

# --- Summary ---
if [[ "$JSON_OUTPUT" != true ]]; then
  echo ""
  echo "━━━ Summary ━━━"
  if [[ $CRITICALS -gt 0 ]]; then
    echo "  Status: CRITICAL ($CRITICALS critical, $WARNINGS warnings)"
  elif [[ $WARNINGS -gt 0 ]]; then
    echo "  Status: WARNING ($WARNINGS warnings)"
  else
    echo "  Status: HEALTHY ✓"
  fi
  echo ""
fi

# --- Exit code ---
if [[ $CRITICALS -gt 0 ]]; then
  exit 2
elif [[ $WARNINGS -gt 0 ]]; then
  exit 1
else
  exit 0
fi
