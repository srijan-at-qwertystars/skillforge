#!/usr/bin/env bash
# =============================================================================
# analyze-image.sh — Analyze a Docker image for best-practice compliance
#
# Usage:
#   ./analyze-image.sh <IMAGE_NAME>
#   ./analyze-image.sh myapp:latest
#   ./analyze-image.sh nginx:1.25-alpine
#
# Checks performed:
#   • Whether the image runs as root
#   • Image size and layer count
#   • HEALTHCHECK presence
#   • Exposed ports
#   • Environment variables (common secrets redacted)
#   • Shell availability (security surface)
#   • Base image information
#   • Overall compliance score
#
# Requires: docker
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' YELLOW='' GREEN='' CYAN='' BOLD='' RESET=''
fi

pass() { echo -e "  ${GREEN}✔ PASS${RESET} — $1"; }
warn() { echo -e "  ${YELLOW}⚠ WARN${RESET} — $1"; }
fail() { echo -e "  ${RED}✖ FAIL${RESET} — $1"; }
info() { echo -e "  ${CYAN}ℹ INFO${RESET} — $1"; }

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <IMAGE_NAME>"
  echo "Example: $0 myapp:latest"
  exit 1
fi

IMAGE="$1"

if ! command -v docker &>/dev/null; then
  echo -e "${RED}Error: docker is not installed or not in PATH.${RESET}"
  exit 1
fi

# Verify the image exists locally (pull if not)
if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo -e "${YELLOW}Image not found locally — attempting to pull...${RESET}"
  if ! docker pull "$IMAGE" 2>/dev/null; then
    echo -e "${RED}Error: unable to find or pull image '${IMAGE}'${RESET}"
    exit 1
  fi
fi

echo -e "${BOLD}Analyzing image: ${IMAGE}${RESET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SCORE=0
TOTAL=0

# ---------------------------------------------------------------------------
# 1. User / root check
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}[1/7] User Configuration${RESET}"
((TOTAL++)) || true

USER_VAL=$(docker inspect --format='{{.Config.User}}' "$IMAGE" 2>/dev/null || echo "")
if [[ -z "$USER_VAL" || "$USER_VAL" == "root" || "$USER_VAL" == "0" ]]; then
  fail "Container runs as root (User=${USER_VAL:-<unset>}). Set a non-root USER."
else
  pass "Runs as non-root user: ${USER_VAL}"
  ((SCORE++)) || true
fi

# ---------------------------------------------------------------------------
# 2. Image size & layer count
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}[2/7] Image Size & Layers${RESET}"
((TOTAL++)) || true

IMAGE_SIZE=$(docker inspect --format='{{.Size}}' "$IMAGE" 2>/dev/null || echo "0")
IMAGE_SIZE_MB=$(awk "BEGIN {printf \"%.1f\", ${IMAGE_SIZE}/1048576}")

LAYER_COUNT=$(docker history --no-trunc -q "$IMAGE" 2>/dev/null | wc -l)

info "Image size: ${IMAGE_SIZE_MB} MB"
info "Layer count: ${LAYER_COUNT}"

if awk "BEGIN {exit !(${IMAGE_SIZE_MB} > 1000)}"; then
  warn "Image is over 1 GB — consider a smaller base or multi-stage build."
elif awk "BEGIN {exit !(${IMAGE_SIZE_MB} > 500)}"; then
  warn "Image is over 500 MB — review for size optimizations."
else
  pass "Image size is reasonable (${IMAGE_SIZE_MB} MB)."
  ((SCORE++)) || true
fi

if [[ "$LAYER_COUNT" -gt 30 ]]; then
  warn "High layer count (${LAYER_COUNT}) — consider combining RUN instructions."
fi

# ---------------------------------------------------------------------------
# 3. HEALTHCHECK
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}[3/7] HEALTHCHECK${RESET}"
((TOTAL++)) || true

HEALTHCHECK=$(docker inspect --format='{{json .Config.Healthcheck}}' "$IMAGE" 2>/dev/null || echo "null")
if [[ "$HEALTHCHECK" == "null" || "$HEALTHCHECK" == "<nil>" || -z "$HEALTHCHECK" ]]; then
  fail "No HEALTHCHECK defined. Add one for orchestrator readiness."
else
  pass "HEALTHCHECK is configured."
  ((SCORE++)) || true
fi

