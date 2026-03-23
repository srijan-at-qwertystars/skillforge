---
name: python-type-hints
description: |
  Use when user adds type hints to Python code, configures mypy/pyright, asks about Protocol, TypeVar, ParamSpec, TypeGuard, Generic classes, overload, or advanced typing patterns.
  Do NOT use for basic Python syntax, runtime validation (use Pydantic/Zod), or TypeScript types.
---

# Python Type Hints & Static Type Checking

## Type Annotation Basics

Annotate variables, function arguments, and return types explicitly.

```python
# Variables
name: str = "alice"
count: int = 0
active: bool = True

# Functions — always annotate args and return type
def greet(name: str, excited: bool = False) -> str:
    return f"Hello, {name}{'!' if excited else '.'}"

# Use None return for side-effect functions
def log(msg: str) -> None:
    print(msg)
```

## Collections

Use lowercase built-in generics (Python 3.9+). For older code, import from `typing`.

```python
# Built-in generic syntax (3.9+)
names: list[str] = ["alice", "bob"]
scores: dict[str, int] = {"alice": 95}
unique: set[int] = {1, 2, 3}
point: tuple[float, float] = (1.0, 2.0)
vary: tuple[int, ...] = (1, 2, 3)

# Abstract collection types — prefer for function params
from collections.abc import Sequence, Mapping, Iterable, Iterator

def process(items: Sequence[str]) -> None: ...
def lookup(data: Mapping[str, int]) -> None: ...
def consume(stream: Iterable[bytes]) -> None: ...
def gen_ids() -> Iterator[int]: ...
```

Use `Sequence`/`Mapping`/`Iterable` for input parameters. Use concrete `list`/`dict` for return types.

## Optional and Union

```python
# Python 3.10+ union syntax
def find_user(user_id: int) -> User | None:
    ...

# Equivalent to Optional[User]
from typing import Optional
def find_user(user_id: int) -> Optional[User]:
    ...

# Multi-type union
def parse(value: str | int | float) -> str:
    return str(value)
```

Always narrow `X | None` before using:

```python
user = find_user(42)
if user is not None:       # type narrowed to User
    print(user.name)
```

## TypeVar and Generics

### Basic TypeVar

```python
from typing import TypeVar

T = TypeVar("T")

def first(items: list[T]) -> T:
    return items[0]
```

### Bound and Constrained TypeVars

```python
from typing import TypeVar

# Bound: T must be a subtype of Comparable
Comparable = TypeVar("Comparable", bound="SupportsLessThan")

# Constrained: T must be exactly str or bytes
StrOrBytes = TypeVar("StrOrBytes", str, bytes)
```

### Generic Classes

```python
from typing import TypeVar, Generic

T = TypeVar("T")

class Stack(Generic[T]):
    def __init__(self) -> None:
        self._items: list[T] = []

    def push(self, item: T) -> None:
        self._items.append(item)

    def pop(self) -> T:
        return self._items.pop()

stack: Stack[int] = Stack()
stack.push(1)
```

### Python 3.12+ Syntax (PEP 695)

```python
# New inline TypeVar — no separate declaration needed
def first[T](items: list[T]) -> T:
    return items[0]

class Stack[T]:
    def __init__(self) -> None:
        self._items: list[T] = []

    def push(self, item: T) -> None:
        self._items.append(item)

    def pop(self) -> T:
        return self._items.pop()

# Inline constraints
def concat[S: (str, bytes)](x: S, y: S) -> S:
    return x + y
```

### Covariance and Contravariance

```python
T_co = TypeVar("T_co", covariant=True)      # read-only containers
T_contra = TypeVar("T_contra", contravariant=True)  # write-only/consumers
```

Use `covariant=True` for producers (return `T`). Use `contravariant=True` for consumers (accept `T`).

## Protocol (Structural Subtyping)

Define interfaces without inheritance. Any class matching the structure satisfies the Protocol.

```python
from typing import Protocol, runtime_checkable

@runtime_checkable
class Serializable(Protocol):
    def serialize(self) -> bytes: ...

class User:
    def serialize(self) -> bytes:
        return b"user-data"

def save(obj: Serializable) -> None:
    data = obj.serialize()  # works — User matches structurally

# runtime_checkable enables isinstance checks
assert isinstance(User(), Serializable)
```

