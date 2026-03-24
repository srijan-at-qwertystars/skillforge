#!/usr/bin/env bash
#
# lambda-local-test.sh — Test AWS Lambda functions locally using SAM CLI
#
# USAGE:
#   ./lambda-local-test.sh --function <LogicalId> --event <event-file> [OPTIONS]
#   ./lambda-local-test.sh --generate <event-type> [--function <LogicalId>]
#   ./lambda-local-test.sh --api [OPTIONS]
#
# OPTIONS:
#   --function        Lambda function logical ID (from template.yaml, default: first function found)
#   --event           Path to JSON event file to use for invocation
#   --generate        Generate a sample event: api, sqs, s3, sns, dynamodb, schedule
#   --api             Start a local API Gateway (sam local start-api)
#   --docker-network  Docker network for SAM containers to join
#   --env-vars        Path to JSON file with environment variable overrides
#   --help            Show this help message and exit
#
# DESCRIPTION:
#   Wraps AWS SAM CLI to simplify local Lambda testing workflows:
#     1. Generate sample events for common triggers and save to events/
#     2. Invoke a function locally with an event payload
#     3. Start a local API Gateway for HTTP-triggered functions
#   Checks for prerequisites (SAM CLI, Docker) and provides clear error messages.
#
# EXAMPLES:
#   ./lambda-local-test.sh --generate api
#   ./lambda-local-test.sh --function MyFunction --event events/api.json
#   ./lambda-local-test.sh --api --env-vars env.json --docker-network my-network
#   ./lambda-local-test.sh --generate sqs --function ProcessorFunction --event events/sqs.json
#

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "${BLUE}[INFO]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
err()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }

# ── Defaults ──────────────────────────────────────────────────────────────────
FUNCTION_ID=""
EVENT_FILE=""
GENERATE_TYPE=""
START_API=false
DOCKER_NETWORK=""
ENV_VARS=""

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

# ── Parse Arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --function)        FUNCTION_ID="$2";    shift 2 ;;
        --event)           EVENT_FILE="$2";     shift 2 ;;
        --generate)        GENERATE_TYPE="$2";  shift 2 ;;
        --api)             START_API=true;      shift ;;
        --docker-network)  DOCKER_NETWORK="$2"; shift 2 ;;
        --env-vars)        ENV_VARS="$2";       shift 2 ;;
        --help|-h)         usage ;;
        *) err "Unknown option: $1"; usage ;;
    esac
done

# ── Prerequisite checks ──────────────────────────────────────────────────────
check_prereqs() {
    local missing=0

    if ! command -v sam &>/dev/null; then
        err "SAM CLI is not installed."
        echo "    Install: https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html"
        missing=1
    else
        ok "SAM CLI found: $(sam --version 2>/dev/null || echo 'unknown')"
    fi

    if ! command -v docker &>/dev/null; then
        warn "Docker is not installed or not in PATH. SAM local requires Docker."
        echo "    Install: https://docs.docker.com/get-docker/"
        missing=1
    else
        if docker info &>/dev/null 2>&1; then
            ok "Docker is running"
        else
            warn "Docker is installed but not running. Please start Docker."
            missing=1
        fi
    fi

    if [[ $missing -ne 0 ]]; then
        err "Missing prerequisites. Please install them and retry."
        exit 1
    fi
}

# ── Locate SAM template ──────────────────────────────────────────────────────
find_template() {
    local candidates=("template.yaml" "template.yml" "sam.yaml" "sam.yml")
    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            echo "$f"
            return
        fi
    done
    err "No SAM template found. Expected one of: ${candidates[*]}"
    exit 1
}

# ── Auto-detect function logical ID from template ─────────────────────────────
detect_function_id() {
    local template="$1"
    # Grep for Type: AWS::Serverless::Function and grab the key above it
    local fn_id
    fn_id=$(grep -B1 'Type:\s*AWS::Serverless::Function' "$template" \
            | grep -v 'Type:' | grep -v '^--$' | head -1 \
            | sed 's/^[[:space:]]*//' | sed 's/:$//')
    if [[ -n "$fn_id" ]]; then
        echo "$fn_id"
    else
        echo ""
    fi
}

