#!/usr/bin/env bash
#
# lambda-optimize.sh — Analyze Lambda function configuration and suggest optimizations
#
# USAGE:
#   ./lambda-optimize.sh --function <name-or-arn> [OPTIONS]
#
# OPTIONS:
#   --function   REQUIRED  Lambda function name or full ARN
#   --region     AWS region (default: AWS_DEFAULT_REGION or us-east-1)
#   --profile    AWS CLI named profile to use
#   --help       Show this help message and exit
#
# DESCRIPTION:
#   Fetches the configuration and recent CloudWatch metrics for a Lambda function,
#   then produces actionable recommendations across these categories:
#     - Memory configuration (over/under-provisioned)
#     - Timeout settings (too high or too low vs actual duration)
#     - Runtime version (deprecated or nearing EOL)
#     - Architecture (arm64 vs x86_64 cost/performance)
#     - Code package size
#     - Concurrency (reserved / provisioned)
#     - VPC configuration overhead
#     - X-Ray tracing
#     - Ephemeral storage
#     - Environment variables count
#   Each finding has a severity: INFO, WARN, or CRITICAL.
#   A summary score (0-100) is printed at the end.
#
# EXAMPLES:
#   ./lambda-optimize.sh --function my-api-handler
#   ./lambda-optimize.sh --function arn:aws:lambda:us-west-2:123456789012:function:processor --region us-west-2
#   ./lambda-optimize.sh --function order-service --profile production --region eu-west-1
#

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info_msg()  { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn_msg()  { printf "  ${YELLOW}⚠${RESET} %s\n" "$*"; }
crit_msg()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
section()   { printf "\n${BOLD}${CYAN}── %s ──${RESET}\n" "$*"; }

# ── Tracking ──────────────────────────────────────────────────────────────────
SCORE=100
INFO_COUNT=0
WARN_COUNT=0
CRIT_COUNT=0

add_info()     { INFO_COUNT=$((INFO_COUNT + 1)); info_msg "[INFO] $*"; }
add_warn()     { WARN_COUNT=$((WARN_COUNT + 1)); SCORE=$((SCORE - 5)); warn_msg "[WARN] $*"; }
add_critical() { CRIT_COUNT=$((CRIT_COUNT + 1)); SCORE=$((SCORE - 15)); crit_msg "[CRITICAL] $*"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
FUNCTION_NAME=""
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"
PROFILE=""

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 0
}

# ── Parse Arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --function)  FUNCTION_NAME="$2"; shift 2 ;;
        --region)    REGION="$2";        shift 2 ;;
        --profile)   PROFILE="$2";       shift 2 ;;
        --help|-h)   usage ;;
        *) printf "${RED}Unknown option: %s${RESET}\n" "$1" >&2; usage ;;
    esac
done

if [[ -z "$FUNCTION_NAME" ]]; then
    printf "${RED}[ERROR] --function is required.${RESET}\n" >&2
    usage
fi

# ── Prerequisite checks ──────────────────────────────────────────────────────
for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
        printf "${RED}[ERROR] Required tool '%s' is not installed.${RESET}\n" "$cmd" >&2
        exit 1
    fi
done

# ── AWS CLI helper ────────────────────────────────────────────────────────────
aws_cmd() {
    local args=("$@")
    if [[ -n "$PROFILE" ]]; then
        aws --region "$REGION" --profile "$PROFILE" --output json "${args[@]}"
    else
        aws --region "$REGION" --output json "${args[@]}"
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}╭──────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${CYAN}│   Lambda Optimization Analyzer            │${RESET}\n"
printf "${BOLD}${CYAN}╰──────────────────────────────────────────╯${RESET}\n\n"
printf "  Function : ${BOLD}%s${RESET}\n" "$FUNCTION_NAME"
printf "  Region   : %s\n" "$REGION"
[[ -n "$PROFILE" ]] && printf "  Profile  : %s\n" "$PROFILE"

# ── Fetch function configuration ─────────────────────────────────────────────
section "Fetching configuration"
CONFIG=$(aws_cmd lambda get-function-configuration --function-name "$FUNCTION_NAME" 2>&1) || {
    printf "${RED}[ERROR] Failed to get function configuration:${RESET}\n%s\n" "$CONFIG" >&2
    exit 1
}
printf "  ${GREEN}✓${RESET} Configuration retrieved\n"

