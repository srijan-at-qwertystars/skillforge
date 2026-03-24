#!/bin/bash
# =============================================================================
# cert-renew-monitor.sh — Certificate Expiration Monitor
# =============================================================================
#
# Usage:
#   ./cert-renew-monitor.sh                           # check domains in config
#   ./cert-renew-monitor.sh -d example.com            # check single domain
#   ./cert-renew-monitor.sh -f /path/to/domains.txt   # check domains from file
#   ./cert-renew-monitor.sh -w 30                     # warn at 30 days
#   ./cert-renew-monitor.sh -c 7                      # critical at 7 days
#   ./cert-renew-monitor.sh --renew                   # attempt renewal for expiring certs
#   ./cert-renew-monitor.sh --slack                   # send alerts to Slack
#   ./cert-renew-monitor.sh --json                    # output JSON report
#
# Environment variables:
#   SLACK_WEBHOOK_URL    — Slack incoming webhook URL for alerts
#   CERT_WARN_DAYS       — Warning threshold (default: 30)
#   CERT_CRIT_DAYS       — Critical threshold (default: 7)
#   CERT_DOMAINS_FILE    — Path to domains file (one domain:port per line)
#   CERT_RENEW_CMD       — Custom renewal command (default: certbot renew)
#
# Dependencies: openssl, curl (for Slack alerts), certbot (for renewal)
# =============================================================================

set -euo pipefail

# Defaults
WARN_DAYS="${CERT_WARN_DAYS:-30}"
CRIT_DAYS="${CERT_CRIT_DAYS:-7}"
DOMAINS_FILE="${CERT_DOMAINS_FILE:-}"
RENEW_CMD="${CERT_RENEW_CMD:-sudo certbot renew --quiet}"
SLACK_URL="${SLACK_WEBHOOK_URL:-}"
DO_RENEW=0
DO_SLACK=0
JSON_OUTPUT=0
SINGLE_DOMAIN=""
SINGLE_PORT=443
LOG_FILE="/var/log/cert-monitor.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d DOMAIN[:PORT]   Check a single domain (default port: 443)"
    echo "  -f FILE            File with domains to check (one per line, domain:port)"
    echo "  -w DAYS            Warning threshold in days (default: $WARN_DAYS)"
    echo "  -c DAYS            Critical threshold in days (default: $CRIT_DAYS)"
    echo "  --renew            Attempt certbot renewal for expiring certificates"
    echo "  --slack            Send alerts to Slack (requires SLACK_WEBHOOK_URL)"
    echo "  --json             Output results as JSON"
    echo "  -h, --help         Show this help"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -d)
            IFS=':' read -r SINGLE_DOMAIN SINGLE_PORT <<< "$2"
            SINGLE_PORT="${SINGLE_PORT:-443}"
            shift 2
            ;;
        -f) DOMAINS_FILE="$2"; shift 2 ;;
        -w) WARN_DAYS="$2"; shift 2 ;;
        -c) CRIT_DAYS="$2"; shift 2 ;;
        --renew) DO_RENEW=1; shift ;;
        --slack) DO_SLACK=1; shift ;;
        --json) JSON_OUTPUT=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

log_msg() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    if [ -w "$(dirname "$LOG_FILE")" ] 2>/dev/null; then
        echo "$msg" >> "$LOG_FILE"
    fi
    if [ "$JSON_OUTPUT" -eq 0 ]; then
        echo -e "$1"
    fi
}

send_slack() {
    local text="$1"
    local color="${2:-danger}"
    if [ "$DO_SLACK" -eq 1 ] && [ -n "$SLACK_URL" ]; then
        curl -s -X POST "$SLACK_URL" \
            -H 'Content-type: application/json' \
            -d "{
                \"attachments\": [{
                    \"color\": \"$color\",
                    \"title\": \"Certificate Monitor Alert\",
                    \"text\": \"$text\",
                    \"footer\": \"cert-renew-monitor.sh | $(hostname)\",
                    \"ts\": $(date +%s)
                }]
            }" >/dev/null 2>&1
    fi
}

