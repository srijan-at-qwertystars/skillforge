# pytest Fixtures — Cheatsheet

Quick reference for writing and using pytest fixtures effectively.

---

## Scope Reference

| Scope | Lifetime | Created | Destroyed | Best for |
|------------|------------------------------|---------|-----------|-------------------------------|
| `function` | One test function (default) | Before each test | After each test | Mutable state, DB sessions |
| `class` | One test class | Before first method | After last method | Shared read-only class state |
| `module` | One `.py` file | Before first test | After last test | Expensive read-only data |
| `package` | One test package (`__init__.py`) | Before first test in pkg | After last test in pkg | Cross-module shared resources |
| `session` | Entire test run | Once at start | Once at end | DB engine, large datasets |

> **Rule of thumb:** Use the *narrowest* scope that avoids redundant work.
> Mutable fixtures should almost always be `function`-scoped.

---

## yield vs return Fixtures

### return (setup only)

```python
@pytest.fixture()
def user():
    return User(name="Alice")
```

### yield (setup + teardown)

```python
@pytest.fixture()
def db_conn():
    conn = database.connect()
    yield conn           # test runs here
    conn.rollback()      # teardown — always runs, even if test fails
    conn.close()
```

> **When to use yield:** Whenever you need cleanup (close connections, delete
> temp files, restore state). Code after `yield` is the teardown.

---

## Parametrized Fixtures

Generate multiple fixture instances — each test using the fixture runs once
per parameter.

```python
@pytest.fixture(params=["sqlite", "postgres", "mysql"], ids=str)
def db_engine(request):
    """Test against every supported database backend."""
    engine = create_engine(request.param)
    yield engine
    engine.dispose()
```

### With indirect parametrize

```python
@pytest.fixture()
def user(request):
    role = request.param
    return User(name="Test", role=role)

@pytest.mark.parametrize("user", ["admin", "viewer"], indirect=True)
def test_permissions(user):
    ...
```

---

## The `request` Object

The `request` fixture gives access to test context inside a fixture.

```python
@pytest.fixture()
def resource(request):
    # request.param        — current parametrize value
    # request.node.name    — name of the current test
    # request.config       — pytest config object
    # request.fspath       — path of the test file
    # request.cls          — test class (or None)
    # request.function     — test function object
    # request.fixturename  — name of this fixture
    # request.scope        — scope of this fixture

    # Conditional setup based on markers:
    if request.node.get_closest_marker("slow"):
        timeout = 60
    else:
        timeout = 5

    return Resource(timeout=timeout)
```

### Adding finalizers via `request`

```python
@pytest.fixture()
def tmpfile(request):
    f = open("temp.txt", "w")
    # Finalizers run even if the fixture setup fails partway through.
    request.addfinalizer(f.close)
    return f
```

---

## autouse Patterns

Fixtures with `autouse=True` run automatically for every test in their scope
*without* being explicitly requested.

```python
# Runs before/after EVERY test in the session
@pytest.fixture(autouse=True, scope="session")
def _setup_logging():
    logging.basicConfig(level=logging.DEBUG)
    yield

# Runs for every test in this file only (place in the test module, not conftest)
@pytest.fixture(autouse=True)
def _reset_singletons():
    MyService._instance = None
    yield
```

### Marker-gated autouse

```python
@pytest.fixture(autouse=True)
def _apply_slow_settings(request):
    """Only activate for tests marked @pytest.mark.slow."""
    marker = request.node.get_closest_marker("slow")
    if marker is None:
        yield
        return
    # Increase timeout for slow tests
    with override_settings(TIMEOUT=120):
        yield
```

---

## Fixture Finalization

Three ways to run cleanup code:

### 1. yield (preferred)

```python
@pytest.fixture()
def server():
    srv = start_server()
    yield srv
    srv.shutdown()
```

### 2. addfinalizer (multiple teardown steps)

