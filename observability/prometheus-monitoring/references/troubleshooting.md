# Prometheus Troubleshooting Guide

Diagnosing and resolving common Prometheus operational issues.

## Table of Contents

- [High Cardinality](#high-cardinality)
- [OOM Crashes](#oom-crashes)
- [Slow Queries](#slow-queries)
- [Scrape Failures](#scrape-failures)
- [Timestamp Alignment Issues](#timestamp-alignment-issues)
- [Staleness Handling](#staleness-handling)
- [WAL Corruption Recovery](#wal-corruption-recovery)
- [Alertmanager Routing Not Matching](#alertmanager-routing-not-matching)
- [Duplicate Alerts](#duplicate-alerts)
- [Federation Issues](#federation-issues)
- [Remote Write Backpressure](#remote-write-backpressure)
- [Rule Evaluation Problems](#rule-evaluation-problems)
- [TSDB Compaction Issues](#tsdb-compaction-issues)
- [Diagnostic Queries and Commands](#diagnostic-queries-and-commands)

---

## High Cardinality

### Symptoms
- `prometheus_tsdb_head_series` growing unboundedly
- Increasing memory usage over time
- Slower query responses
- Alert: `PrometheusHighCardinality`

### Root causes

1. **Unbounded label values** — labels like `user_id`, `request_id`, `trace_id`, `url_path` (with path params not normalized)
2. **Dynamic label explosion** — container IDs, pod UIDs that change on every restart
3. **Too many label combinations** — `method × endpoint × status × instance` multiplying
4. **Misconfigured service discovery** — scraping more targets than intended
5. **Exporters exposing unbounded metrics** — e.g., per-query SQL metrics

### Diagnosis

```promql
# Total active series
prometheus_tsdb_head_series

# Series created per second (high = churn)
rate(prometheus_tsdb_head_series_created_total[5m])

# Highest-cardinality metrics
topk(10, count by (__name__) ({__name__=~".+"}))

# Series per job (find the culprit)
count({__name__=~".+"}) by (job)
```

Use the TSDB status API:

```bash
# Top 10 series by metric name
curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:10]'

# Top 10 label-value pairs by cardinality
curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.labelValueCountByLabelName[:10]'

# Top 10 label-value pairs contributing most series
curl -s http://localhost:9090/api/v1/status/tsdb | jq '.data.memoryInBytesByLabelName[:10]'
```

### Fixes

1. **Drop high-cardinality labels at ingestion** with `metric_relabel_configs`:
   ```yaml
   metric_relabel_configs:
     - source_labels: [__name__]
       regex: "expensive_metric_.*"
       action: drop
     - regex: "request_id|trace_id|user_id"
       action: labeldrop
   ```

2. **Normalize URL paths** in application code before exposing metrics:
   ```
   /users/12345 → /users/{id}
   ```

3. **Limit label values** in client instrumentation to known bounded sets

4. **Reduce scrape targets** — use `relabel_configs` to filter:
   ```yaml
   relabel_configs:
     - source_labels: [__meta_kubernetes_namespace]
       regex: "test|dev"
       action: drop
   ```

5. **Set sample/series limits per scrape**:
   ```yaml
   scrape_configs:
     - job_name: 'suspect-app'
       sample_limit: 10000
       series_limit: 5000
   ```

---

## OOM Crashes

### Symptoms
- Prometheus process killed by OOM killer
- `dmesg` shows: `Out of memory: Killed process ... (prometheus)`
- Container restarts with exit code 137

### Root causes
1. Too many active time series (cardinality)
2. Too many samples in WAL (long scrape intervals with high cardinality)
3. Large queries loading too much data
4. TSDB head block too large
5. Insufficient memory for the workload

### Diagnosis

```bash
# Check OOM kills
dmesg | grep -i "oom\|killed process"

# Current memory usage
curl -s http://localhost:9090/api/v1/status/runtimeinfo | jq '.data'

# Check prometheus metrics about memory
curl -s http://localhost:9090/api/v1/query?query=process_resident_memory_bytes | jq
```

```promql
# Memory usage
process_resident_memory_bytes{job="prometheus"}

# Series count (main memory driver)
prometheus_tsdb_head_series

# Chunks in memory
prometheus_tsdb_head_chunks

# WAL size
prometheus_tsdb_wal_storage_size_bytes
```

### Fixes

1. **Increase memory** — rule of thumb: ~3KB per active time series
   - 1M series ≈ 3GB memory (minimum)
   - Add 50% headroom for queries and GC

2. **Reduce cardinality** (see [High Cardinality](#high-cardinality))

3. **Limit query concurrency**:
   ```
   --query.max-concurrency=10
   --query.max-samples=50000000
   ```

4. **Set GOGC for Go garbage collector**:
   ```
   GOGC=70  # More aggressive GC (default 100)
   ```

5. **Use WAL compression**:
   ```
   --storage.tsdb.wal-compression
   ```

6. **Reduce retention** to lower TSDB size:
   ```
   --storage.tsdb.retention.time=15d
   --storage.tsdb.retention.size=30GB
   ```

7. **Use remote write** to offload long-term storage, keep local retention low

---

## Slow Queries

### Symptoms
- Dashboard panels timing out
- `prometheus_engine_query_duration_seconds` high
- Alert rule evaluation taking too long
- API responses with HTTP 503 or timeouts

### Root causes
1. Queries touching too many series
2. Long range windows (`[30d]`)
3. Expensive subqueries
4. Missing recording rules
5. Regex label matchers scanning all series
6. `topk`/`bottomk` on large datasets

### Diagnosis

```promql
# Slow rule evaluations
prometheus_rule_evaluation_duration_seconds{quantile="0.99"}

# Rule group missed evaluations
prometheus_rule_group_iterations_missed_total

# Query durations
prometheus_engine_query_duration_seconds{quantile="0.99"}

# Queries in flight
prometheus_engine_queries
```

```bash
# Enable query logging
# Add to prometheus.yml or CLI flag
# --query.log-file=/prometheus/query.log

# Check the query log for slow queries
grep "duration" /prometheus/query.log | sort -t= -k2 -rn | head -20
```

### Fixes

1. **Create recording rules** for frequently used aggregations
2. **Narrow time ranges** — `[5m]` instead of `[1h]` where possible
3. **Add label matchers** — always filter by `job` or `namespace` first
4. **Increase query timeout**:
   ```
   --query.timeout=2m
   ```
5. **Limit query samples**:
   ```
   --query.max-samples=50000000
   ```
6. **Use Grafana's `$__rate_interval`** instead of hardcoded ranges
7. **Avoid `{__name__=~".+"}`** — full series scan
8. **Pre-aggregate** before feeding to `topk`/`bottomk`

---

## Scrape Failures

### Symptoms
- `up == 0` for targets
- Gaps in metric data
- `scrape_duration_seconds` unusually high
- Targets show as DOWN in the Prometheus UI `/targets` page

### Root causes
1. Target is down or not exposing `/metrics`
2. Network issues (DNS, firewall, timeout)
3. Authentication failures
4. TLS certificate issues
5. Scrape timeout too low
6. Target returning invalid metrics format
7. Service discovery misconfiguration

### Diagnosis

```promql
# Which targets are down?
up == 0

# Scrape duration (slow targets)
scrape_duration_seconds > 10

# Samples scraped (sudden drops indicate problems)
scrape_samples_scraped

# Sample limit exceeded
scrape_samples_post_metric_relabeling > 9900  # if limit is 10000

# Scrape errors
prometheus_target_scrape_pool_exceeded_target_limit_total
prometheus_target_scrapes_exceeded_sample_limit_total
```

Check Prometheus UI:
- Navigate to **Status → Targets** (`/targets`)
- Look for error messages on failed targets
- Check **Last Scrape** and **Scrape Duration**

```bash
# Manually test the metrics endpoint
curl -v http://target:port/metrics

# Test with auth
curl -u user:pass http://target:port/metrics

# Test TLS
curl --cacert ca.pem --cert client.pem --key client-key.pem https://target:port/metrics

# Check DNS resolution
dig target-hostname
nslookup target-hostname

# Check connectivity
nc -zv target-hostname port
```

### Fixes

1. **Increase scrape timeout**:
   ```yaml
   scrape_configs:
     - job_name: 'slow-target'
       scrape_timeout: 30s  # default is 10s
   ```

2. **Fix TLS configuration**:
   ```yaml
   tls_config:
     ca_file: /etc/prometheus/ca.pem
     cert_file: /etc/prometheus/client.pem
     key_file: /etc/prometheus/client-key.pem
     insecure_skip_verify: false  # only true for testing
   ```

3. **Fix authentication**:
   ```yaml
   basic_auth:
     username: prometheus
     password_file: /etc/prometheus/password
   # or
   bearer_token_file: /etc/prometheus/token
   # or
   authorization:
     type: Bearer
     credentials_file: /etc/prometheus/token
   ```

4. **Validate service discovery labels** — use Prometheus UI **Service Discovery** page to see raw discovered labels before relabeling

5. **Check relabel_configs** — an overly aggressive `drop` action may be filtering all targets:
   ```yaml
   # Debug: temporarily change action to keep and check /targets
   relabel_configs:
     - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
       action: keep
       regex: true
   ```

---

## Timestamp Alignment Issues

### Symptoms
- Unexpected query results (missing data points)
- Jagged or stepped graphs instead of smooth lines
- `rate()` returning 0 or unexpectedly large values at interval boundaries
- Discrepancies between different Prometheus instances querying the same targets

### Root causes
1. Different `scrape_interval` across jobs
2. Targets exposing metrics with custom timestamps
3. Clock skew between Prometheus and targets
4. Federation introducing timestamp offsets
5. Remote read returning data with different alignment

### Explanation

Prometheus aligns all scraped samples to the time of the scrape, not the time reported by the target. When querying:
- **Instant queries** evaluate at a specific timestamp and use the closest sample within the 5-minute lookback window (staleness period)
- **Range queries** step through time at the `step` interval and evaluate at each step

### Fixes

1. **Standardize scrape intervals** across similar jobs
2. **Avoid custom timestamps** in exposition — let Prometheus assign scrape time:
   ```
   # Do NOT include timestamps in /metrics output unless you know why
   my_metric 42.0         # ← correct (Prometheus adds timestamp)
   my_metric 42.0 163000  # ← avoid (overrides Prometheus timestamp)
   ```
3. **Sync clocks** — run NTP on all hosts:
   ```bash
   timedatectl status
   chronyc tracking
   ```
4. **Use `timestamp()` function** to debug sample timing:
   ```promql
   timestamp(up{job="api"}) - time()  # should be small negative number
   ```

---

## Staleness Handling

### Symptoms
- Series remain visible in queries after a target stops being scraped
- `absent()` doesn't fire immediately when a metric disappears
- Graphs show flat lines extending past the last real data point
- "Stale" NaN values in query results

### How staleness works

- Prometheus marks a series as stale 5 minutes after the last scrape
- When a target is removed from scrape config, a **stale marker** (special NaN) is injected at the next evaluation
- When a metric disappears from a target's `/metrics` response, a stale marker is injected
- During lookback, stale markers cause the series to "not exist" — queries won't see it

### Common problems

1. **Series persists after target removal** — normal for up to 5 minutes (staleness window)
2. **absent() delayed** — `absent()` checks instant vector at evaluation time; series stays "present" during lookback window
3. **Rate spikes at staleness boundary** — `rate()` may produce unexpected values if the last sample is a stale marker

### Fixes

1. **Use `absent_over_time()` for more reliable absence detection**:
   ```promql
   # More reliable than absent() — checks entire window
   absent_over_time(up{job="api"}[10m])
   ```

2. **Set appropriate `for` duration in alerts** to survive staleness:
   ```yaml
   - alert: TargetDown
     expr: up == 0
     for: 5m  # at least as long as staleness window
   ```

3. **Understand lookback delta** — can be changed (rarely needed):
   ```
   --query.lookback-delta=5m  # default
   ```

4. **Clean up removed series** — they disappear after TSDB compaction, but remain queryable for retention period

---

## WAL Corruption Recovery

### Symptoms
- Prometheus fails to start with WAL-related errors
- Log messages: `err="invalid checksum"`, `err="unexpected EOF"`, `msg="WAL segment corrupt"`
- Crash loop on startup

### Root causes
1. Ungraceful shutdown (power loss, kill -9, OOM kill)
2. Disk full during WAL write
3. Filesystem corruption
4. Storage hardware failure

### Recovery steps

```bash
# 1. Stop Prometheus
systemctl stop prometheus

# 2. Back up the data directory
cp -r /prometheus/data /prometheus/data.bak

# 3. Try to repair WAL
# Option A: Remove the WAL and let Prometheus rebuild from the last checkpoint
rm -rf /prometheus/data/wal

# Option B: Use promtool to inspect and repair
promtool tsdb analyze /prometheus/data
promtool tsdb list /prometheus/data

# 4. If there are corrupt blocks, remove them
# Check for blocks with issues
ls -la /prometheus/data/
# Remove corrupt block directories (format: 01XXXX...)
rm -rf /prometheus/data/01CORRUPT_BLOCK_ID

# 5. Restart Prometheus
systemctl start prometheus

# 6. Monitor startup logs
journalctl -u prometheus -f
```

### Prevention

1. **Use WAL compression** — reduces disk usage and write amplification:
   ```
   --storage.tsdb.wal-compression
   ```

2. **Ensure graceful shutdown** — send SIGTERM, not SIGKILL:
   ```yaml
   # Docker Compose
   stop_grace_period: 5m
   ```

3. **Monitor disk space** — never let the Prometheus data volume fill up:
   ```promql
   (node_filesystem_avail_bytes{mountpoint="/prometheus"} / node_filesystem_size_bytes{mountpoint="/prometheus"}) < 0.1
   ```

4. **Use reliable storage** — SSDs recommended, avoid network-attached storage for WAL

5. **Set retention size limit** as a safety valve:
   ```
   --storage.tsdb.retention.size=50GB
   ```

---

## Alertmanager Routing Not Matching

### Symptoms
- Alerts going to the wrong receiver
- Alerts not being sent at all
- All alerts falling through to the default receiver
- Expected routing not working after config change

### Root causes
1. Route matching is a **tree**, evaluated top-down with first match wins (unless `continue: true`)
2. Label matchers are case-sensitive
3. `match` uses exact matching; `match_re` uses regex
4. Child routes inherit parent's matchers and settings
5. Missing `continue: true` when alerts should match multiple routes

### Diagnosis

```bash
# Validate config
amtool check-config alertmanager.yml

# Test routing for a specific alert
amtool config routes test --config.file=alertmanager.yml \
  severity=critical service=payment-api

# Show full routing tree
amtool config routes show --config.file=alertmanager.yml

# Check active alerts in Alertmanager
curl -s http://localhost:9093/api/v2/alerts | jq '.[].labels'

# Check which receiver would handle an alert
curl -s http://localhost:9093/api/v2/alerts | jq '.[].receivers'
```

### Common mistakes and fixes

**Mistake 1: Match order wrong**
```yaml
route:
  routes:
    # This catches everything — routes below never match
    - match_re:
        severity: ".*"
      receiver: catch-all
    - match:
        severity: critical
      receiver: pagerduty  # never reached!

# Fix: put specific routes first
route:
  routes:
    - match:
        severity: critical
      receiver: pagerduty
    - match_re:
        severity: ".*"
      receiver: catch-all
```

**Mistake 2: Forgetting continue**
```yaml
# Alert goes to pagerduty only, not also to slack
route:
  routes:
    - match:
        severity: critical
      receiver: pagerduty
      # continue: true  ← add this to also match next route
    - match:
        severity: critical
      receiver: slack-critical
```

**Mistake 3: Label value mismatch**
```yaml
# Won't match if alert has severity="Critical" (capital C)
- match:
    severity: critical  # case-sensitive!
```

**Mistake 4: Child route inheriting parent match**
```yaml
route:
  match:
    team: platform
  routes:
    # This route requires BOTH team=platform AND severity=critical
    - match:
        severity: critical
      receiver: pagerduty
```

### Testing routing

Always test with `amtool` before deploying:

```bash
# Install amtool
# (comes with alertmanager binary)

# Test a specific alert's routing
echo '{"labels":{"alertname":"HighErrorRate","severity":"critical","service":"api"}}' | \
  amtool config routes test --config.file=alertmanager.yml

# Verify all expected routes
amtool config routes show --config.file=alertmanager.yml --verify.receivers=pagerduty
```

---

## Duplicate Alerts

### Symptoms
- Same alert notification sent multiple times
- Multiple Alertmanager instances sending the same notification
- Alert appears in multiple receiver channels

### Root causes
1. Multiple Prometheus instances evaluating the same rules without HA dedup
2. Alertmanager cluster not properly configured
3. `continue: true` on routes causing intentional multi-receiver delivery (misunderstood)
4. Alert with different label values appearing as separate alerts but representing the same issue

### Fixes

**1. Configure Alertmanager clustering:**
```yaml
# All Alertmanager instances must know about each other
# Start each instance with:
alertmanager --cluster.listen-address=0.0.0.0:9094 \
  --cluster.peer=alertmanager-1:9094 \
  --cluster.peer=alertmanager-2:9094
```

**2. Use `group_by` to deduplicate:**
```yaml
route:
  group_by: ['alertname', 'cluster', 'service']
  # Alerts with same alertname+cluster+service are grouped into one notification
```

**3. Use `external_labels` to differentiate Prometheus instances:**
```yaml
# prometheus.yml on each instance
global:
  external_labels:
    replica: prometheus-1  # unique per replica

# Alertmanager deduplicates alerts from different replicas
# using all labels EXCEPT external_labels
```

**4. Remove unintended `continue: true`:**
```yaml
routes:
  - match:
      severity: critical
    receiver: pagerduty
    continue: false  # stop matching after this route
```

**5. Use inhibition rules** to suppress related alerts:
```yaml
inhibit_rules:
  - source_match:
      severity: critical
    target_match:
      severity: warning
    equal: ['alertname', 'instance']
```

---

## Federation Issues

### Symptoms
- Missing metrics in global Prometheus
- Duplicated data in federated queries
- High latency on federation scrapes
- Federation endpoint timing out

### Root causes
1. Federating too many series (raw metrics instead of recording rules)
2. `honor_labels: true` not set (labels get overwritten)
3. Match parameters too broad
4. Network latency between Prometheus instances
5. Scrape interval mismatch between federation and source

### Diagnosis

```promql
# On the global Prometheus — check federation scrape health
up{job="federate"}

# Federation scrape duration
scrape_duration_seconds{job="federate"}

# Samples scraped from federation
scrape_samples_scraped{job="federate"}
```

```bash
# Manually test federation endpoint
curl -G http://regional-prometheus:9090/federate \
  --data-urlencode 'match[]={job=~".+"}' | head -50

# Check how many series the match returns
curl -G http://regional-prometheus:9090/federate \
  --data-urlencode 'match[]={__name__=~"job:.*"}' | wc -l
```

### Fixes

**1. Federate only recording rules and aggregates:**
```yaml
# On global Prometheus
scrape_configs:
  - job_name: 'federate'
    honor_labels: true
    metrics_path: '/federate'
    params:
      'match[]':
        - '{__name__=~"job:.*"}'        # recording rules only
        - '{__name__=~".*:.*:.*"}'      # level:metric:operations pattern
    static_configs:
      - targets: ['prometheus-us:9090', 'prometheus-eu:9090']
```

**2. Always use `honor_labels: true`** — otherwise the global Prometheus overwrites `job` and `instance` labels.

**3. Increase federation scrape timeout:**
```yaml
- job_name: 'federate'
  scrape_interval: 60s    # longer interval for federation
  scrape_timeout: 55s     # close to interval
```

**4. Create recording rules on leaf Prometheus** instances to pre-aggregate:
```yaml
# On regional Prometheus
groups:
  - name: federation_rules
    rules:
      - record: region:http_requests:rate5m
        expr: sum(rate(http_requests_total[5m])) by (region, service)
```

**5. Use remote write instead of federation** for large-scale deployments — push model is more reliable and scalable.

---

## Remote Write Backpressure

### Symptoms
- `prometheus_remote_storage_samples_pending` growing
- `prometheus_remote_storage_samples_failed_total` increasing
- WAL size growing (data queued but not sent)
- Memory pressure from undelivered samples
- Log messages: `Dropped samples`, `queue full`

### Root causes
1. Remote endpoint too slow or unreachable
2. Insufficient shard count for throughput
3. Network bandwidth saturation
4. Remote storage rate limiting
5. Batch size too large for endpoint

### Diagnosis

```promql
# Pending samples (growing = backpressure)
prometheus_remote_storage_samples_pending

# Failed sends
rate(prometheus_remote_storage_samples_failed_total[5m])

# Successful sends
rate(prometheus_remote_storage_samples_total[5m])

# Bytes sent rate
rate(prometheus_remote_storage_bytes_total[5m])

# Current shard count
prometheus_remote_storage_shards

# Max shard count
prometheus_remote_storage_shards_max

# Remote write duration
prometheus_remote_storage_sent_batch_duration_seconds{quantile="0.99"}

# WAL watcher lag (how far behind the WAL reader is)
prometheus_remote_storage_highest_timestamp_in_seconds
  - prometheus_remote_storage_queue_highest_sent_timestamp_seconds
```

### Fixes

**1. Tune queue configuration:**
```yaml
remote_write:
  - url: "https://remote-storage:9090/api/v1/write"
    queue_config:
      capacity: 10000           # buffer size per shard
      max_shards: 50            # increase for more throughput
      min_shards: 1
      max_samples_per_send: 2000  # reduce if endpoint has size limits
      batch_send_deadline: 5s
      min_backoff: 30ms
      max_backoff: 5s
      retry_on_http_429: true   # retry on rate limit
```

**2. Use write relabeling to reduce volume:**
```yaml
remote_write:
  - url: "https://remote-storage:9090/api/v1/write"
    write_relabel_configs:
      # Only send specific metrics
      - source_labels: [__name__]
        regex: "job:.*|node_.*|up"
        action: keep
      # Drop debug metrics
      - source_labels: [__name__]
        regex: "go_.*|promhttp_.*"
        action: drop
```

**3. Enable compression:**
```yaml
remote_write:
  - url: "https://remote-storage:9090/api/v1/write"
    # Snappy compression is default — ensure endpoint supports it
```

**4. Monitor and alert on backpressure:**
```yaml
- alert: RemoteWriteBackpressure
  expr: prometheus_remote_storage_samples_pending > 10000
  for: 15m
  labels:
    severity: warning
  annotations:
    summary: "Remote write falling behind"
```

---

## Rule Evaluation Problems

### Symptoms
- `prometheus_rule_group_iterations_missed_total` increasing
- Stale recording rule data
- Alerts not firing when expected
- `prometheus_rule_evaluation_failures_total` increasing

### Diagnosis

```promql
# Missed evaluations
rate(prometheus_rule_group_iterations_missed_total[5m])

# Evaluation duration per group
prometheus_rule_evaluation_duration_seconds{quantile="0.99"}

# Evaluation failures
rate(prometheus_rule_evaluation_failures_total[5m])

# Rule group last evaluation timestamp
prometheus_rule_group_last_evaluation_timestamp_seconds

# Rules count
prometheus_rule_group_rules
```

### Fixes

1. **Split large rule groups** — each group is evaluated sequentially:
   ```yaml
   # BAD: one huge group
   groups:
     - name: all_rules
       rules:  # 200 rules, evaluated sequentially

   # GOOD: split by domain
   groups:
     - name: http_rules
       rules:  # 20 rules
     - name: node_rules
       rules:  # 15 rules
   ```

2. **Increase evaluation interval for slow rules:**
   ```yaml
   groups:
     - name: expensive_rules
       interval: 60s  # default is global evaluation_interval (usually 15s)
       rules:
         - record: job:expensive_metric:rate5m
           expr: ...
   ```

3. **Use recording rules** to simplify alert expressions — chain recording rules instead of nesting complex queries

4. **Validate rules** before deploying:
   ```bash
   promtool check rules rules/*.yml
   ```

---

## TSDB Compaction Issues

### Symptoms
- Disk usage not decreasing after reducing retention
- Large gaps between block timestamps
- `prometheus_tsdb_compactions_failed_total` increasing
- Slow startup from excessive blocks

### Diagnosis

```bash
# List all TSDB blocks
promtool tsdb list /prometheus/data

# Analyze TSDB for issues
promtool tsdb analyze /prometheus/data

# Check block metadata
cat /prometheus/data/01BLOCK_ID/meta.json | jq
```

```promql
# Compaction failures
prometheus_tsdb_compactions_failed_total

# Time spent in compaction
prometheus_tsdb_compaction_duration_seconds

# Number of blocks
prometheus_tsdb_blocks_loaded
```

### Fixes

1. **Remove tombstones** (after deleting series via API):
   ```bash
   # Trigger a compaction to clean up deleted data
   curl -X POST http://localhost:9090/api/v1/admin/tsdb/clean_tombstones
   ```

2. **Delete corrupt blocks manually:**
   ```bash
   # Identify bad blocks
   promtool tsdb analyze /prometheus/data 2>&1 | grep -i error

   # Remove the corrupt block directory
   rm -rf /prometheus/data/01BAD_BLOCK_ID
   ```

3. **Increase minimum block duration** for fewer blocks:
   ```
   --storage.tsdb.min-block-duration=2h  # default
   --storage.tsdb.max-block-duration=48h
   ```

---

## Diagnostic Queries and Commands

### Essential diagnostic PromQL

```promql
# --- TSDB Health ---
prometheus_tsdb_head_series                                    # active series count
prometheus_tsdb_head_chunks                                    # chunks in memory
prometheus_tsdb_head_samples_appended_total                    # sample ingestion rate
prometheus_tsdb_compactions_failed_total                       # compaction failures
prometheus_tsdb_wal_storage_size_bytes                         # WAL size

# --- Scrape Health ---
up                                                             # target health
scrape_duration_seconds                                        # scrape latency
scrape_samples_scraped                                         # samples per scrape
prometheus_target_scrapes_exceeded_sample_limit_total           # sample limits hit
prometheus_sd_discovered_targets                                # discovered targets

# --- Rule Evaluation ---
prometheus_rule_evaluation_duration_seconds                     # rule eval time
prometheus_rule_group_iterations_missed_total                   # missed evaluations
prometheus_rule_evaluation_failures_total                       # eval failures

# --- Alerting ---
prometheus_notifications_total                                  # notifications sent
prometheus_notifications_dropped_total                          # notifications dropped
prometheus_alertmanager_notifications_failed_total              # failed notifications
ALERTS{alertstate="firing"}                                    # currently firing alerts

# --- Remote Write ---
prometheus_remote_storage_samples_pending                       # queue depth
prometheus_remote_storage_samples_failed_total                  # send failures
prometheus_remote_storage_shards                                # active shards

# --- Resources ---
process_resident_memory_bytes                                   # memory usage
process_cpu_seconds_total                                       # CPU usage
prometheus_engine_queries                                       # concurrent queries
```

### Essential CLI commands

```bash
# Validate configuration
promtool check config prometheus.yml

# Validate rules
promtool check rules rules/*.yml

# Test PromQL expression
promtool query instant http://localhost:9090 'up'

# Query range
promtool query range http://localhost:9090 'rate(http_requests_total[5m])' \
  --start='2024-01-01T00:00:00Z' --end='2024-01-01T01:00:00Z' --step=60s

# TSDB analysis
promtool tsdb analyze /prometheus/data
promtool tsdb list /prometheus/data

# Alertmanager config validation
amtool check-config alertmanager.yml

# Test alert routing
amtool config routes test --config.file=alertmanager.yml severity=critical

# Hot reload configuration
curl -X POST http://localhost:9090/-/reload
curl -X POST http://localhost:9093/-/reload

# Check runtime info
curl -s http://localhost:9090/api/v1/status/runtimeinfo | jq
curl -s http://localhost:9090/api/v1/status/config | jq
curl -s http://localhost:9090/api/v1/status/flags | jq
curl -s http://localhost:9090/api/v1/status/tsdb | jq

# Snapshot for backup
curl -X POST http://localhost:9090/api/v1/admin/tsdb/snapshot
```
