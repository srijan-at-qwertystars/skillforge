#!/usr/bin/env bash
# =============================================================================
# stack-ops.sh — Common Pulumi stack operations with safety checks
# =============================================================================
#
# Usage:
#   ./stack-ops.sh <command> [OPTIONS]
#
# Commands:
#   preview    Run a preview with diff output
#   up         Deploy changes (optionally refresh first)
#   destroy    Tear down all resources (with safety checks)
#   refresh    Reconcile state with actual cloud resources
#   import     Import an existing cloud resource into state
#   export     Export stack state to a timestamped JSON file
#   status     Show stack info, resource count, and pending operations
#   unlock     Cancel pending operations (with backup)
#
# Global Options:
#   --stack STACK       Target a specific stack (default: current)
#   --yes               Skip interactive confirmations
#   --parallel N        Number of parallel resource operations (default: Pulumi's default)
#   --target URN        Target a specific resource URN (repeatable)
#   --diff              Show detailed property-level diffs
#   --refresh           Auto-refresh before 'up' or 'preview'
#   -h, --help          Show this help message
#
# Examples:
#   ./stack-ops.sh preview --diff
#   ./stack-ops.sh up --stack production --refresh
#   ./stack-ops.sh destroy --stack dev --yes
#   ./stack-ops.sh import aws:s3/bucket:Bucket my-bucket my-bucket-id
#   ./stack-ops.sh export --stack staging
#   ./stack-ops.sh status
#   ./stack-ops.sh unlock --stack dev
#   ./stack-ops.sh refresh --expect-no-changes
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
step()    { echo -e "${CYAN}[STEP]${NC}    $*"; }
danger()  { echo -e "${RED}${BOLD}[DANGER]${NC}  $*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
COMMAND=""
STACK_FLAG=""
YES_FLAG=""
PARALLEL_FLAG=""
TARGET_FLAGS=()
DIFF_FLAG=""
REFRESH_FLAG=""
EXPECT_NO_CHANGES=""

# Import-specific args collected after parsing flags
IMPORT_ARGS=()

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    sed -n '2,/^# =====/p' "$0" | head -n -1 | sed 's/^# \?//'
    exit 0
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_pulumi() {
    if ! command -v pulumi &>/dev/null; then
        error "pulumi CLI is not installed."
        exit 1
    fi
}

# Get the effective stack name (for display and safety checks)
get_stack_name() {
    if [[ -n "$STACK_FLAG" ]]; then
        echo "${STACK_FLAG#--stack }"
    else
        pulumi stack --show-name 2>/dev/null || echo "unknown"
    fi
}

# Check for pending operations that would block a deployment
check_pending_operations() {
    local pending
    pending=$(pulumi stack export $STACK_FLAG 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ops = data.get('deployment', {}).get('pending_operations', [])
    print(len(ops))
except:
    print(0)
" 2>/dev/null || echo "0")

    if [[ "$pending" -gt 0 ]]; then
        warn "Stack has ${pending} pending operation(s)."
        warn "Run './stack-ops.sh unlock' to clear them, or '--yes' to proceed anyway."
        if [[ -z "$YES_FLAG" ]]; then
            read -rp "Continue anyway? [y/N] " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                info "Aborted."
                exit 0
            fi
        fi
    fi
}

# Confirm destructive action
confirm_action() {
    local message="$1"
    if [[ -n "$YES_FLAG" ]]; then
        return 0
    fi
    echo -e "${YELLOW}${message}${NC}"
    read -rp "Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        info "Aborted."
        exit 0
    fi
}

# Check if the target stack is a production stack
is_prod_stack() {
    local stack_name
    stack_name="$(get_stack_name)"
    # Match common production stack name patterns
    if [[ "$stack_name" =~ ^(prod|production|prd|live|main)$ ]] ||
       [[ "$stack_name" =~ (prod|production)$ ]]; then
        return 0
    fi
    return 1
}

# Build common Pulumi flags array
build_common_flags() {
    local flags=()
    [[ -n "$STACK_FLAG" ]]    && flags+=($STACK_FLAG)
    [[ -n "$PARALLEL_FLAG" ]] && flags+=($PARALLEL_FLAG)
    [[ -n "$DIFF_FLAG" ]]     && flags+=("--diff")
    for t in "${TARGET_FLAGS[@]}"; do
        flags+=("--target" "$t")
    done
    echo "${flags[@]:-}"
}

# Get resource count for the current stack
get_resource_count() {
    pulumi stack $STACK_FLAG 2>/dev/null | grep -c "URN:" 2>/dev/null || \
    pulumi stack export $STACK_FLAG 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    resources = data.get('deployment', {}).get('resources', [])
    print(len(resources))
except:
    print('unknown')
" 2>/dev/null || echo "unknown"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
# First positional arg is the command
if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"
shift

# Collect remaining args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack)
            STACK_FLAG="--stack $2"
            shift 2
            ;;
        --yes|-y)
            YES_FLAG="--yes"
            shift
            ;;
        --parallel)
            PARALLEL_FLAG="--parallel $2"
            shift 2
            ;;
        --target)
            TARGET_FLAGS+=("$2")
            shift 2
            ;;
        --diff)
            DIFF_FLAG="true"
            shift
            ;;
        --refresh)
            REFRESH_FLAG="true"
            shift
            ;;
        --expect-no-changes)
            EXPECT_NO_CHANGES="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            # Collect remaining positional args (for import command)
            IMPORT_ARGS+=("$1")
            shift
            ;;
    esac
