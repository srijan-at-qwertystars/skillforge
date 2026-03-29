#!/bin/bash
# goreleaser-validate.sh - Validate .goreleaser.yaml configuration

set -e

echo "Validating GoReleaser configuration..."

# Check if goreleaser is installed
if ! command -v goreleaser &> /dev/null; then
    echo "Error: goreleaser is not installed. Install with:"
    echo "  go install github.com/goreleaser/goreleaser/v2@latest"
    exit 1
fi

# Validate config
goreleaser check "$@"

echo "Configuration is valid!"
