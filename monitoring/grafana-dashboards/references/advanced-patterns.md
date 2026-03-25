# Grafana Advanced Dashboard Patterns

> Dense reference for complex dashboard configurations, query patterns, and organizational strategies.

## Table of Contents

- [Complex PromQL Panel Queries](#complex-promql-panel-queries)
- [Multi-Datasource Dashboards](#multi-datasource-dashboards)
- [Variable Chaining](#variable-chaining)
- [Row Repeating](#row-repeating)
- [Dynamic Thresholds](#dynamic-thresholds)
- [Value Mappings](#value-mappings)
- [Field Overrides](#field-overrides)
- [Link Patterns](#link-patterns)
- [Embedded Panels](#embedded-panels)
- [Grafana Scenes](#grafana-scenes)
- [Dashboard Versioning](#dashboard-versioning)
- [Organization Strategies](#organization-strategies)
- [Transformations](#transformations)

---

## Complex PromQL Panel Queries

### Multi-Window Rate Comparison

Compare current vs previous period error rates:

```promql
# Current 5m error rate
sum(rate(http_requests_total{status=~"5..", job="$job"}[$__rate_interval])) by (handler)
/
sum(rate(http_requests_total{job="$job"}[$__rate_interval])) by (handler)
```

```promql
# Same metric offset 1h for comparison (query B, same panel)
sum(rate(http_requests_total{status=~"5..", job="$job"}[$__rate_interval] offset 1h)) by (handler)
/
sum(rate(http_requests_total{job="$job"}[$__rate_interval] offset 1h)) by (handler)
```

### Histogram Heatmap with Custom Buckets

```promql
# Native histogram for heatmap panel (format: heatmap)
sum(rate(http_request_duration_seconds_bucket{job="$job"}[$__rate_interval])) by (le)
```

Set target `format: "heatmap"` and panel type `heatmap` with `options.calculate: false` for pre-bucketed data.

### Apdex Score Calculation

```promql
(
  sum(rate(http_request_duration_seconds_bucket{le="0.5", job="$job"}[$__rate_interval]))
  +
  sum(rate(http_request_duration_seconds_bucket{le="2.0", job="$job"}[$__rate_interval]))
)
/
2
/
sum(rate(http_request_duration_seconds_count{job="$job"}[$__rate_interval]))
```

### Burn Rate for SLO Monitoring

```promql
# 1h burn rate
1 - (
  sum(rate(http_requests_total{status!~"5..", job="$job"}[1h]))
  /
  sum(rate(http_requests_total{job="$job"}[1h]))
) / 0.999
```

### Subquery for Smoothed Aggregation

```promql
# Max of 5m-averaged CPU over the last hour
max_over_time(avg(rate(node_cpu_seconds_total{mode!="idle"}[$__rate_interval]))[1h:5m])
```

### Recording Rule Indicators

Use recording rules for expensive queries, reference the pre-computed metric:

```promql
# In Prometheus rules:
# - record: job:http_errors:rate5m
#   expr: sum(rate(http_requests_total{status=~"5.."}[5m])) by (job)
# In Grafana panel:
job:http_errors:rate5m{job="$job"}
```

### Multi-Quantile Overlay

```promql
# p50 (query A)
histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{job="$job"}[$__rate_interval])) by (le))
# p90 (query B)
histogram_quantile(0.90, sum(rate(http_request_duration_seconds_bucket{job="$job"}[$__rate_interval])) by (le))
# p99 (query C)
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job="$job"}[$__rate_interval])) by (le))
```

Use `legendFormat` values `p50`, `p90`, `p99` for clear labeling.

---

## Multi-Datasource Dashboards

### Mixed Datasource Panel

Set panel `datasource` to `-- Mixed --` to query multiple backends in one panel:

```json
{
  "datasource": { "type": "datasource", "uid": "-- Mixed --" },
  "targets": [
    {
      "datasource": { "type": "prometheus", "uid": "prometheus-main" },
      "expr": "sum(rate(http_requests_total[$__rate_interval]))",
      "legendFormat": "Requests (Prometheus)",
      "refId": "A"
    },
    {
      "datasource": { "type": "loki", "uid": "loki-main" },
      "expr": "sum(rate({job=\"api\"} |= \"error\" [5m]))",
      "legendFormat": "Errors (Loki)",
      "refId": "B"
    }
  ]
}
```

### Datasource Variable for Portability

Define a datasource variable so dashboards work across environments:

```json
{
  "name": "ds_prom",
  "type": "datasource",
  "query": "prometheus",
  "label": "Prometheus Source"
}
```

Reference in panels: `"datasource": { "type": "prometheus", "uid": "$ds_prom" }`.

### Cross-Source Join with Transformations

When merging data from two datasources:

1. Add queries A (Prometheus) and B (SQL DB) in a mixed panel.
2. Add transformation `"id": "merge"` to combine frames by common field.
3. Or use `"id": "joinByField"` with `"options": { "byField": "instance", "mode": "outer" }`.

**Limitation**: Cross-source joins are best-effort. Pre-aggregate or normalize labels where possible.

---

## Variable Chaining

### Deep Chain: Cluster → Namespace → Service → Pod

```json
{
  "templating": {
    "list": [
      {
        "name": "cluster",
        "type": "query",
        "query": "label_values(up{job=\"kubelet\"}, cluster)",
        "refresh": 2, "sort": 1
      },
      {
        "name": "namespace",
        "type": "query",
        "query": "label_values(kube_pod_info{cluster=\"$cluster\"}, namespace)",
        "refresh": 2, "sort": 1, "includeAll": true
      },
      {
        "name": "service",
        "type": "query",
        "query": "label_values(kube_pod_info{cluster=\"$cluster\", namespace=~\"$namespace\"}, created_by_name)",
        "refresh": 2, "sort": 1, "includeAll": true
      },
      {
        "name": "pod",
        "type": "query",
        "query": "label_values(kube_pod_info{cluster=\"$cluster\", namespace=~\"$namespace\", created_by_name=~\"$service\"}, pod)",
        "refresh": 2, "sort": 1, "multi": true, "includeAll": true
      }
    ]
  }
}
```

### Variable Formatting for Multi-Value

| Syntax | Output | Use Case |
|--------|--------|----------|
| `$var` | `value1` or `value1\|value2` | Default, works for most label matchers |
| `${var:regex}` | `value1\|value2` | Inside `=~` regex matchers |
| `${var:pipe}` | `value1\|value2` | Pipe-delimited |
| `${var:csv}` | `value1,value2` | Comma-separated (SQL IN clauses) |
| `${var:sqlstring}` | `'value1','value2'` | SQL WHERE IN |
| `${var:glob}` | `{value1,value2}` | Glob patterns |
| `${var:queryparam}` | `var=value1&var=value2` | URL query strings |
| `${var:raw}` | Raw unescaped value | When no formatting needed |

### Dynamic Group-By Variable

```json
{
  "name": "groupby",
  "type": "custom",
  "query": "job,instance,handler,method,status_code",
  "multi": true,
  "current": { "text": "job", "value": "job" }
}
```

Use in queries: `sum by (${groupby}) (rate(http_requests_total[$__rate_interval]))`.

### Text Box Variable for Ad-Hoc Filtering

```json
{
  "name": "search",
  "type": "textbox",
  "query": "",
  "label": "Log Search"
}
```

Use in LogQL: `{app="$app"} |= "$search"`.

### Ad-Hoc Filters Variable

```json
{
  "name": "Filters",
  "type": "adhoc",
  "datasource": { "type": "prometheus", "uid": "prometheus-main" }
}
```

Grafana automatically injects selected label filters into all queries using that datasource.

---

## Row Repeating

### Repeat Row per Variable Value

```json
{
  "type": "row",
  "title": "Namespace: $namespace",
  "repeat": "namespace",
  "repeatDirection": "v",
  "collapsed": false,
  "panels": []
}
```

Place panels after the row panel in the `panels` array. Grafana clones the row and its child panels for each value of `$namespace`.

### Repeat Panel in Grid

```json
{
  "type": "timeseries",
  "title": "CPU - $instance",
  "repeat": "instance",
  "repeatDirection": "h",
  "maxPerRow": 4,
  "gridPos": { "x": 0, "y": 0, "w": 6, "h": 8 }
}
```

- `repeatDirection`: `"h"` (horizontal) or `"v"` (vertical).
- `maxPerRow`: Max panels per row when horizontal. Set `w` to `24 / maxPerRow`.

### Nested Repeat: Row + Panel

Combine row repeat on `namespace` with panel repeat on `instance` inside each row. The row repeats per namespace, panels inside repeat per instance within that namespace.

---

## Dynamic Thresholds

### Standard Static Thresholds

```json
"thresholds": {
  "mode": "absolute",
  "steps": [
    { "color": "green", "value": null },
    { "color": "yellow", "value": 70 },
    { "color": "red", "value": 90 }
  ]
}
```

### Percentage Mode

```json
"thresholds": {
  "mode": "percentage",
  "steps": [
    { "color": "green", "value": null },
    { "color": "orange", "value": 70 },
    { "color": "red", "value": 90 }
  ]
}
```

Percentage mode uses `min`/`max` field config as the reference range.

### Variable-Driven Thresholds (via Override)

Use a custom variable for threshold values, then apply via field override:

```json
{
  "name": "warn_threshold",
  "type": "textbox",
  "query": "80",
  "label": "Warning %"
}
```

Apply with config override in panel `fieldConfig.overrides` — use the Grafana UI to bind threshold steps to variable-sourced values. For programmatic control, use Grafonnet or Terraform to template threshold values from external inputs.

### Threshold Lines on Time Series

```json
"fieldConfig": {
  "defaults": {
    "custom": {
      "thresholdsStyle": {
        "mode": "line+area"
      }
    },
    "thresholds": {
      "steps": [
        { "color": "transparent", "value": null },
        { "color": "red", "value": 95 }
      ]
    }
  }
}
```

Modes: `"off"`, `"line"`, `"area"`, `"line+area"`, `"dashed"`, `"dashed+area"`.

---

## Value Mappings

### Mapping Types

```json
"mappings": [
  {
    "type": "value",
    "options": {
      "0": { "text": "Down", "color": "red", "index": 0 },
      "1": { "text": "Up", "color": "green", "index": 1 }
    }
  },
  {
    "type": "range",
    "options": {
      "from": 0, "to": 50,
      "result": { "text": "Low", "color": "blue", "index": 2 }
    }
  },
  {
    "type": "regex",
    "options": {
      "pattern": "/err.*/i",
      "result": { "text": "Error!", "color": "red", "index": 3 }
    }
  },
  {
    "type": "special",
    "options": {
      "match": "null",
      "result": { "text": "N/A", "color": "gray", "index": 4 }
    }
  }
]
```

Special match types: `"null"`, `"nan"`, `"null+nan"`, `"true"`, `"false"`, `"empty"`.

---

## Field Overrides

### Matcher Types

| Matcher ID | Options | Description |
|-----------|---------|-------------|
| `byName` | `"field_name"` | Exact field name |
| `byRegexp` | `"/pattern/"` | Regex on field name |
| `byType` | `"number"` | By field type |
| `byFrameRefID` | `"A"` | By query ref ID |

### Override Properties

```json
"overrides": [
  {
    "matcher": { "id": "byName", "options": "errors" },
    "properties": [
      { "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } },
      { "id": "custom.drawStyle", "value": "bars" },
      { "id": "custom.fillOpacity", "value": 50 },
      { "id": "unit", "value": "short" },
      { "id": "decimals", "value": 0 },
      { "id": "custom.axisPlacement", "value": "right" },
      { "id": "custom.lineWidth", "value": 0 }
    ]
  },
  {
    "matcher": { "id": "byRegexp", "options": "/latency_p\\d+/" },
    "properties": [
      { "id": "unit", "value": "s" },
      { "id": "custom.drawStyle", "value": "line" },
      { "id": "custom.lineInterpolation", "value": "smooth" }
    ]
  }
]
```

### Common Override Properties

| Property ID | Values | Notes |
|-------------|--------|-------|
| `color` | `{ "fixedColor": "...", "mode": "fixed" }` | Fixed color |
| `unit` | `"reqps"`, `"bytes"`, `"s"`, `"percent"` | Display unit |
| `decimals` | integer | Decimal places |
| `min` / `max` | number | Y-axis range |
| `custom.drawStyle` | `"line"`, `"bars"`, `"points"` | Visualization style |
| `custom.fillOpacity` | 0-100 | Fill under line |
| `custom.lineWidth` | 0-10 | Line thickness |
| `custom.axisPlacement` | `"auto"`, `"left"`, `"right"`, `"hidden"` | Y-axis side |
| `custom.stacking` | `{ "mode": "normal", "group": "A" }` | Stack series |
| `custom.hideFrom` | `{ "tooltip": true, "viz": false, "legend": false }` | Selective hiding |

---

## Link Patterns

### Data Link on Panel

```json
"fieldConfig": {
  "defaults": {
    "links": [
      {
        "title": "View in Explore",
        "url": "/explore?left={\"datasource\":\"prometheus-main\",\"queries\":[{\"expr\":\"${__field.labels.instance}\"}]}",
        "targetBlank": true
      },
      {
        "title": "Drill to detail",
        "url": "/d/detail-dash/detail?var-instance=${__field.labels.instance}&from=${__from}&to=${__to}",
        "targetBlank": false
      }
    ]
  }
}
```

### Data Link Variables

| Variable | Description |
|----------|-------------|
| `${__field.name}` | Field name |
| `${__field.labels.X}` | Label value |
| `${__value.raw}` | Raw field value |
| `${__value.text}` | Formatted value |
| `${__from}` / `${__to}` | Time range (epoch ms) |
| `${__from:date}` / `${__to:date}` | Time range (ISO) |
| `${__from:date:YYYY-MM-DD}` | Custom date format |
| `${__series.name}` | Series name |
| `${__data.fields.X}` | Other field value in same row |

### Dashboard-Level Links

```json
"links": [
  {
    "title": "Service Logs",
    "url": "/d/logs/logs?var-service=${service}&from=${__from}&to=${__to}",
    "type": "link",
    "icon": "doc",
    "tooltip": "Jump to logs for selected service"
  },
  {
    "title": "Related Dashboards",
    "type": "dashboards",
    "tags": ["${__from:date:YYYY}"],
    "asDropdown": true
  }
]
```

---

## Embedded Panels

### Embedding via iframe

Use panel share → embed to get an iframe URL:

```
https://grafana.example.com/d-solo/DASH_UID/dashboard?orgId=1&panelId=2&from=now-6h&to=now&theme=light
```

The `/d-solo/` endpoint renders a single panel. Add `&theme=light` or `&theme=dark`. Set `&refresh=30s` for auto-refresh.

### Embedding Requirements

- Enable `allow_embedding = true` in `grafana.ini` under `[security]`.
- Set `cookie_samesite = none` if cross-origin.
- Configure anonymous auth or use auth proxy for public dashboards.

### Public Dashboards

In Grafana 10+, use the built-in public dashboard feature:
Dashboard Settings → Public dashboard → Enable. Generates a unique public URL without authentication.

---

## Grafana Scenes

Scenes is a framework for building dynamic, interactive dashboards as Grafana app plugins.

### Key Concepts

- **Scene objects**: Composable building blocks (panels, variables, layouts).
- **Behaviors**: Attach dynamic logic (auto-refresh, cursor sync, URL sync).
- **Layouts**: `SceneGridLayout`, `SceneFlexLayout`, `SceneCSSGridLayout`.
- **State management**: Reactive — state changes propagate to child objects.

### When to Use Scenes

| Use Case | Standard Dashboard | Scenes |
|----------|-------------------|--------|
| Simple metric dashboard | ✅ | Overkill |
| Complex interactive app | ❌ | ✅ |
| Custom drill-down flows | Limited | ✅ |
| Tabbed or conditional UI | ❌ | ✅ |
| Plugin-embedded analytics | ❌ | ✅ |

### Scenes SDK Example (TypeScript)

```typescript
import { SceneApp, SceneAppPage, EmbeddedScene, SceneFlexLayout,
         SceneFlexItem, VizPanel, SceneQueryRunner, SceneTimePicker,
         SceneTimeRange, VariableValueSelectors,
         QueryVariable } from '@grafana/scenes';

const queryRunner = new SceneQueryRunner({
  datasource: { type: 'prometheus', uid: 'prometheus-main' },
  queries: [{ refId: 'A', expr: 'rate(http_requests_total[$__rate_interval])' }],
});

const scene = new EmbeddedScene({
  $timeRange: new SceneTimeRange({ from: 'now-6h', to: 'now' }),
  $variables: new SceneVariableSet({
    variables: [
      new QueryVariable({ name: 'job', datasource: { type: 'prometheus', uid: 'prom' },
        query: { query: 'label_values(up, job)' } }),
    ],
  }),
  body: new SceneFlexLayout({
    children: [
      new SceneFlexItem({
        body: new VizPanel({ title: 'Request Rate', pluginId: 'timeseries',
          $data: queryRunner }),
      }),
    ],
  }),
  controls: [new VariableValueSelectors({}), new SceneTimePicker({})],
});
```

### Dynamic Dashboards (Grafana 12+)

Grafana 12 introduces Scenes-powered "dynamic dashboards" natively:
- **Tabs layout**: Group panels into tabs for logical separation.
- **Conditional rendering**: Show/hide panels based on variable values.
- **Dashboard outline**: Tree navigation for large dashboards.
- **Responsive layouts**: Auto-grid adapts to screen size.

---

## Dashboard Versioning

### Built-in Version History

Grafana stores version history automatically. Access via:
- UI: Dashboard Settings → Versions.
- API: `GET /api/dashboards/id/:id/versions`.
- Restore: `POST /api/dashboards/id/:id/restore` with `{ "version": N }`.
- Diff: `POST /api/dashboards/id/:id/diff` with `{ "base": N, "new": M }`.

### Git-Based Version Control

Best practice workflow:

1. Export dashboard JSON via API or UI (strip `id`, `version`; keep `uid`).
2. Store in Git under `dashboards/<folder>/<uid>.json`.
3. Provision from Git via CI/CD pipeline or file-based provisioning.
4. Use `allowUiUpdates: false` in provisioning to enforce Git as source of truth.

### Dashboard JSON Cleanup for VCS

Fields to remove before committing:

```json
{
  "id": null,       // Remove — auto-assigned
  "version": 0,     // Reset
  "iteration": null  // Remove if present
}
```

Keep: `uid`, `title`, `tags`, `schemaVersion`, all `panels`.

---

## Organization Strategies

### Folder Hierarchy

```
General/
Infrastructure/
  ├── Node Exporter
  ├── Kubernetes Cluster
  └── Network
Application/
  ├── API Gateway
  ├── Auth Service
  └── Payment Service
Business/
  ├── Revenue Dashboard
  └── User Analytics
SLO/
  ├── API SLOs
  └── Platform SLOs
Alerts/
  └── Alert Overview
```

### Naming Conventions

| Pattern | Example |
|---------|---------|
| `[Team] Service - View` | `[Platform] API Gateway - Overview` |
| `Service / Subsystem` | `Auth Service / Login Flow` |
| `ENV - Service - Detail` | `PROD - Payments - Latency` |

### Tag Strategy

Use consistent tags for cross-dashboard navigation:

- **Environment**: `production`, `staging`, `development`
- **Team**: `platform`, `backend`, `frontend`, `data`
- **Domain**: `kubernetes`, `database`, `messaging`
- **Tier**: `overview`, `detail`, `debug`

### Dashboard Linking Strategy

Create a hierarchy: Overview → Service → Detail → Debug.

```
[Infrastructure Overview] ──→ [Node Detail] ──→ [Node Debug]
         │
         └──→ [Kubernetes Overview] ──→ [Pod Detail]
```

Use dashboard links with `tags` filter for automatic related dashboard discovery, or explicit links with variable pass-through for drill-down paths.

---

## Transformations

### Commonly Used Transformations

| ID | Purpose | Key Options |
|----|---------|-------------|
| `merge` | Merge multiple queries into one table | — |
| `joinByField` | Join frames by a shared field | `byField`, `mode: "outer"\|"inner"` |
| `organize` | Rename, reorder, hide fields | `excludeByName`, `renameByName`, `indexByName` |
| `filterByValue` | Filter rows by field conditions | `filters: [{ fieldName, config: { id, options } }]` |
| `calculateField` | Add computed field | `mode: "binary"`, `alias`, `binary: { left, right, operator }` |
| `groupBy` | Aggregate rows | `fields: { fieldName: { operation, aggregations } }` |
| `sortBy` | Sort by field | `sort: [{ field, desc }]` |
| `reduce` | Collapse to single row | `reducers: ["mean", "max", "last"]` |
| `seriesToColumns` | Pivot time series to columns | `byField: "Time"` |
| `convertFieldType` | Change field type | `conversions: [{ targetField, destinationType }]` |

### Chaining Transformations

```json
"transformations": [
  { "id": "merge" },
  { "id": "organize", "options": {
    "excludeByName": { "Time": true, "__name__": true },
    "renameByName": { "Value #A": "Requests", "Value #B": "Errors" }
  }},
  { "id": "calculateField", "options": {
    "mode": "binary",
    "alias": "Error Rate",
    "binary": { "left": "Errors", "right": "Requests", "operator": "/" }
  }},
  { "id": "sortBy", "options": { "sort": [{ "field": "Error Rate", "desc": true }] }}
]
```
