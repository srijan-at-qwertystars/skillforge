#!/usr/bin/env bash
# cron-monitor.sh — Monitor cron job health: check schedules, report failures
#
# Usage:
#   cron-monitor.sh status                       Show status of all monitored jobs
#   cron-monitor.sh check JOB_NAME CRON_EXPR     Check if job ran on schedule
#   cron-monitor.sh register JOB_NAME CRON_EXPR  Register a job for monitoring
#   cron-monitor.sh unregister JOB_NAME          Remove a job from monitoring
#   cron-monitor.sh report [--format json|text]   Generate health report
#   cron-monitor.sh heartbeat JOB_NAME           Record a heartbeat (call from your cron job)
#   cron-monitor.sh ping-healthchecks UUID        Ping healthchecks.io
#
# Configuration:
#   CRON_MONITOR_DIR    Base directory for state (default: /var/lib/cron-monitor)
#   CRON_MONITOR_LOG    Log directory (default: /var/log/cron-jobs)
#   HC_BASE_URL         Healthchecks.io base URL (default: https://hc-ping.com)
#
# Examples:
#   # Register jobs to monitor
#   cron-monitor.sh register daily-backup "0 2 * * *"
#   cron-monitor.sh register hourly-sync "0 * * * *"
#
#   # In your cron job, send heartbeat on completion
#   0 2 * * * /app/backup.sh && /usr/local/bin/cron-monitor.sh heartbeat daily-backup
#
#   # Check health
#   cron-monitor.sh status
#   cron-monitor.sh report --format json

set -uo pipefail

# --- Configuration ---
MONITOR_DIR="${CRON_MONITOR_DIR:-/var/lib/cron-monitor}"
LOG_DIR="${CRON_MONITOR_LOG:-/var/log/cron-jobs}"
HC_BASE_URL="${HC_BASE_URL:-https://hc-ping.com}"
JOBS_DIR="$MONITOR_DIR/jobs"
HEARTBEATS_DIR="$MONITOR_DIR/heartbeats"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Setup ---
ensure_dirs() {
    mkdir -p "$JOBS_DIR" "$HEARTBEATS_DIR" 2>/dev/null || {
        echo "Error: Cannot create monitor directories under $MONITOR_DIR" >&2
        echo "Try: sudo mkdir -p $MONITOR_DIR && sudo chown \$USER $MONITOR_DIR" >&2
        exit 1
    }
}

# --- Commands ---

cmd_register() {
    local name="$1" expr="$2"
    ensure_dirs

    cat > "$JOBS_DIR/$name.conf" <<EOF
name=$name
schedule=$expr
registered=$(date -Iseconds)
EOF
    echo -e "${GREEN}✓ Registered job: $name ($expr)${NC}"
}

cmd_unregister() {
    local name="$1"
    rm -f "$JOBS_DIR/$name.conf" "$HEARTBEATS_DIR/$name"
    echo -e "${GREEN}✓ Unregistered job: $name${NC}"
}

cmd_heartbeat() {
    local name="$1"
    ensure_dirs
    date +%s > "$HEARTBEATS_DIR/$name"
}

get_expected_interval() {
    # Calculate expected interval in seconds from cron expression using Python
    local expr="$1"
    python3 -c "
import sys
try:
    from croniter import croniter
    from datetime import datetime
    c = croniter('$expr', datetime.now())
    t1 = c.get_next(datetime)
    t2 = c.get_next(datetime)
    print(int((t2 - t1).total_seconds()))
except ImportError:
    # Fallback: rough estimate from cron expression
    fields = '$expr'.split()
    if len(fields) >= 5:
        minute, hour = fields[0], fields[1]
        if minute.startswith('*/'):
            print(int(minute[2:]) * 60)
        elif hour.startswith('*/'):
            print(int(hour[2:]) * 3600)
        elif minute == '0' and hour == '*':
            print(3600)
        elif minute == '0' and hour != '*':
            print(86400)
        else:
            print(86400)
    else:
        print(86400)
except Exception as e:
    print(86400, file=sys.stderr)
    print(86400)
" 2>/dev/null
}

