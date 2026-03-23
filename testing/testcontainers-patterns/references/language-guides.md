# Testcontainers Language Guides

<!-- TOC -->
- [Java](#java)
  - [JUnit 5 Annotations](#junit-5-annotations)
  - [@DynamicPropertySource](#dynamicpropertysource)
  - [Spring Boot Integration](#spring-boot-integration)
  - [Quarkus Integration](#quarkus-integration)
- [Python](#python)
  - [Pytest Fixtures](#pytest-fixtures)
  - [Context Managers](#context-managers)
  - [Advanced Python Patterns](#advanced-python-patterns)
- [Node.js / TypeScript](#nodejs--typescript)
  - [Vitest Integration](#vitest-integration)
  - [Jest Integration](#jest-integration)
  - [StartedTestContainer API](#startedtestcontainer-api)
- [Go](#go)
  - [testcontainers-go Basics](#testcontainers-go-basics)
  - [ContainerRequest](#containerrequest)
  - [Module Containers](#module-containers-go)
- [.NET](#net)
  - [xUnit Integration](#xunit-integration)
  - [WebApplicationFactory](#webapplicationfactory)
<!-- /TOC -->

---

## Java

### JUnit 5 Annotations

The `@Testcontainers` and `@Container` annotations integrate with JUnit 5's
extension model to manage container lifecycle automatically.

```java
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.containers.KafkaContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;
import org.junit.jupiter.api.*;

@Testcontainers
class OrderProcessingTest {

    // Static: shared across all tests in this class (started once)
    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
        .withDatabaseName("orders")
        .withUsername("test")
        .withPassword("test")
        .withInitScript("db/schema.sql");

    // Non-static: new container per test method
    @Container
    GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine")
        .withExposedPorts(6379);

    @Test
    void shouldProcessOrder() {
        String jdbcUrl = postgres.getJdbcUrl();
        String redisHost = redis.getHost();
        int redisPort = redis.getMappedPort(6379);

        // Both containers are running and ready
        OrderProcessor processor = new OrderProcessor(jdbcUrl, redisHost, redisPort);
        processor.process(new Order("item-1", 2));

        // Assert against real Postgres
    }

    @Test
    void shouldCacheOrderLookup() {
        // redis is a fresh container for this test (non-static)
        // postgres is the same container (static)
    }
}
```

**Lifecycle rules:**
- `static @Container` → started before first test, stopped after last test
- Non-static `@Container` → started before each test, stopped after each test
- `@Testcontainers` is required to activate lifecycle management
- Containers start in field declaration order; use `dependsOn()` for explicit ordering

### @DynamicPropertySource

Inject container connection details into Spring's `Environment` at test time.

```java
@SpringBootTest
@Testcontainers
class UserServiceIntegrationTest {

    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine");

    @Container
    static GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine")
        .withExposedPorts(6379);

    @DynamicPropertySource
    static void configureProperties(DynamicPropertyRegistry registry) {
        // Datasource
        registry.add("spring.datasource.url", postgres::getJdbcUrl);
        registry.add("spring.datasource.username", postgres::getUsername);
        registry.add("spring.datasource.password", postgres::getPassword);
        registry.add("spring.datasource.driver-class-name", () -> "org.postgresql.Driver");

        // Redis
        registry.add("spring.data.redis.host", redis::getHost);
        registry.add("spring.data.redis.port", () -> redis.getMappedPort(6379));
    }

    @Autowired
    private UserService userService;

    @Test
    void shouldPersistAndCacheUser() {
        User user = userService.create("alice", "alice@example.com");
        assertThat(userService.findById(user.getId())).isPresent();
    }
}
```

### Spring Boot Integration

Spring Boot 3.1+ provides `@ServiceConnection` for zero-config container wiring.

```java
@SpringBootTest
@Testcontainers
class ApplicationIntegrationTest {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine");

    @Container
    @ServiceConnection
    static KafkaContainer kafka = new KafkaContainer(
        DockerImageName.parse("confluentinc/cp-kafka:7.6.0"));

    @Container
    @ServiceConnection(name = "redis")
    static GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine")
        .withExposedPorts(6379);

    // No @DynamicPropertySource needed — Spring auto-detects connections
    // DataSource, KafkaTemplate, RedisConnectionFactory all auto-configured

    @Autowired ApplicationContext context;

    @Test
    void contextLoads() {
        assertThat(context).isNotNull();
    }
}
```

**Spring Boot TestContainers support (`spring-boot-testcontainers`):**

```java
// TestApplication for `./mvnw spring-boot:test-run`
@TestConfiguration(proxyBeanMethods = false)
class TestcontainersConfig {

    @Bean
    @ServiceConnection
    PostgreSQLContainer<?> postgres() {
        return new PostgreSQLContainer<>("postgres:16-alpine");
    }

    @Bean
    @ServiceConnection
    KafkaContainer kafka() {
        return new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.6.0"));
    }
}

@SpringBootApplication
class TestApplication {
    public static void main(String[] args) {
        SpringApplication
            .from(Application::main)
            .with(TestcontainersConfig.class)
            .run(args);
    }
}
```

### Quarkus Integration

Quarkus Dev Services auto-start containers for supported services. For manual
control, use `@QuarkusTestResource`.

```java
// Automatic (Dev Services) — just add dependency and Quarkus starts the container
// No code needed. Configure in application.properties:
// quarkus.datasource.devservices.image-name=postgres:16-alpine

// Manual control with @QuarkusTestResource
public class PostgresResource implements QuarkusTestResourceLifecycleManager {

    private PostgreSQLContainer<?> container;

    @Override
    public Map<String, String> start() {
        container = new PostgreSQLContainer<>("postgres:16-alpine");
        container.start();
        return Map.of(
            "quarkus.datasource.jdbc.url", container.getJdbcUrl(),
            "quarkus.datasource.username", container.getUsername(),
            "quarkus.datasource.password", container.getPassword()
        );
    }

    @Override
    public void stop() {
        if (container != null) container.stop();
    }
}

@QuarkusTest
@QuarkusTestResource(PostgresResource.class)
class UserResourceTest {
    @Test
    void shouldReturnUsers() {
        given().when().get("/users")
            .then().statusCode(200);
    }
}
```

---

## Python

### Pytest Fixtures

```python
# conftest.py — shared fixtures for your test suite
import pytest
from testcontainers.postgres import PostgresContainer
from testcontainers.mongodb import MongoDbContainer
from testcontainers.redis import RedisContainer
from testcontainers.kafka import KafkaContainer
import sqlalchemy

# Session-scoped: one container for the entire test session
@pytest.fixture(scope="session")
def postgres_container():
    with PostgresContainer("postgres:16-alpine") as pg:
        yield pg

@pytest.fixture(scope="session")
def db_engine(postgres_container):
    engine = sqlalchemy.create_engine(postgres_container.get_connection_url())
    # Run migrations
    with engine.begin() as conn:
        conn.execute(sqlalchemy.text("""
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                name VARCHAR(255) NOT NULL,
                email VARCHAR(255) UNIQUE
            )
        """))
    yield engine
    engine.dispose()

# Function-scoped: clean state per test using transactions
@pytest.fixture
def db_session(db_engine):
    connection = db_engine.connect()
    transaction = connection.begin()
    yield connection
    transaction.rollback()
    connection.close()

# MongoDB fixture
@pytest.fixture(scope="session")
def mongo_container():
    with MongoDbContainer("mongo:7") as mongo:
        yield mongo

@pytest.fixture(scope="session")
def mongo_client(mongo_container):
    from pymongo import MongoClient
    client = MongoClient(mongo_container.get_connection_url())
    yield client
    client.close()

# Redis fixture
@pytest.fixture(scope="session")
def redis_container():
    with RedisContainer("redis:7-alpine") as r:
        yield r

@pytest.fixture
def redis_client(redis_container):
    import redis
    client = redis.Redis(
        host=redis_container.get_container_host_ip(),
        port=redis_container.get_exposed_port(6379),
    )
    yield client
    client.flushall()

# Kafka fixture
@pytest.fixture(scope="session")
def kafka_container():
    with KafkaContainer("confluentinc/cp-kafka:7.6.0") as k:
        yield k
```

### Context Managers

Use context managers for simple, self-contained tests.

```python
from testcontainers.postgres import PostgresContainer
from testcontainers.core.container import DockerContainer
import sqlalchemy

def test_user_crud():
    with PostgresContainer("postgres:16-alpine") as postgres:
        engine = sqlalchemy.create_engine(postgres.get_connection_url())
        with engine.begin() as conn:
            conn.execute(sqlalchemy.text(
                "CREATE TABLE users (id serial PRIMARY KEY, name text NOT NULL)"
            ))
            conn.execute(sqlalchemy.text(
                "INSERT INTO users (name) VALUES (:name)"), {"name": "alice"}
            )
            result = conn.execute(sqlalchemy.text("SELECT name FROM users"))
            assert result.fetchone()[0] == "alice"

def test_custom_service():
    with DockerContainer("nginx:alpine") as nginx:
        nginx.with_exposed_ports(80)
        nginx.start()
        import requests
        host = nginx.get_container_host_ip()
        port = nginx.get_exposed_port(80)
        resp = requests.get(f"http://{host}:{port}")
        assert resp.status_code == 200
```

### Advanced Python Patterns

#### Custom Container Class

```python
from testcontainers.core.container import DockerContainer
from testcontainers.core.waiting_utils import wait_for_logs

class KeycloakContainer(DockerContainer):
    def __init__(self, image="quay.io/keycloak/keycloak:24.0"):
        super().__init__(image)
        self.with_exposed_ports(8080)
        self.with_env("KEYCLOAK_ADMIN", "admin")
        self.with_env("KEYCLOAK_ADMIN_PASSWORD", "admin")
        self.with_command("start-dev")

    def start(self):
        super().start()
        wait_for_logs(self, "Running the server in development mode")
        return self

    def get_url(self):
        host = self.get_container_host_ip()
        port = self.get_exposed_port(8080)
        return f"http://{host}:{port}"

# Usage
def test_keycloak():
    with KeycloakContainer() as kc:
        kc.start()
        url = kc.get_url()
        # test against real Keycloak
```

#### LocalStack for AWS Testing

```python
from testcontainers.localstack import LocalStackContainer
import boto3

@pytest.fixture(scope="session")
def localstack():
    with LocalStackContainer("localstack/localstack:3.4") as ls:
        yield ls

@pytest.fixture
def s3_client(localstack):
    return boto3.client(
        "s3",
        endpoint_url=localstack.get_url(),
        aws_access_key_id="test",
        aws_secret_access_key="test",
        region_name="us-east-1",
    )

def test_s3_upload(s3_client):
    s3_client.create_bucket(Bucket="test-bucket")
    s3_client.put_object(Bucket="test-bucket", Key="test.txt", Body=b"hello")
    obj = s3_client.get_object(Bucket="test-bucket", Key="test.txt")
    assert obj["Body"].read() == b"hello"
```

---

## Node.js / TypeScript

### Vitest Integration

```typescript
// vitest.config.ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    globalSetup: "./tests/global-setup.ts",
    testTimeout: 60_000,      // containers need time to start
    hookTimeout: 120_000,     // setup/teardown may be slow
  },
});
```

```typescript
// tests/global-setup.ts
import { PostgreSqlContainer, StartedPostgreSqlContainer } from "@testcontainers/postgresql";
import { GenericContainer, StartedTestContainer } from "testcontainers";

let pgContainer: StartedPostgreSqlContainer;
let redisContainer: StartedTestContainer;

export async function setup() {
  pgContainer = await new PostgreSqlContainer("postgres:16-alpine")
    .withDatabase("testdb")
    .start();

  redisContainer = await new GenericContainer("redis:7-alpine")
    .withExposedPorts(6379)
    .start();

  process.env.DATABASE_URL = pgContainer.getConnectionUri();
  process.env.REDIS_HOST = redisContainer.getHost();
  process.env.REDIS_PORT = String(redisContainer.getMappedPort(6379));
}

export async function teardown() {
  await redisContainer.stop();
  await pgContainer.stop();
}
```

```typescript
// tests/user.test.ts
import { describe, it, expect, beforeAll } from "vitest";
import { Pool } from "pg";

describe("User Repository", () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: process.env.DATABASE_URL });
  });

  it("should create and retrieve a user", async () => {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS users (
        id SERIAL PRIMARY KEY,
        name TEXT NOT NULL
      )
    `);
    await pool.query("INSERT INTO users (name) VALUES ($1)", ["alice"]);
    const result = await pool.query("SELECT name FROM users WHERE name = $1", ["alice"]);
    expect(result.rows[0].name).toBe("alice");
  });
});
```

### Jest Integration

```typescript
// jest.config.ts
export default {
  globalSetup: "./tests/jest-global-setup.ts",
  globalTeardown: "./tests/jest-global-teardown.ts",
  testTimeout: 60_000,
};
```

```typescript
// tests/jest-global-setup.ts
import { PostgreSqlContainer } from "@testcontainers/postgresql";

export default async function () {
  const container = await new PostgreSqlContainer("postgres:16-alpine").start();
  process.env.DATABASE_URL = container.getConnectionUri();
  // Store reference for teardown
  (globalThis as any).__PG_CONTAINER__ = container;
}
```

```typescript
// tests/jest-global-teardown.ts
export default async function () {
  const container = (globalThis as any).__PG_CONTAINER__;
  if (container) await container.stop();
}
```

```typescript
// tests/user.test.ts
import { Pool } from "pg";

describe("User Service", () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: process.env.DATABASE_URL });
  });

  afterAll(() => pool.end());

  test("should persist user", async () => {
    await pool.query("CREATE TABLE IF NOT EXISTS users (id serial, name text)");
    await pool.query("INSERT INTO users (name) VALUES ($1)", ["bob"]);
    const { rows } = await pool.query("SELECT name FROM users");
    expect(rows).toContainEqual({ name: "bob" });
  });
});
```

### StartedTestContainer API

Key methods available on a started container:

```typescript
import { GenericContainer, Wait, StartedTestContainer } from "testcontainers";

const container: StartedTestContainer = await new GenericContainer("my-service:latest")
  .withExposedPorts(8080, 8443)
  .withEnvironment({ NODE_ENV: "test", LOG_LEVEL: "debug" })
  .withCopyFilesToContainer([
    { source: "./config/test.json", target: "/app/config.json" }
  ])
  .withWaitStrategy(Wait.forHttp("/health", 8080).forStatusCode(200))
  .withStartupTimeout(120_000)
  .start();

// Connection info
const host: string = container.getHost();
const httpPort: number = container.getMappedPort(8080);
const httpsPort: number = container.getMappedPort(8443);

// Execute commands inside container
const { exitCode, output } = await container.exec(["cat", "/etc/hostname"]);

// Stream logs
const stream = await container.logs();
stream.on("data", (line) => console.log(line));
stream.on("err", (line) => console.error(line));

// Restart
await container.restart();

// Stop and remove
await container.stop();
```

---

## Go

### testcontainers-go Basics

```go
package integration_test

import (
    "context"
    "database/sql"
    "testing"

    _ "github.com/lib/pq"
    "github.com/testcontainers/testcontainers-go"
    "github.com/testcontainers/testcontainers-go/modules/postgres"
    "github.com/testcontainers/testcontainers-go/wait"
)

func TestUserRepository(t *testing.T) {
    ctx := context.Background()

    pgContainer, err := postgres.Run(ctx, "postgres:16-alpine",
        postgres.WithDatabase("testdb"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
        postgres.WithInitScripts("testdata/schema.sql"),
        testcontainers.WithWaitStrategy(
            wait.ForLog("database system is ready to accept connections").
                WithOccurrence(2).
                WithStartupTimeout(60*time.Second),
        ),
    )
    if err != nil {
        t.Fatalf("failed to start container: %v", err)
    }
    t.Cleanup(func() {
        if err := pgContainer.Terminate(ctx); err != nil {
            t.Logf("failed to terminate container: %v", err)
        }
    })

    connStr, err := pgContainer.ConnectionString(ctx, "sslmode=disable")
    if err != nil {
        t.Fatal(err)
    }

    db, err := sql.Open("postgres", connStr)
    if err != nil {
        t.Fatal(err)
    }
    defer db.Close()

    // Run tests against real Postgres
    _, err = db.ExecContext(ctx, "INSERT INTO users (name) VALUES ($1)", "alice")
    if err != nil {
        t.Fatal(err)
    }

    var name string
    err = db.QueryRowContext(ctx, "SELECT name FROM users WHERE name = $1", "alice").Scan(&name)
    if err != nil {
        t.Fatal(err)
    }
    if name != "alice" {
        t.Errorf("expected alice, got %s", name)
    }
}
```

### ContainerRequest

`ContainerRequest` is the primary configuration struct for generic containers.

```go
req := testcontainers.ContainerRequest{
    // Image configuration
    Image:          "my-service:latest",
    FromDockerfile: testcontainers.FromDockerfile{  // OR build from Dockerfile
        Context:    "./path/to/context",
        Dockerfile: "Dockerfile",
        BuildArgs:  map[string]*string{"ENV": ptr("test")},
    },

    // Port mapping
    ExposedPorts: []string{"8080/tcp", "8443/tcp"},

    // Environment
    Env: map[string]string{
        "APP_ENV":   "test",
        "LOG_LEVEL": "debug",
    },

    // Commands
    Cmd: []string{"--config", "/etc/app/test.yaml"},

    // File mounting
    Files: []testcontainers.ContainerFile{
        {
            HostFilePath:      "./config/test.yaml",
            ContainerFilePath: "/etc/app/test.yaml",
            FileMode:          0o644,
        },
    },

    // Networking
    Networks:       []string{"test-network"},
    NetworkAliases: map[string][]string{"test-network": {"my-service"}},

    // Wait strategy
    WaitingFor: wait.ForAll(
        wait.ForListeningPort("8080/tcp"),
        wait.ForHTTP("/health").WithPort("8080/tcp").WithStatusCodeMatcher(
            func(status int) bool { return status == 200 },
        ),
    ).WithDeadline(2 * time.Minute),

    // Resource limits
    HostConfigModifier: func(hc *container.HostConfig) {
        hc.Memory = 256 * 1024 * 1024  // 256MB
    },
}

ctr, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
    ContainerRequest: req,
    Started:          true,
})
```

### Module Containers (Go)

Pre-configured containers for popular services:

```go
import (
    "github.com/testcontainers/testcontainers-go/modules/postgres"
    "github.com/testcontainers/testcontainers-go/modules/redis"
    "github.com/testcontainers/testcontainers-go/modules/kafka"
    "github.com/testcontainers/testcontainers-go/modules/mongodb"
    "github.com/testcontainers/testcontainers-go/modules/localstack"
)

// PostgreSQL
pgCtr, _ := postgres.Run(ctx, "postgres:16-alpine",
    postgres.WithDatabase("testdb"),
    postgres.WithUsername("test"),
    postgres.WithPassword("test"),
)
connStr, _ := pgCtr.ConnectionString(ctx, "sslmode=disable")

// Redis
redisCtr, _ := redis.Run(ctx, "redis:7-alpine")
connURI, _ := redisCtr.ConnectionString(ctx)

// Kafka
kafkaCtr, _ := kafka.Run(ctx, "confluentinc/cp-kafka:7.6.0")
brokers, _ := kafkaCtr.Brokers(ctx)

// MongoDB
mongoCtr, _ := mongodb.Run(ctx, "mongo:7")
mongoURI, _ := mongoCtr.ConnectionString(ctx)

// LocalStack
lsCtr, _ := localstack.Run(ctx, "localstack/localstack:3.4")
// Use with AWS SDK pointing to localstack endpoint
```

---

## .NET

### xUnit Integration

```csharp
using Testcontainers.PostgreSql;
using Testcontainers.MongoDb;
using Npgsql;
using Xunit;

// Per-test container (IAsyncLifetime)
public class UserRepositoryTest : IAsyncLifetime
{
    private readonly PostgreSqlContainer _postgres = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .WithDatabase("testdb")
        .WithUsername("test")
        .WithPassword("test")
        .Build();

    public Task InitializeAsync() => _postgres.StartAsync();
    public Task DisposeAsync() => _postgres.DisposeAsync().AsTask();

    [Fact]
    public async Task ShouldCreateUser()
    {
        await using var conn = new NpgsqlConnection(_postgres.GetConnectionString());
        await conn.OpenAsync();

        await using var cmd = new NpgsqlCommand(
            "CREATE TABLE users (id serial PRIMARY KEY, name text)", conn);
        await cmd.ExecuteNonQueryAsync();

        cmd.CommandText = "INSERT INTO users (name) VALUES ('alice')";
        await cmd.ExecuteNonQueryAsync();

        cmd.CommandText = "SELECT name FROM users WHERE name = 'alice'";
        var result = await cmd.ExecuteScalarAsync();
        Assert.Equal("alice", result);
    }
}

// Shared container (Collection Fixture)
public class PostgresFixture : IAsyncLifetime
{
    public PostgreSqlContainer Container { get; } = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .Build();

    public Task InitializeAsync() => Container.StartAsync();
    public Task DisposeAsync() => Container.DisposeAsync().AsTask();
}

[CollectionDefinition("Postgres")]
public class PostgresCollection : ICollectionFixture<PostgresFixture> { }

[Collection("Postgres")]
public class OrderRepositoryTest
{
    private readonly PostgresFixture _fixture;
    public OrderRepositoryTest(PostgresFixture fixture) => _fixture = fixture;

    [Fact]
    public async Task ShouldPersistOrder()
    {
        var connStr = _fixture.Container.GetConnectionString();
        // test with shared container
    }
}
```

### WebApplicationFactory

Integrate Testcontainers with ASP.NET Core integration testing.

```csharp
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Testcontainers.PostgreSql;
using Xunit;

public class ApiFixture : WebApplicationFactory<Program>, IAsyncLifetime
{
    private readonly PostgreSqlContainer _postgres = new PostgreSqlBuilder()
        .WithImage("postgres:16-alpine")
        .Build();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.ConfigureServices(services =>
        {
            // Remove existing DbContext registration
            var descriptor = services.SingleOrDefault(
                d => d.ServiceType == typeof(DbContextOptions<AppDbContext>));
            if (descriptor != null) services.Remove(descriptor);

            // Add DbContext with Testcontainers connection
            services.AddDbContext<AppDbContext>(options =>
                options.UseNpgsql(_postgres.GetConnectionString()));
        });
    }

    public async Task InitializeAsync()
    {
        await _postgres.StartAsync();
    }

    public new async Task DisposeAsync()
    {
        await base.DisposeAsync();
        await _postgres.DisposeAsync();
    }
}

public class UserApiTest : IClassFixture<ApiFixture>
{
    private readonly HttpClient _client;

    public UserApiTest(ApiFixture factory)
    {
        _client = factory.CreateClient();
    }

    [Fact]
    public async Task GetUsers_ReturnsOk()
    {
        var response = await _client.GetAsync("/api/users");
        response.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task CreateUser_ReturnsCreated()
    {
        var content = new StringContent(
            """{"name": "alice", "email": "alice@test.com"}""",
            Encoding.UTF8, "application/json");

        var response = await _client.PostAsync("/api/users", content);
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
    }
}
```

### .NET — Generic Container

```csharp
using DotNet.Testcontainers.Builders;
using DotNet.Testcontainers.Containers;

var container = new ContainerBuilder()
    .WithImage("redis:7-alpine")
    .WithPortBinding(6379, true)  // true = assign random host port
    .WithWaitStrategy(Wait.ForUnixContainer().UntilPortIsAvailable(6379))
    .Build();

await container.StartAsync();

var host = container.Hostname;
var port = container.GetMappedPublicPort(6379);
// connect to redis at host:port

await container.DisposeAsync();
```

### .NET — Custom Module

```csharp
public sealed class KeycloakContainer : DockerContainer
{
    public KeycloakContainer(KeycloakConfiguration config)
        : base(config) { }

    public string GetBaseUrl()
    {
        var host = Hostname;
        var port = GetMappedPublicPort(8080);
        return $"http://{host}:{port}";
    }
}

public sealed class KeycloakBuilder
    : ContainerBuilder<KeycloakBuilder, KeycloakContainer, KeycloakConfiguration>
{
    public KeycloakBuilder()
        : base(new KeycloakConfiguration())
    {
        DockerResourceConfiguration = Init().DockerResourceConfiguration;
    }

    protected override KeycloakBuilder Init()
    {
        return base.Init()
            .WithImage("quay.io/keycloak/keycloak:24.0")
            .WithPortBinding(8080, true)
            .WithEnvironment("KEYCLOAK_ADMIN", "admin")
            .WithEnvironment("KEYCLOAK_ADMIN_PASSWORD", "admin")
            .WithCommand("start-dev")
            .WithWaitStrategy(
                Wait.ForUnixContainer()
                    .UntilHttpRequestIsSucceeded(r => r.ForPort(8080)));
    }
}
```
