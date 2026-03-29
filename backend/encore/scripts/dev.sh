#!/bin/bash
# Quick development server startup with common options

set -e

echo "🚀 Starting Encore development server..."
echo "   Dashboard: http://localhost:9400"
echo "   Press Ctrl+C to stop"
echo ""

# Check if encore.app exists
if [ ! -f "encore.app" ]; then
    echo "❌ Error: No encore.app file found. Are you in an Encore project directory?"
    exit 1
fi

encore run "$@"
