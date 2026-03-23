#!/usr/bin/env bash
# =============================================================================
# optimize-image-size.sh — Analyze a Docker image for size optimization
#
# Usage:
#   ./optimize-image-size.sh <IMAGE_NAME>
#   ./optimize-image-size.sh myapp:latest
#   ./optimize-image-size.sh node:22-alpine
#
# Reports:
#   • Layer-by-layer size breakdown
#   • Largest layers highlighted
#   • Common size-bloater detection (apt cache, npm cache, .git, __pycache__)
#   • Specific optimization suggestions
#   • Overhead compared to the base image
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
  DIM='\033[2m'
  RESET='\033[0m'
else
  RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET=''
fi

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

if ! docker image inspect "$IMAGE" &>/dev/null; then
  echo -e "${YELLOW}Image not found locally — attempting to pull...${RESET}"
  if ! docker pull "$IMAGE" 2>/dev/null; then
    echo -e "${RED}Error: unable to find or pull image '${IMAGE}'${RESET}"
    exit 1
  fi
fi

echo -e "${BOLD}Image Size Analysis: ${IMAGE}${RESET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ---------------------------------------------------------------------------
# 1. Overall image size
# ---------------------------------------------------------------------------
TOTAL_SIZE=$(docker inspect --format='{{.Size}}' "$IMAGE" 2>/dev/null || echo "0")
TOTAL_MB=$(awk "BEGIN {printf \"%.1f\", ${TOTAL_SIZE}/1048576}")
echo -e "\n${BOLD}Total image size: ${TOTAL_MB} MB${RESET}"

# ---------------------------------------------------------------------------
# 2. Layer-by-layer breakdown
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}Layer Breakdown (largest first):${RESET}"
echo -e "${DIM}SIZE       INSTRUCTION${RESET}"
echo "──────────────────────────────────────────────────"