### Generic Protocol

```python
from typing import Protocol, TypeVar

T = TypeVar("T")

class Repository(Protocol[T]):
    def get(self, id: int) -> T: ...
    def save(self, entity: T) -> None: ...
```

## ParamSpec and Concatenate

Type decorators that preserve the wrapped function's signature.

```python
from typing import Callable, TypeVar, ParamSpec
from functools import wraps

P = ParamSpec("P")
R = TypeVar("R")

def log_calls(fn: Callable[P, R]) -> Callable[P, R]:
    @wraps(fn)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        print(f"Calling {fn.__name__}")
        return fn(*args, **kwargs)
    return wrapper

@log_calls
def add(a: int, b: int) -> int:
    return a + b
```

### Concatenate — add parameters to wrapped signature

```python
from typing import Callable, TypeVar, ParamSpec, Concatenate

P = ParamSpec("P")
R = TypeVar("R")

def with_db(
    fn: Callable[Concatenate[Database, P], R]
) -> Callable[P, R]:
    @wraps(fn)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        db = get_database()
        return fn(db, *args, **kwargs)
    return wrapper

@with_db
def get_user(db: Database, user_id: int) -> User:
    return db.query(User, user_id)

# Caller sees: get_user(user_id: int) -> User
```

## TypeGuard and TypeIs

### TypeGuard (Python 3.10+)

Narrow types in conditional branches. Only narrows in the `True` branch.

```python
from typing import TypeGuard

def is_list_of_str(val: list[object]) -> TypeGuard[list[str]]:
    return all(isinstance(x, str) for x in val)

def process(data: list[object]) -> None:
    if is_list_of_str(data):
        # data is list[str] here
        print(data[0].upper())
```

### TypeIs (Python 3.13+ / typing_extensions)

Stricter than TypeGuard — narrows in both branches and preserves type intersection.

```python
from typing import TypeIs

def is_str(val: str | int) -> TypeIs[str]:
    return isinstance(val, str)

def handle(val: str | int) -> None:
    if is_str(val):
        val.upper()    # str in true branch
    else:
        val + 1        # int in false branch (narrowed!)
```

Prefer `TypeIs` over `TypeGuard` when the check is a pure type narrowing.

## Literal, Final, TypedDict, NamedTuple

```python
from typing import Literal, Final, TypedDict, NamedTuple

# Literal — restrict to specific values
def set_mode(mode: Literal["read", "write", "append"]) -> None: ...

# Final — constant, cannot be reassigned
MAX_RETRIES: Final = 3

# TypedDict — typed dictionary with specific keys
class UserDict(TypedDict):
    name: str
    age: int
    email: str | None

class PartialUser(TypedDict, total=False):
    name: str

# NamedTuple
class Point(NamedTuple):
    x: float
    y: float
    label: str = ""
```

## Overload

Declare multiple signatures for functions whose return type depends on input types.

```python
from typing import overload

@overload
def parse(raw: str) -> dict[str, object]: ...
@overload
def parse(raw: bytes) -> list[object]: ...

def parse(raw: str | bytes) -> dict[str, object] | list[object]:
    if isinstance(raw, str):
        return {"data": raw}
    return [raw]
```

Do not use `@overload` when a simple union return suffices. Use it when the return type varies with input type.

## Type Aliases

```python
# Simple alias (works everywhere)
from typing import TypeAlias

UserId: TypeAlias = int
Headers: TypeAlias = dict[str, str]
Callback: TypeAlias = Callable[[int, str], bool]

# Python 3.12+ — type statement (preferred)
type UserId = int
type Headers = dict[str, str]
type Callback = Callable[[int, str], bool]
type JSON = str | int | float | bool | None | list["JSON"] | dict[str, "JSON"]
```

The `type` statement supports forward references and recursive types without quotes.

## mypy Configuration

```toml
[tool.mypy]
python_version = "3.12"
strict = true
warn_return_any = true
warn_unused_configs = true
warn_unused_ignores = true
warn_redundant_casts = true
disallow_any_generics = true
disallow_untyped_defs = true
no_implicit_reexport = true
namespace_packages = true
explicit_package_bases = true
mypy_path = "src"
files = ["src/"]
exclude = ["tests/fixtures/", "migrations/"]

# Plugins for frameworks
plugins = [
    "pydantic.mypy",
    "sqlalchemy.ext.mypy.plugin",
]
```

