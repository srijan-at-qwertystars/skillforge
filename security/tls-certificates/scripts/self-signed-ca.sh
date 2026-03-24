#!/bin/bash
# =============================================================================
# self-signed-ca.sh — Full CA Hierarchy Generator
# =============================================================================
#
# Usage:
#   ./self-signed-ca.sh [output-dir] [domain]
#   ./self-signed-ca.sh                        # defaults: ./ca-output, localhost
#   ./self-signed-ca.sh /opt/pki myapp.internal
#   ./self-signed-ca.sh ./certs api.dev.local
#
# Creates:
#   - Root CA (10-year validity)
#   - Intermediate CA (5-year validity, signed by root)
#   - Server certificate (1-year, signed by intermediate, with SANs)
#   - Client certificate (1-year, signed by intermediate, for mTLS)
#   - Full chain bundle
#   - PKCS#12 bundle
#
# Dependencies: openssl
# =============================================================================

set -euo pipefail

OUTPUT_DIR="${1:-./ca-output}"
DOMAIN="${2:-localhost}"
COUNTRY="US"
STATE="California"
CITY="San Francisco"
ORG="Internal PKI"
ROOT_DAYS=3650
INTERMEDIATE_DAYS=1825
CERT_DAYS=365
RSA_BITS=4096
SERVER_RSA_BITS=2048

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }

echo -e "${BOLD}Creating Full CA Hierarchy${NC}"
echo -e "Output:  ${CYAN}${OUTPUT_DIR}${NC}"
echo -e "Domain:  ${CYAN}${DOMAIN}${NC}"
echo ""

mkdir -p "${OUTPUT_DIR}"/{root-ca,intermediate-ca,server,client,chain}
cd "${OUTPUT_DIR}"

# --- Root CA ---
info "Generating Root CA..."

cat > root-ca/root-ca.cnf << EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_ca
prompt = no

[req_dn]
C = ${COUNTRY}
ST = ${STATE}
L = ${CITY}
O = ${ORG}
CN = ${ORG} Root CA

