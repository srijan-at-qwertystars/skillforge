#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# monitor-lag.sh — Kafka consumer group lag monitoring with alerting
# =============================================================================

# ── Defaults ─────────────────────────────────────────────────────────────────
BOOTSTRAP_SERVER="localhost:9092"
GROUP=""
ALL_GROUPS=false
INTERVAL=10
WARN_THRESHOLD=1000
CRIT_THRESHOLD=10000
ONCE=false
JSON_OUTPUT=false
KAFKA_CONTAINER="kafka"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging helpers ──────────────────────────────────────────────────────────
info()     { printf "${CYAN}[INFO]${NC}     %s\n" "$*"; }
success()  { printf "${GREEN}[OK]${NC}       %s\n" "$*"; }
warn_msg() { printf "${YELLOW}[WARNING]${NC}  %s\n" "$*"; }
crit_msg() { printf "${RED}[CRITICAL]${NC} %s\n" "$*"; }
error()    { printf "${RED}[ERROR]${NC}    %s\n" "$*" >&2; }

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") [OPTIONS]

Monitor Kafka consumer group lag with configurable thresholds and alerting.

${BOLD}Options:${NC}
  --bootstrap-server HOST:PORT   Kafka bootstrap server (default: localhost:9092)
  --group GROUP                  Consumer group to monitor (required unless --all-groups)
  --all-groups                   Monitor all consumer groups
  --interval SECONDS             Polling interval for continuous mode (default: 10)
  --once                         Run a single check and exit (one-shot mode)
  --warn-threshold N             Lag threshold for WARNING alerts (default: 1000)
  --crit-threshold N             Lag threshold for CRITICAL alerts (default: 10000)
  --json                         Output results in JSON format
  --container NAME               Docker container running Kafka (default: kafka)
  -h, --help                     Show this help message

${BOLD}Examples:${NC}
  $(basename "$0") --group my-consumer-group --once
  $(basename "$0") --all-groups --interval 30
  $(basename "$0") --group payments --warn-threshold 500 --crit-threshold 5000
  $(basename "$0") --all-groups --json --once

EOF
}

# ── Parse arguments ──────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bootstrap-server) BOOTSTRAP_SERVER="$2"; shift 2 ;;
            --group)            GROUP="$2";             shift 2 ;;
            --all-groups)       ALL_GROUPS=true;        shift ;;
            --interval)         INTERVAL="$2";          shift 2 ;;
            --once)             ONCE=true;              shift ;;
            --warn-threshold)   WARN_THRESHOLD="$2";    shift 2 ;;
            --crit-threshold)   CRIT_THRESHOLD="$2";    shift 2 ;;
            --json)             JSON_OUTPUT=true;        shift ;;
            --container)        KAFKA_CONTAINER="$2";   shift 2 ;;
            -h|--help)          usage; exit 0 ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [[ -z "${GROUP}" && "${ALL_GROUPS}" == false ]]; then
        error "Either --group <name> or --all-groups is required"
        usage
        exit 1
    fi
}

# ── Resolve kafka-consumer-groups command path ───────────────────────────────
resolve_consumer_groups_cmd() {
    docker exec "${KAFKA_CONTAINER}" sh -c \
        'if [ -f /opt/kafka/bin/kafka-consumer-groups.sh ]; then echo /opt/kafka/bin/kafka-consumer-groups.sh; else echo kafka-consumer-groups; fi'
}

# ── List all consumer groups ─────────────────────────────────────────────────
list_groups() {
    local cmd="$1"
    docker exec "${KAFKA_CONTAINER}" ${cmd} \
        --bootstrap-server "${BOOTSTRAP_SERVER}" \
        --list 2>/dev/null | grep -v '^$' || true
}

# ── Fetch lag data for a single group ────────────────────────────────────────
fetch_group_lag() {
    local cmd="$1"
    local group="$2"

    docker exec "${KAFKA_CONTAINER}" ${cmd} \
        --bootstrap-server "${BOOTSTRAP_SERVER}" \
        --describe --group "${group}" 2>/dev/null \
        | grep -v "^$" \
        | tail -n +2 || true
}

# ── Colorize lag value ───────────────────────────────────────────────────────
colorize_lag() {
    local lag="$1"

    if [[ "${lag}" == "-" || -z "${lag}" ]]; then
        printf "${CYAN}%-10s${NC}" "${lag}"
        return
    fi

    if (( lag >= CRIT_THRESHOLD )); then
        printf "${RED}%-10s${NC}" "${lag}"
    elif (( lag >= WARN_THRESHOLD )); then
        printf "${YELLOW}%-10s${NC}" "${lag}"
    else
        printf "${GREEN}%-10s${NC}" "${lag}"
    fi
}

# ── Print table header ──────────────────────────────────────────────────────
print_header() {
    printf "\n${BOLD}%-25s %-25s %-12s %-18s %-18s %-10s${NC}\n" \
        "GROUP" "TOPIC" "PARTITION" "CURRENT-OFFSET" "LOG-END-OFFSET" "LAG"
    printf "%-25s %-25s %-12s %-18s %-18s %-10s\n" \
        "-------------------------" "-------------------------" "------------" \
        "------------------" "------------------" "----------"
}