# Extract fields
RUNTIME=$(echo "$CONFIG" | jq -r '.Runtime // "custom"')
MEMORY=$(echo "$CONFIG" | jq -r '.MemorySize')
TIMEOUT=$(echo "$CONFIG" | jq -r '.Timeout')
CODE_SIZE=$(echo "$CONFIG" | jq -r '.CodeSize')
ARCH=$(echo "$CONFIG" | jq -r '.Architectures[0] // "x86_64"')
HANDLER=$(echo "$CONFIG" | jq -r '.Handler // "N/A"')
LAST_MODIFIED=$(echo "$CONFIG" | jq -r '.LastModified')
VPC_SUBNETS=$(echo "$CONFIG" | jq -r '.VpcConfig.SubnetIds // [] | length')
TRACING_MODE=$(echo "$CONFIG" | jq -r '.TracingConfig.Mode // "PassThrough"')
EPHEMERAL_SIZE=$(echo "$CONFIG" | jq -r '.EphemeralStorage.Size // 512')
ENV_VAR_COUNT=$(echo "$CONFIG" | jq -r '.Environment.Variables // {} | length')
LAYERS_COUNT=$(echo "$CONFIG" | jq -r '.Layers // [] | length')

CODE_SIZE_MB=$(awk "BEGIN { printf \"%.1f\", $CODE_SIZE / 1048576 }")

printf "  Runtime       : %s\n" "$RUNTIME"
printf "  Memory        : %s MB\n" "$MEMORY"
printf "  Timeout       : %s s\n" "$TIMEOUT"
printf "  Architecture  : %s\n" "$ARCH"
printf "  Code size     : %s MB\n" "$CODE_SIZE_MB"
printf "  Last modified : %s\n" "$LAST_MODIFIED"

# ── Fetch concurrency settings ───────────────────────────────────────────────
RESERVED_CONCURRENCY="none"
CONCURRENCY_JSON=$(aws_cmd lambda get-function-concurrency --function-name "$FUNCTION_NAME" 2>/dev/null || echo "{}")
RC_VAL=$(echo "$CONCURRENCY_JSON" | jq -r '.ReservedConcurrentExecutions // empty')
[[ -n "$RC_VAL" ]] && RESERVED_CONCURRENCY="$RC_VAL"

PROVISIONED_CONCURRENCY="none"
PC_JSON=$(aws_cmd lambda list-provisioned-concurrency-configs --function-name "$FUNCTION_NAME" 2>/dev/null || echo '{"ProvisionedConcurrencyConfigs":[]}')
PC_TOTAL=$(echo "$PC_JSON" | jq '[.ProvisionedConcurrencyConfigs[]? | .AllocatedProvisionedConcurrentExecutions // 0] | add // 0')
[[ "$PC_TOTAL" -gt 0 ]] && PROVISIONED_CONCURRENCY="$PC_TOTAL"

# ── Fetch CloudWatch metrics (last 7 days) ────────────────────────────────────
section "Fetching CloudWatch metrics (last 7 days)"
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || echo "")

if [[ -z "$START_TIME" ]]; then
    START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    warn_msg "Could not compute start time; metrics may be empty"
fi

get_metric() {
    local metric_name="$1" stat="$2"
    aws_cmd cloudwatch get-metric-statistics \
        --namespace AWS/Lambda \
        --metric-name "$metric_name" \
        --dimensions "Name=FunctionName,Value=$FUNCTION_NAME" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period 86400 \
        --statistics "$stat" 2>/dev/null || echo '{"Datapoints":[]}'
}

INVOCATIONS_JSON=$(get_metric Invocations Sum)
ERRORS_JSON=$(get_metric Errors Sum)
DURATION_JSON=$(get_metric Duration Average)
DURATION_MAX_JSON=$(get_metric Duration Maximum)
THROTTLES_JSON=$(get_metric Throttles Sum)

TOTAL_INVOCATIONS=$(echo "$INVOCATIONS_JSON" | jq '[.Datapoints[]?.Sum // 0] | add // 0' | awk '{printf "%.0f", $1}')
TOTAL_ERRORS=$(echo "$ERRORS_JSON" | jq '[.Datapoints[]?.Sum // 0] | add // 0' | awk '{printf "%.0f", $1}')
AVG_DURATION=$(echo "$DURATION_JSON" | jq '[.Datapoints[]?.Average // 0] | if length > 0 then add / length else 0 end' | awk '{printf "%.1f", $1}')
MAX_DURATION=$(echo "$DURATION_MAX_JSON" | jq '[.Datapoints[]?.Maximum // 0] | max // 0' | awk '{printf "%.1f", $1}')
TOTAL_THROTTLES=$(echo "$THROTTLES_JSON" | jq '[.Datapoints[]?.Sum // 0] | add // 0' | awk '{printf "%.0f", $1}')

ERROR_RATE="0"
if [[ "$TOTAL_INVOCATIONS" -gt 0 ]]; then
    ERROR_RATE=$(awk "BEGIN { printf \"%.2f\", ($TOTAL_ERRORS / $TOTAL_INVOCATIONS) * 100 }")
fi

