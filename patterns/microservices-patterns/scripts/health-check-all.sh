#!/usr/bin/env bash
# health-check-all.sh — Check health of all microservices in a deployment
#
# Usage:
#   ./health-check-all.sh                           # Use default config
#   ./health-check-all.sh --config services.conf    # Use custom config file
#   ./health-check-all.sh --discover-k8s            # Auto-discover from Kubernetes
#   ./health-check-all.sh --discover-compose         # Auto-discover from Docker Compose
#
# Config file format (services.conf):
#   # service-name  health-url  [timeout-seconds]
#   order-service   http://localhost:8001/health/ready   5
#   payment-service http://localhost:8002/health/ready   5
#
# Output: Colorized health status table with exit code (0=all healthy, 1=failures)
#
# Requirements: curl, jq (optional, for JSON parsing)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
DEFAULT_TIMEOUT=5
DEFAULT_HEALTH_PATH="/health/ready"
CONFIG_FILE=""
DISCOVER_MODE=""
VERBOSE=false
PARALLEL=true
TOTAL=0
HEALTHY=0
UNHEALTHY=0
DEGRADED=0

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --config FILE         Path to services config file"
    echo "  --discover-k8s        Auto-discover services from Kubernetes"
    echo "  --discover-compose    Auto-discover services from Docker Compose"
    echo "  --timeout SECONDS     Default timeout per health check (default: 5)"
    echo "  --sequential          Run checks sequentially (default: parallel)"
    echo "  --verbose             Show response bodies"
    echo "  -h, --help            Show this help"
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --discover-k8s) DISCOVER_MODE="k8s"; shift ;;
        --discover-compose) DISCOVER_MODE="compose"; shift ;;
        --timeout) DEFAULT_TIMEOUT="$2"; shift 2 ;;
        --sequential) PARALLEL=false; shift ;;
        --verbose) VERBOSE=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Temporary files for parallel results
RESULTS_DIR=$(mktemp -d)
trap 'rm -rf "$RESULTS_DIR"' EXIT

check_service() {
    local name="$1"
    local url="$2"
    local timeout="${3:-$DEFAULT_TIMEOUT}"
    local result_file="$RESULTS_DIR/$name"

    local http_code
    local response
    local duration

    start_time=$(date +%s%N 2>/dev/null || date +%s)

    response=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$timeout" \
        --max-time "$timeout" \
        "$url" 2>/dev/null) || response="000"

    end_time=$(date +%s%N 2>/dev/null || date +%s)

    # Calculate duration in ms (fallback to seconds if nanoseconds unavailable)
    if [[ "$start_time" =~ ^[0-9]{10,}$ ]]; then
        duration=$(( (end_time - start_time) / 1000000 ))
    else
        duration=$(( (end_time - start_time) * 1000 ))
    fi

    local status
    local color
    case "$response" in
        200) status="HEALTHY"; color="$GREEN" ;;
        503) status="DEGRADED"; color="$YELLOW" ;;
        000) status="UNREACHABLE"; color="$RED" ;;
        *)   status="UNHEALTHY($response)"; color="$RED" ;;
    esac

    # Get response body if verbose
    local body=""
    if $VERBOSE && [ "$response" != "000" ]; then
        body=$(curl -s --connect-timeout "$timeout" --max-time "$timeout" "$url" 2>/dev/null | head -c 200)
    fi

    echo "${status}|${duration}|${body}" > "$result_file"
    printf "  %-25s %-18s %s${duration}ms${NC}\n" "$name" "${color}${status}${NC}" "${color}"
}

discover_from_k8s() {
    if ! command -v kubectl &>/dev/null; then
        echo -e "${RED}Error: kubectl not found. Install kubectl or use --config.${NC}"
        exit 1
    fi

    echo -e "${CYAN}Discovering services from Kubernetes...${NC}"
    local namespace="${KUBE_NAMESPACE:-default}"

    while IFS= read -r line; do
        local name=$(echo "$line" | awk '{print $1}')
        local cluster_ip=$(echo "$line" | awk '{print $2}')
        local ports=$(echo "$line" | awk '{print $3}')
        local port=$(echo "$ports" | cut -d'/' -f1 | cut -d',' -f1)

        if [ "$cluster_ip" != "None" ] && [ -n "$port" ]; then
            check_service "$name" "http://${cluster_ip}:${port}${DEFAULT_HEALTH_PATH}" "$DEFAULT_TIMEOUT" &
            TOTAL=$((TOTAL + 1))
        fi
    done < <(kubectl get svc -n "$namespace" --no-headers 2>/dev/null | grep -v kubernetes || true)
}

