# PromQL Cookbook

A deep reference for PromQL — Prometheus's functional query language for selecting, aggregating, and transforming time series data.

## Table of Contents

- [Selectors and Matchers](#selectors-and-matchers)
- [Range Vectors and Instant Vectors](#range-vectors-and-instant-vectors)
- [Rate vs irate vs increase](#rate-vs-irate-vs-increase)
- [Aggregation Operators](#aggregation-operators)
- [Vector Matching](#vector-matching)
- [Subqueries](#subqueries)
- [histogram_quantile Patterns](#histogram_quantile-patterns)
- [label_replace and label_join](#label_replace-and-label_join)
- [absent and absent_over_time](#absent-and-absent_over_time)
- [Common Anti-Patterns](#common-anti-patterns)
- [Query Optimization](#query-optimization)
- [Ready-Made Queries: CPU](#ready-made-queries-cpu)
- [Ready-Made Queries: Memory](#ready-made-queries-memory)
- [Ready-Made Queries: Disk](#ready-made-queries-disk)
- [Ready-Made Queries: Network](#ready-made-queries-network)
- [Ready-Made Queries: HTTP](#ready-made-queries-http)
- [Advanced Patterns](#advanced-patterns)

---

## Selectors and Matchers

### Instant vector selectors

Select the latest sample for each matching time series:

```promql
# Exact label match
http_requests_total{job="api-server", method="GET"}

# Regex match (RE2 syntax)
http_requests_total{status=~"5.."}

# Negative exact match
http_requests_total{method!="OPTIONS"}

# Negative regex match
http_requests_total{status!~"2.."}

# Multiple matchers (AND logic — all must match)
http_requests_total{job="api-server", status=~"5..", method!="OPTIONS"}
```

### Range vector selectors

Select all samples within a time window:

```promql
# Last 5 minutes of data
http_requests_total{job="api-server"}[5m]

# Valid duration units: ms, s, m, h, d, w, y
http_requests_total[30s]
http_requests_total[2h]
http_requests_total[7d]
```

### Offset modifier

Query historical data:

```promql
# Value 1 hour ago
http_requests_total offset 1h

# Rate 1 day ago (useful for week-over-week comparisons)
rate(http_requests_total[5m] offset 1d)

# Compare current to previous day
rate(http_requests_total[5m]) / rate(http_requests_total[5m] offset 1d)
```

### @ modifier

Pin evaluation to a specific Unix timestamp:

```promql
# Value at a specific time
http_requests_total @ 1609459200

# Combine with offset
http_requests_total @ 1609459200 offset 5m
```

---

## Range Vectors and Instant Vectors

Understanding the distinction is critical:

- **Instant vector**: One sample per series at query evaluation time. Used for display, aggregation, arithmetic.
- **Range vector**: Multiple samples per series over a time window. Used as input to functions like `rate()`, `avg_over_time()`, `quantile_over_time()`.

Range vectors **cannot** be graphed directly — they must be passed through a function that returns an instant vector.

### Over-time functions

Apply to range vectors to produce instant vectors:

```promql
# Average value over last 1 hour
avg_over_time(node_cpu_seconds_total{mode="idle"}[1h])

# Maximum value in last 24 hours
max_over_time(node_memory_MemAvailable_bytes[24h])

# Minimum over window
min_over_time(up[5m])

# Count of samples in window
count_over_time(http_requests_total[1h])

# Standard deviation
stddev_over_time(http_request_duration_seconds_sum[1h])

# Last value in the window (useful with subqueries)
last_over_time(up[5m])

# Present (1) if any samples exist in window
present_over_time(up[5m])

# Quantile over time (0.95 = P95)
quantile_over_time(0.95, http_request_duration_seconds[1h])
```

---

## Rate vs irate vs increase

### rate()

Per-second average rate of increase over the entire range window. Handles counter resets.

```promql
rate(http_requests_total[5m])
```

**Rules:**
- Range must be ≥ 4× scrape interval (e.g., `[5m]` for 15s scrape interval) to handle missed scrapes
- Returns per-second value — multiply by duration for total: `rate(x[5m]) * 300`
- Best for dashboards and alerting — produces smooth graphs
- Handles counter resets automatically (detects value decrease)

### irate()

Instant rate — uses only the last two data points in the range window.

```promql
irate(http_requests_total[5m])
```

**Rules:**
- The range window is only used to find the last two samples — a wider window is more tolerant of missed scrapes
- Very responsive to short spikes but volatile
- **Not suitable for alerting** — can miss sustained issues between the two samples
- Use for volatile, real-time dashboards where spikes matter

### increase()

Total increase over the range window. Semantically identical to `rate() * window_seconds`.

```promql
increase(http_requests_total[1h])
```

**Rules:**
- Extrapolates to cover the full window — may return non-integer values even for integer counters
- Handles counter resets
- Use when you want "total count in the last hour" semantics

### When to use which

| Use Case | Function | Why |
|----------|----------|-----|
| Dashboard panels | `rate()` | Smooth, reliable |
| Alerting rules | `rate()` | Stable, handles missed scrapes |
| Real-time spikes | `irate()` | Instant responsiveness |
| "Total in last hour" | `increase()` | Human-readable totals |
| SLO error budget | `increase()` or `rate()` | Depending on window |

---

## Aggregation Operators

### Basic aggregations

```promql
# Sum across all series
sum(rate(http_requests_total[5m]))

# By — keep specified labels, aggregate the rest
sum(rate(http_requests_total[5m])) by (job, method)

# Without — aggregate away specified labels, keep the rest
sum(rate(http_requests_total[5m])) without (instance, pod)

# Count unique series
count(up) by (job)

# Average
avg(node_cpu_seconds_total{mode="idle"}) by (instance)

# Min / Max
min(node_filesystem_avail_bytes) by (instance)
max(node_memory_MemTotal_bytes) by (instance)

# Standard deviation / variance
stddev(rate(http_request_duration_seconds_sum[5m])) by (service)
stdvar(rate(http_request_duration_seconds_sum[5m])) by (service)
```

### TopK / BottomK

```promql
# Top 10 series by request rate
topk(10, sum(rate(http_requests_total[5m])) by (endpoint))

# Bottom 5 by available memory
bottomk(5, node_memory_MemAvailable_bytes)
```

**Warning:** `topk` and `bottomk` return different series at different times — they're unstable for dashboards. Use in consoles or one-off queries.

### count_values

Group series by their value:

```promql
# Count how many instances are on each Go version
count_values("go_version", go_info)
```

### group

Returns 1 for each unique label combination (useful for existence checks):

```promql
group(up) by (job)
```

### Quantile aggregation

```promql
# Median across instances
quantile(0.5, rate(http_requests_total[5m])) by (job)
```

---

## Vector Matching

Vector matching controls how binary operations and functions match elements from two instant vectors.

### One-to-one matching

Default: vectors are matched on all shared label names.

```promql
# Divide errors by total — works if both sides have identical label sets
rate(http_requests_total{status=~"5.."}[5m])
  / rate(http_requests_total[5m])
```

### on / ignoring keywords

**`on(labels)`** — match only on specified labels:

```promql
# Match error count to total only on 'method' label
sum(rate(http_requests_total{status=~"5.."}[5m])) by (method)
  / on(method)
sum(rate(http_requests_total[5m])) by (method)
```

**`ignoring(labels)`** — match on all labels except specified ones:

```promql
# Ignore the 'status' label for matching
rate(http_requests_total{status="500"}[5m])
  / ignoring(status)
rate(http_requests_total[5m])
```

### group_left / group_right (many-to-one / one-to-many)

When one side has higher cardinality:

```promql
# Many-to-one: many error series per method, one total per method
sum(rate(http_requests_total{status=~"5.."}[5m])) by (method, endpoint)
  / on(method) group_left
sum(rate(http_requests_total[5m])) by (method)
```

- `group_left` — the LEFT side is the "many" side (has more labels)
- `group_right` — the RIGHT side is the "many" side

### Copying labels from the "one" side

```promql
# Copy the 'team' label from the info metric to the result
rate(http_requests_total[5m])
  * on(job) group_left(team)
job_info
```

### Common vector matching pitfalls

1. **Missing labels on one side**: If a label exists only on one side, matching fails silently — no result
2. **Many-to-many**: Not supported. You'll get an error. Aggregate one side first
3. **Forgetting group_left/group_right**: Results in "many-to-many matching" errors
4. **Using `on()` with too few labels**: Accidentally aggregating away important dimensions

### Practical vector matching examples

```promql
# Error rate per service, joining with service metadata
(
  sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
  / sum(rate(http_requests_total[5m])) by (service)
)
  * on(service) group_left(team, tier)
service_info

# Node memory usage as percentage, matching filesystem and total
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)
  / node_memory_MemTotal_bytes
# Both sides share the same label set (instance, job) — no on/ignoring needed

# Disk usage percentage with device label from both sides
node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}
  - on(instance, device, mountpoint) node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}
```

---

## Subqueries

Subqueries allow applying range-vector functions to the result of an instant vector expression.

**Syntax:** `<instant_query>[<range>:<resolution>]`

```promql
# Max of the 5-minute rate, evaluated every 1 minute, over the last 1 hour
max_over_time(rate(http_requests_total[5m])[1h:1m])

# Average error rate over the last 24 hours, sampled every 5 minutes
avg_over_time(
  (sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])))[24h:5m]
)

# P99 latency spike detection — max P99 in last 1h
max_over_time(
  histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))[1h:5m]
)

# Minimum of up status over 1 hour (detect any downtime)
min_over_time(up{job="api"}[1h:1m])
```

**Resolution step:**
- If omitted, uses the global evaluation interval
- Lower resolution = more data points = more expensive query
- Use ≥ scrape interval to avoid gaps

**Performance warning:** Subqueries evaluate the inner query at each resolution step. A `[24h:1m]` subquery evaluates the inner expression 1440 times. Use recording rules for expensive inner queries.

---

## histogram_quantile Patterns

### Basic usage

```promql
# P99 latency
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
```

### Aggregated across instances

**Critical:** Always preserve the `le` label when aggregating histogram buckets.

```promql
# P95 across all instances (correct)
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))

# P95 per service (correct)
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))

# WRONG — drops le label, will error
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (service))
```

### Multiple quantiles

```promql
# Compute P50, P90, P99 separately (no single-query multi-quantile)
histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
histogram_quantile(0.90, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
```

### Average from histogram

```promql
# Mean latency from histogram
rate(http_request_duration_seconds_sum[5m])
  / rate(http_request_duration_seconds_count[5m])
```

### Bucket sizing considerations

- Quantile accuracy depends on bucket boundaries — if all requests fall in one bucket, you get poor resolution
- Default buckets: `.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10`
- Set custom buckets based on your SLOs: if P99 target is 300ms, have buckets around that range
- `histogram_quantile` interpolates linearly within buckets — results are estimates, not exact values

### Apdex score from histogram

```promql
# Apdex: satisfied < 300ms, tolerating < 1.2s
(
  sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
  +
  sum(rate(http_request_duration_seconds_bucket{le="1.2"}[5m]))
) / 2
/ sum(rate(http_request_duration_seconds_count[5m]))
```

---

## label_replace and label_join

### label_replace

Create or overwrite a label using regex on another label's value:

```promql
# Extract the port from the instance label
label_replace(up, "port", "$1", "instance", ".*:(.*)")

# Create an 'environment' label from the job name
label_replace(up, "environment", "$1", "job", "(prod|staging|dev)-.*")

# Normalize instance to just hostname (strip port)
label_replace(up, "hostname", "$1", "instance", "(.*):.*")

# Static label assignment (regex matches everything)
label_replace(up, "team", "platform", "", "")
```

**Syntax:** `label_replace(vector, dst_label, replacement, src_label, regex)`
- If regex doesn't match, the original series is returned unchanged
- Use capture groups `$1`, `$2`, etc.

### label_join

Concatenate multiple label values into a new label:

```promql
# Create "namespace/pod" label
label_join(kube_pod_info, "namespace_pod", "/", "namespace", "pod")

# Create "cluster-region" label
label_join(up, "cluster_region", "-", "cluster", "region")
```

**Syntax:** `label_join(vector, dst_label, separator, src_label_1, src_label_2, ...)`

---

## absent and absent_over_time

### absent()

Returns 1 if no time series match the selector. Returns empty if series exist.

```promql
# Alert when the metric disappears entirely
absent(up{job="critical-service"})

# Alert when a specific instance stops reporting
absent(node_cpu_seconds_total{instance="prod-db-01:9100"})

# Use in alerting rules
- alert: CriticalServiceMissing
  expr: absent(up{job="payment-service"})
  for: 5m
  annotations:
    summary: "No metrics from payment-service"
```

**Important:** `absent()` preserves known label values from the selector in the result. If `job="api"` is in the selector, the result has `{job="api"}`.

### absent_over_time()

Returns 1 if no samples existed in the specified time range:

```promql
# No data at all in the last 15 minutes
absent_over_time(up{job="api"}[15m])

# Detect gaps in metric reporting
absent_over_time(node_memory_MemAvailable_bytes{instance="db-01:9100"}[10m])
```

**Use cases:**
- Detecting dead targets that were removed from scrape config (won't show `up == 0`)
- Detecting metrics that stopped being exposed by an application
- More reliable than `absent()` which only checks the latest evaluation

---

## Common Anti-Patterns

### 1. Using rate() on a gauge

```promql
# WRONG — rate on a gauge produces meaningless results
rate(node_memory_MemAvailable_bytes[5m])

# CORRECT — use deriv() for gauge rate of change
deriv(node_memory_MemAvailable_bytes[5m])

# Or use delta() for absolute change
delta(node_memory_MemAvailable_bytes[1h])
```

### 2. rate() with too short a range

```promql
# WRONG — with 15s scrape interval, may have only 1 sample
rate(http_requests_total[15s])

# CORRECT — use at least 4x scrape interval
rate(http_requests_total[1m])  # minimum for 15s interval

# BEST — use $__rate_interval in Grafana
rate(http_requests_total[$__rate_interval])
```

### 3. Aggregating histogram buckets without le

```promql
# WRONG — loses le label
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (job))

# CORRECT
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))
```

### 4. Unbounded cardinality in labels

```promql
# DANGEROUS — user_id has unbounded cardinality
http_requests_total{user_id="..."}

# BETTER — use bounded dimensions
http_requests_total{user_tier="premium"}
```

### 5. Using count() when you mean count_over_time()

```promql
# This counts unique series, not samples
count(http_requests_total)

# This counts samples in the window
count_over_time(http_requests_total[1h])
```

### 6. Not handling counter resets in raw math

```promql
# WRONG — manual subtraction breaks on counter reset
http_requests_total - http_requests_total offset 1h

# CORRECT — increase() handles resets
increase(http_requests_total[1h])
```

### 7. Comparing instant vectors with different label sets

```promql
# Silently returns empty result if labels don't match
container_memory_usage_bytes / node_memory_MemTotal_bytes

# CORRECT — use on() to specify matching labels
container_memory_usage_bytes / on(instance) node_memory_MemTotal_bytes
```

### 8. Using irate() in alerting rules

```promql
# WRONG — irate uses only 2 data points, misses sustained issues
- alert: HighRequestRate
  expr: irate(http_requests_total[5m]) > 1000

# CORRECT — rate provides stable evaluation
- alert: HighRequestRate
  expr: rate(http_requests_total[5m]) > 1000
```

---

## Query Optimization

### 1. Use recording rules for expensive queries

```yaml
# Pre-compute in a recording rule
- record: job:http_requests:rate5m
  expr: sum(rate(http_requests_total[5m])) by (job)
```

Then reference `job:http_requests:rate5m` in dashboards and alerts.

### 2. Reduce series touched with specific selectors

```promql
# SLOW — scans all series then filters
sum(rate(http_requests_total[5m])) by (job)

# FASTER — filter early
sum(rate(http_requests_total{job="api"}[5m]))
```

### 3. Avoid unnecessary label preservation

```promql
# Produces more series than needed
sum(rate(http_requests_total[5m])) by (job, instance, method, status)

# Aggregate to the level you actually need
sum(rate(http_requests_total[5m])) by (job)
```

### 4. Use smaller range windows when possible

```promql
# Touches more data
rate(http_requests_total[1h])

# Faster, sufficient for most use cases
rate(http_requests_total[5m])
```

### 5. Avoid subqueries with small resolution steps

```promql
# Very expensive — 86400 inner evaluations
max_over_time(rate(http_requests_total[5m])[24h:1s])

# Reasonable — 288 inner evaluations
max_over_time(rate(http_requests_total[5m])[24h:5m])
```

### 6. Limit topk/bottomk usage in dashboards

These re-evaluate all series at each point — use recording rules to pre-filter.

### 7. Monitor query performance

```promql
# Slow rule evaluations
prometheus_rule_evaluation_duration_seconds{quantile="0.99"} > 10

# Query engine duration
prometheus_engine_query_duration_seconds

# Total series in TSDB (cardinality indicator)
prometheus_tsdb_head_series
```

---

## Ready-Made Queries: CPU

```promql
# CPU usage percentage per instance (all modes except idle)
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# CPU usage by mode per instance
sum by (instance, mode) (rate(node_cpu_seconds_total[5m])) * 100

# CPU iowait percentage
avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[5m])) * 100

# Number of CPUs per instance
count by (instance) (node_cpu_seconds_total{mode="idle"})

# CPU saturation — load average normalized by CPU count
node_load1 / count by (instance) (node_cpu_seconds_total{mode="idle"})

# Top 5 CPU consumers (by container)
topk(5, sum by (container, pod) (rate(container_cpu_usage_seconds_total[5m])))

# CPU throttling percentage (Kubernetes)
sum by (container, pod) (rate(container_cpu_cfs_throttled_seconds_total[5m]))
  / sum by (container, pod) (rate(container_cpu_cfs_periods_total[5m])) * 100
```

---

## Ready-Made Queries: Memory

```promql
# Memory usage percentage
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# Available memory in GB
node_memory_MemAvailable_bytes / 1024 / 1024 / 1024

# Swap usage percentage
(1 - (node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes)) * 100

# Memory pressure — pages swapped in/out
rate(node_vmstat_pswpin[5m]) + rate(node_vmstat_pswpout[5m])

# OOM kill count
increase(node_vmstat_oom_kill[1h])

# Container memory usage vs limit (Kubernetes)
container_memory_working_set_bytes
  / on(container, pod, namespace) kube_pod_container_resource_limits{resource="memory"} * 100

# Top 10 memory-consuming pods
topk(10, sum by (pod, namespace) (container_memory_working_set_bytes))

# Memory leak detection — steadily increasing RSS over 6 hours
deriv(process_resident_memory_bytes[6h]) > 0
```

---

## Ready-Made Queries: Disk

```promql
# Disk usage percentage per mountpoint
(1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})) * 100

# Available disk space in GB
node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / 1024 / 1024 / 1024

# Predict disk full (linear extrapolation, 4-hour horizon)
predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 4 * 3600) < 0

# Disk I/O utilization (percentage of time spent doing I/O)
rate(node_disk_io_time_seconds_total[5m]) * 100

# Disk read/write throughput in MB/s
rate(node_disk_read_bytes_total[5m]) / 1024 / 1024
rate(node_disk_written_bytes_total[5m]) / 1024 / 1024

# Disk IOPS
rate(node_disk_reads_completed_total[5m])
rate(node_disk_writes_completed_total[5m])

# Average I/O latency per operation
rate(node_disk_read_time_seconds_total[5m]) / rate(node_disk_reads_completed_total[5m])
rate(node_disk_write_time_seconds_total[5m]) / rate(node_disk_writes_completed_total[5m])

# Inode usage percentage
(1 - (node_filesystem_files_free / node_filesystem_files)) * 100
```

---

## Ready-Made Queries: Network

```promql
# Network throughput — received/transmitted in Mbps
rate(node_network_receive_bytes_total{device!~"lo|veth.*|docker.*|br-.*"}[5m]) * 8 / 1024 / 1024
rate(node_network_transmit_bytes_total{device!~"lo|veth.*|docker.*|br-.*"}[5m]) * 8 / 1024 / 1024

# Packet rate
rate(node_network_receive_packets_total[5m])
rate(node_network_transmit_packets_total[5m])

# Network errors rate
rate(node_network_receive_errs_total[5m])
rate(node_network_transmit_errs_total[5m])

# Packet drop rate
rate(node_network_receive_drop_total[5m])
rate(node_network_transmit_drop_total[5m])

# TCP connections by state
node_netstat_Tcp_CurrEstab
node_sockstat_TCP_tw           # TIME_WAIT
node_sockstat_TCP_alloc        # allocated

# TCP retransmission rate
rate(node_netstat_TcpExt_TCPRetransFails[5m])

# Conntrack table utilization
node_nf_conntrack_entries / node_nf_conntrack_entries_limit * 100
```

---

## Ready-Made Queries: HTTP

```promql
# Request rate per service
sum(rate(http_requests_total[5m])) by (service)

# Error rate percentage (5xx)
sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
  / sum(rate(http_requests_total[5m])) by (service) * 100

# Error ratio (for SLO burn rate)
1 - (
  sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
  / sum(rate(http_requests_total[5m])) by (service)
)

# P50, P90, P99 latency
histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))
histogram_quantile(0.90, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))

# Average request duration
sum(rate(http_request_duration_seconds_sum[5m])) by (service)
  / sum(rate(http_request_duration_seconds_count[5m])) by (service)

# Request rate by status code class
sum(rate(http_requests_total[5m])) by (service, status)

# Availability (non-5xx / total)
sum(rate(http_requests_total{status!~"5.."}[30m])) by (service)
  / sum(rate(http_requests_total[30m])) by (service)

# Requests in flight (if using a gauge for concurrent requests)
http_requests_in_flight

# Slow requests — percentage above SLO threshold
1 - (
  sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m])) by (service)
  / sum(rate(http_request_duration_seconds_count[5m])) by (service)
)
```

---

## Advanced Patterns

### Boolean/conditional queries

```promql
# Returns 1 or 0 per series
rate(http_requests_total[5m]) > bool 100

# Filter: keep only series above threshold
rate(http_requests_total[5m]) > 100

# Conditional selection
(up == 1) or (absent(up{job="api"}) * 0)
```

### Combining metrics from different sources

```promql
# Use "or" to merge series from multiple metrics
rate(http_requests_total{job="v1-api"}[5m])
  or
rate(grpc_server_handled_total{job="v2-api"}[5m])
```

### Delta between current and historical

```promql
# Week-over-week request rate change (percentage)
(
  sum(rate(http_requests_total[5m]))
  - sum(rate(http_requests_total[5m] offset 7d))
)
/ sum(rate(http_requests_total[5m] offset 7d)) * 100
```

### Detecting missing scrapes

```promql
# Detect gaps — scrape duration suddenly absent
absent_over_time(up{job="critical"}[2m])

# Count successful scrapes in last hour (should be ~240 for 15s interval)
count_over_time(up{job="critical"}[1h])
```

### Clamp and math functions

```promql
# Clamp value to 0-100 range
clamp(cpu_usage_percent, 0, 100)

# Clamp minimum (floor at 0)
clamp_min(available_bytes, 0)

# Ceiling, floor, round
ceil(request_rate)
floor(request_rate)
round(request_rate, 0.1)  # round to nearest 0.1

# Absolute value
abs(deriv(temperature_celsius[1h]))

# Natural log, log2, log10
ln(http_requests_total)

# Timestamp of last sample
timestamp(up)

# Day of week (0=Sunday, for time-based queries)
day_of_week(vector(time()))
```

### Multi-metric correlation

```promql
# CPU usage correlated with request rate — detect if CPU scales linearly with load
rate(node_cpu_seconds_total{mode!="idle"}[5m])
  / on(instance) group_left
scalar(rate(http_requests_total[5m]))
```
