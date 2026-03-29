#!/bin/bash
# Devbox Project Health Check
# Validates devbox.json, checks for common issues, and provides recommendations

set -euo pipefail

ERRORS=0
WARNINGS=0

echo "🔍 Devbox Health Check"
echo "======================"
echo ""

# Check if devbox.json exists
if [ ! -f "devbox.json" ]; then
    echo "❌ ERROR: devbox.json not found in current directory"
    exit 1
fi

echo "📄 Checking devbox.json..."

# Validate JSON syntax
if ! jq empty devbox.json 2>/dev/null; then
    echo "❌ ERROR: devbox.json contains invalid JSON"
    ((ERRORS++))
else
    echo "✅ devbox.json is valid JSON"
fi

# Check for lockfile
if [ ! -f "devbox.lock" ]; then
    echo "⚠️  WARNING: devbox.lock not found. Run 'devbox shell' to generate it"
    ((WARNINGS++))
else
    echo "✅ devbox.lock exists"
fi

# Check packages
PACKAGES=$(jq -r '.packages // empty' devbox.json)
if [ -z "$PACKAGES" ] || [ "$PACKAGES" = "[]" ] || [ "$PACKAGES" = "{}" ] || [ "$PACKAGES" = "null" ]; then
    echo "⚠️  WARNING: No packages defined in devbox.json"
    ((WARNINGS++))
else
    PACKAGE_COUNT=$(echo "$PACKAGES" | jq 'length')
    echo "✅ Found $PACKAGE_COUNT package(s)"
fi

# Check for version pinning recommendations
echo ""
echo "📋 Package Version Analysis:"
PACKAGES_RAW=$(jq -r '.packages // [] | if type == "array" then .[] else keys[] as $k | "\($k)@\(.[$k])" end' devbox.json 2>/dev/null || true)

if [ -n "$PACKAGES_RAW" ]; then
    while IFS= read -r pkg; do
        if [[ "$pkg" == *"@latest"* ]]; then
            echo "  ⚠️  $pkg - Consider pinning to specific version for reproducibility"
            ((WARNINGS++))
        elif [[ "$pkg" =~ @[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            echo "  ✅ $pkg - Pinned to specific version"
        elif [[ "$pkg" =~ @[0-9]+ ]]; then
            echo "  ℹ️  $pkg - Pinned to major version (consider full semver)"
        fi
    done <<< "$PACKAGES_RAW"
fi

# Check shell scripts
echo ""
echo "🔧 Shell Configuration:"
INIT_HOOK=$(jq -r '.shell.init_hook // empty' devbox.json)
if [ -n "$INIT_HOOK" ] && [ "$INIT_HOOK" != "[]" ] && [ "$INIT_HOOK" != "null" ]; then
    HOOK_COUNT=$(echo "$INIT_HOOK" | jq 'length')
    echo "✅ Found $HOOK_COUNT init hook(s)"
else
    echo "ℹ️  No init hooks defined"
fi

SCRIPTS=$(jq -r '.shell.scripts // empty' devbox.json)
if [ -n "$SCRIPTS" ] && [ "$SCRIPTS" != "{}" ] && [ "$SCRIPTS" != "null" ]; then
    SCRIPT_NAMES=$(echo "$SCRIPTS" | jq -r 'keys[]')
    echo "✅ Defined scripts: $(echo "$SCRIPT_NAMES" | tr '\n' ' ')"
else
    echo "ℹ️  No scripts defined (consider adding common tasks)"
fi

# Check for process-compose.yml
if [ -f "process-compose.yml" ]; then
    echo ""
    echo "🔧 Service Configuration:"
    if jq empty process-compose.yml 2>/dev/null || yq eval '.' process-compose.yml >/dev/null 2>&1; then
        echo "✅ process-compose.yml is valid"
    else
        echo "⚠️  WARNING: process-compose.yml may have syntax issues"
        ((WARNINGS++))
    fi
fi

# Check for .envrc (direnv)
echo ""
echo "🌿 direnv Integration:"
if [ -f ".envrc" ]; then
    if grep -q "devbox" .envrc; then
        echo "✅ .envrc configured for devbox"
    else
        echo "⚠️  WARNING: .envrc exists but may not be configured for devbox"
        echo "   Run: devbox generate direnv"
        ((WARNINGS++))
    fi
else
    echo "ℹ️  No .envrc found (optional: run 'devbox generate direnv' for auto-activation)"
fi

# Check git status
echo ""
echo "📦 Git Integration:"
if [ -d ".git" ]; then
    if git ls-files | grep -q "devbox.json"; then
        echo "✅ devbox.json is tracked in git"
    else
        echo "⚠️  WARNING: devbox.json is not tracked in git"
        echo "   Run: git add devbox.json devbox.lock"
        ((WARNINGS++))
    fi
    
    if git ls-files | grep -q "devbox.lock"; then
        echo "✅ devbox.lock is tracked in git"
    else
        echo "⚠️  WARNING: devbox.lock is not tracked in git"
        ((WARNINGS++))
    fi
else
    echo "ℹ️  Not a git repository"
fi

# Summary
echo ""
echo "======================"
echo "📊 Summary"
echo "======================"
echo "Errors: $ERRORS"
echo "Warnings: $WARNINGS"

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo ""
    echo "🎉 All checks passed! Your devbox setup looks great."
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo ""
    echo "⚠️  Checks completed with warnings. Review recommendations above."
    exit 0
else
    echo ""
    echo "❌ Checks failed with errors. Please fix the issues above."
    exit 1
fi
