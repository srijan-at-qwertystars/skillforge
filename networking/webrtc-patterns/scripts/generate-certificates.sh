#!/usr/bin/env bash
#
# generate-certificates.sh — Generate self-signed certificates for local WebRTC development
#
# Usage:
#   chmod +x generate-certificates.sh
#   ./generate-certificates.sh [options]
#
# Options:
#   --domain <name>   Domain name for the certificate (default: localhost)
#   --out <dir>       Output directory (default: ./certs)
#   --days <n>        Certificate validity in days (default: 365)
#   --ca              Also generate a local CA for trust chain
#
# Generated files:
#   server.key        Private key
#   server.crt        Server certificate (self-signed or CA-signed)
#   server.pem        Combined key + cert (for Node.js)
#   ca.key / ca.crt   CA key and certificate (if --ca flag used)
#
# Examples:
#   ./generate-certificates.sh
#   ./generate-certificates.sh --domain myapp.local --out ./ssl --days 730
#   ./generate-certificates.sh --ca --domain dev.example.com
#
# After generating, trust the CA cert (macOS):
#   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
#
# After generating, trust the CA cert (Linux):
#   sudo cp ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
#

set -euo pipefail

# --- Defaults ---
DOMAIN="localhost"
OUT_DIR="./certs"
DAYS=365
GENERATE_CA=false

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --out)    OUT_DIR="$2"; shift 2 ;;
    --days)   DAYS="$2"; shift 2 ;;
    --ca)     GENERATE_CA=true; shift ;;
    --help)
      head -30 "$0" | tail -28
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Setup ---
mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

echo "=== WebRTC Development Certificate Generator ==="
echo "Domain:    $DOMAIN"
echo "Output:    $(pwd)"
echo "Validity:  $DAYS days"
echo ""

# SAN config for modern browsers
cat > openssl-san.cnf << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
C = US
ST = Development
L = Local
O = WebRTC Dev
CN = $DOMAIN

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
DNS.3 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = 0.0.0.0
EOF

if [[ "$GENERATE_CA" == true ]]; then
  echo "--- Generating Certificate Authority ---"

  # Generate CA private key
  openssl genrsa -out ca.key 4096 2>/dev/null

  # Generate CA certificate
  openssl req -x509 -new -nodes -key ca.key -sha256 -days "$DAYS" \
    -out ca.crt \
    -subj "/C=US/ST=Development/L=Local/O=WebRTC Dev CA/CN=WebRTC Dev Root CA" \
    2>/dev/null

  echo "  ✓ ca.key  (CA private key)"
  echo "  ✓ ca.crt  (CA certificate — install this in your system trust store)"

  echo ""
  echo "--- Generating Server Certificate (signed by CA) ---"

  # Generate server key
  openssl genrsa -out server.key 2048 2>/dev/null

  # Generate CSR
  openssl req -new -key server.key -out server.csr \
    -config openssl-san.cnf \
    2>/dev/null

  # CA extensions config
  cat > ca-ext.cnf << CAEXT
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
DNS.3 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = 0.0.0.0
CAEXT

  # Sign with CA
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out server.crt -days "$DAYS" -sha256 \
    -extfile ca-ext.cnf \
    2>/dev/null

  rm -f server.csr ca-ext.cnf ca.srl

else
  echo "--- Generating Self-Signed Certificate ---"

  # Generate key and self-signed cert in one step
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -keyout server.key \
    -out server.crt \
    -days "$DAYS" \
    -config openssl-san.cnf \
    2>/dev/null
fi

# Create combined PEM (useful for Node.js https.createServer)
cat server.key server.crt > server.pem

# Clean up temp config
rm -f openssl-san.cnf

# Set permissions
chmod 600 server.key *.pem
chmod 644 server.crt
if [[ "$GENERATE_CA" == true ]]; then
  chmod 600 ca.key
  chmod 644 ca.crt
fi

echo "  ✓ server.key  (private key)"
echo "  ✓ server.crt  (certificate)"
echo "  ✓ server.pem  (combined key+cert for Node.js)"

echo ""
echo "=== Certificate Info ==="
openssl x509 -in server.crt -noout -subject -dates -ext subjectAltName 2>/dev/null

echo ""
echo "=== Usage Examples ==="
echo ""
echo "Node.js HTTPS server:"
echo "  const https = require('https');"
echo "  const fs = require('fs');"
echo "  const server = https.createServer({"
echo "    key: fs.readFileSync('$(pwd)/server.key'),"
echo "    cert: fs.readFileSync('$(pwd)/server.crt')"
echo "  }, app);"
echo ""
echo "Express with WebSocket:"
echo "  const server = https.createServer({ pfx: fs.readFileSync('$(pwd)/server.pem') }, app);"
echo "  const wss = new WebSocketServer({ server });"
echo ""
if [[ "$GENERATE_CA" == true ]]; then
  echo "Trust the CA (macOS):"
  echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $(pwd)/ca.crt"
  echo ""
  echo "Trust the CA (Linux):"
  echo "  sudo cp $(pwd)/ca.crt /usr/local/share/ca-certificates/webrtc-dev.crt"
  echo "  sudo update-ca-certificates"
  echo ""
fi
echo "Chrome flag to ignore cert errors (development only):"
echo "  chrome --ignore-certificate-errors --unsafely-treat-insecure-origin-as-secure=https://$DOMAIN"
