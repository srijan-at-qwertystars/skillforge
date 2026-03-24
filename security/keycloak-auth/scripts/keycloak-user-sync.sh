#!/usr/bin/env bash
#
# keycloak-user-sync.sh — Syncs users from CSV or LDAP into Keycloak via Admin API
#
# Usage:
#   ./keycloak-user-sync.sh --csv users.csv              # Import users from CSV
#   ./keycloak-user-sync.sh --csv users.csv --realm myapp # Specify realm
#   ./keycloak-user-sync.sh --csv users.csv --dry-run     # Preview without changes
#   ./keycloak-user-sync.sh --ldap                        # Trigger LDAP full sync
#   ./keycloak-user-sync.sh --ldap --changed-only         # Trigger LDAP changed-users sync
#
# CSV Format (header row required):
#   username,email,firstName,lastName,enabled,password,groups,roles
#   jdoe,john@example.com,John,Doe,true,TempPass123!,engineering;devops,user;developer
#
# Notes:
#   - Groups and roles are semicolon-separated within the CSV field
#   - Password field is optional; if set, it creates a temporary password
#   - If a user already exists (by username), the script updates their attributes
#
# Environment variables:
#   KEYCLOAK_URL       Keycloak base URL (default: http://localhost:8080)
#   KC_ADMIN           Admin username (default: admin)
#   KC_ADMIN_PASSWORD  Admin password (default: admin)
#   KC_REALM           Target realm (default: my-realm, override with --realm)
#
# Prerequisites:
#   - curl and jq installed
#   - Keycloak running and accessible

set -euo pipefail

# --- Configuration ---
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KC_ADMIN="${KC_ADMIN:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"
KC_TARGET_REALM="${KC_REALM:-my-realm}"

# --- Counters ---
CREATED=0
UPDATED=0
SKIPPED=0
ERRORS=0

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $*"; }

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
        "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=${KC_ADMIN}" \
        -d "password=${KC_ADMIN_PASSWORD}" \
        2>/dev/null | jq -r '.access_token // empty')

    if [ -z "$token" ]; then
        log_error "Failed to obtain admin token. Check credentials and Keycloak URL."
        exit 1
    fi
    echo "$token"
}

refresh_token_if_needed() {
    # Tokens expire after 60s by default for admin-cli. Re-authenticate.
    get_admin_token
}

get_user_by_username() {
    local realm="$1"
    local username="$2"
    local token="$3"

    curl -sf -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/users?username=$(urlencode "$username")&exact=true" \
        2>/dev/null | jq '.[0] // empty'
}

urlencode() {
    python3 -c "import urllib.parse; print(urllib.parse.quote('$1'))" 2>/dev/null || \
    echo "$1" | sed 's/ /%20/g; s/!/%21/g; s/"/%22/g; s/#/%23/g; s/\$/%24/g; s/&/%26/g; s/'\''/%27/g; s/(/%28/g; s/)/%29/g; s/+/%2B/g; s/,/%2C/g; s/:/%3A/g; s/;/%3B/g; s/@/%40/g'
}

create_user() {
    local realm="$1"
    local token="$2"
    local username="$3"
    local email="$4"
    local first_name="$5"
    local last_name="$6"
    local enabled="$7"
    local password="$8"

    local user_json
    user_json=$(jq -n \
        --arg username "$username" \
        --arg email "$email" \
        --arg firstName "$first_name" \
        --arg lastName "$last_name" \
        --argjson enabled "${enabled:-true}" \
        '{
            username: $username,
            email: $email,
            firstName: $firstName,
            lastName: $lastName,
            enabled: $enabled,
            emailVerified: true
        }')

    # Add credentials if password provided
    if [ -n "$password" ]; then
        user_json=$(echo "$user_json" | jq \
            --arg password "$password" \
            '. + { credentials: [{ type: "password", value: $password, temporary: true }] }')
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/users" \
        -d "$user_json")

    if [ "$http_code" = "201" ]; then
        return 0
    else
        return 1
    fi
}

update_user() {
    local realm="$1"
    local token="$2"
    local user_id="$3"
    local email="$4"
    local first_name="$5"
    local last_name="$6"
    local enabled="$7"

    local user_json
    user_json=$(jq -n \
        --arg email "$email" \
        --arg firstName "$first_name" \
        --arg lastName "$last_name" \
        --argjson enabled "${enabled:-true}" \
        '{
            email: $email,
            firstName: $firstName,
            lastName: $lastName,
            enabled: $enabled
        }')

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/users/${user_id}" \
        -d "$user_json")

    [ "$http_code" = "204" ]
}

