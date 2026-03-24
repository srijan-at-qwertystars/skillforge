#!/usr/bin/env bash
#
# s3-sync.sh — Smart S3 sync with include/exclude patterns, size verification,
# and progress reporting.
#
# Usage:
#   ./s3-sync.sh <source> <destination> [options]
#
# Examples:
#   # Upload local directory to S3
#   ./s3-sync.sh ./build/ s3://my-bucket/releases/v1.2/
#
#   # Download from S3 to local
#   ./s3-sync.sh s3://my-bucket/data/ ./local-data/
#
#   # Sync between S3 buckets
#   ./s3-sync.sh s3://source-bucket/prefix/ s3://dest-bucket/prefix/
#
#   # With filters and dry-run
#   ./s3-sync.sh ./src/ s3://my-bucket/code/ \
#     --include "*.py" --include "*.json" \
#     --exclude "*.pyc" --exclude "__pycache__/*" \
#     --exclude ".git/*" --dry-run
#
#   # Delete removed files, with size-class override
#   ./s3-sync.sh ./archive/ s3://my-bucket/archive/ --delete --storage-class STANDARD_IA
#
set -euo pipefail

# --- Color output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header(){ echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

# --- Defaults ---
SOURCE=""
DEST=""
INCLUDES=()
EXCLUDES=()
DELETE_FLAG=""
DRY_RUN=""
STORAGE_CLASS=""
PROFILE=""
MAX_CONCURRENT=""
VERIFY_SIZE=true

# --- Argument parsing ---
if [[ $# -lt 2 ]]; then
    cat <<'USAGE'
Usage: s3-sync.sh <source> <destination> [options]

Arguments:
  source          Local path or s3://bucket/prefix/
  destination     Local path or s3://bucket/prefix/

Options:
  --include PATTERN    Include files matching pattern (repeatable)
  --exclude PATTERN    Exclude files matching pattern (repeatable)
  --delete             Delete files in destination not in source
  --dry-run            Preview changes without syncing
  --storage-class CLS  Set storage class (STANDARD_IA, GLACIER, etc.)
  --profile NAME       AWS CLI profile to use
  --max-concurrent N   Max concurrent requests (default: AWS CLI default)
  --no-verify          Skip post-sync size verification

Common Exclude Patterns:
  --exclude ".git/*" --exclude "*.pyc" --exclude "__pycache__/*"
  --exclude "node_modules/*" --exclude ".env"
  --exclude "*.log" --exclude "*.tmp"
USAGE
    exit 1
fi

SOURCE="$1"
DEST="$2"
shift 2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --include)
            INCLUDES+=("$2")
            shift 2
            ;;
        --exclude)
            EXCLUDES+=("$2")
            shift 2
            ;;
        --delete)
            DELETE_FLAG="--delete"
            shift
            ;;
        --dry-run)
            DRY_RUN="--dryrun"
            shift
            ;;
        --storage-class)
            STORAGE_CLASS="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --max-concurrent)
            MAX_CONCURRENT="$2"
            shift 2
            ;;
        --no-verify)
            VERIFY_SIZE=false
            shift
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Validate prerequisites ---
if ! command -v aws &>/dev/null; then
    error "AWS CLI is not installed."
    exit 1
fi

# --- Build AWS CLI command ---
AWS_CMD=(aws)
if [[ -n "${PROFILE}" ]]; then
    AWS_CMD+=(--profile "${PROFILE}")
fi

# Set max concurrent requests if specified
if [[ -n "${MAX_CONCURRENT}" ]]; then
    export AWS_MAX_CONCURRENT_REQUESTS="${MAX_CONCURRENT}"
fi

# --- Build sync arguments ---
SYNC_ARGS=()

for pattern in "${INCLUDES[@]}"; do
    SYNC_ARGS+=(--include "${pattern}")
done

for pattern in "${EXCLUDES[@]}"; do
    SYNC_ARGS+=(--exclude "${pattern}")
done

if [[ -n "${DELETE_FLAG}" ]]; then
    SYNC_ARGS+=("${DELETE_FLAG}")
fi