printf "  Invocations   : %s\n" "$TOTAL_INVOCATIONS"
printf "  Errors        : %s (%.2f%%)\n" "$TOTAL_ERRORS" "$ERROR_RATE"
printf "  Avg duration  : %s ms\n" "$AVG_DURATION"
printf "  Max duration  : %s ms\n" "$MAX_DURATION"
printf "  Throttles     : %s\n" "$TOTAL_THROTTLES"

# ── Analysis ──────────────────────────────────────────────────────────────────
section "Memory Configuration"
if [[ "$MEMORY" -le 128 ]]; then
    add_warn "Memory is only ${MEMORY} MB. This may cause slow cold starts and OOM errors."
elif [[ "$MEMORY" -ge 3008 ]]; then
    add_warn "Memory is ${MEMORY} MB — verify this is needed. Over-provisioning wastes cost."
else
    add_info "Memory is ${MEMORY} MB — within typical range."
fi
if [[ "$TOTAL_INVOCATIONS" -gt 0 ]]; then
    TIMEOUT_MS=$(awk "BEGIN { print $TIMEOUT * 1000 }")
    DURATION_RATIO=$(awk "BEGIN { printf \"%.0f\", ($AVG_DURATION / $TIMEOUT_MS) * 100 }")
    if [[ "$DURATION_RATIO" -lt 5 ]] && [[ "$MEMORY" -ge 512 ]]; then
        add_info "Avg duration is only ${DURATION_RATIO}% of timeout. Consider reducing memory to save cost."
    fi
fi

section "Timeout Settings"
if [[ "$TIMEOUT" -ge 900 ]]; then
    add_warn "Timeout is maximum (${TIMEOUT}s). Consider reducing to catch runaway executions."
elif [[ "$TIMEOUT" -le 3 ]]; then
    add_warn "Timeout is very low (${TIMEOUT}s). May cause premature failures under load."
else
    add_info "Timeout is ${TIMEOUT}s."
fi
if [[ "$TOTAL_INVOCATIONS" -gt 0 ]]; then
    MAX_DUR_S=$(awk "BEGIN { printf \"%.0f\", $MAX_DURATION / 1000 }")
    TIMEOUT_HEADROOM=$(awk "BEGIN { printf \"%.0f\", (($TIMEOUT * 1000 - $MAX_DURATION) / ($TIMEOUT * 1000)) * 100 }")
    if [[ "$TIMEOUT_HEADROOM" -lt 10 ]] && [[ "$TIMEOUT_HEADROOM" -ge 0 ]]; then
        add_critical "Max duration (${MAX_DUR_S}s) is within 10% of timeout (${TIMEOUT}s). Risk of timeouts."
    elif [[ "$TIMEOUT_HEADROOM" -gt 90 ]]; then
        add_info "Timeout has >90% headroom. You could lower it to ${MAX_DUR_S}s + buffer."
    fi
fi

section "Runtime Version"
DEPRECATED_RUNTIMES="python2.7 python3.6 python3.7 nodejs8.10 nodejs10.x nodejs12.x nodejs14.x nodejs16.x dotnetcore2.1 dotnetcore3.1 dotnet5.0 ruby2.5 ruby2.7 java8 go1.x"
EOL_SOON_RUNTIMES="python3.8 python3.9 nodejs18.x dotnet6 java11"
if echo "$DEPRECATED_RUNTIMES" | grep -qw "$RUNTIME"; then
    add_critical "Runtime '$RUNTIME' is deprecated. Migrate immediately to avoid security risks."
elif echo "$EOL_SOON_RUNTIMES" | grep -qw "$RUNTIME"; then
    add_warn "Runtime '$RUNTIME' is approaching end-of-life. Plan a migration."
elif [[ "$RUNTIME" == "custom" ]] || [[ "$RUNTIME" == "provided"* ]]; then
    add_info "Custom runtime detected. Ensure you keep the runtime updated."
else
    add_info "Runtime '$RUNTIME' is current."
fi

section "Architecture"
if [[ "$ARCH" == "x86_64" ]]; then
    add_warn "Using x86_64. Switching to arm64 (Graviton2) can reduce cost by ~20% and improve performance."
else
    add_info "Using arm64 (Graviton2) — optimal price/performance."
fi

section "Code Size"
CODE_SIZE_INT=${CODE_SIZE_MB%.*}
if [[ "$CODE_SIZE_INT" -ge 200 ]]; then
    add_critical "Code package is ${CODE_SIZE_MB} MB (near 250 MB limit). Reduce dependencies or use layers."
elif [[ "$CODE_SIZE_INT" -ge 50 ]]; then
    add_warn "Code package is ${CODE_SIZE_MB} MB. Consider tree-shaking or Lambda layers to reduce size."
else
    add_info "Code package is ${CODE_SIZE_MB} MB — within healthy range."
