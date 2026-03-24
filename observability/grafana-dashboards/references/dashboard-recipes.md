# Grafana Dashboard Recipes

Ready-to-use panel JSON snippets for common monitoring scenarios. Copy-paste into
dashboards or import via the JSON model editor.

> **Convention**: All Prometheus panels use `${DS_PROMETHEUS}` as datasource UID.
> Define as a dashboard variable of type *Datasource* (Prometheus) for portability.

---

## Table of Contents

1. [Kubernetes Cluster Overview](#1-kubernetes-cluster-overview)
2. [Application RED Metrics](#2-application-red-metrics-rateerrorsduration)
3. [Infrastructure USE Method](#3-infrastructure-use-method-utilizationsaturationerrors)
4. [SLO Dashboard with Error Budget Burn Rate](#4-slo-dashboard-with-error-budget-burn-rate)
5. [PostgreSQL / MySQL Performance](#5-postgresql--mysql-performance)
6. [NGINX / HAProxy Traffic](#6-nginx--haproxy-traffic)
7. [Docker Host Monitoring](#7-docker-host-monitoring)
8. [CI/CD Pipeline Metrics](#8-cicd-pipeline-metrics)
9. [Business KPI Dashboard](#9-business-kpi-dashboard)

---

## 1. Kubernetes Cluster Overview

Monitor K8s cluster health and resource consumption. Relies on **kube-state-metrics** and **cAdvisor**.

**Variables**: `DS_PROMETHEUS` (Datasource: Prometheus) · `cluster` (Query: `label_values(kube_node_info, cluster)`) · `namespace` (Query: `label_values(kube_pod_info{cluster="$cluster"}, namespace)`)

### Cluster Node Count

```json
{
  "type": "stat",
  "title": "Cluster Node Count",
  "gridPos": { "h": 4, "w": 4, "x": 0, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "count(kube_node_info{cluster=\"$cluster\"})",
    "legendFormat": "Nodes", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "thresholds": {
        "mode": "absolute",
        "steps": [{ "color": "red", "value": null }, { "color": "green", "value": 1 }]
      },
      "color": { "mode": "thresholds" }
    }
  },
  "options": { "colorMode": "background", "graphMode": "none", "textMode": "value" }
}
```

### Container CPU Usage by Namespace

```json
{
  "type": "timeseries",
  "title": "Container CPU Usage by Namespace",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "sum by (namespace) (rate(container_cpu_usage_seconds_total{cluster=\"$cluster\", image!=\"\", container!=\"POD\"}[5m]))",
    "legendFormat": "{{ namespace }}", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "fillOpacity": 20, "stacking": { "mode": "normal" } },
      "unit": "short"
    }
  }
}
```

### Pod Restart Count (Top 10)

```json
{
  "type": "timeseries",
  "title": "Pod Restart Count (Top 10)",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "topk(10, sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total{cluster=\"$cluster\", namespace=~\"$namespace\"}[1h])))",
    "legendFormat": "{{ namespace }}/{{ pod }}", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "bars", "fillOpacity": 80, "stacking": { "mode": "normal" } },
      "color": { "mode": "palette-classic" }, "unit": "short"
    }
  }
}
```

Additional panels: add Pod Status piechart (by `kube_pod_status_phase`), Container Memory timeseries (unit: bytes), and Node Resource Allocation table.

---

## 2. Application RED Metrics (Rate/Errors/Duration)

**R**ate, **E**rrors, and **D**uration for request-driven services using `http_requests_total` and `http_request_duration_seconds`.

**Variables**: `DS_PROMETHEUS` (Datasource: Prometheus) · `job` (Query: `label_values(http_requests_total, job)`) · `handler` (Query: `label_values(http_requests_total{job="$job"}, handler)`)

### Request Rate per Endpoint

```json
{
  "type": "timeseries",
  "title": "Request Rate per Endpoint",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "sum by (handler) (rate(http_requests_total{job=\"$job\", handler=~\"$handler\"}[5m]))",
    "legendFormat": "{{ handler }}", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "lineWidth": 2, "fillOpacity": 10 },
      "unit": "reqps"
    }
  }
}
```

### Error Rate by Status Code

```json
{
  "type": "timeseries",
  "title": "Error Rate by Status Code",
  "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [
    {
      "expr": "sum by (code) (rate(http_requests_total{job=\"$job\", code=~\"4..|5..\"}[5m]))",
      "legendFormat": "HTTP {{ code }}", "refId": "A"
    },
    {
      "expr": "sum(rate(http_requests_total{job=\"$job\", code=~\"5..\"}[5m])) / sum(rate(http_requests_total{job=\"$job\"}[5m])) * 100",
      "legendFormat": "Error %", "refId": "B"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "fillOpacity": 15, "stacking": { "mode": "none" } },
      "unit": "reqps"
    },
    "overrides": [{
      "matcher": { "id": "byName", "options": "Error %" },
      "properties": [
        { "id": "custom.axisPlacement", "value": "right" },
        { "id": "unit", "value": "percent" },
        { "id": "custom.lineStyle", "value": { "fill": "dash", "dash": [10, 10] } }
      ]
    }]
  }
}
```

### Latency Percentiles (p50 / p95 / p99)

```json
{
  "type": "timeseries",
  "title": "Latency Percentiles (p50 / p95 / p99)",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [
    {
      "expr": "histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{job=\"$job\", handler=~\"$handler\"}[5m])))",
      "legendFormat": "p50", "refId": "A"
    },
    {
      "expr": "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{job=\"$job\", handler=~\"$handler\"}[5m])))",
      "legendFormat": "p95", "refId": "B"
    },
    {
      "expr": "histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{job=\"$job\", handler=~\"$handler\"}[5m])))",
      "legendFormat": "p99", "refId": "C"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "lineWidth": 2, "fillOpacity": 0 },
      "unit": "s", "color": { "mode": "palette-classic" }
    }
  }
}
```

Additional panels: add a Request Duration Heatmap (type: heatmap, format: heatmap, color scheme: Oranges).

---

## 3. Infrastructure USE Method (Utilization/Saturation/Errors)

Brendan Gregg's USE method for Linux hosts via **node_exporter**: **U**tilization, **S**aturation, **E**rrors per resource.

**Variables**: `DS_PROMETHEUS` (Datasource: Prometheus) · `instance` (Query: `label_values(node_uname_info, instance)`)

### CPU Utilization Gauge

```json
{
  "type": "gauge",
  "title": "CPU Utilization",
  "gridPos": { "h": 6, "w": 6, "x": 0, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "(1 - avg(rate(node_cpu_seconds_total{instance=\"$instance\", mode=\"idle\"}[5m]))) * 100",
    "legendFormat": "CPU %", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "percent", "min": 0, "max": 100,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null }, { "color": "yellow", "value": 60 },
          { "color": "orange", "value": 80 }, { "color": "red", "value": 90 }
        ]
      }
    }
  }
}
```

### Memory Utilization & Swap Saturation

```json
{
  "type": "timeseries",
  "title": "Memory Utilization & Swap Saturation",
  "gridPos": { "h": 8, "w": 12, "x": 6, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [
    {
      "expr": "(1 - (node_memory_MemAvailable_bytes{instance=\"$instance\"} / node_memory_MemTotal_bytes{instance=\"$instance\"})) * 100",
      "legendFormat": "Memory Used %", "refId": "A"
    },
    {
      "expr": "(node_memory_SwapTotal_bytes{instance=\"$instance\"} - node_memory_SwapFree_bytes{instance=\"$instance\"}) / node_memory_SwapTotal_bytes{instance=\"$instance\"} * 100",
      "legendFormat": "Swap Used % (saturation)", "refId": "B"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "fillOpacity": 10 },
      "unit": "percent", "min": 0, "max": 100
    },
    "overrides": [{
      "matcher": { "id": "byName", "options": "Swap Used % (saturation)" },
      "properties": [
        { "id": "custom.lineStyle", "value": { "fill": "dash", "dash": [10, 10] } },
        { "id": "color", "value": { "fixedColor": "orange", "mode": "fixed" } }
      ]
    }]
  }
}
```

### Disk I/O Utilization & Saturation

```json
{
  "type": "timeseries",
  "title": "Disk I/O Utilization & Saturation",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [
    {
      "expr": "rate(node_disk_io_time_seconds_total{instance=\"$instance\", device!~\"dm-.*\"}[5m]) * 100",
      "legendFormat": "{{ device }} utilization %", "refId": "A"
    },
    {
      "expr": "rate(node_disk_io_time_weighted_seconds_total{instance=\"$instance\", device!~\"dm-.*\"}[5m])",
      "legendFormat": "{{ device }} saturation (avg queue)", "refId": "B"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "fillOpacity": 10 },
      "unit": "percent"
    },
    "overrides": [{
      "matcher": { "id": "byRegexp", "options": ".*saturation.*" },
      "properties": [
        { "id": "custom.axisPlacement", "value": "right" },
        { "id": "unit", "value": "short" }
      ]
    }]
  }
}
```

Additional panels: add Network Utilization & Errors timeseries (`node_network_receive_bytes_total`, `node_network_transmit_bytes_total`, `node_network_*_errs_total` — use right axis + red color for errors).

---

## 4. SLO Dashboard with Error Budget Burn Rate

Multi-window, multi-burn-rate SLO tracking per the Google SRE workbook. Requires recording rules that pre-compute error ratios.

### Recording Rules (prerequisite)

```yaml
groups:
  - name: slo_error_ratio
    rules:
      - record: slo:error_ratio:rate5m
        expr: >-
          sum(rate(http_requests_total{job="api-server", code=~"5.."}[5m]))
          / sum(rate(http_requests_total{job="api-server"}[5m]))
      - record: slo:error_ratio:rate1h
        expr: # same pattern with [1h] window
      - record: slo:error_ratio:rate6h
        expr: # same pattern with [6h] window
      - record: slo:error_ratio:rate1d
        expr: # same pattern with [1d] window
      - record: slo:error_ratio:rate30d
        expr: # same pattern with [30d] window
```

**Variables**: `DS_PROMETHEUS` (Datasource: Prometheus) · `slo_target` (Constant: `0.9995` i.e. 99.95%)

### SLI — Availability (30d)

```json
{
  "type": "stat",
  "title": "SLI — Availability (30d)",
  "gridPos": { "h": 4, "w": 4, "x": 0, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "(1 - slo:error_ratio:rate30d) * 100",
    "legendFormat": "Availability", "refId": "A", "instant": true
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "percent", "decimals": 3,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "red", "value": null },
          { "color": "orange", "value": 99.5 },
          { "color": "green", "value": 99.95 }
        ]
      }
    }
  },
  "options": { "colorMode": "background", "textMode": "value" }
}
```

### Error Budget Remaining

```json
{
  "type": "gauge",
  "title": "Error Budget Remaining",
  "gridPos": { "h": 6, "w": 6, "x": 4, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "clamp_min((1 - slo:error_ratio:rate30d / (1 - $slo_target)) * 100, 0)",
    "legendFormat": "Budget Remaining %", "refId": "A", "instant": true
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "percent", "min": 0, "max": 100,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "red", "value": null }, { "color": "orange", "value": 25 },
          { "color": "yellow", "value": 50 }, { "color": "green", "value": 75 }
        ]
      }
    }
  }
}
```

### Error Budget Burn Rate (multi-window)

```json
{
  "type": "timeseries",
  "title": "Error Budget Burn Rate (multi-window)",
  "gridPos": { "h": 8, "w": 14, "x": 10, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [
    { "expr": "slo:error_ratio:rate1h / (1 - $slo_target)", "legendFormat": "1h burn rate", "refId": "A" },
    { "expr": "slo:error_ratio:rate6h / (1 - $slo_target)", "legendFormat": "6h burn rate", "refId": "B" },
    { "expr": "slo:error_ratio:rate1d / (1 - $slo_target)", "legendFormat": "1d burn rate", "refId": "C" }
  ],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "lineWidth": 2, "fillOpacity": 0 },
      "unit": "short",
      "thresholds": {
        "mode": "absolute",
        "steps": [{ "color": "green", "value": null }, { "color": "red", "value": 1 }]
      },
      "custom.thresholdsStyle": { "mode": "line" }
    }
  }
}
```

Additional panels: add a Burn Rate Alert Status table with multi-window thresholds (14.4× for 1h/5m page, 6× for 6h/30m page, 1× for 1d/6h ticket). Fires when both fast and slow windows exceed the threshold simultaneously.

---

## 5. PostgreSQL / MySQL Performance

Database health covering connections, throughput, cache, and replication. Uses `pg_*` metrics from **postgres_exporter**. For MySQL, swap metrics as noted — `mysql_global_status_threads_connected` for connections, `rate(mysql_global_status_queries[5m])` for QPS, `mysql_global_status_innodb_buffer_pool_read_requests` for cache hits.

**Variables**: `DS_PROMETHEUS` (Datasource: Prometheus) · `db_instance` (Query: `label_values(pg_up, instance)` — or `mysql_up` for MySQL)

### Active Connections (PostgreSQL)

```json
{
  "type": "timeseries",
  "title": "Active Connections",
  "gridPos": { "h": 8, "w": 8, "x": 0, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "pg_stat_activity_count{instance=\"$db_instance\", state=\"active\"}",
    "legendFormat": "PG active ({{ datname }})", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "fillOpacity": 10 },
      "unit": "short"
    }
  }
}
```

> **MySQL variant**: use `mysql_global_status_threads_connected{instance="$db_instance"}`.

### Cache Hit Ratio

```json
{
  "type": "gauge",
  "title": "Cache Hit Ratio",
  "gridPos": { "h": 6, "w": 6, "x": 0, "y": 8 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "sum(pg_stat_database_blks_hit{instance=\"$db_instance\"}) / (sum(pg_stat_database_blks_hit{instance=\"$db_instance\"}) + sum(pg_stat_database_blks_read{instance=\"$db_instance\"})) * 100",
    "legendFormat": "PG cache hit %", "refId": "A", "instant": true
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "percent", "min": 0, "max": 100,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "red", "value": null },
          { "color": "yellow", "value": 90 },
          { "color": "green", "value": 99 }
        ]
      }
    }
  }
}
```

> **MySQL variant**: use `mysql_global_status_innodb_buffer_pool_read_requests / (…read_requests + …pool_reads) * 100`.

### Replication Lag

```json
{
  "type": "timeseries",
  "title": "Replication Lag",
  "gridPos": { "h": 6, "w": 6, "x": 6, "y": 8 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "pg_replication_lag{instance=\"$db_instance\"}",
    "legendFormat": "PG replication lag", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "fillOpacity": 10 },
      "unit": "s",
      "thresholds": {
        "mode": "absolute",
        "steps": [{ "color": "green", "value": null }, { "color": "red", "value": 30 }]
      },
      "custom.thresholdsStyle": { "mode": "line+area" }
    }
  }
}
```

> **MySQL variant**: use `mysql_slave_status_seconds_behind_master{instance="$db_instance"}`.

Additional panels: add Query Throughput QPS (`pg_stat_database_xact_commit` + `xact_rollback`), Slow Queries stat, and Top 10 Tables by Size bargauge.

---

## 6. NGINX / HAProxy Traffic

Monitor reverse proxy / load balancer layers. Uses **nginx-prometheus-exporter** metrics. For HAProxy, swap metrics as noted.

**Variables**: `DS_PROMETHEUS` (Datasource: Prometheus) · `proxy_instance` (Query: `label_values(nginx_http_requests_total, instance)`) · `backend` (Query: `label_values(haproxy_backend_http_responses_total, proxy)` — HAProxy only)

### Requests per Second (NGINX)

```json
{
  "type": "timeseries",
  "title": "Requests per Second",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "sum(rate(nginx_http_requests_total{instance=\"$proxy_instance\"}[5m]))",
    "legendFormat": "NGINX req/s", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "lineWidth": 2, "fillOpacity": 15 },
      "unit": "reqps"
    }
  }
}
```

> **HAProxy variant**: use `sum by (proxy) (rate(haproxy_frontend_http_requests_total{proxy!="stats"}[5m]))`.

### HTTP Status Code Distribution

```json
{
  "type": "timeseries",
  "title": "HTTP Status Code Distribution",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "sum by (status) (rate(nginx_http_requests_total{instance=\"$proxy_instance\"}[5m]))",
    "legendFormat": "NGINX {{ status }}", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "fillOpacity": 20, "stacking": { "mode": "normal" } },
      "unit": "reqps"
    },
    "overrides": [
      { "matcher": { "id": "byRegexp", "options": ".*2xx.*" }, "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }] },
      { "matcher": { "id": "byRegexp", "options": ".*4xx.*" }, "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }] },
      { "matcher": { "id": "byRegexp", "options": ".*5xx.*" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }
    ]
  }
}
```

> **HAProxy variant**: use `sum by (code) (rate(haproxy_frontend_http_responses_total{proxy!="stats"}[5m]))`.

Additional panels: add Upstream Response Time (p95 histogram quantile / `haproxy_backend_response_time_average_seconds`), Active Connections (`nginx_connections_active` / `haproxy_frontend_current_sessions`), and Bandwidth In/Out.

---

## 7. Docker Host Monitoring

Per-container resource usage via **cAdvisor** metrics. For Docker Compose or standalone Docker hosts.

**Variables**: `DS_PROMETHEUS` (Datasource: Prometheus) · `host` (Query: `label_values(machine_cpu_cores, instance)`) · `container_name` (Query: `label_values(container_last_seen{instance="$host", name!=""}, name)`)

### Container CPU Usage

```json
{
  "type": "timeseries",
  "title": "Container CPU Usage",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "rate(container_cpu_usage_seconds_total{instance=\"$host\", name=~\"$container_name\", image!=\"\"}[5m]) * 100",
    "legendFormat": "{{ name }}", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "fillOpacity": 15, "stacking": { "mode": "none" } },
      "unit": "percent"
    }
  }
}
```

### Container Memory Usage

```json
{
  "type": "timeseries",
  "title": "Container Memory Usage",
  "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "container_memory_usage_bytes{instance=\"$host\", name=~\"$container_name\", image!=\"\"}",
    "legendFormat": "{{ name }}", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "fillOpacity": 15, "stacking": { "mode": "none" } },
      "unit": "bytes"
    }
  }
}
```

Additional panels: add Container Count stat, Network I/O (rx/tx with negative-Y for tx), Disk Usage bargauge, and Docker Image Count stat.

---

## 8. CI/CD Pipeline Metrics

DORA metrics — deployment frequency, lead time, change failure rate, MTTR. Uses custom Prometheus counters pushed by CI webhooks or a metrics bridge.

**Variables**: `DS_PROMETHEUS` (Datasource: Prometheus) · `team` (Query: `label_values(cicd_deployments_total, team)`) · `environment` (Custom: `production,staging,development`)

### Deployment Frequency

```json
{
  "type": "timeseries",
  "title": "Deployment Frequency",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "sum(increase(cicd_deployments_total{team=\"$team\", environment=\"$environment\"}[1d]))",
    "legendFormat": "Deployments / day", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "bars", "fillOpacity": 60, "lineWidth": 0 },
      "unit": "short", "color": { "fixedColor": "blue", "mode": "fixed" }
    }
  }
}
```

### Change Failure Rate (30d)

```json
{
  "type": "stat",
  "title": "Change Failure Rate (30d)",
  "gridPos": { "h": 6, "w": 6, "x": 0, "y": 8 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [{
    "expr": "sum(increase(cicd_deployments_total{team=\"$team\", environment=\"$environment\", status=\"failure\"}[30d])) / sum(increase(cicd_deployments_total{team=\"$team\", environment=\"$environment\"}[30d])) * 100",
    "legendFormat": "Failure Rate %", "refId": "A", "instant": true
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "percent", "decimals": 1,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 15 },
          { "color": "red", "value": 30 }
        ]
      }
    }
  },
  "options": { "colorMode": "background", "textMode": "value" }
}
```

### Mean Time to Recovery (MTTR)

```json
{
  "type": "timeseries",
  "title": "Mean Time to Recovery (MTTR)",
  "gridPos": { "h": 8, "w": 18, "x": 6, "y": 8 },
  "datasource": { "uid": "${DS_PROMETHEUS}", "type": "prometheus" },
  "targets": [
    {
      "expr": "avg(increase(cicd_recovery_time_seconds_sum{team=\"$team\", environment=\"$environment\"}[7d]) / increase(cicd_recovery_time_seconds_count{team=\"$team\", environment=\"$environment\"}[7d]))",
      "legendFormat": "MTTR (7d rolling avg)", "refId": "A"
    },
    {
      "expr": "histogram_quantile(0.95, sum by (le) (rate(cicd_recovery_time_seconds_bucket{team=\"$team\", environment=\"$environment\"}[7d])))",
      "legendFormat": "MTTR p95", "refId": "B"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "line", "lineWidth": 2, "fillOpacity": 10 },
      "unit": "s",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 3600 },
          { "color": "red", "value": 86400 }
        ]
      },
      "custom.thresholdsStyle": { "mode": "line" }
    }
  }
}
```

Additional panels: add Lead Time for Changes (p50/p95 histogram quantile over `cicd_lead_time_seconds_bucket`).

---

## 9. Business KPI Dashboard

High-level business metrics for product managers and executives. Queries a **SQL datasource** (PostgreSQL/MySQL/ClickHouse) rather than Prometheus.

**Variables**: `DS_POSTGRES` (Datasource: PostgreSQL) · `date_from` (Interval: `now-30d`) · `customer_tier` (Custom: `free,starter,pro,enterprise`)

### Revenue (30d)

```json
{
  "type": "stat",
  "title": "Revenue (30d)",
  "gridPos": { "h": 4, "w": 4, "x": 0, "y": 0 },
  "datasource": { "uid": "${DS_POSTGRES}", "type": "postgres" },
  "targets": [{
    "rawSql": "SELECT SUM(amount_cents) / 100.0 AS revenue FROM orders WHERE created_at >= NOW() - INTERVAL '30 days' AND status = 'completed'",
    "format": "table", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "currencyUSD",
      "thresholds": {
        "mode": "absolute",
        "steps": [{ "color": "red", "value": null }, { "color": "green", "value": 1 }]
      }
    }
  },
  "options": { "colorMode": "value", "graphMode": "none", "textMode": "value" }
}
```

### User Signups Over Time

```json
{
  "type": "timeseries",
  "title": "User Signups Over Time",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
  "datasource": { "uid": "${DS_POSTGRES}", "type": "postgres" },
  "targets": [{
    "rawSql": "SELECT date_trunc('day', created_at) AS time, COUNT(*) AS signups FROM users WHERE created_at >= $__timeFrom() AND created_at < $__timeTo() GROUP BY 1 ORDER BY 1",
    "format": "time_series", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": {
      "custom": { "drawStyle": "bars", "fillOpacity": 60, "lineWidth": 0 },
      "unit": "short", "color": { "fixedColor": "purple", "mode": "fixed" }
    }
  }
}
```

### Conversion Funnel (30d)

```json
{
  "type": "bargauge",
  "title": "Conversion Funnel (30d)",
  "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
  "datasource": { "uid": "${DS_POSTGRES}", "type": "postgres" },
  "targets": [{
    "rawSql": "SELECT 'Visitors' AS stage, COUNT(DISTINCT session_id)::float AS value FROM page_views WHERE created_at >= NOW() - INTERVAL '30 days' UNION ALL SELECT 'Signups', COUNT(*)::float FROM users WHERE created_at >= NOW() - INTERVAL '30 days' UNION ALL SELECT 'Activated', COUNT(*)::float FROM users WHERE created_at >= NOW() - INTERVAL '30 days' AND activated_at IS NOT NULL UNION ALL SELECT 'Paying', COUNT(*)::float FROM subscriptions WHERE created_at >= NOW() - INTERVAL '30 days' AND status = 'active' ORDER BY value DESC",
    "format": "table", "refId": "A"
  }],
  "fieldConfig": {
    "defaults": { "unit": "short", "color": { "mode": "continuous-GrYlRd" } }
  },
  "options": { "orientation": "horizontal", "displayMode": "gradient" }
}
```

Additional panels: add Orders stat (30d count), and API Usage by Customer Tier timeseries (join `api_logs` with `customers` table, stacked by tier).
