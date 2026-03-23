---
name: python-dependency-management
description: >
  Use when user manages Python dependencies, asks about uv, pip, poetry, hatch,
  pyproject.toml, virtual environments, lockfiles, dependency resolution, or
  Python packaging with modern tools. Do NOT use for Python packaging/distribution
  (use python-packaging skill), conda/mamba, or general pip install troubleshooting.
---

# Python Dependency Management

## Modern Packaging Landscape

`pyproject.toml` is the single standard project configuration file (PEP 518/517/621). It replaces `setup.py`, `setup.cfg`, and `requirements.txt` for metadata.

- **PEP 518**: Introduced `pyproject.toml` and `[build-system]` table.
- **PEP 517**: Decoupled build frontends (pip, build) from backends (setuptools, hatchling, flit).
- **PEP 621**: Standardized `[project]` table for name, version, dependencies, and metadata.

Always use `pyproject.toml` for new projects. Legacy `setup.py` is only needed for dynamic build logic.

---

## uv (Astral)

Rust-based, 10–100x faster than pip. Replaces pip, pip-tools, venv, virtualenv, pyenv, and pipx.

### Installation

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
# or
pip install uv
brew install uv
```

### Core Commands

```bash
uv init myproject                # scaffold project with pyproject.toml
uv add requests flask            # add dependencies, update pyproject.toml + uv.lock
uv add --dev pytest ruff         # add dev dependencies
uv remove flask                  # remove a dependency
uv lock                          # resolve and write uv.lock without installing
uv sync                          # install exact versions from uv.lock
uv sync --frozen                 # install without updating lockfile
uv run python script.py          # run in project venv (auto-creates if missing)
uv run pytest                    # run any command in project venv
```

### pip Compatibility

```bash
uv pip install requests          # drop-in pip replacement (much faster)
uv pip install -r requirements.txt
uv pip compile requirements.in -o requirements.txt  # like pip-compile
uv pip sync requirements.txt     # like pip-sync
```

### Virtual Environments & Python Versions

```bash
uv venv                          # create .venv in current directory
uv venv --python 3.12            # create with specific Python
uv python install 3.13           # download and manage Python versions
uv python list                   # list available/installed Pythons
uv python pin 3.12               # write .python-version file
```

### Tool Management (pipx replacement)

```bash
uv tool install ruff             # install CLI tool globally in isolated env
uv tool run black -- --check .   # run tool ephemerally (also: uvx black)
uvx ruff check .                 # shorthand for uv tool run
```

### Performance Tips

- uv uses aggressive caching (`~/.cache/uv`). Clear with `uv cache clean`.
- Parallel resolution and downloads by default.
- Use `uv sync --frozen` in CI to skip resolution entirely.

---

## pip and pip-tools

### pip Basics

```bash
pip install requests              # install from PyPI
pip install requests==2.31.0      # pin exact version
pip install -r requirements.txt   # install from file
pip install -e .                  # editable/development install
pip install ".[dev]"              # install with optional extras
pip freeze > requirements.txt     # snapshot current environment
pip install --constraint constraints.txt  # apply version constraints
```

### pip-tools (Recommended with pip)

```bash
pip install pip-tools

# requirements.in → requirements.txt (locked)
pip-compile requirements.in               # resolve and pin all transitive deps
pip-compile --upgrade                      # upgrade all packages
pip-compile --upgrade-package requests     # upgrade single package
pip-sync requirements.txt                  # make env match requirements exactly
pip-compile --generate-hashes              # add hashes for supply-chain security
```

Keep `requirements.in` (abstract) and `requirements.txt` (locked) both in version control.

### Constraints Files

```bash
# constraints.txt — enforce version bounds without installing
pip install -c constraints.txt -r requirements.txt
```

Use constraints to enforce org-wide version policies across multiple projects.

---

## Poetry

### Setup

```bash
curl -sSL https://install.python-poetry.org | python3 -
poetry self update
```

### Project Workflow

```bash
poetry new myproject              # create project scaffold
poetry init                       # interactive init in existing directory
poetry add requests               # add to [tool.poetry.dependencies]
poetry add --group dev pytest     # add to dev dependency group
poetry remove requests            # remove dependency
poetry lock                       # resolve deps → poetry.lock
poetry install                    # install from poetry.lock
poetry install --sync             # remove packages not in lock
poetry update                     # update deps within constraints
poetry show --tree                # visualize dependency tree
poetry run pytest                 # run command in Poetry-managed venv
poetry shell                      # activate venv subshell
```

### Dependency Groups

```toml
# pyproject.toml (Poetry-specific format, migrating to PEP 621 in Poetry 2.x)
[tool.poetry.group.dev.dependencies]
pytest = "^8.0"
ruff = ">=0.4"

