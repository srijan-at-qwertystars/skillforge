# Advanced Grafana Dashboard Patterns

A comprehensive reference for advanced Grafana dashboard techniques including dashboard-as-code, templating, multi-source panels, linking strategies, embedding, programmatic dashboards, and plugin development.

## Table of Contents

- [Grafonnet Library (Jsonnet) for Dashboard-as-Code](#grafonnet-library-jsonnet-for-dashboard-as-code)
- [Advanced Templating](#advanced-templating)
- [Mixed Data Sources](#mixed-data-sources)
- [Shared Crosshair and Tooltip](#shared-crosshair-and-tooltip)
- [Annotations from Multiple Sources](#annotations-from-multiple-sources)
- [Calculated Fields and Transformations Chaining](#calculated-fields-and-transformations-chaining)
- [Dashboard Linking Strategies](#dashboard-linking-strategies)
- [Embedding with iframe / Public Dashboards](#embedding-with-iframe--public-dashboards)
- [Grafana Scenes (Programmatic Dashboards)](#grafana-scenes-programmatic-dashboards)
- [Plugin Development Basics](#plugin-development-basics)

---

## Grafonnet Library (Jsonnet) for Dashboard-as-Code

Grafonnet is the official Jsonnet library for generating Grafana dashboard JSON programmatically, enabling version-controlled, reviewable dashboard definitions.

### Installing Grafonnet with jsonnet-bundler

```bash
go install github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest
go install github.com/google/go-jsonnet/cmd/jsonnet@latest
mkdir grafana-dashboards && cd grafana-dashboards
jb init
jb install github.com/grafana/grafonnet/gen/grafonnet-latest@main
```

### Building a Dashboard Programmatically

```jsonnet
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
local variable = g.dashboard.variable;

g.dashboard.new('Service Overview')
+ g.dashboard.withUid('svc-overview-001')
+ g.dashboard.withTags(['generated', 'service'])
+ g.dashboard.withRefresh('30s')
+ g.dashboard.graphTooltip.withSharedCrosshair()
+ g.dashboard.withVariables([
  variable.datasource.new('datasource', 'prometheus'),
  variable.query.new('namespace')
  + variable.query.queryTypes.withLabelValues('namespace', 'up{}')
  + variable.query.withRefresh('time'),
])
+ g.dashboard.withPanels(g.util.grid.makeGrid([
  g.panel.timeSeries.new('Request Rate')
  + g.panel.timeSeries.withTargets([
      g.query.prometheus.new('$datasource',
        'sum(rate(http_requests_total{namespace="$namespace"}[5m])) by (handler)')
      + g.query.prometheus.withLegendFormat('{{ handler }}'),
    ])
  + g.panel.timeSeries.standardOptions.withUnit('reqps')
  + g.panel.timeSeries.panelOptions.withGridPos(h=8, w=12),
], panelWidth=12))
```

Render: `jsonnet -J vendor/ dashboards/service-overview.jsonnet > output/service-overview.json`

### Reusable Panel Functions

Create `lib/panels.libsonnet` for shared components:

```jsonnet
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-latest/main.libsonnet';
{
  latencyPanel(title, metric, ns, dsVar)::
    g.panel.timeSeries.new(title)
    + g.panel.timeSeries.queryOptions.withDatasource('prometheus', '$' + dsVar)
    + g.panel.timeSeries.withTargets([
        g.query.prometheus.new('$' + dsVar,
          'histogram_quantile(0.99, sum(rate(%s{namespace="%s"}[5m])) by (le))' % [metric, ns])
        + g.query.prometheus.withLegendFormat('p99'),
        g.query.prometheus.new('$' + dsVar,
          'histogram_quantile(0.50, sum(rate(%s{namespace="%s"}[5m])) by (le))' % [metric, ns])
        + g.query.prometheus.withLegendFormat('p50'),
      ])
    + g.panel.timeSeries.standardOptions.withUnit('s'),
}
```

### Parameterized Dashboards

Generate dashboards for multiple services from a configuration list:

```jsonnet
local panels = import '../lib/panels.libsonnet';
local services = [
  { name: 'api-gateway', has_grpc: false },
  { name: 'user-service', has_grpc: true },
];
{
  ['%s-dashboard.json' % svc.name]:
    g.dashboard.new('%s Overview' % svc.name)
    + g.dashboard.withPanels(
      [panels.latencyPanel('HTTP Latency', 'http_duration_bucket', svc.name, 'ds')]
      + (if svc.has_grpc then
        [panels.latencyPanel('gRPC Latency', 'grpc_duration_bucket', svc.name, 'ds')]
      else [])
    )
  for svc in services
}
```

Render all: `jsonnet -J vendor/ -m output/ dashboards/multi-service.jsonnet`

### CI/CD Integration for Rendering JSON

```yaml
name: Grafana Dashboards
on:
  push: { paths: ['dashboards/**', 'lib/**'] }
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          go install github.com/google/go-jsonnet/cmd/jsonnet@latest
          go install github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb@latest
      - run: jb install
      - run: |
          mkdir -p output
          for f in dashboards/*.jsonnet; do
            jsonnet -J vendor/ "$f" > "output/$(basename "$f" .jsonnet).json"
          done
      - if: github.ref == 'refs/heads/main'
        run: |
          for f in output/*.json; do
            curl -s -X POST "$GRAFANA_URL/api/dashboards/db"               -H "Authorization: Bearer $GRAFANA_TOKEN"               -H "Content-Type: application/json"               -d "{"dashboard": $(cat "$f"), "overwrite": true}"
          done
        env:
          GRAFANA_URL: ${{ secrets.GRAFANA_URL }}
          GRAFANA_TOKEN: ${{ secrets.GRAFANA_TOKEN }}
```

---

## Advanced Templating

### Chained Variables (Parent-Child Dependencies)

Child variables reference parent selections. Order matters — parents must precede children. Set `refresh: 2` (on time range change) so children update when parents change.

```json
{
  "templating": { "list": [
    { "name": "cluster", "type": "query", "query": "label_values(up, cluster)", "refresh": 2 },
    { "name": "namespace", "type": "query", "query": "label_values(up{cluster="$cluster"}, namespace)", "refresh": 2 },
    { "name": "pod", "type": "query", "query": "label_values(up{cluster="$cluster", namespace="$namespace"}, pod)", "refresh": 2 }
  ]}
}
```

### Ad-Hoc Filters

Let users add arbitrary label filters at query time. Filters are auto-injected into all queries targeting the configured datasource.

```json
{ "name": "Filters", "type": "adhoc", "datasource": { "uid": "prometheus" } }
```

Limitations: only supported datasources (Prometheus, Loki, Elasticsearch, InfluxDB); applies to all queries for that datasource; no multi-value per key.

### Magic Variables: __interval and __rate_interval

| Variable | Description | Example |
|----------|-------------|---------|
| `$__interval` | Auto step: `time_range / max_data_points` | `15s`, `5m` |
| `$__rate_interval` | Max of `$__interval` and 4x scrape interval | `1m`, `4m` |
| `$__range` / `$__range_s` | Visible time range as duration / seconds | `1h` / `3600` |

```promql
sum(rate(http_requests_total{job="$job"}[$__rate_interval])) by (handler)  -- correct
avg_over_time(cpu_usage{instance="$instance"}[$__interval])               -- correct
sum(rate(http_requests_total[5m]))                                        -- wrong: hardcoded
```

### Multi-Value Variable Formatting

| Syntax | Output for `["a","b","c"]` | Use case |
|--------|---------------------------|----------|
| `${var:csv}` | `a,b,c` | SQL `IN` |
| `${var:pipe}` | `a\|b\|c` | PromQL regex |
| `${var:regex}` | `(a\|b\|c)` | Full regex group |
| `${var:singlequote}` | `'a','b','c'` | SQL strings |
| `${var:json}` | `["a","b","c"]` | JSON arrays |
| `${var:lucene}` | `("a" OR "b" OR "c")` | Elasticsearch |

```promql
http_requests_total{method=~"${method:pipe}"}
```

```sql
SELECT * FROM events WHERE region IN (${region:singlequote})
```

### $__all Behavior and Custom allValue

A custom `allValue` avoids sending every option individually when `All` is selected:

```json
{ "name": "instance", "includeAll": true, "allValue": ".*", "multi": true }
```

This produces `up{instance=~".*"}` instead of `up{instance=~"host1|host2|...|host200"}`. Common values: `.*` (PromQL), `%` (SQL), `*` (Elasticsearch).

### Hide Options

| Value | Effect |
|-------|--------|
| `0` | Visible with label and dropdown |
| `1` | Dropdown only, label hidden |
| `2` | Completely hidden — for computed variables |

---

## Mixed Data Sources

The `-- Mixed --` datasource combines queries from different backends in a single panel.

### Using the Mixed Datasource

```json
{
  "datasource": { "uid": "-- Mixed --" },
  "targets": [
    { "datasource": { "type": "prometheus", "uid": "prom" }, "expr": "rate(http_requests_total[5m])", "refId": "A" },
    { "datasource": { "type": "loki", "uid": "loki" }, "expr": "{job="api"} |= "error"", "refId": "B" }
  ]
}
```

### Per-Query Datasource Override

Each `refId` targets a different datasource independently. Select `-- Mixed --` at the panel level, then set datasources per query row.

### Combining Prometheus + Loki + Elasticsearch

```json
{
  "title": "Error Correlation", "type": "timeseries",
  "datasource": { "uid": "-- Mixed --" },
  "targets": [
    { "refId": "A", "datasource": { "type": "prometheus", "uid": "prom" },
      "expr": "sum(rate(http_requests_total{status=~"5.."}[5m]))", "legendFormat": "5xx rate" },
    { "refId": "B", "datasource": { "type": "loki", "uid": "loki" },
      "expr": "sum(count_over_time({job="api"} |= "panic" [5m]))", "legendFormat": "Panic logs" },
    { "refId": "C", "datasource": { "type": "elasticsearch", "uid": "es" },
      "query": "exception AND service:api",
      "metrics": [{ "type": "count", "id": "1" }],
      "bucketAggs": [{ "type": "date_histogram", "field": "@timestamp", "id": "2" }] }
  ]
}
```

### Use Cases and Gotchas

**Use cases:** correlating metrics with log volume; comparing staging vs. production; overlaying deployment events.

**Gotchas:** different time granularities need "Join by field" transformations; ad-hoc filters only apply to their configured datasource; each query runs as a separate request; template variables must be valid per datasource query language.

---

## Shared Crosshair and Tooltip

### graphTooltip Settings

Dashboard-level setting controlling cross-panel cursor synchronization:

| Value | Mode | Behavior |
|-------|------|----------|
| `0` | Default | Tooltip on hovered panel only |
| `1` | Shared crosshair | Vertical line on all panels, tooltip on hovered panel |
| `2` | Shared tooltip | Full tooltip on all panels simultaneously |

```json
{ "title": "Production Overview", "graphTooltip": 1 }
```

### Configuring Shared Crosshair

In Grafonnet:

```jsonnet
g.dashboard.new('Overview')
+ g.dashboard.graphTooltip.withSharedCrosshair()   // mode 1
+ g.dashboard.graphTooltip.withSharedTooltip()      // mode 2
```

### Interaction Behavior

Mode 2 computes tooltip content for every panel on each mouse move — can lag on dashboards with >20 panels. Prefer mode 1 for dense layouts.

---

## Annotations from Multiple Sources

### Query-Based Annotations

Each annotation source can query a different datasource:

```json
{ "annotations": { "list": [
  { "name": "Deployments", "datasource": { "type": "prometheus", "uid": "prom" },
    "enable": true, "iconColor": "blue",
    "expr": "changes(deployment_revision{namespace="$namespace"}[1m]) > 0",
    "titleFormat": "Deployment", "textFormat": "Revision changed in {{ namespace }}" },
  { "name": "Alerts", "datasource": { "type": "prometheus", "uid": "prom" },
    "enable": true, "iconColor": "red",
    "expr": "ALERTS{alertstate="firing"}", "titleFormat": "{{ alertname }}" },
  { "name": "Error Logs", "datasource": { "type": "loki", "uid": "loki" },
    "enable": false, "iconColor": "orange", "expr": "{job="api"} |= "FATAL"" }
]}}
```

### Annotation Tag Filtering

Filter Grafana-stored annotations by tags and create them via API:

```json
{ "name": "Releases", "datasource": { "uid": "-- Grafana --" },
  "filter": { "tags": ["deploy", "release"] }, "type": "tags" }
```

```bash
curl -X POST "$GRAFANA_URL/api/annotations"   -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json"   -d '{"time":1700000000000,"tags":["deploy","v2.3.1"],"text":"Deployed v2.3.1"}'
```

### Built-In Annotations and Toggle Behavior

The built-in "Annotations & Alerts" source shows alert state changes. `enable` sets default visibility; `hide` controls whether the toolbar toggle appears.

### Performance Considerations

Each enabled annotation queries on every load/time change. Disable expensive sources by default (`enable: false`). Prometheus `changes()` is lightweight; Loki log scanning is heavier. Use tags to filter narrowly.

---

## Calculated Fields and Transformations Chaining

### Add Field from Calculation

```json
{"id":"calculateField","options":{"mode":"binary","binary":{"left":"total","right":"errors","operator":"/"},"alias":"error_rate"}}
```

```json
{"id":"calculateField","options":{"mode":"reduceRow","reduce":{"reducer":"sum","include":["cpu_user","cpu_system"]},"alias":"total_cpu"}}
```

### Chaining Transformations in Sequence

Each step receives the previous step's output:

```json
{ "transformations": [
  { "id": "merge", "options": {} },
  { "id": "organize", "options": {
    "excludeByName": { "__name__": true },
    "renameByName": { "Value #A": "Requests", "Value #B": "Errors" }
  }},
  { "id": "calculateField", "options": {
    "mode": "binary", "binary": { "left": "Errors", "right": "Requests", "operator": "/" }, "alias": "Error Rate"
  }},
  { "id": "filterByValue", "options": {
    "type": "include",
    "filters": [{"fieldName":"Error Rate","config":{"id":"greater","options":{"value":0.01}}}]
  }}
]}
```

### Common Transformation Recipes

**Join by field:** `{"id":"joinByField","options":{"byField":"Time","mode":"outer"}}`

**Reduce:** `{"id":"reduce","options":{"reducers":["mean","max","last"]}}`

**Series to rows:** `{"id":"seriesToRows","options":{}}`

**Group by:**

```json
{"id":"groupBy","options":{"fields":{
  "region":{"operation":"groupby"},
  "latency":{"operation":"aggregate","aggregations":["mean","max"]},
  "requests":{"operation":"aggregate","aggregations":["sum"]}
}}}
```

**Organize fields:**

```json
{"id":"organize","options":{
  "indexByName":{"Time":0,"service":1,"value":2},
  "renameByName":{"value":"Request Count"},
  "excludeByName":{"job":true}
}}
```

---

## Dashboard Linking Strategies

### Dashboard Links with Variable Forwarding

```json
{ "links": [
  { "title": "Service Detail", "type": "dashboard", "tags": ["service-detail"],
    "asDropdown": true, "keepTime": true, "includeVars": true },
  { "title": "Runbook", "type": "link",
    "url": "https://wiki.example.com/runbooks/${service}", "targetBlank": true }
]}
```

Tag-based links auto-discover dashboards with matching tags as a dropdown.

### Data Links with Field Interpolation

```json
{ "fieldConfig": { "defaults": { "links": [
  { "title": "View in Explore",
    "url": "/explore?left={"queries":[{"expr":"rate(http_requests_total{handler=\"${__value.raw}\"}[5m])"}]}",
    "targetBlank": true },
  { "title": "Logs for ${__field.labels.instance}",
    "url": "/explore?left={"queries":[{"expr":"{instance=\"${__field.labels.instance}\"}"}],"datasource":"loki"}" }
]}}}
```

| Variable | Description |
|----------|-------------|
| `${__value.raw}` | Raw clicked value |
| `${__value.numeric}` / `${__value.text}` | Numeric / display text |
| `${__value.time}` | Timestamp (ms epoch) |
| `${__field.name}` | Field name |
| `${__field.labels.instance}` | Label value |
| `${__series.name}` | Series legend |

### Drilldown Patterns

Fleet overview -> service dashboard -> log/trace view:

```json
{ "type": "table", "fieldConfig": { "overrides": [
  { "matcher": {"id":"byName","options":"service"}, "properties": [
    {"id":"links","value":[
      {"title":"Open ${__value.raw}","url":"/d/svc-detail/detail?var-service=${__value.raw}"}
    ]}
  ]}
]}}
```

### keepTime and includeVars

- `keepTime: true` appends `from=<start>&to=<end>` to preserve time range.
- `includeVars: true` appends all template variable values (`var-cluster=prod`).

Without these, the target dashboard loads with default time and variable values.

---

## Embedding with iframe / Public Dashboards

### Public Dashboard Feature

Grafana 9.1+ supports unauthenticated, read-only public dashboards. Enable in `grafana.ini`:

```ini
[feature_toggles]
publicDashboards = true
```

URL: `https://grafana.example.com/public-dashboards/<access-token>`. Variables use saved defaults and are not interactive.

### Embedding via iframe

```html
<!-- Full dashboard, kiosk mode -->
<iframe src="https://grafana.example.com/d/svc/overview?orgId=1&kiosk" width="100%" height="600"></iframe>

<!-- Single panel (solo view) -->
<iframe src="https://grafana.example.com/d-solo/svc/overview?panelId=4&from=now-6h&to=now" width="450" height="200"></iframe>
```

### Authentication and CORS

```ini
[security]
allow_embedding = true
cookie_samesite = none
cookie_secure = true
```

Nginx reverse proxy:

```nginx
location /grafana/ {
    proxy_pass http://grafana:3000/;
    add_header Content-Security-Policy "frame-ancestors 'self' https://portal.example.com";
}
```

### Kiosk Mode and Playlist Mode

Kiosk: append `&kiosk` (or `&kiosk=tv` to also hide panel titles).

Playlist — cycles dashboards automatically:

```json
{ "name": "NOC Display", "interval": "30s",
  "items": [{"type":"dashboard_by_tag","value":"noc"},{"type":"dashboard_by_uid","value":"infra"}] }
```

Start: `https://grafana.example.com/playlists/play/1?kiosk`

---

## Grafana Scenes (Programmatic Dashboards)

Scenes is a TypeScript framework for building dynamic dashboards as React components with full runtime logic, replacing static JSON.

### The Scenes API

Object graph: `SceneApp -> SceneAppPage -> SceneFlexLayout -> SceneFlexItem -> VizPanel + SceneQueryRunner`

```bash
npm install @grafana/scenes @grafana/data @grafana/ui @grafana/schema @grafana/runtime
```

### Building with SceneApp and SceneFlexLayout

```typescript
import {
  EmbeddedScene, SceneFlexLayout, SceneFlexItem, SceneQueryRunner,
  SceneVariableSet, QueryVariable, VizPanel, SceneTimePicker,
  SceneTimeRange, VariableValueSelectors, SceneControlsSpacer, SceneRefreshPicker,
} from '@grafana/scenes';

function getScene(): EmbeddedScene {
  return new EmbeddedScene({
    $timeRange: new SceneTimeRange({ from: 'now-6h', to: 'now' }),
    $variables: new SceneVariableSet({ variables: [
      new QueryVariable({ name: 'namespace',
        datasource: { type: 'prometheus', uid: 'prometheus' },
        query: { query: 'label_values(up, namespace)', refId: 'ns' } }),
    ]}),
    controls: [new VariableValueSelectors({}), new SceneControlsSpacer(),
               new SceneTimePicker({}), new SceneRefreshPicker({})],
    body: new SceneFlexLayout({ direction: 'row', children: [
      new SceneFlexItem({ width: '60%', body: new VizPanel({
        title: 'Request Rate', pluginId: 'timeseries',
        $data: new SceneQueryRunner({
          datasource: { type: 'prometheus', uid: 'prometheus' },
          queries: [{ refId: 'A',
            expr: 'sum(rate(http_requests_total{namespace="$namespace"}[$__rate_interval])) by (handler)',
            legendFormat: '{{ handler }}' }],
        }),
        fieldConfig: { defaults: { unit: 'reqps' }, overrides: [] },
      })}),
    ]}),
  });
}
```

### SceneQueryRunner and VizPanel

```typescript
const vizPanel = new VizPanel({
  title: 'Latency', pluginId: 'timeseries',
  $data: new SceneQueryRunner({
    queries: [
      { refId: 'A', expr: 'histogram_quantile(0.99, sum(rate(duration_bucket[$__rate_interval])) by (le))', legendFormat: 'p99' },
      { refId: 'B', expr: 'histogram_quantile(0.50, sum(rate(duration_bucket[$__rate_interval])) by (le))', legendFormat: 'p50' },
    ], maxDataPoints: 1000,
  }),
  options: { tooltip: { mode: 'multi' }, legend: { displayMode: 'table', calcs: ['mean', 'max'] } },
  fieldConfig: { defaults: { unit: 's', custom: { fillOpacity: 10 } }, overrides: [] },
});
```

### Comparison with Traditional Dashboards

| Feature | JSON Dashboards | Grafana Scenes |
|---------|----------------|----------------|
| Format | Static JSON | TypeScript/React |
| Conditional logic | Not possible | Full control |
| State | URL params + variables | Built-in reactive |
| Reusability | Library panels | React composition |
| Delivery | Provisioned files | App plugin |
| Requirements | All versions | Grafana 10+ |

Use Scenes for conditional rendering, multi-page apps, complex interactions, or type-safety.

---

## Plugin Development Basics

### Using @grafana/create-plugin

```bash
npx @grafana/create-plugin@latest   # prompts: type, name, org
npm install && npm run dev           # dev server with hot reload
docker-compose up -d                 # local Grafana with plugin
npm run build                        # production build
```

### Panel Plugin Structure

`module.ts` — entry point:

```typescript
import { PanelPlugin } from '@grafana/data';
import { SimplePanel } from './components/SimplePanel';
import { SimpleOptions } from './types';

export const plugin = new PanelPlugin<SimpleOptions>(SimplePanel)
  .setPanelOptions((builder) => {
    builder
      .addBooleanSwitch({ path: 'showHeader', name: 'Show header', defaultValue: true })
      .addSelect({ path: 'colorScheme', name: 'Color scheme', defaultValue: 'green',
        settings: { options: [{ value: 'green', label: 'Green' }, { value: 'red', label: 'Red' }] } })
      .addNumberInput({ path: 'threshold', name: 'Threshold', defaultValue: 80,
        settings: { min: 0, max: 100 } });
  });
```

`SimplePanel.tsx` — component:

```typescript
import React from 'react';
import { PanelProps } from '@grafana/data';
import { useTheme2 } from '@grafana/ui';
import { SimpleOptions } from '../types';

export const SimplePanel: React.FC<PanelProps<SimpleOptions>> = ({ options, data, width, height }) => {
  const theme = useTheme2();
  const frame = data.series[0];
  if (!frame) return <div>No data</div>;
  return (
    <div style={{ width, height, padding: theme.spacing(1) }}>
      {options.showHeader && <h3>{frame.name || 'Panel'}</h3>}
      <pre>Fields: {frame.fields.length}, Rows: {frame.length}</pre>
    </div>
  );
};
```

### Data Source Plugin Structure

Frontend datasource class:

```typescript
import { DataSourceApi, DataQueryRequest, DataQueryResponse, DataSourceInstanceSettings } from '@grafana/data';
import { getBackendSrv } from '@grafana/runtime';

export class MyDataSource extends DataSourceApi<MyQuery, MyDataSourceOptions> {
  constructor(settings: DataSourceInstanceSettings<MyDataSourceOptions>) {
    super(settings);
    this.baseUrl = settings.url || '';
  }
  async query(request: DataQueryRequest<MyQuery>): Promise<DataQueryResponse> {
    const resp = await getBackendSrv().datasourceRequest({
      method: 'GET', url: `${this.baseUrl}/api/query`,
      params: { from: request.range.from.toISOString(), to: request.range.to.toISOString() },
    });
    return { data: resp.data };
  }
  async testDatasource() {
    try {
      await getBackendSrv().datasourceRequest({ method: 'GET', url: `${this.baseUrl}/api/health` });
      return { status: 'success', message: 'Working' };
    } catch (e) { return { status: 'error', message: String(e) }; }
  }
}
```

Backend plugins add a Go handler in `pkg/plugin/datasource.go`.

### plugin.json Configuration

```json
{
  "type": "panel",
  "name": "My Panel",
  "id": "myorg-mypanel-panel",
  "info": { "version": "1.0.0", "author": { "name": "My Org" },
    "logos": { "small": "img/logo.svg", "large": "img/logo.svg" } },
  "dependencies": { "grafanaDependency": ">=10.0.0", "plugins": [] }
}
```

Data source plugins set `"type": "datasource"`, `"backend": true`, and `"executable": "gpx_myorg_myplugin"`.

### Testing and Publishing

```typescript
import { render, screen } from '@testing-library/react';
import { SimplePanel } from './SimplePanel';
import { FieldType, LoadingState, toDataFrame } from '@grafana/data';

test('renders', () => {
  render(<SimplePanel options={{ showHeader: true }} data={{
    state: LoadingState.Done,
    series: [toDataFrame({ name: 'test', fields: [
      { name: 'time', type: FieldType.time, values: [1] },
      { name: 'val', type: FieldType.number, values: [10] }
    ]})], timeRange: {} as any }} width={400} height={300} />);
  expect(screen.getByText('test')).toBeInTheDocument();
});
```

Build and sign:

```bash
npm run build
npx @grafana/sign-plugin@latest --rootUrls https://grafana.example.com
```

Publish by hosting source on GitHub, attaching the signed zip to a release, and submitting to the Grafana plugin catalog.
