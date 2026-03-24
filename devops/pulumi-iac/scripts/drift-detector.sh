#!/usr/bin/env bash
# drift-detector.sh — Detect infrastructure drift using pulumi refresh --diff.
#
# Usage:
#   ./drift-detector.sh [options]
#
# Options:
#   --stack <name>          Target stack (default: current)
#   --json                  Output drift report as JSON
#   --output <file>         Write report to file
#   --fail-on-drift         Exit with code 2 if drift is detected (for CI)
#   --notify <webhook-url>  POST drift summary to a webhook (Slack-compatible)
#   -h, --help              Show this help
#
# Examples:
#   ./drift-detector.sh --stack prod
#   ./drift-detector.sh --stack prod --fail-on-drift --json --output drift.json
#   ./drift-detector.sh --stack prod --notify https://hooks.slack.com/services/T.../B.../xxx

set -euo pipefail

# ---------- defaults ----------
STACK=""
JSON_OUTPUT=false
OUTPUT_FILE=""
FAIL_ON_DRIFT=false
WEBHOOK_URL=""

# ---------- colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# ---------- usage ----------
usage() {
    sed -n '2,/^$/s/^# \?//p' "$0"
    exit 0
}

# ---------- parse args ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack)          STACK="$2"; shift 2 ;;
        --json)           JSON_OUTPUT=true; shift ;;
        --output)         OUTPUT_FILE="$2"; shift 2 ;;
        --fail-on-drift)  FAIL_ON_DRIFT=true; shift ;;
        --notify)         WEBHOOK_URL="$2"; shift 2 ;;
        -h|--help)        usage ;;
        *)                die "Unknown option: $1" ;;
    esac
done

# ---------- preflight ----------
command -v pulumi >/dev/null 2>&1 || die "pulumi CLI not found."

# ---------- select stack ----------
if [[ -n "$STACK" ]]; then
    info "Selecting stack '${STACK}'..."
    pulumi stack select "$STACK" 2>/dev/null || die "Stack '${STACK}' not found."
else
    STACK=$(pulumi stack --show-name 2>/dev/null || echo "unknown")
    info "Using current stack: ${STACK}"
fi

# ---------- run refresh --diff ----------
info "Detecting drift on stack '${STACK}'..."
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

REFRESH_TMPFILE=$(mktemp)
trap 'rm -f "$REFRESH_TMPFILE"' EXIT

DRIFT_DETECTED=false
REFRESH_EXIT=0

pulumi refresh --diff --expect-no-changes --show-replacement-steps \
    --non-interactive --yes 2>&1 | tee "$REFRESH_TMPFILE" || REFRESH_EXIT=$?

# ---------- parse results ----------
TOTAL_CHANGES=0
RESOURCES_UPDATED=0
RESOURCES_CREATED=0
RESOURCES_DELETED=0

if grep -q "resources updated" "$REFRESH_TMPFILE" 2>/dev/null; then
    RESOURCES_UPDATED=$(grep -oP '\d+(?= resource[s]? updated)' "$REFRESH_TMPFILE" || echo 0)
    DRIFT_DETECTED=true
fi
if grep -q "resources created" "$REFRESH_TMPFILE" 2>/dev/null; then
    RESOURCES_CREATED=$(grep -oP '\d+(?= resource[s]? created)' "$REFRESH_TMPFILE" || echo 0)
    DRIFT_DETECTED=true
fi
if grep -q "resources deleted" "$REFRESH_TMPFILE" 2>/dev/null; then
    RESOURCES_DELETED=$(grep -oP '\d+(?= resource[s]? deleted)' "$REFRESH_TMPFILE" || echo 0)
    DRIFT_DETECTED=true
fi

# Also check for "changes" or "diff" in output
if grep -qiE '^\s*(~|\+|-)' "$REFRESH_TMPFILE" 2>/dev/null; then
    DRIFT_DETECTED=true
fi

TOTAL_CHANGES=$((RESOURCES_UPDATED + RESOURCES_CREATED + RESOURCES_DELETED))

# Extract drifted resource URNs
DRIFTED_RESOURCES=()
while IFS= read -r line; do
    [[ -n "$line" ]] && DRIFTED_RESOURCES+=("$line")
done < <(grep -oP 'urn:pulumi:[^\s]+' "$REFRESH_TMPFILE" 2>/dev/null | sort -u || true)

