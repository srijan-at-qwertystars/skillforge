#!/usr/bin/env bash
#
# generate-changelog.sh — Generate a changelog from conventional commits using git log
#
# Usage:
#   ./generate-changelog.sh                       # Full changelog from all tags
#   ./generate-changelog.sh --from v1.0.0         # Changelog since a specific tag
#   ./generate-changelog.sh --from v1.0.0 --to v2.0.0  # Between two tags
#   ./generate-changelog.sh --unreleased          # Only unreleased changes (since last tag)
#   ./generate-changelog.sh --output CHANGELOG.md # Write to file (default: stdout)
#   ./generate-changelog.sh --prepend CHANGELOG.md # Prepend to existing file
#   ./generate-changelog.sh --repo-url https://github.com/owner/repo  # Add commit links
#
# What it does:
#   - Parses conventional commits from git history
#   - Groups commits by type (Features, Bug Fixes, etc.)
#   - Generates Markdown changelog with sections per version tag
#   - Supports commit links, issue references, and breaking change callouts
#
# Requirements:
#   - Git repository with conventional commits
#   - Tags following vX.Y.Z or X.Y.Z format

set -euo pipefail

# --- Defaults ---
FROM=""
TO="HEAD"
UNRELEASED=false
OUTPUT=""
PREPEND=""
REPO_URL=""

# --- Type → Section mapping ---
declare -A TYPE_SECTIONS=(
  [feat]="🚀 Features"
  [fix]="🐛 Bug Fixes"
  [perf]="⚡ Performance"
  [security]="🔒 Security"
  [revert]="⏪ Reverts"
  [docs]="📚 Documentation"
  [refactor]="♻️ Refactoring"
  [deps]="📦 Dependencies"
)

# Hidden types (not shown in changelog unless --all)
HIDDEN_TYPES="style|test|build|ci|chore|dx|infra|i18n|a11y|data|wip|hotfix"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)       FROM="$2"; shift 2 ;;
    --to)         TO="$2"; shift 2 ;;
    --unreleased) UNRELEASED=true; shift ;;
    --output)     OUTPUT="$2"; shift 2 ;;
    --prepend)    PREPEND="$2"; shift 2 ;;
    --repo-url)   REPO_URL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Ensure we're in a git repo ---
git rev-parse --git-dir &>/dev/null || { echo "Error: not a git repository" >&2; exit 1; }

# --- Auto-detect repo URL from git remote ---
if [[ -z "$REPO_URL" ]]; then
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ -n "$REMOTE_URL" ]]; then
    # Convert SSH to HTTPS
    REPO_URL=$(echo "$REMOTE_URL" | sed -E 's|git@([^:]+):|https://\1/|; s|\.git$||')
  fi
fi

# --- Helper: format a commit line ---
format_commit() {
  local sha="$1"
  local scope="$2"
  local subject="$3"
  local short_sha="${sha:0:7}"

  local line="- "
  if [[ -n "$scope" ]]; then
    line+="**${scope}:** "
  fi
  line+="${subject}"

  if [[ -n "$REPO_URL" ]]; then
    line+=" ([${short_sha}](${REPO_URL}/commit/${sha}))"
  else
    line+=" (${short_sha})"
  fi

  echo "$line"
}