# Collect layers with sizes
LAYER_DATA=$(docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' "$IMAGE" 2>/dev/null || echo "")

# Parse sizes into bytes for sorting, keeping original size string
declare -a LAYER_BYTES=()
declare -a LAYER_SIZES=()
declare -a LAYER_CMDS=()
IDX=0

while IFS=$'\t' read -r size cmd; do
  [[ -z "$size" ]] && continue
  # Convert human-readable size to bytes for sorting
  BYTES=0
  if [[ "$size" == *"GB"* ]]; then
    NUM=$(echo "$size" | grep -oE '[0-9]+\.?[0-9]*')
    BYTES=$(awk "BEGIN {printf \"%.0f\", ${NUM}*1073741824}")
  elif [[ "$size" == *"MB"* ]]; then
    NUM=$(echo "$size" | grep -oE '[0-9]+\.?[0-9]*')
    BYTES=$(awk "BEGIN {printf \"%.0f\", ${NUM}*1048576}")
  elif [[ "$size" == *"kB"* ]]; then
    NUM=$(echo "$size" | grep -oE '[0-9]+\.?[0-9]*')
    BYTES=$(awk "BEGIN {printf \"%.0f\", ${NUM}*1024}")
  elif [[ "$size" == *"B"* ]]; then
    NUM=$(echo "$size" | grep -oE '[0-9]+\.?[0-9]*')
    BYTES=$(awk "BEGIN {printf \"%.0f\", ${NUM}}")
  fi

  LAYER_BYTES+=("$BYTES")
  LAYER_SIZES+=("$size")
  # Truncate command for display
  SHORT_CMD="${cmd:0:100}"
  LAYER_CMDS+=("$SHORT_CMD")
  ((IDX++)) || true
done <<< "$LAYER_DATA"

# Sort indices by size descending
SORTED_INDICES=()
if [[ ${#LAYER_BYTES[@]} -gt 0 ]]; then
  for i in "${!LAYER_BYTES[@]}"; do
    echo "${LAYER_BYTES[$i]} $i"
  done | sort -rn | while read -r _ idx; do
    echo "$idx"
  done | while read -r idx; do
    SIZE="${LAYER_SIZES[$idx]}"
    CMD="${LAYER_CMDS[$idx]}"
    BYTES="${LAYER_BYTES[$idx]}"

    # Highlight large layers (> 50 MB)
    if [[ "$BYTES" -gt 52428800 ]]; then
      echo -e "${RED}$(printf '%-10s' "$SIZE") ${CMD}${RESET}"
    elif [[ "$BYTES" -gt 10485760 ]]; then
      echo -e "${YELLOW}$(printf '%-10s' "$SIZE") ${CMD}${RESET}"
    elif [[ "$BYTES" -gt 0 ]]; then
      echo -e "$(printf '%-10s' "$SIZE") ${CMD}"
    fi
  done
fi

echo -e "\n  ${DIM}(layers with 0B size omitted; ${RED}red${RESET}${DIM} >50MB, ${YELLOW}yellow${RESET}${DIM} >10MB)${RESET}"

# ---------------------------------------------------------------------------
# 3. Check for common size bloaters
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}Bloater Detection:${RESET}"

SUGGESTIONS=()
HISTORY_FULL=$(docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE" 2>/dev/null || echo "")

# apt/dpkg cache not cleaned
if echo "$HISTORY_FULL" | grep -qiE 'apt-get install|apt install'; then
  if ! echo "$HISTORY_FULL" | grep -qiE 'rm -rf /var/lib/apt/lists'; then
    echo -e "  ${RED}✖${RESET} apt-get used without cleaning /var/lib/apt/lists"
    SUGGESTIONS+=("Add 'rm -rf /var/lib/apt/lists/*' in the same RUN as apt-get install.")
  else
    echo -e "  ${GREEN}✔${RESET} apt cache appears to be cleaned"
  fi
fi

# apk cache
if echo "$HISTORY_FULL" | grep -qiE 'apk add'; then
  if echo "$HISTORY_FULL" | grep -qiE 'apk add.*--no-cache'; then
    echo -e "  ${GREEN}✔${RESET} apk uses --no-cache"
  else
    echo -e "  ${YELLOW}⚠${RESET} apk add without --no-cache detected"
    SUGGESTIONS+=("Use 'apk add --no-cache' to avoid storing the package index.")
  fi
fi

# npm / yarn cache
if echo "$HISTORY_FULL" | grep -qiE 'npm install|npm ci'; then
  if echo "$HISTORY_FULL" | grep -qiE 'npm cache clean|npm ci'; then
    echo -e "  ${GREEN}✔${RESET} npm cache handled (npm ci auto-cleans)"
  else
    echo -e "  ${YELLOW}⚠${RESET} npm install used — consider npm ci which auto-cleans cache"
    SUGGESTIONS+=("Use 'npm ci' instead of 'npm install' for cleaner, faster builds.")
  fi
fi

# pip cache
if echo "$HISTORY_FULL" | grep -qiE 'pip install'; then
  if echo "$HISTORY_FULL" | grep -qiE 'pip install.*--no-cache-dir|mount=type=cache'; then
    echo -e "  ${GREEN}✔${RESET} pip cache handled"
  else
    echo -e "  ${YELLOW}⚠${RESET} pip install without --no-cache-dir"
    SUGGESTIONS+=("Add '--no-cache-dir' to pip install, or use '--mount=type=cache' with BuildKit.")
  fi
fi

# Check filesystem for bloaters by inspecting a temporary container
echo -e "\n${BOLD}Filesystem Scan:${RESET}"

BLOATER_PATHS=(
  "/var/lib/apt/lists:apt package lists"
  "/var/cache/apt:apt download cache"
  "/root/.npm:npm cache"
  "/root/.cache/pip:pip cache"
  "/tmp:temporary files"
  "/.git:git repository"
  "/app/.git:git repository in app"
  "/app/node_modules/.cache:node_modules cache"
)

CONTAINER_ID=$(docker create "$IMAGE" /bin/true 2>/dev/null || echo "")
if [[ -n "$CONTAINER_ID" ]]; then
  for entry in "${BLOATER_PATHS[@]}"; do
    BPATH="${entry%%:*}"
    BLABEL="${entry##*:}"

    DIR_SIZE=$(docker export "$CONTAINER_ID" 2>/dev/null \
      | tar -t 2>/dev/null \
      | grep -c "^${BPATH#/}" 2>/dev/null || echo "0")

    if [[ "$DIR_SIZE" -gt 5 ]]; then
      echo -e "  ${YELLOW}⚠${RESET} ${BPATH} found (${BLABEL}) — ${DIR_SIZE} entries"
      SUGGESTIONS+=("Remove or exclude ${BPATH} (${BLABEL}) to reduce image size.")
    fi
  done
  docker rm "$CONTAINER_ID" &>/dev/null || true
else
  echo -e "  ${DIM}(could not create temp container for filesystem scan)${RESET}"
fi

# ---------------------------------------------------------------------------
# 4. Multi-stage build check
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}Build Pattern:${RESET}"
LAYER_COUNT=$(docker history -q "$IMAGE" 2>/dev/null | wc -l)
MISSING_LAYERS=$(docker history --format '{{.ID}}' "$IMAGE" 2>/dev/null | grep -c '<missing>' || echo "0")

info_line() { echo -e "  ${CYAN}ℹ${RESET} $1"; }

info_line "Total layers: ${LAYER_COUNT}"
if [[ "$MISSING_LAYERS" -gt 0 ]]; then
  info_line "Base image layers (inherited): ${MISSING_LAYERS}"
  ADDED=$((LAYER_COUNT - MISSING_LAYERS))
  info_line "Layers added by Dockerfile: ${ADDED}"
fi

# ---------------------------------------------------------------------------
# 5. Base image comparison
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}Base Image Overhead:${RESET}"

# Try to determine base image from OCI label
BASE_NAME=$(docker inspect --format='{{index .Config.Labels "org.opencontainers.image.base.name"}}' "$IMAGE" 2>/dev/null || echo "")
if [[ -n "$BASE_NAME" && "$BASE_NAME" != "<no value>" ]]; then
  if docker image inspect "$BASE_NAME" &>/dev/null; then
    BASE_SIZE=$(docker inspect --format='{{.Size}}' "$BASE_NAME" 2>/dev/null || echo "0")
    BASE_MB=$(awk "BEGIN {printf \"%.1f\", ${BASE_SIZE}/1048576}")
    OVERHEAD=$(awk "BEGIN {printf \"%.1f\", (${TOTAL_SIZE}-${BASE_SIZE})/1048576}")
    OVERHEAD_PCT=$(awk "BEGIN {printf \"%.0f\", ((${TOTAL_SIZE}-${BASE_SIZE})/${TOTAL_SIZE})*100}")
    info_line "Base image (${BASE_NAME}): ${BASE_MB} MB"
    info_line "Your additions: ${OVERHEAD} MB (${OVERHEAD_PCT}% of total)"
  else
    info_line "Base image ${BASE_NAME} not available locally for comparison."
  fi
else
  info_line "Base image unknown — add OCI labels or compare manually."
  info_line "Tip: docker inspect --format='{{.Size}}' <base-image>"
fi

# ---------------------------------------------------------------------------
# 6. Optimization suggestions
# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}Optimization Suggestions:${RESET}"

if [[ ${#SUGGESTIONS[@]} -eq 0 ]]; then
  echo -e "  ${GREEN}✔ No obvious optimizations detected.${RESET}"
else
  for i in "${!SUGGESTIONS[@]}"; do
    echo -e "  $((i+1)). ${SUGGESTIONS[$i]}"
  done
fi

# General tips always shown
echo ""
echo -e "${DIM}General tips:${RESET}"
echo "  • Use multi-stage builds to exclude build tools from the final image."
echo "  • Choose a smaller base (alpine, slim, distroless, scratch)."
echo "  • Combine RUN commands to reduce layer count."
echo "  • Add a .dockerignore to shrink the build context."
echo "  • Use 'docker scout recommendations' for lighter base suggestions."
