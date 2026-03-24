#!/usr/bin/env bash
#
# scan-table.sh — Parallel scan a DynamoDB table with progress tracking
#
# Usage:
#   ./scan-table.sh --table MyTable
#   ./scan-table.sh --table MyTable --segments 10 --output results.json
#   ./scan-table.sh --table MyTable --region us-west-2 --profile myprofile
#   ./scan-table.sh --table MyTable --filter "status = :s" --values '{":s":{"S":"active"}}'
#   ./scan-table.sh --table MyTable --index GSI1 --projection "PK, SK, #n" --names '{"#n":"name"}'
#   ./scan-table.sh --table MyTable --max-items 10000
#
# Options:
#   --table       Table name (required)
#   --segments    Number of parallel scan segments (default: 5)
#   --output      Output file path (default: stdout)
#   --region      AWS region (default: from AWS config)
#   --profile     AWS CLI profile
#   --filter      FilterExpression
#   --values      ExpressionAttributeValues (JSON)
#   --names       ExpressionAttributeNames (JSON)
#   --projection  ProjectionExpression
#   --index       Index name to scan instead of base table
#   --max-items   Maximum total items to retrieve (default: unlimited)
#   --limit       Items per scan page (default: 1000)
#   --delay       Delay between pages in seconds for rate limiting (default: 0)
#   --consistent  Use strongly consistent reads
#
# Output: JSON array of items written to --output file or stdout
#
# Requirements: aws cli v2, jq, bash 4+
#

set -euo pipefail

# --- Defaults ---
TABLE=""
SEGMENTS=5
OUTPUT=""
REGION_FLAG=""
PROFILE_FLAG=""
FILTER=""
VALUES=""
NAMES=""
PROJECTION=""
INDEX=""
MAX_ITEMS=0
PAGE_LIMIT=1000
DELAY=0
CONSISTENT=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --table) TABLE="$2"; shift 2 ;;
        --segments) SEGMENTS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --region) REGION_FLAG="--region $2"; shift 2 ;;
        --profile) PROFILE_FLAG="--profile $2"; shift 2 ;;
        --filter) FILTER="$2"; shift 2 ;;
        --values) VALUES="$2"; shift 2 ;;
        --names) NAMES="$2"; shift 2 ;;
        --projection) PROJECTION="$2"; shift 2 ;;
        --index) INDEX="$2"; shift 2 ;;
        --max-items) MAX_ITEMS="$2"; shift 2 ;;
        --limit) PAGE_LIMIT="$2"; shift 2 ;;
        --delay) DELAY="$2"; shift 2 ;;
        --consistent) CONSISTENT=true; shift ;;
        -h|--help) head -30 "$0" | tail -27; exit 0 ;;
        *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$TABLE" ]]; then
    echo "Error: --table is required" >&2
    echo "Usage: $0 --table TABLE_NAME [--segments N] [--output FILE]" >&2
    exit 1
fi

# Check dependencies
for cmd in aws jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed" >&2
        exit 1
    fi
done

# --- Temp directory for segment files ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Build scan command base ---
build_scan_cmd() {
    local segment="$1"
    local cmd="aws dynamodb scan"
    cmd+=" --table-name $TABLE"
    cmd+=" --segment $segment"
    cmd+=" --total-segments $SEGMENTS"
    cmd+=" --max-items $PAGE_LIMIT"
    cmd+=" --output json"
    [[ -n "$REGION_FLAG" ]] && cmd+=" $REGION_FLAG"
    [[ -n "$PROFILE_FLAG" ]] && cmd+=" $PROFILE_FLAG"
    [[ -n "$FILTER" ]] && cmd+=" --filter-expression '$FILTER'"
    [[ -n "$VALUES" ]] && cmd+=" --expression-attribute-values '$VALUES'"
    [[ -n "$NAMES" ]] && cmd+=" --expression-attribute-names '$NAMES'"
    [[ -n "$PROJECTION" ]] && cmd+=" --projection-expression '$PROJECTION'"
    [[ -n "$INDEX" ]] && cmd+=" --index-name $INDEX"
    [[ "$CONSISTENT" == "true" ]] && cmd+=" --consistent-read"
    echo "$cmd"
}