# --- Helper: generate changelog for a range ---
generate_section() {
  local range="$1"
  local version_title="$2"
  local date="$3"

  # Get commits in range
  local commits
  commits=$(git log "$range" --pretty=format:"%H|%s" --no-merges 2>/dev/null) || return

  [[ -z "$commits" ]] && return

  # Collect breaking changes
  local breaking_changes=()
  local has_content=false

  # Parse commits by type
  declare -A SECTION_COMMITS

  while IFS='|' read -r sha subject; do
    # Skip merge commits and non-conventional
    if ! echo "$subject" | grep -qE '^(revert: )?[a-z]+(\([^)]*\))?(!)?: '; then
      continue
    fi

    # Extract type, scope, bang, description
    local type scope bang desc
    if echo "$subject" | grep -qE '^revert: '; then
      type="revert"
      desc=$(echo "$subject" | sed -E 's/^revert: //')
      scope=""
      bang=""
    else
      type=$(echo "$subject" | sed -E 's/^([a-z]+)(\([^)]*\))?(!)?: .*/\1/')
      scope=$(echo "$subject" | sed -E 's/^[a-z]+(\(([^)]*)\))?(!)?: .*/\2/')
      bang=$(echo "$subject" | sed -E 's/^[a-z]+(\([^)]*\))?(!)?: .*/\2/')
      desc=$(echo "$subject" | sed -E 's/^[a-z]+(\([^)]*\))?(!)?: //')
    fi

    # Check for breaking change (bang or BREAKING CHANGE in body)
    if [[ "$bang" == "!" ]]; then
      breaking_changes+=("$(format_commit "$sha" "$scope" "$desc")")
    else
      # Check commit body for BREAKING CHANGE footer
      local body
      body=$(git log -1 --pretty=format:"%b" "$sha" 2>/dev/null)
      if echo "$body" | grep -q "^BREAKING CHANGE:"; then
        local bc_desc
        bc_desc=$(echo "$body" | grep "^BREAKING CHANGE:" | sed 's/^BREAKING CHANGE: //')
        breaking_changes+=("- ${bc_desc} (${sha:0:7})")
      fi
    fi

    # Skip hidden types
    if echo "$type" | grep -qE "^(${HIDDEN_TYPES})$"; then
      continue
    fi

    # Get section name
    local section="${TYPE_SECTIONS[$type]:-Other}"
    local commit_line
    commit_line=$(format_commit "$sha" "$scope" "$desc")
    SECTION_COMMITS["$section"]+="${commit_line}"$'\n'
    has_content=true

  done <<< "$commits"

  # Don't output anything if no visible commits
  if [[ "$has_content" == false ]] && [[ ${#breaking_changes[@]} -eq 0 ]]; then
    return
  fi

  # Output version header
  if [[ -n "$date" ]]; then
    echo "## ${version_title} (${date})"
  else
    echo "## ${version_title}"
  fi
  echo ""

  # Output breaking changes first
  if [[ ${#breaking_changes[@]} -gt 0 ]]; then
    echo "### ⚠️ Breaking Changes"
    echo ""
    for bc in "${breaking_changes[@]}"; do
      echo "$bc"
    done
    echo ""
  fi

  # Output sections in order
  local ordered_sections=("🚀 Features" "🐛 Bug Fixes" "⚡ Performance" "🔒 Security" "⏪ Reverts" "📚 Documentation" "♻️ Refactoring" "📦 Dependencies")
  for section in "${ordered_sections[@]}"; do
    if [[ -n "${SECTION_COMMITS[$section]:-}" ]]; then
      echo "### ${section}"
      echo ""
      echo -n "${SECTION_COMMITS[$section]}"
      echo ""
    fi
  done
}

# --- Main logic ---
changelog=""

if [[ "$UNRELEASED" == true ]]; then
  # Get last tag
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
  if [[ -n "$LAST_TAG" ]]; then
    section=$(generate_section "${LAST_TAG}..HEAD" "Unreleased" "")
  else
    section=$(generate_section "HEAD" "Unreleased" "")
  fi
  changelog="$section"

elif [[ -n "$FROM" ]]; then
  # Specific range
  DATE=$(git log -1 --pretty=format:"%Y-%m-%d" "$TO" 2>/dev/null || date +%Y-%m-%d)
  section=$(generate_section "${FROM}..${TO}" "${TO}" "${DATE}")
  changelog="$section"

else
  # Full changelog: iterate all tags
  HEADER="# Changelog

All notable changes to this project will be documented in this file.

This changelog is automatically generated from [Conventional Commits](https://www.conventionalcommits.org/).

"
  changelog="$HEADER"

  # Get all tags sorted by version
  TAGS=$(git tag -l --sort=-version:refname 'v*' 2>/dev/null)
  if [[ -z "$TAGS" ]]; then
    TAGS=$(git tag -l --sort=-version:refname '[0-9]*' 2>/dev/null)
  fi

  # Unreleased section
  LATEST_TAG=$(echo "$TAGS" | head -1)
  if [[ -n "$LATEST_TAG" ]]; then
    section=$(generate_section "${LATEST_TAG}..HEAD" "Unreleased" "")
    if [[ -n "$section" ]]; then
      changelog+="$section"$'\n'
    fi
  fi

  # Tag-to-tag sections
  PREV_TAG=""
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    TAG_DATE=$(git log -1 --pretty=format:"%Y-%m-%d" "$tag" 2>/dev/null)

    if [[ -z "$PREV_TAG" ]]; then
      PREV_TAG="$tag"
      continue
    fi

    section=$(generate_section "${tag}..${PREV_TAG}" "${PREV_TAG}" "$(git log -1 --pretty=format:"%Y-%m-%d" "$PREV_TAG" 2>/dev/null)")
    if [[ -n "$section" ]]; then
      changelog+="$section"$'\n'
    fi
    PREV_TAG="$tag"
  done <<< "$TAGS"

  # First tag (from beginning of history)
  if [[ -n "$PREV_TAG" ]]; then
    section=$(generate_section "$PREV_TAG" "${PREV_TAG}" "$(git log -1 --pretty=format:"%Y-%m-%d" "$PREV_TAG" 2>/dev/null)")
    if [[ -n "$section" ]]; then
      changelog+="$section"$'\n'
    fi
  fi
fi

# --- Output ---
if [[ -n "$PREPEND" ]]; then
  if [[ -f "$PREPEND" ]]; then
    EXISTING=$(cat "$PREPEND")
    # Remove existing header if present
    EXISTING=$(echo "$EXISTING" | sed '/^# Changelog/,/^$/d')
    echo "${changelog}${EXISTING}" > "$PREPEND"
    echo "Prepended changelog to $PREPEND" >&2
  else
    echo "$changelog" > "$PREPEND"
    echo "Created $PREPEND" >&2
  fi
elif [[ -n "$OUTPUT" ]]; then
  echo "$changelog" > "$OUTPUT"
  echo "Wrote changelog to $OUTPUT" >&2
else
  echo "$changelog"
fi
