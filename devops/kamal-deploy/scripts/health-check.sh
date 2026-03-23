#!/usr/bin/env bash
#
# health-check.sh — Verify all Kamal-managed services are healthy
#
# Usage:
#   ./health-check.sh [options]
#
# Options:
#   -c, --config <path>    Path to deploy.yml (default: config/deploy.yml)
#   -d, --destination <d>  Kamal destination (staging, production)
#   -v, --verbose          Show detailed output
#   -q, --quiet            Only output on failure (for cron)
#   -h, --help             Show this help message
#
# Checks performed:
#   1. App containers running and healthy
#   2. kamal-proxy running and responsive
#   3. Accessories (DB, Redis, etc.) running
#   4. SSL certificate validity and expiry
#   5. Disk space on servers
#   6. Health endpoint returning 200

set -euo pipefail

# --- Defaults ---
CONFIG="config/deploy.yml"
DESTINATION=""
VERBOSE=false
QUIET=false
EXIT_CODE=0

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)      CONFIG="$2"; shift 2 ;;
        -d|--destination)  DESTINATION="$2"; shift 2 ;;
        -v|--verbose)      VERBOSE=true; shift ;;
        -q|--quiet)        QUIET=true; shift ;;
        -h|--help)
            head -20 "$0" | tail -16
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

DEST_FLAG=""
[[ -n "$DESTINATION" ]] && DEST_FLAG="-d $DESTINATION"

# --- Output helpers ---
pass()  { $QUIET || echo -e "  ${GREEN}✓${NC} $*"; }
fail()  { echo -e "  ${RED}✗${NC} $*"; EXIT_CODE=1; }
warn()  { $QUIET || echo -e "  ${YELLOW}!${NC} $*"; }
header(){ $QUIET || echo -e "\n${BLUE}[$1]${NC}"; }

$QUIET || echo "============================================"
$QUIET || echo " Kamal Health Check"
$QUIET || echo " $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
$QUIET || echo "============================================"

# --- Check 1: Kamal CLI available ---
header "Prerequisites"
if command -v kamal &>/dev/null; then
    pass "Kamal CLI: $(kamal version 2>/dev/null || echo 'installed')"
else
    fail "Kamal CLI not found — install with: gem install kamal"
    exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
    fail "Config not found: $CONFIG"
    exit 1
fi
pass "Config: $CONFIG"

# --- Check 2: App containers ---
header "App Containers"
APP_DETAILS=$(kamal app details $DEST_FLAG 2>&1) || true

if echo "$APP_DETAILS" | grep -q "running"; then
    RUNNING_COUNT=$(echo "$APP_DETAILS" | grep -c "running" || true)
    pass "Running containers: $RUNNING_COUNT"

    if $VERBOSE; then
        echo "$APP_DETAILS" | grep "running" | while read -r line; do
            echo "    $line"
        done
    fi
else
    fail "No running app containers found"
    if $VERBOSE; then
        echo "    Details: $APP_DETAILS"
    fi
fi

# --- Check 3: kamal-proxy ---
header "kamal-proxy"
PROXY_DETAILS=$(kamal proxy details $DEST_FLAG 2>&1) || true

if echo "$PROXY_DETAILS" | grep -qi "running\|healthy\|kamal-proxy"; then
    pass "kamal-proxy is running"

    if $VERBOSE; then
        echo "$PROXY_DETAILS" | head -10 | while read -r line; do
            echo "    $line"
        done
    fi
else
    fail "kamal-proxy may not be running"
fi

# --- Check 4: Accessories ---
header "Accessories"
ACC_DETAILS=$(kamal accessory details $DEST_FLAG 2>&1) || ACC_DETAILS=""

if [[ -z "$ACC_DETAILS" ]] || echo "$ACC_DETAILS" | grep -qi "no accessories"; then
    warn "No accessories configured"
