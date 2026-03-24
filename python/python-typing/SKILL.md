---
name: python-typing
description: >
  Expert guidance for Python type hints, annotations, and static type checking.
  Covers typing module (TypeVar, Generic, Protocol, TypedDict, ParamSpec, Literal,
  overload), modern syntax (type statement 3.12+, TypeVarTuple 3.11+, Self 3.11+,
  TypeIs 3.13+, override 3.12+), mypy/pyright configuration, runtime checking
  (beartype, typeguard), Pydantic integration, stub files (.pyi), and
  typing_extensions backports. Triggers: "type hints", "mypy", "type annotations",
  "TypeVar", "Generic", "Protocol", "TypedDict", "pyright", "stub files",
  "typing module", "type narrowing", "ParamSpec". NOT for TypeScript types,
  NOT for Java/C# generics, NOT for runtime validation without types,
  NOT for schema validation unrelated to typing.
---

# Python Type Hints & Static Typing

## Skill Resources

### References
- [`references/advanced-patterns.md`](references/advanced-patterns.md) — Recursive types, covariance/contravariance, ParamSpec, Concatenate, TypeVarTuple, TypeGuard/TypeIs, NewType, intersection type workarounds, higher-kinded type emulation, advanced Protocol patterns
- [`references/troubleshooting.md`](references/troubleshooting.md) — Common mypy/pyright errors and fixes: incompatible types, missing stubs, overload resolution, generic variance, circular imports, stub issues, plugin config, type:ignore best practices
- [`references/api-reference.md`](references/api-reference.md) — Complete reference for typing module, typing_extensions backports, mypy CLI flags & config, pyright configuration, common type stub packages, runtime checking libraries

### Scripts
- [`scripts/setup-typing.sh`](scripts/setup-typing.sh) — Configure mypy/pyright in a project with recommended settings (`--mypy`, `--pyright`, `--both`, `--strict`)
- [`scripts/check-coverage.sh`](scripts/check-coverage.sh) — Report type annotation coverage via AST analysis, mypy reports, and pyright diagnostics
- [`scripts/migrate-types.sh`](scripts/migrate-types.sh) — Phased migration from untyped to fully typed using MonkeyType/pytype (phase1→phase4)

### Assets (Templates & Configs)
- [`assets/mypy.ini`](assets/mypy.ini) — Production-ready mypy configuration with strict settings and per-module overrides
- [`assets/pyrightconfig.json`](assets/pyrightconfig.json) — Pyright/Pylance configuration template with strict mode and execution environments
- [`assets/py.typed`](assets/py.typed) — PEP 561 marker file for typed packages (empty file, copy to package root)
- [`assets/conftest.py`](assets/conftest.py) — Pytest configuration with type checking fixtures and mypy integration helpers
- [`assets/typed-decorator.py`](assets/typed-decorator.py) — 7 decorator patterns using ParamSpec: simple, with args, Concatenate injection, async, sync/async universal, class-method-aware, chainable

You are an expert in Python's type system. Generate precise, idiomatic type annotations. Always prefer modern syntax for the target Python version. Use `typing_extensions` for backports when targeting older versions.

## Core Rules

- Use built-in generics (`list[int]`, `dict[str, Any]`) on Python 3.9+. Use `typing.List`, `typing.Dict` only for 3.8-.
- Use `X | Y` union syntax on Python 3.10+. Use `Union[X, Y]` for 3.9-.
- Use `X | None` on 3.10+. Use `Optional[X]` for 3.9-.
- Never use `Optional` for parameters with default values that aren't `None`.
- Annotate all public API signatures. Internal helpers benefit from annotations but are lower priority.
- Prefer `Sequence`, `Mapping`, `Iterable` over concrete `list`, `dict` for input parameters.
- Use concrete types (`list`, `dict`) for return types to preserve caller flexibility.
- Always run `mypy --strict` or `pyright --typeCheckingMode strict` in CI.

## Basic Annotations

```python
name: str = "alice"                          # Primitives: str, int, float, bool, bytes
names: list[str] = []                        # 3.9+ built-in generics
scores: dict[str, int] = {}                  # dict, set, tuple, frozenset
pair: tuple[str, int] = ("a", 1)             # Fixed-length tuple
varlen: tuple[int, ...] = (1, 2, 3)          # Variable-length tuple
value: int | None = None                     # 3.10+ union/optional syntax
result: str | int = "ok"                     # Pre-3.10: Union[str, int], Optional[int]
```

## Function Signatures

```python
def greet(name: str, excited: bool = False) -> str:
    return f"Hello, {name}{'!' if excited else '.'}"

def log(*messages: str, level: int = 0, **meta: str) -> None: ...

# Callable, Generator, Async
from collections.abc import Callable, Generator, AsyncGenerator
def apply(fn: Callable[[int, int], int], a: int, b: int) -> int:
    return fn(a, b)
def counter(n: int) -> Generator[int, None, None]:
    yield from range(n)
async def fetch(url: str) -> bytes: ...
async def stream() -> AsyncGenerator[str, None]: ...
```

