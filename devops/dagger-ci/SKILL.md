---
name: dagger-ci
description: >
  Build CI/CD pipelines as code using Dagger (the programmable container-native CI engine by Solomon Hykes).
  USE this skill when: user asks to create, debug, or optimize Dagger pipelines; write Dagger Functions or Modules
  in Go, Python, or TypeScript; use dagger CLI (dagger call, dagger init, dagger install); compose container
  operations (From, WithExec, WithDirectory, WithMountedCache); set up service bindings (AsService,
  WithServiceBinding); handle secrets in Dagger; integrate Dagger with GitHub Actions or GitLab CI; publish
  container images from Dagger; migrate from Dockerfiles or shell-based CI to Dagger; debug pipeline failures
  with dagger call --interactive.
  DO NOT use when: user wants plain Docker/docker-compose without Dagger; writing GitHub Actions YAML without
  Dagger; using other CI systems (Jenkins, CircleCI, Tekton) without Dagger involvement; general container
  questions unrelated to Dagger; Kubernetes operators or Helm charts not involving Dagger pipelines.
---

# Dagger CI/CD — Skill Reference

## Architecture

Dagger is a programmable CI/CD engine. Key components:

- **Dagger Engine**: Runs as a container (BuildKit-based). Orchestrates pipeline execution via a typed API. Handles caching, networking, secret isolation.
- **Dagger CLI**: `dagger` binary. Entry point for invoking functions, initializing modules, installing dependencies.
- **Dagger Functions**: Units of pipeline logic written in Go, Python, or TypeScript. Each function runs in a container. Inputs and outputs are typed (Container, Directory, File, Secret, Service).
- **Dagger Modules**: Packages of related functions. Shareable via git URLs. Declared in `dagger.json`. Composable via `dagger install`.
- **Daggerverse**: Community registry of reusable modules at daggerverse.dev.
- **dag**: Global client object in every SDK. Entry point for all API calls (`dag.Container()`, `dag.Directory()`, `dag.SetSecret()`).

## Installation & Setup

```bash
# Install Dagger CLI (macOS/Linux)
curl -fsSL https://dl.dagger.io/dagger/install.sh | sh

# Or via Homebrew
brew install dagger/tap/dagger

# Verify
dagger version

# Initialize a new module
dagger init --sdk=go      # or --sdk=python or --sdk=typescript
# Creates: dagger.json, dagger/main.go (or .py/.ts), go.mod (or pyproject.toml/package.json)

# Install a dependency module
dagger install github.com/purpleclay/daggerverse/golang@v0.5.0
```

## Writing Dagger Functions

### Go SDK

```go
package main

import (
    "context"
    "dagger/my-module/internal/dagger"
)

type MyModule struct{}

// Build compiles a Go application and returns the binary as a File.
func (m *MyModule) Build(ctx context.Context, src *dagger.Directory) *dagger.File {
    return dag.Container().
        From("golang:1.23-alpine").
        WithMountedDirectory("/src", src).
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedCache("/root/.cache/go-build", dag.CacheVolume("gobuild")).
        WithWorkdir("/src").
        WithExec([]string{"go", "build", "-o", "/app", "."}).
        File("/app")
}

// Test runs unit tests and returns stdout.
func (m *MyModule) Test(ctx context.Context, src *dagger.Directory) (string, error) {
    return dag.Container().
        From("golang:1.23-alpine").
        WithMountedDirectory("/src", src).
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./...", "-v"}).
        Stdout(ctx)
}
```

### Python SDK

```python
import dagger
from dagger import dag, function, object_type

@object_type
class MyModule:
    @function
    async def build(self, source: dagger.Directory) -> dagger.Container:
        return (
            dag.container()
            .from_("python:3.12-slim")
            .with_directory("/app", source)
            .with_workdir("/app")
            .with_mounted_cache("/root/.cache/pip", dag.cache_volume("pip"))
            .with_exec(["pip", "install", "-r", "requirements.txt"])
            .with_exec(["python", "-m", "build"])
        )
```

### TypeScript SDK