else
    while IFS= read -r acc_name; do
        [[ -z "$acc_name" ]] && continue
        ACC_STATUS=$(kamal accessory details "$acc_name" $DEST_FLAG 2>&1) || true
        if echo "$ACC_STATUS" | grep -qi "running"; then
            pass "Accessory '$acc_name': running"
        else
            fail "Accessory '$acc_name': not running"
        fi
    done < <(grep -oP "^\s*\K\w+(?=:)" "$CONFIG" 2>/dev/null | head -10 || echo "")

    # Fallback: check accessory containers directly
    if $VERBOSE; then
        echo "    Raw details:"
        echo "$ACC_DETAILS" | head -20 | while read -r line; do
            echo "    $line"
        done
    fi
fi

# --- Check 5: SSL Certificate ---
header "SSL Certificate"
# Extract host from deploy.yml
APP_HOST=$(grep -A5 "^proxy:" "$CONFIG" | grep -oP "host:\s*\K\S+" | head -1 || true)

if [[ -n "$APP_HOST" ]]; then
    CERT_INFO=$(echo | openssl s_client -connect "${APP_HOST}:443" -servername "$APP_HOST" 2>/dev/null | \
        openssl x509 -noout -dates -subject 2>/dev/null) || CERT_INFO=""

    if [[ -n "$CERT_INFO" ]]; then
        EXPIRY=$(echo "$CERT_INFO" | grep "notAfter" | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

        if [[ $DAYS_LEFT -gt 30 ]]; then
            pass "SSL cert valid, expires in ${DAYS_LEFT} days ($EXPIRY)"
        elif [[ $DAYS_LEFT -gt 7 ]]; then
            warn "SSL cert expires in ${DAYS_LEFT} days ($EXPIRY)"
        elif [[ $DAYS_LEFT -gt 0 ]]; then
            fail "SSL cert expires in ${DAYS_LEFT} days — renewal needed!"
        else
            fail "SSL cert has EXPIRED ($EXPIRY)"
        fi
    else
        warn "Could not retrieve SSL certificate for $APP_HOST"
    fi
else
    warn "No proxy host found in config — skipping SSL check"
fi

# --- Check 6: Health Endpoint ---
header "Health Endpoint"
HEALTH_PATH=$(grep -A10 "healthcheck:" "$CONFIG" | grep -oP "path:\s*\K\S+" | head -1 || echo "/up")

if [[ -n "$APP_HOST" ]]; then
    HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "https://${APP_HOST}${HEALTH_PATH}" 2>/dev/null) || HTTP_STATUS="000"

    if [[ "$HTTP_STATUS" == "200" ]]; then
        pass "https://${APP_HOST}${HEALTH_PATH} → HTTP $HTTP_STATUS"
    else
        fail "https://${APP_HOST}${HEALTH_PATH} → HTTP $HTTP_STATUS (expected 200)"
    fi
else
    warn "No host configured — skipping endpoint check"
fi

# --- Check 7: Disk Space ---
header "Disk Space"
DISK_OUTPUT=$(kamal server exec "df -h / | tail -1" $DEST_FLAG 2>&1) || DISK_OUTPUT=""

if [[ -n "$DISK_OUTPUT" ]]; then
    echo "$DISK_OUTPUT" | while read -r line; do
        USE_PCT=$(echo "$line" | grep -oP "\d+%" | head -1 || echo "")
        if [[ -n "$USE_PCT" ]]; then
            USE_NUM=${USE_PCT%\%}
            if [[ $USE_NUM -lt 80 ]]; then
                pass "Disk usage: $USE_PCT"
            elif [[ $USE_NUM -lt 90 ]]; then
                warn "Disk usage: $USE_PCT — consider cleanup"
            else
                fail "Disk usage: $USE_PCT — critical!"
            fi
        fi
    done
else
    warn "Could not check disk space"
fi

# Docker disk usage
if $VERBOSE; then
    echo ""
    echo "  Docker disk usage:"
    kamal server exec "docker system df" $DEST_FLAG 2>&1 | while read -r line; do
        echo "    $line"
    done
fi

# --- Summary ---
$QUIET || echo ""
$QUIET || echo "============================================"
if [[ $EXIT_CODE -eq 0 ]]; then
    $QUIET || echo -e " ${GREEN}All checks passed${NC}"
else
    echo -e " ${RED}Some checks failed${NC} — review above"
fi
$QUIET || echo "============================================"

exit $EXIT_CODE