## Generics with TypeVar

```python
from typing import TypeVar

T = TypeVar("T")

def first(items: list[T]) -> T:
    return items[0]

# Bounded TypeVar — restrict to types implementing a protocol/base
H = TypeVar("H", bound=Hashable)
def dedupe(items: list[H]) -> set[H]:
    return set(items)

# Constrained TypeVar — only specific types allowed
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
```

### Python 3.12+ Syntax (PEP 695)

```python
type Vector = list[float]                    # type statement replaces TypeAlias
type Matrix[T] = list[list[T]]              # Parameterized alias

def first[T](items: list[T]) -> T:          # Inline TypeVar
    return items[0]

class Stack[T]:                              # Inline TypeVar in class
    def __init__(self) -> None:
        self._items: list[T] = []
```

## ParamSpec & Concatenate (Decorator Typing)

```python
from typing import ParamSpec, TypeVar, Callable, Concatenate
from functools import wraps

P = ParamSpec("P")
R = TypeVar("R")

# Preserve signature through decorator
def logging_decorator(fn: Callable[P, R]) -> Callable[P, R]:
    @wraps(fn)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        print(f"Calling {fn.__name__}")
        return fn(*args, **kwargs)
    return wrapper

# Decorator that injects an argument
def with_session(
    fn: Callable[Concatenate[Session, P], R]
) -> Callable[P, R]:
    @wraps(fn)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        with create_session() as session:
            return fn(session, *args, **kwargs)
    return wrapper
```

## Protocol (Structural Subtyping)

```python
from typing import Protocol, runtime_checkable

class Closeable(Protocol):
    def close(self) -> None: ...

class Readable(Protocol):
    def read(self, n: int = -1) -> bytes: ...

class ReadableCloseable(Readable, Closeable, Protocol): ...  # Combine protocols

@runtime_checkable  # Enables isinstance() checks
class Sized(Protocol):
    def __len__(self) -> int: ...

def process(resource: Closeable) -> None:  # Any object with .close() works
    try: ...
    finally: resource.close()
```

## TypedDict

```python
from typing import TypedDict, NotRequired

class User(TypedDict):
    name: str                                # required (total=True default)
    email: str
    age: NotRequired[int]                    # optional key (3.11+)
    bio: NotRequired[str]

# Functional syntax for keys that aren't valid identifiers
Status = TypedDict("Status", {"status-code": int, "message": str})
```

## Literal & Overload

```python
from typing import Literal, overload

Mode = Literal["r", "w", "rb", "wb"]

def open_file(path: str, mode: Mode = "r") -> None: ...

# overload — declare distinct input→output type mappings
@overload
def parse(data: str) -> dict[str, str]: ...
@overload
def parse(data: bytes) -> dict[str, bytes]: ...
def parse(data: str | bytes) -> dict[str, str] | dict[str, bytes]:
    if isinstance(data, str):
        return {"key": data}
    return {b"key": data}  # type: ignore[dict-item]
```

## Type Narrowing: TypeGuard & TypeIs

```python
# TypeGuard (3.10+) — narrows type in True branch only
from typing import TypeGuard

def is_str_list(val: list[object]) -> TypeGuard[list[str]]:
    return all(isinstance(x, str) for x in val)

items: list[object] = ["a", "b"]
if is_str_list(items):
    # items is list[str] here
    print(items[0].upper())

# TypeIs (3.13+, or typing_extensions) — narrows BOTH branches
from typing import TypeIs

def is_int(val: int | str) -> TypeIs[int]:
    return isinstance(val, int)

def process(val: int | str) -> None:
    if is_int(val):
        print(val + 1)      # val: int
    else:
        print(val.upper())  # val: str  (narrowed in else too)
```

## Self Type (3.11+)

```python
from typing import Self

class Builder:
    def set_name(self, name: str) -> Self:   # Returns own type, works with subclasses
        self._name = name
        return self
    def clone(self) -> Self:
        return type(self)()
```

## TypeVarTuple (Variadic Generics, 3.11+)

```python
from typing import TypeVarTuple, Unpack, Generic
Ts = TypeVarTuple("Ts")

def head(first: int, *rest: Unpack[Ts]) -> tuple[Unpack[Ts]]:
    return rest

class Array(Generic[*Ts]):                   # Typed heterogeneous containers
    def __init__(self, *values: Unpack[Ts]) -> None:
        self.values = values
```

## override Decorator (3.12+)

```python
from typing import override

class Animal:
    def speak(self) -> str:
        return ""

class Dog(Animal):
    @override
    def speak(self) -> str:  # Type checker verifies parent has speak()
        return "woof"

    @override
    def spak(self) -> str:  # ERROR: typo caught by type checker
        return "woof"
```

## dataclass_transform

```python
from typing import dataclass_transform

@dataclass_transform()
class ModelBase:
    def __init_subclass__(cls, **kwargs: object) -> None: ...

# Type checkers treat subclasses as dataclasses
class User(ModelBase):
    name: str
    age: int
# user = User(name="alice", age=30)  ← type checker understands this
```

## Context Manager Typing

