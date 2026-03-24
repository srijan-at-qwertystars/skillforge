#!/usr/bin/env bash
# wasm-inspect.sh — Inspect a WASM binary: exports, imports, memory, sections, size
#
# Usage: wasm-inspect.sh <file.wasm> [--json]
#   file.wasm   Path to a WebAssembly binary
#   --json      Output in JSON format (requires jq)
#
# Uses wasm-tools (preferred) or falls back to wasm-objdump.
# Install: cargo install wasm-tools  OR  apt install wabt

set -euo pipefail

WASM_FILE="${1:?Usage: $0 <file.wasm> [--json]}"
JSON_OUTPUT="${2:-}"

if [[ ! -f "$WASM_FILE" ]]; then
    echo "Error: File not found: $WASM_FILE" >&2
    exit 1
fi

# Validate it's actually a WASM file (magic bytes: \0asm)
MAGIC=$(xxd -l 4 -p "$WASM_FILE" 2>/dev/null || true)
if [[ "$MAGIC" != "0061736d" ]]; then
    echo "Error: Not a valid WASM file (bad magic bytes): $WASM_FILE" >&2
    exit 1
fi

# File info
FILE_SIZE=$(wc -c < "$WASM_FILE")
FILE_SIZE_KB=$(( FILE_SIZE / 1024 ))
WASM_VERSION=$(xxd -s 4 -l 4 -e "$WASM_FILE" 2>/dev/null | awk '{print $2}' || echo "unknown")

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  WASM Binary Inspector                                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "File:    $WASM_FILE"
echo "Size:    $FILE_SIZE bytes ($FILE_SIZE_KB KiB)"
echo "Version: $WASM_VERSION"
echo ""

# Determine which tool to use
USE_WASM_TOOLS=0
USE_WASM_OBJDUMP=0

if command -v wasm-tools &>/dev/null; then
    USE_WASM_TOOLS=1
elif command -v wasm-objdump &>/dev/null; then
    USE_WASM_OBJDUMP=1
fi

# Check if it's a component or core module
IS_COMPONENT=0
if [[ $USE_WASM_TOOLS -eq 1 ]]; then
    if wasm-tools component wit "$WASM_FILE" &>/dev/null; then
        IS_COMPONENT=1
        echo "Type:    Component (Component Model)"
    else
        echo "Type:    Core Module"
    fi
    echo ""
fi

# --- EXPORTS ---
echo "────────────────── EXPORTS ──────────────────"
if [[ $USE_WASM_TOOLS -eq 1 ]]; then
    if [[ $IS_COMPONENT -eq 1 ]]; then
        echo "(Component WIT exports:)"
        wasm-tools component wit "$WASM_FILE" 2>/dev/null | grep -E '^\s*export' || echo "  (none)"
        echo ""
        echo "(Detailed WIT:)"
        wasm-tools component wit "$WASM_FILE" 2>/dev/null || true
    else
        wasm-tools print "$WASM_FILE" 2>/dev/null | grep '(export' | \
            sed 's/.*(\(export\)/  \1/' || echo "  (none)"
    fi
elif [[ $USE_WASM_OBJDUMP -eq 1 ]]; then
    wasm-objdump -x "$WASM_FILE" 2>/dev/null | \
        sed -n '/^Export\[/,/^[A-Z]/p' | head -50 || echo "  (none)"
else
    echo "  (install wasm-tools or wabt for detailed export listing)"
fi
echo ""

# --- IMPORTS ---
echo "────────────────── IMPORTS ──────────────────"
if [[ $USE_WASM_TOOLS -eq 1 ]]; then
    if [[ $IS_COMPONENT -eq 1 ]]; then
        wasm-tools component wit "$WASM_FILE" 2>/dev/null | grep -E '^\s*import' || echo "  (none)"
    else
        wasm-tools print "$WASM_FILE" 2>/dev/null | grep '(import' | \
            sed 's/.*(\(import\)/  \1/' || echo "  (none)"
    fi
elif [[ $USE_WASM_OBJDUMP -eq 1 ]]; then
    wasm-objdump -x "$WASM_FILE" 2>/dev/null | \
        sed -n '/^Import\[/,/^[A-Z]/p' | head -50 || echo "  (none)"
else
    echo "  (install wasm-tools or wabt for detailed import listing)"
fi
echo ""

