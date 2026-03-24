# Advanced Prometheus Patterns

A comprehensive reference for advanced Prometheus monitoring patterns covering
PromQL mastery, histogram strategies, federation, long-term storage, and modern features.

## Table of Contents

- [PromQL Advanced Queries](#promql-advanced-queries)
  - [Complex Aggregations](#complex-aggregations)
  - [Multi-Dimensional Analysis](#multi-dimensional-analysis)
  - [Subqueries](#subqueries)
  - [Absent and Absent Over Time](#absent-and-absent-over-time)
- [Histogram Best Practices](#histogram-best-practices)
  - [Bucket Selection Strategies](#bucket-selection-strategies)
  - [Percentile Accuracy and Error Bounds](#percentile-accuracy-and-error-bounds)
- [Federation Patterns](#federation-patterns)
  - [Hierarchical Federation](#hierarchical-federation)
  - [Cross-Cluster Federation](#cross-cluster-federation)
- [Remote Write/Read Architecture](#remote-writeread-architecture)
  - [Queue Configuration](#queue-configuration)
  - [Sharding](#sharding)
  - [Write-Ahead Log (WAL)](#write-ahead-log-wal)
- [Thanos vs Mimir vs Cortex Comparison](#thanos-vs-mimir-vs-cortex-comparison)
- [Exemplars with Tracing Integration](#exemplars-with-tracing-integration)
- [Native Histograms](#native-histograms)
- [Recording Rule Optimization Strategies](#recording-rule-optimization-strategies)
- [High-Availability Prometheus Pairs](#high-availability-prometheus-pairs)

---

## PromQL Advanced Queries

### Complex Aggregations

**Top-K with grouped aggregation — busiest endpoints per service:**

```promql
topk(5,
  sum by (service, endpoint) (
    rate(http_requests_total[5m])
  )
) by (service)
```

**Error ratio with division-by-zero protection:**

```promql
sum by (service) (rate(http_requests_total{status=~"5.."}[5m]))
/
clamp_min(
  sum by (service) (rate(http_requests_total[5m])),
  1
)
```

**Multi-level aggregation — per-instance rates aggregated to cluster:**

```promql
avg by (cluster) (
  sum by (cluster, instance) (
    rate(node_cpu_seconds_total{mode!="idle"}[5m])
  )
)
```

**Cross-metric correlation with label manipulation:**

```promql
label_replace(
  sum by (pod) (rate(container_cpu_usage_seconds_total[5m])),
  "deployment", "$1", "pod", "(.*)-[a-z0-9]+-[a-z0-9]+"
)
* on(deployment) group_left()
kube_deployment_spec_replicas
```

### Multi-Dimensional Analysis

**Outlier detection — deviation from the group mean:**

```promql
(
  sum by (instance, job) (rate(http_requests_total[5m]))
  -
  avg by (job) (sum by (instance, job) (rate(http_requests_total[5m])))
)
/
stddev by (job) (sum by (instance, job) (rate(http_requests_total[5m])))
```

**Day-over-day comparison:**

```promql
sum by (service) (rate(http_requests_total[5m]))
/
sum by (service) (rate(http_requests_total[5m] offset 1d))
```

### Subqueries

Subqueries apply range functions over instant vector results evaluated across a window.

**Moving max of 5-minute rates over the past hour:**

```promql
max_over_time(
  rate(http_requests_total[5m])[1h:1m]
)
```

**Sustained high-error detection — errors above 5% for 80% of the window:**

```promql
avg_over_time(
  (
    sum by (service) (rate(http_requests_total{status=~"5.."}[5m]))
    /
    sum by (service) (rate(http_requests_total[5m]))
    > bool 0.05
  )[30m:1m]
) > 0.8
```

**Detect accelerating traffic growth:**

```promql
deriv(
  rate(http_requests_total[5m])[1h:5m]
)
```

### Absent and Absent Over Time

**Detect missing metrics and scrape failures:**

```promql
absent(up{job="my-critical-service"})

absent_over_time(up{job="payment-service"}[10m])
```

**Stale data detection:**

```promql
(time() - timestamp(my_custom_metric)) > 300
```

**Multi-exporter availability check:**

```promql
absent(node_cpu_seconds_total{job="node-exporter"})
or
absent(container_cpu_usage_seconds_total{job="cadvisor"})
or
absent(kube_pod_info{job="kube-state-metrics"})
```

---

## Histogram Best Practices

### Bucket Selection Strategies

**Exponential buckets (recommended starting point for latency):**

```yaml
# Base: 0.01 (10ms), Factor: 2, Count: 10
buckets: [0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.64, 1.28, 2.56, 5.12]
```

**SLO-aligned buckets — dense around your SLO thresholds:**

```yaml
# SLO: 95% < 200ms, 99% < 1s
buckets: [0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.5, 0.75, 1.0, 2.5, 5.0, 10.0]
```

**Linear buckets for bounded distributions:**

```yaml
# Response sizes 0-10KB
buckets: [1024, 2048, 3072, 4096, 5120, 6144, 7168, 8192, 9216, 10240]
```

**Cardinality impact:** Each bucket is a separate series. With `n` label
combinations and `b` buckets you get `n × (b + 2)` series. Keep buckets at 8–15.

### Percentile Accuracy and Error Bounds

`histogram_quantile` assumes uniform distribution within each bucket and
linearly interpolates. The max error equals the bucket width:

```
max_error = bucket_upper_bound - bucket_lower_bound
```

For exponential buckets with factor `f`, relative error is `(f-1)/f`.

**Correct aggregation — aggregate buckets BEFORE computing quantiles:**

```promql
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)

# WRONG — averaging quantiles gives incorrect results:
# avg(histogram_quantile(0.99, rate(..._bucket[5m]) by (instance, le)))
```

---

## Federation Patterns

### Hierarchical Federation

**Leaf Prometheus (datacenter level):**

```yaml
global:
  scrape_interval: 15s
  external_labels:
    datacenter: us-east-1
```

**Recording rules for federation export (always pre-aggregate):**

```yaml
groups:
  - name: federation-exports
    interval: 30s
    rules:
      - record: job:http_requests_total:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))
      - record: job:http_request_duration_seconds:p99
        expr: |
          histogram_quantile(0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )
      - record: cluster:node_cpu:avg_utilization
        expr: 1 - avg by (cluster) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
```

**Global Prometheus federating from leaves:**

```yaml
scrape_configs:
  - job_name: 'federate-us-east'
    honor_labels: true
    metrics_path: '/federate'
    params:
      'match[]':
        - '{__name__=~"job:.*"}'
        - '{__name__=~"cluster:.*"}'
    static_configs:
      - targets: ['prometheus-us-east:9090']
```

### Cross-Cluster Federation

```yaml
scrape_configs:
  - job_name: 'federate-cluster-a'
    honor_labels: true
    metrics_path: '/federate'
    params:
      'match[]':
        - '{__name__=~"namespace:.*"}'
    kubernetes_sd_configs:
      - api_server: 'https://cluster-a-api:6443'
        role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_name]
        regex: prometheus
        action: keep
      - target_label: cluster
        replacement: cluster-a
```

**Key anti-patterns:** Never federate raw high-cardinality metrics; avoid
federation depth > 2 (use Thanos/Mimir instead); always set `honor_labels: true`.

---

## Remote Write/Read Architecture

### Queue Configuration

```yaml
remote_write:
  - url: "https://mimir.example.com/api/v1/push"
    queue_config:
      capacity: 10000
      max_shards: 200
      min_shards: 1
      max_samples_per_send: 2000
      batch_send_deadline: 5s
      min_backoff: 30ms
      max_backoff: 5s
      retry_on_http_429: true
```

| Symptom | Adjustment |
|---|---|
| `samples_pending` consistently high | Increase `max_shards` |
| HTTP 429 from receiver | Decrease `max_samples_per_send`, increase backoff |
| High memory usage | Decrease `capacity` |
| Dropped samples | Increase `capacity` and `max_shards` |

### Sharding

Prometheus auto-scales shards between `min_shards` and `max_shards` based on lag.
Each shard is an independent goroutine with its own connection.

**Monitoring remote write health:**

```promql
prometheus_remote_storage_shards
prometheus_remote_storage_samples_pending
rate(prometheus_remote_storage_failed_samples_total[5m])

# Queue lag
prometheus_remote_storage_highest_timestamp_in_seconds
- ignoring(remote_name, url)
prometheus_remote_storage_queue_highest_sent_timestamp_seconds
```

### Write-Ahead Log (WAL)

The WAL ensures durability across restarts. Remote write replays from WAL after crashes.

```yaml
storage:
  tsdb:
    wal-compression: true      # ~50% reduction in WAL disk usage
    wal-segment-size: 128MB
# Agent mode (WAL-only, no TSDB): prometheus --enable-feature=agent
```

**WAL health metrics:**

```promql
prometheus_tsdb_wal_corruptions_total        # Should be 0
prometheus_tsdb_wal_truncate_duration_seconds # Impacts scrape pauses
prometheus_tsdb_wal_storage_size_bytes
```

---

## Thanos vs Mimir vs Cortex Comparison

| Feature | Thanos | Mimir | Cortex |
|---|---|---|---|
| **Architecture** | Sidecar + components | Monolithic or microservices | Microservices |
| **Storage** | Object store (S3/GCS) | Object store | Object store + DynamoDB |
| **Multi-tenancy** | Limited (external labels) | Native (X-Scope-OrgID) | Native |
| **Downsampling** | Built-in (5m, 1h) | Not built-in | Not built-in |
| **Ingestion** | Sidecar upload or Receive | Remote write | Remote write |
| **HA dedup** | Querier-level | Ingester-level | Ingester-level |
| **Maintained by** | Community (CNCF) | Grafana Labs | Legacy (migrate to Mimir) |

**Thanos sidecar setup:**

```yaml
# docker-compose snippet
services:
  prometheus:
    image: prom/prometheus:v2.51.0
    command:
      - '--storage.tsdb.min-block-duration=2h'
      - '--storage.tsdb.max-block-duration=2h'
  thanos-sidecar:
    image: thanosio/thanos:v0.34.0
    command:
      - sidecar
      - '--tsdb.path=/prometheus'
      - '--prometheus.url=http://prometheus:9090'
      - '--objstore.config-file=/etc/thanos/bucket.yml'
  thanos-querier:
    image: thanosio/thanos:v0.34.0
    command:
      - query
      - '--store=thanos-sidecar:10901'
      - '--query.replica-label=replica'
```

**Mimir config:**

```yaml
target: all
multitenancy_enabled: false
blocks_storage:
  backend: s3
  s3:
    bucket_name: mimir-blocks
    region: us-east-1
  tsdb:
    dir: /data/tsdb
limits:
  max_global_series_per_user: 1500000
  ingestion_rate: 100000
```

**Decision guide:** Choose Thanos for existing Prometheus fleets needing
long-term storage and downsampling. Choose Mimir for greenfield deployments
with strong multi-tenancy needs. Migrate Cortex to Mimir.

---

## Exemplars with Tracing Integration

Exemplars attach trace IDs to metric samples, bridging metrics and distributed traces.

**Enable exemplar storage:**

```yaml
storage:
  exemplars:
    max_exemplars: 100000
```

**Instrumenting exemplars (Go):**

```go
requestDuration.With(prometheus.Labels{
    "method": r.Method,
    "path":   r.URL.Path,
}).(prometheus.ExemplarObserver).ObserveWithExemplar(
    duration,
    prometheus.Labels{"traceID": span.SpanContext().TraceID().String()},
)
```

**Grafana datasource config for trace linking:**

```yaml
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    jsonData:
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
          urlDisplayLabel: 'View Trace'
```

Exemplars appear as dots on Grafana histogram panels. Clicking a dot navigates
to the full trace in Tempo/Jaeger for the corresponding high-latency observation.

---

## Native Histograms

Native (sparse) histograms automatically determine bucket boundaries and
dramatically reduce cardinality compared to classic histograms.

**Enable native histograms:**

```yaml
# prometheus --enable-feature=native-histograms
global:
  scrape_protocols:
    - PrometheusProto
    - OpenMetricsText1.0.0
    - PrometheusText1.0.0
    - PrometheusText0.0.4
```

| Aspect | Classic | Native |
|---|---|---|
| Buckets | User-defined, fixed | Automatic, exponential |
| Series per metric | `n_buckets + 2` | 1 |
| Accuracy | Depends on bucket placement | Bounded relative error |
| Resolution | Fixed at instrumentation | Adapts to observed data |

**Instrumentation (Go):**

```go
prometheus.NewHistogram(prometheus.HistogramOpts{
    Name:                           "http_request_duration_seconds",
    NativeHistogramBucketFactor:    1.1,  // ~10% bucket width
    NativeHistogramMaxBucketNumber: 160,
    Buckets:                        prometheus.DefBuckets, // Dual-publish for migration
})
```

**PromQL for native histograms:**

```promql
histogram_quantile(0.99, sum(rate(http_request_duration_seconds[5m])))
histogram_count(rate(http_request_duration_seconds[5m]))
histogram_sum(rate(http_request_duration_seconds[5m]))
histogram_fraction(0, 0.2, rate(http_request_duration_seconds[5m]))
```

**Migration:** Enable `NativeHistogramBucketFactor` while keeping `Buckets`
for dual-publish. Validate native quantiles match classic, then drop `Buckets`.

---

## Recording Rule Optimization Strategies

**Organize by evaluation interval and purpose:**

```yaml
groups:
  - name: slo-recording-rules
    interval: 30s
    rules:
      - record: slo:http_request_errors:ratio_rate5m
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[5m]))
          /
          sum by (service) (rate(http_requests_total[5m]))
      - record: slo:http_request_errors:ratio_rate1h
        expr: |
          sum by (service) (rate(http_requests_total{status=~"5.."}[1h]))
          /
          sum by (service) (rate(http_requests_total[1h]))

  - name: capacity-recording-rules
    interval: 60s
    rules:
      - record: cluster:node_cpu:ratio_avg
        expr: 1 - avg by (cluster) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
      - record: cluster:memory:utilization_ratio
        expr: |
          1 - sum by (cluster) (node_memory_MemAvailable_bytes)
          / sum by (cluster) (node_memory_MemTotal_bytes)
```

**Chaining rules into aggregation hierarchies:**

```yaml
groups:
  - name: aggregation-chain
    rules:
      - record: instance:http_requests:rate5m
        expr: sum by (instance, job) (rate(http_requests_total[5m]))
      - record: job:http_requests:rate5m
        expr: sum by (job) (instance:http_requests:rate5m)
      - record: global:http_requests:rate5m
        expr: sum(job:http_requests:rate5m)
```

**Naming convention:** `level:metric_name:operations` — e.g.,
`job:http_requests:rate5m`, `cluster:node_cpu:ratio_avg`.

**Monitor rule evaluation performance:**

```promql
# Rule groups that can't keep up (ratio > 1.0 means falling behind)
topk(10,
  prometheus_rule_group_last_duration_seconds
  / prometheus_rule_group_interval_seconds
)

# Failed evaluations
rate(prometheus_rule_evaluation_failures_total[5m]) > 0
```

**When to create recording rules:** queries touching > 1000 series; queries
used in alerts; cross-metric joins evaluated repeatedly; federation exports.

---

## High-Availability Prometheus Pairs

Run two identical Prometheus instances scraping the same targets to ensure
availability during upgrades, crashes, or network partitions.

**Pair configuration — identical config, unique replica labels:**

```yaml
# prometheus-a.yml
global:
  scrape_interval: 15s
  external_labels:
    cluster: production
    replica: prometheus-a

# prometheus-b.yml — same scrape_configs, different replica label
global:
  scrape_interval: 15s
  external_labels:
    cluster: production
    replica: prometheus-b
```

**Kubernetes StatefulSet deployment:**

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus
spec:
  replicas: 2
  serviceName: prometheus
  template:
    spec:
      containers:
        - name: prometheus
          image: prom/prometheus:v2.51.0
          args:
            - '--config.file=/etc/prometheus/prometheus.yml'
            - '--storage.tsdb.retention.time=15d'
  volumeClaimTemplates:
    - metadata:
        name: storage
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 100Gi
```

**Deduplication at the query layer:**

```yaml
# Thanos Querier dedup
thanos query \
  --store=prometheus-a-sidecar:10901 \
  --store=prometheus-b-sidecar:10901 \
  --query.replica-label=replica

# Mimir HA tracker dedup
limits:
  ha_replica_label: replica
  ha_cluster_label: cluster
  accept_ha_samples: true
```

**Alertmanager handles duplicate alerts natively** — both replicas send to the
same Alertmanager cluster, which deduplicates via alert grouping and gossip.

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager-0:9093', 'alertmanager-1:9093']
```

**HA pair health monitoring:**

```promql
# Verify both replicas are up
count by (replica) (up)

# Alert if a replica is missing
absent(up{job="prometheus", replica="prometheus-a"})
or
absent(up{job="prometheus", replica="prometheus-b"})
```
