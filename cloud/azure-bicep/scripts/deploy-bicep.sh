#!/usr/bin/env bash
# deploy-bicep.sh — Deploy Bicep files with what-if preview, parameter files, environment targeting
#
# Usage:
#   ./deploy-bicep.sh -g <resource-group> -f main.bicep                     # Basic deploy
#   ./deploy-bicep.sh -g <resource-group> -f main.bicep -p params.bicepparam # With parameters
#   ./deploy-bicep.sh -g <resource-group> -f main.bicep -e prod              # Environment params
#   ./deploy-bicep.sh -g <resource-group> -f main.bicep --what-if            # Preview only
#   ./deploy-bicep.sh -g <resource-group> -f main.bicep --validate           # Validate only
#   ./deploy-bicep.sh -s <sub-scope.bicep> -l eastus                         # Subscription scope
#   ./deploy-bicep.sh -g myRg -f main.bicep --stack myStack                  # Deploy as stack
#
# Options:
#   -g, --resource-group   Target resource group
#   -f, --file             Bicep template file (default: main.bicep)
#   -p, --params           Parameter file (.bicepparam or .json)
#   -e, --environment      Environment (looks for parameters/<env>.bicepparam)
#   -l, --location         Location (required for subscription/MG scope)
#   -s, --subscription     Deploy at subscription scope
#   -n, --name             Deployment name (default: auto-generated)
#   --what-if              Run what-if preview only
#   --validate             Validate only, don't deploy
#   --stack                Deploy as a deployment stack with given name
#   --deny-mode            Deny settings mode for stacks: none|denyDelete|denyWriteAndDelete
#   --confirm              Skip confirmation prompt
#   -h, --help             Show this help

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "${BLUE}[STEP]${NC} $*"; }

# Defaults
RESOURCE_GROUP=""
TEMPLATE_FILE="main.bicep"
PARAM_FILE=""
ENVIRONMENT=""
LOCATION=""
DEPLOY_NAME=""
WHAT_IF_ONLY=false
VALIDATE_ONLY=false
SUB_SCOPE=false
STACK_NAME=""
DENY_MODE="none"
CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--resource-group)  RESOURCE_GROUP="$2"; shift 2 ;;
    -f|--file)            TEMPLATE_FILE="$2"; shift 2 ;;
    -p|--params)          PARAM_FILE="$2"; shift 2 ;;
    -e|--environment)     ENVIRONMENT="$2"; shift 2 ;;
    -l|--location)        LOCATION="$2"; shift 2 ;;
    -n|--name)            DEPLOY_NAME="$2"; shift 2 ;;
    -s|--subscription)    SUB_SCOPE=true; shift ;;
    --what-if)            WHAT_IF_ONLY=true; shift ;;
    --validate)           VALIDATE_ONLY=true; shift ;;
    --stack)              STACK_NAME="$2"; shift 2 ;;
    --deny-mode)          DENY_MODE="$2"; shift 2 ;;
    --confirm)            CONFIRM=true; shift ;;
    -h|--help)            sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Validation ─────────────────────────────────────────────────────────────────
[[ ! -f "$TEMPLATE_FILE" ]] && { error "Template file not found: $TEMPLATE_FILE"; exit 1; }

if [[ "$SUB_SCOPE" == false && -z "$RESOURCE_GROUP" ]]; then
  error "Resource group required (-g). Use -s for subscription scope."
  exit 1
fi

if [[ "$SUB_SCOPE" == true && -z "$LOCATION" ]]; then
  error "Location required (-l) for subscription-scope deployments."
  exit 1
fi

# Resolve environment-based parameter file
if [[ -n "$ENVIRONMENT" && -z "$PARAM_FILE" ]]; then
  for candidate in "parameters/${ENVIRONMENT}.bicepparam" "parameters/${ENVIRONMENT}.json"; do
    if [[ -f "$candidate" ]]; then
      PARAM_FILE="$candidate"
      info "Using parameter file: $PARAM_FILE"
      break
    fi
  done
  [[ -z "$PARAM_FILE" ]] && warn "No parameter file found for environment '$ENVIRONMENT'"
fi

