---
name: testcontainers-patterns
description: >
  Use when writing integration tests that need real external dependencies (databases, message brokers,
  caches, cloud emulators) via Docker containers. TRIGGER when: code imports testcontainers, uses
  @Testcontainers/@Container annotations, GenericContainer, PostgreSQLContainer, KafkaContainer,
  testcontainers-python, testcontainers-go, or user asks about container-based integration testing,
  Docker test fixtures, or replacing H2/SQLite/mocks with real services in tests. DO NOT TRIGGER
  when: writing unit tests with mocks only, using Docker Compose directly without testcontainers
  library, deploying containers to production, writing Dockerfiles, or doing container orchestration
  (Kubernetes/Swarm). Not for runtime containers—only test-scoped containers.
---

# Testcontainers Patterns

## Architecture

Testcontainers launches throwaway Docker containers from test code. The framework:
- Pulls images, creates containers, maps random host ports to container ports
- Manages full lifecycle: create → start → wait-for-ready → run tests → stop → remove
- Runs Ryuk (reaper sidecar) to garbage-collect orphaned containers on crash/timeout
- Requires a Docker daemon (Docker Desktop, Docker Engine, Podman, or Testcontainers Cloud)

## Prerequisites

- Docker daemon running and accessible to test process
- Language-specific library installed
- Ryuk enabled by default; disable only if environment prohibits sidecar containers (`TESTCONTAINERS_RYUK_DISABLED=true`)

### Installation

```bash
# Java (Maven)
<dependency>
  <groupId>org.testcontainers</groupId>
  <artifactId>testcontainers</artifactId>
  <version>1.20.4</version>
  <scope>test</scope>
</dependency>

# Python
pip install testcontainers[postgres,kafka,redis,mongodb]

# Node.js
npm install -D testcontainers @testcontainers/postgresql @testcontainers/kafka

# Go
go get github.com/testcontainers/testcontainers-go

# .NET
dotnet add package Testcontainers --version 4.3.0
```

## Java — JUnit 5 Integration

Use `@Testcontainers` + `@Container` for automatic lifecycle management.

```java
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.junit.jupiter.api.Test;

@Testcontainers
class UserRepositoryTest {

    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
        .withDatabaseName("testdb")
        .withUsername("test")
        .withPassword("test");

    @Test
    void shouldPersistUser() {
        String jdbcUrl = postgres.getJdbcUrl();
        // wire jdbcUrl into your DataSource or connection pool
        // run assertions against real Postgres
    }
}
```

### Spring Boot 3.1+ — @ServiceConnection

```java
@SpringBootTest
@Testcontainers
class OrderServiceIT {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine");

    @Container
    @ServiceConnection
    static KafkaContainer kafka = new KafkaContainer(
        DockerImageName.parse("confluentinc/cp-kafka:7.6.0"));

    // Spring auto-configures DataSource and KafkaTemplate from containers
}
```

### GenericContainer (Java)

```java
@Container
static GenericContainer<?> redis = new GenericContainer<>("redis:7-alpine")
    .withExposedPorts(6379)
    .waitingFor(Wait.forListeningPort());

// Get connection info:
String host = redis.getHost();
int port = redis.getMappedPort(6379);
```

## Python — testcontainers-python

Use context managers or pytest fixtures.

```python
from testcontainers.postgres import PostgresContainer
from testcontainers.kafka import KafkaContainer
import sqlalchemy

# Context manager pattern
def test_user_persistence():
    with PostgresContainer("postgres:16-alpine") as postgres:
        engine = sqlalchemy.create_engine(postgres.get_connection_url())
        with engine.begin() as conn:
            conn.execute(sqlalchemy.text("CREATE TABLE users (id serial, name text)"))
            conn.execute(sqlalchemy.text("INSERT INTO users (name) VALUES ('alice')"))
            result = conn.execute(sqlalchemy.text("SELECT name FROM users"))
            assert result.fetchone()[0] == "alice"

# Pytest fixture pattern
import pytest

@pytest.fixture(scope="module")
def postgres_url():
    with PostgresContainer("postgres:16-alpine") as pg:
        yield pg.get_connection_url()

def test_query(postgres_url):
    engine = sqlalchemy.create_engine(postgres_url)
    # test against real postgres
```

### Available Python modules

```python
from testcontainers.postgres import PostgresContainer
from testcontainers.mysql import MySqlContainer
from testcontainers.mongodb import MongoDbContainer
from testcontainers.redis import RedisContainer
from testcontainers.kafka import KafkaContainer
from testcontainers.elasticsearch import ElasticSearchContainer
from testcontainers.localstack import LocalStackContainer
from testcontainers.core.container import DockerContainer  # generic
```

## Node.js / TypeScript

