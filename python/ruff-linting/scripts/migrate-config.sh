#!/usr/bin/env bash
# migrate-config.sh — Migrate existing flake8/isort/black config to Ruff pyproject.toml
#
# Usage:
#   ./migrate-config.sh [project-dir]
#
# This script:
#   1. Detects existing linter configs (flake8, isort, black)
#   2. Extracts relevant settings
#   3. Generates a [tool.ruff] section for pyproject.toml
#   4. Prints the generated config to stdout (does NOT modify files)
#
# After reviewing the output, paste it into your pyproject.toml.
#
# Requirements: bash, grep, sed, awk
# No external dependencies.

set -euo pipefail

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR"

echo "# ==================================================="
echo "# Ruff Config Migration — Generated from existing tools"
echo "# ==================================================="
echo "#"
echo "# Source directory: $(pwd)"
echo "# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
echo "#"
echo "# Review this output carefully, then add to pyproject.toml"
echo "# ==================================================="
echo ""

# ---- Detect sources ----
FLAKE8_FILE=""
ISORT_FILE=""
BLACK_FILE=""
LINE_LENGTH="88"
TARGET_VERSION="py312"
SELECT_RULES=()
IGNORE_RULES=()
KNOWN_FIRST_PARTY=()
KNOWN_THIRD_PARTY=()
PER_FILE_IGNORES=()
EXCLUDE_DIRS=()
MAX_COMPLEXITY=""
QUOTE_STYLE="double"
SKIP_STRING_NORM=""

echo "# Detected config files:"

# --- Detect flake8 ---
if [[ -f ".flake8" ]]; then
    FLAKE8_FILE=".flake8"
    echo "# - flake8: .flake8"
elif grep -q '\[flake8\]' setup.cfg 2>/dev/null; then
    FLAKE8_FILE="setup.cfg"
    echo "# - flake8: setup.cfg [flake8]"
elif grep -q '\[flake8\]' tox.ini 2>/dev/null; then
    FLAKE8_FILE="tox.ini"
    echo "# - flake8: tox.ini [flake8]"
fi

# --- Detect isort ---
if [[ -f ".isort.cfg" ]]; then
    ISORT_FILE=".isort.cfg"
    echo "# - isort: .isort.cfg"
elif grep -q '\[tool\.isort\]' pyproject.toml 2>/dev/null; then
    ISORT_FILE="pyproject.toml"
    echo "# - isort: pyproject.toml [tool.isort]"
elif grep -q '\[isort\]' setup.cfg 2>/dev/null; then
    ISORT_FILE="setup.cfg"
    echo "# - isort: setup.cfg [isort]"
fi

# --- Detect black ---
if grep -q '\[tool\.black\]' pyproject.toml 2>/dev/null; then
    BLACK_FILE="pyproject.toml"
    echo "# - black: pyproject.toml [tool.black]"
fi

if [[ -z "$FLAKE8_FILE" && -z "$ISORT_FILE" && -z "$BLACK_FILE" ]]; then
    echo "# - No existing config detected"
fi

echo "#"

