#!/bin/bash
# moon-debug.sh - Debug Moon task execution and caching

set -e

TARGET=""
SHOW_HASH=false
SHOW_GRAPH=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --target|-t)
      TARGET="$2"
      shift 2
      ;;
    --hash)
      SHOW_HASH=true
      shift
      ;;
    --graph)
      SHOW_GRAPH=true
      shift
      ;;
    --help|-h)
      echo "Usage: moon-debug.sh [OPTIONS]"
      echo ""
      echo "Debug Moon task execution and caching"
      echo ""
      echo "Options:"
      echo "  --target, -t TARGET   Task target (e.g., web:build)"
      echo "  --hash                Show hash debug info"
      echo "  --graph               Show dependency graph"
      echo "  --help, -h            Show this help"
      echo ""
      echo "Examples:"
      echo "  moon-debug.sh -t web:build --hash"
      echo "  moon-debug.sh --graph"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "🌙 Moon Debug"
echo "============="

# Check if moon is installed
if ! command -v moon &> /dev/null; then
    echo "❌ moon is not installed"
    exit 1
fi

# Show graph
if [ "$SHOW_GRAPH" = true ]; then
    echo ""
    echo "📊 Dependency Graph:"
    echo "--------------------"
    moon query graph
fi

# Show hash debug
if [ "$SHOW_HASH" = true ]; then
    if [ -z "$TARGET" ]; then
        echo "❌ --target is required with --hash"
        exit 1
    fi
    
    echo ""
    echo "🔍 Hash Debug for $TARGET:"
    echo "-------------------------"
    MOON_DEBUG=true moon run "$TARGET" --dry-run 2>&1 | head -100
fi

# Show project info if target specified
if [ -n "$TARGET" ] && [ "$SHOW_HASH" = false ]; then
    PROJECT=$(echo "$TARGET" | cut -d: -f1)
    
    echo ""
    echo "📋 Project Info for $PROJECT:"
    echo "----------------------------"
    moon project "$PROJECT"
    
    echo ""
    echo "🔧 Task Info for $TARGET:"
    echo "------------------------"
    moon task "$TARGET"
fi

echo ""
echo "💡 Tips:"
echo "  - Use MOON_DEBUG=true for verbose output"
echo "  - Use --force to bypass cache"
echo "  - Check .moon/cache/hashes/ for hash manifests"
