# Migrating to Ruff — Complete Migration Guide

> Step-by-step migration from flake8, black, isort, pylint, bandit, pyupgrade, and pydocstyle to Ruff.

## Table of Contents

- [Migration Overview](#migration-overview)
- [From flake8 (+ plugins)](#from-flake8--plugins)
- [From Black](#from-black)
- [From isort](#from-isort)
- [From Pylint](#from-pylint)
- [From Bandit](#from-bandit)
- [From pyupgrade](#from-pyupgrade)
- [From pydocstyle / pydocstyle via flake8-docstrings](#from-pydocstyle)
- [From autopep8 / yapf](#from-autopep8--yapf)
- [Combined Migration (All-in-One)](#combined-migration-all-in-one)
- [Config File Migration](#config-file-migration)
- [Pre-commit Migration](#pre-commit-migration)
- [CI/CD Migration](#cicd-migration)
- [Handling Gaps](#handling-gaps)
- [Verification Checklist](#verification-checklist)

---

## Migration Overview

### What Ruff replaces

| Tool | Ruff equivalent | Parity |
|------|----------------|--------|
| flake8 | `ruff check` (E, W, F rules) | ~100% for core rules |
| flake8-bugbear | `ruff check` (B rules) | ~100% |
| flake8-comprehensions | `ruff check` (C4 rules) | 100% |
| flake8-simplify | `ruff check` (SIM rules) | ~95% |
| flake8-bandit | `ruff check` (S rules) | ~90% |
| flake8-import-conventions | `ruff check` (ICN rules) | 100% |
| flake8-pytest-style | `ruff check` (PT rules) | ~95% |
| flake8-print | `ruff check` (T20 rules) | 100% |
| flake8-annotations | `ruff check` (ANN rules) | ~90% |
| flake8-builtins | `ruff check` (A rules) | 100% |
| flake8-datetimez | `ruff check` (DTZ rules) | 100% |
| flake8-return | `ruff check` (RET rules) | 100% |
| flake8-unused-arguments | `ruff check` (ARG rules) | 100% |
| flake8-pie | `ruff check` (PIE rules) | 100% |
| flake8-boolean-trap | `ruff check` (FBT rules) | 100% |
| flake8-implicit-str-concat | `ruff check` (ISC rules) | 100% |
| flake8-eradicate | `ruff check` (ERA rules) | 100% |
| flake8-tidy-imports | `ruff check` (TID rules) | ~90% |
| Black | `ruff format` | >99.9% identical output |
| isort | `ruff check --fix` (I rules) | ~100% |
| pyupgrade | `ruff check --fix` (UP rules) | ~95% |
| pydocstyle | `ruff check` (D rules) | ~100% |
| Pylint (partial) | `ruff check` (PL rules) | ~30% of Pylint rules |
| bandit | `ruff check` (S rules) | ~60% of Bandit rules |
| autopep8 | `ruff format` + `ruff check --fix` | ~95% |

### Migration order (recommended)

1. **isort** → simplest, drop-in replacement
2. **Black** → `ruff format` is near-identical
3. **pyupgrade** → add UP rules
4. **flake8 + plugins** → map rules, biggest config effort
5. **bandit** → add S rules, review coverage gaps
6. **pylint** → partial replacement, may keep pylint for advanced rules
7. **pydocstyle** → add D rules with convention preset

---

## From flake8 (+ plugins)

### Step 1: Inventory current flake8 config

Find your config location:
```bash
# Check these files in order
cat .flake8 2>/dev/null
grep -A 30 '\[flake8\]' setup.cfg 2>/dev/null
grep -A 30 '\[flake8\]' tox.ini 2>/dev/null
```

### Step 2: Map flake8 settings to Ruff

| flake8 setting | Ruff equivalent | Location |
|---------------|----------------|----------|
| `max-line-length` | `line-length` | `[tool.ruff]` |
| `select` | `select` | `[tool.ruff.lint]` |
| `extend-select` | `extend-select` | `[tool.ruff.lint]` |
| `ignore` | `ignore` | `[tool.ruff.lint]` |
| `extend-ignore` | `extend-ignore` | `[tool.ruff.lint]` |
| `per-file-ignores` | per-file-ignores | `[tool.ruff.lint.per-file-ignores]` |
| `exclude` | `exclude` | `[tool.ruff]` |
| `max-complexity` | `max-complexity` | `[tool.ruff.lint.mccabe]` |
| `max-doc-length` | `max-doc-length` | `[tool.ruff.lint.pycodestyle]` |
| `count` | N/A (use `--statistics`) | CLI flag |
| `format` | `--output-format` | CLI flag |
| `show-source` | `--show-source` (default on) | CLI flag |

### Step 3: Map flake8 plugin codes

Most flake8 plugins use the **same rule codes** in Ruff:

| flake8 plugin | Install name | Ruff prefix | Notes |
|--------------|-------------|-------------|-------|
| flake8-bugbear | `flake8-bugbear` | B | Same codes (B001-B950) |
| flake8-comprehensions | `flake8-comprehensions` | C4 | C400-C419 |
| flake8-simplify | `flake8-simplify` | SIM | SIM1xx-SIM9xx |
| flake8-bandit | `flake8-bandit` | S | S1xx-S7xx |
| flake8-print | `flake8-print` | T20 | T201 (print), T203 (pprint) |
| flake8-isort | `flake8-isort` | I | I001-I002 |
| flake8-annotations | `flake8-annotations` | ANN | ANN001-ANN401 |
| flake8-builtins | `flake8-builtins` | A | A001-A003 |
| flake8-pytest-style | `flake8-pytest-style` | PT | PT001-PT027 |
| flake8-docstrings | `flake8-docstrings` | D | D100-D418 |
| flake8-import-conventions | `flake8-import-conventions` | ICN | ICN001 |
| flake8-return | `flake8-return` | RET | RET501-RET505 |
| flake8-unused-arguments | `flake8-unused-arguments` | ARG | ARG001-ARG005 |
| flake8-datetimez | `flake8-datetimez` | DTZ | DTZ001-DTZ012 |
| flake8-pie | `flake8-pie` | PIE | PIE790-PIE810 |
| flake8-boolean-trap | `flake8-boolean-trap` | FBT | FBT001-FBT003 |
| flake8-implicit-str-concat | `flake8-implicit-str-concat` | ISC | ISC001-ISC003 |
| flake8-eradicate | `flake8-eradicate` | ERA | ERA001 |
| flake8-tidy-imports | `flake8-tidy-imports` | TID | TID251-TID252 |
| pep8-naming | `pep8-naming` | N | N801-N818 |
| mccabe | `mccabe` | C90 | C901 |

### Step 4: Convert config

**flake8 (.flake8):**
```ini
[flake8]
max-line-length = 100
select = E,F,W,B,C4,SIM
ignore = E501,W503
per-file-ignores =
    tests/*.py:S101,D
    __init__.py:F401
exclude =
    .git,
    __pycache__,
    build
max-complexity = 10
```

**Ruff (pyproject.toml):**
```toml
[tool.ruff]
line-length = 100
exclude = [".git", "__pycache__", "build"]

[tool.ruff.lint]
select = ["E", "F", "W", "B", "C4", "SIM"]
ignore = ["E501"]
# Note: W503 doesn't exist in Ruff (line break rules differ)

[tool.ruff.lint.mccabe]
max-complexity = 10

[tool.ruff.lint.per-file-ignores]
"tests/*.py" = ["S101", "D"]
"__init__.py" = ["F401"]
```

### Step 5: Uninstall flake8 and plugins

```bash
pip uninstall flake8 flake8-bugbear flake8-comprehensions flake8-simplify \
    flake8-bandit flake8-print flake8-isort flake8-annotations \
    flake8-builtins flake8-pytest-style flake8-docstrings mccabe \
    pep8-naming pycodestyle pyflakes

# Remove .flake8 file
rm .flake8
# Or remove [flake8] section from setup.cfg/tox.ini
```

### Step 6: Validate

```bash
ruff check . --statistics
# Compare violation counts — should be similar to flake8 output
```

---

## From Black

### Config mapping

| Black setting | Ruff equivalent | Location |
|--------------|----------------|----------|
| `line-length` | `line-length` | `[tool.ruff]` |
| `target-version` | `target-version` | `[tool.ruff]` |
| `skip-string-normalization` | `quote-style = "preserve"` | `[tool.ruff.format]` |
| `skip-magic-trailing-comma` | `skip-magic-trailing-comma` | `[tool.ruff.format]` |
| `preview` | `preview = true` | `[tool.ruff.format]` |
| `extend-exclude` | `extend-exclude` | `[tool.ruff]` |
| `force-exclude` | `force-exclude` | `[tool.ruff]` |

### Migration steps

```bash
# 1. Note current Black config
grep -A 20 '\[tool.black\]' pyproject.toml

# 2. Add Ruff format config to pyproject.toml
# (see mapping above)

# 3. Verify identical output
black --check . 2>&1 | head -20
ruff format --check . 2>&1 | head -20

# 4. If diffs exist, check for Black preview features
# Ruff may format slightly differently for edge cases

# 5. Remove Black
pip uninstall black
# Remove [tool.black] from pyproject.toml
```

### target-version mapping

| Black | Ruff |
|-------|------|
| `["py38"]` | `"py38"` |
| `["py39"]` | `"py39"` |
| `["py310"]` | `"py310"` |
| `["py311"]` | `"py311"` |
| `["py312"]` | `"py312"` |
| `["py313"]` | `"py313"` |

Note: Black takes a list, Ruff takes a single string.

---

## From isort

### Config mapping

| isort setting | Ruff equivalent | Location |
|--------------|----------------|----------|
| `profile = "black"` | Default behavior | (not needed) |
| `known_first_party` | `known-first-party` | `[tool.ruff.lint.isort]` |
| `known_third_party` | `known-third-party` | `[tool.ruff.lint.isort]` |
| `known_local_folder` | `known-local-folder` | `[tool.ruff.lint.isort]` |
| `sections` | `section-order` | `[tool.ruff.lint.isort]` |
| `combine_as_imports` | `combine-as-imports` | `[tool.ruff.lint.isort]` |
| `force_single_line` | `force-single-line` | `[tool.ruff.lint.isort]` |
| `force_sort_within_sections` | `force-sort-within-sections` | `[tool.ruff.lint.isort]` |
| `lines_after_imports` | `lines-after-imports` | `[tool.ruff.lint.isort]` |
| `lines_between_types` | `lines-between-types` | `[tool.ruff.lint.isort]` |
| `forced_separate` | `forced-separate` | `[tool.ruff.lint.isort]` |
| `extra_standard_library` | `extra-standard-library` | `[tool.ruff.lint.isort]` |
| `split_on_trailing_comma` | `split-on-trailing-comma` | `[tool.ruff.lint.isort]` |
| `from_first` | `from-first` | `[tool.ruff.lint.isort]` |
| `length_sort` | `length-sort` | `[tool.ruff.lint.isort]` |
| `relative_imports_order` | `relative-imports-order` | `[tool.ruff.lint.isort]` |
| `no_lines_before` | `no-lines-before` | `[tool.ruff.lint.isort]` |

### Migration steps

```bash
# 1. Capture current isort config
grep -A 30 '\[tool.isort\]' pyproject.toml 2>/dev/null
grep -A 30 '\[isort\]' setup.cfg 2>/dev/null
cat .isort.cfg 2>/dev/null

# 2. Enable I rules in Ruff and map config (see table above)

# 3. Verify identical ordering
isort --check --diff . 2>&1 | head -40
ruff check --select I --diff . 2>&1 | head -40

# 4. Remove isort
pip uninstall isort
# Remove [tool.isort] from pyproject.toml or .isort.cfg
```

### Common isort profiles in Ruff

`profile = "black"` is Ruff's default — no config needed.

For `profile = "google"`:
```toml
[tool.ruff.lint.isort]
force-single-line = true
force-sort-within-sections = true
```

For `profile = "pycharm"`:
```toml
[tool.ruff.lint.isort]
force-sort-within-sections = true
```

---

## From Pylint

### Understanding coverage

Ruff implements ~30% of Pylint's rules under the PL prefix. For full Pylint parity, you may need to keep Pylint alongside Ruff for advanced rules.

### Rules with Ruff equivalents

| Pylint code | Pylint name | Ruff code | Ruff name |
|------------|------------|-----------|-----------|
| C0114 | missing-module-docstring | D100 | undocumented-public-module |
| C0115 | missing-class-docstring | D101 | undocumented-public-class |
| C0116 | missing-function-docstring | D102/D103 | undocumented-public-method/function |
| C0301 | line-too-long | E501 | line-too-long |
| C0303 | trailing-whitespace | W291 | trailing-whitespace |
| C0410 | multiple-imports | E401 | multiple-imports-on-one-line |
| C0411 | wrong-import-order | I001 | unsorted-imports |
| C0414 | useless-import-alias | PLC0414 | useless-import-alias |
| E0101 | return-in-init | PLE0101 | return-in-init |
| E0102 | function-redefined | F811 | redefined-unused-name |
| E0602 | undefined-variable | F821 | undefined-name |
| E1142 | await-outside-async | PLE1142 | await-outside-async |
| R0911 | too-many-return-statements | PLR0911 | too-many-return-statements |
| R0912 | too-many-branches | PLR0912 | too-many-branches |
| R0913 | too-many-arguments | PLR0913 | too-many-arguments |
| R0915 | too-many-statements | PLR0915 | too-many-statements |
| W0611 | unused-import | F401 | unused-import |
| W0612 | unused-variable | F841 | unused-variable |
| W0602 | global-variable-not-assigned | PLW0602 | global-variable-not-assigned |
| W2901 | redefined-loop-name | PLW2901 | redefined-loop-name |

### Pylint rules NOT in Ruff (keep Pylint for these)

- `R0801` (duplicate-code) — no equivalent
- `C0209` (consider-using-f-string) — partially covered by UP031/UP032
- `W0223` (abstract-method) — not implemented
- `R0401` (cyclic-import) — not implemented
- `W0640` (cell-var-from-loop) — not implemented
- `E1101` (no-member) — requires type inference
- Most `I` (informational) and `R` (refactor) rules

### Migration strategy

```toml
# Step 1: Enable PL rules in Ruff
[tool.ruff.lint]
select = ["E", "F", "W", "I", "PL"]

# Step 2: Keep Pylint running for rules Ruff doesn't cover
# Reduce Pylint config to only the rules Ruff doesn't handle
# In .pylintrc:
# disable=all
# enable=duplicate-code,cyclic-import,no-member,...
```

---

## From Bandit

### Config mapping

| Bandit setting | Ruff equivalent | Notes |
|---------------|----------------|-------|
| `tests` (include list) | `select = ["S"]` with specific codes | `S101`, `S102`, etc. |
| `skips` (exclude list) | `ignore = ["S..."]` | Same codes |
| `exclude_dirs` | `exclude` / per-file-ignores | |
| `severity` (LOW/MEDIUM/HIGH) | N/A | All severities enforced |
| `confidence` (LOW/MEDIUM/HIGH) | N/A | All confidence levels |

### Bandit rules in Ruff

Ruff implements most Bandit rules (S1xx–S7xx). Notable gaps:

| Bandit test | Status in Ruff |
|------------|---------------|
| B101 (assert_used) | ✅ S101 |
| B102 (exec_used) | ✅ S102 |
| B103 (set_bad_file_permissions) | ✅ S103 |
| B104 (hardcoded_bind_all_interfaces) | ✅ S104 |
| B105-B107 (hardcoded_password) | ✅ S105-S107 |
| B108 (hardcoded_tmp_directory) | ✅ S108 |
| B110 (try_except_pass) | ✅ S110 |
| B201 (flask_debug_true) | ✅ S201 |
| B301 (pickle) | ✅ S301 |
| B307 (eval) | ✅ S307 |
| B324 (hashlib_insecure) | ✅ S324 |
| B501 (request_with_no_cert_validation) | ✅ S501 |
| B601-B607 (shell/subprocess) | ✅ S601-S607 |
| B608 (hardcoded_sql) | ✅ S608 |
| B701 (jinja2_autoescape) | ✅ S701 |

### Migration steps

```bash
# 1. Note current bandit config
cat .bandit 2>/dev/null
cat bandit.yaml 2>/dev/null
grep -A 20 '\[bandit\]' setup.cfg 2>/dev/null

# 2. Add S rules to Ruff select
# Map bandit test IDs (B1xx) → Ruff codes (S1xx)

# 3. Validate
bandit -r src/ 2>&1 | tail -5
ruff check --select S src/ --statistics

# 4. Remove bandit
pip uninstall bandit
# Remove .bandit / bandit.yaml
```

---

## From pyupgrade

### Migration steps

pyupgrade is purely a code transformer (no config), so migration is straightforward:

```bash
# 1. Add UP rules to Ruff
# pyupgrade --py3X-plus maps to target-version = "py3X" in Ruff

# 2. Run Ruff with fixes
ruff check --select UP --fix .

# 3. Compare output
pyupgrade --py312-plus $(find . -name "*.py") 2>&1 | head -20
ruff check --select UP --diff . 2>&1 | head -20

# 4. Remove pyupgrade
pip uninstall pyupgrade
# Remove pyupgrade from pre-commit config
```

### Version flag mapping

| pyupgrade flag | Ruff config |
|---------------|-------------|
| `--py36-plus` | `target-version = "py36"` |
| `--py37-plus` | `target-version = "py37"` |
| `--py38-plus` | `target-version = "py38"` |
| `--py39-plus` | `target-version = "py39"` |
| `--py310-plus` | `target-version = "py310"` |
| `--py311-plus` | `target-version = "py311"` |
| `--py312-plus` | `target-version = "py312"` |
| `--py313-plus` | `target-version = "py313"` |

---

## From pydocstyle

### Config mapping

| pydocstyle setting | Ruff equivalent | Location |
|-------------------|----------------|----------|
| `convention` | `convention` | `[tool.ruff.lint.pydocstyle]` |
| `add-select` | `extend-select` | `[tool.ruff.lint]` |
| `add-ignore` | `extend-ignore` | `[tool.ruff.lint]` |
| `match = ".*\.py"` | default behavior | |
| `match-dir = "[^\.].*"` | `exclude` | `[tool.ruff]` |

### Convention presets

| pydocstyle | Ruff |
|-----------|------|
| `--convention=google` | `convention = "google"` |
| `--convention=numpy` | `convention = "numpy"` |
| `--convention=pep257` | `convention = "pep257"` |

### Migration steps

```bash
# 1. Note convention
grep -r "convention" setup.cfg tox.ini pyproject.toml .pydocstyle 2>/dev/null

# 2. Add D rules + convention to Ruff
# [tool.ruff.lint]
# select = [..., "D"]
# [tool.ruff.lint.pydocstyle]
# convention = "google"

# 3. Remove pydocstyle
pip uninstall pydocstyle
# Remove from pre-commit if present
```

---

## From autopep8 / yapf

### autopep8

`ruff format` + `ruff check --fix` covers all autopep8 transformations:

```bash
# 1. Replace autopep8 with ruff format + ruff check --fix
pip uninstall autopep8

# 2. Map settings
# autopep8 --max-line-length → [tool.ruff] line-length
# autopep8 --select → [tool.ruff.lint] select (E/W codes)
# autopep8 --aggressive → ruff check --fix --unsafe-fixes
```

### yapf

YAPF has unique formatting opinions. `ruff format` follows Black style. Migration may cause reformatting diffs:

```bash
# 1. Run ruff format on the codebase
ruff format .

# 2. Review and commit the formatting changes
git diff --stat

# 3. Remove yapf
pip uninstall yapf
# Remove .style.yapf or [yapf] from setup.cfg
```

---

## Combined Migration (All-in-One)

For projects using flake8 + black + isort + pyupgrade + bandit:

```bash
#!/bin/bash
set -e

echo "=== Step 1: Install Ruff ==="
pip install ruff

echo "=== Step 2: Generate initial Ruff config ==="
cat >> pyproject.toml << 'EOF'

[tool.ruff]
line-length = 88
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "W", "I", "UP", "B", "S", "N", "C4", "SIM", "RUF"]
ignore = ["E501"]

[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = ["S101", "ARG001", "D"]
"__init__.py" = ["F401"]

[tool.ruff.format]
quote-style = "double"
docstring-code-format = true
EOF

echo "=== Step 3: Run Ruff and fix ==="
ruff format .
ruff check --fix .

echo "=== Step 4: Remove legacy tools ==="
pip uninstall -y flake8 black isort pyupgrade bandit \
    flake8-bugbear flake8-comprehensions flake8-bandit \
    flake8-isort flake8-print pep8-naming 2>/dev/null || true

echo "=== Step 5: Clean up old config files ==="
rm -f .flake8 .isort.cfg .bandit
# Manually remove [tool.black], [tool.isort], [flake8] from config files

echo "=== Done! Review changes with: git diff ==="
```

---

## Config File Migration

### From setup.cfg / .flake8 / tox.ini to pyproject.toml

```ini
# setup.cfg (BEFORE)
[flake8]
max-line-length = 100
select = E,F,W,B,C4
ignore = E501,W503
per-file-ignores =
    tests/*.py:S101
exclude = build,dist

[isort]
profile = black
known_first_party = myapp

[tool:pytest]
testpaths = tests
```

```toml
# pyproject.toml (AFTER)
[tool.ruff]
line-length = 100
exclude = ["build", "dist"]

[tool.ruff.lint]
select = ["E", "F", "W", "B", "C4", "I"]
ignore = ["E501"]

[tool.ruff.lint.per-file-ignores]
"tests/*.py" = ["S101"]

[tool.ruff.lint.isort]
known-first-party = ["myapp"]

[tool.ruff.format]
quote-style = "double"
```

### Key differences in syntax

| Feature | flake8 (INI) | Ruff (TOML) |
|---------|-------------|-------------|
| Lists | comma-separated | TOML arrays `["a", "b"]` |
| Booleans | `true`/`false` | `true`/`false` |
| Strings | bare | quoted `"value"` |
| Per-file-ignores | `pattern:CODE` | `"pattern" = ["CODE"]` |
| Comments | `#` or `;` | `#` only |

---

## Pre-commit Migration

### Before (multiple tools)

```yaml
repos:
  - repo: https://github.com/pycqa/isort
    rev: 5.13.2
    hooks:
      - id: isort
  - repo: https://github.com/psf/black
    rev: 24.4.2
    hooks:
      - id: black
  - repo: https://github.com/pycqa/flake8
    rev: 7.0.0
    hooks:
      - id: flake8
        additional_dependencies:
          - flake8-bugbear
          - flake8-comprehensions
  - repo: https://github.com/asottile/pyupgrade
    rev: v3.15.0
    hooks:
      - id: pyupgrade
        args: [--py312-plus]
  - repo: https://github.com/PyCQA/bandit
    rev: 1.7.8
    hooks:
      - id: bandit
        args: ["-c", "bandit.yaml"]
```

### After (single tool)

```yaml
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.11.12
    hooks:
      - id: ruff
        args: ["--fix", "--exit-non-zero-on-fix"]
      - id: ruff-format
```

---

## CI/CD Migration

### Before (GitHub Actions with multiple tools)

```yaml
- run: black --check .
- run: isort --check .
- run: flake8 .
- run: bandit -r src/
```

### After

```yaml
- uses: astral-sh/ruff-action@v3
  with:
    args: "check"
- uses: astral-sh/ruff-action@v3
  with:
    args: "format --check"
```

---

## Handling Gaps

### Rules that Ruff doesn't implement

| Tool | Missing rules | Workaround |
|------|--------------|------------|
| Pylint | ~70% of rules (type inference, duplicate-code, cyclic-import) | Keep Pylint for these |
| Bandit | ~40% of rules (complex taint analysis) | Keep Bandit for high-security projects |
| mypy/pyright | Type checking | Ruff doesn't do type checking — keep mypy/pyright |
| flake8-cognitive-complexity | Cognitive complexity | Not yet in Ruff |
| flake8-sql | SQL linting | Not in Ruff |

### Running Ruff alongside legacy tools

```toml
# pyproject.toml — keep only what Ruff can't replace
[tool.pylint.messages_control]
disable = "all"
enable = "duplicate-code,cyclic-import"
```

```yaml
# CI: run both
- run: ruff check .
- run: ruff format --check .
- run: pylint --disable=all --enable=duplicate-code src/  # Only Pylint-exclusive rules
```

---

## Verification Checklist

After migration, verify:

- [ ] `ruff check .` exits clean (or only expected violations)
- [ ] `ruff format --check .` exits clean
- [ ] `ruff check --statistics .` shows expected rule counts
- [ ] CI pipeline passes with Ruff
- [ ] Pre-commit hooks run Ruff (not old tools)
- [ ] Old tool configs removed (`.flake8`, `.isort.cfg`, `[tool.black]`, `.bandit`)
- [ ] Old tools uninstalled from dev dependencies
- [ ] Old tool references removed from `Makefile`, `tox.ini`, scripts
- [ ] IDE settings updated to use Ruff extension
- [ ] Team documentation updated
- [ ] `git blame --ignore-revs-file` set up for the formatting commit

### Setting up git blame ignore

```bash
# After the big formatting commit:
echo "<formatting-commit-hash>" >> .git-blame-ignore-revs
git config blame.ignoreRevsFile .git-blame-ignore-revs
```
