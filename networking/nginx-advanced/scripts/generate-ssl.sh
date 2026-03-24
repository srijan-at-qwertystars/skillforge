#!/usr/bin/env bash
#
# generate-ssl.sh — Generate SSL certificates for nginx
#
# Usage:
#   ./generate-ssl.sh selfsigned <domain> [--days 365] [--out /etc/ssl]
#     Generate a self-signed certificate with SAN support
#
#   ./generate-ssl.sh letsencrypt <domain> [--email admin@example.com] [--staging]
#     Request a Let's Encrypt certificate via certbot (nginx plugin)
#
#   ./generate-ssl.sh dhparam [--bits 4096] [--out /etc/nginx/dhparam.pem]
#     Generate Diffie-Hellman parameters
#
#   ./generate-ssl.sh verify <domain>
#     Verify an existing certificate's validity and expiration
#
# Examples:
#   ./generate-ssl.sh selfsigned example.com
#   ./generate-ssl.sh selfsigned "*.example.com" --days 730 --out /etc/nginx/ssl
#   ./generate-ssl.sh letsencrypt example.com --email admin@example.com
#   ./generate-ssl.sh letsencrypt example.com --staging
#   ./generate-ssl.sh dhparam --bits 2048
#   ./generate-ssl.sh verify example.com
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

usage() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 1
}

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' is required but not installed."
}

########################################
# Self-signed certificate
########################################
cmd_selfsigned() {
    local domain="${1:?Domain required}" ; shift
    local days=365
    local outdir="/etc/ssl/nginx"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)  days="$2"; shift 2 ;;
            --out)   outdir="$2"; shift 2 ;;
            *)       die "Unknown option: $1" ;;
        esac
    done

    require_cmd openssl

    mkdir -p "$outdir"

    local key_file="$outdir/${domain//\*/_wildcard}.key"
    local cert_file="$outdir/${domain//\*/_wildcard}.crt"
    local csr_file
    csr_file=$(mktemp /tmp/csr.XXXXXX.pem)
    local ext_file
    ext_file=$(mktemp /tmp/ext.XXXXXX.cnf)

    # Create extension file with SAN
    cat > "$ext_file" <<EOF
[req]
default_bits = 2048
prompt = no
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = ${domain}
O = Self-Signed
C = US

[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain#\*.}
EOF

    info "Generating private key..."
    openssl genrsa -out "$key_file" 2048 2>/dev/null

    info "Generating CSR..."
    openssl req -new -key "$key_file" -out "$csr_file" -config "$ext_file" 2>/dev/null

    info "Generating self-signed certificate (${days} days)..."
    openssl x509 -req -days "$days" \
        -in "$csr_file" \
        -signkey "$key_file" \
        -out "$cert_file" \
        -extensions v3_req \
        -extfile "$ext_file" 2>/dev/null

    chmod 600 "$key_file"
    chmod 644 "$cert_file"
    rm -f "$csr_file" "$ext_file"

    info "Certificate generated:"
    echo "  Key:  $key_file"
    echo "  Cert: $cert_file"
    echo ""
    info "Nginx config snippet:"
    echo "  ssl_certificate     ${cert_file};"
    echo "  ssl_certificate_key ${key_file};"
    echo ""
    openssl x509 -in "$cert_file" -noout -subject -dates -ext subjectAltName 2>/dev/null
}

