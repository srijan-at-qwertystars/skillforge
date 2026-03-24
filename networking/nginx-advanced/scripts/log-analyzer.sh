#!/usr/bin/env bash
#
# log-analyzer.sh — Analyze nginx access and error logs
#
# Usage:
#   ./log-analyzer.sh [options] [logfile]
#
# Options:
#   --access <file>    Access log to analyze (default: /var/log/nginx/access.log)
#   --error <file>     Error log to analyze (default: /var/log/nginx/error.log)
#   --top-ips [N]      Show top N client IPs (default: 20)
#   --status           Show status code distribution
#   --slow [seconds]   Show requests slower than N seconds (default: 1.0)
#   --errors           Show error patterns from error log
#   --bandwidth        Show bandwidth usage by IP
#   --urls             Show most requested URLs
#   --bots             Show detected bot user agents
#   --timerange        Show requests per minute/hour
#   --all              Run all analyses
#   --since <time>     Filter logs since time (e.g., "1 hour ago", "2024-01-15")
#   --grep <pattern>   Filter log lines matching pattern before analysis
#
# Examples:
#   ./log-analyzer.sh --all
#   ./log-analyzer.sh --top-ips 50 --access /var/log/nginx/api.log
#   ./log-analyzer.sh --slow 2.0 --since "1 hour ago"
#   ./log-analyzer.sh --errors --error /var/log/nginx/error.log
#   ./log-analyzer.sh --status --grep "POST"
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

section() { echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

ACCESS_LOG="/var/log/nginx/access.log"
ERROR_LOG="/var/log/nginx/error.log"
TOP_N=20
SLOW_THRESHOLD="1.0"
SINCE=""
GREP_PATTERN=""
ACTIONS=()

########################################
# Parse arguments
########################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --access)    ACCESS_LOG="$2"; shift 2 ;;
        --error)     ERROR_LOG="$2"; shift 2 ;;
        --top-ips)
            ACTIONS+=("top_ips")
            if [[ "${2:-}" =~ ^[0-9]+$ ]]; then TOP_N="$2"; shift; fi
            shift ;;
        --status)    ACTIONS+=("status_codes"); shift ;;
        --slow)
            ACTIONS+=("slow_requests")
            if [[ "${2:-}" =~ ^[0-9.]+$ ]]; then SLOW_THRESHOLD="$2"; shift; fi
            shift ;;
        --errors)    ACTIONS+=("error_patterns"); shift ;;
        --bandwidth) ACTIONS+=("bandwidth"); shift ;;
        --urls)      ACTIONS+=("top_urls"); shift ;;
        --bots)      ACTIONS+=("bots"); shift ;;
        --timerange) ACTIONS+=("timerange"); shift ;;
        --all)       ACTIONS=("top_ips" "status_codes" "slow_requests" "top_urls" "bandwidth" "bots" "error_patterns" "timerange"); shift ;;
        --since)     SINCE="$2"; shift 2 ;;
        --grep)      GREP_PATTERN="$2"; shift 2 ;;
        -h|--help)   sed -n '3,/^$/s/^# \?//p' "$0"; exit 0 ;;
        *)
            if [[ -f "$1" ]]; then
                ACCESS_LOG="$1"
            else
                echo "Unknown option: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

# Default to all if no action specified
if [[ ${#ACTIONS[@]} -eq 0 ]]; then
    ACTIONS=("top_ips" "status_codes" "top_urls" "error_patterns")
fi

########################################
# Helpers
########################################
get_access_log() {
    local log_data

    if [[ ! -f "$ACCESS_LOG" ]]; then
        echo "Access log not found: ${ACCESS_LOG}" >&2
        return 1
    fi

    log_data=$(cat "$ACCESS_LOG")

    # Apply since filter
    if [[ -n "$SINCE" ]]; then
        local since_epoch
        since_epoch=$(date -d "$SINCE" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$SINCE" +%s 2>/dev/null || echo 0)
        if [[ "$since_epoch" -gt 0 ]]; then
            local since_date
            since_date=$(date -d "@$since_epoch" "+%d/%b/%Y:%H:%M" 2>/dev/null || date -r "$since_epoch" "+%d/%b/%Y:%H:%M")
            log_data=$(echo "$log_data" | awk -v d="$since_date" '$0 >= d')
        fi
    fi

    # Apply grep filter
    if [[ -n "$GREP_PATTERN" ]]; then
        log_data=$(echo "$log_data" | grep -E "$GREP_PATTERN" || true)
    fi

    echo "$log_data"
}

get_error_log() {
    if [[ ! -f "$ERROR_LOG" ]]; then
        echo "Error log not found: ${ERROR_LOG}" >&2
        return 1
    fi
    cat "$ERROR_LOG"
}

format_bytes() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}")"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}")"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f KB\", $bytes/1024}")"
    else
        echo "${bytes} B"
    fi
}

