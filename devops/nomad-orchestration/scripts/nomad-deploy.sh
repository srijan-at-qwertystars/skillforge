#!/usr/bin/env bash
# nomad-deploy.sh — Safe Nomad deployment: validate → plan → confirm → deploy → monitor.
# Usage: ./nomad-deploy.sh <job-file.nomad.hcl> [--auto-approve] [--namespace <ns>]
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

AUTO_APPROVE=false
NAMESPACE=""
JOB_FILE=""
MONITOR_TIMEOUT=300  # 5 minutes default

usage() {
  cat <<EOF
Usage: $0 <job-file.nomad.hcl> [OPTIONS]

Options:
  --auto-approve         Skip confirmation prompt
  --namespace <ns>       Deploy to specific namespace
  --timeout <seconds>    Deployment monitoring timeout (default: 300)
  -h, --help             Show this help

Examples:
  $0 api.nomad.hcl
  $0 api.nomad.hcl --namespace production
  $0 api.nomad.hcl --auto-approve --timeout 600
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-approve) AUTO_APPROVE=true; shift ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --timeout)      MONITOR_TIMEOUT="$2"; shift 2 ;;
    -h|--help)      usage ;;
    -*)             echo "Unknown option: $1"; usage ;;
    *)
      if [[ -z "$JOB_FILE" ]]; then
        JOB_FILE="$1"
      else
        echo "Unexpected argument: $1"; usage
      fi
      shift ;;
  esac
done

if [[ -z "$JOB_FILE" ]]; then
  echo -e "${RED}Error: Job file required${NC}"
  usage
fi

if [[ ! -f "$JOB_FILE" ]]; then
  echo -e "${RED}Error: File not found: $JOB_FILE${NC}"
  exit 1
fi

if ! command -v nomad &>/dev/null; then
  echo -e "${RED}Error: nomad CLI not found in PATH${NC}"
  exit 1
fi

NS_FLAG=""
if [[ -n "$NAMESPACE" ]]; then
  NS_FLAG="-namespace=$NAMESPACE"
fi

echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Nomad Safe Deployment          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""
echo "Job file:  $JOB_FILE"
echo "Namespace: ${NAMESPACE:-default}"
echo "Time:      $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# --- Step 1: Validate ---
echo -e "${BLUE}[1/5] Validating job spec...${NC}"
if nomad job validate $NS_FLAG "$JOB_FILE" 2>&1; then
  echo -e "${GREEN}Validation passed${NC}"
else
  echo -e "${RED}Validation failed — aborting deployment${NC}"
  exit 1
fi
echo ""

# --- Step 2: Plan ---
echo -e "${BLUE}[2/5] Planning deployment...${NC}"
PLAN_OUTPUT=$(nomad job plan $NS_FLAG "$JOB_FILE" 2>&1) || true
PLAN_EXIT=$?

echo "$PLAN_OUTPUT"
echo ""

# Extract the check-index from plan output
CHECK_INDEX=$(echo "$PLAN_OUTPUT" | grep -oP 'check-index\s+\K[0-9]+' | tail -1 || echo "")

# Analyze plan output
if echo "$PLAN_OUTPUT" | grep -q "No changes"; then
  echo -e "${GREEN}No changes detected — nothing to deploy${NC}"
  exit 0
fi

if echo "$PLAN_OUTPUT" | grep -qi "Preemptions"; then
  echo -e "${YELLOW}WARNING: This deployment will preempt existing allocations${NC}"
  echo "$PLAN_OUTPUT" | grep -A10 "Preemptions" || true
  echo ""
fi

# Count changes
CREATES=$(echo "$PLAN_OUTPUT" | grep -c "create" || true)
UPDATES=$(echo "$PLAN_OUTPUT" | grep -c "update" || true)
DESTROYS=$(echo "$PLAN_OUTPUT" | grep -c "destroy" || true)
IN_PLACE=$(echo "$PLAN_OUTPUT" | grep -c "in-place" || true)

echo -e "${BLUE}Plan summary:${NC}"
echo "  Creates:    $CREATES"
echo "  Updates:    $UPDATES"
echo "  Destroys:   $DESTROYS"
echo "  In-place:   $IN_PLACE"
echo ""

