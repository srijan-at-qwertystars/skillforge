#!/bin/bash
# verify-image.sh - Verify container image signatures with cosign
# Usage: ./verify-image.sh <image> [identity] [issuer]

set -euo pipefail

IMAGE="${1:-}"
IDENTITY="${2:-}"
ISSUER="${3:-https://token.actions.githubusercontent.com}"

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image> [identity] [issuer]"
    echo "Examples:"
    echo "  $0 ghcr.io/org/app:latest"
    echo "  $0 ghcr.io/org/app:latest user@example.com https://accounts.google.com"
    exit 1
fi

echo "🔍 Verifying image: $IMAGE"

if [ -n "$IDENTITY" ]; then
    # Keyless verification with specific identity
    cosign verify "$IMAGE" \
        --certificate-identity="$IDENTITY" \
        --certificate-oidc-issuer="$ISSUER"
else
    # General verification (checks transparency log)
    cosign verify "$IMAGE"
fi

echo "✅ Image verification successful!"
