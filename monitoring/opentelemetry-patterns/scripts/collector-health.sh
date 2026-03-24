#!/usr/bin/env bash
# ============================================================================
# collector-health.sh — Check OTel Collector health, pipeline status, and metrics
# ============================================================================
#
# Usage:
#   ./collector-health.sh [OPTIONS]
#
# Options:
#   --host HOST        Collector host (default: localhost)
#   --health-port PORT Health check port (default: 13133)
#   --metrics-port PORT Internal metrics port (default: 8888)
#   --zpages-port PORT zpages port (default: 55679)
#   --json             Output in JSON format
#   --watch            Continuously monitor (every 10s)
#   -h, --help         Show help
#
# Examples:
#   ./collector-health.sh
#   ./collector-health.sh --host otel-collector --metrics-port 8888
#   ./collector-health.sh --watch
#   ./collector-health.sh --json | jq .
#
# Requirements:
#   - curl
#   - jq (optional, for JSON parsing)
# ============================================================================

set -euo pipefail

# --- Defaults ---
HOST="localhost"
HEALTH_PORT="13133"
METRICS_PORT="8888"
ZPAGES_PORT="55679"
JSON_OUTPUT=false
WATCH_MODE=false

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { [[ "$JSON_OUTPUT" == true ]] && return; echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { [[ "$JSON_OUTPUT" == true ]] && return; echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { [[ "$JSON_OUTPUT" == true ]] && return; echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { [[ "$JSON_OUTPUT" == true ]] && return; echo -e "${RED}[FAIL]${NC} $*"; }
header(){ [[ "$JSON_OUTPUT" == true ]] && return; echo -e "\n${BOLD}═══ $* ═══${NC}"; }

usage() {
    head -25 "$0" | tail -20
    exit 0
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --host) HOST="$2"; shift 2 ;;
        --health-port) HEALTH_PORT="$2"; shift 2 ;;
        --metrics-port) METRICS_PORT="$2"; shift 2 ;;
        --zpages-port) ZPAGES_PORT="$2"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        --watch) WATCH_MODE=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

HEALTH_URL="http://${HOST}:${HEALTH_PORT}"
METRICS_URL="http://${HOST}:${METRICS_PORT}/metrics"
ZPAGES_URL="http://${HOST}:${ZPAGES_PORT}"

# ============================================================================
# Health Check
# ============================================================================
check_health() {
    header "Health Check"
    local status_code
    status_code=$(curl -sf -o /dev/null -w "%{http_code}" "${HEALTH_URL}/" 2>/dev/null) || status_code="000"

    if [[ "$status_code" == "200" ]]; then
        ok "Collector is healthy (${HEALTH_URL})"
        return 0
    else
        fail "Collector unhealthy or unreachable (HTTP ${status_code} at ${HEALTH_URL})"
        return 1
    fi
}