```typescript
import { GenericContainer, StartedTestContainer, Wait } from "testcontainers";
import { PostgreSqlContainer } from "@testcontainers/postgresql";

describe("UserRepository", () => {
  let container: StartedTestContainer;
  let connectionUri: string;

  beforeAll(async () => {
    container = await new PostgreSqlContainer("postgres:16-alpine")
      .withDatabase("testdb")
      .withUsername("test")
      .withPassword("test")
      .start();
    connectionUri = container.getConnectionUri();
  }, 60_000); // increase timeout for container startup

  afterAll(async () => {
    await container.stop();
  });

  it("should persist and retrieve user", async () => {
    // use connectionUri with your ORM/client
  });
});
```

### GenericContainer (Node.js)

```typescript
const redis = await new GenericContainer("redis:7-alpine")
  .withExposedPorts(6379)
  .withWaitStrategy(Wait.forListeningPorts())
  .start();

const host = redis.getHost();
const port = redis.getMappedPort(6379);
// connect to redis at host:port
await redis.stop();
```

## Go — testcontainers-go

```go
package repo_test

import (
    "context"
    "testing"
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
        testcontainers.WithWaitStrategy(
            wait.ForLog("database system is ready to accept connections").
                WithOccurrence(2)),
    )
    if err != nil {
        t.Fatal(err)
    }
    defer pgContainer.Terminate(ctx)

    connStr, _ := pgContainer.ConnectionString(ctx, "sslmode=disable")
    // use connStr with database/sql or pgx
}
```

### GenericContainer (Go)

```go
ctx := context.Background()
req := testcontainers.ContainerRequest{
    Image:        "redis:7-alpine",
    ExposedPorts: []string{"6379/tcp"},
    WaitingFor:   wait.ForListeningPort("6379/tcp"),
}
redis, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
    ContainerRequest: req,
    Started:          true,
})
defer redis.Terminate(ctx)
host, _ := redis.Host(ctx)
port, _ := redis.MappedPort(ctx, "6379/tcp")
```

## .NET — Testcontainers for .NET

```csharp
using Testcontainers.PostgreSql;
using Xunit;

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
    public async Task ShouldPersistUser()
    {
        var connectionString = _postgres.GetConnectionString();
        // use with Npgsql, EF Core, Dapper
    }
}
```

## Container Configuration

### Environment Variables

```java
new GenericContainer<>("my-app:latest")
    .withEnv("APP_MODE", "test")
    .withEnv("LOG_LEVEL", "debug")
```

### Volumes and File Mounting

```java
// Classpath resource
container.withClasspathResourceMapping("init.sql", "/docker-entrypoint-initdb.d/init.sql", BindMode.READ_ONLY);
// Host path
container.withFileSystemBind("/host/path", "/container/path", BindMode.READ_WRITE);
```

### Wait Strategies

Pick the strategy matching your service's readiness signal:

```java
// TCP port open (default for most containers)
.waitingFor(Wait.forListeningPort())

// Log message (string or regex)
.waitingFor(Wait.forLogMessage(".*Ready to accept connections.*", 1))

// HTTP endpoint returns 200
.waitingFor(Wait.forHttp("/health").forPort(8080).forStatusCode(200))

// Multiple conditions
.waitingFor(Wait.forLogMessage(".*started.*").withStartupTimeout(Duration.ofSeconds(60)))
```

Node.js equivalents:
```typescript
Wait.forListeningPorts()
Wait.forLogMessage("Ready to accept connections")
Wait.forLogMessage(/ready/i)
Wait.forHttp("/health", 8080)
```

Go equivalents:
```go
wait.ForListeningPort("8080/tcp")
wait.ForLog("Ready to accept connections")
wait.ForHTTP("/health").WithPort("8080/tcp")
```

## Network Management

Share a network between containers for inter-container communication:

```java
try (Network network = Network.newNetwork()) {
    GenericContainer<?> db = new GenericContainer<>("postgres:16-alpine")
        .withNetwork(network)
        .withNetworkAliases("db")
        .withExposedPorts(5432);

    GenericContainer<?> app = new GenericContainer<>("my-app:latest")
        .withNetwork(network)
        .withEnv("DB_HOST", "db")  // reference by alias
        .withEnv("DB_PORT", "5432")
        .withExposedPorts(8080);
}
```

## Docker Compose Module

```java
// Java
@Container
static DockerComposeContainer<?> env = new DockerComposeContainer<>(new File("docker-compose-test.yml"))
    .withExposedService("postgres", 5432, Wait.forListeningPort())
    .withExposedService("redis", 6379);

String pgHost = env.getServiceHost("postgres", 5432);
int pgPort = env.getServicePort("postgres", 5432);
```

```typescript
// Node.js
import { DockerComposeEnvironment } from "testcontainers";

const env = await new DockerComposeEnvironment(".", "docker-compose-test.yml")
  .withWaitStrategy("postgres", Wait.forListeningPorts())
  .up();

const pgContainer = env.getContainer("postgres-1");
```

## Module Containers Quick Reference

