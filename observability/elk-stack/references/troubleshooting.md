# ELK Stack Troubleshooting Reference

A comprehensive guide for diagnosing and resolving common issues in Elasticsearch, Logstash, Kibana, and Beats.

---

## Table of Contents

1. [Cluster Yellow/Red State Diagnosis](#1-cluster-yellowred-state-diagnosis)
2. [Unassigned Shard Troubleshooting](#2-unassigned-shard-troubleshooting)
3. [JVM Heap Pressure and GC Issues](#3-jvm-heap-pressure-and-gc-issues)
4. [Slow Search Diagnosis](#4-slow-search-diagnosis)
5. [Mapping Explosion Prevention](#5-mapping-explosion-prevention)
6. [Logstash Pipeline Debugging](#6-logstash-pipeline-debugging)
7. [Filebeat Registry Corruption](#7-filebeat-registry-corruption)
8. [Kibana Saved Object Conflicts](#8-kibana-saved-object-conflicts)
9. [Circuit Breaker Trips](#9-circuit-breaker-trips)
10. [Disk Watermark Thresholds](#10-disk-watermark-thresholds)
11. [Split-Brain Prevention](#11-split-brain-prevention)
12. [Index Corruption Recovery](#12-index-corruption-recovery)

---

## 1. Cluster Yellow/Red State Diagnosis

### What the States Mean

| State  | Meaning |
|--------|---------|
| Green  | All primary and replica shards are allocated. |
| Yellow | All primaries allocated but one or more replicas are unassigned. Data intact, redundancy reduced. |
| Red    | One or more primary shards are unassigned. Some data is unavailable. |

### Symptoms

- Kibana shows a yellow or red cluster health banner.
- Indexing returns `503` or `408` errors (red state). Search results may be incomplete.

### Diagnosis

**Step 1 — Check cluster health:**

```bash
GET _cluster/health?pretty
```

Key fields: `status`, `unassigned_shards`, `number_of_pending_tasks`, `active_shards_percent_as_number`.

**Step 2 — Identify unhealthy indices:**

```bash
GET _cat/indices?v&health=yellow
GET _cat/indices?v&health=red
```

**Step 3 — Locate unassigned shards:**

```bash
GET _cat/shards?v&h=index,shard,prirep,state,unassigned.reason&s=state:desc
```

The `prirep` column shows whether the missing shard is a primary (`p`) or replica (`r`).

**Step 4 — Get shard-level detail:**

```bash
GET _cluster/health?level=shards&pretty
```

### Solution

- **Yellow on single-node cluster:** Replicas cannot be placed on the same node as the primary:
  ```bash
  PUT my-index/_settings
  { "index.number_of_replicas": 0 }
  ```
- **Red due to node loss:** Restart the failed node. If permanently lost, use `_cluster/reroute` with `accept_data_loss` to promote a stale replica.
- **Increase recovery speed temporarily:**
  ```bash
  PUT _cluster/settings
  { "transient": { "cluster.routing.allocation.node_concurrent_recoveries": 4 } }
  ```

---

## 2. Unassigned Shard Troubleshooting

### Symptoms

- Cluster health is yellow or red with `UNASSIGNED` entries in `_cat/shards`.
- New indices remain yellow immediately after creation.

### Diagnosis

**Step 1 — Allocation explanation:**

```bash
GET _cluster/allocation/explain?pretty
{
  "index": "my-index",
  "shard": 0,
  "primary": false
}
```

Without a body, Elasticsearch explains the first unassigned shard it finds.

**Step 2 — Common unassigned reasons:**

| Reason                  | Description |
|-------------------------|-------------|
| `INDEX_CREATED`         | Newly created, not yet allocated. |
| `NODE_LEFT`             | Node holding this shard left the cluster. |
| `ALLOCATION_FAILED`     | Previous allocation failed (e.g., corrupt shard). |
| `EXISTING_INDEX_RESTORED` | Restored from snapshot, not yet allocated. |

**Step 3 — Check allocation filters:**

```bash
GET my-index/_settings?flat_settings=true&filter_path=**.routing*
GET _cluster/settings?flat_settings=true&filter_path=**.routing*
```

### Solution

- **Disk space exceeded:** See [Section 10](#10-disk-watermark-thresholds).
- **Allocation awareness mismatch:** Ensure enough nodes exist per zone when using `cluster.routing.allocation.awareness.attributes`.
- **Insufficient nodes:** Replicas require more data nodes than the replica count:
  ```bash
  PUT my-index/_settings
  { "index.number_of_replicas": 1 }
  ```
- **Manual reroute:**
  ```bash
  POST _cluster/reroute
  {
    "commands": [{
      "allocate_replica": { "index": "my-index", "shard": 0, "node": "data-node-2" }
    }]
  }
  ```
- **Retry failed allocations:**
  ```bash
  POST _cluster/reroute?retry_failed=true
  ```
- **Remove blocking filters:**
  ```bash
  PUT my-index/_settings
  {
    "index.routing.allocation.exclude._name": null,
    "index.routing.allocation.require._name": null
  }
  ```

---

## 3. JVM Heap Pressure and GC Issues

### Symptoms

- Nodes become unresponsive or drop out intermittently.
- Logs show repeated `[gc][old]` entries with pauses >1s. `CircuitBreakingException` errors appear.

### Diagnosis

**Step 1 — Heap and GC stats:**

```bash
GET _nodes/stats/jvm?pretty
```

Key metrics: `jvm.mem.heap_used_percent`, `jvm.gc.collectors.old.collection_count`, `jvm.gc.collectors.old.collection_time_in_millis`.

**Step 2 — Identify pressured nodes:**

```bash
GET _cat/nodes?v&h=name,heap.percent,heap.max,ram.percent,cpu,load_1m
```

**Step 3 — Check field data usage:**

```bash
GET _cat/fielddata?v&h=node,field,size
```

**Step 4 — Review circuit breakers:**

```bash
GET _nodes/stats/breaker?pretty
```

### Solution

- **Set heap to 50% of RAM** (max 31 GB for compressed OOPs):
  ```bash
  # jvm.options
  -Xms16g
  -Xmx16g
  ```
- **Reduce field data pressure:** Replace `fielddata: true` on text fields with keyword sub-fields.
- **Tune the field data breaker:**
  ```bash
  PUT _cluster/settings
  { "transient": { "indices.breaker.fielddata.limit": "40%" } }
  ```
- **Reduce shard count.** Each shard consumes heap for metadata. Aim for 10–50 GB per shard.
- **Avoid high-cardinality aggregations.** Use `composite` aggregations with pagination instead.
- **Limit bulk request sizes** to 5–15 MB per request.
- **Heap dump for analysis:**
  ```bash
  jmap -dump:live,format=b,file=/tmp/heap.hprof <ES_PID>
  ```

---

## 4. Slow Search Diagnosis

### Symptoms

- Kibana dashboards load slowly or time out.
- Search requests return `504 Gateway Timeout`.
- Thread pool rejections in the `search` pool.
- Search latency p95/p99 well above baseline.

### Diagnosis

**Step 1 — Profile a slow query:**

```bash
GET my-index/_search
{
  "profile": true,
  "query": { "match": { "message": "error" } }
}
```

**Step 2 — Enable slow logs:**

```bash
PUT my-index/_settings
{
  "index.search.slowlog.threshold.query.warn": "10s",
  "index.search.slowlog.threshold.query.info": "5s",
  "index.search.slowlog.threshold.query.debug": "2s",
  "index.search.slowlog.threshold.fetch.warn": "1s",
  "index.search.slowlog.level": "info"
}
```

**Step 3 — Find long-running tasks:**

```bash
GET _tasks?actions=*search&detailed=true&group_by=parents
```

**Step 4 — Cancel a runaway query:**

```bash
POST _tasks/<task_id>/_cancel
```

### Solution

- **Avoid leading wildcards:** `"*error"` scans every term. Use `reverse` token filters or n-grams instead.
- **Replace deep pagination with `search_after`:**
  ```bash
  GET my-index/_search
  {
    "size": 100,
    "sort": [{ "@timestamp": "desc" }, { "_id": "asc" }],
    "search_after": ["2024-01-15T10:30:00.000Z", "abc123"]
  }
  ```
- **Use `filter` context** for non-scoring clauses to leverage caching:
  ```bash
  GET my-index/_search
  {
    "query": {
      "bool": {
        "filter": [
          { "term": { "status": "error" } },
          { "range": { "@timestamp": { "gte": "now-1h" } } }
        ]
      }
    }
  }
  ```
- **Reduce shard count per search.** Target fewer than 20 shards per search request.

---

## 5. Mapping Explosion Prevention

### Symptoms

- Indexing fails with `IllegalArgumentException: Limit of total fields [1000] has been exceeded`.
- Master node becomes unstable due to oversized cluster state.
- `GET my-index/_mapping` returns an extremely large JSON document.

### Diagnosis

**Count fields:**

```bash
curl -s localhost:9200/my-index/_mapping | jq '[.. | .type? // empty] | length'
```

**Check limits:**

```bash
GET my-index/_settings?flat_settings=true&filter_path=**.mapping*
```

Review recent documents for unexpected nested keys (user-generated labels, flattened JSON blobs).

### Solution

- **Set explicit limits:**
  ```bash
  PUT my-index/_settings
  {
    "index.mapping.total_fields.limit": 2000,
    "index.mapping.depth.limit": 10,
    "index.mapping.nested_fields.limit": 50
  }
  ```
- **Use strict mapping** to reject unmapped fields:
  ```bash
  PUT my-index/_mapping
  { "dynamic": "strict" }
  ```
- **Use `flattened` field type** for arbitrary key-value data:
  ```bash
  PUT my-index/_mapping
  {
    "properties": {
      "user_labels": { "type": "flattened" }
    }
  }
  ```
- **Dynamic templates** to control new field mapping:
  ```bash
  PUT my-index
  {
    "mappings": {
      "dynamic_templates": [
        {
          "strings_as_keywords": {
            "match_mapping_type": "string",
            "mapping": { "type": "keyword", "ignore_above": 256 }
          }
        }
      ]
    }
  }
  ```
- **Use `dynamic: runtime`** to auto-create runtime fields instead of indexed fields.
- **Reindex with a curated mapping** when an existing index has already exploded.

---

## 6. Logstash Pipeline Debugging

### Symptoms

- Events are not reaching the destination output.
- Logs show `pipeline worker error` or filter exceptions.
- Events are silently dropped or malformed.

### Diagnosis

**Step 1 — Validate config syntax:**

```bash
bin/logstash --config.test_and_exit -f /etc/logstash/conf.d/
```

**Step 2 — Enable debug logging:**

```bash
bin/logstash --log.level debug -f /etc/logstash/conf.d/my-pipeline.conf
```

Or at runtime:

```bash
curl -XPUT 'localhost:9600/_node/logging?pretty' \
  -H 'Content-Type: application/json' \
  -d '{ "logger.logstash.outputs.elasticsearch": "DEBUG" }'
```

**Step 3 — Check pipeline metrics:**

```bash
curl -s localhost:9600/_node/stats/pipelines?pretty
```

Key metrics: `events.in`, `events.filtered`, `events.out`, `queue.events_count`.

**Step 4 — Use the pipeline viewer** in Kibana Stack Monitoring to visualize per-plugin throughput.

**Step 5 — Inspect the dead letter queue:**

```bash
ls -la /var/lib/logstash/dead_letter_queue/<pipeline_name>/
```

### Solution

- **Enable the DLQ** to capture failed events:
  ```yaml
  # logstash.yml
  dead_letter_queue.enable: true
  dead_letter_queue.max_bytes: 4096mb
  ```
- **Process DLQ events** with a dedicated pipeline:
  ```ruby
  input {
    dead_letter_queue {
      path => "/var/lib/logstash/dead_letter_queue"
      pipeline_id => "main"
    }
  }
  output { elasticsearch { index => "dlq-reprocessed-%{+YYYY.MM.dd}" } }
  ```
- **Enable persistent queues:**
  ```yaml
  queue.type: persisted
  queue.max_bytes: 8gb
  queue.checkpoint.writes: 1024
  ```
- **Debug with stdout:** Add `stdout { codec => rubydebug }` as an output to inspect events at any stage.
- **Grok failures:** Test patterns with the Kibana Grok Debugger. Filter on `_grokparsefailure` tags.
- **Date parse errors:** Provide multiple formats:
  ```ruby
  date {
    match => ["timestamp", "ISO8601", "yyyy-MM-dd HH:mm:ss,SSS"]
  }
  ```

---

## 7. Filebeat Registry Corruption

### Symptoms

- Filebeat stops collecting from certain files while reading others normally.
- Previously ingested data is re-sent, causing duplicates.
- Logs show `Error reading registry` or `Failed to decode registry`.

### Diagnosis

**Step 1 — Locate the registry:**

```bash
# Default: /var/lib/filebeat/registry/filebeat/
ls -la /var/lib/filebeat/registry/filebeat/
```

**Step 2 — Inspect the registry:**

```bash
cat /var/lib/filebeat/registry/filebeat/log.json | python3 -m json.tool | head -50
```

Look for impossible offsets, missing file references, or duplicate inode entries.

**Step 3 — Check Filebeat logs:**

```bash
grep -i "registry\|harvester\|state" /var/log/filebeat/filebeat.log | tail -30
```

### Solution

- **Reset the registry** (causes all matching files to be re-read):
  ```bash
  sudo systemctl stop filebeat
  sudo rm -rf /var/lib/filebeat/registry/filebeat/*
  sudo systemctl start filebeat
  ```
- **Configure cleanup settings:**
  ```yaml
  filebeat.inputs:
    - type: filestream
      id: my-logs
      paths: ["/var/log/app/*.log"]
      clean_removed: true
      clean_inactive: 72h
      ignore_older: 48h
      close_inactive: 5m
  ```
- **Common causes:** Disk full during registry write, abrupt `kill -9` instead of graceful stop, multiple instances sharing the same data directory, NFS locking issues.
- **Migrate to `filestream` input type** for improved registry corruption resilience over the legacy `log` type.

---

## 8. Kibana Saved Object Conflicts

### Symptoms

- Importing dashboards or visualizations fails with conflict errors.
- After upgrading, dashboards show `Could not locate that visualization`.

### Diagnosis

**Step 1 — Export saved objects:**

```bash
curl -s -X POST "localhost:5601/api/saved_objects/_export" \
  -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
  -d '{ "type": ["dashboard", "visualization", "index-pattern"] }' \
  --output export.ndjson
```

**Step 2 — Dry-run import to check conflicts:**

```bash
curl -X POST "localhost:5601/api/saved_objects/_import?overwrite=false" \
  -H 'kbn-xsrf: true' --form file=@export.ndjson
```

**Step 3 — Check Kibana logs:**

```bash
grep -i "migration\|conflict\|saved_object" /var/log/kibana/kibana.log | tail -20
```

### Solution

- **Force overwrite:**
  ```bash
  curl -X POST "localhost:5601/api/saved_objects/_import?overwrite=true" \
    -H 'kbn-xsrf: true' --form file=@export.ndjson
  ```
- **Resolve specific collisions:**
  ```bash
  curl -X POST "localhost:5601/api/saved_objects/_resolve_import_errors" \
    -H 'kbn-xsrf: true' --form file=@export.ndjson \
    --form retries='[{"type":"visualization","id":"old-id","overwrite":true}]'
  ```
- **Space-aware imports:**
  ```bash
  curl -X POST "localhost:5601/s/my-space/api/saved_objects/_import?overwrite=true" \
    -H 'kbn-xsrf: true' --form file=@export.ndjson
  ```
- **Version compatibility:** Always export from the same or older Kibana version. Cross-major-version imports may require the upgrade assistant.
- **Update index pattern references:**
  ```bash
  curl -X PUT "localhost:5601/api/saved_objects/index-pattern/old-pattern-id" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -d '{ "attributes": { "title": "new-index-*" } }'
  ```

---

## 9. Circuit Breaker Trips

### Symptoms

- Requests fail with `CircuitBreakingException` indicating which breaker tripped.
- HTTP 429 or 503 errors on search or indexing operations.

### Circuit Breaker Types

| Breaker      | Default Limit | Purpose |
|--------------|---------------|---------|
| `parent`     | 95% of heap   | Aggregate limit across all breakers. |
| `fielddata`  | 40% of heap   | Field data for text field aggregations. |
| `request`    | 60% of heap   | Per-request data structures (agg buckets). |
| `in_flight`  | 100% of heap  | Transport-level in-flight requests. |
| `accounting` | 100% of heap  | Tracks completed request memory (non-configurable). |

### Diagnosis

**Step 1 — Check tripped breakers:**

```bash
GET _nodes/stats/breaker?pretty
```

Look for `tripped > 0` and compare `estimated_size` against `limit_size`.

**Step 2 — Correlate** the trip timestamp with recent operations: large aggregations, bulk bursts, or fielddata loads on high-cardinality text fields.

**Step 3 — Check settings:**

```bash
GET _cluster/settings?include_defaults=true&flat_settings=true&filter_path=**.breaker*
```

### Solution

- **Fielddata trips:** Stop using `fielddata: true` on text fields. Switch to keyword sub-fields.
- **Request trips:** Reduce aggregation bucket counts with `size` parameters. Break large aggregations into smaller requests.
- **Parent trips:** Address root causes (see [Section 3](#3-jvm-heap-pressure-and-gc-issues)).
- **Tune limits** (raising them increases OOM risk):
  ```bash
  PUT _cluster/settings
  {
    "transient": {
      "indices.breaker.fielddata.limit": "45%",
      "indices.breaker.request.limit": "55%"
    }
  }
  ```
- **In-flight trips:** Reduce concurrent bulk clients or decrease bulk payload sizes.

---

## 10. Disk Watermark Thresholds

### Symptoms

- New shards cannot be allocated; existing indices go read-only.
- Indexing fails with `FORBIDDEN/12/index read-only / allow delete (api)`.

### Watermark Levels

| Watermark   | Default | Effect |
|-------------|---------|--------|
| Low         | 85%     | No new shards allocated to this node. |
| High        | 90%     | Shards relocated off this node. |
| Flood Stage | 95%     | Indices on this node set to `read_only_allow_delete`. |

### Diagnosis

```bash
GET _cat/allocation?v&h=node,disk.used,disk.avail,disk.total,disk.percent
GET _all/_settings?flat_settings=true&filter_path=**.read_only*
GET _cluster/settings?include_defaults=true&flat_settings=true&filter_path=**.watermark*
```

### Solution

- **Clear read-only blocks** after freeing space:
  ```bash
  PUT _all/_settings
  { "index.blocks.read_only_allow_delete": null }
  ```
- **Free space:** Delete old indices, force merge, or remove unused snapshots:
  ```bash
  DELETE old-logs-2023.01.*
  POST my-index/_forcemerge?max_num_segments=1
  ```
- **Adjust thresholds:**
  ```bash
  PUT _cluster/settings
  {
    "persistent": {
      "cluster.routing.allocation.disk.watermark.low": "87%",
      "cluster.routing.allocation.disk.watermark.high": "92%",
      "cluster.routing.allocation.disk.watermark.flood_stage": "97%"
    }
  }
  ```
  Watermarks also accept absolute byte values (e.g., `"50gb"`).
- **Enable ILM policies** to automatically delete or shrink old indices before pressure builds.

---

## 11. Split-Brain Prevention

### Symptoms

- Two subsets of nodes each elect their own master, forming independent clusters.
- Nodes log `master not discovered` or `master changed` warnings frequently.

### What Causes Split-Brain

A network partition separates nodes into isolated groups, and each group independently elects a master. This was more common prior to Elasticsearch 7.x.

### Diagnosis

```bash
GET _cat/master?v
GET _cat/nodes?v&h=name,node.role,master
GET _cluster/state/metadata?filter_path=metadata.cluster_coordination*
```

Review `elasticsearch.yml`:

```yaml
discovery.seed_hosts: ["es-node-1", "es-node-2", "es-node-3"]
cluster.initial_master_nodes: ["es-node-1", "es-node-2", "es-node-3"]
```

### Solution

- **Elasticsearch 7.x+** uses quorum-based consensus that prevents split-brain by design:
  ```yaml
  discovery.seed_hosts:
    - es-master-1:9300
    - es-master-2:9300
    - es-master-3:9300
  # Only on initial bootstrap; remove after first formation
  cluster.initial_master_nodes:
    - es-master-1
    - es-master-2
    - es-master-3
  ```
- **Use an odd number** of master-eligible nodes (3, 5, or 7).
- **Remove `cluster.initial_master_nodes`** after the cluster has formed — leaving it can cause issues during full restarts.
- **Elasticsearch 6.x and earlier:** Set `discovery.zen.minimum_master_nodes` to `(master_eligible / 2) + 1`.
- **Exclude a decommissioned node from voting:**
  ```bash
  POST _cluster/voting_config_exclusions?node_names=old-master-1
  ```
- **Network partition handling:** Monitor connectivity between nodes. Place master-eligible nodes across availability zones with reliable low-latency links.

---

## 12. Index Corruption Recovery

### Symptoms

- Queries return `CorruptIndexException` or `IndexFormatTooOldException`.
- Shard recovery fails with `RecoveryFailedException`.
- `_cat/shards` shows shards stuck in `INITIALIZING` indefinitely.

### Diagnosis

**Step 1 — Segment integrity:**

```bash
GET my-index/_segments?pretty
```

**Step 2 — Recovery status:**

```bash
GET _cat/recovery?v&active_only=true
```

**Step 3 — Dangling indices:**

```bash
GET _dangling?pretty
```

**Step 4 — Log inspection:**

```bash
grep -i "corrupt\|checksum\|segment\|recoveryFailed" /var/log/elasticsearch/*.log | tail -30
```

### Solution

- **Restore from snapshot** (preferred):
  ```bash
  POST my-index/_close
  POST _snapshot/my-backup-repo/snapshot-2024-01-15/_restore
  {
    "indices": "my-index",
    "ignore_unavailable": true,
    "include_global_state": false
  }
  ```
- **Import a dangling index:**
  ```bash
  GET _dangling
  POST _dangling/<index-uuid>?accept_data_loss=true
  ```
- **Use `elasticsearch-shard` tool** on a stopped node:
  ```bash
  bin/elasticsearch-shard remove-corrupted-data --index my-index --shard-id 0
  ```
  > **Warning:** Destructive — truncates translog and removes corrupt segments.
- **Allocate an empty primary** as a last resort (all shard data is lost):
  ```bash
  POST _cluster/reroute
  {
    "commands": [{
      "allocate_empty_primary": {
        "index": "my-index", "shard": 0,
        "node": "data-node-1", "accept_data_loss": true
      }
    }]
  }
  ```
- **Prevention:** Schedule regular snapshots with SLM, monitor disk health, and ensure graceful node shutdowns.

---

## Quick Reference: Diagnostic Commands

| Check                  | Command                                                   |
|------------------------|-----------------------------------------------------------|
| Cluster health         | `GET _cluster/health?pretty`                              |
| Unhealthy indices      | `GET _cat/indices?v&health=red`                           |
| Unassigned shards      | `GET _cat/shards?v&s=state:desc`                          |
| Allocation explanation | `GET _cluster/allocation/explain`                         |
| Node heap / CPU        | `GET _cat/nodes?v&h=name,heap.percent,cpu,load_1m`        |
| Disk usage             | `GET _cat/allocation?v`                                   |
| Thread pool rejections | `GET _cat/thread_pool?v&h=node_name,name,active,rejected` |
| Circuit breakers       | `GET _nodes/stats/breaker`                                |
| Field data usage       | `GET _cat/fielddata?v`                                    |
| Active tasks           | `GET _tasks?detailed=true&group_by=parents`               |
| Hot threads            | `GET _nodes/hot_threads`                                  |
| Recovery status        | `GET _cat/recovery?v&active_only=true`                    |
