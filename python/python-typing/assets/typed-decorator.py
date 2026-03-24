"""typed-decorator.py — Templates for properly typed decorators using ParamSpec.

Copy and adapt these patterns for your decorator needs.
All decorators preserve the original function's type signature.

Requires: Python 3.10+ or typing_extensions for ParamSpec.
"""

from __future__ import annotations

import asyncio
import functools
import logging
import time
from typing import (
    Any,
    Callable,
    Concatenate,
    ParamSpec,
    TypeVar,
    overload,
)

P = ParamSpec("P")
R = TypeVar("R")
T = TypeVar("T")

logger = logging.getLogger(__name__)


# ── Pattern 1: Simple wrapper (no arguments) ──────────────────────────────

def log_calls(fn: Callable[P, R]) -> Callable[P, R]:
    """Log every call to the decorated function. Preserves type signature."""
    @functools.wraps(fn)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        logger.info("Calling %s", fn.__name__)
        result = fn(*args, **kwargs)
        logger.info("Returned from %s", fn.__name__)
        return result
    return wrapper


# Usage:
# @log_calls
# def greet(name: str, excited: bool = False) -> str: ...
# reveal_type(greet)  # (name: str, excited: bool = False) -> str


# ── Pattern 2: Decorator with arguments ───────────────────────────────────

def retry(
    max_attempts: int = 3,
    delay: float = 1.0,
    exceptions: tuple[type[Exception], ...] = (Exception,),
) -> Callable[[Callable[P, R]], Callable[P, R]]:
    """Retry on failure. Preserves type signature."""
    def decorator(fn: Callable[P, R]) -> Callable[P, R]:
        @functools.wraps(fn)
        def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
            last_exc: Exception | None = None
            for attempt in range(1, max_attempts + 1):
                try:
                    return fn(*args, **kwargs)
                except exceptions as exc:
                    last_exc = exc
                    if attempt < max_attempts:
                        time.sleep(delay * attempt)
            raise last_exc  # type: ignore[misc]
        return wrapper
    return decorator


# Usage:
# @retry(max_attempts=5, delay=0.5)
# def fetch(url: str) -> bytes: ...
# reveal_type(fetch)  # (url: str) -> bytes


# ── Pattern 3: Decorator that injects a parameter (Concatenate) ───────────

class Database:
    """Stub database class for demonstration."""
    def query(self, sql: str) -> list[dict[str, Any]]:
        return []

def get_database() -> Database:
    return Database()

def with_db(
    fn: Callable[Concatenate[Database, P], R],
) -> Callable[P, R]:
    """Inject a Database as the first argument. Removes it from caller's signature."""
    @functools.wraps(fn)
    def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        db = get_database()
        return fn(db, *args, **kwargs)
    return wrapper


# Usage:
# @with_db
# def get_users(db: Database, active: bool = True) -> list[str]:
#     return [r["name"] for r in db.query("SELECT name FROM users")]
# reveal_type(get_users)  # (active: bool = True) -> list[str]


# ── Pattern 4: Async decorator ────────────────────────────────────────────

from collections.abc import Awaitable

def async_timer(
    fn: Callable[P, Awaitable[R]],
) -> Callable[P, Awaitable[R]]:
    """Time an async function. Preserves async type signature."""
    @functools.wraps(fn)
    async def wrapper(*args: P.args, **kwargs: P.kwargs) -> R:
        start = time.perf_counter()
        result = await fn(*args, **kwargs)
        elapsed = time.perf_counter() - start
        logger.info("%s took %.3fs", fn.__name__, elapsed)
        return result
    return wrapper


# Usage:
# @async_timer
# async def fetch_data(url: str, timeout: int = 30) -> bytes: ...
# reveal_type(fetch_data)  # (url: str, timeout: int = 30) -> Awaitable[bytes]


# ── Pattern 5: Decorator that works on both sync and async ────────────────

@overload
def universal_timer(fn: Callable[P, Awaitable[R]]) -> Callable[P, Awaitable[R]]: ...
@overload
def universal_timer(fn: Callable[P, R]) -> Callable[P, R]: ...

def universal_timer(fn: Callable[P, Any]) -> Callable[P, Any]:
    """Time any function (sync or async). Detects async automatically."""
    if asyncio.iscoroutinefunction(fn):
        @functools.wraps(fn)
        async def async_wrapper(*args: P.args, **kwargs: P.kwargs) -> Any:
            start = time.perf_counter()
            result = await fn(*args, **kwargs)
            logger.info("%s took %.3fs", fn.__name__, time.perf_counter() - start)
            return result
        return async_wrapper
    else:
        @functools.wraps(fn)
        def sync_wrapper(*args: P.args, **kwargs: P.kwargs) -> Any:
            start = time.perf_counter()
            result = fn(*args, **kwargs)
            logger.info("%s took %.3fs", fn.__name__, time.perf_counter() - start)
            return result
        return sync_wrapper


# ── Pattern 6: Class-method-aware decorator ───────────────────────────────

def validate_positive_first_arg(
    fn: Callable[Concatenate[Any, int, P], R],
) -> Callable[Concatenate[Any, int, P], R]:
    """Validate that the first non-self argument is positive."""
    @functools.wraps(fn)
    def wrapper(self_or_cls: Any, value: int, *args: P.args, **kwargs: P.kwargs) -> R:
        if value <= 0:
            raise ValueError(f"Expected positive value, got {value}")
        return fn(self_or_cls, value, *args, **kwargs)
    return wrapper


# Usage:
# class Account:
#     @validate_positive_first_arg
#     def deposit(self, amount: int, memo: str = "") -> None: ...


# ── Pattern 7: Decorator preserving method return with Self ───────────────

from typing import Self

def chainable_log(fn: Callable[Concatenate[T, P], T]) -> Callable[Concatenate[T, P], T]:
    """Log calls to fluent/chainable methods that return self."""
    @functools.wraps(fn)
    def wrapper(self: T, *args: P.args, **kwargs: P.kwargs) -> T:
        logger.info("Chaining %s.%s", type(self).__name__, fn.__name__)
        return fn(self, *args, **kwargs)
    return wrapper


# Usage:
# class Builder:
#     @chainable_log
#     def set_name(self, name: str) -> Self:
#         self._name = name
#         return self
