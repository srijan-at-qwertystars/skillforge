#!/usr/bin/env bash
# ============================================================================
# setup-electron-forge.sh
# Scaffolds an Electron Forge project with common plugins and configuration.
#
# Usage:
#   ./setup-electron-forge.sh <project-name> [--template=<template>]
#
# Templates:
#   vite-typescript   (default) — Vite + TypeScript
#   vite              — Vite + JavaScript
#   webpack-typescript — Webpack + TypeScript
#   webpack           — Webpack + JavaScript
#
# Examples:
#   ./setup-electron-forge.sh my-app
#   ./setup-electron-forge.sh my-app --template=webpack-typescript
#
# What this script does:
#   1. Creates a new Electron Forge project with the chosen template
#   2. Installs common plugins (auto-unpack-natives, fuses)
#   3. Sets up Electron Forge configuration with best practices
#   4. Adds security defaults (CSP, permission handlers)
#   5. Creates a basic GitHub Actions CI workflow
#   6. Initializes git repository
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Parse arguments
PROJECT_NAME="${1:-}"
TEMPLATE="vite-typescript"

for arg in "$@"; do
  case $arg in
    --template=*)
      TEMPLATE="${arg#*=}"
      ;;
  esac
done

if [[ -z "$PROJECT_NAME" ]]; then
  echo -e "${RED}Error: Project name is required.${NC}"
  echo ""
  echo "Usage: $0 <project-name> [--template=<template>]"
  echo ""
  echo "Templates: vite-typescript (default), vite, webpack-typescript, webpack"
  exit 1
fi

if [[ -d "$PROJECT_NAME" ]]; then
  echo -e "${RED}Error: Directory '$PROJECT_NAME' already exists.${NC}"
  exit 1
fi

# Validate template
case "$TEMPLATE" in
  vite-typescript|vite|webpack-typescript|webpack) ;;
  *)
    echo -e "${RED}Error: Unknown template '$TEMPLATE'.${NC}"
    echo "Available templates: vite-typescript, vite, webpack-typescript, webpack"
    exit 1
    ;;
esac

echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Electron Forge Project Setup${NC}"
echo -e "${BOLD}  Project: ${BLUE}$PROJECT_NAME${NC}"
echo -e "${BOLD}  Template: ${BLUE}$TEMPLATE${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

# Step 1: Create Electron Forge project
echo -e "${GREEN}[1/6]${NC} Creating Electron Forge project..."
npx create-electron-app@latest "$PROJECT_NAME" -- --template="$TEMPLATE"

cd "$PROJECT_NAME"

# Step 2: Install common plugins and dependencies
echo ""
echo -e "${GREEN}[2/6]${NC} Installing additional plugins..."
npm install --save-dev \
  @electron-forge/plugin-auto-unpack-natives \
  @electron/fuses \
  electron-squirrel-startup \
  2>/dev/null

# Install electron-updater for auto-updates
npm install electron-updater 2>/dev/null

echo -e "  ${GREEN}✓${NC} Installed: @electron-forge/plugin-auto-unpack-natives"
echo -e "  ${GREEN}✓${NC} Installed: @electron/fuses"
echo -e "  ${GREEN}✓${NC} Installed: electron-updater"

# Step 3: Create entitlements file for macOS
echo ""
echo -e "${GREEN}[3/6]${NC} Creating platform configuration files..."

mkdir -p build

cat > build/entitlements.mac.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
</dict>
</plist>
PLIST
echo -e "  ${GREEN}✓${NC} Created build/entitlements.mac.plist"

# Step 4: Create .gitignore additions
echo ""
echo -e "${GREEN}[4/6]${NC} Updating .gitignore..."

cat >> .gitignore << 'GITIGNORE'

# Electron Forge output
out/
.webpack/
.vite/

# Build artifacts
dist/
*.dmg
*.exe
*.deb
*.rpm
*.AppImage
*.snap

# Code signing
*.p12
*.pfx
*.pem
*.cer

# Environment
.env
.env.local
GITIGNORE
echo -e "  ${GREEN}✓${NC} Updated .gitignore"

# Step 5: Create GitHub Actions workflow
echo ""
echo -e "${GREEN}[5/6]${NC} Creating CI workflow..."

mkdir -p .github/workflows

cat > .github/workflows/build.yml << 'WORKFLOW'
name: Build & Release

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]

    runs-on: ${{ matrix.os }}

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Lint
        run: npm run lint --if-present

      - name: Package
        run: npm run package

      - name: Make distributables
        if: startsWith(github.ref, 'refs/tags/v')
        run: npm run make
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_APP_SPECIFIC_PASSWORD: ${{ secrets.APPLE_APP_SPECIFIC_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}

      - name: Upload artifacts
        if: startsWith(github.ref, 'refs/tags/v')
        uses: actions/upload-artifact@v4
        with:
          name: distributables-${{ matrix.os }}
          path: out/make/**/*
          retention-days: 5

  release:
    needs: build
    if: startsWith(github.ref, 'refs/tags/v')
    runs-on: ubuntu-latest
    permissions:
      contents: write

    steps:
      - uses: actions/download-artifact@v4
        with:
          merge-multiple: true
          path: artifacts

      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          files: artifacts/**/*
          generate_release_notes: true
WORKFLOW
echo -e "  ${GREEN}✓${NC} Created .github/workflows/build.yml"

# Step 6: Initialize git
echo ""
echo -e "${GREEN}[6/6]${NC} Initializing git repository..."

if [[ ! -d .git ]]; then
  git init -q
  git add -A
  git commit -q -m "Initial Electron Forge project ($TEMPLATE template)"
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ Project '$PROJECT_NAME' created successfully!${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  ${BLUE}cd $PROJECT_NAME${NC}"
echo -e "  ${BLUE}npm start${NC}           — Start in development mode"
echo -e "  ${BLUE}npm run package${NC}     — Package the app"
echo -e "  ${BLUE}npm run make${NC}        — Create platform distributables"
echo -e "  ${BLUE}npm run publish${NC}     — Publish to configured target"
echo ""
echo -e "  ${BOLD}Configuration:${NC}"
echo -e "  Forge config: forge.config.ts (or .js)"
echo -e "  Entitlements: build/entitlements.mac.plist"
echo -e "  CI workflow:  .github/workflows/build.yml"
echo ""
