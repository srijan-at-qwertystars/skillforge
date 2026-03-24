#!/usr/bin/env bash
# vault-helper.sh — Manage Ansible Vault encrypted files
#
# Simplifies common vault operations: encrypt, decrypt, edit, rekey, view,
# and encrypt_string. Supports vault-id for multi-environment setups.
#
# Usage:
#   vault-helper.sh <command> <file> [OPTIONS]
#
# Commands:
#   encrypt       Encrypt a plaintext file
#   decrypt       Decrypt a vault-encrypted file
#   edit          Edit an encrypted file in-place
#   view          View contents of an encrypted file
#   rekey         Change the vault password for a file
#   string        Encrypt a string for inline use
#   status        Check if a file is vault-encrypted
#   bulk-encrypt  Encrypt all matching files in a directory
#   bulk-decrypt  Decrypt all matching files in a directory
#
# Examples:
#   vault-helper.sh encrypt vars/secrets.yml
#   vault-helper.sh encrypt vars/prod.yml --vault-id prod@prompt
#   vault-helper.sh edit vars/secrets.yml
#   vault-helper.sh view vars/secrets.yml --vault-id prod@~/.vault_prod
#   vault-helper.sh rekey vars/secrets.yml --new-vault-id staging@prompt
#   vault-helper.sh string "MySecret123" --name db_password
#   vault-helper.sh status vars/secrets.yml
#   vault-helper.sh bulk-encrypt vars/ --vault-id prod@prompt --pattern "*.secret.yml"

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Defaults ---
COMMAND=""
TARGET=""
VAULT_ID=""
NEW_VAULT_ID=""
VAULT_PASSWORD_FILE=""
VAR_NAME=""
PATTERN="*.yml"
ASK_PASS=false

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [file|string] [OPTIONS]

Manage Ansible Vault encrypted files with vault-id support.

Commands:
  encrypt           Encrypt a plaintext file
  decrypt           Decrypt an encrypted file to plaintext
  edit              Edit an encrypted file (opens \$EDITOR)
  view              View contents of an encrypted file
  rekey             Change vault password on a file
  string            Encrypt a string value for inline use
  status            Check if a file is vault-encrypted
  bulk-encrypt      Encrypt matching files in a directory
  bulk-decrypt      Decrypt matching files in a directory

Options:
  --vault-id ID             Vault identity (e.g., prod@prompt, dev@~/.vault_dev)
  --new-vault-id ID         New vault identity for rekey operations
  --vault-password-file F   Path to vault password file
  --ask-vault-pass          Prompt for vault password
  --name, -n NAME           Variable name (for 'string' command)
  --pattern, -p PATTERN     File glob pattern (for bulk operations, default: *.yml)
  --help, -h                Show this help message

Examples:
  $(basename "$0") encrypt vars/secrets.yml --vault-id prod@prompt
  $(basename "$0") edit vars/secrets.yml --vault-password-file ~/.vault_pass
  $(basename "$0") view vars/secrets.yml --ask-vault-pass
  $(basename "$0") rekey vars/secrets.yml --vault-id prod@~/.vault_prod --new-vault-id prod@prompt
  $(basename "$0") string "SuperSecret" --name db_password --vault-id prod@prompt
  $(basename "$0") status vars/secrets.yml
  $(basename "$0") bulk-encrypt vars/ --vault-id prod@prompt --pattern "*.secret.yml"
EOF
    exit "${1:-0}"
}

# --- Parse arguments ---
[[ $# -eq 0 ]] && usage 1

COMMAND="$1"
shift

# Check if second arg is a file/string (not a flag)
if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
    TARGET="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-id)               VAULT_ID="$2"; shift 2 ;;
        --new-vault-id)           NEW_VAULT_ID="$2"; shift 2 ;;
        --vault-password-file)    VAULT_PASSWORD_FILE="$2"; shift 2 ;;
        --ask-vault-pass)         ASK_PASS=true; shift ;;
        --name|-n)                VAR_NAME="$2"; shift 2 ;;
        --pattern|-p)             PATTERN="$2"; shift 2 ;;
        --help|-h)                usage 0 ;;
        *) echo -e "${RED}Error: Unknown option: $1${NC}" >&2; usage 1 ;;
    esac
done

# --- Helper functions ---
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_ansible_vault() {
    if ! command -v ansible-vault &>/dev/null; then
        log_error "ansible-vault is not installed."
        echo "Install with: pip install ansible-core" >&2
        exit 1
    fi
}

is_vault_encrypted() {
    local file="$1"
    head -1 "$file" 2>/dev/null | grep -q '^\$ANSIBLE_VAULT;' 2>/dev/null
}

