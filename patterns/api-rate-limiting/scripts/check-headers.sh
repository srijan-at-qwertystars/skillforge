#!/usr/bin/env bash
# check-headers.sh — Audit API responses for proper rate limit headers
#
# Usage:
#   ./check-headers.sh <url>                     Check a single URL
#   ./check-headers.sh <url> --verbose            Show all response headers
#   ./check-headers.sh <url> --trigger-429        Send requests until 429, then verify headers
#   ./check-headers.sh <url> --full-audit         Complete audit: normal + 429 + retry-after
#   ./check-headers.sh --help                     Show this help
#
# Requirements: curl, bash 4+
#
# Environment:
#   API_KEY         API key to send in X-API-Key header (optional)
#   AUTH_TOKEN      Bearer token for Authorization header (optional)
#   MAX_REQUESTS    Max requests for --trigger-429 (default: 500)

set -euo pipefail

MAX_REQUESTS="${MAX_REQUESTS:-500}"
PASS="✓"
FAIL="✗"
WARN="⚠"

# Colors (if terminal supports it)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' BLUE='' NC=''
fi

pass() { echo -e "  ${GREEN}${PASS}${NC} $1"; }
fail() { echo -e "  ${RED}${FAIL}${NC} $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}${WARN}${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
info() { echo -e "  ${BLUE}→${NC} $1"; }

FAILURES=0
WARNINGS=0

# Build curl auth args
build_auth_args() {
    local args=()
    if [[ -n "${API_KEY:-}" ]]; then
        args+=(-H "X-API-Key: $API_KEY")
    fi
    if [[ -n "${AUTH_TOKEN:-}" ]]; then
        args+=(-H "Authorization: Bearer $AUTH_TOKEN")
    fi
    echo "${args[@]}"
}

# Fetch headers from URL
fetch_headers() {
    local url="$1"
    local auth_args
    auth_args=$(build_auth_args)
    # shellcheck disable=SC2086
    curl -sS -D - -o /dev/null --max-time 10 $auth_args "$url" 2>/dev/null
}

# Extract header value (case-insensitive)
get_header() {
    local headers="$1"
    local name="$2"
    echo "$headers" | grep -i "^${name}:" | head -1 | sed 's/^[^:]*: *//' | tr -d '\r\n'
}

# Check standard rate limit headers
check_standard_headers() {
    local url="$1"
    local headers
    headers=$(fetch_headers "$url")
    local status
    status=$(echo "$headers" | head -1 | grep -oP '\d{3}' | head -1)

    echo ""
    echo "=== Rate Limit Header Audit: $url ==="
    echo "HTTP Status: $status"
    echo ""

    echo "--- Standard Headers (IETF draft-ietf-httpapi-ratelimit-headers) ---"

    local rl_limit rl_remaining rl_reset
    rl_limit=$(get_header "$headers" "RateLimit-Limit")
    rl_remaining=$(get_header "$headers" "RateLimit-Remaining")
    rl_reset=$(get_header "$headers" "RateLimit-Reset")

    if [[ -n "$rl_limit" ]]; then
        pass "RateLimit-Limit: $rl_limit"
    else
        fail "RateLimit-Limit header missing"
    fi

    if [[ -n "$rl_remaining" ]]; then
        pass "RateLimit-Remaining: $rl_remaining"
        # Sanity check: remaining should be <= limit
        if [[ -n "$rl_limit" ]] && [[ "$rl_remaining" -gt "$rl_limit" ]] 2>/dev/null; then
            warn "RateLimit-Remaining ($rl_remaining) > RateLimit-Limit ($rl_limit)"
        fi
    else
        fail "RateLimit-Remaining header missing"
    fi

    if [[ -n "$rl_reset" ]]; then
        pass "RateLimit-Reset: $rl_reset"
        # Check if it's seconds (integer) not HTTP-date
        if [[ "$rl_reset" =~ ^[0-9]+$ ]]; then
            pass "RateLimit-Reset uses seconds format (correct)"
        else
            warn "RateLimit-Reset uses non-integer format — prefer seconds (integer)"
        fi
    else
        fail "RateLimit-Reset header missing"
    fi

    echo ""
    echo "--- Legacy Headers ---"

    local x_limit x_remaining x_reset
    x_limit=$(get_header "$headers" "X-RateLimit-Limit")
    x_remaining=$(get_header "$headers" "X-RateLimit-Remaining")
    x_reset=$(get_header "$headers" "X-RateLimit-Reset")

    if [[ -n "$x_limit" ]]; then
        pass "X-RateLimit-Limit: $x_limit (legacy)"
    else
        warn "X-RateLimit-Limit missing (legacy compat — optional)"
    fi

    if [[ -n "$x_remaining" ]]; then
        pass "X-RateLimit-Remaining: $x_remaining (legacy)"
    else
        warn "X-RateLimit-Remaining missing (legacy compat — optional)"
    fi

    if [[ -n "$x_reset" ]]; then
        pass "X-RateLimit-Reset: $x_reset (legacy)"
        # Check if it's Unix epoch (common legacy format) vs seconds
        if [[ "$x_reset" -gt 1000000000 ]] 2>/dev/null; then
            info "X-RateLimit-Reset appears to use Unix epoch format"
        fi
    fi

    echo ""
    echo "--- 429-Specific Headers ---"

    if [[ "$status" == "429" ]]; then
        local retry_after
        retry_after=$(get_header "$headers" "Retry-After")
        if [[ -n "$retry_after" ]]; then
            pass "Retry-After: $retry_after"
            if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
                pass "Retry-After uses seconds format (preferred)"
            else
                warn "Retry-After uses HTTP-date format — prefer seconds for machine parsing"
            fi
        else
            fail "Retry-After header missing on 429 response (RFC 6585)"
        fi

        # Check response body
        local body
        body=$(curl -sS --max-time 10 $(build_auth_args) "$url" 2>/dev/null)
        if echo "$body" | grep -qi '"error"'; then
            pass "Response body includes error field"
        else
            warn "429 response body should include error details"
        fi
        if echo "$body" | grep -qi 'retry_after\|retry-after'; then
            pass "Response body includes retry_after field"
        fi
    else
        info "Not a 429 response — Retry-After check skipped"
        info "Use --trigger-429 to test 429 behavior"
    fi
}

# Send requests until 429, then check headers
trigger_429() {
    local url="$1"
    echo ""
    echo "=== Triggering 429 Response ==="
    echo "Sending up to $MAX_REQUESTS requests to $url..."

    local auth_args
    auth_args=$(build_auth_args)
    local got_429=false
    local count=0

    for i in $(seq 1 "$MAX_REQUESTS"); do
        local status
        # shellcheck disable=SC2086
        status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 $auth_args "$url" 2>/dev/null)
        count=$i

        if [[ "$status" == "429" ]]; then
            got_429=true
            echo "  Got 429 after $count requests"
            echo ""
            break
        fi

        # Progress indicator every 50 requests
        if (( i % 50 == 0 )); then
            echo "  Sent $i requests (last status: $status)..."
        fi
    done

    if $got_429; then
        echo "--- Checking 429 Response Headers ---"
        # shellcheck disable=SC2086
        local headers
        headers=$(curl -sS -D - -o /dev/null --max-time 5 $auth_args "$url" 2>/dev/null)
        local retry_after
        retry_after=$(get_header "$headers" "Retry-After")
        local rl_remaining
        rl_remaining=$(get_header "$headers" "RateLimit-Remaining")

        if [[ -n "$retry_after" ]]; then
            pass "Retry-After present on 429: $retry_after"
        else
            fail "Retry-After missing on 429 response"
        fi

        if [[ "$rl_remaining" == "0" ]]; then
            pass "RateLimit-Remaining is 0 on 429"
        elif [[ -n "$rl_remaining" ]]; then
            warn "RateLimit-Remaining is $rl_remaining (expected 0 on 429)"
        fi
    else
        warn "Could not trigger 429 after $MAX_REQUESTS requests"
        info "The endpoint may have high limits, or rate limiting may not be configured"
    fi
}

