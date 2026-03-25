#!/usr/bin/env bash
#
# upload-sourcemaps.sh — Automate Sentry source map upload for JS/TS projects
#
# Usage:
#   ./upload-sourcemaps.sh [OPTIONS]
#
# Options:
#   --version VERSION        Release version (default: git SHA or package.json version)
#   --build-dir DIR          Build output directory (default: ./dist)
#   --url-prefix PREFIX      URL prefix for source maps (default: ~/)
#   --no-finalize            Don't finalize the release
#   --no-commits             Don't associate commits
#   --delete-maps            Delete .map files from build dir after upload
#   --dry-run                Show what would be done without doing it
#   -h, --help               Show this help message
#
# Required environment variables:
#   SENTRY_AUTH_TOKEN   — Auth token with project:releases scope
#   SENTRY_ORG          — Organization slug
#   SENTRY_PROJECT      — Project slug
#
# Optional environment variables:
#   SENTRY_URL          — Sentry URL for self-hosted (default: https://sentry.io)
#
# Examples:
#   # Basic upload
#   SENTRY_AUTH_TOKEN=xxx SENTRY_ORG=my-org SENTRY_PROJECT=my-project \
#     ./upload-sourcemaps.sh
#
#   # Custom build dir and version
#   ./upload-sourcemaps.sh --version "my-app@1.2.3" --build-dir ./build --url-prefix "~/static/js/"
#
#   # Upload and clean up maps
#   ./upload-sourcemaps.sh --delete-maps

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Defaults ---
VERSION=""
BUILD_DIR="./dist"
URL_PREFIX="~/"
FINALIZE=true
ASSOCIATE_COMMITS=true
DELETE_MAPS=false
DRY_RUN=false

# --- Parse Args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)        VERSION="$2"; shift 2 ;;
    --build-dir)      BUILD_DIR="$2"; shift 2 ;;
    --url-prefix)     URL_PREFIX="$2"; shift 2 ;;
    --no-finalize)    FINALIZE=false; shift ;;
    --no-commits)     ASSOCIATE_COMMITS=false; shift ;;
    --delete-maps)    DELETE_MAPS=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^#//' | sed 's/^ //'
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Validate Prerequisites ---

check_prerequisites() {
  # Check sentry-cli is installed
  if ! command -v sentry-cli &>/dev/null; then
    err "sentry-cli is not installed."
    info "Install with: npm install -g @sentry/cli"
    info "  or: curl -sL https://sentry.io/get-cli/ | bash"
    exit 1
  fi

  # Check required env vars
  local missing=false
  for var in SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT; do
    if [[ -z "${!var:-}" ]]; then
      err "Missing required environment variable: $var"
      missing=true
    fi
  done
  [[ "$missing" == "true" ]] && exit 1

  # Check build directory exists
  if [[ ! -d "$BUILD_DIR" ]]; then
    err "Build directory not found: $BUILD_DIR"
    info "Run your build command first, or use --build-dir to specify the correct path."
    exit 1
  fi

  # Check for source map files
  local map_count
  map_count=$(find "$BUILD_DIR" -name "*.map" -type f 2>/dev/null | wc -l)
  if [[ "$map_count" -eq 0 ]]; then
    err "No .map files found in $BUILD_DIR"
    info "Ensure your build generates source maps (sourcemap: true in build config)."
    exit 1
  fi
  info "Found ${map_count} source map file(s) in ${BUILD_DIR}"
}

# --- Determine Version ---

determine_version() {
  if [[ -n "$VERSION" ]]; then
    echo "$VERSION"
    return
  fi

  # Try sentry-cli propose-version (uses git SHA)
  if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null; then
    sentry-cli releases propose-version 2>/dev/null && return
  fi

  # Try package.json version
  if [[ -f "package.json" ]]; then
    local pkg_name pkg_version
    pkg_name=$(node -p "require('./package.json').name" 2>/dev/null || echo "app")
    pkg_version=$(node -p "require('./package.json').version" 2>/dev/null || echo "0.0.0")
    echo "${pkg_name}@${pkg_version}"
    return
  fi

  # Fallback to timestamp
  echo "release-$(date +%Y%m%d%H%M%S)"
}

# --- Main Upload ---

main() {
  check_prerequisites

  local version
  version=$(determine_version)
  info "Release version: ${version}"

  if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY RUN — no changes will be made"
    echo ""
    echo "Would execute:"
    echo "  sentry-cli releases new \"${version}\""
    [[ "$ASSOCIATE_COMMITS" == "true" ]] && echo "  sentry-cli releases set-commits --auto \"${version}\""
    echo "  sentry-cli releases files \"${version}\" upload-sourcemaps ${BUILD_DIR} --url-prefix '${URL_PREFIX}' --validate"
    [[ "$FINALIZE" == "true" ]] && echo "  sentry-cli releases finalize \"${version}\""
    [[ "$DELETE_MAPS" == "true" ]] && echo "  find ${BUILD_DIR} -name '*.map' -type f -delete"
    exit 0
  fi

  # Step 1: Create release
  info "Creating release..."
  sentry-cli releases new "$version"
  ok "Release created: ${version}"

  # Step 2: Associate commits
  if [[ "$ASSOCIATE_COMMITS" == "true" ]]; then
    info "Associating commits..."
    if sentry-cli releases set-commits --auto "$version" 2>/dev/null; then
      ok "Commits associated"
    else
      warn "Could not auto-associate commits (missing repo integration?)"
    fi
  fi

  # Step 3: Upload source maps
  info "Uploading source maps from ${BUILD_DIR}..."
  sentry-cli releases files "$version" upload-sourcemaps "$BUILD_DIR" \
    --url-prefix "$URL_PREFIX" \
    --validate
  ok "Source maps uploaded"

  # Step 4: Finalize release
  if [[ "$FINALIZE" == "true" ]]; then
    info "Finalizing release..."
    sentry-cli releases finalize "$version"
    ok "Release finalized"
  fi

  # Step 5: Delete source maps from build dir (optional)
  if [[ "$DELETE_MAPS" == "true" ]]; then
    info "Deleting .map files from ${BUILD_DIR}..."
    find "$BUILD_DIR" -name "*.map" -type f -delete
    ok "Source maps deleted from build directory"
  fi

  echo ""
  ok "Source map upload complete!"
  info "Release: ${version}"
  info "View at: https://sentry.io/organizations/${SENTRY_ORG}/releases/${version}/"
}

main "$@"
