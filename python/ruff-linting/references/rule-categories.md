# Ruff Rule Categories — Comprehensive Reference

> Dense, actionable guide to every major Ruff rule category with top rules, examples, and selection advice.

## Table of Contents

- [pycodestyle (E/W)](#pycodestyle-ew)
- [Pyflakes (F)](#pyflakes-f)
- [isort (I)](#isort-i)
- [pep8-naming (N)](#pep8-naming-n)
- [pyupgrade (UP)](#pyupgrade-up)
- [flake8-bandit (S)](#flake8-bandit-s)
- [flake8-bugbear (B)](#flake8-bugbear-b)
- [flake8-comprehensions (C4)](#flake8-comprehensions-c4)
- [pydocstyle (D)](#pydocstyle-d)
- [Perflint (PERF)](#perflint-perf)
- [refurb (FURB)](#refurb-furb)
- [Ruff-specific (RUF)](#ruff-specific-ruf)
- [Pylint (PL)](#pylint-pl)
- [flake8-simplify (SIM)](#flake8-simplify-sim)
- [flake8-pytest-style (PT)](#flake8-pytest-style-pt)
- [Other Notable Categories](#other-notable-categories)
- [Selection Strategy Matrix](#selection-strategy-matrix)

---

## pycodestyle (E/W)

**Origin:** PEP 8 style enforcement. E = errors, W = warnings.
**When to use:** Always. These are baseline Python style rules.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| E101 | indentation-contains-mixed-spaces-and-tabs | No | Mixed indent characters |
| E111 | indentation-is-not-multiple | No | Indent not multiple of 4 |
| E401 | multiple-imports-on-one-line | Yes | `import os, sys` |
| E402 | module-import-not-at-top-of-file | No | Imports after code |
| E501 | line-too-long | No | Lines exceeding `line-length` |
| E711 | none-comparison | Yes | `x == None` instead of `x is None` |
| E712 | true-false-comparison | Yes | `x == True` instead of `x is True` |
| E721 | type-comparison | Yes | `type(x) == int` instead of `isinstance` |
| E722 | bare-except | No | `except:` without exception type |
| E741 | ambiguous-variable-name | No | Variables named `l`, `O`, `I` |
| W291 | trailing-whitespace | Yes | Trailing spaces |
| W292 | no-newline-at-end-of-file | Yes | Missing final newline |
| W293 | whitespace-before-comment | Yes | Whitespace before inline `#` |

### Common ignore

```toml
ignore = ["E501"]  # Let ruff format handle line length
```

### Example

```python
# E711 — none-comparison
# BAD
if x == None:
    pass

# GOOD
if x is None:
    pass
```

---

## Pyflakes (F)

**Origin:** Fast static analysis for logical errors.
**When to use:** Always. Catches real bugs with near-zero false positives.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| F401 | unused-import | Yes | `import os` when os is never used |
| F402 | import-shadowed-by-loop-var | No | Loop variable shadows import |
| F403 | undefined-local-with-import-star | No | `from module import *` |
| F405 | undefined-local-with-import-star-usage | No | Using name from star import |
| F501 | percent-format-invalid-format-string | No | Bad `%` format string |
| F601 | multi-value-repeated-key-literal | No | `{"a": 1, "a": 2}` |
| F811 | redefined-unused-name | Yes | Redefining unused variable |
| F821 | undefined-name | No | Using undefined variable |
| F841 | unused-variable | Yes | `x = 1` when x is never read |
| F842 | unused-annotation | No | Annotated but never used |

### Per-file-ignores pattern

```toml
[tool.ruff.lint.per-file-ignores]
"__init__.py" = ["F401"]  # Re-exports are intentional
```

### Example

```python
# F841 — unused-variable
# BAD
def process():
    result = compute()  # result never used
    return True

# GOOD
def process():
    _ = compute()  # convention for intentionally unused
    return True
```

---

## isort (I)

**Origin:** Import sorting and grouping.
**When to use:** Always. Deterministic import ordering eliminates merge conflicts.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| I001 | unsorted-imports | Yes | Imports not in canonical order |
| I002 | missing-required-import | Yes | Required import missing (e.g., `from __future__`) |

### Configuration

```toml
[tool.ruff.lint.isort]
known-first-party = ["myapp", "mylib"]
known-third-party = ["fastapi", "sqlalchemy", "pydantic"]
combine-as-imports = true
force-single-line = false
force-sort-within-sections = true
lines-after-imports = 2
section-order = [
    "future", "standard-library", "third-party",
    "first-party", "local-folder"
]
# Add custom sections
extra-standard-library = ["_thread"]
```

### Section order (default)

1. `__future__` imports
2. Standard library (`os`, `sys`, `pathlib`)
3. Third-party (`requests`, `django`, `flask`)
4. First-party (your project)
5. Local-folder (relative imports)

### Example

```python
# BEFORE (I001)
import requests
import os
from myapp import utils
from pathlib import Path
import sys

# AFTER (fixed)
import os
import sys
from pathlib import Path

import requests

from myapp import utils
```

---

## pep8-naming (N)

**Origin:** PEP 8 naming conventions.
**When to use:** Recommended. Enforces consistent naming across the project.

### Top rules

| Code | Name | What it catches |
|------|------|-----------------|
| N801 | invalid-class-name | Class not CapWords (`class my_class`) |
| N802 | invalid-function-name | Function not lowercase_snake (`def MyFunc`) |
| N803 | invalid-argument-name | Argument not lowercase_snake |
| N804 | invalid-first-argument-name-for-class-method | First arg of classmethod not `cls` |
| N805 | invalid-first-argument-name-for-method | First arg of method not `self` |
| N806 | non-lowercase-variable-in-function | Variable in function not lowercase |
| N811 | constant-imported-as-non-constant | `from math import pi as PI` mismatch |
| N815 | mixed-case-variable-in-class-scope | `myVar` in class body |
| N816 | mixed-case-variable-in-global-scope | `myVar` at module level |
| N817 | camelcase-imported-as-acronym | `import MyModule as MM` |
| N818 | error-suffix-on-exception-name | Exception class not ending in `Error` |

### Common ignores

```toml
# For projects using Django/SQLAlchemy with inherited naming
ignore = ["N802", "N803"]  # Allow mixedCase from frameworks
```

---

## pyupgrade (UP)

**Origin:** Automatic Python version upgrade transformations.
**When to use:** Recommended. Free modernization. Pairs with `target-version`.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| UP001 | useless-metaclass-type | Yes | `__metaclass__ = type` |
| UP004 | useless-object-inheritance | Yes | `class Foo(object):` → `class Foo:` |
| UP006 | non-pep585-annotation | Yes | `typing.List` → `list` (3.9+) |
| UP007 | non-pep604-annotation | Yes | `Union[X, Y]` → `X \| Y` (3.10+) |
| UP008 | super-call-with-parameters | Yes | `super(Cls, self)` → `super()` |
| UP012 | unnecessary-encode-utf8 | Yes | `.encode("utf-8")` → `.encode()` |
| UP015 | redundant-open-modes | Yes | `open(f, "r")` → `open(f)` |
| UP031 | printf-string-formatting | Yes | `"%s" % x` → `f"{x}"` |
| UP032 | f-string | Yes | `"{}".format(x)` → `f"{x}"` |
| UP034 | extraneous-parentheses | Yes | `return (x)` → `return x` |
| UP035 | deprecated-import | Yes | `from typing import Dict` → `from collections.abc import ...` |
| UP036 | version-block | Yes | Dead `sys.version_info` branches |
| UP040 | non-pep695-type-alias | Yes | `TypeAlias` → `type` statement (3.12+) |

### target-version interaction

Rules are gated by `target-version`. Setting `py39` enables PEP 585 fixes but not PEP 604 (requires `py310`).

```toml
[tool.ruff]
target-version = "py310"  # Enables UP006 + UP007
```

### Example

```python
# BEFORE (target-version = "py312")
from typing import Dict, List, Optional, Union

def process(items: List[Dict[str, Any]], flag: Optional[bool] = None) -> Union[str, int]:
    return super(MyClass, self).process()

# AFTER
def process(items: list[dict[str, Any]], flag: bool | None = None) -> str | int:
    return super().process()
```

---

## flake8-bandit (S)

**Origin:** Security vulnerability detection.
**When to use:** Recommended for production code. Disable selectively in tests.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| S101 | assert-used | No | `assert` in production code (stripped by `-O`) |
| S102 | exec-used | No | `exec()` calls |
| S103 | bad-file-permissions | No | Overly permissive `os.chmod` |
| S104 | hardcoded-bind-all-interfaces | No | Binding to `0.0.0.0` |
| S105 | hardcoded-password-string | No | `password = "secret"` |
| S106 | hardcoded-password-func-arg | No | `connect(password="secret")` |
| S107 | hardcoded-password-default | No | `def login(pw="default")` |
| S110 | try-except-pass | No | `except: pass` silencing errors |
| S301 | suspicious-pickle-usage | No | `pickle.loads()` |
| S307 | suspicious-eval-usage | No | `eval()` calls |
| S311 | suspicious-non-cryptographic-random-usage | No | `random.random()` for security |
| S324 | hashlib-insecure-hash-function | No | `hashlib.md5()` / `sha1()` |
| S501 | request-without-timeout | No | `requests.get()` without timeout |
| S506 | unsafe-yaml-load | No | `yaml.load()` without SafeLoader |
| S608 | hardcoded-sql-expression | No | SQL string concatenation |
| S701 | jinja2-autoescape-false | No | Jinja2 without autoescaping |

### Per-file-ignores pattern

```toml
[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = ["S101"]  # assert is fine in tests
"scripts/**/*.py" = ["S311"]  # non-crypto random OK in scripts
```

---

## flake8-bugbear (B)

**Origin:** Catches likely bugs and design problems beyond PEP 8.
**When to use:** Highly recommended. High signal, low noise.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| B002 | unary-prefix-increment-decrement | No | `++x` (no-op in Python) |
| B003 | assignment-to-os-environ | No | `os.environ = {}` (doesn't affect env) |
| B004 | unreliable-callable-check | No | `hasattr(x, '__call__')` → `callable(x)` |
| B006 | mutable-argument-default | No | `def f(items=[])` |
| B007 | unused-loop-control-variable | Yes | `for x in range(10): pass` (x unused) |
| B008 | function-call-in-default-argument | No | `def f(now=datetime.now())` |
| B009 | get-attr-with-constant | Yes | `getattr(x, "name")` → `x.name` |
| B010 | set-attr-with-constant | Yes | `setattr(x, "name", v)` → `x.name = v` |
| B011 | do-not-assert-false | Yes | `assert False` → `raise AssertionError` |
| B015 | useless-comparison | No | Standalone `x == y` expression |
| B017 | assert-raises-exception | No | `assertRaises(Exception)` too broad |
| B018 | useless-expression | No | Standalone string/number expression |
| B024 | abstract-base-class-without-abstract-method | No | ABC with no `@abstractmethod` |
| B026 | star-arg-unpacking-after-keyword-arg | No | `f(**kw, *args)` |
| B028 | no-explicit-stacklevel | No | `warnings.warn()` without `stacklevel` |
| B904 | raise-without-from-inside-except | Yes | `raise X` in `except` without `from` |
| B905 | zip-without-explicit-strict | No | `zip()` without `strict=` parameter |

### Example

```python
# B006 — mutable-argument-default
# BAD
def add_item(item, items=[]):
    items.append(item)
    return items

# GOOD
def add_item(item, items=None):
    if items is None:
        items = []
    items.append(item)
    return items

# B904 — raise-without-from-inside-except
# BAD
try:
    parse(data)
except ValueError:
    raise ValidationError("bad data")

# GOOD
try:
    parse(data)
except ValueError as e:
    raise ValidationError("bad data") from e
```

---

## flake8-comprehensions (C4)

**Origin:** Simplify collection construction using comprehensions.
**When to use:** Recommended. Clean, idiomatic Python.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| C400 | unnecessary-generator-list | Yes | `list(x for x in it)` → `[x for x in it]` |
| C401 | unnecessary-generator-set | Yes | `set(x for x in it)` → `{x for x in it}` |
| C402 | unnecessary-generator-dict | Yes | `dict((k, v) for ...)` → `{k: v for ...}` |
| C403 | unnecessary-list-comprehension-set | Yes | `set([x for x in it])` → `{x for x in it}` |
| C404 | unnecessary-list-comprehension-dict | Yes | `dict([...])` → `{...}` |
| C405 | unnecessary-literal-set | Yes | `set([1, 2])` → `{1, 2}` |
| C408 | unnecessary-collection-call | Yes | `dict()` → `{}` |
| C409 | unnecessary-literal-within-tuple-call | Yes | `tuple([1, 2])` → `(1, 2)` |
| C410 | unnecessary-literal-within-list-call | Yes | `list([1, 2])` → `[1, 2]` |
| C411 | unnecessary-list-call | Yes | `list([x for x])` → `[x for x]` |
| C413 | unnecessary-call-around-sorted | Yes | `list(sorted(x))` is redundant |
| C416 | unnecessary-comprehension | Yes | `[x for x in it]` → `list(it)` |
| C417 | unnecessary-map | Yes | `map(lambda x: x+1, it)` → `[x+1 for x in it]` |
| C419 | unnecessary-comprehension-in-call | Yes | `any([x for x in it])` → `any(x for x in it)` |

### Example

```python
# BEFORE
data = dict([(k, v) for k, v in items.items() if v > 0])
names = list([name.strip() for name in raw_names])
unique = set([x for x in values])

# AFTER (with C4 fixes)
data = {k: v for k, v in items.items() if v > 0}
names = [name.strip() for name in raw_names]
unique = {x for x in values}
```

---

## pydocstyle (D)

**Origin:** Docstring convention enforcement (PEP 257 + style variants).
**When to use:** For libraries and public APIs. Noisy for internal code — use `per-file-ignores` generously.

### Convention presets

```toml
[tool.ruff.lint.pydocstyle]
convention = "google"   # Also: "numpy", "pep257"
```

Setting a convention auto-selects the relevant D rules and ignores conflicting ones.

### Top rules

| Code | Name | What it catches |
|------|------|-----------------|
| D100 | undocumented-public-module | Missing module docstring |
| D101 | undocumented-public-class | Missing class docstring |
| D102 | undocumented-public-method | Missing method docstring |
| D103 | undocumented-public-function | Missing function docstring |
| D104 | undocumented-public-package | Missing `__init__.py` docstring |
| D200 | fits-on-one-line | One-line docstring not on one line |
| D205 | blank-line-after-summary | No blank line after summary |
| D212 | multi-line-summary-first-line | Summary not on first line |
| D213 | multi-line-summary-second-line | Summary not on second line |
| D400 | ends-in-period | Docstring doesn't end in period |
| D401 | non-imperative-mood | First line not imperative mood |
| D415 | ends-in-punctuation | First line ends without punctuation |

### Important: D212 vs D213

These are **mutually exclusive**. Pick one:
- `D212`: Summary on same line as `"""` (Google style)
- `D213`: Summary on line after `"""` (NumPy style)

```toml
# Google style
ignore = ["D213"]
# NumPy style
ignore = ["D212"]
```

### Per-file-ignores pattern

```toml
[tool.ruff.lint.per-file-ignores]
"tests/**/*.py" = ["D"]          # No docstrings required in tests
"scripts/**/*.py" = ["D100"]     # No module docstrings in scripts
"**/migrations/**" = ["D"]       # Skip migrations
```

---

## Perflint (PERF)

**Origin:** Performance anti-patterns.
**When to use:** Recommended. Low noise, catches real performance issues.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| PERF101 | unnecessary-list-cast | Yes | `for x in list(dict_keys)` — iteration doesn't need `list()` |
| PERF102 | incorrect-dict-iterator | Yes | `for k, v in dict.items()` when only k used → `.keys()` |
| PERF203 | try-except-in-loop | No | `try/except` inside loop — move outside |
| PERF401 | manual-list-append | Yes | Manual loop with `.append()` → list comprehension |
| PERF402 | manual-list-copy | Yes | Loop to copy list → `list(x)` or `x.copy()` |
| PERF403 | manual-dict-comprehension | Yes | Manual loop building dict → dict comprehension |

### Example

```python
# PERF401 — manual-list-append
# BAD
result = []
for item in items:
    if item.is_valid():
        result.append(item.name)

# GOOD
result = [item.name for item in items if item.is_valid()]

# PERF102 — incorrect-dict-iterator
# BAD (only uses keys)
for k, v in config.items():
    print(k)

# GOOD
for k in config:
    print(k)
```

---

## refurb (FURB)

**Origin:** Pythonic code modernization (from the `refurb` tool).
**When to use:** Recommended for codebases targeting Python 3.10+. Many rules need preview mode.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| FURB101 | read-whole-file | Yes | `open(f).read()` → `Path(f).read_text()` |
| FURB103 | write-whole-file | Yes | `open(f, "w").write(d)` → `Path(f).write_text(d)` |
| FURB105 | print-empty-string | Yes | `print("")` → `print()` |
| FURB110 | if-exp-instead-of-or-operator | Yes | `x if x else y` → `x or y` |
| FURB113 | repeated-append | Yes | Multiple `.append()` → `.extend()` |
| FURB118 | reimplemented-operator | Yes | `lambda x, y: x + y` → `operator.add` |
| FURB129 | readlines-in-for | Yes | `for line in f.readlines()` → `for line in f` |
| FURB131 | delete-full-slice | Yes | `del x[:]` → `x.clear()` |
| FURB136 | if-expr-min-max | Yes | `x if x < y else y` → `min(x, y)` |
| FURB140 | reimplemented-starmap | Yes | `[f(a, b) for a, b in it]` → `starmap(f, it)` |
| FURB145 | slice-copy | Yes | `x[:]` → `x.copy()` |
| FURB148 | unnecessary-enumerate | Yes | `for i, _ in enumerate(x)` → `for i in range(len(x))` |
| FURB152 | math-constant | Yes | `3.14159` → `math.pi` |
| FURB154 | repeated-global | Yes | `global a; global b` → `global a, b` |
| FURB171 | single-item-membership-test | Yes | `x in [1]` → `x == 1` |

### Example

```python
# FURB101 — read-whole-file
# BAD
with open("config.json") as f:
    data = f.read()

# GOOD
from pathlib import Path
data = Path("config.json").read_text()
```

---

## Ruff-specific (RUF)

**Origin:** Rules unique to Ruff, not from any other linter.
**When to use:** Recommended. These fill gaps no other tool covers.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| RUF001 | ambiguous-unicode-character-string | Yes | Confusable Unicode in strings (Cyrillic о vs Latin o) |
| RUF002 | ambiguous-unicode-character-docstring | Yes | Same in docstrings |
| RUF003 | ambiguous-unicode-character-comment | Yes | Same in comments |
| RUF005 | collection-literal-concatenation | Yes | `[1] + [2]` → `[1, 2]` |
| RUF006 | asyncio-dangling-task | No | `asyncio.create_task()` without saving reference |
| RUF009 | function-call-in-dataclass-default-field | No | `field: list = func()` in dataclass |
| RUF010 | explicit-f-string-type-conversion | Yes | `f"{str(x)}"` → `f"{x!s}"` |
| RUF012 | mutable-class-default | No | `items: list = []` in class body |
| RUF013 | implicit-optional | Yes | `def f(x: str = None)` → `x: str \| None = None` |
| RUF015 | unnecessary-iterable-allocation-for-first-element | Yes | `list(x)[0]` → `next(iter(x))` |
| RUF017 | quadratic-list-summation | Yes | `sum(lists, [])` → `itertools.chain` |
| RUF018 | assignment-in-assert | No | `assert (x := 1)` |
| RUF019 | unnecessary-key-check | Yes | `k in d and d[k]` → `d.get(k)` |
| RUF020 | never-union | Yes | `Union[str, Never]` → `str` |
| RUF100 | unused-noqa | Yes | `# noqa` comment that suppresses nothing |
| RUF200 | invalid-pyproject-toml | No | Invalid `pyproject.toml` schema |

### Example

```python
# RUF013 — implicit-optional
# BAD
def greet(name: str = None):
    print(name or "World")

# GOOD
def greet(name: str | None = None):
    print(name or "World")

# RUF100 — unused-noqa
# BAD (if F401 isn't actually triggered)
import os  # noqa: F401  ← os IS used below

# GOOD
import os
```

---

## Pylint (PL)

**Origin:** Subset of Pylint rules reimplemented in Ruff.
**Subcategories:** PLC (convention), PLE (error), PLR (refactor), PLW (warning).
**When to use:** Selectively. Cherry-pick high-value rules rather than enabling all.

### Top rules

| Code | Name | What it catches |
|------|------|-----------------|
| PLC0414 | useless-import-alias | `import os as os` |
| PLE0101 | return-in-init | `return` value in `__init__` |
| PLE0302 | unexpected-special-method-signature | Wrong `__len__` signature |
| PLE1142 | await-outside-async | `await` in non-async function |
| PLR0911 | too-many-return-statements | Functions with >6 returns |
| PLR0912 | too-many-branches | Functions with >12 branches |
| PLR0913 | too-many-arguments | Functions with >5 parameters |
| PLR0915 | too-many-statements | Functions with >50 statements |
| PLR1714 | repeated-equality-comparison | `x == "a" or x == "b"` → `x in {"a", "b"}` |
| PLR2004 | magic-value-comparison | `if x == 42` without named constant |
| PLR5501 | collapsible-else-if | `else: if ...` → `elif` |
| PLW0120 | useless-else-on-loop | `else` on loop without `break` |
| PLW0602 | global-variable-not-assigned | `global x` but x never assigned |
| PLW2901 | redefined-loop-name | Reassigning loop variable inside loop |

### Configuration for PLR complexity

```toml
[tool.ruff.lint.pylint]
max-args = 6            # PLR0913 threshold (default 5)
max-returns = 8         # PLR0911 threshold (default 6)
max-branches = 15       # PLR0912 threshold (default 12)
max-statements = 60     # PLR0915 threshold (default 50)
max-bool-expr = 5       # Max boolean expressions in if
```

---

## flake8-simplify (SIM)

**Origin:** Code simplification suggestions.
**When to use:** Recommended. Improves readability.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| SIM102 | collapsible-if | Yes | Nested `if` → combined `if ... and` |
| SIM103 | needless-bool | Yes | `if cond: return True; else: return False` → `return cond` |
| SIM108 | if-else-block-instead-of-if-exp | Yes | Simple if/else → ternary |
| SIM110 | reimplemented-builtin | Yes | Loop with flag → `any()`/`all()` |
| SIM114 | if-with-same-arms | Yes | `if x: foo(); elif y: foo()` → `if x or y: foo()` |
| SIM115 | open-file-with-context-handler | No | `f = open()` without `with` |
| SIM117 | multiple-with-statements | Yes | Nested `with` → combined |
| SIM118 | in-dict-keys | Yes | `key in dict.keys()` → `key in dict` |
| SIM201 | negate-equal | Yes | `not x == y` → `x != y` |
| SIM210 | if-expr-with-true-false | Yes | `True if cond else False` → `bool(cond)` |
| SIM300 | yoda-condition | Yes | `"red" == color` → `color == "red"` |
| SIM401 | if-else-block-instead-of-dict-get | Yes | If/else for dict default → `.get()` |

---

## flake8-pytest-style (PT)

**Origin:** Pytest best practices.
**When to use:** In test files. Always pair with per-file-ignores.

### Top rules

| Code | Name | Fixable | What it catches |
|------|------|---------|-----------------|
| PT001 | pytest-fixture-incorrect-parentheses | Yes | `@pytest.fixture()` vs `@pytest.fixture` |
| PT003 | pytest-extraneous-scope-function | Yes | `scope="function"` (default, unnecessary) |
| PT004 | pytest-missing-fixture-name-underscore | No | Setup fixture without `_` prefix |
| PT006 | pytest-parametrize-names-wrong-type | Yes | Names as string vs tuple |
| PT009 | pytest-unittest-assertion | Yes | `self.assertEqual` → `assert ==` |
| PT011 | pytest-raises-too-broad | No | `pytest.raises(ValueError)` without `match=` |
| PT018 | pytest-composite-assertion | No | Multiple asserts in one test |
| PT023 | pytest-incorrect-mark-parentheses | Yes | `@pytest.mark.slow()` → `@pytest.mark.slow` |
| PT027 | pytest-unittest-raises-assertion | Yes | `assertRaises` → `pytest.raises` |

---

## Other Notable Categories

| Prefix | Name | Best for |
|--------|------|----------|
| `A` | flake8-builtins | Catching `list = [1,2]` shadowing builtins |
| `ANN` | flake8-annotations | Enforcing type annotations |
| `ARG` | flake8-unused-arguments | Finding unused function params |
| `DTZ` | flake8-datetimez | Timezone-aware datetime enforcement |
| `ERA` | eradicate | Removing commented-out code |
| `FBT` | flake8-boolean-trap | `def f(flag=True)` positional bool args |
| `ICN` | flake8-import-conventions | `import numpy as np` enforcement |
| `ISC` | flake8-implicit-str-concat | `"foo" "bar"` accidental concatenation |
| `PIE` | flake8-pie | Unnecessary `pass`, spread, dict wrappers |
| `RET` | flake8-return | Unnecessary return/else-after-return |
| `T20` | flake8-print | Catching `print()` in production code |
| `TCH` | flake8-type-checking | Moving imports to `TYPE_CHECKING` blocks |
| `TID` | flake8-tidy-imports | Banning imports, relative import rules |
| `NPY` | NumPy-specific | NumPy 2.0 deprecation warnings |
| `FA` | flake8-future-annotations | `from __future__ import annotations` |

---

## Selection Strategy Matrix

| Project Type | Recommended `select` | Key `ignore` |
|-------------|---------------------|--------------|
| **New library** | `["E","F","W","I","UP","B","N","S","C4","D","SIM","RUF"]` | `["D100","D104"]` |
| **New web app** | `["E","F","W","I","UP","B","N","S","A","C4","SIM","RUF","T20"]` | `["E501"]` |
| **Existing codebase** | Start with `["E","F","W","I"]`, add incrementally | Current violations |
| **Data science** | `["E","F","W","I","UP","B","NPY","RUF"]` | `["E501","T20"]` |
| **CLI tool** | `["E","F","W","I","UP","B","N","S","SIM","RUF"]` | `["T20"]` |
| **Strict / open-source** | `["ALL"]` | `["D100","D104","ANN101","COM812","ISC001"]` |

### Incremental adoption

```bash
# 1. See what you'd get with ALL rules
ruff check --select ALL --statistics . 2>&1 | sort -t: -k2 -rn | head -30

# 2. Enable category-by-category, fix violations, then commit
# 3. Add new categories to select once existing violations are cleared
```
