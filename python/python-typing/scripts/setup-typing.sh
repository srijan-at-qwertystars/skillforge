#!/usr/bin/env bash
# setup-typing.sh — Configure mypy and/or pyright in a Python project
#
# Usage:
#   ./setup-typing.sh [OPTIONS]
#
# Options:
#   --mypy          Set up mypy (default if no checker specified)
#   --pyright       Set up pyright
#   --both          Set up both mypy and pyright
#   --src DIR       Source directory (default: src)
#   --python VER    Python version (default: auto-detect)
#   --strict        Use strict mode (default)
#   --basic         Use basic/relaxed mode
#   --pydantic      Add Pydantic plugin config
#   --django        Add Django plugin config
#   -h, --help      Show this help
#
# Examples:
#   ./setup-typing.sh --both --src mypackage --python 3.12
#   ./setup-typing.sh --mypy --pydantic --strict
#   ./setup-typing.sh --pyright --basic

set -euo pipefail

# Defaults
SETUP_MYPY=false
SETUP_PYRIGHT=false
SRC_DIR="src"
PYTHON_VERSION=""
STRICT=true
PYDANTIC=false
DJANGO=false

usage() {
    sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --mypy)     SETUP_MYPY=true; shift ;;
        --pyright)  SETUP_PYRIGHT=true; shift ;;
        --both)     SETUP_MYPY=true; SETUP_PYRIGHT=true; shift ;;
        --src)      SRC_DIR="$2"; shift 2 ;;
        --python)   PYTHON_VERSION="$2"; shift 2 ;;
        --strict)   STRICT=true; shift ;;
        --basic)    STRICT=false; shift ;;
        --pydantic) PYDANTIC=true; shift ;;
        --django)   DJANGO=true; shift ;;
        -h|--help)  usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
done

# Default to mypy if nothing specified
if ! $SETUP_MYPY && ! $SETUP_PYRIGHT; then
    SETUP_MYPY=true
fi

# Auto-detect Python version
if [[ -z "$PYTHON_VERSION" ]]; then
    if command -v python3 &>/dev/null; then
        PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    else
        PYTHON_VERSION="3.12"
    fi
fi

echo "=== Python Typing Setup ==="
echo "Python version: $PYTHON_VERSION"
echo "Source dir:     $SRC_DIR"
echo "Strict mode:    $STRICT"
echo ""

# ── mypy setup ──────────────────────────────────────────────────────────────

setup_mypy() {
    echo "── Setting up mypy ──"

    # Install mypy
    if ! command -v mypy &>/dev/null; then
        echo "Installing mypy..."
        pip install mypy --quiet
    else
        echo "mypy already installed: $(mypy --version)"
    fi

    # Build plugins list
    PLUGINS=""
    if $PYDANTIC; then
        pip install pydantic --quiet 2>/dev/null || true
        PLUGINS="pydantic.mypy"
    fi
    if $DJANGO; then
        pip install django-stubs --quiet 2>/dev/null || true
        if [[ -n "$PLUGINS" ]]; then
            PLUGINS="$PLUGINS, mypy_django_plugin.main"
        else
            PLUGINS="mypy_django_plugin.main"
        fi
    fi

    # Generate mypy.ini
    if [[ -f mypy.ini ]]; then
        echo "mypy.ini already exists — skipping (backup at mypy.ini.bak)"
        cp mypy.ini mypy.ini.bak
    fi

    cat > mypy.ini << MYPYEOF
[mypy]
python_version = $PYTHON_VERSION
MYPYEOF

    if $STRICT; then
        cat >> mypy.ini << 'MYPYEOF'
strict = True
warn_return_any = True
warn_unused_configs = True
warn_unused_ignores = True
warn_redundant_casts = True
disallow_untyped_defs = True
disallow_any_generics = True
disallow_incomplete_defs = True
no_implicit_reexport = True
check_untyped_defs = True
show_error_codes = True
enable_error_code = ignore-without-code, redundant-expr, truthy-bool
MYPYEOF
    else
        cat >> mypy.ini << 'MYPYEOF'
check_untyped_defs = True
show_error_codes = True
warn_unused_ignores = True
MYPYEOF
    fi

    if [[ -n "$PLUGINS" ]]; then
        echo "plugins = $PLUGINS" >> mypy.ini
    fi

    # Add per-module overrides
    cat >> mypy.ini << MYPYEOF

[mypy-tests.*]
disallow_untyped_defs = False
MYPYEOF

    if $PYDANTIC; then
        cat >> mypy.ini << 'MYPYEOF'

[pydantic-mypy]
init_forbid_extra = True
init_typed = True
warn_required_dynamic_aliases = True
MYPYEOF
    fi

    if $DJANGO; then
        cat >> mypy.ini << 'MYPYEOF'

[mypy.plugins.django-stubs]
django_settings_module = myproject.settings
MYPYEOF
    fi

    echo "Created mypy.ini"
    echo "Run: mypy $SRC_DIR/"
    echo ""
}

