#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# validate-workflows.sh
#
# Validates all GitHub Actions workflow files in a repository.
#
# Usage:
#   ./validate-workflows.sh [REPO_ROOT]
#
# Arguments:
#   REPO_ROOT  Path to the repository root (default: current directory)
#
# Checks performed:
#   - Valid YAML syntax (requires python3 or yq)
#   - Required top-level fields: 'on' and 'jobs'
#   - Action reference format: owner/repo@ref
#   - Warns about mutable tags (non-SHA-pinned action refs)
#   - Detects deprecated features: set-output, save-state commands
#
# Exit codes:
#   0  All workflows passed
#   1  One or more workflows failed validation
##############################################################################

REPO_ROOT="${1:-.}"
WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"

pass_count=0
warn_count=0
fail_count=0
total_count=0

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

log_pass() { echo -e "  ${GREEN}✔ PASS${RESET}: $1"; }
log_warn() { echo -e "  ${YELLOW}⚠ WARN${RESET}: $1"; }
log_fail() { echo -e "  ${RED}✖ FAIL${RESET}: $1"; }

check_yaml_syntax() {
    local file="$1"
    if command -v python3 &>/dev/null; then
        if ! python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$file" 2>/dev/null; then
            return 1
        fi
    elif command -v yq &>/dev/null; then
        if ! yq eval '.' "$file" &>/dev/null; then
            return 1
        fi
    else
        # Fallback: basic syntax checks
        if grep -Pn '^\t' "$file" &>/dev/null; then
            return 1
        fi
    fi
    return 0
}

check_required_fields() {
    local file="$1"
    local has_on=false
    local has_jobs=false

    # Check for top-level 'on' key (could be 'on:' or '"on":' or "'on':")
    if grep -qE "^(on|['\"]on['\"]):" "$file"; then
        has_on=true
    # Also check for 'true:' which is how YAML parses bare 'on' in some parsers
    elif grep -qE "^true:" "$file"; then
        has_on=true
    fi

    if grep -qE "^jobs:" "$file"; then
        has_jobs=true
    fi

    if ! $has_on; then
        log_fail "Missing required top-level key 'on' (trigger definition)"
        return 1
    fi
    if ! $has_jobs; then
        log_fail "Missing required top-level key 'jobs'"
        return 1
    fi
    return 0
}

check_action_references() {
    local file="$1"
    local status=0

    # Extract lines with 'uses:' that reference actions (not docker:// or ./)
    while IFS= read -r line; do
        # Strip leading whitespace and 'uses:'
        local ref
        ref=$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//' | tr -d "'\"")

        # Skip local actions (./) and Docker references (docker://)
        if [[ "$ref" == ./* ]] || [[ "$ref" == docker://* ]]; then
            continue
        fi

        # Validate format: owner/repo@ref or owner/repo/path@ref
        if ! echo "$ref" | grep -qE '^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_/.@-]+)?@[a-zA-Z0-9._-]+$'; then
            log_fail "Invalid action reference format: ${ref}"
            status=1
        fi
    done < <(grep -E '^\s+(-\s+)?uses:' "$file" 2>/dev/null || true)

    return $status
}

check_mutable_tags() {
    local file="$1"
    local found_mutable=false

    while IFS= read -r line; do
        local ref
        ref=$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//' | tr -d "'\"")

        # Skip local actions and Docker references
        if [[ "$ref" == ./* ]] || [[ "$ref" == docker://* ]]; then
            continue
        fi

        # Extract the @ref part
        local tag
        tag=$(echo "$ref" | sed -E 's/.*@//')

        # SHA refs are 40-char hex strings
        if ! echo "$tag" | grep -qE '^[0-9a-f]{40}$'; then
            log_warn "Mutable tag (not SHA-pinned): ${ref}"
            found_mutable=true
        fi
    done < <(grep -E '^\s+(-\s+)?uses:' "$file" 2>/dev/null || true)

    if $found_mutable; then
        return 1
    fi
    return 0
}

check_deprecated_features() {
    local file="$1"
    local found_deprecated=false
    local line_num

    # Check for deprecated set-output command
    while IFS=: read -r line_num content; do
        log_warn "Line ${line_num}: Deprecated 'set-output' command. Use \$GITHUB_OUTPUT instead."
        found_deprecated=true
    done < <(grep -n '::set-output' "$file" 2>/dev/null || true)

    # Check for deprecated save-state command
    while IFS=: read -r line_num content; do
        log_warn "Line ${line_num}: Deprecated 'save-state' command. Use \$GITHUB_STATE instead."
        found_deprecated=true
    done < <(grep -n '::save-state' "$file" 2>/dev/null || true)

    # Check for deprecated ::set-env
    while IFS=: read -r line_num content; do
        log_warn "Line ${line_num}: Deprecated 'set-env' command. Use \$GITHUB_ENV instead."
        found_deprecated=true
    done < <(grep -n '::set-env' "$file" 2>/dev/null || true)

    # Check for deprecated ::add-path
    while IFS=: read -r line_num content; do
        log_warn "Line ${line_num}: Deprecated 'add-path' command. Use \$GITHUB_PATH instead."
        found_deprecated=true
    done < <(grep -n '::add-path' "$file" 2>/dev/null || true)

    if $found_deprecated; then
        return 1
    fi
    return 0
}

# --- Main ---

if [[ ! -d "$WORKFLOW_DIR" ]]; then
    echo -e "${RED}Error${RESET}: No .github/workflows/ directory found in ${REPO_ROOT}"
    exit 1
fi

shopt -s nullglob
workflow_files=("${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml)
shopt -u nullglob

if [[ ${#workflow_files[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No workflow files found in ${WORKFLOW_DIR}${RESET}"
    exit 0
fi

echo -e "${BOLD}Validating GitHub Actions workflows in ${WORKFLOW_DIR}${RESET}"
echo ""

for file in "${workflow_files[@]}"; do
    total_count=$((total_count + 1))
    filename=$(basename "$file")
    file_failed=false
    file_warned=false

    echo -e "${BOLD}── ${filename} ──${RESET}"

    # 1. YAML syntax
    if ! check_yaml_syntax "$file"; then
        log_fail "Invalid YAML syntax"
        file_failed=true
    else
        log_pass "Valid YAML syntax"
    fi

    # 2. Required fields
    if ! check_required_fields "$file"; then
        file_failed=true
    else
        log_pass "Required fields present (on, jobs)"
    fi

    # 3. Action reference format
    if ! check_action_references "$file"; then
        file_failed=true
    else
        log_pass "Action reference format valid"
    fi

    # 4. Mutable tags
    if ! check_mutable_tags "$file"; then
        file_warned=true
    else
        log_pass "All action references are SHA-pinned"
    fi

    # 5. Deprecated features
    if ! check_deprecated_features "$file"; then
        file_warned=true
    fi

    # Tally results
    if $file_failed; then
        fail_count=$((fail_count + 1))
    elif $file_warned; then
        warn_count=$((warn_count + 1))
    else
        pass_count=$((pass_count + 1))
    fi

    echo ""
done

# --- Summary ---
echo -e "${BOLD}Summary${RESET}"
echo -e "  Total:  ${total_count}"
echo -e "  ${GREEN}Passed${RESET}: ${pass_count}"
echo -e "  ${YELLOW}Warned${RESET}: ${warn_count}"
echo -e "  ${RED}Failed${RESET}: ${fail_count}"

if [[ $fail_count -gt 0 ]]; then
    exit 1
fi
exit 0
