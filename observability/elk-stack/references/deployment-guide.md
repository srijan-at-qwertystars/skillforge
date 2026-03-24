# ELK Stack Production Deployment Guide

> Planning, deploying, securing, and operating Elasticsearch, Logstash, and Kibana in production.

## Table of Contents

1. [Sizing and Capacity Planning](#1-sizing-and-capacity-planning)
2. [Network Architecture](#2-network-architecture)
3. [Docker Compose for Development](#3-docker-compose-for-development)
4. [ECK (Elastic Cloud on Kubernetes) for Production](#4-eck-elastic-cloud-on-kubernetes-for-production)
5. [Security Setup](#5-security-setup)
6. [Backup and Restore](#6-backup-and-restore)
7. [Monitoring the Stack Itself](#7-monitoring-the-stack-itself)
8. [Upgrade Strategies](#8-upgrade-strategies)
9. [Multi-Tenant Setup](#9-multi-tenant-setup)

---

## 1. Sizing and Capacity Planning

### Memory Allocation

Set JVM heap to **50% of RAM**, never exceeding **31 GB** (compressed oops threshold). The remaining RAM serves the OS filesystem cache for Lucene segments.

```bash
# jvm.options — always set min and max equal to avoid GC resize pauses
-Xms16g
-Xmx16g
```

| Node RAM | JVM Heap | OS Cache | Use Case                     |
|----------|----------|----------|------------------------------|
| 8 GB     | 4 GB     | 4 GB     | Minimum for light workloads  |
| 16 GB    | 8 GB     | 8 GB     | Small production clusters    |
| 32 GB    | 16 GB    | 16 GB    | Balanced general-purpose     |
| 64 GB    | 31 GB    | 33 GB    | Maximum heap, large clusters |

### Disk Sizing Formula

```
Total Disk = Raw Daily Data × Retention Days × (1 + Replicas) × 1.1 overhead × 1.15 margin
```

The 1.1 factor covers indexing overhead (metadata, doc values). The 15% margin prevents hitting the 90% high disk watermark.

### CPU and Ingest Rates

A single modern core handles ~5,000–10,000 events/sec with standard pipelines. Log-only workloads need 4–8 vCPUs per data node; complex grok/geoip pipelines or search-heavy use need 8–16 vCPUs.

### Shard Sizing

Target **20–40 GB per shard**. Shards under 1 GB waste heap (~50 MB per shard); shards over 50 GB slow recoveries. Keep total shards per data node under 1,000.

### Example Workload Sizing

**10 GB/day** (app logs, 30-day retention):
```
Storage: 10 × 30 × 2 × 1.1 × 1.15 ≈ 759 GB
Cluster: 3 nodes (16 GB RAM, 4 vCPU, 300 GB SSD each)
Shards:  1 primary + 1 replica per daily index
```

**100 GB/day** (multi-service, 30-day retention):
```
Storage: 100 × 30 × 2 × 1.1 × 1.15 ≈ 7.6 TB
Cluster: 3 dedicated masters (4 GB heap, 2 vCPU)
         4–6 hot nodes (32 GB RAM, 8 vCPU, 2 TB NVMe)
         2 warm nodes (32 GB RAM, 4 vCPU, 4 TB HDD)
         2 ingest nodes (16 GB RAM, 8 vCPU)
Shards:  3–5 primaries + 1 replica per daily index
```

**1 TB/day** (infra + security, 90-day retention):
```
Storage: 1000 × 90 × 2 × 1.1 × 1.15 ≈ 228 TB
Cluster: 3 masters (8 GB heap, 4 vCPU) + 10–15 hot nodes (64 GB RAM, 16 vCPU, 4 TB NVMe)
         8–10 warm (64 GB, 8 vCPU, 12 TB HDD) + 4–6 cold (32 GB, object storage)
         3–4 ingest (32 GB, 16 vCPU) + 2 coordinating (32 GB, 8 vCPU) + 2 ML (64 GB, 16 vCPU)
```

---

## 2. Network Architecture

### Dedicated Node Roles

| Role          | Config                     | Purpose                        | Dedicate When            |
|---------------|----------------------------|--------------------------------|--------------------------|
| `master`      | `node.roles: [master]`     | Cluster state, index metadata  | Always in production     |
| `data_hot`    | `node.roles: [data_hot]`   | Active write indices (SSD)     | >50 GB/day ingest        |
| `data_warm`   | `node.roles: [data_warm]`  | Read-heavy older data (HDD ok) | Using ILM tiering        |
| `data_cold`   | `node.roles: [data_cold]`  | Searchable snapshots           | >30-day retention        |
| `ingest`      | `node.roles: [ingest]`     | Pipeline processing            | Complex pipelines        |
| `coordinating`| `node.roles: []`           | Query scatter-gather           | Heavy dashboard usage    |
| `ml`          | `node.roles: [ml]`         | ML jobs                        | Using anomaly detection  |
| `transform`   | `node.roles: [transform]`  | Continuous transforms          | Running pivot jobs       |

### Network Topology

```
                    ┌─────────────────────────┐
                    │     Load Balancer        │
                    │  :9200 (ES) :5601 (Kib)  │
                    └────┬──────────┬──────────┘
                         │          │
          ┌──────────────┤          ├──────────────┐
    ┌─────▼──────┐  ┌────▼───┐  ┌──▼──────┐ ┌─────▼──────┐
    │Coordinating│  │ Kibana │  │ Kibana  │ │  Ingest    │
    │  Node(s)   │  │  :5601 │  │  :5601  │ │  Node(s)   │
    └─────┬──────┘  └────────┘  └─────────┘ └─────┬──────┘
          │            Transport :9300              │
    ┌─────┼────────────────────────────────┬───────┘
    │     │                                │
 ┌──▼──┐ ┌▼────┐ ┌─────┐  ┌─────┐ ┌─────┐ ┌▼────┐
 │Mstr1│ │Mstr2│ │Mstr3│  │Hot 1│ │Hot 2│ │Hot 3│
 └─────┘ └─────┘ └─────┘  └──┬──┘ └──┬──┘ └──┬──┘
                              └───┬───┘       │
                          ┌───────▼───────────▼──┐
                          │  Warm / Cold Nodes    │
                          └──────────────────────-┘
    ┌──────────┐ ┌──────────┐
    │ Logstash │ │ Logstash │  ◄── Beats on :5044, output to ES :9200
    │  :5044   │ │  :5044   │
    └──────────┘ └──────────┘
```

### Port Requirements

| Port | Service                  | Expose Externally? |
|------|--------------------------|--------------------|
| 9200 | ES REST API (HTTP/S)     | Via load balancer   |
| 9300 | ES transport (inter-node)| Never              |
| 5601 | Kibana                   | Via load balancer   |
| 5044 | Logstash Beats input     | Internal only      |
| 8200 | APM Server               | From app network   |

---

## 3. Docker Compose for Development

```yaml
version: "3.8"
services:
  es01:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.12.0
    container_name: es01
    environment:
      - node.name=es01
      - cluster.name=dev-cluster
      - discovery.seed_hosts=es02,es03
      - cluster.initial_master_nodes=es01,es02,es03
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD:-changeme}
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - xpack.security.transport.ssl.enabled=false
      - "ES_JAVA_OPTS=-Xms2g -Xmx2g"
    mem_limit: 4g
    ulimits: { memlock: { soft: -1, hard: -1 } }
    volumes: [esdata01:/usr/share/elasticsearch/data]
    ports: ["9200:9200"]
    networks: [elastic]
    healthcheck:
      test: ["CMD-SHELL", "curl -s -u elastic:${ELASTIC_PASSWORD:-changeme} http://localhost:9200/_cluster/health | grep -qE '\"status\":\"(green|yellow)\"'"]
      interval: 15s
      timeout: 10s
      retries: 20

  es02:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.12.0
    container_name: es02
    environment:
      - node.name=es02
      - cluster.name=dev-cluster
      - discovery.seed_hosts=es01,es03
      - cluster.initial_master_nodes=es01,es02,es03
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD:-changeme}
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - xpack.security.transport.ssl.enabled=false
      - "ES_JAVA_OPTS=-Xms2g -Xmx2g"
    mem_limit: 4g
    ulimits: { memlock: { soft: -1, hard: -1 } }
    volumes: [esdata02:/usr/share/elasticsearch/data]
    networks: [elastic]
    healthcheck:
      test: ["CMD-SHELL", "curl -s -u elastic:${ELASTIC_PASSWORD:-changeme} http://localhost:9200/_cluster/health | grep -qE '\"status\":\"(green|yellow)\"'"]
      interval: 15s
      timeout: 10s
      retries: 20

  es03:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.12.0
    container_name: es03
    environment:
      - node.name=es03
      - cluster.name=dev-cluster
      - discovery.seed_hosts=es01,es02
      - cluster.initial_master_nodes=es01,es02,es03
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD:-changeme}
      - bootstrap.memory_lock=true
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - xpack.security.transport.ssl.enabled=false
      - "ES_JAVA_OPTS=-Xms2g -Xmx2g"
    mem_limit: 4g
    ulimits: { memlock: { soft: -1, hard: -1 } }
    volumes: [esdata03:/usr/share/elasticsearch/data]
    networks: [elastic]
    healthcheck:
      test: ["CMD-SHELL", "curl -s -u elastic:${ELASTIC_PASSWORD:-changeme} http://localhost:9200/_cluster/health | grep -qE '\"status\":\"(green|yellow)\"'"]
      interval: 15s
      timeout: 10s
      retries: 20

  logstash:
    image: docker.elastic.co/logstash/logstash:8.12.0
    container_name: logstash
    environment:
      - "LS_JAVA_OPTS=-Xms1g -Xmx1g"
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD:-changeme}
    mem_limit: 2g
    volumes:
      - ./logstash/pipeline:/usr/share/logstash/pipeline:ro
      - ./logstash/config/logstash.yml:/usr/share/logstash/config/logstash.yml:ro
    ports: ["5044:5044"]
    networks: [elastic]
    depends_on: { es01: { condition: service_healthy } }

  kibana:
    image: docker.elastic.co/kibana/kibana:8.12.0
    container_name: kibana
    environment:
      - ELASTICSEARCH_HOSTS=http://es01:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=${KIBANA_PASSWORD:-changeme}
      - XPACK_SECURITY_ENABLED=true
    mem_limit: 2g
    ports: ["5601:5601"]
    networks: [elastic]
    depends_on: { es01: { condition: service_healthy } }
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:5601/api/status | grep -q 'available'"]
      interval: 15s
      timeout: 10s
      retries: 20

  filebeat:
    image: docker.elastic.co/beats/filebeat:8.12.0
    container_name: filebeat
    user: root
    command: filebeat -e --strict.perms=false
    volumes:
      - ./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [elastic]
    depends_on: { es01: { condition: service_healthy } }

volumes:
  esdata01:
  esdata02:
  esdata03:

networks:
  elastic:
    driver: bridge
```

```bash
export ELASTIC_PASSWORD=MyStr0ngP@ss KIBANA_PASSWORD=K1banaP@ss
docker compose up -d && docker compose ps
curl -u elastic:MyStr0ngP@ss http://localhost:9200/_cluster/health?pretty
```

---

## 4. ECK (Elastic Cloud on Kubernetes) for Production

### Installing the ECK Operator

```bash
kubectl create -f https://download.elastic.co/downloads/eck/2.11.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/2.11.0/operator.yaml
kubectl -n elastic-system get pods   # Verify operator is running
```

### Elasticsearch Manifest

```yaml
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: production
  namespace: elastic
spec:
  version: 8.12.0
  nodeSets:
    - name: masters
      count: 3
      config:
        node.roles: ["master"]
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources: { requests: { memory: 4Gi, cpu: "1" }, limits: { memory: 4Gi, cpu: "2" } }
              env: [{ name: ES_JAVA_OPTS, value: "-Xms2g -Xmx2g" }]
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      elasticsearch.k8s.elastic.co/statefulset-name: production-es-masters
                  topologyKey: kubernetes.io/hostname
          tolerations:
            - { key: "dedicated", operator: "Equal", value: "es-master", effect: "NoSchedule" }
          nodeSelector: { node-role: es-master }
      volumeClaimTemplates:
        - metadata: { name: elasticsearch-data }
          spec: { accessModes: ["ReadWriteOnce"], storageClassName: gp3-encrypted, resources: { requests: { storage: 10Gi } } }

    - name: hot
      count: 6
      config:
        node.roles: ["data_hot", "data_content", "ingest"]
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources: { requests: { memory: 32Gi, cpu: "8" }, limits: { memory: 32Gi, cpu: "16" } }
              env: [{ name: ES_JAVA_OPTS, value: "-Xms16g -Xmx16g" }]
          nodeSelector: { node-role: es-hot }
      volumeClaimTemplates:
        - metadata: { name: elasticsearch-data }
          spec: { accessModes: ["ReadWriteOnce"], storageClassName: gp3-iops, resources: { requests: { storage: 2Ti } } }

    - name: warm
      count: 3
      config:
        node.roles: ["data_warm"]
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources: { requests: { memory: 32Gi, cpu: "4" }, limits: { memory: 32Gi, cpu: "8" } }
              env: [{ name: ES_JAVA_OPTS, value: "-Xms16g -Xmx16g" }]
          nodeSelector: { node-role: es-warm }
      volumeClaimTemplates:
        - metadata: { name: elasticsearch-data }
          spec: { accessModes: ["ReadWriteOnce"], storageClassName: st1, resources: { requests: { storage: 8Ti } } }

    - name: cold
      count: 2
      config:
        node.roles: ["data_cold"]
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources: { requests: { memory: 16Gi, cpu: "2" }, limits: { memory: 16Gi, cpu: "4" } }
              env: [{ name: ES_JAVA_OPTS, value: "-Xms8g -Xmx8g" }]
      volumeClaimTemplates:
        - metadata: { name: elasticsearch-data }
          spec: { accessModes: ["ReadWriteOnce"], storageClassName: sc1, resources: { requests: { storage: 16Ti } } }

  podDisruptionBudget:
    spec:
      maxUnavailable: 1
```

### Kibana CR

```yaml
apiVersion: kibana.k8s.elastic.co/v1
kind: Kibana
metadata: { name: production, namespace: elastic }
spec:
  version: 8.12.0
  count: 2
  elasticsearchRef: { name: production }
  podTemplate:
    spec:
      containers:
        - name: kibana
          resources: { requests: { memory: 2Gi, cpu: "1" }, limits: { memory: 4Gi, cpu: "2" } }
```

### Fleet Server and Elastic Agent

```yaml
apiVersion: agent.k8s.elastic.co/v1alpha1
kind: Agent
metadata: { name: fleet-server, namespace: elastic }
spec:
  version: 8.12.0
  kibanaRef: { name: production }
  elasticsearchRefs: [{ name: production }]
  mode: fleet
  fleetServerEnabled: true
  policyID: eck-fleet-server
  deployment:
    replicas: 2
    podTemplate:
      spec:
        containers:
          - name: agent
            resources: { requests: { memory: 1Gi, cpu: 500m }, limits: { memory: 2Gi, cpu: "1" } }
---
apiVersion: agent.k8s.elastic.co/v1alpha1
kind: Agent
metadata: { name: elastic-agent, namespace: elastic }
spec:
  version: 8.12.0
  kibanaRef: { name: production }
  fleetServerRef: { name: fleet-server }
  mode: fleet
  policyID: eck-agent
  daemonSet:
    podTemplate:
      spec:
        tolerations: [{ operator: Exists }]
        containers:
          - name: agent
            resources: { requests: { memory: 512Mi, cpu: 200m }, limits: { memory: 1Gi, cpu: 500m } }
            volumeMounts: [{ name: varlog, mountPath: /var/log, readOnly: true }]
        volumes: [{ name: varlog, hostPath: { path: /var/log } }]
```

---

## 5. Security Setup

### TLS Certificate Generation

```bash
# Generate CA
bin/elasticsearch-certutil ca --out elastic-stack-ca.p12 --pass ""

# Generate node certificates
bin/elasticsearch-certutil cert \
  --ca elastic-stack-ca.p12 --ca-pass "" \
  --out elastic-certificates.p12 --pass "" \
  --dns "es01,es02,es03,localhost" --ip "127.0.0.1"

# Generate HTTP certificates (interactive wizard)
bin/elasticsearch-certutil http
```

### Transport and HTTP Layer TLS

Add to `elasticsearch.yml`:

```yaml
xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  keystore.path: elastic-certificates.p12
  truststore.path: elastic-certificates.p12
xpack.security.http.ssl:
  enabled: true
  keystore.path: http.p12
  truststore.path: http.p12
```

```bash
# Store passwords in the keystore
bin/elasticsearch-keystore add xpack.security.transport.ssl.keystore.secure_password
bin/elasticsearch-keystore add xpack.security.http.ssl.keystore.secure_password
```

### Users, Roles, and API Keys

```bash
# Role with index-level and field-level security
curl -k -u elastic:$ELASTIC_PASSWORD -X POST "https://localhost:9200/_security/role/logs_reader" \
  -H "Content-Type: application/json" -d '{
  "indices": [{
    "names": ["logs-*"],
    "privileges": ["read", "view_index_metadata"],
    "field_security": {
      "grant": ["@timestamp", "message", "log.level", "service.name"],
      "except": ["user.email", "client.ip"]
    },
    "query": "{\"term\": {\"environment\": \"production\"}}"
  }],
  "cluster": ["monitor"]
}'

# Create a user
curl -k -u elastic:$ELASTIC_PASSWORD -X POST "https://localhost:9200/_security/user/log_viewer" \
  -H "Content-Type: application/json" -d '{
  "password": "v13wer_s3cure!", "roles": ["logs_reader"], "full_name": "Log Viewer"
}'

# Create an API key for Logstash
curl -k -u elastic:$ELASTIC_PASSWORD -X POST "https://localhost:9200/_security/api_key" \
  -H "Content-Type: application/json" -d '{
  "name": "logstash-key", "expiration": "365d",
  "role_descriptors": {
    "logstash_writer": {
      "cluster": ["monitor", "manage_index_templates", "manage_ilm"],
      "indices": [{ "names": ["logs-*", "metrics-*"], "privileges": ["create_index", "write", "manage"] }]
    }
  }
}'
```

### Kibana Spaces with RBAC

```bash
# Create a space
curl -u elastic:$ELASTIC_PASSWORD -X POST "http://localhost:5601/api/spaces/space" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" -d '{
  "id": "platform", "name": "Platform Engineering",
  "disabledFeatures": ["canvas", "maps"], "color": "#2196F3"
}'

# Role scoped to that space
curl -k -u elastic:$ELASTIC_PASSWORD -X POST "https://localhost:9200/_security/role/platform_viewer" \
  -H "Content-Type: application/json" -d '{
  "indices": [{ "names": ["logs-infra-*"], "privileges": ["read"] }],
  "applications": [{
    "application": "kibana-.kibana",
    "privileges": ["feature_discover.read", "feature_dashboard.read"],
    "resources": ["space:platform"]
  }]
}'
```

---

## 6. Backup and Restore

### Snapshot Repository Registration

```bash
# S3
curl -X PUT "https://localhost:9200/_snapshot/s3_backups" -u elastic:$ELASTIC_PASSWORD \
  -H "Content-Type: application/json" -d '{
  "type": "s3",
  "settings": { "bucket": "my-es-snapshots", "region": "us-east-1", "base_path": "production", "server_side_encryption": true }
}'

# GCS
curl -X PUT "https://localhost:9200/_snapshot/gcs_backups" -u elastic:$ELASTIC_PASSWORD \
  -H "Content-Type: application/json" -d '{
  "type": "gcs", "settings": { "bucket": "my-es-snapshots", "base_path": "production" }
}'

# Azure Blob
curl -X PUT "https://localhost:9200/_snapshot/azure_backups" -u elastic:$ELASTIC_PASSWORD \
  -H "Content-Type: application/json" -d '{
  "type": "azure", "settings": { "container": "es-snapshots", "base_path": "production" }
}'

curl -X POST "https://localhost:9200/_snapshot/s3_backups/_verify" -u elastic:$ELASTIC_PASSWORD
```

### Snapshot Lifecycle Management

```bash
curl -X PUT "https://localhost:9200/_slm/policy/nightly-snapshots" -u elastic:$ELASTIC_PASSWORD \
  -H "Content-Type: application/json" -d '{
  "schedule": "0 30 2 * * ?",
  "name": "<nightly-{now/d}>",
  "repository": "s3_backups",
  "config": {
    "indices": ["logs-*", "metrics-*", ".kibana*"],
    "ignore_unavailable": true, "include_global_state": true
  },
  "retention": { "expire_after": "30d", "min_count": 7, "max_count": 30 }
}'

# Test it immediately
curl -X POST "https://localhost:9200/_slm/policy/nightly-snapshots/_execute" -u elastic:$ELASTIC_PASSWORD
```

### Restore Procedures

```bash
# List snapshots
curl "https://localhost:9200/_snapshot/s3_backups/_all?verbose=false" -u elastic:$ELASTIC_PASSWORD

# Full restore
curl -X POST "https://localhost:9200/_snapshot/s3_backups/nightly-2024.01.15/_restore" \
  -u elastic:$ELASTIC_PASSWORD -H "Content-Type: application/json" -d '{
  "indices": "*", "include_global_state": false
}'

# Partial restore with rename (avoids collisions with live indices)
curl -X POST "https://localhost:9200/_snapshot/s3_backups/nightly-2024.01.15/_restore" \
  -u elastic:$ELASTIC_PASSWORD -H "Content-Type: application/json" -d '{
  "indices": "logs-production-2024.01.14",
  "rename_pattern": "(.+)", "rename_replacement": "restored-$1"
}'

# Cross-cluster restore: register the same repo on the target cluster, then restore with rename
# Verify restore
curl "https://localhost:9200/restored-*/_count" -u elastic:$ELASTIC_PASSWORD
```

---

## 7. Monitoring the Stack Itself

### Metricbeat Configuration

Send monitoring data to a **separate** cluster to avoid feedback loops during outages.

```yaml
metricbeat.modules:
  - module: elasticsearch
    xpack.enabled: true
    period: 10s
    hosts: ["https://es01:9200", "https://es02:9200", "https://es03:9200"]
    username: "${ES_MONITORING_USER}"
    password: "${ES_MONITORING_PASS}"
    ssl.certificate_authorities: ["/etc/metricbeat/ca.pem"]
  - module: logstash
    xpack.enabled: true
    period: 10s
    hosts: ["http://logstash:9600"]
  - module: kibana
    xpack.enabled: true
    period: 10s
    hosts: ["https://kibana:5601"]
    username: "${ES_MONITORING_USER}"
    password: "${ES_MONITORING_PASS}"
output.elasticsearch:
  hosts: ["https://monitoring-cluster:9200"]
  username: "${ES_MONITORING_USER}"
  password: "${ES_MONITORING_PASS}"
```

### Key Metrics to Watch

| Metric                     | Healthy          | Alert When                      |
|----------------------------|------------------|---------------------------------|
| Cluster status             | `green`          | `yellow` >5 min or any `red`    |
| JVM heap usage             | <75%             | >85% sustained 5 min            |
| GC time (old gen)          | <500ms           | >1s or >50% time in GC          |
| Search latency (p99)       | <500ms           | >2s sustained 10 min            |
| Indexing rate              | Stable           | Drop >50% or stop               |
| Thread pool rejections     | 0                | Any rejections in 5 min         |
| Disk usage                 | <85%             | >85% (watermark trigger)        |
| Unassigned shards          | 0                | >0 for 10 min                   |

### Alerting on Cluster Health

```bash
curl -s -u elastic:$ELASTIC_PASSWORD "https://localhost:9200/_cluster/health?pretty"
curl -s -u elastic:$ELASTIC_PASSWORD "https://localhost:9200/_nodes/stats/jvm,os?pretty" \
  | jq '.nodes[] | {name: .name, heap_pct: .jvm.mem.heap_used_percent, cpu: .os.cpu.percent}'
curl -s -u elastic:$ELASTIC_PASSWORD \
  "https://localhost:9200/_cat/thread_pool?v&h=node_name,name,active,queue,rejected&s=rejected:desc"
```

---

## 8. Upgrade Strategies

### Pre-Upgrade Checklist

```bash
# 1. Check deprecation warnings
curl -u elastic:$ELASTIC_PASSWORD "https://localhost:9200/_migration/deprecations?pretty"

# 2. Snapshot everything
curl -X PUT "https://localhost:9200/_snapshot/s3_backups/pre-upgrade-$(date +%Y%m%d)" \
  -u elastic:$ELASTIC_PASSWORD -H "Content-Type: application/json" \
  -d '{ "indices": "*", "include_global_state": true }'

# 3. Review breaking changes in Elastic release notes
# 4. Disable shard allocation
curl -X PUT "https://localhost:9200/_cluster/settings" -u elastic:$ELASTIC_PASSWORD \
  -H "Content-Type: application/json" \
  -d '{ "persistent": { "cluster.routing.allocation.enable": "primaries" } }'

# 5. Flush
curl -X POST "https://localhost:9200/_flush" -u elastic:$ELASTIC_PASSWORD
```

### Rolling Upgrade Procedure

Upgrade one node at a time for zero downtime:

```bash
# On each node, repeat:
sudo systemctl stop elasticsearch
sudo dpkg -i elasticsearch-8.13.0-amd64.deb   # or rpm -U
sudo systemctl start elasticsearch
curl -u elastic:$ELASTIC_PASSWORD "https://localhost:9200/_cat/nodes?v"  # Wait for rejoin

# Re-enable allocation, wait for green, then proceed to next node
curl -X PUT "https://localhost:9200/_cluster/settings" -u elastic:$ELASTIC_PASSWORD \
  -H "Content-Type: application/json" \
  -d '{ "persistent": { "cluster.routing.allocation.enable": null } }'
curl -u elastic:$ELASTIC_PASSWORD "https://localhost:9200/_cluster/health?wait_for_status=green&timeout=5m"
```

**Upgrade order**: Elasticsearch → Kibana → Logstash → Beats/Agents

### Version Compatibility Matrix

| Component    | ES 7.17 | ES 8.x | Notes                                     |
|--------------|---------|--------|-------------------------------------------|
| Kibana       | 7.17    | 8.x   | Must match ES major.minor exactly         |
| Logstash     | 7.17    | 7.17+  | 7.17 works with ES 8.x via compat mode   |
| Filebeat     | 7.17    | 7.17+  | Forward-compatible (N → N or N+1)         |
| Metricbeat   | 7.17    | 7.17+  | Same as Filebeat                          |
| Elastic Agent| —       | 8.x   | Only available for 8.x                    |

**Rule**: Beats/Logstash version must never be **newer** than the target Elasticsearch version.

---

## 9. Multi-Tenant Setup

### Kibana Spaces for Team Isolation

```bash
# Create spaces per team
for team in backend frontend platform security; do
  curl -u elastic:$ELASTIC_PASSWORD -X POST "http://localhost:5601/api/spaces/space" \
    -H "kbn-xsrf: true" -H "Content-Type: application/json" \
    -d "{\"id\": \"${team}\", \"name\": \"${team^} Team\"}"
done

# Role granting access to one space with specific indices
curl -k -u elastic:$ELASTIC_PASSWORD -X POST "https://localhost:9200/_security/role/backend_team" \
  -H "Content-Type: application/json" -d '{
  "indices": [{ "names": ["logs-backend-*", "metrics-backend-*"], "privileges": ["read"] }],
  "applications": [{
    "application": "kibana-.kibana",
    "privileges": ["feature_discover.all", "feature_dashboard.all", "feature_lens.all"],
    "resources": ["space:backend"]
  }]
}'
```

### Document-Level Security

For shared indices, restrict visibility with query-based DLS:

```bash
curl -k -u elastic:$ELASTIC_PASSWORD -X POST "https://localhost:9200/_security/role/team_alpha" \
  -H "Content-Type: application/json" -d '{
  "indices": [{
    "names": ["shared-logs-*"],
    "privileges": ["read"],
    "query": { "term": { "metadata.team_id": "alpha" } },
    "field_security": { "grant": ["*"], "except": ["debug.*"] }
  }]
}'
```

Use an ingest pipeline to route documents into team-specific indices:

```bash
curl -X PUT "https://localhost:9200/_ingest/pipeline/team-router" -u elastic:$ELASTIC_PASSWORD \
  -H "Content-Type: application/json" -d '{
  "processors": [{ "set": { "field": "_index", "value": "logs-{{metadata.team_id}}-{{_index}}" } }]
}'
```

### Cross-Space Dashboards

For SRE/leadership visibility across all teams:

```bash
curl -k -u elastic:$ELASTIC_PASSWORD -X POST "https://localhost:9200/_security/role/sre_global" \
  -H "Content-Type: application/json" -d '{
  "indices": [{ "names": ["logs-*", "metrics-*"], "privileges": ["read"] }],
  "applications": [{
    "application": "kibana-.kibana",
    "privileges": ["feature_discover.read", "feature_dashboard.all", "feature_lens.all"],
    "resources": ["space:*"]
  }]
}'

# Cross-tenant data view
curl -u elastic:$ELASTIC_PASSWORD -X POST "http://localhost:5601/api/data_views/data_view" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" -d '{
  "data_view": { "title": "logs-*", "name": "All Team Logs", "timeFieldName": "@timestamp" }
}'
```

---

## Quick Reference

| Task               | API                                            |
|--------------------|------------------------------------------------|
| Cluster health     | `GET _cluster/health`                          |
| Node list          | `GET _cat/nodes?v`                             |
| Shard status       | `GET _cat/shards?v`                            |
| Disable allocation | `PUT _cluster/settings` → `enable: primaries`  |
| Take snapshot      | `PUT _snapshot/repo/snap-name`                 |