```typescript
import { dag, Container, Directory, object, func } from "@dagger.io/dagger"

@object()
class MyModule {
  @func()
  build(source: Directory): Container {
    return dag
      .container()
      .from("node:20-slim")
      .withDirectory("/app", source)
      .withWorkdir("/app")
      .withMountedCache("/app/node_modules", dag.cacheVolume("node-modules"))
      .withExec(["npm", "ci"])
      .withExec(["npm", "run", "build"])
  }
}
```

## Container Operations Reference

Chain these methods on `dag.Container()`:

| Method | Purpose |
|---|---|
| `.From(image)` | Set base image |
| `.WithExec(args)` | Run command in container |
| `.WithDirectory(path, dir)` | Copy Directory into container |
| `.WithFile(path, file)` | Copy single File into container |
| `.WithNewFile(path, contents)` | Create file with inline contents |
| `.WithWorkdir(path)` | Set working directory |
| `.WithEnvVariable(k, v)` | Set environment variable |
| `.WithMountedCache(path, cache)` | Mount persistent cache volume |
| `.WithMountedDirectory(path, dir)` | Mount directory (not copy) |
| `.WithMountedSecret(path, secret)` | Mount secret as file |
| `.WithSecretVariable(name, secret)` | Inject secret as env var |
| `.WithServiceBinding(alias, svc)` | Bind a service container |
| `.WithExposedPort(port)` | Expose network port |
| `.WithUser(user)` | Set user |
| `.WithEntrypoint(args)` | Set entrypoint |
| `.File(path)` | Extract a File from container |
| `.Directory(path)` | Extract a Directory from container |
| `.Stdout(ctx)` | Get stdout of last exec |
| `.Stderr(ctx)` | Get stderr of last exec |
| `.Publish(address)` | Push to OCI registry |
| `.AsService()` | Convert to Service for binding |
| `.Terminal()` | Open interactive debug shell |

## Caching Strategies

Cache volumes persist across pipeline runs. Use aggressively. **Layer ordering for cache efficiency**: copy dependency manifests first, install deps, then copy source:

```go
ctr := dag.Container().
    From("golang:1.23").
    WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
    WithMountedCache("/root/.cache/go-build", dag.CacheVolume("gobuild")).
    WithMountedDirectory("/src", src).
    WithWorkdir("/src").
    WithExec([]string{"go", "build", "./..."})
```

```python
ctr = (
    dag.container().from_("python:3.12-slim").with_workdir("/app")
    # Copy only requirements first — this layer caches if deps unchanged
    .with_file("/app/requirements.txt", source.file("requirements.txt"))
    .with_mounted_cache("/root/.cache/pip", dag.cache_volume("pip"))
    .with_exec(["pip", "install", "-r", "requirements.txt"])
    # Then copy full source — only this layer busts on code change
    .with_directory("/app", source)
)
```

Common cache volume names: `gomod`, `gobuild`, `pip`, `npm`, `maven`, `cargo`, `gradle`.

## Secrets Handling

Never hardcode secrets. Use `dag.SetSecret()` or accept `*dagger.Secret` as function args:

```go
func (m *MyModule) Deploy(ctx context.Context, src *dagger.Directory, token *dagger.Secret) (string, error) {
    return dag.Container().
        From("alpine:3.19").
        WithSecretVariable("DEPLOY_TOKEN", token).
        WithDirectory("/app", src).
        WithExec([]string{"sh", "-c", "deploy.sh"}).
        Stdout(ctx)
}
```

```bash
# Pass secrets via CLI
dagger call deploy --src=. --token=env:DEPLOY_TOKEN
dagger call deploy --src=. --token=file:./secret.txt
dagger call deploy --src=. --token=cmd:"vault read -field=token secret/deploy"
```

Registry authentication with secrets:

```go
func (m *MyModule) Publish(ctx context.Context, ctr *dagger.Container, password *dagger.Secret) (string, error) {
    return ctr.
        WithRegistryAuth("ghcr.io", "username", password).
        Publish(ctx, "ghcr.io/org/app:latest")
}
```

## Service Dependencies

Spin up ephemeral services (databases, caches, APIs) for integration tests:

```go
func (m *MyModule) IntegrationTest(ctx context.Context, src *dagger.Directory) (string, error) {
    postgres := dag.Container().
        From("postgres:16-alpine").
        WithEnvVariable("POSTGRES_PASSWORD", "test").
        WithEnvVariable("POSTGRES_DB", "testdb").
        WithExposedPort(5432).
        AsService()

    return dag.Container().
        From("golang:1.23").
        WithServiceBinding("db", postgres).
        WithEnvVariable("DATABASE_URL", "postgres://postgres:test@db:5432/testdb").
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./integration/...", "-v"}).
        Stdout(ctx)
}
```

Service lifecycle: Dagger auto-starts services when bound, health-checks exposed ports, deduplicates identical services, tears down on pipeline completion.

## Module Publishing & Reuse

```bash
# Install a remote module as a dependency
dagger install github.com/purpleclay/daggerverse/golang@v0.5.0

# Use installed module in your code
# Go: automatically available via dag.Golang()
# Python: dag.golang()
# TypeScript: dag.golang()

# List functions in any module
dagger functions -m github.com/shykes/daggerverse/hello

# Call a remote module function directly
dagger call -m github.com/shykes/daggerverse/hello hello --greeting="Hi" --name="World"
```

Publish your module: push your git repo containing `dagger.json` to GitHub. Others install via `dagger install github.com/you/repo@version`.

## CI Integration

### GitHub Actions

```yaml
name: CI
on: [push, pull_request]

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dagger/dagger-for-github@v7
        with:
          verb: call
          args: test --source=.
          version: "0.15.1"
```

### GitLab CI

```yaml
test:
  image: docker:latest
  services:
    - docker:dind
  variables:
    DOCKER_HOST: tcp://docker:2376
    DOCKER_TLS_CERTDIR: "/certs"
  before_script:
    - apk add curl && curl -fsSL https://dl.dagger.io/dagger/install.sh | sh
    - export PATH=$PWD/bin:$PATH
  script:
    - dagger call test --source=.
```

### Local Development

```bash
# Run any function locally — identical to CI
dagger call build --src=.
dagger call test --src=.
dagger call lint --src=.

# Pipeline runs in containers — no "works on my machine" issues
```

## Debugging

```bash
dagger call build --src=. --debug         # Verbose output
dagger call build --src=. --interactive   # Shell on failure
dagger functions                          # List available functions
```

Insert `.Terminal()` in code to pause and inspect at any pipeline step:

```go
dag.Container().From("alpine:3.19").WithDirectory("/src", src).
    Terminal().  // ← pauses here, opens interactive shell
    WithExec([]string{"go", "build", "./..."})
```

## Common Patterns

### Multi-Architecture Build

```go
func (m *MyModule) BuildMultiArch(ctx context.Context, src *dagger.Directory) (string, error) {
    variants := make([]*dagger.Container, 0)
    for _, platform := range []dagger.Platform{"linux/amd64", "linux/arm64"} {
        binary := dag.Container(dagger.ContainerOpts{Platform: platform}).
            From("golang:1.23-alpine").
            WithMountedDirectory("/src", src).
            WithWorkdir("/src").
            WithEnvVariable("CGO_ENABLED", "0").
            WithExec([]string{"go", "build", "-o", "/app", "."}).
            File("/app")

        ctr := dag.Container(dagger.ContainerOpts{Platform: platform}).
            From("alpine:3.19").
            WithFile("/usr/local/bin/app", binary).
            WithEntrypoint([]string{"/usr/local/bin/app"})
        variants = append(variants, ctr)
    }
    return dag.Container().
        Publish(ctx, "ghcr.io/org/app:latest",
            dagger.ContainerPublishOpts{PlatformVariants: variants})
}
```

### Matrix Testing

```go
func (m *MyModule) TestMatrix(ctx context.Context, src *dagger.Directory) error {
    versions := []string{"3.10", "3.11", "3.12"}
    for _, v := range versions {
        _, err := dag.Container().
            From("python:" + v + "-slim").
            WithDirectory("/app", src).
            WithWorkdir("/app").
            WithExec([]string{"pip", "install", "-r", "requirements.txt"}).
            WithExec([]string{"pytest"}).
            Stdout(ctx)
        if err != nil {
            return fmt.Errorf("tests failed on Python %s: %w", v, err)
        }
    }
    return nil
}
```