########################################
# Analysis functions
########################################
analyze_top_ips() {
    section "Top ${TOP_N} Client IPs"
    local data
    data=$(get_access_log) || return

    echo "$data" | awk '{print $1}' | sort | uniq -c | sort -rn | head -"$TOP_N" | \
        awk '{printf "  %8d  %s\n", $1, $2}'

    echo ""
    local total unique
    total=$(echo "$data" | wc -l)
    unique=$(echo "$data" | awk '{print $1}' | sort -u | wc -l)
    echo -e "  ${CYAN}Total requests: ${total} | Unique IPs: ${unique}${NC}"
}

analyze_status_codes() {
    section "Status Code Distribution"
    local data
    data=$(get_access_log) || return

    local total
    total=$(echo "$data" | wc -l)

    echo "$data" | awk '{print $9}' | grep -E '^[0-9]+$' | sort | uniq -c | sort -rn | \
        while read -r count code; do
            local pct
            pct=$(awk "BEGIN {printf \"%.1f\", ($count/$total)*100}")
            local color="$NC"
            case "${code:0:1}" in
                2) color="$GREEN" ;;
                3) color="$CYAN" ;;
                4) color="$YELLOW" ;;
                5) color="$RED" ;;
            esac
            printf "  %s%3s%s  %8d  (%s%%)\n" "$color" "$code" "$NC" "$count" "$pct"
        done

    echo ""

    # 5xx breakdown
    local fivexx
    fivexx=$(echo "$data" | awk '$9 ~ /^5/' | wc -l)
    if [[ $fivexx -gt 0 ]]; then
        echo -e "  ${RED}5xx errors: ${fivexx} ($(awk "BEGIN {printf \"%.2f\", ($fivexx/$total)*100}")%)${NC}"
        echo "  Top 5xx URLs:"
        echo "$data" | awk '$9 ~ /^5/ {print $9, $7}' | sort | uniq -c | sort -rn | head -5 | \
            awk '{printf "    %6d  %s %s\n", $1, $2, $3}'
    fi
}

analyze_slow_requests() {
    section "Slow Requests (> ${SLOW_THRESHOLD}s)"
    local data
    data=$(get_access_log) || return

    # Try to extract request_time from custom log format (rt=N.NNN)
    local slow
    slow=$(echo "$data" | grep -oP 'rt=\K[0-9.]+' | awk -v t="$SLOW_THRESHOLD" '$1 > t' | wc -l)

    if [[ $slow -gt 0 ]]; then
        echo -e "  ${YELLOW}Found ${slow} slow requests${NC}"
        echo ""
        echo "  Slowest requests:"
        echo "$data" | awk -F'rt=' '{if(NF>1){split($2,a," "); if(a[1]+0 > '"$SLOW_THRESHOLD"') print a[1], $0}}' | \
            sort -rn | head -"$TOP_N" | \
            awk '{printf "  %8ss  %s %s\n", $1, $5, $7}' 2>/dev/null || \
            echo "  (Could not parse request_time — ensure log format includes rt=\$request_time)"
    else
        # Try alternative: look for $request_time as a field
        echo -e "  ${GREEN}No slow requests found (or request_time not in log format)${NC}"
        echo "  Tip: Add 'rt=\$request_time' to your log_format for request timing"
    fi
}

analyze_top_urls() {
    section "Top ${TOP_N} Requested URLs"
    local data
    data=$(get_access_log) || return

    echo "$data" | awk '{print $7}' | sort | uniq -c | sort -rn | head -"$TOP_N" | \
        awk '{printf "  %8d  %s\n", $1, $2}'
}

analyze_bandwidth() {
    section "Bandwidth by IP (Top ${TOP_N})"
    local data
    data=$(get_access_log) || return

    echo "$data" | awk '{ip[$1]+=$10} END {for(i in ip) print ip[i], i}' | sort -rn | head -"$TOP_N" | \
        while read -r bytes ip; do
            printf "  %12s  %s\n" "$(format_bytes "$bytes")" "$ip"
        done

    echo ""
    local total_bytes
    total_bytes=$(echo "$data" | awk '{sum+=$10} END {print sum+0}')
    echo -e "  ${CYAN}Total bandwidth: $(format_bytes "$total_bytes")${NC}"
}

analyze_bots() {
    section "Bot / Crawler Detection"
    local data
    data=$(get_access_log) || return

    echo -e "  ${CYAN}Known bots:${NC}"
    echo "$data" | awk -F'"' '{print $6}' | grep -iE 'bot|crawl|spider|slurp|facebookexternalhit|semrush|ahref|mj12|yandex|baidu|bingbot|googlebot' | \
        sort | uniq -c | sort -rn | head -"$TOP_N" | \
        awk '{printf "  %8d  %s\n", $1, substr($0, index($0,$2))}'

    echo ""
    echo -e "  ${CYAN}Suspicious agents (empty or tool-based):${NC}"
    echo "$data" | awk -F'"' '{print $6}' | grep -iE '^$|^-$|python-requests|wget|curl|scanner|sqlmap|nikto|nmap' | \
        sort | uniq -c | sort -rn | head -10 | \
        awk '{ua=$0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", ua); if(ua == "" || ua == "-") ua="(empty)"; printf "  %8d  %s\n", $1, ua}'
}

