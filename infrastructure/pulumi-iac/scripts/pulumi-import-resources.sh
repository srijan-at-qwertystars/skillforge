#!/usr/bin/env bash
#
# pulumi-import-resources.sh - Import existing AWS resources into Pulumi state
#
# Usage:
#   pulumi-import-resources.sh [OPTIONS]
#
# Options:
#   --resource-type  ec2|s3|rds|lambda|vpc|sg   Filter by resource type (optional, discovers all if omitted)
#   --stack          <stack-name>                Target Pulumi stack (default: current stack)
#   --execute                                   Run the import commands instead of just printing them
#   --region         <aws-region>               AWS region (default: from AWS CLI config)
#   -h, --help                                  Show this help message
#
# Examples:
#   pulumi-import-resources.sh                              # Interactive: discover all, pick resources
#   pulumi-import-resources.sh --resource-type s3            # Only discover S3 buckets
#   pulumi-import-resources.sh --resource-type ec2 --execute # Discover EC2 instances and import them
#   pulumi-import-resources.sh --stack prod --region us-east-1
#
# Prerequisites:
#   - AWS CLI v2 installed and configured
#   - Pulumi CLI installed
#   - Active Pulumi stack (or specify --stack)

set -euo pipefail

# ─── Colors & helpers ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

usage() {
  sed -n '3,/^$/s/^# \?//p' "$0"
  exit 0
}

# ─── Globals ─────────────────────────────────────────────────────────────────

RESOURCE_TYPE=""
STACK=""
EXECUTE=false
REGION=""
declare -a DISCOVERED_RESOURCES=()
declare -a IMPORT_COMMANDS=()

# ─── Argument parsing ───────────────────────────────────────────────────────

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --resource-type) RESOURCE_TYPE="$2"; shift 2 ;;
      --stack)         STACK="$2";         shift 2 ;;
      --region)        REGION="$2";        shift 2 ;;
      --execute)       EXECUTE=true;       shift ;;
      -h|--help)       usage ;;
      *)               die "Unknown option: $1. Use -h for help." ;;
    esac
  done
}

# ─── Validation ──────────────────────────────────────────────────────────────

validate_prerequisites() {
  if ! command -v aws &>/dev/null; then
    die "AWS CLI is not installed. Install it from https://aws.amazon.com/cli/"
  fi

  if ! aws sts get-caller-identity &>/dev/null; then
    die "AWS CLI is not configured or credentials are invalid. Run 'aws configure'."
  fi

  if ! command -v pulumi &>/dev/null; then
    die "Pulumi CLI is not installed. Install it from https://www.pulumi.com/docs/install/"
  fi

  if [[ -n "$RESOURCE_TYPE" && ! "$RESOURCE_TYPE" =~ ^(ec2|s3|rds|lambda|vpc|sg)$ ]]; then
    die "Invalid resource type '$RESOURCE_TYPE'. Must be one of: ec2, s3, rds, lambda, vpc, sg"
  fi

  if [[ -n "$REGION" ]]; then
    export AWS_DEFAULT_REGION="$REGION"
  fi

  info "AWS Account: $(aws sts get-caller-identity --query Account --output text)"
  info "Region:      ${REGION:-$(aws configure get region 2>/dev/null || echo 'default')}"
  echo
}

# ─── Resource discovery ─────────────────────────────────────────────────────

print_table_header() {
  printf "${BOLD}%-4s %-20s %-50s %-20s${NC}\n" "#" "TYPE" "RESOURCE ID" "NAME/DETAILS"
  printf '%-4s %-20s %-50s %-20s\n' "----" "--------------------" "--------------------------------------------------" "--------------------"
}

discover_ec2() {
  info "Discovering EC2 instances..."
  local instances
  instances=$(aws ec2 describe-instances \
    --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==`Name`].Value | [0], State.Name]' \
    --output text 2>/dev/null || true)

  while IFS=$'\t' read -r id name state; do
    [[ -z "$id" ]] && continue
    local idx=${#DISCOVERED_RESOURCES[@]}
    DISCOVERED_RESOURCES+=("ec2|aws:ec2/instance:Instance|${id}|${name:-unnamed} (${state})")
    printf "%-4s %-20s %-50s %-20s\n" "$idx" "EC2 Instance" "$id" "${name:-unnamed} (${state})"
  done <<< "$instances"
}

discover_s3() {
  info "Discovering S3 buckets..."
  local buckets
  buckets=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null || true)

  for bucket in $buckets; do
    [[ -z "$bucket" ]] && continue
    local idx=${#DISCOVERED_RESOURCES[@]}
    DISCOVERED_RESOURCES+=("s3|aws:s3/bucketV2:BucketV2|${bucket}|${bucket}")
    printf "%-4s %-20s %-50s %-20s\n" "$idx" "S3 Bucket" "$bucket" "$bucket"
  done
}