# --- Step 3: Confirm ---
if [[ "$AUTO_APPROVE" != "true" ]]; then
  echo -e "${YELLOW}[3/5] Confirm deployment${NC}"
  read -r -p "Do you want to proceed with this deployment? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY])
      echo "Proceeding..."
      ;;
    *)
      echo -e "${YELLOW}Deployment cancelled by user${NC}"
      exit 0
      ;;
  esac
else
  echo -e "${BLUE}[3/5] Auto-approved${NC}"
fi
echo ""

# --- Step 4: Deploy ---
echo -e "${BLUE}[4/5] Deploying...${NC}"
RUN_CMD="nomad job run"
if [[ -n "$CHECK_INDEX" ]]; then
  RUN_CMD="$RUN_CMD -check-index $CHECK_INDEX"
fi
if [[ -n "$NS_FLAG" ]]; then
  RUN_CMD="$RUN_CMD $NS_FLAG"
fi
RUN_CMD="$RUN_CMD $JOB_FILE"

RUN_OUTPUT=$(eval "$RUN_CMD" 2>&1) || {
  echo -e "${RED}Deployment command failed:${NC}"
  echo "$RUN_OUTPUT"
  exit 1
}

echo "$RUN_OUTPUT"

# Extract eval and deployment IDs
EVAL_ID=$(echo "$RUN_OUTPUT" | grep -oP 'Evaluation ID:\s*"\K[^"]+' || \
          echo "$RUN_OUTPUT" | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || echo "")

# Get job name from the file
JOB_NAME=$(grep -oP '^\s*job\s+"\K[^"]+' "$JOB_FILE" | head -1 || echo "")

echo ""

# --- Step 5: Monitor ---
echo -e "${BLUE}[5/5] Monitoring deployment (timeout: ${MONITOR_TIMEOUT}s)...${NC}"

if [[ -z "$JOB_NAME" ]]; then
  echo -e "${YELLOW}Could not determine job name — skipping monitoring${NC}"
  exit 0
fi

# Wait briefly for deployment to be created
sleep 2

# Get latest deployment ID
DEPLOY_ID=$(nomad job deployments $NS_FLAG -latest "$JOB_NAME" 2>/dev/null | awk 'NR==2{print $1}' || echo "")

if [[ -z "$DEPLOY_ID" ]]; then
  echo -e "${YELLOW}No deployment found (batch/system jobs don't create deployments)${NC}"
  echo "Checking job status..."
  nomad job status $NS_FLAG "$JOB_NAME" 2>/dev/null | tail -20
  exit 0
fi

echo "Deployment ID: $DEPLOY_ID"
echo ""

START_TIME=$(date +%s)

while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))

  if [[ $ELAPSED -gt $MONITOR_TIMEOUT ]]; then
    echo -e "${RED}Monitoring timeout (${MONITOR_TIMEOUT}s) exceeded${NC}"
    echo "Deployment $DEPLOY_ID may still be in progress."
    echo "Check manually: nomad deployment status $DEPLOY_ID"
    exit 1
  fi

  STATUS=$(nomad deployment status $NS_FLAG -json "$DEPLOY_ID" 2>/dev/null || echo "")

  if [[ -z "$STATUS" ]]; then
    echo "Waiting for deployment status..."
    sleep 5
    continue
  fi

  DEPLOY_STATUS=$(echo "$STATUS" | grep -oP '"Status"\s*:\s*"\K[^"]+' | head -1 || echo "unknown")

  case "$DEPLOY_STATUS" in
    successful)
      echo -e "${GREEN}✓ Deployment $DEPLOY_ID succeeded (${ELAPSED}s)${NC}"
      exit 0
      ;;
    failed)
      echo -e "${RED}✗ Deployment $DEPLOY_ID failed (${ELAPSED}s)${NC}"
      echo ""
      echo "Deployment details:"
      nomad deployment status $NS_FLAG "$DEPLOY_ID" 2>/dev/null || true
      echo ""
      echo "Recent allocation events:"
      nomad job status $NS_FLAG "$JOB_NAME" 2>/dev/null | tail -20
      exit 1
      ;;
    cancelled)
      echo -e "${YELLOW}Deployment $DEPLOY_ID was cancelled (${ELAPSED}s)${NC}"
      exit 1
      ;;
    running|pending)
      printf "\r  Status: %-12s Elapsed: %ds" "$DEPLOY_STATUS" "$ELAPSED"
      sleep 5
      ;;
    *)
      echo "  Unknown status: $DEPLOY_STATUS"
      sleep 5
      ;;
  esac
done
