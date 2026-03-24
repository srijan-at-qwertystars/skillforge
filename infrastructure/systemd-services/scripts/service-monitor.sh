#!/usr/bin/env bash
# =============================================================================
# service-monitor.sh — Monitor systemd service health and resource usage
# =============================================================================
# Usage: ./service-monitor.sh [OPTIONS] SERVICE [SERVICE...]
#
# Monitors systemd services for health issues including restart counts,
# memory usage, CPU usage, and failure conditions.
#
# Options:
#   --watch, -w          Continuous monitoring (refresh every interval)
#   --interval, -i SECS  Refresh interval in seconds (default: 5)
#   --alert-restarts N   Alert if restart count >= N (default: 3)
#   --alert-memory PCT   Alert if memory usage >= PCT% of MemoryMax (default: 90)
#   --json               Output as JSON
#   --all                Monitor all active services
#   --failed             Show only failed services
#   --help, -h           Show this help
#
# Examples:
#   ./service-monitor.sh nginx.service myapp.service
#   ./service-monitor.sh --watch --interval 10 myapp.service
#   ./service-monitor.sh --all --failed
#   ./service-monitor.sh --alert-restarts 5 --alert-memory 80 myapp.service
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

WATCH=false
INTERVAL=5
ALERT_RESTARTS=3
ALERT_MEMORY=90
JSON_OUTPUT=false
MONITOR_ALL=false
FAILED_ONLY=false
SERVICES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch|-w) WATCH=true; shift ;;
        --interval|-i) INTERVAL="$2"; shift 2 ;;
        --alert-restarts) ALERT_RESTARTS="$2"; shift 2 ;;
        --alert-memory) ALERT_MEMORY="$2"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        --all) MONITOR_ALL=true; shift ;;
        --failed) FAILED_ONLY=true; shift ;;
        --help|-h)
            head -20 "$0" | tail -18
            exit 0
            ;;
        *) SERVICES+=("$1"); shift ;;
    esac
done

if ! command -v systemctl &>/dev/null; then
    echo "Error: systemctl not found." >&2
    exit 1
fi

get_services() {
    if [[ "$MONITOR_ALL" == true ]]; then
        if [[ "$FAILED_ONLY" == true ]]; then
            systemctl list-units --type=service --state=failed --no-legend --no-pager \
                | awk '{print $1}'
        else
            systemctl list-units --type=service --state=active,failed --no-legend --no-pager \
                | awk '{print $1}'
        fi
    else
        printf '%s\n' "${SERVICES[@]}"
    fi
}

