#!/usr/bin/env bash
# log-analyzer.sh — Parse nginx access logs for top IPs, status codes, and slow requests
#
# Usage:
#   ./log-analyzer.sh [OPTIONS] [LOG_FILE]
#
# Options:
#   --top N          Number of top results to show (default: 20)
#   --since TIME     Only analyze entries after TIME (format: "2024-01-15" or "15/Jan/2024:10:00")
#   --until TIME     Only analyze entries before TIME
#   --slow SECONDS   Threshold for slow requests (default: 2.0)
#   --status CODE    Filter by specific status code (e.g., 500)
#   --ip IP          Filter by specific IP address
#   --uri PATTERN    Filter by URI pattern (grep regex)
#   --format FORMAT  Log format: 'combined' (default), 'json', 'custom'
#   --section SECT   Show only specific section: ips, status, slow, uris, agents, errors, bandwidth
#   --all            Show all sections (default)
#
# Examples:
#   ./log-analyzer.sh /var/log/nginx/access.log
#   ./log-analyzer.sh --top 10 --slow 5 /var/log/nginx/access.log
#   ./log-analyzer.sh --since "2024-01-15" --status 500 /var/log/nginx/access.log
#   ./log-analyzer.sh --section slow --slow 1.0 /var/log/nginx/access.log
#   cat /var/log/nginx/access.log | ./log-analyzer.sh

set -euo pipefail

TOP=20
SLOW_THRESHOLD=2.0
STATUS_FILTER=""
IP_FILTER=""
URI_FILTER=""
SINCE=""
UNTIL=""
FORMAT="combined"
SECTION="all"
LOG_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --top)       TOP="$2";            shift 2 ;;
        --slow)      SLOW_THRESHOLD="$2"; shift 2 ;;
        --status)    STATUS_FILTER="$2";  shift 2 ;;
        --ip)        IP_FILTER="$2";      shift 2 ;;
        --uri)       URI_FILTER="$2";     shift 2 ;;
        --since)     SINCE="$2";          shift 2 ;;
        --until)     UNTIL="$2";          shift 2 ;;
        --format)    FORMAT="$2";         shift 2 ;;
        --section)   SECTION="$2";        shift 2 ;;
        --all)       SECTION="all";       shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            LOG_FILE="$1"
            shift
            ;;
    esac
done

# Read from file or stdin
if [[ -n "$LOG_FILE" ]]; then
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "Error: Log file not found: $LOG_FILE" >&2
        exit 1
    fi
    INPUT="cat $LOG_FILE"
    # Support gzipped logs
    if [[ "$LOG_FILE" == *.gz ]]; then
        INPUT="zcat $LOG_FILE"
    fi
else
    if [[ -t 0 ]]; then
        # Try default locations
        for f in /var/log/nginx/access.log /usr/local/nginx/logs/access.log; do
            if [[ -f "$f" ]]; then
                LOG_FILE="$f"
                INPUT="cat $LOG_FILE"
                break
            fi
        done
        if [[ -z "$LOG_FILE" ]]; then
            echo "Error: No log file specified and no default log found." >&2
            echo "Usage: $0 [OPTIONS] LOG_FILE" >&2
            exit 1
        fi
    else
        INPUT="cat"
        LOG_FILE="stdin"
    fi
fi

# Colors
BOLD='\033[1m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

header() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
}

# Build filter pipeline
FILTER_CMD="cat"
if [[ -n "$IP_FILTER" ]]; then
    FILTER_CMD="$FILTER_CMD | grep '^$IP_FILTER '"
fi
if [[ -n "$URI_FILTER" ]]; then
    FILTER_CMD="$FILTER_CMD | grep -E '$URI_FILTER'"
fi
if [[ -n "$STATUS_FILTER" ]]; then
    FILTER_CMD="$FILTER_CMD | grep '\" $STATUS_FILTER '"
fi

# Create temp file with filtered content
TMPFILE=$(mktemp)
trap 'rm -f $TMPFILE' EXIT

eval "$INPUT" | eval "$FILTER_CMD" > "$TMPFILE" 2>/dev/null || true