get_vault_id_from_file() {
    local file="$1"
    local header
    header=$(head -1 "$file" 2>/dev/null || true)
    if [[ "$header" =~ ^\$ANSIBLE_VAULT\;[0-9.]+\;AES256\;(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "(default)"
    fi
}

# Build vault args
build_vault_args() {
    local args=()
    if [[ -n "$VAULT_ID" ]]; then
        args+=(--vault-id "$VAULT_ID")
    elif [[ -n "$VAULT_PASSWORD_FILE" ]]; then
        args+=(--vault-password-file "$VAULT_PASSWORD_FILE")
    elif $ASK_PASS; then
        args+=(--ask-vault-pass)
    fi
    echo "${args[@]}"
}

require_target() {
    if [[ -z "$TARGET" ]]; then
        log_error "File path is required for '${COMMAND}' command."
        exit 1
    fi
}

require_target_exists() {
    require_target
    if [[ ! -f "$TARGET" ]]; then
        log_error "File not found: ${TARGET}"
        exit 1
    fi
}

# --- Commands ---
cmd_encrypt() {
    require_target_exists
    if is_vault_encrypted "$TARGET"; then
        log_warn "File is already encrypted: ${TARGET}"
        exit 0
    fi
    log_info "Encrypting: ${TARGET}"
    local vault_args
    vault_args=$(build_vault_args)
    # shellcheck disable=SC2086
    ansible-vault encrypt $vault_args "$TARGET"
    log_ok "Encrypted: ${TARGET}"
}

cmd_decrypt() {
    require_target_exists
    if ! is_vault_encrypted "$TARGET"; then
        log_warn "File is not vault-encrypted: ${TARGET}"
        exit 0
    fi
    log_info "Decrypting: ${TARGET}"
    local vault_args
    vault_args=$(build_vault_args)
    # shellcheck disable=SC2086
    ansible-vault decrypt $vault_args "$TARGET"
    log_ok "Decrypted: ${TARGET}"
}

cmd_edit() {
    require_target_exists
    if ! is_vault_encrypted "$TARGET"; then
        log_warn "File is not vault-encrypted, opening in editor..."
        "${EDITOR:-vi}" "$TARGET"
        return
    fi
    log_info "Editing encrypted file: ${TARGET}"
    local vault_args
    vault_args=$(build_vault_args)
    # shellcheck disable=SC2086
    ansible-vault edit $vault_args "$TARGET"
    log_ok "Edit complete: ${TARGET}"
}

cmd_view() {
    require_target_exists
    if ! is_vault_encrypted "$TARGET"; then
        log_warn "File is not vault-encrypted, displaying plaintext:"
        echo "---"
        cat "$TARGET"
        return
    fi
    log_info "Viewing encrypted file: ${TARGET}"
    local vault_id
    vault_id=$(get_vault_id_from_file "$TARGET")
    echo -e "${BLUE}Vault ID: ${vault_id}${NC}"
    echo "---"
    local vault_args
    vault_args=$(build_vault_args)
    # shellcheck disable=SC2086
    ansible-vault view $vault_args "$TARGET"
}

cmd_rekey() {
    require_target_exists
    if ! is_vault_encrypted "$TARGET"; then
        log_error "File is not vault-encrypted: ${TARGET}"
        exit 1
    fi
    log_info "Rekeying: ${TARGET}"
    local vault_args
    vault_args=$(build_vault_args)
    local new_args=()
    if [[ -n "$NEW_VAULT_ID" ]]; then
        new_args+=(--new-vault-id "$NEW_VAULT_ID")
    fi
    # shellcheck disable=SC2086
    ansible-vault rekey $vault_args "${new_args[@]}" "$TARGET"
    log_ok "Rekeyed: ${TARGET}"
}

cmd_string() {
    if [[ -z "$TARGET" ]]; then
        log_info "Enter the string to encrypt (Ctrl-D to finish):"
        TARGET=$(cat)
    fi
    local vault_args
    vault_args=$(build_vault_args)
    local name_args=()
    if [[ -n "$VAR_NAME" ]]; then
        name_args+=(--name "$VAR_NAME")
    fi
    # shellcheck disable=SC2086
    ansible-vault encrypt_string $vault_args "${name_args[@]}" "$TARGET"
}

cmd_status() {
    require_target_exists
    if is_vault_encrypted "$TARGET"; then
        local vault_id
        vault_id=$(get_vault_id_from_file "$TARGET")
        log_ok "Encrypted (vault-id: ${vault_id}): ${TARGET}"
    else
        log_info "Not encrypted: ${TARGET}"
    fi
}

cmd_bulk_encrypt() {
    require_target
    if [[ ! -d "$TARGET" ]]; then
        log_error "Directory not found: ${TARGET}"
        exit 1
    fi
    log_info "Bulk encrypting files matching '${PATTERN}' in ${TARGET}"
    local count=0
    local vault_args
    vault_args=$(build_vault_args)
    while IFS= read -r file; do
        if ! is_vault_encrypted "$file"; then
            log_info "Encrypting: ${file}"
            # shellcheck disable=SC2086
            ansible-vault encrypt $vault_args "$file"
            count=$((count + 1))
        else
            log_warn "Already encrypted, skipping: ${file}"
        fi
    done < <(find "$TARGET" -name "$PATTERN" -type f 2>/dev/null)
    log_ok "Encrypted ${count} files"
}

cmd_bulk_decrypt() {
    require_target
    if [[ ! -d "$TARGET" ]]; then
        log_error "Directory not found: ${TARGET}"
        exit 1
    fi
    log_info "Bulk decrypting files matching '${PATTERN}' in ${TARGET}"
    local count=0
    local vault_args
    vault_args=$(build_vault_args)
    while IFS= read -r file; do
        if is_vault_encrypted "$file"; then
            log_info "Decrypting: ${file}"
            # shellcheck disable=SC2086
            ansible-vault decrypt $vault_args "$file"
            count=$((count + 1))
        else
            log_warn "Not encrypted, skipping: ${file}"
        fi
    done < <(find "$TARGET" -name "$PATTERN" -type f 2>/dev/null)
    log_ok "Decrypted ${count} files"
}

# --- Main ---
check_ansible_vault

case "$COMMAND" in
    encrypt)       cmd_encrypt ;;
    decrypt)       cmd_decrypt ;;
    edit)          cmd_edit ;;
    view)          cmd_view ;;
    rekey)         cmd_rekey ;;
    string)        cmd_string ;;
    status)        cmd_status ;;
    bulk-encrypt)  cmd_bulk_encrypt ;;
    bulk-decrypt)  cmd_bulk_decrypt ;;
    help|--help|-h) usage 0 ;;
    *)
        log_error "Unknown command: ${COMMAND}"
        usage 1
        ;;
esac
