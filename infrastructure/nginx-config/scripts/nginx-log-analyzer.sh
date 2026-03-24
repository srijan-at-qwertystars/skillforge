#!/usr/bin/env bash
# nginx-log-analyzer.sh — Analyze nginx access and error logs
#
# Usage:
#   ./nginx-log-analyzer.sh                                      # Analyze default logs
#   ./nginx-log-analyzer.sh --access /var/log/nginx/access.log   # Custom access log
#   ./nginx-log-analyzer.sh --error /var/log/nginx/error.log     # Custom error log
#   ./nginx-log-analyzer.sh --top 30                             # Show top 30 results
#   ./nginx-log-analyzer.sh --since "1 hour ago"                 # Filter by time
#   ./nginx-log-analyzer.sh --json                               # JSON log format
#
# Analyzes:
#   - Top requesting IPs
#   - Status code distribution
#   - Slowest requests
#   - Error patterns
#   - Request rate over time
#   - Top URIs and user agents
#   - Bandwidth usage

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

header() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# --- Defaults ---
ACCESS_LOG="/var/log/nginx/access.log"
ERROR_LOG="/var/log/nginx/error.log"
TOP_N=20
SINCE=""
JSON_FORMAT=false
SECTIONS="all"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --access)   ACCESS_LOG="$2"; shift 2 ;;
        --error)    ERROR_LOG="$2"; shift 2 ;;
        --top)      TOP_N="$2"; shift 2 ;;
        --since)    SINCE="$2"; shift 2 ;;
        --json)     JSON_FORMAT=true; shift ;;
        --section)  SECTIONS="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "  --access PATH    Access log path (default: /var/log/nginx/access.log)"
            echo "  --error PATH     Error log path (default: /var/log/nginx/error.log)"
            echo "  --top N          Show top N results (default: 20)"
            echo "  --since TIME     Filter by time (e.g., '1 hour ago', '2024-01-01')"
            echo "  --json           Parse JSON-formatted logs"
            echo "  --section NAME   Run specific section (ips|status|slow|errors|rate|uris|bandwidth|agents)"
            exit 0
            ;;
        *)  echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo -e "${BLUE}Nginx Log Analyzer${NC}"
echo "Access log: ${ACCESS_LOG}"
echo "Error log:  ${ERROR_LOG}"

# --- Helper: filter by time if --since provided ---
filter_by_time() {
    if [[ -n "$SINCE" ]]; then
        local since_epoch
        since_epoch=$(date -d "$SINCE" +%s 2>/dev/null || echo 0)
        if [[ "$since_epoch" -gt 0 ]]; then
            awk -v since="$since_epoch" '{
                # Extract timestamp from combined log format [DD/Mon/YYYY:HH:MM:SS +ZONE]
                match($0, /\[([^\]]+)\]/, ts)
                if (ts[1] != "") {
                    gsub(/\//, " ", ts[1]); gsub(/:/, " ", ts[1])
                    cmd = "date -d \"" ts[1] "\" +%s 2>/dev/null"
                    cmd | getline log_epoch
                    close(cmd)
                    if (log_epoch >= since) print
                }
            }'
        else
            cat
        fi
    else
        cat
    fi
}

should_run() {
    [[ "$SECTIONS" == "all" ]] || [[ "$SECTIONS" == *"$1"* ]]
}

# ================================================================
# ACCESS LOG ANALYSIS
# ================================================================

