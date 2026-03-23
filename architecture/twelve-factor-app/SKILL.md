---
name: twelve-factor-app
description:
  positive: "Use when user designs cloud-native applications, asks about twelve-factor methodology, environment-based configuration, stateless processes, port binding, disposability, dev/prod parity, or backing services as attached resources."
  negative: "Do NOT use for monolithic legacy application design, desktop applications, or specific cloud provider services."
---

# Twelve-Factor App Methodology — Modern Practical Guide

Apply these principles when designing, building, and operating cloud-native applications.
Each factor includes its core rule, modern context, and implementation guidance.

---

## I. Codebase — One Codebase, Many Deploys

Track exactly one codebase per service in version control. Deploy the same codebase to dev, staging, and production.

**Modern considerations:**
- Use a single Git repo per microservice. In monorepos, enforce clear service boundaries with workspace tooling (Nx, Turborepo, Bazel).
- Store Kubernetes manifests, Helm charts, and IaC alongside application code or in a dedicated GitOps repo.
- Never fork a codebase to create a new environment — use config and feature flags instead.

```
# GitOps repo structure
apps/payment-service/
  base/         # deployment.yaml, service.yaml
  overlays/
    staging/    # kustomization.yaml
    production/ # kustomization.yaml
```

---

## II. Dependencies — Declare and Isolate

Explicitly declare all dependencies. Never rely on system-wide packages.

**Rules:**
- Use lock files (`package-lock.json`, `poetry.lock`, `go.sum`) and commit them. Pin versions in production.
- Containerize with minimal base images (`distroless`, `alpine`). The container IS your isolation boundary.
- Generate SBOMs in CI for supply-chain security.

```dockerfile
# Multi-stage build with explicit dependencies
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --production
COPY . .
RUN npm run build

FROM gcr.io/distroless/nodejs22-debian12
COPY --from=build /app/dist /app
COPY --from=build /app/node_modules /app/node_modules
CMD ["app/server.js"]
```

---

## III. Config — Store Config in the Environment

Separate config from code. Config varies between deploys; code does not.

**Implementation layers:**
1. **Environment variables** for simple values (`PORT`, `LOG_LEVEL`, `DATABASE_URL`).
2. **ConfigMaps** (Kubernetes) for structured, non-sensitive config.
3. **Secret managers** (Vault, AWS Secrets Manager, GCP Secret Manager) for credentials — never env vars for secrets in production.
4. **Config services** (Consul, etcd) for dynamic config that changes without redeployment.

```yaml
# Kubernetes: inject config and secrets
spec:
  containers:
    - name: api
      envFrom:
        - configMapRef:
            name: api-config
        - secretRef:
            name: api-secrets
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: password
```

**Validation:** Fail fast at startup if required config is missing. Use schema validation (e.g., `zod`, `pydantic`) to parse config on boot.

```python
from pydantic_settings import BaseSettings

class Config(BaseSettings):
    database_url: str
    redis_url: str
    port: int = 8080
    log_level: str = "info"

config = Config()  # raises ValidationError if DATABASE_URL is unset
```

---

## IV. Backing Services — Treat as Attached Resources

Treat databases, caches, queues, SMTP servers, and third-party APIs as attached resources swappable via config.

**Rules:**
- Reference every backing service by URL or connection string from config.
- Swap a local PostgreSQL for managed RDS by changing one env var — zero code changes.
- Use Kubernetes Services to abstract backing service endpoints.
- Implement health checks and circuit breakers for resilience.

```yaml
# Abstract external database as Kubernetes Service
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  type: ExternalName
  externalName: prod-db.example.com
```

---

## V. Build, Release, Run — Strict Separation

Separate build, release, and run stages. Every release is immutable and uniquely identifiable.

**Pipeline:**
1. **Build:** Compile code, run tests, produce a container image tagged with Git SHA.
2. **Release:** Combine the image with environment-specific config. Tag with semantic version + SHA.
3. **Run:** Execute the release in the target environment. Never patch running containers.

```bash
# Build stage
docker build -t myapp:${GIT_SHA} .
docker push registry.example.com/myapp:${GIT_SHA}

# Release stage — config is baked into the deploy manifest, not the image
helm upgrade myapp ./chart \
  --set image.tag=${GIT_SHA} \
  --values values-production.yaml

# Rollback to any prior release
helm rollback myapp 3
```

**Immutability:** Never `docker exec` into production containers to apply fixes. Build a new image, push it, and deploy.

---

## VI. Processes — Stateless and Share-Nothing

Run the app as one or more stateless processes. Store all persistent data in backing services.

