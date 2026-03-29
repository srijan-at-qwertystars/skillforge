#!/bin/bash
# Validate Rspack Configuration
# Usage: ./scripts/validate-config.sh [config-file]

set -e

CONFIG_FILE="${1:-rspack.config.js}"

echo "=== Validating Rspack Configuration ==="
echo "Config file: $CONFIG_FILE"
echo ""

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Check if rspack is installed
if ! command -v npx rspack &> /dev/null; then
    echo "Error: Rspack not found. Run: npm install -D @rspack/core @rspack/cli"
    exit 1
fi

echo "Running Rspack validation..."
npx rspack build --mode=none --stats=errors-only

echo ""
echo "✓ Configuration is valid!"