analyze_error_patterns() {
    section "Error Log Analysis"
    local data
    data=$(get_error_log 2>/dev/null) || { echo "  Error log not available"; return; }

    if [[ -z "$data" ]]; then
        echo -e "  ${GREEN}Error log is empty${NC}"
        return
    fi

    local total
    total=$(echo "$data" | wc -l)
    echo -e "  Total error lines: ${total}"
    echo ""

    # Error level distribution
    echo -e "  ${CYAN}By severity:${NC}"
    echo "$data" | grep -oP '\[\K(emerg|alert|crit|error|warn|notice|info|debug)' | \
        sort | uniq -c | sort -rn | \
        while read -r count level; do
            local color="$NC"
            case "$level" in
                emerg|alert|crit) color="$RED" ;;
                error)            color="$RED" ;;
                warn)             color="$YELLOW" ;;
                *)                color="$GREEN" ;;
            esac
            printf "  %s%8d  [%s]%s\n" "$color" "$count" "$level" "$NC"
        done

    echo ""

    # Common error patterns
    echo -e "  ${CYAN}Common error patterns:${NC}"
    echo "$data" | grep -oP '\[error\].*?:\s*\K.*' | \
        sed 's/client: [0-9.]*//g; s/server: [a-zA-Z0-9._-]*//g; s/request: "[^"]*"//g' | \
        sort | uniq -c | sort -rn | head -10 | \
        awk '{printf "  %8d  %s\n", $1, substr($0, index($0,$2))}'

    echo ""

    # Upstream errors
    local upstream_errors
    upstream_errors=$(echo "$data" | grep -c "upstream" || true)
    if [[ $upstream_errors -gt 0 ]]; then
        echo -e "  ${YELLOW}Upstream errors: ${upstream_errors}${NC}"
        echo "$data" | grep "upstream" | grep -oP 'upstream "[^"]*"' | \
            sort | uniq -c | sort -rn | head -5 | \
            awk '{printf "    %6d  %s\n", $1, substr($0, index($0,$2))}'
    fi

    echo ""

    # Recent errors
    echo -e "  ${CYAN}Last 5 errors:${NC}"
    echo "$data" | grep "\[error\]" | tail -5 | sed 's/^/    /'
}

analyze_timerange() {
    section "Request Rate Over Time"
    local data
    data=$(get_access_log) || return

    echo -e "  ${CYAN}Requests per hour (last 24h):${NC}"
    echo "$data" | awk '{
        match($4, /\[([0-9]+\/[A-Za-z]+\/[0-9]+):([0-9]+)/, arr)
        if (arr[1] != "") print arr[1] ":" arr[2] ":00"
    }' | sort | uniq -c | tail -24 | \
        while read -r count hour; do
            local bar=""
            local bar_len=$(( count / 100 ))
            [[ $bar_len -gt 60 ]] && bar_len=60
            for ((i=0; i<bar_len; i++)); do bar+="▇"; done
            printf "  %s  %6d  %s\n" "$hour" "$count" "$bar"
        done

    echo ""

    # Peak detection
    local peak
    peak=$(echo "$data" | awk '{
        match($4, /\[([0-9]+\/[A-Za-z]+\/[0-9]+:[0-9]+:[0-9]+)/, arr)
        if (arr[1] != "") print arr[1]
    }' | sort | uniq -c | sort -rn | head -1)

    if [[ -n "$peak" ]]; then
        echo -e "  ${CYAN}Peak minute: ${peak}${NC}"
    fi
}

########################################
# Main
########################################
echo -e "${BLUE}Nginx Log Analyzer${NC}"
echo "  Access log: ${ACCESS_LOG}"
echo "  Error log:  ${ERROR_LOG}"
[[ -n "$SINCE" ]] && echo "  Since:      ${SINCE}"
[[ -n "$GREP_PATTERN" ]] && echo "  Filter:     ${GREP_PATTERN}"

for action in "${ACTIONS[@]}"; do
    case "$action" in
        top_ips)        analyze_top_ips ;;
        status_codes)   analyze_status_codes ;;
        slow_requests)  analyze_slow_requests ;;
        top_urls)       analyze_top_urls ;;
        bandwidth)      analyze_bandwidth ;;
        bots)           analyze_bots ;;
        error_patterns) analyze_error_patterns ;;
        timerange)      analyze_timerange ;;
    esac
done

echo ""
