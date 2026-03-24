#!/usr/bin/env bash
# =============================================================================
# build-image.sh — Wrapper for packer build with validation, logging,
#                  variable files, and parallel build control
#
# Usage:
#   ./build-image.sh [options] [PACKER_DIR]
#   ./build-image.sh                                 # Build all sources in .
#   ./build-image.sh -f prod.pkrvars.hcl .           # With var file
#   ./build-image.sh -f prod.pkrvars.hcl -f secrets.pkrvars.hcl .
#   ./build-image.sh --only 'amazon-ebs.*' .         # Single builder
#   ./build-image.sh --except 'docker.*' .            # Exclude builder
#   ./build-image.sh --parallel 2 .                   # Limit concurrency
#   ./build-image.sh --debug .                        # Debug mode
#   ./build-image.sh --dry-run .                      # Validate only
#   ./build-image.sh --log-dir /tmp/logs .            # Custom log dir
#   ./build-image.sh --var 'region=eu-west-1' .       # Pass variables
#
# Options:
#   -f, --var-file FILE     Variable file (can specify multiple times)
#   --var KEY=VALUE         Set a variable (can specify multiple times)
#   --only PATTERN          Build only matching sources (e.g., 'amazon-ebs.*')
#   --except PATTERN        Exclude matching sources
#   --parallel N            Limit parallel builds (default: unlimited)
#   --debug                 Enable PACKER_LOG, -on-error=ask, write debug log
#   --dry-run               Run init + fmt + validate only, skip build
#   --force                 Force overwrite existing images
#   --no-color              Disable color output
#   --log-dir DIR           Directory for build logs (default: ./build-logs)
#   --timestamp-ui          Show timestamps in Packer output
#   -h, --help              Show this help message
#
# Environment Variables:
#   PACKER_DIR              Override template directory (default: first arg or .)
#   PACKER_LOG              Set to 1 for debug logging
#   PACKER_LOG_PATH         Custom log file path
#   PKR_VAR_*               Packer variable overrides
#
# Exit Codes:
#   0  Success
#   1  Packer init/fmt/validate/build failure
#   2  Missing dependencies
#   3  Invalid arguments
# =============================================================================

set -euo pipefail

# --- Defaults ---
PACKER_DIR=""
VAR_FILES=()
VARS=()
ONLY=""
EXCEPT=""
PARALLEL=""
DEBUG=false
DRY_RUN=false
FORCE=false
NO_COLOR=false
TIMESTAMP_UI=true
LOG_DIR="./build-logs"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
log_header() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# --- Help ---
show_help() {
  sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//' | head -n -1
  exit 0
}

# --- Argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--var-file)
      [ -z "${2:-}" ] && { log_error "--var-file requires an argument"; exit 3; }
      VAR_FILES+=("$2"); shift 2 ;;
    --var)
      [ -z "${2:-}" ] && { log_error "--var requires an argument"; exit 3; }
      VARS+=("$2"); shift 2 ;;
    --only)
      [ -z "${2:-}" ] && { log_error "--only requires an argument"; exit 3; }
      ONLY="$2"; shift 2 ;;
    --except)
      [ -z "${2:-}" ] && { log_error "--except requires an argument"; exit 3; }
      EXCEPT="$2"; shift 2 ;;
    --parallel)
      [ -z "${2:-}" ] && { log_error "--parallel requires an argument"; exit 3; }
      PARALLEL="$2"; shift 2 ;;
    --debug)        DEBUG=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --force)        FORCE=true; shift ;;
    --no-color)     NO_COLOR=true; shift ;;
    --log-dir)
      [ -z "${2:-}" ] && { log_error "--log-dir requires an argument"; exit 3; }
      LOG_DIR="$2"; shift 2 ;;
    --timestamp-ui) TIMESTAMP_UI=true; shift ;;
    -h|--help)      show_help ;;
    -*)             log_error "Unknown option: $1"; exit 3 ;;
    *)
      if [ -z "$PACKER_DIR" ]; then
        PACKER_DIR="$1"
      else
        log_error "Unexpected argument: $1"; exit 3
      fi
      shift ;;
  esac
done

PACKER_DIR="${PACKER_DIR:-.}"

# --- Preflight checks ---
check_dependency() {
  command -v "$1" &>/dev/null || { log_error "'$1' is required but not found in PATH"; exit 2; }
}

check_dependency packer

if [ ! -d "$PACKER_DIR" ]; then
  log_error "Packer directory not found: $PACKER_DIR"
  exit 3
fi

