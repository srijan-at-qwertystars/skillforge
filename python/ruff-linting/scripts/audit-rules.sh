#!/usr/bin/env bash
# audit-rules.sh — Analyze codebase for current violations, suggest rule adoption strategy
#
# Usage:
#   ./audit-rules.sh [project-dir] [options]
#
# Options:
#   --select RULES     Comma-separated rule prefixes to audit (default: ALL)
#   --top N            Show top N rules by violation count (default: 30)
#   --output FILE      Write report to file (default: stdout)
#   --fixable-only     Only show rules that have auto-fixes
#   --suggest          Print adoption strategy recommendations
#
# This script:
#   1. Runs ruff check with ALL (or specified) rules
#   2. Collects violation statistics
#   3. Groups by category and severity
#   4. Suggests an incremental adoption plan
#
# Requirements: ruff (installed and on PATH)

set -euo pipefail

# ---- Parse arguments ----
PROJECT_DIR="."
SELECT_RULES="ALL"
TOP_N=30
OUTPUT_FILE=""
FIXABLE_ONLY=false
SUGGEST=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --select)
            SELECT_RULES="$2"
            shift 2
            ;;
        --top)
            TOP_N="$2"
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --fixable-only)
            FIXABLE_ONLY=true
            shift
            ;;
        --suggest)
            SUGGEST=true
            shift
            ;;
        --no-suggest)
            SUGGEST=false
            shift
            ;;
        *)
            PROJECT_DIR="$1"
            shift
            ;;
    esac
done

cd "$PROJECT_DIR"

# ---- Check prerequisites ----
if ! command -v ruff &>/dev/null; then
    echo "ERROR: ruff is not installed. Install with: pip install ruff"
    exit 1
fi

# ---- Setup output ----
if [[ -n "$OUTPUT_FILE" ]]; then
    exec > "$OUTPUT_FILE"
fi

RUFF_VERSION=$(ruff --version 2>/dev/null || echo "unknown")

echo "================================================================"
echo "  Ruff Rule Audit Report"
echo "================================================================"
echo ""
echo "  Directory:    $(pwd)"
echo "  Ruff version: $RUFF_VERSION"
echo "  Rules:        $SELECT_RULES"
echo "  Date:         $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
echo ""
echo "================================================================"
echo ""

# ---- Count Python files ----
PY_COUNT=$(find . -name "*.py" -not -path "./.venv/*" -not -path "./venv/*" \
    -not -path "./.git/*" -not -path "./node_modules/*" \
    -not -path "./__pycache__/*" -not -path "./build/*" \
    -not -path "./dist/*" 2>/dev/null | wc -l | tr -d '[:space:]')
echo "Python files found: $PY_COUNT"
echo ""

if [[ "$PY_COUNT" -eq 0 ]]; then
    echo "No Python files found. Exiting."
    exit 0
fi

# ---- Run ruff with statistics ----
echo "## Violation Summary"
echo ""

STATS_OUTPUT=$(ruff check --select "$SELECT_RULES" --statistics --no-cache . 2>/dev/null || true)

if [[ -z "$STATS_OUTPUT" ]]; then
    echo "✅ No violations found with select = $SELECT_RULES"
    echo ""
    echo "Your codebase is clean! Consider enabling more rules."
    exit 0
fi

TOTAL_VIOLATIONS=$(echo "$STATS_OUTPUT" | awk '{sum += $1} END {print sum}')
TOTAL_RULES=$(echo "$STATS_OUTPUT" | wc -l | tr -d '[:space:]')

echo "Total violations:  $TOTAL_VIOLATIONS"
echo "Distinct rules:    $TOTAL_RULES"
echo ""

# ---- Top rules by count ----
echo "## Top $TOP_N Rules by Violation Count"
echo ""
printf "%-8s %-8s %s\n" "COUNT" "CODE" "DESCRIPTION"
printf "%-8s %-8s %s\n" "-----" "----" "-----------"
echo "$STATS_OUTPUT" | sort -rn | head -"$TOP_N" | while IFS= read -r line; do
    count=$(echo "$line" | awk '{print $1}')
    rest=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ //')
    code=$(echo "$rest" | awk '{print $1}')
    desc=$(echo "$rest" | awk '{$1=""; print $0}' | sed 's/^ //')
    printf "%-8s %-8s %s\n" "$count" "$code" "$desc"
done
echo ""

# ---- Group by category ----
echo "## Violations by Category"
echo ""
printf "%-8s %-10s %s\n" "COUNT" "PREFIX" "CATEGORY"
printf "%-8s %-10s %s\n" "-----" "------" "--------"

