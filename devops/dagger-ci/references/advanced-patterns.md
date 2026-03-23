# Dagger Advanced Patterns

## Table of Contents

- [Multi-Stage Build Pipelines](#multi-stage-build-pipelines)
- [Matrix Testing](#matrix-testing)
- [Multi-Architecture Builds](#multi-architecture-builds)
- [Service Dependencies](#service-dependencies)
- [Custom Dagger Modules and Composition](#custom-dagger-modules-and-composition)
- [Dagger Module Registry and Sharing](#dagger-module-registry-and-sharing)
- [Caching Strategies](#caching-strategies)
- [Parallelism and Performance Optimization](#parallelism-and-performance-optimization)
- [Secrets Management Patterns](#secrets-management-patterns)

---

## Multi-Stage Build Pipelines

Multi-stage pipelines separate concerns (build, test, package, deploy) into composable functions
that share artifacts via typed inputs/outputs.

### Pattern: Staged Pipeline with Artifact Passing

```go
package main

import (
    "context"
    "dagger/ci/internal/dagger"
    "fmt"
)

type CI struct{}

// Stage 1: Build — compile the binary
func (m *CI) Build(ctx context.Context, src *dagger.Directory) *dagger.File {
    return dag.Container().
        From("golang:1.23-alpine").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedCache("/root/.cache/go-build", dag.CacheVolume("gobuild")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithEnvVariable("CGO_ENABLED", "0").
        WithExec([]string{"go", "build", "-ldflags", "-s -w", "-o", "/app", "."}).
        File("/app")
}

// Stage 2: Test — run full test suite
func (m *CI) Test(ctx context.Context, src *dagger.Directory) (string, error) {
    return dag.Container().
        From("golang:1.23-alpine").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "-race", "-coverprofile=coverage.out", "./..."}).
        Stdout(ctx)
}

// Stage 3: Lint — static analysis
func (m *CI) Lint(ctx context.Context, src *dagger.Directory) (string, error) {
    return dag.Container().
        From("golangci/golangci-lint:v1.61-alpine").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"golangci-lint", "run", "--timeout", "5m"}).
        Stdout(ctx)
}

// Stage 4: Package — create minimal runtime image
func (m *CI) Package(ctx context.Context, binary *dagger.File) *dagger.Container {
    return dag.Container().
        From("gcr.io/distroless/static-debian12:nonroot").
        WithFile("/usr/local/bin/app", binary).
        WithEntrypoint([]string{"/usr/local/bin/app"}).
        WithExposedPort(8080)
}

// Stage 5: Publish — push to registry
func (m *CI) Publish(
    ctx context.Context,
    container *dagger.Container,
    registry string,
    username string,
    password *dagger.Secret,
    tag string,
) (string, error) {
    return container.
        WithRegistryAuth(registry, username, password).
        Publish(ctx, fmt.Sprintf("%s:%s", registry, tag))
}

// Pipeline — orchestrate all stages
func (m *CI) Pipeline(
    ctx context.Context,
    src *dagger.Directory,
    registry string,
    username string,
    password *dagger.Secret,
    tag string,
) (string, error) {
    // Test and lint can run before packaging
    if _, err := m.Test(ctx, src); err != nil {
        return "", fmt.Errorf("tests failed: %w", err)
    }
    if _, err := m.Lint(ctx, src); err != nil {
        return "", fmt.Errorf("lint failed: %w", err)
    }

    binary := m.Build(ctx, src)
    container := m.Package(ctx, binary)
    return m.Publish(ctx, container, registry, username, password, tag)
}
```

### Pattern: Conditional Stages

```go
func (m *CI) Pipeline(
    ctx context.Context,
    src *dagger.Directory,
    skipTests bool,
    publish bool,
    token *dagger.Secret,
) (string, error) {
    if !skipTests {
        if _, err := m.Test(ctx, src); err != nil {
            return "", err
        }
    }

    binary := m.Build(ctx, src)
    container := m.Package(ctx, binary)

    if publish {
        return m.Publish(ctx, container, "ghcr.io/org/app", "ci", token, "latest")
    }

    // Just export locally
    _, err := container.Export(ctx, "./app-image.tar")
    return "exported locally", err
}
```

```bash
dagger call pipeline --src=. --skip-tests=false --publish=true --token=env:GHCR_TOKEN
```

---

## Matrix Testing

Run tests across multiple versions of languages, OSes, or dependency sets.

### Pattern: Language Version Matrix

```go
func (m *CI) TestMatrix(ctx context.Context, src *dagger.Directory) error {
    versions := []string{"1.21", "1.22", "1.23"}

    for _, v := range versions {
        _, err := dag.Container().
            From("golang:" + v + "-alpine").
            WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod-"+v)).
            WithMountedDirectory("/src", src).
            WithWorkdir("/src").
            WithExec([]string{"go", "test", "./...", "-v"}).
            Stdout(ctx)
        if err != nil {
            return fmt.Errorf("tests failed on Go %s: %w", v, err)
        }
    }
    return nil
}
```

### Pattern: OS + Version Matrix (Python)

```python
@function
async def test_matrix(self, source: dagger.Directory) -> str:
    """Run tests across Python versions and OS variants."""
    matrix = [
        ("python:3.10-slim", "3.10"),
        ("python:3.11-slim", "3.11"),
        ("python:3.12-slim", "3.12"),
        ("python:3.10-alpine", "3.10-alpine"),
        ("python:3.12-alpine", "3.12-alpine"),
    ]
    results = []
    for image, label in matrix:
        output = await (
            dag.container()
            .from_(image)
            .with_directory("/app", source)
            .with_workdir("/app")
            .with_mounted_cache("/root/.cache/pip", dag.cache_volume(f"pip-{label}"))
            .with_exec(["pip", "install", "-r", "requirements.txt"])
            .with_exec(["pytest", "-v", "--tb=short"])
            .stdout()
        )
        results.append(f"✅ {label}: passed")
    return "\n".join(results)
```

### Pattern: Dependency Version Matrix

```go
func (m *CI) TestWithDeps(ctx context.Context, src *dagger.Directory) error {
    // Test against multiple database versions
    pgVersions := []string{"14", "15", "16"}
    for _, pgVer := range pgVersions {
        db := dag.Container().
            From("postgres:" + pgVer + "-alpine").
            WithEnvVariable("POSTGRES_PASSWORD", "test").
            WithEnvVariable("POSTGRES_DB", "testdb").
            WithExposedPort(5432).
            AsService()

        _, err := dag.Container().
            From("golang:1.23-alpine").
            WithServiceBinding("db", db).
            WithEnvVariable("DATABASE_URL", "postgres://postgres:test@db:5432/testdb").
            WithMountedDirectory("/src", src).
            WithWorkdir("/src").
            WithExec([]string{"go", "test", "./...", "-v"}).
            Stdout(ctx)
        if err != nil {
            return fmt.Errorf("tests failed with Postgres %s: %w", pgVer, err)
        }
    }
    return nil
}
```

---

## Multi-Architecture Builds

Build container images for multiple CPU architectures (AMD64, ARM64) using `dagger.Platform`.

### Pattern: Multi-Arch Container with Platform Variants

```go
func (m *CI) BuildMultiArch(
    ctx context.Context,
    src *dagger.Directory,
    registry string,
    password *dagger.Secret,
) (string, error) {
    platforms := []dagger.Platform{"linux/amd64", "linux/arm64"}
    variants := make([]*dagger.Container, 0, len(platforms))

    for _, platform := range platforms {
        // Cross-compile the binary for target platform
        binary := dag.Container(dagger.ContainerOpts{Platform: platform}).
            From("golang:1.23-alpine").
            WithEnvVariable("CGO_ENABLED", "0").
            WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
            WithMountedDirectory("/src", src).
            WithWorkdir("/src").
            WithExec([]string{"go", "build", "-o", "/app", "."}).
            File("/app")

        // Create minimal runtime container for platform
        ctr := dag.Container(dagger.ContainerOpts{Platform: platform}).
            From("alpine:3.20").
            WithFile("/usr/local/bin/app", binary).
            WithEntrypoint([]string{"/usr/local/bin/app"}).
            WithExposedPort(8080)

        variants = append(variants, ctr)
    }

    // Publish as multi-arch manifest
    return dag.Container().
        WithRegistryAuth(registry, "ci-user", password).
        Publish(ctx, registry+"/app:latest",
            dagger.ContainerPublishOpts{PlatformVariants: variants})
}
```

### Pattern: Multi-Arch with Separate Build and Runtime Bases

```go
func (m *CI) BuildMultiArchDistroless(ctx context.Context, src *dagger.Directory) []*dagger.Container {
    platforms := []dagger.Platform{"linux/amd64", "linux/arm64", "linux/arm/v7"}
    variants := make([]*dagger.Container, 0)

    for _, p := range platforms {
        binary := dag.Container(dagger.ContainerOpts{Platform: p}).
            From("golang:1.23").
            WithEnvVariable("CGO_ENABLED", "0").
            WithMountedDirectory("/src", src).
            WithWorkdir("/src").
            WithExec([]string{"go", "build", "-ldflags", "-s -w", "-o", "/app", "."}).
            File("/app")

        runtime := dag.Container(dagger.ContainerOpts{Platform: p}).
            From("gcr.io/distroless/static-debian12:nonroot").
            WithFile("/app", binary).
            WithEntrypoint([]string{"/app"})

        variants = append(variants, runtime)
    }
    return variants
}
```

---

## Service Dependencies

Use `.AsService()` and `.WithServiceBinding()` to spin up ephemeral infrastructure.

### Pattern: Full Stack Integration Test

```go
func (m *CI) IntegrationTest(ctx context.Context, src *dagger.Directory) (string, error) {
    // Database
    postgres := dag.Container().
        From("postgres:16-alpine").
        WithEnvVariable("POSTGRES_PASSWORD", "test").
        WithEnvVariable("POSTGRES_DB", "testdb").
        WithExposedPort(5432).
        AsService()

    // Cache
    redis := dag.Container().
        From("redis:7-alpine").
        WithExposedPort(6379).
        AsService()

    // Message queue
    rabbit := dag.Container().
        From("rabbitmq:3-management-alpine").
        WithEnvVariable("RABBITMQ_DEFAULT_USER", "guest").
        WithEnvVariable("RABBITMQ_DEFAULT_PASS", "guest").
        WithExposedPort(5672).
        AsService()

    return dag.Container().
        From("golang:1.23-alpine").
        WithServiceBinding("db", postgres).
        WithServiceBinding("cache", redis).
        WithServiceBinding("mq", rabbit).
        WithEnvVariable("DB_HOST", "db").
        WithEnvVariable("REDIS_HOST", "cache").
        WithEnvVariable("AMQP_URL", "amqp://guest:guest@mq:5672/").
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./integration/...", "-v", "-count=1"}).
        Stdout(ctx)
}
```

### Pattern: Service with Initialization Script

```go
func (m *CI) TestWithSeededDB(ctx context.Context, src *dagger.Directory) (string, error) {
    initSQL := src.File("db/init.sql")

    postgres := dag.Container().
        From("postgres:16-alpine").
        WithEnvVariable("POSTGRES_PASSWORD", "test").
        WithEnvVariable("POSTGRES_DB", "testdb").
        WithFile("/docker-entrypoint-initdb.d/init.sql", initSQL).
        WithExposedPort(5432).
        AsService()

    return dag.Container().
        From("golang:1.23").
        WithServiceBinding("db", postgres).
        WithEnvVariable("DATABASE_URL", "postgres://postgres:test@db:5432/testdb?sslmode=disable").
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./...", "-v"}).
        Stdout(ctx)
}
```

### Pattern: Waiting for Service Readiness

```go
func (m *CI) TestWithHealthCheck(ctx context.Context, src *dagger.Directory) (string, error) {
    db := dag.Container().
        From("postgres:16-alpine").
        WithEnvVariable("POSTGRES_PASSWORD", "test").
        WithExposedPort(5432).
        AsService()

    // Dagger automatically waits for exposed ports to accept connections.
    // For custom readiness checks, add a probe container:
    _, err := dag.Container().
        From("postgres:16-alpine").
        WithServiceBinding("db", db).
        WithExec([]string{
            "sh", "-c",
            "until pg_isready -h db -p 5432; do sleep 1; done",
        }).
        Stdout(ctx)
    if err != nil {
        return "", fmt.Errorf("database not ready: %w", err)
    }

    return dag.Container().
        From("golang:1.23").
        WithServiceBinding("db", db).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./..."}).
        Stdout(ctx)
}
```

---

## Custom Dagger Modules and Composition

### Pattern: Modular Pipeline Composition

Split pipeline concerns into separate modules and compose them.

**Module: `builder/`**
```go
// builder/main.go
package main

import (
    "dagger/builder/internal/dagger"
)

type Builder struct{}

func (m *Builder) GoBinary(src *dagger.Directory, goVersion string) *dagger.File {
    if goVersion == "" {
        goVersion = "1.23"
    }
    return dag.Container().
        From("golang:" + goVersion + "-alpine").
        WithEnvVariable("CGO_ENABLED", "0").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "build", "-o", "/out/app", "."}).
        File("/out/app")
}
```

**Module: `deployer/`**
```go
// deployer/main.go
package main

import (
    "context"
    "dagger/deployer/internal/dagger"
    "fmt"
)

type Deployer struct{}

func (m *Deployer) ToRegistry(
    ctx context.Context,
    binary *dagger.File,
    registry string,
    tag string,
    password *dagger.Secret,
) (string, error) {
    return dag.Container().
        From("alpine:3.20").
        WithFile("/usr/local/bin/app", binary).
        WithEntrypoint([]string{"/usr/local/bin/app"}).
        WithRegistryAuth(registry, "ci", password).
        Publish(ctx, fmt.Sprintf("%s:%s", registry, tag))
}
```

**Root module: compose them**
```json
// dagger.json
{
  "name": "ci",
  "sdk": "go",
  "dependencies": [
    { "name": "builder", "source": "./builder" },
    { "name": "deployer", "source": "./deployer" }
  ]
}
```

```go
// main.go — use sub-modules via dag
func (m *CI) Release(ctx context.Context, src *dagger.Directory, token *dagger.Secret) (string, error) {
    binary := dag.Builder().GoBinary(src, "1.23")
    return dag.Deployer().ToRegistry(ctx, binary, "ghcr.io/org/app", "latest", token)
}
```

---

## Dagger Module Registry and Sharing

### Publishing to Daggerverse

Any Git-hosted module with a `dagger.json` at the repo root (or subdirectory) is installable:

```bash
# Others install your module
dagger install github.com/yourorg/yourmodule@v1.0.0

# Install from subdirectory
dagger install github.com/yourorg/monorepo/modules/builder@main

# Explore remote module functions
dagger functions -m github.com/yourorg/yourmodule@v1.0.0

# Call remote module directly without installing
dagger call -m github.com/yourorg/yourmodule@v1.0.0 build --src=.
```

### Best Practices for Shareable Modules

1. **Semantic versioning**: Tag releases with `v1.0.0` format.
2. **Document functions**: Use Go doc comments or Python docstrings — Dagger surfaces them in `dagger functions`.
3. **Accept `*dagger.Directory` not paths**: Makes modules portable.
4. **Accept `*dagger.Secret` for credentials**: Never accept raw strings for secrets.
5. **Use optional parameters with defaults**: Provide sensible defaults; let callers override.
6. **Include a README.md**: Displayed on daggerverse.dev.

---

## Caching Strategies

### Mount Caches

Persistent volumes that survive across pipeline runs. Essential for package manager caches.

```go
// Named cache volumes — shared by name across all pipelines
dag.CacheVolume("gomod")       // Go modules
dag.CacheVolume("gobuild")     // Go build cache
dag.CacheVolume("pip")         // Python pip
dag.CacheVolume("npm")         // Node modules cache
dag.CacheVolume("maven")       // Maven .m2
dag.CacheVolume("gradle")      // Gradle cache
dag.CacheVolume("cargo")       // Rust cargo
dag.CacheVolume("apt")         // APT package cache
```

### Layer Caching

Dagger uses content-addressed caching. Identical container operations are cached automatically.
To maximize cache hits:

```go
// ✅ GOOD: Copy dependency manifest first, install, then copy source
ctr := dag.Container().From("node:20-slim").
    WithWorkdir("/app").
    WithFile("/app/package.json", src.File("package.json")).
    WithFile("/app/package-lock.json", src.File("package-lock.json")).
    WithExec([]string{"npm", "ci"}).         // Cached if package.json unchanged
    WithDirectory("/app", src)               // Only this busts on code change

// ❌ BAD: Copy everything first — any code change busts npm install cache
ctr := dag.Container().From("node:20-slim").
    WithDirectory("/app", src).              // Busts on ANY file change
    WithExec([]string{"npm", "ci"})          // Re-runs every time
```

### Cache Busting for Freshness

```go
// Force re-run by injecting a unique env var
import "time"

ctr := dag.Container().From("alpine:3.20").
    WithEnvVariable("CACHEBUSTER", time.Now().String()).  // Busts all downstream cache
    WithExec([]string{"apk", "update"})
```

### Cache Sharing Enum

```go
// Control concurrent access to shared caches
dag.Container().
    WithMountedCache("/cache", dag.CacheVolume("shared"),
        dagger.ContainerWithMountedCacheOpts{
            Sharing: dagger.CacheSharingModeShared,   // Multiple readers OK
            // Other options: Locked (exclusive), Private (per-pipeline)
        })
```

---

## Parallelism and Performance Optimization

### Pattern: Parallel Execution with sync.ErrGroup

```go
import "golang.org/x/sync/errgroup"

func (m *CI) ParallelChecks(ctx context.Context, src *dagger.Directory) error {
    g, ctx := errgroup.WithContext(ctx)

    g.Go(func() error {
        _, err := m.Test(ctx, src)
        return err
    })

    g.Go(func() error {
        _, err := m.Lint(ctx, src)
        return err
    })

    g.Go(func() error {
        _, err := m.SecurityScan(ctx, src)
        return err
    })

    return g.Wait()  // All run concurrently; fails fast on first error
}
```

### Pattern: Parallel Matrix with Results Collection

```go
func (m *CI) ParallelMatrix(ctx context.Context, src *dagger.Directory) (string, error) {
    type result struct {
        version string
        output  string
    }

    versions := []string{"3.10", "3.11", "3.12"}
    results := make(chan result, len(versions))
    g, ctx := errgroup.WithContext(ctx)

    for _, v := range versions {
        v := v
        g.Go(func() error {
            out, err := dag.Container().
                From("python:" + v + "-slim").
                WithDirectory("/app", src).
                WithWorkdir("/app").
                WithExec([]string{"pip", "install", "-r", "requirements.txt"}).
                WithExec([]string{"pytest", "-v"}).
                Stdout(ctx)
            if err != nil {
                return fmt.Errorf("Python %s failed: %w", v, err)
            }
            results <- result{v, out}
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return "", err
    }
    close(results)

    var summary strings.Builder
    for r := range results {
        summary.WriteString(fmt.Sprintf("Python %s: ✅\n", r.version))
    }
    return summary.String(), nil
}
```

### Performance Tips

1. **Reuse base containers**: Build a base once, chain operations on it.
2. **Use mount caches aggressively**: Every package manager cache should be a `CacheVolume`.
3. **Order layers for cache efficiency**: Dependencies before source code.
4. **Parallelize independent stages**: Use goroutines (Go), asyncio.gather (Python), or Promise.all (TS).
5. **Minimize `.WithExec` calls**: Combine related commands with `sh -c "cmd1 && cmd2"` when outputs aren't needed between steps.
6. **Use `.WithMountedDirectory` over `.WithDirectory`**: Mount avoids copying when the container won't modify files.
7. **Exclude unnecessary files**: Use `.Directory(".", dagger.DirectoryOpts{Exclude: []string{".git", "node_modules"}})`.

---

## Secrets Management Patterns

### Pattern: Multi-Source Secrets

```bash
# From environment variable
dagger call deploy --token=env:DEPLOY_TOKEN

# From file
dagger call deploy --token=file:./secrets/token.txt

# From command output (e.g., vault, 1password)
dagger call deploy --token=cmd:"vault kv get -field=token secret/deploy"
dagger call deploy --token=cmd:"op read op://vault/deploy/token"
```

### Pattern: Registry Auth with Multiple Registries

```go
func (m *CI) PublishEverywhere(
    ctx context.Context,
    ctr *dagger.Container,
    ghcrToken *dagger.Secret,
    dockerToken *dagger.Secret,
    awsSecret *dagger.Secret,
) error {
    authed := ctr.
        WithRegistryAuth("ghcr.io", "ci-user", ghcrToken).
        WithRegistryAuth("docker.io", "myuser", dockerToken).
        WithRegistryAuth("123456789.dkr.ecr.us-east-1.amazonaws.com", "AWS", awsSecret)

    targets := []string{
        "ghcr.io/org/app:latest",
        "docker.io/org/app:latest",
        "123456789.dkr.ecr.us-east-1.amazonaws.com/app:latest",
    }
    for _, t := range targets {
        if _, err := authed.Publish(ctx, t); err != nil {
            return fmt.Errorf("publish to %s failed: %w", t, err)
        }
    }
    return nil
}
```

### Pattern: Secret as Mounted File

```go
func (m *CI) DeployWithKubeconfig(
    ctx context.Context,
    src *dagger.Directory,
    kubeconfig *dagger.Secret,
) (string, error) {
    return dag.Container().
        From("bitnami/kubectl:latest").
        WithMountedSecret("/root/.kube/config", kubeconfig).
        WithDirectory("/manifests", src.Directory("k8s")).
        WithExec([]string{"kubectl", "apply", "-f", "/manifests/"}).
        Stdout(ctx)
}
```

### Security Best Practices

1. **Never log secrets**: Dagger scrubs secrets from logs automatically, but avoid `fmt.Println(secret)`.
2. **Use `*dagger.Secret` type in function signatures**: Enforces proper secret handling.
3. **Prefer `WithMountedSecret` over `WithSecretVariable`**: File mounts don't appear in `/proc/*/environ`.
4. **Scope secrets narrowly**: Pass secrets only to the container that needs them.
5. **Rotate secrets regularly**: Use `cmd:` source to pull from vault/secrets manager.
6. **Never hardcode secrets in module source code**.