# ---------- report ----------
if [[ "$DRIFT_DETECTED" == true ]]; then
    warn "DRIFT DETECTED on stack '${STACK}'"
    echo ""
    echo "  Updated:  ${RESOURCES_UPDATED}"
    echo "  Created:  ${RESOURCES_CREATED} (exist in cloud but not in state)"
    echo "  Deleted:  ${RESOURCES_DELETED} (in state but not in cloud)"
    echo "  Total:    ${TOTAL_CHANGES}"
    echo ""

    if [[ ${#DRIFTED_RESOURCES[@]} -gt 0 ]]; then
        echo "Affected resources:"
        for urn in "${DRIFTED_RESOURCES[@]}"; do
            echo "  - $urn"
        done
    fi
else
    info "No drift detected on stack '${STACK}'. Infrastructure matches state."
fi

# ---------- JSON output ----------
if [[ "$JSON_OUTPUT" == true ]] || [[ -n "$OUTPUT_FILE" ]]; then
    DRIFTED_JSON="[]"
    if [[ ${#DRIFTED_RESOURCES[@]} -gt 0 ]]; then
        DRIFTED_JSON=$(printf '%s\n' "${DRIFTED_RESOURCES[@]}" | jq -R . | jq -s .)
    fi

    JSON_REPORT=$(cat <<EOF
{
    "timestamp": "${TIMESTAMP}",
    "stack": "${STACK}",
    "drift_detected": ${DRIFT_DETECTED},
    "summary": {
        "updated": ${RESOURCES_UPDATED},
        "created": ${RESOURCES_CREATED},
        "deleted": ${RESOURCES_DELETED},
        "total_changes": ${TOTAL_CHANGES}
    },
    "affected_resources": ${DRIFTED_JSON}
}
EOF
)

    if [[ "$JSON_OUTPUT" == true ]]; then
        echo "$JSON_REPORT"
    fi

    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$JSON_REPORT" > "$OUTPUT_FILE"
        info "Report written to ${OUTPUT_FILE}"
    fi
fi

# ---------- webhook notification ----------
if [[ -n "$WEBHOOK_URL" ]] && [[ "$DRIFT_DETECTED" == true ]]; then
    info "Sending drift notification to webhook..."

    RESOURCE_LIST=""
    for urn in "${DRIFTED_RESOURCES[@]:0:10}"; do
        short_urn=$(echo "$urn" | grep -oP '[^:]+$' || echo "$urn")
        RESOURCE_LIST="${RESOURCE_LIST}\n• ${short_urn}"
    done
    [[ ${#DRIFTED_RESOURCES[@]} -gt 10 ]] && RESOURCE_LIST="${RESOURCE_LIST}\n• ... and $((${#DRIFTED_RESOURCES[@]} - 10)) more"

    SLACK_PAYLOAD=$(cat <<EOF
{
    "text": ":warning: Infrastructure drift detected",
    "blocks": [
        {
            "type": "header",
            "text": { "type": "plain_text", "text": "Infrastructure Drift Detected" }
        },
        {
            "type": "section",
            "fields": [
                { "type": "mrkdwn", "text": "*Stack:*\n${STACK}" },
                { "type": "mrkdwn", "text": "*Time:*\n${TIMESTAMP}" },
                { "type": "mrkdwn", "text": "*Changes:*\n${TOTAL_CHANGES}" },
                { "type": "mrkdwn", "text": "*Updated:* ${RESOURCES_UPDATED} | *Created:* ${RESOURCES_CREATED} | *Deleted:* ${RESOURCES_DELETED}" }
            ]
        }
    ]
}
EOF
)

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST -H "Content-Type: application/json" \
        -d "$SLACK_PAYLOAD" "$WEBHOOK_URL" || true)

    if [[ "$HTTP_CODE" == "200" ]]; then
        info "Webhook notification sent successfully."
    else
        warn "Webhook notification failed (HTTP ${HTTP_CODE})."
    fi
fi

# ---------- exit code ----------
if [[ "$FAIL_ON_DRIFT" == true ]] && [[ "$DRIFT_DETECTED" == true ]]; then
    error "Drift detected — exiting with code 2 (--fail-on-drift enabled)."
    exit 2
fi

exit 0
