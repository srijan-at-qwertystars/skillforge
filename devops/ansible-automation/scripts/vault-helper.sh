#!/usr/bin/env bash
# vault-helper.sh — Wrapper for Ansible Vault with improved UX.
#
# Usage: ./vault-helper.sh <action> [options]
#
# Actions:
#   encrypt <file>           Encrypt a file
#   decrypt <file>           Decrypt a file
#   view <file>              View encrypted file contents
#   edit <file>              Edit encrypted file in-place
#   rekey <file>             Change encryption password
#   encrypt-string <string>  Encrypt a string for inline use
#   find                     Find all vault-encrypted files in current tree
#   check <file>             Check if a file is vault-encrypted
#
# Options:
#   --vault-id <id>          Vault identity (e.g., prod, dev)
#   --password-file <file>   Path to vault password file
#   --name <var-name>        Variable name (for encrypt-string)
#
# Examples:
#   ./vault-helper.sh encrypt secrets.yml --vault-id prod
#   ./vault-helper.sh encrypt-string 'my_secret' --name db_password --vault-id prod
#   ./vault-helper.sh rekey vault/prod.yml --vault-id prod
#   ./vault-helper.sh find
#   ./vault-helper.sh view vault/prod.yml

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat << 'EOF'
Ansible Vault Helper — Better UX for vault operations

Usage: vault-helper.sh <action> [options]

Actions:
  encrypt <file>           Encrypt a plaintext file
  decrypt <file>           Decrypt a vault file to plaintext
  view <file>              View contents of encrypted file
  edit <file>              Edit encrypted file in-place
  rekey <file>             Change vault password for a file
  encrypt-string <string>  Encrypt a string for inline use in YAML
  find                     Find all vault-encrypted files in current tree
  check <file>             Check if a file is vault-encrypted

Options:
  --vault-id <id>          Vault identity (e.g., prod, dev, shared)
  --password-file <file>   Path to vault password file
  --name <var-name>        Variable name (for encrypt-string)
  -h, --help               Show this help message

Examples:
  vault-helper.sh encrypt group_vars/prod/vault.yml --vault-id prod
  vault-helper.sh encrypt-string 'SuperSecret' --name db_password --vault-id prod
  vault-helper.sh rekey vault/secrets.yml --vault-id prod
  vault-helper.sh find
  vault-helper.sh view vault/prod.yml --password-file ~/.vault_prod
EOF
    exit 0
}

info()    { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# Check ansible-vault is available
command -v ansible-vault >/dev/null 2>&1 || error "ansible-vault not found. Install Ansible first."

# Parse arguments
ACTION=""
FILE=""
VAULT_ID=""
PASSWORD_FILE=""
VAR_NAME=""
STRING_VALUE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        encrypt|decrypt|view|edit|rekey|find|check)
            ACTION="$1"
            shift
            ;;
        encrypt-string)
            ACTION="encrypt-string"
            if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                STRING_VALUE="$2"
                shift
            fi
            shift
            ;;
        --vault-id)
            VAULT_ID="$2"
            shift 2
            ;;
        --password-file)
            PASSWORD_FILE="$2"
            shift 2
            ;;
        --name)
            VAR_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$FILE" && "$ACTION" != "encrypt-string" && "$ACTION" != "find" ]]; then
                FILE="$1"
            fi
            shift
            ;;
    esac
done

[[ -z "$ACTION" ]] && usage

# Build vault arguments
build_vault_args() {
    local args=()
    if [[ -n "$VAULT_ID" && -n "$PASSWORD_FILE" ]]; then
        args+=(--vault-id "${VAULT_ID}@${PASSWORD_FILE}")
    elif [[ -n "$VAULT_ID" ]]; then
        args+=(--vault-id "${VAULT_ID}@prompt")
    elif [[ -n "$PASSWORD_FILE" ]]; then
        args+=(--vault-password-file "$PASSWORD_FILE")
    else
        args+=(--ask-vault-pass)
    fi
    echo "${args[@]}"
}

is_vault_encrypted() {
    local f="$1"
    head -1 "$f" 2>/dev/null | grep -q '^\$ANSIBLE_VAULT'
}