# --- Scan a single segment ---
scan_segment() {
    local segment="$1"
    local outfile="$TMPDIR/segment_${segment}.json"
    local count=0
    local pages=0
    local starting_token=""

    echo "[]" > "$outfile"

    while true; do
        local cmd
        cmd=$(build_scan_cmd "$segment")
        if [[ -n "$starting_token" ]]; then
            cmd+=" --starting-token $starting_token"
        fi

        local response
        response=$(eval "$cmd" 2>&1)
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            echo "Error in segment $segment: $response" >&2
            return 1
        fi

        # Extract items and append to segment file
        local items
        items=$(echo "$response" | jq -c '.Items // []')
        local page_count
        page_count=$(echo "$items" | jq 'length')
        count=$((count + page_count))
        pages=$((pages + 1))

        # Merge items into segment file
        local existing
        existing=$(cat "$outfile")
        echo "$existing" | jq --argjson new "$items" '. + $new' > "$outfile"

        # Progress update
        echo "  Segment $segment: $count items ($pages pages)" >&2

        # Check max items
        if [[ "$MAX_ITEMS" -gt 0 && "$count" -ge "$MAX_ITEMS" ]]; then
            break
        fi

        # Check for more pages
        starting_token=$(echo "$response" | jq -r '.NextToken // empty')
        if [[ -z "$starting_token" ]]; then
            break
        fi

        # Rate limiting delay
        if (( $(echo "$DELAY > 0" | bc -l) )); then
            sleep "$DELAY"
        fi
    done

    echo "  Segment $segment: DONE — $count items" >&2
    echo "$count"
}

# --- Main execution ---

echo "Starting parallel scan of '$TABLE' with $SEGMENTS segments..." >&2
echo "" >&2

# Track start time
start_time=$(date +%s)

# Launch parallel scans
pids=()
for ((i = 0; i < SEGMENTS; i++)); do
    scan_segment "$i" &
    pids+=($!)
done

# Wait for all segments to complete
failed=false
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        failed=true
    fi
done

if [[ "$failed" == "true" ]]; then
    echo "" >&2
    echo "Error: One or more scan segments failed" >&2
    exit 1
fi

end_time=$(date +%s)
elapsed=$((end_time - start_time))

echo "" >&2
echo "Merging segment results..." >&2

# Merge all segment files into final output
merged="[]"
total_items=0
for ((i = 0; i < SEGMENTS; i++)); do
    segment_file="$TMPDIR/segment_${i}.json"
    if [[ -f "$segment_file" ]]; then
        segment_count=$(jq 'length' "$segment_file")
        total_items=$((total_items + segment_count))
        merged=$(echo "$merged" | jq --slurpfile seg "$segment_file" '. + $seg[0]')
    fi
done

# Trim to max items if specified
if [[ "$MAX_ITEMS" -gt 0 && "$total_items" -gt "$MAX_ITEMS" ]]; then
    merged=$(echo "$merged" | jq ".[0:$MAX_ITEMS]")
    total_items=$MAX_ITEMS
fi

# Output
if [[ -n "$OUTPUT" ]]; then
    echo "$merged" | jq '.' > "$OUTPUT"
    echo "Results written to: $OUTPUT" >&2
else
    echo "$merged" | jq '.'
fi

echo "" >&2
echo "════════════════════════════════════════" >&2
echo "  Scan complete" >&2
echo "  Table:      $TABLE" >&2
echo "  Segments:   $SEGMENTS" >&2
echo "  Items:      $total_items" >&2
echo "  Duration:   ${elapsed}s" >&2
if [[ -n "$OUTPUT" ]]; then
    filesize=$(du -h "$OUTPUT" | cut -f1)
    echo "  File size:  $filesize" >&2
fi
echo "════════════════════════════════════════" >&2
