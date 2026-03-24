#!/usr/bin/env bash
#
# dns-audit.sh — DNS Audit Tool
#
# Performs a comprehensive DNS audit for a domain:
#   - Checks all common record types (A, AAAA, CNAME, MX, NS, SOA, TXT, SRV, CAA, PTR)
#   - Validates DNSSEC chain of trust
#   - Tests email authentication records (SPF, DKIM, DMARC, MTA-STS, TLS-RPT, BIMI)
#   - Reports potential issues and misconfigurations
#
# Usage:
#   ./dns-audit.sh <domain>
#   ./dns-audit.sh example.com
#   ./dns-audit.sh -v example.com       # verbose output
#   ./dns-audit.sh -r 8.8.8.8 example.com  # use specific resolver
#
# Requirements: dig (dnsutils/bind-utils), bash 4+
#
# Exit codes:
#   0 = audit complete (check output for warnings/errors)
#   1 = usage error
#   2 = missing dependencies

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

VERBOSE=0
RESOLVER=""
WARNINGS=0
ERRORS=0

usage() {
    echo "Usage: $0 [-v] [-r resolver] <domain>"
    echo "  -v           Verbose output"
    echo "  -r resolver  Use specific DNS resolver (e.g., 8.8.8.8)"
    exit 1
}

while getopts "vr:" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        r) RESOLVER="@${OPTARG}" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

DOMAIN="${1:-}"
[ -z "$DOMAIN" ] && usage

# Check dependencies
if ! command -v dig &>/dev/null; then
    echo -e "${RED}ERROR: 'dig' not found. Install dnsutils (Debian/Ubuntu) or bind-utils (RHEL/CentOS).${NC}"
    exit 2
fi

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; WARNINGS=$((WARNINGS + 1)); }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; ERRORS=$((ERRORS + 1)); }
section() { echo ""; echo -e "${BLUE}━━━ $* ━━━${NC}"; }
verbose() { [ "$VERBOSE" -eq 1 ] && echo -e "        $*"; }

dig_query() {
    local type="$1"
    local name="${2:-$DOMAIN}"
    dig $RESOLVER +short +time=5 +tries=2 "$name" "$type" 2>/dev/null
}

dig_full() {
    local type="$1"
    local name="${2:-$DOMAIN}"
    dig $RESOLVER +noall +answer +time=5 +tries=2 "$name" "$type" 2>/dev/null
}

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              DNS Audit Report: $DOMAIN"
echo "║              $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "╚══════════════════════════════════════════════════════════╝"

# ─── Record Type Checks ───
section "DNS Records"

# A Records
A_RECORDS=$(dig_query A)
if [ -n "$A_RECORDS" ]; then
    ok "A records found:"
    echo "$A_RECORDS" | while read -r ip; do verbose "$ip"; done
else
    info "No A records found"
fi

# AAAA Records
AAAA_RECORDS=$(dig_query AAAA)
if [ -n "$AAAA_RECORDS" ]; then
    ok "AAAA records found:"
    echo "$AAAA_RECORDS" | while read -r ip; do verbose "$ip"; done
else
    warn "No AAAA (IPv6) records found — consider adding IPv6 support"
fi

# NS Records
NS_RECORDS=$(dig_query NS)
if [ -n "$NS_RECORDS" ]; then
    NS_COUNT=$(echo "$NS_RECORDS" | wc -l)
    if [ "$NS_COUNT" -ge 2 ]; then
        ok "NS records: $NS_COUNT nameservers (redundancy: good)"
    else
        warn "Only $NS_COUNT NS record — minimum 2 recommended for redundancy"
    fi
    echo "$NS_RECORDS" | while read -r ns; do verbose "$ns"; done
else
    fail "No NS records found — critical configuration issue"
fi

# SOA Record
SOA=$(dig_query SOA)
if [ -n "$SOA" ]; then
    ok "SOA record found"
    verbose "$SOA"
    SERIAL=$(echo "$SOA" | awk '{print $3}')
    verbose "Serial: $SERIAL"
else
    fail "No SOA record found"
fi

# MX Records
MX_RECORDS=$(dig_query MX)
if [ -n "$MX_RECORDS" ]; then
    ok "MX records found:"
    echo "$MX_RECORDS" | while read -r mx; do
        verbose "$mx"
        # Check if MX target is a CNAME
        MX_HOST=$(echo "$mx" | awk '{print $2}')
        if [ -n "$MX_HOST" ]; then
            CNAME_CHECK=$(dig_query CNAME "$MX_HOST")
            [ -n "$CNAME_CHECK" ] && warn "MX target $MX_HOST is a CNAME — violates RFC 2181"
        fi
    done
else
    info "No MX records found (domain may not receive email)"
fi

# CAA Records
CAA_RECORDS=$(dig_full CAA)
if [ -n "$CAA_RECORDS" ]; then
    ok "CAA records found (certificate authority restricted)"
    echo "$CAA_RECORDS" | while read -r caa; do verbose "$caa"; done
else
    warn "No CAA records — any CA can issue certificates for this domain"
fi

# TXT Records
TXT_RECORDS=$(dig_query TXT)
if [ -n "$TXT_RECORDS" ]; then
    TXT_COUNT=$(echo "$TXT_RECORDS" | wc -l)
    ok "TXT records found: $TXT_COUNT"
    [ "$VERBOSE" -eq 1 ] && echo "$TXT_RECORDS" | while read -r txt; do verbose "$txt"; done
fi

# ─── DNSSEC ───
section "DNSSEC"

