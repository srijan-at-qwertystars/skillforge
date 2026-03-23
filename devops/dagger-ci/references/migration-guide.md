# Dagger Migration Guide

## Table of Contents

- [Why Migrate to Dagger](#why-migrate-to-dagger)
- [Migrating from GitHub Actions](#migrating-from-github-actions)
- [Migrating from GitLab CI](#migrating-from-gitlab-ci)
- [Migrating from Jenkins](#migrating-from-jenkins)
- [Migrating from Dockerfile-Based Builds](#migrating-from-dockerfile-based-builds)
- [Migrating from Shell Scripts](#migrating-from-shell-scripts)
- [Migration Checklist](#migration-checklist)

---

## Why Migrate to Dagger

| Benefit | Description |
|---------|-------------|
| **Local-CI parity** | Run the exact same pipeline locally and in CI — no "works on my machine" issues |
| **Real programming language** | Use Go, Python, or TypeScript instead of YAML — get conditionals, loops, error handling, types |
| **Composable modules** | Break pipelines into reusable, testable, shareable modules |
| **Built-in caching** | Content-addressed caching and persistent cache volumes out of the box |
| **CI-agnostic** | Same pipeline runs on GitHub Actions, GitLab CI, Jenkins, CircleCI, or locally |
| **Typed I/O** | Function inputs/outputs are typed (Container, Directory, File, Secret, Service) |
| **Service dependencies** | Spin up databases, caches, and other services as ephemeral containers |

---

## Migrating from GitHub Actions

### Strategy

Replace individual workflow steps with Dagger Functions, then call `dagger call` from a minimal workflow.

### Before: GitHub Actions YAML

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: test
          POSTGRES_DB: testdb
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.23'
      - name: Cache Go modules
        uses: actions/cache@v4
        with:
          path: ~/go/pkg/mod
          key: ${{ runner.os }}-go-${{ hashFiles('**/go.sum') }}
      - run: go test ./... -v
        env:
          DATABASE_URL: postgres://postgres:test@localhost:5432/testdb

  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: golangci/golangci-lint-action@v6
        with:
          version: v1.61

  build:
    runs-on: ubuntu-latest
    needs: [test, lint]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.23'
      - run: CGO_ENABLED=0 go build -o app .
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          push: true
          tags: ghcr.io/${{ github.repository }}:latest
```

### After: Dagger Module + Minimal Workflow

**Dagger module (`dagger/main.go`):**
```go
package main

import (
    "context"
    "dagger/ci/internal/dagger"
    "fmt"

    "golang.org/x/sync/errgroup"
)

type CI struct{}

func (m *CI) Test(ctx context.Context, src *dagger.Directory) (string, error) {
    postgres := dag.Container().
        From("postgres:16-alpine").
        WithEnvVariable("POSTGRES_PASSWORD", "test").
        WithEnvVariable("POSTGRES_DB", "testdb").
        WithExposedPort(5432).
        AsService()

    return dag.Container().
        From("golang:1.23-alpine").
        WithServiceBinding("db", postgres).
        WithEnvVariable("DATABASE_URL", "postgres://postgres:test@db:5432/testdb?sslmode=disable").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./...", "-v"}).
        Stdout(ctx)
}

func (m *CI) Lint(ctx context.Context, src *dagger.Directory) (string, error) {
    return dag.Container().
        From("golangci/golangci-lint:v1.61-alpine").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"golangci-lint", "run", "--timeout", "5m"}).
        Stdout(ctx)
}

func (m *CI) Build(ctx context.Context, src *dagger.Directory) *dagger.File {
    return dag.Container().
        From("golang:1.23-alpine").
        WithEnvVariable("CGO_ENABLED", "0").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "build", "-o", "/app", "."}).
        File("/app")
}

func (m *CI) Publish(
    ctx context.Context,
    src *dagger.Directory,
    registry string,
    username string,
    password *dagger.Secret,
    tag string,
) (string, error) {
    // Run tests and lint in parallel
    g, ctx := errgroup.WithContext(ctx)
    g.Go(func() error { _, err := m.Test(ctx, src); return err })
    g.Go(func() error { _, err := m.Lint(ctx, src); return err })
    if err := g.Wait(); err != nil {
        return "", fmt.Errorf("checks failed: %w", err)
    }

    binary := m.Build(ctx, src)
    return dag.Container().
        From("alpine:3.20").
        WithFile("/usr/local/bin/app", binary).
        WithEntrypoint([]string{"/usr/local/bin/app"}).
        WithRegistryAuth(registry, username, password).
        Publish(ctx, fmt.Sprintf("%s:%s", registry, tag))
}
```

**Minimal workflow (`.github/workflows/ci.yml`):**
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
          args: >-
            publish
            --src=.
            --registry=ghcr.io/${{ github.repository }}
            --username=${{ github.actor }}
            --password=env:GHCR_TOKEN
            --tag=${{ github.sha }}
          version: "0.15.1"
        env:
          GHCR_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### Key Mapping

| GitHub Actions concept | Dagger equivalent |
|------------------------|-------------------|
| `steps[].run` | `.WithExec([]string{...})` |
| `services:` | `.AsService()` + `.WithServiceBinding()` |
| `actions/cache` | `dag.CacheVolume()` |
| `actions/setup-go` | `.From("golang:1.23")` |
| `env:` | `.WithEnvVariable()` |
| `secrets.*` | `*dagger.Secret` function arg |
| `needs: [job1, job2]` | Function call ordering / errgroup |
| Matrix `strategy.matrix` | Loop over versions in code |

---

## Migrating from GitLab CI

### Before: `.gitlab-ci.yml`

```yaml
stages:
  - test
  - build
  - deploy

variables:
  POSTGRES_DB: testdb
  POSTGRES_PASSWORD: test

test:
  stage: test
  image: golang:1.23
  services:
    - postgres:16-alpine
  variables:
    DATABASE_URL: "postgres://postgres:test@postgres:5432/testdb"
  cache:
    key: go-modules
    paths:
      - .go/pkg/mod/
  script:
    - go test ./... -v

build:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA .
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA

deploy:
  stage: deploy
  image: bitnami/kubectl:latest
  only:
    - main
  script:
    - kubectl set image deployment/app app=$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
```

### After: Dagger Module + Minimal `.gitlab-ci.yml`

**Dagger module (`dagger/main.go`):**
```go
package main

import (
    "context"
    "dagger/ci/internal/dagger"
    "fmt"
)

type CI struct{}

func (m *CI) Test(ctx context.Context, src *dagger.Directory) (string, error) {
    db := dag.Container().
        From("postgres:16-alpine").
        WithEnvVariable("POSTGRES_PASSWORD", "test").
        WithEnvVariable("POSTGRES_DB", "testdb").
        WithExposedPort(5432).
        AsService()

    return dag.Container().
        From("golang:1.23-alpine").
        WithServiceBinding("db", db).
        WithEnvVariable("DATABASE_URL", "postgres://postgres:test@db:5432/testdb?sslmode=disable").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./...", "-v"}).
        Stdout(ctx)
}

func (m *CI) BuildAndPush(
    ctx context.Context,
    src *dagger.Directory,
    registry string,
    username string,
    password *dagger.Secret,
    tag string,
) (string, error) {
    if _, err := m.Test(ctx, src); err != nil {
        return "", err
    }

    binary := dag.Container().
        From("golang:1.23-alpine").
        WithEnvVariable("CGO_ENABLED", "0").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "build", "-o", "/app", "."}).
        File("/app")

    return dag.Container().
        From("alpine:3.20").
        WithFile("/usr/local/bin/app", binary).
        WithEntrypoint([]string{"/usr/local/bin/app"}).
        WithRegistryAuth(registry, username, password).
        Publish(ctx, fmt.Sprintf("%s:%s", registry, tag))
}

func (m *CI) Deploy(
    ctx context.Context,
    kubeconfig *dagger.Secret,
    image string,
    deployment string,
) (string, error) {
    return dag.Container().
        From("bitnami/kubectl:latest").
        WithMountedSecret("/root/.kube/config", kubeconfig).
        WithExec([]string{"kubectl", "set", "image",
            fmt.Sprintf("deployment/%s", deployment),
            fmt.Sprintf("app=%s", image)}).
        Stdout(ctx)
}
```

**Minimal `.gitlab-ci.yml`:**
```yaml
stages:
  - ci

ci:
  stage: ci
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
    - dagger call build-and-push
        --src=.
        --registry=$CI_REGISTRY_IMAGE
        --username=$CI_REGISTRY_USER
        --password=env:CI_REGISTRY_PASSWORD
        --tag=$CI_COMMIT_SHA
```

### Key Mapping

| GitLab CI concept | Dagger equivalent |
|-------------------|-------------------|
| `stages:` | Function call ordering |
| `services:` | `.AsService()` + `.WithServiceBinding()` |
| `cache:` | `dag.CacheVolume()` |
| `image:` | `.From()` |
| `variables:` | `.WithEnvVariable()` |
| `$CI_REGISTRY_PASSWORD` | `*dagger.Secret` |
| `only: [main]` | Conditional logic in CI config or Dagger code |
| `artifacts:` | Return `*dagger.File` or `*dagger.Directory` |

---

## Migrating from Jenkins

### Before: `Jenkinsfile`

```groovy
pipeline {
    agent any
    environment {
        REGISTRY = 'ghcr.io/org/app'
        REGISTRY_CREDS = credentials('ghcr-token')
    }
    stages {
        stage('Test') {
            steps {
                sh 'go test ./... -v -race'
            }
        }
        stage('Build') {
            steps {
                sh 'CGO_ENABLED=0 go build -o app .'
            }
        }
        stage('Docker Build & Push') {
            steps {
                sh """
                    docker build -t ${REGISTRY}:${BUILD_NUMBER} .
                    echo ${REGISTRY_CREDS_PSW} | docker login ghcr.io -u ${REGISTRY_CREDS_USR} --password-stdin
                    docker push ${REGISTRY}:${BUILD_NUMBER}
                """
            }
        }
        stage('Deploy') {
            when { branch 'main' }
            steps {
                sh "kubectl set image deployment/app app=${REGISTRY}:${BUILD_NUMBER}"
            }
        }
    }
    post {
        always { cleanWs() }
    }
}
```

### After: Dagger Module + Minimal `Jenkinsfile`

**Dagger module (`dagger/main.go`):**
```go
package main

import (
    "context"
    "dagger/ci/internal/dagger"
    "fmt"
)

type CI struct{}

func (m *CI) Test(ctx context.Context, src *dagger.Directory) (string, error) {
    return dag.Container().
        From("golang:1.23-alpine").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./...", "-v", "-race"}).
        Stdout(ctx)
}

func (m *CI) BuildAndPublish(
    ctx context.Context,
    src *dagger.Directory,
    registry string,
    username string,
    password *dagger.Secret,
    tag string,
) (string, error) {
    if _, err := m.Test(ctx, src); err != nil {
        return "", fmt.Errorf("tests failed: %w", err)
    }

    binary := dag.Container().
        From("golang:1.23-alpine").
        WithEnvVariable("CGO_ENABLED", "0").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "build", "-o", "/app", "."}).
        File("/app")

    return dag.Container().
        From("alpine:3.20").
        WithFile("/usr/local/bin/app", binary).
        WithEntrypoint([]string{"/usr/local/bin/app"}).
        WithRegistryAuth(registry, username, password).
        Publish(ctx, fmt.Sprintf("%s:%s", registry, tag))
}
```

**Minimal `Jenkinsfile`:**
```groovy
pipeline {
    agent any
    environment {
        GHCR_TOKEN = credentials('ghcr-token')
    }
    stages {
        stage('CI') {
            steps {
                sh """
                    curl -fsSL https://dl.dagger.io/dagger/install.sh | sh
                    ./bin/dagger call build-and-publish \
                        --src=. \
                        --registry=ghcr.io/org/app \
                        --username=ci-user \
                        --password=env:GHCR_TOKEN \
                        --tag=${BUILD_NUMBER}
                """
            }
        }
    }
}
```

### Key Mapping

| Jenkins concept | Dagger equivalent |
|-----------------|-------------------|
| `stage('...')` | Named Dagger Function |
| `sh '...'` | `.WithExec([]string{...})` |
| `credentials()` | `*dagger.Secret` |
| `when { branch }` | Go `if` / Python `if` conditionals |
| `post { always }` | Handled automatically (container cleanup) |
| `agent { docker }` | `.From("image")` |
| `environment {}` | `.WithEnvVariable()` |
| Plugins (SonarQube, etc.) | Dagger containers running the tool directly |

### Key Benefits Over Jenkins

- No plugin management or version conflicts
- No Jenkins server maintenance (controller, agents, updates)
- Pipeline is testable locally with `dagger call`
- No Groovy/CPS restrictions — use a real language

---

## Migrating from Dockerfile-Based Builds

### Before: `Dockerfile`

```dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app/server .

