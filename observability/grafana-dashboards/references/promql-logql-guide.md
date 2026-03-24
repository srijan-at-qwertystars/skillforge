# PromQL, LogQL & Query Language Deep Dive

> Dense reference for query languages used in Grafana: PromQL, LogQL, TraceQL, SQL macros, and Flux.

## Table of Contents

- [PromQL Fundamentals](#promql-fundamentals)
- [PromQL Instant vs Range Vectors](#promql-instant-vs-range-vectors)
- [PromQL Aggregation Operators](#promql-aggregation-operators)
- [rate vs irate](#rate-vs-irate)
- [histogram_quantile](#histogram_quantile)
- [Recording Rules](#recording-rules)
- [Subqueries](#subqueries)
- [PromQL Patterns and Recipes](#promql-patterns-and-recipes)
- [LogQL Fundamentals](#logql-fundamentals)
- [LogQL Stream Selectors](#logql-stream-selectors)
- [LogQL Filter Expressions](#logql-filter-expressions)
- [LogQL Parsers](#logql-parsers)
- [LogQL Metrics from Logs](#logql-metrics-from-logs)
- [LogQL Pattern Matching](#logql-pattern-matching)
- [TraceQL Basics](#traceql-basics)
- [SQL Queries for Database Sources](#sql-queries-for-database-sources)
- [Flux for InfluxDB](#flux-for-influxdb)

---

## PromQL Fundamentals

### Data types

| Type | Description | Example |
|------|-------------|---------|
| Instant vector | Set of time series, each with single sample at query time | `http_requests_total{job="api"}` |
| Range vector | Set of time series with range of samples | `http_requests_total{job="api"}[5m]` |
| Scalar | Single numeric value | `42`, `1.5` |
| String | Single string (rarely used) | `"hello"` |

### Label matchers

| Operator | Description | Example |
|----------|-------------|---------|
| `=` | Exact match | `{job="api"}` |
| `!=` | Not equal | `{job!="test"}` |
| `=~` | Regex match | `{status=~"5.."}` |
| `!~` | Negative regex | `{method!~"GET\|HEAD"}` |

Always prefer `=` over `=~` for exact values — regex matching is slower. Avoid `{job=~".*"}` — it matches everything and is expensive.

### Staleness

- A series becomes stale 5 minutes after the last scrape
- Stale series are excluded from instant vector queries
- `rate()` and `increase()` handle staleness boundaries correctly
- For raw gauges across gaps: use `last_over_time(metric[10m])`

---

## PromQL Instant vs Range Vectors

### Instant vector queries

Return one value per series at the evaluation timestamp:

```promql
# Current value
http_requests_total{job="api"}

# Result: {method="GET", status="200"} 15234
#         {method="POST", status="200"} 8921
```

### Range vector queries

Return a matrix of samples over a time window — required by functions like `rate()`:

```promql
# Last 5 minutes of samples
http_requests_total{job="api"}[5m]

# Result: {method="GET"} [15000@t-5m, 15050@t-4m, ..., 15234@t]
```

### Key rules

- Range vectors cannot be graphed directly — they must be passed to a function
- Functions requiring range vectors: `rate()`, `irate()`, `increase()`, `avg_over_time()`, `max_over_time()`, `min_over_time()`, `sum_over_time()`, `count_over_time()`, `stddev_over_time()`, `quantile_over_time()`, `last_over_time()`, `present_over_time()`, `changes()`, `resets()`, `deriv()`, `predict_linear()`, `delta()`, `idelta()`
- Functions returning instant vectors from range vectors: `rate()`, `avg_over_time()`, etc.
- In Grafana: use `$__rate_interval` for range duration — accounts for scrape interval + resolution step

### over_time functions for gauges

```promql
# Average CPU over 5m windows
avg_over_time(node_cpu_seconds_total{mode="idle"}[5m])

# Max memory usage in window
max_over_time(container_memory_usage_bytes[1h])

# 95th percentile of response time (gauge metric) over window
quantile_over_time(0.95, http_response_time_seconds[5m])
```

---

## PromQL Aggregation Operators

### Syntax

```promql
<aggr_op>([parameter,] <vector>) [without|by (<label_list>)]
```

### Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `sum` | Sum values | `sum by (job) (rate(requests_total[5m]))` |
| `avg` | Mean | `avg by (instance) (cpu_usage)` |
| `min` / `max` | Extremes | `max by (pod) (memory_usage)` |
| `count` | Count series | `count by (job) (up)` |
| `stddev` / `stdvar` | Standard deviation/variance | `stddev by (service) (latency)` |
| `topk` / `bottomk` | Top/bottom K series | `topk(10, rate(requests_total[5m]))` |
| `count_values` | Count unique values | `count_values("version", app_version)` |
| `quantile` | Quantile across series | `quantile(0.95, rate(latency[5m]))` |
| `group` | Returns 1 per group | `group by (job) (up)` |

### `by` vs `without`

```promql
# Keep only listed labels in result
sum by (job, status) (rate(http_requests_total[5m]))

# Remove listed labels, keep all others
sum without (instance, pod) (rate(http_requests_total[5m]))
```

Use `without` when you want most labels preserved and only need to aggregate away a few (e.g., `instance`).

### Binary operators with vector matching

```promql
# One-to-one matching (default: match on all shared labels)
rate(errors_total[5m]) / rate(requests_total[5m])

# Explicit matching labels
rate(errors_total[5m]) / on(job, method) rate(requests_total[5m])

# Ignore specific labels
rate(errors_total[5m]) / ignoring(status) rate(requests_total[5m])

# One-to-many / many-to-one
rate(errors_total[5m]) / on(job) group_left(team) rate(requests_total[5m])
```

`group_left` / `group_right` enables many-to-one joins and can copy labels from the "one" side.

---

## rate vs irate

### rate()

Calculates per-second average rate of increase over the full range:

```promql
rate(http_requests_total[5m])
```

- Uses first and last points in range window
- Smooths out spikes — good for alerting and dashboards
- Handles counter resets correctly
- **Always use `$__rate_interval`** in Grafana: `rate(metric[$__rate_interval])`

### irate()

Calculates per-second instant rate using the last two data points:

```promql
irate(http_requests_total[5m])
```

- Only uses last two samples — very responsive to spikes
- The range `[5m]` is only a lookback window to find two points, not an averaging window
- More volatile — useful for debugging, not for alerting
- May miss short spikes if scrape interval is too long

### When to use which

| Scenario | Use | Why |
|----------|-----|-----|
| Alerting | `rate()` | Smoothed, fewer false positives |
| Dashboard trends | `rate()` | Readable, consistent |
| Debugging/spike detection | `irate()` | Shows actual rate between scrapes |
| Recording rules | `rate()` | Predictable, composable |
| High-resolution (scrape <15s) | Either | `irate` useful when investigating |

### increase()

`increase()` is syntactic sugar for `rate() * range_seconds`:

```promql
# These are equivalent:
increase(http_requests_total[1h])
rate(http_requests_total[1h]) * 3600
```

Use `increase()` when you want absolute count over a period, not per-second rate.

---

## histogram_quantile

### Prometheus histograms

Histograms use `_bucket`, `_count`, and `_sum` suffixes:

```
http_request_duration_seconds_bucket{le="0.005"} 1000
http_request_duration_seconds_bucket{le="0.01"}  1500
http_request_duration_seconds_bucket{le="0.025"} 2000
http_request_duration_seconds_bucket{le="0.05"}  3000
http_request_duration_seconds_bucket{le="0.1"}   4000
http_request_duration_seconds_bucket{le="+Inf"}  5000
http_request_duration_seconds_count              5000
http_request_duration_seconds_sum                250.5
```

### Computing quantiles

```promql
# P99 latency
histogram_quantile(0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)

# P99 per service
histogram_quantile(0.99,
  sum by (le, service) (rate(http_request_duration_seconds_bucket[5m]))
)

# Average latency (from sum/count, not histogram_quantile)
rate(http_request_duration_seconds_sum[5m])
/ rate(http_request_duration_seconds_count[5m])
```

### Critical rules

1. **Always `rate()` before `histogram_quantile()`** — raw bucket counters are cumulative
2. **Always `sum by (le, ...)`** — `le` label must be preserved for interpolation
3. **Don't aggregate away `le`** — `sum without (le)` breaks histogram_quantile
4. **Result accuracy depends on bucket boundaries** — poorly chosen buckets = inaccurate quantiles

### Native histograms (Prometheus 2.40+)

```promql
# Native histograms — no le label needed
histogram_quantile(0.99, rate(http_request_duration_seconds[5m]))
```

Native histograms are more efficient (single series instead of N bucket series) and more accurate.

### Heatmap panels

For Grafana heatmap visualization, use raw bucket rates without `histogram_quantile`:

```promql
# For heatmap panel — set Format: Heatmap
sum by (le) (rate(http_request_duration_seconds_bucket{job="api"}[$__rate_interval]))
```

---

## Recording Rules

Pre-compute expensive queries and store results as new time series.

### Configuration

```yaml
# prometheus/rules/recording.yml
groups:
  - name: http_rules
    interval: 30s    # Evaluation interval for this group
    rules:
      # Request rate by job
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))

      # Error ratio by job
      - record: job:http_errors:ratio5m
        expr: |
          sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
          / sum by (job) (rate(http_requests_total[5m]))

      # P99 latency by job
      - record: job:http_duration:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )

      # Availability
      - record: job:availability:ratio5m
        expr: |
          1 - job:http_errors:ratio5m
```

### Naming convention

```
level:metric:operations
```

- `level` — aggregation level: `job`, `instance`, `namespace`, `cluster`
- `metric` — metric name without suffix
- `operations` — applied functions: `rate5m`, `ratio`, `p99_5m`

### When to use recording rules

- Query takes >1s in Grafana
- Same aggregation used in multiple dashboards
- Alerting on complex expressions (alerts should reference recorded metrics)
- Reducing query load on Prometheus during peak dashboard usage
- Bridging data retention: record 5m aggregates for long-term trends

### Use in Grafana

Reference recording rules like any metric:

```promql
# In dashboard panel — fast, pre-computed
job:http_requests:rate5m{job="$job"}

# In alert rule — more reliable than computing on-the-fly
job:http_errors:ratio5m{job="api"} > 0.05
```

---

## Subqueries

Evaluate a query over a range at fixed resolution, then apply outer function.

### Syntax

```promql
<instant_query>[<range>:<resolution>]
```

### Examples

```promql
# Max of 5m rate, computed every 1m, over the last 1h
max_over_time(rate(http_requests_total[5m])[1h:1m])

# Average P99 latency over the last day, sampled every 5m
avg_over_time(
  histogram_quantile(0.99, sum by (le) (rate(http_duration_bucket[5m])))[1d:5m]
)

# Smoothed CPU usage — average of 5m rate over 1h window
avg_over_time(rate(node_cpu_seconds_total{mode="idle"}[5m])[1h:5m])

# How many times did error rate exceed 5% in the last 24h?
count_over_time((job:http_errors:ratio5m > 0.05)[24h:5m])
```

### Performance considerations

- Subqueries are expensive — each evaluation computes the inner query
- Use recording rules instead when the inner query is complex
- Resolution `:1m` means 60 evaluations per hour — keep reasonable
- Omitting resolution (e.g., `[1h:]`) uses default evaluation step

---

## PromQL Patterns and Recipes

### RED method (Rate, Errors, Duration)

```promql
# Rate
sum by (service) (rate(http_requests_total[5m]))

# Errors (as ratio)
sum by (service) (rate(http_requests_total{status=~"5.."}[5m]))
/ sum by (service) (rate(http_requests_total[5m]))

# Duration (P99)
histogram_quantile(0.99, sum by (service, le) (rate(http_duration_bucket[5m])))
```

### USE method (Utilization, Saturation, Errors)

```promql
# CPU Utilization
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))

# CPU Saturation (load average / CPU count)
node_load1 / count without (cpu) (node_cpu_seconds_total{mode="idle"})

# Disk Errors
rate(node_disk_io_errors_total[5m])
```

### Percentage calculations

```promql
# Percentage of total
sum by (status) (rate(http_requests_total[5m]))
/ ignoring(status) group_left sum(rate(http_requests_total[5m]))
* 100

# Memory usage percentage
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
```

### Counter resets detection

```promql
# Number of counter resets in the last hour
resets(http_requests_total[1h])

# Changes in a gauge metric
changes(up[1h])
```

### Absent/dead metrics

```promql
# Returns 1 if metric is absent
absent(up{job="api"})

# Returns vector of missing label combinations
absent_notseries(up{job="api", instance=~".+"})

# Useful in alerting: "is this target down?"
absent(up{job="critical-service"} == 1)
```

### Label manipulation

```promql
# Rename a label
label_replace(up, "service", "$1", "job", "(.*)")

# Join label — static string
label_join(up, "combined", "-", "job", "instance")
```

---

## LogQL Fundamentals

LogQL has two modes:
1. **Log queries** — return log lines (for log panels)
2. **Metric queries** — return numeric values computed from logs (for time series panels)

### Query structure

```
{stream_selectors} | line_filters | parser | label_filters | line_format | ...
```

Each `|` is a pipeline stage. Stages execute left-to-right. Filter early to reduce processing.

---

## LogQL Stream Selectors

Stream selectors choose which log streams to query. They match on Loki labels (set during ingestion).

```logql
# Exact match
{app="api", env="production"}

# Regex match
{app=~"api|gateway", namespace=~"prod-.*"}

# Negation
{app="api", level!="debug"}
{app!~"test-.*"}
```

**Performance rule**: At least one label matcher must use `=` or `=~` without `.*` prefix. Loki indexes labels, not log content — label filters determine which chunks to scan.

---

## LogQL Filter Expressions

### Line filters (text search on raw log line)

| Operator | Description | Example |
|----------|-------------|---------|
| `\|=` | Contains | `{app="api"} \|= "error"` |
| `!=` | Not contains | `{app="api"} != "healthcheck"` |
| `\|~` | Regex match | `{app="api"} \|~ "status=[45]\\d{2}"` |
| `!~` | Not regex | `{app="api"} !~ "DEBUG\|TRACE"` |

Chain for AND logic:

```logql
{app="api"} |= "error" != "healthcheck" |= "timeout"
```

### Label filters (after parsing)

```logql
{app="api"} | json | status >= 500
{app="api"} | json | method = "POST" and path =~ "/api/v2/.*"
{app="api"} | json | duration > 1s    # Duration comparison
{app="api"} | json | bytes > 1kb      # Size comparison
```

Supported operators: `=`, `!=`, `=~`, `!~`, `>`, `>=`, `<`, `<=`

Units recognized: duration (`ns`, `us`, `ms`, `s`, `m`, `h`), bytes (`b`, `kb`, `mb`, `gb`, `tb`)

---

## LogQL Parsers

### JSON parser

```logql
{app="api"} | json

# Extract specific fields only (faster)
{app="api"} | json level="level", msg="message", dur="response.duration"

# Log line: {"level":"error","message":"timeout","response":{"duration":2.5}}
# Extracted labels: level=error, msg=timeout, dur=2.5
```

### Logfmt parser

```logql
{app="api"} | logfmt

# Log line: level=error method=POST path=/api/users duration=2.5s
# Extracted labels: level=error, method=POST, path=/api/users, duration=2.5s
```

### Regex parser

```logql
{app="nginx"} | regexp `(?P<ip>\S+) \S+ \S+ \[(?P<timestamp>[^\]]+)\] "(?P<method>\S+) (?P<path>\S+) \S+" (?P<status>\d+) (?P<size>\d+)`
```

### Pattern parser (simpler than regex)

```logql
{app="nginx"} | pattern `<ip> - - [<_>] "<method> <path> <_>" <status> <size>`

# <_> captures and discards (unnamed)
# <name> captures as label
```

### Unpack parser

For JSON-in-JSON or packed log formats:

```logql
{app="api"} | unpack
```

### Parser chaining

```logql
{app="api"} | json | line_format "{{.message}}" | logfmt
```

Parse outer JSON, extract message field, then parse the message as logfmt.

---

## LogQL Metrics from Logs

### Metric query functions

| Function | Description | Example |
|----------|-------------|---------|
| `count_over_time` | Count log lines | `count_over_time({app="api"} \|= "error" [5m])` |
| `rate` | Lines per second | `rate({app="api"} \|= "error" [5m])` |
| `bytes_over_time` | Total bytes | `bytes_over_time({app="api"}[5m])` |
| `bytes_rate` | Bytes per second | `bytes_rate({app="api"}[5m])` |
| `sum_over_time` | Sum extracted values | `sum_over_time({app="api"} \| json \| unwrap duration [5m])` |
| `avg_over_time` | Average extracted values | `avg_over_time({app="api"} \| json \| unwrap duration [5m])` |
| `max_over_time` | Max extracted values | `max_over_time({app="api"} \| json \| unwrap size [5m])` |
| `min_over_time` | Min extracted values | `min_over_time(...)` |
| `first_over_time` | First value in window | `first_over_time(...)` |
| `last_over_time` | Last value in window | `last_over_time(...)` |
| `stddev_over_time` | Std deviation | `stddev_over_time(...)` |
| `quantile_over_time` | Quantile of extracted values | `quantile_over_time(0.99, {app="api"} \| json \| unwrap duration [5m])` |
| `absent_over_time` | Returns empty vector if no logs | `absent_over_time({app="api"} [5m])` |

### unwrap for numeric values

Extract a numeric label for aggregation:

```logql
# Average response time from JSON logs
avg_over_time(
  {app="api"} | json | unwrap response_time | __error__="" [5m]
) by (method)

# P99 response time from logs
quantile_over_time(0.99,
  {app="api"} | json | unwrap duration | __error__="" [5m]
) by (endpoint)
```

`| __error__=""` filters out lines where parsing/unwrap failed — essential for clean metrics.

### Aggregation with metric queries

```logql
# Error rate by service
sum by (service) (rate({env="production"} |= "error" [5m]))

# Top 5 noisiest services
topk(5, sum by (app) (rate({env="production"}[5m])))

# Error ratio
sum(rate({app="api"} |= "error" [5m])) / sum(rate({app="api"}[5m]))
```

---

## LogQL Pattern Matching

### IP address extraction

```logql
{app="nginx"} | pattern `<ip> - - [<_>] "<method> <path> <_>" <status> <size>`
| ip != "127.0.0.1"
| status >= 400
| line_format "{{.ip}} {{.method}} {{.path}} → {{.status}}"
```

### Multi-line log handling

Loki treats each push entry as one log line. For multi-line (e.g., stack traces), configure at ingestion:

```yaml
# Promtail config
scrape_configs:
  - job_name: java
    pipeline_stages:
      - multiline:
          firstline: '^\d{4}-\d{2}-\d{2}'
          max_wait_time: 3s
```

### line_format for output reshaping

```logql
{app="api"} | json
| line_format "{{.timestamp}} [{{.level | ToUpper}}] {{.method}} {{.path}} → {{.status}} ({{.duration}}ms)"
```

Template functions: `ToUpper`, `ToLower`, `Replace`, `Trim`, `Trunc`, `Contains`, `HasPrefix`, `HasSuffix`, `regexReplaceAll`.

### decolorize

Strip ANSI color codes from log lines:

```logql
{app="api"} | decolorize
```

---

## TraceQL Basics

TraceQL queries traces stored in Tempo. Queries operate on **spans**.

### Span attribute selectors

```
# Service name
{ resource.service.name = "checkout" }

# HTTP method and status
{ span.http.method = "POST" && span.http.status_code >= 500 }

# Duration filter
{ duration > 2s }

# Status
{ status = error }

# Span name
{ name = "HTTP GET /api/users" }
```

### Structural operators

```
# Parent-child relationship
{ resource.service.name = "gateway" } >> { resource.service.name = "api" }

# Direct parent-child
{ resource.service.name = "gateway" } > { resource.service.name = "api" }

# Sibling spans
{ resource.service.name = "api" } ~ { resource.service.name = "cache" }

# Unscoped: any span in trace matches
{ resource.service.name = "checkout" && span.http.status_code = 500 }
```

### Aggregate functions

```
# Traces where total duration > 5s
{ } | count() > 10

# Traces with >5 error spans
{ status = error } | count() > 5

# Traces where max span duration > 2s
{ } | max(duration) > 2s

# Average span duration in trace > 500ms
{ } | avg(duration) > 500ms
```

### Use in Grafana

- **Explore → Tempo**: Run TraceQL queries interactively
- **Traces panel**: Display trace waterfall
- **TraceQL metrics** (experimental): Time series from trace data
  ```
  { resource.service.name = "api" } | rate()
  { status = error } | rate() by (resource.service.name)
  ```

---

## SQL Queries for Database Sources

### Grafana SQL macros

| Macro | PostgreSQL expansion | MySQL expansion |
|-------|---------------------|-----------------|
| `$__timeFilter(col)` | `col BETWEEN '...' AND '...'` | `col BETWEEN '...' AND '...'` |
| `$__timeFrom()` | Start of time range | Start of time range |
| `$__timeTo()` | End of time range | End of time range |
| `$__timeGroup(col, interval)` | `date_trunc(interval, col)` | `UNIX_TIMESTAMP(col) DIV interval * interval` |
| `$__timeGroup(col, interval, NULL)` | Same with NULL fill | Same with NULL fill |
| `$__unixEpochFilter(col)` | `col >= epoch AND col <= epoch` | Same |
| `$__unixEpochGroup(col, interval)` | `floor(col/interval)*interval` | Same |

### Time series query format

```sql
-- Required columns: time (datetime), value (numeric), optional metric (string)
SELECT
  $__timeGroup(created_at, '$__interval') AS time,
  count(*) AS value,
  status AS metric
FROM orders
WHERE $__timeFilter(created_at)
GROUP BY time, status
ORDER BY time
```

### Table query format

```sql
-- Any column structure; no time column required
SELECT
  user_id,
  email,
  created_at,
  order_count,
  total_revenue
FROM user_summary
WHERE region = '$region'
ORDER BY total_revenue DESC
LIMIT 100
```

### Variable queries (PostgreSQL)

```sql
-- For template variable of type "query" with PostgreSQL data source
SELECT DISTINCT region FROM orders ORDER BY region;

-- Dependent variable
SELECT DISTINCT city FROM orders WHERE region = '$region' ORDER BY city;
```

### Alerts with SQL

```sql
-- Returns single value for threshold evaluation
SELECT count(*) AS value
FROM failed_jobs
WHERE created_at > now() - interval '5 minutes'
  AND status = 'failed'
```

---

## Flux for InfluxDB

Flux is the query language for InfluxDB 2.x. Used when Grafana connects to InfluxDB with Flux query language.

### Basic query structure

```flux
from(bucket: "metrics")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r["_measurement"] == "http_requests")
  |> filter(fn: (r) => r["_field"] == "count")
  |> filter(fn: (r) => r["host"] =~ /prod-.*/)
  |> aggregateWindow(every: v.windowPeriod, fn: sum, createEmpty: false)
  |> yield(name: "requests")
```

### Grafana Flux variables

| Variable | Description |
|----------|-------------|
| `v.timeRangeStart` | Dashboard time range start |
| `v.timeRangeStop` | Dashboard time range stop |
| `v.windowPeriod` | Auto-calculated window period |
| `v.defaultBucket` | Default bucket from data source config |
| `v.organization` | Organization from data source config |

### Common patterns

```flux
// Rate of change (derivative)
from(bucket: "metrics")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r["_measurement"] == "http_requests")
  |> derivative(unit: 1s, nonNegative: true)

// Percentile
from(bucket: "metrics")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r["_measurement"] == "response_time")
  |> aggregateWindow(every: v.windowPeriod, fn: (tables=<-, column) =>
    tables |> quantile(q: 0.99, column: column), createEmpty: false)

// Join two measurements
requests = from(bucket: "metrics")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r["_measurement"] == "requests")
  |> aggregateWindow(every: v.windowPeriod, fn: sum)

errors = from(bucket: "metrics")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r["_measurement"] == "errors")
  |> aggregateWindow(every: v.windowPeriod, fn: sum)

join(tables: {requests: requests, errors: errors}, on: ["_time", "host"])
  |> map(fn: (r) => ({r with _value: r._value_errors / r._value_requests * 100.0}))

// Conditional alert value
from(bucket: "metrics")
  |> range(start: -5m)
  |> filter(fn: (r) => r["_measurement"] == "queue_depth")
  |> last()
  |> map(fn: (r) => ({r with alert: if r._value > 1000 then "critical" else "ok"}))
```

### Template variables with Flux

```flux
// For Grafana variable query
import "influxdata/influxdb/schema"
schema.tagValues(bucket: "metrics", tag: "host")

// Filtered by another variable
from(bucket: "metrics")
  |> range(start: -1h)
  |> filter(fn: (r) => r["host"] == "${host}")
  |> aggregateWindow(every: v.windowPeriod, fn: mean)
```
