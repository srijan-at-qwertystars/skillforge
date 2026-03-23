# Temporal Production Guide

## Table of Contents

- [Self-Hosted Deployment](#self-hosted-deployment)
  - [Docker Compose](#docker-compose)
  - [Kubernetes / Helm](#kubernetes--helm)
- [Temporal Cloud Setup](#temporal-cloud-setup)
- [Monitoring](#monitoring)
  - [Prometheus Metrics](#prometheus-metrics)
  - [Grafana Dashboards](#grafana-dashboards)
- [Security](#security)
  - [mTLS Configuration](#mtls-configuration)
  - [Authorization](#authorization)
- [Data Converter and Encryption](#data-converter-and-encryption)
- [Archival](#archival)
- [Multi-Tenancy Patterns](#multi-tenancy-patterns)
- [Capacity Planning](#capacity-planning)

---

## Self-Hosted Deployment

### Docker Compose

For development and small-scale production. See `assets/docker-compose.yml` for a full ready-to-run configuration.

**Minimum requirements**: 4 CPU cores, 8 GB RAM, SSD storage for PostgreSQL.

```bash
# Quick start with the official repository
git clone https://github.com/temporalio/docker-compose.git
cd docker-compose
docker compose up -d

# Verify
curl -s localhost:7233 || echo "gRPC port open"
open http://localhost:8080  # Web UI
```

**Production hardening for Docker Compose**:

1. **External database**: Use managed PostgreSQL (RDS, Cloud SQL) instead of containerized DB
2. **Persistent volumes**: Map named volumes for all data directories
3. **Resource limits**: Set CPU/memory limits on each service
4. **Secrets management**: Use Docker secrets or env files, never inline passwords
5. **Separate service roles**: Run frontend, history, matching, and worker as separate containers

```yaml
# Example resource limits
services:
  temporal:
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4G
        reservations:
          cpus: '1.0'
          memory: 2G
```

### Kubernetes / Helm

The recommended production deployment method. Uses the official Temporal Helm chart.

```bash
# Add the Temporal Helm repository
helm repo add temporal https://temporalio.github.io/helm-charts
helm repo update

# Install with PostgreSQL and Elasticsearch
helm install temporal temporal/temporal \
  --namespace temporal --create-namespace \
  --set server.replicaCount=3 \
  --set cassandra.enabled=false \
  --set mysql.enabled=false \
  --set postgresql.enabled=true \
  --set elasticsearch.enabled=true \
  --set prometheus.enabled=true \
  --set grafana.enabled=true \
  --timeout 15m

# Verify deployment
kubectl get pods -n temporal
kubectl port-forward svc/temporal-frontend 7233:7233 -n temporal
kubectl port-forward svc/temporal-web 8080:8080 -n temporal
```

**Production values.yaml example**:

```yaml
server:
  replicaCount: 3
  resources:
    requests:
      cpu: "1"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "4Gi"
  config:
    persistence:
      default:
        driver: sql
        sql:
          driver: postgres12
          host: my-rds-instance.region.rds.amazonaws.com
          port: 5432
          database: temporal
          user: temporal
          existingSecret: temporal-db-credentials
      visibility:
        driver: sql
        sql:
          driver: postgres12
          host: my-rds-instance.region.rds.amazonaws.com
          port: 5432
          database: temporal_visibility
          user: temporal
          existingSecret: temporal-db-credentials

elasticsearch:
  enabled: true
  external: true
  host: my-es-cluster.region.es.amazonaws.com
  port: 443
  scheme: https

web:
  replicaCount: 2
  resources:
    requests:
      cpu: "250m"
      memory: "256Mi"

admintools:
  enabled: true

prometheus:
  enabled: true

grafana:
  enabled: true
```

**Key Helm configuration areas**:
- `server.config.persistence` — Database connection for workflow data
- `server.config.persistence.visibility` — Database/ES for search and listing
- `server.config.clusterMetadata` — Multi-cluster setup
- `server.config.tls` — mTLS between services
- `server.dynamicConfig` — Runtime-tunable parameters

### Dynamic Configuration (self-hosted)

Runtime-tunable parameters without restarting:

```yaml
# dynamic-config.yaml
frontend.maxNamespaceCountPerInstance:
  - value: 100
    constraints: {}
history.maximumBufferedEventsBatch:
  - value: 1000
    constraints: {}
system.forceSearchAttributesCacheRefreshOnRead:
  - value: true
    constraints: {}
limit.maxIDLength:
  - value: 255
    constraints: {}
frontend.namespaceCount:
  - value: 100
    constraints: {}
```

---

## Temporal Cloud Setup

Temporal Cloud is the fully managed service. No server operations required.

### Getting Started

1. Create account at [cloud.temporal.io](https://cloud.temporal.io)
2. Create a namespace (includes region selection)
3. Generate or upload CA certificates for mTLS
4. Configure workers to connect

### Worker Connection

```typescript
import { Connection, Client } from '@temporalio/client';
import { readFileSync } from 'fs';

const connection = await Connection.connect({
  address: 'my-namespace.my-account.tmprl.cloud:7233',
  tls: {
    clientCertPair: {
      crt: readFileSync('path/to/client.pem'),
      key: readFileSync('path/to/client-key.pem'),
    },
  },
});

const client = new Client({ connection, namespace: 'my-namespace.my-account' });
```

```go
clientOptions := client.Options{
    HostPort:  "my-namespace.my-account.tmprl.cloud:7233",
    Namespace: "my-namespace.my-account",
    ConnectionOptions: client.ConnectionOptions{
        TLS: &tls.Config{
            Certificates: []tls.Certificate{cert},
        },
    },
}
c, err := client.Dial(clientOptions)
```

### Temporal Cloud CLI (tcld)

```bash
# Install
brew install temporalio/brew/tcld

# Login
tcld login

# Namespace operations
tcld namespace list
tcld namespace get --namespace my-ns

# Certificate management
tcld namespace accepted-client-ca set --namespace my-ns \
  --ca-certificate-file ca.pem

# API key management
tcld apikey create --name my-key --duration 90d
```

### Pricing Model
- Per-action pricing (workflow starts, activity executions, signals, queries)
- Storage for running workflows and retained history
- No charge for idle workers or polling

---

## Monitoring

### Prometheus Metrics

Temporal server and SDKs expose Prometheus metrics on `/metrics` endpoints.

**Critical server metrics to alert on**:

| Metric | Alert Threshold | Meaning |
|--------|----------------|---------|
| `schedule_to_start_latency` | p99 > 5s | Task queue backlog — add more workers |
| `persistence_latency` | p99 > 1s | Database slow — check DB performance |
| `service_errors` | Rate > 0.01/s | Server errors — check logs |
| `workflow_task_schedule_to_start_latency` | p99 > 2s | Worker contention |
| `activity_schedule_to_start_latency` | p99 > 10s | Activity worker saturation |

**Critical SDK/worker metrics**:

| Metric | Alert Threshold | Meaning |
|--------|----------------|---------|
| `temporal_sticky_cache_size` | Near max | Increase cache or add workers |
| `temporal_worker_task_slots_available` | 0 | Worker saturated — scale out |
| `temporal_long_request_failure` | Count > 0 | Worker-to-server connectivity issue |
| `temporal_workflow_task_execution_failed` | Count > 0 | Workflow code errors |

**Temporal Cloud metrics**: Available via a Prometheus-compatible endpoint. Configure in your observability stack:

```yaml
# prometheus.yml scrape config for Temporal Cloud
scrape_configs:
  - job_name: 'temporal-cloud'
    scheme: https
    tls_config:
      cert_file: /certs/client.pem
      key_file: /certs/client-key.pem
    static_configs:
      - targets: ['my-account.tmprl.cloud:443']
    metrics_path: /prometheus
    params:
      temporal_namespace: ['my-namespace']
```

### Grafana Dashboards

Temporal provides official Grafana dashboard JSON files. Key dashboards:

1. **Server Overview**: Frontend/History/Matching/Worker service health, request rates, latencies
2. **SDK Metrics**: Worker throughput, task slots, cache usage, poll success rate
3. **Workflow Metrics**: Start rate, completion rate, failure rate by workflow type
4. **Persistence**: DB query latency, connection pool usage, error rates

**Import official dashboards**:

```bash
# Download from Temporal's GitHub
curl -LO https://raw.githubusercontent.com/temporalio/dashboards/main/server/server-general.json
curl -LO https://raw.githubusercontent.com/temporalio/dashboards/main/sdk/sdk-general.json

# Import via Grafana UI: Dashboards → Import → Upload JSON
```

**Essential Grafana panels**:

```
Row 1: Workflow throughput
  - Workflows started/s  |  Workflows completed/s  |  Workflows failed/s

Row 2: Latency
  - Schedule-to-start p50/p99  |  Activity execution p50/p99  |  Workflow task latency

Row 3: Worker health
  - Task slots available  |  Sticky cache usage  |  Poll success rate

Row 4: Persistence
  - DB latency p99  |  DB error rate  |  Connection pool usage
```

---

## Security

### mTLS Configuration

All production deployments should use mutual TLS for:
- Client → Frontend (worker/client to server)
- Internode (frontend ↔ history ↔ matching)
- (Optional) Frontend → Database

**Self-hosted mTLS setup**:

```yaml
# Temporal server TLS config
tls:
  internode:
    server:
      certFile: /certs/internode.pem
      keyFile: /certs/internode-key.pem
      requireClientAuth: true
      clientCaFiles:
        - /certs/internode-ca.pem
    client:
      certFile: /certs/internode.pem
      keyFile: /certs/internode-key.pem
      rootCaFiles:
        - /certs/internode-ca.pem
  frontend:
    server:
      certFile: /certs/frontend.pem
      keyFile: /certs/frontend-key.pem
      requireClientAuth: true
      clientCaFiles:
        - /certs/client-ca.pem
    client:
      certFile: /certs/frontend.pem
      keyFile: /certs/frontend-key.pem
      rootCaFiles:
        - /certs/server-ca.pem
```

**Certificate generation (development)**:

```bash
# Generate CA
openssl genrsa -out ca-key.pem 4096
openssl req -new -x509 -key ca-key.pem -sha256 -subj "/CN=Temporal CA" \
  -days 3650 -out ca.pem

# Generate server cert
openssl genrsa -out server-key.pem 4096
openssl req -new -key server-key.pem -subj "/CN=temporal-server" -out server.csr
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem \
  -CAcreateserial -days 365 -sha256 -out server.pem

# Generate client cert
openssl genrsa -out client-key.pem 4096
openssl req -new -key client-key.pem -subj "/CN=temporal-client" -out client.csr
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca-key.pem \
  -CAcreateserial -days 365 -sha256 -out client.pem
```

### Authorization

Temporal supports pluggable authorization via an `Authorizer` and `ClaimMapper` interface.

**Self-hosted RBAC**:

```yaml
# Temporal server authorization config
authorization:
  jwtKeyProvider:
    keySourceURIs:
      - https://my-idp.example.com/.well-known/jwks.json
  permissionsClaimName: "permissions"
  authorizer: "default"
  claimMapper: "default"
```

**Namespace-level permissions**: `read`, `write`, `admin` per namespace.

**Temporal Cloud**: Built-in RBAC with namespace-level access controls. Manage via UI or `tcld`.

---

## Data Converter and Encryption

Encrypt workflow/activity payloads end-to-end using a custom data converter.

### TypeScript Encryption Codec

```typescript
import { PayloadCodec } from '@temporalio/common';
import { createCipheriv, createDecipheriv, randomBytes } from 'crypto';

const ENCRYPTION_KEY = Buffer.from(process.env.TEMPORAL_ENCRYPTION_KEY!, 'base64');

export class EncryptionCodec implements PayloadCodec {
  async encode(payloads: Payload[]): Promise<Payload[]> {
    return payloads.map(payload => {
      const iv = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', ENCRYPTION_KEY, iv);
      const encrypted = Buffer.concat([cipher.update(payload.data!), cipher.final()]);
      const tag = cipher.getAuthTag();
      return {
        metadata: {
          encoding: Buffer.from('binary/encrypted'),
          'encryption-key-id': Buffer.from('my-key-v1'),
        },
        data: Buffer.concat([iv, tag, encrypted]),
      };
    });
  }

  async decode(payloads: Payload[]): Promise<Payload[]> {
    return payloads.map(payload => {
      const data = payload.data!;
      const iv = data.slice(0, 12);
      const tag = data.slice(12, 28);
      const encrypted = data.slice(28);
      const decipher = createDecipheriv('aes-256-gcm', ENCRYPTION_KEY, iv);
      decipher.setAuthTag(tag);
      return { data: Buffer.concat([decipher.update(encrypted), decipher.final()]) };
    });
  }
}

// Register in worker and client
const worker = await Worker.create({
  dataConverter: { payloadCodecPath: require.resolve('./encryption-codec') },
  // ...
});
```

### Codec Server

For the Web UI and CLI to display encrypted payloads, run a codec server:

```typescript
import { CodecServer } from '@temporalio/codec-server';
import { EncryptionCodec } from './encryption-codec';

const server = new CodecServer({ codecs: [new EncryptionCodec()] });
server.listen(8888);
// Configure Web UI: TEMPORAL_CODEC_ENDPOINT=http://localhost:8888
```

---

## Archival

Move completed workflow histories to long-term storage (S3, GCS, local filesystem) to reduce database size.

### Configuration

```yaml
# Temporal server archival config
archival:
  history:
    state: enabled
    enableRead: true
    provider:
      s3store:
        region: us-east-1
  visibility:
    state: enabled
    enableRead: true
    provider:
      s3store:
        region: us-east-1

namespaceDefaults:
  archival:
    history:
      state: enabled
      URI: "s3://my-temporal-archive/history"
    visibility:
      state: enabled
      URI: "s3://my-temporal-archive/visibility"
```

```bash
# Enable archival for an existing namespace
temporal operator namespace update --namespace my-ns \
  --history-archival-state enabled \
  --history-uri "s3://my-temporal-archive/history"
```

---

## Multi-Tenancy Patterns

### Namespace-per-Tenant

The primary isolation mechanism. Each tenant gets its own namespace with independent:
- Search attributes, retention policy, archival config
- Rate limits (via dynamic config)
- RBAC permissions

```bash
# Create tenant namespace
temporal operator namespace create --namespace tenant-acme \
  --retention 720h \
  --description "ACME Corp tenant"

# Set per-namespace rate limits (dynamic config)
frontend.namespaceRPS:
  - value: 1000
    constraints:
      namespace: "tenant-acme"
frontend.namespaceRPS:
  - value: 500
    constraints:
      namespace: "tenant-startup"
```

### Task-Queue-per-Tenant

For lighter isolation within a single namespace:

```typescript
// Route each tenant to its own task queue
const taskQueue = `processing-${tenantId}`;
await client.workflow.start('processOrder', {
  taskQueue,
  workflowId: `order-${tenantId}-${orderId}`,
  args: [orderData],
});

// Deploy dedicated workers per tenant (or shared workers polling multiple queues)
```

### Shared Workers with Tenant Context

```typescript
// Pass tenant context through workflow, enforce limits in activities
export async function tenantWorkflow(tenantId: string, data: Input): Promise<void> {
  const acts = wf.proxyActivities<typeof activities>({
    startToCloseTimeout: '30s',
    retry: { maximumAttempts: 3 },
  });

  await acts.processWithTenantLimits(tenantId, data);
}
```

---

## Capacity Planning

### Sizing the Temporal Server

| Component | CPU | Memory | Notes |
|-----------|-----|--------|-------|
| Frontend | 2-4 cores | 2-4 GB | Scales with request rate |
| History | 4-8 cores | 4-8 GB | Most resource-intensive; scales with workflow count |
| Matching | 2-4 cores | 2-4 GB | Scales with task queue count |
| Worker (internal) | 1-2 cores | 1-2 GB | Handles archival, replication |

### Database Sizing

| Load Level | PostgreSQL | Elasticsearch |
|------------|-----------|---------------|
| Low (< 100 workflows/s) | 2 vCPU, 8 GB, 100 GB SSD | 2 nodes, 4 GB each |
| Medium (100-1000/s) | 4 vCPU, 16 GB, 500 GB SSD | 3 nodes, 8 GB each |
| High (1000-10000/s) | 8+ vCPU, 32 GB, 1 TB SSD | 5+ nodes, 16 GB each |

### Worker Sizing

```
Workers needed ≈ (peak_workflow_starts/s × avg_activities_per_workflow × avg_activity_duration_s)
                 / maxConcurrentActivityTaskExecutions_per_worker
```

Example: 100 starts/s × 5 activities × 2s each = 1000 activity-seconds/s.
With 200 concurrent activities per worker: 1000 / 200 = 5 workers minimum.

### Scaling Checklist

- [ ] Database connection pool sized for server replicas (connections = replicas × pool_per_instance)
- [ ] Elasticsearch heap set to 50% of available memory (max 32 GB)
- [ ] Worker count matches peak load with 50% headroom
- [ ] Prometheus retention sized for your alert evaluation windows
- [ ] Network policies allow gRPC (7233), HTTP (8080), Prometheus (9090)
- [ ] Pod disruption budgets configured for rolling updates
- [ ] Horizontal pod autoscaler (HPA) on worker deployments based on queue depth
- [ ] Regular load testing with production-like workflow patterns
