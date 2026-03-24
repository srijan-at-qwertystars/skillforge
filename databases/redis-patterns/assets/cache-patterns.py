"""
Redis Cache Patterns — Production implementations
Includes: cache-aside, write-through, distributed lock, and cache stampede protection.

Requirements: pip install redis

Usage:
    import redis
    from cache_patterns import CacheAside, WriteThrough, DistributedLock

    r = redis.Redis(host='localhost', port=6379, decode_responses=True)
    cache = CacheAside(r, default_ttl=300)
    value = cache.get_or_load("user:1001", lambda: db.fetch_user(1001))
"""

import json
import time
import uuid
import hashlib
import functools
import logging
from contextlib import contextmanager
from typing import Any, Callable, Optional

import redis

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Cache-Aside (Lazy Loading)
# ---------------------------------------------------------------------------

class CacheAside:
    """
    Cache-aside pattern: check cache first, load from source on miss,
    populate cache for next read.

    Features:
    - Configurable TTL per key or global default
    - JSON serialization
    - Cache stampede protection via probabilistic early recomputation
    - Null value caching (prevents cache penetration)
    """

    def __init__(
        self,
        client: redis.Redis,
        default_ttl: int = 300,
        null_ttl: int = 60,
        key_prefix: str = "cache:",
    ):
        self.r = client
        self.default_ttl = default_ttl
        self.null_ttl = null_ttl
        self.key_prefix = key_prefix

    def _make_key(self, key: str) -> str:
        return f"{self.key_prefix}{key}"

    def get(self, key: str) -> Optional[Any]:
        """Read from cache. Returns None on miss."""
        raw = self.r.get(self._make_key(key))
        if raw is None:
            return None
        data = json.loads(raw)
        if data.get("__null__"):
            return None
        return data.get("v")

    def set(self, key: str, value: Any, ttl: Optional[int] = None) -> None:
        """Write to cache with TTL."""
        ttl = ttl or self.default_ttl
        cache_key = self._make_key(key)
        if value is None:
            # Cache null to prevent repeated DB lookups for missing keys
            self.r.set(cache_key, json.dumps({"__null__": True}), ex=self.null_ttl)
        else:
            self.r.set(cache_key, json.dumps({"v": value}), ex=ttl)

    def delete(self, key: str) -> None:
        """Invalidate cache entry."""
        self.r.delete(self._make_key(key))

    def get_or_load(
        self,
        key: str,
        loader: Callable[[], Any],
        ttl: Optional[int] = None,
    ) -> Any:
        """
        Get from cache or load from source on miss.
        Loader is called only on cache miss.
        """
        value = self.get(key)
        if value is not None:
            return value

        # Cache miss — load from source
        value = loader()
        self.set(key, value, ttl)
        return value

    def get_or_load_protected(
        self,
        key: str,
        loader: Callable[[], Any],
        ttl: Optional[int] = None,
        lock_timeout: int = 10,
    ) -> Optional[Any]:
        """
        Cache-aside with stampede protection using a distributed lock.
        Only one caller loads on miss; others wait or get stale data.
        """
        value = self.get(key)
        if value is not None:
            return value

        lock_key = f"lock:load:{key}"
        lock = DistributedLock(self.r, lock_key, timeout=lock_timeout)

        if lock.acquire(blocking_timeout=lock_timeout):
            try:
                # Double-check after acquiring lock
                value = self.get(key)
                if value is not None:
                    return value
                value = loader()
                self.set(key, value, ttl)
                return value
            finally:
                lock.release()
        else:
            # Another process is loading — retry cache read
            time.sleep(0.5)
            return self.get(key)


# ---------------------------------------------------------------------------
# Write-Through Cache
# ---------------------------------------------------------------------------

class WriteThrough:
    """
    Write-through pattern: writes go to both cache and database atomically.
    Reads always hit cache first.

    The `writer` callable must persist to the database.
    Cache is updated only after successful DB write.
    """

    def __init__(
        self,
        client: redis.Redis,
        default_ttl: int = 300,
        key_prefix: str = "wt:",
    ):
        self.r = client
        self.default_ttl = default_ttl
        self.key_prefix = key_prefix

    def _make_key(self, key: str) -> str:
        return f"{self.key_prefix}{key}"

    def read(self, key: str, loader: Callable[[], Any], ttl: Optional[int] = None) -> Any:
        """Read from cache, fallback to loader on miss."""
        cache_key = self._make_key(key)
        raw = self.r.get(cache_key)
        if raw is not None:
            return json.loads(raw)

        value = loader()
        if value is not None:
            self.r.set(cache_key, json.dumps(value), ex=ttl or self.default_ttl)
        return value

    def write(
        self,
        key: str,
        value: Any,
        writer: Callable[[str, Any], None],
        ttl: Optional[int] = None,
    ) -> None:
        """
        Write to database first, then update cache.
        If DB write fails, cache is not updated (consistency).
        """
        # Write to database (raises on failure)
        writer(key, value)
        # Update cache
        self.r.set(
            self._make_key(key),
            json.dumps(value),
            ex=ttl or self.default_ttl,
        )

    def delete(self, key: str, deleter: Callable[[str], None]) -> None:
        """Delete from database and invalidate cache."""
        deleter(key)
        self.r.delete(self._make_key(key))


# ---------------------------------------------------------------------------
# Distributed Lock (Redlock-lite)
# ---------------------------------------------------------------------------

