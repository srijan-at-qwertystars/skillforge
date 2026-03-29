#!/bin/bash
# goreleaser-release.sh - Full release (requires GITHUB_TOKEN)

set -e

# Check if GITHUB_TOKEN is set
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN environment variable is not set"
    echo "Set it with: export GITHUB_TOKEN=your_token_here"
    exit 1
fi

# Check if goreleaser is installed
if ! command -v goreleaser &> /dev/null; then
    echo "Error: goreleaser is not installed. Install with:"
    echo "  go install github.com/goreleaser/goreleaser/v2@latest"
    exit 1
fi

echo "Running GoReleaser release..."
goreleaser release --clean "$@"

echo "Release complete!"
