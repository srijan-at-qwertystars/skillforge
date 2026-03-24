#!/usr/bin/env bash
# ============================================================================
# stress-test.sh — CPU, memory, and disk stress injection using stress-ng.
#
# Usage:
#   ./stress-test.sh cpu <cores> <duration_s> [load_percent]
#   ./stress-test.sh memory <amount> <duration_s>
#   ./stress-test.sh disk-io <workers> <duration_s>
#   ./stress-test.sh disk-fill <size> <path> [duration_s]
#   ./stress-test.sh combined <cpu_cores> <mem_amount> <duration_s>
#   ./stress-test.sh status
#   ./stress-test.sh stop
#
# Examples:
#   ./stress-test.sh cpu 4 60                # 4 CPU workers for 60s (100%)
#   ./stress-test.sh cpu 0 120 80            # All CPUs at 80% for 120s
#   ./stress-test.sh memory 2G 60            # Allocate 2GB for 60s
#   ./stress-test.sh disk-io 4 60            # 4 I/O workers for 60s
#   ./stress-test.sh disk-fill 10G /tmp 30   # Fill 10GB in /tmp for 30s
#   ./stress-test.sh combined 2 1G 60        # CPU + memory combined for 60s
#   ./stress-test.sh status                  # Show running stress-ng processes
#   ./stress-test.sh stop                    # Stop all stress-ng processes
#
# Requirements: stress-ng (install: apt-get install stress-ng)
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_chaos() { echo -e "${CYAN}[STRESS]${NC} $*"; }

FILL_FILE=""

cleanup() {
    if [[ -n "$FILL_FILE" && -f "$FILL_FILE" ]]; then
        rm -f "$FILL_FILE"
        log_info "Removed disk fill file: $FILL_FILE"
    fi
}
trap cleanup EXIT INT TERM

check_deps() {
    if ! command -v stress-ng &>/dev/null; then
        log_error "stress-ng not found. Install with: apt-get install stress-ng"
        exit 1
    fi
}

show_system_state() {
    echo -e "\n${CYAN}=== System State ===${NC}"
    echo -n "CPU Usage: "
    top -bn1 | grep "Cpu(s)" | awk '{print $2}' | head -1 || echo "N/A"
    echo -n "Memory: "
    free -h | awk '/^Mem:/ {printf "%s used / %s total (%.1f%%)\n", $3, $2, $3/$2*100}'
    echo -n "Disk: "
    df -h / | awk 'NR==2 {printf "%s used / %s total (%s)\n", $3, $2, $5}'
    echo ""
}

cmd_cpu() {
    local cores="${1:?Usage: cpu <cores> <duration_s> [load_percent]}"
    local duration="${2:?Duration in seconds required}"
    local load="${3:-100}"

    log_chaos "CPU stress: $cores core(s) at ${load}% for ${duration}s"
    show_system_state

    if [[ "$load" -lt 100 ]]; then
        stress-ng --cpu "$cores" --cpu-load "$load" --timeout "${duration}s" --metrics-brief
    else
        stress-ng --cpu "$cores" --timeout "${duration}s" --metrics-brief
    fi

    log_info "CPU stress completed"
    show_system_state
}

cmd_memory() {
    local amount="${1:?Usage: memory <amount> <duration_s> (e.g., 2G, 512M)}"
    local duration="${2:?Duration in seconds required}"

    log_chaos "Memory stress: allocating $amount for ${duration}s"
    show_system_state

    stress-ng --vm 1 --vm-bytes "$amount" --vm-keep --timeout "${duration}s" --metrics-brief

    log_info "Memory stress completed"
    show_system_state
}

cmd_disk_io() {
    local workers="${1:?Usage: disk-io <workers> <duration_s>}"
    local duration="${2:?Duration in seconds required}"

    log_chaos "Disk I/O stress: $workers worker(s) for ${duration}s"
    show_system_state

    stress-ng --io "$workers" --timeout "${duration}s" --metrics-brief

    log_info "Disk I/O stress completed"
    show_system_state
}

