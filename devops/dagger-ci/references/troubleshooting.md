# Dagger Troubleshooting Guide

## Table of Contents

- [Dagger Engine Not Starting / Connection Errors](#dagger-engine-not-starting--connection-errors)
- [Cache Invalidation Problems](#cache-invalidation-problems)
- [Build Context Too Large](#build-context-too-large)
- [Network Access in Containers](#network-access-in-containers)
- [Debugging Failed Pipelines](#debugging-failed-pipelines)
- [SDK Version Compatibility](#sdk-version-compatibility)
- [OCI Registry Authentication Issues](#oci-registry-authentication-issues)
- [Performance Bottlenecks](#performance-bottlenecks)

---

## Dagger Engine Not Starting / Connection Errors

### Symptom: `Error: failed to connect to dagger engine`

**Common causes and fixes:**

1. **Docker/container runtime not running**
   ```bash
   # Check Docker is running
   docker info
   # If not running:
   sudo systemctl start docker    # Linux
   open -a Docker                  # macOS
   ```

2. **Dagger engine container crashed or stale**
   ```bash
   # Check if engine container exists
   docker ps -a | grep dagger-engine

   # Remove stale engine and restart
   docker rm -f dagger-engine-*
   dagger call --help  # Triggers re-creation

   # Or fully reset
   dagger engine stop
   ```

3. **Docker socket permissions**
   ```bash
   # Linux: add user to docker group
   sudo usermod -aG docker $USER
   newgrp docker

   # Verify socket access
   ls -la /var/run/docker.sock
   ```

4. **Custom Docker contexts or remote Docker hosts**
   ```bash
   # Check current Docker context
   docker context show
   docker context ls

   # Dagger uses DOCKER_HOST if set — ensure it's correct
   echo $DOCKER_HOST

   # Reset to default
   unset DOCKER_HOST
   docker context use default
   ```

5. **Rootless Docker issues**
   ```bash
   # Ensure rootless daemon socket is accessible
   export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
   ```

6. **Firewall/network blocking engine communication**
   ```bash
   # Dagger engine communicates via gRPC on a Unix socket
   # If using TCP, ensure port is not blocked
   # Check: _EXPERIMENTAL_DAGGER_RUNNER_HOST
   echo $_EXPERIMENTAL_DAGGER_RUNNER_HOST
   ```

### Symptom: `context deadline exceeded` on startup

The engine is starting but taking too long (first run pulls the engine image):

```bash
# Increase timeout
export _EXPERIMENTAL_DAGGER_ENGINE_START_TIMEOUT=300

# Pre-pull the engine image
docker pull registry.dagger.io/engine:v0.15.1
```

---

## Cache Invalidation Problems

### Symptom: Changes not picked up — stale build output

1. **Source files not updated in container**
   ```go
   // ❌ Using .WithMountedDirectory mounts a snapshot at call time
   // If you modify files after mounting, changes won't appear

   // ✅ Rebuild the Directory from the host
   src := dag.Host().Directory(".", dagger.HostDirectoryOpts{
       Exclude: []string{".git", "node_modules", "vendor"},
   })
   ```

2. **Cache volume contains stale data**
   ```bash
   # List Dagger cache volumes
   docker volume ls | grep dagger

   # Remove specific cache volume
   docker volume rm <volume-name>

   # Nuclear option: remove all Dagger volumes
   docker volume ls -q | grep dagger | xargs docker volume rm
   ```

3. **Layer caching prevents re-execution**
   ```go
   // Force cache bust by injecting a changing value
   import "time"
   ctr := dag.Container().
       From("alpine:3.20").
       WithEnvVariable("CACHE_BUST", time.Now().String()).
       WithExec([]string{"apk", "update"})
   ```

### Symptom: Cache not working — everything rebuilds every time

1. **Check layer ordering** — put stable layers (deps) before volatile layers (source):
   ```go
   // ✅ Dependencies first, source second
   ctr := dag.Container().From("node:20-slim").
       WithFile("/app/package.json", src.File("package.json")).
       WithExec([]string{"npm", "ci"}).       // Cached if package.json unchanged
       WithDirectory("/app/src", src.Directory("src"))  // Only source changes bust this
   ```

2. **CacheVolume names must be consistent** — typos create new empty volumes:
   ```go
   // These are DIFFERENT caches:
   dag.CacheVolume("go-mod")
   dag.CacheVolume("gomod")
   dag.CacheVolume("go_mod")
   ```

3. **Exclude volatile files from source directory**:
   ```go
   src := dag.Host().Directory(".", dagger.HostDirectoryOpts{
       Exclude: []string{".git", "node_modules", "__pycache__", ".pytest_cache", "dist", "build"},
   })
   ```

---

## Build Context Too Large

### Symptom: Slow pipeline start, high memory usage, or timeout

1. **Exclude unnecessary files**
   ```go
   src := dag.Host().Directory(".", dagger.HostDirectoryOpts{
       Exclude: []string{
           ".git",
           "node_modules",
           "vendor",
           ".venv",
           "__pycache__",
           "*.tar.gz",
           "dist",
           "build",
           ".next",
           "coverage",
       },
   })
   ```

2. **Use `.daggerignore`** — works like `.dockerignore`:
   ```
   # .daggerignore
   .git
   node_modules
   vendor
   *.tar.gz
   dist/
   build/
   .next/
   coverage/
   ```

3. **Pass only needed subdirectories**
   ```go
   // Instead of the entire repo:
   // src := dag.Host().Directory(".")

   // Pass only what's needed:
   appSrc := dag.Host().Directory("./src")
   config := dag.Host().Directory("./config")
   ```

4. **Check context size**
   ```bash
   # See what's being sent
   du -sh . --exclude=.git --exclude=node_modules
   find . -size +10M -not -path './.git/*'
   ```

---

## Network Access in Containers

### Symptom: `Could not resolve host` or connection refused

1. **DNS resolution in containers**
   ```go
   // Containers have network access by default
   // If DNS fails, try explicit DNS config:
   ctr := dag.Container().
       From("alpine:3.20").
       WithExec([]string{"cat", "/etc/resolv.conf"}).  // Debug DNS
       WithExec([]string{"nslookup", "registry.npmjs.org"})  // Test resolution
   ```

2. **Corporate proxy/firewall**
   ```go
   ctr := dag.Container().
       From("alpine:3.20").
       WithEnvVariable("HTTP_PROXY", "http://proxy.corp.com:8080").
       WithEnvVariable("HTTPS_PROXY", "http://proxy.corp.com:8080").
       WithEnvVariable("NO_PROXY", "localhost,127.0.0.1,.corp.com").
       WithExec([]string{"apk", "add", "curl"})
   ```

3. **Service binding connectivity**
   ```go
   // Services are accessed by their alias, not localhost
   // ✅ Correct:
   ctr.WithServiceBinding("db", postgres).
       WithEnvVariable("DB_HOST", "db")

   // ❌ Wrong:
   ctr.WithServiceBinding("db", postgres).
       WithEnvVariable("DB_HOST", "localhost")  // Won't work
   ```

4. **Exposed ports must match**
   ```go
   // Service must expose the port you're connecting to
   svc := dag.Container().
       From("postgres:16-alpine").
       WithExposedPort(5432).  // Required for health check and binding
       AsService()
   ```

### Symptom: Cannot pull images from private registries

```go
// Authenticate before pulling
ctr := dag.Container().
    WithRegistryAuth("ghcr.io", "username", token).
    From("ghcr.io/org/private-image:latest")
```

---

## Debugging Failed Pipelines

### CLI Debug Flags

```bash
# Verbose output — shows full BuildKit logs
dagger call build --src=. --debug

# Interactive mode — drops into shell on failure
dagger call build --src=. --interactive

# Combine both
dagger call build --src=. --debug --interactive
```

### In-Code Debugging

```go
// Insert .Terminal() to pause and inspect container state
ctr := dag.Container().
    From("golang:1.23-alpine").
    WithDirectory("/src", src).
    WithWorkdir("/src").
    Terminal().                    // ← Opens interactive shell here
    WithExec([]string{"go", "build", "./..."})
```

### Inspect Intermediate State

```go
// Print container file listing
func (m *CI) DebugFiles(ctx context.Context, src *dagger.Directory) (string, error) {
    return dag.Container().
        From("golang:1.23-alpine").
        WithDirectory("/src", src).
        WithWorkdir("/src").
        WithExec([]string{"find", ".", "-type", "f", "-name", "*.go"}).
        Stdout(ctx)
}

// Print environment variables
func (m *CI) DebugEnv(ctx context.Context) (string, error) {
    return dag.Container().
        From("alpine:3.20").
        WithExec([]string{"env"}).
        Stdout(ctx)
}
```

### Export Container Filesystem

```bash
# Export container as tarball for inspection
dagger call build --src=. export --path=./debug-output.tar

# Export a directory from the container
dagger call build --src=. directory --path=/app export --path=./app-output/
```

### Check Dagger Engine Logs

```bash
# View engine container logs
docker logs $(docker ps -q --filter name=dagger-engine)

# Follow logs in real-time
docker logs -f $(docker ps -q --filter name=dagger-engine)
```

---

## SDK Version Compatibility

### Symptom: `SDK version mismatch` or unexpected API errors

1. **Check versions**
   ```bash
   # CLI version
   dagger version

   # Module SDK version (in dagger.json)
   cat dagger.json | jq '.sdkVersion'

   # Engine version
   docker inspect $(docker ps -q --filter name=dagger-engine) | jq '.[0].Config.Image'
   ```

2. **Ensure CLI and SDK versions match**
   ```bash
   # Update CLI
   curl -fsSL https://dl.dagger.io/dagger/install.sh | DAGGER_VERSION=0.15.1 sh

   # Regenerate SDK code after CLI update
   dagger develop
   ```

3. **Pin versions in dagger.json**
   ```json
   {
     "name": "my-module",
     "sdk": "go",
     "engineVersion": "v0.15.1"
   }
   ```

4. **Common version mismatch symptoms**
   - `unknown field` errors: SDK is newer than engine
   - Missing methods: SDK is older than engine
   - `failed to get module definition`: regenerate with `dagger develop`

### Updating SDK Dependencies

```bash
# Go SDK
cd dagger/
go get dagger.io/dagger@latest
go mod tidy

# Python SDK
pip install --upgrade dagger-io

# TypeScript SDK
npm update @dagger.io/dagger

# Then regenerate
dagger develop
```

---

## OCI Registry Authentication Issues

### Symptom: `401 Unauthorized` or `403 Forbidden` on publish/pull

1. **GitHub Container Registry (ghcr.io)**
   ```bash
   # Create a PAT with `write:packages` scope
   # Pass as secret:
   dagger call publish --password=env:GHCR_TOKEN
   ```

   ```go
   ctr.WithRegistryAuth("ghcr.io", "USERNAME", token).
       Publish(ctx, "ghcr.io/org/image:tag")
   ```

2. **Docker Hub**
   ```go
   // Use Docker Hub username (not email) and access token
   ctr.WithRegistryAuth("docker.io", "username", token).
       Publish(ctx, "docker.io/org/image:tag")

   // Note: docker.io is the registry, not index.docker.io
   ```

3. **AWS ECR**
   ```bash
   # Get token via AWS CLI
   dagger call publish --password=cmd:"aws ecr get-login-password --region us-east-1"
   ```

   ```go
   ctr.WithRegistryAuth("123456789.dkr.ecr.us-east-1.amazonaws.com", "AWS", ecrToken).
       Publish(ctx, "123456789.dkr.ecr.us-east-1.amazonaws.com/app:tag")
   ```

4. **Google Artifact Registry**
   ```bash
   dagger call publish --password=cmd:"gcloud auth print-access-token"
   ```

   ```go
   ctr.WithRegistryAuth("us-docker.pkg.dev", "oauth2accesstoken", gcrToken).
       Publish(ctx, "us-docker.pkg.dev/project/repo/image:tag")
   ```

5. **Debug auth issues**
   ```bash
   # Test credentials outside Dagger
   echo $TOKEN | docker login ghcr.io -u USERNAME --password-stdin
   docker pull ghcr.io/org/private-image:latest
   ```

---

## Performance Bottlenecks

### Diagnosis

```bash
# Time your pipeline
time dagger call build --src=.

# Check engine resource usage
docker stats $(docker ps -q --filter name=dagger-engine)

# Check disk space (BuildKit cache)
docker system df
```

### Common Bottlenecks and Fixes

1. **Large build context**
   - Use `.daggerignore` or `Exclude` option (see [Build Context Too Large](#build-context-too-large))

2. **No caching / cache misses**
   - Add `CacheVolume` for all package managers
   - Order layers: dependency files → install → source code
   - Use consistent cache volume names

3. **Sequential execution of independent steps**
   ```go
   // ❌ Sequential
   m.Test(ctx, src)
   m.Lint(ctx, src)
   m.SecurityScan(ctx, src)

   // ✅ Parallel with errgroup
   g, ctx := errgroup.WithContext(ctx)
   g.Go(func() error { _, err := m.Test(ctx, src); return err })
   g.Go(func() error { _, err := m.Lint(ctx, src); return err })
   g.Go(func() error { _, err := m.SecurityScan(ctx, src); return err })
   g.Wait()
   ```

4. **Pulling large base images repeatedly**
   ```go
   // ✅ Use slim/alpine variants
   dag.Container().From("golang:1.23-alpine")  // ~250MB vs ~800MB
   dag.Container().From("python:3.12-slim")     // ~150MB vs ~900MB
   dag.Container().From("node:20-slim")          // ~200MB vs ~1GB
   ```

5. **Too many WithExec calls**
   ```go
   // ❌ Multiple execs for related commands
   ctr.WithExec([]string{"apt-get", "update"}).
       WithExec([]string{"apt-get", "install", "-y", "curl"}).
       WithExec([]string{"apt-get", "install", "-y", "git"})

   // ✅ Combine into one
   ctr.WithExec([]string{"sh", "-c", "apt-get update && apt-get install -y curl git"})
   ```

6. **Engine resource constraints**
   ```bash
   # Increase Docker resources (Docker Desktop)
   # Settings > Resources > increase CPU/Memory

   # Or set BuildKit worker limits
   export _EXPERIMENTAL_DAGGER_MAX_PARALLELISM=4
   ```

7. **Disk space exhaustion**
   ```bash
   # Prune BuildKit cache
   docker builder prune

   # Remove old Dagger engine containers
   docker rm -f $(docker ps -aq --filter name=dagger-engine)
   docker volume prune -f
   ```