if [[ -f "$ACCESS_LOG" ]]; then
    TOTAL_LINES=$(wc -l < "$ACCESS_LOG")
    echo -e "Total access log lines: ${GREEN}${TOTAL_LINES}${NC}"

    # --- Top IPs ---
    if should_run "ips"; then
        header "Top $TOP_N Requesting IPs"

        if $JSON_FORMAT; then
            if command -v jq &>/dev/null; then
                cat "$ACCESS_LOG" | jq -r '.remote_addr' 2>/dev/null | \
                    sort | uniq -c | sort -rn | head -"$TOP_N" | \
                    awk '{printf "  %8d  %s\n", $1, $2}'
            else
                echo "  jq required for JSON log parsing"
            fi
        else
            awk '{print $1}' "$ACCESS_LOG" | \
                sort | uniq -c | sort -rn | head -"$TOP_N" | \
                awk '{printf "  %8d  %s\n", $1, $2}'
        fi
    fi

    # --- Status Code Distribution ---
    if should_run "status"; then
        header "Status Code Distribution"

        if $JSON_FORMAT; then
            if command -v jq &>/dev/null; then
                cat "$ACCESS_LOG" | jq -r '.status' 2>/dev/null | \
                    sort | uniq -c | sort -rn | \
                    awk '{
                        code=$2; count=$1;
                        if (code >= 500) color="\033[0;31m";
                        else if (code >= 400) color="\033[1;33m";
                        else if (code >= 300) color="\033[0;36m";
                        else color="\033[0;32m";
                        printf "  %s%8d  %s\033[0m\n", color, count, code
                    }'
            fi
        else
            awk '{print $9}' "$ACCESS_LOG" | grep -E '^[0-9]{3}$' | \
                sort | uniq -c | sort -rn | \
                awk '{
                    code=$2; count=$1;
                    if (code >= 500) color="\033[0;31m";
                    else if (code >= 400) color="\033[1;33m";
                    else if (code >= 300) color="\033[0;36m";
                    else color="\033[0;32m";
                    printf "  %s%8d  %s\033[0m\n", color, count, code
                }'
        fi

        # Calculate error rates
        if ! $JSON_FORMAT; then
            TOTAL=$(awk '{print $9}' "$ACCESS_LOG" | grep -cE '^[0-9]{3}$' || echo 0)
            ERR_4XX=$(awk '{print $9}' "$ACCESS_LOG" | grep -cE '^4[0-9]{2}$' || echo 0)
            ERR_5XX=$(awk '{print $9}' "$ACCESS_LOG" | grep -cE '^5[0-9]{2}$' || echo 0)
            if [[ "$TOTAL" -gt 0 ]]; then
                echo ""
                printf "  4xx rate: ${YELLOW}%.2f%%${NC}\n" "$(echo "scale=4; $ERR_4XX * 100 / $TOTAL" | bc)"
                printf "  5xx rate: ${RED}%.2f%%${NC}\n" "$(echo "scale=4; $ERR_5XX * 100 / $TOTAL" | bc)"
            fi
        fi
    fi

    # --- Slowest Requests ---
    if should_run "slow"; then
        header "Top $TOP_N Slowest Requests"

        if $JSON_FORMAT; then
            if command -v jq &>/dev/null; then
                cat "$ACCESS_LOG" | jq -r 'select(.request_time != null) | "\(.request_time)s \(.request_method) \(.request_uri) [\(.status)]"' 2>/dev/null | \
                    sort -rn | head -"$TOP_N" | \
                    awk '{printf "  %s\n", $0}'
            fi
        else
            # Assumes request_time is the last field (common in custom log formats)
            awk '{
                time=$NF;
                method=$6; gsub(/"/, "", method);
                uri=$7;
                status=$9;
                if (time+0 > 0) printf "%8.3fs  %s %s [%s]\n", time, method, uri, status
            }' "$ACCESS_LOG" | sort -rn | head -"$TOP_N" | sed 's/^/  /'
        fi
    fi

    # --- Top URIs ---
    if should_run "uris"; then
        header "Top $TOP_N Requested URIs"

        if $JSON_FORMAT; then
            if command -v jq &>/dev/null; then
                cat "$ACCESS_LOG" | jq -r '.request_uri' 2>/dev/null | \
                    sort | uniq -c | sort -rn | head -"$TOP_N" | \
                    awk '{printf "  %8d  %s\n", $1, $2}'
            fi
        else
            awk '{print $7}' "$ACCESS_LOG" | \
                sort | uniq -c | sort -rn | head -"$TOP_N" | \
                awk '{printf "  %8d  %s\n", $1, $2}'
        fi
    fi

    # --- Top URIs returning errors ---
    if should_run "errors"; then
        header "Top $TOP_N URIs with 5xx Errors"

        if $JSON_FORMAT; then
            if command -v jq &>/dev/null; then
                cat "$ACCESS_LOG" | jq -r 'select(.status >= 500) | "\(.status) \(.request_method) \(.request_uri)"' 2>/dev/null | \
                    sort | uniq -c | sort -rn | head -"$TOP_N" | \
                    awk '{printf "  %8d  %s\n", $1, substr($0, index($0,$2))}'
            fi
        else
            awk '$9 >= 500 {printf "%s %s %s\n", $9, $6, $7}' "$ACCESS_LOG" | \
                sed 's/"//g' | sort | uniq -c | sort -rn | head -"$TOP_N" | \
                awk '{printf "  %8d  %s\n", $1, substr($0, index($0,$2))}'
        fi
    fi

    # --- Request Rate ---
    if should_run "rate"; then
        header "Request Rate (per minute, last 30 minutes)"

        if $JSON_FORMAT; then
            if command -v jq &>/dev/null; then
                cat "$ACCESS_LOG" | jq -r '.time' 2>/dev/null | \
                    cut -c1-16 | sort | uniq -c | tail -30 | \
                    awk '{printf "  %8d req/min  %s\n", $1, $2}'
            fi
        else
            awk '{
                match($4, /\[(.+):(.+):(.+):/, arr)
                if (arr[0] != "") {
                    minute = substr($4, 2, 17)
                    print minute
                }
            }' "$ACCESS_LOG" | sort | uniq -c | tail -30 | \
                awk '{
                    rate=$1;
                    if (rate > 1000) color="\033[0;31m";
                    else if (rate > 500) color="\033[1;33m";
                    else color="\033[0;32m";
                    printf "  %s%8d req/min  %s\033[0m\n", color, rate, $2
                }'
        fi
    fi

    # --- Bandwidth ---
    if should_run "bandwidth"; then
        header "Bandwidth Usage"

        if $JSON_FORMAT; then
            if command -v jq &>/dev/null; then
                TOTAL_BYTES=$(cat "$ACCESS_LOG" | jq -r '.body_bytes_sent // 0' 2>/dev/null | awk '{sum+=$1} END {print sum}')
            else
                TOTAL_BYTES=0
            fi
        else
            TOTAL_BYTES=$(awk '{sum+=$10} END {print sum+0}' "$ACCESS_LOG")
        fi

        if [[ "$TOTAL_BYTES" -gt 0 ]]; then
            if [[ "$TOTAL_BYTES" -gt 1073741824 ]]; then
                printf "  Total transferred: ${GREEN}%.2f GB${NC}\n" "$(echo "scale=2; $TOTAL_BYTES / 1073741824" | bc)"
            elif [[ "$TOTAL_BYTES" -gt 1048576 ]]; then
                printf "  Total transferred: ${GREEN}%.2f MB${NC}\n" "$(echo "scale=2; $TOTAL_BYTES / 1048576" | bc)"
            else
                printf "  Total transferred: ${GREEN}%.2f KB${NC}\n" "$(echo "scale=2; $TOTAL_BYTES / 1024" | bc)"
            fi

            # Top bandwidth consumers
            echo ""
            echo "  Top $TOP_N bandwidth-consuming URIs:"
            if $JSON_FORMAT; then
                if command -v jq &>/dev/null; then
                    cat "$ACCESS_LOG" | jq -r '"\(.body_bytes_sent // 0) \(.request_uri)"' 2>/dev/null | \
                        awk '{bytes[$2]+=$1} END {for(u in bytes) printf "%d %s\n", bytes[u], u}' | \
                        sort -rn | head -"$TOP_N" | \
                        awk '{
                            if ($1 > 1073741824) printf "  %8.1f GB  %s\n", $1/1073741824, $2;
                            else if ($1 > 1048576) printf "  %8.1f MB  %s\n", $1/1048576, $2;
                            else printf "  %8.1f KB  %s\n", $1/1024, $2
                        }'
                fi
            else
                awk '{bytes[$7]+=$10} END {for(u in bytes) printf "%d %s\n", bytes[u], u}' "$ACCESS_LOG" | \
                    sort -rn | head -"$TOP_N" | \
                    awk '{
                        if ($1 > 1073741824) printf "  %8.1f GB  %s\n", $1/1073741824, $2;
                        else if ($1 > 1048576) printf "  %8.1f MB  %s\n", $1/1048576, $2;
                        else printf "  %8.1f KB  %s\n", $1/1024, $2
                    }'
            fi
        fi
    fi

    # --- Top User Agents ---
    if should_run "agents"; then
        header "Top $TOP_N User Agents"

        if $JSON_FORMAT; then
            if command -v jq &>/dev/null; then
                cat "$ACCESS_LOG" | jq -r '.http_user_agent' 2>/dev/null | \
                    sort | uniq -c | sort -rn | head -"$TOP_N" | \
                    awk '{printf "  %8d  %s\n", $1, substr($0, index($0,$2))}'
            fi
        else
            awk -F'"' '{print $6}' "$ACCESS_LOG" | \
                sort | uniq -c | sort -rn | head -"$TOP_N" | \
                awk '{printf "  %8d  %s\n", $1, substr($0, index($0,$2))}'
        fi
    fi

