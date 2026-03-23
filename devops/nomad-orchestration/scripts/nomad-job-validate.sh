#!/usr/bin/env bash
# nomad-job-validate.sh — Validates a Nomad job file with built-in and custom checks.
# Usage: ./nomad-job-validate.sh <job-file.nomad.hcl>
set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

error() { echo -e "${RED}ERROR:${NC} $1"; ((ERRORS++)); }
warn()  { echo -e "${YELLOW}WARN:${NC} $1"; ((WARNINGS++)); }
ok()    { echo -e "${GREEN}OK:${NC} $1"; }

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <job-file.nomad.hcl>"
  exit 1
fi

JOB_FILE="$1"

if [[ ! -f "$JOB_FILE" ]]; then
  error "File not found: $JOB_FILE"
  exit 1
fi

echo "=== Nomad Job Validation: $JOB_FILE ==="
echo ""

# --- Step 1: Built-in nomad job validate ---
echo "--- Built-in validation ---"
if command -v nomad &>/dev/null; then
  if nomad job validate "$JOB_FILE" 2>&1; then
    ok "nomad job validate passed"
  else
    error "nomad job validate failed"
  fi
else
  warn "nomad CLI not found — skipping built-in validation"
fi
echo ""

# --- Step 2: Custom checks ---
echo "--- Custom checks ---"
CONTENT=$(cat "$JOB_FILE")

# Check: job type present
if echo "$CONTENT" | grep -qE '^\s*type\s*='; then
  JOB_TYPE=$(echo "$CONTENT" | grep -oP '^\s*type\s*=\s*"\K[^"]+' | head -1)
  ok "Job type defined: $JOB_TYPE"
else
  warn "No job type specified (defaults to 'service')"
  JOB_TYPE="service"
fi

# Check: update stanza present (for service jobs)
if [[ "$JOB_TYPE" == "service" ]]; then
  if echo "$CONTENT" | grep -qE '^\s*update\s*\{'; then
    ok "update stanza found"

    # Check for auto_revert
    if echo "$CONTENT" | grep -qE 'auto_revert\s*=\s*true'; then
      ok "auto_revert enabled"
    else
      warn "auto_revert not enabled — failed deployments won't auto-rollback"
    fi

    # Check for min_healthy_time
    if echo "$CONTENT" | grep -qE 'min_healthy_time'; then
      ok "min_healthy_time set"
    else
      warn "min_healthy_time not set — defaults to 10s, may be too short"
    fi

    # Check for healthy_deadline
    if echo "$CONTENT" | grep -qE 'healthy_deadline'; then
      ok "healthy_deadline set"
    else
      warn "healthy_deadline not set — defaults to 5m"
    fi
  else
    error "No update stanza found for service job — deployments will replace all allocations at once"
  fi
fi

# Check: resources block present
if echo "$CONTENT" | grep -qE '^\s*resources\s*\{'; then
  ok "resources block found"

  # Check for cpu
  if echo "$CONTENT" | grep -qE '^\s*cpu\s*='; then
    ok "CPU resources specified"
  else
    warn "CPU not specified in resources — defaults to 100 MHz"
  fi

  # Check for memory
  if echo "$CONTENT" | grep -qE '^\s*memory\s*='; then
    ok "Memory resources specified"
  else
    warn "Memory not specified in resources — defaults to 300 MB"
  fi
else
  error "No resources block found — tasks will use defaults (100 MHz CPU, 300 MB memory)"
fi

# Check: health checks present (for service jobs)
if [[ "$JOB_TYPE" == "service" || "$JOB_TYPE" == "system" ]]; then
  if echo "$CONTENT" | grep -qE '^\s*service\s*\{'; then
    if echo "$CONTENT" | grep -qE '^\s*check\s*\{'; then
      ok "Health check(s) defined"
    else
      error "Service registered but no health check defined — traffic will route to unhealthy instances"
    fi
  else
    warn "No service block — job won't register with service discovery"
  fi
fi

# Check: datacenters specified
if echo "$CONTENT" | grep -qE '^\s*datacenters\s*='; then
  ok "Datacenters specified"
else
  warn "No datacenters specified — may use default"
fi

# Check: namespace specified
if echo "$CONTENT" | grep -qE '^\s*namespace\s*='; then
  ok "Namespace specified"
else
  warn "No namespace specified — will deploy to 'default' namespace"
fi

# Check: Docker image uses pinned version (not :latest)
IMAGES=$(echo "$CONTENT" | grep -oP 'image\s*=\s*"\K[^"]+' || true)
if [[ -n "$IMAGES" ]]; then
  while IFS= read -r img; do
    if [[ "$img" == *":latest" ]]; then
      warn "Image uses :latest tag: $img — pin to a specific version for reproducibility"
    elif [[ "$img" != *":"* && "$img" != *"@sha256:"* ]]; then
      warn "Image has no tag: $img — defaults to :latest, pin to a specific version"
    else
      ok "Image pinned: $img"
    fi
  done <<< "$IMAGES"
fi

# Check: raw_exec usage
if echo "$CONTENT" | grep -qE 'driver\s*=\s*"raw_exec"'; then
  warn "raw_exec driver used — no isolation, avoid in production"
fi

# Check: static ports
STATIC_PORTS=$(echo "$CONTENT" | grep -cE '^\s*static\s*=' || true)
if [[ "$STATIC_PORTS" -gt 0 ]]; then
  warn "$STATIC_PORTS static port(s) defined — limits bin-packing, use dynamic ports where possible"
fi

# Check: vault block without template
if echo "$CONTENT" | grep -qE '^\s*vault\s*\{'; then
  if ! echo "$CONTENT" | grep -qE '^\s*template\s*\{'; then
    warn "Vault block present but no template stanza — secrets won't be rendered into the task"
  else
    ok "Vault + template stanzas present"
  fi
fi

# Check: count specified for groups
if echo "$CONTENT" | grep -qE '^\s*group\s'; then
  if echo "$CONTENT" | grep -qE '^\s*count\s*='; then
    ok "Group count specified"
  else
    warn "No count specified on group — defaults to 1"
  fi
fi

# --- Summary ---
echo ""
echo "=== Summary ==="
echo -e "Errors:   ${RED}${ERRORS}${NC}"
echo -e "Warnings: ${YELLOW}${WARNINGS}${NC}"

if [[ $ERRORS -gt 0 ]]; then
  echo -e "${RED}Validation FAILED${NC}"
  exit 1
elif [[ $WARNINGS -gt 0 ]]; then
  echo -e "${YELLOW}Validation PASSED with warnings${NC}"
  exit 0
else
  echo -e "${GREEN}Validation PASSED${NC}"
  exit 0
fi
