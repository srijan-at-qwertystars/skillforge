# Cloud Run Advanced Patterns

## Table of Contents

- [Multi-Container Sidecars](#multi-container-sidecars)
- [Session Affinity](#session-affinity)
- [Startup CPU Boost](#startup-cpu-boost)
- [GPU Support](#gpu-support)
- [gRPC on Cloud Run](#grpc-on-cloud-run)
- [Cloud Run + Cloud CDN](#cloud-run--cloud-cdn)
- [Binary Authorization](#binary-authorization)
- [Volume Mounts](#volume-mounts)
- [Always-On CPU for Background Processing](#always-on-cpu-for-background-processing)
- [Cloud Run Integrations](#cloud-run-integrations)

---

## Multi-Container Sidecars

Cloud Run supports up to 10 containers per instance. One ingress container handles HTTP; sidecars run alongside for proxying, monitoring, auth, or data processing.

**Key rules:**
- Only ONE container exposes the external port (ingress container)
- All containers share `localhost` networking and can communicate via ports
- Shared in-memory volumes enable file exchange between containers
- Container startup order is controlled via `container-dependencies` annotation

### Service YAML with Sidecar

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: my-api
spec:
  template:
    metadata:
      annotations:
        # app depends on proxy — proxy starts first
        run.googleapis.com/container-dependencies: '{"app": ["proxy"]}'
    spec:
      containers:
      - name: proxy
        image: us-docker.pkg.dev/PROJECT/repo/envoy:v1
        ports:
        - name: http1
          containerPort: 8080
        resources:
          limits:
            cpu: 500m
            memory: 256Mi
      - name: app
        image: us-docker.pkg.dev/PROJECT/repo/app:v1
        env:
        - name: PORT
          value: "8888"
        resources:
          limits:
            cpu: "1"
            memory: 512Mi
        volumeMounts:
        - name: shared
          mountPath: /shared
      volumes:
      - name: shared
        emptyDir:
          medium: Memory
          sizeLimit: 128Mi
```

### Deploy

```bash
gcloud run services replace service.yaml --region=us-central1
```

### Common sidecar use cases

| Sidecar | Purpose |
|---------|---------|
| OpenTelemetry Collector | Export traces/metrics to backends |
| Envoy/Nginx | Reverse proxy, mTLS, header manipulation |
| Cloud SQL Auth Proxy | Secure DB connections (auto-configured with `--add-cloudsql-instances`) |
| OPA (Open Policy Agent) | Request-level authorization |
| Log processor | Transform/forward structured logs |

---

## Session Affinity

Routes requests from the same client to the same instance using a cookie (30-day TTL). Best-effort only — instances may still shut down.

### Enable

```bash
gcloud run services update my-api --session-affinity --region=us-central1
```

### YAML

```yaml
metadata:
  annotations:
    run.googleapis.com/sessionAffinity: "true"
```

### When to use
- In-memory caches (warm cache hits)
- WebSocket-like patterns
- Local session state as optimization (always persist critical state externally)

### Caveats
- Not guaranteed — instances scale down, crash, or get reassigned
- Not compatible with Cloud Load Balancer session affinity on serverless NEGs
- Don't rely on it for correctness — only performance

---

## Startup CPU Boost

Temporarily allocates additional CPU during container startup (first ~10 seconds), reducing cold start latency by up to 50%.

### Enable

```bash
gcloud run services update my-api --cpu-boost --region=us-central1
```

### YAML

```yaml
metadata:
  annotations:
    run.googleapis.com/startup-cpu-boost: "true"
```

### Terraform

```hcl
resources {
  limits       = { cpu = "2", memory = "1Gi" }
  startup_cpu_boost = true
}
```

### Best for
- JVM languages (Java, Kotlin, Scala) — heaviest startup
- Python/Node with large dependency trees
- Containers loading ML models or large configs at startup
- Always combine with `--min-instances=1+` for production

---

## GPU Support

Attach an NVIDIA GPU to Cloud Run instances for AI inference, video processing, or other GPU workloads.

### Supported GPUs

| GPU | Min CPU | Min Memory | Regions |
|-----|---------|------------|---------|
| NVIDIA L4 | 4 | 16 GiB | us-central1, europe-west4, asia-southeast1 |
| NVIDIA RTX PRO 6000 (Blackwell) | 20 | 80 GiB | Limited availability |

### Deploy with GPU

```bash
gcloud beta run deploy my-ml-api \
  --image=us-docker.pkg.dev/PROJECT/repo/ml-app:v1 \
  --gpu=1 --gpu-type=nvidia-l4 \
  --cpu=8 --memory=32Gi \
  --no-cpu-throttling \
  --max-instances=5 \
  --region=us-central1
```

### Rules
- One GPU per instance maximum
- Requires always-on CPU (`--no-cpu-throttling`)
- Only the main ingress container can access the GPU (not sidecars)
- Drivers are auto-managed — no manual CUDA install needed
- Use `--min-instances=1` to avoid GPU cold starts (30-60s)

---

## gRPC on Cloud Run

Cloud Run natively supports gRPC including unary, server-streaming, client-streaming, and bidirectional streaming.

### Requirements
- Enable HTTP/2: set port name to `h2c` in service config
- Listen on `$PORT` (default 8080)
- Cloud Run load balancer terminates and forwards gRPC connections

### YAML configuration

```yaml
spec:
  template:
    spec:
      containers:
      - image: us-docker.pkg.dev/PROJECT/repo/grpc-app:v1
        ports:
        - name: h2c
          containerPort: 8080
```

### Deploy with gcloud

```bash
gcloud run deploy my-grpc --image=IMG --port=h2c:8080 --region=us-central1
```

### Client connection

```python
import grpc
channel = grpc.secure_channel(
    "my-grpc-HASH-uc.a.run.app:443",
    grpc.ssl_channel_credentials()
)
```

### Caveats
- Keepalive settings affect client↔LB leg only
- Autoscaling based on concurrent requests, not connections
- Max request timeout applies to streaming RPCs too (default 5m, max 60m)
- Use `--concurrency=1` for CPU-heavy unary RPCs

---

## Cloud Run + Cloud CDN

Enable edge caching by placing a global Application Load Balancer with Cloud CDN in front of Cloud Run.

### Architecture

```
Client → Cloud CDN → Global ALB → Serverless NEG → Cloud Run
```

### Setup steps

```bash
# 1. Create serverless NEG
gcloud compute network-endpoint-groups create my-neg \
  --region=us-central1 --network-endpoint-type=serverless \
  --cloud-run-service=my-api

# 2. Create backend service with CDN
gcloud compute backend-services create my-backend --global \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --enable-cdn --cache-mode=CACHE_ALL_STATIC

# 3. Add NEG to backend
gcloud compute backend-services add-backend my-backend --global \
  --network-endpoint-group=my-neg \
  --network-endpoint-group-region=us-central1

# 4. Create URL map + HTTPS proxy + forwarding rule
gcloud compute url-maps create my-urlmap --default-service=my-backend
gcloud compute ssl-certificates create my-cert --domains=api.example.com --global
gcloud compute target-https-proxies create my-proxy \
  --url-map=my-urlmap --ssl-certificates=my-cert
gcloud compute forwarding-rules create my-fwd --global \
  --target-https-proxy=my-proxy --ports=443
```

### Cache control from app

```python
# Set cache headers in your app
response.headers["Cache-Control"] = "public, max-age=3600"
```

### Benefits
- Edge caching reduces latency globally
- Cloud Armor WAF protection
- Custom domain with managed SSL
- Path-based routing to multiple services

---

## Binary Authorization

Enforce deploy-time security: only signed/attested container images can be deployed.

### Enable

```bash
# Enable Binary Authorization on Cloud Run
gcloud run services update my-api \
  --binary-authorization=default --region=us-central1
```

### Create attestor and policy

```bash
# Create attestor
gcloud container binauthz attestors create my-attestor \
  --attestation-authority-note=projects/PROJECT/notes/my-note \
  --attestation-authority-note-project=PROJECT

# Set policy to require attestation
cat > policy.yaml << 'EOF'
defaultAdmissionRule:
  evaluationMode: REQUIRE_ATTESTATION
  enforcementMode: ENFORCED_BLOCK_AND_AUDIT_LOG
  requireAttestationsBy:
  - projects/PROJECT/attestors/my-attestor
globalPolicyEvaluationMode: ENABLE
EOF
gcloud container binauthz policy import policy.yaml
```

### Use cases
- Enforce that only CI/CD-built images are deployed
- Require vulnerability scanning attestation before deployment
- Enforce organization-wide deployment policies

---

## Volume Mounts

Cloud Run supports three volume types. All require Gen2 execution environment.

### GCS FUSE — Mount a Cloud Storage bucket

```yaml
volumes:
- name: gcs-data
  gcs:
    bucket: my-bucket
    readOnly: true
containers:
- image: IMG
  volumeMounts:
  - name: gcs-data
    mountPath: /mnt/gcs
```

```bash
gcloud run services update my-api --execution-environment=gen2 \
  --add-volume=name=gcs-vol,type=cloud-storage,bucket=my-bucket \
  --add-volume-mount=volume=gcs-vol,mount-path=/mnt/gcs
```

**Caveats:** Not fully POSIX-compliant. No file locking. Last-write-wins on concurrent writes. Uses container RAM for FUSE cache.

### NFS — Mount Filestore or any NFS share

```yaml
volumes:
- name: nfs-vol
  nfs:
    server: 10.0.0.2
    path: /share
containers:
- image: IMG
  volumeMounts:
  - name: nfs-vol
    mountPath: /mnt/nfs
```

Requires VPC connectivity to NFS server. `nolock` mode enforced. Match UID/GID between container and NFS share.

### In-Memory (emptyDir) — Shared tmpfs between containers

```yaml
volumes:
- name: scratch
  emptyDir:
    medium: Memory
    sizeLimit: 512Mi
containers:
- image: IMG
  volumeMounts:
  - name: scratch
    mountPath: /tmp/shared
```

Backed by instance RAM. Always set `sizeLimit` to prevent OOM. Ideal for sidecar data exchange. Not shared across instances.

**Disallowed mount paths:** `/dev`, `/proc`, `/sys` and subdirectories.

---

## Always-On CPU for Background Processing

By default, Cloud Run throttles CPU between requests. Always-on CPU keeps CPU allocated for the full instance lifetime.

### Enable

```bash
gcloud run deploy my-api --image=IMG --no-cpu-throttling --region=us-central1
```

### Use cases
- Background task queues processed between requests
- WebSocket connections requiring ongoing CPU
- Prometheus metric collection/export
- Scheduled in-process cron jobs
- Streaming responses (SSE, long-polling)

### Pricing impact
- Lower per-vCPU-second rate than request-based
- But you pay for idle time — combine with `--min-instances` wisely
- Use `--min-instances=0` to still scale to zero when no traffic

---

## Cloud Run Integrations

Pre-configured integrations available via the Cloud Run console or gcloud beta:

| Integration | What it provisions |
|-------------|-------------------|
| Custom domains | Global ALB + managed SSL + DNS mapping |
| Firebase Hosting | CDN + custom domain via Firebase |
| Cloud SQL | Auth proxy sidecar + IAM binding |
| Memorystore Redis | VPC connector + Redis instance |
| Cloud Storage | FUSE volume mount |
| Pub/Sub | Push subscription to service URL |
| Eventarc | Event triggers (GCS, Pub/Sub, Audit Log, etc.) |

### Create via CLI

```bash
gcloud beta run integrations create \
  --type=custom-domains \
  --parameters='set-mapping=api.example.com:my-api' \
  --region=us-central1

gcloud beta run integrations create \
  --type=cloud-sql \
  --parameters='instance=my-instance' \
  --service=my-api \
  --region=us-central1
```

### List available integrations

```bash
gcloud beta run integrations types list --region=us-central1
```

Integrations automate provisioning but may not suit advanced custom configurations. For production, prefer explicit infrastructure setup (Terraform/gcloud) for full control.
