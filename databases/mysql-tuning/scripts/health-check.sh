#!/usr/bin/env bash
#
# health-check.sh — Check key MySQL performance metrics and health indicators
#
# Usage:
#   ./health-check.sh [OPTIONS]
#
# Options:
#   -u, --user USER       MySQL user (default: root)
#   -p, --password PASS   MySQL password (prompted if omitted)
#   -H, --host HOST       MySQL host (default: localhost)
#   -P, --port PORT       MySQL port (default: 3306)
#   -S, --socket PATH     MySQL socket path
#   -w, --warn-only       Only show warnings and critical findings
#   -h, --help            Show this help message
#
# Checks performed:
#   - Buffer pool hit ratio (target: >99%)
#   - Thread usage and cache efficiency
#   - Table cache hit ratio
#   - Temporary tables on disk ratio
#   - Connection utilization
#   - Slow query rate
#   - InnoDB row lock waits
#   - Replication status (if replica)
#   - Key InnoDB metrics
#   - Uptime and version info
#
# Examples:
#   ./health-check.sh -u admin -H db.example.com
#   ./health-check.sh -S /var/run/mysqld/mysqld.sock
#   ./health-check.sh --warn-only
#

set -euo pipefail

# Defaults
MYSQL_USER="root"
MYSQL_PASS=""
MYSQL_HOST="localhost"
MYSQL_PORT="3306"
MYSQL_SOCKET=""
WARN_ONLY=false

usage() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)      MYSQL_USER="$2"; shift 2 ;;
        -p|--password)  MYSQL_PASS="$2"; shift 2 ;;
        -H|--host)      MYSQL_HOST="$2"; shift 2 ;;
        -P|--port)      MYSQL_PORT="$2"; shift 2 ;;
        -S|--socket)    MYSQL_SOCKET="$2"; shift 2 ;;
        -w|--warn-only) WARN_ONLY=true; shift ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

# Build mysql command
MYSQL_CMD="mysql -u${MYSQL_USER} -h${MYSQL_HOST} -P${MYSQL_PORT} --batch --skip-column-names"
[[ -n "$MYSQL_PASS" ]] && MYSQL_CMD="$MYSQL_CMD -p${MYSQL_PASS}"
[[ -n "$MYSQL_SOCKET" ]] && MYSQL_CMD="$MYSQL_CMD -S${MYSQL_SOCKET}"

# Test connection
if ! $MYSQL_CMD -e "SELECT 1" &>/dev/null; then
    echo "ERROR: Cannot connect to MySQL at ${MYSQL_HOST}:${MYSQL_PORT} as ${MYSQL_USER}"
    exit 1
fi

# Helper: execute a query and return the result
mysql_val() {
    $MYSQL_CMD -e "$1" 2>/dev/null | tail -1
}

# Helper: get a global status variable
status_val() {
    mysql_val "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME = '$1'" 2>/dev/null || \
    mysql_val "SHOW GLOBAL STATUS LIKE '$1'" 2>/dev/null | awk '{print $2}'
}

# Helper: get a global variable
var_val() {
    mysql_val "SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME = '$1'" 2>/dev/null || \
    mysql_val "SHOW GLOBAL VARIABLES LIKE '$1'" 2>/dev/null | awk '{print $2}'
}

# Status indicators
OK="[  OK  ]"
WARN="[ WARN ]"
CRIT="[ CRIT ]"
INFO="[ INFO ]"

findings=()
report() {
    local level="$1"
    local message="$2"
    if [[ "$WARN_ONLY" == true && "$level" == "$OK" ]]; then
        return
    fi
    if [[ "$WARN_ONLY" == true && "$level" == "$INFO" ]]; then
        return
    fi
    echo "$level $message"
    if [[ "$level" == "$WARN" || "$level" == "$CRIT" ]]; then
        findings+=("$message")
    fi
}

echo "╔══════════════════════════════════════════════╗"
echo "║       MySQL Health Check Report              ║"
echo "╠══════════════════════════════════════════════╣"
echo "║ Host: $(printf '%-38s' "${MYSQL_HOST}:${MYSQL_PORT}") ║"
echo "║ Date: $(printf '%-38s' "$(date '+%Y-%m-%d %H:%M:%S')") ║"
echo "╚══════════════════════════════════════════════╝"
echo

# --- Server Info ---
echo "=== Server Information ==="
VERSION=$(mysql_val "SELECT VERSION()")
UPTIME=$(status_val "Uptime")
UPTIME_DAYS=$((UPTIME / 86400))
report "$INFO" "Version: $VERSION"
report "$INFO" "Uptime: ${UPTIME_DAYS} days (${UPTIME}s)"
echo