**Rules:**
- Never store session state, uploaded files, or cache in local memory or filesystem.
- Use Redis, Memcached, or a distributed cache for session data. Use object storage (S3, GCS, MinIO) for file uploads.
- Replace sticky sessions with token-based auth (JWT) or centralized session stores.

```python
# WRONG — state in local process memory
sessions = {}

# RIGHT — externalized session store
import redis
session_store = redis.Redis.from_url(os.environ["REDIS_URL"])

def get_session(session_id: str) -> dict:
    data = session_store.get(f"session:{session_id}")
    return json.loads(data) if data else {}
```

**Kubernetes implication:** Pods are ephemeral. Any pod can be killed, rescheduled, or scaled at any time. Design accordingly.

---

## VII. Port Binding — Export Services via Port Binding

The app is self-contained. It binds to a port and serves requests directly.

**Rules:**
- Embed the HTTP server in the app (`express`, `uvicorn`, `net/http`). Do not depend on external app servers.
- Expose via Kubernetes Service and Ingress for TLS, load balancing, and routing.
- One service, one port. Use Kubernetes Service objects for discovery.

```go
// Self-contained HTTP server
func main() {
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }
    http.HandleFunc("/health", healthHandler)
    http.HandleFunc("/api/v1/", apiHandler)
    log.Fatal(http.ListenAndServe(":"+port, nil))
}
```

---

## VIII. Concurrency — Scale Out via the Process Model

Scale by running more processes, not by making processes larger. Use different process types for different workloads.

**Process types:**
- `web` — handles HTTP requests
- `worker` — processes background jobs from a queue
- `scheduler` — triggers periodic tasks
- `consumer` — reads from event streams

**Kubernetes scaling:**
```yaml
# Horizontal Pod Autoscaler
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 3
  maxReplicas: 50
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

Use separate Deployments for each process type. Scale them independently based on their workload characteristics.

---

## IX. Disposability — Fast Startup, Graceful Shutdown

Maximize robustness with fast startup and graceful shutdown. Embrace crash-only design.

**Startup:** Target sub-second startup. Defer heavy initialization to first request or background task. Implement readiness probes so Kubernetes routes traffic only when ready.

**Shutdown:** Handle `SIGTERM`. Stop accepting new requests, drain in-flight work, close connections, exit. Set `terminationGracePeriodSeconds` to match drain time. Make work idempotent so interrupted jobs safely retry.

```python
import signal, sys

def shutdown_handler(signum, frame):
    logger.info("SIGTERM received, draining connections...")
    server.stop(grace=10)  # stop accepting, finish in-flight
    db_pool.close()
    sys.exit(0)

signal.signal(signal.SIGTERM, shutdown_handler)
```

```yaml
spec:
  containers:
    - name: api
      readinessProbe:
        httpGet: { path: /healthz/ready, port: 8080 }
        initialDelaySeconds: 2
        periodSeconds: 5
      livenessProbe:
        httpGet: { path: /healthz/live, port: 8080 }
        initialDelaySeconds: 5
        periodSeconds: 10
  terminationGracePeriodSeconds: 30
```

---

## X. Dev/Prod Parity — Keep Environments Identical

Minimize gaps between development and production: time, personnel, and tooling.
- Run the same container image in every environment. Vary only config.
- Use Docker Compose or Tilt for local dev with the same backing services — not SQLite as a stand-in for Postgres.
- Define infrastructure with IaC (Terraform, Pulumi, Crossplane). Provision staging from the same modules as production.
- Use feature flags (LaunchDarkly, Unleash, Flipt) to decouple deploy from release.

```yaml
# docker-compose.yml — local parity with production
services:
  api:
    build: .
    env_file: .env.local
    ports: ["8080:8080"]
    depends_on: [postgres, redis]
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: myapp
      POSTGRES_PASSWORD: localdev
  redis:
    image: redis:7-alpine
```

---

## XI. Logs — Treat as Event Streams

Write all logs to stdout/stderr. Never write to files inside the container. Let the platform handle aggregation.

**Rules:**
- Use structured logging (JSON). Include `timestamp`, `level`, `service`, `trace_id`, `message`.
- Add correlation IDs propagated through request headers for distributed tracing.
- Ship logs via Fluentd, Fluent Bit, or the platform's native agent to a centralized system (ELK, Loki, Datadog).

```json
{
  "timestamp": "2025-06-01T12:00:00Z",
  "level": "error",
  "service": "payment-api",
  "trace_id": "abc123def456",
  "message": "charge failed",
  "error": "insufficient_funds",
  "customer_id": "cust_789",
  "amount_cents": 5000
}
```

```python
import structlog
logger = structlog.get_logger()

