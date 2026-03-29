#!/bin/bash
# goreleaser-init-project.sh - Initialize a new Go project with GoReleaser

set -e

PROJECT_NAME=$1

if [ -z "$PROJECT_NAME" ]; then
    echo "Usage: $0 <project-name>"
    exit 1
fi

echo "Initializing GoReleaser for project: $PROJECT_NAME"

# Check if goreleaser is installed
if ! command -v goreleaser &> /dev/null; then
    echo "Installing GoReleaser..."
    go install github.com/goreleaser/goreleaser/v2@latest
fi

# Initialize config if it doesn't exist
if [ ! -f ".goreleaser.yaml" ] && [ ! -f ".goreleaser.yml" ]; then
    echo "Creating .goreleaser.yaml..."
    goreleaser init
else
    echo "GoReleaser config already exists"
fi

# Create GitHub Actions workflow directory
mkdir -p .github/workflows

# Create release workflow
cat > .github/workflows/release.yml << 'EOF'
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write
  packages: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: actions/setup-go@v5
        with:
          go-version: stable

      - uses: goreleaser/goreleaser-action@v6
        with:
          distribution: goreleaser
          version: '~> v2'
          args: release --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
EOF

echo "Created .github/workflows/release.yml"

# Create a basic .gitignore if it doesn't exist
if [ ! -f ".gitignore" ]; then
    cat > .gitignore << 'EOF'
# Binaries
dist/
*.exe
*.dll
*.so
*.dylib

# Test binary
*.test

# Output of the go coverage tool
*.out

# Go workspace file
go.work

# Dependency directories
vendor/

# IDE
.idea/
.vscode/
*.swp
*.swo
*~
EOF
    echo "Created .gitignore"
fi

echo ""
echo "GoReleaser project initialized!"
echo "Next steps:"
echo "  1. Review and customize .goreleaser.yaml"
echo "  2. Commit your changes: git add . && git commit -m 'chore: add goreleaser'"
echo "  3. Push to GitHub: git push origin main"
echo "  4. Create and push a tag to trigger release: git tag v0.1.0 && git push origin v0.1.0"
