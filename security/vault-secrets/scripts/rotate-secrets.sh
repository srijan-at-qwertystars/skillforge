#!/usr/bin/env bash
#
# rotate-secrets.sh — Zero-downtime database credential rotation with Vault
#
# Usage:
#   ./rotate-secrets.sh --role app-db                          # Rotate credentials for a role
#   ./rotate-secrets.sh --role app-db --grace-period 300       # Keep old creds alive for 5 min
#   ./rotate-secrets.sh --rotate-root mydb                     # Rotate root DB password
#   ./rotate-secrets.sh --role app-db --revoke-old             # Rotate and revoke old leases
#   ./rotate-secrets.sh --role app-db --notify webhook-url     # Notify via webhook after rotation
#   ./rotate-secrets.sh --status app-db                        # Show active leases for a role
#   ./rotate-secrets.sh --dry-run --role app-db                # Preview without changes
#
# Zero-Downtime Strategy:
#   1. Request new dynamic credentials from Vault
#   2. Verify new credentials work (optional --verify-cmd)
#   3. Write new credentials to output file (optional --output)
#   4. Signal application to pick up new credentials (optional --signal-cmd)
#   5. Wait grace period for in-flight connections to drain
#   6. Revoke old leases (only with --revoke-old)
#
# Prerequisites:
#   - vault CLI configured (VAULT_ADDR, VAULT_TOKEN)
#   - Database secrets engine enabled with configured roles

set -euo pipefail

# --- Defaults ---
ROLE=""
DB_ENGINE="database"
ROTATE_ROOT=""
REVOKE_OLD=false
GRACE_PERIOD=60
DRY_RUN=false
NOTIFY=""
STATUS_ONLY=""
SIGNAL_CMD=""
VERIFY_CMD=""
OUTPUT_FILE=""

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)           ROLE="$2"; shift 2 ;;
    --engine)         DB_ENGINE="$2"; shift 2 ;;
    --rotate-root)    ROTATE_ROOT="$2"; shift 2 ;;
    --revoke-old)     REVOKE_OLD=true; shift ;;
    --grace-period)   GRACE_PERIOD="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --notify)         NOTIFY="$2"; shift 2 ;;
    --status)         STATUS_ONLY="$2"; shift 2 ;;
    --signal-cmd)     SIGNAL_CMD="$2"; shift 2 ;;
    --verify-cmd)     VERIFY_CMD="$2"; shift 2 ;;
    --output)         OUTPUT_FILE="$2"; shift 2 ;;
    --help|-h)        head -20 "$0" | tail -18; exit 0 ;;
    *)                echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Helpers ---
log()  { echo -e "\033[1;32m[$(date '+%H:%M:%S')]\033[0m $1"; }
warn() { echo -e "\033[1;33m[$(date '+%H:%M:%S')] WARN:\033[0m $1"; }
err()  { echo -e "\033[1;31m[$(date '+%H:%M:%S')] ERROR:\033[0m $1" >&2; exit 1; }

dry() {
  if $DRY_RUN; then
    log "DRY RUN: $*"
    return 0
  fi
  "$@"
}

notify() {
  local message="$1"
  if [[ -n "$NOTIFY" ]]; then
    curl -sf -X POST "$NOTIFY" \
      -H "Content-Type: application/json" \
      -d "{\"text\":\"[Vault Rotation] ${message}\"}" 2>/dev/null || \
      warn "Webhook notification failed"
  fi
}

# --- Preflight ---
command -v vault >/dev/null 2>&1 || err "vault CLI not found"
[[ -n "${VAULT_ADDR:-}" ]] || err "VAULT_ADDR not set"
[[ -n "${VAULT_TOKEN:-}" ]] || err "VAULT_TOKEN not set"
vault token lookup &>/dev/null || err "Invalid or expired Vault token"

# --- Show Status ---
if [[ -n "$STATUS_ONLY" ]]; then
  log "Active leases for ${DB_ENGINE}/creds/${STATUS_ONLY}:"
  LEASES=$(vault list -format=json \
    "sys/leases/lookup/${DB_ENGINE}/creds/${STATUS_ONLY}" 2>/dev/null || echo "[]")
  COUNT=$(echo "$LEASES" | jq 'length')
  log "Total active leases: ${COUNT}"

  if [[ "$COUNT" -gt 0 ]]; then
    echo "$LEASES" | jq -r '.[]' | head -20 | while read -r lease_key; do
      LEASE_INFO=$(vault write -format=json sys/leases/lookup \
        lease_id="${DB_ENGINE}/creds/${STATUS_ONLY}/${lease_key}" 2>/dev/null || echo '{}')
      TTL=$(echo "$LEASE_INFO" | jq -r '.data.ttl // "unknown"')
      echo "  ${lease_key} (TTL: ${TTL}s)"
    done
    [[ "$COUNT" -gt 20 ]] && log "  ... and $((COUNT - 20)) more"
  fi
  exit 0
fi

