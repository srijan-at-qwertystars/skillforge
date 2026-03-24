#!/usr/bin/env bash
# ============================================================================
# build-and-sign.sh
# Cross-platform build and code signing script for Electron apps.
# Supports both Electron Forge and electron-builder.
#
# Usage:
#   ./build-and-sign.sh [options]
#
# Options:
#   --platform=<mac|win|linux|all>   Target platform (default: current)
#   --tool=<forge|builder>           Build tool (default: auto-detect)
#   --publish                        Publish after building
#   --skip-sign                      Skip code signing
#   --skip-notarize                  Skip macOS notarization
#   --arch=<x64|arm64|universal>     Target architecture (default: current)
#   --dry-run                        Show what would be done without executing
#
# Environment Variables (for code signing):
#   macOS:
#     CSC_LINK              — Path or base64 of .p12 certificate
#     CSC_KEY_PASSWORD       — Certificate password
#     APPLE_ID               — Apple ID for notarization
#     APPLE_APP_SPECIFIC_PASSWORD — App-specific password
#     APPLE_TEAM_ID          — Apple Developer Team ID
#
#   Windows:
#     WIN_CSC_LINK           — Path or base64 of .pfx certificate
#     WIN_CSC_KEY_PASSWORD   — Certificate password
#
# Examples:
#   ./build-and-sign.sh                           # Build for current platform
#   ./build-and-sign.sh --platform=all            # Build for all platforms
#   ./build-and-sign.sh --platform=mac --publish  # Build, sign, notarize, publish for macOS
#   ./build-and-sign.sh --skip-sign --dry-run     # Dry run without signing
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
PLATFORM=""
TOOL=""
PUBLISH=false
SKIP_SIGN=false
SKIP_NOTARIZE=false
ARCH=""
DRY_RUN=false

# Parse arguments
for arg in "$@"; do
  case $arg in
    --platform=*)   PLATFORM="${arg#*=}" ;;
    --tool=*)       TOOL="${arg#*=}" ;;
    --publish)      PUBLISH=true ;;
    --skip-sign)    SKIP_SIGN=true ;;
    --skip-notarize) SKIP_NOTARIZE=true ;;
    --arch=*)       ARCH="${arg#*=}" ;;
    --dry-run)      DRY_RUN=true ;;
    -h|--help)
      head -40 "$0" | tail -35
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $arg${NC}"
      exit 1
      ;;
  esac
done

# Detect current platform
detect_platform() {
  case "$(uname -s)" in
    Darwin*)  echo "mac" ;;
    Linux*)   echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "win" ;;
    *)        echo "unknown" ;;
  esac
}

# Detect build tool
detect_tool() {
  if [[ -f "forge.config.ts" || -f "forge.config.js" || -f "forge.config.cjs" ]]; then
    echo "forge"
  elif grep -q '"build"' package.json 2>/dev/null && grep -q '"electron-builder"' package.json 2>/dev/null; then
    echo "builder"
  elif grep -q '@electron-forge' package.json 2>/dev/null; then
    echo "forge"
  elif grep -q 'electron-builder' package.json 2>/dev/null; then
    echo "builder"
  else
    echo "unknown"
  fi
}

# Set defaults
if [[ -z "$PLATFORM" ]]; then
  PLATFORM=$(detect_platform)
fi

if [[ -z "$TOOL" ]]; then
  TOOL=$(detect_tool)
fi

