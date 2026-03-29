#!/bin/bash
# buf-check.sh - Comprehensive Buf lint and breaking change detection
# Usage: ./buf-check.sh [branch|tag|commit]

set -euo pipefail

AGAINST="${1:-.git#branch=main}"

echo "=== Buf Comprehensive Check ==="
echo ""

echo "1. Format check..."
if ! buf format --diff --exit-code; then
    echo "   ⚠️  Format issues found. Run 'buf format -w' to fix."
else
    echo "   ✓ Format OK"
fi
echo ""

echo "2. Lint check..."
if buf lint; then
    echo "   ✓ Lint passed"
else
    echo "   ✗ Lint failed"
    exit 1
fi
echo ""

echo "3. Build check..."
if buf build --error-format=json > /dev/null 2>&1; then
    echo "   ✓ Build passed"
else
    echo "   ✗ Build failed"
    exit 1
fi
echo ""

echo "4. Breaking change detection (against: $AGAINST)..."
if buf breaking --against "$AGAINST"; then
    echo "   ✓ No breaking changes"
else
    echo "   ✗ Breaking changes detected!"
    exit 1
fi
echo ""

echo "=== All checks passed! ==="
