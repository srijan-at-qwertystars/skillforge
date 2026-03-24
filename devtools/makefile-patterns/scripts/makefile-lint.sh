#!/usr/bin/env bash
# makefile-lint.sh — Lint Makefiles for common issues.
#
# Usage:
#   makefile-lint.sh [options] [makefile...]
#
# Options:
#   -q          Quiet mode (only show errors, not warnings)
#   -s          Strict mode (treat warnings as errors)
#   -f FORMAT   Output format: text (default), json
#   -h          Show help
#
# Checks performed:
#   [ERROR]   Recipe lines using spaces instead of tabs
#   [ERROR]   Missing .PHONY for non-file targets
#   [WARNING] Variables defined but never used
#   [WARNING] Missing .DELETE_ON_ERROR directive
#   [WARNING] Missing .DEFAULT_GOAL
#   [WARNING] Shell-specific syntax without SHELL override
#   [WARNING] Use of recursive make without + prefix
#   [WARNING] Missing help target
#   [WARNING] Targets without ## documentation comments
#   [INFO]    Suggestions for improvements
#
# Examples:
#   makefile-lint.sh                       # Lint ./Makefile
#   makefile-lint.sh Makefile build.mk     # Lint multiple files
#   makefile-lint.sh -s -q Makefile        # Strict + quiet

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────
QUIET=false
STRICT=false
FORMAT="text"
ERRORS=0
WARNINGS=0
INFOS=0

# ─── Parse Arguments ────────────────────────────────────────
usage() {
    sed -n '2,/^$/s/^# //p' "$0"
    exit "${1:-0}"
}

FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q) QUIET=true; shift ;;
        -s) STRICT=true; shift ;;
        -f) FORMAT="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        -*) echo "Unknown option: $1" >&2; usage 1 ;;
        *)  FILES+=("$1"); shift ;;
    esac
done

# Default to Makefile in current directory
if [[ ${#FILES[@]} -eq 0 ]]; then
    if [[ -f "Makefile" ]]; then
        FILES=("Makefile")
    elif [[ -f "makefile" ]]; then
        FILES=("makefile")
    elif [[ -f "GNUmakefile" ]]; then
        FILES=("GNUmakefile")
    else
        echo "Error: No Makefile found in current directory." >&2
        exit 1
    fi
fi

# ─── Output Helpers ─────────────────────────────────────────

report() {
    local level="$1" file="$2" line="$3" msg="$4"

    case "$level" in
        ERROR)   ((ERRORS++)) ;;
        WARNING) ((WARNINGS++)); $QUIET && return ;;
        INFO)    ((INFOS++)); $QUIET && return ;;
    esac

    if [[ "$FORMAT" == "json" ]]; then
        printf '{"level":"%s","file":"%s","line":%s,"message":"%s"}\n' \
            "$level" "$file" "$line" "$msg"
    else
        local color=""
        case "$level" in
            ERROR)   color="\033[31m" ;;
            WARNING) color="\033[33m" ;;
            INFO)    color="\033[36m" ;;
        esac
        printf "${color}[%-7s]\033[0m %s:%s: %s\n" "$level" "$file" "$line" "$msg"
    fi
}

# ─── Lint Checks ────────────────────────────────────────────

check_tabs_vs_spaces() {
    local file="$1"
    local in_recipe=false
    local lineno=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((lineno++))

        # Detect target lines (start of recipe)
        if [[ "$line" =~ ^[a-zA-Z_.%/\$][^:=]*: && ! "$line" =~ ^[[:space:]] ]]; then
            in_recipe=true
            continue
        fi

        # Blank line ends recipe context
        if [[ -z "$line" ]]; then
            in_recipe=false
            continue
        fi

        # Check recipe lines for spaces instead of tabs
        if $in_recipe; then
            if [[ "$line" =~ ^[[:space:]] && ! "$line" =~ ^$'\t' && ! "$line" =~ ^[[:space:]]*# ]]; then
                # Line starts with spaces, not tab — likely a recipe line
                if [[ "$line" =~ ^\ {2,} && ! "$line" =~ ^\ *[\$\(\)a-zA-Z_]*\ *[:+?]?= ]]; then
                    report "ERROR" "$file" "$lineno" \
                        "Recipe line uses spaces instead of tab: $(echo "$line" | head -c 60)"
                fi
            fi
        fi
    done < "$file"
}

check_phony_targets() {
    local file="$1"

    # Extract declared .PHONY targets
    local phony_targets
    phony_targets=$(grep -E '^\s*\.PHONY\s*:' "$file" 2>/dev/null | \
        sed 's/.*://' | tr ' ' '\n' | grep -v '^$' | sort -u || true)

    # Extract all targets
    local all_targets
    all_targets=$(grep -E '^[a-zA-Z_][a-zA-Z0-9_-]*\s*:' "$file" 2>/dev/null | \
        grep -v ':=' | sed 's/\s*:.*//' | sort -u || true)

    # Common non-file targets that should be .PHONY
    local common_phony="all build test lint clean install deploy run dev \
        fmt format check help docker push pull release dist distclean \
        coverage serve start stop restart"

    while IFS= read -r target; do
        [[ -z "$target" ]] && continue

        # Check if it's a common non-file target that's not declared .PHONY
        for phony in $common_phony; do
            if [[ "$target" == "$phony" ]]; then
                if ! echo "$phony_targets" | grep -qx "$target"; then
                    local lineno
                    lineno=$(grep -n "^${target}\s*:" "$file" | head -1 | cut -d: -f1)
                    report "ERROR" "$file" "${lineno:-0}" \
                        "Target '$target' is likely non-file but not declared .PHONY"
                fi
                break
            fi
        done
    done <<< "$all_targets"
}

check_unused_variables() {
    local file="$1"
    local content
    content=$(cat "$file")

    # Extract variable definitions
    local lineno=0
    while IFS= read -r line; do
        ((lineno++))

        # Match variable assignments: VAR := value, VAR = value, VAR ?= value
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)[[:space:]]*[:?+]?= ]]; then
            local varname="${BASH_REMATCH[1]}"

            # Skip common Make built-ins
            case "$varname" in
                SHELL|MAKEFLAGS|MAKECMDGOALS|CURDIR|MAKEFILE_LIST|MAKE|AR|CC|CXX) continue ;;
                .DEFAULT_GOAL) continue ;;
            esac

            # Count usages (excluding the definition line itself)
            local usage_count
            usage_count=$(grep -c "\$(${varname})\|\${${varname}}" "$file" 2>/dev/null || echo 0)
            # Also check for $() with parens
            local usage_count2
            usage_count2=$(grep -c "\$(${varname}[):]" "$file" 2>/dev/null || echo 0)

            # Subtract 1 for the definition if it uses itself (e.g., VAR += ...)
            if [[ $((usage_count + usage_count2)) -le 1 ]]; then
                # Check if it's exported or used in a recipe (harder to detect)
                if ! grep -q "export.*${varname}\|${varname}" <<< "$(grep -v "^${varname}" "$file" | grep "$varname")" 2>/dev/null; then
                    report "WARNING" "$file" "$lineno" \
                        "Variable '$varname' may be defined but never used"
                fi
            fi
        fi
    done < "$file"
}

