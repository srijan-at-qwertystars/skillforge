#!/usr/bin/env bash
set -euo pipefail

# Usage: setup-pytest.sh [OPTIONS] [PROJECT_DIR]
#
# Sets up a pytest project with best-practice configuration, recommended
# dependencies, directory structure, and sample files.
#
# Arguments:
#   PROJECT_DIR        Target project directory (default: current directory)
#
# Options:
#   --with-django      Add Django testing dependencies and configuration
#   --with-fastapi     Add FastAPI testing dependencies (httpx, async)
#   --with-async       Add async testing support (pytest-asyncio)
#   --force            Overwrite existing files
#   -h, --help         Show this help message
#
# Examples:
#   setup-pytest.sh
#   setup-pytest.sh --with-django ./myproject
#   setup-pytest.sh --with-fastapi --with-async --force

WITH_DJANGO=false
WITH_FASTAPI=false
WITH_ASYNC=false
FORCE=false
PROJECT_DIR="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-django)  WITH_DJANGO=true; shift ;;
        --with-fastapi) WITH_FASTAPI=true; shift ;;
        --with-async)   WITH_ASYNC=true; shift ;;
        --force)        FORCE=true; shift ;;
        -h|--help)
            sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            exit 1
            ;;
        *)
            PROJECT_DIR="$1"; shift ;;
    esac
done

mkdir -p "$PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
echo "Setting up pytest project in: $PROJECT_DIR"

# --- Helper: write file only if it doesn't exist (or --force) ---
write_file() {
    local filepath="$1"
    local content="$2"
    local full_path="$PROJECT_DIR/$filepath"

    mkdir -p "$(dirname "$full_path")"

    if [[ -f "$full_path" && "$FORCE" != true ]]; then
        echo "  SKIP $filepath (exists, use --force to overwrite)"
        return 0
    fi

    printf '%s\n' "$content" > "$full_path"
    if [[ -f "$full_path" ]]; then
        echo "  CREATE $filepath"
    fi
}

# --- 1. Create/update pyproject.toml with pytest config ---
PYTEST_INI_OPTIONS='minversion = "7.0"
testpaths = ["tests"]
python_files = ["test_*.py"]
python_classes = ["Test*"]
python_functions = ["test_*"]
addopts = "-ra -q --strict-markers --strict-config"
markers = [
    "slow: marks tests as slow (deselect with '\''-m \"not slow\"'\'')",
    "integration: marks integration tests",
    "unit: marks unit tests",
]'

COVERAGE_CONFIG='[tool.coverage.run]
source = ["src"]
branch = true
omit = ["*/tests/*", "*/migrations/*"]

[tool.coverage.report]
show_missing = true
fail_under = 80
exclude_lines = [
    "pragma: no cover",
    "def __repr__",
    "if TYPE_CHECKING:",
    "raise NotImplementedError",
]'

if [[ -f "$PROJECT_DIR/pyproject.toml" && "$FORCE" != true ]]; then
    echo "  SKIP pyproject.toml (exists, use --force to overwrite)"
    echo "  TIP: Manually add [tool.pytest.ini_options] section if needed."
else
    PYPROJECT="[tool.pytest.ini_options]
$PYTEST_INI_OPTIONS

$COVERAGE_CONFIG"
    write_file "pyproject.toml" "$PYPROJECT"
fi

# --- 2. Create directory structure ---
for dir in tests tests/unit tests/integration; do
    if [[ ! -d "$PROJECT_DIR/$dir" ]]; then
        mkdir -p "$PROJECT_DIR/$dir"
        echo "  MKDIR $dir/"
    fi
    # Ensure __init__.py exists in each test directory
    if [[ ! -f "$PROJECT_DIR/$dir/__init__.py" ]]; then
        touch "$PROJECT_DIR/$dir/__init__.py"
    fi
done

# --- 3. Build dependencies list ---
DEPS=("pytest" "pytest-cov" "pytest-mock" "pytest-xdist")

if [[ "$WITH_ASYNC" == true || "$WITH_FASTAPI" == true ]]; then
    DEPS+=("pytest-asyncio")
fi

if [[ "$WITH_DJANGO" == true ]]; then
    DEPS+=("pytest-django")
fi

if [[ "$WITH_FASTAPI" == true ]]; then
    DEPS+=("httpx")
fi

echo ""
echo "Recommended dependencies:"
for dep in "${DEPS[@]}"; do
    echo "  - $dep"
done
echo ""
echo "Install with:"
echo "  pip install ${DEPS[*]}"

# --- 4. Create conftest.py with common fixtures ---
CONFTEST_IMPORTS='import pytest
import os
import tempfile
from pathlib import Path
from unittest.mock import MagicMock'

CONFTEST_FIXTURES='

# -- Common fixtures --

@pytest.fixture
def tmp_path_with_cleanup(tmp_path):
    """Provides a temporary directory that is cleaned up after each test."""
    yield tmp_path


