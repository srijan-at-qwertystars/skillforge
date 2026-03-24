#!/usr/bin/env bash
# =============================================================================
# redis-health-check.sh — Redis Health Check Script
# =============================================================================
# Usage: ./redis-health-check.sh [-h HOST] [-p PORT] [-a PASSWORD] [-n DB]
#
# Checks: memory usage, connected clients, hit ratio, replication status,
#         slow log entries, big keys scan.
#
# Examples:
#   ./redis-health-check.sh
#   ./redis-health-check.sh -h redis.example.com -p 6380
#   ./redis-health-check.sh -a mypassword
#   REDISCLI_AUTH=secret ./redis-health-check.sh
# =============================================================================

set -euo pipefail

# Defaults
HOST="127.0.0.1"
PORT="6379"
AUTH=""
DB="0"

while getopts "h:p:a:n:" opt; do
    case "$opt" in
        h) HOST="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        a) AUTH="$OPTARG" ;;
        n) DB="$OPTARG" ;;
        *) echo "Usage: $0 [-h host] [-p port] [-a password] [-n db]" >&2; exit 1 ;;
    esac
done

REDIS_CLI="redis-cli -h $HOST -p $PORT"
[ -n "$AUTH" ] && REDIS_CLI="$REDIS_CLI -a $AUTH --no-auth-warning"
[ "$DB" != "0" ] && REDIS_CLI="$REDIS_CLI -n $DB"

rcli() {
    $REDIS_CLI "$@" 2>/dev/null
}

get_info_field() {
    local section="$1"
    local field="$2"
    rcli INFO "$section" | grep "^${field}:" | cut -d: -f2 | tr -d '[:space:]'
}

divider() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════"
}

# --- Connectivity Check ---
if ! rcli PING | grep -q "PONG"; then
    echo "ERROR: Cannot connect to Redis at $HOST:$PORT" >&2
    exit 1
fi

echo "Redis Health Check — $(date '+%Y-%m-%d %H:%M:%S')"
echo "Target: $HOST:$PORT"

# --- Server Info ---
divider "SERVER INFO"
REDIS_VERSION=$(get_info_field server redis_version)
UPTIME_DAYS=$(get_info_field server uptime_in_days)
REDIS_MODE=$(get_info_field server redis_mode)
OS=$(get_info_field server os)
printf "  Version:     %s\n" "$REDIS_VERSION"
printf "  Mode:        %s\n" "$REDIS_MODE"
printf "  Uptime:      %s days\n" "$UPTIME_DAYS"
printf "  OS:          %s\n" "$OS"

# --- Memory ---
divider "MEMORY USAGE"
USED_MEMORY_HUMAN=$(get_info_field memory used_memory_human)
USED_MEMORY_RSS_HUMAN=$(get_info_field memory used_memory_rss_human)
USED_MEMORY_PEAK_HUMAN=$(get_info_field memory used_memory_peak_human)
MAXMEMORY=$(get_info_field memory maxmemory)
MAXMEMORY_HUMAN=$(get_info_field memory maxmemory_human)
MAXMEMORY_POLICY=$(get_info_field memory maxmemory_policy)
FRAG_RATIO=$(get_info_field memory mem_fragmentation_ratio)
ALLOCATOR=$(get_info_field memory mem_allocator)

printf "  Used Memory:         %s\n" "$USED_MEMORY_HUMAN"
printf "  RSS Memory:          %s\n" "$USED_MEMORY_RSS_HUMAN"
printf "  Peak Memory:         %s\n" "$USED_MEMORY_PEAK_HUMAN"
printf "  Max Memory:          %s\n" "${MAXMEMORY_HUMAN:-unlimited}"
printf "  Eviction Policy:     %s\n" "$MAXMEMORY_POLICY"
printf "  Fragmentation Ratio: %s\n" "$FRAG_RATIO"
printf "  Allocator:           %s\n" "$ALLOCATOR"

# Fragmentation warnings
if command -v bc &>/dev/null && [ -n "$FRAG_RATIO" ]; then
    if (( $(echo "$FRAG_RATIO < 1.0" | bc -l 2>/dev/null || echo 0) )); then
        echo "  ⚠  WARNING: Fragmentation < 1.0 — Redis may be using SWAP!"
    elif (( $(echo "$FRAG_RATIO > 2.0" | bc -l 2>/dev/null || echo 0) )); then
        echo "  ⚠  WARNING: High fragmentation (>2.0) — consider activedefrag or restart"
    else
        echo "  ✓  Fragmentation ratio is healthy"
    fi
