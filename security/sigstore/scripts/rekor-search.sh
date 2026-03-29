#!/bin/bash
# rekor-search.sh - Search Rekor transparency log for artifacts
# Usage: ./rekor-search.sh <sha256-digest|artifact-path>

set -euo pipefail

INPUT="${1:-}"

if [ -z "$INPUT" ]; then
    echo "Usage: $0 <sha256-digest|artifact-path>"
    echo "Examples:"
    echo "  $0 sha256:abc123..."
    echo "  $0 ./my-artifact.tar.gz"
    exit 1
fi

# Check if input is a file or a digest
if [ -f "$INPUT" ]; then
    echo "📁 Calculating digest for: $INPUT"
    DIGEST="sha256:$(sha256sum "$INPUT" | cut -d' ' -f1)"
    echo "🔐 SHA256: $DIGEST"
else
    DIGEST="$INPUT"
    # Add sha256: prefix if missing
    [[ "$DIGEST" != sha256:* ]] && DIGEST="sha256:$DIGEST"
    echo "🔐 Using digest: $DIGEST"
fi

echo ""
echo "🔍 Searching Rekor transparency log..."

if command -v rekor-cli &> /dev/null; then
    rekor-cli search --sha "$DIGEST"
else
    echo "⚠️  rekor-cli not installed. Install with:"
    echo "   go install github.com/sigstore/rekor/cmd/rekor-cli@latest"
    exit 1
fi