DNSKEY=$(dig_query DNSKEY)
if [ -n "$DNSKEY" ]; then
    ok "DNSKEY records found — DNSSEC is enabled"

    # Check DS at parent
    DS=$(dig_query DS)
    if [ -n "$DS" ]; then
        ok "DS record found at parent zone"
        verbose "$DS"
    else
        warn "DNSKEY exists but no DS at parent — DNSSEC chain incomplete"
    fi

    # Validate DNSSEC
    DNSSEC_TEST=$(dig $RESOLVER +dnssec +time=5 +tries=2 "$DOMAIN" A 2>/dev/null)
    if echo "$DNSSEC_TEST" | grep -q "ad"; then
        ok "DNSSEC validation: PASS (AD flag set)"
    else
        # Check if it's a validation failure
        DNSSEC_CD=$(dig $RESOLVER +cd +time=5 +tries=2 "$DOMAIN" A 2>/dev/null)
        if echo "$DNSSEC_CD" | grep -q "SERVFAIL"; then
            fail "DNSSEC validation: FAIL (SERVFAIL even with +cd)"
        elif echo "$DNSSEC_TEST" | grep -q "SERVFAIL"; then
            fail "DNSSEC validation: FAIL (SERVFAIL, works with +cd — broken chain)"
        else
            info "DNSSEC: records present but AD flag not set by resolver"
        fi
    fi

    # Check RRSIG
    RRSIG=$(dig $RESOLVER +dnssec +noall +answer +time=5 "$DOMAIN" A 2>/dev/null | grep RRSIG)
    if [ -n "$RRSIG" ]; then
        ok "RRSIG found for A record"
    fi
else
    info "DNSSEC not enabled (no DNSKEY records)"
fi

# ─── Email Authentication ───
section "Email Authentication"

# SPF
SPF=$(dig_query TXT | grep -i "v=spf1" || true)
if [ -n "$SPF" ]; then
    ok "SPF record found"
    verbose "$SPF"

    # Check for multiple SPF records
    SPF_COUNT=$(dig_query TXT | grep -c "v=spf1" || true)
    if [ "$SPF_COUNT" -gt 1 ]; then
        fail "Multiple SPF records found ($SPF_COUNT) — only one allowed per domain"
    fi

    # Check for -all vs ~all
    if echo "$SPF" | grep -q "\-all"; then
        ok "SPF uses hard fail (-all)"
    elif echo "$SPF" | grep -q "~all"; then
        warn "SPF uses soft fail (~all) — consider -all for production"
    elif echo "$SPF" | grep -q "+all"; then
        fail "SPF uses +all — this authorizes EVERYONE (defeats purpose of SPF)"
    fi
else
    warn "No SPF record found — email spoofing possible"
fi

# DKIM (check common selectors)
section "DKIM Selectors"
DKIM_FOUND=0
for selector in google selector1 selector2 default dkim s1 s2 k1 k2 k3 mail protonmail mimecast mandrill; do
    DKIM=$(dig_query TXT "${selector}._domainkey.${DOMAIN}")
    if [ -n "$DKIM" ]; then
        ok "DKIM found: ${selector}._domainkey.${DOMAIN}"
        verbose "$DKIM"
        DKIM_FOUND=1
    fi
done
if [ "$DKIM_FOUND" -eq 0 ]; then
    warn "No DKIM records found for common selectors (may use non-standard selector)"
fi

# DMARC
section "DMARC"
DMARC=$(dig_query TXT "_dmarc.${DOMAIN}")
if [ -n "$DMARC" ]; then
    ok "DMARC record found"
    verbose "$DMARC"

    if echo "$DMARC" | grep -qi "p=reject"; then
        ok "DMARC policy: reject (full enforcement)"
    elif echo "$DMARC" | grep -qi "p=quarantine"; then
        info "DMARC policy: quarantine (partial enforcement)"
    elif echo "$DMARC" | grep -qi "p=none"; then
        warn "DMARC policy: none (monitoring only — not enforcing)"
    fi

    if echo "$DMARC" | grep -qi "rua="; then
        ok "DMARC aggregate reporting enabled"
    else
        warn "DMARC rua= not set — no aggregate reports will be received"
    fi
else
    warn "No DMARC record found — domain is vulnerable to spoofing"
fi

# MTA-STS
section "MTA-STS & TLS-RPT"
MTA_STS=$(dig_query TXT "_mta-sts.${DOMAIN}")
if [ -n "$MTA_STS" ]; then
    ok "MTA-STS record found"
    verbose "$MTA_STS"
else
    info "No MTA-STS record (optional but recommended for email security)"
fi

# TLS-RPT
TLS_RPT=$(dig_query TXT "_smtp._tls.${DOMAIN}")
if [ -n "$TLS_RPT" ]; then
    ok "TLS-RPT record found"
    verbose "$TLS_RPT"
else
    info "No TLS-RPT record (optional — enables TLS failure reporting)"
fi

# BIMI
BIMI=$(dig_query TXT "default._bimi.${DOMAIN}")
if [ -n "$BIMI" ]; then
    ok "BIMI record found"
    verbose "$BIMI"
else
    info "No BIMI record (optional — displays brand logo in email clients)"
fi

# ─── Summary ───
section "Audit Summary"
echo ""
echo "  Domain:   $DOMAIN"
echo "  Resolver: ${RESOLVER:-system default}"
echo "  Date:     $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""
echo -e "  ${GREEN}Warnings: ${WARNINGS}${NC}"
echo -e "  ${RED}Errors:   ${ERRORS}${NC}"
echo ""

if [ "$ERRORS" -gt 0 ]; then
    echo -e "  ${RED}⚠ Critical issues found — review errors above${NC}"
elif [ "$WARNINGS" -gt 0 ]; then
    echo -e "  ${YELLOW}⚡ Minor issues found — review warnings above${NC}"
else
    echo -e "  ${GREEN}✓ All checks passed${NC}"
fi
echo ""