# Generate deployment name
if [[ -z "$DEPLOY_NAME" ]]; then
  DEPLOY_NAME="$(basename "${TEMPLATE_FILE%.*}")-$(date +%Y%m%d-%H%M%S)"
fi

# Build param arguments
PARAM_ARGS=""
if [[ -n "$PARAM_FILE" ]]; then
  PARAM_ARGS="--parameters $PARAM_FILE"
fi

# ── Functions ──────────────────────────────────────────────────────────────────
build_scope_args() {
  if [[ "$SUB_SCOPE" == true ]]; then
    echo "sub --location $LOCATION"
  else
    echo "group --resource-group $RESOURCE_GROUP"
  fi
}

run_lint() {
  step "Linting $TEMPLATE_FILE..."
  if az bicep lint --file "$TEMPLATE_FILE" 2>&1; then
    info "Lint passed ✓"
  else
    error "Lint failed"
    exit 1
  fi
}

run_validate() {
  step "Validating deployment..."
  local scope_args
  scope_args=$(build_scope_args)
  # shellcheck disable=SC2086
  if az deployment $scope_args validate \
    --name "$DEPLOY_NAME" \
    --template-file "$TEMPLATE_FILE" \
    $PARAM_ARGS \
    --no-prompt 2>&1; then
    info "Validation passed ✓"
  else
    error "Validation failed"
    exit 1
  fi
}

run_whatif() {
  step "Running what-if analysis..."
  local scope_args
  scope_args=$(build_scope_args)
  # shellcheck disable=SC2086
  az deployment $scope_args what-if \
    --name "$DEPLOY_NAME" \
    --template-file "$TEMPLATE_FILE" \
    $PARAM_ARGS \
    --no-prompt
  echo ""
}

run_deploy() {
  step "Deploying $TEMPLATE_FILE..."
  local scope_args
  scope_args=$(build_scope_args)
  # shellcheck disable=SC2086
  az deployment $scope_args create \
    --name "$DEPLOY_NAME" \
    --template-file "$TEMPLATE_FILE" \
    $PARAM_ARGS \
    --no-prompt \
    --verbose
  info "Deployment '$DEPLOY_NAME' completed ✓"
}

run_stack_deploy() {
  step "Deploying as stack '$STACK_NAME'..."
  local scope_cmd
  if [[ "$SUB_SCOPE" == true ]]; then
    scope_cmd="az stack sub create --location $LOCATION"
  else
    scope_cmd="az stack group create --resource-group $RESOURCE_GROUP"
  fi
  # shellcheck disable=SC2086
  $scope_cmd \
    --name "$STACK_NAME" \
    --template-file "$TEMPLATE_FILE" \
    $PARAM_ARGS \
    --deny-settings-mode "$DENY_MODE" \
    --action-on-unmanage detachAll \
    --yes
  info "Stack '$STACK_NAME' deployed ✓"
}

confirm_deploy() {
  if [[ "$CONFIRM" == true ]]; then return 0; fi
  echo ""
  echo -e "${YELLOW}Proceed with deployment?${NC} [y/N] "
  read -r response
  [[ "$response" =~ ^[Yy]$ ]] || { info "Deployment cancelled."; exit 0; }
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  info "=== Bicep Deployment ==="
  info "Template:    $TEMPLATE_FILE"
  info "Deployment:  $DEPLOY_NAME"
  [[ -n "$RESOURCE_GROUP" ]] && info "RG:          $RESOURCE_GROUP"
  [[ -n "$PARAM_FILE" ]]     && info "Parameters:  $PARAM_FILE"
  [[ -n "$STACK_NAME" ]]     && info "Stack:       $STACK_NAME (deny: $DENY_MODE)"
  echo ""

  run_lint
  run_validate

  if [[ "$VALIDATE_ONLY" == true ]]; then
    info "=== Validation Complete ==="
    exit 0
  fi

  run_whatif

  if [[ "$WHAT_IF_ONLY" == true ]]; then
    info "=== What-If Complete (no changes deployed) ==="
    exit 0
  fi

  confirm_deploy

  if [[ -n "$STACK_NAME" ]]; then
    run_stack_deploy
  else
    run_deploy
  fi

  info "=== Deployment Complete ==="
}

main