declare -A CATEGORY_NAMES
CATEGORY_NAMES=(
    ["E"]="pycodestyle errors"
    ["W"]="pycodestyle warnings"
    ["F"]="Pyflakes"
    ["I"]="isort"
    ["N"]="pep8-naming"
    ["UP"]="pyupgrade"
    ["S"]="bandit (security)"
    ["B"]="flake8-bugbear"
    ["A"]="flake8-builtins"
    ["C4"]="flake8-comprehensions"
    ["C9"]="mccabe complexity"
    ["D"]="pydocstyle"
    ["SIM"]="flake8-simplify"
    ["PT"]="flake8-pytest-style"
    ["RET"]="flake8-return"
    ["ARG"]="flake8-unused-arguments"
    ["DTZ"]="flake8-datetimez"
    ["ISC"]="implicit-str-concat"
    ["ICN"]="import-conventions"
    ["PL"]="Pylint"
    ["PERF"]="Perflint"
    ["RUF"]="Ruff-specific"
    ["ANN"]="flake8-annotations"
    ["FA"]="flake8-future-annotations"
    ["TCH"]="flake8-type-checking"
    ["T20"]="flake8-print"
    ["ERA"]="eradicate"
    ["FBT"]="flake8-boolean-trap"
    ["PIE"]="flake8-pie"
    ["NPY"]="NumPy-specific"
    ["FURB"]="refurb"
    ["DJ"]="flake8-django"
    ["ASYNC"]="flake8-async"
    ["TID"]="flake8-tidy-imports"
    ["COM"]="flake8-commas"
)

# Extract category counts
declare -A CAT_COUNTS
while IFS= read -r line; do
    count=$(echo "$line" | awk '{print $1}')
    code=$(echo "$line" | awk '{print $2}')

    # Extract prefix (letters only)
    prefix=$(echo "$code" | sed 's/[0-9].*//')

    if [[ -v "CAT_COUNTS[$prefix]" ]]; then
        CAT_COUNTS[$prefix]=$(( ${CAT_COUNTS[$prefix]} + count ))
    else
        CAT_COUNTS[$prefix]=$count
    fi
done <<< "$STATS_OUTPUT"

# Sort and print
for prefix in $(for k in "${!CAT_COUNTS[@]}"; do echo "$k ${CAT_COUNTS[$k]}"; done | sort -k2 -rn | awk '{print $1}'); do
    count=${CAT_COUNTS[$prefix]}
    name="${CATEGORY_NAMES[$prefix]:-unknown}"
    printf "%-8s %-10s %s\n" "$count" "$prefix" "$name"
done
echo ""

# ---- Files with most violations ----
echo "## Top 15 Files by Violation Count"
echo ""
ruff check --select "$SELECT_RULES" --no-cache . 2>/dev/null | \
    awk -F: '{print $1}' | sort | uniq -c | sort -rn | head -15 | \
    while read -r count file; do
        printf "  %5s  %s\n" "$count" "$file"
    done || true
echo ""

# ---- Fixable analysis ----
echo "## Auto-fix Potential"
echo ""
FIXABLE_COUNT=$(ruff check --select "$SELECT_RULES" --no-cache . 2>/dev/null | grep -c "\[*\]" || echo "0")
if [[ "$TOTAL_VIOLATIONS" -gt 0 ]]; then
    FIXABLE_PCT=$((FIXABLE_COUNT * 100 / TOTAL_VIOLATIONS))
else
    FIXABLE_PCT=0
fi
echo "Fixable violations:     $FIXABLE_COUNT / $TOTAL_VIOLATIONS ($FIXABLE_PCT%)"
echo ""
echo "To auto-fix safe issues:   ruff check --select $SELECT_RULES --fix ."
echo "To fix including unsafe:   ruff check --select $SELECT_RULES --fix --unsafe-fixes ."
echo ""

# ---- Adoption strategy ----
if $SUGGEST; then
    echo "================================================================"
    echo "  Recommended Adoption Strategy"
    echo "================================================================"
    echo ""
    echo "Phase 1 — Foundation (zero/low violation categories):"
    echo "  Enable categories with 0-10 violations. Fix them immediately."
    echo ""

    phase1=()
    phase2=()
    phase3=()

    for prefix in "${!CAT_COUNTS[@]}"; do
        count=${CAT_COUNTS[$prefix]}
        if [[ $count -le 10 ]]; then
            phase1+=("$prefix($count)")
        elif [[ $count -le 50 ]]; then
            phase2+=("$prefix($count)")
        else
            phase3+=("$prefix($count)")
        fi
    done

    if [[ ${#phase1[@]} -gt 0 ]]; then
        echo "  Candidates: ${phase1[*]}"
    else
        echo "  (none — all categories have >10 violations)"
    fi

    echo ""
    echo "Phase 2 — Incremental (moderate violation categories):"
    echo "  Enable categories with 11-50 violations. Fix with --fix where possible."
    echo ""
    if [[ ${#phase2[@]} -gt 0 ]]; then
        echo "  Candidates: ${phase2[*]}"
    else
        echo "  (none)"
    fi

    echo ""
    echo "Phase 3 — Major cleanup (high violation categories):"
    echo "  Categories with 50+ violations. Plan dedicated cleanup sprints."
    echo ""
    if [[ ${#phase3[@]} -gt 0 ]]; then
        echo "  Candidates: ${phase3[*]}"
    else
        echo "  (none — great job!)"
    fi

    echo ""
    echo "General approach:"
    echo "  1. Start config:  select = [\"E\", \"F\", \"W\", \"I\"]"
    echo "  2. Run:           ruff check --fix ."
    echo "  3. Add one new category at a time from Phase 1"
    echo "  4. Fix violations, commit, repeat"
    echo "  5. Use per-file-ignores for legacy code that can't be fixed yet"
    echo ""
fi

echo "================================================================"
echo "  End of Audit Report"
echo "================================================================"