discover_rds() {
  info "Discovering RDS instances..."
  local dbs
  dbs=$(aws rds describe-db-instances \
    --query 'DBInstances[].[DBInstanceIdentifier, Engine, DBInstanceClass]' \
    --output text 2>/dev/null || true)

  while IFS=$'\t' read -r id engine class; do
    [[ -z "$id" ]] && continue
    local idx=${#DISCOVERED_RESOURCES[@]}
    DISCOVERED_RESOURCES+=("rds|aws:rds/instance:Instance|${id}|${engine} ${class}")
    printf "%-4s %-20s %-50s %-20s\n" "$idx" "RDS Instance" "$id" "${engine} ${class}"
  done <<< "$dbs"
}

discover_lambda() {
  info "Discovering Lambda functions..."
  local functions
  functions=$(aws lambda list-functions \
    --query 'Functions[].[FunctionName, Runtime, MemorySize]' \
    --output text 2>/dev/null || true)

  while IFS=$'\t' read -r name runtime memory; do
    [[ -z "$name" ]] && continue
    local idx=${#DISCOVERED_RESOURCES[@]}
    DISCOVERED_RESOURCES+=("lambda|aws:lambda/function:Function|${name}|${runtime} ${memory}MB")
    printf "%-4s %-20s %-50s %-20s\n" "$idx" "Lambda Function" "$name" "${runtime} ${memory}MB"
  done <<< "$functions"
}

discover_vpc() {
  info "Discovering VPCs..."
  local vpcs
  vpcs=$(aws ec2 describe-vpcs \
    --query 'Vpcs[].[VpcId, CidrBlock, Tags[?Key==`Name`].Value | [0]]' \
    --output text 2>/dev/null || true)

  while IFS=$'\t' read -r id cidr name; do
    [[ -z "$id" ]] && continue
    local idx=${#DISCOVERED_RESOURCES[@]}
    DISCOVERED_RESOURCES+=("vpc|aws:ec2/vpc:Vpc|${id}|${name:-unnamed} ${cidr}")
    printf "%-4s %-20s %-50s %-20s\n" "$idx" "VPC" "$id" "${name:-unnamed} ${cidr}"
  done <<< "$vpcs"
}

discover_sg() {
  info "Discovering Security Groups..."
  local sgs
  sgs=$(aws ec2 describe-security-groups \
    --query 'SecurityGroups[].[GroupId, GroupName, VpcId]' \
    --output text 2>/dev/null || true)

  while IFS=$'\t' read -r id name vpc; do
    [[ -z "$id" ]] && continue
    local idx=${#DISCOVERED_RESOURCES[@]}
    DISCOVERED_RESOURCES+=("sg|aws:ec2/securityGroup:SecurityGroup|${id}|${name} (${vpc})")
    printf "%-4s %-20s %-50s %-20s\n" "$idx" "Security Group" "$id" "${name} (${vpc})"
  done <<< "$sgs"
}

discover_resources() {
  echo -e "${BOLD}${CYAN}Discovered Resources${NC}"
  echo
  print_table_header

  if [[ -z "$RESOURCE_TYPE" ]]; then
    discover_ec2; discover_s3; discover_rds; discover_lambda; discover_vpc; discover_sg
  else
    case "$RESOURCE_TYPE" in
      ec2)    discover_ec2 ;;
      s3)     discover_s3 ;;
      rds)    discover_rds ;;
      lambda) discover_lambda ;;
      vpc)    discover_vpc ;;
      sg)     discover_sg ;;
    esac
  fi

  echo
  if [[ ${#DISCOVERED_RESOURCES[@]} -eq 0 ]]; then
    warn "No resources found."
    exit 0
  fi
  info "Found ${#DISCOVERED_RESOURCES[@]} resource(s)."
}

# ─── Resource selection ─────────────────────────────────────────────────────

select_resources() {
  echo
  echo -e "${BOLD}Enter resource numbers to import (comma-separated, or 'all'):${NC}"
  read -r -p "> " selection

  local indices=()
  if [[ "$selection" == "all" ]]; then
    for ((i = 0; i < ${#DISCOVERED_RESOURCES[@]}; i++)); do
      indices+=("$i")
    done
  else
    IFS=',' read -ra indices <<< "$selection"
  fi

  local stack_flag=""
  [[ -n "$STACK" ]] && stack_flag="--stack ${STACK}"

  echo
  echo -e "${BOLD}${CYAN}Import Commands${NC}"
  echo

  for idx in "${indices[@]}"; do
    idx=$(echo "$idx" | tr -d ' ')
    if [[ "$idx" -ge 0 && "$idx" -lt ${#DISCOVERED_RESOURCES[@]} ]] 2>/dev/null; then
      local entry="${DISCOVERED_RESOURCES[$idx]}"
      IFS='|' read -r _type pulumi_type resource_id _detail <<< "$entry"
      local logical_name
      logical_name=$(echo "$resource_id" | tr '.' '-' | tr '/' '-')
      local cmd="pulumi import ${stack_flag} ${pulumi_type} ${logical_name} ${resource_id}"
      IMPORT_COMMANDS+=("$cmd")
      echo "  $cmd"
    else
      warn "Skipping invalid index: $idx"
    fi
  done
}

# ─── Execution ───────────────────────────────────────────────────────────────

execute_imports() {
  echo
  if [[ "$EXECUTE" == true ]]; then
    info "Executing imports..."
    echo
    for cmd in "${IMPORT_COMMANDS[@]}"; do
      info "Running: $cmd"
      if eval "$cmd --yes" 2>&1; then
        ok "Imported successfully."
      else
        err "Failed to import. Continuing with remaining resources..."
      fi
      echo
    done
  else
    echo -e "${YELLOW}Dry run only.${NC} Re-run with ${BOLD}--execute${NC} to perform the imports."
    echo "Or copy the commands above and run them manually."
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  validate_prerequisites
  discover_resources
  select_resources
  execute_imports

  echo
  ok "Done."
}

main "$@"
