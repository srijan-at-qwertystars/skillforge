---
name: pytest-patterns
description: >
  Use when user writes Python tests with pytest, asks about fixtures, parametrize,
  mocking with pytest-mock/monkeypatch, conftest.py patterns, test organization,
  marks, or pytest plugins. Do NOT use for unittest-only codebases,
  JavaScript/TypeScript testing (Jest/Vitest), or general Python coding unrelated
  to testing.
---

# Pytest Patterns and Best Practices

## Fixture Patterns

### Scope

Set fixture scope to control lifecycle. Use `function` (default) for isolation,
`module` or `session` for expensive resources.

```python
@pytest.fixture(scope="session")
def db_engine():
    engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(engine)
    yield engine
    engine.dispose()

@pytest.fixture(scope="function")
def db_session(db_engine):
    connection = db_engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)
    yield session
    session.close()
    transaction.rollback()
    connection.close()
```

### Yield Fixtures (Setup/Teardown)

Use `yield` for cleanup. Everything after `yield` runs as teardown.

```python
@pytest.fixture
def temp_config(tmp_path):
    config_file = tmp_path / "config.yaml"
    config_file.write_text("debug: true")
    yield config_file
    # teardown: tmp_path auto-cleans, but custom cleanup goes here
```

### Factory Fixtures

Return a callable to create multiple instances with varying attributes.

```python
@pytest.fixture
def make_user():
    created = []
    def _make_user(name="default", role="viewer"):
        user = User(name=name, role=role)
        created.append(user)
        return user
    yield _make_user
    for u in created:
        u.delete()

def test_admin_permissions(make_user):
    admin = make_user(name="alice", role="admin")
    viewer = make_user(name="bob")
    assert admin.can_edit() and not viewer.can_edit()
```

### Autouse Fixtures

Apply automatically to all tests in scope. Use sparingly—prefer explicit dependencies.

```python
@pytest.fixture(autouse=True)
def reset_environment(monkeypatch):
    monkeypatch.delenv("API_KEY", raising=False)
```

### Request Param (Parameterized Fixtures)

Run every dependent test against multiple fixture values.

```python
@pytest.fixture(params=["sqlite", "postgres"])
def db_backend(request):
    return create_backend(request.param)

def test_insert(db_backend):  # runs twice, once per backend
    db_backend.insert({"key": "val"})
    assert db_backend.get("key") == "val"
```

## Parametrize

### Single Parameter

```python
@pytest.mark.parametrize("value", [1, 0, -1])
def test_abs_positive(value):
    assert abs(value) >= 0
```

### Multiple Parameters with IDs

```python
@pytest.mark.parametrize("a, b, expected", [
    (2, 3, 5),
    (-1, 1, 0),
    (0, 0, 0),
], ids=["positive", "mixed-sign", "zeros"])
def test_add(a, b, expected):
    assert add(a, b) == expected
```

### Stacking Parametrize (Cartesian Product)

```python
@pytest.mark.parametrize("x", [1, 2])
@pytest.mark.parametrize("y", [10, 20])
def test_multiply(x, y):  # 4 combinations
    assert multiply(x, y) == x * y
```

### Indirect Parametrize

Pass params through a fixture instead of directly to the test.

```python
@pytest.fixture
def user(request):
    return User(role=request.param)

@pytest.mark.parametrize("user", ["admin", "viewer"], indirect=True)
def test_user_access(user):
    assert user.role in ("admin", "viewer")
```

## Mocking

### monkeypatch (Built-in)

Use for environment vars, attributes, dict items. Automatically reverts after test.

```python
def test_config_from_env(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "sqlite:///test.db")
    config = load_config()
    assert config.db_url == "sqlite:///test.db"

def test_override_method(monkeypatch):
    monkeypatch.setattr("myapp.service.get_time", lambda: 1000)
    assert myapp.service.get_time() == 1000
```

### pytest-mock (`mocker` fixture)

Thin wrapper over `unittest.mock`. Use when you need call tracking, spec enforcement,
or complex mock behavior.