# ============================================================================
# Pipeline Metrics
# ============================================================================
check_pipelines() {
    header "Pipeline Status"

    local metrics
    metrics=$(curl -sf "${METRICS_URL}" 2>/dev/null) || {
        fail "Cannot fetch metrics from ${METRICS_URL}"
        return 1
    }

    # --- Receiver Stats ---
    echo -e "\n${BOLD}Receivers:${NC}"
    local accepted_spans refused_spans accepted_metrics accepted_logs
    accepted_spans=$(echo "$metrics" | grep -E "^otelcol_receiver_accepted_spans_total" | head -5)
    refused_spans=$(echo "$metrics" | grep -E "^otelcol_receiver_refused_spans_total" | head -5)
    accepted_metrics=$(echo "$metrics" | grep -E "^otelcol_receiver_accepted_metric_points_total" | head -5)
    accepted_logs=$(echo "$metrics" | grep -E "^otelcol_receiver_accepted_log_records_total" | head -5)

    if [[ -n "$accepted_spans" ]]; then
        echo "  Accepted spans:"
        echo "$accepted_spans" | sed 's/^/    /'
    fi
    if [[ -n "$refused_spans" ]]; then
        local refused_count
        refused_count=$(echo "$refused_spans" | awk '{sum += $2} END {print sum+0}')
        if [[ "$refused_count" -gt 0 ]]; then
            warn "  Refused spans (backpressure): $refused_count"
            echo "$refused_spans" | sed 's/^/    /'
        fi
    fi
    if [[ -n "$accepted_metrics" ]]; then
        echo "  Accepted metric points:"
        echo "$accepted_metrics" | sed 's/^/    /'
    fi
    if [[ -n "$accepted_logs" ]]; then
        echo "  Accepted log records:"
        echo "$accepted_logs" | sed 's/^/    /'
    fi

    # --- Processor Stats ---
    echo -e "\n${BOLD}Processors:${NC}"
    local dropped_spans dropped_metrics dropped_logs
    dropped_spans=$(echo "$metrics" | grep -E "^otelcol_processor_dropped_spans_total" | head -5)
    dropped_metrics=$(echo "$metrics" | grep -E "^otelcol_processor_dropped_metric_points_total" | head -5)
    dropped_logs=$(echo "$metrics" | grep -E "^otelcol_processor_dropped_log_records_total" | head -5)

    local total_dropped=0
    if [[ -n "$dropped_spans" ]]; then
        local count
        count=$(echo "$dropped_spans" | awk '{sum += $2} END {print sum+0}')
        total_dropped=$((total_dropped + count))
        if [[ "$count" -gt 0 ]]; then
            warn "  Dropped spans: $count"
            echo "$dropped_spans" | sed 's/^/    /'
        fi
    fi
    if [[ -n "$dropped_metrics" ]]; then
        local count
        count=$(echo "$dropped_metrics" | awk '{sum += $2} END {print sum+0}')
        total_dropped=$((total_dropped + count))
        if [[ "$count" -gt 0 ]]; then
            warn "  Dropped metric points: $count"
        fi
    fi
    if [[ -n "$dropped_logs" ]]; then
        local count
        count=$(echo "$dropped_logs" | awk '{sum += $2} END {print sum+0}')
        total_dropped=$((total_dropped + count))
        if [[ "$count" -gt 0 ]]; then
            warn "  Dropped log records: $count"
        fi
    fi
    if [[ "$total_dropped" -eq 0 ]]; then
        ok "  No data dropped by processors"
    fi

    # --- Exporter Stats ---
    echo -e "\n${BOLD}Exporters:${NC}"
    local sent_spans failed_spans sent_metrics sent_logs
    sent_spans=$(echo "$metrics" | grep -E "^otelcol_exporter_sent_spans_total" | head -5)
    failed_spans=$(echo "$metrics" | grep -E "^otelcol_exporter_send_failed_spans_total" | head -5)
    sent_metrics=$(echo "$metrics" | grep -E "^otelcol_exporter_sent_metric_points_total" | head -5)
    sent_logs=$(echo "$metrics" | grep -E "^otelcol_exporter_sent_log_records_total" | head -5)

    if [[ -n "$sent_spans" ]]; then
        echo "  Sent spans:"
        echo "$sent_spans" | sed 's/^/    /'
    fi
    if [[ -n "$sent_metrics" ]]; then
        echo "  Sent metric points:"
        echo "$sent_metrics" | sed 's/^/    /'
    fi
    if [[ -n "$sent_logs" ]]; then
        echo "  Sent log records:"
        echo "$sent_logs" | sed 's/^/    /'
    fi

    # Check for failures
    if [[ -n "$failed_spans" ]]; then
        local fail_count
        fail_count=$(echo "$failed_spans" | awk '{sum += $2} END {print sum+0}')
        if [[ "$fail_count" -gt 0 ]]; then
            fail "  Export failures detected: $fail_count spans failed"
            echo "$failed_spans" | sed 's/^/    /'
        else
            ok "  No export failures"
        fi
    fi

    # --- Queue Stats ---
    echo -e "\n${BOLD}Exporter Queues:${NC}"
    local queue_size queue_capacity
    queue_size=$(echo "$metrics" | grep -E "^otelcol_exporter_queue_size{" | head -5)
    queue_capacity=$(echo "$metrics" | grep -E "^otelcol_exporter_queue_capacity{" | head -5)

    if [[ -n "$queue_size" ]]; then
        echo "  Queue size:"
        echo "$queue_size" | sed 's/^/    /'
    fi
    if [[ -n "$queue_capacity" ]]; then
        echo "  Queue capacity:"
        echo "$queue_capacity" | sed 's/^/    /'
    fi
    if [[ -z "$queue_size" && -z "$queue_capacity" ]]; then
        info "  No queue metrics (sending_queue may be disabled)"
    fi
}

