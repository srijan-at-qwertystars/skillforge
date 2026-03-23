#!/usr/bin/env bash
# cmake-analyze.sh — Analyze a CMake project for anti-patterns and issues
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [directory]

Analyze a CMake project for anti-patterns, deprecated commands, and best-practice violations.

Options:
  -s, --summary      Show summary only (no file-level detail)
  -j, --json         Output results as JSON
  -h, --help         Show this help

Categories checked:
  • Global variable usage instead of target properties
  • Missing target_* commands
  • Old-style CMake commands
  • Missing modern features (presets, compile_commands, etc.)
  • Dependency management issues
  • Install/export issues

Example:
  $(basename "$0") /path/to/project
EOF
    exit "${1:-0}"
}

SUMMARY_ONLY=0
JSON_OUTPUT=0
TARGET_DIR="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--summary) SUMMARY_ONLY=1; shift ;;
        -j|--json) JSON_OUTPUT=1; shift ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1" >&2; usage 1 ;;
        *) TARGET_DIR="$1"; shift ;;
    esac
done

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: '$TARGET_DIR' is not a directory" >&2
    exit 1
fi

# Collect CMake files
CMAKE_FILES=()
while IFS= read -r -d '' file; do
    CMAKE_FILES+=("$file")
done < <(find "$TARGET_DIR" -type f \( -name "CMakeLists.txt" -o -name "*.cmake" \) \
    ! -path "*/build/*" ! -path "*/_deps/*" ! -path "*/cmake-build-*/*" \
    ! -path "*/.cache/*" ! -path "*/vcpkg_installed/*" ! -path "*/third_party/*" \
    -print0 2>/dev/null)