```python
def test_send_email(mocker):
    mock_smtp = mocker.patch("myapp.notifications.smtp_client")
    send_welcome_email("user@test.com")
    mock_smtp.send.assert_called_once_with(
        to="user@test.com", subject=mocker.ANY, body=mocker.ANY
    )
```

### When to Use Which

| Tool | Best For |
|------|----------|
| `monkeypatch` | Env vars, simple attribute/dict overrides, no call tracking needed |
| `pytest-mock` | Call assertions, return value sequences, side effects, spec validation |
| `unittest.mock` directly | Only if avoiding plugin dependencies; prefer `pytest-mock` wrapper |

### Patch Location Rule

Patch where the name is looked up, not where it is defined.

```python
# myapp/views.py imports: from myapp.services import fetch_data
# Correct:
mocker.patch("myapp.views.fetch_data")
# Wrong:
mocker.patch("myapp.services.fetch_data")  # won't affect views.py
```

## conftest.py Organization

### Fixture Sharing

Place shared fixtures in `conftest.py` at the appropriate directory level.
Pytest discovers them automatically—no imports needed.

```
tests/
├── conftest.py              # session-scoped fixtures (db, client)
├── unit/
│   ├── conftest.py          # unit-specific helpers
│   └── test_models.py
└── integration/
    ├── conftest.py          # integration fixtures (test server)
    └── test_api.py
```

### Hooks and Custom Options

```python
# tests/conftest.py
def pytest_addoption(parser):
    parser.addoption("--runslow", action="store_true", default=False)

def pytest_collection_modifyitems(config, items):
    if not config.getoption("--runslow"):
        skip_slow = pytest.mark.skip(reason="need --runslow to run")
        for item in items:
            if "slow" in item.keywords:
                item.add_marker(skip_slow)
```

### Keep conftest.py Focused

- Put only truly shared fixtures and hooks in conftest.py.
- Do not put test functions in conftest.py.
- Use multiple conftest.py files at different directory levels for scoping.

## Marks

### Built-in Marks

```python
@pytest.mark.skip(reason="broken upstream dependency")
def test_broken_feature(): ...

@pytest.mark.skipif(sys.platform == "win32", reason="unix only")
def test_unix_sockets(): ...

@pytest.mark.xfail(reason="known bug #1234", strict=True)
def test_known_bug():
    assert buggy_function() == "fixed"  # strict=True: XPASS = failure
```

### Custom Marks

Register in `pyproject.toml` to avoid warnings:

```toml
[tool.pytest.ini_options]
markers = [
    "slow: marks tests as slow",
    "integration: integration tests requiring external services",
]
```

```python
@pytest.mark.slow
def test_full_pipeline(): ...

# Run only integration tests:
# pytest -m integration
# Exclude slow tests:
# pytest -m "not slow"
```

### Strict Mode

Enable `--strict-markers` (or set in config) to error on unregistered marks.
Catches typos like `@pytest.mark.slwo`.

```toml
[tool.pytest.ini_options]
addopts = "--strict-markers"
```

## Test Organization

### Directory Structure

Mirror source layout. Separate unit and integration tests.

```
src/
  myapp/
    models.py
    services.py
tests/
  unit/
    test_models.py
    test_services.py
  integration/
    test_api.py
  conftest.py
pyproject.toml
```

### Naming Conventions

- Files: `test_*.py` or `*_test.py`
- Functions: `test_<what>_<scenario>_<expected>`
- Classes: `TestClassName` (no `__init__`)

```python
def test_parse_date_invalid_format_raises_valueerror(): ...
def test_user_creation_duplicate_email_returns_conflict(): ...
```

### Functions vs Classes

Prefer standalone functions. Use classes only to group related tests sharing setup.

```python
class TestUserAuthentication:
    def test_login_valid_credentials(self, client): ...
    def test_login_wrong_password(self, client): ...
    def test_login_locked_account(self, client): ...
```

## Common Plugins

