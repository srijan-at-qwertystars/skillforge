#!/bin/bash
# build-all.sh - Build packages for all architectures and packagers

set -e

VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo '0.1.0')}"
DIST_DIR="${DIST_DIR:-./dist}"

# Architectures to build for
ARCHS="${ARCHS:-amd64 arm64 armhf 386}"
# Packagers to build for
PACKAGERS="${PACKAGERS:-deb rpm apk}"

mkdir -p "$DIST_DIR"

echo "Building packages version: $VERSION"
echo "Architectures: $ARCHS"
echo "Packagers: $PACKAGERS"
echo ""

for arch in $ARCHS; do
    for packager in $PACKAGERS; do
        output="${DIST_DIR}/${PACKAGER}/${arch}"
        mkdir -p "$output"
        
        echo "Building $packager for $arch..."
        if ARCH="$arch" VERSION="$VERSION" nfpm pkg \
            --config .nfpm.yaml \
            --packager "$packager" \
            --target "$output/" 2>/dev/null; then
            echo "  ✓ Success"
        else
            echo "  ✗ Failed (skipping)"
        fi
    done
done

echo ""
echo "Build complete. Packages in $DIST_DIR:"
find "$DIST_DIR" -type f \( -name "*.deb" -o -name "*.rpm" -o -name "*.apk" \) | sort
