# Testcontainers Troubleshooting Guide

<!-- TOC -->
- [Docker Daemon Not Found](#docker-daemon-not-found)
- [CI/CD Docker-in-Docker Issues](#cicd-docker-in-docker-issues)
- [Ryuk Container Failures](#ryuk-container-failures)
- [Port Mapping Problems](#port-mapping-problems)
- [Container Startup Timeouts](#container-startup-timeouts)
- [Resource Cleanup](#resource-cleanup)
- [Image Pull Rate Limits](#image-pull-rate-limits)
- [WSL2 Issues](#wsl2-issues)
- [Testcontainers Cloud Troubleshooting](#testcontainers-cloud-troubleshooting)
- [Diagnostic Commands](#diagnostic-commands)
<!-- /TOC -->

---

## Docker Daemon Not Found

**Symptom:** `Could not find a valid Docker environment` or
`java.lang.IllegalStateException: Could not find a valid Docker environment`

### Causes and Fixes

**1. Docker not installed or not running**

```bash
# Check Docker is running
docker info
# If not running:
sudo systemctl start docker       # Linux
open -a Docker                     # macOS (Docker Desktop)
```

**2. Docker socket not accessible**

```bash
# Check socket permissions
ls -la /var/run/docker.sock
# Fix: add user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

**3. Custom Docker host**

If Docker is on a remote host or non-default socket:

```bash
# Set Docker host explicitly
export DOCKER_HOST=tcp://localhost:2375
# Or for socket
export DOCKER_HOST=unix:///var/run/docker.sock
```

Testcontainers-specific override:
```bash
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock
```

**4. Podman instead of Docker**

```bash
# Enable Podman socket
systemctl --user enable --now podman.socket
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
export TESTCONTAINERS_RYUK_DISABLED=true  # Ryuk may not work with Podman
```

**5. Colima (macOS alternative)**

```bash
# Start Colima
colima start
export DOCKER_HOST=unix://$HOME/.colima/default/docker.sock
export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock
```

### Configuration File

Create `~/.testcontainers.properties`:
```properties
docker.host=unix:///var/run/docker.sock
# or
docker.host=tcp://localhost:2375
docker.tls.verify=0
```

---

## CI/CD Docker-in-Docker Issues

### GitHub Actions

Docker is pre-installed on `ubuntu-latest`. Tests should work out of the box.

If using a custom runner:
```yaml
jobs:
  test:
    runs-on: self-hosted
    services:
      dind:
        image: docker:dind
        options: --privileged
    env:
      DOCKER_HOST: tcp://dind:2375
      DOCKER_TLS_CERTDIR: ""
      TESTCONTAINERS_HOST_OVERRIDE: dind
```

### GitLab CI

```yaml
integration-tests:
  image: maven:3.9-eclipse-temurin-21
  services:
    - docker:dind
  variables:
    DOCKER_HOST: tcp://docker:2375
    DOCKER_TLS_CERTDIR: ""
    TESTCONTAINERS_HOST_OVERRIDE: docker
  script:
    - mvn verify
```

**Common mistake:** Missing `TESTCONTAINERS_HOST_OVERRIDE`. Without it,
Testcontainers tries to connect to containers via `localhost`, but the
containers are running inside the DinD service.

### Jenkins

```groovy
pipeline {
    agent {
        docker {
            image 'maven:3.9-eclipse-temurin-21'
            args '-v /var/run/docker.sock:/var/run/docker.sock'
        }
    }
    stages {
        stage('Test') {
            steps {
                sh 'mvn verify'
            }
        }
    }
}
```

⚠️ Mounting the Docker socket gives the build container full Docker access.
Use Testcontainers Cloud for more secure CI setups.

### CircleCI

```yaml
jobs:
  test:
    machine:
      image: ubuntu-2204:current
    steps:
      - checkout
      - run: mvn verify
```

Use `machine` executor (not `docker`) — it provides a full VM with Docker.

### Kubernetes-Based CI (Tekton, ArgoCD)

Docker-in-Docker is often restricted. Options:
1. **Testcontainers Cloud** — no Docker daemon needed in the pod
2. **Sysbox runtime** — enables secure DinD in k8s
3. **Kaniko-based Docker socket** — mount host Docker socket (security risk)

---

## Ryuk Container Failures

Ryuk is the resource reaper sidecar that cleans up containers after test runs.

### Symptoms

- `Could not start Ryuk container`
- `Ryuk container is not running`
- Orphaned containers accumulating

### Fixes

**1. Permission denied starting Ryuk**

```bash
# Ryuk needs Docker socket access
export TESTCONTAINERS_RYUK_DISABLED=true  # temporary workaround
```

Better fix: ensure the Docker socket is accessible to the test process.

**2. Ryuk not supported (rootless Docker, Podman)**

```bash
export TESTCONTAINERS_RYUK_DISABLED=true
```

When Ryuk is disabled, you MUST ensure containers are cleaned up manually:
```java
// Always use try-with-resources or @Container annotation
try (PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16-alpine")) {
    pg.start();
    // tests
} // container stopped and removed here
```

**3. Ryuk times out**

```bash
# Increase Ryuk timeout (default 30s)
export RYUK_CONNECTION_TIMEOUT=60s
export RYUK_RECONNECTION_TIMEOUT=30s
```

**4. Custom Ryuk image (air-gapped environments)**

```properties
# ~/.testcontainers.properties
ryuk.container.image=my-registry.com/testcontainers/ryuk:0.7.0
```

---

## Port Mapping Problems

### Symptom: Connection Refused

**Root cause:** Using the container's internal port instead of the mapped host
port.

```java
// ❌ WRONG — internal port
int port = 5432;

// ✅ CORRECT — mapped host port
int port = postgres.getMappedPort(5432);
String host = postgres.getHost();
```

### Symptom: Port Already in Use

**Root cause:** Hardcoded host ports.

```java
// ❌ WRONG — hardcoded port will conflict
container.withFixedExposedPort(5432, 5432);

// ✅ CORRECT — random port mapping (default)
container.withExposedPorts(5432);
int hostPort = container.getMappedPort(5432);
```

### Symptom: Port Not Available Yet

Container is "running" but the service inside isn't ready.

```java
// ❌ WRONG — no wait strategy
container.withExposedPorts(8080);
container.start();
// Service may not be ready!

// ✅ CORRECT — wait for readiness
container.withExposedPorts(8080);
container.waitingFor(Wait.forHttp("/health").forStatusCode(200));
container.start();
// Service is ready to accept connections
```

### Multiple Exposed Ports

```java
container.withExposedPorts(8080, 8443, 9090);

// Each gets a different random host port
int httpPort = container.getMappedPort(8080);
int httpsPort = container.getMappedPort(8443);
int metricsPort = container.getMappedPort(9090);
```

---

## Container Startup Timeouts

### Symptom

`ContainerLaunchException: Timed out waiting for container port to open`

### Fixes

**1. Increase startup timeout**

```java
// Java
container.withStartupTimeout(Duration.ofMinutes(3));

// Or on the wait strategy
container.waitingFor(
    Wait.forListeningPort().withStartupTimeout(Duration.ofMinutes(3))
);
```

```typescript
// Node.js
container.withStartupTimeout(180_000);
```

```go
// Go
wait.ForListeningPort("5432/tcp").WithStartupTimeout(3 * time.Minute)
```

**2. Wrong wait strategy**

```java
// ❌ Database isn't ready just because port is open
.waitingFor(Wait.forListeningPort())

// ✅ Wait for actual readiness
.waitingFor(Wait.forLogMessage(".*database system is ready to accept connections.*", 2))
```

**3. Image pull timeout**

First run pulls the image, which can be slow:
```bash
# Pre-pull images before tests
docker pull postgres:16-alpine
docker pull confluentinc/cp-kafka:7.6.0
docker pull redis:7-alpine
```

**4. Insufficient resources**

```bash
# Check available resources
docker system info | grep -E "CPUs|Memory"
docker system df

# Free up resources
docker system prune -f
```

**5. Check container logs for errors**

```java
// Java — get container logs
String logs = container.getLogs();
System.out.println(logs);

// Or stream logs
container.followOutput(outputFrame ->
    System.out.println(outputFrame.getUtf8String()));
```

```typescript
// Node.js
const stream = await container.logs();
stream.on("data", (line) => console.log(line));
```

---

## Resource Cleanup

### Orphaned Containers

```bash
# List Testcontainers-managed containers
docker ps --filter "label=org.testcontainers=true"

# Remove all Testcontainers containers
docker rm -f $(docker ps -q --filter "label=org.testcontainers=true")

# Remove Testcontainers networks
docker network ls --filter "label=org.testcontainers=true" -q | xargs docker network rm

# Nuclear option: remove everything
docker system prune -af --volumes
```

### Memory Leaks in Tests

```java
// ❌ Container never stopped
PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16-alpine");
pg.start();
// test runs, but if exception occurs, container leaks

// ✅ Always use try-with-resources
try (PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16-alpine")) {
    pg.start();
    // container always stopped
}

// ✅ Or use @Container annotation (JUnit manages lifecycle)
@Container
static PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:16-alpine");
```

### Database Connection Pool Exhaustion

```java
// ❌ Connections leak
@Test
void test1() {
    Connection conn = DriverManager.getConnection(postgres.getJdbcUrl(), ...);
    // forgot to close!
}

// ✅ Always close connections
@Test
void test2() {
    try (Connection conn = DriverManager.getConnection(postgres.getJdbcUrl(), ...)) {
        // use connection
    }
}
```

---

## Image Pull Rate Limits

### Docker Hub Rate Limits

Anonymous: 100 pulls/6h, authenticated: 200 pulls/6h.

**Symptoms:**
- `toomanyrequests: You have reached your pull rate limit`
- `Error response from daemon: pull access denied`

### Fixes

**1. Authenticate with Docker Hub**

```bash
docker login
# Testcontainers uses Docker's credential store automatically
```

**2. Use a registry mirror**

```json
// /etc/docker/daemon.json
{
  "registry-mirrors": ["https://mirror.gcr.io"]
}
```

```properties
# ~/.testcontainers.properties
docker.registry.mirror=mirror.gcr.io
```

**3. Pre-pull images in CI**

```yaml
# GitHub Actions
- name: Pre-pull test images
  run: |
    docker pull postgres:16-alpine
    docker pull redis:7-alpine
    docker pull confluentinc/cp-kafka:7.6.0
```

**4. Use a private registry**

```java
// Pull from private registry
new PostgreSQLContainer<>(
    DockerImageName.parse("my-registry.com/postgres:16-alpine")
        .asCompatibleSubstituteFor("postgres"))
```

**5. Image name substitution (org-wide)**

```properties
# ~/.testcontainers.properties
# Prefix all image pulls with your registry
docker.image.substitutor=org.testcontainers.utility.ImageNameSubstitutor
```

---

## WSL2 Issues

### Docker Desktop WSL2 Backend

**Symptom:** Testcontainers can't find Docker in WSL2.

```bash
# Ensure Docker Desktop WSL integration is enabled
# Docker Desktop → Settings → Resources → WSL Integration → Enable for your distro

# Verify in WSL
docker info
```

**Symptom:** Volume mounts fail in WSL2.

```bash
# Use /tmp or home directory for mounts
# ❌ Windows paths don't work
container.withFileSystemBind("C:\\Users\\me\\data", "/data");

# ✅ WSL paths work
container.withFileSystemBind("/home/me/data", "/data");
```

### WSL2 Without Docker Desktop

```bash
# Install Docker Engine directly in WSL2
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io
sudo service docker start

# Add user to docker group
sudo usermod -aG docker $USER
```

### Performance

```bash
# Store project files in WSL filesystem (not /mnt/c/)
# WSL2 native filesystem is much faster than Windows mount
cd ~/projects/my-app  # ✅ Fast
cd /mnt/c/projects/my-app  # ❌ Slow
```

---

## Testcontainers Cloud Troubleshooting

### Agent Not Connecting

```bash
# Check agent status
testcontainers-cloud agent status

# Verify token
echo $TC_CLOUD_TOKEN

# Test connectivity
testcontainers-cloud agent diagnose
```

### Containers Not Starting in Cloud

**1. Image not accessible from cloud**

Testcontainers Cloud pulls images from public registries. For private images:
```bash
# Configure registry credentials in TC Cloud dashboard
# or use the agent's credential helper
testcontainers-cloud agent configure-registry
```

**2. Network timeout**

```properties
# ~/.testcontainers.properties
tc.cloud.timeout=120
```

**3. Agent version mismatch**

```bash
# Update the agent
testcontainers-cloud agent update

# Or reinstall
curl -fsSL https://get.testcontainers.cloud | sh
```

### Debugging Cloud Execution

```bash
# Enable verbose logging
export TC_CLOUD_LOGS_VERBOSE=true

# Check agent logs
testcontainers-cloud agent logs

# Run with debug output
export TESTCONTAINERS_LOG_LEVEL=DEBUG
```

### CI/CD with Testcontainers Cloud

```yaml
# Ensure the agent is set up before tests
- uses: atomicjar/testcontainers-cloud-setup@v1
  with:
    token: ${{ secrets.TC_CLOUD_TOKEN }}
    wait: true  # wait for agent to be ready
```

---

## Diagnostic Commands

Quick diagnostic script for common issues:

```bash
# Docker basics
docker version
docker info
docker ps -a --filter "label=org.testcontainers=true"

# Resource usage
docker system df
docker stats --no-stream

# Network
docker network ls
docker network inspect bridge

# Check Testcontainers properties
cat ~/.testcontainers.properties 2>/dev/null || echo "No properties file"

# Environment variables
env | grep -i -E "docker|testcontainers|ryuk"

# Ryuk status
docker ps --filter "name=ryuk"

# Recent container logs
docker logs $(docker ps -lq --filter "label=org.testcontainers=true") 2>&1 | tail -50
```

### Java Debug Logging

```xml
<!-- logback-test.xml -->
<configuration>
  <logger name="org.testcontainers" level="DEBUG"/>
  <logger name="com.github.dockerjava" level="WARN"/>
  <logger name="org.testcontainers.utility.RyukResourceReaper" level="DEBUG"/>
</configuration>
```

### Node.js Debug Logging

```bash
export DEBUG=testcontainers*
npm test
```

### Go Debug Logging

```go
import "github.com/testcontainers/testcontainers-go"

// Enable debug logging
testcontainers.Logger = testcontainers.TestLogger(t)
```

### Python Debug Logging

```python
import logging
logging.basicConfig(level=logging.DEBUG)
logging.getLogger("testcontainers").setLevel(logging.DEBUG)
```
