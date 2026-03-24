#!/usr/bin/env bash
#
# cross-compile.sh — Cross-compile a Zig project for multiple targets
#
# Usage:
#   ./cross-compile.sh [--targets <list>] [--optimize <mode>] [--output-dir <dir>]
#
# Examples:
#   ./cross-compile.sh                                    # all default targets
#   ./cross-compile.sh --targets "x86_64-linux,aarch64-linux"
#   ./cross-compile.sh --optimize ReleaseFast --output-dir dist/
#

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Default Configuration ---
DEFAULT_TARGETS=(
    "x86_64-linux-gnu"
    "aarch64-linux-gnu"
    "x86_64-macos"
    "aarch64-macos"
    "x86_64-windows-gnu"
)

OPTIMIZE="ReleaseSafe"
OUTPUT_DIR="zig-cross-out"
TARGETS=()

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --targets)
            IFS=',' read -ra TARGETS <<< "$2"
            shift 2
            ;;
        --optimize)
            OPTIMIZE="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: ${SCRIPT_NAME} [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --targets <list>     Comma-separated target triples"
            echo "                       Default: x86_64-linux-gnu,aarch64-linux-gnu,"
            echo "                                x86_64-macos,aarch64-macos,x86_64-windows-gnu"
            echo "  --optimize <mode>    Debug|ReleaseSafe|ReleaseFast|ReleaseSmall"
            echo "                       Default: ReleaseSafe"
            echo "  --output-dir <dir>   Output directory (default: zig-cross-out)"
            echo "  -h, --help           Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Use defaults if no targets specified
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    TARGETS=("${DEFAULT_TARGETS[@]}")
fi

# --- Validation ---
if [[ ! -f "build.zig" ]]; then
    log_error "No build.zig found in current directory. Run from a Zig project root."
    exit 1
fi

if ! command -v zig &>/dev/null; then
    log_error "Zig is not installed or not in PATH."
    exit 1
fi

case "$OPTIMIZE" in
    Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
    *)
        log_error "Invalid optimize mode: ${OPTIMIZE}"
        log_error "Valid modes: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall"
        exit 1
        ;;
esac

# --- Detect project name from build.zig ---
PROJECT_NAME=$(grep -oP '\.name\s*=\s*"\K[^"]+' build.zig | head -1 || echo "app")
log_info "Project: ${PROJECT_NAME}"
log_info "Optimize: ${OPTIMIZE}"
log_info "Targets: ${TARGETS[*]}"

mkdir -p "$OUTPUT_DIR"

# --- Cross-Compile ---
SUCCEEDED=0
FAILED=0
FAILED_TARGETS=()

for target in "${TARGETS[@]}"; do
    log_info "Building for ${target}..."

    target_dir="${OUTPUT_DIR}/${target}"
    mkdir -p "$target_dir"

    if zig build \
        -Dtarget="${target}" \
        -Doptimize="${OPTIMIZE}" \
        --prefix "$target_dir" \
        2>&1; then

        # Determine expected binary name
        case "$target" in
            *windows*)
                binary="${target_dir}/bin/${PROJECT_NAME}.exe"
                ;;
            *)
                binary="${target_dir}/bin/${PROJECT_NAME}"
                ;;
        esac

        if [[ -f "$binary" ]]; then
            size=$(du -h "$binary" | cut -f1)
            log_ok "${target} → ${binary} (${size})"
        else
            log_ok "${target} → ${target_dir}/"
        fi
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        log_error "Failed to build for ${target}"
        FAILED=$((FAILED + 1))
        FAILED_TARGETS+=("$target")
    fi
done

# --- Summary ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Cross-compilation complete"
echo "  Succeeded: ${SUCCEEDED}/${#TARGETS[@]}"

if [[ $FAILED -gt 0 ]]; then
    echo "  Failed:    ${FAILED} (${FAILED_TARGETS[*]})"
fi

echo "  Output:    ${OUTPUT_DIR}/"
echo ""

# List all built binaries with sizes
if command -v find &>/dev/null; then
    log_info "Built artifacts:"
    find "$OUTPUT_DIR" -type f \( -name "${PROJECT_NAME}" -o -name "${PROJECT_NAME}.exe" \) \
        -exec ls -lh {} \; 2>/dev/null | while read -r line; do
        echo "  $line"
    done
fi

exit $FAILED
