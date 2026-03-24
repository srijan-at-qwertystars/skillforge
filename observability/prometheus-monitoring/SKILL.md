---
name: prometheus-monitoring
description: >
  Use when setting up Prometheus monitoring, writing PromQL queries, configuring alerting rules,
  instrumenting applications with Prometheus metrics, scrape configuration, recording rules,
  service discovery, relabeling, histogram_quantile calculations, or Alertmanager routing.
  Do NOT use for Datadog/New Relic/Splunk proprietary monitoring, log aggregation (use ELK/Loki),
  distributed tracing (use Jaeger/Tempo), or general Grafana dashboard design without Prometheus.
---

# Prometheus Monitoring

## Architecture

Prometheus uses a **pull-based scrape model** — the server periodically scrapes HTTP `/metrics` endpoints.

**Core components:** Prometheus Server (scrape, rule evaluation, TSDB storage), Alertmanager (dedup, group, route, silence alerts), Pushgateway (short-lived batch jobs only), Exporters (third-party metric translation), Client Libraries (application instrumentation).

**Federation** — higher-level Prometheus scrapes `/federate` from lower-level instances:
```yaml
- job_name: 'federate'
  honor_labels: true
  metrics_path: '/federate'
  params:
    'match[]': ['{job="app"}']
  static_configs:
    - targets: ['prometheus-dc1:9090', 'prometheus-dc2:9090']
```

## Configuration (prometheus.yml)

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
rule_files: ['rules/*.yml']
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']
scrape_configs:
  - job_name: 'app'
    metrics_path: '/metrics'
    scheme: 'https'
    tls_config:
      ca_file: '/etc/prom/ca.pem'
    static_configs:
      - targets: ['app1:8080', 'app2:8080']
        labels:
          env: 'production'
```

Key flags: `--storage.tsdb.retention.time=30d`, `--storage.tsdb.retention.size=50GB`, `--web.enable-lifecycle`.

## Metric Types

- **Counter** — monotonically increasing. Use for: request counts, errors, bytes. Example: `http_requests_total{method="GET"} 1027`
- **Gauge** — goes up and down. Use for: temperature, memory, queue depth. Example: `node_memory_MemAvailable_bytes 4.29e+09`
- **Histogram** — observations in configurable buckets (`_bucket{le="..."}`, `_sum`, `_count`). Use for: latency, response size. **Prefer over summary** — aggregatable across instances.
- **Summary** — client-side quantiles. Use only for exact per-instance quantiles that never need aggregation. **Cannot be aggregated.**

**Decision rule:** Default to histograms. Use summaries only for precise single-instance quantiles.

## PromQL Fundamentals

```promql
# Selectors
http_requests_total{job="api", status=~"5.."}      # instant vector
http_requests_total{job="api"}[5m]                   # range vector
http_requests_total{status!="200"}                   # negative match

# Operators
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes
method_a / on(instance) method_b
method_a / ignoring(status) group_left method_b

# Aggregation
sum(rate(http_requests_total[5m])) by (service)
topk(5, rate(http_requests_total[5m]))
count_values("version", build_info)

# Functions
rate(counter[5m])           # per-second rate, smoothed
increase(counter[1h])       # total increase over window
absent(up{job="api"})       # 1 if series missing
label_replace(metric, "dst", "$1", "src", "(.*)")
```

## PromQL Advanced

**rate vs irate:** `rate()` averages over the window (use for alerting). `irate()` uses last two points only (use for volatile dashboards). Always use `rate` in alert rules.

**histogram_quantile:** Always `rate()` buckets first. Always include `le` in `by` clause.
```promql
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))
```

**predict_linear:** `predict_linear(node_filesystem_avail_bytes[6h], 4*3600) < 0` — disk full in 4h.

**Subqueries:** `max_over_time(rate(http_requests_total[5m])[1h:1m])` — max rate over 1h, evaluated every 1m.

## Instrumentation

### Go
```go
var httpDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
    Name: "http_request_duration_seconds", Help: "Request duration.",
    Buckets: prometheus.DefBuckets,
}, []string{"method", "path", "status"})
func init() { prometheus.MustRegister(httpDuration) }
// http.Handle("/metrics", promhttp.Handler())
```

### Python
```python
from prometheus_client import Counter, Histogram, start_http_server
REQUEST_COUNT = Counter('http_requests_total', 'Total requests', ['method', 'endpoint'])
REQUEST_DURATION = Histogram('http_request_duration_seconds', 'Duration', ['method', 'endpoint'])
# start_http_server(8000) to expose /metrics
```

### Java
```java
static final Counter requests = Counter.build()
    .name("http_requests_total").help("Total requests")
    .labelNames("method", "endpoint").register();
static final Histogram duration = Histogram.build()
    .name("http_request_duration_seconds").help("Duration")
    .labelNames("method", "endpoint").register();
