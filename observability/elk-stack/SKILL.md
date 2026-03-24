---
name: elk-stack
description: >
  Expert guidance for the Elastic (ELK) Stack: Elasticsearch, Logstash, Kibana, Beats, and Elastic Agent.
  Use when setting up Elasticsearch clusters, writing Logstash pipelines, configuring Filebeat/Metricbeat,
  building Kibana dashboards, writing Elasticsearch queries (DSL), or managing log aggregation with the
  Elastic Stack. Covers index lifecycle management (ILM), data streams, ingest pipelines, Elastic APM,
  alerting, security (TLS, RBAC), cluster operations, and Docker/Kubernetes deployment patterns.
  Do NOT use for Prometheus metrics monitoring, Grafana-only dashboards, Splunk queries, Datadog log
  management, or Loki/Grafana log aggregation.
---

# ELK Stack / Elastic Stack

## Architecture Overview

The Elastic Stack consists of layered components. Deploy and scale each tier independently:

- **Beats / Elastic Agent** — Lightweight shippers on edge hosts. Collect logs, metrics, uptime, audit data.
- **Logstash** — Central processing pipeline. Parse, enrich, transform, route events.
- **Elasticsearch** — Distributed search and analytics engine. Stores, indexes, and queries all data.
- **Kibana** — Visualization and management UI. Dashboards, alerting, Fleet, APM, SIEM.
- **Fleet Server** — Central coordinator for Elastic Agent deployments. Manages policies and upgrades.

Data flow: `Beats/Agent → (optional Logstash) → Elasticsearch → Kibana`

For HA, run minimum 3 master-eligible nodes, 2+ data nodes, and load-balance Kibana.

## Elasticsearch

### Indices, Mappings, and Analyzers

Define explicit mappings. Avoid dynamic mapping in production — it causes mapping explosions.

```json
PUT /app-logs
{
  "settings": { "number_of_shards": 3, "number_of_replicas": 1, "refresh_interval": "5s" },
  "mappings": {
    "properties": {
      "@timestamp":  { "type": "date" },
      "message":     { "type": "text", "analyzer": "standard" },
      "level":       { "type": "keyword" },
      "host":        { "type": "keyword" },
      "duration_ms": { "type": "integer" },
      "geo":         { "type": "geo_point" }
    }
  }
}
```

Use `keyword` for exact-match fields (status codes, hostnames). Use `text` with analyzers for full-text search. Create custom analyzers for language-specific tokenization.

### Shards and Replicas

- Target 20–40 GB per shard. Oversized shards slow recovery; undersized waste overhead.
- Set replicas ≥ 1 for fault tolerance. Use 0 only during bulk re-indexing.
- Monitor: `GET _cat/shards?v` and `GET _cluster/health`.

### Index Lifecycle Management (ILM)

Automate hot → warm → cold → frozen → delete transitions:

```json
PUT _ilm/policy/logs-policy
{
  "policy": {
    "phases": {
      "hot":    { "min_age": "0ms",  "actions": { "rollover": { "max_size": "30gb", "max_age": "1d" } } },
      "warm":   { "min_age": "7d",   "actions": { "shrink": { "number_of_shards": 1 }, "forcemerge": { "max_num_segments": 1 } } },
      "cold":   { "min_age": "30d",  "actions": { "allocate": { "require": { "data": "cold" } } } },
      "delete": { "min_age": "90d",  "actions": { "delete": {} } }
    }
  }
}
```

For simpler time-series retention, use data stream lifecycle (8.14+) instead of ILM — fewer knobs, applied directly on data streams.

### Index Templates, Component Templates, and Data Streams

Use component templates for reusable mappings. Compose them into index templates:

```json
PUT _component_template/log-mappings
{
  "template": { "mappings": { "properties": {
    "@timestamp": { "type": "date" },
    "message": { "type": "text" },
    "log.level": { "type": "keyword" }
  } } }
}
PUT _index_template/logs-template
{
  "index_patterns": ["logs-*"],
  "data_stream": {},
  "composed_of": ["log-mappings"],
  "priority": 200,
  "template": { "settings": { "number_of_replicas": 1 } }
}
```

Data streams manage backing indices automatically for time-series data. Write with `POST logs-app/_doc` — no manual index creation needed.

## Elasticsearch Query DSL

### Core Queries

```json
// Match (full-text, analyzed)
{ "query": { "match": { "message": "connection timeout" } } }

// Term (exact keyword match — do NOT use on text fields)
{ "query": { "term": { "level": "ERROR" } } }

// Range
{ "query": { "range": { "@timestamp": { "gte": "now-1h", "lte": "now" } } } }

// Bool (combine with must, should, must_not, filter)
{ "query": { "bool": {
    "must":     [{ "match": { "message": "timeout" } }],
    "filter":   [{ "term": { "level": "ERROR" } }, { "range": { "@timestamp": { "gte": "now-24h" } } }],
    "must_not": [{ "term": { "host": "test-server" } }]
} } }

// Nested (for nested object arrays)
{ "query": { "nested": {
    "path": "headers",
    "query": { "bool": { "must": [{ "term": { "headers.name": "Content-Type" } }] } }
} } }
```

