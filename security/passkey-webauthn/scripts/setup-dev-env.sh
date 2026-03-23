#!/usr/bin/env bash
# setup-dev-env.sh — Set up local HTTPS development environment for WebAuthn testing.
#
# Creates a local CA and TLS certificates using mkcert so WebAuthn works
# with full HTTPS in development. Also configures common dev servers.
#
# Usage:
#     ./setup-dev-env.sh                      # interactive setup
#     ./setup-dev-env.sh --domain localhost    # specify domain
#     ./setup-dev-env.sh --skip-install        # skip mkcert installation
#     ./setup-dev-env.sh --output-dir ./certs  # custom certificate output dir
#
# Supports: macOS (Homebrew), Ubuntu/Debian (apt), Fedora/RHEL (dnf)

set -euo pipefail

# --- Configuration ---
DOMAIN="${DOMAIN:-localhost}"
OUTPUT_DIR="${OUTPUT_DIR:-./certs}"
SKIP_INSTALL=false
GENERATE_NGINX=false
GENERATE_NODE=false
PORT="${PORT:-3000}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain|-d)
            DOMAIN="$2"
            shift 2
            ;;
        --output-dir|-o)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --port|-p)
            PORT="$2"
            shift 2
            ;;
        --skip-install)
            SKIP_INSTALL=true
            shift
            ;;
        --nginx)
            GENERATE_NGINX=true
            shift
            ;;
        --node)
            GENERATE_NODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --domain, -d DOMAIN     Domain name (default: localhost)"
            echo "  --output-dir, -o DIR    Certificate output directory (default: ./certs)"
            echo "  --port, -p PORT         Dev server port (default: 3000)"
            echo "  --skip-install          Skip mkcert installation"
            echo "  --nginx                 Generate nginx config snippet"
            echo "  --node                  Generate Node.js HTTPS server snippet"
            echo "  --help, -h              Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "================================================"
echo "  WebAuthn Local HTTPS Development Setup"
echo "================================================"
echo ""
log_info "Domain:     ${DOMAIN}"
log_info "Output dir: ${OUTPUT_DIR}"
log_info "Port:       ${PORT}"
echo ""

