#!/bin/bash
# Run OXC in CI mode (fails on any warning)
# Usage: ./oxc-ci.sh [path]

TARGET="${1:-.}"

echo "🔍 Running OXC CI check on: $TARGET"
npx oxlint "$TARGET" --max-warnings 0
