---
name: python-packaging
description:
  positive: "Use when user creates Python packages, asks about pyproject.toml, setup.cfg, setuptools, poetry, hatch, uv, flit, building wheels/sdists, publishing to PyPI, version management, or dependency specification."
  negative: "Do NOT use for pip install usage, virtual environment setup, or Python application deployment (Docker, serverless)."
---

# Python Packaging and Distribution

## pyproject.toml as the Standard

Use `pyproject.toml` as the single source of truth. It replaces `setup.py`, `setup.cfg`, and `MANIFEST.in` for modern projects. Three top-level tables matter:

### [build-system] — Required

Declare the build backend. Always pin a minimum version.

```toml
[build-system]
requires = ["hatchling>=1.26"]
build-backend = "hatchling.build"
```

### [project] — PEP 621 Metadata

All package metadata lives here. Keep it static when possible.

```toml
[project]
name = "my-package"
version = "1.2.0"
description = "Short description of what this does"
readme = "README.md"
license = "MIT"
requires-python = ">=3.10"
authors = [{ name = "Your Name", email = "you@example.com" }]
classifiers = [
    "Programming Language :: Python :: 3",
    "License :: OSI Approved :: MIT License",
]
dependencies = [
    "httpx>=0.27",
    "pydantic>=2.0,<3",
]

[project.urls]
Homepage = "https://github.com/you/my-package"
Documentation = "https://my-package.readthedocs.io"
```

### [tool.*] — Tool Configuration

Consolidate tool config here instead of separate files:

```toml
[tool.ruff]
line-length = 88

[tool.pytest.ini_options]
testpaths = ["tests"]

[tool.mypy]
strict = true
```

## Build Backends Comparison

| Backend | Best For | PEP 621 | C Extensions | Editable (PEP 660) |
|---------|----------|---------|-------------|---------------------|
| **setuptools** | Legacy, C extensions, max compat | Yes | Full support | Yes |
| **hatchling** | New projects, speed, plugins | Yes | Via hooks | Yes |
| **flit** | Simple pure-Python packages | Yes | No | Yes |
| **poetry-core** | Poetry users, all-in-one workflow | Yes (v2+) | Limited | Yes |
| **maturin** | Rust/Python hybrid (PyO3) | Yes | Rust only | Yes |

### Build-system declarations

```toml
# setuptools
[build-system]
requires = ["setuptools>=77"]
build-backend = "setuptools.build_meta"

# hatchling
[build-system]
requires = ["hatchling>=1.26"]
build-backend = "hatchling.build"

# flit
[build-system]
requires = ["flit_core>=3.9"]
build-backend = "flit_core.buildapi"

# poetry
[build-system]
requires = ["poetry-core>=2.0"]
build-backend = "poetry.core.masonry.api"

# maturin (Rust extensions)
[build-system]
requires = ["maturin>=1.7"]
build-backend = "maturin"
```

Choose **hatchling** for new pure-Python projects. Use **setuptools** when you need C/Cython extensions or legacy compatibility. Use **maturin** for Rust bindings.

## Package Manager Comparison

| Feature | pip | uv | poetry | pdm | hatch |
|---------|-----|-----|--------|-----|-------|
| Written in | Python | Rust | Python | Python | Python |
| Speed | Moderate | 10-40× faster | Moderate | Fast | Fast |
| Lockfile | No (use pip-tools) | uv.lock | poetry.lock | pdm.lock | No |
| Venv management | Manual | Built-in | Built-in | Built-in | Built-in |
| Python version mgmt | No | Yes | No | Yes | No |
| Publishing | No (use twine) | Yes | Yes | Yes | Yes |
| Workspaces/monorepo | No | Yes | Experimental | Yes | Yes |
| Dependency groups (PEP 735) | Yes (pip 25.1+) | Yes | Yes | Yes | Yes |

**Recommendations:** Use **uv** for speed and CI/CD. Use **poetry** for teams wanting all-in-one workflow. Use **hatch** for plugin-driven development workflows.

## Project Structure

### src layout (recommended for libraries)

```
my-project/
├── src/
│   └── my_package/
│       ├── __init__.py
│       ├── core.py
│       └── py.typed
├── tests/
│   ├── __init__.py
│   └── test_core.py
├── pyproject.toml
├── README.md
└── LICENSE
```