fi

# Memory usage percentage
if [ -n "$MAXMEMORY" ] && [ "$MAXMEMORY" != "0" ]; then
    USED_MEMORY=$(get_info_field memory used_memory)
    if command -v bc &>/dev/null; then
        USAGE_PCT=$(echo "scale=1; $USED_MEMORY * 100 / $MAXMEMORY" | bc 2>/dev/null || echo "N/A")
        printf "  Memory Usage:        %s%%\n" "$USAGE_PCT"
        if (( $(echo "$USAGE_PCT > 90" | bc -l 2>/dev/null || echo 0) )); then
            echo "  ⚠  WARNING: Memory usage above 90%!"
        fi
    fi
fi

# --- Clients ---
divider "CONNECTED CLIENTS"
CONNECTED=$(get_info_field clients connected_clients)
BLOCKED=$(get_info_field clients blocked_clients)
MAXCLIENTS=$(rcli CONFIG GET maxclients 2>/dev/null | tail -1)
REJECTED=$(get_info_field stats rejected_connections)
printf "  Connected:    %s / %s (maxclients)\n" "$CONNECTED" "$MAXCLIENTS"
printf "  Blocked:      %s\n" "$BLOCKED"
printf "  Rejected:     %s (total since start)\n" "$REJECTED"
if [ -n "$CONNECTED" ] && [ -n "$MAXCLIENTS" ] && [ "$MAXCLIENTS" != "0" ]; then
    if command -v bc &>/dev/null; then
        CLIENT_PCT=$(echo "scale=1; $CONNECTED * 100 / $MAXCLIENTS" | bc 2>/dev/null || echo "N/A")
        printf "  Client Usage: %s%%\n" "$CLIENT_PCT"
        if (( $(echo "$CLIENT_PCT > 80" | bc -l 2>/dev/null || echo 0) )); then
            echo "  ⚠  WARNING: Client connections above 80% of maxclients!"
        fi
    fi
fi

# --- Hit Ratio ---
divider "CACHE HIT RATIO"
HITS=$(get_info_field stats keyspace_hits)
MISSES=$(get_info_field stats keyspace_misses)
if [ -n "$HITS" ] && [ -n "$MISSES" ]; then
    TOTAL=$((HITS + MISSES))
    if [ "$TOTAL" -gt 0 ] && command -v bc &>/dev/null; then
        HIT_RATIO=$(echo "scale=2; $HITS * 100 / $TOTAL" | bc 2>/dev/null || echo "N/A")
        printf "  Hits:       %s\n" "$HITS"
        printf "  Misses:     %s\n" "$MISSES"
        printf "  Hit Ratio:  %s%%\n" "$HIT_RATIO"
        if (( $(echo "$HIT_RATIO < 80" | bc -l 2>/dev/null || echo 0) )); then
            echo "  ⚠  WARNING: Hit ratio below 80% — review TTLs and cache strategy"
        else
            echo "  ✓  Hit ratio is healthy"
        fi
    else
        echo "  No keyspace operations recorded yet"
    fi
fi

# --- Throughput ---
divider "THROUGHPUT"
OPS_SEC=$(get_info_field stats instantaneous_ops_per_sec)
INPUT_KBPS=$(get_info_field stats instantaneous_input_kbps)
OUTPUT_KBPS=$(get_info_field stats instantaneous_output_kbps)
TOTAL_CMDS=$(get_info_field stats total_commands_processed)
EVICTED=$(get_info_field stats evicted_keys)
EXPIRED=$(get_info_field stats expired_keys)
printf "  Ops/sec:        %s\n" "$OPS_SEC"
printf "  Input:          %s KB/s\n" "$INPUT_KBPS"
printf "  Output:         %s KB/s\n" "$OUTPUT_KBPS"
printf "  Total Commands: %s\n" "$TOTAL_CMDS"
printf "  Evicted Keys:   %s\n" "$EVICTED"
printf "  Expired Keys:   %s\n" "$EXPIRED"

# --- Replication ---
divider "REPLICATION STATUS"
ROLE=$(get_info_field replication role)
printf "  Role: %s\n" "$ROLE"