# --- Rotate Root ---
if [[ -n "$ROTATE_ROOT" ]]; then
  log "Rotating root credentials for database: ${ROTATE_ROOT}"
  warn "After rotation, only Vault knows the new root password"

  vault read "${DB_ENGINE}/config/${ROTATE_ROOT}" &>/dev/null || \
    err "Cannot read database config for ${ROTATE_ROOT}"

  dry vault write -f "${DB_ENGINE}/rotate-root/${ROTATE_ROOT}" || \
    err "Root credential rotation failed"

  log "Root credentials rotated for ${ROTATE_ROOT}"
  notify "Root credentials rotated for database '${ROTATE_ROOT}'"
  exit 0
fi

# --- Validate Role ---
[[ -n "$ROLE" ]] || err "No action specified. Use --role, --rotate-root, or --status."

log "Verifying role: ${DB_ENGINE}/roles/${ROLE}"
ROLE_CONFIG=$(vault read -format=json "${DB_ENGINE}/roles/${ROLE}" 2>/dev/null) || \
  err "Role '${ROLE}' not found in engine '${DB_ENGINE}'"

DEFAULT_TTL=$(echo "$ROLE_CONFIG" | jq -r '.data.default_ttl // 3600')
MAX_TTL=$(echo "$ROLE_CONFIG" | jq -r '.data.max_ttl // 86400')
log "Role TTLs: default=${DEFAULT_TTL}s, max=${MAX_TTL}s"

# --- Snapshot Old Leases ---
OLD_LEASES=$(vault list -format=json \
  "sys/leases/lookup/${DB_ENGINE}/creds/${ROLE}" 2>/dev/null || echo "[]")
OLD_LEASE_COUNT=$(echo "$OLD_LEASES" | jq 'length')
log "Existing active leases: ${OLD_LEASE_COUNT}"

# --- Generate New Credentials ---
log "Requesting new database credentials..."
if $DRY_RUN; then
  log "DRY RUN: vault read ${DB_ENGINE}/creds/${ROLE}"
  log "DRY RUN: Would generate new credentials, verify, and signal app"
  if $REVOKE_OLD; then
    log "DRY RUN: Would wait ${GRACE_PERIOD}s then revoke ${OLD_LEASE_COUNT} old lease(s)"
  fi
  exit 0
fi

NEW_CREDS=$(vault read -format=json "${DB_ENGINE}/creds/${ROLE}") || \
  err "Failed to generate new credentials"

NEW_USER=$(echo "$NEW_CREDS" | jq -r '.data.username')
NEW_PASS=$(echo "$NEW_CREDS" | jq -r '.data.password')
NEW_LEASE=$(echo "$NEW_CREDS" | jq -r '.lease_id')
NEW_TTL=$(echo "$NEW_CREDS" | jq -r '.lease_duration')

log "New credentials generated:"
log "  Username: ${NEW_USER}"
log "  Lease ID: ${NEW_LEASE}"
log "  TTL:      ${NEW_TTL}s"

# --- Verify New Credentials ---
if [[ -n "$VERIFY_CMD" ]]; then
  log "Verifying new credentials..."
  EXPANDED_CMD=$(echo "$VERIFY_CMD" | \
    sed "s|{username}|${NEW_USER}|g; s|{password}|${NEW_PASS}|g")
  if eval "$EXPANDED_CMD" &>/dev/null; then
    log "Credential verification succeeded"
  else
    warn "Credential verification FAILED — revoking new lease"
    vault lease revoke "$NEW_LEASE" 2>/dev/null || true
    err "New credentials do not work. Rotation aborted. Old creds unchanged."
  fi
fi

# --- Write Output ---
if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$NEW_CREDS" | jq -r '.data | to_entries | map("\(.key)=\(.value)") | .[]' \
    > "$OUTPUT_FILE"
  chmod 600 "$OUTPUT_FILE"
  log "Credentials written to ${OUTPUT_FILE}"
fi

# --- Signal Application ---
if [[ -n "$SIGNAL_CMD" ]]; then
  log "Signaling application: ${SIGNAL_CMD}"
  eval "$SIGNAL_CMD" || warn "Signal command returned non-zero"
fi

# --- Grace Period + Revoke Old ---
if $REVOKE_OLD && [[ "$OLD_LEASE_COUNT" -gt 0 ]]; then
  log "Waiting ${GRACE_PERIOD}s for in-flight connections to drain..."
  sleep "$GRACE_PERIOD"

  log "Revoking ${OLD_LEASE_COUNT} old lease(s)..."
  REVOKED=0
  FAILED=0
  echo "$OLD_LEASES" | jq -r '.[]' | while read -r lease_key; do
    if vault lease revoke "${DB_ENGINE}/creds/${ROLE}/${lease_key}" 2>/dev/null; then
      REVOKED=$((REVOKED + 1))
    else
      FAILED=$((FAILED + 1))
    fi
  done
  log "Old lease revocation complete"
elif [[ "$OLD_LEASE_COUNT" -gt 0 ]]; then
  log "Old leases (${OLD_LEASE_COUNT}) will expire naturally"
  log "Use --revoke-old to revoke immediately after grace period"
fi

notify "Rotated credentials for role '${ROLE}'. New user: ${NEW_USER}. Old leases: ${OLD_LEASE_COUNT}."
log "Rotation complete for role: ${ROLE}"
