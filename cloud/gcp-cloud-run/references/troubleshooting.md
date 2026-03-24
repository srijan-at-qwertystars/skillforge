# Cloud Run Troubleshooting Guide

## Table of Contents

- [Cold Start Debugging](#cold-start-debugging)
- [Container Contract Violations](#container-contract-violations)
- [Memory and CPU Limits Exceeded](#memory-and-cpu-limits-exceeded)
- [Request Timeout Issues](#request-timeout-issues)
- [VPC Connector Issues](#vpc-connector-issues)
- [Cloud SQL Connection Problems](#cloud-sql-connection-problems)
- [Permission Errors](#permission-errors)
- [Health Check Failures](#health-check-failures)
- [Revision Not Serving](#revision-not-serving)
- [General Debugging Commands](#general-debugging-commands)

---

## Cold Start Debugging

Cold starts occur when Cloud Run spins up a new instance. Typical latency: 500ms–10s+ depending on language, image size, and initialization.

### Diagnose

```bash
# Check cold start latency in logs
gcloud logging read 'resource.type="cloud_run_revision" AND \
  resource.labels.service_name="my-api" AND \
  httpRequest.latency>"2s"' \
  --limit=20 --format=json

# Check instance startup time
gcloud run revisions describe my-api-00005 \
  --region=us-central1 --format="yaml(status)"
```

### Common causes and fixes

| Cause | Fix |
|-------|-----|
| Large container image (>1GB) | Use multi-stage builds, distroless/Alpine base images |
| Heavy import-time initialization | Defer DB pools, ML models to first-request or background thread |
| Slow language runtime (JVM, Python) | Enable `--cpu-boost`, use GraalVM native-image, or precompiled deps |
| No warm instances | Set `--min-instances=1` (or more for production) |
| VPC connector overhead | Switch to Direct VPC egress (adds 1-3s to cold start with connector) |
| Many dependencies | Trim unused packages, use compiled languages for fast boot |

### Measure cold start vs warm request

```bash
# Force a cold start — deploy then immediately hit the URL
gcloud run deploy my-api --image=IMG --max-instances=1 --region=us-central1
time curl -s -o /dev/null -w "%{time_total}" https://my-api-HASH.a.run.app/
```

---

## Container Contract Violations

Cloud Run requires containers to meet specific contract rules. Violations prevent startup.

### The contract

1. **Must listen on `0.0.0.0:$PORT`** — `$PORT` defaults to 8080, set by Cloud Run
2. **Must be Linux x86_64 (amd64)** — ARM images fail silently
3. **Must respond to HTTP requests** (services only)
4. **Must start within the startup timeout** (default 240s, max 3600s)
5. **Cannot write to the filesystem** beyond `/tmp` (read-only root fs)

### Common errors and fixes

**"Container failed to start. Failed to start and then listen on the port defined by the PORT environment variable."**
```bash
# Fix: Ensure app listens on 0.0.0.0, not 127.0.0.1 or localhost
# Wrong:
server.listen(8080, '127.0.0.1')
# Right:
server.listen(process.env.PORT || 8080, '0.0.0.0')
```

**"Container called exit(1)" or "Container exited with non-zero status"**
```bash
# Debug: Run container locally
docker run -p 8080:8080 -e PORT=8080 YOUR_IMAGE
# Check logs for crashes, missing env vars, or failed connections
```

**Wrong architecture**
```bash
# Build for linux/amd64 explicitly
docker build --platform linux/amd64 -t IMG .
```

---

## Memory and CPU Limits Exceeded

### Symptoms
- Container killed mid-request (HTTP 500 to client)
- Logs show: `"Memory limit of X MiB exceeded with Y MiB used"`
- OOMKilled signal

### Diagnose

```bash
# Check for OOM kills
gcloud logging read 'resource.type="cloud_run_revision" AND \
  resource.labels.service_name="my-api" AND \
  textPayload=~"Memory limit"' \
  --limit=10

# Check current resource config
gcloud run services describe my-api --region=us-central1 \
  --format="value(spec.template.spec.containers[0].resources.limits)"
```

### Fix

```bash
# Increase memory (max 32Gi)
gcloud run services update my-api --memory=2Gi --region=us-central1

# Increase CPU (1, 2, 4, or 8 vCPUs)
gcloud run services update my-api --cpu=4 --region=us-central1
```

### Memory rules

| CPU | Min Memory | Max Memory |
|-----|-----------|------------|
| 1 | 128Mi | 4Gi |
| 2 | 256Mi | 8Gi |
| 4 | 512Mi | 16Gi |
| 8 | 1Gi | 32Gi |

### Best practices
- Profile memory usage under load before deploying
- Watch for memory leaks — Cloud Run instances are long-lived when `min-instances>0`
- GCS FUSE mounts consume container memory for caching
- Reduce concurrency (`--concurrency`) to lower per-instance memory pressure

---

## Request Timeout Issues

Default timeout: **300s (5 min)**. Maximum: **3600s (60 min)**.

### Symptoms
- HTTP 504 Gateway Timeout returned to client
- Long-running requests killed before completion
- Streaming connections dropped

### Diagnose

```bash
# Check current timeout
gcloud run services describe my-api --region=us-central1 \
  --format="value(spec.template.spec.timeoutSeconds)"

# Find timeout errors in logs
gcloud logging read 'resource.type="cloud_run_revision" AND \
  resource.labels.service_name="my-api" AND \
  httpRequest.status=504' --limit=10
```

### Fix

```bash
# Increase timeout (max 3600s = 60 min)
gcloud run services update my-api --timeout=900 --region=us-central1
```

### Patterns for long-running work
- **Don't block the request** — return 202 Accepted, process async
- Use Cloud Run Jobs for batch tasks >60min
- Use Cloud Tasks to enqueue work and process in background
- For streaming: enable always-on CPU (`--no-cpu-throttling`), set appropriate timeout
- For WebSocket: timeout applies per-message, not per-connection (with HTTP/2)

---

## VPC Connector Issues

### Common problems

**"Serverless VPC Access connector is not ready"**
```bash
# Check connector status
gcloud compute networks vpc-access connectors describe my-conn \
  --region=us-central1

# Connector must be READY. If ERROR, recreate:
gcloud compute networks vpc-access connectors delete my-conn --region=us-central1
gcloud compute networks vpc-access connectors create my-conn \
  --region=us-central1 --network=my-vpc --range=10.8.0.0/28 \
  --min-instances=2 --max-instances=10
```

**No connectivity to private resources**
```bash
# Verify firewall allows traffic from connector subnet
gcloud compute firewall-rules list --filter="network=my-vpc"

# Check egress setting — must be all-traffic for private IP access
gcloud run services describe my-api --region=us-central1 \
  --format="value(spec.template.metadata.annotations['run.googleapis.com/vpc-access-egress'])"
```

**Connector IP exhaustion**
- `/28` subnet = 16 IPs, only ~10 usable for connector VMs
- If connector needs more capacity, use a larger subnet or Direct VPC egress

### Switch to Direct VPC Egress (recommended)

```bash
# Remove connector, use direct VPC
gcloud run deploy my-api --image=IMG \
  --network=my-vpc --subnet=my-subnet \
  --vpc-egress=all-traffic \
  --clear-vpc-connector \
  --region=us-central1
```

Benefits: no connector VMs to manage, lower cold start overhead, auto-scales with Cloud Run.

---

## Cloud SQL Connection Problems

### Common errors

**"Connection refused" or "Can't connect to MySQL/PostgreSQL server"**

```bash
# Verify Cloud SQL instance is running
gcloud sql instances describe INSTANCE_NAME --format="value(state)"

# Check Cloud Run has the connection configured
gcloud run services describe my-api --region=us-central1 \
  --format="value(spec.template.metadata.annotations['run.googleapis.com/cloudsql-instances'])"
```

### Connection pooling

Cloud SQL Auth Proxy creates a Unix socket per instance. Pooling happens at the application level.

```python
# Python — use connection pool with SQLAlchemy
engine = create_engine(
    "postgresql+pg8000://",
    creator=connect,
    pool_size=5,          # Don't exceed Cloud SQL max_connections / num_instances
    max_overflow=2,
    pool_timeout=30,
    pool_recycle=1800,    # Recycle connections every 30 min
)
```

### Cloud SQL Admin API quota

High-traffic services with many instances may hit Cloud SQL Admin API rate limits. Fixes:
- Use private IP via VPC instead of Cloud SQL Auth Proxy
- Set `--max-instances` to limit connection proliferation
- Use PgBouncer or ProxySQL as connection pooler sidecar

### Required IAM roles

| Role | Purpose |
|------|---------|
| `roles/cloudsql.client` | Connect via Auth Proxy |
| `roles/cloudsql.instanceUser` | Connect with IAM DB authentication |

```bash
gcloud projects add-iam-policy-binding PROJECT \
  --member=serviceAccount:SA@PROJECT.iam.gserviceaccount.com \
  --role=roles/cloudsql.client
```

---

## Permission Errors

### HTTP 401 Unauthorized — calling a private service

```bash
# Check who has invoker access
gcloud run services get-iam-policy my-api --region=us-central1

# Grant invoker to calling service account
gcloud run services add-iam-policy-binding my-api \
  --member=serviceAccount:caller@PROJECT.iam.gserviceaccount.com \
  --role=roles/run.invoker \
  --region=us-central1
```

### HTTP 403 Forbidden — org policy blocking

```bash
# Check organization policies
gcloud org-policies list --project=PROJECT

# Common blockers:
# - iam.allowedPolicyMemberDomains (blocks allUsers)
# - run.allowedIngress (restricts to internal-only)
```

### Key IAM roles for Cloud Run

| Role | Permissions |
|------|------------|
| `roles/run.invoker` | Call the service (HTTP requests) |
| `roles/run.admin` | Full management (deploy, delete, update traffic) |
| `roles/run.developer` | Deploy new revisions, read configs |
| `roles/run.viewer` | Read-only access to service configs and status |

### Common mistakes
- Granting `roles/run.admin` when only `roles/run.invoker` is needed
- Forgetting to grant `roles/iam.serviceAccountUser` on the runtime SA to the deployer
- Using a service account without `roles/secretmanager.secretAccessor` when using secrets
- Not propagating IAM changes (wait 60s after binding)

---

## Health Check Failures

### Startup probe failures

**Symptom:** Revision never becomes ready. Logs show repeated health check attempts.

```bash
# Check revision status
gcloud run revisions describe REVISION --region=us-central1 \
  --format="yaml(status.conditions)"

# Look for startup probe failures
gcloud logging read 'resource.type="cloud_run_revision" AND \
  resource.labels.revision_name="REVISION" AND \
  "startup probe"' --limit=10
```

**Fixes:**
- Increase `failureThreshold` (default 3, try 12+ for slow-starting apps)
- Increase `timeoutSeconds` per probe check
- Verify the health endpoint returns HTTP 200 quickly
- Don't block the health endpoint on DB connectivity

### Liveness probe failures

Liveness probe failures cause instance restarts. If your app becomes unhealthy after some time:
- Check for memory leaks or resource exhaustion
- Ensure the health endpoint doesn't depend on external services
- Use a simple in-process health check (`return 200 OK`)

### Probe configuration tips

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 0
  periodSeconds: 2        # Check every 2s during startup
  failureThreshold: 15    # Allow 30s total (2s × 15)
  timeoutSeconds: 3
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  periodSeconds: 30       # Don't check too frequently
  failureThreshold: 3
  timeoutSeconds: 5
```

---

## Revision Not Serving

### Symptoms
- Service URL returns 404 or 503
- Revision shows 0% traffic
- New deployment didn't take traffic

### Diagnose

```bash
# Check traffic allocation
gcloud run services describe my-api --region=us-central1 \
  --format="yaml(status.traffic)"

# Check revision status
gcloud run revisions list --service=my-api --region=us-central1

# Check for conditions
gcloud run revisions describe REVISION --region=us-central1 \
  --format="yaml(status.conditions)"
```

### Common causes

| Cause | Fix |
|-------|-----|
| Deployed with `--no-traffic` | Route traffic: `gcloud run services update-traffic my-api --to-latest` |
| Previous revision still has 100% | Explicitly set traffic split |
| Revision failed health checks | Fix container startup (see above) |
| Revision image not found | Verify image exists in Artifact Registry |
| Revision quota exceeded (1000 max) | Delete old revisions |

### Force traffic to latest

```bash
gcloud run services update-traffic my-api --to-latest --region=us-central1
```

### Delete stuck revisions

```bash
# Cannot delete revisions serving traffic — reassign first
gcloud run services update-traffic my-api \
  --to-revisions=GOOD_REVISION=100 --region=us-central1
gcloud run revisions delete BAD_REVISION --region=us-central1
```

---

## General Debugging Commands

```bash
# Tail live logs
gcloud run services logs tail my-api --region=us-central1

# Read recent logs with severity filter
gcloud logging read 'resource.type="cloud_run_revision" AND \
  resource.labels.service_name="my-api" AND \
  severity>=ERROR' --limit=50 --format=json

# Check service status
gcloud run services describe my-api --region=us-central1 \
  --format="yaml(status)"

# List all revisions with status
gcloud run revisions list --service=my-api --region=us-central1 \
  --format="table(name,status.conditions[0].type,status.conditions[0].status,spec.containers[0].image)"

# Check instance count and scaling
gcloud monitoring metrics list --filter="metric.type=run.googleapis.com/container/instance_count"

# Test connectivity from inside the container
gcloud run deploy debug --image=gcr.io/google.com/cloudsdktool/cloud-sdk:slim \
  --command="sleep,3600" --no-cpu-throttling --region=us-central1
# Then exec in via Cloud Shell or log commands

# Export service config for review
gcloud run services describe my-api --region=us-central1 --format=export > debug-service.yaml
```