# ── Generate sample event ────────────────────────────────────────────────────
generate_event() {
    local event_type="$1"
    local valid_types="api sqs s3 sns dynamodb schedule"

    if ! echo "$valid_types" | grep -qw "$event_type"; then
        err "Invalid event type '$event_type'. Choose: $valid_types"
        exit 1
    fi

    mkdir -p events
    local outfile="events/${event_type}.json"

    info "Generating $event_type event → $outfile"

    case "$event_type" in
    api)
        cat > "$outfile" << 'EVTEOF'
{
  "httpMethod": "GET",
  "path": "/",
  "headers": {
    "Content-Type": "application/json",
    "Accept": "*/*"
  },
  "queryStringParameters": null,
  "pathParameters": null,
  "body": null,
  "isBase64Encoded": false,
  "requestContext": {
    "stage": "dev",
    "requestId": "test-request-id",
    "httpMethod": "GET",
    "path": "/"
  }
}
EVTEOF
        ;;
    sqs)
        cat > "$outfile" << 'EVTEOF'
{
  "Records": [
    {
      "messageId": "059f36b4-87a3-44ab-83d2-661975830a7d",
      "receiptHandle": "AQEBwJnKyrHigUMZj6rYigCgxlaS3SLy0a...",
      "body": "{\"action\":\"process\",\"id\":12345}",
      "attributes": {
        "ApproximateReceiveCount": "1",
        "SentTimestamp": "1545082649636",
        "SenderId": "AIDAIENQZJOLO23YVJ4VO",
        "ApproximateFirstReceiveTimestamp": "1545082649636"
      },
      "messageAttributes": {},
      "md5OfBody": "e4e68fb7bd0e697a0ae8f1bb342846b3",
      "eventSource": "aws:sqs",
      "eventSourceARN": "arn:aws:sqs:us-east-1:123456789012:MyQueue",
      "awsRegion": "us-east-1"
    }
  ]
}
EVTEOF
        ;;
    s3)
        cat > "$outfile" << 'EVTEOF'
{
  "Records": [
    {
      "eventVersion": "2.1",
      "eventSource": "aws:s3",
      "awsRegion": "us-east-1",
      "eventTime": "2024-01-15T12:00:00.000Z",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "bucket": {
          "name": "my-bucket",
          "arn": "arn:aws:s3:::my-bucket"
        },
        "object": {
          "key": "uploads/test-file.txt",
          "size": 1024,
          "eTag": "d41d8cd98f00b204e9800998ecf8427e"
        }
      }
    }
  ]
}
EVTEOF
        ;;
    sns)
        cat > "$outfile" << 'EVTEOF'
{
  "Records": [
    {
      "EventVersion": "1.0",
      "EventSource": "aws:sns",
      "Sns": {
        "Type": "Notification",
        "MessageId": "95df01b4-ee98-5cb9-9903-4c221d41eb5e",
        "TopicArn": "arn:aws:sns:us-east-1:123456789012:MyTopic",
        "Subject": "Test notification",
        "Message": "{\"action\":\"notify\",\"data\":\"hello\"}",
        "Timestamp": "2024-01-15T12:00:00.000Z"
      }
    }
  ]
}
EVTEOF
        ;;
    dynamodb)
        cat > "$outfile" << 'EVTEOF'
{
  "Records": [
    {
      "eventID": "1",
      "eventVersion": "1.1",
      "dynamodb": {
        "Keys": { "Id": { "N": "101" } },
        "NewImage": { "Id": { "N": "101" }, "Name": { "S": "test-item" } },
        "StreamViewType": "NEW_AND_OLD_IMAGES",
        "SequenceNumber": "111",
        "SizeBytes": 26
      },
      "awsRegion": "us-east-1",
      "eventName": "INSERT",
      "eventSourceARN": "arn:aws:dynamodb:us-east-1:123456789012:table/MyTable/stream/2024-01-15T00:00:00.000"
    }
  ]
}
EVTEOF
        ;;
    schedule)
        cat > "$outfile" << 'EVTEOF'
{
  "version": "0",
  "id": "53dc4d37-cffa-4f76-80c9-8b7d4a4d2eaa",
  "detail-type": "Scheduled Event",
  "source": "aws.events",
  "account": "123456789012",
  "time": "2024-01-15T12:00:00Z",
  "region": "us-east-1",
  "resources": [
    "arn:aws:events:us-east-1:123456789012:rule/my-scheduled-rule"
  ],
  "detail": {}
}
EVTEOF
        ;;
    esac

    ok "Event saved to $outfile ($(wc -c < "$outfile") bytes)"
}