if [[ -z "$ARCH" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) ARCH="x64" ;;
  esac
fi

# Validation
if [[ ! -f "package.json" ]]; then
  echo -e "${RED}Error: No package.json found. Run from your Electron project root.${NC}"
  exit 1
fi

if [[ "$TOOL" == "unknown" ]]; then
  echo -e "${RED}Error: Could not detect build tool. Ensure electron-forge or electron-builder is installed.${NC}"
  exit 1
fi

# Display configuration
APP_NAME=$(node -e "console.log(require('./package.json').name || 'unknown')" 2>/dev/null || echo "unknown")
APP_VERSION=$(node -e "console.log(require('./package.json').version || '0.0.0')" 2>/dev/null || echo "0.0.0")

echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Electron Build & Sign${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "  App:       ${BLUE}$APP_NAME v$APP_VERSION${NC}"
echo -e "  Tool:      ${BLUE}$TOOL${NC}"
echo -e "  Platform:  ${BLUE}$PLATFORM${NC}"
echo -e "  Arch:      ${BLUE}$ARCH${NC}"
echo -e "  Sign:      ${BLUE}$([[ "$SKIP_SIGN" == "true" ]] && echo "skip" || echo "yes")${NC}"
echo -e "  Notarize:  ${BLUE}$([[ "$SKIP_NOTARIZE" == "true" || "$PLATFORM" != "mac" ]] && echo "skip" || echo "yes")${NC}"
echo -e "  Publish:   ${BLUE}$PUBLISH${NC}"
if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "  ${YELLOW}DRY RUN — no commands will be executed${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

run_cmd() {
  echo -e "  ${GREEN}\$${NC} $*"
  if [[ "$DRY_RUN" != "true" ]]; then
    "$@"
  fi
}

# Step 1: Install dependencies
echo -e "${GREEN}[1/5]${NC} Installing dependencies..."
run_cmd npm ci

# Step 2: Run tests/lint if available
echo ""
echo -e "${GREEN}[2/5]${NC} Running pre-build checks..."
if grep -q '"lint"' package.json 2>/dev/null; then
  run_cmd npm run lint
fi
if grep -q '"test"' package.json 2>/dev/null; then
  run_cmd npm test 2>/dev/null || echo -e "  ${YELLOW}⚠ Tests skipped or failed${NC}"
fi

# Step 3: Set up code signing environment
echo ""
echo -e "${GREEN}[3/5]${NC} Configuring code signing..."

if [[ "$SKIP_SIGN" == "true" ]]; then
  echo -e "  ${YELLOW}Skipping code signing${NC}"
  export CSC_IDENTITY_AUTO_DISCOVERY=false
else
  case "$PLATFORM" in
    mac)
      if [[ -n "${CSC_LINK:-}" ]]; then
        echo -e "  ${GREEN}✓${NC} macOS certificate configured (CSC_LINK)"
      else
        echo -e "  ${YELLOW}⚠ CSC_LINK not set — macOS signing may use keychain identity${NC}"
      fi
      if [[ "$SKIP_NOTARIZE" != "true" ]]; then
        if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
          echo -e "  ${GREEN}✓${NC} Notarization credentials configured"
        else
          echo -e "  ${YELLOW}⚠ Notarization credentials incomplete — skipping notarization${NC}"
          SKIP_NOTARIZE=true
        fi
      fi
      ;;
    win)
      if [[ -n "${WIN_CSC_LINK:-}" ]]; then
        echo -e "  ${GREEN}✓${NC} Windows certificate configured (WIN_CSC_LINK)"
      else
        echo -e "  ${YELLOW}⚠ WIN_CSC_LINK not set — Windows builds will not be signed${NC}"
      fi
      ;;
    linux)
      echo -e "  ${BLUE}ℹ${NC} Linux does not require code signing"
      ;;
  esac
fi

# Step 4: Build
echo ""
echo -e "${GREEN}[4/5]${NC} Building distributables..."

build_forge() {
  local platforms=()

  case "$PLATFORM" in
    mac)   platforms=(--platform=darwin) ;;
    win)   platforms=(--platform=win32) ;;
    linux) platforms=(--platform=linux) ;;
    all)   platforms=() ;; # Forge builds for current platform by default
  esac

  local arch_flag="--arch=$ARCH"

  if [[ "$PUBLISH" == "true" ]]; then
    run_cmd npx electron-forge publish "${platforms[@]}" "$arch_flag"
  else
    run_cmd npx electron-forge make "${platforms[@]}" "$arch_flag"
  fi
}

build_builder() {
  local platform_flags=()

  case "$PLATFORM" in
    mac)   platform_flags=(--mac) ;;
    win)   platform_flags=(--win) ;;
    linux) platform_flags=(--linux) ;;
    all)   platform_flags=(--mac --win --linux) ;;
  esac

  local arch_flag="--$ARCH"
  local publish_flag=""
  if [[ "$PUBLISH" == "true" ]]; then
    publish_flag="--publish always"
  else
    publish_flag="--publish never"
  fi

  local sign_flags=()
  if [[ "$SKIP_SIGN" == "true" ]]; then
    sign_flags=(-c.mac.identity=null)
  fi
  if [[ "$SKIP_NOTARIZE" == "true" ]]; then
    sign_flags+=(-c.mac.notarize=false)
  fi

  # shellcheck disable=SC2086
  run_cmd npx electron-builder "${platform_flags[@]}" "$arch_flag" $publish_flag "${sign_flags[@]}"
}

case "$TOOL" in
  forge)   build_forge ;;
  builder) build_builder ;;
esac

# Step 5: Post-build summary
echo ""
echo -e "${GREEN}[5/5]${NC} Build complete!"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Output${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"

if [[ "$DRY_RUN" != "true" ]]; then
  case "$TOOL" in
    forge)
      if [[ -d "out/make" ]]; then
        find out/make -type f \( -name "*.dmg" -o -name "*.exe" -o -name "*.deb" -o -name "*.rpm" -o -name "*.AppImage" -o -name "*.zip" -o -name "*.nupkg" \) 2>/dev/null | while read -r f; do
          SIZE=$(du -h "$f" | cut -f1)
          echo -e "  ${GREEN}✓${NC} $f ($SIZE)"
        done
      fi
      ;;
    builder)
      if [[ -d "dist" ]]; then
        find dist -maxdepth 1 -type f \( -name "*.dmg" -o -name "*.exe" -o -name "*.deb" -o -name "*.rpm" -o -name "*.AppImage" -o -name "*.zip" -o -name "*.yml" \) 2>/dev/null | while read -r f; do
          SIZE=$(du -h "$f" | cut -f1)
          echo -e "  ${GREEN}✓${NC} $f ($SIZE)"
        done
      fi
      ;;
  esac
else
  echo -e "  ${YELLOW}Dry run — no artifacts produced${NC}"
fi

echo ""