check_directives() {
    local file="$1"

    # Check for .DELETE_ON_ERROR
    if ! grep -q '\.DELETE_ON_ERROR' "$file" 2>/dev/null; then
        report "WARNING" "$file" "1" \
            "Missing .DELETE_ON_ERROR directive (recommended for safe incremental builds)"
    fi

    # Check for .DEFAULT_GOAL
    if ! grep -q '\.DEFAULT_GOAL\|^\.PHONY.*all\b\|^all\s*:' "$file" 2>/dev/null; then
        report "WARNING" "$file" "1" \
            "No .DEFAULT_GOAL or 'all' target found — default target may be unexpected"
    fi

    # Check for help target
    if ! grep -q '^help\s*:' "$file" 2>/dev/null; then
        report "INFO" "$file" "1" \
            "No 'help' target found — consider adding a self-documenting help target"
    fi
}

check_shell_compatibility() {
    local file="$1"
    local has_shell_override
    has_shell_override=$(grep -c 'SHELL\s*[:?]*=' "$file" 2>/dev/null || echo 0)

    if [[ "$has_shell_override" -eq 0 ]]; then
        local lineno=0
        while IFS= read -r line; do
            ((lineno++))

            # Check for bash-specific syntax in recipes
            if [[ "$line" =~ ^\t ]]; then
                # [[ ]] syntax
                if [[ "$line" =~ \[\[ ]]; then
                    report "WARNING" "$file" "$lineno" \
                        "Bash-specific [[ ]] used without SHELL := /bin/bash"
                fi
                # Process substitution <()
                if [[ "$line" =~ \<\( || "$line" =~ \>\( ]]; then
                    report "WARNING" "$file" "$lineno" \
                        "Bash process substitution used without SHELL := /bin/bash"
                fi
            fi
        done < "$file"
    fi
}

check_recursive_make() {
    local file="$1"
    local lineno=0

    while IFS= read -r line; do
        ((lineno++))

        # Check for $(MAKE) without + prefix
        if [[ "$line" =~ ^\t[^+] && "$line" =~ \$\(MAKE\)|\$\{MAKE\} ]]; then
            if [[ ! "$line" =~ ^\t\+ ]]; then
                report "INFO" "$file" "$lineno" \
                    "Recursive \$(MAKE) without + prefix — may not run with -n (dry run)"
            fi
        fi
    done < "$file"
}

check_documented_targets() {
    local file="$1"

    # Find targets without ## documentation
    local lineno=0
    while IFS= read -r line; do
        ((lineno++))

        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_-]*)\s*: && ! "$line" =~ ## ]]; then
            local target="${BASH_REMATCH[1]}"
            # Skip internal/pattern targets
            case "$target" in
                _*|.PHONY|.SUFFIXES|.DELETE_ON_ERROR|.DEFAULT_GOAL|.ONESHELL|.SECONDARY|.PRECIOUS|.INTERMEDIATE) continue ;;
            esac
            report "INFO" "$file" "$lineno" \
                "Target '$target' has no ## documentation comment"
        fi
    done < "$file"
}

# ─── Main ───────────────────────────────────────────────────

for file in "${FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "Error: File not found: $file" >&2
        ((ERRORS++))
        continue
    fi

    if [[ "$FORMAT" == "text" ]] && [[ ${#FILES[@]} -gt 1 ]]; then
        echo ""
        echo "── Linting: $file ──"
    fi

    check_tabs_vs_spaces "$file"
    check_phony_targets "$file"
    check_unused_variables "$file"
    check_directives "$file"
    check_shell_compatibility "$file"
    check_recursive_make "$file"
    check_documented_targets "$file"
done

# ─── Summary ────────────────────────────────────────────────

if [[ "$FORMAT" == "text" ]]; then
    echo ""
    echo "────────────────────────────────────"
    printf "  Errors:   %d\n" "$ERRORS"
    if ! $QUIET; then
        printf "  Warnings: %d\n" "$WARNINGS"
        printf "  Info:     %d\n" "$INFOS"
    fi
    echo "────────────────────────────────────"
fi

if [[ $ERRORS -gt 0 ]]; then
    exit 1
elif $STRICT && [[ $WARNINGS -gt 0 ]]; then
    exit 1
fi

exit 0
