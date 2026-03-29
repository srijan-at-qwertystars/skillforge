#!/bin/bash
# moon-clean.sh - Clean Moon cache and artifacts

set -e

CLEAN_CACHE=false
CLEAN_OUTPUTS=false
CLEAN_ALL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --cache)
      CLEAN_CACHE=true
      shift
      ;;
    --outputs)
      CLEAN_OUTPUTS=true
      shift
      ;;
    --all)
      CLEAN_ALL=true
      shift
      ;;
    --help|-h)
      echo "Usage: moon-clean.sh [OPTIONS]"
      echo ""
      echo "Clean Moon cache and build outputs"
      echo ""
      echo "Options:"
      echo "  --cache       Clean .moon/cache directory"
      echo "  --outputs     Clean task outputs (dist/, build/, etc.)"
      echo "  --all         Clean everything (cache + outputs)"
      echo "  --help, -h    Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Default to all if no options specified
if [ "$CLEAN_CACHE" = false ] && [ "$CLEAN_OUTPUTS" = false ]; then
    CLEAN_ALL=true
fi

echo "🌙 Moon Clean"
echo "============="

if [ "$CLEAN_ALL" = true ] || [ "$CLEAN_CACHE" = true ]; then
    if [ -d ".moon/cache" ]; then
        echo "🗑️  Cleaning .moon/cache..."
        rm -rf .moon/cache/*
        echo "   ✅ Cache cleaned"
    else
        echo "   ℹ️  No cache directory found"
    fi
fi

if [ "$CLEAN_ALL" = true ] || [ "$CLEAN_OUTPUTS" = true ]; then
    echo "🗑️  Cleaning build outputs..."
    
    # Common output directories
    find . -type d -name "dist" -not -path "*/node_modules/*" -exec rm -rf {} + 2>/dev/null || true
    find . -type d -name "build" -not -path "*/node_modules/*" -exec rm -rf {} + 2>/dev/null || true
    find . -type d -name "target" -not -path "*/node_modules/*" -exec rm -rf {} + 2>/dev/null || true
    find . -type d -name ".next" -not -path "*/node_modules/*" -exec rm -rf {} + 2>/dev/null || true
    find . -type d -name "coverage" -not -path "*/node_modules/*" -exec rm -rf {} + 2>/dev/null || true
    
    echo "   ✅ Build outputs cleaned"
fi

echo ""
echo "✅ Clean complete!"
echo "   Run 'moon run :build' to rebuild"
