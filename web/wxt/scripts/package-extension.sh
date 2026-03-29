#!/bin/bash
# Package extension for distribution (creates zip files)
# Usage: ./package-extension.sh [browser]

set -e

BROWSER="${1:-chrome}"

echo "📦 Packaging extension for $BROWSER..."

# Build first
npm run build -- --browser "$BROWSER"

# Create zip
npm run zip -- --browser "$BROWSER"

# Also create sources zip for Firefox
if [ "$BROWSER" == "firefox" ]; then
    echo "📦 Creating sources zip for Firefox review..."
    npm run zip -- --browser firefox --sources
fi

echo ""
echo "✅ Package created!"
echo "📁 Check the project root for .zip files"
