#!/usr/bin/env bash
# generate-ssl-config.sh — Generate SSL/TLS configuration following Mozilla recommendations
#
# Usage:
#   ./generate-ssl-config.sh [--profile modern|intermediate] [--domain DOMAIN] [--output FILE]
#
# Options:
#   --profile   SSL profile: 'modern' (TLS 1.3 only) or 'intermediate' (default)
#   --domain    Domain name for the certificate paths (default: example.com)
#   --output    Output file path (default: stdout)
#   --dhparam   Generate DH parameters file (2048-bit) at specified path
#   --certpath  Base path for certificates (default: /etc/letsencrypt/live)
#
# Examples:
#   ./generate-ssl-config.sh --domain mysite.com --profile intermediate
#   ./generate-ssl-config.sh --domain api.mysite.com --profile modern --output /etc/nginx/conf.d/ssl.conf
#   ./generate-ssl-config.sh --domain mysite.com --dhparam /etc/nginx/dhparam.pem

set -euo pipefail

PROFILE="intermediate"
DOMAIN="example.com"
OUTPUT=""
DHPARAM_PATH=""
CERT_PATH="/etc/letsencrypt/live"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)    PROFILE="$2";     shift 2 ;;
        --domain)     DOMAIN="$2";      shift 2 ;;
        --output)     OUTPUT="$2";      shift 2 ;;
        --dhparam)    DHPARAM_PATH="$2"; shift 2 ;;
        --certpath)   CERT_PATH="$2";   shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

generate_modern() {
    cat <<EOF
# Mozilla Modern SSL Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Profile: Modern (TLS 1.3 only)
# Supports: Firefox 63+, Android 10+, Chrome 70+, Safari 12.1+
# Reference: https://ssl-config.mozilla.org/

ssl_certificate     ${CERT_PATH}/${DOMAIN}/fullchain.pem;
ssl_certificate_key ${CERT_PATH}/${DOMAIN}/privkey.pem;
ssl_trusted_certificate ${CERT_PATH}/${DOMAIN}/chain.pem;

ssl_protocols TLSv1.3;
ssl_prefer_server_ciphers off;

ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;

# OCSP Stapling
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

# HSTS (2 years, includes subdomains, preload-ready)
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
EOF
}

generate_intermediate() {
    cat <<EOF
# Mozilla Intermediate SSL Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Profile: Intermediate (TLS 1.2 + 1.3)
# Supports: Firefox 27+, Android 4.4+, Chrome 31+, IE 11+, Safari 9+
# Reference: https://ssl-config.mozilla.org/

ssl_certificate     ${CERT_PATH}/${DOMAIN}/fullchain.pem;
ssl_certificate_key ${CERT_PATH}/${DOMAIN}/privkey.pem;
ssl_trusted_certificate ${CERT_PATH}/${DOMAIN}/chain.pem;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;

# DH parameters for DHE ciphers
# Generate: openssl dhparam -out ${CERT_PATH}/../dhparam.pem 2048
ssl_dhparam /etc/nginx/dhparam.pem;

ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;

# OCSP Stapling
ssl_stapling on;
ssl_stapling_verify on;
resolver 1.1.1.1 8.8.8.8 valid=300s;
resolver_timeout 5s;

# HSTS (2 years, includes subdomains, preload-ready)
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
EOF
}

# Generate the config
config=""
case "$PROFILE" in
    modern)
        config=$(generate_modern)
        ;;
    intermediate)
        config=$(generate_intermediate)
        ;;
    *)
        echo "Error: Unknown profile '$PROFILE'. Use 'modern' or 'intermediate'." >&2
        exit 1
        ;;
esac

# Output
if [[ -n "$OUTPUT" ]]; then
    mkdir -p "$(dirname "$OUTPUT")"
    echo "$config" > "$OUTPUT"
    echo "SSL configuration written to $OUTPUT"
else
    echo "$config"
fi

# Generate DH parameters if requested
if [[ -n "$DHPARAM_PATH" ]]; then
    echo "Generating DH parameters (2048-bit) at $DHPARAM_PATH ..."
    echo "This may take a few minutes."
    openssl dhparam -out "$DHPARAM_PATH" 2048
    chmod 644 "$DHPARAM_PATH"
    echo "DH parameters written to $DHPARAM_PATH"
fi