```python
from contextlib import contextmanager, asynccontextmanager
from collections.abc import Iterator, AsyncIterator

@contextmanager
def managed_resource(path: str) -> Iterator[Resource]:
    r = Resource(path)
    try: yield r
    finally: r.close()

@asynccontextmanager
async def async_db() -> AsyncIterator[Connection]:
    conn = await connect()
    try: yield conn
    finally: await conn.close()

# Class-based: implement __enter__(self) -> Self,
# __exit__(self, exc_type, exc_val, exc_tb) -> bool | None
```

## Callback Typing Patterns

```python
from collections.abc import Callable, Awaitable

# Simple callback
Handler = Callable[[Request], Response]

# Async callback
AsyncHandler = Callable[[Request], Awaitable[Response]]

# Callback protocol (when you need named parameters)
class OnError(Protocol):
    def __call__(self, error: Exception, *, retry: bool = False) -> None: ...

def register(callback: OnError) -> None: ...
```

## Stub Files (.pyi)

```python
# mymodule.pyi — type stubs for untyped or C-extension modules
def connect(host: str, port: int = 5432) -> Connection: ...
class Connection:
    def execute(self, query: str, params: tuple[Any, ...] = ()) -> Cursor: ...
    def close(self) -> None: ...
```

Generate: `stubgen -p mypackage`. Validate: `stubtest mypackage`. Place `.pyi` next to `.py` or in `stubs/`.

## typing_extensions Backports

```python
import sys
if sys.version_info >= (3, 12):
    from typing import override
else:
    from typing_extensions import override
# Key backports: Self(3.11), TypeGuard(3.10), TypeIs(3.13), ParamSpec(3.10),
# TypeVarTuple(3.11), override(3.12), NotRequired(3.11), dataclass_transform(3.12)
```

## mypy Configuration

```toml
# pyproject.toml
[tool.mypy]
python_version = "3.12"
strict = true
warn_return_any = true
warn_unused_configs = true
disallow_untyped_defs = true
disallow_any_generics = true
no_implicit_reexport = true
check_untyped_defs = true

# Per-module overrides
[[tool.mypy.overrides]]
module = "tests.*"
disallow_untyped_defs = false

[[tool.mypy.overrides]]
module = "third_party_lib.*"
ignore_missing_imports = true
```

Run: `mypy src/` or `mypy --strict src/`.

## Pyright Configuration

```json
// pyrightconfig.json
{
  "include": ["src"],
  "exclude": ["tests", "build"],
  "typeCheckingMode": "strict",
  "pythonVersion": "3.12",
  "reportMissingTypeStubs": true,
  "reportUnusedImport": true,
  "reportPrivateUsage": "warning"
}
```

Run: `pyright src/`. In VS Code, Pylance uses this config automatically.

## Runtime Type Checking

```python
# beartype — near-zero overhead, JIT checking
from beartype import beartype

@beartype
def add(a: int, b: int) -> int:
    return a + b

add(1, "2")  # raises BeartypeCallHintParamViolation

# typeguard — thorough checking, higher overhead
from typeguard import typechecked

@typechecked
def divide(a: float, b: float) -> float:
    return a / b
```

Use runtime checking at I/O boundaries and in tests. Avoid in hot loops.

## Pydantic Integration

```python
from pydantic import BaseModel, Field

class User(BaseModel):
    name: str
    age: int = Field(ge=0, le=150)
    email: str | None = None

# Pydantic uses type hints for validation + serialization
user = User(name="Alice", age=30)
user_dict = user.model_dump()

# Works with mypy plugin:
# pyproject.toml → [tool.mypy] plugins = ["pydantic.mypy"]
# Or pyright: Pydantic v2 natively supports pyright
```

## Common Anti-Patterns

```python
# ❌ Any to silence errors          → fix the real type
# ❌ Optional[str] = "default"      → str = "default" (not None-able)
# ❌ list[int] = [] as default      → use None, create inside function
# ❌ # type: ignore (broad)         → # type: ignore[assignment] (specific code)

# ✅ Correct mutable default
def good(items: list[int] | None = None) -> None:
    items = items if items is not None else []
```

## Quick Reference: Version Availability

| Feature | Stdlib | typing_extensions |
|---|---|---|
| `list[int]` built-in generics | 3.9+ | `__future__.annotations` 3.7+ |
| `X \| Y` union syntax | 3.10+ | `__future__.annotations` 3.7+ |
| `ParamSpec`, `Concatenate` | 3.10+ | 3.7+ |
| `TypeGuard` | 3.10+ | 3.7+ |
| `Self` | 3.11+ | 3.7+ |
| `TypeVarTuple`, `Unpack` | 3.11+ | 3.7+ |
| `Required`, `NotRequired` | 3.11+ | 3.7+ |
| `override` | 3.12+ | 3.7+ |
| `type` statement (PEP 695) | 3.12+ | N/A (syntax) |
| `TypeIs` | 3.13+ | 3.7+ |
| `dataclass_transform` | 3.12+ | 3.7+ |

<!-- tested: pass -->