// Expose via MetricsServlet or Spring Boot Actuator /actuator/prometheus
```

### Node.js
```javascript
const client = require('prom-client');
const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds', help: 'Request duration',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 5]
});
// const end = httpDuration.startTimer({method, route}); end({status});
// res.end(await client.register.metrics());
```

## Service Discovery

```yaml
scrape_configs:
  - job_name: 'static'
    static_configs:
      - targets: ['host1:9090']
  - job_name: 'file'
    file_sd_configs:
      - files: ['/etc/prom/targets/*.json']
        refresh_interval: 30s
  - job_name: 'k8s-pods'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
  - job_name: 'consul'
    consul_sd_configs:
      - server: 'consul:8500'
        services: ['web', 'api']
  - job_name: 'ec2'
    ec2_sd_configs:
      - region: us-east-1
        port: 9100
        filters:
          - name: tag:Environment
            values: ['production']
  - job_name: 'dns'
    dns_sd_configs:
      - names: ['_prometheus._tcp.example.com']
        type: SRV
```

## Relabeling

Two phases: **`relabel_configs`** (before scrape — target selection/label rewriting) and **`metric_relabel_configs`** (after scrape — metric/label filtering).

| Action | Effect |
|---|---|
| `replace` | Set `target_label` from `source_labels` regex match |
| `keep`/`drop` | Keep/drop targets matching `regex` |
| `labelmap` | Copy matching labels to new names |
| `labeldrop`/`labelkeep` | Remove/keep labels matching `regex` |
| `hashmod` | Set `target_label` to hash mod (for sharding) |

```yaml
relabel_configs:
  - source_labels: [__meta_kubernetes_pod_label_app]
    target_label: app
  # Shard across 4 Prometheus instances
  - source_labels: [__address__]
    modulus: 4
    target_label: __tmp_hash
    action: hashmod
  - source_labels: [__tmp_hash]
    regex: ^0$
    action: keep
metric_relabel_configs:
  - source_labels: [__name__]
    regex: 'expensive_metric_.*'
    action: drop
  - regex: 'tmp_.*'
    action: labeldrop
```

## Recording Rules

Precompute expensive queries. Naming convention: `level:metric:operations`.

```yaml
groups:
  - name: http_rules
    interval: 30s
    rules:
      - record: job:http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (job)
      - record: job:http_request_duration_seconds:p99
        expr: histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))
      - record: instance:node_cpu:ratio
        expr: 1 - avg without(cpu) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
```

## Alerting Rules

```yaml
groups:
  - name: app_alerts
    rules:
      - alert: HighErrorRate
        expr: sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
            / sum(rate(http_requests_total[5m])) by (service) > 0.05
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: 'High error rate on {{ $labels.service }}'
          description: 'Error rate is {{ $value | humanizePercentage }}'
          runbook_url: 'https://wiki.example.com/runbooks/high-error-rate'
      - alert: DiskWillFillIn4Hours
        expr: predict_linear(node_filesystem_avail_bytes[6h], 4*3600) < 0
        for: 30m
        labels:
          severity: warning
      - alert: TargetDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
```

Use `for` to avoid transient spike alerts. Always include `runbook_url`.

## Alertmanager

```yaml
global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.example.com:587'
  smtp_from: 'alerts@example.com'
route:
  receiver: 'default'
  group_by: ['alertname', 'cluster', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - match: { severity: critical }
      receiver: 'pagerduty'
    - match: { severity: warning }
      receiver: 'slack-warnings'
receivers:
  - name: 'default'
    email_configs:
      - to: 'team@example.com'
  - name: 'pagerduty'
    pagerduty_configs:
      - routing_key: '<key>'
  - name: 'slack-warnings'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/...'
        channel: '#alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}'
inhibit_rules:
  - source_matchers: ['severity = critical']
    target_matchers: ['severity = warning']
    equal: ['alertname', 'cluster']
```

**Silences:** `amtool silence add alertname="NoisyAlert" --duration=2h --comment="deploy"`.  
**Grouping:** `group_by: ['...']` aggregates all alerts into one group.

## Storage and Retention

**Local TSDB:** Default 15-day retention. Uses 2-hour blocks compacted into larger blocks. Configure via `--storage.tsdb.retention.time` or `--storage.tsdb.retention.size`.

**Remote write/read** for long-term storage:
```yaml
remote_write:
  - url: 'http://thanos-receive:19291/api/v1/receive'
remote_read:
  - url: 'http://thanos-query:9090/api/v1/read'
    read_recent: false
```

**Long-term options:** Thanos (sidecar, object storage, global query, downsampling), Cortex/Mimir (multi-tenant, horizontally scalable), VictoriaMetrics (drop-in replacement, compression).

## Kubernetes Monitoring

**Components:** kube-state-metrics (cluster state), node-exporter (host metrics), cAdvisor (container metrics, built into kubelet). Deploy via `kube-prometheus-stack` Helm chart.

```promql
# Pod CPU/memory
sum(rate(container_cpu_usage_seconds_total{container!="POD",container!=""}[5m])) by (namespace, pod)
sum(container_memory_working_set_bytes{container!="POD",container!=""}) by (namespace, pod)
# Restarts and availability
increase(kube_pod_container_status_restarts_total[1h]) > 3
kube_deployment_status_replicas_available / kube_deployment_spec_replicas
```

## Common Patterns

**RED Method (request-oriented):** Rate `sum(rate(http_requests_total[5m])) by (service)`, Errors `sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)`, Duration `histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))`.

**USE Method (resource-oriented):** Utilization `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance)`, Saturation `node_load1 / count without(cpu) (node_cpu_seconds_total{mode="idle"})`, Errors `rate(node_disk_io_errors_total[5m])`.

**SLO/SLI:**
```promql
# Availability SLI
sum(rate(http_requests_total{status!~"5.."}[30d])) / sum(rate(http_requests_total[30d]))
# Error budget remaining (99.9% SLO)
1 - ((1 - sum(rate(http_requests_total{status!~"5.."}[30d])) / sum(rate(http_requests_total[30d]))) / (1 - 0.999))
# Burn rate
(sum(rate(http_requests_total{status=~"5.."}[1h])) / sum(rate(http_requests_total[1h]))) / (1 - 0.999)
```

## Exporters Ecosystem

| Exporter | Port | Purpose |
|---|---|---|
| node_exporter | 9100 | Host metrics (CPU, mem, disk, net) |
| blackbox_exporter | 9115 | Probe endpoints (HTTP, DNS, TCP, ICMP) |
| mysqld_exporter | 9104 | MySQL metrics |
| postgres_exporter | 9187 | PostgreSQL metrics |
| redis_exporter | 9121 | Redis metrics |

Blackbox prober pattern — use relabeling to pass target as parameter:
```yaml
- job_name: 'blackbox-http'
  metrics_path: /probe
  params: { module: [http_2xx] }
  static_configs:
    - targets: ['https://example.com']
  relabel_configs:
    - source_labels: [__address__]
      target_label: __param_target
    - source_labels: [__param_target]
      target_label: instance
    - target_label: __address__
      replacement: blackbox-exporter:9115