# Verify at least one .pkr.hcl file exists
if ! ls "$PACKER_DIR"/*.pkr.hcl &>/dev/null; then
  log_error "No .pkr.hcl files found in $PACKER_DIR"
  exit 3
fi

# Verify var files exist
for vf in "${VAR_FILES[@]}"; do
  if [ ! -f "$vf" ]; then
    log_error "Variable file not found: $vf"
    exit 3
  fi
done

# --- Setup logging ---
mkdir -p "$LOG_DIR"
BUILD_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BUILD_LOG="$LOG_DIR/build-${BUILD_TIMESTAMP}.log"

log_info "Build log: $BUILD_LOG"

# Tee output to log file
exec > >(tee -a "$BUILD_LOG") 2>&1

log_header "Packer Build — $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
log_info "Template directory: $PACKER_DIR"
log_info "Variable files: ${VAR_FILES[*]:-none}"
log_info "Git SHA: $(git -C "$PACKER_DIR" rev-parse --short HEAD 2>/dev/null || echo 'not a git repo')"

# --- Build common args ---
build_common_args() {
  local args=()
  for vf in "${VAR_FILES[@]}"; do
    args+=("-var-file=$vf")
  done
  for v in "${VARS[@]}"; do
    args+=("-var" "$v")
  done
  echo "${args[@]}"
}

COMMON_ARGS=$(build_common_args)

# --- Step 1: Init ---
log_step "Initializing plugins"
packer init "$PACKER_DIR"
log_info "Plugins initialized ✓"

# --- Step 2: Format check ---
log_step "Checking format"
if ! packer fmt -check -diff "$PACKER_DIR" 2>&1; then
  log_warn "Some files need formatting. Run: packer fmt $PACKER_DIR"
  # Non-fatal — continue with build
fi
log_info "Format check done ✓"

# --- Step 3: Validate ---
log_step "Validating template"
# shellcheck disable=SC2086
if ! packer validate $COMMON_ARGS "$PACKER_DIR"; then
  log_error "Validation FAILED"
  exit 1
fi
log_info "Validation passed ✓"

# --- Dry run stops here ---
if [ "$DRY_RUN" = true ]; then
  log_header "Dry Run Complete"
  log_info "Template is valid. Skipping build (--dry-run)."
  exit 0
fi

# --- Step 4: Build ---
log_step "Starting build"

BUILD_ARGS=()

# Common args
# shellcheck disable=SC2206
BUILD_ARGS+=($COMMON_ARGS)

# Color
if [ "$NO_COLOR" = true ]; then
  BUILD_ARGS+=("-color=false")
fi

# Timestamp UI
if [ "$TIMESTAMP_UI" = true ]; then
  BUILD_ARGS+=("-timestamp-ui")
fi

# Only/Except
[ -n "$ONLY" ] && BUILD_ARGS+=("-only=$ONLY")
[ -n "$EXCEPT" ] && BUILD_ARGS+=("-except=$EXCEPT")

# Parallel
[ -n "$PARALLEL" ] && BUILD_ARGS+=("-parallel-builds=$PARALLEL")

# Force
[ "$FORCE" = true ] && BUILD_ARGS+=("-force")

# Debug mode
if [ "$DEBUG" = true ]; then
  export PACKER_LOG=1
  export PACKER_LOG_PATH="$LOG_DIR/packer-debug-${BUILD_TIMESTAMP}.log"
  BUILD_ARGS+=("-on-error=ask")
  log_info "Debug mode: PACKER_LOG=1, log=$PACKER_LOG_PATH"
fi

# Record start time
BUILD_START=$(date +%s)

log_info "Running: packer build ${BUILD_ARGS[*]} $PACKER_DIR"

# Run the build
if packer build "${BUILD_ARGS[@]}" "$PACKER_DIR"; then
  BUILD_END=$(date +%s)
  BUILD_DURATION=$(( BUILD_END - BUILD_START ))
  log_header "Build Complete ✅"
  log_info "Duration: ${BUILD_DURATION}s ($(( BUILD_DURATION / 60 ))m $(( BUILD_DURATION % 60 ))s)"

  # Extract artifact info from manifest if available
  MANIFEST=$(find "$PACKER_DIR" -name 'manifest.json' -path '*/manifests/*' 2>/dev/null | head -1)
  if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] && command -v jq &>/dev/null; then
    log_info "Manifest: $MANIFEST"
    ARTIFACT_ID=$(jq -r '.builds[-1].artifact_id // "unknown"' "$MANIFEST")
    BUILDER_TYPE=$(jq -r '.builds[-1].builder_type // "unknown"' "$MANIFEST")
    log_info "Builder: $BUILDER_TYPE"
    log_info "Artifact: $ARTIFACT_ID"
  fi

  log_info "Build log: $BUILD_LOG"
  exit 0
else
  BUILD_END=$(date +%s)
  BUILD_DURATION=$(( BUILD_END - BUILD_START ))
  log_header "Build FAILED ❌"
  log_error "Duration: ${BUILD_DURATION}s"
  log_error "Check log: $BUILD_LOG"
  [ "$DEBUG" = true ] && log_error "Debug log: $PACKER_LOG_PATH"
  exit 1
fi
