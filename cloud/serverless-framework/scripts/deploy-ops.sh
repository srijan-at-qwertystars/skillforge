#!/usr/bin/env bash
# =============================================================================
# deploy-ops.sh — Serverless Framework deployment and operations helper
# =============================================================================
#
# Usage:
#   ./deploy-ops.sh <command> [options]
#
# Commands:
#   deploy       Full stack deployment (or single function with -f)
#   remove       Remove deployed stack
#   invoke       Invoke a function (remote or local)
#   logs         View or tail function logs
#   info         Show deployed service info
#   print        Print resolved serverless.yml configuration
#   package      Package service without deploying
#   rollback     Rollback to previous deployment
#   prune        Remove old Lambda function versions
#
# Options:
#   -s, --stage    Stage name (default: dev)
#   -r, --region   AWS region (default: from serverless.yml)
#   -f, --function Function name (for deploy/invoke/logs)
#   -d, --data     Invocation data (JSON string)
#   -p, --path     Event file path (for invoke)
#   -l, --local    Invoke locally instead of remotely
#   --tail         Tail logs in real-time
#   --verbose      Verbose output
#   --force        Force deployment
#   --dry-run      Package only, don't deploy
#   --profile      AWS profile to use
#
# Examples:
#   ./deploy-ops.sh deploy -s prod
#   ./deploy-ops.sh deploy -s dev -f myFunction
#   ./deploy-ops.sh invoke -f hello -d '{"key":"value"}' -s dev
#   ./deploy-ops.sh invoke -f hello -p events/test.json --local
#   ./deploy-ops.sh logs -f hello -s prod --tail
#   ./deploy-ops.sh info -s prod
#   ./deploy-ops.sh remove -s dev
#   ./deploy-ops.sh prune -s prod --keep 3
# =============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Defaults ---
COMMAND=""
STAGE="dev"
REGION=""
FUNCTION=""
DATA=""
EVENT_PATH=""
LOCAL=false
TAIL=false
VERBOSE=false
FORCE=false
DRY_RUN=false
AWS_PROFILE_OPT=""
KEEP_VERSIONS=5

# --- Parse arguments ---
if [[ $# -lt 1 ]]; then
  echo -e "${RED}Error: No command provided${NC}"
  echo "Usage: $0 <command> [options]"
  echo "Commands: deploy, remove, invoke, logs, info, print, package, rollback, prune"
  exit 1
fi

COMMAND="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--stage) STAGE="$2"; shift 2 ;;
    -r|--region) REGION="$2"; shift 2 ;;
    -f|--function) FUNCTION="$2"; shift 2 ;;
    -d|--data) DATA="$2"; shift 2 ;;
    -p|--path) EVENT_PATH="$2"; shift 2 ;;
    -l|--local) LOCAL=true; shift ;;
    --tail) TAIL=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --profile) AWS_PROFILE_OPT="--aws-profile $2"; shift 2 ;;
    --keep) KEEP_VERSIONS="$2"; shift 2 ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
  esac
done

# --- Build common flags ---
COMMON_FLAGS="--stage $STAGE"
[[ -n "$REGION" ]] && COMMON_FLAGS="$COMMON_FLAGS --region $REGION"
[[ -n "$AWS_PROFILE_OPT" ]] && COMMON_FLAGS="$COMMON_FLAGS $AWS_PROFILE_OPT"
[[ "$VERBOSE" == true ]] && COMMON_FLAGS="$COMMON_FLAGS --verbose"

# --- Check serverless.yml exists ---
check_config() {
  if [[ ! -f "serverless.yml" && ! -f "serverless.yaml" && ! -f "serverless.ts" ]]; then
    echo -e "${RED}Error: No serverless.yml found in current directory${NC}"
    exit 1
  fi
}

# --- Confirm destructive operations ---
confirm() {
  local msg="$1"
  echo -e "${YELLOW}⚠️  $msg${NC}"
  read -r -p "Continue? [y/N] " response
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
}

# --- Timer ---
timer_start() { START_TIME=$(date +%s); }
timer_end() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  echo -e "${BLUE}⏱  Completed in ${elapsed}s${NC}"
}

# --- Commands ---

cmd_deploy() {
  check_config
  timer_start

  if [[ -n "$FUNCTION" ]]; then
    echo -e "${GREEN}🚀 Deploying function '$FUNCTION' to stage '$STAGE'...${NC}"
    # shellcheck disable=SC2086
    serverless deploy function -f "$FUNCTION" $COMMON_FLAGS
  elif [[ "$DRY_RUN" == true ]]; then
    echo -e "${GREEN}📦 Packaging (dry-run) for stage '$STAGE'...${NC}"
    # shellcheck disable=SC2086
    serverless package $COMMON_FLAGS
  else
    if [[ "$STAGE" == "prod" ]]; then
      confirm "Deploying to PRODUCTION"
    fi
    echo -e "${GREEN}🚀 Deploying full stack to stage '$STAGE'...${NC}"
    local flags="$COMMON_FLAGS"
    [[ "$FORCE" == true ]] && flags="$flags --force"
    # shellcheck disable=SC2086
    serverless deploy $flags
  fi

  timer_end
}

