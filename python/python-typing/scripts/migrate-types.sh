#!/usr/bin/env bash
# migrate-types.sh — Migrate a Python project from untyped to fully typed
#
# Usage:
#   ./migrate-types.sh [PHASE] [OPTIONS] [DIR]
#
# Phases (run in order):
#   phase1    Baseline: install tools, scan current state
#   phase2    Auto-annotate: use MonkeyType/pytype to generate draft annotations
#   phase3    Validate: run mypy/pyright, report remaining errors
#   phase4    Strict: enable strict mode, generate final coverage report
#   all       Run all phases sequentially
#
# Options:
#   --tool monkeytype   Use MonkeyType for auto-annotation (default)
#   --tool pytype       Use pytype for auto-annotation
#   --test-cmd CMD      Test command for MonkeyType tracing (default: pytest)
#   --dry-run           Show what would be done without making changes
#   -h, --help          Show this help
#
# Examples:
#   ./migrate-types.sh phase1 src/
#   ./migrate-types.sh phase2 --tool monkeytype --test-cmd "pytest tests/" src/
#   ./migrate-types.sh all mypackage/
#
# Workflow:
#   1. Run phase1 to understand current state
#   2. Run phase2 to auto-generate draft annotations
#   3. Review and refine annotations manually
#   4. Run phase3 to validate with type checkers
#   5. Run phase4 to enable strict mode and measure final coverage

set -euo pipefail

# Defaults
PHASE=""
TOOL="monkeytype"
TEST_CMD="pytest"
DRY_RUN=false
TARGET_DIR=""

usage() {
    sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        phase1|phase2|phase3|phase4|all) PHASE="$1"; shift ;;
        --tool)     TOOL="$2"; shift 2 ;;
        --test-cmd) TEST_CMD="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        -h|--help)  usage ;;
        -*)         echo "Unknown option: $1"; usage ;;
        *)          TARGET_DIR="$1"; shift ;;
    esac
done

if [[ -z "$PHASE" ]]; then
    echo "Error: specify a phase (phase1, phase2, phase3, phase4, or all)"
    usage
fi

if [[ -z "$TARGET_DIR" ]]; then
    if [[ -d "src" ]]; then TARGET_DIR="src"
    else TARGET_DIR="."; fi
fi

echo "=== Type Migration Tool ==="
echo "Phase:   $PHASE"
echo "Target:  $TARGET_DIR"
echo "Tool:    $TOOL"
echo ""

# ── Phase 1: Baseline ──────────────────────────────────────────────────────

phase1() {
    echo "═══ Phase 1: Baseline Assessment ═══"
    echo ""

    # Check/install tools
    echo "── Checking tools ──"
    for cmd in python3 pip; do
        if command -v "$cmd" &>/dev/null; then
            echo "  ✅ $cmd: $(command -v "$cmd")"
        else
            echo "  ❌ $cmd: not found"
            exit 1
        fi
    done

    # Install type checkers
    echo ""
    echo "── Installing type checkers ──"
    pip install mypy pyright typing-extensions --quiet
    echo "  ✅ mypy $(mypy --version 2>&1 | head -1)"
    echo "  ✅ pyright installed"
    echo "  ✅ typing-extensions installed"

    # Count current annotations
    echo ""
    echo "── Current Annotation Status ──"
    python3 << 'PYEOF' "$TARGET_DIR"
import ast, os, sys
from pathlib import Path

target = sys.argv[1]
total_funcs = 0
annotated = 0
files = 0
py_files = []

for root, dirs, fnames in os.walk(target):
    dirs[:] = [d for d in dirs if d not in {"__pycache__", ".venv", "venv", ".git"}]
    for f in fnames:
        if f.endswith(".py"):
            py_files.append(os.path.join(root, f))

for fpath in sorted(py_files):
    try:
        tree = ast.parse(Path(fpath).read_text())
    except SyntaxError:
        continue
    files += 1
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            total_funcs += 1
            has_any = node.returns is not None or any(
                a.annotation is not None
                for a in node.args.args + node.args.posonlyargs + node.args.kwonlyargs
                if a.arg not in ("self", "cls")
            )
            if has_any:
                annotated += 1

pct = (annotated / total_funcs * 100) if total_funcs else 0
print(f"  Python files:     {files}")
print(f"  Total functions:  {total_funcs}")
print(f"  With any types:   {annotated} ({pct:.1f}%)")
print(f"  Without types:    {total_funcs - annotated}")
print(f"  Starting coverage: {pct:.1f}%")
PYEOF

    # Quick mypy scan
    echo ""
    echo "── mypy Baseline (permissive mode) ──"
    mypy "$TARGET_DIR" --ignore-missing-imports --no-error-summary 2>&1 | tail -5 || true

    echo ""
    echo "Phase 1 complete. Review the baseline, then run phase2."
}