assign_groups() {
    local realm="$1"
    local token="$2"
    local user_id="$3"
    local groups_str="$4"

    if [ -z "$groups_str" ]; then return; fi

    IFS=';' read -ra groups <<< "$groups_str"
    for group_name in "${groups[@]}"; do
        group_name=$(echo "$group_name" | xargs)  # trim whitespace
        [ -z "$group_name" ] && continue

        # Find group by name
        local group_id
        group_id=$(curl -sf -H "Authorization: Bearer ${token}" \
            "${KEYCLOAK_URL}/admin/realms/${realm}/groups?search=$(urlencode "$group_name")" \
            2>/dev/null | jq -r --arg name "$group_name" '.[] | select(.name == $name) | .id // empty')

        if [ -z "$group_id" ]; then
            log_warn "  Group '${group_name}' not found. Skipping."
            continue
        fi

        curl -sf -X PUT \
            -H "Authorization: Bearer ${token}" \
            "${KEYCLOAK_URL}/admin/realms/${realm}/users/${user_id}/groups/${group_id}" \
            >/dev/null 2>&1 || log_warn "  Failed to assign group '${group_name}'."
    done
}

assign_roles() {
    local realm="$1"
    local token="$2"
    local user_id="$3"
    local roles_str="$4"

    if [ -z "$roles_str" ]; then return; fi

    IFS=';' read -ra roles <<< "$roles_str"
    local role_payload="["
    local first=true

    for role_name in "${roles[@]}"; do
        role_name=$(echo "$role_name" | xargs)
        [ -z "$role_name" ] && continue

        # Get role details
        local role_json
        role_json=$(curl -sf -H "Authorization: Bearer ${token}" \
            "${KEYCLOAK_URL}/admin/realms/${realm}/roles/${role_name}" 2>/dev/null)

        if [ -z "$role_json" ] || echo "$role_json" | jq -e '.error' &>/dev/null; then
            log_warn "  Role '${role_name}' not found. Skipping."
            continue
        fi

        if [ "$first" = true ]; then first=false; else role_payload+=","; fi
        role_payload+="$role_json"
    done

    role_payload+="]"

    if [ "$role_payload" != "[]" ]; then
        curl -sf -X POST \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            "${KEYCLOAK_URL}/admin/realms/${realm}/users/${user_id}/role-mappings/realm" \
            -d "$role_payload" >/dev/null 2>&1 || log_warn "  Failed to assign roles."
    fi
}

sync_from_csv() {
    local csv_file="$1"
    local realm="$2"
    local dry_run="$3"

    if [ ! -f "$csv_file" ]; then
        log_error "CSV file not found: ${csv_file}"
        exit 1
    fi

    local token
    token=$(get_admin_token)
    log_info "Authenticated to Keycloak."

    # Read header to determine column positions
    local header
    header=$(head -1 "$csv_file")
    log_info "CSV header: ${header}"
    log_info "Starting user sync to realm '${realm}'..."
    echo ""

    local line_num=0
    local token_refresh_counter=0

    while IFS=, read -r username email first_name last_name enabled password groups roles; do
        line_num=$((line_num + 1))

        # Skip header
        if [ $line_num -eq 1 ]; then continue; fi

        # Skip empty lines
        username=$(echo "$username" | xargs | tr -d '"')
        [ -z "$username" ] && continue

        # Clean fields
        email=$(echo "$email" | xargs | tr -d '"')
        first_name=$(echo "$first_name" | xargs | tr -d '"')
        last_name=$(echo "$last_name" | xargs | tr -d '"')
        enabled=$(echo "${enabled:-true}" | xargs | tr -d '"')
        password=$(echo "${password:-}" | xargs | tr -d '"')
        groups=$(echo "${groups:-}" | xargs | tr -d '"')
        roles=$(echo "${roles:-}" | xargs | tr -d '"')

        # Refresh token every 20 users to avoid expiry
        token_refresh_counter=$((token_refresh_counter + 1))
        if [ $token_refresh_counter -ge 20 ]; then
            token=$(refresh_token_if_needed)
            token_refresh_counter=0
        fi

        log_info "Processing user: ${username} (${email})"

        if [ "$dry_run" = true ]; then
            log_debug "  [DRY RUN] Would create/update: ${username} <${email}>"
            log_debug "  [DRY RUN]   Name: ${first_name} ${last_name}, Enabled: ${enabled}"
            [ -n "$groups" ] && log_debug "  [DRY RUN]   Groups: ${groups}"
            [ -n "$roles" ] && log_debug "  [DRY RUN]   Roles: ${roles}"
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Check if user exists
        local existing_user
        existing_user=$(get_user_by_username "$realm" "$username" "$token")

        if [ -n "$existing_user" ] && [ "$existing_user" != "null" ]; then
            # Update existing user
            local user_id
            user_id=$(echo "$existing_user" | jq -r '.id')
            if update_user "$realm" "$token" "$user_id" "$email" "$first_name" "$last_name" "$enabled"; then
                log_info "  Updated user: ${username}"
                UPDATED=$((UPDATED + 1))
            else
                log_error "  Failed to update user: ${username}"
                ERRORS=$((ERRORS + 1))
                continue
            fi
        else
            # Create new user
            if create_user "$realm" "$token" "$username" "$email" "$first_name" "$last_name" "$enabled" "$password"; then
                log_info "  Created user: ${username}"
                CREATED=$((CREATED + 1))
                # Get the newly created user ID
                existing_user=$(get_user_by_username "$realm" "$username" "$token")
            else
                log_error "  Failed to create user: ${username}"
                ERRORS=$((ERRORS + 1))
                continue
            fi
        fi

        # Assign groups and roles
        local user_id
        user_id=$(echo "$existing_user" | jq -r '.id // empty')
        if [ -n "$user_id" ]; then
            [ -n "$groups" ] && assign_groups "$realm" "$token" "$user_id" "$groups"
            [ -n "$roles" ] && assign_roles "$realm" "$token" "$user_id" "$roles"
        fi

    done < "$csv_file"
}

