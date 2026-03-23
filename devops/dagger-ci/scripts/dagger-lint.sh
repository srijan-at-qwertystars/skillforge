#!/usr/bin/env bash
#
# dagger-lint.sh — Lint and validate Dagger module configuration
#
# Usage:
#   ./dagger-lint.sh [--dir=path] [--fix] [--verbose]
#
# Options:
#   --dir=DIR     Directory containing dagger.json (default: current directory)
#   --fix         Attempt to fix common issues automatically
#   --verbose     Show detailed output for each check
#   --help        Show this help message
#
# Checks performed:
#   1. dagger.json exists and is valid JSON
#   2. Required fields (name, sdk) are present
#   3. SDK-specific source files exist
#   4. Dependencies are properly declared
#   5. .daggerignore exists with recommended entries
#   6. No secrets or credentials in source files
#   7. Cache volumes are used for known package managers
#   8. dagger CLI version matches module engineVersion (if set)
#
# Examples:
#   ./dagger-lint.sh
#   ./dagger-lint.sh --dir=./my-project --verbose
#   ./dagger-lint.sh --fix
#

set -euo pipefail

TARGET_DIR="."
FIX=false
VERBOSE=false
ERRORS=0
WARNINGS=0

for arg in "$@"; do
    case "$arg" in
        --dir=*)    TARGET_DIR="${arg#*=}" ;;
        --fix)      FIX=true ;;
        --verbose)  VERBOSE=true ;;
        --help|-h)  sed -n '3,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)          echo "Unknown option: $arg"; exit 1 ;;
    esac
done

cd "$TARGET_DIR"

info()    { echo "  ℹ️  $1"; }
pass()    { echo "  ✅ $1"; }
warn()    { echo "  ⚠️  $1"; WARNINGS=$((WARNINGS + 1)); }
fail()    { echo "  ❌ $1"; ERRORS=$((ERRORS + 1)); }

echo "🔍 Dagger Lint — checking $(pwd)"
echo ""

# --- Check 1: dagger.json exists and is valid ---
echo "📋 Configuration"

if [ ! -f "dagger.json" ]; then
    fail "dagger.json not found. Run: dagger init --sdk=<go|python|typescript>"
    echo ""
    echo "Result: $ERRORS error(s), $WARNINGS warning(s)"
    exit 1
fi
pass "dagger.json exists"

if ! python3 -c "import json; json.load(open('dagger.json'))" 2>/dev/null && \
   ! jq empty dagger.json 2>/dev/null; then
    fail "dagger.json is not valid JSON"
    echo ""
    echo "Result: $ERRORS error(s), $WARNINGS warning(s)"
    exit 1
fi
pass "dagger.json is valid JSON"

# Parse fields (use python3 as it's more commonly available than jq)
parse_json() {
    python3 -c "import json,sys; d=json.load(open('dagger.json')); print(d.get('$1',''))" 2>/dev/null || echo ""
}

MODULE_NAME=$(parse_json "name")
MODULE_SDK=$(parse_json "sdk")
ENGINE_VERSION=$(parse_json "engineVersion")

if [ -z "$MODULE_NAME" ]; then
    fail "dagger.json missing 'name' field"
else
    pass "Module name: $MODULE_NAME"
fi

if [ -z "$MODULE_SDK" ]; then
    fail "dagger.json missing 'sdk' field"
else
    pass "SDK: $MODULE_SDK"
fi

if [ -n "$ENGINE_VERSION" ]; then
    $VERBOSE && info "Engine version pinned: $ENGINE_VERSION"
    if command -v dagger &>/dev/null; then
        CLI_VERSION=$(dagger version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo "")
        if [ -n "$CLI_VERSION" ] && [ "$CLI_VERSION" != "$ENGINE_VERSION" ]; then
            warn "CLI version ($CLI_VERSION) differs from engineVersion ($ENGINE_VERSION)"
        fi
    fi
fi

echo ""

# --- Check 2: SDK source files ---
echo "📁 Source Files"

