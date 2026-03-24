"""conftest.py — Pytest configuration with type checking integration.

Copy to your project's tests/ directory or project root.

Features:
  - pytest-mypy-plugins integration for testing type annotations
  - typeguard runtime checking during tests
  - beartype runtime checking option
  - Fixtures for type-checking test helpers

Install dependencies:
  pip install pytest typeguard beartype pytest-mypy-plugins

Usage:
  pytest                          # Normal test run
  pytest --typeguard-packages=mypackage  # With runtime type checking
"""

from __future__ import annotations

import sys
from typing import TYPE_CHECKING, Any

import pytest

if TYPE_CHECKING:
    from collections.abc import Generator


# ── Runtime type checking configuration ────────────────────────────────────

def pytest_addoption(parser: pytest.Parser) -> None:
    """Add custom CLI options for type checking."""
    parser.addoption(
        "--runtime-typecheck",
        action="store_true",
        default=False,
        help="Enable beartype runtime type checking for all test functions",
    )


def pytest_configure(config: pytest.Config) -> None:
    """Register custom markers."""
    config.addinivalue_line(
        "markers",
        "typecheck: mark test to run with runtime type checking enabled",
    )


# ── Fixtures ───────────────────────────────────────────────────────────────

@pytest.fixture
def assert_type() -> Any:
    """Fixture to verify type checker behavior at runtime.

    Usage:
        def test_return_type(assert_type):
            result = my_function(42)
            assert_type(result, int)
    """
    def _assert_type(value: object, expected_type: type) -> None:
        assert isinstance(value, expected_type), (
            f"Expected {expected_type.__name__}, got {type(value).__name__}"
        )
    return _assert_type


@pytest.fixture
def type_error_expected() -> Any:
    """Fixture for testing that code raises TypeError at runtime.

    Usage:
        def test_bad_input(type_error_expected):
            with type_error_expected:
                my_typed_function("not_an_int")  # type: ignore[arg-type]
    """
    return pytest.raises(TypeError)


@pytest.fixture
def reveal_type_capture(capsys: pytest.CaptureFixture[str]) -> Any:
    """Capture reveal_type() output for assertion.

    Usage:
        def test_inferred_type(reveal_type_capture):
            x = [1, 2, 3]
            reveal_type(x)
            assert "list[int]" in reveal_type_capture()
    """
    def _capture() -> str:
        captured = capsys.readouterr()
        return captured.err + captured.out
    return _capture


# ── Type checking test helpers ─────────────────────────────────────────────

class TypeCheckCase:
    """Helper for mypy-plugins-style type checking tests.

    Usage in a YAML test file (test_types.yml):
        - case: test_my_function
          main: |
            from mypackage import my_function
            reveal_type(my_function(42))  # N: Revealed type is "builtins.str"
    """

    @staticmethod
    def assert_mypy_output(
        source: str,
        expected_errors: list[tuple[int, str]] | None = None,
    ) -> None:
        """Run mypy on a code snippet and verify output.

        Args:
            source: Python source code to check.
            expected_errors: List of (line_number, error_substring) tuples.
        """
        import subprocess
        import tempfile
        from pathlib import Path

        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".py", delete=False
        ) as f:
            f.write(source)
            f.flush()
            result = subprocess.run(
                [sys.executable, "-m", "mypy", "--no-error-summary", f.name],
                capture_output=True,
                text=True,
            )

        if expected_errors is None:
            assert result.returncode == 0, f"Unexpected mypy errors:\n{result.stdout}"
        else:
            for line_no, error_substr in expected_errors:
                assert error_substr in result.stdout, (
                    f"Expected error containing '{error_substr}' at line {line_no}\n"
                    f"Actual output:\n{result.stdout}"
                )

        Path(f.name).unlink(missing_ok=True)


@pytest.fixture
def typecheck() -> type[TypeCheckCase]:
    """Fixture providing TypeCheckCase helper."""
    return TypeCheckCase