if [[ -n "${DRY_RUN}" ]]; then
    SYNC_ARGS+=("${DRY_RUN}")
fi

if [[ -n "${STORAGE_CLASS}" ]]; then
    SYNC_ARGS+=(--storage-class "${STORAGE_CLASS}")
fi

# --- Helper: get size of local directory ---
get_local_size() {
    local path="$1"
    if [[ -d "${path}" ]]; then
        du -sb "${path}" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

# --- Helper: get size of S3 prefix ---
get_s3_size() {
    local s3_path="$1"
    "${AWS_CMD[@]}" s3 ls "${s3_path}" --recursive --summarize 2>/dev/null \
        | grep "Total Size" | awk '{print $3}' || echo "0"
}

# --- Helper: count objects at S3 prefix ---
get_s3_count() {
    local s3_path="$1"
    "${AWS_CMD[@]}" s3 ls "${s3_path}" --recursive --summarize 2>/dev/null \
        | grep "Total Objects" | awk '{print $3}' || echo "0"
}

# --- Helper: format bytes ---
format_bytes() {
    local bytes="$1"
    if [[ -z "${bytes}" || "${bytes}" == "0" ]]; then
        echo "0 B"
        return
    fi
    if (( bytes >= 1073741824 )); then
        echo "$(echo "scale=2; ${bytes}/1073741824" | bc) GB"
    elif (( bytes >= 1048576 )); then
        echo "$(echo "scale=2; ${bytes}/1048576" | bc) MB"
    elif (( bytes >= 1024 )); then
        echo "$(echo "scale=2; ${bytes}/1024" | bc) KB"
    else
        echo "${bytes} B"
    fi
}

# --- Pre-sync report ---
header "S3 Sync Configuration"
echo "  Source:        ${SOURCE}"
echo "  Destination:   ${DEST}"
echo "  Delete mode:   $(if [[ -n "${DELETE_FLAG}" ]]; then echo "YES (files in dest not in source will be removed)"; else echo "No"; fi)"
echo "  Dry run:       $(if [[ -n "${DRY_RUN}" ]]; then echo "YES (preview only)"; else echo "No"; fi)"
echo "  Storage class: $(if [[ -n "${STORAGE_CLASS}" ]]; then echo "${STORAGE_CLASS}"; else echo "Default (STANDARD)"; fi)"

if [[ ${#INCLUDES[@]} -gt 0 ]]; then
    echo "  Includes:      ${INCLUDES[*]}"
fi
if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
    echo "  Excludes:      ${EXCLUDES[*]}"
fi

# --- Measure source size ---
header "Pre-Sync Analysis"
if [[ "${SOURCE}" == s3://* ]]; then
    SOURCE_SIZE=$(get_s3_size "${SOURCE}")
    SOURCE_COUNT=$(get_s3_count "${SOURCE}")
    info "Source (S3): ${SOURCE_COUNT} objects, $(format_bytes "${SOURCE_SIZE}")"
else
    SOURCE_SIZE=$(get_local_size "${SOURCE}")
    SOURCE_COUNT=$(find "${SOURCE}" -type f 2>/dev/null | wc -l)
    info "Source (local): ${SOURCE_COUNT} files, $(format_bytes "${SOURCE_SIZE}")"
fi

if [[ "${DEST}" == s3://* ]]; then
    DEST_SIZE_BEFORE=$(get_s3_size "${DEST}")
    DEST_COUNT_BEFORE=$(get_s3_count "${DEST}")
    info "Destination (S3) before sync: ${DEST_COUNT_BEFORE} objects, $(format_bytes "${DEST_SIZE_BEFORE}")"
else
    DEST_SIZE_BEFORE=$(get_local_size "${DEST}")
    DEST_COUNT_BEFORE=$(find "${DEST}" -type f 2>/dev/null | wc -l || echo "0")
    info "Destination (local) before sync: ${DEST_COUNT_BEFORE} files, $(format_bytes "${DEST_SIZE_BEFORE}")"
fi

# --- Execute sync ---
header "Syncing"
START_TIME=$(date +%s)

# If includes are specified, we need --exclude "*" at the end to exclude everything else
if [[ ${#INCLUDES[@]} -gt 0 ]]; then
    # With includes: --include first, then --exclude patterns, then --exclude "*"
    INCLUDE_ARGS=()
    for pattern in "${INCLUDES[@]}"; do
        INCLUDE_ARGS+=(--include "${pattern}")
    done
    EXCLUDE_ARGS=()
    for pattern in "${EXCLUDES[@]}"; do
        EXCLUDE_ARGS+=(--exclude "${pattern}")
    done
    EXTRA_ARGS=()
    if [[ -n "${DELETE_FLAG}" ]]; then EXTRA_ARGS+=("${DELETE_FLAG}"); fi
    if [[ -n "${DRY_RUN}" ]]; then EXTRA_ARGS+=("${DRY_RUN}"); fi
    if [[ -n "${STORAGE_CLASS}" ]]; then EXTRA_ARGS+=(--storage-class "${STORAGE_CLASS}"); fi

    "${AWS_CMD[@]}" s3 sync "${SOURCE}" "${DEST}" \
        "${INCLUDE_ARGS[@]}" \
        "${EXCLUDE_ARGS[@]}" \
        --exclude "*" \
        "${EXTRA_ARGS[@]}" \
        2>&1 | tee /tmp/s3-sync-output-$$.log
else
    "${AWS_CMD[@]}" s3 sync "${SOURCE}" "${DEST}" \
        "${SYNC_ARGS[@]}" \
        2>&1 | tee /tmp/s3-sync-output-$$.log
fi

END_TIME=$(date +%s)
DURATION=$(( END_TIME - START_TIME ))

# --- Post-sync report ---
header "Post-Sync Report"

SYNCED_COUNT=$(grep -c "^upload\|^download\|^copy\|^delete" /tmp/s3-sync-output-$$.log 2>/dev/null || echo "0")
info "Duration: ${DURATION} seconds"
info "Operations: ${SYNCED_COUNT} files transferred/deleted"

# --- Size verification ---
if [[ "${VERIFY_SIZE}" == true && -z "${DRY_RUN}" ]]; then
    header "Size Verification"

    if [[ "${DEST}" == s3://* ]]; then
        DEST_SIZE_AFTER=$(get_s3_size "${DEST}")
        DEST_COUNT_AFTER=$(get_s3_count "${DEST}")
        info "Destination (S3) after sync: ${DEST_COUNT_AFTER} objects, $(format_bytes "${DEST_SIZE_AFTER}")"
    else
        DEST_SIZE_AFTER=$(get_local_size "${DEST}")
        DEST_COUNT_AFTER=$(find "${DEST}" -type f 2>/dev/null | wc -l)
        info "Destination (local) after sync: ${DEST_COUNT_AFTER} files, $(format_bytes "${DEST_SIZE_AFTER}")"
    fi

    SIZE_DIFF=$(( DEST_SIZE_AFTER - DEST_SIZE_BEFORE ))
    if (( SIZE_DIFF >= 0 )); then
        info "Size change: +$(format_bytes ${SIZE_DIFF})"
    else
        ABS_DIFF=$(( -SIZE_DIFF ))
        info "Size change: -$(format_bytes ${ABS_DIFF})"
    fi

    if [[ "${SOURCE}" != s3://* && "${DEST}" == s3://* ]]; then
        if [[ "${SOURCE_SIZE}" -gt 0 ]]; then
            RATIO=$(echo "scale=2; ${DEST_SIZE_AFTER} * 100 / ${SOURCE_SIZE}" | bc 2>/dev/null || echo "N/A")
            if [[ "${RATIO}" != "N/A" ]]; then
                info "Coverage: ${RATIO}% of source size synced to destination"
                RATIO_INT=$(echo "${RATIO}" | cut -d. -f1)
                if (( RATIO_INT < 90 )); then
                    warn "Destination size is significantly smaller than source."
                    warn "This may be expected if using include/exclude filters."
                fi
            fi
        fi
    fi
fi

# --- Cleanup ---
rm -f /tmp/s3-sync-output-$$.log

header "Sync Complete"
info "Source:      ${SOURCE}"
info "Destination: ${DEST}"
info "Duration:    ${DURATION}s"