# ---- Extract flake8 settings ----
if [[ -n "$FLAKE8_FILE" ]]; then
    # Extract max-line-length
    len=$(grep -E '^\s*max[_-]line[_-]length\s*=' "$FLAKE8_FILE" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
    if [[ -n "$len" ]]; then
        LINE_LENGTH="$len"
    fi

    # Extract select
    sel=$(grep -E '^\s*select\s*=' "$FLAKE8_FILE" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
    if [[ -n "$sel" ]]; then
        IFS=',' read -ra SELECT_RULES <<< "$sel"
    fi

    # Extract ignore
    ign=$(grep -E '^\s*ignore\s*=' "$FLAKE8_FILE" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
    if [[ -n "$ign" ]]; then
        IFS=',' read -ra IGNORE_RULES <<< "$ign"
    fi

    # Extract max-complexity
    mc=$(grep -E '^\s*max[_-]complexity\s*=' "$FLAKE8_FILE" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
    if [[ -n "$mc" ]]; then
        MAX_COMPLEXITY="$mc"
    fi

    # Extract exclude
    exc=$(grep -E '^\s*exclude\s*=' "$FLAKE8_FILE" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
    if [[ -n "$exc" ]]; then
        IFS=',' read -ra EXCLUDE_DIRS <<< "$exc"
    fi
fi

# ---- Extract black settings ----
if [[ -n "$BLACK_FILE" ]]; then
    bl_len=$(awk '/\[tool\.black\]/,/^\[/' "$BLACK_FILE" | grep -E '^\s*line[_-]length\s*=' | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
    if [[ -n "$bl_len" ]]; then
        LINE_LENGTH="$bl_len"
    fi

    bl_target=$(awk '/\[tool\.black\]/,/^\[/' "$BLACK_FILE" | grep -E '^\s*target[_-]version\s*=' | head -1 | sed 's/.*=\s*//' | tr -d '[:space:][]"' | head -1)
    if [[ -n "$bl_target" ]]; then
        # Extract first version from list
        TARGET_VERSION=$(echo "$bl_target" | tr ',' '\n' | head -1 | tr -d '[:space:]"')
    fi

    bl_skip=$(awk '/\[tool\.black\]/,/^\[/' "$BLACK_FILE" | grep -E '^\s*skip[_-]string[_-]normalization\s*=' | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
    if [[ "$bl_skip" == "true" ]]; then
        QUOTE_STYLE="preserve"
    fi
fi

# ---- Extract isort settings ----
if [[ -n "$ISORT_FILE" ]]; then
    fp=""
    tp=""
    if [[ "$ISORT_FILE" == "pyproject.toml" ]]; then
        fp=$(awk '/\[tool\.isort\]/,/^\[/' "$ISORT_FILE" | grep -E '^\s*known[_-]first[_-]party\s*=' | head -1 | sed 's/.*=\s*//')
        tp=$(awk '/\[tool\.isort\]/,/^\[/' "$ISORT_FILE" | grep -E '^\s*known[_-]third[_-]party\s*=' | head -1 | sed 's/.*=\s*//')
    else
        fp=$(grep -E '^\s*known_first_party\s*=' "$ISORT_FILE" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
        tp=$(grep -E '^\s*known_third_party\s*=' "$ISORT_FILE" 2>/dev/null | head -1 | sed 's/.*=\s*//' | tr -d '[:space:]')
    fi
    if [[ -n "$fp" ]]; then
        fp_clean=$(echo "$fp" | tr -d '[]"' | tr ',' ' ')
        read -ra KNOWN_FIRST_PARTY <<< "$fp_clean"
    fi
    if [[ -n "$tp" ]]; then
        tp_clean=$(echo "$tp" | tr -d '[]"' | tr ',' ' ')
        read -ra KNOWN_THIRD_PARTY <<< "$tp_clean"
    fi
fi

# ---- Generate Ruff config ----
echo "[tool.ruff]"
echo "line-length = $LINE_LENGTH"
echo "target-version = \"$TARGET_VERSION\""

if [[ ${#EXCLUDE_DIRS[@]} -gt 0 ]]; then
    printf 'extend-exclude = ['
    first=true
    for dir in "${EXCLUDE_DIRS[@]}"; do
        dir=$(echo "$dir" | tr -d '[:space:]')
        if [[ -n "$dir" ]]; then
            if $first; then first=false; else printf ', '; fi
            printf '"%s"' "$dir"
        fi
    done
    echo ']'
fi

echo ""
echo "[tool.ruff.lint]"

# Select rules
if [[ ${#SELECT_RULES[@]} -gt 0 ]]; then
    printf 'select = ['
    first=true
    for rule in "${SELECT_RULES[@]}"; do
        rule=$(echo "$rule" | tr -d '[:space:]')
        if [[ -n "$rule" ]]; then
            if $first; then first=false; else printf ', '; fi
            printf '"%s"' "$rule"
        fi
    done
    echo ']'
else
    echo 'select = ["E", "F", "W", "I", "UP", "B", "N", "S", "RUF"]'
fi

# Add I for isort if not already in select
if [[ ${#SELECT_RULES[@]} -gt 0 ]]; then
    has_i=false
    for r in "${SELECT_RULES[@]}"; do
        [[ "$(echo "$r" | tr -d '[:space:]')" == "I" ]] && has_i=true
    done
    if ! $has_i; then
        echo '# NOTE: Add "I" to select for isort import sorting'
    fi
fi

# Ignore rules
if [[ ${#IGNORE_RULES[@]} -gt 0 ]]; then
    printf 'ignore = ['
    first=true
    for rule in "${IGNORE_RULES[@]}"; do
        rule=$(echo "$rule" | tr -d '[:space:]')
        # Skip W503 — doesn't exist in Ruff
        if [[ "$rule" == "W503" || "$rule" == "W504" ]]; then
            continue
        fi
        if [[ -n "$rule" ]]; then
            if $first; then first=false; else printf ', '; fi
            printf '"%s"' "$rule"
        fi
    done
    echo ']'
    echo '# NOTE: W503/W504 removed (not applicable in Ruff)'
fi

echo 'fixable = ["ALL"]'
echo 'unfixable = []'

# McCabe complexity
if [[ -n "$MAX_COMPLEXITY" ]]; then
    echo ""
    echo "[tool.ruff.lint.mccabe]"
    echo "max-complexity = $MAX_COMPLEXITY"
fi

# isort config
if [[ ${#KNOWN_FIRST_PARTY[@]} -gt 0 || ${#KNOWN_THIRD_PARTY[@]} -gt 0 ]]; then
    echo ""
    echo "[tool.ruff.lint.isort]"
    if [[ ${#KNOWN_FIRST_PARTY[@]} -gt 0 ]]; then
        printf 'known-first-party = ['
        first=true
        for pkg in "${KNOWN_FIRST_PARTY[@]}"; do
            pkg=$(echo "$pkg" | tr -d '[:space:]')
            if [[ -n "$pkg" ]]; then
                if $first; then first=false; else printf ', '; fi
                printf '"%s"' "$pkg"
            fi
        done
        echo ']'
    fi
    if [[ ${#KNOWN_THIRD_PARTY[@]} -gt 0 ]]; then
        printf 'known-third-party = ['
        first=true
        for pkg in "${KNOWN_THIRD_PARTY[@]}"; do
            pkg=$(echo "$pkg" | tr -d '[:space:]')
            if [[ -n "$pkg" ]]; then
                if $first; then first=false; else printf ', '; fi
                printf '"%s"' "$pkg"
            fi
        done
        echo ']'
    fi
    echo 'combine-as-imports = true'
    echo 'force-sort-within-sections = true'
fi

echo ""
echo "[tool.ruff.lint.per-file-ignores]"
echo '"tests/**/*.py" = ["S101", "ARG001", "D"]'
echo '"__init__.py" = ["F401", "D104"]'
echo '"conftest.py" = ["ARG001"]'

echo ""
echo "[tool.ruff.format]"
echo "quote-style = \"$QUOTE_STYLE\""
echo 'indent-style = "space"'
echo 'docstring-code-format = true'
echo 'line-ending = "auto"'

echo ""
echo "# ==================================================="
echo "# Migration steps:"
echo "# 1. Add the above config to your pyproject.toml"
echo "# 2. Run: ruff check . --statistics"
echo "# 3. Run: ruff format --diff ."
echo "# 4. Review and adjust ignore list as needed"
echo "# 5. Run: ruff check --fix . && ruff format ."
echo "# 6. Uninstall old tools: pip uninstall flake8 black isort"
echo "# 7. Remove old config files: .flake8, .isort.cfg, [tool.black]"
echo "# ==================================================="
