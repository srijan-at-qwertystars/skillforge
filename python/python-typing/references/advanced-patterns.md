# Advanced Python Typing Patterns

Dense reference for advanced type system patterns. Python 3.10+ unless noted.

## Table of Contents

1. [Recursive & Self-Referential Types](#recursive--self-referential-types)
2. [Covariance & Contravariance](#covariance--contravariance)
3. [ParamSpec for Decorator Typing](#paramspec-for-decorator-typing)
4. [Concatenate — Injecting Parameters](#concatenate--injecting-parameters)
5. [TypeVarTuple — Variadic Generics](#typevartuple--variadic-generics)
6. [Type Narrowing: TypeGuard & TypeIs](#type-narrowing-typeguard--typeis)
7. [Nominal Typing with NewType](#nominal-typing-with-newtype)
8. [Intersection Types Workarounds](#intersection-types-workarounds)
9. [Higher-Kinded Types Workarounds](#higher-kinded-types-workarounds)
10. [Advanced Protocol Patterns](#advanced-protocol-patterns)
11. [Overload Strategies](#overload-strategies)
12. [Type-Level Computation Patterns](#type-level-computation-patterns)

---

## Recursive & Self-Referential Types

### JSON Type (Classic Recursive)

```python
# Python 3.12+ (PEP 695)
type JSON = str | int | float | bool | None | list["JSON"] | dict[str, "JSON"]

# Python 3.10-3.11
from typing import TypeAlias
JSON: TypeAlias = str | int | float | bool | None | list["JSON"] | dict[str, "JSON"]
```

### Tree Structures

```python
from __future__ import annotations
from dataclasses import dataclass

@dataclass
class TreeNode[T]:              # 3.12+ syntax
    value: T
    children: list[TreeNode[T]]

# Pre-3.12
from typing import TypeVar, Generic
T = TypeVar("T")

@dataclass
class TreeNode(Generic[T]):
    value: T
    children: list[TreeNode[T]]  # Forward ref resolved by __future__
```

### Linked List

```python
from __future__ import annotations
from dataclasses import dataclass

@dataclass
class Node[T]:
    value: T
    next: Node[T] | None = None
```

### Mutually Recursive Types

```python
from __future__ import annotations

class Expression:
    terms: list[Term]

class Term:
    factors: list[Expression | Literal]

class Literal:
    value: int
```

---

## Covariance & Contravariance

**Rule of thumb:** Producers are covariant, consumers are contravariant, both → invariant.

```python
from typing import TypeVar, Generic

T_co = TypeVar("T_co", covariant=True)       # Read-only container
T_contra = TypeVar("T_contra", contravariant=True)  # Write-only/consumer

# Covariant: ImmutableList[Dog] IS-A ImmutableList[Animal]
class ImmutableList(Generic[T_co]):
    def __init__(self, items: tuple[T_co, ...]) -> None:
        self._items = items
    def __getitem__(self, index: int) -> T_co:
        return self._items[index]
    # No setter — read-only makes covariance safe

# Contravariant: Callback[Animal] IS-A Callback[Dog]
class Handler(Generic[T_contra]):
    def handle(self, item: T_contra) -> None: ...

# Invariant (default): MutableList[Dog] is NOT related to MutableList[Animal]
class MutableList(Generic[T]):  # plain TypeVar = invariant
    def append(self, item: T) -> None: ...
    def __getitem__(self, index: int) -> T: ...
```

### When to Use Each

| Variance | TypeVar flag | Use when class... | Safe operations |
|---|---|---|---|
| Covariant | `covariant=True` | Only produces/returns T | `__getitem__`, properties |
| Contravariant | `contravariant=True` | Only consumes/accepts T | Method parameters |
| Invariant | (default) | Both produces and consumes T | All operations |

### Practical: Sequence vs List

```python
from collections.abc import Sequence

def process(items: Sequence[Animal]) -> None:  # Sequence is covariant
    for item in items:
        item.speak()

dogs: list[Dog] = [Dog()]
process(dogs)  # OK — Sequence[Dog] assignable to Sequence[Animal]

def append_to(items: list[Animal]) -> None:  # list is invariant
    items.append(Cat())

append_to(dogs)  # ERROR — list[Dog] != list[Animal] (rightfully so!)
```

---

## ParamSpec for Decorator Typing

### Basic Signature-Preserving Decorator

```python
from typing import ParamSpec, TypeVar, Callable
from functools import wraps

P = ParamSpec("P")
R = TypeVar("R")

def retry(max_attempts: int = 3) -> Callable[[Callable[P, R]], Callable[P, R]]:
    def decorator(fn: Callable[P, R]) -> Callable[P, R]:
        @wraps(fn)
        def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            for attempt in range(max_attempts):
                try:
                    return fn(*args, **kwargs)
                except Exception:
                    if attempt == max_attempts - 1:
                        raise
            raise RuntimeError("unreachable")
        return wrapper
    return decorator

@retry(max_attempts=5)
def fetch(url: str, timeout: int = 30) -> bytes: ...
# Type checker knows: fetch(url: str, timeout: int = 30) -> bytes
```

### Async Decorator

```python
from typing import ParamSpec, TypeVar, Callable, Awaitable
import asyncio

P = ParamSpec("P")
R = TypeVar("R")

def async_retry(
    fn: Callable[P, Awaitable[R]]
) -> Callable[P, Awaitable[R]]:
    @wraps(fn)
    async def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        return await fn(*args, **kwargs)
    return wrapper
```

---

## Concatenate — Injecting Parameters

```python
from typing import ParamSpec, TypeVar, Callable, Concatenate

P = ParamSpec("P")
R = TypeVar("R")

# Decorator that prepends a `db: Database` argument
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

# Caller sees: get_user(user_id: int) -> User (db is injected)
```

### Multiple Injected Parameters

```python
def with_context(
    fn: Callable[Concatenate[Request, Session, P], R]
) -> Callable[P, R]:
    @wraps(fn)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        req, session = get_request(), get_session()
        return fn(req, session, *args, **kwargs)
    return wrapper
```

---

## TypeVarTuple — Variadic Generics

Available 3.11+ (or `typing_extensions`).

```python
from typing import TypeVarTuple, Unpack

Ts = TypeVarTuple("Ts")

# Function accepting variable type args
def zip_strict(*iterables: Unpack[Ts]) -> ...: ...

# Typed tuple operations
def head_tail(
    first: int, *rest: Unpack[Ts]
) -> tuple[Unpack[Ts]]:
    return rest  # type: tuple minus the first element

# Generic class with variadic type params
from typing import Generic

class TypedPipeline(Generic[*Ts]):
    """Pipeline where each stage transforms types sequentially."""
    def __init__(self, *stages: Unpack[Ts]) -> None:
        self.stages = stages
```

### Shape-Typed Arrays (NumPy Pattern)

```python
from typing import TypeVarTuple, Generic, Unpack

Shape = TypeVarTuple("Shape")

class Array(Generic[*Shape]):
    def __init__(self, *shape: Unpack[Shape]) -> None: ...
    def reshape[*NewShape](self, *new_shape: Unpack[NewShape]) -> Array[*NewShape]: ...

# Usage
x: Array[int, int, int] = Array(3, 224, 224)  # 3D array shape
```

---

## Type Narrowing: TypeGuard & TypeIs

### TypeGuard (3.10+) — Narrows True Branch Only

```python
from typing import TypeGuard

def is_str_list(val: list[object]) -> TypeGuard[list[str]]:
    return all(isinstance(x, str) for x in val)

def process(data: list[object]) -> None:
    if is_str_list(data):
        reveal_type(data)  # list[str]
    else:
        reveal_type(data)  # list[object] — NOT narrowed
```

### TypeIs (3.13+) — Narrows Both Branches

```python
from typing import TypeIs  # or typing_extensions

def is_int(val: int | str) -> TypeIs[int]:
    return isinstance(val, int)

def handle(val: int | str) -> None:
    if is_int(val):
        reveal_type(val)  # int
    else:
        reveal_type(val)  # str — narrowed in else!
```

### Key Differences

| Feature | TypeGuard | TypeIs |
|---|---|---|
| True branch narrowing | ✅ | ✅ |
| False branch narrowing | ❌ | ✅ |
| Must be subtype of input | ❌ | ✅ |
| Available since | 3.10 | 3.13 |

### Advanced Narrowing with TypeGuard

```python
from typing import TypeGuard, TypeVar

T = TypeVar("T")

def is_not_none(val: T | None) -> TypeGuard[T]:
    return val is not None

# Narrowing dicts
def has_key(d: dict[str, object], key: str) -> TypeGuard[dict[str, str]]:
    return key in d and isinstance(d[key], str)
```

---

## Nominal Typing with NewType

```python
from typing import NewType

UserId = NewType("UserId", int)
PostId = NewType("PostId", int)

def get_user(uid: UserId) -> User: ...
def get_post(pid: PostId) -> Post: ...

uid = UserId(42)
pid = PostId(42)

get_user(uid)  # OK
get_user(pid)  # ERROR — PostId is not UserId
get_user(42)   # ERROR — int is not UserId

# NewType stacks
AdminId = NewType("AdminId", UserId)
admin = AdminId(UserId(1))
get_user(admin)  # OK — AdminId is a subtype of UserId
```

### NewType vs TypeAlias

```python
# TypeAlias: just an alias, fully interchangeable
type Seconds = float              # float and Seconds are identical
# NewType: distinct type at check time
Seconds = NewType("Seconds", float)  # Seconds ≠ float for type checkers
```

---

## Intersection Types Workarounds

Python has no native `A & B` syntax. Use Protocol composition:

```python
from typing import Protocol

class Readable(Protocol):
    def read(self) -> bytes: ...

class Closeable(Protocol):
    def close(self) -> None: ...

# "Intersection" via combined Protocol
class ReadableCloseable(Readable, Closeable, Protocol): ...

def process(resource: ReadableCloseable) -> None:
    data = resource.read()
    resource.close()
# Any class with both read() and close() satisfies this
```

### Generic Intersection Pattern

```python
from typing import TypeVar, Protocol

class HasName(Protocol):
    name: str

class HasAge(Protocol):
    age: int

# Intersect with a TypeVar bound to combined protocol
class HasNameAndAge(HasName, HasAge, Protocol): ...

T = TypeVar("T", bound=HasNameAndAge)

def greet(entity: T) -> str:
    return f"{entity.name} is {entity.age}"
```

---

## Higher-Kinded Types Workarounds

Python cannot parameterize over type constructors natively. Workarounds:

### Protocol-Based Functor

```python
from typing import Protocol, TypeVar, Generic

A = TypeVar("A")
B = TypeVar("B")

class Functor(Protocol[A]):
    def map(self, fn: Callable[[A], B]) -> Functor[B]: ...

class MyList(Generic[A]):
    def __init__(self, items: list[A]) -> None:
        self.items = items
    def map(self, fn: Callable[[A], B]) -> MyList[B]:
        return MyList([fn(x) for x in self.items])
```

### `returns` Library for Monadic Patterns

```python
# pip install returns
from returns.result import Result, Success, Failure

def divide(a: float, b: float) -> Result[float, ZeroDivisionError]:
    if b == 0:
        return Failure(ZeroDivisionError())
    return Success(a / b)

result = divide(10, 3).map(lambda x: x * 2)  # Fully typed chain
```

---

## Advanced Protocol Patterns

### Generic Protocol with Self

```python
from typing import Protocol, Self

class Comparable(Protocol):
    def __lt__(self, other: Self) -> bool: ...
    def __le__(self, other: Self) -> bool: ...

def max_item[T: Comparable](items: list[T]) -> T:  # 3.12+
    return max(items)
```

### Protocol with ClassVar and __init__

```python
from typing import Protocol, ClassVar

class Registrable(Protocol):
    registry: ClassVar[dict[str, type]]
    def __init__(self, name: str) -> None: ...
```

### Callback Protocol (Named Parameters)

```python
class ErrorHandler(Protocol):
    def __call__(
        self, error: Exception, *, retry: bool = False, context: dict[str, str] | None = None
    ) -> bool: ...
```

---

## Overload Strategies

### Return Type Varies by Argument Value

```python
from typing import overload, Literal

@overload
def fetch(url: str, raw: Literal[True]) -> bytes: ...
@overload
def fetch(url: str, raw: Literal[False] = ...) -> str: ...
def fetch(url: str, raw: bool = False) -> str | bytes:
    resp = urllib.request.urlopen(url).read()
    return resp if raw else resp.decode()
```

### Overload with Generic Return

```python
from typing import overload, TypeVar, Type

T = TypeVar("T")

@overload
def parse(data: str, as_type: Type[int]) -> int: ...
@overload
def parse(data: str, as_type: Type[float]) -> float: ...
@overload
def parse(data: str, as_type: Type[T]) -> T: ...
def parse(data: str, as_type: type = str) -> object:
    return as_type(data)
```

---

## Type-Level Computation Patterns

### Conditional Types with Overload

```python
from typing import overload

@overload
def ensure(val: None) -> NoReturn: ...
@overload
def ensure[T](val: T) -> T: ...
def ensure(val: object) -> object:
    if val is None:
        raise ValueError("unexpected None")
    return val
```

### Mapped Types with TypedDict + Unpack

```python
from typing import TypedDict, Unpack

class Options(TypedDict, total=False):
    timeout: int
    retries: int
    verbose: bool

def request(url: str, **kwargs: Unpack[Options]) -> bytes:
    # Type checker validates keyword args against Options
    ...
```

### Final and Immutability

```python
from typing import Final

MAX_RETRIES: Final = 3            # Cannot be reassigned
API_URL: Final[str] = "https://..."  # Explicit type + final

class Config:
    DEBUG: Final = False           # Cannot be overridden in subclass
```
