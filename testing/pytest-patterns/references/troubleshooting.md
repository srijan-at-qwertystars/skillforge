# Pytest Troubleshooting Guide

## Table of Contents

- [Fixture Errors](#fixture-errors)
- [Import Errors and conftest.py Resolution](#import-errors-and-conftestpy-resolution)
- [Async Test Pitfalls](#async-test-pitfalls)
- [Parametrize Issues](#parametrize-issues)
- [Collection Errors and Test Discovery](#collection-errors-and-test-discovery)
- [Slow Test Diagnosis](#slow-test-diagnosis)
- [Mocking Gone Wrong](#mocking-gone-wrong)
- [Plugin Conflicts](#plugin-conflicts)
- [CI-Specific Issues](#ci-specific-issues)

---

## Fixture Errors

### ScopeMismatch

**Error:** `ScopeMismatch: You tried to access a 'function' scoped fixture from a 'session' scoped one.`

A higher-scoped fixture cannot depend on a lower-scoped fixture. Session fixtures outlive function fixtures.

```python
# BROKEN: session-scoped depends on function-scoped
@pytest.fixture(scope="session")
def db(app_config):  # app_config is function-scoped → ScopeMismatch
    ...

# FIX 1: Promote the dependency
@pytest.fixture(scope="session")
def app_config():
    return AppConfig(testing=True)

# FIX 2: Demote the consumer
@pytest.fixture(scope="function")  # match or lower scope
def db(app_config):
    ...
```

**Scope hierarchy:** `session` > `package` > `module` > `class` > `function`

A fixture can only depend on fixtures at the **same or higher** scope.

### Fixture Not Found

**Error:** `fixture 'my_fixture' not found`

Causes and fixes:

| Cause | Fix |
|-------|-----|
| Fixture defined in wrong `conftest.py` | Move to a `conftest.py` at or above the test's directory |
| Fixture in a test file, not conftest | Move to `conftest.py` or import explicitly (not recommended) |
| Typo in fixture name | Check spelling; enable `--strict-markers` |
| Missing plugin | Install the plugin providing the fixture (e.g., `pytest-mock` for `mocker`) |
| conftest.py not collected | Ensure it's named exactly `conftest.py` (not `conftests.py`) |

**Debug:** `pytest --fixtures` lists all available fixtures and their locations.

### Circular Fixture Dependencies

**Error:** `RecursionError` or `fixture ... is already being resolved`

```python
# BROKEN: circular dependency
@pytest.fixture
def user(profile):
    return User(profile=profile)

@pytest.fixture
def profile(user):  # depends on user → circular
    return user.create_profile()

# FIX: Break the cycle with a factory or merge
@pytest.fixture
def user_with_profile():
    user = User()
    profile = Profile(user=user)
    return user, profile
```

### Fixture Teardown Errors

If teardown (code after `yield`) raises, the error is reported but the test result is preserved. Use `addfinalizer` for critical cleanup that must always run.

```python
@pytest.fixture
def resource(request):
    r = acquire_resource()
    # addfinalizer always runs, even if the fixture setup partially fails
    request.addfinalizer(lambda: release_resource(r))
    return r
```

**Multiple yields:** A fixture can only `yield` once. For multiple resources, yield a tuple or use separate fixtures.

### Fixture Finalization Order

Fixtures are torn down in reverse order of their creation. If fixture B depends on fixture A, A's teardown runs after B's. This is usually correct, but be aware if fixtures share external resources.

---

## Import Errors and conftest.py Resolution

### `ModuleNotFoundError` in Tests

**Common cause:** Package not installed in editable mode.

```bash
# Fix: install the project
pip install -e .
# Or add src to sys.path via conftest.py
```

```python
# tests/conftest.py — last resort
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))
```

### conftest.py Discovery Rules

1. pytest collects `conftest.py` files from the **rootdir** downward.
2. Each `conftest.py` applies to its directory and all subdirectories.
3. `conftest.py` files are **not** imported as regular modules—they are loaded by pytest's collection mechanism.
4. You **cannot** import from `conftest.py` in test files (`from conftest import ...` is fragile).

```
project/
├── conftest.py          # applies to ALL tests
├── tests/
│   ├── conftest.py      # applies to tests/ and below
│   ├── unit/
│   │   ├── conftest.py  # applies to unit/ only
│   │   └── test_foo.py
│   └── integration/
│       └── test_bar.py  # gets project/conftest.py + tests/conftest.py
```

### `rootdir` Determination

pytest determines `rootdir` from:
1. CLI args (testpaths)
2. Presence of `pyproject.toml`, `setup.cfg`, or `tox.ini`
3. Common ancestor of specified test paths

**Debug:** First line of pytest output shows `rootdir`. If it's wrong, your tests won't be found.

```bash
pytest --co -q  # dry-run: show which tests would be collected
```

### `__init__.py` in Test Directories

| Layout | `__init__.py` in tests/ | Behavior |
|--------|------------------------|----------|
| Without | No | Test files must have unique names globally |
| With | Yes | Test files can share names across directories |

If you have `tests/unit/test_utils.py` and `tests/integration/test_utils.py`, you need `__init__.py` in both directories to avoid collection conflicts.

### Import Mode

```toml
[tool.pytest.ini_options]
# "importlib" (recommended for modern projects)
# Avoids sys.path manipulation; uses importlib to import test modules
import_mode = "importlib"
```

---

## Async Test Pitfalls

### Event Loop Scope Mismatch

**Error:** `RuntimeError: Event loop is closed` or `ScopeMismatch` with async fixtures.

```python
# BROKEN: session-scoped async fixture with function-scoped event loop
@pytest.fixture(scope="session")
async def shared_conn():  # event loop destroyed between tests
    conn = await connect()
    yield conn
    await conn.close()

# FIX: Match loop scope to fixture scope
# pyproject.toml
[tool.pytest.ini_options]
asyncio_default_fixture_loop_scope = "session"

# Or per-fixture (pytest-asyncio >= 0.23)
@pytest.fixture(scope="session", loop_scope="session")
async def shared_conn():
    conn = await connect()
    yield conn
    await conn.close()
```

### Async Fixture Cleanup Failures

If an async fixture's teardown (post-yield) fails, the error may be swallowed or cause cascading failures.

```python
# BROKEN: cleanup runs on a possibly-closed loop
@pytest.fixture
async def ws_client():
    client = await WebSocketClient.connect("ws://localhost:8000")
    yield client
    await client.close()  # may fail if server is already down

# FIX: Guard the cleanup
@pytest.fixture
async def ws_client():
    client = await WebSocketClient.connect("ws://localhost:8000")
    yield client
    try:
        await asyncio.wait_for(client.close(), timeout=2.0)
    except Exception:
        pass  # best-effort cleanup
```

### anyio vs asyncio Confusion

If you mix `@pytest.mark.asyncio` with anyio-based code (or vice versa), tests may fail silently or use the wrong event loop.

```python
# DON'T: mix markers
@pytest.mark.anyio       # uses anyio runner
async def test_foo():
    await asyncio.sleep(1)  # asyncio-specific → may break on trio

# DO: pick one framework consistently
@pytest.mark.anyio
async def test_foo():
    await anyio.sleep(1)   # backend-agnostic
```

### Unclosed Resources Warning

`ResourceWarning: unclosed <socket>` — async fixtures that don't properly close connections.

```python
# Always use async context managers
@pytest.fixture
async def http_client():
    async with httpx.AsyncClient() as client:
        yield client
    # client.__aexit__ handles cleanup automatically
```

### `PytestUnraisableExceptionWarning`

Async teardown exceptions become "unraisable." Promote to errors:

```toml
[tool.pytest.ini_options]
filterwarnings = [
    "error::pytest.PytestUnraisableExceptionWarning",
]
```

---

## Parametrize Issues

### Unhelpful Test IDs

Default parametrize IDs can be opaque (e.g., `test_foo[arg0-arg1]`).

```python
# UNCLEAR: test_check[0-True] — what do 0 and True mean?
@pytest.mark.parametrize("status, expected", [(0, True), (1, False)])
def test_check(status, expected): ...

# FIX: explicit IDs
@pytest.mark.parametrize("status, expected", [
    pytest.param(0, True, id="success"),
    pytest.param(1, False, id="failure"),
])
def test_check(status, expected): ...
```

### Non-Serializable Parameters

Objects that don't have a useful `repr` produce ugly test IDs.

```python
# FIX: use pytest.param with id
@pytest.mark.parametrize("config", [
    pytest.param(Config(debug=True), id="debug-mode"),
    pytest.param(Config(debug=False), id="prod-mode"),
])
def test_with_config(config): ...
```

### Parametrize + Fixtures Interaction

`@pytest.mark.parametrize` values are resolved **before** fixtures. You can't reference a fixture inside `parametrize` arguments.

```python
# BROKEN: can't use fixture values in parametrize
@pytest.mark.parametrize("n", [db_session.count()])  # db_session not available here
def test_count(n): ...

# FIX: use indirect parametrize or move logic into the test
@pytest.fixture(params=[1, 5, 10])
def item_count(request):
    return request.param

def test_count(item_count, db_session):
    create_items(db_session, item_count)
    assert db_session.query(Item).count() == item_count
```

### Debugging a Specific Parametrized Case

```bash
# Run a specific parametrized case by ID
pytest "tests/test_foo.py::test_check[success]"

# List all parametrized IDs
pytest --collect-only -q tests/test_foo.py::test_check
```

---

## Collection Errors and Test Discovery

### Tests Not Found

**Checklist:**

1. File matches pattern: `test_*.py` or `*_test.py`
2. Function starts with `test_`
3. Class starts with `Test` and has **no** `__init__` method
4. `testpaths` in config points to the right directory
5. File isn't excluded by `--ignore` or `collect_ignore`

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
python_files = ["test_*.py", "*_test.py"]
python_classes = ["Test*"]
python_functions = ["test_*"]
```

### `conftest.py` Causing Collection Errors

Syntax errors or import failures in `conftest.py` prevent collection of all tests in that directory tree.

```bash
# Debug: attempt to import conftest directly
python -c "import tests.conftest"

# Verbose collection
pytest --collect-only -v
```

### Duplicate Test Names

If two test files have the same name without `__init__.py`, pytest may silently shadow one.

```
tests/
├── api/test_utils.py       # collected
└── core/test_utils.py      # SHADOWED — not collected

# Fix: add __init__.py to both api/ and core/
```

### `collect_ignore` and `collect_ignore_glob`

```python
# conftest.py
collect_ignore = ["tests/legacy/"]
collect_ignore_glob = ["tests/*_wip.py"]
```

### Test Discovery Debug Commands

```bash
pytest --collect-only             # show all collected tests
pytest --collect-only -q          # just test IDs
pytest --collect-only --co -q 2>&1 | head -20  # quick preview
```

---

## Slow Test Diagnosis

### `--durations` Flag

```bash
# Show 10 slowest tests
pytest --durations=10

# Show ALL timings including setup/teardown
pytest --durations=0 -v
```

### pytest-profiling

```bash
pip install pytest-profiling

pytest --profile          # generates prof/ directory with cProfile output
pytest --profile-svg      # generate SVG call graph
```

### pytest-benchmark

```bash
pip install pytest-benchmark

def test_sort_performance(benchmark):
    data = list(range(10000, 0, -1))
    result = benchmark(sorted, data)
    assert result == list(range(1, 10001))
```

### Common Slow Test Causes

| Cause | Symptom | Fix |
|-------|---------|-----|
| Network calls in tests | Slow, flaky | Mock HTTP calls with `respx`/`responses` |
| Unnecessary DB setup | Slow fixture setup | Use narrower fixture scope, in-memory DB |
| `time.sleep()` in tests | Artificially slow | Mock time or use events/polling |
| Large test data | Slow parametrize | Reduce data size, use sampling |
| Disk I/O | Slow on CI | Use `tmp_path` (tmpfs on Linux CI), mock filesystem |
| Expensive imports | Slow collection | Lazy imports, refactor heavy modules |
| No parallelism | Linear execution | Use `pytest-xdist -n auto` |

### Marking Slow Tests

```python
@pytest.mark.slow
def test_full_integration():
    ...

# pyproject.toml
[tool.pytest.ini_options]
markers = ["slow: marks tests as slow (deselect with '-m \"not slow\"')"]
```

```bash
# Skip slow tests in local dev
pytest -m "not slow"

# Run everything in CI
pytest
```

### pytest-timeout

```bash
pip install pytest-timeout

# Global timeout
pytest --timeout=30

# Per-test
@pytest.mark.timeout(5)
def test_should_be_fast():
    ...
```

```toml
[tool.pytest.ini_options]
timeout = 30
timeout_method = "signal"  # "thread" on Windows
```

---

## Mocking Gone Wrong

### Patching the Wrong Target

The #1 mocking mistake. Patch where the name is **looked up**, not where it's **defined**.

```python
# myapp/views.py
from myapp.services import send_email

def signup(user):
    send_email(user.email, "Welcome!")

# WRONG: patches the original definition
mocker.patch("myapp.services.send_email")  # views.py already imported it

# RIGHT: patch the reference in the consuming module
mocker.patch("myapp.views.send_email")
```

**Rule:** If `module_a` does `from module_b import func`, patch `module_a.func`.

### autospec Issues

`autospec=True` creates a mock that mirrors the real object's signature. It catches signature mismatches but has edge cases.

```python
# autospec enforces signature
mocker.patch("myapp.views.send_email", autospec=True)
send_email(wrong_arg=True)  # raises TypeError — good!

# But: autospec can fail on descriptors, properties, and classmethods
# If you get odd errors with autospec, try spec_set or spec instead:
mocker.patch("myapp.views.MyClass", spec_set=MyClass)
```

### Mock Leaking Between Tests

If a mock isn't properly scoped, it can bleed into other tests.

```python
# BROKEN: module-level patch persists across tests
unittest.mock.patch("myapp.config.DEBUG", True).start()
# If .stop() is never called, all subsequent tests see DEBUG=True

# FIX: Use pytest-mock's `mocker` fixture — auto-reverts after each test
def test_debug_mode(mocker):
    mocker.patch("myapp.config.DEBUG", True)
    # Automatically undone after test
```

### Asserting Mock Calls

```python
# Fragile: order-dependent assertion
mock.assert_has_calls([call("a"), call("b")], any_order=False)

# Better: assert on specific calls without order dependency
assert mock.call_args_list == [call("a"), call("b")]

# Best: assert on behavior, not implementation
result = do_thing()
assert result.status == "ok"
```

### `MagicMock` Absorbing Attribute Access

`MagicMock` returns a new mock for **any** attribute access. This silently passes tests that should fail.

```python
mock = MagicMock()
mock.nonexistent_method()  # no error! Returns another MagicMock

# FIX: use spec to restrict attributes
mock = MagicMock(spec=RealClass)
mock.nonexistent_method()  # raises AttributeError
```

### `AsyncMock` vs `MagicMock`

```python
# BROKEN: MagicMock for async function — returns MagicMock, not a coroutine
mocker.patch("myapp.client.fetch", return_value={"data": "ok"})
await fetch()  # TypeError: 'dict' not awaitable

# FIX: Use AsyncMock
from unittest.mock import AsyncMock
mocker.patch("myapp.client.fetch", new_callable=AsyncMock, return_value={"data": "ok"})
```

---

## Plugin Conflicts

### Diagnosing Plugin Conflicts

```bash
# List all installed plugins
pytest --co -q 2>&1 | head -5  # shows plugin summary
pip list | grep pytest          # all installed pytest packages

# Disable all plugins, then enable one-by-one
pytest -p no:randomly -p no:cov -p no:xdist

# Disable a specific plugin
pytest -p no:randomly
```

### Common Conflicts

| Conflict | Symptom | Fix |
|----------|---------|-----|
| `pytest-asyncio` + `anyio` | Duplicate async markers, wrong event loop | Use only one. `anyio` fixture already provides async support. |
| `pytest-xdist` + `pytest-cov` | Missing coverage data | Set `parallel = true` in `[tool.coverage.run]` |
| `pytest-randomly` + order-dependent tests | Tests fail in random order | Fix the tests (they have hidden dependencies) or mark `@pytest.mark.order` |
| `pytest-django` + `pytest-asyncio` | DB access in async tests fails | Use `@pytest.mark.django_db(transaction=True)` with async tests |
| Multiple conftest plugins | Hook ordering issues | Use `@pytest.hookimpl(tryfirst=True)` or `trylast=True` |

### Plugin Load Order

Plugins load in this order:
1. Built-in plugins
2. External plugins (installed via pip, sorted by name)
3. conftest.py plugins (root first, then deeper directories)

Use `pytest_plugin_registered` hook to debug load order:

```python
# conftest.py
def pytest_plugin_registered(plugin, manager):
    print(f"Plugin registered: {plugin}")
```

### Forcing Plugin Order

```python
# conftest.py
pytest_plugins = ["my_plugin_a", "my_plugin_b"]  # load in this order
```

### Environment Variable Conflicts

Some plugins read environment variables that conflict:

```bash
# pytest-randomly reads PYTHONHASHSEED
# pytest-xdist sets PYTEST_XDIST_WORKER
# pytest-django reads DJANGO_SETTINGS_MODULE

# Debug: dump env in conftest
def pytest_configure(config):
    import os
    for key in sorted(os.environ):
        if "PYTEST" in key or "DJANGO" in key:
            print(f"  {key}={os.environ[key]}")
```

---

## CI-Specific Issues

### Output Buffering

CI systems often capture stdout/stderr differently. Tests that rely on print output may behave differently.

```bash
# Force unbuffered output
pytest -s                        # disable output capture
pytest --capture=no              # same as -s
pytest --tb=short                # shorter tracebacks for CI readability

# Or in config
[tool.pytest.ini_options]
addopts = "--tb=short -q"
```

### tmpdir / tmp_path Issues

CI environments may have different tmpdir locations, permissions, or filesystem types.

```python
# BROKEN: hardcoded temp paths
TEMP_FILE = "/tmp/test_output.txt"

# FIX: always use tmp_path fixture
def test_file_output(tmp_path):
    output = tmp_path / "output.txt"
    generate_output(output)
    assert output.read_text() == "expected"

# For session-scoped temp dirs
@pytest.fixture(scope="session")
def shared_tmp(tmp_path_factory):
    return tmp_path_factory.mktemp("shared")
```

### Parallel Execution Flakes in CI

Tests pass locally but fail in CI with `pytest-xdist` due to resource contention.

| Problem | Fix |
|---------|-----|
| Port conflicts | Use `0` for port (OS assigns free port) or `portpicker` |
| File locking | Use `tmp_path` per-test; `filelock` for shared setup |
| Database races | Per-worker databases or transaction isolation |
| Time-dependent | Mock `time.time()` or `datetime.now()` |
| Non-deterministic order | Run `pytest --randomly-seed=12345` to reproduce |

### GitHub Actions–Specific

```yaml
- name: Run tests
  run: |
    pytest -x -q --tb=short \
      --junitxml=results.xml \
      --timeout=120 \
      -n auto
  env:
    PYTHONDONTWRITEBYTECODE: 1

- name: Upload test results
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: test-results
    path: results.xml
```

### Handling Flaky Tests

```python
# pytest-rerunfailures: retry flaky tests
# pip install pytest-rerunfailures
pytest --reruns=3 --reruns-delay=2

# Mark individual tests
@pytest.mark.flaky(reruns=3, reruns_delay=1)
def test_external_service():
    ...
```

### Timezone Issues

```python
# Tests pass locally (PST) but fail in CI (UTC)
# FIX: always set timezone in CI
env:
  TZ: UTC

# Or freeze time in tests
from freezegun import freeze_time

@freeze_time("2024-01-15 12:00:00", tz_offset=0)
def test_date_logic():
    assert get_greeting() == "Good afternoon"
```

### Memory Issues in CI

```bash
# CI runners have limited memory
# Limit xdist workers
pytest -n 2  # not -n auto on small CI runners

# Garbage-collect between tests
@pytest.fixture(autouse=True)
def _gc_between_tests():
    yield
    import gc
    gc.collect()
```

### Reproducibility

```bash
# Pin random seed for reproducibility
pytest -p randomly --randomly-seed=12345

# Print seed in output (default behavior with pytest-randomly)
# "Using --randomly-seed=12345"

# Reproduce last run
pytest -p randomly --randomly-seed=last
```

### JUnit XML for CI Integration

```toml
[tool.pytest.ini_options]
addopts = "--junitxml=test-results/results.xml"
junit_family = "xunit2"
junit_logging = "all"
junit_log_passing_tests = false
```