# --- MEMORY ---
echo "────────────────── MEMORY ──────────────────"
if [[ $USE_WASM_TOOLS -eq 1 ]] && [[ $IS_COMPONENT -eq 0 ]]; then
    MEMORY_INFO=$(wasm-tools print "$WASM_FILE" 2>/dev/null | grep -E '\(memory' || true)
    if [[ -n "$MEMORY_INFO" ]]; then
        echo "$MEMORY_INFO" | while read -r line; do
            echo "  $line"
            # Parse initial/max pages
            INIT=$(echo "$line" | grep -oP '\(memory \K\d+' || true)
            MAX=$(echo "$line" | grep -oP '\(memory \d+ \K\d+' || true)
            if [[ -n "$INIT" ]]; then
                echo "    Initial: $INIT pages ($((INIT * 64)) KiB)"
            fi
            if [[ -n "$MAX" ]]; then
                echo "    Maximum: $MAX pages ($((MAX * 64)) KiB)"
            fi
        done
    else
        echo "  (no memory section — may import memory)"
    fi
elif [[ $USE_WASM_OBJDUMP -eq 1 ]]; then
    wasm-objdump -x "$WASM_FILE" 2>/dev/null | grep -A5 'Memory\[' || echo "  (none)"
else
    echo "  (install wasm-tools or wabt for memory info)"
fi
echo ""

# --- TABLE ---
echo "────────────────── TABLE ──────────────────"
if [[ $USE_WASM_TOOLS -eq 1 ]] && [[ $IS_COMPONENT -eq 0 ]]; then
    wasm-tools print "$WASM_FILE" 2>/dev/null | grep -E '\(table' | \
        sed 's/.*(\(table\)/  \1/' || echo "  (none)"
elif [[ $USE_WASM_OBJDUMP -eq 1 ]]; then
    wasm-objdump -x "$WASM_FILE" 2>/dev/null | grep -A3 'Table\[' || echo "  (none)"
else
    echo "  (install wasm-tools or wabt for table info)"
fi
echo ""

# --- CUSTOM SECTIONS ---
echo "────────────────── CUSTOM SECTIONS ──────────────────"
if [[ $USE_WASM_TOOLS -eq 1 ]]; then
    wasm-tools dump "$WASM_FILE" 2>/dev/null | grep -i 'custom' | \
        sed 's/^/  /' || echo "  (none)"
elif [[ $USE_WASM_OBJDUMP -eq 1 ]]; then
    wasm-objdump -h "$WASM_FILE" 2>/dev/null | grep -i 'custom' | \
        sed 's/^/  /' || echo "  (none)"
else
    echo "  (install wasm-tools or wabt for section listing)"
fi
echo ""

# --- SECTIONS SUMMARY ---
echo "────────────────── SECTIONS SUMMARY ──────────────────"
if [[ $USE_WASM_TOOLS -eq 1 ]]; then
    wasm-tools dump "$WASM_FILE" 2>/dev/null | grep -E '^\s*(type|import|function|table|memory|global|export|start|element|code|data|custom)' | \
        sort | uniq -c | sort -rn | sed 's/^/  /' || echo "  (unable to parse sections)"
elif [[ $USE_WASM_OBJDUMP -eq 1 ]]; then
    wasm-objdump -h "$WASM_FILE" 2>/dev/null | sed 's/^/  /' || echo "  (unable to parse sections)"
fi
echo ""

# --- VALIDATION ---
echo "────────────────── VALIDATION ──────────────────"
if [[ $USE_WASM_TOOLS -eq 1 ]]; then
    if wasm-tools validate "$WASM_FILE" 2>&1; then
        echo "  ✅ Valid WASM binary"
    else
        echo "  ❌ Validation failed"
    fi
elif [[ $USE_WASM_OBJDUMP -eq 1 ]]; then
    echo "  (use wasm-tools validate for validation)"
fi
echo ""

# --- FUNCTION COUNT ---
if [[ $USE_WASM_TOOLS -eq 1 ]] && [[ $IS_COMPONENT -eq 0 ]]; then
    FUNC_COUNT=$(wasm-tools print "$WASM_FILE" 2>/dev/null | grep -c '(func' || echo 0)
    IMPORT_COUNT=$(wasm-tools print "$WASM_FILE" 2>/dev/null | grep -c '(import' || echo 0)
    EXPORT_COUNT=$(wasm-tools print "$WASM_FILE" 2>/dev/null | grep -c '(export' || echo 0)
    echo "────────────────── STATS ──────────────────"
    echo "  Functions: $FUNC_COUNT"
    echo "  Imports:   $IMPORT_COUNT"
    echo "  Exports:   $EXPORT_COUNT"
    echo "  Size:      $FILE_SIZE bytes ($FILE_SIZE_KB KiB)"
    echo ""
fi

echo "Done."
