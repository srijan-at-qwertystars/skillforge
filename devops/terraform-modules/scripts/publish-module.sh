#!/usr/bin/env bash
#
# publish-module.sh — Tag and publish a Terraform module to a private registry.
#
# Usage:
#   ./publish-module.sh <version> [--dry-run]
#
# Arguments:
#   version    Semantic version to publish (e.g., 1.2.0 — without 'v' prefix)
#   --dry-run  Show what would be done without making changes
#
# Prerequisites:
#   - Clean git working tree (no uncommitted changes)
#   - On the main/master branch
#   - TERRAFORM_REGISTRY_TOKEN env var set (for private registry push)
#   - Git remote configured
#
# What it does:
#   1. Validates the version format (semver)
#   2. Checks for clean git tree and correct branch
#   3. Runs validation (fmt, validate, tflint)
#   4. Creates an annotated git tag (v<version>)
#   5. Pushes the tag to origin
#   6. Optionally publishes to a private Terraform registry via API
#
# Examples:
#   ./publish-module.sh 1.0.0
#   ./publish-module.sh 2.1.0 --dry-run
#   TERRAFORM_REGISTRY_TOKEN=xxx ./publish-module.sh 1.3.0
#
# Environment Variables:
#   TERRAFORM_REGISTRY_TOKEN  API token for private registry (optional)
#   TERRAFORM_REGISTRY_URL    Registry URL (default: app.terraform.io)
#   TERRAFORM_ORG             Organization name for private registry
#   MODULE_PROVIDER           Provider name (auto-detected from repo name)
#   MODULE_NAME               Module name (auto-detected from repo name)
#   GIT_REMOTE                Git remote to push to (default: origin)
#   MAIN_BRANCH               Main branch name (default: auto-detect main/master)
#
set -euo pipefail

# --- Configuration ---
VERSION="${1:-}"
DRY_RUN=false
GIT_REMOTE="${GIT_REMOTE:-origin}"
REGISTRY_URL="${TERRAFORM_REGISTRY_URL:-app.terraform.io}"
REGISTRY_TOKEN="${TERRAFORM_REGISTRY_TOKEN:-}"
ORG="${TERRAFORM_ORG:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }

# --- Parse Arguments ---
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [--dry-run]"
  echo "Example: $0 1.2.0"
  exit 1
fi

# --- Validate Version Format ---
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
  err "Invalid version format: '$VERSION'. Use semantic versioning (e.g., 1.2.0)."
  exit 1
fi

TAG="v${VERSION}"

info "Publishing module version ${TAG}"
if $DRY_RUN; then
  warn "DRY RUN — no changes will be made"
fi
echo ""

# --- Auto-detect module name and provider from repo name ---
REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
if [[ "$REPO_NAME" =~ ^terraform-([a-z]+)-(.+)$ ]]; then
  MODULE_PROVIDER="${MODULE_PROVIDER:-${BASH_REMATCH[1]}}"
  MODULE_NAME="${MODULE_NAME:-${BASH_REMATCH[2]}}"
  info "Detected module: ${MODULE_PROVIDER}/${MODULE_NAME}"
else
  MODULE_PROVIDER="${MODULE_PROVIDER:-unknown}"
  MODULE_NAME="${MODULE_NAME:-${REPO_NAME}}"
  warn "Could not auto-detect provider/name from repo name '${REPO_NAME}'"
fi

# --- Detect main branch ---
MAIN_BRANCH="${MAIN_BRANCH:-}"
if [[ -z "$MAIN_BRANCH" ]]; then
  if git rev-parse --verify main &>/dev/null; then
    MAIN_BRANCH="main"
  elif git rev-parse --verify master &>/dev/null; then
    MAIN_BRANCH="master"
  else
    err "Cannot detect main branch. Set MAIN_BRANCH env var."
    exit 1
  fi
fi

# --- Pre-flight Checks ---
echo "--- Pre-flight Checks ---"

# Check clean working tree
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  err "Working tree is not clean. Commit or stash changes first."
  git status --short
  exit 1
fi
ok "Working tree is clean"

# Check branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "$MAIN_BRANCH" ]]; then
  err "Not on ${MAIN_BRANCH} branch (currently on ${CURRENT_BRANCH})."
  echo "   Switch with: git checkout ${MAIN_BRANCH}"
  exit 1
fi
ok "On ${MAIN_BRANCH} branch"

# Check tag doesn't exist
if git rev-parse "$TAG" &>/dev/null; then
  err "Tag ${TAG} already exists."
  exit 1
fi
ok "Tag ${TAG} is available"

# Check remote is up to date
git fetch "$GIT_REMOTE" --tags --quiet
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse "${GIT_REMOTE}/${MAIN_BRANCH}" 2>/dev/null || echo "unknown")
if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
  warn "Local HEAD differs from ${GIT_REMOTE}/${MAIN_BRANCH}. Consider pulling first."