########################################
# Let's Encrypt via certbot
########################################
cmd_letsencrypt() {
    local domain="${1:?Domain required}" ; shift
    local email=""
    local staging=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email)    email="$2"; shift 2 ;;
            --staging)  staging="--staging"; shift ;;
            *)          die "Unknown option: $1" ;;
        esac
    done

    require_cmd certbot

    local email_flag=""
    if [[ -n "$email" ]]; then
        email_flag="--email $email"
    else
        email_flag="--register-unsafely-without-email"
        warn "No email specified. Using --register-unsafely-without-email"
    fi

    info "Requesting Let's Encrypt certificate for ${domain}..."

    # shellcheck disable=SC2086
    certbot certonly \
        --nginx \
        --non-interactive \
        --agree-tos \
        $email_flag \
        $staging \
        -d "$domain"

    local cert_dir="/etc/letsencrypt/live/${domain}"

    if [[ -d "$cert_dir" ]]; then
        info "Certificate obtained successfully!"
        echo "  Fullchain: ${cert_dir}/fullchain.pem"
        echo "  Key:       ${cert_dir}/privkey.pem"
        echo ""
        info "Nginx config snippet:"
        echo "  ssl_certificate     ${cert_dir}/fullchain.pem;"
        echo "  ssl_certificate_key ${cert_dir}/privkey.pem;"
        echo ""
        info "Auto-renewal is configured via certbot timer/cron."
        echo "  Test renewal: certbot renew --dry-run"
    else
        die "Certificate directory not found at ${cert_dir}"
    fi
}

########################################
# DH parameter generation
########################################
cmd_dhparam() {
    local bits=4096
    local outfile="/etc/nginx/dhparam.pem"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bits)  bits="$2"; shift 2 ;;
            --out)   outfile="$2"; shift 2 ;;
            *)       die "Unknown option: $1" ;;
        esac
    done

    require_cmd openssl

    if [[ "$bits" -lt 2048 ]]; then
        die "DH parameter bits must be >= 2048 (got ${bits})"
    fi

    info "Generating ${bits}-bit DH parameters (this may take several minutes)..."
    openssl dhparam -out "$outfile" "$bits" 2>/dev/null

    chmod 644 "$outfile"
    info "DH parameters written to ${outfile}"
    echo ""
    info "Nginx config:"
    echo "  ssl_dhparam ${outfile};"
}

########################################
# Verify certificate
########################################
cmd_verify() {
    local domain="${1:?Domain required}"

    require_cmd openssl

    info "Checking certificate for ${domain}..."
    echo ""

    # Try live connection first
    if echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null | openssl x509 -noout -text 2>/dev/null | head -30; then
        echo ""
        info "Certificate dates:"
        echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null

        echo ""
        info "OCSP stapling:"
        echo | openssl s_client -connect "${domain}:443" -servername "$domain" -status 2>/dev/null | grep -A3 "OCSP Response" || warn "No OCSP stapling detected"

        echo ""
        info "TLS version:"
        echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null | grep "Protocol\|Cipher"
    else
        # Check local cert files
        local cert_paths=(
            "/etc/letsencrypt/live/${domain}/fullchain.pem"
            "/etc/ssl/nginx/${domain}.crt"
            "/etc/ssl/certs/${domain}.crt"
        )

        for cert in "${cert_paths[@]}"; do
            if [[ -f "$cert" ]]; then
                info "Found local certificate: ${cert}"
                openssl x509 -in "$cert" -noout -subject -dates -issuer -ext subjectAltName
                echo ""

                # Check expiration
                local expiry
                expiry=$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)
                local expiry_epoch
                expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry" +%s 2>/dev/null)
                local now_epoch
                now_epoch=$(date +%s)
                local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

                if [[ $days_left -lt 0 ]]; then
                    error "Certificate EXPIRED ${days_left#-} days ago!"
                elif [[ $days_left -lt 30 ]]; then
                    warn "Certificate expires in ${days_left} days!"
                else
                    info "Certificate valid for ${days_left} more days."
                fi
                return 0
            fi
        done
        warn "No certificate found for ${domain} (checked local paths and remote connection)"
    fi
}

########################################
# Main
########################################
[[ $# -lt 1 ]] && usage

case "$1" in
    selfsigned)   shift; cmd_selfsigned "$@" ;;
    letsencrypt)  shift; cmd_letsencrypt "$@" ;;
    dhparam)      shift; cmd_dhparam "$@" ;;
    verify)       shift; cmd_verify "$@" ;;
    -h|--help)    usage ;;
    *)            die "Unknown command: $1. Use: selfsigned|letsencrypt|dhparam|verify" ;;
esac