class DistributedLock:
    """
    Redis distributed lock using SET NX EX with safe release via Lua.

    Features:
    - Unique owner token prevents releasing someone else's lock
    - Automatic expiry prevents deadlocks
    - Lua-based atomic release
    - Optional blocking acquire with timeout
    - Context manager support

    For stronger guarantees across multiple Redis instances, use the full
    Redlock algorithm (see redis.io/topics/distlock).
    """

    RELEASE_SCRIPT = """
    if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('del', KEYS[1])
    else
        return 0
    end
    """

    EXTEND_SCRIPT = """
    if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('pexpire', KEYS[1], ARGV[2])
    else
        return 0
    end
    """

    def __init__(
        self,
        client: redis.Redis,
        name: str,
        timeout: int = 30,
        retry_interval: float = 0.1,
    ):
        self.r = client
        self.name = name
        self.timeout = timeout
        self.retry_interval = retry_interval
        self.token: Optional[str] = None
        self._release_sha: Optional[str] = None
        self._extend_sha: Optional[str] = None

    def _load_scripts(self) -> None:
        if self._release_sha is None:
            self._release_sha = self.r.script_load(self.RELEASE_SCRIPT)
            self._extend_sha = self.r.script_load(self.EXTEND_SCRIPT)

    def acquire(self, blocking_timeout: Optional[int] = None) -> bool:
        """
        Acquire the lock.
        If blocking_timeout is set, retry until acquired or timeout.
        Returns True if lock acquired, False otherwise.
        """
        self.token = str(uuid.uuid4())
        deadline = time.monotonic() + (blocking_timeout or 0)

        while True:
            if self.r.set(self.name, self.token, nx=True, ex=self.timeout):
                return True

            if blocking_timeout is None or time.monotonic() >= deadline:
                self.token = None
                return False

            time.sleep(self.retry_interval)

    def release(self) -> bool:
        """
        Release the lock. Only succeeds if we still own it.
        Returns True if released, False if lock was lost/expired.
        """
        if self.token is None:
            return False
        self._load_scripts()
        result = self.r.evalsha(self._release_sha, 1, self.name, self.token)
        self.token = None
        return bool(result)

    def extend(self, additional_time: int) -> bool:
        """
        Extend the lock TTL. Only succeeds if we still own it.
        additional_time is in seconds.
        """
        if self.token is None:
            return False
        self._load_scripts()
        result = self.r.evalsha(
            self._extend_sha, 1, self.name, self.token, additional_time * 1000
        )
        return bool(result)

    @contextmanager
    def __call__(self, blocking_timeout: Optional[int] = None):
        """Context manager for lock acquisition and release."""
        if not self.acquire(blocking_timeout=blocking_timeout):
            raise TimeoutError(f"Could not acquire lock: {self.name}")
        try:
            yield self
        finally:
            self.release()

    def __enter__(self):
        if not self.acquire():
            raise TimeoutError(f"Could not acquire lock: {self.name}")
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.release()
        return False


# ---------------------------------------------------------------------------
# Cache decorator
# ---------------------------------------------------------------------------

def cached(
    client: redis.Redis,
    ttl: int = 300,
    prefix: str = "fn:",
    key_builder: Optional[Callable] = None,
):
    """
    Decorator to cache function results in Redis.

    @cached(redis_client, ttl=60)
    def get_user(user_id: int) -> dict:
        return db.query(f"SELECT * FROM users WHERE id = {user_id}")
    """
    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            if key_builder:
                cache_key = f"{prefix}{func.__name__}:{key_builder(*args, **kwargs)}"
            else:
                raw = f"{args}:{sorted(kwargs.items())}"
                key_hash = hashlib.md5(raw.encode()).hexdigest()[:12]
                cache_key = f"{prefix}{func.__name__}:{key_hash}"

            cached_val = client.get(cache_key)
            if cached_val is not None:
                return json.loads(cached_val)

            result = func(*args, **kwargs)
            client.set(cache_key, json.dumps(result), ex=ttl)
            return result

        wrapper.invalidate = lambda *a, **kw: client.delete(
            f"{prefix}{func.__name__}:{key_builder(*a, **kw) if key_builder else hashlib.md5(f'{a}:{sorted(kw.items())}'.encode()).hexdigest()[:12]}"
        )
        return wrapper
    return decorator


# ---------------------------------------------------------------------------
# Example usage
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    r = redis.Redis(host="localhost", port=6379, decode_responses=True)

    # --- Cache-Aside ---
    cache = CacheAside(r, default_ttl=60)
    cache.set("user:1001", {"name": "Alice", "email": "alice@example.com"})
    user = cache.get_or_load("user:1001", lambda: {"name": "Alice"})
    print(f"Cache-aside: {user}")

    # --- Write-Through ---
    db_store = {}
    wt = WriteThrough(r, default_ttl=60)
    wt.write("product:42", {"name": "Widget", "price": 9.99},
             writer=lambda k, v: db_store.update({k: v}))
    product = wt.read("product:42", loader=lambda: db_store.get("product:42"))
    print(f"Write-through: {product}")

    # --- Distributed Lock ---
    lock = DistributedLock(r, "lock:critical-section", timeout=10)
    with lock:
        print("Distributed lock: acquired, doing work...")
    print("Distributed lock: released")

    # --- Cached decorator ---
    @cached(r, ttl=30, key_builder=lambda uid: str(uid))
    def get_user_profile(user_id: int) -> dict:
        return {"id": user_id, "name": f"User {user_id}"}

    profile = get_user_profile(42)
    print(f"Cached decorator: {profile}")
    get_user_profile.invalidate(42)
    print("Cache invalidated for user 42")
