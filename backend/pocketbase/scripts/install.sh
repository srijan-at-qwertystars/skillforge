#!/bin/bash
# PocketBase Installation Script
# Downloads and installs the latest PocketBase binary

set -e

VERSION="${1:-latest}"
OS="${2:-linux}"
ARCH="${3:-amd64}"
INSTALL_DIR="${4:-/usr/local/bin}"

echo "Installing PocketBase ${VERSION} for ${OS}_${ARCH}..."

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Download URL
if [ "$VERSION" = "latest" ]; then
    URL="https://github.com/pocketbase/pocketbase/releases/latest/download/pocketbase_${OS}_${ARCH}.zip"
else
    URL="https://github.com/pocketbase/pocketbase/releases/download/v${VERSION}/pocketbase_${OS}_${ARCH}.zip"
fi

echo "Downloading from: $URL"
curl -L "$URL" -o "$TMP_DIR/pocketbase.zip"

# Extract
echo "Extracting..."
unzip -q "$TMP_DIR/pocketbase.zip" -d "$TMP_DIR"

# Install
if [ -w "$INSTALL_DIR" ]; then
    mv "$TMP_DIR/pocketbase" "$INSTALL_DIR/pocketbase"
    chmod +x "$INSTALL_DIR/pocketbase"
else
    echo "Need sudo to install to $INSTALL_DIR"
    sudo mv "$TMP_DIR/pocketbase" "$INSTALL_DIR/pocketbase"
    sudo chmod +x "$INSTALL_DIR/pocketbase"
fi

echo "PocketBase installed to: $INSTALL_DIR/pocketbase"
echo "Version: $(pocketbase --version)"
