#!/bin/bash
# test-package.sh - Test packages in Docker containers

set -e

DIST_DIR="${DIST_DIR:-./dist}"
PACKAGE_NAME="${1:-}"

if [ -z "$PACKAGE_NAME" ]; then
    echo "Usage: $0 <package-file>"
    echo ""
    echo "Examples:"
    echo "  $0 dist/myapp_1.0.0_amd64.deb"
    echo "  $0 dist/myapp-1.0.0-1.x86_64.rpm"
    exit 1
fi

if [ ! -f "$PACKAGE_NAME" ]; then
    echo "Error: Package not found: $PACKAGE_NAME"
    exit 1
fi

echo "Testing package: $PACKAGE_NAME"

# Determine package type and test accordingly
case "$PACKAGE_NAME" in
    *.deb)
        echo "Testing Debian package..."
        docker run --rm -v "$(pwd)/$DIST_DIR:/pkgs" ubuntu:22.04 \
            bash -c "dpkg -i /pkgs/$(basename $PACKAGE_NAME) && apt-get install -f -y || true"
        ;;
    *.rpm)
        echo "Testing RPM package..."
        docker run --rm -v "$(pwd)/$DIST_DIR:/pkgs" fedora:39 \
            bash -c "rpm -ivh /pkgs/$(basename $PACKAGE_NAME) || yum localinstall -y /pkgs/$(basename $PACKAGE_NAME)"
        ;;
    *.apk)
        echo "Testing APK package..."
        docker run --rm -v "$(pwd)/$DIST_DIR:/pkgs" alpine:3.19 \
            sh -c "apk add --allow-untrusted /pkgs/$(basename $PACKAGE_NAME)"
        ;;
    *)
        echo "Unknown package type: $PACKAGE_NAME"
        exit 1
        ;;
esac

echo ""
echo "Package test complete!"