check_domain() {
    local domain="$1"
    local port="${2:-443}"
    local status="ok"
    local days_left=-1
    local expiry_date=""
    local issuer=""
    local subject=""
    local error=""

    # Get certificate data
    local cert_data
    cert_data=$(echo | timeout 10 openssl s_client \
        -connect "${domain}:${port}" \
        -servername "$domain" 2>/dev/null || true)

    if [ -z "$cert_data" ] || ! echo "$cert_data" | grep -q "BEGIN CERTIFICATE"; then
        error="Connection failed"
        status="error"
    else
        expiry_date=$(echo "$cert_data" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        issuer=$(echo "$cert_data" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
        subject=$(echo "$cert_data" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')

        if [ -n "$expiry_date" ]; then
            local expiry_epoch
            expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || \
                date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry_date" +%s 2>/dev/null || echo 0)
            local now_epoch
            now_epoch=$(date +%s)
            days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

            if [ "$days_left" -lt 0 ]; then
                status="expired"
            elif [ "$days_left" -le "$CRIT_DAYS" ]; then
                status="critical"
            elif [ "$days_left" -le "$WARN_DAYS" ]; then
                status="warning"
            else
                status="ok"
            fi
        else
            error="Could not parse expiry date"
            status="error"
        fi
    fi

    # Output
    if [ "$JSON_OUTPUT" -eq 1 ]; then
        echo "{\"domain\":\"${domain}\",\"port\":${port},\"status\":\"${status}\",\"days_left\":${days_left},\"expiry\":\"${expiry_date}\",\"issuer\":\"${issuer}\",\"error\":\"${error}\"}"
    else
        case "$status" in
            ok)
                log_msg "${GREEN}[OK]${NC}       ${domain}:${port} — expires in ${days_left} days (${expiry_date})"
                ;;
            warning)
                log_msg "${YELLOW}[WARNING]${NC}  ${domain}:${port} — expires in ${days_left} days (${expiry_date})"
                send_slack "⚠️ ${domain}:${port} certificate expires in ${days_left} days (${expiry_date})" "warning"
                ;;
            critical)
                log_msg "${RED}[CRITICAL]${NC} ${domain}:${port} — expires in ${days_left} days! (${expiry_date})"
                send_slack "🚨 ${domain}:${port} certificate expires in ${days_left} days! (${expiry_date})" "danger"
                ;;
            expired)
                log_msg "${RED}[EXPIRED]${NC}  ${domain}:${port} — EXPIRED ${days_left#-} days ago (${expiry_date})"
                send_slack "💀 ${domain}:${port} certificate has EXPIRED! (${expiry_date})" "danger"
                ;;
            error)
                log_msg "${RED}[ERROR]${NC}    ${domain}:${port} — ${error}"
                send_slack "❌ ${domain}:${port} — ${error}" "danger"
                ;;
        esac
    fi

    # Attempt renewal if requested and cert is expiring
    if [ "$DO_RENEW" -eq 1 ] && [[ "$status" == "warning" || "$status" == "critical" || "$status" == "expired" ]]; then
        log_msg "  Attempting renewal for ${domain}..."
        if eval "$RENEW_CMD" --cert-name "$domain" 2>&1; then
            log_msg "${GREEN}  Renewal successful for ${domain}${NC}"
            send_slack "✅ Certificate renewed successfully for ${domain}" "good"
        else
            log_msg "${RED}  Renewal FAILED for ${domain}${NC}"
            send_slack "❌ Certificate renewal FAILED for ${domain}" "danger"
        fi
    fi

    # Return non-zero for warning/critical/error
    case "$status" in
        critical|expired|error) return 2 ;;
        warning) return 1 ;;
        *) return 0 ;;
    esac
}

# --- Main ---
EXIT_CODE=0

if [ "$JSON_OUTPUT" -eq 0 ]; then
    echo -e "${BOLD}Certificate Expiration Monitor${NC}"
    echo -e "Warning: ${WARN_DAYS} days | Critical: ${CRIT_DAYS} days"
    echo -e "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

if [ "$JSON_OUTPUT" -eq 1 ]; then
    echo "["
    FIRST=1
fi

check_one() {
    local domain="$1"
    local port="$2"
    if [ "$JSON_OUTPUT" -eq 1 ] && [ "$FIRST" -eq 0 ]; then
        echo ","
    fi
    FIRST=0
    check_domain "$domain" "$port" || {
        local rc=$?
        if [ $rc -gt $EXIT_CODE ]; then EXIT_CODE=$rc; fi
    }
}

if [ -n "$SINGLE_DOMAIN" ]; then
    check_one "$SINGLE_DOMAIN" "$SINGLE_PORT"
elif [ -n "$DOMAINS_FILE" ] && [ -f "$DOMAINS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)  # strip comments and whitespace
        [ -z "$line" ] && continue
        IFS=':' read -r domain port <<< "$line"
        port="${port:-443}"
        check_one "$domain" "$port"
    done < "$DOMAINS_FILE"
else
    # Default: check common domains (customize this list)
    DEFAULTS=(
        "localhost:443"
    )
    if [ "$JSON_OUTPUT" -eq 0 ]; then
        echo -e "${YELLOW}No domains specified. Use -d, -f, or edit the DEFAULTS array.${NC}"
        echo "Examples:"
        echo "  $0 -d example.com"
        echo "  $0 -f /etc/cert-monitor/domains.txt"
        echo ""
        echo "Domains file format (one per line):"
        echo "  example.com"
        echo "  api.example.com:8443"
        echo "  # comments are supported"
    fi
fi

if [ "$JSON_OUTPUT" -eq 1 ]; then
    echo ""
    echo "]"
fi

exit $EXIT_CODE
