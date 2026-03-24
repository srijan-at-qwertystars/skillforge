#!/usr/bin/env bash
# check-coverage.sh — Report type annotation coverage for a Python project
#
# Usage:
#   ./check-coverage.sh [OPTIONS] [DIR]
#
# Options:
#   --mypy          Use mypy for coverage analysis (default)
#   --pyright       Use pyright for coverage analysis
#   --both          Run both analyzers
#   --html          Generate HTML report (mypy only)
#   --output DIR    Output directory for reports (default: type-coverage)
#   --summary       Print summary only (skip detailed file list)
#   -h, --help      Show this help
#
# Examples:
#   ./check-coverage.sh src/
#   ./check-coverage.sh --both --html src/
#   ./check-coverage.sh --pyright --summary mypackage/

set -euo pipefail

# Defaults
USE_MYPY=false
USE_PYRIGHT=false
GENERATE_HTML=false
OUTPUT_DIR="type-coverage"
SUMMARY_ONLY=false
TARGET_DIR=""

usage() {
    sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --mypy)     USE_MYPY=true; shift ;;
        --pyright)  USE_PYRIGHT=true; shift ;;
        --both)     USE_MYPY=true; USE_PYRIGHT=true; shift ;;
        --html)     GENERATE_HTML=true; shift ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        --summary)  SUMMARY_ONLY=true; shift ;;
        -h|--help)  usage ;;
        -*)         echo "Unknown option: $1"; usage ;;
        *)          TARGET_DIR="$1"; shift ;;
    esac
done

# Default to mypy
if ! $USE_MYPY && ! $USE_PYRIGHT; then
    USE_MYPY=true
fi

# Default target
if [[ -z "$TARGET_DIR" ]]; then
    if [[ -d "src" ]]; then
        TARGET_DIR="src"
    else
        TARGET_DIR="."
    fi
fi

mkdir -p "$OUTPUT_DIR"

echo "=== Type Coverage Report ==="
echo "Target: $TARGET_DIR"
echo ""

# ── Annotation counter (Python-based, no dependencies) ─────────────────────

count_annotations() {
    python3 << 'PYEOF' "$TARGET_DIR" "$SUMMARY_ONLY"
import ast
import sys
import os
from pathlib import Path

target = sys.argv[1]
summary_only = sys.argv[2] == "True"

stats = {"files": 0, "functions": 0, "annotated": 0, "partially": 0, "unannotated": 0}
file_stats = []

for root, dirs, files in os.walk(target):
    dirs[:] = [d for d in dirs if d not in {"__pycache__", ".venv", "venv", "node_modules", ".git"}]
    for fname in sorted(files):
        if not fname.endswith(".py"):
            continue
        fpath = os.path.join(root, fname)
        try:
            tree = ast.parse(Path(fpath).read_text(), filename=fpath)
        except SyntaxError:
            continue

        stats["files"] += 1
        file_funcs = 0
        file_annotated = 0

        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                file_funcs += 1
                stats["functions"] += 1

                has_return = node.returns is not None
                param_count = 0
                annotated_params = 0
                for arg in node.args.args + node.args.posonlyargs + node.args.kwonlyargs:
                    if arg.arg == "self" or arg.arg == "cls":
                        continue
                    param_count += 1
                    if arg.annotation is not None:
                        annotated_params += 1

                if node.args.vararg and node.args.vararg.annotation:
                    annotated_params += 1
                    param_count += 1
                elif node.args.vararg:
                    param_count += 1

                if node.args.kwarg and node.args.kwarg.annotation:
                    annotated_params += 1
                    param_count += 1
                elif node.args.kwarg:
                    param_count += 1

                fully = has_return and (param_count == 0 or annotated_params == param_count)
                if fully:
                    stats["annotated"] += 1
                    file_annotated += 1
                elif has_return or annotated_params > 0:
                    stats["partially"] += 1
                else:
                    stats["unannotated"] += 1

        if file_funcs > 0:
            pct = (file_annotated / file_funcs * 100) if file_funcs else 0
            file_stats.append((fpath, file_annotated, file_funcs, pct))

if not summary_only and file_stats:
    print(f"{'File':<60} {'Typed':>6} {'Total':>6} {'Coverage':>9}")
    print("─" * 85)
    for fpath, ann, total, pct in sorted(file_stats, key=lambda x: x[3]):
        icon = "✅" if pct == 100 else "⚠️ " if pct > 0 else "❌"
        print(f"{icon} {fpath:<57} {ann:>6} {total:>6} {pct:>8.1f}%")
    print("─" * 85)

total = stats["functions"]
annotated = stats["annotated"]
pct = (annotated / total * 100) if total > 0 else 0

print(f"\nSummary:")
print(f"  Files scanned:        {stats['files']}")
print(f"  Total functions:      {total}")
print(f"  Fully annotated:      {annotated} ({pct:.1f}%)")
print(f"  Partially annotated:  {stats['partially']}")
print(f"  Unannotated:          {stats['unannotated']}")
print(f"  Coverage:             {pct:.1f}%")
PYEOF
}

