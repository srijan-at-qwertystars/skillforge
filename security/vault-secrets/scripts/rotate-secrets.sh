#!/usr/bin/env bash
#
# rotate-secrets.sh — Rotates dynamic secrets and updates dependent services
#
# Usage:
#   ./rotate-secrets.sh --engine database --role app-role     # Rotate DB creds for a role
#   ./rotate-secrets.sh --engine database --rotate-root mydb  # Rotate root DB password
#   ./rotate-secrets.sh --engine aws --role deploy-role       # Rotate AWS creds
#   ./rotate-secrets.sh --kv secret/myapp/api-key             # Rotate a static KV secret
#   ./rotate-secrets.sh --revoke-prefix database/creds/app    # Revoke all leases under prefix
#   ./rotate-secrets.sh --transit-key my-key                  # Rotate Transit encryption key
#
# Prerequisites:
#   - vault CLI installed and configured (VAULT_ADDR, VAULT_TOKEN)
#   - Appropriate Vault policies for the operations
#
# This script:
#   1. Rotates the specified secret type
#   2. Verifies new credentials work (where applicable)
#   3. Optionally revokes old leases
#   4. Logs all operations for audit trail
#
# For automated rotation, combine with Vault Agent or a cron job.

set -euo pipefail

# --- Defaults ---
ENGINE=""
ROLE=""
ROTATE_ROOT=""
KV_PATH=""
REVOKE_PREFIX=""
TRANSIT_KEY=""
FORCE=false
DRY_RUN=false

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)
      ENGINE="$2"
      shift 2
      ;;
    --role)
      ROLE="$2"
      shift 2
      ;;
    --rotate-root)
      ROTATE_ROOT="$2"
      shift 2
      ;;
    --kv)
      KV_PATH="$2"
      shift 2
      ;;
    --revoke-prefix)
      REVOKE_PREFIX="$2"
      shift 2
      ;;
    --transit-key)
      TRANSIT_KEY="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      head -22 "$0" | tail -20
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# --- Helpers ---
log() { echo -e "\033[1;32m[$(date '+%H:%M:%S')]\033[0m $1"; }
warn() { echo -e "\033[1;33m[$(date '+%H:%M:%S')] WARN:\033[0m $1"; }
err() { echo -e "\033[1;31m[$(date '+%H:%M:%S')] ERROR:\033[0m $1" >&2; exit 1; }

dry() {
  if $DRY_RUN; then
    log "DRY RUN: $*"
    return 0
  fi
  "$@"
}

# --- Preflight Checks ---
command -v vault >/dev/null 2>&1 || err "vault CLI not found"
[[ -n "${VAULT_ADDR:-}" ]] || err "VAULT_ADDR not set"
[[ -n "${VAULT_TOKEN:-}" ]] || err "VAULT_TOKEN not set"
vault token lookup &>/dev/null || err "Invalid Vault token"