check_job_health() {
    local name="$1" expr="$2"
    local heartbeat_file="$HEARTBEATS_DIR/$name"
    local now
    now=$(date +%s)

    if [[ ! -f "$heartbeat_file" ]]; then
        echo "UNKNOWN"
        return
    fi

    local last_beat
    last_beat=$(cat "$heartbeat_file" 2>/dev/null || echo 0)
    local age=$(( now - last_beat ))

    # Get expected interval and allow 50% grace period
    local interval
    interval=$(get_expected_interval "$expr")
    local grace=$(( interval + interval / 2 ))

    if (( age <= grace )); then
        echo "HEALTHY"
    elif (( age <= grace * 2 )); then
        echo "WARNING"
    else
        echo "CRITICAL"
    fi
}

format_duration() {
    local seconds="$1"
    if (( seconds < 60 )); then
        echo "${seconds}s"
    elif (( seconds < 3600 )); then
        echo "$((seconds / 60))m ago"
    elif (( seconds < 86400 )); then
        echo "$((seconds / 3600))h ago"
    else
        echo "$((seconds / 86400))d ago"
    fi
}

cmd_status() {
    ensure_dirs

    local total=0 healthy=0 warning=0 critical=0 unknown=0

    printf "\n${BLUE}%-20s %-20s %-10s %-15s${NC}\n" "JOB" "SCHEDULE" "STATUS" "LAST RUN"
    printf "%-20s %-20s %-10s %-15s\n" "────────────────────" "────────────────────" "──────────" "───────────────"

    for conf in "$JOBS_DIR"/*.conf 2>/dev/null; do
        [[ -f "$conf" ]] || continue
        ((total++))

        local name="" schedule=""
        while IFS='=' read -r key value; do
            case "$key" in
                name) name="$value" ;;
                schedule) schedule="$value" ;;
            esac
        done < "$conf"

        local status
        status=$(check_job_health "$name" "$schedule")
        local last_run="never"

        if [[ -f "$HEARTBEATS_DIR/$name" ]]; then
            local last_ts
            last_ts=$(cat "$HEARTBEATS_DIR/$name")
            local age=$(( $(date +%s) - last_ts ))
            last_run=$(format_duration "$age")
        fi

        local color="$NC"
        case "$status" in
            HEALTHY)  color="$GREEN"; ((healthy++)) ;;
            WARNING)  color="$YELLOW"; ((warning++)) ;;
            CRITICAL) color="$RED"; ((critical++)) ;;
            UNKNOWN)  color="$YELLOW"; ((unknown++)) ;;
        esac

        printf "%-20s %-20s ${color}%-10s${NC} %-15s\n" "$name" "$schedule" "$status" "$last_run"
    done

    if (( total == 0 )); then
        echo -e "${YELLOW}No jobs registered. Use: $0 register JOB_NAME 'CRON_EXPR'${NC}"
        return
    fi

    echo ""
    echo -e "Total: $total | ${GREEN}Healthy: $healthy${NC} | ${YELLOW}Warning: $warning${NC} | ${RED}Critical: $critical${NC} | Unknown: $unknown"
}

cmd_check() {
    local name="$1" expr="$2"
    ensure_dirs

    local status
    status=$(check_job_health "$name" "$expr")
    local exit_code=0

    case "$status" in
        HEALTHY)
            echo -e "${GREEN}✓ $name: healthy${NC}"
            ;;
        WARNING)
            echo -e "${YELLOW}⚠ $name: overdue (warning)${NC}"
            exit_code=1
            ;;
        CRITICAL)
            echo -e "${RED}✗ $name: overdue (critical)${NC}"
            exit_code=2
            ;;
        UNKNOWN)
            echo -e "${YELLOW}? $name: no heartbeat recorded${NC}"
            exit_code=3
            ;;
    esac

    if [[ -f "$HEARTBEATS_DIR/$name" ]]; then
        local last_ts
        last_ts=$(cat "$HEARTBEATS_DIR/$name")
        local age=$(( $(date +%s) - last_ts ))
        echo "  Last heartbeat: $(format_duration $age) ($(date -d "@$last_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$last_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown'))"
    fi

    # Check log file for recent errors
    local log_file="$LOG_DIR/${name}.log"
    if [[ -f "$log_file" ]]; then
        local recent_errors
        recent_errors=$(grep -c "FAILED\|ERROR\|error\|fatal" "$log_file" 2>/dev/null || echo 0)
        if (( recent_errors > 0 )); then
            echo -e "  ${YELLOW}Log has $recent_errors error lines: $log_file${NC}"
            echo "  Last error:"
            grep -i "FAILED\|ERROR\|fatal" "$log_file" | tail -1 | sed 's/^/    /'
        fi
    fi

    return $exit_code
}

cmd_report() {
    local format="${1:-text}"
    ensure_dirs

    if [[ "$format" == "json" ]]; then
        echo "{"
        echo "  \"timestamp\": \"$(date -Iseconds)\","
        echo "  \"jobs\": ["

        local first=true
        for conf in "$JOBS_DIR"/*.conf 2>/dev/null; do
            [[ -f "$conf" ]] || continue

            local name="" schedule=""
            while IFS='=' read -r key value; do
                case "$key" in
                    name) name="$value" ;;
                    schedule) schedule="$value" ;;
                esac
            done < "$conf"

            local status
            status=$(check_job_health "$name" "$schedule")
            local last_heartbeat="null"
            if [[ -f "$HEARTBEATS_DIR/$name" ]]; then
                last_heartbeat=$(cat "$HEARTBEATS_DIR/$name")
            fi

            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo ","
            fi

            printf '    {"name": "%s", "schedule": "%s", "status": "%s", "last_heartbeat": %s}' \
                "$name" "$schedule" "$status" "$last_heartbeat"
        done

        echo ""
        echo "  ]"
        echo "}"
    else
        cmd_status
    fi
}

cmd_ping_healthchecks() {
    local uuid="$1"
    local exit_code="${2:-0}"

    if (( exit_code == 0 )); then
        curl -fsS -m 10 "${HC_BASE_URL}/${uuid}" > /dev/null 2>&1
        echo -e "${GREEN}✓ Pinged healthchecks.io (success)${NC}"
    else
        curl -fsS -m 10 "${HC_BASE_URL}/${uuid}/fail" > /dev/null 2>&1
        echo -e "${RED}✗ Pinged healthchecks.io (failure)${NC}"
    fi
}

# --- Main ---
if [[ $# -lt 1 ]]; then
    sed -n '2,/^$/s/^# \?//p' "$0"
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    register)
        [[ $# -ge 2 ]] || { echo "Usage: $0 register JOB_NAME 'CRON_EXPR'"; exit 1; }
        cmd_register "$1" "$2"
        ;;
    unregister)
        [[ $# -ge 1 ]] || { echo "Usage: $0 unregister JOB_NAME"; exit 1; }
        cmd_unregister "$1"
        ;;
    heartbeat)
        [[ $# -ge 1 ]] || { echo "Usage: $0 heartbeat JOB_NAME"; exit 1; }
        cmd_heartbeat "$1"
        ;;
    check)
        [[ $# -ge 2 ]] || { echo "Usage: $0 check JOB_NAME 'CRON_EXPR'"; exit 1; }
        cmd_check "$1" "$2"
        ;;
    status)
        cmd_status
        ;;
    report)
        format="text"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --format) format="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        cmd_report "$format"
        ;;
    ping-healthchecks)
        [[ $# -ge 1 ]] || { echo "Usage: $0 ping-healthchecks UUID [EXIT_CODE]"; exit 1; }
        cmd_ping_healthchecks "$1" "${2:-0}"
        ;;
    *)
        echo "Unknown command: $COMMAND"
        echo "Commands: register, unregister, heartbeat, check, status, report, ping-healthchecks"
        exit 1
        ;;
esac
