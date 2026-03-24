#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# bulk-import.sh
# Bulk import JSON, NDJSON, or CSV data into Meilisearch with batching and
# progress tracking.
# =============================================================================

# ---------------------------------------------------------------------------
# Color output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
FILE=""
INDEX=""
API_KEY=""
MEILI_URL="${MEILI_URL:-http://localhost:7700}"
BATCH_SIZE=10000
PRIMARY_KEY=""
TMPDIR_BASE=""

# ---------------------------------------------------------------------------
# Cleanup trap – remove temp files on exit
# ---------------------------------------------------------------------------
cleanup() {
    if [[ -n "$TMPDIR_BASE" && -d "$TMPDIR_BASE" ]]; then
        rm -rf "$TMPDIR_BASE"
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") -f <file> -i <index> [options]

Bulk import JSON, NDJSON, or CSV data into Meilisearch.

${BOLD}Required:${NC}
  -f, --file <path>         Path to input file (JSON, NDJSON, or CSV)
  -i, --index <name>        Target Meilisearch index UID

${BOLD}Options:${NC}
  -k, --api-key <key>       API key for authentication (or set MEILI_API_KEY)
  -u, --url <url>           Meilisearch URL (default: \$MEILI_URL or http://localhost:7700)
  -b, --batch-size <n>      Documents per batch (default: 10000)
  -p, --primary-key <key>   Primary key field name (optional)
  -h, --help                Show this help message

${BOLD}Supported formats:${NC}
  .json     JSON array of objects
  .ndjson   Newline-delimited JSON (one object per line)
  .csv      Comma-separated values with header row

${BOLD}Examples:${NC}
  $(basename "$0") -f movies.json -i movies -k 'my-api-key'
  $(basename "$0") -f products.csv -i products -b 5000 -p sku
  $(basename "$0") -f logs.ndjson -i logs -u http://meili:7700
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)        FILE="$2";        shift 2 ;;
        -i|--index)       INDEX="$2";       shift 2 ;;
        -k|--api-key)     API_KEY="$2";     shift 2 ;;
        -u|--url)         MEILI_URL="$2";   shift 2 ;;
        -b|--batch-size)  BATCH_SIZE="$2";  shift 2 ;;
        -p|--primary-key) PRIMARY_KEY="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) die "Unknown option: $1. Use -h for help." ;;
    esac
done

# Fall back to env var for API key
API_KEY="${API_KEY:-${MEILI_API_KEY:-}}"

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
[[ -z "$FILE" ]]  && die "Input file is required (-f). Use -h for help."
[[ -z "$INDEX" ]] && die "Index name is required (-i). Use -h for help."
[[ -f "$FILE" ]]  || die "File not found: ${FILE}"

if ! command -v curl &>/dev/null; then
    die "curl is required but not found."
fi

if ! command -v jq &>/dev/null; then
    die "jq is required for JSON processing but not found."
fi

# Check Meilisearch is reachable
info "Checking Meilisearch at ${MEILI_URL}..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${MEILI_URL}/health" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "200" ]]; then
    die "Meilisearch is not reachable at ${MEILI_URL} (HTTP ${HTTP_CODE})."
fi
success "Meilisearch is healthy."

# Validate API key if provided
if [[ -n "$API_KEY" ]]; then
    KEY_CHECK=$(curl -s -o /dev/null -w '%{http_code}' \
        "${MEILI_URL}/indexes" \
        -H "Authorization: Bearer ${API_KEY}" 2>/dev/null || echo "000")
    if [[ "$KEY_CHECK" == "403" || "$KEY_CHECK" == "401" ]]; then
        die "API key is invalid or lacks permission (HTTP ${KEY_CHECK})."
    fi
    success "API key validated."
fi

# ---------------------------------------------------------------------------
# Detect file format
# ---------------------------------------------------------------------------
detect_format() {
    local file="$1"
    local ext="${file##*.}"
    ext="${ext,,}" # lowercase

    case "$ext" in
        json)
            # Peek at first non-whitespace character to distinguish JSON array vs NDJSON
            local first_char
            first_char=$(head -c 4096 "$file" | sed -n 's/^[[:space:]]*\(.\).*/\1/p' | head -1)
            if [[ "$first_char" == "[" ]]; then
                echo "json"
            else
                echo "ndjson"
            fi
            ;;
        ndjson|jsonl)
            echo "ndjson"
            ;;
        csv)
            echo "csv"
            ;;
        *)
            # Try to auto-detect from content
            local first_char
            first_char=$(head -c 4096 "$file" | sed -n 's/^[[:space:]]*\(.\).*/\1/p' | head -1)
            if [[ "$first_char" == "[" ]]; then
                echo "json"
            elif [[ "$first_char" == "{" ]]; then
                echo "ndjson"
            else
                echo "csv"
            fi
            ;;
    esac
}

