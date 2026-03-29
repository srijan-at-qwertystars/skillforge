#!/bin/bash
# inspect-package.sh - Inspect package contents and metadata

set -e

PACKAGE="${1:-}"

if [ -z "$PACKAGE" ]; then
    echo "Usage: $0 <package-file>"
    echo ""
    echo "Examples:"
    echo "  $0 dist/myapp_1.0.0_amd64.deb"
    echo "  $0 dist/myapp-1.0.0-1.x86_64.rpm"
    exit 1
fi

if [ ! -f "$PACKAGE" ]; then
    echo "Error: Package not found: $PACKAGE"
    exit 1
fi

echo "Inspecting: $PACKAGE"
echo ""

case "$PACKAGE" in
    *.deb)
        echo "=== Package Info ==="
        dpkg-deb -I "$PACKAGE"
        echo ""
        echo "=== Contents ==="
        dpkg-deb -c "$PACKAGE"
        echo ""
        echo "=== Control Fields ==="
        dpkg-deb -f "$PACKAGE"
        ;;
    *.rpm)
        echo "=== Package Info ==="
        rpm -qip "$PACKAGE"
        echo ""
        echo "=== Contents ==="
        rpm -qlp "$PACKAGE"
        echo ""
        echo "=== Scripts ==="
        rpm -qp --scripts "$PACKAGE" 2>/dev/null || echo "No scripts"
        ;;
    *.apk)
        echo "=== Contents ==="
        tar -tzf "$PACKAGE"
        echo ""
        echo "=== .PKGINFO ==="
        tar -xzf "$PACKAGE" -O .PKGINFO 2>/dev/null || echo "No .PKGINFO found"
        ;;
    *)
        echo "Unknown package type: $PACKAGE"
        exit 1
        ;;
esac
