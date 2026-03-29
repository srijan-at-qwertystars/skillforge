#!/bin/bash
# earthly-lint.sh - Lint Earthfile for common issues

set -e

EARTHFILE="${1:-Earthfile}"

if [[ ! -f "$EARTHFILE" ]]; then
    echo "Error: $EARTHFILE not found"
    exit 1
fi

echo "Linting $EARTHFILE..."

# Check for VERSION directive
if ! grep -q "^VERSION" "$EARTHFILE"; then
    echo "❌ Missing VERSION directive (must be first line)"
else
    echo "✓ VERSION directive present"
fi

# Check for 'latest' tag usage
if grep -E "FROM\s+\S+:latest" "$EARTHFILE"; then
    echo "⚠️  Warning: Using 'latest' tag detected (use specific versions)"
fi

# Check for proper SAVE ARTIFACT usage
if grep -q "SAVE ARTIFACT" "$EARTHFILE"; then
    echo "✓ SAVE ARTIFACT usage found"
fi

# Check for cache mounts in package manager commands
if grep -q "go mod download" "$EARTHFILE" && ! grep -q "mount=type=cache.*go/pkg/mod" "$EARTHFILE"; then
    echo "⚠️  Consider adding cache mount for Go modules: --mount=type=cache,target=/go/pkg/mod"
fi

if grep -q "npm ci" "$EARTHFILE" && ! grep -q "mount=type=cache.*npm" "$EARTHFILE"; then
    echo "⚠️  Consider adding cache mount for npm: --mount=type=cache,target=/root/.npm"
fi

echo "Lint complete."
