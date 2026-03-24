# Ruff Advanced Configuration Patterns

> Complex configuration patterns for real-world projects: monorepos, frameworks, preview rules, and fine-tuned control.

## Table of Contents

- [Configuration File Hierarchy](#configuration-file-hierarchy)
- [extend vs override](#extend-vs-override)
- [per-file-ignores Patterns](#per-file-ignores-patterns)
- [target-version and Python Version Gating](#target-version-and-python-version-gating)
- [Preview Rules](#preview-rules)
- [Rule Deprecation Handling](#rule-deprecation-handling)
- [Custom Fixable/Unfixable Sets](#custom-fixableunfixable-sets)
- [Namespace Packages](#namespace-packages)
- [Monorepo Configuration](#monorepo-configuration)
- [Django-Specific Config](#django-specific-config)
- [FastAPI-Specific Config](#fastapi-specific-config)
- [pytest-Specific Config](#pytest-specific-config)
- [Data Science Config](#data-science-config)
- [Output Formats and Integration](#output-formats-and-integration)
- [Performance Tuning](#performance-tuning)
- [Cache Management](#cache-management)

---

## Configuration File Hierarchy

Ruff searches for config in this order (first match wins):

1. `pyproject.toml` (under `[tool.ruff]`)
2. `ruff.toml`
3. `.ruff.toml`

In subdirectories, Ruff walks up the directory tree and uses the **nearest** config file. This enables per-package config in monorepos.

### pyproject.toml vs ruff.toml syntax

```toml
# pyproject.toml — all keys under [tool.ruff]
[tool.ruff]
line-length = 88

[tool.ruff.lint]
select = ["E", "F"]

[tool.ruff.lint.isort]
known-first-party = ["myapp"]
```

```toml
# ruff.toml — top-level keys (no [tool.ruff] prefix)
line-length = 88

[lint]
select = ["E", "F"]

[lint.isort]
known-first-party = ["myapp"]
```

### Config discovery with --config

```bash
# Use a specific config file
ruff check --config /path/to/ruff.toml .

# Inline config override
ruff check --config 'lint.select = ["E", "F"]' .

# Show which config is being used
ruff check --show-settings . 2>&1 | head -5
```

---

## extend vs override

### select vs extend-select

`select` **replaces** the default rule set. `extend-select` **adds** to whatever `select` sets.

```toml
[tool.ruff.lint]
# OVERRIDE: Only these rules, nothing else
select = ["E", "F"]

# EXTEND: Add to whatever select defines
extend-select = ["B", "UP"]
# Result: E + F + B + UP
```

### ignore vs extend-ignore

Same pattern: `ignore` replaces, `extend-ignore` adds.

```toml
[tool.ruff.lint]
select = ["ALL"]
ignore = ["D100", "D104"]           # Base ignores
extend-ignore = ["ANN101", "ANN102"]  # Additional ignores
```

### exclude vs extend-exclude

```toml
[tool.ruff]
# OVERRIDE default excludes (careful — loses built-in excludes like .git, __pycache__)
exclude = ["generated/", "vendor/"]

# EXTEND: Keep defaults AND add your own
extend-exclude = ["generated/", "vendor/", "legacy/"]
```

**Default excludes** (you lose these if you use `exclude`):
`.bzr`, `.direnv`, `.eggs`, `.git`, `.git-rewrite`, `.hg`, `.ipynb_checkpoints`, `.mypy_cache`, `.nox`, `.pants.d`, `.pyenv`, `.pytest_cache`, `.pytype`, `.ruff_cache`, `.svn`, `.tox`, `.venv`, `__pypackages__`, `_build`, `buck-out`, `build`, `dist`, `node_modules`, `site-packages`, `venv`

### fixable vs extend-fixable

```toml
[tool.ruff.lint]
fixable = ["ALL"]          # Allow all auto-fixes (default)
unfixable = ["F401"]       # Never auto-remove unused imports

# Or extend:
extend-fixable = ["B"]     # Add bugbear fixes to defaults
```

---

## per-file-ignores Patterns

### Glob patterns

```toml
[tool.ruff.lint.per-file-ignores]
# Exact file
"conftest.py" = ["ARG001", "E501"]

# Directory glob (recursive)
"tests/**/*.py" = ["S101", "ARG001", "D", "ANN"]

# Top-level directory only (non-recursive)
"tests/*.py" = ["S101"]

# Multiple patterns for same file type
"__init__.py" = ["F401", "E402", "D104"]
"**/migrations/*.py" = ["ALL"]

# Scripts
"scripts/**/*.py" = ["T20", "S"]
"manage.py" = ["INP001"]

# Notebooks (if using ruff on .pyi or generated code)
"*.pyi" = ["D", "ANN"]

# Protobuf generated files
"*_pb2.py" = ["ALL"]
"*_pb2_grpc.py" = ["ALL"]
```

### Common patterns by project type

```toml
# Web app (Django/FastAPI)
[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = ["S101", "ARG001", "D", "ANN", "PLR2004"]
"__init__.py" = ["F401", "D104"]
"**/migrations/**" = ["ALL"]
"manage.py" = ["INP001"]
"settings/**/*.py" = ["F405", "E501"]
"conftest.py" = ["ARG001"]
"scripts/**/*.py" = ["T20", "INP001"]
"docs/**/*.py" = ["INP001", "D"]

# Library
[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = ["S101", "ARG001", "D103", "ANN"]
"__init__.py" = ["F401", "D104"]
"examples/**/*.py" = ["T20", "D", "INP001"]
"benchmarks/**/*.py" = ["T20", "S101"]
"docs/conf.py" = ["INP001", "A001"]
```

---

## target-version and Python Version Gating

`target-version` affects which rules are enabled and which fixes are applied:

```toml
[tool.ruff]
target-version = "py310"
```

### Version-gated behaviors

| Version | Rules/fixes enabled |
|---------|-------------------|
| `py38` | UP004 (remove `object` base), UP008 (`super()`) |
| `py39` | UP006 (`typing.List` → `list`), UP035 (deprecated typing imports) |
| `py310` | UP007 (`Union` → `\|`), UP038 (isinstance union) |
| `py311` | UP036 (version block cleanup) |
| `py312` | UP040 (`TypeAlias` → `type` statement) |
| `py313` | Latest deprecation removals |

### Multiple Python versions

If your project supports multiple Python versions, set `target-version` to the **minimum** supported version:

```toml
# Project supports Python 3.9+
[tool.ruff]
target-version = "py39"
# UP006 (List→list) will fire, but UP007 (Union→|) won't
```

### required-version

Lock the Ruff version for reproducibility:

```toml
[tool.ruff]
required-version = ">=0.11.0,<0.12.0"
```

---

## Preview Rules

Preview rules are new, potentially unstable rules behind a flag. They may change behavior between releases.

### Enabling preview

```toml
[tool.ruff]
preview = true  # Enables ALL preview rules and behaviors

[tool.ruff.lint]
preview = true  # Preview for linting only

[tool.ruff.format]
preview = true  # Preview for formatting only
```

### Selective preview rules

You can use preview mode while selecting specific preview rules:

```toml
[tool.ruff.lint]
preview = true
select = ["E", "F", "W", "I", "UP"]
# Preview rules within these categories are now available

# Or explicitly select a preview rule:
extend-select = ["FURB101", "FURB103"]
# Some FURB rules require preview = true
```

### Checking preview status

```bash
# List all rules and their preview status
ruff rule --all 2>&1 | grep "preview"

# Check a specific rule
ruff rule FURB101
```

---

## Rule Deprecation Handling

When rules are deprecated, Ruff will warn. Handle proactively:

```toml
[tool.ruff.lint]
select = ["E", "F", "W", "I", "UP", "B", "N", "S"]
ignore = [
    # Deprecated rules — remove when dropping Python 3.9
    "ANN101",  # Deprecated: missing-type-self (removed in Ruff 0.2+)
    "ANN102",  # Deprecated: missing-type-cls

    # Rules that conflict with formatter
    "COM812",  # trailing-comma (conflicts with ruff format)
    "ISC001",  # single-line-implicit-string-concatenation (conflicts with ruff format)

    # Deprecated W codes (removed from pycodestyle)
    # "W503",  # Not in Ruff at all (line break before binary operator)
]
```

### Formatter conflicts

These rules **must** be ignored when using `ruff format`:

```toml
ignore = [
    "COM812",  # Trailing comma — formatter handles this
    "ISC001",  # Implicit string concat — conflicts with formatter
    "E111",    # Indentation — formatter handles
    "E114",    # Indentation — formatter handles
    "E117",    # Over-indented — formatter handles
    "W191",    # Tabs — formatter handles
]
```

---

## Custom Fixable/Unfixable Sets

Fine-grained control over which rules can be auto-fixed:

```toml
[tool.ruff.lint]
# Allow all fixes by default
fixable = ["ALL"]

# Never auto-fix these (require manual review)
unfixable = [
    "F401",   # Don't auto-remove imports (might be re-exports)
    "F841",   # Don't auto-remove variables (might have side effects)
    "ERA001", # Don't auto-remove commented code (might be intentional)
    "B",      # Don't auto-fix bugbear (review manually)
]
```

### Safe vs unsafe fix control via CLI

```bash
# Only safe fixes
ruff check --fix .

# Safe + unsafe fixes
ruff check --fix --unsafe-fixes .

# Show what would be fixed
ruff check --diff .

# Show fix safety per violation
ruff check --show-fixes .
```

---

## Namespace Packages

For namespace packages (no `__init__.py`), Ruff needs explicit configuration:

```toml
[tool.ruff]
# Tell Ruff these directories are namespace packages
namespace-packages = ["src/mycompany"]

# Without this, Ruff may not correctly resolve first-party imports
# in directories lacking __init__.py
```

### src layout

```toml
[tool.ruff]
src = ["src"]  # Tell Ruff where your source code lives

[tool.ruff.lint.isort]
known-first-party = ["mypackage"]
```

### Flat layout

```toml
[tool.ruff]
src = ["."]

[tool.ruff.lint.isort]
known-first-party = ["mypackage"]
```

---

## Monorepo Configuration

### Shared root config with per-package overrides

```
monorepo/
├── pyproject.toml          ← root config (shared defaults)
├── packages/
│   ├── api/
│   │   ├── pyproject.toml  ← package-specific overrides
│   │   └── src/
│   ├── worker/
│   │   ├── ruff.toml       ← can use ruff.toml too
│   │   └── src/
│   └── shared/
│       └── src/
└── scripts/
```

**Root pyproject.toml:**
```toml
[tool.ruff]
line-length = 88
target-version = "py312"
extend-exclude = ["**/migrations/**", "**/generated/**"]

[tool.ruff.lint]
select = ["E", "F", "W", "I", "UP", "B", "N", "S", "RUF"]
ignore = ["E501"]

[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = ["S101", "ARG001"]
"__init__.py" = ["F401"]
```

**packages/api/pyproject.toml (extends root):**
```toml
[tool.ruff]
# Inherits line-length, target-version from root
extend = "../../pyproject.toml"

[tool.ruff.lint]
# Add API-specific rules
extend-select = ["FAST"]  # FastAPI rules (if using preview)

[tool.ruff.lint.per-file-ignores]
"**/migrations/**" = ["ALL"]
```

**packages/worker/ruff.toml:**
```toml
extend = "../../pyproject.toml"

[lint]
extend-select = ["ASYNC"]  # Async rules for worker
```

### Running Ruff across monorepo

```bash
# Lint everything from root
ruff check .

# Lint specific package
ruff check packages/api/

# Lint with explicit config
ruff check --config packages/api/pyproject.toml packages/api/
```

---

## Django-Specific Config

```toml
[tool.ruff]
line-length = 88
target-version = "py312"
src = ["."]

[tool.ruff.lint]
select = [
    "E", "F", "W", "I", "UP", "B", "N", "S",
    "A", "C4", "SIM", "RUF", "DJ",  # DJ = flake8-django rules
]
ignore = [
    "E501",   # Line length handled by formatter
    "RUF012", # Mutable class default — common in Django models
]

[tool.ruff.lint.per-file-ignores]
"**/migrations/**" = ["ALL"]              # Auto-generated
"**/settings/**" = ["F405", "E501"]       # Star imports, long lines in settings
"settings.py" = ["F405", "E501"]
"manage.py" = ["INP001"]                  # Not a package
"__init__.py" = ["F401", "D104"]
"tests/**/*.py" = ["S101", "ARG001", "D"]
"conftest.py" = ["ARG001"]
"**/admin.py" = ["D"]                     # Admin classes rarely need docstrings
"**/apps.py" = ["D"]
"**/factories.py" = ["S311", "ARG001"]    # Factories use random, unused fixture args
"**/management/commands/**" = ["T20"]     # Commands use print

[tool.ruff.lint.isort]
known-first-party = ["myproject"]
known-third-party = ["django", "rest_framework", "celery"]
# Django convention: separate django imports
section-order = [
    "future", "standard-library", "third-party",
    "django", "first-party", "local-folder"
]
[tool.ruff.lint.isort.sections]
"django" = ["django", "rest_framework"]

[tool.ruff.lint.pydocstyle]
convention = "google"

[tool.ruff.format]
quote-style = "double"
docstring-code-format = true
```

### Django-specific rules (DJ)

| Code | What it catches |
|------|-----------------|
| DJ001 | Avoid `null=True` on string-based fields |
| DJ003 | Avoid `locals()` in `render` |
| DJ006 | Don't use `exclude` in ModelForm |
| DJ007 | Don't use `__all__` with ModelForm |
| DJ008 | Model without `__str__` |
| DJ012 | Order of model inner classes/methods |

---

## FastAPI-Specific Config

```toml
[tool.ruff]
line-length = 88
target-version = "py312"
src = ["src", "app"]

[tool.ruff.lint]
select = [
    "E", "F", "W", "I", "UP", "B", "N", "S",
    "A", "C4", "SIM", "RUF", "ASYNC",
    "ANN",   # Type annotations important for FastAPI
    "TCH",   # TYPE_CHECKING optimization
]
ignore = [
    "E501",
    "ANN101", # self type
    "ANN102", # cls type
    "ANN401", # Allow Any in certain cases
    "B008",   # Function call in default — FastAPI's Depends() pattern
]

[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = ["S101", "ARG001", "ANN", "D"]
"__init__.py" = ["F401", "D104"]
"**/models/**" = ["ANN"]      # SQLAlchemy/Pydantic models
"**/schemas/**" = ["ANN"]     # Pydantic schemas have implicit types
"alembic/**" = ["ALL"]
"conftest.py" = ["ARG001", "ANN"]

[tool.ruff.lint.isort]
known-first-party = ["app", "myapi"]
known-third-party = ["fastapi", "pydantic", "sqlalchemy", "httpx", "starlette"]

[tool.ruff.lint.flake8-type-checking]
runtime-evaluated-base-classes = [
    "pydantic.BaseModel",
    "sqlalchemy.orm.DeclarativeBase",
]
# Prevent moving imports used in Pydantic models to TYPE_CHECKING
runtime-evaluated-decorators = [
    "pydantic.validate_call",
    "attrs.define",
]

[tool.ruff.format]
quote-style = "double"
docstring-code-format = true
```

### Key FastAPI pattern: B008 ignore

FastAPI uses `Depends()`, `Query()`, `Path()` etc. as default arguments — this triggers B008. Always ignore B008 for FastAPI:

```python
# This is valid FastAPI but triggers B008 without the ignore
@app.get("/items/")
async def read_items(db: Session = Depends(get_db)):
    ...
```

---

## pytest-Specific Config

```toml
[tool.ruff.lint]
extend-select = ["PT"]  # pytest-style rules

[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = [
    "S101",    # assert is fine in tests
    "ARG001",  # Fixtures often appear unused
    "ARG002",  # Unused method arguments (test classes)
    "D",       # No docstrings required in tests
    "ANN",     # No annotations required in tests
    "PLR2004", # Magic values OK in tests
    "PLR0913", # Many arguments OK in tests (fixtures)
    "S311",    # Random OK in tests
    "E501",    # Long lines OK in tests (assertions)
]
"conftest.py" = ["ARG001", "ARG002"]

[tool.ruff.lint.flake8-pytest-style]
fixture-parentheses = false     # @pytest.fixture not @pytest.fixture()
mark-parentheses = false        # @pytest.mark.slow not @pytest.mark.slow()
parametrize-names-type = "csv"  # "a,b" not ("a", "b") or ["a", "b"]
raises-require-match-for = [
    "ValueError",
    "TypeError",
    "KeyError",
    "AttributeError",
    "RuntimeError",
]
```

---

## Data Science Config

```toml
[tool.ruff]
line-length = 100  # Wider for data science
target-version = "py310"

[tool.ruff.lint]
select = ["E", "F", "W", "I", "UP", "B", "NPY", "RUF"]
ignore = [
    "E501",  # Long lines common with data transforms
    "T20",   # print() OK in notebooks/scripts
    "ERA",   # Commented code OK in exploratory work
]

[tool.ruff.lint.per-file-ignores]
"notebooks/**/*.py" = ["E", "F", "W", "D", "ANN", "T20", "ERA"]
"*.ipynb" = ["E", "F401", "T20", "ERA"]

[tool.ruff.lint.flake8-import-conventions.aliases]
numpy = "np"
pandas = "pd"
matplotlib = "mpl"
"matplotlib.pyplot" = "plt"
seaborn = "sns"
scipy = "sp"
polars = "pl"
tensorflow = "tf"

[tool.ruff.lint.flake8-import-conventions.extend-aliases]
"dask.dataframe" = "dd"
```

---

## Output Formats and Integration

### Available output formats

```bash
ruff check . --output-format text      # Default human-readable
ruff check . --output-format json      # Machine-parseable JSON
ruff check . --output-format github    # GitHub Actions annotations
ruff check . --output-format gitlab    # GitLab CI code quality
ruff check . --output-format pylint    # Pylint-compatible
ruff check . --output-format rdjson    # Reviewdog JSON
ruff check . --output-format sarif     # SARIF (for security tools)
ruff check . --output-format grouped   # Grouped by file
ruff check . --output-format azure     # Azure DevOps
ruff check . --output-format concise   # One-line per violation
ruff check . --output-format full      # Full details with source
```

### JSON output structure

```bash
ruff check --output-format json . | python -m json.tool | head -30
```

```json
[
  {
    "code": "F401",
    "message": "`os` imported but unused",
    "filename": "src/main.py",
    "location": {"row": 1, "column": 8},
    "end_location": {"row": 1, "column": 10},
    "fix": {
      "applicability": "safe",
      "message": "Remove unused import: `os`",
      "edits": [...]
    },
    "url": "https://docs.astral.sh/ruff/rules/unused-import"
  }
]
```

---

## Performance Tuning

### Parallel execution (default)

Ruff auto-parallelizes. Control with environment variables:

```bash
# Limit threads (useful in CI with resource limits)
RUFF_WORKERS=4 ruff check .

# Single-threaded (for debugging)
RUFF_WORKERS=1 ruff check .
```

### Exclude patterns for speed

```toml
[tool.ruff]
extend-exclude = [
    "node_modules",
    "vendor",
    "*.min.py",
    "generated/",
    ".venv",
    "data/",        # Large data directories
    "**/*.pyc",
]
```

### Force-exclude

Use when files match include patterns but should still be skipped:

```toml
[tool.ruff]
force-exclude = true  # Respect excludes even when files are passed explicitly
```

---

## Cache Management

Ruff caches results in `.ruff_cache/` by default:

```bash
# Clear cache
ruff clean

# Disable cache (CI environments)
ruff check --no-cache .

# Custom cache directory
ruff check --cache-dir /tmp/ruff-cache .
```

```toml
[tool.ruff]
cache-dir = ".ruff_cache"  # Default
```

### .gitignore entry

```
.ruff_cache/
```

---

## Complete Production Config Template

```toml
# Full production config for a web application
[tool.ruff]
line-length = 88
target-version = "py312"
src = ["src"]
extend-exclude = ["migrations", "generated"]
# required-version = ">=0.11.0"  # Pin for reproducibility

[tool.ruff.lint]
select = [
    "E", "F", "W",    # pycodestyle + pyflakes
    "I",               # isort
    "UP",              # pyupgrade
    "B",               # bugbear
    "N",               # pep8-naming
    "S",               # bandit security
    "A",               # builtins shadowing
    "C4",              # comprehensions
    "SIM",             # simplify
    "RUF",             # ruff-specific
    "PERF",            # performance
    "T20",             # print detection
    "PT",              # pytest style
    "RET",             # return style
    "ARG",             # unused arguments
    "DTZ",             # datetime timezone
    "FURB",            # refurb modernization
    "PLR",             # pylint refactor subset
]
ignore = [
    "E501",            # Line length — formatter handles
    "COM812",          # Trailing comma — conflicts with formatter
    "ISC001",          # String concat — conflicts with formatter
]
fixable = ["ALL"]
unfixable = ["F401"]   # Don't auto-remove imports

[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = ["S101", "ARG", "D", "ANN", "PLR2004", "PLR0913"]
"__init__.py" = ["F401", "D104"]
"conftest.py" = ["ARG001"]
"scripts/**" = ["T20", "INP001"]

[tool.ruff.lint.isort]
known-first-party = ["myapp"]
combine-as-imports = true
force-sort-within-sections = true

[tool.ruff.lint.pydocstyle]
convention = "google"

[tool.ruff.lint.pylint]
max-args = 6
max-returns = 8
max-branches = 15

[tool.ruff.lint.flake8-pytest-style]
fixture-parentheses = false
mark-parentheses = false

[tool.ruff.format]
quote-style = "double"
indent-style = "space"
docstring-code-format = true
docstring-code-line-length = 72
line-ending = "auto"
```
