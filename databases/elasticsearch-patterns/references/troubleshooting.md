# Elasticsearch Troubleshooting Guide

> Diagnosis-first reference for common ES issues. Each section: symptoms → diagnosis → fix → prevention.

## Table of Contents

- [Cluster Health: Yellow Status](#cluster-health-yellow-status)
- [Cluster Health: Red Status](#cluster-health-red-status)
- [Unassigned Shards](#unassigned-shards)
- [Shard Allocation Failures](#shard-allocation-failures)
- [Disk Watermarks](#disk-watermarks)
- [Mapping Explosion](#mapping-explosion)
- [Field Limit Exceeded](#field-limit-exceeded)
- [Circuit Breaker Errors](#circuit-breaker-errors)
- [Search Slow Log Analysis](#search-slow-log-analysis)
- [Indexing Bottlenecks](#indexing-bottlenecks)
- [GC Pressure](#gc-pressure)
- [Node Disconnections](#node-disconnections)
- [Split Brain Prevention](#split-brain-prevention)
- [Version Upgrade Issues](#version-upgrade-issues)
- [Reindex Failures](#reindex-failures)
- [Analyzer Debugging](#analyzer-debugging)
- [Relevance Tuning](#relevance-tuning)

---

## Cluster Health: Yellow Status

**Symptoms**: `GET _cluster/health` returns `"status": "yellow"`. Reads work; writes work.

**Meaning**: All primary shards assigned, but one or more replica shards are unassigned.

### Diagnosis

```bash
# Which indices are yellow?
GET _cat/indices?v&health=yellow&s=index

# Which shards are unassigned?
GET _cat/shards?v&h=index,shard,prirep,state,unassigned.reason&s=state

# Why unassigned?
GET _cluster/allocation/explain
```

### Common causes and fixes

| Cause | Fix |
|-------|-----|
| Single-node cluster with replicas > 0 | `PUT /index/_settings { "number_of_replicas": 0 }` |
| Node left cluster | Wait for node to rejoin, or reduce replicas |
| Not enough nodes for replicas | Add nodes or reduce `number_of_replicas` |
| Disk watermark hit | Free disk or raise watermark thresholds |
| Allocation awareness rules | Ensure nodes span required zones |

### Quick fix for dev/single-node

```json
PUT _settings
{ "index.number_of_replicas": 0 }
```

---

## Cluster Health: Red Status

**Symptoms**: `GET _cluster/health` returns `"status": "red"`. Some data is unavailable.

**Meaning**: One or more primary shards are unassigned. Data loss risk.

### Emergency triage

```bash
# 1. How bad is it?
GET _cluster/health?level=indices

# 2. Which indices are red?
GET _cat/indices?v&health=red

# 3. Which primary shards are unassigned?
GET _cat/shards?v&h=index,shard,prirep,state,unassigned.reason&s=state
# Filter for: prirep=p AND state=UNASSIGNED

# 4. Allocation explanation
GET _cluster/allocation/explain
{
  "index": "my_index",
  "shard": 0,
  "primary": true
}
```

### Recovery options (in order of preference)

1. **Wait for node recovery**: if the node carrying the shard is restarting.

2. **Reroute with accept data loss**:
```json
POST _cluster/reroute
{
  "commands": [{
    "allocate_stale_primary": {
      "index": "my_index",
      "shard": 0,
      "node": "surviving_node",
      "accept_data_loss": true
    }
  }]
}
```

3. **Allocate empty primary** (last resort — shard data is lost):
```json
POST _cluster/reroute
{
  "commands": [{
    "allocate_empty_primary": {
      "index": "my_index",
      "shard": 0,
      "node": "any_node",
      "accept_data_loss": true
    }
  }]
}
```

4. **Restore from snapshot** (if data is critical).

---

## Unassigned Shards

### Diagnosis

```bash
GET _cluster/allocation/explain?pretty

# Bulk check all unassigned
GET _cat/shards?v&h=index,shard,prirep,state,unassigned.reason,unassigned.details&s=state
```

### Unassigned reasons and fixes

| Reason | Meaning | Fix |
|--------|---------|-----|
| `INDEX_CREATED` | New index, no node available | Add data nodes |
| `CLUSTER_RECOVERED` | Cluster restart, shard not yet allocated | Wait; check disk |
| `NODE_LEFT` | Node departed | Rejoin node or wait for rebalance |
| `ALLOCATION_FAILED` | Prior attempt failed | `POST _cluster/reroute?retry_failed=true` |
| `REALLOCATED_REPLICA` | Replica moved away | Usually resolves automatically |
| `REINITIALIZED` | Shard recovery restarted | Check node logs for cause |
| `REROUTE_CANCELLED` | Manual reroute cancelled | Re-issue reroute command |
| `EXISTING_INDEX_RESTORED` | Snapshot restore in progress | Wait for restore completion |

### Force retry all failed allocations

```json
POST _cluster/reroute?retry_failed=true
```

---

## Shard Allocation Failures

### Allocation filtering diagnostics

```bash
# Check cluster-level allocation settings
GET _cluster/settings?include_defaults=true&flat_settings=true&filter_path=*.cluster.routing*

# Check index-level allocation rules
GET /my_index/_settings?flat_settings=true&filter_path=*.routing*

# Check node attributes
GET _cat/nodeattrs?v
```

### Common allocation blockers

```json
// Remove cluster-level allocation blocks
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.enable": "all" } }

// Remove index-level allocation filters
PUT /my_index/_settings
{
  "index.routing.allocation.require._name": null,
  "index.routing.allocation.include._tier_preference": null
}

// Disable read-only block (often set by disk watermark)
PUT /my_index/_settings
{ "index.blocks.read_only_allow_delete": null }

PUT _cluster/settings
{ "persistent": { "cluster.blocks.read_only_allow_delete": null } }
```

### Awareness and forced awareness

```bash
# If using allocation awareness, verify zone distribution
GET _cat/nodeattrs?v&h=node,attr,value
# Ensure nodes exist in all configured zones
```

---

## Disk Watermarks

ES prevents shard allocation when disk gets full. Three thresholds:

| Watermark | Default | Effect |
|-----------|---------|--------|
| Low (`cluster.routing.allocation.disk.watermark.low`) | 85% | No new shards allocated to node |
| High (`cluster.routing.allocation.disk.watermark.high`) | 90% | ES attempts to relocate shards away |
| Flood stage (`cluster.routing.allocation.disk.watermark.flood_stage`) | 95% | Index set to `read_only_allow_delete` |

### Diagnosis

```bash
GET _cat/allocation?v              # disk usage per node
GET _cat/nodes?v&h=name,disk.total,disk.used,disk.avail,disk.used_percent
GET _cluster/settings?flat_settings=true&filter_path=*watermark*
```

### Fixes

```json
// 1. Immediate: unlock read-only indices
PUT _all/_settings
{ "index.blocks.read_only_allow_delete": null }

// 2. Adjust watermarks (temporary relief)
PUT _cluster/settings
{
  "persistent": {
    "cluster.routing.allocation.disk.watermark.low": "90%",
    "cluster.routing.allocation.disk.watermark.high": "95%",
    "cluster.routing.allocation.disk.watermark.flood_stage": "97%"
  }
}

// 3. Delete old data
DELETE /logs-2022.*

// 4. Force merge to reclaim deleted doc space
POST /my_index/_forcemerge?max_num_segments=1
```

### Prevention

- Set up ILM with delete phase.
- Monitor disk usage with alerts at 75%.
- Use hot/warm/cold tiers with different storage.
- Configure data streams with rollover by size.

---

## Mapping Explosion

**Symptoms**: `illegal_argument_exception: Limit of total fields [1000] has been exceeded`.

### Diagnosis

```bash
GET /my_index/_mapping         # inspect full mapping
GET /my_index/_stats/fielddata  # memory used by field data

# Count fields
GET /my_index/_mapping | jq '[.. | .properties? // empty | keys[]] | length'
```

### Fixes

```json
// Increase field limit (not recommended as first resort)
PUT /my_index/_settings
{ "index.mapping.total_fields.limit": 2000 }

// Use strict mapping to prevent unknown fields
PUT /my_index/_mapping
{ "dynamic": "strict" }

// Use flattened type for semi-structured data
PUT /my_index/_mapping
{
  "properties": {
    "metadata": { "type": "flattened" }
  }
}

// Use object with enabled: false (stored but not indexed)
PUT /my_index/_mapping
{
  "properties": {
    "raw_payload": { "type": "object", "enabled": false }
  }
}
```

### Prevention

- Always set `"dynamic": "strict"` in production.
- Use `flattened` type for arbitrary key-value data.
- Review mappings before deploying new data shapes.
- Set `index.mapping.total_fields.limit` as a safety net, not a solution.

---

## Field Limit Exceeded

Similar to mapping explosion but for specific sub-limits:

| Setting | Default | Description |
|---------|---------|-------------|
| `index.mapping.total_fields.limit` | 1000 | Total number of fields |
| `index.mapping.depth.limit` | 20 | Max nesting depth |
| `index.mapping.nested_fields.limit` | 50 | Max nested field types |
| `index.mapping.nested_objects.limit` | 10000 | Max nested objects per doc |
| `index.mapping.field_name_length.limit` | 32766 (Long.MAX) | Max field name length |

```json
// Adjust specific limits
PUT /my_index/_settings
{
  "index.mapping.depth.limit": 10,
  "index.mapping.nested_fields.limit": 100,
  "index.mapping.nested_objects.limit": 50000
}
```

---

## Circuit Breaker Errors

**Symptoms**: `circuit_breaking_exception: [parent] Data too large` or `[request] Data too large`.

### Circuit breakers

| Breaker | Default | Protects |
|---------|---------|----------|
| Parent | 95% JVM heap | All memory |
| Request | 60% JVM heap | Single request (aggs, sorting) |
| Fielddata | 40% JVM heap | Text field aggregations |
| In-flight requests | 100% JVM heap | Transport-level |
| Model inference | 50% JVM heap | ML model memory |

### Diagnosis

```bash
GET _nodes/stats/breaker
GET _nodes/stats/jvm      # heap usage
GET _cat/fielddata?v       # fielddata per field per node
```

### Fixes

```json
// Clear fielddata cache (immediate relief)
POST _cache/clear?fielddata=true

// Don't aggregate on text fields — use keyword subfield
// BAD: { "terms": { "field": "title" } }
// GOOD: { "terms": { "field": "title.keyword" } }

// Reduce bucket count in aggregations
{ "terms": { "field": "category", "size": 100 } }   // not 10000

// Use composite agg for high-cardinality (paginated)
{ "composite": { "size": 100, "sources": [...] } }

// Reduce concurrent queries
// Add search.max_concurrent_shard_requests to limit concurrency

// Adjust breaker limits (careful — may cause OOM)
PUT _cluster/settings
{
  "persistent": {
    "indices.breaker.request.limit": "70%",
    "indices.breaker.fielddata.limit": "50%"
  }
}
```

### Prevention

- Never aggregate on `text` fields. Always use `keyword` or `keyword` subfield.
- Use `doc_values: false` on fields you never sort/aggregate.
- Prefer `search_after` over deep pagination.
- Monitor fielddata size with alerting.

---

## Search Slow Log Analysis

### Enable slow logs

```json
PUT /my_index/_settings
{
  "index.search.slowlog.threshold.query.warn": "10s",
  "index.search.slowlog.threshold.query.info": "5s",
  "index.search.slowlog.threshold.query.debug": "2s",
  "index.search.slowlog.threshold.query.trace": "500ms",
  "index.search.slowlog.threshold.fetch.warn": "1s",
  "index.search.slowlog.threshold.fetch.info": "800ms",
  "index.search.slowlog.level": "info",
  "index.indexing.slowlog.threshold.index.warn": "10s",
  "index.indexing.slowlog.threshold.index.info": "5s"
}
```

### Read slow logs

```bash
# Log location (default)
tail -f /var/log/elasticsearch/<cluster>_index_search_slowlog.json

# Key fields in JSON log:
# - took_millis: query duration
# - source: the actual query
# - total_shards, total_hits
```

### Common slow query patterns

| Pattern | Symptom | Fix |
|---------|---------|-----|
| Leading wildcard `*foo*` | Full index scan | Use ngram analyzer or `wildcard` field type |
| Deep pagination `from: 50000` | Memory + latency | Use `search_after` + PIT |
| Script scoring | CPU-bound | Pre-compute scores at index time |
| Large terms list | Slow bool expansion | Use `terms` lookup or pre-filter |
| High-cardinality agg | Memory + CPU | Use `composite` agg, reduce `size` |
| Unfiltered aggs | Scans all docs | Add `query` filter first |
| Regex on keyword | Full scan | Use prefix or `wildcard` type |
| Nested queries on large arrays | Per-nested-doc scoring | Limit nested objects, denormalize |

### Profile API for diagnosis

```json
POST /my_index/_search
{
  "profile": true,
  "query": { "match": { "title": "slow query" } }
}
// Check profile.shards[].searches[].query[].time_in_nanos for bottleneck
```

---

## Indexing Bottlenecks

### Diagnosis

```bash
GET _cat/thread_pool/write?v&h=node_name,active,queue,rejected,completed
GET _nodes/stats/indices/indexing
GET /my_index/_stats/indexing
GET _tasks?actions=*bulk*&detailed&group_by=parents
```

### Common causes and fixes

| Bottleneck | Diagnosis | Fix |
|-----------|-----------|-----|
| Refresh too frequent | `refresh_interval: "1s"` | Set to `"30s"` or `"-1"` during bulk |
| Too many replicas | High write latency | Set replicas to 0 during initial load |
| Small bulk batches | High overhead per request | Target 5-15 MB per `_bulk` request |
| Too few threads | Low CPU utilization | Increase concurrent bulk threads to 8-16 |
| Translog flush | Disk I/O bottleneck | Increase `translog.flush_threshold_size` |
| Merge throttle | Heavy segment merging | Increase `index.merge.scheduler.max_thread_count` |
| Ingest pipeline | CPU on ingest nodes | Scale ingest nodes, simplify pipeline |
| Cross-cluster writes | Network latency | Index locally, replicate with CCR |

### Bulk indexing optimization

```json
PUT /my_index/_settings
{
  "index.refresh_interval": "-1",
  "index.number_of_replicas": 0,
  "index.translog.flush_threshold_size": "1gb",
  "index.translog.durability": "async"
}

// After bulk load completes:
PUT /my_index/_settings
{
  "index.refresh_interval": "5s",
  "index.number_of_replicas": 1,
  "index.translog.durability": "request"
}

POST /my_index/_forcemerge?max_num_segments=5
```

---

## GC Pressure

**Symptoms**: high heap usage, long GC pauses, slow responses, node timeouts.

### Diagnosis

```bash
GET _nodes/stats/jvm
GET _cat/nodes?v&h=name,heap.percent,heap.max,ram.percent,cpu

# JVM logs
grep "gc.*pause" /var/log/elasticsearch/gc.log | tail -20

# Key metrics:
# - heap.percent > 75% sustained = problem
# - Old generation GC pauses > 1s = critical
# - Young GC frequency > 20/s = high allocation rate
```

### Common causes

| Cause | Evidence | Fix |
|-------|----------|-----|
| Fielddata on text fields | `_cat/fielddata?v` shows large values | Use keyword subfield |
| Too many open PITs/scrolls | `GET _nodes/stats/indices/search` | Close unused PITs |
| High-cardinality aggregations | Large bucket counts | Use composite agg, limit size |
| Large `_source` fields | Memory per doc high | Exclude large fields with `_source.excludes` |
| Over-sharding | Too many shards per node | Merge indices, increase shard size |
| Cache pressure | Check `GET _nodes/stats/indices/query_cache` | Clear caches, reduce cache size |

### JVM tuning

```bash
# elasticsearch.yml / jvm.options
# Heap: set to 50% RAM, max 31GB (compressed oops)
-Xms16g
-Xmx16g

# Never exceed 31GB — loses pointer compression
# 32GB heap ≈ 26GB usable (worse than 31GB)
```

### Emergency relief

```json
// Clear all caches
POST _cache/clear

// Reduce concurrent searches
PUT _cluster/settings
{ "persistent": { "search.max_concurrent_shard_requests": 3 } }
```

---

## Node Disconnections

### Diagnosis

```bash
GET _cat/nodes?v&h=name,ip,role,master,heap.percent,cpu,load_1m

# Check logs for disconnect messages
grep -E "disconnected|removed|master.*leave" /var/log/elasticsearch/*.log | tail -30
```

### Common causes

| Cause | Evidence | Fix |
|-------|----------|-----|
| Long GC pauses | GC logs show pauses > `discovery.cluster_fault_detection.leader_check.timeout` (default 10s) | Reduce heap pressure |
| Network issues | Intermittent packet loss | Check NIC, switches, MTU |
| Disk I/O saturation | `iowait` high in OS metrics | Faster disks, reduce merge pressure |
| Too many shards | >1000 shards/node | Merge indices, larger shards |
| Master overloaded | Cluster state updates slow | Dedicate master nodes (no data) |

### Tune fault detection

```json
PUT _cluster/settings
{
  "persistent": {
    "cluster.fault_detection.leader_check.interval": "2s",
    "cluster.fault_detection.leader_check.timeout": "30s",
    "cluster.fault_detection.leader_check.retry_count": 5,
    "cluster.fault_detection.follower_check.interval": "2s",
    "cluster.fault_detection.follower_check.timeout": "30s",
    "cluster.fault_detection.follower_check.retry_count": 5
  }
}
```

---

## Split Brain Prevention

ES 8.x uses a quorum-based master election that inherently prevents split brain (no `minimum_master_nodes` setting needed — that was ES 6.x/7.x).

### Best practices

- **Always use 3+ dedicated master-eligible nodes** (odd number preferred).
- Master nodes should be lightweight — no data, no ingest, no ML.
- Use `node.roles: [master]` to dedicate.

### Verify master election

```bash
GET _cat/master?v
GET _cat/nodes?v&h=name,role,master
GET _cluster/state/master_node,nodes?pretty
```

### If split brain somehow occurs

1. Stop all nodes in the minority partition.
2. Verify the majority partition has quorum.
3. Restart stopped nodes — they will rejoin the majority cluster.
4. Check data integrity with `GET _cat/indices?health=red`.

---

## Version Upgrade Issues

### Pre-upgrade checklist

```bash
# 1. Check deprecation log
GET _migration/deprecations

# 2. Verify index compatibility
GET _cat/indices?v&h=index,creation.date.string,version.created.string

# 3. Check for incompatible settings
GET _cluster/settings?include_defaults=true

# 4. Snapshot before upgrade
PUT _snapshot/upgrade_backup/pre_upgrade?wait_for_completion=true
```

### Rolling upgrade procedure

1. Disable shard allocation:
```json
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.enable": "primaries" } }
```

2. Stop non-essential indexing and perform a synced flush:
```json
POST _flush/synced
```

3. Stop ONE node, upgrade it, start it.

4. Wait for node to rejoin:
```bash
GET _cat/nodes?v
GET _cat/health?v
```

5. Re-enable allocation:
```json
PUT _cluster/settings
{ "persistent": { "cluster.routing.allocation.enable": "all" } }
```

6. Wait for `green` status, then repeat for next node.

### Post-upgrade

```bash
GET _cat/health?v
GET _cat/indices?v&health=yellow
GET _cat/indices?v&health=red

# Update index settings that were deprecated
GET _migration/deprecations
```

---

## Reindex Failures

### Common errors and fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `version_conflict_engine_exception` | Doc already exists with higher version | Add `"conflicts": "proceed"` |
| `mapper_parsing_exception` | Dest mapping doesn't match source | Fix dest mapping before reindex |
| `rejected_execution_exception` | Write queue full | Reduce `slices`, throttle |
| Timeout | Large index, slow network | Use `wait_for_completion=false`, poll `_tasks` |

### Robust reindex pattern

```json
POST _reindex?wait_for_completion=false&slices=auto
{
  "conflicts": "proceed",
  "source": {
    "index": "old_index",
    "size": 5000,
    "query": { "range": { "@timestamp": { "gte": "2024-01-01" } } }
  },
  "dest": {
    "index": "new_index",
    "pipeline": "my_pipeline",
    "op_type": "create"
  }
}

// Monitor
GET _tasks?actions=*reindex*&detailed
GET _tasks/<task_id>

// Throttle a running reindex
POST _reindex/<task_id>/_rethrottle?requests_per_second=1000

// Cancel
POST _tasks/<task_id>/_cancel
```

### Remote reindex (across clusters)

```json
POST _reindex
{
  "source": {
    "remote": {
      "host": "https://old-cluster:9200",
      "username": "user",
      "password": "pass"
    },
    "index": "old_index"
  },
  "dest": { "index": "new_index" }
}
```

---

## Analyzer Debugging

### Test analyzer output

```json
// Test built-in analyzer
POST _analyze
{ "analyzer": "standard", "text": "The quick-brown fox's email is fox@example.com" }

// Test custom analyzer by index
POST /my_index/_analyze
{ "analyzer": "my_custom_analyzer", "text": "Testing custom analysis" }

// Test specific tokenizer + filters
POST _analyze
{
  "tokenizer": "standard",
  "filter": ["lowercase", "asciifolding", "snowball"],
  "text": "Résumé writing techniques"
}
// Output: ["resume", "write", "techniqu"]

// Test char_filter
POST _analyze
{
  "char_filter": ["html_strip"],
  "tokenizer": "standard",
  "text": "<p>Hello <b>World</b></p>"
}
```

### Compare indexed vs search analysis

```json
// See how a field was indexed
POST /my_index/_analyze
{ "field": "title", "text": "Quick brown fox" }

// See how a search query is analyzed
POST /my_index/_analyze
{
  "analyzer": "my_search_analyzer",
  "text": "Quick brown fox"
}
```

### Debug why a document doesn't match

```json
// 1. Check what tokens the document produced
POST /my_index/_analyze
{ "field": "content", "text": "The actual document text" }

// 2. Check what tokens the query produces
POST /my_index/_analyze
{ "field": "content", "text": "your search query" }

// 3. Use explain API
GET /my_index/_explain/doc_id
{ "query": { "match": { "content": "your search query" } } }

// 4. Check term vectors for an indexed doc
GET /my_index/_termvectors/doc_id
{ "fields": ["content"], "term_statistics": true }
```

### Common analyzer pitfalls

| Issue | Symptom | Fix |
|-------|---------|-----|
| Different index/search analyzers | Unexpected mismatches | Verify both with `_analyze` |
| Missing synonym at search time | Synonym not expanding | Use `search_analyzer` with synonyms |
| Stop words removing query terms | Empty query | Remove stop filter or use `"stopwords": "_none_"` |
| ASCII folding mismatch | "café" doesn't match "cafe" | Add `asciifolding` filter to both index and search analyzers |
| Stemmer over-aggressiveness | False positives | Switch to lighter stemmer or use `keyword_marker` |

---

## Relevance Tuning

### Diagnosis

```json
// Explain scoring
GET /products/_explain/doc_id
{ "query": { "match": { "name": "laptop" } } }

// Profile query execution
POST /products/_search
{ "profile": true, "query": { "match": { "name": "laptop" } } }
```

### Quick wins

| Problem | Fix |
|---------|-----|
| Important field scores same as others | Boost: `"name^3"` in multi_match |
| Exact matches don't rank higher | Add `keyword` subfield as `should` clause |
| Older docs dominate | Add `gauss` decay function on date |
| Low-quality docs rank high | Add `field_value_factor` on quality metric |
| Partial matches too prominent | Increase `minimum_should_match` |
| Typos not handled | Add `fuzziness: "AUTO"` |
| Synonyms not applied | Add synonym token filter |

### Evaluate relevance changes

```json
POST /products/_rank_eval
{
  "requests": [
    {
      "id": "laptop_query",
      "request": { "query": { "match": { "name": "laptop" } } },
      "ratings": [
        { "_index": "products", "_id": "1", "rating": 3 },
        { "_index": "products", "_id": "5", "rating": 2 },
        { "_index": "products", "_id": "10", "rating": 0 }
      ]
    }
  ],
  "metric": { "dcg": { "k": 10, "normalize": true } }
}
```