### Per-Module Overrides

```toml
[[tool.mypy.overrides]]
module = "third_party_lib.*"
ignore_missing_imports = true

[[tool.mypy.overrides]]
module = "legacy_module.*"
disallow_untyped_defs = false

[[tool.mypy.overrides]]
module = "tests.*"
disallow_untyped_defs = false
allow_untyped_decorators = true
```

### mypy.ini (alternative)

```ini
[mypy]
strict = True

[mypy-third_party_lib.*]
ignore_missing_imports = True
```

### Key strict-mode flags

`disallow_untyped_defs` — every function needs annotations. `disallow_any_generics` — no bare `list`, must use `list[X]`. `check_untyped_defs` — check bodies of untyped functions. `no_implicit_optional` — must write `X | None` explicitly. `warn_return_any` — flag functions returning `Any`. `strict_equality` — stricter equality comparisons.

## pyright / Pylance Configuration

### pyproject.toml

```toml
[tool.pyright]
pythonVersion = "3.12"
typeCheckingMode = "strict"     # off | basic | standard | strict | all
include = ["src"]
exclude = ["tests/fixtures", "**/__pycache__"]
reportMissingTypeStubs = "warning"
reportUnusedImport = "error"
reportUnnecessaryTypeIgnoreComment = "warning"
```

### pyright vs mypy

| Aspect | mypy | pyright |
|--------|------|---------|
| Speed | Moderate | 3-5x faster |
| Untyped code | Skips by default | Infers and checks always |
| Plugins | Yes (ORMs, Pydantic) | Limited |
| IDE integration | Basic | Excellent (VS Code/Pylance) |
| Config | `[tool.mypy]` | `[tool.pyright]` |

Run both in CI for maximum coverage.

## Gradual Typing Strategy

1. **Start with `strict = false`**. Enable `check_untyped_defs` and `warn_return_any` first.
2. **Annotate new code fully**. Enforce via CI on changed files.
3. **Annotate public APIs first** — function signatures in modules others import.
4. **Use per-module overrides** to relax rules for legacy code.
5. **Increase strictness incrementally**: enable one flag at a time, fix violations, repeat.
6. **Target `strict = true`** for new packages from day one.

```python
# Phase 1                          # Phase 2                        # Phase 3
[tool.mypy]                        [tool.mypy]                      [tool.mypy]
check_untyped_defs = true          disallow_untyped_defs = true     strict = true
```

## Common Patterns and Anti-Patterns

### Anti-patterns — avoid these

```python
# ❌ Bare Any everywhere — defeats the purpose
def process(data: Any) -> Any: ...

# ❌ Overusing cast — hides real type errors
x = cast(int, some_value)  # are you sure?

# ❌ Blanket type: ignore without error code
x = broken_call()  # type: ignore

# ❌ Bare dict/list without type params
def get_config() -> dict: ...
```

### Good patterns

```python
# ✅ Use specific ignore codes
x = broken_call()  # type: ignore[no-untyped-call]

# ✅ Narrow before using
def safe_len(val: str | None) -> int:
    if val is None:
        return 0
    return len(val)

# ✅ Use Protocol over ABC for duck typing
class HasName(Protocol):
    name: str

# ✅ Use TypeVar for type-preserving functions
T = TypeVar("T")
def ensure_list(val: T | list[T]) -> list[T]:
    return val if isinstance(val, list) else [val]

# ✅ Annotate constants with Final
MAX_RETRY: Final = 5

# ✅ Use Callable with ParamSpec for decorators, not Callable[..., Any]
# ✅ Return concrete types, accept abstract types
def filter_names(names: Iterable[str]) -> list[str]:
    return [n for n in names if n]
```

### When to use `cast`

```python
from typing import cast
# Only when you know the type but the checker cannot infer it
config = cast(dict[str, str], json.loads(payload))
```

### Suppressing errors

```python
x: int = some_call()  # type: ignore[assignment]      # mypy — use specific codes
x: int = some_call()  # pyright: ignore[reportAssignmentType]  # pyright
# Never use bare `type: ignore` — it hides real bugs
```

<!-- tested: pass -->