```python
@pytest.fixture()
def resources(request):
    db = connect_db()
    request.addfinalizer(db.close)

    cache = connect_cache()
    request.addfinalizer(cache.flush)

    return db, cache
```

### 3. Context managers

```python
@pytest.fixture()
def temp_dir():
    with tempfile.TemporaryDirectory() as d:
        yield Path(d)
    # Cleanup is handled by the context manager.
```

> **yield vs addfinalizer:** Prefer `yield`. Use `addfinalizer` when you need
> multiple independent teardown steps or when cleanup must run even if setup
> fails partway through (code after `yield` won't run if setup raises).

---

## Fixture Composition

Fixtures can depend on other fixtures. pytest resolves the dependency graph
automatically.

```python
@pytest.fixture()
def db():
    return create_db()

@pytest.fixture()
def user(db):       # depends on db
    return db.create_user("Alice")

@pytest.fixture()
def auth_token(user):  # depends on user → depends on db
    return generate_token(user)

def test_authenticated_request(auth_token):
    # pytest sets up: db → user → auth_token
    ...
```

---

## Common Pitfalls

### ❌ Mutable default in wider-scoped fixtures

```python
# BAD — all tests share the SAME list object
@pytest.fixture(scope="session")
def items():
    return []

# GOOD — function scope, or return a copy
@pytest.fixture()
def items():
    return []
```

### ❌ Scope mismatch

```python
# BAD — function-scoped fixture depends on function-scoped DB,
# but is declared as session-scoped. pytest will raise an error.
@pytest.fixture(scope="session")
def analytics(db_session):  # db_session is function-scoped!
    ...

# GOOD — match scopes or use a wider-scoped DB fixture
@pytest.fixture(scope="session")
def analytics(session_db):  # session_db is also session-scoped
    ...
```

### ❌ Side effects in parametrized fixtures

```python
# BAD — files accumulate across parametrize runs
@pytest.fixture(params=["a.txt", "b.txt"])
def data_file(request):
    Path(request.param).write_text("data")
    return request.param
    # No cleanup! Files leak.

# GOOD — clean up with yield
@pytest.fixture(params=["a.txt", "b.txt"])
def data_file(request, tmp_path):
    f = tmp_path / request.param
    f.write_text("data")
    yield f
    # tmp_path handles cleanup automatically
```

### ❌ Forgetting `yield` in async fixtures

```python
# BAD — returns a coroutine, not the value
@pytest.fixture()
async def client():
    return await create_client()

# GOOD — yield so teardown can await cleanup
@pytest.fixture()
async def client():
    c = await create_client()
    yield c
    await c.close()
```

### ❌ Heavy setup in function-scoped fixtures

```python
# BAD — spins up a container 500 times
@pytest.fixture()
def database():
    container = start_postgres_container()  # 3 seconds each time!
    yield container
    container.stop()

# GOOD — session scope + per-test transaction isolation
@pytest.fixture(scope="session")
def database():
    container = start_postgres_container()
    yield container
    container.stop()

@pytest.fixture()
def db_session(database):
    conn = database.connect()
    txn = conn.begin()
    yield conn
    txn.rollback()
    conn.close()
```

---

## Quick Reference Table

| Pattern | Code |
|-------------------------------|-----------------------------------------------|
| Basic fixture | `@pytest.fixture()` |
| With scope | `@pytest.fixture(scope="session")` |
| With autouse | `@pytest.fixture(autouse=True)` |
| Parametrized | `@pytest.fixture(params=[1, 2, 3])` |
| Access param value | `request.param` |
| Teardown with yield | `yield value` then cleanup |
| Teardown with finalizer | `request.addfinalizer(cleanup_fn)` |
| Override in sub-conftest | Re-declare the fixture with the same name |
| Fixture from plugin | `pip install pytest-X`, then request by name |
| List available fixtures | `pytest --fixtures` |
| Show fixture setup order | `pytest --setup-show` |
