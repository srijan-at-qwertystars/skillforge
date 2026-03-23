#!/usr/bin/env bash
# caddy-install.sh — Cross-platform Caddy installation script
# Supports: apt (Debian/Ubuntu), dnf (Fedora/RHEL), brew (macOS), and binary download
set -euo pipefail

VERSION="${1:-latest}"
INSTALL_DIR="/usr/local/bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BOLD}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $1"; exit 1; }

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-$OS_ID}"
    elif [[ "$(uname)" == "Darwin" ]]; then
        OS_ID="macos"
        OS_ID_LIKE="macos"
    else
        OS_ID="unknown"
        OS_ID_LIKE="unknown"
    fi
}

detect_arch() {
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) fail "Unsupported architecture: $ARCH" ;;
    esac
}

install_apt() {
    info "Installing Caddy via apt (Debian/Ubuntu)..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq caddy
    success "Caddy installed via apt"
}

install_dnf() {
    info "Installing Caddy via dnf (Fedora/RHEL)..."
    sudo dnf install -y -q 'dnf-command(copr)'
    sudo dnf copr enable -y @caddy/caddy
    sudo dnf install -y -q caddy
    success "Caddy installed via dnf"
}

install_brew() {
    info "Installing Caddy via Homebrew..."
    if ! command -v brew &>/dev/null; then
        fail "Homebrew not found. Install from https://brew.sh"
    fi
    brew install caddy
    success "Caddy installed via Homebrew"
}

install_binary() {
    info "Installing Caddy via binary download..."

    detect_arch
    local OS
    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

    local DOWNLOAD_URL
    if [[ "$VERSION" == "latest" ]]; then
        DOWNLOAD_URL="https://caddyserver.com/api/download?os=${OS}&arch=${ARCH}"
    else
        DOWNLOAD_URL="https://caddyserver.com/api/download?os=${OS}&arch=${ARCH}&version=${VERSION}"
    fi

    local TMPFILE
    TMPFILE="$(mktemp)"
    trap 'rm -f "$TMPFILE"' EXIT

    info "Downloading from: $DOWNLOAD_URL"
    if ! curl -fsSL -o "$TMPFILE" "$DOWNLOAD_URL"; then
        fail "Download failed. Check version and connectivity."
    fi

    sudo install -m 0755 "$TMPFILE" "${INSTALL_DIR}/caddy"
    success "Caddy binary installed to ${INSTALL_DIR}/caddy"
}

setup_systemd() {
    if [[ "$(uname)" == "Darwin" ]] || [[ ! -d /etc/systemd/system ]]; then
        return
    fi

    if [[ -f /etc/systemd/system/caddy.service ]]; then
        info "Systemd unit already exists"
        return
    fi

    info "Setting up systemd service..."

    # Create caddy user if not exists
    if ! id caddy &>/dev/null; then
        sudo useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
    fi

    # Create directories
    sudo mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    sudo chown -R caddy:caddy /var/lib/caddy /var/log/caddy

    # Create default Caddyfile if not exists
    if [[ ! -f /etc/caddy/Caddyfile ]]; then
        cat <<'CADDYEOF' | sudo tee /etc/caddy/Caddyfile >/dev/null
# Default Caddyfile — customize for your needs
:80 {
    respond "Caddy is running!" 200
}
CADDYEOF
        sudo chown root:caddy /etc/caddy/Caddyfile
        sudo chmod 640 /etc/caddy/Caddyfile
    fi

    # Grant port binding capability
    if command -v setcap &>/dev/null; then
        sudo setcap cap_net_bind_service=+ep "$(command -v caddy)"
    fi

    success "Systemd service configured"
    info "Enable and start: sudo systemctl enable --now caddy"
}

verify_installation() {
    echo ""
    info "Verifying installation..."
    if command -v caddy &>/dev/null; then
        local VER
        VER="$(caddy version 2>/dev/null || echo 'unknown')"
        success "Caddy installed: $VER"
        echo ""
        info "Loaded modules:"
        caddy list-modules --versions 2>/dev/null | head -10
        echo "  ... (run 'caddy list-modules' for full list)"
    else
        fail "Caddy binary not found in PATH after installation"
    fi
}

# --- Main ---
echo -e "${BOLD}=== Caddy Installation Script ===${NC}"
echo ""

detect_os
info "Detected OS: $OS_ID (like: $OS_ID_LIKE)"

case "$OS_ID" in
    ubuntu|debian|linuxmint|pop)
        install_apt
        ;;
    fedora|rhel|centos|rocky|alma)
        install_dnf
        ;;
    macos)
        install_brew
        ;;
    *)
        # Fallback: check if apt or dnf is available
        if command -v apt-get &>/dev/null; then
            install_apt
        elif command -v dnf &>/dev/null; then
            install_dnf
        elif command -v brew &>/dev/null; then
            install_brew
        else
            info "No supported package manager found — downloading binary"
            install_binary
        fi
        ;;
esac

setup_systemd
verify_installation

echo ""
success "Installation complete!"
echo ""
info "Next steps:"
echo "  1. Edit /etc/caddy/Caddyfile (or create one in current directory)"
echo "  2. Run: caddy validate --config /etc/caddy/Caddyfile"
echo "  3. Run: sudo systemctl enable --now caddy"
echo "  4. Or run interactively: caddy run --config Caddyfile"