# --- Buffer Pool Hit Ratio ---
echo "=== InnoDB Buffer Pool ==="
BP_READS=$(status_val "Innodb_buffer_pool_reads")
BP_READ_REQUESTS=$(status_val "Innodb_buffer_pool_read_requests")
BP_SIZE=$(var_val "innodb_buffer_pool_size")
BP_SIZE_GB=$(echo "scale=2; $BP_SIZE / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "N/A")
BP_INSTANCES=$(var_val "innodb_buffer_pool_instances")

if [[ "$BP_READ_REQUESTS" -gt 0 ]]; then
    BP_HIT_RATIO=$(echo "scale=4; (1 - ($BP_READS / $BP_READ_REQUESTS)) * 100" | bc 2>/dev/null || echo "0")
    if (( $(echo "$BP_HIT_RATIO >= 99" | bc -l 2>/dev/null || echo 0) )); then
        report "$OK" "Buffer pool hit ratio: ${BP_HIT_RATIO}%"
    elif (( $(echo "$BP_HIT_RATIO >= 95" | bc -l 2>/dev/null || echo 0) )); then
        report "$WARN" "Buffer pool hit ratio: ${BP_HIT_RATIO}% (target: >99%)"
    else
        report "$CRIT" "Buffer pool hit ratio: ${BP_HIT_RATIO}% (target: >99%, consider increasing innodb_buffer_pool_size)"
    fi
else
    report "$INFO" "Buffer pool hit ratio: N/A (no read requests yet)"
fi
report "$INFO" "Buffer pool size: ${BP_SIZE_GB}GB, instances: ${BP_INSTANCES}"

BP_PAGES_DIRTY=$(status_val "Innodb_buffer_pool_pages_dirty")
BP_PAGES_TOTAL=$(status_val "Innodb_buffer_pool_pages_total")
if [[ "$BP_PAGES_TOTAL" -gt 0 ]]; then
    DIRTY_PCT=$(echo "scale=2; $BP_PAGES_DIRTY * 100 / $BP_PAGES_TOTAL" | bc 2>/dev/null || echo "0")
    if (( $(echo "$DIRTY_PCT > 75" | bc -l 2>/dev/null || echo 0) )); then
        report "$WARN" "Buffer pool dirty pages: ${DIRTY_PCT}% (high — check I/O capacity)"
    else
        report "$OK" "Buffer pool dirty pages: ${DIRTY_PCT}%"
    fi
fi
echo

# --- Thread Usage ---
echo "=== Threads & Connections ==="
THREADS_CONNECTED=$(status_val "Threads_connected")
THREADS_RUNNING=$(status_val "Threads_running")
THREADS_CREATED=$(status_val "Threads_created")
MAX_CONNECTIONS=$(var_val "max_connections")
MAX_USED=$(status_val "Max_used_connections")
THREAD_CACHE=$(var_val "thread_cache_size")

CONN_USAGE_PCT=$(echo "scale=1; $MAX_USED * 100 / $MAX_CONNECTIONS" | bc 2>/dev/null || echo "0")
if (( $(echo "$CONN_USAGE_PCT > 85" | bc -l 2>/dev/null || echo 0) )); then
    report "$CRIT" "Peak connection usage: ${CONN_USAGE_PCT}% (${MAX_USED}/${MAX_CONNECTIONS}) — increase max_connections"
elif (( $(echo "$CONN_USAGE_PCT > 70" | bc -l 2>/dev/null || echo 0) )); then
    report "$WARN" "Peak connection usage: ${CONN_USAGE_PCT}% (${MAX_USED}/${MAX_CONNECTIONS})"
else
    report "$OK" "Peak connection usage: ${CONN_USAGE_PCT}% (${MAX_USED}/${MAX_CONNECTIONS})"
fi

report "$INFO" "Currently connected: ${THREADS_CONNECTED}, running: ${THREADS_RUNNING}"

# Thread cache efficiency
if [[ "$UPTIME" -gt 0 ]]; then
    THREAD_CREATE_RATE=$(echo "scale=4; $THREADS_CREATED / $UPTIME" | bc 2>/dev/null || echo "0")
    if (( $(echo "$THREAD_CREATE_RATE > 2" | bc -l 2>/dev/null || echo 0) )); then
        report "$WARN" "Thread creation rate: ${THREAD_CREATE_RATE}/s (increase thread_cache_size from ${THREAD_CACHE})"
    else
        report "$OK" "Thread creation rate: ${THREAD_CREATE_RATE}/s (cache size: ${THREAD_CACHE})"
    fi
fi
echo

# --- Table Cache ---
echo "=== Table Cache ==="
OPEN_TABLES=$(status_val "Open_tables")
OPENED_TABLES=$(status_val "Opened_tables")
TABLE_CACHE=$(var_val "table_open_cache")

if [[ "$UPTIME" -gt 0 ]]; then
    TABLE_OPEN_RATE=$(echo "scale=4; $OPENED_TABLES / $UPTIME" | bc 2>/dev/null || echo "0")
    if (( $(echo "$TABLE_OPEN_RATE > 5" | bc -l 2>/dev/null || echo 0) )); then
        report "$WARN" "Table open rate: ${TABLE_OPEN_RATE}/s (increase table_open_cache from ${TABLE_CACHE})"
    else
        report "$OK" "Table open rate: ${TABLE_OPEN_RATE}/s (open: ${OPEN_TABLES}, cache: ${TABLE_CACHE})"
    fi
fi
echo

# --- Temporary Tables ---
echo "=== Temporary Tables ==="
TMP_TABLES=$(status_val "Created_tmp_tables")
TMP_DISK_TABLES=$(status_val "Created_tmp_disk_tables")

if [[ "$TMP_TABLES" -gt 0 ]]; then
    TMP_DISK_PCT=$(echo "scale=1; $TMP_DISK_TABLES * 100 / $TMP_TABLES" | bc 2>/dev/null || echo "0")
    if (( $(echo "$TMP_DISK_PCT > 25" | bc -l 2>/dev/null || echo 0) )); then
        report "$WARN" "Temp tables on disk: ${TMP_DISK_PCT}% (${TMP_DISK_TABLES}/${TMP_TABLES}) — increase tmp_table_size"
    else
        report "$OK" "Temp tables on disk: ${TMP_DISK_PCT}% (${TMP_DISK_TABLES}/${TMP_TABLES})"
    fi
else
    report "$INFO" "No temporary tables created yet"
fi
echo

# --- Slow Queries ---
echo "=== Slow Queries ==="
SLOW_QUERIES=$(status_val "Slow_queries")
QUESTIONS=$(status_val "Questions")
LONG_QUERY_TIME=$(var_val "long_query_time")
SLOW_LOG_ON=$(var_val "slow_query_log")

if [[ "$QUESTIONS" -gt 0 ]]; then
    SLOW_PCT=$(echo "scale=6; $SLOW_QUERIES * 100 / $QUESTIONS" | bc 2>/dev/null || echo "0")
    if (( $(echo "$SLOW_PCT > 1" | bc -l 2>/dev/null || echo 0) )); then
        report "$WARN" "Slow query ratio: ${SLOW_PCT}% (${SLOW_QUERIES} of ${QUESTIONS}, threshold: ${LONG_QUERY_TIME}s)"
    else
        report "$OK" "Slow query ratio: ${SLOW_PCT}% (${SLOW_QUERIES} of ${QUESTIONS})"
    fi
fi

if [[ "$SLOW_LOG_ON" != "ON" && "$SLOW_LOG_ON" != "1" ]]; then
    report "$WARN" "Slow query log is DISABLED — enable for production monitoring"
fi
echo

# --- InnoDB Row Locks ---
echo "=== InnoDB Lock Metrics ==="
ROW_LOCK_WAITS=$(status_val "Innodb_row_lock_waits")
ROW_LOCK_TIME=$(status_val "Innodb_row_lock_time")
ROW_LOCK_TIME_AVG=$(status_val "Innodb_row_lock_time_avg")

if [[ "$ROW_LOCK_WAITS" -gt 0 ]]; then
    ROW_LOCK_TIME_SEC=$(echo "scale=2; $ROW_LOCK_TIME / 1000" | bc 2>/dev/null || echo "0")
    if (( $(echo "$ROW_LOCK_TIME_AVG > 500" | bc -l 2>/dev/null || echo 0) )); then
        report "$WARN" "Row lock waits: ${ROW_LOCK_WAITS}, total time: ${ROW_LOCK_TIME_SEC}s, avg: ${ROW_LOCK_TIME_AVG}ms"
    else
        report "$OK" "Row lock waits: ${ROW_LOCK_WAITS}, avg wait: ${ROW_LOCK_TIME_AVG}ms"
    fi
else
    report "$OK" "No row lock waits detected"
fi

# Deadlocks
DEADLOCKS=$(mysql_val "SELECT COUNT FROM information_schema.INNODB_METRICS WHERE NAME = 'lock_deadlocks'" 2>/dev/null || echo "0")
if [[ "$DEADLOCKS" -gt 0 ]]; then
    report "$WARN" "Deadlocks since startup: ${DEADLOCKS}"
else
    report "$OK" "No deadlocks detected"
fi
echo

# --- InnoDB I/O ---
echo "=== InnoDB I/O ==="
IO_CAPACITY=$(var_val "innodb_io_capacity")
IO_CAPACITY_MAX=$(var_val "innodb_io_capacity_max")
FLUSH_METHOD=$(var_val "innodb_flush_method")
DATA_READS=$(status_val "Innodb_data_reads")
DATA_WRITES=$(status_val "Innodb_data_writes")
PENDING_READS=$(status_val "Innodb_data_pending_reads")
PENDING_WRITES=$(status_val "Innodb_data_pending_writes")

report "$INFO" "I/O capacity: ${IO_CAPACITY} (max: ${IO_CAPACITY_MAX}), flush method: ${FLUSH_METHOD}"

if [[ "$UPTIME" -gt 0 ]]; then
    READ_IOPS=$(echo "scale=1; $DATA_READS / $UPTIME" | bc 2>/dev/null || echo "0")
    WRITE_IOPS=$(echo "scale=1; $DATA_WRITES / $UPTIME" | bc 2>/dev/null || echo "0")
    report "$INFO" "Avg I/O: ${READ_IOPS} reads/s, ${WRITE_IOPS} writes/s"
fi

if [[ "$PENDING_READS" -gt 0 || "$PENDING_WRITES" -gt 0 ]]; then
    report "$WARN" "Pending I/O: ${PENDING_READS} reads, ${PENDING_WRITES} writes (I/O bottleneck)"
else
    report "$OK" "No pending I/O operations"
fi
echo

# --- Replication ---
echo "=== Replication ==="
REPLICA_STATUS=$($MYSQL_CMD -e "SHOW REPLICA STATUS\G" 2>/dev/null || $MYSQL_CMD -e "SHOW SLAVE STATUS\G" 2>/dev/null || echo "")

if [[ -n "$REPLICA_STATUS" ]]; then
    IO_RUNNING=$(echo "$REPLICA_STATUS" | grep -E "Replica_IO_Running|Slave_IO_Running" | awk '{print $2}')
    SQL_RUNNING=$(echo "$REPLICA_STATUS" | grep -E "Replica_SQL_Running:|Slave_SQL_Running:" | head -1 | awk '{print $2}')
    SECONDS_BEHIND=$(echo "$REPLICA_STATUS" | grep -E "Seconds_Behind_Source|Seconds_Behind_Master" | awk '{print $2}')
    LAST_ERROR=$(echo "$REPLICA_STATUS" | grep -E "Last_Error|Last_SQL_Error" | head -1 | sed 's/^[^:]*: //')

    if [[ "$IO_RUNNING" == "Yes" && "$SQL_RUNNING" == "Yes" ]]; then
        report "$OK" "Replication running (IO: Yes, SQL: Yes)"
    else
        report "$CRIT" "Replication NOT running (IO: ${IO_RUNNING}, SQL: ${SQL_RUNNING})"
    fi

    if [[ "$SECONDS_BEHIND" == "NULL" || -z "$SECONDS_BEHIND" ]]; then
        report "$CRIT" "Replication lag: UNKNOWN (NULL)"
    elif [[ "$SECONDS_BEHIND" -gt 60 ]]; then
        report "$CRIT" "Replication lag: ${SECONDS_BEHIND}s"
    elif [[ "$SECONDS_BEHIND" -gt 5 ]]; then
        report "$WARN" "Replication lag: ${SECONDS_BEHIND}s"
    else
        report "$OK" "Replication lag: ${SECONDS_BEHIND}s"
    fi

    if [[ -n "$LAST_ERROR" && "$LAST_ERROR" != " " ]]; then
        report "$CRIT" "Replication error: $LAST_ERROR"
    fi
else
    report "$INFO" "Not a replica (or replication not configured)"
fi
echo

# --- Summary ---
echo "╔══════════════════════════════════════════════╗"
echo "║                  Summary                     ║"
echo "╠══════════════════════════════════════════════╣"
if [[ ${#findings[@]} -eq 0 ]]; then
    echo "║  All checks passed. Server looks healthy.    ║"
else
    echo "║  ${#findings[@]} issue(s) found:                          ║"
    for finding in "${findings[@]}"; do
        printf "║  • %-42s ║\n" "$(echo "$finding" | cut -c1-42)"
    done
fi
echo "╚══════════════════════════════════════════════╝"