Prevents accidental imports from the project root during testing. Catches packaging errors before publishing. Use for anything published to PyPI.

With setuptools, explicitly set package discovery:

```toml
[tool.setuptools.packages.find]
where = ["src"]
```

Hatchling and flit auto-detect `src/` layout.

### Flat layout (acceptable for apps and small scripts)

```
my-project/
├── my_package/
│   ├── __init__.py
│   └── core.py
├── tests/
├── pyproject.toml
└── README.md
```

Simpler but risks test pollution from local imports. Use for internal tools and applications not published to PyPI.

## Dependency Specification

### Version ranges

```toml
dependencies = [
    "requests>=2.28,<3",       # compatible range
    "numpy>=1.24",             # minimum only — use for stable APIs
    "pydantic~=2.0",           # equivalent to >=2.0,<3.0
    "typing-extensions>=4.0;python_version<'3.12'",  # environment marker
]
```

### Optional dependencies (extras)

```toml
[project.optional-dependencies]
dev = ["pytest>=8", "ruff>=0.5", "mypy>=1.10"]
docs = ["sphinx>=7", "sphinx-rtd-theme"]
postgres = ["psycopg[binary]>=3.1"]
```

Install with `pip install my-package[dev,docs]` or `uv pip install my-package[dev]`.

### Dependency groups (PEP 735)

For development-only deps that should NOT be published as package extras:

```toml
[dependency-groups]
test = ["pytest>=8", "pytest-cov"]
lint = ["ruff>=0.5", "mypy>=1.10"]
dev = [
    { include-group = "test" },
    { include-group = "lint" },
]
```

Install with `pip install --group test` (pip 25.1+) or `uv sync --group dev`.

Dependency groups replace ad-hoc `requirements-dev.txt` files. Use extras for end-user-installable optional features. Use dependency groups for contributor/CI workflows.

## Entry Points

### Console scripts

```toml
[project.scripts]
my-cli = "my_package.cli:main"
```

Creates a `my-cli` executable on install that calls `my_package.cli.main()`.

### GUI scripts

```toml
[project.gui-scripts]
my-app = "my_package.gui:launch"
```

Same as console scripts but suppresses console window on Windows.

### Plugin entry points

```toml
[project.entry-points."my_package.plugins"]
csv = "my_package.plugins.csv:CsvPlugin"
json = "my_package.plugins.json:JsonPlugin"
```

Discover at runtime:

```python
from importlib.metadata import entry_points
plugins = entry_points(group="my_package.plugins")
for ep in plugins:
    plugin_class = ep.load()
```

## Version Management

### Static version

```toml
[project]
version = "1.2.0"
```

Simple. Manually bump before each release.

### Dynamic version from VCS (setuptools-scm)

```toml
[build-system]
requires = ["setuptools>=77", "setuptools-scm>=8"]
build-backend = "setuptools.build_meta"

[project]
dynamic = ["version"]

[tool.setuptools_scm]
```

Derives version from git tags. Tag `v1.2.0` → version `1.2.0`. Untagged commits get dev versions like `1.2.1.dev3+g1a2b3c4`.

### Dynamic version with hatch-vcs

```toml
[build-system]
requires = ["hatchling", "hatch-vcs"]
build-backend = "hatchling.build"

[project]
dynamic = ["version"]

[tool.hatch.version]
source = "vcs"
```

### Version bumping (without VCS)

Use `bump2version` or `python-semantic-release` for automated version bumps:

```bash
bump2version minor  # 1.2.0 → 1.3.0
```

## Building Packages

### Build sdist and wheel

```bash
python -m build           # builds both sdist and wheel in dist/
uv build                  # same, faster
hatch build               # if using hatch
```

Always publish both sdist (`.tar.gz`) and wheel (`.whl`). Wheels skip the build step at install time.

### Editable installs (PEP 660)

```bash
pip install -e .          # editable install for development
uv pip install -e .       # same, faster
```

PEP 660 standardized editable installs for PEP 517 build backends. No `setup.py` needed. All modern backends (setuptools, hatchling, flit) support this.

## Publishing to PyPI

### Using twine (traditional)

