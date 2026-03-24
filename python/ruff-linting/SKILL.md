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

## Rule Categories Reference

Select rules via prefix codes in `select`. Core categories (see `references/rule-categories.md` for full details):

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

See `references/migration-guide.md` for comprehensive step-by-step migration from all tools. Quick overview:

### From Flake8

```bash
# 1. Map flake8 settings to [tool.ruff.lint] (same rule codes)
# 2. Run: scripts/migrate-config.sh to auto-generate config
# 3. Uninstall: pip uninstall flake8 flake8-bugbear flake8-comprehensions ...
```

### From Black

```bash
# 1. ruff format is a drop-in replacement (>99.9% identical output)
# 2. Copy line-length and target-version to [tool.ruff]
# 3. skip-string-normalization = true → quote-style = "preserve"
# 4. Uninstall: pip uninstall black
```

### From isort

```bash
# 1. Enable "I" rules in Ruff
# 2. Map known_first_party → [tool.ruff.lint.isort] known-first-party
# 3. profile = "black" → Ruff default already matches
# 4. Uninstall: pip uninstall isort
```

### From Pylint

```toml
# Enable PL rules for partial Pylint parity (~30% of rules)
[tool.ruff.lint]
select = ["PL"]
# Keep Pylint for advanced checks (duplicate-code, cyclic-import, no-member)
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

## Reference Guides

Deep-dive documentation in `references/`:

### Rule Categories (`references/rule-categories.md`)
Comprehensive guide to all Ruff rule categories with top rules, code examples, fixability info, and per-file-ignores patterns. Covers: pycodestyle (E/W), Pyflakes (F), isort (I), pep8-naming (N), pyupgrade (UP), bandit (S), bugbear (B), comprehensions (C4), pydocstyle (D), Perflint (PERF), refurb (FURB), Ruff-specific (RUF), Pylint (PL), simplify (SIM), pytest-style (PT), and more. Includes a selection strategy matrix by project type.

### Migration Guide (`references/migration-guide.md`)
Step-by-step migration from flake8 (with all plugins), Black, isort, Pylint, Bandit, pyupgrade, pydocstyle, autopep8, and yapf. Contains config mapping tables (setting-by-setting), equivalent rule code tables, pre-commit migration, CI/CD migration, combined all-in-one migration script, gap analysis for rules Ruff doesn't implement, and a verification checklist.

### Advanced Configuration (`references/advanced-config.md`)
Complex config patterns: `extend` vs override semantics, per-file-ignores glob recipes, target-version gating, preview rules, rule deprecation, custom fixable/unfixable sets, namespace packages, monorepo config with per-package overrides, and framework-specific configs for Django, FastAPI, pytest, and data science projects. Also covers output formats, performance tuning, and cache management.

## Helper Scripts

Executable scripts in `scripts/`:

| Script | Purpose | Usage |
|--------|---------|-------|
| `scripts/migrate-config.sh` | Migrate flake8/isort/black config to Ruff `pyproject.toml` | `./scripts/migrate-config.sh [project-dir]` |
| `scripts/setup-precommit.sh` | Set up pre-commit hooks with Ruff linting + formatting | `./scripts/setup-precommit.sh [project-dir]` |
| `scripts/audit-rules.sh` | Analyze codebase violations, suggest adoption strategy | `./scripts/audit-rules.sh [project-dir]` |

### migrate-config.sh
Detects existing `.flake8`, `setup.cfg [flake8]`, `[tool.isort]`, and `[tool.black]` configs. Extracts line-length, select/ignore rules, known-first-party, max-complexity, and quote style. Outputs a ready-to-paste `[tool.ruff]` config block. Does not modify files.

### setup-precommit.sh
Creates `.pre-commit-config.yaml` with `ruff` (lint + fix) and `ruff-format` hooks. Auto-detects installed Ruff version. Supports `--ruff-version`, `--unsafe-fixes`, `--no-install`, `--dry-run` flags. Installs `pre-commit` if missing and runs initial check.

### audit-rules.sh
Runs `ruff check --select ALL --statistics` on your codebase. Reports total violations, top rules by count, violations grouped by category, worst files, auto-fix potential percentage, and a phased adoption strategy (low → medium → high violation categories). Supports `--top N`, `--output FILE`, `--select RULES`.

## Config Templates (Assets)

Ready-to-use templates in `assets/`:

| File | Description |
|------|-------------|
| `assets/pyproject.toml` | Production Ruff config with recommended rules for web projects. Heavily commented — every rule category explained. |
| `assets/pre-commit-config.yaml` | Pre-commit config with Ruff hooks + general file hygiene hooks. Optional mypy and detect-secrets hooks commented out. |
| `assets/github-actions.yml` | GitHub Actions workflow for Ruff linting and formatting. Uses official `astral-sh/ruff-action`. Includes optional auto-fix job. |
