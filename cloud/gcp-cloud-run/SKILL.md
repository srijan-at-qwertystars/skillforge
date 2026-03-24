---
name: gcp-cloud-run
description: >
  Expert guidance for Google Cloud Run: deploying and managing serverless containers and jobs on GCP.
  Covers services vs jobs, source/container/Artifact Registry deploys, revision management with traffic
  splitting and canary rollouts, autoscaling (min/max instances, concurrency, CPU allocation), integrations
  with Cloud SQL, Memorystore, Cloud Storage, Pub/Sub, Eventarc, VPC networking (Direct VPC egress,
  connectors), custom domains, health checks, secrets via Secret Manager, service-to-service IAM auth,
  Cloud Run functions (2nd gen), YAML service config, gcloud CLI, Cloud Build CI/CD, Terraform/Pulumi IaC,
  cold start optimization, multi-region deployment, and pricing.
  Triggers: "Cloud Run", "GCP serverless containers", "gcloud run deploy", "Cloud Run jobs",
  "Cloud Run functions", "Cloud Run traffic splitting", "Cloud Run autoscaling".
  NOT for GKE/Kubernetes clusters. NOT for AWS Lambda/Fargate. NOT for App Engine. NOT for Cloud Functions
  1st gen standalone. NOT for Compute Engine VMs.
---

# Google Cloud Run — Complete Reference

## Skill Resources

### references/
- **[advanced-patterns.md](references/advanced-patterns.md)** — Multi-container sidecars, session affinity, startup CPU boost, GPU support, gRPC, Cloud CDN integration, binary authorization, volume mounts (GCS FUSE, NFS, in-memory), always-on CPU, Cloud Run integrations marketplace
- **[troubleshooting.md](references/troubleshooting.md)** — Cold start debugging, container contract violations, memory/CPU limits exceeded, request timeouts, VPC connector issues, Cloud SQL connection pooling, permission errors (invoker vs admin), health check failures, revision not serving
- **[cli-reference.md](references/cli-reference.md)** — Complete gcloud run commands: deploy, services, revisions, jobs, executions, domain-mappings — all flags and common patterns

### scripts/
- **[deploy-cloud-run.sh](scripts/deploy-cloud-run.sh)** — Deploy with environment detection, canary/full traffic modes, promote, rollback, status
- **[setup-cloud-sql.sh](scripts/setup-cloud-sql.sh)** — Configure Cloud Run ↔ Cloud SQL via Auth Proxy or VPC private IP, manage secrets
- **[monitor-cloud-run.sh](scripts/monitor-cloud-run.sh)** — Health checks, revision traffic, latency/request metrics, error logs

### assets/
- **[service.yaml](assets/service.yaml)** — Cloud Run service YAML template with all common settings (scaling, probes, secrets, VPC, sidecars, volumes)
- **[job.yaml](assets/job.yaml)** — Cloud Run job YAML template (parallel tasks, retries, timeouts)
- **[cloudbuild.yaml](assets/cloudbuild.yaml)** — Cloud Build CI/CD pipeline with canary/full deploy modes
- **[Dockerfile](assets/Dockerfile)** — Multi-stage Dockerfile optimized for Cloud Run (Go/Node/Python variants)
- **[terraform-cloud-run.tf](assets/terraform-cloud-run.tf)** — Terraform module with variables for all common Cloud Run settings

## Services vs Jobs

**Services** handle HTTP/gRPC requests, autoscale 0-to-N, and support revisions with traffic splitting.
**Jobs** run containerized tasks to completion (batch, migrations, ETL). No HTTP endpoint; execute N parallel tasks.

Choose services for APIs/web apps. Choose jobs for scheduled/one-off workloads.

```bash
# Deploy a service
gcloud run deploy my-api --image=us-docker.pkg.dev/PROJECT/REPO/my-api:v1 \
  --region=us-central1 --allow-unauthenticated

# Create and execute a job
gcloud run jobs create my-etl --image=us-docker.pkg.dev/PROJECT/REPO/etl:v1 \
  --region=us-central1 --tasks=10 --max-retries=3
gcloud run jobs execute my-etl --region=us-central1
```

## Deployment Methods

### From container image (Artifact Registry)
```bash
gcloud run deploy my-svc --image=us-central1-docker.pkg.dev/PROJECT/REPO/IMAGE:tag --region=us-central1
```

