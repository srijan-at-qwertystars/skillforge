# Advanced Pytest Patterns

## Table of Contents

- [Property-Based Testing with Hypothesis](#property-based-testing-with-hypothesis)
- [Snapshot / Approval Testing](#snapshot--approval-testing)
- [Mutation Testing with mutmut](#mutation-testing-with-mutmut)
- [Test Factories](#test-factories)
- [Async Testing Deep Dive](#async-testing-deep-dive)
- [Database Testing Patterns](#database-testing-patterns)
- [API Testing Patterns](#api-testing-patterns)
- [BDD with pytest-bdd](#bdd-with-pytest-bdd)
- [Custom Pytest Plugin Development](#custom-pytest-plugin-development)
- [Test Coverage Strategies](#test-coverage-strategies)
- [Parallel Execution](#parallel-execution)

---

## Property-Based Testing with Hypothesis

Hypothesis generates random inputs to find edge cases your unit tests miss. Instead of specifying examples, you describe the *shape* of valid inputs and let the engine explore.

### Install

```bash
pip install hypothesis
```

### Core Strategies

```python
from hypothesis import given, settings, assume, example
from hypothesis import strategies as st

# Basic: integers, text, floats
@given(st.integers(), st.integers())
def test_addition_commutative(a, b):
    assert a + b == b + a

# Constrained strategies
@given(st.integers(min_value=1, max_value=1000))
def test_positive_square(n):
    assert n * n > 0

# Text with alphabet control
@given(st.text(alphabet=st.characters(whitelist_categories=("L", "N")), min_size=1))
def test_slugify_no_empty(s):
    result = slugify(s)
    assert isinstance(result, str)

# Composite strategies for domain objects
@st.composite
def user_strategy(draw):
    name = draw(st.text(min_size=1, max_size=50))
    age = draw(st.integers(min_value=0, max_value=150))
    email = draw(st.emails())
    return {"name": name, "age": age, "email": email}

@given(user_strategy())
def test_user_serialization_roundtrip(user_data):
    user = User(**user_data)
    serialized = user.to_dict()
    restored = User.from_dict(serialized)
    assert restored.name == user.name
    assert restored.age == user.age
```

### Settings and Profiles

```python
from hypothesis import settings, Phase, HealthCheck

# Per-test settings
@settings(max_examples=500, deadline=None)
@given(st.binary())
def test_compression_roundtrip(data):
    assert decompress(compress(data)) == data

# Profiles for CI vs local
settings.register_profile("ci", max_examples=1000, deadline=None)
settings.register_profile("dev", max_examples=50)
settings.load_profile(os.getenv("HYPOTHESIS_PROFILE", "dev"))
```

### Stateful Testing

Model complex stateful systems with `RuleBasedStateMachine`.

```python
from hypothesis.stateful import RuleBasedStateMachine, rule, precondition, invariant

class SetModel(RuleBasedStateMachine):
    def __init__(self):
        super().__init__()
        self.model = set()
        self.real = MyCustomSet()

    @rule(value=st.integers())
    def add(self, value):
        self.model.add(value)
        self.real.add(value)

    @rule(value=st.integers())
    def discard(self, value):
        self.model.discard(value)
        self.real.discard(value)

    @invariant()
    def sets_match(self):
        assert set(self.real) == self.model

TestSetModel = SetModel.TestCase
```

### Integration with pytest

```python
# hypothesis plays well with fixtures
@given(data=st.data())
def test_db_insert(db_session, data):
    name = data.draw(st.text(min_size=1, max_size=100))
    user = User(name=name)
    db_session.add(user)
    db_session.flush()
    assert db_session.query(User).filter_by(name=name).first() is not None

# Use assume() to filter invalid combinations
@given(st.floats(), st.floats())
def test_division(a, b):
    assume(b != 0)
    assume(not (math.isinf(a) or math.isinf(b)))
    result = a / b
    assert math.isclose(result * b, a, rel_tol=1e-9) or a == 0
```

### Key Strategies Reference

| Strategy | Generates | Example |
|----------|-----------|---------|
| `st.integers()` | Arbitrary ints | `st.integers(min_value=0)` |
| `st.floats()` | Floats incl NaN/inf | `st.floats(allow_nan=False)` |
| `st.text()` | Unicode strings | `st.text(min_size=1)` |
| `st.binary()` | Byte strings | `st.binary(max_size=1024)` |
| `st.lists()` | Lists of strategy | `st.lists(st.integers(), min_size=1)` |
| `st.dictionaries()` | Dicts | `st.dictionaries(st.text(), st.integers())` |
| `st.one_of()` | Union of strategies | `st.one_of(st.none(), st.integers())` |
| `st.builds()` | Construct objects | `st.builds(User, name=st.text())` |
| `st.from_type()` | From type annotations | `st.from_type(MyDataclass)` |
| `st.emails()` | Valid emails | — |
| `st.datetimes()` | datetime objects | `st.datetimes(min_value=datetime(2020,1,1))` |
| `st.sampled_from()` | Pick from sequence | `st.sampled_from(["a", "b", "c"])` |

---

## Snapshot / Approval Testing

### syrupy (Recommended)

Inline snapshot assertions with format-aware serializers. Stores snapshots in `__snapshots__/` directories.

```bash
pip install syrupy
```

```python
# syrupy provides the `snapshot` fixture automatically
def test_user_dict(snapshot):
    user = User(name="Alice", role="admin")
    assert user.to_dict() == snapshot

# JSON serializer for API responses
from syrupy.extensions.json import JSONSnapshotExtension

@pytest.fixture
def snapshot_json(snapshot):
    return snapshot.use_extension(JSONSnapshotExtension)

def test_api_response(snapshot_json):
    resp = client.get("/api/users/1")
    assert resp.json() == snapshot_json
```

#### Masking Dynamic Fields

```python
def test_created_response(snapshot):
    result = create_item(name="widget")
    # Replace dynamic values before snapshot comparison
    result["id"] = "<UUID>"
    result["created_at"] = "<TIMESTAMP>"
    assert result == snapshot
```

#### Custom Serializers

```python
from syrupy.extensions.single_file import SingleFileSnapshotExtension

class SVGSnapshotExtension(SingleFileSnapshotExtension):
    _file_extension = "svg"

@pytest.fixture
def snapshot_svg(snapshot):
    return snapshot.use_extension(SVGSnapshotExtension)

def test_chart_svg(snapshot_svg):
    svg_content = render_chart(data)
    assert svg_content == snapshot_svg
```

#### Commands

```bash
pytest --snapshot-update   # update all snapshots
pytest --snapshot-warn-unused  # warn about orphaned snapshots
```

### pytest-snapshot

Simpler file-based snapshots. Good when you want explicit file paths.

```bash
pip install pytest-snapshot
```

```python
def test_report(snapshot):
    report = generate_report()
    snapshot.assert_match(report, "expected_report.txt")
```

### inline-snapshot

Snapshots stored directly in source code. Great for small values.

```bash
pip install inline-snapshot
```

```python
from inline_snapshot import snapshot

def test_greeting():
    assert greet("Alice") == snapshot("Hello, Alice!")  # auto-fills on first run
```

---

## Mutation Testing with mutmut

Mutmut modifies your source code (mutants) and re-runs tests. If tests still pass after a mutation, you have a coverage gap.

### Install and Run

```bash
pip install mutmut

# Run against all tests
mutmut run

# Target specific source
mutmut run --paths-to-mutate=src/myapp/core.py

# Use specific test command
mutmut run --tests-dir=tests/ --runner="pytest -x -q"
```

### Analyze Results

```bash
mutmut results          # summary of survived/killed
mutmut show 42          # show specific survived mutant
mutmut html             # generate HTML report

# Apply a mutant to inspect it
mutmut apply 42
# then revert
mutmut apply 0
```

### Configuration (pyproject.toml)

```toml
[tool.mutmut]
paths_to_mutate = "src/myapp/"
tests_dir = "tests/"
runner = "python -m pytest -x -q --tb=no"
dict_synonyms = "Struct, NamedStruct"
```

### Interpreting Results

| Status | Meaning | Action |
|--------|---------|--------|
| Killed | Mutant detected by tests | Good—test suite caught the change |
| Survived | Tests pass despite mutation | Add or strengthen test assertions |
| Timeout | Mutant caused infinite loop | Usually fine—means code change was caught |
| Suspicious | Test result was ambiguous | Investigate manually |

### Common Surviving Mutations

```python
# Mutation: changed `>` to `>=`
# If this survives, you lack a boundary test
def is_adult(age):
    return age > 18  # mutant: age >= 18

# Fix: add boundary test
def test_is_adult_boundary():
    assert not is_adult(18)
    assert is_adult(19)
```

---

## Test Factories

### factory_boy

Declarative test data factories with database integration.

```bash
pip install factory-boy
```

```python
import factory
from myapp.models import User, Address

class AddressFactory(factory.Factory):
    class Meta:
        model = Address

    street = factory.Faker("street_address")
    city = factory.Faker("city")
    country = factory.LazyFunction(lambda: "US")

class UserFactory(factory.Factory):
    class Meta:
        model = User

    name = factory.Faker("name")
    email = factory.LazyAttribute(lambda obj: f"{obj.name.lower().replace(' ', '.')}@example.com")
    role = "viewer"
    address = factory.SubFactory(AddressFactory)
    created_at = factory.LazyFunction(datetime.utcnow)

# Sequences for unique values
class OrganizationFactory(factory.Factory):
    class Meta:
        model = Organization

    name = factory.Sequence(lambda n: f"Org-{n}")
    slug = factory.LazyAttribute(lambda obj: obj.name.lower())
```

#### Traits for Variants

```python
class UserFactory(factory.Factory):
    class Meta:
        model = User

    name = factory.Faker("name")
    role = "viewer"
    is_active = True

    class Params:
        admin = factory.Trait(role="admin")
        inactive = factory.Trait(is_active=False)

# Usage
admin = UserFactory(admin=True)
inactive_user = UserFactory(inactive=True)
inactive_admin = UserFactory(admin=True, inactive=True)
```

#### SQLAlchemy Integration

```python
from factory.alchemy import SQLAlchemyModelFactory

class UserFactory(SQLAlchemyModelFactory):
    class Meta:
        model = User
        sqlalchemy_session = None  # set in fixture

    name = factory.Faker("name")

@pytest.fixture
def user_factory(db_session):
    UserFactory._meta.sqlalchemy_session = db_session
    return UserFactory
```

### pytest-factoryboy

Register factory_boy factories as pytest fixtures automatically.

```bash
pip install pytest-factoryboy
```

```python
# conftest.py
from pytest_factoryboy import register

register(UserFactory)       # creates `user` and `user_factory` fixtures
register(UserFactory, "admin_user", admin=True)  # named variant

# tests
def test_user_default(user):
    assert user.role == "viewer"

def test_admin(admin_user):
    assert admin_user.role == "admin"

def test_batch(user_factory):
    users = user_factory.create_batch(5)
    assert len(users) == 5
```

### Faker Integration

```python
from faker import Faker

fake = Faker()
Faker.seed(42)  # reproducible data

@pytest.fixture
def random_user_data():
    return {
        "name": fake.name(),
        "email": fake.email(),
        "address": fake.address(),
        "phone": fake.phone_number(),
        "bio": fake.paragraph(nb_sentences=3),
    }
```

---

## Async Testing Deep Dive

### pytest-asyncio Modes

```toml
# pyproject.toml
[tool.pytest.ini_options]
asyncio_mode = "auto"    # auto-detect async tests (recommended)
# asyncio_mode = "strict"  # require explicit @pytest.mark.asyncio
```

#### Mode Comparison

| Mode | Behavior | Use When |
|------|----------|----------|
| `strict` | Must mark each async test with `@pytest.mark.asyncio` | Mixed sync/async projects, explicit control |
| `auto` | All async functions auto-detected as async tests | Mostly-async projects, less boilerplate |

### Event Loop Scope

```python
# Per-session event loop (shared across all tests)
@pytest.fixture(scope="session")
def event_loop_policy():
    return asyncio.DefaultEventLoopPolicy()

# Since pytest-asyncio 0.23+, use loop_scope
@pytest.fixture(loop_scope="session")
async def shared_connection():
    conn = await create_connection()
    yield conn
    await conn.close()

# pyproject.toml approach
[tool.pytest.ini_options]
asyncio_default_fixture_loop_scope = "function"  # or "session", "module"
```

### Async Fixtures

```python
@pytest.fixture
async def async_client():
    async with httpx.AsyncClient(app=app, base_url="http://test") as client:
        yield client

@pytest.fixture
async def populated_db(async_session):
    users = [User(name=f"user_{i}") for i in range(10)]
    async_session.add_all(users)
    await async_session.commit()
    return users
```

### anyio for Backend-Agnostic Testing

Test code that runs on both asyncio and trio.

```bash
pip install anyio pytest-anyio
```

```python
import pytest
import anyio

@pytest.mark.anyio
async def test_concurrent_tasks():
    results = []
    async with anyio.create_task_group() as tg:
        for i in range(3):
            tg.start_soon(worker, i, results)
    assert len(results) == 3

# Parametrize across backends
@pytest.fixture(params=["asyncio", "trio"])
def anyio_backend(request):
    return request.param
```

### trio with pytest-trio

```bash
pip install trio pytest-trio
```

```python
import trio

async def test_trio_task():
    async with trio.open_nursery() as nursery:
        nursery.start_soon(my_background_task)
```

### Async Testing Patterns

```python
# Testing timeouts
@pytest.mark.asyncio
async def test_timeout_behavior():
    with pytest.raises(asyncio.TimeoutError):
        await asyncio.wait_for(slow_operation(), timeout=0.1)

# Testing cancellation
@pytest.mark.asyncio
async def test_cancellation_cleanup():
    task = asyncio.create_task(long_running())
    await asyncio.sleep(0.01)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

# Mock async dependencies
@pytest.mark.asyncio
async def test_async_service(mocker):
    mocker.patch("myapp.client.fetch", new_callable=AsyncMock,
                 return_value={"status": "ok"})
    result = await my_service.process()
    assert result.status == "ok"
```

---

## Database Testing Patterns

### pytest-django

```bash
pip install pytest-django
```

```python
# pyproject.toml
[tool.pytest.ini_options]
DJANGO_SETTINGS_MODULE = "myproject.settings"
```

```python
import pytest
from myapp.models import Article

@pytest.mark.django_db
def test_create_article():
    article = Article.objects.create(title="Test", body="Content")
    assert Article.objects.count() == 1

# Transaction test case for testing rollback behavior
@pytest.mark.django_db(transaction=True)
def test_atomic_operation():
    with pytest.raises(IntegrityError):
        with transaction.atomic():
            Article.objects.create(title=None)  # violates NOT NULL
    assert Article.objects.count() == 0

# Access DB in fixtures
@pytest.fixture
@pytest.mark.django_db
def sample_articles(db):
    return [Article.objects.create(title=f"Article {i}") for i in range(5)]
```

### SQLAlchemy Fixtures with Transaction Rollback

Session-scoped engine, function-scoped sessions with automatic rollback for test isolation.

```python
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session

@pytest.fixture(scope="session")
def engine():
    engine = create_engine("postgresql://test:test@localhost/testdb")
    Base.metadata.create_all(engine)
    yield engine
    Base.metadata.drop_all(engine)
    engine.dispose()

@pytest.fixture
def db_session(engine):
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)
    yield session
    session.close()
    transaction.rollback()
    connection.close()

# Nested transactions for savepoint-based isolation
@pytest.fixture
def db_session_nested(engine):
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)
    # Nested savepoints for tests that call session.commit()
    session.begin_nested()

    @event.listens_for(session, "after_transaction_end")
    def restart_savepoint(session, trans):
        if trans.nested and not trans._parent.nested:
            session.begin_nested()

    yield session
    session.close()
    transaction.rollback()
    connection.close()
```

### Async SQLAlchemy (asyncpg / aiosqlite)

```python
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession

@pytest.fixture(scope="session")
async def async_engine():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    await engine.dispose()

@pytest.fixture
async def async_db(async_engine):
    async with AsyncSession(async_engine) as session:
        async with session.begin():
            yield session
            await session.rollback()
```

### Testing with Test Databases

```python
# conftest.py — create/drop test database
@pytest.fixture(scope="session")
def test_db():
    db_name = f"test_{uuid4().hex[:8]}"
    admin_engine = create_engine("postgresql://localhost/postgres")
    with admin_engine.connect() as conn:
        conn.execution_options(isolation_level="AUTOCOMMIT")
        conn.execute(text(f"CREATE DATABASE {db_name}"))
    yield f"postgresql://localhost/{db_name}"
    with admin_engine.connect() as conn:
        conn.execution_options(isolation_level="AUTOCOMMIT")
        conn.execute(text(f"DROP DATABASE {db_name}"))
    admin_engine.dispose()
```

---

## API Testing Patterns

### httpx with respx (Mocking httpx)

```bash
pip install httpx respx
```

```python
import httpx
import respx

# Decorator style
@respx.mock
def test_external_api():
    respx.get("https://api.example.com/users/1").mock(
        return_value=httpx.Response(200, json={"id": 1, "name": "Alice"})
    )
    resp = httpx.get("https://api.example.com/users/1")
    assert resp.json()["name"] == "Alice"

# Context manager style
def test_api_error_handling():
    with respx.mock:
        respx.get("https://api.example.com/users/1").mock(
            return_value=httpx.Response(500)
        )
        with pytest.raises(ServiceError):
            fetch_user(1)

# Pattern matching
@respx.mock
def test_api_batch():
    route = respx.get(url__regex=r"https://api\.example\.com/users/\d+").mock(
        return_value=httpx.Response(200, json={"status": "ok"})
    )
    fetch_all_users([1, 2, 3])
    assert route.call_count == 3

# Side effects
@respx.mock
def test_retry_logic():
    route = respx.get("https://api.example.com/data")
    route.side_effect = [
        httpx.Response(503),
        httpx.Response(503),
        httpx.Response(200, json={"data": "ok"}),
    ]
    result = fetch_with_retry("https://api.example.com/data", retries=3)
    assert result == {"data": "ok"}
```

### Async httpx Mocking

```python
@respx.mock
@pytest.mark.asyncio
async def test_async_api():
    respx.get("https://api.example.com/items").mock(
        return_value=httpx.Response(200, json=[{"id": 1}])
    )
    async with httpx.AsyncClient() as client:
        resp = await client.get("https://api.example.com/items")
    assert len(resp.json()) == 1
```

### pytest-httpserver (Real HTTP Server)

Spins up a real local HTTP server—useful when you need actual network I/O.

```bash
pip install pytest-httpserver
```

```python
def test_real_http(httpserver):
    httpserver.expect_request("/api/health").respond_with_json({"status": "ok"})
    resp = httpx.get(httpserver.url_for("/api/health"))
    assert resp.json()["status"] == "ok"

# Ordered requests
def test_ordered_requests(httpserver):
    httpserver.expect_ordered_request("/step1").respond_with_json({"next": "/step2"})
    httpserver.expect_ordered_request("/step2").respond_with_json({"done": True})
    run_workflow(httpserver.url_for("/step1"))

# Custom matchers
from werkzeug.wrappers import Request

def test_request_body(httpserver):
    httpserver.expect_request(
        "/api/users",
        method="POST",
        json={"name": "Alice"},
    ).respond_with_json({"id": 1}, status=201)
    resp = httpx.post(httpserver.url_for("/api/users"), json={"name": "Alice"})
    assert resp.status_code == 201
```

### ASGI/WSGI App Testing

Test FastAPI/Starlette apps without a real server using `httpx.AsyncClient` transport.

```python
from httpx import AsyncClient, ASGITransport
from myapp import app

@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c

@pytest.mark.asyncio
async def test_create_item(client):
    resp = await client.post("/items", json={"name": "widget"})
    assert resp.status_code == 201
    assert resp.json()["name"] == "widget"
```

---

## BDD with pytest-bdd

Behavior-driven development: write tests as Gherkin feature files, implement with Python step definitions.

```bash
pip install pytest-bdd
```

### Feature File

```gherkin
# tests/features/auth.feature
Feature: User Authentication

  Scenario: Successful login
    Given a registered user "alice" with password "secret123"
    When the user logs in with "alice" and "secret123"
    Then the response status is 200
    And the response contains a valid token

  Scenario Outline: Invalid login
    Given a registered user "alice" with password "secret123"
    When the user logs in with "<username>" and "<password>"
    Then the response status is 401

    Examples:
      | username | password   |
      | alice    | wrong      |
      | bob      | secret123  |
      | alice    |            |
```

### Step Definitions

```python
# tests/step_defs/test_auth.py
from pytest_bdd import scenarios, given, when, then, parsers

scenarios("../features/auth.feature")

@given(parsers.parse('a registered user "{name}" with password "{password}"'))
def registered_user(db_session, name, password):
    user = User(name=name)
    user.set_password(password)
    db_session.add(user)
    db_session.commit()
    return user

@when(parsers.parse('the user logs in with "{username}" and "{password}"'),
      target_fixture="login_response")
def login(client, username, password):
    return client.post("/auth/login", json={"username": username, "password": password})

@then(parsers.parse("the response status is {status:d}"))
def check_status(login_response, status):
    assert login_response.status_code == status

@then("the response contains a valid token")
def check_token(login_response):
    data = login_response.json()
    assert "token" in data
    assert len(data["token"]) > 0
```

### Fixture Integration

```python
# Reuse existing pytest fixtures in BDD steps
@given("an authenticated admin client", target_fixture="admin_client")
def admin_client(client, admin_user):
    token = create_token(admin_user)
    client.headers["Authorization"] = f"Bearer {token}"
    return client
```

---

## Custom Pytest Plugin Development

### Hook-Based Plugin (conftest.py or installable)

```python
# conftest.py or myplugin.py
import pytest
import time

def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line("markers", "gpu: requires GPU")

def pytest_collection_modifyitems(config, items):
    """Skip GPU tests unless --gpu flag is set."""
    if not config.getoption("--gpu", default=False):
        skip_gpu = pytest.mark.skip(reason="need --gpu to run")
        for item in items:
            if "gpu" in item.keywords:
                item.add_marker(skip_gpu)

def pytest_addoption(parser):
    parser.addoption("--gpu", action="store_true", default=False)

@pytest.hookimpl(tryfirst=True)
def pytest_runtest_makereport(item, call):
    """Attach extra info to test report."""
    if call.when == "call" and call.excinfo is not None:
        item.user_properties.append(("failure_time", time.time()))
```

### Fixture-Based Plugin

```python
# pytest_timing_plugin.py
import pytest
import time

@pytest.fixture(autouse=True)
def _time_each_test(request):
    start = time.perf_counter()
    yield
    duration = time.perf_counter() - start
    if duration > 1.0:
        print(f"\n⚠️  SLOW TEST: {request.node.nodeid} took {duration:.2f}s")
```

### Installable Plugin (entry point)

```toml
# pyproject.toml for the plugin package
[project]
name = "pytest-mycompany"
version = "0.1.0"
[project.entry-points.pytest11]
mycompany = "pytest_mycompany.plugin"
```

```python
# pytest_mycompany/plugin.py
import pytest

def pytest_report_header(config):
    return "MyCompany Test Suite v2.0"

@pytest.fixture
def company_api_client():
    """Provides a pre-configured API client for internal services."""
    client = CompanyAPIClient(base_url=os.getenv("API_URL", "http://localhost:8000"))
    yield client
    client.close()
```

### Useful Hooks Reference

| Hook | When | Use For |
|------|------|---------|
| `pytest_configure` | Startup | Register markers, set config |
| `pytest_addoption` | Startup | Add CLI options |
| `pytest_collection_modifyitems` | After collection | Filter, reorder, skip tests |
| `pytest_runtest_setup` | Before each test | Custom setup logic |
| `pytest_runtest_makereport` | After each phase | Custom reporting, artifacts |
| `pytest_terminal_summary` | End of session | Print custom summaries |
| `pytest_sessionfinish` | Session end | Cleanup, upload results |

---

## Test Coverage Strategies

### coverage.py Configuration

```toml
# pyproject.toml
[tool.coverage.run]
source = ["src/myapp"]
branch = true                    # measure branch coverage, not just line
parallel = true                  # support for pytest-xdist
omit = [
    "*/migrations/*",
    "*/tests/*",
    "*/__main__.py",
    "*/conftest.py",
]

[tool.coverage.report]
fail_under = 85
show_missing = true
skip_covered = true              # hide 100%-covered files in terminal output
exclude_lines = [
    "pragma: no cover",
    "def __repr__",
    "if TYPE_CHECKING:",
    "if __name__ == .__main__.",
    "raise NotImplementedError",
    "pass",
    "@abstractmethod",
]
exclude_also = [
    "class .*\\(Protocol\\):",
    "@overload",
]

[tool.coverage.html]
directory = "htmlcov"
```

### pytest-cov Usage

```bash
# Basic
pytest --cov=myapp --cov-report=term-missing

# Multiple report formats
pytest --cov=myapp --cov-report=term-missing --cov-report=html --cov-report=xml

# Fail under threshold
pytest --cov=myapp --cov-fail-under=85

# With branch coverage
pytest --cov=myapp --cov-branch
```

### Branch Coverage

Line coverage misses untested branches. Branch coverage ensures both `if` and `else` paths are exercised.

```python
# 100% line coverage but 50% branch coverage if only True tested
def check_access(user):
    if user.is_admin:
        return "full"
    return "limited"       # branch: this line needs a non-admin test too

# Test both branches
def test_admin_access():
    assert check_access(User(is_admin=True)) == "full"

def test_limited_access():
    assert check_access(User(is_admin=False)) == "limited"
```

### Coverage in CI

```yaml
# .github/workflows/test.yml
- name: Test with coverage
  run: pytest --cov=myapp --cov-report=xml --cov-fail-under=85
- name: Upload coverage
  uses: codecov/codecov-action@v4
  with:
    files: coverage.xml
```

### Context-Aware Coverage

Track which test covers which line:

```toml
[tool.coverage.run]
dynamic_context = "test_function"
```

```bash
pytest --cov=myapp
coverage html --show-contexts  # HTML shows which test hit each line
```

---

## Parallel Execution

### pytest-xdist Configuration

```bash
pip install pytest-xdist

pytest -n auto                     # auto-detect CPU count
pytest -n 4                        # 4 workers
pytest -n auto --dist loadscope   # group by module then class
pytest -n auto --dist worksteal   # dynamic load balancing (best for uneven tests)
```

### Distribution Modes

| Mode | Behavior | Best For |
|------|----------|----------|
| `load` (default) | Round-robin distribution | Evenly-sized tests |
| `loadscope` | Group by module/class | Tests sharing module-scoped fixtures |
| `loadgroup` | Group by `@pytest.mark.xdist_group` | Explicit grouping |
| `worksteal` | Workers steal from others' queues | Mixed fast/slow tests |

### Worker-Safe Fixtures

```python
# Session-scoped fixtures run once PER WORKER by default.
# Use FileLock for shared one-time setup across workers.
from filelock import FileLock

@pytest.fixture(scope="session")
def db_schema(tmp_path_factory):
    root_tmp = tmp_path_factory.getbasetemp().parent
    lock = root_tmp / "db_schema.lock"
    with FileLock(str(lock)):
        marker = root_tmp / "db_schema.done"
        if not marker.exists():
            create_test_schema()  # only one worker does this
            marker.touch()
    yield

# Worker identification
@pytest.fixture(scope="session")
def worker_id(request):
    if hasattr(request.config, "workerinput"):
        return request.config.workerinput["workerid"]  # "gw0", "gw1", etc.
    return "master"

# Per-worker database
@pytest.fixture(scope="session")
def db_name(worker_id):
    return f"test_{worker_id}"
```

### Grouping Tests

```python
# Force tests to run on the same worker
@pytest.mark.xdist_group("database")
class TestDatabaseOperations:
    def test_insert(self): ...
    def test_query(self): ...
    def test_delete(self): ...
```

### xdist + coverage

```bash
# coverage.py must merge results from workers
pytest -n auto --cov=myapp --cov-report=term-missing
# Ensure parallel=true in [tool.coverage.run]
```

### CI Configuration

```yaml
- name: Test (parallel)
  run: pytest -n auto --dist worksteal --timeout=60 -q
```

### Avoiding Parallel Pitfalls

| Problem | Solution |
|---------|----------|
| Port conflicts | Use random ports or per-worker ports: `base_port + worker_number` |
| File conflicts | Use `tmp_path` (per-test) not hardcoded paths |
| DB conflicts | Per-worker databases or transaction isolation |
| Shared state | No module-level mutable state; use fixtures |
| Fixture duplication | Session fixtures run per-worker; use `FileLock` for global setup |
| Non-deterministic order | Tests must be independent; use `pytest-randomly` to catch order deps |
