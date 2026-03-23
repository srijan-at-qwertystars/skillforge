#!/usr/bin/env bash
# caddy-validate.sh — Validate Caddyfile syntax and check for common misconfigurations
set -euo pipefail

CADDYFILE="${1:-Caddyfile}"
ERRORS=0
WARNINGS=0

# Colors
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

error() { echo -e "${RED}ERROR:${NC} $1"; ((ERRORS++)); }
warn()  { echo -e "${YELLOW}WARN:${NC}  $1"; ((WARNINGS++)); }
ok()    { echo -e "${GREEN}OK:${NC}    $1"; }
info()  { echo -e "${BOLD}INFO:${NC}  $1"; }

echo -e "${BOLD}=== Caddy Configuration Validator ===${NC}"
echo ""

# --- Check file exists ---
if [[ ! -f "$CADDYFILE" ]]; then
    error "Caddyfile not found: $CADDYFILE"
    echo ""
    echo "Usage: $0 [path/to/Caddyfile]"
    exit 1
fi

info "Validating: $CADDYFILE"
echo ""

# --- Step 1: Caddy built-in validation ---
echo -e "${BOLD}[1/5] Syntax Validation${NC}"
if command -v caddy &>/dev/null; then
    if caddy validate --config "$CADDYFILE" 2>/dev/null; then
        ok "Caddyfile syntax is valid"
    else
        error "Caddyfile syntax validation failed"
        echo "  Run: caddy validate --config $CADDYFILE"
    fi
else
    warn "caddy binary not found — skipping syntax validation"
    echo "  Install Caddy or run caddy-install.sh first"
fi
echo ""

# --- Step 2: Check for common misconfigurations ---
echo -e "${BOLD}[2/5] Common Misconfiguration Checks${NC}"

# Check for admin API exposed on all interfaces
if grep -qE '^\s*admin\s+:2019' "$CADDYFILE" 2>/dev/null; then
    warn "Admin API exposed on all interfaces (:2019)"
    echo "  Consider: admin localhost:2019 or admin unix//run/caddy/admin.sock"
fi

# Check for admin API explicitly bound to 0.0.0.0
if grep -qE '^\s*admin\s+0\.0\.0\.0' "$CADDYFILE" 2>/dev/null; then
    error "Admin API bound to 0.0.0.0 — publicly accessible! No auth on admin API."
    echo "  Fix: admin off, admin localhost:2019, or admin unix//run/caddy/admin.sock"
fi

# Check for tls_insecure_skip_verify
if grep -q 'tls_insecure_skip_verify' "$CADDYFILE" 2>/dev/null; then
    warn "tls_insecure_skip_verify found — skips upstream TLS verification"
    echo "  Only use for known-safe internal services"
fi

# Check for missing request_body limits
if grep -q 'reverse_proxy' "$CADDYFILE" 2>/dev/null && ! grep -q 'request_body' "$CADDYFILE" 2>/dev/null; then
    warn "No request_body size limit configured for reverse proxy"
    echo "  Consider: request_body { max_size 10MB }"
fi

# Check for on_demand TLS without ask endpoint
if grep -q 'on_demand' "$CADDYFILE" 2>/dev/null && ! grep -q 'ask' "$CADDYFILE" 2>/dev/null; then
    error "on_demand TLS enabled without 'ask' endpoint — vulnerable to abuse"
    echo "  Add: on_demand_tls { ask http://localhost:5555/check }"
fi

# Check for ephemeral storage hints (Docker)
if grep -qE '/data\s*$' "$CADDYFILE" 2>/dev/null; then
    warn "Verify /data volume is persistent (not ephemeral) for certificate storage"
fi

# Check for http:// sites in production configs (intentional HTTP-only)
HTTP_SITES=$(grep -cE '^\s*http://' "$CADDYFILE" 2>/dev/null || true)
if [[ "$HTTP_SITES" -gt 0 ]]; then
    warn "$HTTP_SITES site(s) configured as HTTP-only (no TLS)"
    echo "  Intentional? Remove http:// prefix for automatic HTTPS"
fi

# Check for flush_interval with SSE/streaming
if grep -q 'reverse_proxy' "$CADDYFILE" 2>/dev/null; then
    if grep -qE 'event|stream|sse' "$CADDYFILE" 2>/dev/null && ! grep -q 'flush_interval' "$CADDYFILE" 2>/dev/null; then
        warn "SSE/streaming paths detected without flush_interval -1"
        echo "  Add: flush_interval -1 to the reverse_proxy block"
    fi
fi

ok "Misconfiguration checks complete"
echo ""

# --- Step 3: Check for deprecated patterns ---
echo -e "${BOLD}[3/5] Deprecation Checks${NC}"

# Caddy v1 syntax
if grep -qE '^\s*proxy\s' "$CADDYFILE" 2>/dev/null; then
    error "'proxy' is Caddy v1 syntax — use 'reverse_proxy' in v2"
fi
if grep -qE '^\s*ext\s' "$CADDYFILE" 2>/dev/null; then
    error "'ext' is Caddy v1 syntax — use 'file_server' with try_files in v2"
fi
if grep -qE '^\s*browse\s*$' "$CADDYFILE" 2>/dev/null; then
    warn "'browse' as standalone directive is Caddy v1 — use 'file_server browse' in v2"
fi
if grep -qE '^\s*tls\s+self_signed' "$CADDYFILE" 2>/dev/null; then
    warn "'tls self_signed' is deprecated — use 'tls internal' in Caddy v2"
fi

ok "Deprecation checks complete"
echo ""

# --- Step 4: Check brace balance ---
echo -e "${BOLD}[4/5] Brace Balance Check${NC}"
OPEN_BRACES=$(grep -o '{' "$CADDYFILE" | wc -l)
CLOSE_BRACES=$(grep -o '}' "$CADDYFILE" | wc -l)
if [[ "$OPEN_BRACES" -ne "$CLOSE_BRACES" ]]; then
    error "Unbalanced braces: $OPEN_BRACES opening vs $CLOSE_BRACES closing"
else
    ok "Braces balanced: $OPEN_BRACES pairs"
fi
echo ""

# --- Step 5: Try adapting to JSON ---
echo -e "${BOLD}[5/5] JSON Adaptation Test${NC}"
if command -v caddy &>/dev/null; then
    if caddy adapt --config "$CADDYFILE" >/dev/null 2>&1; then
        ok "Caddyfile successfully adapts to JSON config"
    else
        error "Caddyfile failed to adapt to JSON — check syntax"
        caddy adapt --config "$CADDYFILE" 2>&1 | head -5
    fi
else
    warn "caddy binary not found — skipping JSON adaptation test"
fi
echo ""

# --- Summary ---
echo -e "${BOLD}=== Summary ===${NC}"
if [[ "$ERRORS" -gt 0 ]]; then
    echo -e "${RED}$ERRORS error(s)${NC}, ${YELLOW}$WARNINGS warning(s)${NC}"
    exit 1
elif [[ "$WARNINGS" -gt 0 ]]; then
    echo -e "${GREEN}0 errors${NC}, ${YELLOW}$WARNINGS warning(s)${NC}"
    exit 0
else
    echo -e "${GREEN}All checks passed — no issues found${NC}"
    exit 0
fi
