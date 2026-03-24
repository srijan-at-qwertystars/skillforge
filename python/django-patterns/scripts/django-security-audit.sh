#!/usr/bin/env bash
# ==============================================================================
# django-security-audit.sh — Audit Django project security settings
#
# Usage:
#   ./django-security-audit.sh [path/to/manage.py]
#
# Checks:
#   - DEBUG mode
#   - ALLOWED_HOSTS configuration
#   - SECURE_* settings (HSTS, SSL redirect, cookies)
#   - CSRF configuration
#   - Session security
#   - Hardcoded secrets in source code
#   - Unsafe deserialization (pickle)
#   - Django's built-in security check (manage.py check --deploy)
#   - Dependency vulnerabilities (pip-audit)
#
# Exit codes:
#   0 — No critical issues
#   1 — Critical issues found
# ==============================================================================

set -euo pipefail

MANAGE_PY="${1:-manage.py}"
PYTHON="${PYTHON:-python3}"
EXIT_CODE=0
WARNINGS=0
CRITICAL=0

if [[ ! -f "$MANAGE_PY" ]]; then
    echo "❌ Cannot find $MANAGE_PY"
    echo "Usage: $0 [path/to/manage.py]"
    exit 1
fi

echo "🔒 Django Security Audit"
echo "========================"
echo ""

# Helper functions
pass_check()  { echo "   ✅ $1"; }
warn_check()  { echo "   ⚠️  $1"; WARNINGS=$((WARNINGS + 1)); }
fail_check()  { echo "   ❌ $1"; CRITICAL=$((CRITICAL + 1)); EXIT_CODE=1; }

# --- Check 1: Django's built-in security check ---
echo "1️⃣  Running Django deployment checks..."
DEPLOY_CHECK=$($PYTHON "$MANAGE_PY" check --deploy 2>&1 || true)
if echo "$DEPLOY_CHECK" | grep -q "System check identified no issues"; then
    pass_check "Django deploy check passed"
else
    ISSUE_COUNT=$(echo "$DEPLOY_CHECK" | grep -c "WARNINGS\|WARNING\|ERROR" || echo "0")
    warn_check "Django deploy check found issues:"
    echo "$DEPLOY_CHECK" | grep -E "^\?" | head -20 | sed 's/^/      /'
fi
echo ""

# --- Check 2: DEBUG mode ---
echo "2️⃣  Checking DEBUG setting..."
DEBUG_VALUE=$($PYTHON -c "
import os, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.production')
try:
    django.setup()
    from django.conf import settings
    print(settings.DEBUG)
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null || echo "SKIP")

if [[ "$DEBUG_VALUE" == "False" ]]; then
    pass_check "DEBUG is False in production settings"
elif [[ "$DEBUG_VALUE" == "True" ]]; then
    fail_check "DEBUG is True in production settings!"
else
    warn_check "Could not determine DEBUG value (check manually)"
fi
echo ""

# --- Check 3: Hardcoded secrets ---
echo "3️⃣  Scanning for hardcoded secrets..."
SECRET_PATTERNS=(
    "SECRET_KEY\s*=\s*['\"]"
    "PASSWORD\s*=\s*['\"]"
    "API_KEY\s*=\s*['\"]"
    "PRIVATE_KEY\s*=\s*['\"]"
    "AWS_SECRET"
    "TOKEN\s*=\s*['\"][a-zA-Z0-9]"
)

FOUND_SECRETS=0
for pattern in "${SECRET_PATTERNS[@]}"; do
    MATCHES=$(grep -rn --include="*.py" "$pattern" . \
        --exclude-dir=".venv" \
        --exclude-dir="node_modules" \
        --exclude-dir=".git" \
        --exclude-dir="__pycache__" \
        --exclude="*.pyc" \
        2>/dev/null | \
        grep -v "env(" | \
        grep -v "os.environ" | \
        grep -v "# noqa" | \
        grep -v "example" | \
        grep -v "test" | \
        grep -v ".env" | \
        head -5 || true)

    if [[ -n "$MATCHES" ]]; then
        FOUND_SECRETS=1
        echo "$MATCHES" | while IFS= read -r match; do
            fail_check "Possible hardcoded secret: $match"
        done
    fi
done

if [[ $FOUND_SECRETS -eq 0 ]]; then
    pass_check "No obvious hardcoded secrets found"
fi
echo ""

# --- Check 4: Unsafe deserialization ---
echo "4️⃣  Checking for unsafe deserialization..."
PICKLE_USAGE=$(grep -rn --include="*.py" \
    -e "pickle\.loads" \
    -e "pickle\.load(" \
    -e "yaml\.load(" \
    -e "yaml\.unsafe_load" \
    -e "marshal\.loads" \
    . \
    --exclude-dir=".venv" \
    --exclude-dir=".git" \
    --exclude-dir="__pycache__" \
    2>/dev/null | head -10 || true)