# Show all headers
show_verbose() {
    local url="$1"
    echo ""
    echo "=== All Response Headers ==="
    local headers
    headers=$(fetch_headers "$url")
    echo "$headers" | head -20
}

# Full audit
full_audit() {
    local url="$1"
    check_standard_headers "$url"
    trigger_429 "$url"
    echo ""
    echo "=========================================="
    echo " Audit Summary"
    echo "=========================================="
    echo "  Failures: $FAILURES"
    echo "  Warnings: $WARNINGS"
    if [[ $FAILURES -eq 0 ]]; then
        echo -e "  ${GREEN}Overall: PASS${NC}"
    else
        echo -e "  ${RED}Overall: FAIL${NC}"
    fi
}

# --- Main ---

case "${1:-}" in
    --help|-h|"")
        echo "Usage: $0 <url> [--verbose|--trigger-429|--full-audit]"
        echo ""
        echo "Audits API responses for proper rate limit headers."
        echo ""
        echo "Options:"
        echo "  --verbose      Show all response headers"
        echo "  --trigger-429  Send requests until 429, verify Retry-After"
        echo "  --full-audit   Complete check: standard + 429 + body"
        echo ""
        echo "Environment:"
        echo "  API_KEY=...     Send X-API-Key header"
        echo "  AUTH_TOKEN=...  Send Authorization: Bearer header"
        echo "  MAX_REQUESTS=500  Max requests for --trigger-429"
        echo ""
        echo "Examples:"
        echo "  $0 https://api.example.com/v1/users"
        echo "  API_KEY=sk-xxx $0 https://api.example.com/v1/users --full-audit"
        exit 0
        ;;
    *)
        url="$1"
        shift
        case "${1:-}" in
            --verbose)      check_standard_headers "$url"; show_verbose "$url" ;;
            --trigger-429)  trigger_429 "$url" ;;
            --full-audit)   full_audit "$url" ;;
            *)              check_standard_headers "$url" ;;
        esac
        ;;
esac

echo ""
if [[ $FAILURES -gt 0 ]]; then
    exit 1
fi
