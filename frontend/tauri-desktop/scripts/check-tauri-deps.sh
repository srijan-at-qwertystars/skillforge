#!/usr/bin/env bash
#
# check-tauri-deps.sh — Check system for required Tauri v2 build dependencies
#
# Usage:
#   ./check-tauri-deps.sh
#
# Checks for:
#   - Rust toolchain (rustc, cargo)
#   - Node.js and npm
#   - Platform-specific system libraries
#   - Tauri CLI
#   - Optional tools (code signing, etc.)
#
# Exit codes:
#   0 — All required dependencies found
#   1 — Missing required dependencies

set -euo pipefail

MISSING=0
WARNINGS=0

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    BLUE=''
    NC=''
fi

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; MISSING=$((MISSING + 1)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
info() { echo -e "  ${BLUE}ℹ${NC} $1"; }

check_cmd() {
    local cmd="$1"
    local label="${2:-$1}"
    if command -v "$cmd" >/dev/null 2>&1; then
        local version
        version=$("$cmd" --version 2>/dev/null | head -1)
        ok "$label: $version"
        return 0
    else
        fail "$label: not found"
        return 1
    fi
}

check_lib() {
    local lib="$1"
    local label="${2:-$1}"
    if pkg-config --exists "$lib" 2>/dev/null; then
        local version
        version=$(pkg-config --modversion "$lib" 2>/dev/null)
        ok "$label: $version"
        return 0
    else
        fail "$label: not found"
        return 1
    fi
}

OS="$(uname -s)"
ARCH="$(uname -m)"

echo "========================================"
echo " Tauri v2 Dependency Check"
echo "========================================"
echo " OS: $OS ($ARCH)"
echo "========================================"
echo ""

# --- Core Tools ---
echo "Core Tools:"
check_cmd "rustc" "Rust compiler" || true
check_cmd "cargo" "Cargo" || true

if command -v rustc >/dev/null 2>&1; then
    RUST_VER=$(rustc --version | grep -oP '\d+\.\d+\.\d+')
    RUST_MAJOR=$(echo "$RUST_VER" | cut -d. -f1)
    RUST_MINOR=$(echo "$RUST_VER" | cut -d. -f2)
    if [[ "$RUST_MAJOR" -lt 1 ]] || [[ "$RUST_MAJOR" -eq 1 && "$RUST_MINOR" -lt 77 ]]; then
        warn "Rust $RUST_VER is old; Tauri v2 recommends 1.77+"
    fi
fi

check_cmd "node" "Node.js" || true

if command -v node >/dev/null 2>&1; then
    NODE_VER=$(node --version | tr -d 'v')
    NODE_MAJOR=$(echo "$NODE_VER" | cut -d. -f1)
    if [[ "$NODE_MAJOR" -lt 18 ]]; then
        warn "Node.js $NODE_VER is old; recommend 18+"
    fi
fi

check_cmd "npm" "npm" || true
echo ""

# --- Tauri CLI ---
echo "Tauri CLI:"
if npx tauri --version >/dev/null 2>&1; then
    TAURI_VER=$(npx tauri --version 2>/dev/null)
    ok "Tauri CLI: $TAURI_VER"
else
    warn "Tauri CLI not installed (install with: npm install @tauri-apps/cli)"
fi
echo ""

# --- Platform-Specific Dependencies ---
echo "Platform Dependencies:"

case "$OS" in
    Linux)
        check_lib "webkit2gtk-4.1" "WebKitGTK 4.1" || true
        check_lib "gtk+-3.0" "GTK+ 3.0" || true
        check_lib "glib-2.0" "GLib 2.0" || true

        # Check for appindicator (optional, for system tray)
        if pkg-config --exists ayatana-appindicator3-0.1 2>/dev/null; then
            ok "AppIndicator (ayatana): $(pkg-config --modversion ayatana-appindicator3-0.1)"
        elif pkg-config --exists appindicator3-0.1 2>/dev/null; then
            ok "AppIndicator: $(pkg-config --modversion appindicator3-0.1)"
        else
            warn "AppIndicator: not found (needed for system tray)"
        fi

        check_lib "librsvg-2.0" "librsvg" || true
        check_cmd "patchelf" "patchelf" || true

        echo ""
        echo "Install missing Linux deps with:"
        echo "  Ubuntu/Debian:"
        info "sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev patchelf"
        echo "  Fedora:"
        info "sudo dnf install webkit2gtk4.1-devel gtk3-devel libappindicator-gtk3-devel librsvg2-devel"
        echo "  Arch:"
        info "sudo pacman -S webkit2gtk-4.1 gtk3 libappindicator-gtk3 librsvg patchelf"
        ;;

    Darwin)
        if xcode-select -p >/dev/null 2>&1; then
            ok "Xcode Command Line Tools: installed"
        else
            fail "Xcode Command Line Tools: not installed (run: xcode-select --install)"
        fi

        # Check for universal binary targets
        if rustup target list --installed 2>/dev/null | grep -q "aarch64-apple-darwin"; then
            ok "Rust target: aarch64-apple-darwin"
        else
            warn "Rust target aarch64-apple-darwin not installed (needed for universal binary)"
        fi

        if rustup target list --installed 2>/dev/null | grep -q "x86_64-apple-darwin"; then
            ok "Rust target: x86_64-apple-darwin"
        else
            warn "Rust target x86_64-apple-darwin not installed (needed for universal binary)"
        fi
        ;;

    MINGW*|MSYS*|CYGWIN*)
        # Check for Visual Studio Build Tools
        if command -v cl >/dev/null 2>&1; then
            ok "MSVC compiler: found"
        else
            warn "MSVC compiler: not found in PATH (Visual Studio Build Tools may still be installed)"
        fi

        # Check WebView2
        WEBVIEW2_KEY="HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
        if reg query "$WEBVIEW2_KEY" >/dev/null 2>&1; then
            ok "WebView2 Runtime: installed"
        else
            warn "WebView2 Runtime: not detected (will be installed with the app)"
        fi
        ;;

    *)
        warn "Unknown OS: $OS — cannot check platform dependencies"
        ;;
esac

echo ""

# --- Optional Tools ---
echo "Optional Tools:"
check_cmd "git" "Git" || true

if command -v cargo-tauri >/dev/null 2>&1; then
    ok "cargo-tauri: installed"
else
    info "cargo-tauri: not installed (optional, use npx tauri instead)"
fi

echo ""

# --- Summary ---
echo "========================================"
if [[ $MISSING -eq 0 ]]; then
    echo -e " ${GREEN}All required dependencies found!${NC}"
else
    echo -e " ${RED}Missing $MISSING required dependency(ies).${NC}"
fi
if [[ $WARNINGS -gt 0 ]]; then
    echo -e " ${YELLOW}$WARNINGS warning(s) — see above.${NC}"
fi
echo "========================================"

exit $MISSING