# ── pyright setup ───────────────────────────────────────────────────────────

setup_pyright() {
    echo "── Setting up pyright ──"

    # Install pyright
    if ! command -v pyright &>/dev/null; then
        echo "Installing pyright..."
        if command -v npm &>/dev/null; then
            npm install -g pyright --quiet 2>/dev/null || pip install pyright --quiet
        else
            pip install pyright --quiet
        fi
    else
        echo "pyright already installed: $(pyright --version)"
    fi

    local MODE="strict"
    if ! $STRICT; then
        MODE="basic"
    fi

    if [[ -f pyrightconfig.json ]]; then
        echo "pyrightconfig.json already exists — skipping (backup at pyrightconfig.json.bak)"
        cp pyrightconfig.json pyrightconfig.json.bak
    fi

    cat > pyrightconfig.json << PYRIGHTEOF
{
  "include": ["$SRC_DIR"],
  "exclude": ["**/node_modules", "**/__pycache__", "build", "dist", ".venv"],
  "pythonVersion": "$PYTHON_VERSION",
  "typeCheckingMode": "$MODE",
  "reportMissingImports": true,
  "reportMissingTypeStubs": true,
  "reportUnusedImport": "warning",
  "reportUnusedVariable": "warning",
  "reportPrivateUsage": "warning",
  "reportUnnecessaryTypeIgnoreComment": true,
  "reportUnnecessaryCast": true,
  "reportDeprecated": "warning"
}
PYRIGHTEOF

    echo "Created pyrightconfig.json"
    echo "Run: pyright"
    echo ""
}

# ── Install common stubs ───────────────────────────────────────────────────

install_common_stubs() {
    echo "── Installing common type stubs ──"
    local stubs=()

    # Detect installed packages and install matching stubs
    for pkg_stub in "requests:types-requests" "PyYAML:types-PyYAML" \
                    "setuptools:types-setuptools" "redis:types-redis" \
                    "Pillow:types-Pillow" "python-dateutil:types-python-dateutil"; do
        local pkg="${pkg_stub%%:*}"
        local stub="${pkg_stub##*:}"
        if pip show "$pkg" &>/dev/null 2>&1; then
            stubs+=("$stub")
        fi
    done

    if [[ ${#stubs[@]} -gt 0 ]]; then
        echo "Installing: ${stubs[*]}"
        pip install "${stubs[@]}" --quiet
    else
        echo "No common packages detected that need stubs."
    fi
    echo ""
}

# ── Create py.typed marker ─────────────────────────────────────────────────

create_py_typed() {
    if [[ -d "$SRC_DIR" ]]; then
        local marker="$SRC_DIR/py.typed"
        if [[ ! -f "$marker" ]]; then
            touch "$marker"
            echo "Created $marker (PEP 561 marker)"
        fi
    fi
}

# ── Execute ─────────────────────────────────────────────────────────────────

$SETUP_MYPY && setup_mypy
$SETUP_PYRIGHT && setup_pyright
install_common_stubs
create_py_typed

echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Run your type checker to see current status"
$SETUP_MYPY && echo "     mypy $SRC_DIR/"
$SETUP_PYRIGHT && echo "     pyright"
echo "  2. Fix errors or add # type: ignore[code] for known issues"
echo "  3. Add type checking to CI/CD"
