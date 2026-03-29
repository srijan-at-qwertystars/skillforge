#!/bin/bash
# moon-ci.sh - CI-optimized Moon runner with common patterns

set -e

# Default values
BASE="origin/main"
AFFECTED_ONLY=true
PARALLEL=true
REMOTE_CACHE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --base)
      BASE="$2"
      shift 2
      ;;
    --all)
      AFFECTED_ONLY=false
      shift
      ;;
    --no-parallel)
      PARALLEL=false
      shift
      ;;
    --remote-cache)
      REMOTE_CACHE=true
      shift
      ;;
    --help|-h)
      echo "Usage: moon-ci.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --base REF          Base ref for affected detection (default: origin/main)"
      echo "  --all               Run all tasks, not just affected"
      echo "  --no-parallel       Disable parallel execution"
      echo "  --remote-cache      Enable remote caching"
      echo "  --help, -h          Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "🌙 Moon CI Runner"
echo "=================="
echo "Base ref: $BASE"
echo "Affected only: $AFFECTED_ONLY"
echo "Parallel: $PARALLEL"
echo "Remote cache: $REMOTE_CACHE"
echo ""

# Check if moon is installed
if ! command -v moon &> /dev/null; then
    echo "❌ moon is not installed"
    exit 1
fi

# Build moon command
MOON_CMD="moon ci"

if [ "$AFFECTED_ONLY" = true ]; then
    MOON_CMD="$MOON_CMD --base $BASE"
fi

# Run the CI command
echo "Running: $MOON_CMD"
echo ""

if $MOON_CMD; then
    echo ""
    echo "✅ All tasks completed successfully"
else
    echo ""
    echo "❌ Some tasks failed"
    exit 1
fi
