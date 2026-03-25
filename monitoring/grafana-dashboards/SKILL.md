---
name: grafana-dashboards
description: >
  Create, configure, and provision Grafana dashboards and visualizations. Use when: building Grafana dashboards, configuring panels (time series, stat, gauge, table, heatmap, logs, geomap, bar chart), writing PromQL/LogQL queries for Grafana panels, setting up Grafana variables and templating, configuring Grafana annotations, creating Grafana alert rules with contact points and notification policies, provisioning dashboards via YAML/JSON, using Grafonnet jsonnet library or Terraform grafana provider for dashboard-as-code, organizing Grafana folders and permissions. Do NOT use when: configuring Prometheus server without Grafana involvement, building Datadog or New Relic dashboards, creating Kibana/OpenSearch visualizations, general metrics collection or instrumentation without dashboard context, configuring standalone alertmanager without Grafana unified alerting.
---

# Grafana Dashboards & Visualization

## Dashboard JSON Structure

Every Grafana dashboard is a JSON document. Set `id: null` for new dashboards; Grafana assigns it.

```json
{
  "id": null,
  "uid": "svc-overview-01",
  "title": "Service Overview",
  "tags": ["production", "backend"],
  "timezone": "browser",
  "editable": true,
  "graphTooltip": 1,
  "schemaVersion": 39,
  "version": 0,
  "time": { "from": "now-6h", "to": "now" },
  "refresh": "30s",
  "panels": [],
  "templating": { "list": [] },
  "annotations": { "list": [] },
  "links": []
}
```

Key fields: `uid` (unique string, stable across exports), `schemaVersion` (39+ for Grafana 11.x), `graphTooltip` (0=default, 1=shared crosshair, 2=shared tooltip).

## Panel Types & Configuration

### Grid Positioning

Every panel requires `gridPos`: `{ "x": 0, "y": 0, "w": 12, "h": 8 }`. Dashboard width is 24 units.

### Time Series Panel

```json
{
  "type": "timeseries",
  "title": "Request Rate",
  "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
  "datasource": { "type": "prometheus", "uid": "prometheus-main" },
  "targets": [{
    "expr": "sum(rate(http_requests_total{job=\"$job\"}[5m])) by (status_code)",
    "legendFormat": "{{status_code}}"
  }],
  "fieldConfig": {
    "defaults": {
      "unit": "reqps",
      "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 }
    },
    "overrides": [{
      "matcher": { "id": "byName", "options": "500" },
      "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }]
    }]
  }
}
```

### Stat Panel

```json
{
  "type": "stat",
  "title": "Total Requests",
  "targets": [{ "expr": "sum(increase(http_requests_total{job=\"$job\"}[24h]))" }],
  "fieldConfig": {
    "defaults": {
      "unit": "short",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 10000 },
          { "color": "red", "value": 50000 }
        ]
      }
    }
  },
  "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background" }
}
```

### Gauge Panel

Set `options.showThresholdLabels: true` and `fieldConfig.defaults.min/max` for proper scaling. Use `unit` field for display (percent, bytes, etc.).

### Table Panel

```json
{
  "type": "table",
  "title": "Top Endpoints",
  "targets": [{
    "expr": "topk(10, sum(rate(http_requests_total[5m])) by (handler))",
    "format": "table", "instant": true
  }],
  "transformations": [
    { "id": "organize", "options": { "excludeByName": { "Time": true } } }
  ],
  "fieldConfig": {
    "overrides": [{
      "matcher": { "id": "byName", "options": "Value" },
      "properties": [{ "id": "custom.cellOptions", "value": { "type": "color-background" } }]
    }]
  }
}
```

### Logs Panel

```json
{
  "type": "logs",
  "title": "Application Logs",
  "datasource": { "type": "loki", "uid": "loki-main" },
  "targets": [{
    "expr": "{namespace=\"$namespace\", app=\"$app\"} |= \"$search\" | logfmt | level=~\"$level\"",
    "refId": "A"
  }],
  "options": { "showTime": true, "sortOrder": "Descending", "wrapLogMessage": true }
}
```

### Heatmap, Bar Chart, Geomap Panels

- **Heatmap**: `"type": "heatmap"`. Set `options.calculate: true` for raw data, `false` for pre-bucketed. Configure `options.yAxis.unit` and `color.scheme`.
- **Bar Chart**: `"type": "barchart"`. Set `options.orientation` ("horizontal"/"vertical"), `options.showValue`. Pair with instant queries and table format.
- **Geomap**: `"type": "geomap"`. Requires `latitude`/`longitude` fields or field mappings. Set `options.view.id` for map type.

## Queries

### PromQL Patterns for Dashboards

