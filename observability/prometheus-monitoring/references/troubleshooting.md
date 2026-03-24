# Prometheus Troubleshooting Guide

## Table of Contents

- [High Cardinality Debugging](#high-cardinality-debugging)
- [Scrape Failures Diagnosis](#scrape-failures-diagnosis)
- [OOM and Storage Issues](#oom-and-storage-issues)
- [Slow Queries and Query Optimization](#slow-queries-and-query-optimization)
- [Relabeling Debugging](#relabeling-debugging)
- [Stale Time Series](#stale-time-series)
- [Metric Name Collisions](#metric-name-collisions)
- [Alertmanager Routing Debugging](#alertmanager-routing-debugging)
- [Push Gateway Pitfalls](#push-gateway-pitfalls)
- [WAL Corruption Recovery](#wal-corruption-recovery)
- [Target Discovery Problems](#target-discovery-problems)

---

## High Cardinality Debugging

### Symptoms

- Prometheus memory growing unboundedly.
- `prometheus_tsdb_head_series` climbing into millions.
- Slow query responses on broad selectors.

### Diagnosis

```bash
curl -s http://localhost:9090/api/v1/status/tsdb | jq .
```

This returns top labels by value count and top metrics by series count. Look for unbounded labels like `user_id` or `request_id`.

```promql
# Current active series
prometheus_tsdb_head_series

# Series creation churn
rate(prometheus_tsdb_head_series_created_total[5m])
```

Use the TSDB CLI for on-disk analysis:

```bash
tsdb analyze /path/to/prometheus/data
```

Identify per-job contributions:

```promql
count by (job) ({__name__=~".+"})
```

### Resolution

Drop high-cardinality labels and enforce limits:

```yaml
scrape_configs:
  - job_name: 'my-app'
    sample_limit: 5000
    metric_relabel_configs:
      - source_labels: [request_id]
        action: labeldrop
      - source_labels: [__name__]
        regex: 'debug_.*'
        action: drop
```

### Prevention

- Set `sample_limit` on all scrape configs.
- Alert on `prometheus_tsdb_head_series > 2e6`.
- Review new metrics in code review for unbounded label values.

---

## Scrape Failures Diagnosis

### Symptoms

- `up == 0` for targets; gaps in dashboards.
- Targets showing "DOWN" in the `/targets` UI.

### Diagnosis

```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health=="down")'
```

The `lastError` field reveals the cause. Test connectivity directly:

```bash
curl -v http://target-host:9100/metrics
dig target-host
```

Common errors:

| Error | Cause |
|-------|-------|
| `connection refused` | Target not running or wrong port |
| `context deadline exceeded` | Scrape timeout too short |
| `server returned HTTP status 401` | Missing authentication |
| `could not parse text` | Invalid metric format |

Validate exporter output:

```bash
curl -s http://target:9100/metrics | promtool check metrics
```

### Resolution

Increase timeout for slow targets (must be ≤ `scrape_interval`):

```yaml
scrape_configs:
  - job_name: 'slow-target'
    scrape_timeout: 30s
    scrape_interval: 60s
```

### Prevention

- Alert on `up == 0` for all jobs.
- Run `promtool check config prometheus.yml` before deploying changes.

---

## OOM and Storage Issues

### Symptoms

- OOM kills (`dmesg | grep -i oom`).
- TSDB compaction failures: `msg="compaction failed"`.
- Disk usage growing faster than expected.

### Diagnosis

```bash
ps aux | grep prometheus | grep -v grep
du -sh /path/to/prometheus/data/{,wal/,chunks_head/}
```

```promql
prometheus_tsdb_compactions_failed_total
prometheus_tsdb_head_chunks
```

```bash
curl -s http://localhost:9090/api/v1/status/flags | jq '."storage.tsdb.retention.time", ."storage.tsdb.retention.size"'
```

### Resolution

**Memory sizing:** ~2-3 bytes per active series per scrape. For 1M series, plan 4-6 GB RAM.

```bash
prometheus \
  --storage.tsdb.retention.time=15d \
  --storage.tsdb.retention.size=50GB \
  --query.max-concurrency=10
```

For corrupted blocks, remove the problematic block and restart:

```bash
grep "compaction failed" /var/log/prometheus.log
mv /path/to/prometheus/data/01BLOCK_ID /tmp/prometheus-corrupt-backup/
```

### Prevention

- Set both time and size retention limits.
- Provision at least 20% free disk headroom.
- Monitor `prometheus_tsdb_storage_blocks_bytes`.

---

## Slow Queries and Query Optimization

### Symptoms

- Dashboard panels timing out.
- `msg="Slow query detected"` in logs.
- High `prometheus_engine_query_duration_seconds`.

### Diagnosis

```bash
prometheus --query.log-file=/var/log/prometheus-queries.log
```

```bash
time curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=rate(http_requests_total[5m])' | jq '.data.result | length'
```

```promql
histogram_quantile(0.99, rate(prometheus_engine_query_duration_seconds_bucket[5m]))
```

### Resolution

Replace expensive queries with recording rules:

```yaml
groups:
  - name: aggregations
    interval: 30s
    rules:
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))
```

Set query guardrails:

```bash
prometheus --query.max-samples=50000000 --query.timeout=2m
```

**Optimization tips:**
- Always specify label matchers — avoid bare `{}`.
- Prefer `rate(x[5m])` over `rate(x[1h])` when possible.
- Use `without()` instead of `by()` when dropping fewer labels.
- Never use `{__name__=~".+"}` in dashboards.

### Prevention

- Create recording rules for any dashboard query touching 1,000+ series.
- Set `query.max-samples` and `query.timeout` as guardrails.

---

## Relabeling Debugging

### Symptoms

- Targets not appearing after adding service discovery.
- Labels missing or metrics unexpectedly dropped.

### Diagnosis

Enable debug logging:

```bash
prometheus --log.level=debug 2>&1 | grep -i "relabel"
```

Compare discovered vs active labels:

```bash
curl -s http://localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | {discoveredLabels, activeLabels: .labels}'
```

**Key pitfalls:**
- `regex` is implicitly anchored (`^...$`) — `go_` won't match `go_gc_duration_seconds`.
- `source_labels` are joined with `;` by default.
- `relabel_configs` runs before scrape; `metric_relabel_configs` runs after.

### Resolution

Fix regex anchoring:

```yaml
# WRONG — regex is fully anchored
- source_labels: [__name__]
  regex: 'go_'
  action: drop

# CORRECT
- source_labels: [__name__]
  regex: 'go_.*'
  action: drop
```

### Prevention

- Test configs with debug logging before deploying.
- Prefer `action: keep` allowlists over complex drop rules.

---

## Stale Time Series

### Symptoms

- Series showing `NaN` after target restarts.
- Gaps in graphs during rolling deployments.
- Alerts flickering during deployments.

### Diagnosis

Prometheus injects a staleness marker when a series disappears from a scrape response. After the lookback delta (default 5m), the series becomes invisible.

```bash
curl -s http://localhost:9090/api/v1/status/flags | jq '."query.lookback-delta"'
```

```promql
# Check instance churn
changes(up{job="my-app"}[1h])
```

### Resolution

Adjust lookback delta:

```bash
prometheus --query.lookback-delta=3m
```

Handle staleness in alerts with longer `for` durations:

```yaml
- alert: InstanceDown
  expr: up == 0
  for: 10m
```

Bridge gaps in queries:

```promql
my_metric or on() vector(0)
```

### Prevention

- Ensure new pods are scraped before old ones terminate.
- Set alert `for` durations longer than the lookback delta.

---

## Metric Name Collisions

### Symptoms

- Unexpected label combinations on a metric.
- `TYPE` mismatch warnings in logs.
- Incorrect aggregation results across jobs.

### Diagnosis

```bash
journalctl -u prometheus | grep -i "type mismatch"
```

```promql
group by (job) (my_metric_name)
```

```bash
curl -s http://localhost:9090/api/v1/metadata?metric=my_metric_name | jq .
```

### Resolution

Rename metrics at scrape time:

```yaml
metric_relabel_configs:
  - source_labels: [__name__]
    regex: 'http_requests_total'
    target_label: __name__
    replacement: 'legacy_http_requests_total'
```

### Prevention

- Prefix metrics with application name: `myapp_http_requests_total`.
- Validate exporter output with `promtool check metrics` in CI.
- Establish a metric naming registry across teams.

---

## Alertmanager Routing Debugging

### Symptoms

- Alerts not reaching the expected receiver.
- Duplicate notifications or unexpected grouping.

### Diagnosis

```bash
amtool config routes test \
  --config.file=/etc/alertmanager/alertmanager.yml \
  severity=critical team=platform alertname=HighErrorRate

amtool config routes show --config.file=/etc/alertmanager/alertmanager.yml
```

```bash
amtool alert query --alertmanager.url=http://localhost:9093
amtool silence query --alertmanager.url=http://localhost:9093
amtool check-config /etc/alertmanager/alertmanager.yml
```

### Resolution

Alertmanager uses first-match routing. Place specific routes before general ones:

```yaml
route:
  receiver: 'default'
  group_by: ['alertname', 'cluster']
  routes:
    - match:
        severity: critical
        team: platform
      receiver: 'platform-pagerduty'
    - match:
        severity: critical
      receiver: 'oncall-pagerduty'
```

Use `continue: true` to send to multiple receivers:

```yaml
routes:
  - match:
      severity: critical
    receiver: 'pagerduty'
    continue: true
  - match:
      severity: critical
    receiver: 'slack-critical'
```

### Prevention

- Always test with `amtool config routes test` before deploying.
- Keep the routing tree flat and well-commented.

---

## Push Gateway Pitfalls

### Symptoms

- Metrics never disappear after the source job stops.
- Multiple pushers overwriting each other.
- Alerting on stale data from completed batch jobs.

### Diagnosis

```bash
curl -s http://localhost:9091/metrics | grep push_time_seconds
```

```promql
time() - push_time_seconds
```

### Resolution

Delete stale groups:

```bash
curl -X DELETE http://localhost:9091/metrics/job/my-batch-job/instance/worker-1
```

Use unique grouping keys per instance:

```bash
cat <<EOF | curl --data-binary @- http://localhost:9091/metrics/job/etl/instance/worker-1
batch_records_processed 42
batch_duration_seconds 12.5
EOF
```

### When NOT to Use Pushgateway

- **Not for long-running services** — use pull-based scraping.
- **Not to convert pull to push** — if the target is scrapable, scrape it.
- **Not from multiple instances to the same grouping key** — they overwrite each other.

### Prevention

- Alert on `push_time_seconds` being older than expected.
- Set up a cron-based cleanup for stale groups.

---

## WAL Corruption Recovery

### Symptoms

- Prometheus fails to start: `msg="Failed to read WAL"` or `err="unexpected EOF"`.
- Crash loops after unclean shutdown (power failure, OOM kill).

### Diagnosis

```bash
journalctl -u prometheus | grep -i "wal\|corrupt\|segment"
ls -la /path/to/prometheus/data/wal/
```

Look for truncated or zero-byte WAL segments.

### Resolution

**Option 1 — Remove WAL (loses recent un-compacted data):**

```bash
systemctl stop prometheus
cp -r /path/to/prometheus/data /path/to/prometheus/data.bak
rm -rf /path/to/prometheus/data/wal/
systemctl start prometheus
```

**Option 2 — Remove only the corrupted segment:**

```bash
rm /path/to/prometheus/data/wal/00000042
systemctl restart prometheus
```

**Option 3 — TSDB repair:**

```bash
promtool tsdb clean /path/to/prometheus/data
```

### Prevention

- Always use `SIGTERM` for shutdown, never `SIGKILL`.
- Take snapshots via the admin API:

```bash
curl -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot
```

- Monitor `prometheus_tsdb_wal_corruptions_total`.
- Provision adequate disk I/O to reduce write latency.

---

## Target Discovery Problems

### Symptoms

- Expected targets not appearing in `/targets`.
- Targets flapping (appearing and disappearing).
- `msg="Error refreshing targets"` in logs.

### Diagnosis

```bash
journalctl -u prometheus | grep -i "discovery\|sd\|refresh"
```

Verify the SD source is healthy:

```bash
# Kubernetes
kubectl auth can-i list pods --as=system:serviceaccount:monitoring:prometheus
kubectl get endpoints my-service

# Consul
curl -s http://consul:8500/v1/catalog/service/my-service | jq .

# DNS
dig SRV _my-service._tcp.example.com
```

Check connectivity:

```bash
nc -zv target-host 9100 -w 5
```

Inspect discovered labels to see if relabeling is dropping targets:

```bash
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | .discoveredLabels'
```

### Resolution

Ensure Prometheus has proper RBAC for Kubernetes:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/metrics", "services", "endpoints", "pods"]
    verbs: ["get", "list", "watch"]
```

Reduce DNS SD refresh interval for faster discovery:

```yaml
dns_sd_configs:
  - names: ['_myservice._tcp.example.com']
    type: SRV
    refresh_interval: 15s
```

### Prevention

- Monitor `prometheus_sd_discovered_targets` for unexpected drops.
- Alert on `prometheus_sd_refresh_failures_total > 0`.
- Open required ports and verify NetworkPolicies allow monitoring traffic.
