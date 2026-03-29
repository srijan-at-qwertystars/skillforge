#!/bin/bash
# Run OXC on changed files only (git diff)
# Usage: ./oxc-changed.sh

CHANGED_FILES=$(git diff --name-only HEAD | grep -E '\.(js|ts|jsx|tsx|mjs|cjs)$' | tr '\n' ' ')

if [ -z "$CHANGED_FILES" ]; then
    echo "✅ No JS/TS files changed"
    exit 0
fi

echo "🔍 Linting changed files:"
echo "$CHANGED_FILES"
npx oxlint $CHANGED_FILES
