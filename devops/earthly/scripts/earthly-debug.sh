#!/bin/bash
# earthly-debug.sh - Debug Earthly build issues

set -e

TARGET="${1:-+build}"

echo "Debugging Earthly target: $TARGET"
echo "================================"

# Show Earthly version
echo "Earthly version:"
earthly --version
echo ""

# Show available targets
echo "Available targets in Earthfile:"
grep -E "^[a-zA-Z_][a-zA-Z0-9_-]*:" Earthfile | sed 's/:/ /' | awk '{print "  - " $1}'
echo ""

# Run with verbose output and no cache
echo "Running with --verbose --no-cache for debugging..."
earthly --verbose --no-cache "$TARGET" 2>&1 | tee earthly-debug.log

echo ""
echo "Debug log saved to: earthly-debug.log"