fi

echo ""

# --- Validation ---
echo "--- Module Validation ---"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -x "${SCRIPT_DIR}/validate-module.sh" ]]; then
  if "${SCRIPT_DIR}/validate-module.sh" .; then
    ok "Module validation passed"
  else
    err "Module validation failed. Fix issues before publishing."
    exit 1
  fi
else
  # Inline minimal validation
  if command -v terraform &>/dev/null; then
    terraform fmt -check -recursive . >/dev/null 2>&1 && ok "terraform fmt" || { err "terraform fmt"; exit 1; }
    terraform validate >/dev/null 2>&1 && ok "terraform validate" || { err "terraform validate"; exit 1; }
  fi
fi

echo ""

# --- Create Tag ---
echo "--- Tagging ---"
CHANGELOG=""
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [[ -n "$PREV_TAG" ]]; then
  CHANGELOG=$(git log --oneline "${PREV_TAG}..HEAD" 2>/dev/null || echo "Initial release")
  info "Changes since ${PREV_TAG}:"
  echo "$CHANGELOG" | head -20
else
  CHANGELOG="Initial release"
  info "No previous tag found — this is the initial release"
fi

TAG_MESSAGE="Release ${TAG}

Changes:
${CHANGELOG}"

if $DRY_RUN; then
  info "[DRY RUN] Would create tag: ${TAG}"
  info "[DRY RUN] Tag message:"
  echo "$TAG_MESSAGE"
else
  git tag -a "$TAG" -m "$TAG_MESSAGE"
  ok "Created tag ${TAG}"
fi

echo ""

# --- Push Tag ---
echo "--- Publishing ---"
if $DRY_RUN; then
  info "[DRY RUN] Would push tag ${TAG} to ${GIT_REMOTE}"
else
  git push "$GIT_REMOTE" "$TAG"
  ok "Pushed tag ${TAG} to ${GIT_REMOTE}"
fi

# --- Private Registry Publish (optional) ---
if [[ -n "$REGISTRY_TOKEN" && -n "$ORG" ]]; then
  echo ""
  echo "--- Registry Publish ---"
  API_URL="https://${REGISTRY_URL}/api/v2/organizations/${ORG}/registry-modules"

  if $DRY_RUN; then
    info "[DRY RUN] Would publish to ${REGISTRY_URL} as ${ORG}/${MODULE_NAME}/${MODULE_PROVIDER}"
  else
    # Create module in registry (idempotent)
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${REGISTRY_TOKEN}" \
      -H "Content-Type: application/vnd.api+json" \
      -d "{
        \"data\": {
          \"type\": \"registry-modules\",
          \"attributes\": {
            \"name\": \"${MODULE_NAME}\",
            \"provider\": \"${MODULE_PROVIDER}\",
            \"registry-name\": \"private\"
          }
        }
      }" \
      "${API_URL}")

    if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "422" ]]; then
      ok "Module registered (or already exists) in ${REGISTRY_URL}"
    else
      warn "Registry API returned HTTP ${HTTP_CODE} — module may need manual setup"
    fi

    # Create version
    VERSION_URL="${API_URL}/private/${ORG}/${MODULE_NAME}/${MODULE_PROVIDER}/versions"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${REGISTRY_TOKEN}" \
      -H "Content-Type: application/vnd.api+json" \
      -d "{
        \"data\": {
          \"type\": \"registry-module-versions\",
          \"attributes\": { \"version\": \"${VERSION}\" }
        }
      }" \
      "${VERSION_URL}")

    if [[ "$HTTP_CODE" == "201" ]]; then
      ok "Version ${VERSION} published to registry"
    else
      warn "Version publish returned HTTP ${HTTP_CODE} — check registry manually"
    fi
  fi
fi

# --- Summary ---
echo ""
echo "==========================================="
if $DRY_RUN; then
  echo -e "${YELLOW}Dry run complete — no changes were made.${NC}"
  echo "Run without --dry-run to publish."
else
  echo -e "${GREEN}Module ${MODULE_PROVIDER}/${MODULE_NAME} version ${TAG} published!${NC}"
  echo ""
  echo "Usage in Terraform:"
  echo ""
  if [[ -n "$ORG" ]]; then
    echo "  module \"${MODULE_NAME//-/_}\" {"
    echo "    source  = \"${REGISTRY_URL}/${ORG}/${MODULE_NAME}/${MODULE_PROVIDER}\""
    echo "    version = \"${VERSION}\""
    echo "  }"
  else
    echo "  module \"${MODULE_NAME//-/_}\" {"
    echo "    source = \"git::https://github.com/org/terraform-${MODULE_PROVIDER}-${MODULE_NAME}.git?ref=${TAG}\""
    echo "  }"
  fi
fi