done

check_pulumi

# ---------------------------------------------------------------------------
# Command: preview
# ---------------------------------------------------------------------------
cmd_preview() {
    step "Running preview..."

    local flags
    flags="$(build_common_flags)"

    if [[ -n "$REFRESH_FLAG" ]]; then
        info "Refreshing state before preview..."
        # shellcheck disable=SC2086
        pulumi refresh --yes $STACK_FLAG 2>&1 || warn "Refresh encountered issues."
    fi

    # Always show diff in preview for maximum visibility
    # shellcheck disable=SC2086
    pulumi preview --diff $flags 2>&1
    success "Preview complete."
}

# ---------------------------------------------------------------------------
# Command: up
# ---------------------------------------------------------------------------
cmd_up() {
    local stack_name
    stack_name="$(get_stack_name)"
    step "Deploying stack '${stack_name}'..."

    check_pending_operations

    local flags
    flags="$(build_common_flags)"

    # Optional refresh before deployment
    if [[ -n "$REFRESH_FLAG" ]]; then
        info "Refreshing state before deployment..."
        # shellcheck disable=SC2086
        pulumi refresh --yes $STACK_FLAG 2>&1 || warn "Refresh encountered issues."
    fi

    # Production stack safety
    if is_prod_stack; then
        warn "You are deploying to a PRODUCTION stack: ${stack_name}"
        confirm_action "Are you sure you want to deploy to production?"
    fi

    # Run deployment
    # shellcheck disable=SC2086
    pulumi up $flags $YES_FLAG 2>&1

    success "Deployment to '${stack_name}' complete."
}

# ---------------------------------------------------------------------------
# Command: destroy
# ---------------------------------------------------------------------------
cmd_destroy() {
    local stack_name
    stack_name="$(get_stack_name)"

    step "Preparing to destroy stack '${stack_name}'..."

    # Show resource count before destroying
    local count
    count="$(get_resource_count)"
    warn "Stack '${stack_name}' contains ${count} resource(s)."

    # Safety: single confirmation for non-prod
    confirm_action "This will DESTROY all resources in stack '${stack_name}'."

    # Safety: double confirmation for production stacks
    if is_prod_stack; then
        echo ""
        danger "██████████████████████████████████████████████████████████████"
        danger "  WARNING: You are about to DESTROY a PRODUCTION stack!"
        danger "  Stack: ${stack_name}"
        danger "  Resources: ${count}"
        danger "██████████████████████████████████████████████████████████████"
        echo ""
        echo -e "${RED}Type the full stack name '${stack_name}' to confirm:${NC}"
        read -rp "> " confirm_name
        if [[ "$confirm_name" != "$stack_name" ]]; then
            info "Stack name did not match. Aborted."
            exit 0
        fi
    fi

    local flags
    flags="$(build_common_flags)"

    # shellcheck disable=SC2086
    pulumi destroy $flags --yes 2>&1

    success "Stack '${stack_name}' destroyed."
}