if [[ ${#CMAKE_FILES[@]} -eq 0 ]]; then
    echo "No CMake files found in '$TARGET_DIR'"
    exit 0
fi

# Counters
declare -A CATEGORY_COUNTS
CATEGORIES=(
    "global-variables"
    "old-style-commands"
    "missing-visibility"
    "missing-best-practices"
    "dependency-issues"
    "install-issues"
    "security"
)
for cat in "${CATEGORIES[@]}"; do
    CATEGORY_COUNTS[$cat]=0
done

TOTAL_ERRORS=0
TOTAL_WARNINGS=0

# Store findings
FINDINGS=()

add_finding() {
    local severity="$1"
    local category="$2"
    local file="$3"
    local line="$4"
    local message="$5"
    local suggestion="$6"

    ((CATEGORY_COUNTS[$category]++)) || true

    if [[ "$severity" == "error" ]]; then
        ((TOTAL_ERRORS++)) || true
    else
        ((TOTAL_WARNINGS++)) || true
    fi

    if [[ $SUMMARY_ONLY -eq 0 && $JSON_OUTPUT -eq 0 ]]; then
        local icon="⚠"
        [[ "$severity" == "error" ]] && icon="✗"
        printf "%s [%s] %s:%s\n  %s\n  → %s\n\n" "$icon" "$category" "$file" "$line" "$message" "$suggestion"
    fi

    if [[ $JSON_OUTPUT -eq 1 ]]; then
        FINDINGS+=("{\"severity\":\"$severity\",\"category\":\"$category\",\"file\":\"$file\",\"line\":$line,\"message\":\"$message\",\"suggestion\":\"$suggestion\"}")
    fi
}

# Read all cmake content for whole-project checks
ALL_CONTENT=""
for file in "${CMAKE_FILES[@]}"; do
    ALL_CONTENT+=$(cat "$file")$'\n'
done

# === ANALYSIS FUNCTIONS ===

analyze_global_variables() {
    local file="$1"
    local content
    content=$(cat "$file")
    local line_num=0

    while IFS= read -r line; do
        ((line_num++)) || true
        # Skip comments
        local trimmed
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
        [[ "$trimmed" == \#* || -z "$trimmed" ]] && continue

        # include_directories()
        if echo "$line" | grep -q "^[[:space:]]*include_directories\b"; then
            add_finding "error" "global-variables" "$file" "$line_num" \
                "Global include_directories() pollutes all targets" \
                "Replace with target_include_directories(target PRIVATE/PUBLIC ...)"
        fi

        # link_directories()
        if echo "$line" | grep -q "^[[:space:]]*link_directories\b"; then
            add_finding "error" "global-variables" "$file" "$line_num" \
                "Global link_directories() is fragile and deprecated" \
                "Use imported targets via find_package() instead"
        fi

        # link_libraries()
        if echo "$line" | grep -q "^[[:space:]]*link_libraries\b"; then
            add_finding "error" "global-variables" "$file" "$line_num" \
                "Global link_libraries() applies to all subsequent targets" \
                "Replace with target_link_libraries(target PRIVATE ...)"
        fi

        # add_definitions()
        if echo "$line" | grep -q "^[[:space:]]*add_definitions\b"; then
            add_finding "error" "global-variables" "$file" "$line_num" \
                "Global add_definitions() affects all targets" \
                "Replace with target_compile_definitions(target PRIVATE ...)"
        fi

        # CMAKE_CXX_FLAGS modification
        if echo "$line" | grep -q "set[[:space:]]*(CMAKE_CXX_FLAGS"; then
            add_finding "warning" "global-variables" "$file" "$line_num" \
                "Modifying CMAKE_CXX_FLAGS applies globally" \
                "Use target_compile_options(target PRIVATE ...) per target"
        fi

        # CMAKE_C_FLAGS modification
        if echo "$line" | grep -q "set[[:space:]]*(CMAKE_C_FLAGS"; then
            add_finding "warning" "global-variables" "$file" "$line_num" \
                "Modifying CMAKE_C_FLAGS applies globally" \
                "Use target_compile_options(target PRIVATE ...) per target"
        fi

        # Global CMAKE_CXX_STANDARD
        if echo "$line" | grep -q "^[[:space:]]*set[[:space:]]*(CMAKE_CXX_STANDARD\b"; then
            add_finding "warning" "global-variables" "$file" "$line_num" \
                "Setting CMAKE_CXX_STANDARD globally instead of per-target" \
                "Use target_compile_features(target PUBLIC cxx_std_XX)"
        fi

    done < "$file"
}

analyze_old_style() {
    local file="$1"
    local line_num=0

    while IFS= read -r line; do
        ((line_num++)) || true
        local trimmed
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
        [[ "$trimmed" == \#* || -z "$trimmed" ]] && continue

        # cmake_minimum_required VERSION 2.x
        if echo "$line" | grep -q "cmake_minimum_required.*VERSION[[:space:]]*2\."; then
            add_finding "error" "old-style-commands" "$file" "$line_num" \
                "CMake 2.x minimum is severely outdated" \
                "Upgrade to cmake_minimum_required(VERSION 3.20) or higher"
        fi

        # Bare target_link_libraries without keywords
        if echo "$line" | grep -qE "^[[:space:]]*target_link_libraries[[:space:]]*\([^)]+\)"; then
            if ! echo "$line" | grep -qiE "PUBLIC|PRIVATE|INTERFACE"; then
                # Multi-line check — look if it's a single-line call
                if echo "$line" | grep -q ")"; then
                    add_finding "warning" "missing-visibility" "$file" "$line_num" \
                        "target_link_libraries() without visibility keyword" \
                        "Add PUBLIC, PRIVATE, or INTERFACE keyword"
                fi
            fi
        fi

        # file(GLOB for sources
        if echo "$line" | grep -qE "file[[:space:]]*\(GLOB[[:space:]]"; then
            add_finding "warning" "old-style-commands" "$file" "$line_num" \
                "file(GLOB) for sources won't detect new files without reconfigure" \
                "List source files explicitly in add_library/add_executable"
        fi

        # Linking by file path
        if echo "$line" | grep -qE "target_link_libraries.*(/usr/lib|/opt/|/home/)"; then
            add_finding "error" "old-style-commands" "$file" "$line_num" \
                "Hardcoded library path in target_link_libraries" \
                "Use find_package() and imported targets instead"
        fi

        # Hardcoded paths for dependencies
        if echo "$line" | grep -qE "set\(.*_ROOT.*\"/home/|set\(.*_ROOT.*\"/opt/"; then
            add_finding "warning" "old-style-commands" "$file" "$line_num" \
                "Hardcoded dependency path" \
                "Use CMakePresets.json or toolchain files for path configuration"
        fi

        # add_compile_options
        if echo "$line" | grep -q "^[[:space:]]*add_compile_options\b"; then
            add_finding "warning" "old-style-commands" "$file" "$line_num" \
                "add_compile_options() is global to current directory and below" \
                "Consider target_compile_options(target PRIVATE ...) for precision"
        fi

    done < "$file"
}

analyze_best_practices() {
    local file="$1"
    local content
    content=$(cat "$file")
    local basename_file
    basename_file=$(basename "$file")

    # Only check top-level CMakeLists.txt for project-level issues
    if [[ "$basename_file" == "CMakeLists.txt" ]]; then
        # Missing project()
        if echo "$content" | grep -q "cmake_minimum_required" && \
           ! echo "$content" | grep -q "project("; then
            # Could be a subdirectory — only flag root
            if echo "$content" | grep -q "cmake_minimum_required"; then
                add_finding "warning" "missing-best-practices" "$file" "1" \
                    "cmake_minimum_required without project() in same file" \
                    "Add project(MyProject VERSION X.Y.Z LANGUAGES CXX)"
            fi
        fi
    fi

    # Library without ALIAS
    local line_num=0
    while IFS= read -r line; do
        ((line_num++)) || true
        local trimmed
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
        [[ "$trimmed" == \#* || -z "$trimmed" ]] && continue

        if echo "$line" | grep -qE "^[[:space:]]*add_library[[:space:]]*\([[:space:]]*[a-zA-Z_]+" ; then
            # Skip if ALIAS, IMPORTED, INTERFACE, OBJECT, or MODULE
            if ! echo "$line" | grep -qiE "ALIAS|IMPORTED|INTERFACE|OBJECT|MODULE"; then
                local lib_name
                lib_name=$(echo "$line" | sed -E 's/.*add_library[[:space:]]*\([[:space:]]*([a-zA-Z_0-9]+).*/\1/')
                # Check if an ALIAS exists for this target
                if ! grep -q "ALIAS[[:space:]]*${lib_name}" "$file" 2>/dev/null; then
                    add_finding "warning" "missing-best-practices" "$file" "$line_num" \
                        "Library '$lib_name' has no ALIAS target" \
                        "Add: add_library(Namespace::${lib_name} ALIAS ${lib_name})"
                fi
            fi
        fi
    done < "$file"
}

analyze_security() {
    local file="$1"
    local line_num=0

    while IFS= read -r line; do
        ((line_num++)) || true
        local trimmed
        trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
        [[ "$trimmed" == \#* || -z "$trimmed" ]] && continue

        # execute_process without ERROR_VARIABLE
        if echo "$line" | grep -q "execute_process"; then
            if ! echo "$line" | grep -qE "ERROR_VARIABLE|COMMAND_ERROR_IS_FATAL"; then
                add_finding "warning" "security" "$file" "$line_num" \
                    "execute_process() without error checking" \
                    "Add COMMAND_ERROR_IS_FATAL ANY or ERROR_VARIABLE + check"
            fi
        fi
    done < "$file"
}

# === RUN ANALYSIS ===

if [[ $JSON_OUTPUT -eq 0 ]]; then
    echo "╔══════════════════════════════════════════════╗"
    echo "║         CMake Project Analysis Report        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    echo "Directory: $(realpath "$TARGET_DIR")"
    echo "Files: ${#CMAKE_FILES[@]}"
    echo ""
fi

for file in "${CMAKE_FILES[@]}"; do
    analyze_global_variables "$file"
    analyze_old_style "$file"
    analyze_best_practices "$file"
    analyze_security "$file"
done

# === PROJECT-LEVEL CHECKS ===

# Check for CMakePresets.json
if [[ ! -f "$TARGET_DIR/CMakePresets.json" ]]; then
    add_finding "warning" "missing-best-practices" "$TARGET_DIR" "0" \
        "No CMakePresets.json found" \
        "Add CMakePresets.json for reproducible builds across developers and CI"
fi

# Check for compile_commands.json support
if ! echo "$ALL_CONTENT" | grep -q "CMAKE_EXPORT_COMPILE_COMMANDS"; then
    add_finding "warning" "missing-best-practices" "$TARGET_DIR" "0" \
        "CMAKE_EXPORT_COMPILE_COMMANDS not enabled" \
        "Add set(CMAKE_EXPORT_COMPILE_COMMANDS ON) or use presets for IDE/clangd support"
fi

# Check for install rules
HAS_LIBRARY=$(echo "$ALL_CONTENT" | grep -c "add_library" || true)
HAS_INSTALL=$(echo "$ALL_CONTENT" | grep -c "install(" || true)
if [[ $HAS_LIBRARY -gt 0 && $HAS_INSTALL -eq 0 ]]; then
    add_finding "warning" "install-issues" "$TARGET_DIR" "0" \
        "Libraries defined but no install() rules found" \
        "Add install(TARGETS ...) and export rules for library consumers"
fi

# === OUTPUT ===

if [[ $JSON_OUTPUT -eq 1 ]]; then
    echo "{"
    echo "  \"directory\": \"$(realpath "$TARGET_DIR")\","
    echo "  \"files_checked\": ${#CMAKE_FILES[@]},"
    echo "  \"total_errors\": $TOTAL_ERRORS,"
    echo "  \"total_warnings\": $TOTAL_WARNINGS,"
    echo "  \"categories\": {"
    first=1
    for cat in "${CATEGORIES[@]}"; do
        [[ $first -eq 0 ]] && echo ","
        printf "    \"%s\": %d" "$cat" "${CATEGORY_COUNTS[$cat]}"
        first=0
    done
    echo ""
    echo "  },"
    echo "  \"findings\": ["
    local_first=1
    for f in "${FINDINGS[@]}"; do
        [[ $local_first -eq 0 ]] && echo ","
        printf "    %s" "$f"
        local_first=0
    done
    echo ""
    echo "  ]"
    echo "}"
else
    echo "═══════════════════════════════════════════════"
    echo "Summary"
    echo "═══════════════════════════════════════════════"
    echo ""
    printf "  %-25s %s\n" "Files checked:" "${#CMAKE_FILES[@]}"
    printf "  %-25s %s\n" "Errors:" "$TOTAL_ERRORS"
    printf "  %-25s %s\n" "Warnings:" "$TOTAL_WARNINGS"
    echo ""
    echo "  By category:"
    for cat in "${CATEGORIES[@]}"; do
        count="${CATEGORY_COUNTS[$cat]}"
        if [[ $count -gt 0 ]]; then
            printf "    %-25s %d\n" "$cat:" "$count"
        fi
    done
    echo ""

    if [[ $TOTAL_ERRORS -eq 0 && $TOTAL_WARNINGS -eq 0 ]]; then
        echo "  ✅ No issues found — your CMake looks modern and clean!"
    elif [[ $TOTAL_ERRORS -eq 0 ]]; then
        echo "  ⚠ No errors, but consider addressing the warnings above."
    else
        echo "  ✗ Found $TOTAL_ERRORS error(s) that should be fixed."
    fi
    echo ""
fi

if [[ $TOTAL_ERRORS -gt 0 ]]; then
    exit 1
fi
exit 0