logger.error("charge failed",
    error="insufficient_funds",
    customer_id="cust_789",
    amount_cents=5000)
```

---

## XII. Admin Processes — Run as One-Off Tasks

Run admin tasks (migrations, data fixes, REPL sessions) as one-off processes in the same environment as the app.

**Kubernetes approach:**
- Use Kubernetes Jobs for migrations. Run as init containers or pre-deploy hooks.
- Package admin scripts in the same image so they share code and dependencies.

```yaml
# Database migration as Kubernetes Job
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    "helm.sh/hook": pre-upgrade
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: registry.example.com/myapp:abc123
          command: ["python", "manage.py", "migrate"]
          envFrom:
            - secretRef:
                name: db-credentials
      restartPolicy: Never
  backoffLimit: 3
```

---

## XIII. API-First Design (Modern Addition)

Design APIs before implementation. APIs are the product contract.

**Rules:**
- Write OpenAPI/AsyncAPI specs first. Generate server stubs and client SDKs.
- Version APIs explicitly (`/api/v1/`). Never break backward compatibility within a version.
- Validate requests and responses against the spec in CI.
- Use API gateways (Kong, Envoy, Traefik) for rate limiting, auth, and routing.

```yaml
# openapi.yaml — contract-first
openapi: "3.1.0"
info:
  title: Payment API
  version: "1.0.0"
paths:
  /charges:
    post:
      operationId: createCharge
      requestBody:
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/ChargeRequest"
      responses:
        "201":
          description: Charge created
```

---

## XIV. Telemetry and Observability (Modern Addition)

Instrument everything. Observability is not optional for distributed systems.

**Three pillars:**
1. **Metrics** — Expose Prometheus-format metrics. Track request rate, error rate, latency (RED), and saturation.
2. **Traces** — Use OpenTelemetry. Propagate W3C Trace Context headers across services.
3. **Logs** — Structured, correlated with trace IDs (see Factor XI).

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

provider = TracerProvider()
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)

@app.post("/charges")
async def create_charge(req: ChargeRequest):
    with tracer.start_as_current_span("create_charge") as span:
        span.set_attribute("customer.id", req.customer_id)
        return await process_charge(req)
```

**Kubernetes:** Deploy OpenTelemetry Collector as a DaemonSet. Export to Grafana, Jaeger, or your observability platform.

---

## XV. Security by Default (Modern Addition)

Embed security at every layer. Never bolt it on after the fact.

**Rules:**
- Authenticate every API call. Use OAuth2/OIDC for user-facing APIs, mTLS for service-to-service.
- Apply least-privilege RBAC. Run containers as non-root with read-only filesystems.
- Scan images in CI (Trivy, Grype). Block deployment of images with critical CVEs.
- Encrypt in transit (TLS) and at rest. Rotate secrets automatically.
- Use Kubernetes NetworkPolicies to enforce zero-trust service communication.

```yaml
# Kubernetes: non-root, read-only, least-privilege
spec:
  containers:
    - name: api
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
```

```yaml
# Network Policy: api can only talk to postgres and redis
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-egress
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes: ["Egress"]
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
        - podSelector:
            matchLabels:
              app: redis
```

---

## Quick Reference Checklist

| Factor | Key Question | Anti-Pattern |
|--------|-------------|--------------|
| I. Codebase | One repo per deployable? | Multiple apps in one repo without boundaries |
| II. Dependencies | All deps declared and locked? | `apt-get install` in production without pinning |
| III. Config | All config from environment? | Hardcoded connection strings |
| IV. Backing Services | Swappable via config? | Direct filesystem paths to local DBs |
| V. Build/Release/Run | Immutable artifacts? | SSH into prod and `git pull` |
| VI. Processes | Fully stateless? | Local file uploads, in-memory sessions |
| VII. Port Binding | Self-contained server? | Deploying a WAR into Tomcat |
| VIII. Concurrency | Horizontal scaling? | Vertical scaling only, single-threaded |
| IX. Disposability | Fast start, clean stop? | 60s startup, no SIGTERM handling |
| X. Dev/Prod Parity | Same stack everywhere? | SQLite in dev, Postgres in prod |
| XI. Logs | Stdout only, structured? | Writing to `/var/log/app.log` |
| XII. Admin | One-off jobs, same env? | Manual SQL on production DB |
| XIII. API-First | Contract defined first? | Ad-hoc endpoints, no schema |
| XIV. Telemetry | Metrics, traces, logs? | `print("error happened")` |
| XV. Security | Zero-trust, least-privilege? | Root containers, no net policies |
