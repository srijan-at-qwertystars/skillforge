#!/bin/bash
# Rspack Bundle Analyzer
# Usage: ./scripts/analyze-bundle.sh [stats.json]

set -e

STATS_FILE="${1:-stats.json}"

if [ ! -f "$STATS_FILE" ]; then
    echo "Generating bundle stats..."
    npx rspack build --json > "$STATS_FILE"
fi

echo "Analyzing bundle: $STATS_FILE"

# Check if webpack-bundle-analyzer is installed
if ! command -v npx webpack-bundle-analyzer &> /dev/null; then
    echo "Installing webpack-bundle-analyzer..."
    npm install -D webpack-bundle-analyzer
fi

npx webpack-bundle-analyzer "$STATS_FILE" dist/
