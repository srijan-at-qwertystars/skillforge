#!/usr/bin/env bash
# =============================================================================
# diff-specs.sh — Compare two OpenAPI specs for breaking changes
#
# Usage:
#   ./diff-specs.sh <base-spec> <new-spec> [options]
#
# Options:
#   --format         Output format: text (default), json, yaml, markdown
#   --fail-on        Fail on severity: ERR (default), WARN, INFO
#   --breaking-only  Show only breaking changes (default: false)
#   --exclude-elements  Comma-separated list of elements to exclude
#   -h, --help       Show this help message
#
# Examples:
#   ./diff-specs.sh v1/openapi.yaml v2/openapi.yaml
#   ./diff-specs.sh base.yaml new.yaml --breaking-only
#   ./diff-specs.sh base.yaml new.yaml --format markdown > changelog.md
#   ./diff-specs.sh base.yaml new.yaml --fail-on WARN
#   ./diff-specs.sh https://api.example.com/openapi.yaml ./openapi.yaml
#
# Prerequisites:
#   go install github.com/tufin/oasdiff@latest
#   # Or: brew install oasdiff
#   # Or: docker pull tufin/oasdiff
#
# Exit codes:
#   0 — No breaking changes (or only info-level changes)
#   1 — Breaking changes detected at or above --fail-on level
#   2 — Usage error
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_SPEC=""
NEW_SPEC=""
FORMAT="text"
FAIL_ON="ERR"
BREAKING_ONLY=false
EXCLUDE_ELEMENTS=""

usage() {
  sed -n '/^# ====/,/^# ====/{ /^# ====/d; s/^# //; s/^#//; p; }' "$0" | head -n 22
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --format) FORMAT="$2"; shift 2 ;;
    --fail-on) FAIL_ON="$2"; shift 2 ;;
    --breaking-only) BREAKING_ONLY=true; shift ;;
    --exclude-elements) EXCLUDE_ELEMENTS="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *)
      if [ -z "$BASE_SPEC" ]; then
        BASE_SPEC="$1"
      elif [ -z "$NEW_SPEC" ]; then
        NEW_SPEC="$1"
      else
        echo "Error: Too many arguments"
        usage
      fi
      shift
      ;;
  esac
done

if [ -z "$BASE_SPEC" ] || [ -z "$NEW_SPEC" ]; then
  echo -e "${RED}Error: Both base spec and new spec are required.${NC}"
  usage
fi

# Validate files exist (skip for URLs)
for spec in "$BASE_SPEC" "$NEW_SPEC"; do
  if [[ ! "$spec" =~ ^https?:// ]] && [ ! -f "$spec" ]; then
    echo -e "${RED}Error: File not found: $spec${NC}"
    exit 2
  fi
done

# Find oasdiff
OASDIFF_CMD=""
if command -v oasdiff &>/dev/null; then
  OASDIFF_CMD="oasdiff"
elif docker image inspect tufin/oasdiff &>/dev/null 2>&1; then
  OASDIFF_CMD="docker run --rm -v $(pwd):/work -w /work tufin/oasdiff"
else
  echo -e "${RED}Error: oasdiff not found.${NC}"
  echo ""
  echo "Install with one of:"
  echo "  go install github.com/tufin/oasdiff@latest"
  echo "  brew install oasdiff"
  echo "  docker pull tufin/oasdiff"
  exit 2
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  OpenAPI Spec Diff${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Base:          $BASE_SPEC"
echo "  New:           $NEW_SPEC"
echo "  Format:        $FORMAT"
echo "  Fail on:       $FAIL_ON"
echo "  Breaking only: $BREAKING_ONLY"
echo ""

# ── Breaking changes check ───────────────────────────────────────────────────
echo -e "${BLUE}Checking for breaking changes...${NC}"
echo ""

BREAKING_ARGS=("breaking" "$BASE_SPEC" "$NEW_SPEC")
BREAKING_ARGS+=("--fail-on" "$FAIL_ON")

if [ "$FORMAT" != "text" ]; then
  BREAKING_ARGS+=("--format" "$FORMAT")
fi

if [ -n "$EXCLUDE_ELEMENTS" ]; then
  BREAKING_ARGS+=("--exclude-elements" "$EXCLUDE_ELEMENTS")
fi

BREAKING_EXIT=0
$OASDIFF_CMD "${BREAKING_ARGS[@]}" || BREAKING_EXIT=$?

if [ $BREAKING_EXIT -eq 0 ]; then
  echo ""
  echo -e "${GREEN}✅ No breaking changes detected at $FAIL_ON level or above.${NC}"
else
  echo ""
  echo -e "${RED}❌ Breaking changes detected!${NC}"
fi

# ── Full diff (unless breaking-only) ─────────────────────────────────────────
if [ "$BREAKING_ONLY" = false ]; then
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  Full diff${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  DIFF_ARGS=("diff" "$BASE_SPEC" "$NEW_SPEC")
  if [ "$FORMAT" != "text" ]; then
    DIFF_ARGS+=("--format" "$FORMAT")
  fi
  if [ -n "$EXCLUDE_ELEMENTS" ]; then
    DIFF_ARGS+=("--exclude-elements" "$EXCLUDE_ELEMENTS")
  fi

  $OASDIFF_CMD "${DIFF_ARGS[@]}" || true
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Summary: Also consider running a full changelog:${NC}"
echo -e "${BLUE}    $OASDIFF_CMD changelog $BASE_SPEC $NEW_SPEC${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

exit $BREAKING_EXIT
