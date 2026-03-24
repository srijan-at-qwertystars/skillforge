#!/usr/bin/env bash
# lb-health-check.sh — Load balancer health verification script
# Tests all backends, measures response times, checks distribution.
#
# Usage:
#   ./lb-health-check.sh -l <lb_url> -b <backend1,backend2,...> [-n <num_requests>] [-t <timeout>]
#   ./lb-health-check.sh -l http://lb.example.com -b 10.0.1.10:8080,10.0.1.11:8080 -n 100
#   ./lb-health-check.sh -l http://lb.example.com -H /healthz    # custom health path
#
# Options:
#   -l  Load balancer URL (required)
#   -b  Comma-separated list of backend addresses (host:port) (required)
#   -n  Number of requests for distribution test (default: 50)
#   -t  Timeout in seconds per request (default: 5)
#   -H  Health check path (default: /healthz)
#   -v  Verbose output
#   -h  Show help

set -euo pipefail

# --- Defaults ---
NUM_REQUESTS=50
TIMEOUT=5
HEALTH_PATH="/healthz"
VERBOSE=false
LB_URL=""
BACKENDS=""

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \?//'
    exit 0
}

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_debug() { [[ "$VERBOSE" == "true" ]] && echo -e "[DEBUG] $*" || true; }

# --- Parse arguments ---
while getopts "l:b:n:t:H:vh" opt; do
    case "$opt" in
        l) LB_URL="$OPTARG" ;;
        b) BACKENDS="$OPTARG" ;;
        n) NUM_REQUESTS="$OPTARG" ;;
        t) TIMEOUT="$OPTARG" ;;
        H) HEALTH_PATH="$OPTARG" ;;
        v) VERBOSE=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$LB_URL" || -z "$BACKENDS" ]]; then
    echo "Error: -l (load balancer URL) and -b (backends) are required."
    echo "Run with -h for usage."
    exit 1
fi

IFS=',' read -ra BACKEND_LIST <<< "$BACKENDS"

echo "============================================"
echo "  Load Balancer Health Check"
echo "============================================"
echo "  LB URL:       $LB_URL"
echo "  Backends:     ${#BACKEND_LIST[@]}"
echo "  Requests:     $NUM_REQUESTS"
echo "  Timeout:      ${TIMEOUT}s"
echo "  Health path:  $HEALTH_PATH"
echo "============================================"
echo

OVERALL_STATUS=0

# -----------------------------------------------
# Phase 1: Direct Backend Health Checks
# -----------------------------------------------
echo "--- Phase 1: Direct Backend Health Checks ---"
echo

for backend in "${BACKEND_LIST[@]}"; do
    backend=$(echo "$backend" | xargs)  # trim whitespace
    log_info "Checking backend: $backend"

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        "http://${backend}${HEALTH_PATH}" 2>/dev/null) || HTTP_CODE="000"

    RESPONSE_TIME=$(curl -s -o /dev/null -w "%{time_total}" \
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        "http://${backend}${HEALTH_PATH}" 2>/dev/null) || RESPONSE_TIME="N/A"

    if [[ "$HTTP_CODE" == "200" ]]; then
        log_ok "$backend — HTTP $HTTP_CODE (${RESPONSE_TIME}s)"
    elif [[ "$HTTP_CODE" == "000" ]]; then
        log_fail "$backend — Connection failed (unreachable or timeout)"
        OVERALL_STATUS=1
    else
        log_warn "$backend — HTTP $HTTP_CODE (${RESPONSE_TIME}s)"
        OVERALL_STATUS=1
    fi
done

echo

# -----------------------------------------------
# Phase 2: Load Balancer Endpoint Check
# -----------------------------------------------
echo "--- Phase 2: Load Balancer Endpoint Check ---"
echo

log_info "Testing LB endpoint: $LB_URL"

LB_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    "$LB_URL" 2>/dev/null) || LB_CODE="000"

LB_TIME=$(curl -s -o /dev/null -w "%{time_total}" \
    --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    "$LB_URL" 2>/dev/null) || LB_TIME="N/A"

if [[ "$LB_CODE" =~ ^2[0-9]{2}$ ]]; then
    log_ok "LB responding — HTTP $LB_CODE (${LB_TIME}s)"
elif [[ "$LB_CODE" == "000" ]]; then
    log_fail "LB unreachable"
    OVERALL_STATUS=1
else
    log_warn "LB returned HTTP $LB_CODE (${LB_TIME}s)"
    OVERALL_STATUS=1
fi

