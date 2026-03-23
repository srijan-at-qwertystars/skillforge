# Advanced Testcontainers Patterns

<!-- TOC -->
- [Singleton Containers](#singleton-containers)
- [Container Reuse (withReuse)](#container-reuse-withreuse)
- [Custom Container Images](#custom-container-images)
- [Multi-Container Test Setups](#multi-container-test-setups)
- [Network Management](#network-management)
- [Docker Compose Module](#docker-compose-module)
- [Testcontainers Cloud](#testcontainers-cloud)
- [Parallel Test Execution](#parallel-test-execution)
- [Custom Wait Strategies](#custom-wait-strategies)
- [Init Scripts and Schema Setup](#init-scripts-and-schema-setup)
- [Fixture Management Patterns](#fixture-management-patterns)
<!-- /TOC -->

---

## Singleton Containers

Singleton containers start once and are shared across an entire test suite. This
dramatically reduces test execution time when many test classes need the same
infrastructure.

### Java — Static Initializer Pattern

```java
public abstract class AbstractIntegrationTest {

    static final PostgreSQLContainer<?> POSTGRES;
    static final KafkaContainer KAFKA;

    static {
        POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("testdb")
            .withUsername("test")
            .withPassword("test")
            .withTmpFs(Map.of("/var/lib/postgresql/data", "rw"));
        POSTGRES.start();

        KAFKA = new KafkaContainer(
            DockerImageName.parse("confluentinc/cp-kafka:7.6.0"));
        KAFKA.start();
    }

    @DynamicPropertySource
    static void configureProperties(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        registry.add("spring.kafka.bootstrap-servers", KAFKA::getBootstrapServers);
    }
}

// Concrete test classes extend the base:
class OrderServiceTest extends AbstractIntegrationTest {
    @Test
    void shouldCreateOrder() { /* uses shared POSTGRES and KAFKA */ }
}

class UserServiceTest extends AbstractIntegrationTest {
    @Test
    void shouldCreateUser() { /* same containers, no restart */ }
}
```

### Python — Session-Scoped Conftest

```python
# conftest.py
import pytest
from testcontainers.postgres import PostgresContainer
from testcontainers.kafka import KafkaContainer

@pytest.fixture(scope="session")
def postgres():
    with PostgresContainer("postgres:16-alpine") as pg:
        yield pg

@pytest.fixture(scope="session")
def kafka():
    with KafkaContainer("confluentinc/cp-kafka:7.6.0") as k:
        yield k

@pytest.fixture(scope="session")
def db_engine(postgres):
    from sqlalchemy import create_engine
    engine = create_engine(postgres.get_connection_url())
    yield engine
    engine.dispose()
```

### Node.js — Global Setup/Teardown

```typescript
// global-setup.ts
import { PostgreSqlContainer, StartedPostgreSqlContainer } from "@testcontainers/postgresql";

let container: StartedPostgreSqlContainer;

export async function setup() {
  container = await new PostgreSqlContainer("postgres:16-alpine").start();
  process.env.DATABASE_URL = container.getConnectionUri();
}

export async function teardown() {
  await container.stop();
}
```

### Go — TestMain

```go
package repo_test

import (
    "context"
    "os"
    "testing"
    "github.com/testcontainers/testcontainers-go/modules/postgres"
)

var connStr string

func TestMain(m *testing.M) {
    ctx := context.Background()
    pgContainer, err := postgres.Run(ctx, "postgres:16-alpine",
        postgres.WithDatabase("testdb"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
    )
    if err != nil {
        panic(err)
    }
    connStr, _ = pgContainer.ConnectionString(ctx, "sslmode=disable")

    code := m.Run()

    pgContainer.Terminate(ctx)
    os.Exit(code)
}
```

### .NET — Collection Fixture

```csharp
public class DatabaseFixture : IAsyncLifetime
{
    public PostgreSqlContainer Postgres { get; } = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .Build();

    public Task InitializeAsync() => Postgres.StartAsync();
    public Task DisposeAsync() => Postgres.DisposeAsync().AsTask();
}

[CollectionDefinition("Database")]
public class DatabaseCollection : ICollectionFixture<DatabaseFixture> { }

[Collection("Database")]
public class UserRepositoryTest
{
    private readonly DatabaseFixture _db;
    public UserRepositoryTest(DatabaseFixture db) => _db = db;

    [Fact]
    public async Task ShouldPersist()
    {
        var connStr = _db.Postgres.GetConnectionString();
        // ...
    }
}
```

---

## Container Reuse (withReuse)

Container reuse keeps containers running between test runs during local
development. Containers are not stopped when the JVM/process exits, so
subsequent runs skip the startup cost entirely.

### Configuration

Enable globally in `~/.testcontainers.properties`:
```properties
testcontainers.reuse.enable=true
```

### Java

```java
PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
    .withDatabaseName("testdb")
    .withReuse(true);
postgres.start();
// Container stays running after JVM exits
// Next run reuses the same container (matched by config hash)
```

### Python

```python
from testcontainers.core.container import DockerContainer

container = DockerContainer("redis:7-alpine")
container.with_kwargs(reuse=True)
container.with_exposed_ports(6379)
container.start()
```

### Node.js

```typescript
const container = await new PostgreSqlContainer("postgres:16-alpine")
  .withReuse()
  .start();
```

### When to Use Reuse

| Scenario | Recommendation |
|----------|---------------|
| Local development | ✅ Enable — saves 5-30s per run |
| CI/CD pipelines | ❌ Disable — clean state each run |
| Debugging failing tests | ✅ Enable — iterate faster |
| Production test suites | ❌ Disable — ensure isolation |

### How Reuse Matching Works

Testcontainers creates a hash of the container configuration (image, env vars,
ports, commands). On subsequent runs, if a running container matches the hash,
it's reused. Changing any configuration creates a new container.

⚠️ **Caveat**: Reused containers retain state from previous runs. Always design
tests that clean up after themselves or use unique namespacing.

---

## Custom Container Images

Build custom images at test time when you need pre-configured dependencies.

### Java — ImageFromDockerfile

```java
GenericContainer<?> container = new GenericContainer<>(
    new ImageFromDockerfile()
        .withDockerfileFromBuilder(builder ->
            builder
                .from("postgres:16-alpine")
                .run("apt-get update && apt-get install -y postgresql-16-postgis-3")
                .build()
        ))
    .withExposedPorts(5432)
    .waitingFor(Wait.forListeningPort());
```

### Java — From Project Dockerfile

```java
GenericContainer<?> app = new GenericContainer<>(
    new ImageFromDockerfile("my-app-test", false)
        .withFileFromPath(".", Paths.get(".")))
    .withExposedPorts(8080)
    .waitingFor(Wait.forHttp("/health").forStatusCode(200));
```

### Python — Build from Dockerfile

```python
from testcontainers.core.image import DockerImage

with DockerImage(path=".", dockerfile_path="Dockerfile") as image:
    with DockerContainer(str(image)) as container:
        container.with_exposed_ports(8080)
        container.start()
```

### Node.js — GenericContainer.fromDockerfile

```typescript
const container = await GenericContainer.fromDockerfile("./path/to/context")
  .withBuildArgs({ NODE_ENV: "test" })
  .build("my-test-image");

const started = await container
  .withExposedPorts(8080)
  .start();
```

### Go — FromDockerfile

```go
req := testcontainers.ContainerRequest{
    FromDockerfile: testcontainers.FromDockerfile{
        Context:    ".",
        Dockerfile: "Dockerfile.test",
    },
    ExposedPorts: []string{"8080/tcp"},
    WaitingFor:   wait.ForHTTP("/health"),
}
```

---

## Multi-Container Test Setups

Complex integration tests often need multiple interdependent services.

### Pattern: Application + Dependencies

```java
@Testcontainers
class FullStackIntegrationTest {

    static Network network = Network.newNetwork();

    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
        .withNetwork(network)
        .withNetworkAliases("db");

    @Container
    static GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine")
        .withNetwork(network)
        .withNetworkAliases("cache")
        .withExposedPorts(6379);

    @Container
    static KafkaContainer kafka = new KafkaContainer(
            DockerImageName.parse("confluentinc/cp-kafka:7.6.0"))
        .withNetwork(network)
        .withNetworkAliases("broker");

    @Container
    static GenericContainer<?> app = new GenericContainer<>("my-app:latest")
        .withNetwork(network)
        .withEnv("DB_URL", "jdbc:postgresql://db:5432/test")
        .withEnv("REDIS_HOST", "cache")
        .withEnv("KAFKA_BOOTSTRAP", "broker:9092")
        .withExposedPorts(8080)
        .waitingFor(Wait.forHttp("/health").forStatusCode(200))
        .dependsOn(postgres, redis, kafka);

    @Test
    void shouldProcessOrderEndToEnd() {
        String appUrl = "http://" + app.getHost() + ":" + app.getMappedPort(8080);
        // test full flow through the application
    }
}
```

### Python — Multiple Fixtures

```python
@pytest.fixture(scope="session")
def test_network():
    from docker import DockerClient
    client = DockerClient.from_env()
    network = client.networks.create("test-net")
    yield network
    network.remove()

@pytest.fixture(scope="session")
def postgres(test_network):
    with PostgresContainer("postgres:16-alpine") as pg:
        # configure network
        yield pg

@pytest.fixture(scope="session")
def redis(test_network):
    with RedisContainer("redis:7-alpine") as r:
        yield r
```

### Node.js — Composed Setup

```typescript
import { Network } from "testcontainers";

const network = await new Network().start();

const postgres = await new PostgreSqlContainer("postgres:16-alpine")
  .withNetwork(network)
  .withNetworkAliases("db")
  .start();

const redis = await new GenericContainer("redis:7-alpine")
  .withNetwork(network)
  .withNetworkAliases("cache")
  .withExposedPorts(6379)
  .start();

// Clean up in reverse order
await redis.stop();
await postgres.stop();
await network.stop();
```

---

## Network Management

Networks enable container-to-container communication using aliases instead of
host-mapped ports.

### Key Concepts

- **Network aliases** act as DNS names within the Docker network
- Containers on the same network communicate via internal ports (no mapping)
- Host-mapped ports are still needed for test code → container communication
- Each test suite should use its own network for isolation

### Java

```java
try (Network network = Network.newNetwork()) {
    // Service A
    GenericContainer<?> serviceA = new GenericContainer<>("service-a:latest")
        .withNetwork(network)
        .withNetworkAliases("service-a")
        .withExposedPorts(8080);

    // Service B depends on A
    GenericContainer<?> serviceB = new GenericContainer<>("service-b:latest")
        .withNetwork(network)
        .withNetworkAliases("service-b")
        .withEnv("SERVICE_A_URL", "http://service-a:8080")
        .withExposedPorts(8081)
        .dependsOn(serviceA);

    serviceA.start();
    serviceB.start();
}
```

### Go

```go
network, err := testcontainers.GenericNetwork(ctx, testcontainers.GenericNetworkRequest{
    NetworkRequest: testcontainers.NetworkRequest{
        Name:   "test-network",
        Driver: "bridge",
    },
})
defer network.Remove(ctx)

req := testcontainers.ContainerRequest{
    Image:    "my-service:latest",
    Networks: []string{"test-network"},
    NetworkAliases: map[string][]string{
        "test-network": {"my-service"},
    },
}
```

---

## Docker Compose Module

Use Docker Compose for complex multi-service setups already defined in a
compose file.

### Java — ComposeContainer (v2)

```java
@Container
static ComposeContainer env = new ComposeContainer(new File("docker-compose-test.yml"))
    .withExposedService("postgres", 5432, Wait.forListeningPort())
    .withExposedService("redis", 6379, Wait.forListeningPort())
    .withExposedService("app", 8080, Wait.forHttp("/health"))
    .withLocalCompose(true);  // use local docker compose binary

@Test
void test() {
    String pgHost = env.getServiceHost("postgres", 5432);
    int pgPort = env.getServicePort("postgres", 5432);
    // connect to services
}
```

### Node.js — DockerComposeEnvironment

```typescript
import { DockerComposeEnvironment, Wait } from "testcontainers";

const env = await new DockerComposeEnvironment(".", "docker-compose-test.yml")
  .withWaitStrategy("postgres-1", Wait.forHealthCheck())
  .withWaitStrategy("redis-1", Wait.forListeningPorts())
  .up();

const pgContainer = env.getContainer("postgres-1");
const pgPort = pgContainer.getMappedPort(5432);

// Teardown
await env.down();
```

### Go

```go
compose, err := tc.NewDockerCompose("docker-compose-test.yml")
if err != nil {
    t.Fatal(err)
}
t.Cleanup(func() { compose.Down(ctx) })

err = compose.
    WaitForService("postgres", wait.ForListeningPort("5432/tcp")).
    Up(ctx)
```

---

## Testcontainers Cloud

Testcontainers Cloud offloads container execution to remote infrastructure,
eliminating the need for a local Docker daemon.

### Setup

1. Sign up at [testcontainers.cloud](https://testcontainers.cloud)
2. Install the Testcontainers Cloud agent
3. Set `TC_CLOUD_TOKEN` environment variable
4. Run tests normally — no code changes required

### CI/CD Integration

```yaml
# GitHub Actions
- uses: atomicjar/testcontainers-cloud-setup@v1
  with:
    token: ${{ secrets.TC_CLOUD_TOKEN }}
```

### Benefits

- **No Docker Desktop license** needed on developer machines
- **Faster CI** — containers run on optimized cloud infrastructure
- **Corporate firewalls** — works where Docker socket access is restricted
- **Turbo mode** — parallel container execution across cloud VMs
- **Shared image cache** — team-wide image caching reduces pull times

### Configuration

```properties
# ~/.testcontainers.properties
tc.cloud.token=YOUR_TOKEN
tc.cloud.logs.verbose=true
```

### When to Use

| Scenario | TC Cloud | Local Docker |
|----------|----------|-------------|
| CI/CD without Docker-in-Docker | ✅ | ❌ |
| Corporate firewalls | ✅ | ❌ |
| Large test suites (50+ containers) | ✅ | ⚠️ |
| Quick local prototyping | ⚠️ | ✅ |
| Offline development | ❌ | ✅ |

---

## Parallel Test Execution

Running tests in parallel with Testcontainers requires care around port
conflicts and resource management.

### Java — JUnit 5 Parallel

```properties
# src/test/resources/junit-platform.properties
junit.jupiter.execution.parallel.enabled=true
junit.jupiter.execution.parallel.mode.classes.default=concurrent
junit.jupiter.execution.parallel.config.fixed.parallelism=4
```

Each test class using `@Container` gets its own container instance. Random port
mapping prevents conflicts.

### Key Rules

1. **Never share mutable state** between parallel test classes
2. **Use per-class containers** (`@Container static`) or singletons with proper isolation
3. **Limit parallelism** to avoid exhausting Docker resources
4. **Monitor Docker resources**: `docker stats` during test runs
5. **Use tmpfs** for database containers to reduce I/O contention

### Resource Limits

```java
container.withCreateContainerCmdModifier(cmd -> {
    cmd.getHostConfig()
        .withMemory(256L * 1024 * 1024)  // 256MB
        .withCpuCount(1L);
});
```

### Python — pytest-xdist

```bash
pip install pytest-xdist
pytest -n 4  # 4 parallel workers
```

Each worker process gets its own container instances. Use `session`-scoped
fixtures per worker (not shared across workers).

---

## Custom Wait Strategies

When built-in wait strategies don't match your service's readiness signal.

### Java — Custom WaitStrategy

```java
public class CustomWaitStrategy extends AbstractWaitStrategy {
    @Override
    protected void waitUntilReady() {
        Unreliables.retryUntilSuccess(
            (int) startupTimeout.getSeconds(),
            TimeUnit.SECONDS,
            () -> {
                getRateLimiter().doWhenReady(() -> {
                    String host = waitStrategyTarget.getHost();
                    int port = waitStrategyTarget.getMappedPort(5432);
                    // Custom readiness check
                    try (Connection conn = DriverManager.getConnection(
                            "jdbc:postgresql://" + host + ":" + port + "/test",
                            "user", "pass")) {
                        conn.createStatement().execute("SELECT 1");
                    }
                });
                return true;
            }
        );
    }
}

// Usage:
container.waitingFor(new CustomWaitStrategy());
```

### Composite Wait Strategies

```java
// Wait for BOTH conditions
container.waitingFor(
    new WaitAllStrategy()
        .withStrategy(Wait.forListeningPort())
        .withStrategy(Wait.forLogMessage(".*ready.*", 1))
        .withStartupTimeout(Duration.ofMinutes(2))
);
```

### Node.js — Custom Wait

```typescript
import { AbstractWaitStrategy } from "testcontainers";

class CustomWait extends AbstractWaitStrategy {
  async waitUntilReady(container: StartedTestContainer): Promise<void> {
    const host = container.getHost();
    const port = container.getMappedPort(8080);
    // poll until ready
    await this.retryUntil(async () => {
      const res = await fetch(`http://${host}:${port}/ready`);
      return res.status === 200;
    });
  }
}
```

---

## Init Scripts and Schema Setup

Pre-load databases with schema and test data before tests run.

### Java — Classpath Init Scripts

```java
PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
    .withDatabaseName("testdb")
    .withInitScript("db/init.sql");  // from src/test/resources/
```

### Multiple Init Scripts (Java)

```java
container.withCopyFileToContainer(
    MountableFile.forClasspathResource("db/01-schema.sql"),
    "/docker-entrypoint-initdb.d/01-schema.sql"
).withCopyFileToContainer(
    MountableFile.forClasspathResource("db/02-seed.sql"),
    "/docker-entrypoint-initdb.d/02-seed.sql"
);
```

### Python — Init Script

```python
from testcontainers.postgres import PostgresContainer

postgres = PostgresContainer("postgres:16-alpine")
postgres.with_volume_mapping("./tests/init.sql",
    "/docker-entrypoint-initdb.d/init.sql")
postgres.start()
```

### Node.js — Copy Files

```typescript
import { PostgreSqlContainer } from "@testcontainers/postgresql";
import path from "path";

const container = await new PostgreSqlContainer("postgres:16-alpine")
  .withCopyFilesToContainer([{
    source: path.resolve("./tests/init.sql"),
    target: "/docker-entrypoint-initdb.d/init.sql"
  }])
  .start();
```

### Go — Init Script

```go
pgContainer, err := postgres.Run(ctx, "postgres:16-alpine",
    postgres.WithInitScripts("testdata/init.sql"),
    postgres.WithDatabase("testdb"),
)
```

### Programmatic Schema Setup

```java
@BeforeAll
static void setupSchema() {
    try (Connection conn = DriverManager.getConnection(
            postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
        ScriptUtils.runInitScript(
            new JdbcDatabaseDelegate(postgres, ""),
            "db/schema.sql"
        );
    }
}
```

---

## Fixture Management Patterns

### Pattern 1: Test Data Builders

```java
class TestDataBuilder {
    private final DataSource ds;

    TestDataBuilder(DataSource ds) { this.ds = ds; }

    User createUser(String name) {
        try (var conn = ds.getConnection()) {
            var stmt = conn.prepareStatement(
                "INSERT INTO users (name) VALUES (?) RETURNING id", 
                Statement.RETURN_GENERATED_KEYS);
            stmt.setString(1, name);
            stmt.executeUpdate();
            var rs = stmt.getGeneratedKeys();
            rs.next();
            return new User(rs.getLong(1), name);
        }
    }

    void cleanup() {
        try (var conn = ds.getConnection()) {
            conn.createStatement().execute("TRUNCATE users CASCADE");
        }
    }
}
```

### Pattern 2: Transaction Rollback

```java
@Testcontainers
@Transactional  // Spring rolls back after each test
class UserServiceTest {
    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = 
        new PostgreSQLContainer<>("postgres:16-alpine");

    @Autowired UserService userService;

    @Test
    void shouldCreateUser() {
        userService.create("alice");
        // data is rolled back after this test
    }
}
```

### Pattern 3: Database Per Test (Extreme Isolation)

```java
@BeforeEach
void createFreshDatabase() {
    String dbName = "test_" + UUID.randomUUID().toString().replace("-", "");
    try (Connection conn = DriverManager.getConnection(
            postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())) {
        conn.createStatement().execute("CREATE DATABASE " + dbName);
    }
    // Point test DataSource at the new database
}
```

### Pattern 4: Flyway/Liquibase Migration

```java
@Container
static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine");

@BeforeAll
static void migrate() {
    Flyway.configure()
        .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
        .locations("classpath:db/migration")
        .load()
        .migrate();
}
```
