#!/bin/bash
# verify-sbom.sh - Verify SBOM attestations for container images
# Usage: ./verify-sbom.sh <image> [output-file]

set -euo pipefail

IMAGE="${1:-}"
OUTPUT="${2:-verified-sbom.json}"

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image> [output-file]"
    echo "Examples:"
    echo "  $0 ghcr.io/org/app:latest"
    echo "  $0 ghcr.io/org/app:latest sbom.json"
    exit 1
fi

echo "🔍 Verifying SBOM attestation for: $IMAGE"
echo "📄 Output will be saved to: $OUTPUT"

cosign verify-attestation "$IMAGE" \
    --type spdxjson \
    --output-file "$OUTPUT"

echo "✅ SBOM attestation verified!"
echo "📊 SBOM saved to: $OUTPUT"
echo ""
echo "View with: cat $OUTPUT | jq '.predicate'"