# TLS check if HTTPS
if [[ "$LB_URL" == https://* ]]; then
    echo
    log_info "Checking TLS certificate..."
    CERT_INFO=$(echo | openssl s_client -connect "${LB_URL#https://}:443" -servername "${LB_URL#https://}" 2>/dev/null | \
        openssl x509 -noout -dates 2>/dev/null) || CERT_INFO=""

    if [[ -n "$CERT_INFO" ]]; then
        EXPIRY=$(echo "$CERT_INFO" | grep "notAfter" | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo "0")
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

        if (( DAYS_LEFT > 30 )); then
            log_ok "TLS certificate valid for $DAYS_LEFT days (expires: $EXPIRY)"
        elif (( DAYS_LEFT > 0 )); then
            log_warn "TLS certificate expires in $DAYS_LEFT days! (expires: $EXPIRY)"
        else
            log_fail "TLS certificate EXPIRED! (expired: $EXPIRY)"
            OVERALL_STATUS=1
        fi
    else
        log_warn "Could not retrieve TLS certificate info"
    fi
fi

echo

# -----------------------------------------------
# Phase 3: Response Time Analysis
# -----------------------------------------------
echo "--- Phase 3: Response Time Analysis ---"
echo

TIMES_FILE=$(mktemp)
trap 'rm -f "$TIMES_FILE"' EXIT

log_info "Sending $NUM_REQUESTS requests to $LB_URL ..."

for i in $(seq 1 "$NUM_REQUESTS"); do
    TIME=$(curl -s -o /dev/null -w "%{time_total}" \
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        "$LB_URL" 2>/dev/null) || TIME="0"
    echo "$TIME" >> "$TIMES_FILE"
    log_debug "Request $i: ${TIME}s"
done

# Calculate percentiles
SORTED_TIMES=$(sort -n "$TIMES_FILE")
TOTAL=$(wc -l < "$TIMES_FILE")

p50_idx=$(( TOTAL * 50 / 100 ))
p90_idx=$(( TOTAL * 90 / 100 ))
p99_idx=$(( TOTAL * 99 / 100 ))
[[ $p50_idx -lt 1 ]] && p50_idx=1
[[ $p90_idx -lt 1 ]] && p90_idx=1
[[ $p99_idx -lt 1 ]] && p99_idx=1

P50=$(echo "$SORTED_TIMES" | sed -n "${p50_idx}p")
P90=$(echo "$SORTED_TIMES" | sed -n "${p90_idx}p")
P99=$(echo "$SORTED_TIMES" | sed -n "${p99_idx}p")
MIN=$(echo "$SORTED_TIMES" | head -1)
MAX=$(echo "$SORTED_TIMES" | tail -1)
AVG=$(awk '{sum += $1; count++} END {printf "%.3f", sum/count}' "$TIMES_FILE")

echo "  Requests sent:  $TOTAL"
echo "  Min:            ${MIN}s"
echo "  Avg:            ${AVG}s"
echo "  p50:            ${P50}s"
echo "  p90:            ${P90}s"
echo "  p99:            ${P99}s"
echo "  Max:            ${MAX}s"

# Alert on high latency
if (( $(echo "$P99 > 2.0" | bc -l 2>/dev/null || echo 0) )); then
    log_warn "p99 latency > 2s — possible backend performance issue"
fi

echo

# -----------------------------------------------
# Phase 4: Distribution Check
# -----------------------------------------------
echo "--- Phase 4: Distribution Check ---"
echo

log_info "Checking request distribution across backends..."
log_info "(Requires backend to return identifying header, e.g., X-Backend-Server)"

DIST_FILE=$(mktemp)
trap 'rm -f "$TIMES_FILE" "$DIST_FILE"' EXIT

for i in $(seq 1 "$NUM_REQUESTS"); do
    BACKEND_ID=$(curl -s -D - -o /dev/null \
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        "$LB_URL" 2>/dev/null | grep -i "x-backend-server\|x-served-by\|x-upstream" | \
        head -1 | cut -d: -f2 | xargs) || BACKEND_ID="unknown"
    echo "${BACKEND_ID:-unknown}" >> "$DIST_FILE"
done

UNIQUE_BACKENDS=$(sort "$DIST_FILE" | uniq -c | sort -rn)
NUM_UNIQUE=$(echo "$UNIQUE_BACKENDS" | grep -cv "^$" 2>/dev/null || echo 0)

if [[ "$NUM_UNIQUE" -gt 1 ]]; then
    log_ok "Traffic distributed across $NUM_UNIQUE backends:"
    echo "$UNIQUE_BACKENDS" | while read -r count backend; do
        PCT=$(( count * 100 / NUM_REQUESTS ))
        echo "    $backend: $count requests ($PCT%)"
    done
elif [[ "$NUM_UNIQUE" -eq 1 ]]; then
    FIRST_BACKEND=$(echo "$UNIQUE_BACKENDS" | awk '{print $2}')
    if [[ "$FIRST_BACKEND" == "unknown" ]]; then
        log_warn "No backend identification header found."
        echo "    Add 'X-Backend-Server' header to backend responses for distribution tracking."
    else
        log_warn "All requests went to a single backend: $FIRST_BACKEND"
        echo "    This may indicate sticky sessions, only one healthy backend, or L4 balancing."
    fi
else
    log_warn "Could not determine distribution. Add backend identification headers."
fi

echo
echo "============================================"
if [[ "$OVERALL_STATUS" -eq 0 ]]; then
    log_ok "All checks passed"
else
    log_fail "Some checks failed — review output above"
fi
echo "============================================"

exit "$OVERALL_STATUS"
