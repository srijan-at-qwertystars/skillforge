#!/bin/bash
# earthly-ci.sh - Run Earthly targets in CI with proper flags

set -e

TARGET="${1:-+all}"
PUSH="${2:-false}"

echo "Running Earthly target: $TARGET"

# Base flags for CI
FLAGS="--ci --verbose"

# Add push flag if requested
if [[ "$PUSH" == "true" ]]; then
    FLAGS="$FLAGS --push"
fi

# Check for secrets
if [[ -n "$EARTHLY_SECRETS" ]]; then
    FLAGS="$FLAGS --secret $EARTHLY_SECRETS"
fi

# Run with retry logic
MAX_RETRIES=3
RETRY_COUNT=0

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    if earthly $FLAGS "$TARGET"; then
        echo "✓ Build successful"
        exit 0
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "⚠️  Build failed, retry $RETRY_COUNT/$MAX_RETRIES..."
    sleep 5
done

echo "❌ Build failed after $MAX_RETRIES attempts"
exit 1
