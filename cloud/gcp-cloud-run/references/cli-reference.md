# gcloud run CLI Reference

## Table of Contents

- [deploy](#deploy)
- [services](#services)
- [revisions](#revisions)
- [jobs](#jobs)
- [executions](#executions)
- [domain-mappings](#domain-mappings)
- [Common Patterns](#common-patterns)

---

## deploy

Create or update a Cloud Run service, creating a new revision.

```bash
gcloud run deploy SERVICE [--image=IMAGE | --source=SOURCE] \
  --region=REGION [FLAGS]
```

### Core flags

| Flag | Description | Default |
|------|-------------|---------|
| `--image=IMAGE` | Container image to deploy | — |
| `--source=.` | Deploy from source (Cloud Build) | — |
| `--function=ENTRYPOINT` | Deploy as Cloud Run function | — |
| `--base-image=BASE` | Base image for source deploys | auto |
| `--region=REGION` | Target region | prompt |
| `--project=PROJECT` | GCP project | current |
| `--platform=managed` | Always `managed` for Cloud Run | managed |

### Access control

| Flag | Description |
|------|-------------|
| `--allow-unauthenticated` | Make service public |
| `--no-allow-unauthenticated` | Require IAM auth |
| `--ingress=INGRESS` | `all`, `internal`, `internal-and-cloud-load-balancing` |
| `--service-account=SA` | Runtime service account email |

### Resources and scaling

| Flag | Description | Default | Range |
|------|-------------|---------|-------|
| `--cpu=CPU` | vCPU count | 1 | 1, 2, 4, 8 |
| `--memory=MEM` | Memory limit | 512Mi | 128Mi–32Gi |
| `--min-instances=N` | Minimum instances | 0 | 0–1000 |
| `--max-instances=N` | Maximum instances | 100 | 1–1000 |
| `--concurrency=N` | Max concurrent requests/instance | 80 | 1–1000 |
| `--timeout=SECONDS` | Request timeout | 300 | 1–3600 |
| `--cpu-boost` | Startup CPU boost | off | — |
| `--no-cpu-throttling` | Always-on CPU allocation | off | — |
| `--gpu=N` | Number of GPUs | 0 | 0–1 |
| `--gpu-type=TYPE` | GPU type (e.g., `nvidia-l4`) | — | — |
| `--execution-environment=ENV` | `gen1` or `gen2` | gen1 | — |

### Environment and secrets

| Flag | Description |
|------|-------------|
| `--set-env-vars=K=V,K2=V2` | Set env vars (replaces all) |
| `--update-env-vars=K=V` | Add/update env vars (keeps existing) |
| `--remove-env-vars=K1,K2` | Remove specific env vars |
| `--clear-env-vars` | Remove all env vars |
| `--set-secrets=K=SECRET:VERSION` | Mount secret as env var |
| `--update-secrets=K=SECRET:VERSION` | Add/update secret bindings |
| `--set-secrets=/path=SECRET:VERSION` | Mount secret as file volume |

### Networking

| Flag | Description |
|------|-------------|
| `--vpc-connector=CONNECTOR` | Serverless VPC connector name |
| `--network=NETWORK` | VPC network (Direct VPC egress) |
| `--subnet=SUBNET` | VPC subnet (Direct VPC egress) |
| `--vpc-egress=EGRESS` | `all-traffic` or `private-ranges-only` |
| `--clear-vpc-connector` | Remove VPC connector |
| `--add-cloudsql-instances=CONN` | Cloud SQL connection string |
| `--port=PORT` | Container port (default 8080) |
| `--session-affinity` | Enable session affinity |

### Traffic control

| Flag | Description |
|------|-------------|
| `--no-traffic` | Deploy revision without routing traffic |
| `--tag=TAG` | Assign a tag to the revision |
| `--revision-suffix=SUFFIX` | Custom revision name suffix |

### Health probes

| Flag | Description |
|------|-------------|
| `--startup-probe=SPEC` | Startup probe config |
| `--liveness-probe=SPEC` | Liveness probe config |

Probe spec format: `httpGet,path=/healthz,port=8080,initialDelaySeconds=0,failureThreshold=12,timeoutSeconds=3`

### Labels and annotations

| Flag | Description |
|------|-------------|
| `--labels=K=V,K2=V2` | Set labels |
| `--update-labels=K=V` | Add/update labels |
| `--remove-labels=K1,K2` | Remove labels |

### Full deploy example

```bash
gcloud run deploy my-api \
  --image=us-central1-docker.pkg.dev/myproj/repo/app:v2 \
  --region=us-central1 \
  --service-account=my-sa@myproj.iam.gserviceaccount.com \
  --cpu=2 --memory=1Gi \
  --min-instances=2 --max-instances=50 \
  --concurrency=100 --timeout=600 \
  --no-cpu-throttling --cpu-boost \
  --set-env-vars=ENV=production,LOG_LEVEL=info \
  --set-secrets=DB_PASS=db-password:latest \
  --add-cloudsql-instances=myproj:us-central1:mydb \
  --network=my-vpc --subnet=my-subnet --vpc-egress=all-traffic \
  --ingress=internal-and-cloud-load-balancing \
  --no-allow-unauthenticated \
  --tag=canary --no-traffic \
  --labels=team=backend,env=prod
```

---

## services

Manage Cloud Run services.

### list

```bash
gcloud run services list [--region=REGION | --regions=all] \
  [--format=FORMAT] [--filter=FILTER]
```

```bash
# List all services in a region
gcloud run services list --region=us-central1

# List across all regions
gcloud run services list --regions=all

# JSON output for scripting
gcloud run services list --region=us-central1 --format=json

# Filter by label
gcloud run services list --region=us-central1 --filter="metadata.labels.env=prod"
```

### describe

```bash
gcloud run services describe SERVICE --region=REGION [--format=FORMAT]
```

```bash
# Full YAML description
gcloud run services describe my-api --region=us-central1

# Just the URL
gcloud run services describe my-api --region=us-central1 \
  --format="value(status.url)"

# Export for editing
gcloud run services describe my-api --region=us-central1 --format=export > service.yaml
```

### update

Update configuration without redeploying. Creates a new revision.

```bash
gcloud run services update SERVICE --region=REGION [FLAGS]
```

Accepts same resource/env/network flags as `deploy`. Does not accept `--image` or `--source`.

```bash
# Scale up
gcloud run services update my-api --memory=2Gi --cpu=4 --region=us-central1

# Change concurrency
gcloud run services update my-api --concurrency=200 --region=us-central1
```

### update-traffic

```bash
gcloud run services update-traffic SERVICE --region=REGION \
  [--to-latest | --to-revisions=REV=PCT,... | --to-tags=TAG=PCT,...]
```

```bash
# All traffic to latest
gcloud run services update-traffic my-api --to-latest --region=us-central1

# Split traffic
gcloud run services update-traffic my-api \
  --to-revisions=my-api-v1=90,my-api-v2=10 --region=us-central1

# Split by tag
gcloud run services update-traffic my-api \
  --to-tags=canary=10 --region=us-central1
```

### replace

Replace service configuration from YAML.

```bash
gcloud run services replace service.yaml --region=REGION
```

### delete

```bash
gcloud run services delete SERVICE --region=REGION [--quiet]
```

### add-iam-policy-binding / remove-iam-policy-binding

```bash
gcloud run services add-iam-policy-binding SERVICE \
  --member=MEMBER --role=ROLE --region=REGION

gcloud run services remove-iam-policy-binding SERVICE \
  --member=MEMBER --role=ROLE --region=REGION
```

```bash
# Make public
gcloud run services add-iam-policy-binding my-api \
  --member=allUsers --role=roles/run.invoker --region=us-central1

# Grant specific SA
gcloud run services add-iam-policy-binding my-api \
  --member=serviceAccount:caller@myproj.iam.gserviceaccount.com \
  --role=roles/run.invoker --region=us-central1
```

### get-iam-policy

```bash
gcloud run services get-iam-policy SERVICE --region=REGION
```

### logs

```bash
# Read logs
gcloud run services logs read SERVICE --region=REGION --limit=100

# Tail logs (streaming)
gcloud run services logs tail SERVICE --region=REGION
```

---

## revisions

Manage service revisions.

### list

```bash
gcloud run revisions list --service=SERVICE --region=REGION [--format=FORMAT]
```

```bash
# List with traffic info
gcloud run revisions list --service=my-api --region=us-central1

# Table with image info
gcloud run revisions list --service=my-api --region=us-central1 \
  --format="table(name,spec.containers[0].image,status.conditions[0].status)"
```

### describe

```bash
gcloud run revisions describe REVISION --region=REGION
```

### delete

Cannot delete revisions currently serving traffic.

```bash
gcloud run revisions delete REVISION --region=REGION [--quiet]
```

---

## jobs

Manage Cloud Run jobs (containerized tasks that run to completion).

### create

```bash
gcloud run jobs create JOB --image=IMAGE --region=REGION [FLAGS]
```

| Flag | Description | Default |
|------|-------------|---------|
| `--tasks=N` | Number of parallel tasks | 1 |
| `--max-retries=N` | Retries per failed task | 3 |
| `--task-timeout=DURATION` | Timeout per task | 600s |
| `--parallelism=N` | Max tasks running simultaneously | 0 (all) |
| `--cpu=CPU` | vCPU per task | 1 |
| `--memory=MEM` | Memory per task | 512Mi |
| `--set-env-vars=K=V` | Environment variables | — |
| `--set-secrets=K=SECRET:VER` | Secret bindings | — |
| `--service-account=SA` | Runtime service account | default compute SA |

```bash
gcloud run jobs create my-etl \
  --image=us-docker.pkg.dev/myproj/repo/etl:v1 \
  --region=us-central1 \
  --tasks=10 --parallelism=5 --max-retries=2 \
  --task-timeout=1800 \
  --cpu=2 --memory=4Gi \
  --set-env-vars=BATCH_SIZE=1000
```

### update

```bash
gcloud run jobs update JOB --region=REGION [FLAGS]
```

Same flags as `create`.

### execute

```bash
gcloud run jobs execute JOB --region=REGION [--wait] [--async]
```

```bash
# Run and wait for completion
gcloud run jobs execute my-etl --region=us-central1 --wait

# Override tasks count for this execution
gcloud run jobs execute my-etl --region=us-central1 --tasks=5

# Override env vars for this execution
gcloud run jobs execute my-etl --region=us-central1 \
  --update-env-vars=BATCH_SIZE=500
```

### list

```bash
gcloud run jobs list --region=REGION
```

### describe

```bash
gcloud run jobs describe JOB --region=REGION
```

### delete

```bash
gcloud run jobs delete JOB --region=REGION [--quiet]
```

---

## executions

Manage job executions.

### list

```bash
gcloud run jobs executions list --job=JOB --region=REGION
```

### describe

```bash
gcloud run jobs executions describe EXECUTION --region=REGION
```

### cancel

```bash
gcloud run jobs executions cancel EXECUTION --region=REGION
```

### delete

```bash
gcloud run jobs executions delete EXECUTION --region=REGION [--quiet]
```

### tasks list

```bash
gcloud run jobs executions tasks list --execution=EXECUTION --region=REGION
```

---

## domain-mappings

Map custom domains to Cloud Run services. Auto-provisions TLS certificates.

### create

```bash
gcloud run domain-mappings create --service=SERVICE \
  --domain=DOMAIN --region=REGION
```

After creation, add the displayed DNS records (CNAME or A records) at your domain registrar.

### list

```bash
gcloud run domain-mappings list --region=REGION
```

### describe

```bash
gcloud run domain-mappings describe --domain=DOMAIN --region=REGION
```

### delete

```bash
gcloud run domain-mappings delete --domain=DOMAIN --region=REGION
```

### Using integrations (preferred for new setups)

```bash
# Create with global load balancer + managed SSL
gcloud beta run integrations create --type=custom-domains \
  --parameters='set-mapping=api.example.com:my-api' \
  --region=us-central1
```

---

## Common Patterns

### Deploy canary with gradual rollout

```bash
# Deploy canary revision (no traffic)
gcloud run deploy my-api --image=IMG:v2 --no-traffic --tag=canary --region=us-central1

# Test canary URL
curl https://canary---my-api-HASH.a.run.app/healthz

# Route 5% → 25% → 100%
gcloud run services update-traffic my-api --to-tags=canary=5 --region=us-central1
gcloud run services update-traffic my-api --to-tags=canary=25 --region=us-central1
gcloud run services update-traffic my-api --to-latest --region=us-central1
```

### Instant rollback

```bash
# List revisions to find the good one
gcloud run revisions list --service=my-api --region=us-central1

# Route all traffic to previous revision
gcloud run services update-traffic my-api \
  --to-revisions=my-api-00003=100 --region=us-central1
```

### Multi-region deploy

```bash
IMAGE="us-docker.pkg.dev/myproj/repo/app:v1"
for REGION in us-central1 europe-west1 asia-east1; do
  gcloud run deploy my-api --image=$IMAGE --region=$REGION \
    --min-instances=1 --no-allow-unauthenticated
done
```

### Export and import service config

```bash
# Export
gcloud run services describe my-api --region=us-central1 --format=export > service.yaml

# Edit service.yaml...

# Import (creates new revision)
gcloud run services replace service.yaml --region=us-central1
```

### Scripting: get service URL

```bash
URL=$(gcloud run services describe my-api --region=us-central1 \
  --format="value(status.url)")
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" "$URL/endpoint"
```

### Scripting: wait for deployment

```bash
gcloud run deploy my-api --image=IMG --region=us-central1 --quiet
gcloud run services describe my-api --region=us-central1 \
  --format="value(status.conditions[0].status)" | grep -q True \
  && echo "Ready" || echo "Not ready"
```

### Delete all revisions except latest

```bash
LATEST=$(gcloud run services describe my-api --region=us-central1 \
  --format="value(status.latestReadyRevisionName)")
gcloud run revisions list --service=my-api --region=us-central1 \
  --format="value(name)" | grep -v "$LATEST" | while read REV; do
  gcloud run revisions delete "$REV" --region=us-central1 --quiet
done
```

### Check revision image digest

```bash
gcloud run revisions describe my-api-00005 --region=us-central1 \
  --format="value(spec.containers[0].image)"
```

### List services with resource usage

```bash
gcloud run services list --region=us-central1 \
  --format="table(name,spec.template.spec.containers[0].resources.limits.cpu,\
spec.template.spec.containers[0].resources.limits.memory,\
spec.template.metadata.annotations['autoscaling.knative.dev/minScale'],\
spec.template.metadata.annotations['autoscaling.knative.dev/maxScale'])"
```