### From source (buildpacks auto; add Dockerfile to override)
```bash
gcloud run deploy my-svc --source=. --region=us-central1
```
### Deploy from YAML
```bash
gcloud run services describe my-svc --format=export > service.yaml
# Edit service.yaml
gcloud run services replace service.yaml --region=us-central1
```

## YAML Service Configuration

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: my-api
  annotations:
    run.googleapis.com/launch-stage: GA
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "1"
        autoscaling.knative.dev/maxScale: "100"
        run.googleapis.com/cpu-throttling: "false"       # always-on CPU
        run.googleapis.com/startup-cpu-boost: "true"
        run.googleapis.com/vpc-access-egress: all-traffic
        run.googleapis.com/network-interfaces: '[{"network":"my-vpc","subnetwork":"my-subnet"}]'
    spec:
      containerConcurrency: 80
      timeoutSeconds: 300
      serviceAccountName: my-sa@PROJECT.iam.gserviceaccount.com
      containers:
      - image: us-central1-docker.pkg.dev/PROJECT/REPO/my-api:v1
        ports:
        - containerPort: 8080
        resources:
          limits:
            cpu: "2"
            memory: 1Gi
        env:
        - name: DB_NAME
          value: mydb
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              key: "latest"
              name: db-password
        startupProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 0
          periodSeconds: 5
          failureThreshold: 12
          timeoutSeconds: 3
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          periodSeconds: 10
          failureThreshold: 3
          timeoutSeconds: 3
  traffic:
  - percent: 100
    latestRevision: true
```

## Revision Management & Traffic Splitting

Every deploy creates an immutable revision. Up to 1000 revisions per service.

```bash
# Deploy new revision without taking traffic
gcloud run deploy my-api --image=IMG:v2 --no-traffic --tag=canary --region=us-central1

# Test canary at https://canary---my-api-HASH.a.run.app

# Split traffic: 90% stable, 10% canary
gcloud run services update-traffic my-api \
  --to-revisions=my-api-00001=90,my-api-00002=10 --region=us-central1

# Promote canary to 100%
gcloud run services update-traffic my-api --to-latest --region=us-central1

# Rollback to previous revision
gcloud run services update-traffic my-api \
  --to-revisions=my-api-00001=100 --region=us-central1
```

## Autoscaling & CPU Allocation

### Key settings
| Setting | Flag | Default | Range |
|---|---|---|---|
| Min instances | `--min-instances` | 0 | 0–1000 |
| Max instances | `--max-instances` | 100 | 1–1000 |
| Concurrency | `--concurrency` | 80 | 1–1000 |
| CPU | `--cpu` | 1 | 1, 2, 4, 8 |
| Memory | `--memory` | 512Mi | 128Mi–32Gi |
| Timeout | `--timeout` | 300s | 1–3600s |

### CPU allocation modes
- **Request-based** (default): CPU throttled between requests. Scale to zero. Pay only during request processing.
- **Always-on** (`--no-cpu-throttling`): CPU allocated for full instance lifetime. Required for background work, WebSockets. Lower per-vCPU cost but pay during idle.

```bash
# Always-on CPU with startup boost, min 2 instances
gcloud run deploy my-api --image=IMG:v1 \
  --no-cpu-throttling --cpu-boost \
  --min-instances=2 --max-instances=50 \
  --cpu=2 --memory=1Gi --concurrency=100 \
  --region=us-central1
```

### Cold start optimization
- Use `--min-instances=1+` to keep warm instances.
- Enable `--cpu-boost` for temporary extra CPU during startup.
- Use distroless/alpine base images; minimize dependencies.
- Defer heavy initialization (DB pools, ML models) from import-time to first-request.
- Prefer Go/Rust/Node for fastest cold starts; Java/Python benefit most from min-instances.

## Secrets via Secret Manager

```bash
# Mount as environment variable
gcloud run deploy my-api --image=IMG \
  --set-secrets=DB_PASS=db-password:latest \
  --region=us-central1

# Mount as file volume
gcloud run deploy my-api --image=IMG \
  --set-secrets=/secrets/tls.key=tls-key:latest \
  --region=us-central1
```

Service account needs `roles/secretmanager.secretAccessor`. Pin versions in prod; use `latest` only in dev.

## Health Checks (Startup & Liveness Probes)

Configure via YAML (see above) or gcloud:
```bash
gcloud run deploy my-api --image=IMG \
  --startup-probe="httpGet,path=/healthz,port=8080,initialDelaySeconds=0,failureThreshold=12" \
  --liveness-probe="httpGet,path=/healthz,port=8080,periodSeconds=10,failureThreshold=3" \
  --region=us-central1
