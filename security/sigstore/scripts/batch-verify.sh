#!/bin/bash
# batch-verify.sh - Batch verify multiple images from a list
# Usage: ./batch-verify.sh <image-list-file> [identity] [issuer]

set -euo pipefail

LIST_FILE="${1:-}"
IDENTITY="${2:-}"
ISSUER="${3:-https://token.actions.githubusercontent.com}"

if [ -z "$LIST_FILE" ] || [ ! -f "$LIST_FILE" ]; then
    echo "Usage: $0 <image-list-file> [identity] [issuer]"
    echo ""
    echo "Image list file format (one image per line):"
    echo "  ghcr.io/org/app:v1.0.0"
    echo "  ghcr.io/org/app:v1.1.0"
    echo "  docker.io/library/nginx:latest"
    exit 1
fi

FAILED=0
TOTAL=0

echo "🔍 Batch verifying images from: $LIST_FILE"
echo ""

while IFS= read -r image; do
    # Skip empty lines and comments
    [[ -z "$image" || "$image" =~ ^# ]] && continue
    
    TOTAL=$((TOTAL + 1))
    echo "[$TOTAL] Verifying: $image"
    
    if [ -n "$IDENTITY" ]; then
        if cosign verify "$image" \
            --certificate-identity="$IDENTITY" \
            --certificate-oidc-issuer="$ISSUER" 2>/dev/null; then
            echo "  ✅ Verified"
        else
            echo "  ❌ Failed"
            FAILED=$((FAILED + 1))
        fi
    else
        if cosign verify "$image" 2>/dev/null; then
            echo "  ✅ Verified"
        else
            echo "  ❌ Failed"
            FAILED=$((FAILED + 1))
        fi
    fi
done < "$LIST_FILE"

echo ""
echo "📊 Results: $((TOTAL - FAILED))/$TOTAL images verified"

if [ $FAILED -gt 0 ]; then
    echo "❌ $FAILED image(s) failed verification"
    exit 1
else
    echo "✅ All images verified successfully!"
    exit 0
fi
