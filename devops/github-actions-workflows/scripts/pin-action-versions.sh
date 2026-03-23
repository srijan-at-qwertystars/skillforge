#!/usr/bin/env bash
set -euo pipefail

##############################################################################
# pin-action-versions.sh
#
# Pins GitHub Action references to their full SHA commit digests.
#
# Usage:
#   ./pin-action-versions.sh [OPTIONS] [REPO_ROOT]
#
# Options:
#   --dry-run    Show what would be changed without modifying files
#   --help       Show this help message
#
# Arguments:
#   REPO_ROOT    Path to the repository root (default: current directory)
#
# Behavior:
#   - Scans .github/workflows/*.yml and *.yaml for 'uses: owner/repo@vX' refs
#   - If the 'gh' CLI is available and authenticated, resolves tags to SHAs
#     via the GitHub API and rewrites references in-place (unless --dry-run)
#   - If 'gh' is not available, prints a report of actions that need pinning
#   - Adds a comment with the original tag for readability:
#       uses: actions/checkout@<sha> # v4
#
# Exit codes:
#   0  Success (or dry-run completed)
#   1  Error occurred during processing
##############################################################################

DRY_RUN=false
REPO_ROOT="."

usage() {
    sed -n '/^##/,/^##/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            REPO_ROOT="$1"
            shift
            ;;
    esac
done

WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

HAS_GH=false
if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null 2>&1; then
        HAS_GH=true
    fi
fi

# Cache resolved SHAs to avoid redundant API calls
declare -A SHA_CACHE

resolve_tag_to_sha() {
    local owner_repo="$1"
    local tag="$2"
    local cache_key="${owner_repo}@${tag}"

    if [[ -n "${SHA_CACHE[$cache_key]:-}" ]]; then
        echo "${SHA_CACHE[$cache_key]}"
        return 0
    fi

    if $HAS_GH; then
        local sha
        # Try as a tag first, then as a branch
        sha=$(gh api "repos/${owner_repo}/git/ref/tags/${tag}" --jq '.object.sha' 2>/dev/null || true)

        # If it's an annotated tag, we need to dereference it
        if [[ -n "$sha" ]]; then
            local obj_type
            obj_type=$(gh api "repos/${owner_repo}/git/tags/${sha}" --jq '.object.type' 2>/dev/null || echo "commit")
            if [[ "$obj_type" == "commit" ]]; then
                local deref_sha
                deref_sha=$(gh api "repos/${owner_repo}/git/tags/${sha}" --jq '.object.sha' 2>/dev/null || echo "$sha")
                sha="$deref_sha"
            fi
        fi

        # Fallback: try as a branch ref
        if [[ -z "$sha" ]]; then
            sha=$(gh api "repos/${owner_repo}/git/ref/heads/${tag}" --jq '.object.sha' 2>/dev/null || true)
        fi

        # Fallback: try matching via git ls-remote
        if [[ -z "$sha" ]]; then
            sha=$(git ls-remote "https://github.com/${owner_repo}.git" "${tag}" 2>/dev/null | head -1 | awk '{print $1}' || true)
        fi

        if [[ -n "$sha" ]]; then
            SHA_CACHE[$cache_key]="$sha"
            echo "$sha"
            return 0
        fi
    fi

    return 1
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

echo -e "${BOLD}Scanning for unpinned action references...${RESET}"
echo ""

unpinned_count=0
pinned_count=0
error_count=0

for file in "${workflow_files[@]}"; do
    filename=$(basename "$file")
    file_has_unpinned=false

    while IFS= read -r line; do
        # Extract the action reference
        ref=$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//' | sed -E 's/[[:space:]]*#.*//' | tr -d "'\"")

        # Skip local (./) and Docker (docker://) references
        if [[ "$ref" == ./* ]] || [[ "$ref" == docker://* ]]; then
            continue
        fi

        # Extract owner/repo and tag
        owner_repo=$(echo "$ref" | sed -E 's/@.*//' | sed -E 's|/[^/]*$||; s|^([^/]+/[^/]+).*|\1|')
        # More robust: get everything before @
        action_path=$(echo "$ref" | sed -E 's/@.*//')
        owner_repo=$(echo "$action_path" | cut -d'/' -f1,2)
        tag=$(echo "$ref" | sed -E 's/.*@//')

        # Skip already SHA-pinned refs
        if echo "$tag" | grep -qE '^[0-9a-f]{40}$'; then
            continue
        fi

        # Check if there's already a tag comment
        existing_comment=$(echo "$line" | sed -n 's/.*#[[:space:]]*//p' || true)

        if ! $file_has_unpinned; then
            echo -e "${BOLD}── ${filename} ──${RESET}"
            file_has_unpinned=true
        fi

        unpinned_count=$((unpinned_count + 1))

        if $HAS_GH; then
            sha=$(resolve_tag_to_sha "$owner_repo" "$tag" || true)
            if [[ -n "$sha" ]]; then
                echo -e "  ${GREEN}📌${RESET} ${action_path}@${tag} → ${sha:0:12}..."

                if ! $DRY_RUN; then
                    # Build the replacement: uses: action_path@sha # tag
                    escaped_ref=$(printf '%s\n' "$ref" | sed 's/[[\.*^$()+?{|]/\\&/g')
                    new_ref="${action_path}@${sha} # ${tag}"
                    sed -i "s|${escaped_ref}|${new_ref}|g" "$file"
                fi

                pinned_count=$((pinned_count + 1))
            else
                echo -e "  ${RED}✖${RESET} ${action_path}@${tag} — could not resolve SHA"
                error_count=$((error_count + 1))
            fi
        else
            echo -e "  ${YELLOW}⚠${RESET} ${action_path}@${tag} — needs pinning"
        fi

    done < <(grep -E '^\s+(-\s+)?uses:' "$file" 2>/dev/null || true)

    if $file_has_unpinned; then
        echo ""
    fi
done

# --- Summary ---
echo -e "${BOLD}Summary${RESET}"
echo -e "  Unpinned references found: ${unpinned_count}"

if $HAS_GH; then
    if $DRY_RUN; then
        echo -e "  ${CYAN}Resolvable (dry-run)${RESET}:     ${pinned_count}"
    else
        echo -e "  ${GREEN}Pinned${RESET}:                   ${pinned_count}"
    fi
    echo -e "  ${RED}Errors${RESET}:                   ${error_count}"
else
    echo ""
    echo -e "${YELLOW}Note${RESET}: Install and authenticate the GitHub CLI (gh) to auto-resolve SHAs."
    echo "  brew install gh && gh auth login"
    echo "  Then re-run this script to pin references automatically."
fi

if $DRY_RUN; then
    echo ""
    echo -e "${CYAN}Dry-run mode${RESET}: no files were modified."
fi

exit 0
