#!/usr/bin/env bash
#
# rotate-keys.sh — JWT signing key rotation with grace period
#
# Usage:
#   ./rotate-keys.sh <algorithm> <jwks-file> [grace-days]
#
# Arguments:
#   algorithm    Key algorithm: rs256, es256, eddsa
#   jwks-file    Path to JWKS JSON file (will be updated in place)
#   grace-days   Days to keep old key in JWKS (default: 1, minimum: 0)
#
# Examples:
#   ./rotate-keys.sh es256 jwks.json              # Rotate with 1-day grace
#   ./rotate-keys.sh rs256 jwks.json 7            # Rotate with 7-day grace
#   ./rotate-keys.sh eddsa ./well-known/jwks.json # Rotate EdDSA key
#
# What it does:
#   1. Generates a new key pair with a timestamped kid
#   2. Adds new public key to the JWKS file
#   3. Marks old keys with a retire-after date
#   4. Optionally prunes keys past their grace period
#   5. Outputs the new kid for configuration update
#
# Requirements: openssl (1.1.1+), python3
#
set -euo pipefail

ALG="${1:-}"
JWKS_FILE="${2:-}"
GRACE_DAYS="${3:-1}"

KEYS_DIR="keys"
DATE_STAMP=$(date +%Y%m%d-%H%M%S)

log() { echo "[rotate-keys] $*"; }
err() { echo "[rotate-keys] ERROR: $*" >&2; exit 1; }

show_usage() {
    echo "Usage: $0 <algorithm> <jwks-file> [grace-days]"
    echo ""
    echo "Arguments:"
    echo "  algorithm    rs256, es256, or eddsa"
    echo "  jwks-file    Path to JWKS JSON file"
    echo "  grace-days   Days to keep old key active (default: 1)"
    echo ""
    echo "Examples:"
    echo "  $0 es256 jwks.json"
    echo "  $0 rs256 ./well-known/jwks.json 7"
    exit 0
}

[[ -z "$ALG" || -z "$JWKS_FILE" ]] && show_usage
[[ "$ALG" == "-h" || "$ALG" == "--help" ]] && show_usage

command -v openssl >/dev/null 2>&1 || err "openssl is required"
command -v python3 >/dev/null 2>&1 || err "python3 is required"

mkdir -p "$KEYS_DIR"
mkdir -p "$(dirname "$JWKS_FILE")"

# Initialize JWKS file if it doesn't exist
if [[ ! -f "$JWKS_FILE" ]]; then
    log "Creating new JWKS file: $JWKS_FILE"
    echo '{"keys":[]}' > "$JWKS_FILE"
fi

# Validate existing JWKS
python3 -c "import json; json.load(open('$JWKS_FILE'))" 2>/dev/null || \
    err "Invalid JSON in $JWKS_FILE"

NEW_KID="key-${DATE_STAMP}-${ALG}"
PRIV_PEM="${KEYS_DIR}/${NEW_KID}-private.pem"
PUB_PEM="${KEYS_DIR}/${NEW_KID}-public.pem"

# --- Generate New Key ---
log "Generating new ${ALG} key pair..."
log "  kid: ${NEW_KID}"

case "$ALG" in
    rs256|RS256)
        openssl genrsa -out "$PRIV_PEM" 2048 2>/dev/null
        openssl rsa -in "$PRIV_PEM" -pubout -out "$PUB_PEM" 2>/dev/null
        JWK_ALG="RS256"
        JWK_KTY="RSA"
        ;;
    es256|ES256)
        openssl ecparam -genkey -name prime256v1 -noout -out "$PRIV_PEM" 2>/dev/null
        openssl ec -in "$PRIV_PEM" -pubout -out "$PUB_PEM" 2>/dev/null
        JWK_ALG="ES256"
        JWK_KTY="EC"
        ;;
    eddsa|EdDSA|ed25519)
        openssl genpkey -algorithm Ed25519 -out "$PRIV_PEM" 2>/dev/null || \
            err "Ed25519 not supported by your OpenSSL version"
        openssl pkey -in "$PRIV_PEM" -pubout -out "$PUB_PEM" 2>/dev/null
        JWK_ALG="EdDSA"
        JWK_KTY="OKP"
        ;;
    *)
        err "Unsupported algorithm: $ALG (use rs256, es256, or eddsa)"
        ;;
esac

log "  Private key: ${PRIV_PEM}"
log "  Public key:  ${PUB_PEM}"

# --- Update JWKS ---
log "Updating JWKS file: ${JWKS_FILE}"

python3 << PYEOF
import json
from datetime import datetime, timedelta, timezone

jwks_file = "$JWKS_FILE"
new_kid = "$NEW_KID"
jwk_alg = "$JWK_ALG"
jwk_kty = "$JWK_KTY"
grace_days = int("$GRACE_DAYS")
pub_pem = "$PUB_PEM"

now = datetime.now(timezone.utc)
retire_after = (now + timedelta(days=grace_days)).isoformat()

# Load existing JWKS
with open(jwks_file) as f:
    jwks = json.load(f)

# Mark existing keys with retire-after date (if not already set)
for key in jwks.get("keys", []):
    if "_retire_after" not in key and key.get("_status") != "retiring":
        key["_status"] = "retiring"
        key["_retire_after"] = retire_after
        print(f"  Marked key '{key.get('kid', 'unknown')}' to retire after {retire_after}")

# Prune keys past their grace period
pruned = []
active_keys = []
for key in jwks.get("keys", []):
    ra = key.get("_retire_after")
    if ra:
        try:
            retire_dt = datetime.fromisoformat(ra)
            if now > retire_dt:
                pruned.append(key.get("kid", "unknown"))
                continue
        except (ValueError, TypeError):
            pass
    active_keys.append(key)

if pruned:
    for kid in pruned:
        print(f"  Pruned expired key: {kid}")

# Build new key entry
new_key = {
    "kty": jwk_kty,
    "kid": new_kid,
    "use": "sig",
    "alg": jwk_alg,
    "_status": "active",
    "_created": now.isoformat(),
    "_pem_file": pub_pem,
}

if jwk_kty == "EC":
    new_key["crv"] = "P-256"
elif jwk_kty == "OKP":
    new_key["crv"] = "Ed25519"

# Add new key at the beginning (active key first)
active_keys.insert(0, new_key)
jwks["keys"] = active_keys

# Write updated JWKS
with open(jwks_file, "w") as f:
    json.dump(jwks, f, indent=2)

print(f"  Added new key: {new_kid}")
print(f"  Total keys in JWKS: {len(active_keys)}")
PYEOF

# --- Summary ---
echo ""
log "═══════════════════════════════════════"
log "  Key rotation complete!"
log "═══════════════════════════════════════"
log ""
log "  New signing key:  ${NEW_KID}"
log "  Private key:      ${PRIV_PEM}"
log "  Public key:       ${PUB_PEM}"
log "  JWKS updated:     ${JWKS_FILE}"
log "  Grace period:     ${GRACE_DAYS} day(s)"
log ""
log "  Next steps:"
log "  1. Deploy the updated JWKS file to your JWKS endpoint"
log "  2. Update your auth service to sign with kid=${NEW_KID}"
log "  3. Old keys will remain valid for ${GRACE_DAYS} day(s)"
log "  4. Run this script again after grace period to prune old keys"
log ""
log "  SECURITY: ${PRIV_PEM} must be stored securely."
log "            Add '${KEYS_DIR}/' to .gitignore."