cmd_remove() {
  check_config

  if [[ "$STAGE" == "prod" ]]; then
    confirm "You are about to REMOVE the PRODUCTION stack. This is irreversible!"
  else
    confirm "Removing stack for stage '$STAGE'"
  fi

  timer_start
  echo -e "${RED}🗑️  Removing stack for stage '$STAGE'...${NC}"
  # shellcheck disable=SC2086
  serverless remove $COMMON_FLAGS
  timer_end
}

cmd_invoke() {
  check_config

  if [[ -z "$FUNCTION" ]]; then
    echo -e "${RED}Error: --function/-f is required for invoke${NC}"
    exit 1
  fi

  local invoke_type="invoke"
  [[ "$LOCAL" == true ]] && invoke_type="invoke local"

  echo -e "${GREEN}⚡ Invoking '$FUNCTION' ($( [[ "$LOCAL" == true ]] && echo 'local' || echo "remote / $STAGE" ))...${NC}"

  local flags="$COMMON_FLAGS"
  [[ -n "$DATA" ]] && flags="$flags -d '$DATA'"
  [[ -n "$EVENT_PATH" ]] && flags="$flags -p $EVENT_PATH"
  flags="$flags --log"

  # shellcheck disable=SC2086
  eval serverless $invoke_type -f "$FUNCTION" $flags
}

cmd_logs() {
  check_config

  if [[ -z "$FUNCTION" ]]; then
    echo -e "${RED}Error: --function/-f is required for logs${NC}"
    exit 1
  fi

  echo -e "${GREEN}📋 Fetching logs for '$FUNCTION' (stage: $STAGE)...${NC}"

  local flags="$COMMON_FLAGS"
  [[ "$TAIL" == true ]] && flags="$flags --tail"

  # shellcheck disable=SC2086
  serverless logs -f "$FUNCTION" $flags
}

cmd_info() {
  check_config
  echo -e "${GREEN}ℹ️  Service info (stage: $STAGE)...${NC}"
  # shellcheck disable=SC2086
  serverless info $COMMON_FLAGS
}

cmd_print() {
  check_config
  echo -e "${GREEN}📝 Resolved configuration (stage: $STAGE)...${NC}"
  # shellcheck disable=SC2086
  serverless print $COMMON_FLAGS
}

cmd_package() {
  check_config
  timer_start
  echo -e "${GREEN}📦 Packaging for stage '$STAGE'...${NC}"
  # shellcheck disable=SC2086
  serverless package $COMMON_FLAGS
  echo ""
  echo "Package artifacts:"
  ls -lhS .serverless/*.zip 2>/dev/null || echo "No zip artifacts found."
  timer_end
}

cmd_rollback() {
  check_config

  echo -e "${GREEN}📜 Available deployments for stage '$STAGE':${NC}"
  # shellcheck disable=SC2086
  serverless deploy list $COMMON_FLAGS

  echo ""
  read -r -p "Enter timestamp to rollback to: " timestamp
  if [[ -z "$timestamp" ]]; then
    echo "Aborted."
    exit 0
  fi

  confirm "Rolling back stage '$STAGE' to timestamp '$timestamp'"

  timer_start
  # shellcheck disable=SC2086
  serverless rollback --timestamp "$timestamp" $COMMON_FLAGS
  timer_end
}

cmd_prune() {
  check_config

  echo -e "${GREEN}🧹 Pruning old Lambda versions (keeping last $KEEP_VERSIONS)...${NC}"

  if command -v npx &>/dev/null && npm ls serverless-prune-plugin 2>/dev/null | grep -q serverless-prune-plugin; then
    # shellcheck disable=SC2086
    serverless prune -n "$KEEP_VERSIONS" $COMMON_FLAGS
  else
    echo -e "${YELLOW}Note: serverless-prune-plugin not installed.${NC}"
    echo "Install with: npm i -D serverless-prune-plugin"
    echo "Then add to plugins in serverless.yml"
  fi
}

# --- Dispatch ---
case "$COMMAND" in
  deploy)   cmd_deploy ;;
  remove)   cmd_remove ;;
  invoke)   cmd_invoke ;;
  logs)     cmd_logs ;;
  info)     cmd_info ;;
  print)    cmd_print ;;
  package)  cmd_package ;;
  rollback) cmd_rollback ;;
  prune)    cmd_prune ;;
  *)
    echo -e "${RED}Unknown command: $COMMAND${NC}"
    echo "Available: deploy, remove, invoke, logs, info, print, package, rollback, prune"
    exit 1
    ;;
esac