discover_from_compose() {
    local compose_file=""
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [ -f "$f" ]; then
            compose_file="$f"
            break
        fi
    done

    if [ -z "$compose_file" ]; then
        echo -e "${RED}Error: No docker-compose file found in current directory.${NC}"
        exit 1
    fi

    echo -e "${CYAN}Discovering services from $compose_file...${NC}"

    while IFS= read -r svc; do
        svc_clean=$(echo "$svc" | sed 's/://;s/^[[:space:]]*//')
        if [ -n "$svc_clean" ]; then
            # Try common ports
            for port in 8080 8081 3000 5000 8000 80; do
                url="http://localhost:${port}${DEFAULT_HEALTH_PATH}"
                if curl -s --connect-timeout 1 --max-time 1 "$url" &>/dev/null; then
                    check_service "$svc_clean" "$url" "$DEFAULT_TIMEOUT"
                    TOTAL=$((TOTAL + 1))
                    break
                fi
            done
        fi
    done < <(grep -E '^  [a-zA-Z][a-zA-Z0-9_-]+:' "$compose_file" 2>/dev/null | head -30 || true)
}

read_from_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Error: Config file '$CONFIG_FILE' not found.${NC}"
        exit 1
    fi

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue

        local name=$(echo "$line" | awk '{print $1}')
        local url=$(echo "$line" | awk '{print $2}')
        local timeout=$(echo "$line" | awk '{print $3}')
        timeout="${timeout:-$DEFAULT_TIMEOUT}"

        if [ -n "$name" ] && [ -n "$url" ]; then
            if $PARALLEL; then
                check_service "$name" "$url" "$timeout" &
            else
                check_service "$name" "$url" "$timeout"
            fi
            TOTAL=$((TOTAL + 1))
        fi
    done < "$CONFIG_FILE"
}

# --- Main ---
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           MICROSERVICES HEALTH CHECK                        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""
printf "  ${BOLD}%-25s %-18s %s${NC}\n" "SERVICE" "STATUS" "LATENCY"
echo "  ─────────────────────────────────────────────────────────"

if [ -n "$DISCOVER_MODE" ]; then
    case "$DISCOVER_MODE" in
        k8s) discover_from_k8s ;;
        compose) discover_from_compose ;;
    esac
elif [ -n "$CONFIG_FILE" ]; then
    read_from_config
else
    # Default: check common local development ports
    DEFAULT_SERVICES=(
        "api-gateway|http://localhost:8080${DEFAULT_HEALTH_PATH}"
        "order-service|http://localhost:8081${DEFAULT_HEALTH_PATH}"
        "payment-service|http://localhost:8082${DEFAULT_HEALTH_PATH}"
        "inventory-service|http://localhost:8083${DEFAULT_HEALTH_PATH}"
        "notification-service|http://localhost:8084${DEFAULT_HEALTH_PATH}"
        "user-service|http://localhost:8085${DEFAULT_HEALTH_PATH}"
    )

    for entry in "${DEFAULT_SERVICES[@]}"; do
        IFS='|' read -r name url <<< "$entry"
        if $PARALLEL; then
            check_service "$name" "$url" "$DEFAULT_TIMEOUT" &
        else
            check_service "$name" "$url" "$DEFAULT_TIMEOUT"
        fi
        TOTAL=$((TOTAL + 1))
    done
fi

# Wait for parallel checks
$PARALLEL && wait

# Tally results
for f in "$RESULTS_DIR"/*; do
    [ -f "$f" ] || continue
    status=$(head -1 "$f" | cut -d'|' -f1)
    case "$status" in
        HEALTHY) HEALTHY=$((HEALTHY + 1)) ;;
        DEGRADED) DEGRADED=$((DEGRADED + 1)) ;;
        *) UNHEALTHY=$((UNHEALTHY + 1)) ;;
    esac
done

# Summary
echo ""
echo "  ─────────────────────────────────────────────────────────"
echo -e "  ${BOLD}Total:${NC} $TOTAL  ${GREEN}Healthy: $HEALTHY${NC}  ${YELLOW}Degraded: $DEGRADED${NC}  ${RED}Unhealthy: $UNHEALTHY${NC}"
echo ""

if [ "$UNHEALTHY" -gt 0 ]; then
    echo -e "  ${RED}⚠ Some services are unhealthy!${NC}"
    exit 1
elif [ "$DEGRADED" -gt 0 ]; then
    echo -e "  ${YELLOW}⚡ Some services are degraded.${NC}"
    exit 0
else
    echo -e "  ${GREEN}✓ All services healthy.${NC}"
    exit 0
fi