# ── Phase 2: Auto-Annotate ─────────────────────────────────────────────────

phase2() {
    echo "═══ Phase 2: Auto-Annotation ═══"
    echo ""

    if [[ "$TOOL" == "monkeytype" ]]; then
        phase2_monkeytype
    elif [[ "$TOOL" == "pytype" ]]; then
        phase2_pytype
    else
        echo "Unknown tool: $TOOL (use monkeytype or pytype)"
        exit 1
    fi
}

phase2_monkeytype() {
    echo "── Using MonkeyType ──"

    # Install
    pip install MonkeyType --quiet
    echo "  ✅ MonkeyType installed"

    if $DRY_RUN; then
        echo ""
        echo "Dry run — would execute:"
        echo "  1. monkeytype run $TEST_CMD"
        echo "  2. monkeytype list-modules"
        echo "  3. monkeytype apply <module> (for each module)"
        return
    fi

    # Collect type traces by running tests
    echo ""
    echo "── Collecting type traces ──"
    echo "Running: monkeytype run $TEST_CMD"
    if monkeytype run $TEST_CMD 2>&1; then
        echo "  ✅ Trace collection complete"
    else
        echo "  ⚠️  Test run had errors (traces may be partial)"
    fi

    # List discovered modules
    echo ""
    echo "── Discovered modules ──"
    local modules
    modules=$(monkeytype list-modules 2>/dev/null || true)

    if [[ -z "$modules" ]]; then
        echo "  No modules traced. Ensure tests exercise your code."
        echo "  Try: monkeytype run pytest tests/ -x"
        return
    fi

    echo "$modules"

    # Apply annotations
    echo ""
    echo "── Applying annotations ──"
    while IFS= read -r module; do
        if [[ -n "$module" ]]; then
            echo "  Annotating: $module"
            monkeytype apply "$module" 2>&1 || echo "    ⚠️  Failed for $module"
        fi
    done <<< "$modules"

    echo ""
    echo "  ✅ Draft annotations applied"
    echo "  ⚠️  Review changes carefully — MonkeyType infers concrete types only"
    echo "  Tip: Replace list[int] with Sequence[int] for parameters"
}

phase2_pytype() {
    echo "── Using pytype ──"

    pip install pytype --quiet 2>/dev/null || {
        echo "  ⚠️  pytype installation failed (may not support this Python/OS)"
        echo "  Try: pip install pytype"
        echo "  Alternative: use --tool monkeytype"
        return 1
    }

    echo "  ✅ pytype installed"

    if $DRY_RUN; then
        echo "Dry run — would execute:"
        echo "  1. pytype $TARGET_DIR"
        echo "  2. merge-pyi (for each inferred .pyi)"
        return
    fi

    echo ""
    echo "── Running pytype inference ──"
    pytype "$TARGET_DIR" 2>&1 || true

    echo ""
    echo "── Merging inferred types ──"
    if command -v merge-pyi &>/dev/null; then
        find .pytype/pyi -name "*.pyi" 2>/dev/null | while read -r pyi; do
            local py="${pyi%.pyi}.py"
            py="${py#.pytype/pyi/}"
            if [[ -f "$py" ]]; then
                echo "  Merging: $py"
                merge-pyi -i "$py" "$pyi" || true
            fi
        done
    fi

    echo ""
    echo "  ✅ pytype inference complete"
}