FORMAT=$(detect_format "$FILE")
info "Detected format: ${BOLD}${FORMAT}${NC}"

# ---------------------------------------------------------------------------
# Create temp directory for batch files
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d "/tmp/meili-import.XXXXXX")
BATCH_DIR="${TMPDIR_BASE}/batches"
mkdir -p "$BATCH_DIR"

# ---------------------------------------------------------------------------
# Build auth header
# ---------------------------------------------------------------------------
AUTH_HEADER=()
if [[ -n "$API_KEY" ]]; then
    AUTH_HEADER=(-H "Authorization: Bearer ${API_KEY}")
fi

# Primary key query param
PK_PARAM=""
if [[ -n "$PRIMARY_KEY" ]]; then
    PK_PARAM="?primaryKey=${PRIMARY_KEY}"
fi

# ---------------------------------------------------------------------------
# Split file into batches
# ---------------------------------------------------------------------------
info "Splitting data into batches of ${BATCH_SIZE} documents..."

TOTAL_DOCS=0
TOTAL_BATCHES=0

case "$FORMAT" in
    json)
        # Count total documents in JSON array
        TOTAL_DOCS=$(jq 'length' "$FILE")
        TOTAL_BATCHES=$(( (TOTAL_DOCS + BATCH_SIZE - 1) / BATCH_SIZE ))

        info "Total documents: ${TOTAL_DOCS}, batches: ${TOTAL_BATCHES}"

        # Split the array into batch files
        for (( b=0; b<TOTAL_BATCHES; b++ )); do
            START=$(( b * BATCH_SIZE ))
            jq ".[$START:$((START + BATCH_SIZE))]" "$FILE" > "${BATCH_DIR}/batch_$(printf '%06d' $b).json"
        done
        ;;

    ndjson)
        # Count total lines (each line is a document)
        TOTAL_DOCS=$(wc -l < "$FILE" | tr -d ' ')
        TOTAL_BATCHES=$(( (TOTAL_DOCS + BATCH_SIZE - 1) / BATCH_SIZE ))

        info "Total documents: ${TOTAL_DOCS}, batches: ${TOTAL_BATCHES}"

        # Split into fixed-size chunks
        split -l "$BATCH_SIZE" -d -a 6 "$FILE" "${BATCH_DIR}/batch_"
        # Rename to .ndjson
        for f in "${BATCH_DIR}"/batch_*; do
            [[ -f "$f" ]] && mv "$f" "${f}.ndjson"
        done
        ;;

    csv)
        # Count lines excluding header
        TOTAL_DOCS=$(( $(wc -l < "$FILE" | tr -d ' ') - 1 ))
        if (( TOTAL_DOCS <= 0 )); then
            die "CSV file appears empty (no data rows)."
        fi
        TOTAL_BATCHES=$(( (TOTAL_DOCS + BATCH_SIZE - 1) / BATCH_SIZE ))

        info "Total documents: ${TOTAL_DOCS}, batches: ${TOTAL_BATCHES}"

        # Extract header
        HEADER=$(head -1 "$FILE")

        # Split data rows (skip header), preserving the header in each batch
        BATCH_NUM=0
        CURRENT_LINE=0
        BATCH_FILE=""
        while IFS= read -r line; do
            if (( CURRENT_LINE % BATCH_SIZE == 0 )); then
                BATCH_FILE="${BATCH_DIR}/batch_$(printf '%06d' $BATCH_NUM).csv"
                echo "$HEADER" > "$BATCH_FILE"
                (( BATCH_NUM++ )) || true
            fi
            echo "$line" >> "$BATCH_FILE"
            (( CURRENT_LINE++ )) || true
        done < <(tail -n +2 "$FILE")
        ;;
esac

success "Data split into ${TOTAL_BATCHES} batch file(s)."

# ---------------------------------------------------------------------------
# Import batches with progress tracking
# ---------------------------------------------------------------------------
info "Starting import into index '${INDEX}'..."
echo ""

TASK_UIDS=()
IMPORTED=0
FAILED_BATCHES=0
START_TIME=$(date +%s)

# Determine content type
case "$FORMAT" in
    json)   CONTENT_TYPE="application/json" ;;
    ndjson) CONTENT_TYPE="application/x-ndjson" ;;
    csv)    CONTENT_TYPE="text/csv" ;;
esac

BATCH_FILES=("${BATCH_DIR}"/batch_*)
BATCH_INDEX=0

