#!/usr/bin/env bash
# gleam-ci.sh — CI pipeline for Gleam projects
#
# Usage:
#   ./gleam-ci.sh                 # Run full CI pipeline (format, build, test for Erlang target)
#   ./gleam-ci.sh --all-targets   # Test both Erlang and JavaScript targets
#   ./gleam-ci.sh --skip-format   # Skip format check
#   ./gleam-ci.sh --step format   # Run only the format step
#   ./gleam-ci.sh --step build    # Run only the build step
#   ./gleam-ci.sh --step test     # Run only the test step
#
# Exit codes:
#   0 — All checks passed
#   1 — One or more checks failed
#
# Environment variables:
#   GLEAM_CI_TARGET   — Override target (erlang, javascript, both). Default: erlang
#   GLEAM_CI_VERBOSE  — Set to "true" for verbose output

set -euo pipefail

ALL_TARGETS=false
SKIP_FORMAT=false
SINGLE_STEP=""
TARGET="${GLEAM_CI_TARGET:-erlang}"
VERBOSE="${GLEAM_CI_VERBOSE:-false}"
FAILED=0
STEPS_RUN=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-targets)  ALL_TARGETS=true; shift ;;
    --skip-format)  SKIP_FORMAT=true; shift ;;
    --step)         SINGLE_STEP="$2"; shift 2 ;;
    --target)       TARGET="$2"; shift 2 ;;
    --verbose)      VERBOSE=true; shift ;;
    -h|--help)      head -14 "$0" | tail -12; exit 0 ;;
    *)              echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if $ALL_TARGETS; then
  TARGET="both"
fi

# ── Output Helpers ────────────────────────────────────────────────────────────
info()    { echo -e "\033[1;34m▸\033[0m $*"; }
success() { echo -e "\033[1;32m✓\033[0m $*"; }
fail()    { echo -e "\033[1;31m✗\033[0m $*"; FAILED=$((FAILED + 1)); }
header()  { echo ""; echo -e "\033[1;37m══ $* ══\033[0m"; }

run_step() {
  local name="$1"
  shift

  # Skip if running a single step and this isn't it
  if [[ -n "$SINGLE_STEP" && "$SINGLE_STEP" != "$name" ]]; then
    return
  fi

  STEPS_RUN=$((STEPS_RUN + 1))
  header "$name"

  if "$@"; then
    success "$name passed"
  else
    fail "$name FAILED"
  fi
}

# ── CI Steps ──────────────────────────────────────────────────────────────────
step_format() {
  info "Checking code formatting..."
  gleam format --check
}

step_build_erlang() {
  info "Building for Erlang target..."
  gleam build --target erlang
}

step_build_javascript() {
  info "Building for JavaScript target..."
  gleam build --target javascript
}

step_test_erlang() {
  info "Running tests (Erlang target)..."
  gleam test --target erlang
}

step_test_javascript() {
  info "Running tests (JavaScript target)..."
  gleam test --target javascript
}

# ── Main Pipeline ─────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "╔══════════════════════════════════════╗"
  echo "║       Gleam CI Pipeline              ║"
  echo "╚══════════════════════════════════════╝"
  echo ""
  info "Target: $TARGET"
  info "Working directory: $(pwd)"
  info "Gleam version: $(gleam --version 2>/dev/null || echo 'not found')"
  echo ""

  # Check gleam is available
  if ! command -v gleam &>/dev/null; then
    fail "Gleam is not installed"
    exit 1
  fi

  # Download dependencies
  header "Dependencies"
  info "Downloading dependencies..."
  gleam deps download
  success "Dependencies downloaded"

  # Format check
  if ! $SKIP_FORMAT; then
    run_step "format" step_format
  fi

  # Build
  case "$TARGET" in
    erlang)
      run_step "build-erlang" step_build_erlang
      ;;
    javascript)
      run_step "build-javascript" step_build_javascript
      ;;
    both)
      run_step "build-erlang" step_build_erlang
      run_step "build-javascript" step_build_javascript
      ;;
  esac

  # Test
  case "$TARGET" in
    erlang)
      run_step "test-erlang" step_test_erlang
      ;;
    javascript)
      run_step "test-javascript" step_test_javascript
      ;;
    both)
      run_step "test-erlang" step_test_erlang
      run_step "test-javascript" step_test_javascript
      ;;
  esac

  # ── Summary ──────────────────────────────────────────────────────────────────
  echo ""
  echo "────────────────────────────────────────"
  if [[ $FAILED -eq 0 ]]; then
    success "All $STEPS_RUN steps passed!"
    exit 0
  else
    fail "$FAILED of $STEPS_RUN steps failed"
    exit 1
  fi
}

main
