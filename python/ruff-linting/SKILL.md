---
name: ruff-linting
description: >
  Ruff Python linter and formatter skill. Covers installation, configuration,
  rule selection, formatting, import sorting, migration, and CI integration.
  Trigger for: "Ruff linter", "Ruff formatter", "ruff check", "ruff format",
  "Python linting with Ruff", "pyproject.toml ruff config", "Ruff rules",
  "migrate from flake8/isort/black to Ruff".
  Do NOT trigger for: "flake8 without Ruff", "pylint config", "mypy type checking",
  "black formatter without Ruff", "ESLint JavaScript".
---

# Ruff Python Linter & Formatter

Ruff is a Rust-powered Python linter and formatter (by Astral). It replaces Flake8, Black, isort, pyupgrade, pydocstyle, bandit, and most Flake8 plugins in a single binary. 10–100× faster than legacy tools.

## Installation

```bash
# pip
pip install ruff

# uv (recommended for speed)
uv tool install ruff

# pipx (isolated global install)
pipx install ruff

# conda
conda install -c conda-forge ruff

# Verify
ruff --version
```

Add as dev dependency:
```bash
# Poetry
poetry add --group dev ruff

# pip-tools: add "ruff" to requirements-dev.in, then pip-compile
```

## Configuration

Configure in `pyproject.toml` (preferred), `ruff.toml`, or `.ruff.toml`. Use `pyproject.toml` for unified project config.

### Minimal starter config

```toml
[tool.ruff]
line-length = 88
target-version = "py312"
exclude = [".git", ".venv", "build", "dist", "__pycache__", "*.egg-info"]

[tool.ruff.lint]
select = ["E", "F", "W", "I", "UP", "B", "N"]
ignore = []
fixable = ["ALL"]
unfixable = []

[tool.ruff.format]
quote-style = "double"
indent-style = "space"
line-ending = "auto"
```

### Equivalent ruff.toml (standalone)

```toml
line-length = 88
target-version = "py312"

[lint]
select = ["E", "F", "W", "I", "UP", "B", "N"]

[format]
quote-style = "double"
```

## Rule Categories Reference

Select rules via prefix codes in `select`. Core categories:

| Prefix | Origin | What it checks |
|--------|--------|---------------|
| `E` | pycodestyle | PEP 8 errors (indentation, whitespace, syntax) |
| `W` | pycodestyle | PEP 8 warnings (trailing whitespace, blank lines) |
| `F` | Pyflakes | Unused imports/vars, undefined names, redefined |
| `I` | isort | Import ordering and grouping |
| `N` | pep8-naming | Naming conventions (classes, functions, constants) |
| `UP` | pyupgrade | Python version upgrade suggestions (f-strings, type hints) |
| `S` | bandit | Security vulnerabilities (exec, eval, hardcoded passwords) |
| `B` | flake8-bugbear | Likely bugs, mutable defaults, assert misuse |
| `A` | flake8-builtins | Shadowing Python builtins (list, dict, type) |
| `C4` | flake8-comprehensions | Unnecessary list/dict/set calls, use comprehensions |
| `D` | pydocstyle | Docstring style and presence |
| `SIM` | flake8-simplify | Simplifiable constructs (ternary, context managers) |
| `PT` | flake8-pytest-style | Pytest best practices |
| `RET` | flake8-return | Unnecessary return/else-after-return |
| `ARG` | flake8-unused-arguments | Unused function arguments |
| `DTZ` | flake8-datetimez | Timezone-naive datetime usage |
| `ISC` | flake8-implicit-str-concat | Implicit string concatenation |
| `ICN` | flake8-import-conventions | Import alias conventions (np, pd) |
| `PL` | Pylint | Pylint error/warning/convention/refactor rules |
| `PERF` | Perflint | Performance anti-patterns |
| `RUF` | Ruff-specific | Ruff's own rules (mutable defaults, etc.) |
| `ANN` | flake8-annotations | Missing type annotations |
| `FA` | flake8-future-annotations | `from __future__ import annotations` usage |
| `TCH` | flake8-type-checking | TYPE_CHECKING block optimization |
| `T20` | flake8-print | Print statement detection |
| `ERA` | eradicate | Commented-out code |
| `FBT` | flake8-boolean-trap | Boolean positional arguments |
| `PIE` | flake8-pie | Misc. lints (unnecessary pass, spread, etc.) |
| `NPY` | NumPy-specific | NumPy deprecations and style |
| `FURB` | refurb | Pythonic code modernization |

