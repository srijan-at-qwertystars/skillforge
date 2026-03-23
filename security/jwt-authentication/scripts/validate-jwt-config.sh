#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# validate-jwt-config.sh — Audit JWT configuration for security issues
#
# Usage:
#   ./validate-jwt-config.sh [OPTIONS]
#
# Options:
#   --secret SECRET          HMAC secret string to check
#   --secret-file FILE       File containing HMAC secret
#   --rsa-key FILE           RSA private or public key file to check
#   --jwks-url URL           JWKS endpoint URL to validate
#   --check-env              Check common JWT-related environment variables
#   --all                    Run all applicable checks
#   -h, --help               Show this help message
#
# Checks performed:
#   • HMAC secret strength (length, entropy, common patterns)
#   • RSA key size (minimum 2048 bits)
#   • JWKS endpoint accessibility, TLS, format, key presence
#   • Environment variable misconfigurations
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed (FAIL)
#   2  Warnings issued but no failures
#
# Examples:
#   ./validate-jwt-config.sh --secret "my-secret"
#   ./validate-jwt-config.sh --rsa-key ./private.pem
#   ./validate-jwt-config.sh --jwks-url https://auth.example.com/.well-known/jwks.json
#   ./validate-jwt-config.sh --check-env
#   ./validate-jwt-config.sh --all --secret "$JWT_SECRET" --rsa-key ./key.pem
##############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# Counters
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

SECRET=""
SECRET_FILE=""
RSA_KEY=""
JWKS_URL=""
CHECK_ENV=false

usage() {
  sed -n '/^##*$/,/^##*$/{ /^##*$/d; s/^# \{0,1\}//; p }' "$0"
  exit 0
}

err() {
  echo -e "${RED}ERROR: $*${RESET}" >&2
  exit 1
}

pass() {
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  echo -e "  ${GREEN}[PASS]${RESET} $*"
}

warn() {
  WARN_COUNT=$(( WARN_COUNT + 1 ))
  echo -e "  ${YELLOW}[WARN]${RESET} $*"
}

fail() {
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  echo -e "  ${RED}[FAIL]${RESET} $*"
}

# ── Parse Arguments ──────────────────────────────────────────────────────────

if [[ $# -eq 0 ]]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --secret)
      SECRET="${2:-}"
      [[ -z "$SECRET" ]] && err "--secret requires a value"
      shift 2
      ;;
    --secret-file)
      SECRET_FILE="${2:-}"
      [[ -z "$SECRET_FILE" ]] && err "--secret-file requires a value"
      shift 2
      ;;
    --rsa-key)
      RSA_KEY="${2:-}"
      [[ -z "$RSA_KEY" ]] && err "--rsa-key requires a value"
      shift 2
      ;;
    --jwks-url)
      JWKS_URL="${2:-}"
      [[ -z "$JWKS_URL" ]] && err "--jwks-url requires a value"
      shift 2
      ;;
    --check-env)
      CHECK_ENV=true
      shift
      ;;
    --all)
      CHECK_ENV=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      err "Unknown option: $1"
      ;;
  esac