```
# Rate of counter
rate(http_requests_total{job="$job"}[$__rate_interval])

# Error ratio
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# Histogram quantile (p99 latency)
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job="$job"}[5m])) by (le))

# Aggregation with variable
sum by ($groupby) (rate(metric_name[$__rate_interval]))
```

Use `$__rate_interval` instead of hardcoded `[5m]` — it auto-adjusts to scrape interval. Use `$__interval` for non-rate aggregations.

### LogQL Patterns for Dashboards

```
# Filter and parse
{namespace="production", app="api"} |= "error" | json | line_format "{{.message}}"

# Metric query from logs (rate of errors)
sum(rate({app="api"} |= "error" [5m])) by (level)

# Pattern-based extraction
{job="nginx"} | pattern "<ip> - - <_> \"<method> <uri> <_>\" <status> <size>" | status >= 400
```

## Variables (Templating)

Define in `templating.list`. Variable types:

### Query Variable (dynamic from datasource)

```json
{
  "name": "namespace",
  "type": "query",
  "datasource": { "type": "prometheus", "uid": "prometheus-main" },
  "query": "label_values(kube_pod_info, namespace)",
  "refresh": 2,
  "sort": 1,
  "multi": true,
  "includeAll": true,
  "allValue": ".*"
}
```

`refresh`: 1=on dashboard load, 2=on time range change. `sort`: 0=disabled, 1=alpha asc, 2=alpha desc, 3=numeric asc.

### Chained Variables

Create dependency chains: namespace → service → pod.

```json
[
  { "name": "namespace", "query": "label_values(kube_pod_info, namespace)" },
  { "name": "service", "query": "label_values(kube_pod_info{namespace=\"$namespace\"}, service)" },
  { "name": "pod", "query": "label_values(kube_pod_info{namespace=\"$namespace\", service=\"$service\"}, pod)" }
]
```

### Custom Variable

```json
{ "name": "env", "type": "custom", "query": "production,staging,development", "current": { "text": "production", "value": "production" } }
```

### Interval Variable

```json
{ "name": "smoothing", "type": "interval", "query": "1m,5m,15m,30m,1h", "auto": true, "auto_count": 30, "auto_min": "10s" }
```

### Datasource Variable

```json
{ "name": "ds_prometheus", "type": "datasource", "query": "prometheus" }
```

Reference in panels: `"datasource": { "type": "prometheus", "uid": "$ds_prometheus" }`.

### Variable Syntax

Use `$var` for simple substitution, `${var}` mid-string, `${var:regex}` for regex-escaped, `${var:pipe}` for pipe-delimited multi-values, `${var:csv}` for comma-separated.

## Annotations

```json
{
  "annotations": {
    "list": [{
      "name": "Deployments",
      "datasource": { "type": "prometheus", "uid": "prometheus-main" },
      "expr": "changes(deploy_timestamp{app=\"$app\"}[1m]) > 0",
      "tagKeys": "app,version",
      "textFormat": "Deployed {{version}}",
      "iconColor": "blue",
      "enable": true
    }]
  }
}
```

## Dashboard Links

```json
{
  "links": [
    { "title": "Logs", "url": "/d/logs-dash/logs?var-app=$app", "type": "link", "icon": "doc", "targetBlank": false },
    { "title": "Related", "type": "dashboards", "tags": ["production"], "asDropdown": true }
  ]
}
```

## Provisioning

### Dashboard Provider (YAML)

Place in `provisioning/dashboards/`:

```yaml
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: Production
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
```

`foldersFromFilesStructure: true` mirrors subdirectory layout as Grafana folders.

### Datasource Provisioning

Place in `provisioning/datasources/`:

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus-main
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    jsonData:
      timeInterval: 15s
      httpMethod: POST
  - name: Loki
    type: loki
    uid: loki-main
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        - name: TraceID
          matcherRegex: "traceID=(\\w+)"
          url: "$${__value.raw}"
          datasourceUid: tempo-main
```

### Directory Layout

```
grafana/
  provisioning/
    dashboards/
      default.yaml
    datasources/
      datasources.yaml
    alerting/
      rules.yaml
      contact-points.yaml
      policies.yaml
  dashboards/
    infrastructure/
      node-exporter.json
      kubernetes.json
    application/
      api-overview.json
      database.json
```

## Alerting (Unified Alerting)

### Alert Rule Provisioning

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: platform-alerts
    folder: Alerts
    interval: 1m
    rules:
      - uid: high-error-rate
        title: High Error Rate
        condition: C
        data:
          - refId: A
            relativeTimeRange: { from: 300, to: 0 }
            datasourceUid: prometheus-main
            model:
              expr: sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))
              instant: true
          - refId: B
            relativeTimeRange: { from: 0, to: 0 }
            datasourceUid: __expr__
            model: { type: reduce, reducer: last, expression: A }
          - refId: C
            datasourceUid: __expr__
            model: { type: threshold, expression: B, conditions: [{ evaluator: { type: gt, params: [0.05] } }] }
        for: 5m
        labels:
          severity: critical
          team: backend
        annotations:
          summary: "Error rate above 5%"
          runbook_url: "https://wiki.example.com/runbooks/high-error-rate"
```

