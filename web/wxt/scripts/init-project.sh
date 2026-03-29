#!/bin/bash
# Initialize a new WXT extension project
# Usage: ./init-project.sh [project-name] [template]

set -e

PROJECT_NAME="${1:-my-extension}"
TEMPLATE="${2:-vanilla}"

echo "🚀 Creating new WXT extension: $PROJECT_NAME"
echo "📦 Template: $TEMPLATE"

# Create project using npm create
if ! command -v npm &> /dev/null; then
    echo "❌ npm is required but not installed"
    exit 1
fi

# Use npm create wxt@latest with the project name
cd "$(dirname "$0")/.." || exit 1
mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Initialize with WXT
echo "⏳ Running npm create wxt@latest..."
npm create wxt@latest . -- --template "$TEMPLATE"

echo ""
echo "✅ Project created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npm install"
echo "  npm run dev"
echo ""
echo "Available templates: vanilla, vue, react, svelte, solid"