### Full Build-Test-Publish Pipeline

```go
func (m *MyModule) CI(ctx context.Context, src *dagger.Directory, registryPassword *dagger.Secret) (string, error) {
    app := m.Build(ctx, src)
    if _, err := m.Test(ctx, src); err != nil {
        return "", fmt.Errorf("tests failed: %w", err)
    }
    return dag.Container().From("alpine:3.19").
        WithFile("/usr/local/bin/app", app).
        WithEntrypoint([]string{"/usr/local/bin/app"}).
        WithRegistryAuth("ghcr.io", "ci-user", registryPassword).
        Publish(ctx, "ghcr.io/org/app:latest")
}
```

```bash
dagger call ci --src=. --registry-password=env:GHCR_TOKEN
```

## Migration from Dockerfiles

| Dockerfile | Dagger (Go) |
|---|---|
| `FROM golang:1.23` | `.From("golang:1.23")` |
| `WORKDIR /app` | `.WithWorkdir("/app")` |
| `COPY . .` | `.WithDirectory("/app", src)` |
| `COPY go.mod .` | `.WithFile("/app/go.mod", src.File("go.mod"))` |
| `RUN go build` | `.WithExec([]string{"go", "build"})` |
| `ENV KEY=val` | `.WithEnvVariable("KEY", "val")` |
| `EXPOSE 8080` | `.WithExposedPort(8080)` |
| `ENTRYPOINT ["/app"]` | `.WithEntrypoint([]string{"/app"})` |

Advantages: real language, conditional logic, loops, error handling, testable, composable modules, typed I/O, service deps, secret injection without build args.

## Migration from Shell-Based CI

**Before (GitHub Actions YAML):**
```yaml
- run: go build -o app .
- run: go test ./...
- run: docker build -t myapp .
- run: docker push ghcr.io/org/myapp:latest
```

**After (Dagger Function + single CI step):**
```go
func (m *MyModule) CI(ctx context.Context, src *dagger.Directory, token *dagger.Secret) (string, error) {
    built := dag.Container().From("golang:1.23").
        WithDirectory("/src", src).WithWorkdir("/src").
        WithExec([]string{"go", "test", "./..."}).
        WithExec([]string{"go", "build", "-o", "/app", "."}).
        File("/app")
    return dag.Container().From("alpine:3.19").
        WithFile("/usr/local/bin/app", built).
        WithEntrypoint([]string{"/usr/local/bin/app"}).
        WithRegistryAuth("ghcr.io", "ci-user", token).
        Publish(ctx, "ghcr.io/org/myapp:latest")
}
```

## Input/Output Examples

**User:** "Create a Dagger function to build and test a Node.js app"

```typescript
@object()
class Nodejs {
  @func()
  buildAndTest(source: Directory): Container {
    return dag.container().from("node:20-slim")
      .withDirectory("/app", source).withWorkdir("/app")
      .withMountedCache("/app/node_modules", dag.cacheVolume("node-modules"))
      .withExec(["npm", "ci"]).withExec(["npm", "test"]).withExec(["npm", "run", "build"])
  }
}
```
`dagger call build-and-test --source=.`

**User:** "Add a Postgres integration test to my Dagger pipeline"

```python
@function
async def integration_test(self, source: dagger.Directory) -> str:
    db = (
        dag.container().from_("postgres:16-alpine")
        .with_env_variable("POSTGRES_PASSWORD", "test")
        .with_env_variable("POSTGRES_DB", "myapp_test")
        .with_exposed_port(5432).as_service()
    )
    return await (
        dag.container().from_("python:3.12-slim")
        .with_service_binding("db", db)
        .with_directory("/app", source).with_workdir("/app")
        .with_exec(["pip", "install", "-r", "requirements.txt"])
        .with_env_variable("DATABASE_URL", "postgresql://postgres:test@db:5432/myapp_test")
        .with_exec(["pytest", "tests/integration/", "-v"]).stdout()
    )
```
