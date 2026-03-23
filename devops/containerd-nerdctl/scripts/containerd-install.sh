#!/usr/bin/env bash
# containerd-install.sh — Install containerd + nerdctl + CNI plugins + BuildKit on Linux
#
# Usage: sudo ./containerd-install.sh [--rootless]
#   --rootless   Install rootless containerd for the current user (no sudo required after install)
#
# Requirements: Linux (amd64 or arm64), curl or wget, tar

set -euo pipefail

# Versions — update these as needed
CONTAINERD_VERSION="2.0.4"
NERDCTL_VERSION="2.2.1"
CNI_VERSION="1.6.2"
BUILDKIT_VERSION="0.20.1"
RUNC_VERSION="1.2.5"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# Detect architecture
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       die "Unsupported architecture: $arch" ;;
    esac
}

# Detect download tool
download() {
    local url="$1" dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -q -O "$dest" "$url"
    else
        die "Neither curl nor wget found. Install one and retry."
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo). For rootless install, use: sudo $0 --rootless"
    fi
}

ARCH=$(detect_arch)
ROOTLESS=false
TMPDIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --rootless) ROOTLESS=true ;;
        --help|-h)
            echo "Usage: sudo $0 [--rootless]"
            echo "  --rootless   Install rootless containerd for the current user"
            exit 0
            ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

install_runc() {
    info "Installing runc ${RUNC_VERSION}..."
    download "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${ARCH}" "${TMPDIR}/runc"
    install -m 755 "${TMPDIR}/runc" /usr/local/sbin/runc
    info "runc $(runc --version | head -1) installed."
}

install_containerd() {
    info "Installing containerd ${CONTAINERD_VERSION}..."
    local tarball="containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
    download "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/${tarball}" "${TMPDIR}/${tarball}"
    tar -C /usr/local -xzf "${TMPDIR}/${tarball}"

    # Install systemd service if not present
    if [[ ! -f /usr/local/lib/systemd/system/containerd.service ]]; then
        mkdir -p /usr/local/lib/systemd/system
        download "https://raw.githubusercontent.com/containerd/containerd/main/containerd.service" \
            /usr/local/lib/systemd/system/containerd.service
    fi

    # Generate default config
    mkdir -p /etc/containerd
    if [[ ! -f /etc/containerd/config.toml ]]; then
        containerd config default > /etc/containerd/config.toml
        # Enable SystemdCgroup for cgroup v2
        if grep -q "SystemdCgroup" /etc/containerd/config.toml; then
            sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        fi
        info "Generated default config at /etc/containerd/config.toml"
    else
        warn "Config already exists at /etc/containerd/config.toml — not overwriting."
    fi

    systemctl daemon-reload
    systemctl enable --now containerd
    info "containerd $(containerd --version) installed and started."
}

install_nerdctl() {
    info "Installing nerdctl ${NERDCTL_VERSION}..."
    local tarball="nerdctl-${NERDCTL_VERSION}-linux-${ARCH}.tar.gz"
    download "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/${tarball}" "${TMPDIR}/${tarball}"
    tar -C /usr/local/bin -xzf "${TMPDIR}/${tarball}"
    info "nerdctl $(nerdctl --version) installed."
}

install_cni_plugins() {
    info "Installing CNI plugins ${CNI_VERSION}..."
    local tarball="cni-plugins-linux-${ARCH}-v${CNI_VERSION}.tgz"
    download "https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/${tarball}" "${TMPDIR}/${tarball}"
    mkdir -p /opt/cni/bin
    tar -C /opt/cni/bin -xzf "${TMPDIR}/${tarball}"
    info "CNI plugins installed to /opt/cni/bin/."
}

install_buildkit() {
    info "Installing BuildKit ${BUILDKIT_VERSION}..."
    local tarball="buildkit-v${BUILDKIT_VERSION}.linux-${ARCH}.tar.gz"
    download "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/${tarball}" "${TMPDIR}/${tarball}"
    tar -C /usr/local -xzf "${TMPDIR}/${tarball}"

    # Install systemd service if not present
    if [[ ! -f /usr/local/lib/systemd/system/buildkit.service ]]; then
        mkdir -p /usr/local/lib/systemd/system
        cat > /usr/local/lib/systemd/system/buildkit.service <<'UNIT'
[Unit]
Description=BuildKit
Documentation=https://github.com/moby/buildkit
After=containerd.service

[Service]
Type=notify
ExecStart=/usr/local/bin/buildkitd --oci-worker=false --containerd-worker=true

[Install]
WantedBy=multi-user.target
UNIT
    fi

    systemctl daemon-reload
    systemctl enable --now buildkit
    info "BuildKit $(buildkitd --version 2>/dev/null || echo "${BUILDKIT_VERSION}") installed and started."
}

install_rootless() {
    info "Setting up rootless containerd..."
    local target_user="${SUDO_USER:-}"
    [[ -z "$target_user" ]] && die "Cannot determine target user. Run with: sudo -E $0 --rootless"

    # Install prerequisites
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq uidmap slirp4netns fuse-overlayfs >/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q shadow-utils slirp4netns fuse-overlayfs >/dev/null
    fi

    # Set up subuid/subgid if not configured
    if ! grep -q "^${target_user}:" /etc/subuid 2>/dev/null; then
        usermod --add-subuids 100000-165535 "$target_user"
        usermod --add-subgids 100000-165535 "$target_user"
        info "Configured subuid/subgid for ${target_user}."
    fi

    # Enable lingering for systemd user services
    loginctl enable-linger "$target_user"

    info "Run the following as ${target_user} (without sudo):"
    echo "  containerd-rootless-setuptool.sh install"
    echo "  containerd-rootless-setuptool.sh install-buildkit"
}

verify_installation() {
    echo ""
    info "=== Installation Summary ==="
    echo -e "  runc:       $(runc --version 2>/dev/null | head -1 || echo 'not found')"
    echo -e "  containerd: $(containerd --version 2>/dev/null || echo 'not found')"
    echo -e "  nerdctl:    $(nerdctl --version 2>/dev/null || echo 'not found')"
    echo -e "  buildkitd:  $(buildkitd --version 2>/dev/null || echo 'not found')"
    echo -e "  CNI:        $(ls /opt/cni/bin/ 2>/dev/null | wc -l) plugins in /opt/cni/bin/"
    echo ""

    info "=== Service Status ==="
    systemctl is-active containerd && info "containerd is running" || warn "containerd is NOT running"
    systemctl is-active buildkit && info "buildkit is running" || warn "buildkit is NOT running"
    echo ""

    info "=== Quick Test ==="
    if nerdctl run --rm alpine echo "Hello from containerd + nerdctl!" 2>/dev/null; then
        info "Installation verified successfully!"
    else
        warn "Quick test failed. Check containerd logs: journalctl -u containerd"
    fi
}

# Main
check_root
info "Installing containerd stack for linux/${ARCH}..."
echo ""

install_runc
install_containerd
install_nerdctl
install_cni_plugins
install_buildkit

if $ROOTLESS; then
    install_rootless
fi

verify_installation
info "Done! Run 'nerdctl run --rm alpine echo hello' to verify."
