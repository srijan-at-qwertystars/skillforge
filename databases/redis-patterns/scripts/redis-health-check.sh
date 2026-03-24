#!/usr/bin/env bash
# redis-health-check.sh — Check Redis instance health
#
# Usage:
#   ./redis-health-check.sh [host:port] [password]
#
# Examples:
#   ./redis-health-check.sh                        # localhost:6379
#   ./redis-health-check.sh 10.0.0.5:6379
#   ./redis-health-check.sh redis.example.com:6380 mypassword
#
# Reports: connectivity, memory, connections, replication, keyspace, slow log, latency, persistence

set -euo pipefail

HOSTPORT="${1:-localhost:6379}"
HOST="${HOSTPORT%%:*}"
PORT="${HOSTPORT##*:}"
PASSWORD="${2:-}"

AUTH_ARGS=()
if [ -n "$PASSWORD" ]; then
  AUTH_ARGS=(-a "$PASSWORD" --no-auth-warning)
fi

CLI="redis-cli -h $HOST -p $PORT ${AUTH_ARGS[*]:-}"

red()    { printf '\033[0;31m  ✗ %s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m  ⚠ %s\033[0m\n' "$*"; }
header() { printf '\n\033[1;36m━━━ %s ━━━\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }

ISSUES=0
WARNINGS=0

check_pass()    { green "$*"; }
check_warn()    { yellow "$*"; ((WARNINGS++)); }
check_fail()    { red "$*"; ((ISSUES++)); }

get_info() {
  $CLI INFO "$1" 2>/dev/null | tr -d '\r'
}

get_field() {
  echo "$1" | grep "^$2:" | cut -d: -f2
}

# --- Connectivity ---
header "Connectivity"
PONG=$($CLI PING 2>/dev/null || true)
if [ "$PONG" = "PONG" ]; then
  check_pass "Connected to $HOST:$PORT"
else
  check_fail "Cannot connect to $HOST:$PORT"
  echo "Ensure Redis is running and accessible."
  exit 1
fi

SERVER_INFO=$(get_info server)
VERSION=$(get_field "$SERVER_INFO" "redis_version")
UPTIME=$(get_field "$SERVER_INFO" "uptime_in_seconds")
UPTIME_DAYS=$((UPTIME / 86400))
info "Version: $VERSION | Uptime: ${UPTIME_DAYS}d $(( (UPTIME % 86400) / 3600 ))h"

# --- Memory ---
header "Memory"
MEM_INFO=$(get_info memory)
USED_MEM=$(get_field "$MEM_INFO" "used_memory")
USED_MEM_H=$(get_field "$MEM_INFO" "used_memory_human")
MAX_MEM=$(get_field "$MEM_INFO" "maxmemory")
MAX_MEM_H=$(get_field "$MEM_INFO" "maxmemory_human")
FRAG=$(get_field "$MEM_INFO" "mem_fragmentation_ratio")
USED_RSS_H=$(get_field "$MEM_INFO" "used_memory_rss_human")

info "Used: $USED_MEM_H | RSS: $USED_RSS_H | Max: ${MAX_MEM_H:-not set}"

if [ "$MAX_MEM" = "0" ]; then
  check_warn "maxmemory not set — Redis can grow unbounded"
elif [ "$USED_MEM" -gt 0 ] && [ "$MAX_MEM" -gt 0 ]; then
  PCT=$((USED_MEM * 100 / MAX_MEM))
  if [ "$PCT" -gt 90 ]; then
    check_fail "Memory usage at ${PCT}% of maxmemory"
  elif [ "$PCT" -gt 75 ]; then
    check_warn "Memory usage at ${PCT}% of maxmemory"
  else
    check_pass "Memory usage at ${PCT}% of maxmemory"
  fi
fi

FRAG_INT=${FRAG%%.*}
if [ "${FRAG_INT:-1}" -gt 1 ]; then
  FRAG_CHECK=$(echo "$FRAG" | awk '{if ($1 > 1.5) print "high"; else if ($1 > 1.2) print "moderate"; else print "ok"}')
  case "$FRAG_CHECK" in
    high)     check_fail "Memory fragmentation ratio: $FRAG (>1.5 — consider active defrag)" ;;
    moderate) check_warn "Memory fragmentation ratio: $FRAG" ;;
    ok)       check_pass "Memory fragmentation ratio: $FRAG" ;;
  esac