### Contact Points & Notification Policies

```yaml
# contact-points.yaml
apiVersion: 1
contactPoints:
  - orgId: 1
    name: platform-slack
    receivers:
      - uid: slack-receiver
        type: slack
        settings:
          url: https://hooks.slack.com/services/T00/B00/XXX
          recipient: "#alerts-platform"
---
# policies.yaml
apiVersion: 1
policies:
  - orgId: 1
    receiver: platform-slack
    group_by: [alertname, namespace]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - receiver: pagerduty-oncall
        matchers: [severity = critical]
      - receiver: email-team
        matchers: [team = database]
```

Route with `matchers` using label selectors. Set `continue: true` to evaluate sibling routes after match.

## Grafana as Code (Grafonnet)

### Grafonnet Jsonnet Library

Install with jsonnet-bundler:

```bash
jb init
jb install github.com/grafana/grafonnet/gen/grafonnet-latest@main
```

### Dashboard Example

```jsonnet
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';

g.dashboard.new('Service Overview')
+ g.dashboard.withUid('svc-overview')
+ g.dashboard.withTags(['production'])
+ g.dashboard.withTimezone('browser')
+ g.dashboard.withRefresh('30s')
+ g.dashboard.time.withFrom('now-6h')
+ g.dashboard.time.withTo('now')
+ g.dashboard.withVariables([
    g.dashboard.variable.query.new('namespace')
    + g.dashboard.variable.query.withDatasource('prometheus', 'prometheus-main')
    + g.dashboard.variable.query.queryTypes.withLabelValues('namespace', 'kube_pod_info'),
  ])
+ g.dashboard.withPanels(
  g.util.grid.makeGrid([
    g.panel.timeSeries.new('Request Rate')
    + g.panel.timeSeries.queryOptions.withDatasource('prometheus', 'prometheus-main')
    + g.panel.timeSeries.queryOptions.withTargets([
        g.query.prometheus.new('prometheus-main',
          'sum(rate(http_requests_total{namespace="$namespace"}[$__rate_interval])) by (status_code)')
        + g.query.prometheus.withLegendFormat('{{status_code}}'),
      ])
    + g.panel.timeSeries.standardOptions.withUnit('reqps'),
  ], panelWidth=12, panelHeight=8)
)
```

Build: `jsonnet -J vendor/ dashboard.jsonnet > dashboard.json`

### Terraform Integration

```hcl
terraform {
  required_providers {
    grafana  = { source = "grafana/grafana", version = "~> 3.0" }
    jsonnet  = { source = "alxrem/jsonnet", version = "~> 2.4" }
  }
}
provider "grafana" {
  url  = "https://grafana.example.com"
  auth = var.grafana_api_key
}
resource "grafana_folder" "production" { title = "Production" }
data "jsonnet_file" "dashboard" {
  source  = "${path.module}/dashboards/service.jsonnet"
  ext_str = { namespace = "production" }
}
resource "grafana_dashboard" "service" {
  folder      = grafana_folder.production.id
  config_json = data.jsonnet_file.dashboard.rendered
}
```

## Best Practices

### Dashboard Organization

- One dashboard per service/domain. Avoid mega-dashboards with 30+ panels.
- Use folders: `Infrastructure/`, `Application/`, `Business/`, `Alerts/`.
- Tag consistently: environment, team, service. Use dashboard links for drill-downs.

### Performance

- Limit to 15-20 panels per dashboard; each fires a separate query.
- Use `$__rate_interval` over hardcoded intervals. Set `instant: true` for stat/gauge/table.
- Use `min_step` or `intervalMs` to prevent excessive data points.
- Avoid unbounded regex like `{__name__=~".*"}`; always scope with at least one label.
- Set `refresh` to 30s for ops dashboards, 5m+ for business dashboards.

### Repeating Panels & Rows

Repeat a panel across variable values: set `"repeat": "instance"`, `"repeatDirection": "h"`, `"maxPerRow": 4`. For row repeats: set `"repeat": "namespace"` on a row panel (`"type": "row"`). Use `"collapsed": true` on rows for large dashboards.

### Export & Version Control

Export via Dashboard Settings → JSON Model. Remove `id`, `version` before committing to Git. Keep `uid` stable.

### Permissions

Use folder-level permissions for team access. Assign Viewer/Editor/Admin per folder. Use org roles for broad access, folder permissions for fine-grained control.