if [[ -z "$PICKLE_USAGE" ]]; then
    pass_check "No unsafe deserialization detected"
else
    while IFS= read -r match; do
        warn_check "Unsafe deserialization: $match"
    done <<< "$PICKLE_USAGE"
fi
echo ""

# --- Check 5: Security headers and cookies ---
echo "5️⃣  Checking security settings in source..."

check_setting() {
    local setting_name="$1"
    local expected="$2"
    local severity="$3"

    FOUND=$(grep -rn --include="*.py" "$setting_name" config/settings/ 2>/dev/null | head -1 || true)
    if [[ -z "$FOUND" ]]; then
        if [[ "$severity" == "critical" ]]; then
            fail_check "$setting_name not found in settings"
        else
            warn_check "$setting_name not found in settings"
        fi
    elif echo "$FOUND" | grep -q "$expected"; then
        pass_check "$setting_name is properly configured"
    else
        warn_check "$setting_name may not be properly set: $FOUND"
    fi
}

check_setting "SECURE_HSTS_SECONDS" "31536000" "warn"
check_setting "SECURE_SSL_REDIRECT" "True" "warn"
check_setting "SESSION_COOKIE_SECURE" "True" "warn"
check_setting "CSRF_COOKIE_SECURE" "True" "warn"
check_setting "SECURE_CONTENT_TYPE_NOSNIFF" "True" "warn"
check_setting "X_FRAME_OPTIONS" "DENY" "warn"
echo ""

# --- Check 6: ALLOWED_HOSTS ---
echo "6️⃣  Checking ALLOWED_HOSTS..."
WILDCARD_HOST=$(grep -rn --include="*.py" "ALLOWED_HOSTS.*\[.*\"\*\".*\]" config/settings/ 2>/dev/null || true)
if [[ -n "$WILDCARD_HOST" ]]; then
    fail_check "ALLOWED_HOSTS contains wildcard '*' — restrict to specific domains"
else
    pass_check "ALLOWED_HOSTS does not contain wildcard"
fi
echo ""

# --- Check 7: SQL injection patterns ---
echo "7️⃣  Checking for raw SQL usage..."
RAW_SQL=$(grep -rn --include="*.py" \
    -e "\.raw(" \
    -e "\.extra(" \
    -e "cursor\.execute" \
    . \
    --exclude-dir=".venv" \
    --exclude-dir=".git" \
    --exclude-dir="__pycache__" \
    --exclude-dir="migrations" \
    2>/dev/null | head -10 || true)

if [[ -z "$RAW_SQL" ]]; then
    pass_check "No raw SQL usage detected"
else
    COUNT=$(echo "$RAW_SQL" | wc -l | tr -d ' ')
    warn_check "Found $COUNT raw SQL usage(s) — verify parameterized queries:"
    echo "$RAW_SQL" | sed 's/^/      /'
fi
echo ""

# --- Check 8: Dependency vulnerabilities ---
echo "8️⃣  Checking for dependency vulnerabilities..."
if command -v pip-audit &>/dev/null; then
    AUDIT_OUTPUT=$(pip-audit --format=columns 2>&1 || true)
    if echo "$AUDIT_OUTPUT" | grep -q "No known vulnerabilities found"; then
        pass_check "No known vulnerabilities in dependencies"
    else
        warn_check "Dependency vulnerabilities found:"
        echo "$AUDIT_OUTPUT" | head -20 | sed 's/^/      /'
    fi
elif command -v safety &>/dev/null; then
    SAFETY_OUTPUT=$(safety check 2>&1 || true)
    if echo "$SAFETY_OUTPUT" | grep -q "No known security vulnerabilities found"; then
        pass_check "No known vulnerabilities in dependencies"
    else
        warn_check "Dependency vulnerabilities found (run 'safety check' for details)"
    fi
else
    warn_check "Neither pip-audit nor safety installed — install with: pip install pip-audit"
fi
echo ""

# --- Check 9: .env file security ---
echo "9️⃣  Checking .env file security..."
if [[ -f ".env" ]]; then
    # Check if .env is in .gitignore
    if [[ -f ".gitignore" ]] && grep -q "^\.env$" .gitignore; then
        pass_check ".env is in .gitignore"
    else
        fail_check ".env is NOT in .gitignore — secrets may be committed!"
    fi
else
    pass_check "No .env file in project root (using environment variables)"
fi
echo ""

# --- Summary ---
echo "========================"
echo "📊 Audit Summary"
echo "   Critical issues: $CRITICAL"
echo "   Warnings:        $WARNINGS"
echo ""

if [[ $CRITICAL -gt 0 ]]; then
    echo "❌ CRITICAL issues found — fix before deploying to production!"
elif [[ $WARNINGS -gt 0 ]]; then
    echo "⚠️  Warnings found — review and address where applicable."
else
    echo "✅ All security checks passed!"
fi

exit $EXIT_CODE
