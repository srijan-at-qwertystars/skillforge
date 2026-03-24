#!/usr/bin/env bash
# validate-rules.sh — Validate Prometheus recording and alerting rules files.
# Uses promtool to check rule syntax, expression validity, and naming conventions.
#
# Usage:
#   ./validate-rules.sh [path ...]
#
# Arguments:
#   path    File or directory containing .yml/.yaml rule files.
#           Defaults to current directory if no arguments given.
#
# Examples:
#   ./validate-rules.sh rules/
#   ./validate-rules.sh alerting-rules.yml recording-rules.yml
#   ./validate-rules.sh /etc/prometheus/rules/
#
# Requirements:
#   - promtool (ships with Prometheus binary distribution)
#     Install: https://prometheus.io/download/

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TOTAL_FILES=0
PASSED=0
FAILED=0
SKIPPED=0
FAILED_FILES=()

# ─── Helpers ─────────────────────────────────────────────────────────────────

check_promtool() {
  if ! command -v promtool &>/dev/null; then
    echo -e "${RED}ERROR: promtool is not installed or not in PATH.${NC}" >&2
    echo "" >&2
    echo "Install promtool:" >&2
    echo "  Option 1: Download from https://prometheus.io/download/" >&2
    echo "  Option 2: go install github.com/prometheus/prometheus/cmd/promtool@latest" >&2
    echo "  Option 3: brew install prometheus  (macOS)" >&2
    echo "  Option 4: apt install prometheus   (Debian/Ubuntu)" >&2
    exit 1
  fi
  echo -e "Using promtool: $(command -v promtool)"
  echo -e "Version: $(promtool --version 2>&1 | head -1)"
  echo ""
}

find_rule_files() {
  local search_path="$1"

  if [[ -f "${search_path}" ]]; then
    echo "${search_path}"
    return
  fi

  if [[ -d "${search_path}" ]]; then
    find "${search_path}" -type f \( -name "*.yml" -o -name "*.yaml" \) | sort
    return
  fi

  echo -e "${YELLOW}WARNING: '${search_path}' is not a file or directory, skipping.${NC}" >&2
}

validate_file() {
  local file="$1"
  TOTAL_FILES=$((TOTAL_FILES + 1))

  # Quick check: does the file look like a rules file?
  if ! grep -qE '^\s*(groups:|rules:|- record:|- alert:)' "$file" 2>/dev/null; then
    echo -e "  ${YELLOW}SKIP${NC}  ${file}  (does not appear to be a rules file)"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  # Run promtool validation
  local output
  if output=$(promtool check rules "$file" 2>&1); then
    echo -e "  ${GREEN}PASS${NC}  ${file}"
    PASSED=$((PASSED + 1))

    # Show summary of rules found
    local alert_count recording_count
    alert_count=$(grep -cE '^\s*- alert:' "$file" 2>/dev/null || echo 0)
    recording_count=$(grep -cE '^\s*- record:' "$file" 2>/dev/null || echo 0)
    if [[ ${alert_count} -gt 0 || ${recording_count} -gt 0 ]]; then
      echo "        └─ ${alert_count} alerting rule(s), ${recording_count} recording rule(s)"
    fi
  else
    echo -e "  ${RED}FAIL${NC}  ${file}"
    echo "${output}" | sed 's/^/        /'
    FAILED=$((FAILED + 1))
    FAILED_FILES+=("${file}")
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

echo "═══════════════════════════════════════════════════"
echo " Prometheus Rules Validator"
echo "═══════════════════════════════════════════════════"
echo ""

check_promtool

# Default to current directory if no arguments
PATHS=("${@:-.}")

echo "Scanning for rule files..."
echo ""

for path in "${PATHS[@]}"; do
  while IFS= read -r file; do
    [[ -n "${file}" ]] && validate_file "${file}"
  done < <(find_rule_files "${path}")
done

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════"
echo " Results"
echo "═══════════════════════════════════════════════════"
printf "  Total files scanned:  %d\n" "${TOTAL_FILES}"
printf "  ${GREEN}Passed:${NC}               %d\n" "${PASSED}"
printf "  ${RED}Failed:${NC}               %d\n" "${FAILED}"
printf "  ${YELLOW}Skipped:${NC}              %d\n" "${SKIPPED}"

if [[ ${FAILED} -gt 0 ]]; then
  echo ""
  echo -e "${RED}Failed files:${NC}"
  for f in "${FAILED_FILES[@]}"; do
    echo "  - ${f}"
  done
  echo ""
  exit 1
fi

echo ""
echo -e "${GREEN}All rules files are valid.${NC}"
exit 0