### Aggregations

```json
{ "size": 0, "aggs": {
    "errors_per_host": {
      "terms": { "field": "host", "size": 20 },
      "aggs": { "over_time": { "date_histogram": { "field": "@timestamp", "calendar_interval": "1h" } } }
    },
    "latency_percentiles": { "percentiles": { "field": "duration_ms", "percents": [50, 95, 99] } },
    "unique_users": { "cardinality": { "field": "user.id" } }
} }
```

Place `filter` clauses in `bool.filter` (not `must`) to leverage caching and skip scoring. Add `"size": 0` when only aggregations are needed.

## Logstash

### Pipeline Configuration

Structure every pipeline with `input`, `filter`, and `output` blocks:

```ruby
input {
  beats { port => 5044 }
  kafka { topics => ["app-logs"] bootstrap_servers => "kafka:9092" codec => json }
}
filter {
  grok {
    match => { "message" => "%{TIMESTAMP_ISO8601:timestamp} %{LOGLEVEL:level} %{GREEDYDATA:msg}" }
  }
  # dissect is faster than grok for fixed-format logs
  dissect {
    mapping => { "message" => "%{timestamp} %{level} [%{thread}] %{class} - %{msg}" }
  }
  date { match => ["timestamp", "ISO8601", "yyyy-MM-dd HH:mm:ss"] target => "@timestamp" }
  mutate {
    rename => { "msg" => "log_message" }
    remove_field => ["message", "timestamp"]
    add_field => { "environment" => "production" }
  }
  geoip { source => "client_ip" target => "geo" }
  if [level] == "ERROR" { mutate { add_tag => ["alert"] } }
}
output {
  elasticsearch {
    hosts => ["https://es-node:9200"]
    index => "logs-%{+YYYY.MM.dd}"
    user => "logstash_writer"
    password => "${LS_PASSWORD}"
    ssl_certificate_verification => true
  }
}
```

Use `dissect` over `grok` when format is fixed — significantly faster. Use `pipelines.yml` to run multiple pipelines per Logstash instance.

## Filebeat

### Configuration and Modules

```yaml
filebeat.inputs:
  - type: filestream
    id: app-logs
    paths: ["/var/log/app/*.log"]
    parsers:
      - multiline:
          pattern: '^\d{4}-\d{2}-\d{2}'
          negate: true
          match: after
processors:
  - add_host_metadata: ~
  - add_cloud_metadata: ~
  - drop_event:
      when: { regexp: { message: "^DEBUG" } }
output.elasticsearch:
  hosts: ["https://es:9200"]
  index: "filebeat-%{+yyyy.MM.dd}"
  username: "filebeat_writer"
  password: "${FB_PASSWORD}"
  ssl.certificate_authorities: ["/etc/pki/ca.pem"]
```

Enable built-in modules: `filebeat modules enable nginx apache mysql postgresql`.

### Autodiscover for Containers

```yaml
filebeat.autodiscover:
  providers:
    - type: kubernetes
      hints.enabled: true
      templates:
        - condition: { contains: { kubernetes.labels.app: "myapp" } }
          config:
            - type: container
              paths: ["/var/log/containers/*-${data.kubernetes.container.id}.log"]
```

Annotate pods with `co.elastic.logs/enabled: "true"` to control collection.

## Metricbeat

Deploy as DaemonSet for node metrics, as Deployment for cluster-level:

```yaml
metricbeat.modules:
  - module: system
    metricsets: [cpu, memory, network, diskio, filesystem, process]
    period: 10s
  - module: docker
    metricsets: [container, cpu, memory, network]
    hosts: ["unix:///var/run/docker.sock"]
    period: 10s
  - module: kubernetes
    metricsets: [node, pod, container, volume]
    period: 10s
    hosts: ["https://${NODE_NAME}:10250"]
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
```

For cluster metrics (deployments, replicasets), use a separate Metricbeat Deployment pointing at kube-state-metrics.

## Kibana

### Data Views and Discover

Create data views (formerly index patterns) matching index names: `logs-*`, `filebeat-*`, `metrics-*`. Use KQL in Discover:

```
level: "ERROR" and message: "timeout" and @timestamp >= now-1h
host: "prod-*" and not tags: "test"
```

### Visualizations

