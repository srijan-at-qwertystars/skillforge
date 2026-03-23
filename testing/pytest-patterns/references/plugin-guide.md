# Essential Pytest Plugins Guide

## Table of Contents

- [Testing](#testing)
  - [pytest-mock](#pytest-mock)
  - [pytest-cov](#pytest-cov)
  - [pytest-xdist](#pytest-xdist)
  - [pytest-randomly](#pytest-randomly)
  - [pytest-timeout](#pytest-timeout)
- [Web Frameworks](#web-frameworks)
  - [pytest-django](#pytest-django)
  - [pytest-flask](#pytest-flask)
  - [pytest-fastapi (httpx + ASGI)](#pytest-fastapi-httpx--asgi)
  - [pytest-httpserver](#pytest-httpserver)
- [Async](#async)
  - [pytest-asyncio](#pytest-asyncio)
  - [anyio (pytest plugin built-in)](#anyio)
  - [pytest-trio](#pytest-trio)
- [Data & Generation](#data--generation)
  - [pytest-factoryboy](#pytest-factoryboy)
  - [hypothesis](#hypothesis)
  - [syrupy](#syrupy)
- [Reporting & Performance](#reporting--performance)
  - [pytest-html](#pytest-html)
  - [pytest-sugar](#pytest-sugar)
  - [pytest-benchmark](#pytest-benchmark)

---

## Testing

### pytest-mock

Thin `unittest.mock` wrapper providing the `mocker` fixture. Auto-reverts patches after each test.

```bash
pip install pytest-mock
```

**Key config:** None required. Works out of the box.

```python
def test_service_calls_api(mocker):
    mock_get = mocker.patch("myapp.service.requests.get")
    mock_get.return_value.json.return_value = {"status": "ok"}

    result = myapp.service.fetch_status()

    mock_get.assert_called_once_with("https://api.example.com/status")
    assert result == "ok"

# spy: wrap a real function, track calls without replacing behavior
def test_logging(mocker):
    spy = mocker.spy(myapp.service, "log_event")
    myapp.service.process_order(order_id=42)
    spy.assert_called_once_with("order_processed", order_id=42)

# PropertyMock for property attributes
def test_property(mocker):
    mocker.patch.object(type(user), "is_admin", new_callable=mocker.PropertyMock, return_value=True)
    assert user.is_admin

# AsyncMock for async functions
def test_async_fetch(mocker):
    mocker.patch("myapp.client.fetch", new_callable=mocker.AsyncMock, return_value={"data": 1})
```

**Key features:**
- `mocker.patch()` / `mocker.patch.object()` — auto-cleanup
- `mocker.spy()` — wrap real functions, track calls
- `mocker.stub()` — create unnamed stubs
- `mocker.MagicMock`, `mocker.AsyncMock`, `mocker.PropertyMock` — convenient access
- `mocker.stopall()` — stop all patches (rarely needed, automatic on teardown)

---

### pytest-cov

Coverage reporting integrated into pytest. Wraps `coverage.py`.

```bash
pip install pytest-cov
```

**Key config (`pyproject.toml`):**

```toml
[tool.coverage.run]
source = ["src/myapp"]
branch = true
omit = ["*/tests/*", "*/migrations/*"]

[tool.coverage.report]
fail_under = 85
show_missing = true
exclude_lines = [
    "pragma: no cover",
    "if TYPE_CHECKING:",
    "raise NotImplementedError",
]
```

```bash
# Basic usage
pytest --cov=myapp --cov-report=term-missing

# Multiple report formats
pytest --cov=myapp --cov-report=term-missing --cov-report=html --cov-report=xml

# Fail under threshold
pytest --cov=myapp --cov-fail-under=85

# With xdist (needs parallel=true in config)
pytest -n auto --cov=myapp
```

**Key features:**
- `--cov-branch` — branch coverage
- `--cov-report=html` — HTML report in `htmlcov/`
- `--cov-report=xml` — Cobertura XML for CI tools (Codecov, Coveralls)
- `--cov-fail-under=N` — fail if coverage drops below N%
- `--no-cov` — disable coverage (useful for debugging)

---

### pytest-xdist

Parallel test execution across multiple CPUs or machines.

```bash
pip install pytest-xdist
```

**Key config (`pyproject.toml`):**

```toml
[tool.pytest.ini_options]
addopts = "-n auto"  # optional: always run parallel
```

```bash
pytest -n auto                    # auto-detect CPU count
pytest -n 4                       # 4 workers
pytest -n auto --dist loadscope  # group by module/class
pytest -n auto --dist worksteal  # dynamic load balancing
```

**Distribution modes:**

| Mode | Strategy |
|------|----------|
| `load` | Round-robin (default) |
| `loadscope` | Group by module, then class |
| `loadgroup` | Group by `@pytest.mark.xdist_group("name")` |
| `worksteal` | Dynamic stealing from other workers' queues |

**Worker-safe fixtures:**

```python
from filelock import FileLock

@pytest.fixture(scope="session")
def db_schema(tmp_path_factory):
    root = tmp_path_factory.getbasetemp().parent
    with FileLock(str(root / "db.lock")):
        if not (root / "db.done").exists():
            create_schema()
            (root / "db.done").touch()
```

**Key features:**
- `-n auto` — auto-detect CPUs
- `--dist worksteal` — best for mixed-duration tests
- `--maxprocesses=N` — limit worker count
- `@pytest.mark.xdist_group("name")` — force co-location
- Compatible with `pytest-cov` (set `parallel = true` in coverage config)

---

### pytest-randomly

Randomize test execution order to expose hidden dependencies.

```bash
pip install pytest-randomly
```

**Key config (`pyproject.toml`):**

```toml
[tool.pytest.ini_options]
addopts = "-p randomly"
```

```bash
# Run with random order (default when installed)
pytest

# Reproduce a specific order
pytest -p randomly --randomly-seed=12345

# Replay last run's order
pytest -p randomly --randomly-seed=last

# Disable randomization
pytest -p no:randomly
```

**Key features:**
- Randomizes test module order, then test order within modules
- Reseeds `random`, `Faker`, `factory_boy` per test for reproducibility
- Prints seed in output: `Using --randomly-seed=12345`
- `--randomly-dont-shuffle-module` — randomize across modules but not within

---

### pytest-timeout

Prevent tests from hanging indefinitely.

```bash
pip install pytest-timeout
```

**Key config (`pyproject.toml`):**

```toml
[tool.pytest.ini_options]
timeout = 30
timeout_method = "signal"   # "thread" on Windows
```

```python
# Per-test timeout
@pytest.mark.timeout(5)
def test_should_be_fast():
    result = quick_operation()
    assert result is not None

# Disable timeout for specific tests
@pytest.mark.timeout(0)
def test_allowed_to_be_slow():
    ...

# Timeout with method override
@pytest.mark.timeout(10, method="thread")
def test_threaded_timeout():
    ...
```

```bash
# CLI override
pytest --timeout=60
pytest --timeout=0          # disable all timeouts
```

**Timeout methods:**

| Method | Mechanism | Platform |
|--------|-----------|----------|
| `signal` | SIGALRM (most reliable) | Unix only |
| `thread` | Background thread check | Cross-platform |

---

## Web Frameworks

### pytest-django

Full Django integration: DB access, client, settings override, live server.

```bash
pip install pytest-django
```

**Key config (`pyproject.toml`):**

```toml
[tool.pytest.ini_options]
DJANGO_SETTINGS_MODULE = "myproject.settings"
django_find_namespace_packages = true
```

```python
# DB access (required marker)
@pytest.mark.django_db
def test_create_user():
    User.objects.create(username="alice")
    assert User.objects.count() == 1

# Transaction mode for testing rollback/atomic blocks
@pytest.mark.django_db(transaction=True)
def test_atomic_operation():
    ...

# Django test client
def test_homepage(client):
    response = client.get("/")
    assert response.status_code == 200

# Authenticated client
@pytest.fixture
def auth_client(client, django_user_model):
    user = django_user_model.objects.create_user(username="test", password="pass")
    client.force_login(user)
    return client

# Settings override
def test_debug_mode(settings):
    settings.DEBUG = True
    assert settings.DEBUG

# Admin client
def test_admin_page(admin_client):
    response = admin_client.get("/admin/")
    assert response.status_code == 200

# Live server for Selenium/integration
@pytest.mark.django_db
def test_live(live_server):
    url = live_server.url
    response = requests.get(f"{url}/api/health")
    assert response.status_code == 200

# RF (RequestFactory)
def test_view_directly(rf):
    request = rf.get("/fake-url/")
    response = my_view(request)
    assert response.status_code == 200
```

**Key fixtures:** `client`, `admin_client`, `rf`, `settings`, `live_server`, `db`, `transactional_db`, `django_user_model`, `django_assert_num_queries`

---

### pytest-flask

Flask application testing with fixtures.

```bash
pip install pytest-flask
```

```python
# conftest.py
@pytest.fixture
def app():
    app = create_app(testing=True)
    yield app

@pytest.fixture
def client(app):
    return app.test_client()

# Tests
def test_homepage(client):
    response = client.get("/")
    assert response.status_code == 200
    assert b"Welcome" in response.data

def test_api(client):
    response = client.post("/api/items",
        json={"name": "widget"},
        headers={"Authorization": "Bearer token123"})
    assert response.status_code == 201

# Access app config in tests
def test_config(app):
    assert app.config["TESTING"] is True

# Live server
@pytest.mark.usefixtures("live_server")
def test_live(live_server):
    response = requests.get(f"http://localhost:{live_server.port}/")
    assert response.ok
```

**Key fixtures:** `app`, `client`, `live_server`, `request_ctx`, `config`

---

### pytest-fastapi (httpx + ASGI)

No dedicated plugin needed—use `httpx.AsyncClient` with `ASGITransport`.

```bash
pip install httpx
```

```python
# conftest.py
import pytest
from httpx import AsyncClient, ASGITransport
from myapp.main import app

@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c

# Tests
@pytest.mark.asyncio
async def test_read_items(client):
    resp = await client.get("/items")
    assert resp.status_code == 200
    assert isinstance(resp.json(), list)

@pytest.mark.asyncio
async def test_create_item(client):
    resp = await client.post("/items", json={"name": "widget", "price": 9.99})
    assert resp.status_code == 201
    data = resp.json()
    assert data["name"] == "widget"

# Override dependencies
from myapp.main import app, get_db

async def override_get_db():
    async with AsyncSession(test_engine) as session:
        yield session

app.dependency_overrides[get_db] = override_get_db

@pytest.mark.asyncio
async def test_with_test_db(client):
    resp = await client.get("/users")
    assert resp.status_code == 200
```

---

### pytest-httpserver

Starts a real local HTTP server for integration testing.

```bash
pip install pytest-httpserver
```

```python
# Basic usage — fixture auto-provided
def test_api_client(httpserver):
    httpserver.expect_request("/api/data").respond_with_json({"key": "value"})

    client = MyAPIClient(base_url=httpserver.url_for("/"))
    result = client.fetch_data()
    assert result == {"key": "value"}

# Multiple endpoints
def test_workflow(httpserver):
    httpserver.expect_request("/auth", method="POST").respond_with_json(
        {"token": "abc123"}, status=200
    )
    httpserver.expect_request("/data", method="GET").respond_with_json(
        {"items": [1, 2, 3]}, status=200
    )
    run_workflow(httpserver.url_for("/"))

# Ordered requests (must be called in sequence)
def test_ordered(httpserver):
    httpserver.expect_ordered_request("/step1").respond_with_json({"next": "step2"})
    httpserver.expect_ordered_request("/step2").respond_with_json({"done": True})

# Error responses
def test_error_handling(httpserver):
    httpserver.expect_request("/api/data").respond_with_data("Server Error", status=500)
    with pytest.raises(ServiceUnavailableError):
        client.fetch(httpserver.url_for("/api/data"))

# Request body matching
def test_post_body(httpserver):
    httpserver.expect_request("/api/users", method="POST",
        json={"name": "Alice", "role": "admin"}
    ).respond_with_json({"id": 1}, status=201)
```

**Key features:**
- Real HTTP server (not mocked) on localhost
- Request matching by method, path, headers, body, query params
- Ordered request expectations
- SSL support with `httpserver_ssl` fixture
- `httpserver.check_assertions()` — verify all expected requests were made

---

## Async

### pytest-asyncio

Run async tests and fixtures natively in pytest.

```bash
pip install pytest-asyncio
```

**Key config (`pyproject.toml`):**

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"       # auto-detect async tests
# asyncio_mode = "strict"   # require explicit @pytest.mark.asyncio
asyncio_default_fixture_loop_scope = "function"  # or "session", "module"
```

```python
# With auto mode, no decorator needed
async def test_async_operation():
    result = await async_add(1, 2)
    assert result == 3

# Strict mode requires marker
@pytest.mark.asyncio
async def test_explicit():
    result = await fetch_data()
    assert result is not None

# Async fixtures
@pytest.fixture
async def db_connection():
    conn = await asyncpg.connect("postgresql://localhost/test")
    yield conn
    await conn.close()

# Session-scoped async fixture (needs matching loop scope)
@pytest.fixture(scope="session", loop_scope="session")
async def shared_pool():
    pool = await asyncpg.create_pool("postgresql://localhost/test")
    yield pool
    await pool.close()
```

**Key features:**
- `asyncio_mode = "auto"` — no need to mark each async test
- Async fixtures with `yield` for cleanup
- `loop_scope` parameter for fixture-event-loop alignment
- Compatible with `pytest-xdist` (each worker gets its own event loop)

---

### anyio

Backend-agnostic async testing. Tests run on both asyncio and trio.

```bash
pip install anyio
```

**Key config:** None required. The `anyio` pytest plugin is included.

```python
import pytest
import anyio

@pytest.mark.anyio
async def test_concurrent():
    results = []
    async with anyio.create_task_group() as tg:
        tg.start_soon(anyio.sleep, 0.01)
    assert True

# Parametrize across backends
@pytest.fixture(params=["asyncio", "trio"])
def anyio_backend(request):
    return request.param

@pytest.mark.anyio
async def test_multi_backend(anyio_backend):
    await anyio.sleep(0)  # runs on both asyncio and trio

# Async fixtures
@pytest.fixture
async def connection():
    async with open_connection("localhost", 8080) as conn:
        yield conn
```

**Key features:**
- `@pytest.mark.anyio` — backend-agnostic marker
- `anyio_backend` fixture to parametrize across asyncio/trio
- Async fixtures and generators
- Task groups, streams, locks work across backends

---

### pytest-trio

Native trio testing support.

```bash
pip install pytest-trio trio
```

```python
import trio

async def test_trio_nursery():
    results = []

    async def worker(n):
        await trio.sleep(0.01)
        results.append(n)

    async with trio.open_nursery() as nursery:
        for i in range(3):
            nursery.start_soon(worker, i)

    assert len(results) == 3

# Trio fixtures
@pytest.fixture
async def trio_connection():
    stream = await trio.open_tcp_stream("localhost", 8080)
    yield stream
    await stream.aclose()
```

**Key features:**
- Auto-detects async test functions using trio
- Async fixtures with cleanup
- Nursery-based concurrency testing
- Instruments for testing timing-sensitive code

---

## Data & Generation

### pytest-factoryboy

Registers `factory_boy` factories as pytest fixtures.

```bash
pip install pytest-factoryboy factory-boy
```

```python
# factories.py
import factory
from myapp.models import User, Post

class UserFactory(factory.Factory):
    class Meta:
        model = User
    name = factory.Faker("name")
    email = factory.Faker("email")
    role = "viewer"
    class Params:
        admin = factory.Trait(role="admin")

class PostFactory(factory.Factory):
    class Meta:
        model = Post
    title = factory.Faker("sentence")
    author = factory.SubFactory(UserFactory)

# conftest.py
from pytest_factoryboy import register
from .factories import UserFactory, PostFactory

register(UserFactory)                          # → user, user_factory fixtures
register(UserFactory, "admin_user", admin=True) # → admin_user fixture
register(PostFactory)                          # → post, post_factory fixtures
```

```python
# Tests — fixtures auto-available
def test_user_defaults(user):
    assert user.role == "viewer"

def test_admin(admin_user):
    assert admin_user.role == "admin"

def test_post_has_author(post):
    assert post.author is not None

def test_batch(user_factory):
    users = user_factory.create_batch(10)
    assert len(users) == 10

# Override attributes via fixture
@pytest.fixture
def user__name():        # override UserFactory.name
    return "Alice"

def test_named_user(user):
    assert user.name == "Alice"
```

**Key features:**
- `register(Factory)` → creates `<model>` and `<model>_factory` fixtures
- `register(Factory, "name", **overrides)` → named variant fixtures
- Override factory attributes via `<fixture>__<field>` fixtures
- Works with SQLAlchemy (`SQLAlchemyModelFactory`) and Django (`DjangoModelFactory`)

---

### hypothesis

Property-based testing: generate random inputs, find edge cases automatically.

```bash
pip install hypothesis
```

**Key config (`pyproject.toml`):**

```toml
[tool.hypothesis]
# Profiles loaded via settings.load_profile()
```

```python
from hypothesis import given, settings, assume
from hypothesis import strategies as st

# Basic property test
@given(st.lists(st.integers()))
def test_sort_is_idempotent(xs):
    assert sorted(sorted(xs)) == sorted(xs)

# Constrained inputs
@given(st.text(min_size=1, max_size=100, alphabet=st.characters(whitelist_categories=("L",))))
def test_title_case(s):
    result = s.title()
    assert result[0].isupper()

# Composite strategies
@st.composite
def valid_order(draw):
    items = draw(st.lists(st.builds(Item, price=st.floats(0.01, 9999.99)), min_size=1))
    return Order(items=items)

@given(valid_order())
def test_order_total_positive(order):
    assert order.total() > 0

# Settings for CI
@settings(max_examples=500, deadline=None)
@given(st.binary())
def test_roundtrip(data):
    assert decode(encode(data)) == data
```

**Key features:**
- `@given(strategy)` — auto-generates test inputs
- `st.composite` — build complex domain-specific strategies
- `assume()` — filter invalid inputs
- `@example()` — pin specific regression cases
- Stateful testing with `RuleBasedStateMachine`
- Database of failing examples persisted in `.hypothesis/`
- CI profiles: `settings.register_profile("ci", max_examples=1000)`

---

### syrupy

Snapshot testing with format-aware serializers. Stores snapshots next to tests.

```bash
pip install syrupy
```

**Key config:** None required. The `snapshot` fixture is auto-available.

```python
# Basic snapshot
def test_serialization(snapshot):
    user = User(name="Alice", role="admin")
    assert user.to_dict() == snapshot

# JSON extension for API responses
from syrupy.extensions.json import JSONSnapshotExtension

@pytest.fixture
def snapshot_json(snapshot):
    return snapshot.use_extension(JSONSnapshotExtension)

def test_api_response(snapshot_json, client):
    resp = client.get("/api/users/1")
    assert resp.json() == snapshot_json

# Single-file extension (images, SVG, etc.)
from syrupy.extensions.single_file import SingleFileSnapshotExtension

class PNGExtension(SingleFileSnapshotExtension):
    _file_extension = "png"

@pytest.fixture
def snapshot_png(snapshot):
    return snapshot.use_extension(PNGExtension)

def test_chart(snapshot_png):
    chart_bytes = render_chart()
    assert chart_bytes == snapshot_png

# Masking dynamic values
def test_dynamic(snapshot):
    result = create_record()
    result.pop("created_at")   # remove dynamic field before snapshot
    assert result == snapshot
```

```bash
# Update snapshots after intentional changes
pytest --snapshot-update

# Warn about unused (orphaned) snapshots
pytest --snapshot-warn-unused
```

**Key features:**
- `snapshot` fixture — automatic assertion and storage
- Multiple serializer extensions (Amber, JSON, single-file, YAML)
- Custom extensions for any format
- `--snapshot-update` to approve changes
- Stores in `__snapshots__/` alongside test files
- Diffs shown on failure with clear before/after

---

## Reporting & Performance

### pytest-html

Generate standalone HTML test reports.

```bash
pip install pytest-html
```

**Key config (`pyproject.toml`):**

```toml
[tool.pytest.ini_options]
addopts = "--html=report.html --self-contained-html"
```

```bash
pytest --html=report.html --self-contained-html
```

```python
# Add extra info to report
@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    extras = getattr(report, "extras", [])
    if report.when == "call":
        # Add screenshot on failure
        if report.failed:
            extras.append(pytest_html.extras.image(screenshot_path))
        report.extras = extras

# Add metadata to report header
def pytest_html_report_title(report):
    report.title = "My Project Test Report"

def pytest_configure(config):
    config._metadata["Project"] = "MyApp"
    config._metadata["Environment"] = os.getenv("ENV", "local")
```

**Key features:**
- `--self-contained-html` — single HTML file with embedded CSS/JS
- Hook-based customization (extras, metadata, title)
- Attach screenshots, logs, or links to failing tests
- CSS customization via `--css` flag

---

### pytest-sugar

Better terminal output: progress bar, instant failure display, cleaner formatting.

```bash
pip install pytest-sugar
```

**Key config:** None required. Active immediately upon install.

```bash
# Disable temporarily
pytest -p no:sugar

# Works with other plugins
pytest -n auto -p sugar  # combines with xdist
```

**Output features:**
- Progress bar instead of dots
- Failures shown immediately (not at end)
- Color-coded pass/fail/skip
- Cleaner traceback formatting
- Time display per test

---

### pytest-benchmark

Micro-benchmarking with statistical analysis.

```bash
pip install pytest-benchmark
```

```python
# Basic benchmark
def test_sort_performance(benchmark):
    data = list(range(10000, 0, -1))
    result = benchmark(sorted, data)
    assert result[0] == 1

# Benchmark with setup (setup excluded from timing)
def test_db_query(benchmark, db_session):
    def setup():
        populate_db(db_session, n=1000)
        return (db_session,), {}

    def run(session):
        return session.query(User).filter_by(active=True).all()

    result = benchmark.pedantic(run, setup=setup, rounds=10, warmup_rounds=2)
    assert len(result) > 0

# Parametrized benchmarks
@pytest.mark.parametrize("size", [100, 1000, 10000])
def test_scaling(benchmark, size):
    data = list(range(size))
    benchmark(sorted, data)

# Group benchmarks
@pytest.mark.benchmark(group="sorting")
def test_builtin_sort(benchmark):
    benchmark(sorted, data)

@pytest.mark.benchmark(group="sorting")
def test_custom_sort(benchmark):
    benchmark(my_sort, data)
```

```bash
# Run benchmarks
pytest --benchmark-only              # skip non-benchmark tests
pytest --benchmark-disable           # skip benchmarks
pytest --benchmark-sort=mean         # sort by mean time
pytest --benchmark-compare           # compare with saved results
pytest --benchmark-save=baseline     # save results
pytest --benchmark-autosave          # auto-save each run

# Output formats
pytest --benchmark-json=output.json
pytest --benchmark-histogram         # generate histogram image
```

**Key features:**
- `benchmark(func, *args)` — time a callable
- `benchmark.pedantic()` — fine control over rounds, warmup, setup
- Statistical output: min, max, mean, stddev, median, IQR, outliers
- `--benchmark-compare` — compare against saved baselines
- `--benchmark-group-by=param` — group results by parametrize values
- Histogram and JSON output for CI integration

**Config (`pyproject.toml`):**

```toml
[tool.pytest.ini_options]
addopts = "--benchmark-disable"  # disable by default, enable with --benchmark-enable
```
