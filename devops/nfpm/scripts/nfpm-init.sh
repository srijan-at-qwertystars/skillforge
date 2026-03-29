#!/bin/bash
# nfpm-init.sh - Initialize nfpm configuration for a project

set -e

PROJECT_NAME="${1:-$(basename $(pwd))}"
MAINTAINER="${2:-$(git config user.name) <$(git config user.email)>}"

echo "Initializing nfpm for project: $PROJECT_NAME"
echo "Maintainer: $MAINTAINER"

# Check if nfpm is installed
if ! command -v nfpm &> /dev/null; then
    echo "nfpm not found. Installing..."
    go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
fi

# Create .nfpm.yaml if it doesn't exist
if [ -f ".nfpm.yaml" ]; then
    echo ".nfpm.yaml already exists. Skipping creation."
else
    cat > .nfpm.yaml << EOF
name: ${PROJECT_NAME}
arch: amd64
platform: linux
version: "\${VERSION:-0.1.0}"
section: default
priority: extra
maintainer: "${MAINTAINER}"
description: |
  ${PROJECT_NAME} package.
  Add your description here.

contents:
  # Add your binary
  # - src: ./dist/${PROJECT_NAME}
  #   dst: /usr/bin/${PROJECT_NAME}
  #   file_info:
  #     mode: 0755

  # Add config file (config|noreplace preserves user changes)
  # - src: ./config/${PROJECT_NAME}.conf
  #   dst: /etc/${PROJECT_NAME}/config.conf
  #   type: config|noreplace
  #   file_info:
  #     mode: 0644

  # Create data directory
  # - dst: /var/lib/${PROJECT_NAME}
  #   type: dir
  #   file_info:
  #     mode: 0750

# depends:
#   - libc6

# scripts:
#   postinstall: ./scripts/postinstall.sh
#   preremove: ./scripts/preremove.sh
EOF
    echo "Created .nfpm.yaml"
fi

# Create scripts directory
mkdir -p scripts

# Create postinstall template
if [ ! -f "scripts/postinstall.sh" ]; then
    cat > scripts/postinstall.sh << 'EOF'
#!/bin/sh
set -e

# Post-install script
# $1 = configure (deb) or package count (rpm)

echo "Package installed successfully"
EOF
    chmod +x scripts/postinstall.sh
    echo "Created scripts/postinstall.sh"
fi

# Create preremove template
if [ ! -f "scripts/preremove.sh" ]; then
    cat > scripts/preremove.sh << 'EOF'
#!/bin/sh
set -e

# Pre-remove script
# $1 = remove (deb) or package count (rpm)

echo "Removing package..."
EOF
    chmod +x scripts/preremove.sh
    echo "Created scripts/preremove.sh"
fi

# Create build script
if [ ! -f "scripts/build-packages.sh" ]; then
    cat > scripts/build-packages.sh << 'EOF'
#!/bin/bash
# Build packages for all supported formats

set -e

VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo '0.1.0')}"
ARCH="${ARCH:-amd64}"
DIST_DIR="${DIST_DIR:-./dist}"

mkdir -p "$DIST_DIR"

for packager in deb rpm apk; do
    echo "Building $packager package..."
    nfpm pkg \
        --config .nfpm.yaml \
        --packager "$packager" \
        --target "$DIST_DIR/"
done

echo "Packages built in $DIST_DIR:"
ls -la "$DIST_DIR/"
EOF
    chmod +x scripts/build-packages.sh
    echo "Created scripts/build-packages.sh"
fi

echo ""
echo "nfpm initialization complete!"
echo "Next steps:"
echo "  1. Edit .nfpm.yaml to configure your package"
echo "  2. Add your binaries to the contents section"
echo "  3. Run: ./scripts/build-packages.sh"
