#!/bin/bash
# Quick OXC lint runner with common options
# Usage: ./oxc-quick.sh [path]

TARGET="${1:-.}"

echo "🔍 Running OXC linter on: $TARGET"
npx oxlint "$TARGET" --fix