```

Probe types: `httpGet`, `tcpSocket`, `grpc`. Use startup probes for slow-init containers. Liveness probes restart unhealthy instances.

## Service-to-Service Authentication

### Restrict access with IAM
```bash
# Remove public access
gcloud run services remove-iam-policy-binding my-api \
  --member=allUsers --role=roles/run.invoker --region=us-central1

# Grant invoker to specific SA
gcloud run services add-iam-policy-binding my-api \
  --member=serviceAccount:caller@PROJECT.iam.gserviceaccount.com \
  --role=roles/run.invoker --region=us-central1
```

### Generate identity token (caller side)
```python
import google.auth.transport.requests
import google.oauth2.id_token

url = "https://my-api-HASH.a.run.app"
req = google.auth.transport.requests.Request()
token = google.oauth2.id_token.fetch_id_token(req, url)
headers = {"Authorization": f"Bearer {token}"}
```

```bash
# From gcloud
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  https://my-api-HASH.a.run.app/endpoint
```

## VPC Networking

### Direct VPC egress (preferred)
```bash
gcloud run deploy my-api --image=IMG \
  --network=my-vpc --subnet=my-subnet \
  --vpc-egress=all-traffic \
  --region=us-central1
```
Lower latency, no connector VMs, auto-scales. Use for Cloud SQL private IP, internal APIs.

### Serverless VPC connector (legacy, required for Memorystore)
```bash
gcloud compute networks vpc-access connectors create my-conn \
  --region=us-central1 --network=my-vpc --range=10.8.0.0/28

gcloud run deploy my-api --image=IMG \
  --vpc-connector=my-conn --vpc-egress=all-traffic --region=us-central1
```

**Cannot use both** on the same service. Use connector if Memorystore access is needed.

## GCP Service Integrations

### Cloud SQL
```bash
gcloud run deploy my-api --image=IMG \
  --add-cloudsql-instances=PROJECT:REGION:INSTANCE \
  --set-env-vars=DB_HOST=/cloudsql/PROJECT:REGION:INSTANCE \
  --region=us-central1
```
Use Cloud SQL Auth Proxy sidecar (auto-configured) or private IP via VPC.

### Cloud Storage
Access via client libraries. Grant `roles/storage.objectUser` to the service account.

### Pub/Sub (push subscription)
Create push subscription pointing to Cloud Run URL. Cloud Run auto-validates Pub/Sub tokens.
```bash
gcloud pubsub subscriptions create my-sub \
  --topic=my-topic \
  --push-endpoint=https://my-api-HASH.a.run.app/pubsub \
  --push-auth-service-account=pubsub-sa@PROJECT.iam.gserviceaccount.com
```

### Eventarc triggers
```bash
gcloud eventarc triggers create my-trigger \
  --destination-run-service=my-api \
  --destination-run-region=us-central1 \
  --event-filters="type=google.cloud.storage.object.v1.finalized" \
  --event-filters="bucket=my-bucket" \
  --service-account=eventarc-sa@PROJECT.iam.gserviceaccount.com
```

## Custom Domains

```bash
gcloud run domain-mappings create --service=my-api \
  --domain=api.example.com --region=us-central1
# Add the displayed DNS records. TLS auto-provisioned.
```

For global LB with managed certs:
```bash
gcloud compute backend-services create my-backend --global \
  --load-balancing-scheme=EXTERNAL_MANAGED
gcloud compute backend-services add-backend my-backend --global \
  --network-endpoint-group=my-neg --network-endpoint-group-region=us-central1
```

## Cloud Run Functions (2nd Gen)

Cloud Functions 2nd gen = Cloud Run functions. Built on Cloud Run + Eventarc + Cloud Build.

```bash
gcloud run deploy my-func --source=. --function=entrypoint \
  --base-image=google-22/python312 --region=us-central1 \
  --allow-unauthenticated
```

Advantages over 1st gen: up to 60min timeout, 32GB RAM, 8 vCPU, concurrency up to 1000, traffic splitting, revisions, VPC egress. Use for event-driven workloads with Cloud Run features.

## Cloud Build CI/CD

```yaml
# cloudbuild.yaml
steps:
- name: gcr.io/cloud-builders/docker
  args: ['build', '-t', 'us-central1-docker.pkg.dev/$PROJECT_ID/repo/app:$SHORT_SHA', '.']
- name: gcr.io/cloud-builders/docker
  args: ['push', 'us-central1-docker.pkg.dev/$PROJECT_ID/repo/app:$SHORT_SHA']
