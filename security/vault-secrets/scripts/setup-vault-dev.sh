#!/usr/bin/env bash
#
# setup-vault-dev.sh — Sets up a Vault dev server with common secrets engines and auth methods
#
# Usage:
#   ./setup-vault-dev.sh                  # Start dev server on default port 8200
#   ./setup-vault-dev.sh --port 8201      # Start on custom port
#   ./setup-vault-dev.sh --no-server      # Configure only (assumes Vault already running)
#
# Prerequisites:
#   - vault CLI installed (https://developer.hashicorp.com/vault/install)
#   - jq installed
#
# What this script does:
#   1. Starts a Vault dev server (unless --no-server)
#   2. Enables KV v2, Transit, PKI, Database secrets engines
#   3. Enables AppRole, Userpass auth methods
#   4. Creates sample policies (admin, readonly, app)
#   5. Creates sample secrets for testing
#   6. Prints connection details and root token
#
# The dev server runs in-memory — all data is lost on restart.
# NEVER use dev mode in production.

set -euo pipefail

PORT=8200
START_SERVER=true
ROOT_TOKEN="dev-root-token"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    --no-server)
      START_SERVER=false
      shift
      ;;
    --help|-h)
      head -22 "$0" | tail -20
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

export VAULT_ADDR="http://127.0.0.1:${PORT}"
export VAULT_TOKEN="${ROOT_TOKEN}"

log() { echo -e "\033[1;32m==>\033[0m $1"; }
warn() { echo -e "\033[1;33mWARN:\033[0m $1"; }
err() { echo -e "\033[1;31mERROR:\033[0m $1" >&2; exit 1; }

command -v vault >/dev/null 2>&1 || err "vault CLI not found. Install from https://developer.hashicorp.com/vault/install"
command -v jq >/dev/null 2>&1 || warn "jq not found — some output formatting will be limited"

# --- Start Dev Server ---
if $START_SERVER; then
  log "Starting Vault dev server on port ${PORT}..."
  vault server -dev \
    -dev-root-token-id="${ROOT_TOKEN}" \
    -dev-listen-address="127.0.0.1:${PORT}" \
    &>/tmp/vault-dev-${PORT}.log &
  VAULT_PID=$!
  echo "$VAULT_PID" > /tmp/vault-dev-${PORT}.pid
  sleep 2

  if ! kill -0 "$VAULT_PID" 2>/dev/null; then
    err "Vault dev server failed to start. Check /tmp/vault-dev-${PORT}.log"
  fi
  log "Vault dev server started (PID: ${VAULT_PID})"
fi

# Wait for Vault to be ready
for i in $(seq 1 10); do
  vault status &>/dev/null && break
  sleep 1
done
vault status &>/dev/null || err "Vault is not responding at ${VAULT_ADDR}"

# --- Secrets Engines ---
log "Enabling secrets engines..."

vault secrets enable -version=2 -path=secret kv 2>/dev/null || true
vault secrets enable -path=transit transit 2>/dev/null || true
vault secrets enable -path=pki pki 2>/dev/null || true

# --- Transit Keys ---
log "Creating Transit encryption keys..."
vault write -f transit/keys/app-key 2>/dev/null || true
vault write -f transit/keys/data-key type=aes256-gcm96 2>/dev/null || true

# --- PKI ---
log "Configuring PKI secrets engine..."
vault secrets tune -max-lease-ttl=87600h pki 2>/dev/null || true
vault write -f pki/root/generate/internal \
  common_name="Dev Root CA" \
  ttl=87600h 2>/dev/null || true
vault write pki/roles/dev-certs \
  allowed_domains="localhost,example.com,dev.local" \
  allow_subdomains=true \
  allow_localhost=true \
  max_ttl=720h 2>/dev/null || true

# --- Sample KV Secrets ---
log "Writing sample secrets..."
vault kv put secret/myapp/config \
  db_host="localhost" \
  db_port="5432" \
  db_name="myapp_dev" \
  api_key="dev-api-key-12345" \
  debug="true"

vault kv put secret/myapp/credentials \
  admin_user="admin" \
  admin_password="dev-password-67890"

vault kv put secret/shared/config \
  log_level="debug" \
  environment="development"

# --- Auth Methods ---
log "Enabling auth methods..."

vault auth enable approle 2>/dev/null || true
vault auth enable userpass 2>/dev/null || true

# --- Policies ---
log "Creating policies..."

vault policy write admin - <<'POLICY'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
POLICY

vault policy write readonly - <<'POLICY'
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}
path "sys/health" {
  capabilities = ["read"]
}
path "sys/seal-status" {
  capabilities = ["read"]
}
POLICY

vault policy write app-policy - <<'POLICY'
path "secret/data/myapp/*" {
  capabilities = ["read", "list"]
}
path "secret/data/shared/*" {
  capabilities = ["read"]
}
path "transit/encrypt/app-key" {
  capabilities = ["update"]
}
path "transit/decrypt/app-key" {
  capabilities = ["update"]
}
path "pki/issue/dev-certs" {
  capabilities = ["create", "update"]
}
POLICY

vault policy write ci-cd-policy - <<'POLICY'
path "secret/data/myapp/*" {
  capabilities = ["read"]
}
path "secret/metadata/myapp/*" {
  capabilities = ["list"]
}
POLICY

# --- AppRole ---
log "Configuring AppRole auth..."
vault write auth/approle/role/my-app \
  token_policies="app-policy" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=720h

ROLE_ID=$(vault read -field=role_id auth/approle/role/my-app/role-id)
SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/my-app/secret-id)

# --- Userpass ---
log "Configuring Userpass auth..."
vault write auth/userpass/users/dev-user \
  password="dev-password" \
  policies="app-policy"

vault write auth/userpass/users/admin-user \
  password="admin-password" \
  policies="admin"

vault write auth/userpass/users/readonly-user \
  password="readonly-password" \
  policies="readonly"

# --- Print Summary ---
echo ""
echo "============================================="
echo "  Vault Dev Server Ready"
echo "============================================="
echo ""
echo "  Address:     ${VAULT_ADDR}"
echo "  Root Token:  ${ROOT_TOKEN}"
echo ""
echo "  Secrets Engines:"
echo "    - secret/ (KV v2)"
echo "    - transit/"
echo "    - pki/"
echo ""
echo "  Auth Methods:"
echo "    - approle/"
echo "    - userpass/"
echo ""
echo "  AppRole Credentials:"
echo "    Role ID:   ${ROLE_ID}"
echo "    Secret ID: ${SECRET_ID}"
echo ""
echo "  Userpass Accounts:"
echo "    dev-user / dev-password       (app-policy)"
echo "    admin-user / admin-password   (admin)"
echo "    readonly-user / readonly-password (readonly)"
echo ""
echo "  Sample Secrets:"
echo "    vault kv get secret/myapp/config"
echo "    vault kv get secret/myapp/credentials"
echo "    vault kv get secret/shared/config"
echo ""
if $START_SERVER; then
  echo "  Stop server: kill \$(cat /tmp/vault-dev-${PORT}.pid)"
  echo "  Server log:  /tmp/vault-dev-${PORT}.log"
fi
echo "============================================="