FROM alpine:3.20
RUN apk --no-cache add ca-certificates
COPY --from=builder /app/server /usr/local/bin/server
EXPOSE 8080
USER nobody
ENTRYPOINT ["/usr/local/bin/server"]
```

### After: Dagger Function

```go
func (m *CI) Build(ctx context.Context, src *dagger.Directory) *dagger.Container {
    // Builder stage
    binary := dag.Container().
        From("golang:1.23-alpine").
        WithWorkdir("/app").
        WithFile("/app/go.mod", src.File("go.mod")).
        WithFile("/app/go.sum", src.File("go.sum")).
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithExec([]string{"go", "mod", "download"}).
        WithDirectory("/app", src).
        WithEnvVariable("CGO_ENABLED", "0").
        WithExec([]string{"go", "build", "-ldflags", "-s -w", "-o", "/out/server", "."}).
        File("/out/server")

    // Runtime stage
    return dag.Container().
        From("alpine:3.20").
        WithExec([]string{"apk", "--no-cache", "add", "ca-certificates"}).
        WithFile("/usr/local/bin/server", binary).
        WithExposedPort(8080).
        WithUser("nobody").
        WithEntrypoint([]string{"/usr/local/bin/server"})
}
```

### Instruction-by-Instruction Mapping

| Dockerfile | Dagger (Go) |
|---|---|
| `FROM image` | `.From("image")` |
| `FROM image AS builder` | Assign to a variable: `builder := dag.Container().From(...)` |
| `WORKDIR /app` | `.WithWorkdir("/app")` |
| `COPY . .` | `.WithDirectory("/app", src)` |
| `COPY go.mod .` | `.WithFile("/app/go.mod", src.File("go.mod"))` |
| `COPY --from=builder /app /out` | Extract via `.File()` or `.Directory()`, pass to next container |
| `RUN command` | `.WithExec([]string{"command", "arg1", "arg2"})` |
| `ENV KEY=value` | `.WithEnvVariable("KEY", "value")` |
| `ARG NAME=default` | Use function parameters with defaults |
| `EXPOSE 8080` | `.WithExposedPort(8080)` |
| `USER nobody` | `.WithUser("nobody")` |
| `ENTRYPOINT ["/app"]` | `.WithEntrypoint([]string{"/app"})` |
| `CMD ["--flag"]` | `.WithDefaultArgs([]string{"--flag"})` |
| `VOLUME /data` | Not needed — use `CacheVolume` for caches |
| `HEALTHCHECK` | Health checks are automatic on exposed ports |

### Advantages Over Dockerfiles

- **Conditional logic**: Use `if/else`, loops, error handling — impossible in Dockerfile
- **Better caching**: `CacheVolume` persists across builds; layer ordering is explicit
- **Composability**: Functions call other functions; share code between pipelines
- **Testing**: Test pipeline logic with standard unit test frameworks
- **Multi-arch**: Trivial with `dagger.Platform` parameter
- **Services**: Spin up dependencies (DBs, caches) during build — not possible in Dockerfile

---

## Migrating from Shell Scripts

### Before: `ci.sh`

```bash
#!/bin/bash
set -euo pipefail

