# Python Typing API Reference

Complete reference for `typing`, `typing_extensions`, mypy CLI, pyright config, and common stubs.

## Table of Contents

1. [typing Module — Core Types](#typing-module--core-types)
2. [typing Module — Generics & TypeVar](#typing-module--generics--typevar)
3. [typing Module — Protocols & Structural](#typing-module--protocols--structural)
4. [typing Module — Advanced Constructs](#typing-module--advanced-constructs)
5. [typing_extensions Backports](#typing_extensions-backports)
6. [mypy CLI Reference](#mypy-cli-reference)
7. [mypy Configuration Options](#mypy-configuration-options)
8. [pyright Configuration](#pyright-configuration)
9. [Common Type Stub Packages](#common-type-stub-packages)
10. [Runtime Checking Libraries](#runtime-checking-libraries)

---

## typing Module — Core Types

### Primitive & Container Types (3.9+ built-in generics)

| Type | Example | Notes |
|---|---|---|
| `int, str, float, bool, bytes` | `x: int = 1` | Primitives |
| `list[T]` | `list[int]` | Mutable sequence |
| `dict[K, V]` | `dict[str, int]` | Mutable mapping |
| `set[T]` | `set[str]` | Mutable set |
| `frozenset[T]` | `frozenset[int]` | Immutable set |
| `tuple[T, ...]` | `tuple[int, ...]` | Variable-length |
| `tuple[T1, T2]` | `tuple[str, int]` | Fixed-length |
| `type[C]` | `type[Animal]` | Class itself |
| `None` | `-> None` | No return value |

### Union & Optional

| Syntax | Version | Example |
|---|---|---|
| `X \| Y` | 3.10+ | `int \| str` |
| `Union[X, Y]` | 3.7+ | `Union[int, str]` |
| `X \| None` | 3.10+ | `str \| None` |
| `Optional[X]` | 3.7+ | `Optional[str]` (= `str \| None`) |

### Special Types

| Type | Purpose | Example |
|---|---|---|
| `Any` | Disable type checking | `x: Any = ...` |
| `object` | Base of all types (safe) | Better than `Any` |
| `NoReturn` | Function never returns | `def fail() -> NoReturn: raise` |
| `Never` | Bottom type (3.11+) | Unreachable code |
| `Final[T]` | Cannot be reassigned | `MAX: Final = 100` |
| `ClassVar[T]` | Class-level variable | `count: ClassVar[int] = 0` |
| `Literal[v]` | Exact value type | `Literal["r", "w"]` |
| `LiteralString` | Any literal string (3.11+) | SQL injection prevention |
| `Annotated[T, meta]` | Attach metadata | `Annotated[int, Gt(0)]` |

---

## typing Module — Generics & TypeVar

### TypeVar

```python
T = TypeVar("T")                           # Unconstrained
T = TypeVar("T", bound=Hashable)           # Upper bound
T = TypeVar("T", str, bytes)               # Constrained to specific types
T = TypeVar("T", covariant=True)           # Covariant
T = TypeVar("T", contravariant=True)       # Contravariant
T = TypeVar("T", default=int)              # Default (3.13+)
```

### 3.12+ TypeVar Syntax (PEP 695)

```python
def first[T](items: list[T]) -> T: ...              # Inline TypeVar
def clamp[T: (int, float)](val: T) -> T: ...         # Constrained
class Stack[T]: ...                                   # Generic class
type Alias[T] = list[T]                               # Generic alias
```

### ParamSpec & Concatenate

```python
P = ParamSpec("P")                    # Captures full signature
P.args                                # *args type
P.kwargs                              # **kwargs type
Callable[P, R]                        # Function with signature P returning R
Callable[Concatenate[int, P], R]      # Prepend int to P's params
```

### TypeVarTuple

```python
Ts = TypeVarTuple("Ts")              # Variadic type variable
tuple[*Ts]                            # Unpacked in tuple
tuple[int, *Ts, str]                  # Prefix/suffix with fixed types
Unpack[Ts]                            # Explicit unpack (3.11 compat)
```

---

## typing Module — Protocols & Structural

### Protocol

```python
class Proto(Protocol):                # Structural subtype
    attr: int                         # Required attribute
    def method(self) -> str: ...      # Required method

@runtime_checkable                    # Enables isinstance()
class Sized(Protocol):
    def __len__(self) -> int: ...

class Combined(ProtoA, ProtoB, Protocol): ...  # Combine protocols
```

### TypedDict

```python
class Config(TypedDict):             # All keys required by default
    host: str
    port: int

class Config(TypedDict, total=False): # All keys optional
    host: str
    port: int

class Config(TypedDict):             # Mixed (3.11+)
    host: str                         # Required
    port: NotRequired[int]            # Optional key
    debug: NotRequired[bool]

# ReadOnly keys (3.13+)
class Config(TypedDict):
    host: ReadOnly[str]               # Cannot be modified
```

### NamedTuple

```python
class Point(NamedTuple):
    x: float
    y: float
    z: float = 0.0                    # Default value
```

---

## typing Module — Advanced Constructs

| Construct | Version | Purpose |
|---|---|---|
| `Self` | 3.11+ | Return type for method chaining / subclass-safe |
| `TypeGuard[T]` | 3.10+ | Narrow type in `if` branch |
| `TypeIs[T]` | 3.13+ | Narrow type in both branches |
| `override` | 3.12+ | Mark method overrides (checked by type checker) |
| `dataclass_transform()` | 3.12+ | Tell checkers a decorator/class acts like dataclass |
| `NewType("Name", Base)` | 3.7+ | Nominal subtype for static checking |
| `cast(T, expr)` | 3.7+ | Assert expression is type T (no runtime effect) |
| `assert_type(expr, T)` | 3.11+ | Assert type checker sees expr as T |
| `reveal_type(expr)` | 3.11+ | Print inferred type (debug) |
| `assert_never(x)` | 3.11+ | Exhaustiveness check in match/if chains |
| `get_type_hints(obj)` | 3.7+ | Get resolved type hints at runtime |
| `TYPE_CHECKING` | 3.5+ | `True` only during static analysis |
| `@no_type_check` | 3.5+ | Disable type checking for function/class |

### collections.abc Types (Preferred for Parameters)

| Abstract Type | Use For | Methods Required |
|---|---|---|
| `Iterable[T]` | Any iterable | `__iter__` |
| `Iterator[T]` | Iterator | `__iter__`, `__next__` |
| `Sequence[T]` | Indexed + sized | `__getitem__`, `__len__` |
| `MutableSequence[T]` | Mutable indexed | + `__setitem__`, `__delitem__`, `insert` |
| `Mapping[K, V]` | Read-only dict-like | `__getitem__`, `__iter__`, `__len__` |
| `MutableMapping[K, V]` | Mutable dict-like | + `__setitem__`, `__delitem__` |
| `Set[T]` | Read-only set | `__contains__`, `__iter__`, `__len__` |
| `Callable[[Args], Ret]` | Any callable | `__call__` |
| `Generator[Y, S, R]` | Generator function | Yield, Send, Return types |
| `AsyncGenerator[Y, S]` | Async generator | Async yield, send |
| `Awaitable[T]` | Awaitable object | `__await__` |
| `Coroutine[Y, S, R]` | Coroutine | Yield, send, return |
| `AsyncIterable[T]` | Async iterable | `__aiter__` |
| `Buffer` | Buffer protocol (3.12+) | `__buffer__` |

---

## typing_extensions Backports

Install: `pip install typing-extensions`

### Import Pattern

```python
import sys
if sys.version_info >= (3, 13):
    from typing import TypeIs
else:
    from typing_extensions import TypeIs
```

### Key Backports by Feature

| Feature | Stdlib Version | typing_extensions |
|---|---|---|
| `Annotated` | 3.9 | 3.7+ |
| `ParamSpec` | 3.10 | 3.7+ |
| `TypeGuard` | 3.10 | 3.7+ |
| `Self` | 3.11 | 3.7+ |
| `TypeVarTuple`, `Unpack` | 3.11 | 3.7+ |
| `NotRequired`, `Required` | 3.11 | 3.7+ |
| `Never` | 3.11 | 3.7+ |
| `assert_never` | 3.11 | 3.7+ |
| `override` | 3.12 | 3.7+ |
| `dataclass_transform` | 3.12 | 3.7+ |
| `TypeIs` | 3.13 | 3.7+ |
| `ReadOnly` (TypedDict) | 3.13 | 3.7+ |
| `TypeVar(default=)` | 3.13 | 3.7+ |

---

## mypy CLI Reference

### Basic Usage

```bash
mypy file.py                    # Check single file
mypy src/                       # Check directory recursively
mypy -m mypackage               # Check module
mypy -p mypackage               # Check package (recursive)
mypy -c "x: int = 'a'"         # Check inline code
```

### Key Flags

| Flag | Purpose |
|---|---|
| `--strict` | Enable all strict checks |
| `--python-version 3.12` | Target Python version |
| `--ignore-missing-imports` | Skip missing stubs (use sparingly) |
| `--disallow-untyped-defs` | Require annotations on all functions |
| `--check-untyped-defs` | Check bodies of unannotated functions |
| `--no-implicit-optional` | Don't treat `= None` as Optional |
| `--warn-return-any` | Warn when returning Any |
| `--warn-unused-ignores` | Flag unused `type: ignore` |
| `--warn-redundant-casts` | Flag unnecessary casts |
| `--no-implicit-reexport` | Don't re-export imported names |
| `--disallow-any-generics` | Disallow bare `list`, `dict` |
| `--show-error-codes` | Show `[code]` in errors |
| `--pretty` | Colorize output |

### Report Flags

| Flag | Purpose |
|---|---|
| `--html-report DIR` | HTML coverage report |
| `--txt-report DIR` | Text coverage report |
| `--linecount-report DIR` | Line count statistics |
| `--any-exprs-report DIR` | Report `Any` expression usage |
| `--lineprecision-report DIR` | Per-line precision stats |

### Incremental & Performance

| Flag | Purpose |
|---|---|
| `--incremental` | Use cache (default: on) |
| `--cache-dir DIR` | Set cache location |
| `--no-incremental` | Disable cache |
| `--sqlite-cache` | Use SQLite for cache |
| `-j N` / `--jobs N` | Parallel workers |

---

## mypy Configuration Options

### pyproject.toml

```toml
[tool.mypy]
python_version = "3.12"
strict = true
warn_return_any = true
warn_unused_configs = true
disallow_untyped_defs = true
disallow_any_generics = true
no_implicit_reexport = true
check_untyped_defs = true
warn_unused_ignores = true
warn_redundant_casts = true
show_error_codes = true
enable_error_code = ["ignore-without-code", "redundant-expr", "truthy-bool"]
mypy_path = "stubs"
plugins = ["pydantic.mypy"]

[[tool.mypy.overrides]]
module = "tests.*"
disallow_untyped_defs = false

[[tool.mypy.overrides]]
module = ["third_party.*", "legacy.*"]
ignore_missing_imports = true
```

### mypy.ini

```ini
[mypy]
python_version = 3.12
strict = True
show_error_codes = True
mypy_path = stubs
plugins = pydantic.mypy

[mypy-tests.*]
disallow_untyped_defs = False

[mypy-third_party.*]
ignore_missing_imports = True
```

---

## pyright Configuration

### pyrightconfig.json

```json
{
  "include": ["src"],
  "exclude": ["**/node_modules", "**/__pycache__", "build", "dist"],
  "ignore": ["src/legacy"],
  "typeshedPath": "",
  "stubPath": "stubs",
  "venvPath": ".",
  "venv": ".venv",
  "pythonVersion": "3.12",
  "pythonPlatform": "Linux",
  "typeCheckingMode": "strict",
  "reportMissingImports": true,
  "reportMissingTypeStubs": true,
  "reportUnusedImport": "warning",
  "reportUnusedVariable": "warning",
  "reportUnusedClass": "warning",
  "reportPrivateUsage": "warning",
  "reportConstantRedefinition": "error",
  "reportIncompatibleMethodOverride": "error",
  "reportMissingTypeArgument": "warning",
  "reportUnnecessaryTypeIgnoreComment": true,
  "reportUnnecessaryCast": true,
  "reportUnnecessaryIsInstance": true,
  "reportDeprecated": "warning"
}
```

### pyproject.toml (pyright)

```toml
[tool.pyright]
include = ["src"]
exclude = ["build"]
typeCheckingMode = "strict"
pythonVersion = "3.12"
reportMissingTypeStubs = true
reportUnusedImport = "warning"
```

### Type Checking Modes

| Mode | Strictness | Use Case |
|---|---|---|
| `off` | None | Disable checking |
| `basic` | Low | New projects, gradual adoption |
| `standard` | Medium | Default for most projects |
| `strict` | High | Production libraries, mature codebases |

---

## Common Type Stub Packages

### Most Used

| Package | Stub Package | Install |
|---|---|---|
| requests | types-requests | `pip install types-requests` |
| PyYAML | types-PyYAML | `pip install types-PyYAML` |
| setuptools | types-setuptools | `pip install types-setuptools` |
| redis | types-redis | `pip install types-redis` |
| boto3 | boto3-stubs | `pip install boto3-stubs` |
| Pillow | types-Pillow | `pip install types-Pillow` |
| python-dateutil | types-python-dateutil | `pip install types-python-dateutil` |
| docutils | types-docutils | `pip install types-docutils` |
| six | types-six | `pip install types-six` |
| toml | types-toml | `pip install types-toml` |
| Markdown | types-Markdown | `pip install types-Markdown` |
| beautifulsoup4 | types-beautifulsoup4 | `pip install types-beautifulsoup4` |
| protobuf | types-protobuf | `pip install types-protobuf` |
| ujson | types-ujson | `pip install types-ujson` |
| Jinja2 | Bundled (3.1+) | (ships with inline types) |
| SQLAlchemy | Bundled (2.0+) | (ships with inline types) |
| Pydantic | Bundled (v2+) | (ships with inline types) |

### Discovering Stubs

```bash
# Search for stubs on PyPI
pip search types-PACKAGENAME      # (if search is available)

# mypy suggests stubs automatically
mypy src/  # "note: install types-requests for requests"

# List all installed stub packages
pip list | grep types-
```

---

## Runtime Checking Libraries

### beartype (Near-Zero Overhead)

```bash
pip install beartype
```

```python
from beartype import beartype

@beartype
def process(items: list[int], factor: float = 1.0) -> list[float]:
    return [x * factor for x in items]
```

### typeguard (Thorough Checking)

```bash
pip install typeguard
```

```python
from typeguard import typechecked

@typechecked
def divide(a: float, b: float) -> float:
    return a / b

# Pytest integration
# pytest --typeguard-packages=mypackage
```

### Comparison

| Feature | beartype | typeguard |
|---|---|---|
| Overhead | Near-zero (JIT) | Higher (thorough) |
| Depth | Shallow by default | Deep (nested containers) |
| Pytest plugin | Yes | Yes |
| Best for | Production code | Tests, I/O boundaries |
