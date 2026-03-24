# Advanced Grafana Patterns

> Dense reference for advanced Grafana dashboard design, reusable components, and integration patterns. Grafana 11.x.

## Table of Contents

- [Dashboard Design Best Practices](#dashboard-design-best-practices)
- [Library Panels](#library-panels)
- [Dashboard Links and Drilldowns](#dashboard-links-and-drilldowns)
- [Template Variable Chaining](#template-variable-chaining)
- [Repeating Panels and Rows](#repeating-panels-and-rows)
- [Mixed Data Source Queries](#mixed-data-source-queries)
- [Data Source Correlations](#data-source-correlations)
- [Grafana Scenes](#grafana-scenes)
- [Plugin Development](#plugin-development)
- [Grafana k6 Integration](#grafana-k6-integration)
- [SLO Dashboards](#slo-dashboards)
- [Business Metrics Dashboards](#business-metrics-dashboards)
- [Capacity Planning Dashboards](#capacity-planning-dashboards)

---

## Dashboard Design Best Practices

### Layout hierarchy

Use a top-down reading pattern: summary stats at top → trends in middle → details at bottom.

```
Row 0 (h=4):  [Stat: Availability] [Stat: Error Rate] [Stat: P99 Latency] [Stat: Throughput]
Row 1 (h=8):  [TimeSeries: Request Rate (w=12)] [TimeSeries: Error Rate (w=12)]
Row 2 (h=8):  [Heatmap: Latency Distribution (w=24)]
Row 3 (h=10): [Logs: Recent Errors (w=24)]
```

### Golden signals layout

Every service dashboard should cover the four golden signals:

| Signal | Panel type | Metric example |
|--------|-----------|----------------|
| Latency | Heatmap / TimeSeries | `histogram_quantile(0.99, rate(http_duration_bucket[5m]))` |
| Traffic | TimeSeries | `sum(rate(http_requests_total[5m]))` |
| Errors | TimeSeries + Stat | `sum(rate(http_requests_total{status=~"5.."}[5m]))` |
| Saturation | Gauge / TimeSeries | `container_memory_working_set_bytes / container_spec_memory_limit_bytes` |

### Naming conventions

- Dashboard titles: `<Team> / <Service> / <Aspect>` — e.g., `Platform / API Gateway / Traffic`
- Panel titles: Concise, metric-focused — `Request Rate`, `P99 Latency`, not `Graph of requests per second over time`
- UIDs: Lowercase kebab-case, deterministic — `platform-api-traffic`
- Tags: Consistent taxonomy — `team:platform`, `env:production`, `signal:latency`

### Color and theme

- Use semantic colors: green=healthy, yellow=warning, red=critical
- Threshold-driven coloring via `fieldConfig.defaults.thresholds`
- Use `overrides` to pin specific series to fixed colors for consistency across dashboards
- Set `fieldConfig.defaults.color.mode` to `"palette-classic"` for auto-assignment or `"fixed"` for explicit

### Dashboard size limits

- ≤20 panels per dashboard; 8–12 is ideal
- Split by concern: overview → detail drilldowns
- Use collapsible rows to hide secondary panels
- Set `maxDataPoints: 1500` (default) to prevent browser overload
- Lazy loading: panels below viewport only query when scrolled into view (Grafana 10+)

---

## Library Panels

Library panels are reusable panel definitions shared across dashboards. Changes propagate to all dashboards using the panel.

### Create via API

```bash
curl -X POST http://localhost:3000/api/library-elements \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Standard Error Rate",
    "model": {
      "type": "timeseries",
      "title": "Error Rate",
      "targets": [{"expr": "sum(rate(http_requests_total{status=~\"5..\",job=\"$job\"}[$__rate_interval]))", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "reqps", "thresholds": {"steps": [{"color": "green", "value": null}, {"color": "red", "value": 10}]}}}
    },
    "kind": 1,
    "folderUid": "shared-panels"
  }'
```

### Use in dashboard JSON

```json
{
  "id": 5,
  "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
  "libraryPanel": {
    "uid": "std-error-rate",
    "name": "Standard Error Rate"
  }
}
```

### Management

- List: `GET /api/library-elements?kind=1&perPage=100`
- Get connections: `GET /api/library-elements/{uid}/connections` — shows which dashboards use it
- Update: `PATCH /api/library-elements/{uid}` — propagates to all linked dashboards
- Delete: `DELETE /api/library-elements/{uid}` — fails if still connected to dashboards

### Best practices

- Use for standardized panels: error rate, availability, latency quantiles
- Store in a dedicated folder for discoverability
- Version control the panel definitions alongside dashboards
- Use variables (`$job`, `$namespace`) to make panels context-aware

---

## Dashboard Links and Drilldowns

### Dashboard-level links

```json
{
  "links": [
    {
      "title": "Service Detail",
      "type": "dashboards",
      "tags": ["service-detail"],
      "asDropdown": true,
      "includeVars": true,
      "keepTime": true,
      "targetBlank": false
    },
    {
      "title": "Runbook",
      "type": "link",
      "url": "https://wiki.internal/runbooks/${__dashboard.uid}",
      "targetBlank": true,
      "icon": "doc"
    }
  ]
}
```

### Panel-level data links

```json
{
  "fieldConfig": {
    "defaults": {
      "links": [
        {
          "title": "View in Explore",
          "url": "/explore?orgId=1&left={\"datasource\":\"prometheus\",\"queries\":[{\"expr\":\"rate(http_requests_total{instance=\\\"${__data.fields.instance}\\\"}[5m])\"}]}",
          "targetBlank": true
        },
        {
          "title": "Drill to Service",
          "url": "/d/svc-detail/service-detail?var-service=${__data.fields.service}&${__url_time_range}",
          "targetBlank": false
        },
        {
          "title": "View Traces",
          "url": "",
          "internal": {
            "datasourceUid": "tempo-uid",
            "datasourceName": "Tempo",
            "query": {"queryType": "traceqlSearch", "serviceName": "${__data.fields.service}"}
          }
        }
      ]
    }
  }
}
```

### Link variable interpolation

| Variable | Description |
|----------|-------------|
| `${__data.fields.name}` | Value of field `name` from the data frame |
| `${__data.fields[0]}` | First field value |
| `${__series.name}` | Series name / legend |
| `${__value.raw}` | Raw value of clicked data point |
| `${__value.text}` | Display text of value |
| `${__url_time_range}` | `from=...&to=...` for preserving time range |
| `${__from}` / `${__to}` | Epoch ms timestamps |
| `${__org.id}` | Current org ID |
| `${__user.login}` | Current user login |

### Drilldown patterns

1. **Overview → Detail**: Tag-based dashboard links with `includeVars: true`
2. **Metric → Logs**: Data link from Prometheus panel to Loki Explore with label filters
3. **Metric → Traces**: Exemplar links from Prometheus to Tempo
4. **Log → Trace**: Derived fields in Loki extracting trace IDs linking to Tempo
5. **Trace → Logs**: Tempo `tracesToLogsV2` config for correlated log lookup

---

## Template Variable Chaining

Chain variables so child options depend on parent selections.

### Three-level chain: Cluster → Namespace → Pod

```json
{
  "templating": {
    "list": [
      {
        "name": "cluster",
        "type": "query",
        "query": "label_values(up{job=\"kubelet\"}, cluster)",
        "refresh": 1,
        "sort": 1
      },
      {
        "name": "namespace",
        "type": "query",
        "query": "label_values(kube_pod_info{cluster=\"$cluster\"}, namespace)",
        "refresh": 2,
        "multi": true,
        "includeAll": true,
        "allValue": ".*"
      },
      {
        "name": "pod",
        "type": "query",
        "query": "label_values(kube_pod_info{cluster=\"$cluster\", namespace=~\"$namespace\"}, pod)",
        "refresh": 2,
        "multi": true,
        "includeAll": true
      }
    ]
  }
}
```

### Performance tips for variable queries

- Use `label_values(metric{filter}, label)` — faster than `query_result()`
- Set `refresh: 1` (on dashboard load) for slow-changing values like clusters
- Set `refresh: 2` (on time range change) for time-dependent values
- Cache with `"cacheDurationSeconds": 300` in data source jsonData
- Use `sort: 1` (alphabetical asc) or `sort: 3` (numerical asc) for consistent ordering
- Add `regex` field to filter/transform values: `"/^prod-(.*)$/"` captures suffix only

### Data source variable

Make dashboards portable across environments:

```json
{
  "name": "datasource",
  "type": "datasource",
  "query": "prometheus",
  "regex": "/^(Prod|Staging) .*/",
  "multi": false
}
```

All panels reference `"datasource": {"uid": "${datasource}"}`.

### Interval variable with auto

```json
{
  "name": "interval",
  "type": "interval",
  "query": "1m,5m,15m,30m,1h",
  "auto": true,
  "auto_min": "10s",
  "auto_count": 30
}
```

Use in queries: `rate(metric[$interval])`. The auto option calculates interval from time range / auto_count.

---

## Repeating Panels and Rows

Dynamically generate panels/rows based on multi-value variable selections.

### Repeating panel

```json
{
  "id": 10,
  "type": "timeseries",
  "title": "CPU Usage: $instance",
  "repeat": "instance",
  "repeatDirection": "h",
  "maxPerRow": 4,
  "gridPos": {"x": 0, "y": 0, "w": 6, "h": 8},
  "targets": [{
    "expr": "rate(process_cpu_seconds_total{instance=\"$instance\"}[$__rate_interval])",
    "refId": "A"
  }]
}
```

- `repeat`: Variable name to repeat over
- `repeatDirection`: `"h"` (horizontal) or `"v"` (vertical)
- `maxPerRow`: Max panels per row (horizontal only)
- Panel title interpolates the variable value

### Repeating row

```json
{
  "type": "row",
  "title": "Namespace: $namespace",
  "repeat": "namespace",
  "collapsed": true,
  "panels": [
    {
      "type": "timeseries",
      "title": "Pod CPU in $namespace",
      "targets": [{"expr": "sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"$namespace\"}[5m]))", "refId": "A"}],
      "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8}
    },
    {
      "type": "timeseries",
      "title": "Pod Memory in $namespace",
      "targets": [{"expr": "sum by (pod) (container_memory_working_set_bytes{namespace=\"$namespace\"})", "refId": "A"}],
      "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8}
    }
  ]
}
```

### Pitfalls

- Only one `repeat` per panel/row; nest by using repeated rows containing panels with different variables
- Repeated panels generate copies with sequential IDs — don't hardcode IDs in links
- Large multi-value selections (>20 values) cause performance issues — add `includeAll: false` or limit with regex

---

## Mixed Data Source Queries

Combine multiple data sources in a single panel.

### Mixed data source panel

```json
{
  "type": "timeseries",
  "title": "Requests vs Errors (Multi-Source)",
  "datasource": {"type": "mixed", "uid": "-- Mixed --"},
  "targets": [
    {
      "datasource": {"type": "prometheus", "uid": "prom-1"},
      "expr": "sum(rate(http_requests_total[5m]))",
      "legendFormat": "Total Requests",
      "refId": "A"
    },
    {
      "datasource": {"type": "loki", "uid": "loki-1"},
      "expr": "sum(count_over_time({app=\"api\"} |= \"error\" [5m]))",
      "legendFormat": "Log Errors",
      "refId": "B"
    }
  ]
}
```

### Transformations for cross-source correlation

Use **Join by field** transformation to merge results from different data sources on time:

```json
{
  "transformations": [
    {
      "id": "joinByField",
      "options": {"byField": "Time", "mode": "outer"}
    },
    {
      "id": "calculateField",
      "options": {
        "mode": "binary",
        "binary": {"left": "Log Errors", "operator": "/", "right": "Total Requests"},
        "alias": "Error Ratio"
      }
    }
  ]
}
```

### Use cases

- Overlay deployment events (annotation source) on metric graphs
- Compare Prometheus metrics with database query results
- Show Loki error counts alongside Prometheus error rates for validation
- Correlate CloudWatch metrics with on-prem Prometheus data

---

## Data Source Correlations

Grafana 10+ correlations link data sources for seamless navigation.

### Configure correlation

```bash
curl -X POST http://localhost:3000/api/datasources/uid/loki-uid/correlations \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "targetUID": "tempo-uid",
    "label": "View Trace",
    "description": "Open trace in Tempo",
    "config": {
      "type": "query",
      "target": {"query": "${__data.fields.traceID}"},
      "field": "traceID"
    }
  }'
```

### Cross-source links matrix

| From | To | Link mechanism |
|------|----|----------------|
| Prometheus → Tempo | Exemplars | `exemplarTraceIdDestinations` in data source config |
| Loki → Tempo | Derived fields | `derivedFields` extracting trace ID regex |
| Tempo → Loki | Trace-to-logs | `tracesToLogsV2` with `filterByTraceID` |
| Tempo → Prometheus | Trace-to-metrics | `tracesToMetrics` with span attribute mapping |
| Tempo → Profiles | Trace-to-profiles | `tracesToProfiles` (Pyroscope) |
| Any → Any | Correlations API | `POST /api/datasources/uid/{uid}/correlations` |

### Exemplar configuration (Prometheus → Tempo)

```yaml
# In datasource provisioning
jsonData:
  exemplarTraceIdDestinations:
    - name: traceID
      datasourceUid: tempo-uid
      urlDisplayLabel: "View Trace"
```

Requires instrumented apps to emit exemplars with trace IDs on histogram metrics.

---

## Grafana Scenes

Scenes is the new framework for building dynamic, interactive dashboard experiences (Grafana 11+). It replaces the legacy dashboard model with a composable, reactive architecture.

### Core concepts

| Concept | Description |
|---------|-------------|
| `SceneApp` | Top-level container, defines pages/routing |
| `EmbeddedScene` | Self-contained scene for embedding |
| `SceneFlexLayout` | Flexible panel arrangement |
| `SceneGridLayout` | Grid-based layout (like classic dashboards) |
| `SceneQueryRunner` | Executes data source queries |
| `SceneTimePicker` | Time range control |
| `SceneVariableSet` | Variable definitions |
| `VizPanel` | Panel visualization wrapper |

### Basic Scene example (React)

```tsx
import {
  EmbeddedScene,
  SceneFlexLayout,
  SceneFlexItem,
  SceneQueryRunner,
  SceneTimePicker,
  SceneTimeRange,
  VizPanel,
} from '@grafana/scenes';

function getScene(): EmbeddedScene {
  const queryRunner = new SceneQueryRunner({
    datasource: { type: 'prometheus', uid: 'prom-1' },
    queries: [
      { refId: 'A', expr: 'rate(http_requests_total[5m])' },
    ],
  });

  return new EmbeddedScene({
    $timeRange: new SceneTimeRange({ from: 'now-6h', to: 'now' }),
    controls: [new SceneTimePicker({})],
    body: new SceneFlexLayout({
      direction: 'column',
      children: [
        new SceneFlexItem({
          body: new VizPanel({
            title: 'Request Rate',
            pluginId: 'timeseries',
            $data: queryRunner,
          }),
        }),
      ],
    }),
  });
}
```

### When to use Scenes

- Building Grafana app plugins with complex UIs
- Custom dashboards requiring dynamic layout changes
- Multi-page observability apps with routing
- Dashboards needing programmatic panel management
- Not needed for standard JSON/YAML-provisioned dashboards

---

## Plugin Development

### Plugin types

| Type | Purpose | Scaffold command |
|------|---------|-----------------|
| Panel | Custom visualization | `npx @grafana/create-plugin@latest --plugin-type=panel` |
| Data source | Custom backend | `npx @grafana/create-plugin@latest --plugin-type=datasource` |
| App | Full application | `npx @grafana/create-plugin@latest --plugin-type=app` |

### Development workflow

```bash
# Scaffold
npx @grafana/create-plugin@latest
cd my-plugin

# Install and build
npm install
npm run dev          # Watch mode

# Run Grafana with plugin
docker run -d -p 3000:3000 \
  -v $(pwd)/dist:/var/lib/grafana/plugins/my-plugin \
  -e "GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=my-plugin" \
  grafana/grafana:11.0.0

# Backend plugin (Go)
mage -v build:linux  # Compile Go backend
```

### Key APIs

```typescript
// Panel plugin
import { PanelPlugin } from '@grafana/data';
export const plugin = new PanelPlugin<Options>(MyPanel)
  .setPanelOptions(builder => {
    builder.addBooleanSwitch({ path: 'showLegend', name: 'Show legend', defaultValue: true });
  });

// Data source plugin
import { DataSourcePlugin } from '@grafana/data';
export const plugin = new DataSourcePlugin<MyDataSource>(MyDataSource)
  .setConfigEditor(ConfigEditor)
  .setQueryEditor(QueryEditor);
```

### Signing and distribution

- Sign with `npx @grafana/sign-plugin@latest`
- Publish to Grafana plugin catalog via `grafana.com/plugins`
- Private distribution: `GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=plugin-id`

---

## Grafana k6 Integration

### k6 → Prometheus → Grafana pipeline

```javascript
// k6 script with Prometheus remote write output
import http from 'k6/http';
import { check } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 100 },
    { duration: '5m', target: 100 },
    { duration: '2m', target: 0 },
  ],
};

export default function () {
  const res = http.get('http://api.example.com/endpoint');
  check(res, { 'status 200': (r) => r.status === 200 });
}
```

Run with Prometheus output:

```bash
K6_PROMETHEUS_RW_SERVER_URL=http://prometheus:9090/api/v1/write \
  k6 run --out experimental-prometheus-rw script.js
```

### k6 dashboard panels

```promql
# Virtual Users
k6_vus{testrun_id="$testrun"}

# Request Rate
rate(k6_http_reqs_total{testrun_id="$testrun"}[$__rate_interval])

# Response Time P95
histogram_quantile(0.95, rate(k6_http_req_duration_seconds_bucket{testrun_id="$testrun"}[$__rate_interval]))

# Error Rate
rate(k6_http_reqs_total{testrun_id="$testrun", expected_response="false"}[$__rate_interval])
/ rate(k6_http_reqs_total{testrun_id="$testrun"}[$__rate_interval])
```

### Grafana Cloud k6

- Native integration via Grafana Cloud k6 app
- Results stored in Grafana Cloud Prometheus
- Pre-built k6 dashboard: import ID `18030`
- Correlate load test results with application metrics on same time range

---

## SLO Dashboards

### SLI/SLO structure

| Component | Definition | Example |
|-----------|-----------|---------|
| SLI | Service Level Indicator | Proportion of successful requests |
| SLO | Service Level Objective | 99.9% availability over 30 days |
| Error Budget | Allowable failures | 0.1% × total requests in window |

### Error budget panel

```promql
# Availability SLI (ratio of successful requests)
sum(rate(http_requests_total{status!~"5..", job="$job"}[${__range}]))
/
sum(rate(http_requests_total{job="$job"}[${__range}]))

# Error budget remaining (fraction)
1 - (
  (1 - (sum(rate(http_requests_total{status!~"5..", job="$job"}[$__range]))
        / sum(rate(http_requests_total{job="$job"}[$__range]))))
  / (1 - 0.999)
)

# Error budget burn rate (multi-window)
(
  sum(rate(http_requests_total{status=~"5..", job="$job"}[1h]))
  / sum(rate(http_requests_total{job="$job"}[1h]))
) / (1 - 0.999)
```

### Multi-window burn rate alerting

```yaml
# Fast burn (2% budget in 1h) - page
- alert: SLOHighBurnRate_Page
  expr: |
    (
      sum(rate(http_requests_total{status=~"5..",job="api"}[1h]))
      / sum(rate(http_requests_total{job="api"}[1h]))
    ) > 14.4 * (1 - 0.999)
    and
    (
      sum(rate(http_requests_total{status=~"5..",job="api"}[5m]))
      / sum(rate(http_requests_total{job="api"}[5m]))
    ) > 14.4 * (1 - 0.999)
  for: 2m
  labels: { severity: critical }

# Slow burn (5% budget in 6h) - ticket
- alert: SLOHighBurnRate_Ticket
  expr: |
    (
      sum(rate(http_requests_total{status=~"5..",job="api"}[6h]))
      / sum(rate(http_requests_total{job="api"}[6h]))
    ) > 1 * (1 - 0.999)
    and
    (
      sum(rate(http_requests_total{status=~"5..",job="api"}[30m]))
      / sum(rate(http_requests_total{job="api"}[30m]))
    ) > 1 * (1 - 0.999)
  for: 15m
  labels: { severity: warning }
```

### Dashboard layout for SLO

```
Row 0: [Stat: Current SLI] [Gauge: Budget Remaining %] [Stat: Budget Burn Rate] [Stat: Time Until Exhaustion]
Row 1: [TimeSeries: SLI over time with SLO target line (w=24)]
Row 2: [TimeSeries: Error Budget consumption over 30d (w=12)] [TimeSeries: Burn Rate (w=12)]
Row 3: [Table: SLO Summary per service (w=24)]
```

Use annotation queries to mark incidents and deployments on the SLI timeline.

---

## Business Metrics Dashboards

### Connecting business KPIs to observability

| Business metric | Data source | Query approach |
|----------------|-------------|----------------|
| Revenue per minute | PostgreSQL / MySQL | SQL with `$__timeGroup` |
| Active users | Prometheus (custom metrics) | `sum(active_sessions_total)` |
| Conversion rate | PostgreSQL | `orders / page_views` over time |
| Cart abandonment | Application metrics | Custom counter metrics |
| Feature adoption | Prometheus + feature flags | Label-filtered counters |

### SQL business panel example

```sql
-- Revenue over time (PostgreSQL)
SELECT
  $__timeGroup(created_at, '$interval') AS time,
  SUM(amount_cents) / 100.0 AS revenue,
  payment_method AS metric
FROM orders
WHERE $__timeFilter(created_at) AND status = 'completed'
GROUP BY time, payment_method
ORDER BY time
```

### Combining technical and business metrics

Use mixed data source panels:

```json
{
  "datasource": {"type": "mixed", "uid": "-- Mixed --"},
  "targets": [
    {
      "datasource": {"type": "prometheus", "uid": "prom"},
      "expr": "sum(rate(http_requests_total{endpoint=\"/checkout\"}[5m]))",
      "legendFormat": "Checkout Requests/s",
      "refId": "A"
    },
    {
      "datasource": {"type": "postgres", "uid": "pg"},
      "rawSql": "SELECT $__timeGroup(created_at, '5m') AS time, count(*) AS value FROM orders WHERE $__timeFilter(created_at) GROUP BY time ORDER BY time",
      "format": "time_series",
      "refId": "B"
    }
  ]
}
```

Apply **Calculate field** transformation to derive conversion rate: `Orders / Checkout Requests`.

---

## Capacity Planning Dashboards

### Key metrics

| Resource | Metric | Forecast query |
|----------|--------|---------------|
| CPU | `instance:node_cpu:rate:sum` | `predict_linear(instance:node_cpu:rate:sum[7d], 30*86400)` |
| Memory | `node_memory_MemAvailable_bytes` | `predict_linear(node_memory_MemAvailable_bytes[7d], 30*86400)` |
| Disk | `node_filesystem_avail_bytes` | `predict_linear(node_filesystem_avail_bytes[7d], 30*86400)` |
| Network | `rate(node_network_receive_bytes_total[5m])` | Linear extrapolation |

### predict_linear panels

```promql
# Days until disk full
(node_filesystem_avail_bytes{mountpoint="/", instance="$instance"})
/
- deriv(node_filesystem_avail_bytes{mountpoint="/", instance="$instance"}[7d])
/ 86400
```

Display as **Stat** panel with unit `d` (days) and thresholds: red < 7, yellow < 30, green ≥ 30.

### Capacity dashboard layout

```
Row 0: [Stat: Days to CPU Saturated] [Stat: Days to Memory Full] [Stat: Days to Disk Full]
Row 1: [TimeSeries: CPU Usage + 30d forecast (w=12)] [TimeSeries: Memory + 30d forecast (w=12)]
Row 2: [TimeSeries: Disk Usage + 30d forecast (w=12)] [Table: Resource Summary per Node (w=12)]
Row 3: [Heatmap: Pod CPU Distribution (w=24)]
```

### Forecast overlay technique

Use two targets in one panel — actual data + `predict_linear` — with distinct colors and the prediction using dashed line style via override:

```json
{
  "targets": [
    {"expr": "node_filesystem_avail_bytes{instance=\"$instance\"}", "legendFormat": "Actual", "refId": "A"},
    {"expr": "predict_linear(node_filesystem_avail_bytes{instance=\"$instance\"}[7d], $__range_s)", "legendFormat": "Forecast", "refId": "B"}
  ],
  "fieldConfig": {
    "overrides": [
      {
        "matcher": {"id": "byName", "options": "Forecast"},
        "properties": [
          {"id": "custom.lineStyle", "value": {"fill": "dash", "dash": [10, 10]}},
          {"id": "color", "value": {"mode": "fixed", "fixedColor": "orange"}}
        ]
      }
    ]
  }
}
```