# ---------------------------------------------------------------------------
# 4. Exposed ports
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}[4/7] Exposed Ports${RESET}"
((TOTAL++)) || true

PORTS=$(docker inspect --format='{{json .Config.ExposedPorts}}' "$IMAGE" 2>/dev/null || echo "{}")
if [[ "$PORTS" == "{}" || "$PORTS" == "null" || -z "$PORTS" ]]; then
  info "No ports exposed via EXPOSE directive."
  ((SCORE++)) || true
else
  # Pretty-print port list
  PORT_LIST=$(echo "$PORTS" | tr -d '{}\"' | tr ',' '\n' | sed 's/://g' | tr '\n' ', ' | sed 's/, $//')
  info "Exposed ports: ${PORT_LIST}"
  # Check for privileged ports
  HAS_PRIV=false
  for p in $(echo "$PORTS" | tr -d '{}\"' | tr ',' '\n' | grep -oE '[0-9]+'); do
    if [[ "$p" -lt 1024 ]]; then
      HAS_PRIV=true
    fi
  done
  if [[ "$HAS_PRIV" == "true" ]]; then
    warn "Privileged port(s) (<1024) exposed — requires elevated permissions."
  else
    pass "No privileged ports exposed."
    ((SCORE++)) || true
  fi
fi

# ---------------------------------------------------------------------------
# 5. Environment variables (redact secrets)
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}[5/7] Environment Variables${RESET}"
((TOTAL++)) || true

ENV_VARS=$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE" 2>/dev/null || echo "")

SECRET_PATTERNS="PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY|ACCESS_KEY|AUTH|CREDENTIAL"
HAS_SUSPECT=false

if [[ -n "$ENV_VARS" ]]; then
  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    KEY="${var%%=*}"
    VALUE="${var#*=}"
    if echo "$KEY" | grep -qiE "$SECRET_PATTERNS"; then
      info "${KEY}=<REDACTED>"
      HAS_SUSPECT=true
    else
      info "${KEY}=${VALUE}"
    fi
  done <<< "$ENV_VARS"
fi

if [[ "$HAS_SUSPECT" == "true" ]]; then
  warn "Potential secret(s) found in ENV. Use runtime secrets or mounts instead."
else
  pass "No obvious secrets in environment variables."
  ((SCORE++)) || true
fi

# ---------------------------------------------------------------------------
# 6. Shell availability
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}[6/7] Shell Availability${RESET}"
((TOTAL++)) || true

SHELL_FOUND=false
for sh in /bin/sh /bin/bash /bin/ash; do
  if docker run --rm --entrypoint "" "$IMAGE" test -x "$sh" 2>/dev/null; then
    SHELL_FOUND=true
    break
  fi
done

if [[ "$SHELL_FOUND" == "true" ]]; then
  warn "Shell is available in the image — increases attack surface. Consider distroless/scratch."
else
  pass "No shell detected — reduced attack surface."
  ((SCORE++)) || true
fi

# ---------------------------------------------------------------------------
# 7. Base image info
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}[7/7] Base Image Information${RESET}"

# Attempt to extract base from labels or history
BASE_LABEL=$(docker inspect --format='{{index .Config.Labels "org.opencontainers.image.base.name"}}' "$IMAGE" 2>/dev/null || echo "")
if [[ -n "$BASE_LABEL" && "$BASE_LABEL" != "<no value>" ]]; then
  info "Base image (from OCI label): ${BASE_LABEL}"
else
  # Fallback: show bottom layer comment from history
  BASE_HISTORY=$(docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE" 2>/dev/null | tail -1)
  if [[ -n "$BASE_HISTORY" ]]; then
    info "Earliest layer: ${BASE_HISTORY:0:120}"
  else
    info "Base image: unable to determine."
  fi
fi

# ---------------------------------------------------------------------------
# Compliance summary
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PERCENT=$((SCORE * 100 / TOTAL))
echo -e "${BOLD}Compliance Score: ${SCORE}/${TOTAL} (${PERCENT}%)${RESET}"

if [[ $PERCENT -ge 80 ]]; then
  echo -e "${GREEN}★ Good — image follows most best practices.${RESET}"
elif [[ $PERCENT -ge 50 ]]; then
  echo -e "${YELLOW}★ Fair — several improvements recommended.${RESET}"
else
  echo -e "${RED}★ Poor — significant best-practice gaps detected.${RESET}"
fi
