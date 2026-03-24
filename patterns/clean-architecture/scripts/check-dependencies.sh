#!/usr/bin/env bash
# =============================================================================
# check-dependencies.sh — Verify Clean Architecture dependency rule
#
# Usage:
#   ./check-dependencies.sh [source-dir]
#
# Defaults to ./src if no directory is provided.
#
# Checks that inner layers do not import from outer layers:
#   - domain/ must NOT import from application/, infrastructure/, presentation/
#   - application/ must NOT import from infrastructure/, presentation/
#   - Inner layers depend only on themselves or layers further inside.
#
# Reports violations with file path, line number, and the offending import.
#
# Exit codes:
#   0 — No violations found
#   1 — Violations found
#   2 — Source directory not found
#
# Examples:
#   ./check-dependencies.sh
#   ./check-dependencies.sh ./src
#   ./check-dependencies.sh ./internal   # for Go projects
# =============================================================================

set -euo pipefail

SRC_DIR="${1:-.\/src}"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Error: Source directory '$SRC_DIR' not found."
  echo "Usage: $0 [source-dir]"
  exit 2
fi

VIOLATIONS=0
VIOLATION_DETAILS=""

# Color output if terminal supports it
RED=""
GREEN=""
YELLOW=""
RESET=""
if [[ -t 1 ]]; then
  RED="\033[0;31m"
  GREEN="\033[0;32m"
  YELLOW="\033[0;33m"
  RESET="\033[0m"
fi

# =============================================================================
# Define forbidden import patterns per layer
# =============================================================================

# Layer: domain
# Forbidden: application, infrastructure, presentation
check_domain_violations() {
  local domain_dir
  # Support both domain/ and internal/domain/
  for domain_dir in "$SRC_DIR/domain" "$SRC_DIR/internal/domain"; do
    [[ -d "$domain_dir" ]] || continue

    # TypeScript/JavaScript imports
    while IFS=: read -r file line content; do
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_DETAILS+="  ${RED}VIOLATION${RESET} domain → outer layer\n"
      VIOLATION_DETAILS+="    File: $file:$line\n"
      VIOLATION_DETAILS+="    Import: $(echo "$content" | sed 's/^[[:space:]]*//')\n\n"
    done < <(grep -rn \
      -e "from ['\"].*\(application\|infrastructure\|presentation\|adapter\|usecase\)" \
      -e "import.*from ['\"].*\(application\|infrastructure\|presentation\|adapter\|usecase\)" \
      -e "require(['\"].*\(application\|infrastructure\|presentation\|adapter\|usecase\)" \
      "$domain_dir" \
      --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
      2>/dev/null || true)

    # Python imports
    while IFS=: read -r file line content; do
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_DETAILS+="  ${RED}VIOLATION${RESET} domain → outer layer\n"
      VIOLATION_DETAILS+="    File: $file:$line\n"
      VIOLATION_DETAILS+="    Import: $(echo "$content" | sed 's/^[[:space:]]*//')\n\n"
    done < <(grep -rn \
      -e "from \(application\|infrastructure\|presentation\|adapter\|usecase\)" \
      -e "import \(application\|infrastructure\|presentation\|adapter\|usecase\)" \
      "$domain_dir" \
      --include="*.py" \
      2>/dev/null || true)

    # Go imports
    while IFS=: read -r file line content; do
      # Skip if importing from own domain subpackages
      if echo "$content" | grep -q "domain/"; then
        continue
      fi
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_DETAILS+="  ${RED}VIOLATION${RESET} domain → outer layer\n"
      VIOLATION_DETAILS+="    File: $file:$line\n"
      VIOLATION_DETAILS+="    Import: $(echo "$content" | sed 's/^[[:space:]]*//')\n\n"
    done < <(grep -rn \
      -e "\".*\(application\|infrastructure\|presentation\|adapter\|usecase\)" \
      "$domain_dir" \
      --include="*.go" \
      2>/dev/null || true)
  done
}

# Layer: application / usecase
# Forbidden: infrastructure, presentation
check_application_violations() {
  local app_dir
  for app_dir in "$SRC_DIR/application" "$SRC_DIR/internal/usecase" "$SRC_DIR/use-cases" "$SRC_DIR/application"; do
    [[ -d "$app_dir" ]] || continue

    # TypeScript/JavaScript imports
    while IFS=: read -r file line content; do
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_DETAILS+="  ${RED}VIOLATION${RESET} application → outer layer\n"
      VIOLATION_DETAILS+="    File: $file:$line\n"
      VIOLATION_DETAILS+="    Import: $(echo "$content" | sed 's/^[[:space:]]*//')\n\n"
    done < <(grep -rn \
      -e "from ['\"].*\(infrastructure\|presentation\|adapter\)" \
      -e "import.*from ['\"].*\(infrastructure\|presentation\|adapter\)" \
      -e "require(['\"].*\(infrastructure\|presentation\|adapter\)" \
      "$app_dir" \
      --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
      2>/dev/null || true)

    # Python imports
    while IFS=: read -r file line content; do
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_DETAILS+="  ${RED}VIOLATION${RESET} application → outer layer\n"
      VIOLATION_DETAILS+="    File: $file:$line\n"
      VIOLATION_DETAILS+="    Import: $(echo "$content" | sed 's/^[[:space:]]*//')\n\n"
    done < <(grep -rn \
      -e "from \(infrastructure\|presentation\|adapter\)" \
      -e "import \(infrastructure\|presentation\|adapter\)" \
      "$app_dir" \
      --include="*.py" \
      2>/dev/null || true)

    # Go imports
    while IFS=: read -r file line content; do
      VIOLATIONS=$((VIOLATIONS + 1))
      VIOLATION_DETAILS+="  ${RED}VIOLATION${RESET} application → outer layer\n"
      VIOLATION_DETAILS+="    File: $file:$line\n"
      VIOLATION_DETAILS+="    Import: $(echo "$content" | sed 's/^[[:space:]]*//')\n\n"
    done < <(grep -rn \
      -e "\".*\(infrastructure\|presentation\|adapter\)" \
      "$app_dir" \
      --include="*.go" \
      2>/dev/null || true)
  done
}

# =============================================================================
# Run checks
# =============================================================================

echo "🔍 Checking Clean Architecture dependency rules in: $SRC_DIR"
echo ""

check_domain_violations
check_application_violations

# =============================================================================
# Report results
# =============================================================================

if [[ $VIOLATIONS -eq 0 ]]; then
  echo -e "${GREEN}✅ No dependency rule violations found.${RESET}"
  echo ""
  echo "Layer dependency rules verified:"
  echo "  domain → (no outer imports)     ✓"
  echo "  application → domain only       ✓"
  exit 0
else
  echo -e "${RED}❌ Found $VIOLATIONS dependency rule violation(s):${RESET}"
  echo ""
  echo -e "$VIOLATION_DETAILS"
  echo "Dependency rules:"
  echo "  domain/       → must NOT import from application/, infrastructure/, presentation/"
  echo "  application/  → must NOT import from infrastructure/, presentation/"
  echo ""
  echo "Fix: Move shared types to the domain layer, or use dependency inversion"
  echo "     (define interfaces in inner layers, implement in outer layers)."
  exit 1
fi