if [ "$ROLE" = "master" ]; then
    CONNECTED_SLAVES=$(get_info_field replication connected_slaves)
    REPL_OFFSET=$(get_info_field replication master_repl_offset)
    printf "  Connected Replicas: %s\n" "$CONNECTED_SLAVES"
    printf "  Replication Offset: %s\n" "$REPL_OFFSET"

    if [ -n "$CONNECTED_SLAVES" ] && [ "$CONNECTED_SLAVES" -gt 0 ]; then
        for i in $(seq 0 $((CONNECTED_SLAVES - 1))); do
            SLAVE_INFO=$(get_info_field replication "slave${i}")
            if [ -n "$SLAVE_INFO" ]; then
                SLAVE_STATE=$(echo "$SLAVE_INFO" | tr ',' '\n' | grep "state=" | cut -d= -f2)
                SLAVE_OFFSET=$(echo "$SLAVE_INFO" | tr ',' '\n' | grep "offset=" | cut -d= -f2)
                SLAVE_LAG=$(echo "$SLAVE_INFO" | tr ',' '\n' | grep "lag=" | cut -d= -f2)
                SLAVE_IP=$(echo "$SLAVE_INFO" | tr ',' '\n' | grep "ip=" | cut -d= -f2)
                printf "  Replica %d: %s (state=%s, lag=%ss, offset_diff=%s)\n" \
                    "$i" "$SLAVE_IP" "$SLAVE_STATE" "$SLAVE_LAG" \
                    "$((REPL_OFFSET - SLAVE_OFFSET))"
                if [ -n "$SLAVE_LAG" ] && [ "$SLAVE_LAG" -gt 5 ]; then
                    echo "  ⚠  WARNING: Replica $i has lag > 5 seconds!"
                fi
            fi
        done
    fi
elif [ "$ROLE" = "slave" ]; then
    MASTER_HOST=$(get_info_field replication master_host)
    MASTER_PORT=$(get_info_field replication master_port)
    LINK_STATUS=$(get_info_field replication master_link_status)
    LAST_IO=$(get_info_field replication master_last_io_seconds_ago)
    printf "  Master:            %s:%s\n" "$MASTER_HOST" "$MASTER_PORT"
    printf "  Link Status:       %s\n" "$LINK_STATUS"
    printf "  Last I/O (sec):    %s\n" "$LAST_IO"
    if [ "$LINK_STATUS" != "up" ]; then
        echo "  ⚠  WARNING: Replication link is DOWN!"
    fi
fi

# --- Persistence ---
divider "PERSISTENCE"
RDB_STATUS=$(get_info_field persistence rdb_last_bgsave_status)
RDB_LAST_TIME=$(get_info_field persistence rdb_last_bgsave_time_sec)
AOF_ENABLED=$(get_info_field persistence aof_enabled)
AOF_STATUS=$(get_info_field persistence aof_last_bgrewriteaof_status)
LOADING=$(get_info_field persistence loading)
printf "  RDB last save status:    %s\n" "$RDB_STATUS"
printf "  RDB last save duration:  %s seconds\n" "$RDB_LAST_TIME"
printf "  AOF enabled:             %s\n" "$AOF_ENABLED"
printf "  AOF last rewrite status: %s\n" "$AOF_STATUS"
printf "  Loading data:            %s\n" "${LOADING:-0}"
if [ "$RDB_STATUS" != "ok" ]; then
    echo "  ⚠  WARNING: Last RDB save failed!"
fi
if [ "$AOF_STATUS" != "ok" ] && [ "$AOF_ENABLED" = "1" ]; then
    echo "  ⚠  WARNING: Last AOF rewrite failed!"
fi

# --- Slow Log ---
divider "SLOW LOG (last 10 entries)"
SLOWLOG_LEN=$(rcli SLOWLOG LEN)
printf "  Total slow log entries: %s\n\n" "$SLOWLOG_LEN"
if [ -n "$SLOWLOG_LEN" ] && [ "$SLOWLOG_LEN" -gt 0 ]; then
    rcli SLOWLOG GET 10
fi

# --- Keyspace ---
divider "KEYSPACE OVERVIEW"
rcli INFO keyspace | grep "^db" | while IFS= read -r line; do
    printf "  %s\n" "$line"
done

# --- Big Keys Scan (sampled) ---
divider "BIG KEYS SCAN"
echo "  Running --bigkeys scan (sampled)..."
echo ""
$REDIS_CLI --bigkeys 2>/dev/null | grep -E "(Biggest|summary|found)" | head -20

divider "HEALTH CHECK COMPLETE"
echo ""
