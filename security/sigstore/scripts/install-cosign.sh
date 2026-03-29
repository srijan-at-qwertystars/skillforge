#!/bin/bash
# install-cosign.sh - Install cosign binary for the current platform
# Usage: ./install-cosign.sh [version] [install-path]

set -euo pipefail

VERSION="${1:-latest}"
INSTALL_PATH="${2:-/usr/local/bin}"

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "📦 Installing cosign for $OS/$ARCH"
echo "   Version: $VERSION"
echo "   Install path: $INSTALL_PATH"

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

if [ "$VERSION" = "latest" ]; then
    DOWNLOAD_URL="https://github.com/sigstore/cosign/releases/latest/download/cosign-${OS}-${ARCH}"
else
    DOWNLOAD_URL="https://github.com/sigstore/cosign/releases/download/v${VERSION}/cosign-${OS}-${ARCH}"
fi

echo "⬇️  Downloading from: $DOWNLOAD_URL"

if command -v curl &> /dev/null; then
    curl -sL "$DOWNLOAD_URL" -o "$TMP_DIR/cosign"
elif command -v wget &> /dev/null; then
    wget -q "$DOWNLOAD_URL" -O "$TMP_DIR/cosign"
else
    echo "❌ curl or wget required"
    exit 1
fi

chmod +x "$TMP_DIR/cosign"

# Verify the binary works
if ! "$TMP_DIR/cosign" version &> /dev/null; then
    echo "❌ Downloaded binary doesn't work. Check version/OS/architecture."
    exit 1
fi

echo "✅ Binary verified"

# Install (may require sudo)
if [ -w "$INSTALL_PATH" ]; then
    mv "$TMP_DIR/cosign" "$INSTALL_PATH/cosign"
else
    echo "🔐 sudo required for $INSTALL_PATH"
    sudo mv "$TMP_DIR/cosign" "$INSTALL_PATH/cosign"
fi

echo "✅ Cosign installed successfully!"
echo ""
cosign version