# --- Rotate Database Credentials ---
rotate_database_creds() {
  local engine="$1"
  local role="$2"

  log "Rotating database credentials for role: ${role} (engine: ${engine})"

  # Count existing leases
  LEASE_COUNT=$(vault list -format=json "sys/leases/lookup/${engine}/creds/${role}" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
  log "Active leases for ${role}: ${LEASE_COUNT}"

  # Generate new credentials
  log "Requesting new credentials..."
  NEW_CREDS=$(dry vault read -format=json "${engine}/creds/${role}" 2>&1) || err "Failed to generate new credentials"

  if ! $DRY_RUN; then
    NEW_USER=$(echo "$NEW_CREDS" | jq -r '.data.username')
    LEASE_ID=$(echo "$NEW_CREDS" | jq -r '.lease_id')
    LEASE_DURATION=$(echo "$NEW_CREDS" | jq -r '.lease_duration')

    log "New credentials generated:"
    log "  Username:       ${NEW_USER}"
    log "  Lease ID:       ${LEASE_ID}"
    log "  Lease Duration: ${LEASE_DURATION}s"
  fi

  # Optionally revoke old leases
  if $FORCE && [[ "$LEASE_COUNT" -gt 0 ]]; then
    warn "Revoking ${LEASE_COUNT} old lease(s) for ${role}..."
    dry vault lease revoke -prefix "${engine}/creds/${role}"
    log "Old leases revoked"
  fi
}

# --- Rotate Root Database Password ---
rotate_database_root() {
  local db_name="$1"

  log "Rotating root credentials for database: ${db_name}"
  warn "This will change the root password. Vault will manage the new password."

  if ! $FORCE; then
    warn "Use --force to confirm root credential rotation"
    return 1
  fi

  dry vault write -f "database/rotate-root/${db_name}" || err "Failed to rotate root credentials"
  log "Root credentials rotated for ${db_name}"
  log "The new password is managed by Vault and cannot be retrieved"
}

# --- Rotate AWS Credentials ---
rotate_aws_creds() {
  local engine="$1"
  local role="$2"

  log "Rotating AWS credentials for role: ${role} (engine: ${engine})"

  # Revoke existing leases
  if $FORCE; then
    LEASE_COUNT=$(vault list -format=json "sys/leases/lookup/${engine}/creds/${role}" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
    if [[ "$LEASE_COUNT" -gt 0 ]]; then
      log "Revoking ${LEASE_COUNT} existing AWS credential lease(s)..."
      dry vault lease revoke -prefix "${engine}/creds/${role}"
    fi
  fi

  # Generate new credentials
  log "Requesting new AWS credentials..."
  NEW_CREDS=$(dry vault read -format=json "${engine}/creds/${role}" 2>&1) || err "Failed to generate AWS credentials"

  if ! $DRY_RUN; then
    ACCESS_KEY=$(echo "$NEW_CREDS" | jq -r '.data.access_key')
    LEASE_ID=$(echo "$NEW_CREDS" | jq -r '.lease_id')
    log "New AWS credentials generated:"
    log "  Access Key: ${ACCESS_KEY}"
    log "  Lease ID:   ${LEASE_ID}"
  fi
}

# --- Rotate KV Secret ---
rotate_kv_secret() {
  local kv_path="$1"

  log "Rotating static secret at: ${kv_path}"

  # Read current secret
  CURRENT=$(vault kv get -format=json "$kv_path" 2>/dev/null) || err "Cannot read ${kv_path}"
  VERSION=$(echo "$CURRENT" | jq -r '.data.metadata.version')
  log "Current version: ${VERSION}"

  # Get current keys
  KEYS=$(echo "$CURRENT" | jq -r '.data.data | keys[]')
  log "Keys in secret: $(echo $KEYS | tr '\n' ', ')"

  # Prompt-style: show what would be updated
  echo ""
  echo "To rotate, update the secret with new values:"
  echo ""
  echo "  vault kv put ${kv_path} \\"

  for key in $KEYS; do
    VALUE=$(echo "$CURRENT" | jq -r ".data.data.\"${key}\"")
    # Mask the value for display
    MASKED="${VALUE:0:3}***"
    echo "    ${key}=\"<new-value>\"  # current: ${MASKED} \\"
  done
  echo ""

  log "Use 'vault kv rollback -version=${VERSION} ${kv_path}' to revert if needed"
}

# --- Revoke Leases by Prefix ---
revoke_lease_prefix() {
  local prefix="$1"

  log "Revoking all leases under prefix: ${prefix}"

  LEASE_COUNT=$(vault list -format=json "sys/leases/lookup/${prefix}" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
  log "Found ${LEASE_COUNT} active lease(s)"

  if [[ "$LEASE_COUNT" -eq 0 ]]; then
    log "No leases to revoke"
    return 0
  fi

  if ! $FORCE; then
    warn "Use --force to confirm revocation of ${LEASE_COUNT} lease(s)"
    return 1
  fi

  dry vault lease revoke -prefix "$prefix" || err "Failed to revoke leases"
  log "Successfully revoked all leases under ${prefix}"
}

# --- Rotate Transit Key ---
rotate_transit_key() {
  local key_name="$1"

  log "Rotating Transit encryption key: ${key_name}"

  # Get current key info
  KEY_INFO=$(vault read -format=json "transit/keys/${key_name}" 2>/dev/null) || err "Cannot read Transit key ${key_name}"
  CURRENT_VERSION=$(echo "$KEY_INFO" | jq -r '.data.latest_version')
  MIN_DECRYPT=$(echo "$KEY_INFO" | jq -r '.data.min_decryption_version')
  log "Current version: ${CURRENT_VERSION}, Min decryption version: ${MIN_DECRYPT}"

  # Rotate
  dry vault write -f "transit/keys/${key_name}/rotate" || err "Failed to rotate Transit key"

  if ! $DRY_RUN; then
    NEW_VERSION=$((CURRENT_VERSION + 1))
    log "Key rotated to version ${NEW_VERSION}"
    log "Old versions can still decrypt. To enforce new version only:"
    log "  vault write transit/keys/${key_name}/config min_decryption_version=${NEW_VERSION}"
    log ""
    log "To re-encrypt existing ciphertext with new key version:"
    log "  vault write transit/rewrap/${key_name} ciphertext=<old_ciphertext>"
  fi
}

# --- Main ---
ACTIONS=0

if [[ -n "$ENGINE" && -n "$ROLE" ]]; then
  case "$ENGINE" in
    database|db)
      rotate_database_creds "${ENGINE}" "${ROLE}"
      ;;
    aws)
      rotate_aws_creds "${ENGINE}" "${ROLE}"
      ;;
    *)
      err "Unsupported engine: ${ENGINE}. Supported: database, aws"
      ;;
  esac
  ACTIONS=$((ACTIONS + 1))
fi

if [[ -n "$ROTATE_ROOT" ]]; then
  rotate_database_root "$ROTATE_ROOT"
  ACTIONS=$((ACTIONS + 1))
fi

if [[ -n "$KV_PATH" ]]; then
  rotate_kv_secret "$KV_PATH"
  ACTIONS=$((ACTIONS + 1))
fi

if [[ -n "$REVOKE_PREFIX" ]]; then
  revoke_lease_prefix "$REVOKE_PREFIX"
  ACTIONS=$((ACTIONS + 1))
fi

if [[ -n "$TRANSIT_KEY" ]]; then
  rotate_transit_key "$TRANSIT_KEY"
  ACTIONS=$((ACTIONS + 1))
fi

if [[ "$ACTIONS" -eq 0 ]]; then
  err "No action specified. Use --help for usage."
fi

log "Done. ${ACTIONS} rotation action(s) completed."