done

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║     JWT Configuration Auditor            ║${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${RESET}"
echo ""

# ── HMAC Secret Check ────────────────────────────────────────────────────────

check_hmac_secret() {
  local secret="$1"

  echo -e "${BOLD}── HMAC Secret Analysis ────────────────────${RESET}"
  echo ""

  local len=${#secret}

  # Length check
  if (( len >= 32 )); then
    pass "Secret length: ${len} characters (≥32 recommended)"
  elif (( len >= 16 )); then
    warn "Secret length: ${len} characters (≥32 recommended, ≥16 minimum)"
  else
    fail "Secret length: ${len} characters (too short! minimum 16, recommended 32+)"
  fi

  # Byte-length check for HS256 (needs 256 bits = 32 bytes)
  local byte_len
  byte_len="$(echo -n "$secret" | wc -c)"
  if (( byte_len < 32 )); then
    warn "Secret is ${byte_len} bytes — HS256 recommends ≥32 bytes (256 bits)"
  fi

  # Common weak secrets
  local -a WEAK_SECRETS=(
    "secret" "password" "jwt-secret" "jwt_secret" "changeme"
    "your-256-bit-secret" "shhhhh" "mysecret" "my-secret"
    "super-secret" "supersecret" "test" "dev" "development"
    "12345" "123456" "1234567890"
  )

  local secret_lower="${secret,,}"
  local is_weak=false
  for weak in "${WEAK_SECRETS[@]}"; do
    if [[ "$secret_lower" == "$weak" ]]; then
      is_weak=true
      break
    fi
  done

  if $is_weak; then
    fail "Secret matches a commonly-used weak secret"
  else
    pass "Secret does not match known weak patterns"
  fi

  # Entropy estimation (unique characters / total)
  local unique_chars
  unique_chars="$(echo -n "$secret" | fold -w1 | sort -u | wc -l)"
  local entropy_ratio
  if (( len > 0 )); then
    entropy_ratio="$(echo "scale=2; $unique_chars * 100 / $len" | bc 2>/dev/null || echo "0")"
  else
    entropy_ratio="0"
  fi

  if (( unique_chars <= 4 )); then
    fail "Very low character diversity: only ${unique_chars} unique characters"
  elif (( unique_chars <= 8 )); then
    warn "Low character diversity: ${unique_chars} unique characters"
  else
    pass "Character diversity: ${unique_chars} unique characters"
  fi

  # Check for all-numeric or all-alpha
  if [[ "$secret" =~ ^[0-9]+$ ]]; then
    warn "Secret is purely numeric — use mixed character types"
  elif [[ "$secret" =~ ^[a-zA-Z]+$ ]]; then
    warn "Secret is purely alphabetic — use mixed character types"
  fi

  echo ""
}

# ── RSA Key Check ────────────────────────────────────────────────────────────

check_rsa_key() {
  local key_file="$1"

  echo -e "${BOLD}── RSA Key Analysis ────────────────────────${RESET}"
  echo ""

  # File existence
  if [[ ! -f "$key_file" ]]; then
    fail "Key file not found: ${key_file}"
    echo ""
    return
  fi

  pass "Key file exists: ${key_file}"

  # File permissions
  local perms
  perms="$(stat -c '%a' "$key_file" 2>/dev/null || stat -f '%Lp' "$key_file" 2>/dev/null || echo "unknown")"
  if [[ "$perms" == "600" || "$perms" == "400" ]]; then
    pass "File permissions: ${perms} (restrictive)"
  elif [[ "$perms" == "644" || "$perms" == "640" ]]; then
    # Public keys may have 644
    if grep -q "PUBLIC KEY" "$key_file" 2>/dev/null; then
      pass "File permissions: ${perms} (acceptable for public key)"
    else
      warn "File permissions: ${perms} (private keys should be 600 or 400)"
    fi
  elif [[ "$perms" != "unknown" ]]; then
    if grep -q "PRIVATE KEY" "$key_file" 2>/dev/null; then
      fail "File permissions: ${perms} (private key is too permissive!)"
    else
      warn "File permissions: ${perms}"
    fi
  fi

  # Check if it's a valid key
  if ! openssl pkey -in "$key_file" -noout 2>/dev/null && \
     ! openssl rsa -in "$key_file" -pubin -noout 2>/dev/null; then
    fail "File does not contain a valid RSA key"
    echo ""
    return
  fi

  pass "Valid RSA key file"

  # Extract key size
  local key_bits
  if openssl pkey -in "$key_file" -noout 2>/dev/null; then
    key_bits="$(openssl rsa -in "$key_file" -text -noout 2>/dev/null | head -1 | grep -oP '[0-9]+' | head -1 || echo "0")"
  else
    key_bits="$(openssl rsa -in "$key_file" -pubin -text -noout 2>/dev/null | head -1 | grep -oP '[0-9]+' | head -1 || echo "0")"
  fi

  if [[ -n "$key_bits" && "$key_bits" -gt 0 ]]; then
    if (( key_bits >= 4096 )); then
      pass "Key size: ${key_bits} bits (strong)"
    elif (( key_bits >= 2048 )); then
      pass "Key size: ${key_bits} bits (acceptable)"
    elif (( key_bits >= 1024 )); then
      fail "Key size: ${key_bits} bits (below 2048-bit minimum!)"
    else
      fail "Key size: ${key_bits} bits (critically weak!)"
    fi
  else
    warn "Could not determine key size"
  fi

  echo ""
}

# ── JWKS Endpoint Check ─────────────────────────────────────────────────────

check_jwks_endpoint() {
  local url="$1"

  echo -e "${BOLD}── JWKS Endpoint Validation ────────────────${RESET}"
  echo ""

  # Check for curl
  if ! command -v curl &>/dev/null; then
    warn "curl not available — cannot validate JWKS endpoint"
    echo ""
    return
  fi

  # TLS check
  if [[ "$url" == https://* ]]; then
    pass "Endpoint uses HTTPS"
  elif [[ "$url" == http://* ]]; then
    fail "Endpoint uses HTTP — JWKS must be served over HTTPS in production"
  else
    warn "Unrecognized URL scheme: ${url}"
  fi

  # Accessibility check
  local http_code body
  http_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 "$url" 2>/dev/null || echo "000")"

  if [[ "$http_code" == "200" ]]; then
    pass "Endpoint accessible (HTTP ${http_code})"
  elif [[ "$http_code" == "000" ]]; then
    fail "Endpoint unreachable (connection failed)"
    echo ""
    return
  else
    fail "Endpoint returned HTTP ${http_code} (expected 200)"
    echo ""
    return
  fi

  # Fetch and validate JSON
  body="$(curl -s --connect-timeout 10 --max-time 15 "$url" 2>/dev/null || echo "")"

  if [[ -z "$body" ]]; then
    fail "Empty response from JWKS endpoint"
    echo ""
    return
  fi

  # Validate JSON structure
  local is_valid_json=false
  if command -v jq &>/dev/null; then
    if echo "$body" | jq . &>/dev/null; then
      is_valid_json=true
    fi
  elif command -v python3 &>/dev/null; then
    if echo "$body" | python3 -m json.tool &>/dev/null; then
      is_valid_json=true
    fi
  fi

  if $is_valid_json; then
    pass "Response is valid JSON"
  else
    fail "Response is not valid JSON"
    echo ""
    return
  fi

  # Check for "keys" array
  local has_keys=false
  local key_count=0
  if command -v jq &>/dev/null; then
    has_keys="$(echo "$body" | jq 'has("keys")' 2>/dev/null || echo "false")"
    key_count="$(echo "$body" | jq '.keys | length' 2>/dev/null || echo "0")"
  elif command -v python3 &>/dev/null; then
    has_keys="$(echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('true' if 'keys' in d and isinstance(d['keys'], list) else 'false')
" 2>/dev/null || echo "false")"
    key_count="$(echo "$body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d.get('keys', [])))
" 2>/dev/null || echo "0")"
  fi

  if [[ "$has_keys" == "true" ]]; then
    pass "JWKS contains 'keys' array"
  else
    fail "JWKS response missing 'keys' array"
  fi

  if (( key_count > 0 )); then
    pass "JWKS contains ${key_count} key(s)"
  else
    warn "JWKS 'keys' array is empty — no keys published"
  fi

  # Check each key has required fields
  if command -v jq &>/dev/null && [[ "$has_keys" == "true" ]]; then
    local missing_kty=0
    local missing_alg=0
    missing_kty="$(echo "$body" | jq '[.keys[] | select(.kty == null)] | length' 2>/dev/null || echo "0")"
    missing_alg="$(echo "$body" | jq '[.keys[] | select(.alg == null and .use == null)] | length' 2>/dev/null || echo "0")"

    if (( missing_kty == 0 )); then
      pass "All keys have 'kty' (key type) field"
    else
      fail "${missing_kty} key(s) missing required 'kty' field"
    fi

    if (( missing_alg == 0 )); then
      pass "All keys have 'alg' or 'use' field"
    else
      warn "${missing_alg} key(s) missing 'alg' and 'use' fields"
    fi
  fi

  echo ""
}

# ── Environment Variable Check ───────────────────────────────────────────────

check_env_vars() {
  echo -e "${BOLD}── Environment Variable Audit ──────────────${RESET}"
  echo ""

  # Common JWT-related env vars to check
  local -a JWT_SECRET_VARS=(
    "JWT_SECRET" "JWT_SECRET_KEY" "JWT_SIGNING_KEY"
    "TOKEN_SECRET" "AUTH_SECRET" "SECRET_KEY"
    "ACCESS_TOKEN_SECRET" "REFRESH_TOKEN_SECRET"
  )

  local -a JWT_CONFIG_VARS=(
    "JWT_ISSUER" "JWT_AUDIENCE" "JWT_EXPIRATION"
    "JWT_ALGORITHM" "JWT_JWKS_URI" "JWT_PUBLIC_KEY"
    "JWT_PRIVATE_KEY" "JWT_EXPIRES_IN"
  )

  local found_any=false

  # Check secret variables
  for var in "${JWT_SECRET_VARS[@]}"; do
    local val="${!var:-}"
    if [[ -n "$val" ]]; then
      found_any=true
      echo -e "  Found: ${BOLD}${var}${RESET} (set)"

      # Check if it looks like a placeholder
      local val_lower="${val,,}"
      if [[ "$val_lower" == "changeme" || "$val_lower" == "secret" || \
            "$val_lower" == "todo" || "$val_lower" == "replace_me" || \
            "$val_lower" == "your-secret-here" || "$val_lower" == "xxx" ]]; then
        fail "${var} contains a placeholder value — must set a real secret"
      elif (( ${#val} < 16 )); then
        fail "${var} is too short (${#val} chars, need ≥16)"
      elif (( ${#val} < 32 )); then
        warn "${var} is short (${#val} chars, recommend ≥32)"
      else
        pass "${var} length looks adequate (${#val} chars)"
      fi
    fi
  done

  # Check config variables
  for var in "${JWT_CONFIG_VARS[@]}"; do
    local val="${!var:-}"
    if [[ -n "$val" ]]; then
      found_any=true
      echo -e "  Found: ${BOLD}${var}${RESET}=${val}"

      # Algorithm checks
      if [[ "$var" == "JWT_ALGORITHM" ]]; then
        local alg_upper="${val^^}"
        case "$alg_upper" in
          NONE|"")
            fail "${var}='none' — the 'none' algorithm disables signature verification!"
            ;;
          HS256|HS384|HS512)
            pass "${var}=${val} (HMAC — ensure secret is strong)"
            ;;
          RS256|RS384|RS512|PS256|PS384|PS512)
            pass "${var}=${val} (RSA — ensure key size ≥2048)"
            ;;
          ES256|ES384|ES512)
            pass "${var}=${val} (ECDSA — good choice)"
            ;;
          *)
            warn "${var}=${val} (unrecognized algorithm)"
            ;;
        esac
      fi

      # Expiration checks
      if [[ "$var" == "JWT_EXPIRATION" || "$var" == "JWT_EXPIRES_IN" ]]; then
        if [[ "$val" =~ ^[0-9]+$ ]]; then
          if (( val > 86400 )); then
            warn "${var}=${val} — token lifetime exceeds 24 hours"
          elif (( val > 3600 )); then
            warn "${var}=${val} — consider shorter token lifetime for access tokens"
          else
            pass "${var}=${val} — reasonable token lifetime"
          fi
        fi
      fi

      # JWKS URI check
      if [[ "$var" == "JWT_JWKS_URI" ]]; then
        if [[ "$val" == http://* ]]; then
          fail "${var} uses HTTP — must use HTTPS in production"
        elif [[ "$val" == https://* ]]; then
          pass "${var} uses HTTPS"
        fi
      fi
    fi
  done

  if ! $found_any; then
    warn "No common JWT environment variables found"
    echo -e "  Checked: ${JWT_SECRET_VARS[*]}"
    echo -e "  Checked: ${JWT_CONFIG_VARS[*]}"
  fi

  echo ""
}

# ── Run Checks ───────────────────────────────────────────────────────────────

# Load secret from file if specified
if [[ -n "$SECRET_FILE" ]]; then
  if [[ ! -f "$SECRET_FILE" ]]; then
    err "Secret file not found: ${SECRET_FILE}"
  fi
  SECRET="$(cat "$SECRET_FILE")"
fi

if [[ -n "$SECRET" ]]; then
  check_hmac_secret "$SECRET"
fi

if [[ -n "$RSA_KEY" ]]; then
  check_rsa_key "$RSA_KEY"
fi

if [[ -n "$JWKS_URL" ]]; then
  check_jwks_endpoint "$JWKS_URL"
fi

if $CHECK_ENV; then
  check_env_vars
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo -e "${BOLD}── Summary ─────────────────────────────────${RESET}"
echo ""
echo -e "  ${GREEN}PASS: ${PASS_COUNT}${RESET}  |  ${YELLOW}WARN: ${WARN_COUNT}${RESET}  |  ${RED}FAIL: ${FAIL_COUNT}${RESET}"
echo ""

if (( FAIL_COUNT > 0 )); then
  echo -e "${RED}${BOLD}⚠  Security issues detected! Address FAIL items before deploying.${RESET}"
  exit 1
elif (( WARN_COUNT > 0 )); then
  echo -e "${YELLOW}${BOLD}⚠  Warnings issued. Review and address where possible.${RESET}"
  exit 2
else
  echo -e "${GREEN}${BOLD}✓  All checks passed.${RESET}"
  exit 0
fi