```

## Best Practices

**Naming:** `snake_case` with unit suffix (`http_request_duration_seconds`). Counters end in `_total`. Prefix with app domain (`myapp_orders_processed_total`).

**Cardinality:** Never use unbounded label values (user IDs, emails, URL paths with IDs). Monitor with `prometheus_tsdb_head_series`. Set `sample_limit` per scrape job. Pre-aggregate in recording rules.

**Labels:** Avoid frequently changing labels (pod UIDs). Use consistent names across services (`instance`, `job`, `env`, `service`). Only `le` for histogram buckets.

**Operations:** Monitor Prometheus itself (`prometheus_tsdb_head_series`, `prometheus_engine_query_duration_seconds`). Set `--query.max-samples` to prevent OOM. Run HA pairs — Alertmanager deduplicates via cluster gossip. Reload config via `POST /-/reload` with `--web.enable-lifecycle`.

## Reference Docs

Deep-dive guides in `references/`:

| Document | Topics |
|---|---|
| `advanced-patterns.md` | PromQL advanced queries (subqueries, multi-dimensional analysis), histogram best practices, federation patterns, remote write/read, Thanos vs Mimir vs Cortex, exemplars, native histograms, recording rule optimization, HA pairs |
| `troubleshooting.md` | High cardinality debugging, scrape failures, OOM/storage issues, slow queries, relabeling debugging, stale series, metric collisions, Alertmanager routing, push gateway pitfalls, WAL corruption, target discovery |
| `kubernetes-monitoring.md` | kube-prometheus-stack Helm, ServiceMonitor/PodMonitor CRDs, kube-state-metrics, node-exporter DaemonSet, cAdvisor, kubelet/API server/etcd metrics, custom metrics for HPA, cluster health alerts, Grafana provisioning |
| `alerting-patterns.md` | Multi-window burn-rate alerting, SLO-based alerts, alert routing strategies |
| `promql-cookbook.md` | PromQL recipes for common monitoring scenarios |

## Helper Scripts

Executable scripts in `scripts/`:

| Script | Purpose | Usage |
|---|---|---|
| `setup-prometheus.sh` | Deploy Prometheus + Grafana + Alertmanager stack via Docker Compose or local binary | `./setup-prometheus.sh docker` |
| `check-cardinality.sh` | Analyze TSDB for high-cardinality metrics, report top series/labels/memory | `./check-cardinality.sh [prom_url]` |
| `generate-alerts.sh` | Generate alerting rules from templates (SLO, infra, app, k8s, self-monitoring) | `./generate-alerts.sh all -o ./rules/` |
| `validate-rules.sh` | Validate Prometheus rule files with promtool | `./validate-rules.sh rules/` |

## Asset Templates

Production-ready configs in `assets/`:

| Asset | Description |
|---|---|
| `prometheus.yml` | Full config with Kubernetes SD, relabeling, remote write/read, TLS, blackbox probing |
| `docker-compose.yml` | Complete stack: Prometheus, Grafana, Alertmanager, node-exporter, cAdvisor |
| `alerting-rules.yml` | SLO burn-rate, infrastructure, disk, target health, Prometheus self-monitoring alerts |
| `recording-rules.yml` | Precomputed CPU, memory, disk, network, HTTP, and SLO burn-rate metrics |
| `alertmanager.yml` | Alertmanager with PagerDuty, Slack, email routing and inhibition rules |
