#!/bin/bash
# Generate API clients from Encore app

set -e

LANGUAGE=${1:-typescript}
OUTPUT_DIR=${2:-./client}

echo "📝 Generating $LANGUAGE client..."
echo "   Output: $OUTPUT_DIR"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

case "$LANGUAGE" in
    typescript|ts)
        encore gen client --lang=typescript --output="$OUTPUT_DIR"
        ;;
    go)
        encore gen client --lang=go --output="$OUTPUT_DIR"
        ;;
    javascript|js)
        encore gen client --lang=javascript --output="$OUTPUT_DIR"
        ;;
    python|py)
        encore gen client --lang=python --output="$OUTPUT_DIR"
        ;;
    *)
        echo "❌ Unsupported language: $LANGUAGE"
        echo "Supported: typescript, go, javascript, python"
        exit 1
        ;;
esac

echo ""
echo "✅ Client generated successfully in $OUTPUT_DIR"
