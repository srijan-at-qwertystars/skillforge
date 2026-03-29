#!/bin/bash
# sign-image.sh - Sign container images with cosign (keyless or key-based)
# Usage: ./sign-image.sh <image> [--key path]

set -euo pipefail

IMAGE="${1:-}"
KEY_FLAG=""

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image> [--key path]"
    echo "Examples:"
    echo "  $0 ghcr.io/org/app:latest           # Keyless signing"
    echo "  $0 ghcr.io/org/app:latest --key.key # Key-based signing"
    exit 1
fi

# Parse optional key argument
if [ "${2:-}" = "--key" ] && [ -n "${3:-}" ]; then
    KEY_FLAG="--key $3"
    echo "🔑 Using key-based signing with: $3"
else
    echo "🔑 Using keyless signing (requires OIDC auth)"
fi

echo "📝 Signing image: $IMAGE"

if [ -n "$KEY_FLAG" ]; then
    cosign sign $KEY_FLAG "$IMAGE"
else
    # Keyless signing with automatic yes
    cosign sign --yes "$IMAGE"
fi

echo "✅ Image signed successfully!"
echo ""
echo "Verify with:"
echo "  cosign verify $IMAGE"
