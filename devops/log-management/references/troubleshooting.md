# Log System Troubleshooting Guide

> Diagnosis and resolution for common logging infrastructure problems: Elasticsearch performance, Loki query issues, Fluent Bit backpressure, log loss, timestamp parsing, multiline handling, high-cardinality labels, and storage planning.

## Table of Contents

- [Elasticsearch Performance Issues](#elasticsearch-performance-issues)
  - [Shard Sizing](#shard-sizing)
  - [Mapping Explosions](#mapping-explosions)
  - [JVM Tuning](#jvm-tuning)
  - [Slow Queries](#slow-queries)
  - [Cluster Health Diagnostics](#cluster-health-diagnostics)
- [Loki Query Optimization](#loki-query-optimization)
- [Fluent Bit Backpressure Handling](#fluent-bit-backpressure-handling)
- [Log Loss Diagnosis](#log-loss-diagnosis)
- [Timestamp Parsing Issues](#timestamp-parsing-issues)
- [Multiline Log Handling](#multiline-log-handling)
- [High-Cardinality Label Problems](#high-cardinality-label-problems)
- [Storage Capacity Planning](#storage-capacity-planning)

---

## Elasticsearch Performance Issues

### Shard Sizing

**Symptoms:** Slow queries, high memory usage, cluster instability, unassigned shards.

**Root cause:** Too many small shards (over-sharding) or too few large shards.

**Guidelines:**

| Metric | Target | Why |
|--------|--------|-----|
| Shard size | 10–50 GB | Balances query speed and recovery time |
| Shards per node | < 20 per GB heap | Each shard consumes ~1 MB heap + file handles |
| Total shards per node | < 600 | Beyond this, cluster state becomes expensive |
| Shards per index | 1 per 50 GB data | Start with 1, increase only when needed |

**Calculating shard count:**
```
target_shards = ceil(expected_index_size_gb / 30)
# Example: 200 GB index → ceil(200/30) = 7 shards
```

**Fix over-sharding (too many small indices):**
```json
// Use ILM rollover instead of daily indices
PUT _ilm/policy/logs-policy
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_size": "30gb",
            "max_age": "7d"
          }
        }
      }
    }
  }
}
```

**Merge small shards:**
```bash
# Force merge read-only indices to 1 segment
POST /logs-2024.01.*/_forcemerge?max_num_segments=1

# Shrink index to fewer shards
POST /logs-old/_shrink/logs-old-shrunk
{
  "settings": { "index.number_of_shards": 1 }
}
```

**Monitoring:**
```bash
# Check shard sizes
GET _cat/shards?v&s=store:desc&h=index,shard,prirep,state,docs,store

# Count shards per node
GET _cat/allocation?v

# Find oversized indices
GET _cat/indices?v&s=store.size:desc&h=index,docs.count,store.size,pri
```

### Mapping Explosions

**Symptoms:** `IllegalArgumentException: Limit of total fields [1000] has been exceeded`, high memory, slow indexing.

**Root cause:** Dynamic mapping + inconsistent log fields creating thousands of unique field names.

**Diagnosis:**
```bash
# Count fields in an index mapping
GET /logs-*/_mapping | jq '[.. | .properties? // empty | keys[]] | length'

# Find indices with most fields
GET _cat/indices?v&h=index,docs.count,store.size
# Then check each mapping for field count
```

**Solutions:**

1. **Disable dynamic mapping for unknown fields:**
```json
PUT _index_template/logs-template
{
  "index_patterns": ["logs-*"],
  "template": {
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "@timestamp": { "type": "date" },
        "level": { "type": "keyword" },
        "message": { "type": "text" },
        "service": { "type": "keyword" },
        "trace_id": { "type": "keyword" }
      }
    }
  }
}
```

2. **Use `flattened` type for arbitrary key-value data:**
```json
{
  "mappings": {
    "properties": {
      "labels": { "type": "flattened" },
      "metadata": { "type": "flattened" }
    }
  }
}
```

3. **Set field limits:**
```json
{
  "settings": {
    "index.mapping.total_fields.limit": 2000,
    "index.mapping.depth.limit": 5,
    "index.mapping.nested_fields.limit": 25
  }
}
```

4. **Fix at source:** Standardize log fields in the application; don't log arbitrary user input as top-level fields.

### JVM Tuning

**Key settings (`jvm.options`):**

```bash
# Heap: set to 50% of RAM, max 31 GB (compressed oops threshold)
-Xms16g
-Xmx16g

# Use G1GC for heaps > 6 GB
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
-XX:G1HeapRegionSize=16m
-XX:InitiatingHeapOccupancyPercent=45

# GC logging for diagnosis
-Xlog:gc*,gc+age=trace,safepoint:file=/var/log/elasticsearch/gc.log:utctime,pid,tags:filecount=32,filesize=64m
```

**Diagnosis checklist:**

| Issue | Check | Fix |
|-------|-------|-----|
| OOM kills | `dmesg \| grep -i oom` | Reduce heap or add nodes |
| Long GC pauses | GC logs: pauses > 500ms | Switch to G1GC, reduce heap pressure |
| High heap usage | `GET _nodes/stats/jvm` — heap > 85% | Add nodes, reduce shard count, disable field data caching |
| Swap usage | `GET _nodes/stats/os` — swap > 0 | Disable swap: `bootstrap.memory_lock: true` |

```bash
# Check JVM heap usage
GET _nodes/stats/jvm?filter_path=nodes.*.jvm.mem

# Monitor GC metrics
GET _nodes/stats/jvm?filter_path=nodes.*.jvm.gc

# Verify memory lock
GET _nodes?filter_path=nodes.*.process.mlockall
```

**Critical settings (`elasticsearch.yml`):**
```yaml
bootstrap.memory_lock: true
# In /etc/security/limits.conf:
# elasticsearch soft memlock unlimited
# elasticsearch hard memlock unlimited

# In systemd unit override:
# LimitMEMLOCK=infinity
```

### Slow Queries

**Diagnosis:**
```bash
# Enable slow query log
PUT /logs-*/_settings
{
  "index.search.slowlog.threshold.query.warn": "5s",
  "index.search.slowlog.threshold.query.info": "2s",
  "index.search.slowlog.threshold.fetch.warn": "1s"
}

# Check hot threads
GET _nodes/hot_threads

# Profile a specific query
POST /logs-*/_search
{
  "profile": true,
  "query": { "match": { "message": "timeout" } }
}
```

**Common fixes:**
- Add `keyword` subfield for fields used in aggregations (avoid fielddata on `text`)
- Use `filter` context instead of `query` for non-scoring clauses (cached)
- Limit time range in queries — always add `@timestamp` range filter
- Use `index.sort.field` on `@timestamp` for time-series data

### Cluster Health Diagnostics

```bash
# Quick health check
GET _cluster/health?pretty

# Unassigned shards diagnosis
GET _cluster/allocation/explain

# Disk watermarks (default: 85% warn, 90% read-only, 95% flood)
GET _cluster/settings?include_defaults&filter_path=*.cluster.routing.allocation.disk

# Fix read-only indices (disk watermark triggered)
PUT _all/_settings
{ "index.blocks.read_only_allow_delete": null }

# Node-level diagnostics
GET _cat/nodes?v&h=name,heap.percent,ram.percent,cpu,disk.used_percent,node.role
```

---

## Loki Query Optimization

### LogQL Performance Tips

**1. Always use label matchers first (indexed):**
```logql
# GOOD — labels narrow the search first
{namespace="production", service="api"} | json | level="error"

# BAD — scans all streams, then filters
{job=~".+"} | json | service="api" | level="error"
```

**2. Prefer `|=` (contains) over `|~` (regex) for simple string matches:**
```logql
# GOOD — fast substring match
{service="api"} |= "timeout"

# SLOWER — regex engine overhead
{service="api"} |~ ".*timeout.*"
```

**3. Restrict time ranges:**
```logql
# Query only the last hour, not the last week
{service="api"} |= "error" | json  # with short time picker
```

**4. Use `line_format` to reduce output:**
```logql
{service="api"} | json | level="error"
  | line_format "{{.timestamp}} {{.message}} trace={{.trace_id}}"
```

**5. Use `unwrap` for numeric operations:**
```logql
# P95 latency
quantile_over_time(0.95,
  {service="api"} | json | unwrap duration_ms [$__interval]
) by (endpoint)
```

**6. Limit concurrent queries** — configure in `loki.yaml`:
```yaml
query_scheduler:
  max_outstanding_requests_per_tenant: 2048

limits_config:
  max_query_parallelism: 32
  max_query_series: 5000
  max_entries_limit_per_query: 10000
  query_timeout: 5m
```

### Common Loki Issues

| Issue | Symptom | Fix |
|-------|---------|-----|
| Query timeout | "context deadline exceeded" | Shorten time range, add label matchers |
| Too many streams | "too many outstanding requests" | Reduce label cardinality |
| Missing logs | Logs visible in source but not Loki | Check Promtail/agent targets, timestamp parsing |
| Out of order | "entry out of order" | Set `unordered_writes: true` in Loki config |

---

## Fluent Bit Backpressure Handling

### Symptoms
- `[warn] [input] paused (mem buf overlimit)` in Fluent Bit logs
- OOM kills of Fluent Bit process
- Log gaps during high-volume spikes

### Configuration

```ini
[SERVICE]
    Flush        5
    Log_Level    info
    # Enable filesystem buffering (critical for production)
    storage.path              /var/log/flb-storage/
    storage.sync              normal
    storage.checksum          off
    storage.max_chunks_up     128
    storage.backlog.mem_limit 10M

[INPUT]
    Name              tail
    Path              /var/log/containers/*.log
    Tag               kube.*
    # Per-input memory buffer limit
    Mem_Buf_Limit     50MB
    # Use filesystem storage for overflow
    storage.type      filesystem
    Skip_Long_Lines   On
    Refresh_Interval  10

[OUTPUT]
    Name              es
    Match             *
    Host              elasticsearch
    Port              9200
    # Retry failed flushes
    Retry_Limit       5
    # Workers for parallel output
    Workers           2
    # Bulk size
    Buffer_Size       5MB
```

### Monitoring Fluent Bit

```ini
# Enable Prometheus metrics endpoint
[INPUT]
    Name   fluentbit_metrics
    Tag    internal_metrics

[OUTPUT]
    Name   prometheus_exporter
    Match  internal_metrics
    Host   0.0.0.0
    Port   2021
```

Key metrics to alert on:
- `fluentbit_input_bytes_total` — ingestion rate
- `fluentbit_output_retries_total` — downstream problems
- `fluentbit_output_errors_total` — data loss risk
- `fluentbit_input_paused` — backpressure active

---

## Log Loss Diagnosis

### Diagnosis Flowchart

```
Logs missing?
├── Are logs written to disk? → Check app log config, permissions, disk space
├── Is collector running? → Check systemd status, OOM kills, restarts
│   ├── Collector OOM → Increase Mem_Buf_Limit or add filesystem buffering
│   └── Collector crash-loop → Check config syntax, input permissions
├── Is collector shipping? → Check output connectivity, auth, TLS
│   ├── Network issue → Test curl to output endpoint
│   └── Auth failure → Verify credentials, certificates
├── Is backend receiving? → Check backend ingest metrics
│   ├── Rejected → Check mapping conflicts, field type errors
│   └── Throttled → Check rate limits, increase capacity
└── Can you query them? → Check index patterns, time range, filters
    ├── Wrong time → Timestamp parsing issue (see below)
    └── Wrong index → Check index template routing
```

### Common Loss Points

| Point | Cause | Prevention |
|-------|-------|------------|
| App → Disk | Container stdout buffer overflow | Write to file + stdout |
| Disk → Collector | Collector not tailing new files | Check `Refresh_Interval`, glob patterns |
| Collector buffer | Memory-only buffer under spike | Use `storage.type filesystem` |
| Collector → Backend | Network partition, backend down | Enable retries, persistent queue |
| Backend ingest | Mapping conflict, full disk | Monitor ingest errors, disk watermarks |
| Backend query | Wrong time range due to clock skew | Sync NTP, use `@timestamp` vs ingest time |

### Verification Commands

```bash
# Count logs at source
wc -l /var/log/app/app.log

# Count in Elasticsearch
curl -s "es:9200/logs-*/_count" | jq .count

# Compare rates
# In Grafana: overlay input rate vs output rate from Fluent Bit metrics

# Check Fluent Bit internal status
curl -s http://localhost:2020/api/v1/metrics/prometheus | grep -E "input|output"
```

---

## Timestamp Parsing Issues

### Common Problems

| Problem | Example | Fix |
|---------|---------|-----|
| No timezone | `2024-03-24 12:34:56` | Assume UTC or configure timezone in parser |
| Mixed formats | ISO8601 + epoch + custom | Normalize at collector with multiple date patterns |
| Clock skew | Server 5 min ahead | Deploy NTP/chrony, use `@timestamp` from log |
| Future timestamps | Log from 2025 arriving now | Reject logs with timestamp > now + 5m |
| Epoch ambiguity | `1711234567` — seconds or ms? | Check digit count: 10=sec, 13=ms, 16=µs, 19=ns |

### Logstash Date Patterns

```ruby
filter {
  date {
    match => ["timestamp",
      "ISO8601",                              # 2024-03-24T12:34:56.789Z
      "yyyy-MM-dd HH:mm:ss.SSS",            # 2024-03-24 12:34:56.789
      "dd/MMM/yyyy:HH:mm:ss Z",             # 24/Mar/2024:12:34:56 +0000 (CLF)
      "UNIX",                                 # 1711234567
      "UNIX_MS"                               # 1711234567000
    ]
    target => "@timestamp"
    timezone => "UTC"
  }
}
```

### Fluent Bit Parser Examples

```ini
[PARSER]
    Name         json_iso
    Format       json
    Time_Key     timestamp
    Time_Format  %Y-%m-%dT%H:%M:%S.%LZ
    Time_Keep    On

[PARSER]
    Name         apache_clf
    Format       regex
    Regex        ^(?<host>[^ ]*) [^ ]* (?<user>[^ ]*) \[(?<time>[^\]]*)\] "(?<method>\S+)(?: +(?<path>[^\"]*?)(?: +\S*)?)?" (?<code>[^ ]*) (?<size>[^ ]*)
    Time_Key     time
    Time_Format  %d/%b/%Y:%H:%M:%S %z

[PARSER]
    Name         syslog_rfc3164
    Format       regex
    Regex        ^\<(?<pri>[0-9]+)\>(?<time>[^ ]* {1,2}[^ ]* [^ ]*) (?<host>[^ ]*) (?<ident>[a-zA-Z0-9_\/\.\-]*)(?:\[(?<pid>[0-9]+)\])?(?:[^\:]*\:)? *(?<message>.*)$
    Time_Key     time
    Time_Format  %b %d %H:%M:%S
```

### Clock Sync Verification

```bash
# Check NTP sync status
timedatectl status
chronyc tracking
ntpstat

# Compare container clock to host
docker exec myapp date -u
date -u

# Find clock skew in logs
# Look for logs arriving with future timestamps
curl -s "es:9200/logs-*/_search" -H 'Content-Type: application/json' -d '{
  "query": { "range": { "@timestamp": { "gt": "now+1m" } } },
  "size": 5
}'
```

---

## Multiline Log Handling

### The Problem

Stack traces and multi-line messages get split into separate log entries:
```
2024-03-24 12:34:56 ERROR NullPointerException: user is null    ← entry 1
    at com.app.UserService.getUser(UserService.java:42)          ← entry 2 (orphaned)
    at com.app.ApiHandler.handle(ApiHandler.java:15)             ← entry 3 (orphaned)
```

### Fluent Bit Multiline Parser

```ini
[MULTILINE_PARSER]
    name          java_stacktrace
    type          regex
    # First line starts with timestamp
    rule          "start_state"  "/^\d{4}-\d{2}-\d{2}/"  "cont"
    # Continuation: starts with whitespace, "at", or "Caused by"
    rule          "cont"         "/^(\s+at |Caused by:|\s+\.\.\.|\s)/"  "cont"

[MULTILINE_PARSER]
    name          python_traceback
    type          regex
    rule          "start_state"  "/^Traceback/"                         "python_tb"
    rule          "python_tb"    "/^\s+File/"                           "python_tb"
    rule          "python_tb"    "/^\S/"                                "end"

[INPUT]
    Name              tail
    Path              /var/log/app/*.log
    multiline.parser  java_stacktrace
    Tag               app.*
```

### Docker/Kubernetes Multiline

Docker splits logs at 16KB boundaries and newlines. Solutions:

```yaml
# Promtail pipeline stages for multiline
scrape_configs:
  - pipeline_stages:
      - multiline:
          firstline: '^\d{4}-\d{2}-\d{2}'
          max_wait_time: 3s
          max_lines: 128
```

```ini
# Fluent Bit Docker multiline
[INPUT]
    Name              tail
    Path              /var/log/containers/*.log
    Parser            cri
    multiline.parser  docker, cri
    # Use built-in docker/CRI multiline parsers
```

### Testing Multiline Config

```bash
# Test with sample file
echo '2024-03-24 12:34:56 ERROR Something broke
    at com.app.Service.run(Service.java:42)
    at com.app.Main.main(Main.java:10)
2024-03-24 12:34:57 INFO Next normal log' > /tmp/test-multiline.log

# Run Fluent Bit in dry-run
fluent-bit -i tail -p path=/tmp/test-multiline.log \
  -p multiline.parser=java_stacktrace \
  -o stdout -f 1
# Should output 2 records, not 4
```

---

## High-Cardinality Label Problems

### What Is High Cardinality?

Labels with many unique values (user IDs, request IDs, IP addresses) create an explosion of streams/time series.

| Cardinality | Example | Impact |
|-------------|---------|--------|
| Low (< 100) | `env`, `region`, `service` | ✅ Good label |
| Medium (100–1K) | `endpoint`, `status_code` | ⚠️ Acceptable with caution |
| High (> 1K) | `user_id`, `request_id`, `trace_id` | ❌ Never use as label |

### Symptoms

**Loki:**
- `too many outstanding requests`
- `max streams limit exceeded`
- Memory growth proportional to unique label combinations
- Ingester OOM crashes

**Prometheus / metrics:**
- `too many time series` errors
- Slow queries on dashboards
- High memory on Prometheus/Thanos

### Diagnosis

```bash
# Loki — count active streams
curl -s http://loki:3100/metrics | grep loki_ingester_streams_created_total

# Loki — find high-cardinality labels
logcli series '{job="app"}' --analyze-labels

# Prometheus — count series per metric
curl -s http://prometheus:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:10]'

# Elasticsearch — find high-cardinality fields
GET /logs-*/_search
{
  "size": 0,
  "aggs": {
    "unique_fields": {
      "cardinality": { "field": "user_id.keyword" }
    }
  }
}
```

### Solutions

1. **Move high-cardinality data to structured fields** (not labels):
```yaml
# BAD — Promtail creating label per user
pipeline_stages:
  - labels:
      user_id:  # Creates stream per user!

# GOOD — keep as structured field, query with | json
pipeline_stages:
  - json:
      expressions:
        user_id: user_id
  # Don't add user_id to labels
```

2. **Drop or hash problematic labels:**
```yaml
# Promtail — drop high-cardinality labels
pipeline_stages:
  - labeldrop:
      - request_id
      - trace_id
      - client_ip
```

3. **Aggregate before storage:**
```yaml
# OTEL Collector — group by low-cardinality attributes only
processors:
  groupbyattrs:
    keys:
      - service.name
      - http.method
      - http.status_code
```

---

## Storage Capacity Planning

### Estimation Formula

```
Daily storage = Log lines/day × Average line size (bytes)
Monthly raw   = Daily storage × 30
With replicas = Monthly raw × (1 + replica_count)
With overhead = With replicas × 1.15  (15% indexing overhead for ES)
With compression = With overhead × compression_ratio

Total = With compression × retention_months
```

### Example Calculation

| Parameter | Value |
|-----------|-------|
| Log lines per day | 500 million |
| Average line size | 500 bytes |
| Daily raw volume | 250 GB |
| Replicas | 1 (total 2 copies) |
| Retention hot | 14 days |
| Retention warm | 90 days |
| ES index overhead | 15% |
| Compression (warm) | 50% |

```
Hot tier:   250 GB × 2 copies × 14 days × 1.15 = 8,050 GB ≈ 8 TB
Warm tier:  250 GB × 1 copy  × 76 days × 1.15 × 0.5 = 10,925 GB ≈ 11 TB
Cold (S3):  250 GB × 90 days × 0.1 (high compression) = 2,250 GB ≈ 2.3 TB
Total:      ~21.3 TB
```

### Cost Estimation (2024 Approximate)

| Tier | Storage Type | Cost per GB/Month | 20 TB Cost/Month |
|------|-------------|-------------------|-------------------|
| Hot (ES SSD) | NVMe/SSD | $0.20–0.30 | $4,000–6,000 |
| Warm (ES HDD) | HDD | $0.05–0.10 | $1,000–2,000 |
| Cold (S3) | Object storage | $0.01–0.02 | $200–400 |
| Managed (Elastic Cloud) | Managed | $0.25–0.40 | $5,000–8,000 |
| Loki (S3-backed) | S3 + compute | $0.02–0.05 | $400–1,000 |

### Capacity Monitoring

```bash
# Elasticsearch disk usage
GET _cat/allocation?v&h=node,disk.used,disk.avail,disk.percent

# Index sizes over time
GET _cat/indices?v&s=store.size:desc&h=index,docs.count,store.size

# Predict growth (Prometheus query for ES metrics)
predict_linear(
  elasticsearch_indices_store_size_bytes_total[7d], 30*24*3600
)
```

### Alerts

```yaml
# Alert when disk hits 70%
- alert: ElasticsearchDiskHigh
  expr: elasticsearch_filesystem_data_used_percent > 70
  for: 10m
  labels: { severity: warning }
  annotations:
    summary: "ES disk usage {{ $value }}% on {{ $labels.name }}"

# Alert when daily ingest exceeds plan
- alert: LogIngestSpike
  expr: rate(elasticsearch_indices_indexing_index_total[1h]) * 3600 > 50000000
  for: 30m
  labels: { severity: warning }
```