| Plugin | Purpose | Key Usage |
|--------|---------|-----------|
| `pytest-cov` | Coverage reporting | `pytest --cov=myapp --cov-report=term-missing` |
| `pytest-xdist` | Parallel execution | `pytest -n auto` (use all cores) |
| `pytest-randomly` | Randomize test order | Exposes order-dependent bugs; set `--randomly-seed=last` to reproduce |
| `pytest-asyncio` | Async test support | Mark with `@pytest.mark.asyncio` or set `asyncio_mode = "auto"` |
| `pytest-httpx` | Mock HTTPX requests | Fixture-based mocking for async HTTP |
| `pytest-timeout` | Prevent hanging tests | `@pytest.mark.timeout(10)` or global `--timeout=30` |
| `pytest-rerunfailures` | Retry flaky tests | `pytest --reruns=3 --reruns-delay=1` |
| `pytest-mock` | Mocking wrapper | Provides `mocker` fixture over `unittest.mock` |

## Async Testing Patterns

### pytest-asyncio

```python
import pytest

@pytest.mark.asyncio
async def test_async_fetch(httpx_mock):
    httpx_mock.add_response(json={"status": "ok"})
    async with httpx.AsyncClient() as client:
        resp = await client.get("https://api.example.com/health")
    assert resp.json() == {"status": "ok"}
```

### Auto Mode

Set in `pyproject.toml` to avoid marking every async test:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
```

### Async Fixtures

```python
@pytest.fixture
async def async_db():
    db = await Database.connect("sqlite+aiosqlite:///:memory:")
    yield db
    await db.disconnect()
```

## Snapshot / Approval Testing

### Snapshot Testing (pytest-verify, syrupy, inline-snapshot)

Compare complex outputs against stored snapshots. Update with `--update-snapshots`.

```python
def test_api_response_shape(snapshot):
    result = get_api_response()
    assert result == snapshot
```

**Rules:**
- Mask dynamic fields (timestamps, UUIDs) before snapshotting.
- Keep snapshot files in version control.
- Review diffs before approving updates—never blindly accept.
- Use format-specific serializers (JSON, YAML) for readable diffs.

### Approval Testing (approvaltests)

Golden-master approach for large outputs (HTML reports, CSV exports).

```python
from approvaltests import verify

def test_report_output():
    report = generate_monthly_report()
    verify(report)
```

## Performance

### Parallel Execution with pytest-xdist

```bash
pytest -n auto                    # use all CPU cores
pytest -n 4                       # use 4 workers
pytest -n auto --dist loadscope   # group by module/class
pytest -n auto --dist worksteal   # dynamic work stealing
```

Ensure tests are independent—no shared state, files, or ports between workers.

### Fail Fast

```bash
pytest -x              # stop on first failure
pytest --maxfail=3     # stop after 3 failures
```

### Re-run Targeted Tests

```bash
pytest --lf            # re-run only last-failed tests
pytest --ff            # run last-failed first, then rest
pytest --nf            # run new (not yet seen) tests first
```

### Cache and Stepwise

```bash
pytest --sw            # stop on failure, resume from last failure next run
pytest --cache-clear   # reset pytest cache
```

## Anti-Patterns and Fixes

| Anti-Pattern | Problem | Fix |
|---|---|---|
| Testing mock behavior | Asserts `mock.called` instead of real outcomes | Assert on return values, DB state, or side effects |
| Mocking everything | Removes real behavior, tests pass vacuously | Mock only external boundaries (HTTP, DB, filesystem) |
| Test-only production code | `if testing:` branches pollute prod code | Use dependency injection; pass collaborators as args |
| Shared mutable state | Tests pass alone, fail together | Use fresh fixtures per test; avoid module-level mutables |
| Huge test functions | Hard to diagnose failures | Split into focused tests with descriptive names |
| Ignoring warnings | `PytestUnraisableExceptionWarning` hides bugs | Set `filterwarnings = ["error"]` in config |
| No fixture teardown | Resource leaks across tests | Use `yield` fixtures or `addfinalizer` |
| Asserting on `repr` | Brittle to formatting changes | Assert on attributes or use structured comparison |
| Copy-paste test cases | Duplication, missed edge cases | Use `parametrize` or factory fixtures |
| Sleeping in tests | Slow, flaky | Use `asyncio.Event`, polling with timeout, or mock time |

<!-- tested: pass -->