cmd_disk_fill() {
    local size="${1:?Usage: disk-fill <size> <path> [duration_s]}"
    local path="${2:?Target path required (e.g., /tmp)}"
    local duration="${3:-30}"

    FILL_FILE="${path}/chaos-disk-fill-$(date +%s).dat"

    log_chaos "Disk fill: creating ${size} file at $FILL_FILE for ${duration}s"

    local available
    available=$(df -BG "$path" | awk 'NR==2 {print $4}' | tr -d 'G')
    local requested
    requested=$(echo "$size" | sed 's/[Gg]$//')
    if [[ "$requested" -gt "$available" ]]; then
        log_error "Requested ${size} but only ${available}G available at $path"
        exit 1
    fi

    show_system_state
    fallocate -l "$size" "$FILL_FILE"
    log_info "Created $size file: $FILL_FILE"
    df -h "$path"

    log_info "Holding for ${duration}s..."
    sleep "$duration"

    rm -f "$FILL_FILE"
    FILL_FILE=""
    log_info "Disk fill removed"
    df -h "$path"
}

cmd_combined() {
    local cpu_cores="${1:?Usage: combined <cpu_cores> <mem_amount> <duration_s>}"
    local mem_amount="${2:?Memory amount required (e.g., 1G)}"
    local duration="${3:?Duration in seconds required}"

    log_chaos "Combined stress: $cpu_cores CPU core(s) + $mem_amount memory for ${duration}s"
    show_system_state

    stress-ng \
        --cpu "$cpu_cores" \
        --vm 1 --vm-bytes "$mem_amount" --vm-keep \
        --timeout "${duration}s" \
        --metrics-brief

    log_info "Combined stress completed"
    show_system_state
}

cmd_status() {
    echo -e "${CYAN}=== Active Stress Processes ===${NC}"
    if pgrep -a stress-ng 2>/dev/null; then
        echo ""
        show_system_state
    else
        log_info "No active stress-ng processes"
    fi

    local fill_files
    fill_files=$(find /tmp -name "chaos-disk-fill-*" 2>/dev/null || true)
    if [[ -n "$fill_files" ]]; then
        echo -e "\n${CYAN}=== Disk Fill Files ===${NC}"
        ls -lh $fill_files
    fi
}

cmd_stop() {
    log_info "Stopping all stress-ng processes..."
    local pids
    pids=$(pgrep stress-ng 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | while read -r pid; do
            kill "$pid" 2>/dev/null || true
            log_info "Killed stress-ng PID $pid"
        done
    else
        log_info "No stress-ng processes found"
    fi

    local fill_files
    fill_files=$(find /tmp -name "chaos-disk-fill-*" 2>/dev/null || true)
    if [[ -n "$fill_files" ]]; then
        rm -f $fill_files
        log_info "Removed disk fill files"
    fi

    log_info "All stress stopped"
}

usage() {
    cat <<'EOF'
Usage: stress-test.sh <command> [args...]

Commands:
  cpu <cores> <duration_s> [load%]            CPU stress (0=all cores)
  memory <amount> <duration_s>                Memory allocation (e.g., 2G)
  disk-io <workers> <duration_s>              Disk I/O saturation
  disk-fill <size> <path> [duration_s]        Fill disk space temporarily
  combined <cores> <mem> <duration_s>         CPU + memory combined stress
  status                                      Show active stress processes
  stop                                        Stop all stress processes

Requires: stress-ng (apt-get install stress-ng)
EOF
    exit 1
}

# --- Main ---
check_deps

case "${1:-}" in
    cpu)       shift; cmd_cpu "$@" ;;
    memory)    shift; cmd_memory "$@" ;;
    disk-io)   shift; cmd_disk_io "$@" ;;
    disk-fill) shift; cmd_disk_fill "$@" ;;
    combined)  shift; cmd_combined "$@" ;;
    status)    cmd_status ;;
    stop)      cmd_stop ;;
    *)         usage ;;
esac
