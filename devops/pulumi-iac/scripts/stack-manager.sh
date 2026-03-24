#!/usr/bin/env bash
# stack-manager.sh — Manage Pulumi stacks: create, list, select, destroy, export/import state.
#
# Usage:
#   ./stack-manager.sh <command> [options]
#
# Commands:
#   list                              List all stacks
#   create  <name>                    Create a new stack
#   select  <name>                    Select an existing stack
#   destroy <name> [--yes]            Destroy a stack's resources
#   remove  <name> [--force]          Remove a stack entirely
#   export  <name> [--file out.json]  Export stack state
#   import  <name> --file in.json     Import stack state
#   clone   <src> <dest>              Clone config from one stack to another
#   diff    <stack1> <stack2>         Diff config between two stacks
#
# Examples:
#   ./stack-manager.sh list
#   ./stack-manager.sh create staging
#   ./stack-manager.sh export prod --file prod-state.json
#   ./stack-manager.sh clone dev staging

set -euo pipefail

# ---------- colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# ---------- preflight ----------
command -v pulumi >/dev/null 2>&1 || die "pulumi CLI not found."
command -v jq >/dev/null 2>&1     || warn "jq not found — some features will be limited."

# ---------- usage ----------
usage() {
    sed -n '2,/^$/s/^# \?//p' "$0"
    exit 0
}

[[ $# -lt 1 ]] && usage

COMMAND="$1"; shift

# ---------- commands ----------

cmd_list() {
    info "Listing stacks..."
    pulumi stack ls --all
}

cmd_create() {
    local name="${1:?Stack name required}"
    info "Creating stack '${name}'..."
    pulumi stack init "$name"
    info "Stack '${name}' created. Set config with: pulumi config set <key> <value>"
}

cmd_select() {
    local name="${1:?Stack name required}"
    info "Selecting stack '${name}'..."
    pulumi stack select "$name"
    info "Active stack: ${name}"
}

cmd_destroy() {
    local name="${1:?Stack name required}"
    shift
    local yes_flag=""
    [[ "${1:-}" == "--yes" ]] && yes_flag="--yes"

    info "Destroying resources in stack '${name}'..."
    pulumi stack select "$name"
    pulumi destroy $yes_flag

    info "Stack '${name}' resources destroyed."
}

cmd_remove() {
    local name="${1:?Stack name required}"
    shift
    local force_flag=""
    [[ "${1:-}" == "--force" ]] && force_flag="--force"

    warn "Removing stack '${name}' entirely (this does not destroy cloud resources)."
    pulumi stack rm "$name" $force_flag

    info "Stack '${name}' removed."
}

cmd_export() {
    local name="${1:?Stack name required}"
    shift
    local file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file) file="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    local outfile="${file:-${name}-state-$(date +%Y%m%d-%H%M%S).json}"
    info "Exporting state for stack '${name}' to '${outfile}'..."
    pulumi stack export --stack "$name" > "$outfile"

    local resource_count
    if command -v jq >/dev/null 2>&1; then
        resource_count=$(jq '.deployment.resources | length' "$outfile")
        info "Exported ${resource_count} resources to ${outfile}"
    else
        info "State exported to ${outfile}"
    fi
}

cmd_import() {
    local name="${1:?Stack name required}"
    shift
    local file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file) file="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -z "$file" ]] && die "--file is required for import"
    [[ -f "$file" ]] || die "File not found: $file"

    warn "Importing state into stack '${name}' from '${file}'..."
    warn "This will OVERWRITE the current state. Back up first with: $0 export ${name}"

    pulumi stack select "$name"
    pulumi stack import < "$file"

    info "State imported into '${name}'."
}

cmd_clone() {
    local src="${1:?Source stack required}"
    local dest="${2:?Destination stack required}"

    info "Cloning config from '${src}' to '${dest}'..."

    # Create dest if it doesn't exist
    if ! pulumi stack ls 2>/dev/null | grep -qw "$dest"; then
        info "Creating stack '${dest}'..."
        pulumi stack init "$dest"
    fi

    # Copy config values (not secrets — they need re-encryption)
    pulumi stack select "$src"
    local config_keys
    config_keys=$(pulumi config --json 2>/dev/null | jq -r 'to_entries[] | select(.value.secret != true) | .key' || true)

    pulumi stack select "$dest"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local value
        pulumi stack select "$src"
        value=$(pulumi config get "$key" 2>/dev/null || true)
        pulumi stack select "$dest"
        if [[ -n "$value" ]]; then
            pulumi config set "$key" "$value"
            info "  Copied: $key"
        fi
    done <<< "$config_keys"

    warn "Secret values were NOT copied — set them manually with: pulumi config set --secret <key> <value>"
    info "Config cloned from '${src}' to '${dest}'."
}

cmd_diff() {
    local stack1="${1:?First stack required}"
    local stack2="${2:?Second stack required}"

    if ! command -v jq >/dev/null 2>&1; then
        die "jq is required for config diff"
    fi

    info "Comparing config: ${stack1} vs ${stack2}"
    echo ""

    local config1 config2
    config1=$(pulumi config --stack "$stack1" --json 2>/dev/null || echo "{}")
    config2=$(pulumi config --stack "$stack2" --json 2>/dev/null || echo "{}")

    local all_keys
    all_keys=$(echo "$config1 $config2" | jq -rs '[.[] | keys] | add | unique | .[]')

    printf "${CYAN}%-40s %-30s %-30s${NC}\n" "KEY" "$stack1" "$stack2"
    printf "%-40s %-30s %-30s\n" "$(printf '%0.s-' {1..40})" "$(printf '%0.s-' {1..30})" "$(printf '%0.s-' {1..30})"

    while IFS= read -r key; do
        local v1 v2
        v1=$(echo "$config1" | jq -r --arg k "$key" '.[$k].value // "—"')
        v2=$(echo "$config2" | jq -r --arg k "$key" '.[$k].value // "—"')

        if [[ "$v1" == "$v2" ]]; then
            printf "%-40s %-30s %-30s\n" "$key" "$v1" "$v2"
        else
            printf "${YELLOW}%-40s %-30s %-30s${NC}\n" "$key" "$v1" "$v2"
        fi
    done <<< "$all_keys"
}

# ---------- dispatch ----------
case "$COMMAND" in
    list)    cmd_list "$@" ;;
    create)  cmd_create "$@" ;;
    select)  cmd_select "$@" ;;
    destroy) cmd_destroy "$@" ;;
    remove)  cmd_remove "$@" ;;
    export)  cmd_export "$@" ;;
    import)  cmd_import "$@" ;;
    clone)   cmd_clone "$@" ;;
    diff)    cmd_diff "$@" ;;
    -h|--help) usage ;;
    *)       die "Unknown command: $COMMAND. Run with --help for usage." ;;
esac