# ============================================================================
# Resource Usage
# ============================================================================
check_resources() {
    header "Resource Usage"

    local metrics
    metrics=$(curl -sf "${METRICS_URL}" 2>/dev/null) || return 1

    # Process memory
    local mem_rss
    mem_rss=$(echo "$metrics" | grep -E "^process_runtime_total_alloc_bytes " | awk '{printf "%.1f MB\n", $2/1048576}')
    if [[ -n "$mem_rss" ]]; then
        echo "  Total alloc: $mem_rss"
    fi

    # Up time
    local uptime
    uptime=$(echo "$metrics" | grep -E "^otelcol_process_uptime_total " | awk '{printf "%.1f hours\n", $2/3600}')
    if [[ -n "$uptime" ]]; then
        echo "  Uptime: $uptime"
    fi

    # CPU
    local cpu
    cpu=$(echo "$metrics" | grep -E "^otelcol_process_cpu_seconds_total " | awk '{printf "%.1f seconds\n", $2}')
    if [[ -n "$cpu" ]]; then
        echo "  CPU time: $cpu"
    fi
}

# ============================================================================
# JSON Output
# ============================================================================
output_json() {
    local health="unknown"
    local status_code
    status_code=$(curl -sf -o /dev/null -w "%{http_code}" "${HEALTH_URL}/" 2>/dev/null) || status_code="000"
    [[ "$status_code" == "200" ]] && health="healthy" || health="unhealthy"

    local metrics=""
    metrics=$(curl -sf "${METRICS_URL}" 2>/dev/null) || true

    local accepted_spans=0 refused_spans=0 sent_spans=0 failed_spans=0 dropped_spans=0
    if [[ -n "$metrics" ]]; then
        accepted_spans=$(echo "$metrics" | grep -E "^otelcol_receiver_accepted_spans_total" | awk '{sum += $2} END {print sum+0}')
        refused_spans=$(echo "$metrics" | grep -E "^otelcol_receiver_refused_spans_total" | awk '{sum += $2} END {print sum+0}')
        sent_spans=$(echo "$metrics" | grep -E "^otelcol_exporter_sent_spans_total" | awk '{sum += $2} END {print sum+0}')
        failed_spans=$(echo "$metrics" | grep -E "^otelcol_exporter_send_failed_spans_total" | awk '{sum += $2} END {print sum+0}')
        dropped_spans=$(echo "$metrics" | grep -E "^otelcol_processor_dropped_spans_total" | awk '{sum += $2} END {print sum+0}')
    fi

    cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "collector": "${HOST}",
  "health": "${health}",
  "receivers": {
    "accepted_spans": ${accepted_spans},
    "refused_spans": ${refused_spans}
  },
  "processors": {
    "dropped_spans": ${dropped_spans}
  },
  "exporters": {
    "sent_spans": ${sent_spans},
    "failed_spans": ${failed_spans}
  }
}
EOF
}

# ============================================================================
# Main
# ============================================================================
run_checks() {
    if [[ "$JSON_OUTPUT" == true ]]; then
        output_json
        return
    fi

    echo -e "${BOLD}OpenTelemetry Collector Health Report${NC}"
    echo "Collector: ${HOST}"
    echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

    check_health || true
    check_pipelines || true
    check_resources || true

    header "Summary"
    echo "  Health endpoint:  ${HEALTH_URL}"
    echo "  Metrics endpoint: ${METRICS_URL}"
    echo "  zpages:           ${ZPAGES_URL}/debug/tracez"
}

if [[ "$WATCH_MODE" == true ]]; then
    while true; do
        clear
        run_checks
        echo -e "\n${BLUE}Refreshing in 10s... (Ctrl+C to stop)${NC}"
        sleep 10
    done
else
    run_checks
fi
