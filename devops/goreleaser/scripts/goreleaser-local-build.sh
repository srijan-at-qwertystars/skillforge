#!/bin/bash
# goreleaser-local-build.sh - Build locally without releasing (snapshot mode)

set -e

echo "Running GoReleaser in snapshot mode (local build, no release)..."

# Check if goreleaser is installed
if ! command -v goreleaser &> /dev/null; then
    echo "Error: goreleaser is not installed. Install with:"
    echo "  go install github.com/goreleaser/goreleaser/v2@latest"
    exit 1
fi

# Run snapshot build
goreleaser release --snapshot --clean "$@"

echo "Build complete. Artifacts in ./dist/"