TOTAL_LINES=$(wc -l < "$TMPFILE")
if [[ "$TOTAL_LINES" -eq 0 ]]; then
    echo "No log entries found matching the specified filters."
    exit 0
fi

echo -e "${BOLD}Nginx Access Log Analysis${NC}"
echo "  Source: $LOG_FILE"
echo "  Total entries: $TOTAL_LINES"
echo "  Filters: ${IP_FILTER:+ip=$IP_FILTER }${STATUS_FILTER:+status=$STATUS_FILTER }${URI_FILTER:+uri=$URI_FILTER }${SINCE:+since=$SINCE }${UNTIL:+until=$UNTIL}"

# ── Top IPs ──
if [[ "$SECTION" == "all" || "$SECTION" == "ips" ]]; then
    header "Top $TOP Client IPs"
    printf "${CYAN}%-8s  %-15s  %-10s${NC}\n" "Count" "IP Address" "% of Total"
    awk '{print $1}' "$TMPFILE" | sort | uniq -c | sort -rn | head -"$TOP" | \
    while read -r count ip; do
        pct=$(awk "BEGIN {printf \"%.1f\", ($count/$TOTAL_LINES)*100}")
        bar_len=$(awk "BEGIN {printf \"%d\", ($count/$TOTAL_LINES)*40}")
        bar=$(printf '%*s' "$bar_len" '' | tr ' ' '█')
        printf "%-8s  %-15s  %5s%%  %s\n" "$count" "$ip" "$pct" "$bar"
    done
fi

# ── Status Code Distribution ──
if [[ "$SECTION" == "all" || "$SECTION" == "status" ]]; then
    header "HTTP Status Code Distribution"
    printf "${CYAN}%-8s  %-6s  %-10s  %-30s${NC}\n" "Count" "Code" "% of Total" "Category"
    awk '{print $9}' "$TMPFILE" | grep -E '^[0-9]{3}$' | sort | uniq -c | sort -rn | \
    while read -r count code; do
        pct=$(awk "BEGIN {printf \"%.1f\", ($count/$TOTAL_LINES)*100}")
        category=""
        color="$NC"
        case "$code" in
            2*) category="Success";       color="$GREEN" ;;
            3*) category="Redirect";      color="$CYAN" ;;
            4*) category="Client Error";  color="$YELLOW" ;;
            5*) category="Server Error";  color="$RED" ;;
        esac
        printf "%s%-8s  %-6s  %5s%%     %-30s%s\n" "$color" "$count" "$code" "$pct" "$category" "$NC"
    done
fi

# ── Top URIs ──
if [[ "$SECTION" == "all" || "$SECTION" == "uris" ]]; then
    header "Top $TOP Requested URIs"
    printf "${CYAN}%-8s  %-60s${NC}\n" "Count" "URI"
    awk '{print $7}' "$TMPFILE" | sort | uniq -c | sort -rn | head -"$TOP" | \
    while read -r count uri; do
        printf "%-8s  %-60s\n" "$count" "$uri"
    done
fi

# ── Top URIs by Status (4xx and 5xx) ──
if [[ "$SECTION" == "all" || "$SECTION" == "errors" ]]; then
    ERRORS=$(awk '$9 ~ /^[45][0-9]{2}$/' "$TMPFILE" | wc -l)
    if [[ "$ERRORS" -gt 0 ]]; then
        header "Top $TOP Error URIs (4xx/5xx)"
        printf "${CYAN}%-8s  %-6s  %-55s${NC}\n" "Count" "Status" "URI"
        awk '$9 ~ /^[45][0-9]{2}$/ {print $9, $7}' "$TMPFILE" | sort | uniq -c | sort -rn | head -"$TOP" | \
        while read -r count status uri; do
            color="$YELLOW"
            [[ "$status" == 5* ]] && color="$RED"
            printf "%s%-8s  %-6s  %-55s%s\n" "$color" "$count" "$status" "$uri" "$NC"
        done
    fi
fi

