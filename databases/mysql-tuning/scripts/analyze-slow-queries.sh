#!/usr/bin/env bash
#
# analyze-slow-queries.sh — Parse MySQL slow query log and extract top queries
#
# Usage:
#   ./analyze-slow-queries.sh [OPTIONS]
#
# Options:
#   -f, --file PATH       Path to slow query log (default: /var/log/mysql/slow.log)
#   -n, --top N           Show top N queries (default: 10)
#   -t, --threshold SECS  Only show queries slower than SECS seconds (default: 1)
#   -e, --explain         Run EXPLAIN on extracted queries (requires mysql client)
#   -u, --user USER       MySQL user for EXPLAIN (default: root)
#   -p, --password PASS   MySQL password for EXPLAIN
#   -H, --host HOST       MySQL host for EXPLAIN (default: localhost)
#   -d, --database DB     Default database for EXPLAIN
#   -h, --help            Show this help message
#
# Examples:
#   ./analyze-slow-queries.sh -f /var/log/mysql/slow.log -n 20
#   ./analyze-slow-queries.sh -f slow.log -n 5 -e -u root -d myapp
#   ./analyze-slow-queries.sh --threshold 5 --top 3
#
# Dependencies:
#   - awk, sort, head (standard Unix tools)
#   - mysql client (only if --explain is used)
#   - pt-query-digest (optional, used if available for richer output)
#

set -euo pipefail

# Defaults
SLOW_LOG="/var/log/mysql/slow.log"
TOP_N=10
THRESHOLD=1
RUN_EXPLAIN=false
MYSQL_USER="root"
MYSQL_PASS=""
MYSQL_HOST="localhost"
MYSQL_DB=""

usage() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)      SLOW_LOG="$2"; shift 2 ;;
        -n|--top)       TOP_N="$2"; shift 2 ;;
        -t|--threshold) THRESHOLD="$2"; shift 2 ;;
        -e|--explain)   RUN_EXPLAIN=true; shift ;;
        -u|--user)      MYSQL_USER="$2"; shift 2 ;;
        -p|--password)  MYSQL_PASS="$2"; shift 2 ;;
        -H|--host)      MYSQL_HOST="$2"; shift 2 ;;
        -d|--database)  MYSQL_DB="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

# Validate slow log exists
if [[ ! -f "$SLOW_LOG" ]]; then
    echo "ERROR: Slow query log not found: $SLOW_LOG"
    echo "Specify the path with -f /path/to/slow.log"
    exit 1
fi

echo "============================================"
echo "  MySQL Slow Query Log Analysis"
echo "============================================"
echo "Log file:  $SLOW_LOG"
echo "File size: $(du -h "$SLOW_LOG" | cut -f1)"
echo "Top N:     $TOP_N"
echo "Threshold: ${THRESHOLD}s"
echo "Date:      $(date)"
echo "============================================"
echo

# Check if pt-query-digest is available
if command -v pt-query-digest &>/dev/null; then
    echo ">>> Using pt-query-digest (Percona Toolkit) for analysis"
    echo
    pt-query-digest \
        --limit="${TOP_N}" \
        --filter "\$event->{Query_time} >= ${THRESHOLD}" \
        "$SLOW_LOG"
    echo
else
    echo ">>> pt-query-digest not found, using built-in analysis"
    echo "    (Install Percona Toolkit for richer output)"
    echo

    # Parse slow query log with awk
    # Extract: query time, lock time, rows examined, rows sent, and the SQL
    awk -v threshold="$THRESHOLD" '
    /^# Query_time:/ {
        query_time = $3
        lock_time = $5
        rows_sent = $7
        rows_examined = $9
        next
    }
    /^# User@Host:/ {
        user_host = $0
        next
    }
    /^SET timestamp=/ {
        next
    }
    /^# Time:/ {
        next
    }
    /^use / {
        db = $2
        gsub(/;/, "", db)
        next
    }
    # Skip comment lines and empty lines
    /^#/ || /^$/ || /^\/\*/ {
        next
    }
    # Collect the query (may be multi-line, ends with ;)
    {
        if (query_time + 0 >= threshold + 0) {
            # Normalize the query: collapse whitespace, remove specific values
            query = $0
            gsub(/\n/, " ", query)
            gsub(/[[:space:]]+/, " ", query)
            # Remove trailing semicolon for grouping
            gsub(/;[[:space:]]*$/, "", query)

            # Normalize: replace numbers with N, strings with S
            normalized = query
            gsub(/'[^']*'/, "'S'", normalized)
            gsub(/"[^"]*"/, "\"S\"", normalized)
            gsub(/[0-9]+/, "N", normalized)

            count[normalized]++
            total_time[normalized] += query_time
            max_time[normalized] = (max_time[normalized] > query_time) ? max_time[normalized] : query_time
            total_rows[normalized] += rows_examined
            if (!(normalized in example)) {
                example[normalized] = query
            }
        }
        query_time = 0
    }
    END {
        for (q in count) {
            avg = total_time[q] / count[q]
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", total_time[q], count[q], avg, max_time[q], total_rows[q], example[q]
        }
    }
    ' "$SLOW_LOG" | sort -t$'\t' -k1 -rn | head -n "$TOP_N" | \
    awk -F'\t' '
    BEGIN {
        rank = 0
    }
    {
        rank++
        printf "--- Rank %d ---\n", rank
        printf "  Total time:     %.3fs\n", $1
        printf "  Exec count:     %d\n", $2
        printf "  Avg time:       %.3fs\n", $3
        printf "  Max time:       %.3fs\n", $4
        printf "  Total rows:     %d\n", $5
        printf "  Example query:  %s\n", $6
        printf "\n"
    }'
fi

# Run EXPLAIN on top queries if requested
if [[ "$RUN_EXPLAIN" == true ]]; then
    echo
    echo "============================================"
    echo "  EXPLAIN Plans for Top Queries"
    echo "============================================"
    echo

    MYSQL_CMD="mysql -u${MYSQL_USER} -h${MYSQL_HOST}"
    [[ -n "$MYSQL_PASS" ]] && MYSQL_CMD="$MYSQL_CMD -p${MYSQL_PASS}"
    [[ -n "$MYSQL_DB" ]] && MYSQL_CMD="$MYSQL_CMD ${MYSQL_DB}"

    # Test connection
    if ! $MYSQL_CMD -e "SELECT 1" &>/dev/null; then
        echo "ERROR: Cannot connect to MySQL. Check credentials."
        echo "Connection: $MYSQL_CMD"
        exit 1
    fi

    # Extract unique SELECT queries and run EXPLAIN
    query_count=0
    awk '/^# Query_time:/ { qt=$3 } /^SELECT|^select/ && qt+0 >= '"$THRESHOLD"' { print; qt=0 }' "$SLOW_LOG" | \
    sort -u | head -n "$TOP_N" | while IFS= read -r query; do
        query_count=$((query_count + 1))
        echo "--- Query $query_count ---"
        echo "$query"
        echo
        # Only EXPLAIN SELECT queries
        if echo "$query" | grep -qi "^SELECT"; then
            echo "EXPLAIN output:"
            $MYSQL_CMD -e "EXPLAIN $query" 2>/dev/null || echo "  (EXPLAIN failed — query may reference missing table/db)"
        else
            echo "  (Skipping EXPLAIN — not a SELECT query)"
        fi
        echo
    done
fi

echo "============================================"
echo "  Analysis complete"
echo "============================================"