human_bytes() {
    local bytes="$1"
    if [[ -z "$bytes" || "$bytes" == "[not set]" || "$bytes" == "infinity" ]]; then
        echo "N/A"
        return
    fi
    if (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.1fG\", $bytes/1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.1fM\", $bytes/1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN {printf \"%.1fK\", $bytes/1024}"
    else
        echo "${bytes}B"
    fi
}

human_nsec() {
    local nsec="$1"
    if [[ -z "$nsec" || "$nsec" == "[not set]" ]]; then
        echo "N/A"
        return
    fi
    local sec
    sec=$(awk "BEGIN {printf \"%.2f\", $nsec/1000000000}")
    if awk "BEGIN {exit !($sec >= 3600)}" 2>/dev/null; then
        awk "BEGIN {printf \"%.1fh\", $sec/3600}"
    elif awk "BEGIN {exit !($sec >= 60)}" 2>/dev/null; then
        awk "BEGIN {printf \"%.1fm\", $sec/60}"
    else
        echo "${sec}s"
    fi
}

get_service_info() {
    local service="$1"
    local props
    props=$(systemctl show "$service" --no-pager \
        -p ActiveState \
        -p SubState \
        -p MainPID \
        -p NRestarts \
        -p MemoryCurrent \
        -p MemoryMax \
        -p MemoryHigh \
        -p CPUUsageNSec \
        -p TasksCurrent \
        -p TasksMax \
        -p ExecMainStartTimestamp \
        -p Result \
        -p InvocationID \
        -p StatusText 2>/dev/null)

    echo "$props"
}

monitor_service() {
    local service="$1"
    local props
    props=$(get_service_info "$service")

    local active sub pid restarts mem_current mem_max mem_high cpu_nsec
    local tasks_current tasks_max start_time result status_text

    active=$(echo "$props" | grep '^ActiveState=' | cut -d= -f2-)
    sub=$(echo "$props" | grep '^SubState=' | cut -d= -f2-)
    pid=$(echo "$props" | grep '^MainPID=' | cut -d= -f2-)
    restarts=$(echo "$props" | grep '^NRestarts=' | cut -d= -f2-)
    mem_current=$(echo "$props" | grep '^MemoryCurrent=' | cut -d= -f2-)
    mem_max=$(echo "$props" | grep '^MemoryMax=' | cut -d= -f2-)
    mem_high=$(echo "$props" | grep '^MemoryHigh=' | cut -d= -f2-)
    cpu_nsec=$(echo "$props" | grep '^CPUUsageNSec=' | cut -d= -f2-)
    tasks_current=$(echo "$props" | grep '^TasksCurrent=' | cut -d= -f2-)
    tasks_max=$(echo "$props" | grep '^TasksMax=' | cut -d= -f2-)
    start_time=$(echo "$props" | grep '^ExecMainStartTimestamp=' | cut -d= -f2-)
    result=$(echo "$props" | grep '^Result=' | cut -d= -f2-)
    status_text=$(echo "$props" | grep '^StatusText=' | cut -d= -f2-)

    # Calculate memory percentage
    local mem_pct="N/A"
    if [[ -n "$mem_current" && "$mem_current" != "[not set]" && \
          -n "$mem_max" && "$mem_max" != "infinity" && "$mem_max" != "[not set]" && \
          "$mem_max" -gt 0 ]] 2>/dev/null; then
        mem_pct=$(awk "BEGIN {printf \"%.1f\", ($mem_current / $mem_max) * 100}")
    fi

    # Determine alerts
    local alerts=()
    if [[ "$active" == "failed" ]]; then
        alerts+=("FAILED")
    fi
    if [[ -n "$restarts" ]] && (( restarts >= ALERT_RESTARTS )); then
        alerts+=("HIGH_RESTARTS:${restarts}")
    fi
    if [[ "$mem_pct" != "N/A" ]] && awk "BEGIN {exit !($mem_pct >= $ALERT_MEMORY)}" 2>/dev/null; then
        alerts+=("HIGH_MEMORY:${mem_pct}%")
    fi

    if [[ "$JSON_OUTPUT" == true ]]; then
        local alert_json=""
        for a in "${alerts[@]:-}"; do
            [[ -z "$a" ]] && continue
            alert_json="${alert_json:+$alert_json,}\"$a\""
        done
        printf '{"service":"%s","active":"%s","sub":"%s","pid":%s,"restarts":%s,"memory_bytes":%s,"memory_max":%s,"memory_pct":"%s","cpu_nsec":%s,"tasks":%s,"tasks_max":%s,"alerts":[%s]}\n' \
            "$service" "$active" "$sub" "${pid:-0}" "${restarts:-0}" \
            "${mem_current:-0}" "${mem_max:-0}" "$mem_pct" "${cpu_nsec:-0}" \
            "${tasks_current:-0}" "${tasks_max:-0}" "$alert_json"
        return
    fi

    # Status color
    local state_color="$GREEN"
    if [[ "$active" == "failed" ]]; then state_color="$RED"
    elif [[ "$active" == "activating" || "$active" == "deactivating" ]]; then state_color="$YELLOW"
    elif [[ "$active" == "inactive" ]]; then state_color="$DIM"
    fi

    echo -e "${BOLD}${service}${NC}"
    printf "  %-14s ${state_color}%s (%s)${NC}" "State:" "$active" "$sub"
    if [[ "$result" != "success" && "$result" != "" ]]; then
        printf "  result=${RED}%s${NC}" "$result"
    fi
    echo ""

    printf "  %-14s %s\n" "PID:" "${pid:-N/A}"
    printf "  %-14s %s\n" "Started:" "${start_time:-N/A}"

    # Restarts
    local restart_color="$NC"
    if [[ -n "$restarts" ]] && (( restarts >= ALERT_RESTARTS )); then
        restart_color="$RED"
    elif [[ -n "$restarts" ]] && (( restarts > 0 )); then
        restart_color="$YELLOW"
    fi
    printf "  %-14s ${restart_color}%s${NC}\n" "Restarts:" "${restarts:-0}"

    # Memory
    local mem_color="$NC"
    if [[ "$mem_pct" != "N/A" ]] && awk "BEGIN {exit !($mem_pct >= $ALERT_MEMORY)}" 2>/dev/null; then
        mem_color="$RED"
    elif [[ "$mem_pct" != "N/A" ]] && awk "BEGIN {exit !($mem_pct >= 70)}" 2>/dev/null; then
        mem_color="$YELLOW"
    fi
    local mem_h
    mem_h=$(human_bytes "${mem_current:-0}")
    local max_h
    max_h=$(human_bytes "${mem_max:-0}")
    printf "  %-14s ${mem_color}%s / %s (%s%%)${NC}\n" "Memory:" "$mem_h" "$max_h" "$mem_pct"

    # CPU
    local cpu_h
    cpu_h=$(human_nsec "${cpu_nsec:-0}")
    printf "  %-14s %s\n" "CPU time:" "$cpu_h"

    # Tasks
    printf "  %-14s %s / %s\n" "Tasks:" "${tasks_current:-N/A}" "${tasks_max:-N/A}"

    # Status text
    if [[ -n "$status_text" ]]; then
        printf "  %-14s %s\n" "Status:" "$status_text"
    fi

    # Alerts
    if [[ ${#alerts[@]} -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}⚠ ALERTS:${NC} ${RED}${alerts[*]}${NC}"
    fi

    echo ""
}

run_once() {
    local services_list
    services_list=$(get_services)

    if [[ -z "$services_list" ]]; then
        if [[ "$FAILED_ONLY" == true ]]; then
            echo -e "${GREEN}No failed services found.${NC}"
        else
            echo "No services specified. Use --all or provide service names." >&2
            exit 1
        fi
        return
    fi

    if [[ "$JSON_OUTPUT" != true && "$WATCH" != true ]]; then
        echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}║     systemd Service Health Monitor       ║${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
        echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo ""
    fi

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        monitor_service "$service"
    done <<< "$services_list"
}

# Main
if [[ "$MONITOR_ALL" == false && ${#SERVICES[@]} -eq 0 && "$FAILED_ONLY" == false ]]; then
    echo "Usage: $0 [OPTIONS] SERVICE [SERVICE...]" >&2
    echo "       $0 --all [--failed]" >&2
    exit 1
fi

if [[ "$WATCH" == true ]]; then
    while true; do
        clear
        echo -e "${BOLD}Service Monitor${NC} — ${DIM}$(date '+%Y-%m-%d %H:%M:%S') (every ${INTERVAL}s, Ctrl+C to stop)${NC}"
        echo ""
        run_once
        sleep "$INTERVAL"
    done
else
    run_once
fi