- name: gcr.io/google.com/cloudsdktool/cloud-sdk
  entrypoint: gcloud
  args:
  - run
  - deploy
  - my-api
  - --image=us-central1-docker.pkg.dev/$PROJECT_ID/repo/app:$SHORT_SHA
  - --region=us-central1
  - --tag=canary
  - --no-traffic
images:
- us-central1-docker.pkg.dev/$PROJECT_ID/repo/app:$SHORT_SHA
```

Trigger from GitHub/Cloud Source Repos push. Add traffic promotion step after approval.

## Terraform

```hcl
resource "google_cloud_run_v2_service" "api" {
  name     = "my-api"
  location = "us-central1"

  template {
    scaling {
      min_instance_count = 1
      max_instance_count = 100
    }
    containers {
      image = "us-central1-docker.pkg.dev/PROJECT/repo/app:v1"
      ports { container_port = 8080 }
      resources {
        limits   = { cpu = "2", memory = "1Gi" }
        cpu_idle = false  # always-on CPU
        startup_cpu_boost = true
      }
      env {
        name  = "DB_NAME"
        value = "mydb"
      }
      env {
        name = "DB_PASS"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_pass.secret_id
            version = "latest"
          }
        }
      }
      startup_probe {
        http_get { path = "/healthz" }
        initial_delay_seconds = 0
        failure_threshold     = 12
      }
      liveness_probe {
        http_get { path = "/healthz" }
        period_seconds    = 10
        failure_threshold = 3
      }
    }
    service_account = google_service_account.api.email
    vpc_access {
      network_interfaces {
        network    = google_compute_network.main.id
        subnetwork = google_compute_subnetwork.main.id
      }
      egress = "ALL_TRAFFIC"
    }
  }
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
```

## Multi-Region Deployment

Deploy same service to multiple regions; front with global Application Load Balancer.

```bash
for REGION in us-central1 europe-west1 asia-east1; do
  gcloud run deploy my-api --image=IMG:v1 --region=$REGION --no-allow-unauthenticated
done

# Create serverless NEGs per region, attach to global backend service + URL map + HTTPS proxy
```

Use Cloud CDN + managed SSL certs for edge caching and TLS termination.

## Pricing Model

| Component | Request-based | Instance-based (always-on) |
|---|---|---|
| vCPU/s | $0.000024 | $0.000018 |
| GiB/s | $0.0000025 | $0.0000020 |
| Requests | $0.40/million | $0.40/million |
| Free tier | 2M requests, 360K vCPU-s, 180K GiB-s/month | Same |

Networking: $0.01/GiB egress (intra-region free). Cloud SQL connector: no extra cost. VPC connector: cost of connector VMs.

**Cost guidance**: Use request-based for bursty/low-traffic. Use instance-based for steady traffic or background processing. Monitor with Cloud Billing recommender.

## Quick Reference: Common gcloud Commands

```bash
gcloud run services list --region=us-central1
gcloud run services describe my-api --region=us-central1
gcloud run revisions list --service=my-api --region=us-central1
gcloud run services delete my-api --region=us-central1
gcloud run services logs read my-api --region=us-central1 --limit=100
gcloud run services update my-api --cpu=4 --memory=2Gi --region=us-central1
gcloud run jobs list --region=us-central1
gcloud run jobs executions list --job=my-etl --region=us-central1
```

## Examples

**User**: Deploy a Python Flask app to Cloud Run from source with Cloud SQL and secrets
**Assistant**: Steps:
```bash
# 1. Create secret
echo -n "s3cret" | gcloud secrets create db-pass --data-file=- --replication-policy=automatic

# 2. Deploy from source with Cloud SQL + secret
gcloud run deploy flask-api --source=. \
  --region=us-central1 \
  --add-cloudsql-instances=myproj:us-central1:mydb \
  --set-secrets=DB_PASS=db-pass:latest \
  --set-env-vars=DB_HOST=/cloudsql/myproj:us-central1:mydb,DB_USER=app \
  --min-instances=1 --max-instances=10 \
  --allow-unauthenticated
```

**User**: Set up canary deployment with 10% traffic to new version
**Assistant**:
```bash
# Deploy new revision without traffic
gcloud run deploy my-api --image=IMG:v2 --no-traffic --tag=canary --region=us-central1

# Route 10% to canary
gcloud run services update-traffic my-api \
  --to-tags=canary=10 --region=us-central1

# After validation, promote
gcloud run services update-traffic my-api --to-latest --region=us-central1
```
