# Mypy & Pyright Troubleshooting Guide

Common errors, their causes, and fixes. Organized by error category.

## Table of Contents

1. [Incompatible Types](#incompatible-types)
2. [Missing Imports & Stubs](#missing-imports--stubs)
3. [Overload Errors](#overload-errors)
4. [Generic Variance Errors](#generic-variance-errors)
5. [Circular Imports](#circular-imports)
6. [Stub File Issues](#stub-file-issues)
7. [Plugin Configuration](#plugin-configuration)
8. [Union & Optional Pitfalls](#union--optional-pitfalls)
9. [Type Ignore Best Practices](#type-ignore-best-practices)
10. [Pyright-Specific Issues](#pyright-specific-issues)
11. [Migration Errors](#migration-errors)

---

## Incompatible Types

### `error: Incompatible types in assignment [assignment]`

```python
# Problem
x: int = "hello"  # [assignment]

# Fix: correct the type or the value
x: str = "hello"
# Or: x: int | str = "hello"
```

### `error: Incompatible return value type [return-value]`

```python
# Problem
def get_name() -> str:
    return 42  # [return-value]

# Fix: match return type to annotation
def get_name() -> str:
    return str(42)
```

### `error: Argument N has incompatible type [arg-type]`

```python
# Problem
def greet(name: str) -> None: ...
greet(42)  # [arg-type]

# Fix: pass correct type or widen parameter type
greet(str(42))
```

### Container Type Mismatch

```python
# Problem: list is invariant
def process(items: list[object]) -> None: ...
names: list[str] = ["a"]
process(names)  # ERROR: list[str] != list[object]

# Fix: use covariant Sequence for read-only access
from collections.abc import Sequence
def process(items: Sequence[object]) -> None: ...
process(names)  # OK
```

---

## Missing Imports & Stubs

### `error: Cannot find implementation or library stub [import]`

```python
# Problem: third-party library has no type stubs
import requests  # [import]

# Fix 1: Install stubs
# pip install types-requests

# Fix 2: Per-module ignore in config
# mypy.ini:
# [mypy-requests.*]
# ignore_missing_imports = True

# Fix 3: Create a minimal stub
# stubs/requests/__init__.pyi
def get(url: str, **kwargs: object) -> Response: ...
```

### `error: Library stubs not installed [import-untyped]`

```bash
# mypy suggests the stub package
pip install types-requests types-PyYAML types-setuptools

# Common stub packages:
# types-requests, types-PyYAML, types-setuptools, types-docutils
# types-Pillow, types-redis, types-boto3, types-six
# types-toml, types-python-dateutil, types-Markdown
```

### `error: Module has no attribute [attr-defined]`

```python
# Problem: stub doesn't include the attribute
from os.path import something_new  # [attr-defined]

# Fix 1: check if attribute exists (typo?)
# Fix 2: use cast or type: ignore with specific code
from typing import cast
result = cast(str, getattr(module, "dynamic_attr"))
```

---

## Overload Errors

### `error: Overloaded function signature N will never be matched [misc]`

```python
# Problem: overload ordering — more general before specific
@overload
def parse(x: object) -> str: ...    # Catches everything!
@overload
def parse(x: int) -> int: ...       # Never reached
def parse(x: object) -> str | int: ...

# Fix: order from specific to general
@overload
def parse(x: int) -> int: ...       # Specific first
@overload
def parse(x: object) -> str: ...    # General last
def parse(x: object) -> str | int: ...
```

### `error: Overloaded function implementation does not accept all possible arguments [misc]`

```python
# Problem: implementation signature too narrow
@overload
def fetch(url: str) -> bytes: ...
@overload
def fetch(url: str, decode: bool) -> str: ...
def fetch(url: str) -> bytes:  # Missing decode parameter!
    ...

# Fix: implementation must be superset of all overloads
def fetch(url: str, decode: bool = False) -> bytes | str:
    ...
```

### `error: Overload implementation return type inconsistent [misc]`

```python
# Fix: implementation return type must be union of all overload returns
@overload
def load(path: str, binary: Literal[True]) -> bytes: ...
@overload
def load(path: str, binary: Literal[False]) -> str: ...
def load(path: str, binary: bool = False) -> str | bytes:  # Union of returns
    ...
```

---

## Generic Variance Errors

### `error: Covariant type variable in mutable container [misc]`

```python
# Problem: using covariant TypeVar in a mutable position
T_co = TypeVar("T_co", covariant=True)

class Bad(Generic[T_co]):
    def add(self, item: T_co) -> None: ...  # ERROR: contravariant position

# Fix: use invariant TypeVar for mutable containers
T = TypeVar("T")

class Good(Generic[T]):
    def add(self, item: T) -> None: ...
    def get(self) -> T: ...
```

### `error: Cannot use covariant TypeVar as parameter [misc]`

```python
# Covariant TypeVars can only appear in return positions
# Contravariant TypeVars can only appear in parameter positions

# Fix: choose correct variance for your use case
T_co = TypeVar("T_co", covariant=True)

class Producer(Generic[T_co]):
    def get(self) -> T_co: ...          # OK: return position
    # def put(self, val: T_co): ...     # ERROR: parameter position
```

### `error: Incompatible types in assignment (invariance)`

```python
# Problem
class Animal: ...
class Dog(Animal): ...

dogs: list[Dog] = [Dog()]
animals: list[Animal] = dogs  # ERROR: list is invariant

# Fix options:
animals: Sequence[Animal] = dogs        # Sequence is covariant
animals_list: list[Animal] = list(dogs) # Explicit copy
```

---

## Circular Imports

### Pattern: `TYPE_CHECKING` Guard

```python
# file_a.py
from __future__ import annotations
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from file_b import ClassB  # Only imported during type checking

class ClassA:
    def method(self) -> ClassB: ...  # String annotation via __future__

# file_b.py
from __future__ import annotations
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from file_a import ClassA

class ClassB:
    def method(self) -> ClassA: ...
```

### Pattern: String Annotations (Without `__future__`)

```python
class ClassA:
    def method(self) -> "ClassB": ...  # Quoted forward reference
```

### Pattern: Move Types to Shared Module

```python
# types_.py (shared type definitions)
from __future__ import annotations
from typing import Protocol

class HasId(Protocol):
    id: int

# file_a.py and file_b.py both import from types_.py — no cycle
```

---

## Stub File Issues

### Stubs Out of Sync

```bash
# Validate stubs match implementation
python -m mypy.stubtest mypackage

# Regenerate stubs
stubgen -p mypackage -o stubs/
```

### `error: Incompatible types in assignment` in Stubs

```python
# Problem: enum stubs in mypy 1.14+
class Color(enum.Enum):
    RED: int  # ERROR in stubs

# Fix: use assignment syntax
class Color(enum.Enum):
    RED = 1      # In .py
    RED = ...    # In .pyi stub
```

### Stub Resolution Order

```
1. Inline types in .py files
2. .pyi stubs next to .py files
3. typeshed (bundled with mypy/pyright)
4. Third-party stub packages (types-*)
5. Custom stubs paths (mypy_path / stubPackages)
```

### PEP 561: Making Your Package Typed

```
mypackage/
├── __init__.py
├── py.typed          ← empty marker file
├── module.py         ← inline annotations
└── _internal.pyi     ← stubs for C extensions
```

---

## Plugin Configuration

### Pydantic Plugin (mypy)

```ini
# mypy.ini
[mypy]
plugins = pydantic.mypy

[pydantic-mypy]
init_forbid_extra = true
init_typed = true
warn_required_dynamic_aliases = true
```

### Django Plugin (mypy)

```ini
[mypy]
plugins = mypy_django_plugin.main

[mypy.plugins.django-stubs]
django_settings_module = myproject.settings
```

### SQLAlchemy Plugin (mypy)

```ini
[mypy]
plugins = sqlalchemy.ext.mypy.plugin
```

### Pyright Plugin Equivalents

Pyright handles Pydantic v2 and dataclasses natively. For Django:

```json
{
  "executionEnvironments": [
    { "root": "src", "extraPaths": ["stubs"] }
  ]
}
```

---

## Union & Optional Pitfalls

### `error: Item "None" of "X | None" has no attribute "y" [union-attr]`

```python
# Problem
def get_name(user: User | None) -> str:
    return user.name  # [union-attr] — user could be None

# Fix: narrow with guard
def get_name(user: User | None) -> str:
    if user is None:
        return "anonymous"
    return user.name  # OK — narrowed to User

# Fix 2: assert (when you know it's not None)
def get_name(user: User | None) -> str:
    assert user is not None
    return user.name
```

### `error: Unsupported operand types [operator]`

```python
# Problem
def double(x: int | str) -> int | str:
    return x * 2  # [operator] — str * int returns str, not int|str

# Fix: narrow first
def double(x: int | str) -> int | str:
    if isinstance(x, int):
        return x * 2
    return x * 2  # Now str path is clear
```

---

## Type Ignore Best Practices

```python
# ❌ Bad: blanket ignore hides real bugs
result = sketchy_call()  # type: ignore

# ✅ Good: specific error code
result = sketchy_call()  # type: ignore[no-untyped-call]

# ✅ Good: with explanation
result = sketchy_call()  # type: ignore[misc]  # Pending upstream fix #1234

# Enable unused-ignore detection
# mypy.ini: warn_unused_ignores = true
# pyright: reportUnnecessaryTypeIgnoreComment = true
```

### Common Error Codes for `type: ignore`

| Code | Meaning |
|---|---|
| `assignment` | Incompatible assignment |
| `arg-type` | Wrong argument type |
| `return-value` | Wrong return type |
| `union-attr` | Attribute not on all union members |
| `override` | Incompatible method override |
| `no-untyped-def` | Missing annotations |
| `no-untyped-call` | Calling untyped function |
| `misc` | Miscellaneous errors |
| `import` | Missing module/stub |
| `name-defined` | Undefined name |
| `index` | Invalid index operation |
| `operator` | Invalid operator for types |
| `type-arg` | Invalid type argument |
| `var-annotated` | Missing variable annotation |
| `call-overload` | No matching overload |

---

## Pyright-Specific Issues

### `reportMissingTypeStubs`

```json
// pyrightconfig.json — suppress for specific packages
{
  "reportMissingTypeStubs": true,
  "executionEnvironments": [
    {
      "root": "src",
      "reportMissingTypeStubs": false,
      "extraPaths": ["stubs"]
    }
  ]
}
```

### `reportGeneralTypeIssues` False Positives

```python
# Pyright is stricter than mypy on some patterns
# Use pyright-specific ignore:
result = dynamic_call()  # pyright: ignore[reportGeneralTypeIssues]
```

### Pyright vs Mypy Differences

| Behavior | mypy | pyright |
|---|---|---|
| TypeVar defaults | Partial support | Full support |
| Type narrowing | Good | More aggressive |
| Overload matching | Strict ordering | More flexible |
| Generics inference | Explicit needed | More implicit |
| Speed | Slower (Python) | Fast (TypeScript) |
| Config format | `.ini`, `pyproject.toml` | `pyrightconfig.json`, `pyproject.toml` |

---

## Migration Errors

### Gradual Typing: Ignoring Untyped Code

```ini
# mypy.ini — check only annotated functions initially
[mypy]
check_untyped_defs = false        # Don't check functions without annotations
disallow_untyped_defs = false     # Don't require annotations everywhere

# Tighten per-module as you add types
[mypy-mypackage.core.*]
disallow_untyped_defs = true
check_untyped_defs = true
```

### `error: Need type annotation for variable [var-annotated]`

```python
# Problem: mypy can't infer empty container type
items = []  # [var-annotated]

# Fix: annotate
items: list[str] = []
```

### `error: Function is missing a type annotation [no-untyped-def]`

```python
# Problem (in strict mode)
def helper(x):  # [no-untyped-def]
    return x + 1

# Fix
def helper(x: int) -> int:
    return x + 1
```
