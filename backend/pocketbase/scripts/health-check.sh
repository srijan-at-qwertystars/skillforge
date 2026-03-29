#!/bin/bash
# PocketBase Health Check Script
# Checks if PocketBase instance is running and healthy

set -e

PB_URL="${1:-http://localhost:8090}"
TIMEOUT="${2:-5}"

echo "Checking PocketBase health at: $PB_URL"

# Check health endpoint
if curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$PB_URL/api/health" | grep -q "200"; then
    echo "✓ PocketBase is healthy"
    
    # Get API info
    echo ""
    echo "API Info:"
    curl -s --max-time "$TIMEOUT" "$PB_URL/api/" | head -c 500
    echo ""
    exit 0
else
    echo "✗ PocketBase is not responding (HTTP 200)"
    exit 1
fi