# ---------------------------------------------------------------------------
# Command: refresh
# ---------------------------------------------------------------------------
cmd_refresh() {
    local stack_name
    stack_name="$(get_stack_name)"
    step "Refreshing stack '${stack_name}'..."

    local flags
    flags="$(build_common_flags)"

    if [[ -n "$EXPECT_NO_CHANGES" ]]; then
        info "Running refresh with --expect-no-changes (CI drift detection mode)..."
        # shellcheck disable=SC2086
        if ! pulumi refresh --yes --expect-no-changes $flags 2>&1; then
            error "Drift detected! State does not match actual cloud resources."
            exit 1
        fi
        success "No drift detected."
    else
        # shellcheck disable=SC2086
        pulumi refresh $flags $YES_FLAG 2>&1
        success "Refresh complete."
    fi
}

# ---------------------------------------------------------------------------
# Command: import
# ---------------------------------------------------------------------------
cmd_import() {
    # Expected positional args: <resource-type> <name> <id>
    if [[ ${#IMPORT_ARGS[@]} -lt 3 ]]; then
        error "Import requires: <resource-type> <resource-name> <resource-id>"
        echo ""
        echo "Usage:  ./stack-ops.sh import <type> <name> <id> [--stack STACK]"
        echo ""
        echo "Example:"
        echo "  ./stack-ops.sh import aws:s3/bucket:Bucket my-bucket my-bucket-id"
        echo "  ./stack-ops.sh import azure:storage:Account myacct /subscriptions/.../myacct"
        exit 1
    fi

    local resource_type="${IMPORT_ARGS[0]}"
    local resource_name="${IMPORT_ARGS[1]}"
    local resource_id="${IMPORT_ARGS[2]}"

    # Validate resource type format (provider:module/resource:Type or provider:module:Type)
    if ! [[ "$resource_type" =~ ^[a-z]+:[a-zA-Z/]+:[A-Za-z]+$ ]]; then
        error "Invalid resource type format: '${resource_type}'"
        echo "Expected format: provider:module/resource:Type (e.g., aws:s3/bucket:Bucket)"
        exit 1
    fi

    step "Importing resource..."
    info "Type: ${resource_type}"
    info "Name: ${resource_name}"
    info "ID:   ${resource_id}"

    # shellcheck disable=SC2086
    pulumi import "$resource_type" "$resource_name" "$resource_id" $STACK_FLAG $YES_FLAG 2>&1

    success "Resource imported successfully."
    info "Add the corresponding code to your Pulumi program, then run 'pulumi preview' to verify."
}

# ---------------------------------------------------------------------------
# Command: export
# ---------------------------------------------------------------------------
cmd_export() {
    local stack_name
    stack_name="$(get_stack_name)"
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local filename="pulumi-export-${stack_name}-${timestamp}.json"

    step "Exporting stack '${stack_name}' to ${filename}..."

    # shellcheck disable=SC2086
    pulumi stack export $STACK_FLAG > "$filename" 2>/dev/null

    if [[ -f "$filename" && -s "$filename" ]]; then
        local size
        size=$(du -h "$filename" | cut -f1)
        success "Exported to ${filename} (${size})"
    else
        error "Export failed or produced an empty file."
        rm -f "$filename"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Command: status
# ---------------------------------------------------------------------------
cmd_status() {
    local stack_name
    stack_name="$(get_stack_name)"
    step "Stack status for '${stack_name}':"
    echo ""

    # Basic stack info
    # shellcheck disable=SC2086
    pulumi stack $STACK_FLAG 2>/dev/null || true

    echo ""
    echo -e "${CYAN}── Summary ──────────────────────────────────────────────────${NC}"

    # Resource count and pending operations from exported state
    # shellcheck disable=SC2086
    pulumi stack export $STACK_FLAG 2>/dev/null | python3 -c "
import sys, json, datetime

try:
    data = json.load(sys.stdin)
    deployment = data.get('deployment', {})
    resources = deployment.get('resources', [])
    pending = deployment.get('pending_operations', [])

    print(f'  Resources:          {len(resources)}')
    print(f'  Pending operations: {len(pending)}')

    if pending:
        for op in pending:
            res = op.get('resource', {})
            print(f'    - {op.get(\"type\", \"unknown\")}: {res.get(\"urn\", \"unknown\")}')

    # Count by type
    type_counts = {}
    for r in resources:
        rtype = r.get('type', 'unknown')
        type_counts[rtype] = type_counts.get(rtype, 0) + 1

    if type_counts:
        print()
        print('  Resources by type:')
        for rtype, count in sorted(type_counts.items()):
            if rtype != 'pulumi:pulumi:Stack':
                print(f'    {count:4d}  {rtype}')
except Exception as e:
    print(f'  Could not parse stack state: {e}')
" 2>/dev/null || warn "Could not retrieve detailed status."

    echo ""

    # Last update timestamp
    info "Last update: $(pulumi stack history --show-secrets=false $STACK_FLAG 2>/dev/null | head -5 || echo 'unknown')"
}

# ---------------------------------------------------------------------------
# Command: unlock
# ---------------------------------------------------------------------------
cmd_unlock() {
    local stack_name
    stack_name="$(get_stack_name)"
    step "Unlocking stack '${stack_name}'..."

    # Back up current state before modifying
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    local backup_file="pulumi-backup-${stack_name}-${timestamp}.json"

    info "Creating state backup: ${backup_file}"
    # shellcheck disable=SC2086
    pulumi stack export $STACK_FLAG > "$backup_file" 2>/dev/null || true

    if [[ -f "$backup_file" && -s "$backup_file" ]]; then
        success "Backup saved to ${backup_file}"
    else
        warn "Could not create backup. Proceeding anyway..."
    fi

    confirm_action "This will cancel all pending operations on stack '${stack_name}'."

    # shellcheck disable=SC2086
    pulumi cancel $STACK_FLAG --yes 2>&1 || true

    # If cancel doesn't work, try manually clearing pending operations
    # shellcheck disable=SC2086
    pulumi stack export $STACK_FLAG 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
deployment = data.get('deployment', {})
pending = deployment.get('pending_operations', [])
if pending:
    deployment['pending_operations'] = []
    json.dump(data, sys.stdout, indent=2)
    sys.exit(0)
else:
    sys.exit(1)
" 2>/dev/null > "${backup_file}.clean" && {
        info "Clearing pending operations from state..."
        # shellcheck disable=SC2086
        pulumi stack import $STACK_FLAG --file "${backup_file}.clean" 2>/dev/null
        rm -f "${backup_file}.clean"
        success "Pending operations cleared."
    } || {
        rm -f "${backup_file}.clean"
        success "No pending operations to clear (or already cancelled)."
    }
}

# ---------------------------------------------------------------------------
# Dispatch command
# ---------------------------------------------------------------------------
case "$COMMAND" in
    preview)  cmd_preview  ;;
    up)       cmd_up       ;;
    destroy)  cmd_destroy  ;;
    refresh)  cmd_refresh  ;;
    import)   cmd_import   ;;
    export)   cmd_export   ;;
    status)   cmd_status   ;;
    unlock)   cmd_unlock   ;;
    -h|--help) usage       ;;
    *)
        error "Unknown command: '${COMMAND}'"
        echo "Run with --help for usage information."
        exit 1
        ;;
esac