else
  check_pass "Memory fragmentation ratio: $FRAG"
fi

# --- Eviction ---
STATS_INFO=$(get_info stats)
EVICTED=$(get_field "$STATS_INFO" "evicted_keys")
if [ "${EVICTED:-0}" -gt 0 ]; then
  check_warn "Evicted keys: $EVICTED (keys are being evicted due to memory pressure)"
else
  check_pass "No evicted keys"
fi

# --- Connections ---
header "Connections"
CLIENT_INFO=$(get_info clients)
CONNECTED=$(get_field "$CLIENT_INFO" "connected_clients")
BLOCKED=$(get_field "$CLIENT_INFO" "blocked_clients")
MAX_CLIENTS=$($CLI CONFIG GET maxclients 2>/dev/null | tail -1)

info "Connected: $CONNECTED | Blocked: $BLOCKED | Max: $MAX_CLIENTS"

if [ "$MAX_CLIENTS" -gt 0 ]; then
  CONN_PCT=$((CONNECTED * 100 / MAX_CLIENTS))
  if [ "$CONN_PCT" -gt 80 ]; then
    check_fail "Connection usage at ${CONN_PCT}% of maxclients"
  elif [ "$CONN_PCT" -gt 50 ]; then
    check_warn "Connection usage at ${CONN_PCT}% of maxclients"
  else
    check_pass "Connection usage at ${CONN_PCT}% of maxclients"
  fi
fi

REJECTED=$(get_field "$STATS_INFO" "rejected_connections")
if [ "${REJECTED:-0}" -gt 0 ]; then
  check_fail "Rejected connections: $REJECTED"
else
  check_pass "No rejected connections"
fi

# --- Replication ---
header "Replication"
REPL_INFO=$(get_info replication)
ROLE=$(get_field "$REPL_INFO" "role")
info "Role: $ROLE"

if [ "$ROLE" = "master" ]; then
  SLAVES=$(get_field "$REPL_INFO" "connected_slaves")
  info "Connected replicas: $SLAVES"
  if [ "${SLAVES:-0}" -gt 0 ]; then
    for i in $(seq 0 $((SLAVES - 1))); do
      SLAVE_LINE=$(get_field "$REPL_INFO" "slave${i}")
      SLAVE_STATE=$(echo "$SLAVE_LINE" | grep -oP 'state=\K[^,]+')
      SLAVE_LAG=$(echo "$SLAVE_LINE" | grep -oP 'lag=\K[^,]+' || echo "?")
      SLAVE_IP=$(echo "$SLAVE_LINE" | grep -oP 'ip=\K[^,]+')
      if [ "$SLAVE_STATE" = "online" ] && [ "$SLAVE_LAG" != "?" ] && [ "$SLAVE_LAG" -lt 5 ]; then
        check_pass "Replica $SLAVE_IP: state=$SLAVE_STATE lag=${SLAVE_LAG}s"
      elif [ "$SLAVE_STATE" = "online" ]; then
        check_warn "Replica $SLAVE_IP: state=$SLAVE_STATE lag=${SLAVE_LAG}s"
      else
        check_fail "Replica $SLAVE_IP: state=$SLAVE_STATE"
      fi
    done
  fi
elif [ "$ROLE" = "slave" ]; then
  LINK=$(get_field "$REPL_INFO" "master_link_status")
  MASTER_HOST=$(get_field "$REPL_INFO" "master_host")
  LAST_IO=$(get_field "$REPL_INFO" "master_last_io_seconds_ago")
  info "Primary: $MASTER_HOST | Link: $LINK | Last I/O: ${LAST_IO}s ago"
  if [ "$LINK" = "up" ]; then
    check_pass "Replication link is up"
  else
    check_fail "Replication link is DOWN"
  fi
fi