# ── Build common SAM args ────────────────────────────────────────────────────
build_sam_args() {
    local args=""
    if [[ -n "$DOCKER_NETWORK" ]]; then
        args+=" --docker-network $DOCKER_NETWORK"
    fi
    if [[ -n "$ENV_VARS" ]]; then
        if [[ ! -f "$ENV_VARS" ]]; then
            err "Environment vars file not found: $ENV_VARS"
            exit 1
        fi
        args+=" --env-vars $ENV_VARS"
    fi
    echo "$args"
}

# ── Invoke function locally ──────────────────────────────────────────────────
invoke_local() {
    local template fn_id event sam_extra

    template=$(find_template)
    info "Using template: $template"

    fn_id="$FUNCTION_ID"
    if [[ -z "$fn_id" ]]; then
        fn_id=$(detect_function_id "$template")
        if [[ -z "$fn_id" ]]; then
            err "Could not detect function ID. Use --function to specify it."
            exit 1
        fi
        info "Auto-detected function: $fn_id"
    fi

    event="$EVENT_FILE"
    if [[ -z "$event" ]]; then
        err "No event file specified. Use --event <path> or --generate <type> first."
        exit 1
    fi
    if [[ ! -f "$event" ]]; then
        err "Event file not found: $event"
        exit 1
    fi

    sam_extra=$(build_sam_args)

    info "Building function..."
    sam build --template-file "$template" 2>&1 | while IFS= read -r line; do
        printf "  ${CYAN}│${RESET} %s\n" "$line"
    done

    echo ""
    info "Invoking $fn_id with event $event"
    printf "${BOLD}${CYAN}── Function Output ─────────────────────────────────${RESET}\n"

    # shellcheck disable=SC2086
    sam local invoke "$fn_id" \
        --template-file "$template" \
        --event "$event" \
        $sam_extra 2>&1

    printf "${BOLD}${CYAN}────────────────────────────────────────────────────${RESET}\n"
    ok "Invocation complete"
}

# ── Start local API ──────────────────────────────────────────────────────────
start_local_api() {
    local template sam_extra

    template=$(find_template)
    info "Using template: $template"

    sam_extra=$(build_sam_args)

    info "Building for local API..."
    sam build --template-file "$template" 2>&1 | while IFS= read -r line; do
        printf "  ${CYAN}│${RESET} %s\n" "$line"
    done

    echo ""
    info "Starting local API Gateway..."
    info "Press Ctrl+C to stop"
    printf "${BOLD}${GREEN}── Local API Gateway ───────────────────────────────${RESET}\n"

    # shellcheck disable=SC2086
    sam local start-api \
        --template-file "$template" \
        $sam_extra

    printf "${BOLD}${GREEN}────────────────────────────────────────────────────${RESET}\n"
}

# ── Main ──────────────────────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}╭──────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${CYAN}│   Lambda Local Testing                    │${RESET}\n"
printf "${BOLD}${CYAN}╰──────────────────────────────────────────╯${RESET}\n\n"

check_prereqs

# No action specified
if [[ -z "$GENERATE_TYPE" ]] && [[ "$START_API" == false ]] && [[ -z "$EVENT_FILE" ]]; then
    warn "No action specified. Use --generate, --event, or --api."
    echo ""
    usage
fi

# Generate event if requested
if [[ -n "$GENERATE_TYPE" ]]; then
    generate_event "$GENERATE_TYPE"
    # If no --event was given but generate was, auto-set it
    if [[ -z "$EVENT_FILE" ]] && [[ "$START_API" == false ]]; then
        EVENT_FILE="events/${GENERATE_TYPE}.json"
        info "Auto-set event file to: $EVENT_FILE"
    fi
fi

# Start API mode
if [[ "$START_API" == true ]]; then
    start_local_api
    exit 0
fi

# Invoke if we have an event file
if [[ -n "$EVENT_FILE" ]]; then
    invoke_local
fi

echo ""
ok "Done!"
