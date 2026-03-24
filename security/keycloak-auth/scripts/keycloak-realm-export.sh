#!/usr/bin/env bash
#
# keycloak-realm-export.sh — Exports realm configuration for environment promotion
#
# Usage:
#   ./keycloak-realm-export.sh <realm-name>                  # Export realm
#   ./keycloak-realm-export.sh <realm-name> --full            # Include users/secrets
#   ./keycloak-realm-export.sh <realm-name> --output dir/     # Custom output directory
#   ./keycloak-realm-export.sh <realm-name> --strip-ids       # Remove UUIDs for portability
#
# Environment variables:
#   KEYCLOAK_URL       Keycloak base URL (default: http://localhost:8080)
#   KC_ADMIN           Admin username (default: admin)
#   KC_ADMIN_PASSWORD  Admin password (default: admin)
#   KC_REALM           Admin realm for auth (default: master)
#
# This script exports a Keycloak realm configuration via the Admin REST API,
# strips sensitive data (client secrets, LDAP passwords, SMTP credentials) by
# default, and produces a clean JSON file suitable for version control and
# environment promotion (dev → staging → prod).
#
# Prerequisites:
#   - curl and jq installed
#   - Keycloak running and accessible
#   - Admin credentials with realm export permissions

set -euo pipefail

# --- Configuration ---
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KC_ADMIN="${KC_ADMIN:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"
KC_REALM="${KC_REALM:-master}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Functions ---

check_prerequisites() {
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "'$cmd' is required but not installed."
            exit 1
        fi
    done
}