| Service        | Java                        | Python                   | Node.js                          | Go                          |
|----------------|-----------------------------|--------------------------|---------------------------------|-----------------------------|
| PostgreSQL     | `PostgreSQLContainer`       | `PostgresContainer`      | `PostgreSqlContainer`           | `postgres.Run()`            |
| MySQL          | `MySQLContainer`            | `MySqlContainer`         | `MySqlContainer`                | `mysql.Run()`               |
| MongoDB        | `MongoDBContainer`          | `MongoDbContainer`       | `MongoDBContainer`              | `mongodb.Run()`             |
| Redis          | `GenericContainer("redis")` | `RedisContainer`         | `GenericContainer("redis")`     | `redis.Run()`               |
| Kafka          | `KafkaContainer`            | `KafkaContainer`         | `KafkaContainer`                | `kafka.Run()`               |
| Elasticsearch  | `ElasticsearchContainer`    | `ElasticSearchContainer` | `ElasticsearchContainer`        | `elasticsearch.Run()`       |
| LocalStack     | `LocalStackContainer`       | `LocalStackContainer`    | `LocalStackContainer`           | `localstack.Run()`          |

## CI/CD Integration

Docker is pre-installed on GitHub Actions `ubuntu-latest`. No extra config needed:

```yaml
jobs:
  integration-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./mvnw verify
```

For Testcontainers Cloud: add `atomicjar/testcontainers-cloud-setup@v1` step.
For GitLab CI: use `docker:dind` service with `DOCKER_HOST=tcp://docker:2375` and
`TESTCONTAINERS_HOST_OVERRIDE=docker`. See `references/troubleshooting.md` for details.

## Performance Optimization

1. **Singleton containers** — start once, share across test suite (see `references/advanced-patterns.md`)
2. **Pin image tags** — avoid `:latest` to prevent unexpected pulls
3. **Use alpine variants** — smaller images, faster pulls (`postgres:16-alpine`)
4. **Session/class scope** — start expensive containers once, not per-test
5. **Reuse containers** — `.withReuse(true)` + `testcontainers.reuse.enable=true` in `~/.testcontainers.properties`
6. **Pre-pull images** in CI — add a `docker pull` step before tests
7. **tmpfs for databases** — `withTmpFs(Map.of("/var/lib/postgresql/data", "rw"))`
8. **Testcontainers Cloud** — offloads to remote Docker; set `TC_CLOUD_TOKEN` env var, no code changes

## Common Pitfalls

| Pitfall | Fix |
|---------|-----|
| Container startup timeout | Increase `withStartupTimeout(Duration.ofMinutes(2))` |
| Port already in use | Never hardcode ports; always use `getMappedPort()` |
| Tests pass locally, fail in CI | Check Docker access; increase timeouts for slower CI |
| Flaky tests due to race conditions | Use proper wait strategy, not `Thread.sleep()` |
| Container not found after test | Ryuk is disabled or Docker socket not mounted |
| Slow image pulls | Pin versions, pre-pull in CI, use `withReuse(true)` locally |
| Using `:latest` tag | Pin to specific version for reproducibility |
| Bind mounts fail in CI | Use `withCopyToContainer()` instead of host bind mounts |
| OOM in CI | Limit concurrent containers; use session-scoped singletons |
| Ryuk permission denied | Grant Docker socket access or set `TESTCONTAINERS_RYUK_DISABLED=true` |

## Resources

### References (`references/`)

| File | Contents |
|------|----------|
| `advanced-patterns.md` | Singleton containers, container reuse, custom images, multi-container setups, network management, Docker Compose module, Testcontainers Cloud, parallel execution, custom wait strategies, init scripts, fixture management |
| `language-guides.md` | Deep dives per language — Java (annotations, @DynamicPropertySource, Spring Boot, Quarkus), Python (fixtures, context managers), Node.js (Vitest/Jest, StartedTestContainer), Go (ContainerRequest, modules), .NET (xUnit, WebApplicationFactory) |
| `troubleshooting.md` | Docker daemon issues, CI/CD DinD, Ryuk failures, port mapping, startup timeouts, cleanup, image pull rate limits, WSL2, Testcontainers Cloud diagnostics |

### Scripts (`scripts/`) — all executable

| Script | Purpose |
|--------|---------|
| `setup-testcontainers.sh <lang>` | Verify Docker, install Testcontainers for Java/Python/Node/Go/.NET |
| `tc-health-check.sh` | Check prerequisites: Docker, Ryuk, network, disk/memory/CPU, config |
| `generate-test-template.py <lang> <service>` | Generate a ready-to-run test file (7 services × 5 languages) |

### Assets (`assets/`) — copy-paste templates

| File | Description |
|------|-------------|
| `pytest-fixtures.py` | Python pytest fixtures for Postgres, MySQL, MongoDB, Redis, Kafka, LocalStack, Elasticsearch |
| `junit5-base-test.java` | Java JUnit 5 base class with singleton Postgres + Redis, transaction rollback, helpers |
| `vitest-setup.ts` | Node.js Vitest global setup — parallel Postgres + Redis start, env var export |
| `docker-compose-test.yml` | Multi-service Compose file (Postgres, Redis, Kafka, MongoDB, Elasticsearch, LocalStack) |
