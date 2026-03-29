#!/bin/bash
# Build WXT extension for all target browsers
# Usage: ./build-all.sh

set -e

echo "🔨 Building WXT extension for all browsers..."

BROWSERS=("chrome" "firefox" "edge" "safari")

for browser in "${BROWSERS[@]}"; do
    echo ""
    echo "📦 Building for $browser..."
    npm run build -- --browser "$browser" || echo "⚠️  Build failed for $browser"
done

echo ""
echo "✅ Build complete! Check .output/ directory"
echo ""
ls -la .output/
