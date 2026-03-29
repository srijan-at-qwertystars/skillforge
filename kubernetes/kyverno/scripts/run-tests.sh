#!/bin/bash
# Run Kyverno tests and show results

set -e

TEST_DIR="${1:-.}"

echo "Running Kyverno tests in: $TEST_DIR"
echo ""

kyverno test "$TEST_DIR"

echo ""
echo "Test execution complete!"
