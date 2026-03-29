#!/bin/bash
# moon-docker.sh - Docker scaffolding helpers for Moon projects

set -e

PROJECT=""
ACTION="scaffold"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --project|-p)
      PROJECT="$2"
      shift 2
      ;;
    --scaffold)
      ACTION="scaffold"
      shift
      ;;
    --file)
      ACTION="file"
      shift
      ;;
    --prune)
      ACTION="prune"
      shift
      ;;
    --help|-h)
      echo "Usage: moon-docker.sh [OPTIONS]"
      echo ""
      echo "Docker helpers for Moon projects"
      echo ""
      echo "Options:"
      echo "  --project, -p NAME   Project name (required)"
      echo "  --scaffold           Scaffold Docker files (default)"
      echo "  --file               Generate Dockerfile"
      echo "  --prune              Prune for production"
      echo "  --help, -h           Show this help"
      echo ""
      echo "Examples:"
      echo "  moon-docker.sh -p web --scaffold"
      echo "  moon-docker.sh -p api --file"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate project name
if [ -z "$PROJECT" ]; then
    echo "❌ Project name is required. Use --project or -p"
    exit 1
fi

echo "🌙 Moon Docker Helper"
echo "===================="
echo "Project: $PROJECT"
echo "Action: $ACTION"
echo ""

# Check if moon is installed
if ! command -v moon &> /dev/null; then
    echo "❌ moon is not installed"
    exit 1
fi

# Execute action
case $ACTION in
  scaffold)
    echo "📦 Scaffolding Docker files for $PROJECT..."
    moon docker scaffold "$PROJECT"
    ;;
  file)
    echo "🐳 Generating Dockerfile for $PROJECT..."
    moon docker file "$PROJECT"
    ;;
  prune)
    echo "🧹 Pruning for production..."
    moon docker prune
    ;;
esac

echo ""
echo "✅ Done!"