case "$ACTION" in
    encrypt)
        [[ -z "$FILE" ]] && error "File path required. Usage: vault-helper.sh encrypt <file>"
        [[ ! -f "$FILE" ]] && error "File not found: $FILE"
        if is_vault_encrypted "$FILE"; then
            warn "File is already encrypted: $FILE"
            exit 0
        fi
        info "Encrypting: $FILE"
        # shellcheck disable=SC2046
        ansible-vault encrypt $(build_vault_args) "$FILE"
        success "Encrypted: $FILE"
        ;;

    decrypt)
        [[ -z "$FILE" ]] && error "File path required. Usage: vault-helper.sh decrypt <file>"
        [[ ! -f "$FILE" ]] && error "File not found: $FILE"
        if ! is_vault_encrypted "$FILE"; then
            warn "File is not vault-encrypted: $FILE"
            exit 0
        fi
        warn "This will write plaintext to disk. Continue? (y/N)"
        read -r confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { info "Aborted."; exit 0; }
        info "Decrypting: $FILE"
        # shellcheck disable=SC2046
        ansible-vault decrypt $(build_vault_args) "$FILE"
        success "Decrypted: $FILE"
        warn "Remember to re-encrypt before committing!"
        ;;

    view)
        [[ -z "$FILE" ]] && error "File path required. Usage: vault-helper.sh view <file>"
        [[ ! -f "$FILE" ]] && error "File not found: $FILE"
        if ! is_vault_encrypted "$FILE"; then
            warn "File is not vault-encrypted. Showing plaintext:"
            cat "$FILE"
            exit 0
        fi
        # shellcheck disable=SC2046
        ansible-vault view $(build_vault_args) "$FILE"
        ;;

    edit)
        [[ -z "$FILE" ]] && error "File path required. Usage: vault-helper.sh edit <file>"
        [[ ! -f "$FILE" ]] && error "File not found: $FILE"
        # shellcheck disable=SC2046
        ansible-vault edit $(build_vault_args) "$FILE"
        success "Saved: $FILE"
        ;;

    rekey)
        [[ -z "$FILE" ]] && error "File path required. Usage: vault-helper.sh rekey <file>"
        [[ ! -f "$FILE" ]] && error "File not found: $FILE"
        if ! is_vault_encrypted "$FILE"; then
            error "File is not vault-encrypted: $FILE"
        fi
        info "Rekeying: $FILE"
        info "You will be prompted for the OLD password, then the NEW password."
        # shellcheck disable=SC2046
        ansible-vault rekey $(build_vault_args) "$FILE"
        success "Rekeyed: $FILE"
        ;;

    encrypt-string)
        if [[ -z "$STRING_VALUE" ]]; then
            info "Enter the string to encrypt (input hidden):"
            read -rs STRING_VALUE
            echo ""
        fi
        [[ -z "$STRING_VALUE" ]] && error "Empty string provided."
        local_args=$(build_vault_args)
        if [[ -n "$VAR_NAME" ]]; then
            info "Encrypting string as variable '$VAR_NAME':"
            # shellcheck disable=SC2086
            ansible-vault encrypt_string $local_args "$STRING_VALUE" --name "$VAR_NAME"
        else
            info "Encrypting string (no variable name):"
            # shellcheck disable=SC2086
            ansible-vault encrypt_string $local_args "$STRING_VALUE"
        fi
        echo ""
        info "Paste the output into your YAML file."
        ;;

    find)
        info "Searching for vault-encrypted files..."
        count=0
        while IFS= read -r -d '' f; do
            if is_vault_encrypted "$f"; then
                vault_id=$(head -1 "$f" | awk -F';' '{if(NF>=4) print $4; else print "default"}')
                echo -e "  ${GREEN}🔒${NC} $f ${YELLOW}(vault-id: $vault_id)${NC}"
                ((count++)) || true
            fi
        done < <(find . -name '*.yml' -o -name '*.yaml' -o -name '*.json' | tr '\n' '\0')
        echo ""
        if [[ $count -eq 0 ]]; then
            info "No vault-encrypted files found."
        else
            success "Found $count vault-encrypted file(s)."
        fi
        ;;

    check)
        [[ -z "$FILE" ]] && error "File path required. Usage: vault-helper.sh check <file>"
        [[ ! -f "$FILE" ]] && error "File not found: $FILE"
        if is_vault_encrypted "$FILE"; then
            vault_id=$(head -1 "$FILE" | awk -F';' '{if(NF>=4) print $4; else print "default"}')
            success "$FILE is vault-encrypted (vault-id: $vault_id)"
        else
            info "$FILE is NOT vault-encrypted (plaintext)"
        fi
        ;;

    *)
        error "Unknown action: $ACTION"
        ;;
esac