for batch_file in "${BATCH_FILES[@]}"; do
    [[ -f "$batch_file" ]] || continue
    (( BATCH_INDEX++ )) || true

    # Count docs in this batch
    case "$FORMAT" in
        json)   BATCH_DOCS=$(jq 'length' "$batch_file") ;;
        ndjson) BATCH_DOCS=$(wc -l < "$batch_file" | tr -d ' ') ;;
        csv)    BATCH_DOCS=$(( $(wc -l < "$batch_file" | tr -d ' ') - 1 )) ;;
    esac

    ELAPSED=$(( $(date +%s) - START_TIME ))
    printf "  ${BLUE}[%d/%d]${NC} Importing batch (%d docs) ... elapsed: %ds " \
        "$BATCH_INDEX" "$TOTAL_BATCHES" "$BATCH_DOCS" "$ELAPSED"

    RESPONSE=$(curl -s -X POST \
        "${MEILI_URL}/indexes/${INDEX}/documents${PK_PARAM}" \
        "${AUTH_HEADER[@]}" \
        -H "Content-Type: ${CONTENT_TYPE}" \
        --data-binary "@${batch_file}" 2>/dev/null || echo '{"error": "curl failed"}')

    TASK_UID=$(echo "$RESPONSE" | jq -r '.taskUid // empty' 2>/dev/null || echo "")

    if [[ -n "$TASK_UID" ]]; then
        TASK_UIDS+=("$TASK_UID")
        IMPORTED=$(( IMPORTED + BATCH_DOCS ))
        echo -e "${GREEN}✓${NC} (task: ${TASK_UID})"
    else
        (( FAILED_BATCHES++ )) || true
        ERR_MSG=$(echo "$RESPONSE" | jq -r '.message // .error // "unknown error"' 2>/dev/null || echo "unknown")
        echo -e "${RED}✗${NC} ${ERR_MSG}"
    fi
done

echo ""

# ---------------------------------------------------------------------------
# Poll for task completion
# ---------------------------------------------------------------------------
if [[ ${#TASK_UIDS[@]} -gt 0 ]]; then
    info "Waiting for ${#TASK_UIDS[@]} indexing task(s) to complete..."

    SUCCEEDED=0
    FAILED=0
    POLL_TIMEOUT=300 # 5 minutes max
    POLL_START=$(date +%s)

    PENDING_TASKS=("${TASK_UIDS[@]}")

    while [[ ${#PENDING_TASKS[@]} -gt 0 ]]; do
        ELAPSED=$(( $(date +%s) - POLL_START ))
        if (( ELAPSED > POLL_TIMEOUT )); then
            warn "Timed out after ${POLL_TIMEOUT}s. ${#PENDING_TASKS[@]} task(s) still pending."
            break
        fi

        STILL_PENDING=()
        for uid in "${PENDING_TASKS[@]}"; do
            STATUS=$(curl -s "${MEILI_URL}/tasks/${uid}" \
                "${AUTH_HEADER[@]}" 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

            case "$STATUS" in
                succeeded) (( SUCCEEDED++ )) || true ;;
                failed)    (( FAILED++ )) || true ;;
                *)         STILL_PENDING+=("$uid") ;;
            esac
        done

        PENDING_TASKS=("${STILL_PENDING[@]+"${STILL_PENDING[@]}"}")
        if [[ ${#PENDING_TASKS[@]} -gt 0 ]]; then
            printf "\r  Completed: %d succeeded, %d failed, %d pending ... " \
                "$SUCCEEDED" "$FAILED" "${#PENDING_TASKS[@]}"
            sleep 2
        fi
    done
    echo ""

    if (( FAILED > 0 )); then
        warn "${FAILED} task(s) failed. Check /tasks for details."
    fi
fi

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------
TOTAL_TIME=$(( $(date +%s) - START_TIME ))

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║           Import Complete                                    ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Index:${NC}              ${INDEX}"
echo -e "  ${BOLD}Source file:${NC}        ${FILE}"
echo -e "  ${BOLD}Format:${NC}             ${FORMAT}"
echo -e "  ${BOLD}Total documents:${NC}    ${IMPORTED}"
echo -e "  ${BOLD}Batches sent:${NC}       ${BATCH_INDEX} (${FAILED_BATCHES} failed)"
echo -e "  ${BOLD}Tasks succeeded:${NC}    ${SUCCEEDED:-N/A}"
echo -e "  ${BOLD}Tasks failed:${NC}       ${FAILED:-0}"
echo -e "  ${BOLD}Total time:${NC}         ${TOTAL_TIME}s"
echo ""

if (( FAILED_BATCHES > 0 || ${FAILED:-0} > 0 )); then
    warn "Some batches or tasks failed. Review the output above for details."
    exit 1
fi

success "All data imported successfully."