get_admin_token() {
    local token
    token=$(curl -sf -X POST \
        "${KEYCLOAK_URL}/realms/${KC_REALM}/protocol/openid-connect/token" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=${KC_ADMIN}" \
        -d "password=${KC_ADMIN_PASSWORD}" \
        | jq -r '.access_token')

    if [ -z "$token" ] || [ "$token" = "null" ]; then
        log_error "Failed to obtain admin token. Check credentials and Keycloak URL."
        exit 1
    fi
    echo "$token"
}

export_realm() {
    local realm="$1"
    local token="$2"

    log_info "Exporting realm '${realm}'..."

    # Export the full realm representation
    local realm_json
    realm_json=$(curl -sf -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${realm}")

    if [ -z "$realm_json" ] || [ "$realm_json" = "null" ]; then
        log_error "Failed to export realm '${realm}'. Does it exist?"
        exit 1
    fi

    # Export clients
    log_info "Exporting clients..."
    local clients_json
    clients_json=$(curl -sf -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/clients" | jq '.')

    # Export client scopes
    log_info "Exporting client scopes..."
    local client_scopes_json
    client_scopes_json=$(curl -sf -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/client-scopes" | jq '.')

    # Export roles
    log_info "Exporting realm roles..."
    local roles_json
    roles_json=$(curl -sf -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/roles" | jq '.')

    # Export groups
    log_info "Exporting groups..."
    local groups_json
    groups_json=$(curl -sf -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/groups" | jq '.')

    # Export authentication flows
    log_info "Exporting authentication flows..."
    local flows_json
    flows_json=$(curl -sf -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/authentication/flows" | jq '.')

    # Export identity providers
    log_info "Exporting identity providers..."
    local idps_json
    idps_json=$(curl -sf -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/identity-provider/instances" | jq '.')

    # Assemble the full export
    echo "$realm_json" | jq \
        --argjson clients "$clients_json" \
        --argjson clientScopes "$client_scopes_json" \
        --argjson roles "$roles_json" \
        --argjson groups "$groups_json" \
        --argjson authFlows "$flows_json" \
        --argjson idps "$idps_json" \
        '. + {
            clients: $clients,
            clientScopes: $clientScopes,
            roles: { realm: $roles },
            groups: $groups,
            authenticationFlows: $authFlows,
            identityProviders: $idps
        }'
}

strip_sensitive_data() {
    local json="$1"

    log_info "Stripping sensitive data..."

    echo "$json" | jq '
        # Strip client secrets
        (.clients // []) |= map(
            .secret = "**REDACTED**" |
            .attributes."client.secret.creation.time" = null
        ) |

        # Strip LDAP bind credentials
        (.components."org.keycloak.storage.UserStorageProvider" // []) |= map(
            if .providerId == "ldap" then
                .config.bindCredential = ["**REDACTED**"]
            else . end
        ) |

        # Strip SMTP password
        .smtpServer.password = "**REDACTED**" |

        # Strip identity provider secrets
        (.identityProviders // []) |= map(
            .config.clientSecret = "**REDACTED**"
        ) |

        # Strip browser security headers (these have defaults)
        # Keep them but note they are environment-specific

        # Nullify sensitive realm keys
        del(.privateKey) |
        del(.publicKey) |
        del(.certificate) |
        del(.codeSecret)
    '
}

strip_ids() {
    local json="$1"

    log_info "Stripping UUIDs for portability..."

    echo "$json" | jq '
        del(.id) |
        (.clients // []) |= map(del(.id)) |
        (.clientScopes // []) |= map(del(.id)) |
        (.roles.realm // []) |= map(del(.id)) |
        (.groups // []) |= map(del(.id)) |
        (.authenticationFlows // []) |= map(del(.id)) |
        (.identityProviders // []) |= map(del(.internalId))
    '
}

export_users() {
    local realm="$1"
    local token="$2"

    log_info "Exporting users (this may take a while for large realms)..."

    local page=0
    local page_size=100
    local all_users="[]"

    while true; do
        local users
        users=$(curl -sf -H "Authorization: Bearer ${token}" \
            "${KEYCLOAK_URL}/admin/realms/${realm}/users?first=$((page * page_size))&max=${page_size}")

        local count
        count=$(echo "$users" | jq 'length')

        if [ "$count" -eq 0 ]; then
            break
        fi

        # Strip sensitive user data
        users=$(echo "$users" | jq '[.[] | del(.credentials) | del(.federatedIdentities)]')
        all_users=$(echo "$all_users" "$users" | jq -s '.[0] + .[1]')

        page=$((page + 1))

        if [ "$count" -lt "$page_size" ]; then
            break
        fi
    done

    local user_count
    user_count=$(echo "$all_users" | jq 'length')
    log_info "Exported ${user_count} users."
    echo "$all_users"
}

# --- Main ---

check_prerequisites

REALM_NAME=""
OUTPUT_DIR="."
FULL_EXPORT=false
STRIP_IDS_FLAG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            FULL_EXPORT=true
            shift
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --strip-ids)
            STRIP_IDS_FLAG=true
            shift
            ;;
        --help|-h)
            head -18 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            REALM_NAME="$1"
            shift
            ;;
    esac
done

if [ -z "$REALM_NAME" ]; then
    log_error "Realm name is required. Usage: $0 <realm-name>"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Get admin token
TOKEN=$(get_admin_token)
log_info "Authenticated to Keycloak."

# Export realm
EXPORT_JSON=$(export_realm "$REALM_NAME" "$TOKEN")

# Strip sensitive data (unless --full)
if [ "$FULL_EXPORT" = false ]; then
    EXPORT_JSON=$(strip_sensitive_data "$EXPORT_JSON")
fi

# Strip IDs if requested
if [ "$STRIP_IDS_FLAG" = true ]; then
    EXPORT_JSON=$(strip_ids "$EXPORT_JSON")
fi

# Write realm export
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
REALM_FILE="${OUTPUT_DIR}/${REALM_NAME}-realm-${TIMESTAMP}.json"
echo "$EXPORT_JSON" | jq '.' > "$REALM_FILE"
log_info "Realm exported to: ${REALM_FILE}"

# Export users if --full
if [ "$FULL_EXPORT" = true ]; then
    USERS_JSON=$(export_users "$REALM_NAME" "$TOKEN")
    USERS_FILE="${OUTPUT_DIR}/${REALM_NAME}-users-${TIMESTAMP}.json"
    echo "$USERS_JSON" | jq '.' > "$USERS_FILE"
    log_info "Users exported to: ${USERS_FILE}"
fi

# Summary
FILE_SIZE=$(wc -c < "$REALM_FILE" | tr -d ' ')
log_info "Export complete. File size: ${FILE_SIZE} bytes"
log_warn "Review the export file before committing to version control."
if [ "$FULL_EXPORT" = false ]; then
    log_info "Sensitive data has been redacted. Use --full to include secrets (not recommended for VCS)."
fi
