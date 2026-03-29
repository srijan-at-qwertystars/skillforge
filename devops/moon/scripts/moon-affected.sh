#!/bin/bash
# moon-affected.sh - Show affected projects and tasks

set -e

BASE="origin/main"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --base)
      BASE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: moon-affected.sh [OPTIONS]"
      echo ""
      echo "Show affected projects and tasks based on changes since base ref"
      echo ""
      echo "Options:"
      echo "  --base REF          Base ref (default: origin/main)"
      echo "  --help, -h          Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "🌙 Moon Affected Detection"
echo "========================="
echo "Base ref: $BASE"
echo ""

# Check if moon is installed
if ! command -v moon &> /dev/null; then
    echo "❌ moon is not installed"
    exit 1
fi

# Show affected projects
echo "📦 Affected Projects:"
echo "--------------------"
moon query projects --affected --base "$BASE" 2>/dev/null || echo "   (no affected projects)"
echo ""

# Show affected tasks
echo "🔧 Affected Tasks:"
echo "-----------------"
moon query tasks --affected --base "$BASE" 2>/dev/null || echo "   (no affected tasks)"
echo ""

# Show graph
echo "📊 Dependency Graph:"
echo "-------------------"
moon query graph --base "$BASE" 2>/dev/null | head -50 || echo "   (graph not available)"