# ── Process & display lag for one group ──────────────────────────────────────
process_group() {
    local cmd="$1"
    local group="$2"
    local total_lag=0
    local partition_count=0
    local max_lag=0
    local alert_level="OK"
    local json_entries=()

    local raw_output
    raw_output=$(fetch_group_lag "${cmd}" "${group}")

    if [[ -z "${raw_output}" ]]; then
        if [[ "${JSON_OUTPUT}" == false ]]; then
            warn_msg "No data for group '${group}'"
        fi
        return
    fi

    if [[ "${JSON_OUTPUT}" == false ]]; then
        print_header
    fi

    while IFS= read -r line; do
        # Parse columns: GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG ...
        local g t p co leo lag
        read -r g t p co leo lag _ <<< "${line}"

        # Skip header rows or empty
        [[ "${g}" == "GROUP" || -z "${g}" ]] && continue

        ((partition_count++)) || true

        local numeric_lag=0
        if [[ "${lag}" =~ ^[0-9]+$ ]]; then
            numeric_lag=${lag}
            ((total_lag += numeric_lag)) || true
            if (( numeric_lag > max_lag )); then
                max_lag=${numeric_lag}
            fi
        fi

        if [[ "${JSON_OUTPUT}" == false ]]; then
            printf "%-25s %-25s %-12s %-18s %-18s " "${g}" "${t}" "${p}" "${co}" "${leo}"
            colorize_lag "${lag}"
            printf "\n"
        else
            json_entries+=("{\"group\":\"${g}\",\"topic\":\"${t}\",\"partition\":${p},\"current_offset\":\"${co}\",\"log_end_offset\":\"${leo}\",\"lag\":\"${lag}\"}")
        fi
    done <<< "${raw_output}"

    # Determine alert level
    if (( max_lag >= CRIT_THRESHOLD )); then
        alert_level="CRITICAL"
    elif (( max_lag >= WARN_THRESHOLD )); then
        alert_level="WARNING"
    fi

    # ── JSON output ──────────────────────────────────────────────────────
    if [[ "${JSON_OUTPUT}" == true ]]; then
        local joined
        joined=$(IFS=,; echo "${json_entries[*]}")
        cat <<ENDJSON
{
  "group": "${group}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total_lag": ${total_lag},
  "max_lag": ${max_lag},
  "partitions_monitored": ${partition_count},
  "alert_level": "${alert_level}",
  "warn_threshold": ${WARN_THRESHOLD},
  "crit_threshold": ${CRIT_THRESHOLD},
  "partitions": [${joined}]
}
ENDJSON
        return
    fi

    # ── Summary line ─────────────────────────────────────────────────────
    printf "\n${BOLD}Summary:${NC} group=${CYAN}%s${NC}  partitions=${CYAN}%d${NC}  total_lag=" "${group}" "${partition_count}"
    colorize_lag "${total_lag}"
    printf "  max_lag="
    colorize_lag "${max_lag}"
    printf "\n"

    # ── Alert output ─────────────────────────────────────────────────────
    case "${alert_level}" in
        CRITICAL)
            crit_msg "Group '${group}' — total_lag=${total_lag}, max_lag=${max_lag} (threshold: ${CRIT_THRESHOLD})"
            ;;
        WARNING)
            warn_msg "Group '${group}' — total_lag=${total_lag}, max_lag=${max_lag} (threshold: ${WARN_THRESHOLD})"
            ;;
        OK)
            success "Group '${group}' — lag within acceptable range"
            ;;
    esac
}

# ── Single monitoring pass ───────────────────────────────────────────────────
run_check() {
    local cmd="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ "${JSON_OUTPUT}" == false ]]; then
        printf "\n${BOLD}═══ Kafka Lag Monitor — %s ═══${NC}\n" "${timestamp}"
    fi

    if [[ "${ALL_GROUPS}" == true ]]; then
        local groups
        groups=$(list_groups "${cmd}")
        if [[ -z "${groups}" ]]; then
            if [[ "${JSON_OUTPUT}" == false ]]; then
                warn_msg "No consumer groups found"
            else
                echo '{"error":"no consumer groups found","timestamp":"'"${timestamp}"'"}'
            fi
            return
        fi
        while IFS= read -r g; do
            [[ -z "${g}" ]] && continue
            process_group "${cmd}" "${g}"
        done <<< "${groups}"
    else
        process_group "${cmd}" "${GROUP}"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    # Preflight: check docker is running and container exists
    if ! command -v docker &>/dev/null; then
        error "docker is not installed or not in PATH"
        exit 1
    fi
    if ! docker inspect "${KAFKA_CONTAINER}" &>/dev/null; then
        error "Container '${KAFKA_CONTAINER}' is not running. Start Kafka first."
        exit 1
    fi

    local consumer_groups_cmd
    consumer_groups_cmd=$(resolve_consumer_groups_cmd)

    if [[ "${ONCE}" == true ]]; then
        run_check "${consumer_groups_cmd}"
    else
        info "Starting continuous monitoring (interval=${INTERVAL}s). Press Ctrl+C to stop."
        trap 'printf "\n"; info "Monitoring stopped."; exit 0' INT TERM
        while true; do
            run_check "${consumer_groups_cmd}"
            sleep "${INTERVAL}"
        done
    fi
}

main "$@"