# --- Keyspace ---
header "Keyspace"
KS_INFO=$(get_info keyspace)
TOTAL_KEYS=0
if [ -n "$KS_INFO" ]; then
  while IFS= read -r line; do
    DB=$(echo "$line" | cut -d: -f1)
    KEYS=$(echo "$line" | grep -oP 'keys=\K[0-9]+' || echo 0)
    EXPIRES=$(echo "$line" | grep -oP 'expires=\K[0-9]+' || echo 0)
    if [ -n "$DB" ] && echo "$DB" | grep -q "^db"; then
      info "$DB: keys=$KEYS expires=$EXPIRES"
      TOTAL_KEYS=$((TOTAL_KEYS + KEYS))
    fi
  done <<< "$KS_INFO"
else
  info "No keys in any database"
fi
info "Total keys: $TOTAL_KEYS"

# Cache hit ratio
HITS=$(get_field "$STATS_INFO" "keyspace_hits")
MISSES=$(get_field "$STATS_INFO" "keyspace_misses")
if [ "${HITS:-0}" -gt 0 ] || [ "${MISSES:-0}" -gt 0 ]; then
  TOTAL_OPS=$((HITS + MISSES))
  if [ "$TOTAL_OPS" -gt 0 ]; then
    HIT_RATIO=$((HITS * 100 / TOTAL_OPS))
    if [ "$HIT_RATIO" -lt 50 ]; then
      check_warn "Cache hit ratio: ${HIT_RATIO}% ($HITS hits / $MISSES misses)"
    else
      check_pass "Cache hit ratio: ${HIT_RATIO}% ($HITS hits / $MISSES misses)"
    fi
  fi
fi

# --- Persistence ---
header "Persistence"
PERSIST_INFO=$(get_info persistence)
AOF_ENABLED=$(get_field "$PERSIST_INFO" "aof_enabled")
RDB_STATUS=$(get_field "$PERSIST_INFO" "rdb_last_bgsave_status")
RDB_LAST=$(get_field "$PERSIST_INFO" "rdb_last_save_time")

info "AOF enabled: ${AOF_ENABLED:-0}"
if [ "$RDB_STATUS" = "ok" ]; then
  check_pass "Last RDB save: ok (at $(date -d @"$RDB_LAST" 2>/dev/null || date -r "$RDB_LAST" 2>/dev/null || echo "$RDB_LAST"))"
elif [ -n "$RDB_STATUS" ]; then
  check_fail "Last RDB save: $RDB_STATUS"
fi

if [ "${AOF_ENABLED:-0}" = "1" ]; then
  AOF_STATUS=$(get_field "$PERSIST_INFO" "aof_last_bgrewriteaof_status")
  if [ "$AOF_STATUS" = "ok" ]; then
    check_pass "Last AOF rewrite: ok"
  elif [ -n "$AOF_STATUS" ]; then
    check_fail "Last AOF rewrite: $AOF_STATUS"
  fi
fi

# --- Slow Log ---
header "Slow Log"
SLOWLOG_LEN=$($CLI SLOWLOG LEN 2>/dev/null)
info "Slow log entries: $SLOWLOG_LEN"

if [ "${SLOWLOG_LEN:-0}" -gt 0 ]; then
  info "Last 5 slow commands:"
  $CLI SLOWLOG GET 5 2>/dev/null | while IFS= read -r line; do
    info "  $line"
  done
  if [ "${SLOWLOG_LEN:-0}" -gt 50 ]; then
    check_warn "Slow log has $SLOWLOG_LEN entries — review with SLOWLOG GET"
  else
    check_pass "Slow log entries within normal range"
  fi
else
  check_pass "No slow log entries"
fi

# --- Ops/sec ---
header "Throughput"
OPS=$(get_field "$STATS_INFO" "instantaneous_ops_per_sec")
INPUT_BW=$(get_field "$STATS_INFO" "instantaneous_input_kbps")
OUTPUT_BW=$(get_field "$STATS_INFO" "instantaneous_output_kbps")
info "Ops/sec: $OPS | Input: ${INPUT_BW}KB/s | Output: ${OUTPUT_BW}KB/s"

# --- Summary ---
header "Summary"
if [ "$ISSUES" -gt 0 ]; then
  red "$ISSUES issue(s) found"
fi
if [ "$WARNINGS" -gt 0 ]; then
  yellow "$WARNINGS warning(s) found"
fi
if [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  green "All checks passed — Redis is healthy"
fi

exit "$ISSUES"
