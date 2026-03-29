#!/bin/bash
# buf-ls-breaking.sh - List all breaking changes between two refs
# Usage: ./buf-ls-breaking.sh <from-ref> [to-ref]

set -euo pipefail

FROM_REF="${1:-}"
TO_REF="${2:-HEAD}"

if [ -z "$FROM_REF" ]; then
    echo "Usage: $0 <from-ref> [to-ref]"
    echo "Example: $0 v1.0.0 HEAD"
    echo "Example: $0 main feature-branch"
    exit 1
fi

echo "=== Breaking Changes: $FROM_REF → $TO_REF ==="
echo ""

# Create temporary directories
FROM_DIR=$(mktemp -d)
TO_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$FROM_DIR" "$TO_DIR"
}
trap cleanup EXIT

# Export protos from both refs
echo "Exporting protos from $FROM_REF..."
git show "$FROM_REF:proto" > /dev/null 2>&1 && \
    git archive "$FROM_REF" proto/ | tar -x -C "$FROM_DIR" 2>/dev/null || \
    echo "  (no proto dir at $FROM_REF)"

echo "Exporting protos from $TO_REF..."
git archive "$TO_REF" proto/ | tar -x -C "$TO_DIR" 2>/dev/null || \
    echo "  (no proto dir at $TO_REF)"

# Check breaking changes
echo ""
echo "Checking breaking changes..."
echo ""

if [ -f "$TO_DIR/proto/buf.yaml" ]; then
    cd "$TO_DIR"
    if buf breaking --against "$FROM_DIR/proto" 2>&1; then
        echo ""
        echo "✓ No breaking changes detected"
    else
        echo ""
        echo "✗ Breaking changes detected above"
        exit 1
    fi
else
    echo "No buf.yaml found in target. Running basic check..."
    if buf breaking "$TO_DIR/proto" --against "$FROM_DIR/proto" 2>&1; then
        echo ""
        echo "✓ No breaking changes detected"
    else
        echo ""
        echo "✗ Breaking changes detected above"
        exit 1
    fi
fi