# ── Slow Requests ──
if [[ "$SECTION" == "all" || "$SECTION" == "slow" ]]; then
    header "Slow Requests (> ${SLOW_THRESHOLD}s)"
    # Try to extract request_time from log (rt= format or last numeric field)
    SLOW_LINES=$(grep -oP 'rt=\K[0-9.]+' "$TMPFILE" 2>/dev/null | awk -v t="$SLOW_THRESHOLD" '$1+0 > t' | wc -l)

    if [[ "$SLOW_LINES" -gt 0 ]]; then
        printf "${CYAN}%-10s  %-8s  %-6s  %-45s${NC}\n" "Time (s)" "Method" "Status" "URI"
        grep -P 'rt=[0-9.]+' "$TMPFILE" | \
        awk -v t="$SLOW_THRESHOLD" '{
            match($0, /rt=([0-9.]+)/, rt);
            if (rt[1]+0 > t) {
                printf "%-10s  %-8s  %-6s  %-45s\n", rt[1], $6, $9, $7
            }
        }' | sort -rn | head -"$TOP"

        echo ""
        echo "  Slow request statistics:"
        grep -oP 'rt=\K[0-9.]+' "$TMPFILE" 2>/dev/null | awk -v t="$SLOW_THRESHOLD" '
        $1+0 > t {
            count++; sum+=$1;
            if ($1 > max) max=$1;
        }
        END {
            if (count > 0)
                printf "    Count: %d | Avg: %.2fs | Max: %.2fs\n", count, sum/count, max
        }'
    else
        echo "  No slow requests found (or request_time not in log format)."
        echo "  Ensure your log_format includes rt=\$request_time"
    fi
fi

# ── Top User Agents ──
if [[ "$SECTION" == "all" || "$SECTION" == "agents" ]]; then
    header "Top $TOP User Agents"
    printf "${CYAN}%-8s  %-65s${NC}\n" "Count" "User Agent"
    awk -F'"' '{print $6}' "$TMPFILE" | sort | uniq -c | sort -rn | head -"$TOP" | \
    while read -r count agent; do
        printf "%-8s  %.65s\n" "$count" "$agent"
    done
fi

# ── Bandwidth ──
if [[ "$SECTION" == "all" || "$SECTION" == "bandwidth" ]]; then
    header "Bandwidth Summary"
    awk '{sum += $10} END {
        if (sum > 1073741824)
            printf "  Total bytes served: %.2f GB\n", sum/1073741824
        else if (sum > 1048576)
            printf "  Total bytes served: %.2f MB\n", sum/1048576
        else
            printf "  Total bytes served: %.2f KB\n", sum/1024
    }' "$TMPFILE" 2>/dev/null

    echo ""
    echo "  Top $TOP URIs by bandwidth:"
    printf "  ${CYAN}%-12s  %-50s${NC}\n" "Size" "URI"
    awk '{bytes[$7] += $10} END {for (uri in bytes) print bytes[uri], uri}' "$TMPFILE" | \
    sort -rn | head -"$TOP" | \
    while read -r bytes uri; do
        if (( bytes > 1073741824 )); then
            size=$(awk "BEGIN {printf \"%.1f GB\", $bytes/1073741824}")
        elif (( bytes > 1048576 )); then
            size=$(awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}")
        else
            size=$(awk "BEGIN {printf \"%.1f KB\", $bytes/1024}")
        fi
        printf "  %-12s  %-50s\n" "$size" "$uri"
    done
fi

# ── Requests per Hour ──
if [[ "$SECTION" == "all" ]]; then
    header "Requests per Hour (last 24 entries)"
    awk -F'[\\[/:]' '{print $5":"$6":00"}' "$TMPFILE" 2>/dev/null | sort | uniq -c | tail -24 | \
    while read -r count hour; do
        bar_width=$((count / (TOTAL_LINES / 100 + 1) ))
        [[ $bar_width -gt 50 ]] && bar_width=50
        bar=$(printf '%*s' "$bar_width" '' | tr ' ' '▓')
        printf "  %-15s  %6d  %s\n" "$hour" "$count" "$bar"
    done
fi

echo ""
echo -e "${BOLD}Analysis complete.${NC}"