# ── Phase 3: Validate ──────────────────────────────────────────────────────

phase3() {
    echo "═══ Phase 3: Validation ═══"
    echo ""

    echo "── mypy check (standard mode) ──"
    local mypy_errors
    mypy_errors=$(mypy "$TARGET_DIR" --ignore-missing-imports --show-error-codes 2>&1) || true
    local error_count
    error_count=$(echo "$mypy_errors" | grep -c "error:" || true)

    if [[ "$error_count" -eq 0 ]]; then
        echo "  ✅ No mypy errors!"
    else
        echo "  Found $error_count errors"
        echo ""
        # Group by error code
        echo "  Errors by type:"
        echo "$mypy_errors" | grep "error:" | grep -oP '\[\K[^\]]+' | sort | uniq -c | sort -rn | head -15 | while read -r count code; do
            printf "    %-30s %s\n" "[$code]" "$count"
        done
        echo ""
        echo "  First 10 errors:"
        echo "$mypy_errors" | grep "error:" | head -10 | sed 's/^/    /'
    fi

    echo ""
    echo "── pyright check ──"
    if command -v pyright &>/dev/null; then
        local pyright_output
        pyright_output=$(pyright "$TARGET_DIR" 2>&1) || true
        echo "$pyright_output" | tail -3
    else
        echo "  pyright not installed (pip install pyright)"
    fi

    echo ""
    echo "Phase 3 complete. Fix reported errors, then run phase4."
}

# ── Phase 4: Strict Mode ───────────────────────────────────────────────────

phase4() {
    echo "═══ Phase 4: Strict Mode ═══"
    echo ""

    echo "── mypy --strict ──"
    local strict_errors
    strict_errors=$(mypy "$TARGET_DIR" --strict --show-error-codes 2>&1) || true
    local error_count
    error_count=$(echo "$strict_errors" | grep -c "error:" || true)

    echo "  Strict mode errors: $error_count"

    if [[ "$error_count" -gt 0 ]]; then
        echo ""
        echo "  Errors by type:"
        echo "$strict_errors" | grep "error:" | grep -oP '\[\K[^\]]+' | sort | uniq -c | sort -rn | head -10 | while read -r count code; do
            printf "    %-30s %s\n" "[$code]" "$count"
        done
    fi

    # Final coverage
    echo ""
    echo "── Final Coverage ──"
    python3 << 'PYEOF' "$TARGET_DIR"
import ast, os, sys
from pathlib import Path

target = sys.argv[1]
total = annotated = 0

for root, dirs, fnames in os.walk(target):
    dirs[:] = [d for d in dirs if d not in {"__pycache__", ".venv", "venv", ".git"}]
    for f in fnames:
        if not f.endswith(".py"): continue
        try: tree = ast.parse(Path(os.path.join(root, f)).read_text())
        except SyntaxError: continue
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                total += 1
                if node.returns is not None:
                    annotated += 1

pct = (annotated / total * 100) if total else 0
print(f"  Functions with return type: {annotated}/{total} ({pct:.1f}%)")
if pct >= 90: print("  🎉 Excellent coverage!")
elif pct >= 70: print("  👍 Good coverage — keep going!")
elif pct >= 50: print("  ⚠️  Moderate coverage — focus on public APIs")
else: print("  📝 Low coverage — continue with phase2/phase3 iterations")
PYEOF

    echo ""
    echo "═══ Migration Summary ═══"
    echo "  Strict mode errors: $error_count"
    echo ""
    echo "Next steps:"
    echo "  1. Fix remaining strict-mode errors"
    echo "  2. Add mypy/pyright to CI: mypy src/ --strict"
    echo "  3. Create py.typed marker for PEP 561"
    echo "  4. Consider runtime checking (beartype) at I/O boundaries"
}

# ── Execute phases ──────────────────────────────────────────────────────────

case "$PHASE" in
    phase1) phase1 ;;
    phase2) phase2 ;;
    phase3) phase3 ;;
    phase4) phase4 ;;
    all)    phase1; echo ""; phase2; echo ""; phase3; echo ""; phase4 ;;
esac