fi
if [[ "$LAYERS_COUNT" -gt 3 ]]; then
    add_warn "Using $LAYERS_COUNT layers. Each layer adds cold start latency."
fi

section "Concurrency"
if [[ "$RESERVED_CONCURRENCY" == "none" ]]; then
    add_warn "No reserved concurrency set. Function shares the account pool and can be throttled by other functions."
elif [[ "$RESERVED_CONCURRENCY" == "0" ]]; then
    add_critical "Reserved concurrency is 0 — function is effectively disabled!"
else
    add_info "Reserved concurrency: $RESERVED_CONCURRENCY"
fi
if [[ "$PROVISIONED_CONCURRENCY" != "none" ]]; then
    add_info "Provisioned concurrency: $PROVISIONED_CONCURRENCY — eliminates cold starts."
else
    if [[ "$TOTAL_INVOCATIONS" -gt 100000 ]]; then
        add_info "High invocation volume. Consider provisioned concurrency to reduce cold starts."
    fi
fi
if [[ "$TOTAL_THROTTLES" -gt 0 ]]; then
    add_critical "Function was throttled $TOTAL_THROTTLES times. Increase reserved concurrency or request a limit increase."
fi

section "VPC Configuration"
if [[ "$VPC_SUBNETS" -gt 0 ]]; then
    add_warn "Function is in a VPC ($VPC_SUBNETS subnets). VPC adds cold start latency (~1-2s). Ensure this is necessary."
else
    add_info "Not in a VPC — no additional cold start overhead."
fi

section "Tracing"
if [[ "$TRACING_MODE" == "PassThrough" ]]; then
    add_warn "X-Ray tracing is disabled. Enable Active tracing for better observability."
else
    add_info "X-Ray tracing is active."
fi

section "Ephemeral Storage"
if [[ "$EPHEMERAL_SIZE" -gt 512 ]]; then
    add_info "Ephemeral storage is ${EPHEMERAL_SIZE} MB (above default 512 MB). Ensure this is needed."
else
    add_info "Ephemeral storage is default (512 MB)."
fi

section "Environment Variables"
if [[ "$ENV_VAR_COUNT" -gt 20 ]]; then
    add_warn "Function has $ENV_VAR_COUNT environment variables. Consider using SSM Parameter Store or Secrets Manager for cleaner config."
elif [[ "$ENV_VAR_COUNT" -gt 0 ]]; then
    add_info "$ENV_VAR_COUNT environment variable(s) configured."
else
    add_info "No environment variables set."
fi

section "Error Rate"
if [[ "$TOTAL_INVOCATIONS" -gt 0 ]]; then
    ER_INT=${ERROR_RATE%.*}
    if [[ "$ER_INT" -ge 10 ]]; then
        add_critical "Error rate is ${ERROR_RATE}%. Investigate immediately."
    elif [[ "$ER_INT" -ge 2 ]]; then
        add_warn "Error rate is ${ERROR_RATE}%. Review CloudWatch Logs for root cause."
    else
        add_info "Error rate is ${ERROR_RATE}% — healthy."
    fi
else
    add_info "No invocations in the last 7 days — no error data."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
[[ $SCORE -lt 0 ]] && SCORE=0

echo ""
printf "${BOLD}${CYAN}╭──────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${CYAN}│   Optimization Summary                    │${RESET}\n"
printf "${BOLD}${CYAN}╰──────────────────────────────────────────╯${RESET}\n\n"

if [[ $SCORE -ge 80 ]]; then
    SCORE_COLOR="$GREEN"
    VERDICT="Excellent"
elif [[ $SCORE -ge 60 ]]; then
    SCORE_COLOR="$YELLOW"
    VERDICT="Needs Attention"
else
    SCORE_COLOR="$RED"
    VERDICT="Needs Work"
fi

printf "  ${BOLD}Score: ${SCORE_COLOR}%d/100${RESET} — ${SCORE_COLOR}%s${RESET}\n\n" "$SCORE" "$VERDICT"
printf "  ${GREEN}INFO${RESET}     : %d\n" "$INFO_COUNT"
printf "  ${YELLOW}WARN${RESET}     : %d\n" "$WARN_COUNT"
printf "  ${RED}CRITICAL${RESET} : %d\n" "$CRIT_COUNT"
echo ""

if [[ $CRIT_COUNT -gt 0 ]]; then
    printf "  ${RED}${BOLD}Address CRITICAL issues first to avoid outages or security risks.${RESET}\n"
elif [[ $WARN_COUNT -gt 0 ]]; then
    printf "  ${YELLOW}Review warnings to improve cost, performance, and reliability.${RESET}\n"
else
    printf "  ${GREEN}${BOLD}Great job! Your Lambda configuration looks well optimized.${RESET}\n"
fi
echo ""