[tool.poetry.group.docs.dependencies]
sphinx = "^7.0"
```

```bash
poetry install --with docs        # install main + docs group
poetry install --only dev         # install only dev group
poetry install --without docs     # exclude docs group
```

### Publishing

```bash
poetry build                      # build sdist + wheel
poetry publish                    # upload to PyPI
poetry config pypi-token.pypi <token>
```

### poetry.lock

Always commit `poetry.lock`. It ensures reproducible installs. `poetry install` reads the lock; `poetry update` regenerates it.

---

## Hatch

### Setup and Core Commands

```bash
pip install hatch
hatch new myproject               # create project with pyproject.toml
hatch new --init                  # init in existing directory
hatch env create                  # create default environment
hatch shell                       # enter default environment shell
hatch run pytest                  # run command in default env
hatch run test:pytest             # run in named env
```

### Environment Matrix Testing

```toml
# pyproject.toml
[tool.hatch.envs.test]
dependencies = ["pytest", "coverage"]

[[tool.hatch.envs.test.matrix]]
python = ["3.10", "3.11", "3.12", "3.13"]
```

```bash
hatch run test:pytest             # runs across all matrix combinations
```

### Version Management and Scripts

```bash
hatch version                     # show current version
hatch version minor               # bump minor version
```

```toml
[tool.hatch.envs.default.scripts]
lint = "ruff check ."
test = "pytest {args}"
all = ["lint", "test"]
```

---

## PDM

Supports PEP 621 natively. Optional PEP 582 (`__pypackages__`) for install-without-venv.

```bash
pip install pdm
pdm init                          # initialize project
pdm add requests                  # add dependency
pdm add -dG test pytest           # add to dev group "test"
pdm remove requests               # remove dependency
pdm lock                          # generate pdm.lock
pdm install                       # install from lockfile
pdm run python script.py          # run in project environment
pdm update                        # update dependencies
pdm list --tree                   # show dependency tree
```

PDM stores metadata in standard `[project]` table. Lockfile is `pdm.lock`.

---

## Virtual Environments

### Creation and Activation

```bash
python -m venv .venv              # stdlib venv
source .venv/bin/activate         # Linux/macOS
.venv\Scripts\activate            # Windows
deactivate                        # leave venv
```

### Key Concepts

- `VIRTUAL_ENV` env var points to active venv path.
- `.python-version` file: used by pyenv, uv, and other tools to auto-select Python.
- Always add `.venv/` to `.gitignore`. Prefer `.venv` as directory name.
- Verify: `which python` should point to `.venv/bin/python`.

---

## pyproject.toml Reference

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "mypackage"
version = "1.0.0"
requires-python = ">=3.10"
license = "MIT"
dependencies = [
    "requests>=2.28",
    "pydantic>=2.0,<3",
]

[project.optional-dependencies]
dev = ["pytest>=8.0", "ruff>=0.4"]

[project.scripts]
mycli = "mypackage.cli:main"

[tool.pytest.ini_options]
testpaths = ["tests"]

[tool.ruff]
line-length = 88
```

---

## Dependency Specification

### Version Specifiers (PEP 440)

```
requests>=2.28            # minimum version
requests>=2.28,<3         # bounded range
requests~=2.28.0          # compatible release (>=2.28.0, <2.29.0)
requests==2.31.0          # exact pin
requests!=2.30.0          # exclusion
```

### Extras

```
httpx[http2]              # install with http2 extra
package[extra1,extra2]    # multiple extras
```

### Platform Markers (PEP 508)

```
pywin32>=300; sys_platform == "win32"
uvloop>=0.19; sys_platform != "win32"
typing-extensions>=4.0; python_version < "3.12"
```

### Source URLs and Direct References

```
package @ https://example.com/package-1.0.tar.gz
package @ git+https://github.com/user/repo.git@main
package @ git+https://github.com/user/repo.git@v2.0.0
```

---

## Lockfiles

### Why Lock

- Pin exact versions of all transitive dependencies.
- Guarantee reproducible builds across machines and CI.
- Detect dependency drift and supply-chain changes.

### Lockfile Formats

| Tool       | Lockfile             | Cross-platform | Hashes |
|------------|----------------------|----------------|--------|
| uv         | `uv.lock`            | Yes            | Yes    |
| Poetry     | `poetry.lock`        | Yes            | Yes    |
| pip-tools  | `requirements.txt`   | No             | Opt-in |
| PDM        | `pdm.lock`           | Yes            | Yes    |

### Rules

- Always commit lockfiles to version control.
- Use `--frozen` or `--sync` flags in CI to fail on lockfile mismatch.
- Regenerate lockfiles on dependency changes, not manually.

---

## Dependency Resolution

### Conflict Resolution