else
    echo -e "${YELLOW}Access log not found: ${ACCESS_LOG}${NC}"
fi

# ================================================================
# ERROR LOG ANALYSIS
# ================================================================

if [[ -f "$ERROR_LOG" ]] && should_run "errors"; then
    ERROR_LINES=$(wc -l < "$ERROR_LOG")
    header "Error Log Analysis ($ERROR_LINES lines)"

    # Error level distribution
    echo -e "  ${CYAN}Error levels:${NC}"
    grep -oP '\[\w+\]' "$ERROR_LOG" | sort | uniq -c | sort -rn | \
        awk '{
            level=$2;
            if (level ~ /emerg|alert|crit/) color="\033[0;31m";
            else if (level ~ /error/) color="\033[1;33m";
            else color="\033[0;32m";
            printf "    %s%8d  %s\033[0m\n", color, $1, level
        }'

    # Top error patterns
    echo ""
    echo -e "  ${CYAN}Top error patterns:${NC}"
    grep -oP '(?<=\] ).+?(?=,)' "$ERROR_LOG" 2>/dev/null | \
        sort | uniq -c | sort -rn | head -"$TOP_N" | \
        awk '{printf "    %8d  %s\n", $1, substr($0, index($0,$2))}'

    # Upstream errors
    UPSTREAM_ERRORS=$(grep -c "upstream" "$ERROR_LOG" 2>/dev/null || echo 0)
    if [[ "$UPSTREAM_ERRORS" -gt 0 ]]; then
        echo ""
        echo -e "  ${CYAN}Upstream errors (${UPSTREAM_ERRORS} total):${NC}"
        grep "upstream" "$ERROR_LOG" | grep -oP '(upstream timed out|upstream prematurely closed|connect\(\) failed|no live upstreams)' 2>/dev/null | \
            sort | uniq -c | sort -rn | \
            awk '{printf "    %8d  %s\n", $1, substr($0, index($0,$2))}'
    fi

    # SSL errors
    SSL_ERRORS=$(grep -ciE "ssl|certificate|handshake" "$ERROR_LOG" 2>/dev/null || echo 0)
    if [[ "$SSL_ERRORS" -gt 0 ]]; then
        echo ""
        echo -e "  ${CYAN}SSL/TLS errors (${SSL_ERRORS} total):${NC}"
        grep -iE "ssl|certificate|handshake" "$ERROR_LOG" | tail -5 | sed 's/^/    /'
    fi

    # Rate limiting events
    RATE_LIMIT=$(grep -c "limiting" "$ERROR_LOG" 2>/dev/null || echo 0)
    if [[ "$RATE_LIMIT" -gt 0 ]]; then
        echo ""
        echo -e "  ${CYAN}Rate limiting events: ${YELLOW}${RATE_LIMIT}${NC}"
        grep "limiting" "$ERROR_LOG" | grep -oP 'client: [0-9.]+' | \
            sort | uniq -c | sort -rn | head -10 | \
            awk '{printf "    %8d  %s\n", $1, $2}'
    fi

else
    [[ ! -f "$ERROR_LOG" ]] && echo -e "\n${YELLOW}Error log not found: ${ERROR_LOG}${NC}"
fi

echo ""
echo -e "${GREEN}Analysis complete.${NC}"