[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always, issuer

[v3_intermediate]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always, issuer
EOF

openssl genrsa -out root-ca/root-ca.key ${RSA_BITS} 2>/dev/null
chmod 400 root-ca/root-ca.key

openssl req -x509 -new -nodes \
    -key root-ca/root-ca.key \
    -sha256 \
    -days ${ROOT_DAYS} \
    -out root-ca/root-ca.crt \
    -config root-ca/root-ca.cnf \
    -extensions v3_ca

ok "Root CA created (${ROOT_DAYS} days validity)"

# --- Intermediate CA ---
info "Generating Intermediate CA..."

cat > intermediate-ca/intermediate-ca.cnf << EOF
[req]
distinguished_name = req_dn
prompt = no

[req_dn]
C = ${COUNTRY}
ST = ${STATE}
L = ${CITY}
O = ${ORG}
CN = ${ORG} Intermediate CA
EOF

openssl genrsa -out intermediate-ca/intermediate-ca.key ${RSA_BITS} 2>/dev/null
chmod 400 intermediate-ca/intermediate-ca.key

openssl req -new -nodes \
    -key intermediate-ca/intermediate-ca.key \
    -out intermediate-ca/intermediate-ca.csr \
    -config intermediate-ca/intermediate-ca.cnf

openssl x509 -req \
    -in intermediate-ca/intermediate-ca.csr \
    -CA root-ca/root-ca.crt \
    -CAkey root-ca/root-ca.key \
    -CAcreateserial \
    -out intermediate-ca/intermediate-ca.crt \
    -days ${INTERMEDIATE_DAYS} \
    -sha256 \
    -extfile root-ca/root-ca.cnf \
    -extensions v3_intermediate

ok "Intermediate CA created (${INTERMEDIATE_DAYS} days validity)"

# --- Server Certificate ---
info "Generating Server Certificate for ${DOMAIN}..."

cat > server/server.cnf << EOF
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no

[req_dn]
C = ${COUNTRY}
ST = ${STATE}
L = ${CITY}
O = ${ORG}
CN = ${DOMAIN}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid, issuer

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = *.${DOMAIN}
DNS.3 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl genrsa -out server/server.key ${SERVER_RSA_BITS} 2>/dev/null
chmod 400 server/server.key

openssl req -new \
    -key server/server.key \
    -out server/server.csr \
    -config server/server.cnf

openssl x509 -req \
    -in server/server.csr \
    -CA intermediate-ca/intermediate-ca.crt \
    -CAkey intermediate-ca/intermediate-ca.key \
    -CAcreateserial \
    -out server/server.crt \
    -days ${CERT_DAYS} \
    -sha256 \
    -extfile server/server.cnf \
    -extensions v3_req

ok "Server certificate created for ${DOMAIN} (${CERT_DAYS} days validity)"

# --- Client Certificate (for mTLS) ---
info "Generating Client Certificate for mTLS..."

cat > client/client.cnf << EOF
[req]
distinguished_name = req_dn
req_extensions = v3_req
prompt = no

[req_dn]
C = ${COUNTRY}
ST = ${STATE}
O = ${ORG}
CN = client-app

[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid, issuer
EOF

openssl genrsa -out client/client.key ${SERVER_RSA_BITS} 2>/dev/null
chmod 400 client/client.key

openssl req -new \
    -key client/client.key \
    -out client/client.csr \
    -config client/client.cnf

openssl x509 -req \
    -in client/client.csr \
    -CA intermediate-ca/intermediate-ca.crt \
    -CAkey intermediate-ca/intermediate-ca.key \
    -CAcreateserial \
    -out client/client.crt \
    -days ${CERT_DAYS} \
    -sha256 \
    -extfile client/client.cnf \
    -extensions v3_req

ok "Client certificate created (${CERT_DAYS} days validity)"

# --- Chain Bundles ---
info "Creating chain bundles..."

# Full chain: leaf + intermediate + root
cat server/server.crt intermediate-ca/intermediate-ca.crt root-ca/root-ca.crt > chain/fullchain.pem
# Server chain (without root, standard for deployment)
cat server/server.crt intermediate-ca/intermediate-ca.crt > chain/server-chain.pem
# CA bundle (intermediate + root)
cat intermediate-ca/intermediate-ca.crt root-ca/root-ca.crt > chain/ca-bundle.pem

ok "Chain bundles created"

# --- PKCS#12 Bundles ---
info "Creating PKCS#12 bundles..."

openssl pkcs12 -export \
    -out server/server.p12 \
    -inkey server/server.key \
    -in server/server.crt \
    -certfile chain/ca-bundle.pem \
    -passout pass:changeit

openssl pkcs12 -export \
    -out client/client.p12 \
    -inkey client/client.key \
    -in client/client.crt \
    -certfile chain/ca-bundle.pem \
    -passout pass:changeit

ok "PKCS#12 bundles created (password: changeit)"

# --- Verification ---
info "Verifying certificate chain..."

VERIFY_RESULT=$(openssl verify \
    -CAfile root-ca/root-ca.crt \
    -untrusted intermediate-ca/intermediate-ca.crt \
    server/server.crt 2>&1)

if echo "$VERIFY_RESULT" | grep -q ": OK"; then
    ok "Server certificate chain verified successfully"
else
    echo -e "${RED}[FAIL]${NC} Chain verification failed: $VERIFY_RESULT"
fi

VERIFY_CLIENT=$(openssl verify \
    -CAfile root-ca/root-ca.crt \
    -untrusted intermediate-ca/intermediate-ca.crt \
    client/client.crt 2>&1)

if echo "$VERIFY_CLIENT" | grep -q ": OK"; then
    ok "Client certificate chain verified successfully"
else
    echo -e "${RED}[FAIL]${NC} Client chain verification failed: $VERIFY_CLIENT"
fi

# --- Summary ---
echo ""
echo -e "${BOLD}━━━ Generated Files ━━━${NC}"
echo ""
echo "Root CA:"
echo "  ${OUTPUT_DIR}/root-ca/root-ca.key        (KEEP OFFLINE & SECURE)"
echo "  ${OUTPUT_DIR}/root-ca/root-ca.crt        (distribute to trust stores)"
echo ""
echo "Intermediate CA:"
echo "  ${OUTPUT_DIR}/intermediate-ca/intermediate-ca.key"
echo "  ${OUTPUT_DIR}/intermediate-ca/intermediate-ca.crt"
echo ""
echo "Server Certificate:"
echo "  ${OUTPUT_DIR}/server/server.key"
echo "  ${OUTPUT_DIR}/server/server.crt"
echo "  ${OUTPUT_DIR}/server/server.p12           (password: changeit)"
echo ""
echo "Client Certificate (mTLS):"
echo "  ${OUTPUT_DIR}/client/client.key"
echo "  ${OUTPUT_DIR}/client/client.crt"
echo "  ${OUTPUT_DIR}/client/client.p12           (password: changeit)"
echo ""
echo "Chain Bundles:"
echo "  ${OUTPUT_DIR}/chain/fullchain.pem         (server + intermediate + root)"
echo "  ${OUTPUT_DIR}/chain/server-chain.pem      (server + intermediate)"
echo "  ${OUTPUT_DIR}/chain/ca-bundle.pem         (intermediate + root)"
echo ""
echo -e "${BOLD}Quick Test Commands:${NC}"
echo ""
echo "  # Start test HTTPS server"
echo "  openssl s_server -cert server/server.crt -key server/server.key \\"
echo "    -CAfile chain/ca-bundle.pem -accept 4443 -www"
echo ""
echo "  # Test with curl (mTLS)"
echo "  curl --cacert root-ca/root-ca.crt \\"
echo "    --cert client/client.crt --key client/client.key \\"
echo "    https://localhost:4443"
echo ""
echo "  # Add Root CA to system trust store (Ubuntu/Debian)"
echo "  sudo cp root-ca/root-ca.crt /usr/local/share/ca-certificates/"
echo "  sudo update-ca-certificates"