- **Lens** — Drag-and-drop, recommended default. Supports bar, line, area, pie, heatmap, metric, table.
- **TSVB** — Advanced time-series with annotations, math expressions, multiple data sources.
- **Canvas** — Pixel-perfect, presentation-style dashboards with live data.
- **Saved Searches** — Embed Discover results directly into dashboards.

### Dashboards

Combine Lens, TSVB, Markdown, and Saved Search panels. Add time-range filter controls and dropdown filters at top. Configure drill-down links on panel click actions to navigate to filtered views. Export via **Stack Management → Saved Objects → Export** (ndjson). Import with `POST api/saved_objects/_import`. Version-control exported ndjson files.

## Security

### TLS/SSL

Generate certs with `elasticsearch-certutil`. Configure in `elasticsearch.yml`:

```yaml
xpack.security.enabled: true
xpack.security.transport.ssl:
  enabled: true
  verification_mode: certificate
  keystore.path: elastic-certificates.p12
xpack.security.http.ssl:
  enabled: true
  keystore.path: http.p12
```

### Authentication and RBAC

Supports native, LDAP, Active Directory, SAML, and OIDC realms. Define roles with index, field, and document-level security:

```json
POST _security/role/log_reader
{
  "indices": [{
    "names": ["logs-*"],
    "privileges": ["read", "view_index_metadata"],
    "field_security": { "grant": ["@timestamp", "message", "level", "host"] },
    "query": "{\"term\": {\"environment\": \"production\"}}"
  }]
}
```

`field_security` restricts visible fields. The `query` field restricts visible documents. Use `POST _security/api_key` for service accounts.

## Cluster Management

### Node Roles

Assign dedicated roles in `elasticsearch.yml`:

```yaml
node.roles: [master]              # Dedicated master
node.roles: [data_hot, data_content]  # Hot data (fast SSDs)
node.roles: [data_warm]           # Warm data (large HDD)
node.roles: []                    # Coordinating-only (query router)
```

### Shard Allocation Awareness

```yaml
cluster.routing.allocation.awareness.attributes: zone
node.attr.zone: us-east-1a
```

### Snapshot and Restore

```json
PUT _snapshot/my_backup
{ "type": "s3", "settings": { "bucket": "es-snapshots", "region": "us-east-1" } }
PUT _snapshot/my_backup/snapshot_1
{ "indices": "logs-*", "ignore_unavailable": true }
POST _snapshot/my_backup/snapshot_1/_restore
{ "indices": "logs-2024.*" }
```

### Cross-Cluster Replication (CCR)

Use CCR to replicate indices to a follower cluster for DR or geo-proximity reads. Configure remote clusters first, then create follower indices pointing to leader indices.

## Performance Tuning

- **JVM Heap**: 50% of RAM, max 31 GB (compressed oops). Set `Xms` = `Xmx`.
- **Refresh interval**: Set `30s`–`60s` for write-heavy workloads. Use `-1` during bulk loads.
- **Bulk indexing**: `_bulk` API with 5–15 MB payloads. Set replicas to 0 during initial load.
- **Query optimization**: Use `filter` context for non-scoring clauses. Use `keyword` for sort/agg.
- **Force merge**: `POST /index/_forcemerge?max_num_segments=1` on read-only indices.
- **Circuit breakers**: Monitor with `GET _nodes/stats/breaker`.
- **Index buffer**: Increase `indices.memory.index_buffer_size` for sustained high throughput.

## Ingest Pipelines

Process documents at index time without Logstash:

```json
PUT _ingest/pipeline/parse-logs
{
  "processors": [
    { "grok":   { "field": "message", "patterns": ["%{TIMESTAMP_ISO8601:ts} %{LOGLEVEL:level} %{GREEDYDATA:msg}"] } },
    { "date":   { "field": "ts", "formats": ["ISO8601"], "target_field": "@timestamp" } },
    { "remove": { "field": "ts" } },
    { "geoip":  { "field": "client_ip", "target_field": "geo" } },
    { "enrich": { "policy_name": "users-policy", "field": "user.email", "target_field": "user_info" } },
    { "set":    { "field": "ingested_at", "value": "{{{_ingest.timestamp}}}" } }
  ]
}
// Simulate before deploying
POST _ingest/pipeline/parse-logs/_simulate
{ "docs": [{ "_source": { "message": "2024-01-15T10:30:00Z ERROR Connection refused", "client_ip": "8.8.8.8" } }] }
```

Assign to index templates: `"default_pipeline": "parse-logs"` in settings.

## Elastic APM

Install language-specific agents (Java, Node.js, Python, Go, .NET, Ruby, PHP):

```javascript
const apm = require('elastic-apm-node').start({
  serviceName: 'my-api',
  serverUrl: 'https://apm-server:8200',
  environment: 'production',
  transactionSampleRate: 0.5
});
```