When two packages require incompatible versions of a shared dependency, the resolver fails. Fix by:

1. Relaxing version bounds in your own `pyproject.toml`.
2. Upgrading the conflicting packages.
3. Using `--resolution lowest-direct` (uv) to test lower bounds.

### Version Bounds Strategy

- **Applications**: Pin exact versions in lockfile. Use `>=` in pyproject.toml.
- **Libraries**: Use `>=` lower bounds. Avoid upper bounds (`<`) unless a known incompatibility exists.
- **Upper bound controversy**: Adding `<` caps causes ecosystem-wide resolution failures. Prefer testing against new releases over preemptive caps.

### Inspecting the Dependency Tree

```bash
uv tree                           # uv
poetry show --tree                 # poetry
pipdeptree                        # pip (install pipdeptree first)
pdm list --tree                   # pdm
```

---

## CI/CD Patterns

### Caching

```yaml
# GitHub Actions — uv
- uses: astral-sh/setup-uv@v4
  with:
    enable-cache: true
- run: uv sync --frozen

# GitHub Actions — pip
- uses: actions/setup-python@v5
  with:
    python-version: "3.12"
    cache: "pip"
- run: pip install -r requirements.txt
```

### Lockfile Verification

```bash
# Fail CI if lockfile is stale
uv lock --check                   # uv: exits non-zero if lock needs update
poetry check --lock               # poetry: verify lock matches pyproject.toml
```

### Security Scanning

```bash
pip-audit                         # scan installed packages for CVEs
uv pip audit                      # uv equivalent
safety check                      # another scanner
```

---

## Monorepo Patterns

### uv Workspaces

```toml
# Root pyproject.toml
[tool.uv.workspace]
members = ["packages/*"]
```

```bash
uv sync                          # resolves all workspace members together
uv run --package subpkg pytest    # run command in specific member
```

### Path Dependencies

```toml
# In a sub-package pyproject.toml
dependencies = ["shared-lib @ file:///../shared-lib"]

# Or with uv/poetry source:
[tool.uv.sources]
shared-lib = { path = "../shared-lib", editable = true }
```

### Editable Installs

```bash
pip install -e ./packages/core    # pip
uv pip install -e ./packages/core # uv
poetry install                    # poetry auto-installs project as editable
```

Use editable installs during development so code changes reflect immediately.

---

## Tool Comparison

| Feature              | uv            | pip + pip-tools | Poetry        | Hatch         |
|----------------------|---------------|-----------------|---------------|---------------|
| Speed                | Fastest       | Slow            | Moderate      | Fast          |
| Lockfile             | `uv.lock`     | `requirements.txt` | `poetry.lock` | None (planned)|
| Venv management      | Built-in      | Manual          | Built-in      | Built-in      |
| Python management    | Built-in      | No              | No            | No            |
| PEP 621 support      | Yes           | N/A             | Poetry 2.x    | Yes           |
| Workspaces/monorepo  | Yes           | No              | No            | Yes           |
| Tool runner (pipx)   | `uvx`         | No              | No            | No            |
| Maturity             | Newer (2024+) | Established     | Established   | Growing       |

### When to Choose

- **uv**: Default for new projects. Best speed, unified workflow, CI/CD, monorepos.
- **pip + pip-tools**: Legacy projects, minimal tooling, corporate environments with pip-only policy.
- **Poetry**: Established teams already using it; good library publishing workflow.
- **Hatch**: Matrix testing, advanced environment management, PyPA-aligned standards.

---

## Anti-Patterns

1. **Unpinned dependencies in deployment**: Always lock. `pip install requests` in production without a lockfile causes version drift.
2. **Global installs**: Never `pip install` into system Python. Always use a venv.
3. **`requirements.txt` without lockfile**: A `requirements.txt` with `>=` specifiers is not a lockfile. Use `pip-compile` or switch to uv/poetry.
4. **Committing `.venv/`**: Add `.venv/` to `.gitignore`. Environments are not portable.
5. **Manual lockfile edits**: Never hand-edit `uv.lock`, `poetry.lock`, or compiled `requirements.txt`. Regenerate via tooling.
6. **Mixing dependency managers**: Pick one tool per project. Do not mix `poetry add` with `pip install`.
7. **Upper-bounding library deps**: Avoid `<` caps in libraries unless a known breakage exists. Caps cause resolver conflicts downstream.
8. **Ignoring `requires-python`**: Set it in `pyproject.toml` so resolvers select compatible wheels.
9. **`pip freeze` as source of truth**: `pip freeze` captures everything including transitive deps. Use `pip-compile` from an `.in` file instead.
10. **Skipping hash verification**: Use `--generate-hashes` (pip-compile) or uv's built-in hashing for supply-chain security.

<!-- tested: pass -->