```bash
python -m build
twine check dist/*                           # validate metadata
twine upload --repository testpypi dist/*    # test first
twine upload dist/*                          # publish to PyPI
```

### Trusted publishing with OIDC (recommended)

Configure on PyPI: Project Settings → Publishing → add GitHub Actions as trusted publisher. Specify owner, repo, workflow filename, and optionally a GitHub environment.

```yaml
# .github/workflows/publish.yml
name: Publish to PyPI
on:
  release:
    types: [published]

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    environment: pypi
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.x"
      - run: python -m pip install build && python -m build
      - uses: pypa/gh-action-pypi-publish@v1
```

No API tokens needed. OIDC tokens are short-lived and scoped to the specific workflow.

### TestPyPI workflow

Always test first:

1. Register trusted publisher on `test.pypi.org` with the same workflow.
2. Upload to TestPyPI: `twine upload --repository testpypi dist/*`
3. Install from TestPyPI: `pip install --index-url https://test.pypi.org/simple/ my-package`
4. Verify install works, then publish to production PyPI.

## Package Data and Resource Files

Include non-Python files (templates, configs, data) via build backend config.

### With setuptools

```toml
[tool.setuptools.package-data]
my_package = ["data/*.json", "templates/*.html", "py.typed"]
```

### With hatchling

Hatchling includes all tracked files by default. Exclude with:

```toml
[tool.hatch.build.targets.wheel]
packages = ["src/my_package"]
exclude = ["tests/"]
```

### Accessing resources at runtime

Use `importlib.resources` — never use `__file__` paths:

```python
from importlib.resources import files

data = files("my_package").joinpath("data/config.json").read_text()
```

For files requiring a filesystem path (e.g., passing to C libraries):

```python
from importlib.resources import as_file, files

with as_file(files("my_package").joinpath("data/model.bin")) as path:
    load_model(str(path))
```

## Type Stubs and py.typed Marker

### Inline typing (preferred)

Add type annotations directly in `.py` files. Place an empty `py.typed` marker at the package root (next to `__init__.py`). This signals PEP 561 compliance to type checkers.

```
src/my_package/
├── __init__.py
├── core.py       # contains inline type annotations
└── py.typed      # empty file
```

Include `py.typed` in package data:

```toml
[tool.setuptools.package-data]
my_package = ["py.typed"]
```

### Stub-only packages

For third-party stubs, create a separate `<pkgname>-stubs` package. No `py.typed` needed — the `-stubs` suffix signals typing support.

### Validate completeness

```bash
pyright --verifytypes my_package
```

Reports percentage of public API that is typed. Aim for 100% before adding `py.typed`.

## Inline Script Metadata (PEP 723)

For single-file scripts, embed dependencies inline:

```python
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "httpx>=0.27",
#     "rich",
# ]
# ///

import httpx
from rich import print
# ...
```

Run with `uv run script.py` — uv auto-creates an ephemeral environment with the declared dependencies.

## Common Mistakes and Fixes

**Missing `__init__.py`:** Every Python package directory needs one. Without it, setuptools and flit will not discover the package.

**Using `find_packages()` in pyproject.toml:** There is no `find_packages()` function. Use `[tool.setuptools.packages.find]` table instead.

**Hardcoded `__file__` paths for data:** Breaks in wheel installs and zip imports. Use `importlib.resources.files()`.

**Publishing without `py.typed`:** Type checkers ignore your annotations if `py.typed` is missing. Add it and include it in package data.

**Version mismatch between tag and metadata:** Use `setuptools-scm` or `hatch-vcs` to derive version from git tags automatically.

**Forgetting `requires-python`:** Always set it. Without it, pip may install your package on incompatible Python versions.

**Using `setup.py` for new projects:** Use `pyproject.toml` exclusively. `setup.py` is legacy and causes security concerns (arbitrary code execution on install).

**Not testing with TestPyPI:** Always upload to TestPyPI first. Broken releases on PyPI cannot be re-uploaded with the same version.

**Declaring dev dependencies as extras:** Use PEP 735 dependency groups for development dependencies. Extras are for end-user-installable optional features.

**Missing `build-system` table:** Without it, pip falls back to legacy `setup.py` behavior. Always declare the build backend explicitly.