@pytest.fixture
def sample_data():
    """Provides reusable sample data for tests."""
    return {
        "id": 1,
        "name": "Test Item",
        "active": True,
        "tags": ["unit", "sample"],
    }


@pytest.fixture
def mock_env(monkeypatch):
    """Fixture to set environment variables for testing."""
    def _set_env(**kwargs):
        for key, value in kwargs.items():
            monkeypatch.setenv(key, value)
    return _set_env


@pytest.fixture
def capture_logs(caplog):
    """Fixture that captures log output at DEBUG level."""
    import logging
    with caplog.at_level(logging.DEBUG):
        yield caplog'

DJANGO_FIXTURES=""
if [[ "$WITH_DJANGO" == true ]]; then
    CONFTEST_IMPORTS+="
from django.test import Client"
    DJANGO_FIXTURES='


# -- Django fixtures --

@pytest.fixture
def api_client():
    """Provides a Django test client."""
    return Client()


@pytest.fixture
def authenticated_client(api_client, django_user_model):
    """Provides an authenticated Django test client."""
    user = django_user_model.objects.create_user(
        username="testuser", password="testpass123"
    )
    api_client.force_login(user)
    api_client.user = user
    return api_client'
fi

FASTAPI_FIXTURES=""
if [[ "$WITH_FASTAPI" == true ]]; then
    CONFTEST_IMPORTS+="
import httpx
import pytest_asyncio"
    FASTAPI_FIXTURES='


# -- FastAPI fixtures --
# Uncomment and adapt the following once your FastAPI app is created:
#
# from your_app.main import app
#
# @pytest_asyncio.fixture
# async def async_client():
#     """Provides an async HTTP client for FastAPI testing."""
#     async with httpx.AsyncClient(
#         transport=httpx.ASGITransport(app=app),
#         base_url="http://testserver",
#     ) as client:
#         yield client'
fi

ASYNC_FIXTURES=""
if [[ "$WITH_ASYNC" == true ]]; then
    ASYNC_FIXTURES='


# -- Async fixtures --

@pytest.fixture
def event_loop_policy():
    """Override if you need a custom event loop policy."""
    import asyncio
    return asyncio.DefaultEventLoopPolicy()'
fi

CONFTEST_CONTENT="${CONFTEST_IMPORTS}${CONFTEST_FIXTURES}${DJANGO_FIXTURES}${FASTAPI_FIXTURES}${ASYNC_FIXTURES}"
write_file "tests/conftest.py" "$CONFTEST_CONTENT"

# --- 5. Create sample test file ---
SAMPLE_TEST='"""Sample test file demonstrating pytest patterns and best practices."""
import pytest


class TestSampleUnit:
    """Example unit test class."""

    def test_addition(self):
        assert 1 + 1 == 2

    def test_string_operations(self):
        greeting = "hello world"
        assert greeting.upper() == "HELLO WORLD"
        assert greeting.split() == ["hello", "world"]

    def test_with_sample_data(self, sample_data):
        """Uses the sample_data fixture from conftest.py."""
        assert sample_data["name"] == "Test Item"
        assert sample_data["active"] is True

    @pytest.mark.parametrize(
        "input_val, expected",
        [
            (1, 1),
            (2, 4),
            (3, 9),
            (0, 0),
            (-2, 4),
        ],
    )
    def test_square(self, input_val, expected):
        assert input_val ** 2 == expected

    @pytest.mark.slow
    def test_marked_as_slow(self):
        """This test is marked as slow and can be excluded with -m '"'"'not slow'"'"'."""
        import time
        time.sleep(0.01)
        assert True


def test_exception_handling():
    """Demonstrates testing for expected exceptions."""
    with pytest.raises(ZeroDivisionError):
        1 / 0

    with pytest.raises(ValueError, match="invalid literal"):
        int("not_a_number")'

write_file "tests/unit/test_sample.py" "$SAMPLE_TEST"

# --- 6. Create pytest marker config for async if needed ---
if [[ "$WITH_ASYNC" == true || "$WITH_FASTAPI" == true ]]; then
    # Append asyncio mode to pyproject.toml if we created it
    if [[ -f "$PROJECT_DIR/pyproject.toml" ]]; then
        if ! grep -q "asyncio_mode" "$PROJECT_DIR/pyproject.toml" 2>/dev/null; then
            echo '' >> "$PROJECT_DIR/pyproject.toml"
            echo '[tool.pytest.ini_options.asyncio_mode]' >> "$PROJECT_DIR/pyproject.toml"
            echo '# Set to "auto" to automatically treat async tests as asyncio tests' >> "$PROJECT_DIR/pyproject.toml"
            echo '# asyncio_mode = "auto"' >> "$PROJECT_DIR/pyproject.toml"
        fi
    fi
fi

# --- Done ---
echo ""
echo "✅ Pytest project setup complete!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_DIR"
echo "  pip install ${DEPS[*]}"
echo "  pytest                    # run all tests"
echo "  pytest -m 'not slow'     # skip slow tests"
echo "  pytest --cov             # run with coverage"
echo "  pytest -n auto           # run in parallel (xdist)"
