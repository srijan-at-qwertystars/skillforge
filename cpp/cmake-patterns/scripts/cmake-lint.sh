#!/usr/bin/env bash
# cmake-lint.sh — Lint CMakeLists.txt and .cmake files
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [directory]

Run cmake-lint and cmake-format checks on CMake files.
Falls back to built-in pattern checks if external tools aren't installed.

Options:
  -f, --fix          Auto-fix formatting issues (cmake-format only)
  -v, --verbose      Show all checks, not just failures
  -h, --help         Show this help

Examples:
  $(basename "$0")                # Lint current directory
  $(basename "$0") -f src/        # Lint and fix src/
  $(basename "$0") --verbose .    # Verbose lint of current dir
EOF
    exit "${1:-0}"
}

FIX=0
VERBOSE=0
TARGET_DIR="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--fix) FIX=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1" >&2; usage 1 ;;
        *) TARGET_DIR="$1"; shift ;;
    esac
done

# Collect CMake files
CMAKE_FILES=()
while IFS= read -r -d '' file; do
    CMAKE_FILES+=("$file")
done < <(find "$TARGET_DIR" -type f \( -name "CMakeLists.txt" -o -name "*.cmake" \) \
    ! -path "*/build/*" ! -path "*/_deps/*" ! -path "*/cmake-build-*/*" \
    ! -path "*/.cache/*" ! -path "*/vcpkg_installed/*" \
    -print0 2>/dev/null)

if [[ ${#CMAKE_FILES[@]} -eq 0 ]]; then
    echo "No CMake files found in '$TARGET_DIR'"
    exit 0
fi

echo "Found ${#CMAKE_FILES[@]} CMake file(s) to check"
echo ""

ERRORS=0
WARNINGS=0

# --- Try cmake-lint (pip install cmakelang) ---
if command -v cmake-lint &>/dev/null; then
    echo "=== cmake-lint ==="
    for file in "${CMAKE_FILES[@]}"; do
        if [[ $VERBOSE -eq 1 ]]; then
            echo "Checking: $file"
        fi
        if ! cmake-lint "$file" 2>&1; then
            ((ERRORS++)) || true
        fi
    done
    echo ""
else
    echo "ℹ cmake-lint not found (install: pip install cmakelang)"
    echo ""
fi

# --- Try cmake-format ---
if command -v cmake-format &>/dev/null; then
    echo "=== cmake-format ==="
    for file in "${CMAKE_FILES[@]}"; do
        if [[ $FIX -eq 1 ]]; then
            cmake-format -i "$file"
            echo "Formatted: $file"
        else
            if ! diff -u "$file" <(cmake-format "$file") 2>/dev/null; then
                echo "⚠ Format differs: $file (use --fix to auto-format)"
                ((WARNINGS++)) || true
            elif [[ $VERBOSE -eq 1 ]]; then
                echo "✓ $file"
            fi
        fi
    done
    echo ""
else
    echo "ℹ cmake-format not found (install: pip install cmakelang)"
    echo ""
fi

# --- Built-in pattern checks (always run) ---
echo "=== Built-in pattern checks ==="

check_pattern() {
    local pattern="$1"
    local message="$2"
    local severity="$3"  # error or warning
    
    for file in "${CMAKE_FILES[@]}"; do
        local matches
        matches=$(grep -n "$pattern" "$file" 2>/dev/null || true)
        if [[ -n "$matches" ]]; then
            while IFS= read -r match; do
                local line_num="${match%%:*}"
                local line_content="${match#*:}"
                # Skip comments
                local trimmed
                trimmed=$(echo "$line_content" | sed 's/^[[:space:]]*//')
                if [[ "$trimmed" == \#* ]]; then
                    continue
                fi
                if [[ "$severity" == "error" ]]; then
                    echo "ERROR $file:$line_num: $message"
                    echo "  → $line_content"
                    ((ERRORS++)) || true
                else
                    echo "WARN  $file:$line_num: $message"
                    echo "  → $line_content"
                    ((WARNINGS++)) || true
                fi
            done <<< "$matches"
        fi
    done
}

# Anti-pattern: global include_directories
check_pattern "^[[:space:]]*include_directories\b" \
    "Use target_include_directories() instead of include_directories()" "error"

# Anti-pattern: global link_directories
check_pattern "^[[:space:]]*link_directories\b" \
    "Use target_link_libraries() with imported targets instead of link_directories()" "error"

# Anti-pattern: global link_libraries
check_pattern "^[[:space:]]*link_libraries\b" \
    "Use target_link_libraries() instead of link_libraries()" "error"

# Anti-pattern: global add_definitions
check_pattern "^[[:space:]]*add_definitions\b" \
    "Use target_compile_definitions() instead of add_definitions()" "error"

# Anti-pattern: global add_compile_options (sometimes acceptable)
check_pattern "^[[:space:]]*add_compile_options\b" \
    "Consider target_compile_options() instead of add_compile_options()" "warning"

# Anti-pattern: file(GLOB for sources
check_pattern "file[[:space:]]*(GLOB[[:space:]]" \
    "Avoid file(GLOB) for sources — list files explicitly" "warning"

# Anti-pattern: global CMAKE_CXX_STANDARD
check_pattern "^[[:space:]]*set[[:space:]]*(CMAKE_CXX_STANDARD\b" \
    "Use target_compile_features(target PUBLIC cxx_std_XX) instead" "warning"

# Anti-pattern: CMAKE_CXX_FLAGS manipulation
check_pattern "set[[:space:]]*(CMAKE_CXX_FLAGS" \
    "Use target_compile_options() instead of modifying CMAKE_CXX_FLAGS" "warning"

# Anti-pattern: cmake_minimum_required too old
check_pattern "cmake_minimum_required[[:space:]]*(VERSION[[:space:]]*2\." \
    "CMake 2.x is obsolete — upgrade to cmake_minimum_required(VERSION 3.20)" "error"

# Missing: visibility keywords
for file in "${CMAKE_FILES[@]}"; do
    matches=$(grep -n "target_link_libraries\|target_include_directories\|target_compile_definitions\|target_compile_options" "$file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        while IFS= read -r match; do
            line_content="${match#*:}"
            trimmed=$(echo "$line_content" | sed 's/^[[:space:]]*//')
            [[ "$trimmed" == \#* ]] && continue
            if ! echo "$line_content" | grep -qiE "PUBLIC|PRIVATE|INTERFACE"; then
                line_num="${match%%:*}"
                echo "WARN  $file:$line_num: Missing visibility keyword (PUBLIC/PRIVATE/INTERFACE)"
                echo "  → $line_content"
                ((WARNINGS++)) || true
            fi
        done <<< "$matches"
    fi
done

echo ""
echo "=== Summary ==="
echo "Files checked: ${#CMAKE_FILES[@]}"
echo "Errors: $ERRORS"
echo "Warnings: $WARNINGS"

if [[ $ERRORS -gt 0 ]]; then
    exit 1
fi
exit 0
