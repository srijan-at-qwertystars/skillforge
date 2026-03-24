#!/usr/bin/env bash
# =============================================================================
# validate-spec.sh — Validate an OpenAPI spec with multiple tools
#
# Usage:
#   ./validate-spec.sh <spec-file> [--strict] [--format json|text]
#
# Examples:
#   ./validate-spec.sh openapi.yaml
#   ./validate-spec.sh openapi.yaml --strict
#   ./validate-spec.sh openapi.yaml --format json
#
# Tools used (in order):
#   1. Spectral     — Style linting and best practices
#   2. Redocly CLI  — Structural validation and bundling check
#   3. swagger-cli  — JSON Schema validation
#
# Prerequisites:
#   npm install -g @stoplight/spectral-cli @redocly/cli @apidevtools/swagger-cli
#
# Exit codes:
#   0 — All validators passed
#   1 — One or more validators found errors
#   2 — Usage error (missing spec file, missing tools)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SPEC_FILE=""
STRICT=false
FORMAT="text"
EXIT_CODE=0

usage() {
  echo "Usage: $0 <spec-file> [--strict] [--format json|text]"
  echo ""
  echo "Options:"
  echo "  --strict       Treat warnings as errors"
  echo "  --format       Output format: text (default) or json"
  echo "  -h, --help     Show this help message"
  exit 2
}

log_header() {
  if [ "$FORMAT" = "text" ]; then
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  fi
}

log_pass() {
  if [ "$FORMAT" = "text" ]; then
    echo -e "  ${GREEN}✅ PASS${NC} — $1"
  fi
}

log_fail() {
  if [ "$FORMAT" = "text" ]; then
    echo -e "  ${RED}❌ FAIL${NC} — $1"
  fi
}

log_skip() {
  if [ "$FORMAT" = "text" ]; then
    echo -e "  ${YELLOW}⏭  SKIP${NC} — $1 (not installed)"
  fi
}

log_warn() {
  if [ "$FORMAT" = "text" ]; then
    echo -e "  ${YELLOW}⚠️  WARN${NC} — $1"
  fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --strict) STRICT=true; shift ;;
    --format) FORMAT="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1"; usage ;;
    *) SPEC_FILE="$1"; shift ;;
  esac
done

if [ -z "$SPEC_FILE" ]; then
  echo "Error: No spec file specified."
  usage
fi

if [ ! -f "$SPEC_FILE" ]; then
  echo "Error: File not found: $SPEC_FILE"
  exit 2
fi

RESULTS=()

# ── Spectral ─────────────────────────────────────────────────────────────────
log_header "Spectral — Style Linting"

if command -v spectral &>/dev/null; then
  SPECTRAL_ARGS=("lint" "$SPEC_FILE")
  if [ "$STRICT" = true ]; then
    SPECTRAL_ARGS+=("--fail-severity" "warn")
  else
    SPECTRAL_ARGS+=("--fail-severity" "error")
  fi
  if [ "$FORMAT" = "json" ]; then
    SPECTRAL_ARGS+=("--format" "json")
  fi

  if spectral "${SPECTRAL_ARGS[@]}"; then
    log_pass "Spectral"
    RESULTS+=("spectral:pass")
  else
    log_fail "Spectral found issues"
    RESULTS+=("spectral:fail")
    EXIT_CODE=1
  fi
else
  log_skip "Spectral"
  RESULTS+=("spectral:skipped")
fi

# ── Redocly CLI ──────────────────────────────────────────────────────────────
log_header "Redocly CLI — Structural Validation"

if command -v redocly &>/dev/null || npx --yes @redocly/cli --version &>/dev/null 2>&1; then
  REDOCLY_CMD="redocly"
  if ! command -v redocly &>/dev/null; then
    REDOCLY_CMD="npx --yes @redocly/cli"
  fi

  REDOCLY_ARGS=("lint" "$SPEC_FILE")
  if [ "$FORMAT" = "json" ]; then
    REDOCLY_ARGS+=("--format" "json")
  fi

  if $REDOCLY_CMD "${REDOCLY_ARGS[@]}"; then
    log_pass "Redocly CLI"
    RESULTS+=("redocly:pass")
  else
    log_fail "Redocly CLI found issues"
    RESULTS+=("redocly:fail")
    EXIT_CODE=1
  fi
else
  log_skip "Redocly CLI"
  RESULTS+=("redocly:skipped")
fi

# ── swagger-cli ──────────────────────────────────────────────────────────────
log_header "swagger-cli — Schema Validation"

if command -v swagger-cli &>/dev/null || npx --yes @apidevtools/swagger-cli --version &>/dev/null 2>&1; then
  SWAGGER_CMD="swagger-cli"
  if ! command -v swagger-cli &>/dev/null; then
    SWAGGER_CMD="npx --yes @apidevtools/swagger-cli"
  fi

  if $SWAGGER_CMD validate "$SPEC_FILE"; then
    log_pass "swagger-cli"
    RESULTS+=("swagger-cli:pass")
  else
    log_fail "swagger-cli found issues"
    RESULTS+=("swagger-cli:fail")
    EXIT_CODE=1
  fi
else
  log_skip "swagger-cli"
  RESULTS+=("swagger-cli:skipped")
fi

# ── Summary ──────────────────────────────────────────────────────────────────
log_header "Summary"

if [ "$FORMAT" = "json" ]; then
  echo "{"
  echo "  \"file\": \"$SPEC_FILE\","
  echo "  \"strict\": $STRICT,"
  echo "  \"results\": {"
  for result in "${RESULTS[@]}"; do
    tool="${result%%:*}"
    status="${result##*:}"
    echo "    \"$tool\": \"$status\","
  done
  echo "  },"
  echo "  \"overallStatus\": $([ $EXIT_CODE -eq 0 ] && echo '"pass"' || echo '"fail"')"
  echo "}"
else
  echo ""
  echo "  File: $SPEC_FILE"
  echo "  Strict mode: $STRICT"
  echo ""
  for result in "${RESULTS[@]}"; do
    tool="${result%%:*}"
    status="${result##*:}"
    case $status in
      pass) log_pass "$tool" ;;
      fail) log_fail "$tool" ;;
      skipped) log_skip "$tool" ;;
    esac
  done
  echo ""
  if [ $EXIT_CODE -eq 0 ]; then
    echo -e "  ${GREEN}All validators passed ✅${NC}"
  else
    echo -e "  ${RED}Validation failed ❌${NC}"
  fi
fi

exit $EXIT_CODE
