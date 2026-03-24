#!/usr/bin/env bash
#
# build-all-platforms.sh — Cross-platform build script for Tauri v2 apps
#
# Usage:
#   ./build-all-platforms.sh [options]
#
# Options:
#   --target <target>    Build for specific target (e.g., x86_64-apple-darwin)
#   --debug              Build in debug mode (default: release)
#   --verbose            Enable verbose output
#   --no-bundle          Skip bundling (just compile)
#   --help               Show this help message
#
# Examples:
#   ./build-all-platforms.sh                                # Build for current platform
#   ./build-all-platforms.sh --target universal-apple-darwin # macOS universal binary
#   ./build-all-platforms.sh --debug --verbose              # Debug build with verbose output
#
# Notes:
#   - Cross-compilation is limited; use CI runners for other platforms.
#   - Ensure all platform dependencies are installed (run check-tauri-deps.sh).
#   - For macOS signing, set APPLE_SIGNING_IDENTITY env var.
#   - For Windows signing, set TAURI_SIGNING_PRIVATE_KEY env var.

set -euo pipefail

# --- Defaults ---
TARGET=""
BUILD_MODE="release"
VERBOSE=""
NO_BUNDLE=""

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            TARGET="$2"
            shift 2
            ;;
        --debug)
            BUILD_MODE="debug"
            shift
            ;;
        --verbose)
            VERBOSE="--verbose"
            shift
            ;;
        --no-bundle)
            NO_BUNDLE="--no-bundle"
            shift
            ;;
        --help)
            head -24 "$0" | tail -22
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Detect OS ---
OS="$(uname -s)"
ARCH="$(uname -m)"

echo "========================================"
echo " Tauri Build Script"
echo "========================================"
echo "OS:         $OS ($ARCH)"
echo "Mode:       $BUILD_MODE"
echo "Target:     ${TARGET:-current platform}"
echo "========================================"

# --- Verify Prerequisites ---
command -v cargo >/dev/null 2>&1 || { echo "Error: cargo not found. Install Rust via rustup."; exit 1; }
command -v node >/dev/null 2>&1 || { echo "Error: node not found. Install Node.js."; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "Error: npm not found. Install Node.js."; exit 1; }

# Check for tauri CLI
if ! npx tauri --version >/dev/null 2>&1; then
    echo "Tauri CLI not found. Installing..."
    npm install @tauri-apps/cli@latest
fi

# --- Install frontend dependencies ---
if [[ -f "package.json" ]]; then
    echo ""
    echo "Installing frontend dependencies..."
    npm install --prefer-offline --no-audit 2>/dev/null || npm install
fi

# --- Build frontend ---
echo ""
echo "Building frontend..."
if npm run build --if-present 2>/dev/null; then
    echo "Frontend build complete."
else
    echo "Warning: No frontend build script found; proceeding with Tauri build."
fi

# --- Construct Tauri build command ---
BUILD_CMD="npx tauri build"

if [[ "$BUILD_MODE" == "debug" ]]; then
    BUILD_CMD="$BUILD_CMD --debug"
fi

if [[ -n "$TARGET" ]]; then
    BUILD_CMD="$BUILD_CMD --target $TARGET"
fi

if [[ -n "$VERBOSE" ]]; then
    BUILD_CMD="$BUILD_CMD --verbose"
fi

if [[ -n "$NO_BUNDLE" ]]; then
    BUILD_CMD="$BUILD_CMD --no-bundle"
fi

# --- Run Build ---
echo ""
echo "Running: $BUILD_CMD"
echo "----------------------------------------"
eval "$BUILD_CMD"

# --- Report Output ---
echo ""
echo "========================================"
echo " Build Complete!"
echo "========================================"

BUNDLE_DIR="src-tauri/target"
if [[ "$BUILD_MODE" == "release" ]]; then
    BUNDLE_DIR="$BUNDLE_DIR/release/bundle"
else
    BUNDLE_DIR="$BUNDLE_DIR/debug/bundle"
fi

if [[ -n "$TARGET" ]]; then
    # Target-specific directory
    BUNDLE_DIR="src-tauri/target/${TARGET}/release/bundle"
fi

if [[ -d "$BUNDLE_DIR" ]]; then
    echo "Bundle output:"
    case "$OS" in
        Darwin)
            echo "  macOS:"
            ls -lh "$BUNDLE_DIR/dmg/"*.dmg 2>/dev/null || true
            ls -lh "$BUNDLE_DIR/macos/"*.app 2>/dev/null || true
            ;;
        Linux)
            echo "  Linux:"
            ls -lh "$BUNDLE_DIR/deb/"*.deb 2>/dev/null || true
            ls -lh "$BUNDLE_DIR/appimage/"*.AppImage 2>/dev/null || true
            ls -lh "$BUNDLE_DIR/rpm/"*.rpm 2>/dev/null || true
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "  Windows:"
            ls -lh "$BUNDLE_DIR/nsis/"*.exe 2>/dev/null || true
            ls -lh "$BUNDLE_DIR/msi/"*.msi 2>/dev/null || true
            ;;
    esac
else
    echo "Binary compiled. No bundle directory found (might be --no-bundle mode)."
fi