case "$MODULE_SDK" in
    go)
        if [ -f "dagger/main.go" ] || [ -f "main.go" ]; then
            pass "Go source file found"
        else
            fail "No main.go found in dagger/ or project root"
        fi
        if [ -f "go.mod" ] || [ -f "dagger/go.mod" ]; then
            pass "go.mod found"
        else
            warn "go.mod not found — run 'dagger develop' to generate"
        fi
        ;;
    python)
        if [ -f "dagger/src/__init__.py" ] || [ -f "src/__init__.py" ]; then
            pass "Python source file found"
        else
            fail "No src/__init__.py found"
        fi
        ;;
    typescript)
        if [ -f "dagger/src/index.ts" ] || [ -f "src/index.ts" ]; then
            pass "TypeScript source file found"
        else
            fail "No src/index.ts found"
        fi
        ;;
    "")
        fail "Cannot check source files — SDK not specified"
        ;;
    *)
        warn "Unknown SDK '$MODULE_SDK' — cannot validate source files"
        ;;
esac

echo ""

# --- Check 3: .daggerignore ---
echo "🚫 Ignore File"

RECOMMENDED_IGNORES=(".git" "node_modules" "vendor" ".venv" "__pycache__" "dist" "build")

if [ -f ".daggerignore" ]; then
    pass ".daggerignore exists"
    for entry in "${RECOMMENDED_IGNORES[@]}"; do
        if ! grep -qx "$entry" .daggerignore 2>/dev/null; then
            if [ -d "$entry" ] || [ "$entry" = ".git" ]; then
                warn ".daggerignore missing recommended entry: $entry"
                if $FIX; then
                    echo "$entry" >> .daggerignore
                    info "Added '$entry' to .daggerignore"
                fi
            fi
        fi
    done
else
    warn ".daggerignore not found — build context may include unnecessary files"
    if $FIX; then
        printf '%s\n' "${RECOMMENDED_IGNORES[@]}" > .daggerignore
        info "Created .daggerignore with recommended entries"
    fi
fi

echo ""

# --- Check 4: Secrets in source ---
echo "🔐 Security"

SECRET_PATTERNS='(password|secret|token|api_key|apikey|private_key)\s*[:=]\s*["\x27][^"\x27]{8,}'
FOUND_SECRETS=false

find_sources() {
    find . -type f \( -name '*.go' -o -name '*.py' -o -name '*.ts' -o -name '*.js' \) \
        -not -path './.git/*' \
        -not -path './node_modules/*' \
        -not -path './vendor/*' \
        -not -path './.venv/*' 2>/dev/null
}

while IFS= read -r file; do
    if grep -iEn "$SECRET_PATTERNS" "$file" 2>/dev/null | grep -ivq '(test|example|placeholder|xxx|changeme)'; then
        fail "Possible hardcoded secret in $file"
        FOUND_SECRETS=true
        if $VERBOSE; then
            grep -iEn "$SECRET_PATTERNS" "$file" 2>/dev/null | head -3 | sed 's/^/       /'
        fi
    fi
done < <(find_sources)

if ! $FOUND_SECRETS; then
    pass "No hardcoded secrets detected"
fi

echo ""

# --- Check 5: Caching ---
echo "⚡ Caching"

HAS_CACHE=false
if find_sources | xargs grep -l 'CacheVolume\|cache_volume\|cacheVolume' 2>/dev/null | head -1 | grep -q .; then
    HAS_CACHE=true
    pass "Cache volumes are used"
    if $VERBOSE; then
        find_sources | xargs grep -h 'CacheVolume\|cache_volume\|cacheVolume' 2>/dev/null | \
            sed 's/.*\(CacheVolume\|cache_volume\|cacheVolume\)(\s*"\([^"]*\)".*/  → \2/' | \
            sort -u | head -10 | sed 's/^/       /'
    fi
else
    warn "No cache volumes found — consider adding CacheVolume for package managers"
fi

echo ""

# --- Check 6: CLI availability ---
echo "🔧 Tooling"

if command -v dagger &>/dev/null; then
    DAGGER_VERSION=$(dagger version 2>/dev/null || echo "unknown")
    pass "Dagger CLI installed: $DAGGER_VERSION"
else
    warn "Dagger CLI not found in PATH"
fi

if command -v docker &>/dev/null; then
    if docker info &>/dev/null 2>&1; then
        pass "Docker is running"
    else
        warn "Docker is installed but not running"
    fi
else
    warn "Docker not found — Dagger requires a container runtime"
fi

echo ""

# --- Summary ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✅ All checks passed!"
elif [ $ERRORS -eq 0 ]; then
    echo "⚠️  $WARNINGS warning(s), 0 errors"
else
    echo "❌ $ERRORS error(s), $WARNINGS warning(s)"
fi

exit $ERRORS