### Rule selection strategies

**Conservative (new projects):**
```toml
select = ["E", "F", "W", "I"]
```

**Recommended (most projects):**
```toml
select = ["E", "F", "W", "I", "UP", "B", "N", "S", "A", "C4", "SIM", "RUF"]
ignore = ["E501"]  # Let formatter handle line length
```

**Strict (maximum quality):**
```toml
select = ["ALL"]
ignore = [
  "D100", "D104",  # Missing module/package docstrings
  "ANN101",         # Missing self type annotation (deprecated)
  "COM812",         # Conflicts with formatter
  "ISC001",         # Conflicts with formatter
]
```

**When using `select = ["ALL"]`:** Start with ALL, run `ruff check .`, then add noisy codes to `ignore`. Use `--statistics` to see violation counts by rule.

## Formatter (ruff format) — Black Replacement

`ruff format` is a drop-in Black replacement. Produces identical output for >99.9% of cases.

```bash
# Format all files
ruff format .

# Check formatting without modifying (CI mode)
ruff format --check .

# Format a single file
ruff format path/to/file.py

# Format and show diff
ruff format --diff .
```

### Formatter configuration

```toml
[tool.ruff.format]
quote-style = "double"            # "double" (default) or "single"
indent-style = "space"            # "space" (default) or "tab"
skip-magic-trailing-comma = false # Respect trailing commas for multiline
line-ending = "auto"              # "auto", "lf", "crlf", "native"
docstring-code-format = true      # Format code blocks inside docstrings
docstring-code-line-length = 72   # Line length for docstring code blocks
```

## Import Sorting (isort Replacement)

Enable with `"I"` in `select`. Ruff sorts imports in-place with `--fix`.

```toml
[tool.ruff.lint]
select = ["I"]

[tool.ruff.lint.isort]
known-first-party = ["mypackage"]
known-third-party = ["fastapi", "pydantic"]
combine-as-imports = true
force-single-line = false
force-sort-within-sections = true
lines-after-imports = 2
section-order = ["future", "standard-library", "third-party", "first-party", "local-folder"]
```

```bash
# Sort imports and fix
ruff check --select I --fix .
```

## Per-File Ignores and Inline Suppressions

### Per-file ignores in config

```toml
[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = ["S101", "ARG001", "D"]      # Allow assert, unused args, skip docstrings
"__init__.py" = ["F401", "E402"]                 # Allow unused imports, late imports
"scripts/**/*.py" = ["T20"]                      # Allow print statements
"conftest.py" = ["ARG001", "E501"]               # Fixtures often have unused args
"migrations/**/*.py" = ["ALL"]                   # Skip linting migrations entirely
```

### Inline suppression comments

```python
x = eval("1+1")  # noqa: S307

# Suppress multiple rules on one line
import os  # noqa: F401, E402

# Suppress for entire block — not supported; use per-file-ignores instead
```

Use `# noqa` (no code) to suppress ALL rules on that line — avoid this; always specify codes.

Generate noqa comments automatically:
```bash
ruff check --add-noqa .
```

## Fix Mode

```bash
# Apply safe auto-fixes
ruff check --fix .

# Apply safe + unsafe auto-fixes (review changes afterward)
ruff check --fix --unsafe-fixes .

# Preview what --fix would change without modifying
ruff check --diff .

# Show fix applicability per rule
ruff check --show-fixes .
```

Control fixability in config:
```toml
[tool.ruff.lint]
fixable = ["ALL"]
unfixable = ["F401"]  # Never auto-remove unused imports
```

### Safe vs. unsafe fixes
- **Safe fixes:** Guaranteed not to change semantics (e.g., removing trailing whitespace).
- **Unsafe fixes:** May change runtime behavior (e.g., removing unused variables that have side effects). Always review `--unsafe-fixes` output.

## Migration from Legacy Tools

### From Flake8

```bash
# 1. Remove flake8 and plugins
pip uninstall flake8 flake8-bugbear flake8-comprehensions flake8-isort

# 2. Convert .flake8 or setup.cfg to pyproject.toml
# Map max-line-length → line-length
# Map select/extend-select → [tool.ruff.lint] select
# Map ignore → [tool.ruff.lint] ignore
# Map per-file-ignores → [tool.ruff.lint.per-file-ignores]
# Map flake8 plugin codes → equivalent Ruff prefixes (usually same codes)
```

### From Black