echo "=== Running tests ==="
go test ./... -v -race -coverprofile=coverage.out

echo "=== Linting ==="
golangci-lint run --timeout 5m

echo "=== Building ==="
CGO_ENABLED=0 go build -ldflags="-s -w" -o ./bin/app .

echo "=== Building Docker image ==="
docker build -t ghcr.io/org/app:${GITHUB_SHA:-latest} .

echo "=== Pushing image ==="
echo "$GHCR_TOKEN" | docker login ghcr.io -u ci-user --password-stdin
docker push ghcr.io/org/app:${GITHUB_SHA:-latest}

echo "=== Done ==="
```

### After: Dagger Function

```go
package main

import (
    "context"
    "dagger/ci/internal/dagger"
    "fmt"
)

type CI struct{}

func (m *CI) Test(ctx context.Context, src *dagger.Directory) (string, error) {
    return dag.Container().
        From("golang:1.23-alpine").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedCache("/root/.cache/go-build", dag.CacheVolume("gobuild")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "test", "./...", "-v", "-race", "-coverprofile=coverage.out"}).
        Stdout(ctx)
}

func (m *CI) Lint(ctx context.Context, src *dagger.Directory) (string, error) {
    return dag.Container().
        From("golangci/golangci-lint:v1.61-alpine").
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"golangci-lint", "run", "--timeout", "5m"}).
        Stdout(ctx)
}