# --- Step 1: Check/install mkcert ---
install_mkcert() {
    log_info "Installing mkcert..."

    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew &>/dev/null; then
            brew install mkcert
            # Install nss for Firefox support
            if brew list --formula | grep -q nss 2>/dev/null; then
                log_info "nss already installed"
            else
                brew install nss
            fi
        else
            log_error "Homebrew not found. Install from https://brew.sh/"
            exit 1
        fi
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq libnss3-tools
        # Install mkcert from binary
        MKCERT_VERSION="v1.4.4"
        ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
        curl -fsSL "https://dl.filippo.io/mkcert/latest?for=linux/${ARCH}" -o /tmp/mkcert
        chmod +x /tmp/mkcert
        sudo mv /tmp/mkcert /usr/local/bin/mkcert
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y nss-tools
        MKCERT_VERSION="v1.4.4"
        ARCH=$(uname -m)
        [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
        curl -fsSL "https://dl.filippo.io/mkcert/latest?for=linux/${ARCH}" -o /tmp/mkcert
        chmod +x /tmp/mkcert
        sudo mv /tmp/mkcert /usr/local/bin/mkcert
    else
        log_error "Unsupported package manager. Install mkcert manually:"
        log_error "  https://github.com/FiloSottile/mkcert#installation"
        exit 1
    fi
}

if ! command -v mkcert &>/dev/null; then
    if [[ "$SKIP_INSTALL" == "true" ]]; then
        log_error "mkcert not found. Run without --skip-install or install manually."
        exit 1
    fi
    install_mkcert
    log_ok "mkcert installed"
else
    log_ok "mkcert already installed: $(mkcert --version 2>/dev/null || echo 'unknown version')"
fi

# --- Step 2: Install local CA ---
log_info "Installing local CA (may require sudo)..."
mkcert -install 2>/dev/null || {
    log_warn "Could not install CA automatically. You may need to run 'mkcert -install' manually."
}
log_ok "Local CA installed"

# --- Step 3: Generate certificates ---
mkdir -p "${OUTPUT_DIR}"

CERT_FILE="${OUTPUT_DIR}/${DOMAIN}.pem"
KEY_FILE="${OUTPUT_DIR}/${DOMAIN}-key.pem"

log_info "Generating certificates for: ${DOMAIN}, 127.0.0.1, ::1"

cd "${OUTPUT_DIR}"
mkcert "${DOMAIN}" "127.0.0.1" "::1" 2>/dev/null

# mkcert names files based on the first domain
GENERATED_CERT=$(ls -1 "${DOMAIN}"*.pem 2>/dev/null | grep -v '\-key' | head -1)
GENERATED_KEY=$(ls -1 "${DOMAIN}"*-key.pem 2>/dev/null | head -1)

if [[ -z "$GENERATED_CERT" || -z "$GENERATED_KEY" ]]; then
    log_error "Certificate generation failed"
    exit 1
fi

# Rename to predictable names
if [[ "$GENERATED_CERT" != "${DOMAIN}.pem" ]]; then
    mv "$GENERATED_CERT" "${DOMAIN}.pem"
fi
if [[ "$GENERATED_KEY" != "${DOMAIN}-key.pem" ]]; then
    mv "$GENERATED_KEY" "${DOMAIN}-key.pem"
fi

cd - >/dev/null

log_ok "Certificate: ${CERT_FILE}"
log_ok "Private key: ${KEY_FILE}"

# --- Step 4: Verify certificates ---
log_info "Verifying certificate..."
if command -v openssl &>/dev/null; then
    SUBJECT=$(openssl x509 -in "${CERT_FILE}" -noout -subject 2>/dev/null || echo "unknown")
    EXPIRE=$(openssl x509 -in "${CERT_FILE}" -noout -enddate 2>/dev/null || echo "unknown")
    log_ok "Subject: ${SUBJECT}"
    log_ok "Expires: ${EXPIRE}"
fi

# --- Step 5: Generate config snippets ---
if [[ "$GENERATE_NGINX" == "true" ]]; then
    NGINX_CONF="${OUTPUT_DIR}/nginx-dev.conf"
    cat > "${NGINX_CONF}" << NGINX_EOF
# Nginx HTTPS config for WebAuthn development
# Include this in your nginx.conf server block

server {
    listen ${PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     $(realpath "${CERT_FILE}");
    ssl_certificate_key $(realpath "${KEY_FILE}");

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX_EOF
    log_ok "Nginx config: ${NGINX_CONF}"
fi

if [[ "$GENERATE_NODE" == "true" ]]; then
    NODE_SNIPPET="${OUTPUT_DIR}/https-server.js"
    cat > "${NODE_SNIPPET}" << NODE_EOF
// Node.js HTTPS server for WebAuthn development
const https = require('https');
const fs = require('fs');
const path = require('path');

const options = {
  key: fs.readFileSync(path.join(__dirname, '${DOMAIN}-key.pem')),
  cert: fs.readFileSync(path.join(__dirname, '${DOMAIN}.pem')),
};

// If using Express:
// const app = require('./app');
// https.createServer(options, app).listen(${PORT}, () => {
//   console.log('HTTPS server running at https://${DOMAIN}:${PORT}');
// });

// Standalone test server:
https.createServer(options, (req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/html' });
  res.end('<h1>WebAuthn Dev Server</h1><p>HTTPS is working!</p>');
}).listen(${PORT}, () => {
  console.log('HTTPS server running at https://${DOMAIN}:${PORT}');
});
NODE_EOF
    log_ok "Node.js snippet: ${NODE_SNIPPET}"
fi

# --- Step 6: Print summary ---
echo ""
echo "================================================"
echo "  Setup Complete!"
echo "================================================"
echo ""
echo "  Certificate: ${CERT_FILE}"
echo "  Private key: ${KEY_FILE}"
echo ""
echo "  WebAuthn config for development:"
echo "    rpID:   '${DOMAIN}'"
echo "    origin: 'https://${DOMAIN}:${PORT}'"
echo ""
echo "  Quick test with Node.js:"
echo "    node -e \"require('https').createServer({"
echo "      key: require('fs').readFileSync('${KEY_FILE}'),"
echo "      cert: require('fs').readFileSync('${CERT_FILE}')"
echo "    }, (req, res) => { res.end('OK') }).listen(${PORT})\""
echo ""
echo "  Then visit: https://${DOMAIN}:${PORT}"
echo ""

if [[ "$DOMAIN" == "localhost" ]]; then
    log_info "Tip: 'localhost' is treated as a secure context by most browsers."
    log_info "You can also use http://localhost for basic WebAuthn testing."
    log_info "HTTPS is recommended for testing conditional UI and hybrid flows."
fi