```bash
# 1. Remove black
pip uninstall black

# 2. Use ruff format (drop-in replacement)
# Copy line-length from [tool.black] to [tool.ruff]
# Copy target-version
# skip-string-normalization = true → quote-style = "preserve"
```

### From isort

```bash
# 1. Remove isort
pip uninstall isort

# 2. Enable "I" rules in Ruff
# Map known_first_party → [tool.ruff.lint.isort] known-first-party
# Map known_third_party → known-third-party
# Map profile = "black" → Ruff default already matches
```

### From Pylint

```toml
# Enable PL rules for Pylint parity
[tool.ruff.lint]
select = ["PL"]
# PLC = Pylint Convention, PLE = Error, PLR = Refactor, PLW = Warning
# Not all Pylint rules have Ruff equivalents; keep Pylint for advanced checks if needed
```

### Migration command helper

```bash
# See which Flake8 rules map to Ruff
ruff rule F401   # Show details for a specific rule
ruff linter      # List all supported linters/origins
```

## Pre-commit Integration

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.11.12  # pin to latest release
    hooks:
      - id: ruff
        args: ["--fix", "--exit-non-zero-on-fix"]
      - id: ruff-format
```

Run lint before format so fixes are formatted. Install and run:
```bash
pre-commit install
pre-commit run --all-files
```

## Editor Integration

### VS Code
Install the official `charliermarsh.ruff` extension. Settings:
```json
{
  "ruff.lint.run": "onSave",
  "ruff.format.args": [],
  "editor.defaultFormatter": "charliermarsh.ruff",
  "[python]": {
    "editor.formatOnSave": true,
    "editor.codeActionsOnSave": {
      "source.fixAll.ruff": "explicit",
      "source.organizeImports.ruff": "explicit"
    }
  }
}
```

### Neovim (via nvim-lspconfig)
```lua
require('lspconfig').ruff.setup({
  init_options = {
    settings = { lineLength = 88, lint = { select = {"E", "F", "W", "I"} } }
  }
})
-- Or use conform.nvim for format-on-save with ruff_format
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Lint
on: [push, pull_request]
jobs:
  ruff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/ruff-action@v3
        with:
          args: "check"
      - uses: astral-sh/ruff-action@v3
        with:
          args: "format --check"
```

### GitLab CI

```yaml
ruff:
  image: python:3.12-slim
  before_script: pip install ruff
  script:
    - ruff check .
    - ruff format --check .
```

### Generic CI script

```bash
#!/bin/bash
set -e
ruff check . --output-format=github  # Annotates PR diffs on GitHub
ruff format --check .
```

Output formats: `text` (default), `json`, `github`, `gitlab`, `pylint`, `rdjson`, `sarif`.

## Examples

### Before/after: unused import + unsorted imports

```python
# BEFORE
import os
import sys
from collections import OrderedDict
import json
unused = os
```

```bash
ruff check --select F401,I --fix example.py
```

```python
# AFTER
import json
import sys
from collections import OrderedDict
```

### Before/after: pyupgrade (UP) modernization

```python
# BEFORE
x = dict([(k, v) for k, v in items])
isinstance(x, (int, float))
"{0} {1}".format(a, b)
```

```python
# AFTER (with UP rules)
x = dict(items)
isinstance(x, int | float)
f"{a} {b}"
```

### Before/after: bugbear (B006) mutable default

```python
# BEFORE — B006 violation
def foo(items=[]):
    items.append(1)
```

```python
# AFTER
def foo(items=None):
    if items is None:
        items = []
    items.append(1)
```

### Check statistics for a codebase

```bash
ruff check . --statistics --select ALL
# Shows count per rule code — use this to decide what to ignore
```

## Quick Command Reference

| Command | Purpose |
|---------|---------|
| `ruff check .` | Lint all files |
| `ruff check --fix .` | Lint and auto-fix safe issues |
| `ruff check --fix --unsafe-fixes .` | Lint and fix all fixable issues |
| `ruff format .` | Format all files (Black replacement) |
| `ruff format --check .` | Check formatting without changes |
| `ruff format --diff .` | Show formatting diff |
| `ruff check --select I --fix .` | Sort imports only |
| `ruff check --add-noqa .` | Add noqa comments for current violations |
| `ruff check --statistics .` | Show violation counts by rule |
| `ruff rule <CODE>` | Show details for a specific rule |
| `ruff linter` | List all supported linter origins |
| `ruff check --output-format json .` | JSON output for tooling |
| `ruff check --diff .` | Show what --fix would change |