func (m *CI) Build(src *dagger.Directory) *dagger.File {
    return dag.Container().
        From("golang:1.23-alpine").
        WithEnvVariable("CGO_ENABLED", "0").
        WithMountedCache("/go/pkg/mod", dag.CacheVolume("gomod")).
        WithMountedDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"go", "build", "-ldflags", "-s -w", "-o", "/app", "."}).
        File("/app")
}

func (m *CI) CI(
    ctx context.Context,
    src *dagger.Directory,
    tag string,
    password *dagger.Secret,
) (string, error) {
    // Test + Lint
    if _, err := m.Test(ctx, src); err != nil {
        return "", fmt.Errorf("tests failed: %w", err)
    }
    if _, err := m.Lint(ctx, src); err != nil {
        return "", fmt.Errorf("lint failed: %w", err)
    }

    // Build + Publish
    binary := m.Build(src)
    return dag.Container().
        From("alpine:3.20").
        WithFile("/usr/local/bin/app", binary).
        WithEntrypoint([]string{"/usr/local/bin/app"}).
        WithRegistryAuth("ghcr.io", "ci-user", password).
        Publish(ctx, fmt.Sprintf("ghcr.io/org/app:%s", tag))
}
```

```bash
# Replace: ./ci.sh
# With:
dagger call ci --src=. --tag=$(git rev-parse HEAD) --password=env:GHCR_TOKEN
```

### Advantages Over Shell Scripts

| Shell scripts | Dagger |
|---------------|--------|
| Depends on host tools (go, docker, golangci-lint) | Everything runs in containers — no host dependencies |
| Different behavior on different machines | Identical execution everywhere |
| Manual error handling (`set -e`, `trap`) | Typed errors, proper error propagation |
| No caching (or fragile manual caching) | Built-in content-addressed caching |
| Hard to test script logic | Functions are unit-testable |
| Sequential execution | Easy parallelism with goroutines/async |
| Secrets in environment / command args | First-class `Secret` type, scrubbed from logs |

---

## Migration Checklist

Use this checklist when migrating any CI system to Dagger:

### Phase 1: Setup
- [ ] Install Dagger CLI (`curl -fsSL https://dl.dagger.io/dagger/install.sh | sh`)
- [ ] Initialize module (`dagger init --sdk=go` or `--sdk=python` or `--sdk=typescript`)
- [ ] Choose SDK based on team expertise

### Phase 2: Convert Pipeline Steps
- [ ] Map each CI step to a Dagger Function
- [ ] Replace service containers with `.AsService()` + `.WithServiceBinding()`
- [ ] Replace cache configs with `dag.CacheVolume()`
- [ ] Replace secret references with `*dagger.Secret` parameters
- [ ] Replace matrix strategies with loops in code

### Phase 3: Test Locally
- [ ] Run each function locally: `dagger call <function> --args`
- [ ] Verify caching works (second run should be faster)
- [ ] Test with `--debug` flag for verbose output
- [ ] Use `--interactive` to debug failures

### Phase 4: CI Integration
- [ ] Create minimal CI config that calls `dagger call`
- [ ] Pass CI secrets as `env:SECRET_NAME`
- [ ] Run in parallel with existing pipeline (shadow mode)
- [ ] Compare results and performance

### Phase 5: Cutover
- [ ] Remove old pipeline configuration
- [ ] Update team documentation
- [ ] Share reusable modules via git or Daggerverse
