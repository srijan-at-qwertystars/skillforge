#!/bin/bash
# sign-packages.sh - Sign packages with GPG/RSA keys

set -e

DIST_DIR="${DIST_DIR:-./dist}"
GPG_KEY_ID="${GPG_KEY_ID:-}"
DEB_SIGN_METHOD="${DEB_SIGN_METHOD:-dpkg-sig}"

if [ -z "$GPG_KEY_ID" ]; then
    echo "Error: GPG_KEY_ID not set"
    echo "Usage: GPG_KEY_ID=<key-id> $0"
    exit 1
fi

echo "Signing packages with key: $GPG_KEY_ID"
echo ""

# Sign .deb packages
for pkg in "$DIST_DIR"/*.deb; do
    if [ -f "$pkg" ]; then
        echo "Signing $pkg..."
        case "$DEB_SIGN_METHOD" in
            dpkg-sig)
                dpkg-sig --sign builder -k "$GPG_KEY_ID" "$pkg"
                ;;
            debsigs)
                debsigs --sign=builder -k "$GPG_KEY_ID" "$pkg"
                ;;
            *)
                echo "Unknown sign method: $DEB_SIGN_METHOD"
                exit 1
                ;;
        esac
    fi
done

# Sign .rpm packages
for pkg in "$DIST_DIR"/*.rpm; do
    if [ -f "$pkg" ]; then
        echo "Signing $pkg..."
        rpm --addsign "$pkg"
    fi
done

# Note: APK packages need RSA keys, not GPG
echo ""
echo "Note: APK packages require RSA signing, not GPG."
echo "Use 'abuild-sign' or include signature in nfpm config."

echo ""
echo "Signing complete!"