# ── mypy coverage ───────────────────────────────────────────────────────────

mypy_coverage() {
    echo "── mypy Coverage Analysis ──"

    if ! command -v mypy &>/dev/null; then
        echo "mypy not found. Install with: pip install mypy"
        return 1
    fi

    # Generate reports
    local report_args=("--txt-report" "$OUTPUT_DIR/mypy-txt")
    if $GENERATE_HTML; then
        report_args+=("--html-report" "$OUTPUT_DIR/mypy-html")
    fi
    report_args+=("--linecount-report" "$OUTPUT_DIR/mypy-linecount")
    report_args+=("--any-exprs-report" "$OUTPUT_DIR/mypy-any-exprs")

    echo "Running mypy analysis (this may take a moment)..."
    mypy "$TARGET_DIR" "${report_args[@]}" --no-error-summary 2>/dev/null || true

    # Display text report if available
    if [[ -f "$OUTPUT_DIR/mypy-txt/index.txt" ]]; then
        if $SUMMARY_ONLY; then
            tail -5 "$OUTPUT_DIR/mypy-txt/index.txt"
        else
            cat "$OUTPUT_DIR/mypy-txt/index.txt"
        fi
    fi

    # Display linecount summary
    if [[ -f "$OUTPUT_DIR/mypy-linecount/linecount.txt" ]]; then
        echo ""
        echo "Line-level precision:"
        cat "$OUTPUT_DIR/mypy-linecount/linecount.txt"
    fi

    if $GENERATE_HTML && [[ -d "$OUTPUT_DIR/mypy-html" ]]; then
        echo ""
        echo "HTML report: $OUTPUT_DIR/mypy-html/index.html"
    fi

    echo ""
}

# ── pyright coverage ────────────────────────────────────────────────────────

pyright_coverage() {
    echo "── pyright Coverage Analysis ──"

    if ! command -v pyright &>/dev/null; then
        echo "pyright not found. Install with: pip install pyright"
        return 1
    fi

    echo "Running pyright analysis..."

    # Pyright outputs diagnostics; count errors/warnings for coverage signal
    local output
    output=$(pyright "$TARGET_DIR" 2>&1) || true

    # Extract summary line
    echo "$output" | tail -5

    # Save full output
    echo "$output" > "$OUTPUT_DIR/pyright-report.txt"
    echo ""
    echo "Full report: $OUTPUT_DIR/pyright-report.txt"
    echo ""
}

# ── Annotation-level coverage (always runs) ─────────────────────────────────

echo "── Annotation Coverage (AST analysis) ──"
count_annotations
echo ""

# Run checker-specific analysis
$USE_MYPY && mypy_coverage
$USE_PYRIGHT && pyright_coverage

echo "=== Reports saved to $OUTPUT_DIR/ ==="