APM captures transactions (HTTP requests, background jobs), spans (DB queries, HTTP calls, cache ops), and errors automatically. Use `apm.startTransaction()` / `apm.startSpan()` for custom instrumentation. View in Kibana → Observability → APM.

## Alerting

Create rules in **Stack Management → Rules**. Types: Elasticsearch query, log threshold, metric threshold, anomaly detection.

```json
PUT _watcher/watch/error-spike
{
  "trigger":   { "schedule": { "interval": "5m" } },
  "input":     { "search": { "request": { "indices": ["logs-*"],
    "body": { "query": { "bool": { "filter": [
      { "term": { "level": "ERROR" } },
      { "range": { "@timestamp": { "gte": "now-5m" } } }
    ] } } } } } },
  "condition": { "compare": { "ctx.payload.hits.total.value": { "gt": 100 } } },
  "actions":   { "notify": { "webhook": {
    "method": "POST", "url": "https://hooks.slack.com/xxx",
    "body": "{{ctx.payload.hits.total.value}} errors in last 5 min" } } }
}
```

Prefer Kibana alerting rules over Watcher for new setups — supports connectors for Slack, PagerDuty, email, webhooks, ServiceNow.

## Docker / Kubernetes Deployment

For development, use the single-node Docker Compose quick-start or the full 3-node production-like stack in [assets/docker-compose.yml](assets/docker-compose.yml). Run `scripts/setup-elk-stack.sh` for automated TLS-secured setup.

For production Kubernetes, deploy with ECK (Elastic Cloud on Kubernetes):

```bash
kubectl create -f https://download.elastic.co/downloads/eck/2.14.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/2.14.0/operator.yaml
```

See [Deployment Guide](references/deployment-guide.md) for full ECK manifests (master/hot/warm/cold node sets, Kibana, Fleet Server, Agent DaemonSet, PDB, affinity rules).

Deploy Elastic Agent as DaemonSet with Fleet for unified log/metric collection. Use the ECK Agent CRD. Prefer Elastic Agent over standalone Beats for new Kubernetes deployments.

## Reference Documents

Deep-dive guides in `references/`:

| Document | Topics |
|----------|--------|
| [Advanced Patterns](references/advanced-patterns.md) | Script queries, runtime fields, search templates, async search, pipeline/matrix/composite aggregations, custom analyzers, cross-cluster search/replication, data streams, ILM design, ingest processors, rollups, transforms, searchable snapshots, Fleet management |
| [Troubleshooting](references/troubleshooting.md) | Cluster yellow/red diagnosis, unassigned shards, JVM heap pressure, slow search (_profile API), mapping explosions, Logstash debugging (DLQ, persistent queues), Filebeat registry, Kibana saved object conflicts, circuit breakers, disk watermarks, split-brain, index corruption |
| [Deployment Guide](references/deployment-guide.md) | Sizing/capacity planning, node role architecture, Docker Compose dev setup, ECK production deployment, TLS/security setup, snapshot backup/restore (S3/GCS/Azure), monitoring the stack, rolling upgrades, multi-tenant RBAC |

## Helper Scripts

Executable scripts in `scripts/` (run with `--help` for usage):

| Script | Purpose |
|--------|---------|
| [setup-elk-stack.sh](scripts/setup-elk-stack.sh) | Deploys a full ELK stack via Docker Compose with TLS certs, 3 ES nodes, Logstash, Kibana, Filebeat. Flags: `--output-dir`, `--version`, `--password` |
| [es-cluster-health.sh](scripts/es-cluster-health.sh) | Color-coded cluster diagnostics: health status, nodes, shard allocation, disk/JVM usage, pending tasks. Flags: `--url`, `--user`, `--password` |
| [index-lifecycle-setup.sh](scripts/index-lifecycle-setup.sh) | Creates ILM policies (logs/metrics/APM), component templates, and index templates. Flags: `--url`, `--user`, `--password` |

## Asset Templates

Ready-to-use configurations in `assets/`:

| Asset | Description |
|-------|-------------|
| [docker-compose.yml](assets/docker-compose.yml) | Production-like stack: 3 ES nodes with TLS, Logstash, Kibana, Filebeat, health checks, resource limits |
| [logstash/pipeline.conf](assets/logstash/pipeline.conf) | Multi-input pipeline (beats/syslog/HTTP) with grok, geoip, useragent, fingerprint dedup, conditional output routing |
| [filebeat/filebeat.yml](assets/filebeat/filebeat.yml) | Docker autodiscover with hints, container-specific templates, processors, ILM-enabled ES output |
| [elasticsearch/ilm-policy.json](assets/elasticsearch/ilm-policy.json) | 5-phase ILM template: hot → warm → cold → frozen → delete with rollover, shrink, searchable snapshots |
