#!/bin/bash
# Run WXT extension in development mode with auto-reload
# Usage: ./dev-watch.sh [browser]

set -e

BROWSER="${1:-chrome}"

echo "🚀 Starting WXT development server..."
echo "🌐 Browser: $BROWSER"
echo ""
echo "Press Ctrl+C to stop"
echo ""

npm run dev -- --browser "$BROWSER"