trigger_ldap_sync() {
    local realm="$1"
    local changed_only="$2"

    local token
    token=$(get_admin_token)
    log_info "Authenticated to Keycloak."

    # Find LDAP federation providers
    local providers
    providers=$(curl -sf -H "Authorization: Bearer ${token}" \
        "${KEYCLOAK_URL}/admin/realms/${realm}/components?type=org.keycloak.storage.UserStorageProvider" \
        2>/dev/null | jq '[.[] | select(.providerId == "ldap")]')

    local count
    count=$(echo "$providers" | jq 'length')

    if [ "$count" -eq 0 ]; then
        log_error "No LDAP federation providers found in realm '${realm}'."
        exit 1
    fi

    log_info "Found ${count} LDAP provider(s)."

    echo "$providers" | jq -r '.[].id' | while read -r provider_id; do
        local provider_name
        provider_name=$(echo "$providers" | jq -r --arg id "$provider_id" '.[] | select(.id == $id) | .name')

        if [ "$changed_only" = true ]; then
            log_info "Triggering changed-users sync for '${provider_name}'..."
            local result
            result=$(curl -sf -X POST \
                -H "Authorization: Bearer ${token}" \
                "${KEYCLOAK_URL}/admin/realms/${realm}/user-storage/${provider_id}/sync?action=triggerChangedUsersSync" \
                2>/dev/null)
        else
            log_info "Triggering full sync for '${provider_name}'..."
            local result
            result=$(curl -sf -X POST \
                -H "Authorization: Bearer ${token}" \
                "${KEYCLOAK_URL}/admin/realms/${realm}/user-storage/${provider_id}/sync?action=triggerFullSync" \
                2>/dev/null)
        fi

        if [ -n "$result" ]; then
            local added removed updated failed status
            added=$(echo "$result" | jq '.added // 0')
            removed=$(echo "$result" | jq '.removed // 0')
            updated=$(echo "$result" | jq '.updated // 0')
            failed=$(echo "$result" | jq '.failed // 0')
            status=$(echo "$result" | jq -r '.status // "unknown"')

            log_info "Sync result for '${provider_name}':"
            log_info "  Status:  ${status}"
            log_info "  Added:   ${added}"
            log_info "  Updated: ${updated}"
            log_info "  Removed: ${removed}"
            log_info "  Failed:  ${failed}"
        else
            log_error "Sync failed for '${provider_name}'. Check Keycloak logs."
        fi
    done
}

print_summary() {
    echo ""
    echo "============================================"
    echo "  User Sync Summary"
    echo "============================================"
    echo "  Created:  ${CREATED}"
    echo "  Updated:  ${UPDATED}"
    echo "  Skipped:  ${SKIPPED}"
    echo "  Errors:   ${ERRORS}"
    echo "============================================"
}

# --- Main ---

check_prerequisites

CSV_FILE=""
DRY_RUN=false
LDAP_SYNC=false
CHANGED_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv)
            CSV_FILE="$2"
            shift 2
            ;;
        --realm)
            KC_TARGET_REALM="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --ldap)
            LDAP_SYNC=true
            shift
            ;;
        --changed-only)
            CHANGED_ONLY=true
            shift
            ;;
        --help|-h)
            head -22 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$LDAP_SYNC" = true ]; then
    trigger_ldap_sync "$KC_TARGET_REALM" "$CHANGED_ONLY"
elif [ -n "$CSV_FILE" ]; then
    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY RUN mode — no changes will be made."
    fi
    sync_from_csv "$CSV_FILE" "$KC_TARGET_REALM" "$DRY_RUN"
    print_summary
else
    log_error "Specify --csv <file> or --ldap. Run with --help for usage."
    exit 1
fi
