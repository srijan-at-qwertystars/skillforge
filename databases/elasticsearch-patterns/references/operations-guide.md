# Elasticsearch Operations Guide

> Production operations reference for ES 8.x. Covers sizing, upgrades, monitoring, security, and architecture.

## Table of Contents

- [Cluster Sizing](#cluster-sizing)
- [Capacity Planning](#capacity-planning)
- [Rolling Upgrades](#rolling-upgrades)
- [Index Template Versioning](#index-template-versioning)
- [Alias-Based Zero-Downtime Reindexing](#alias-based-zero-downtime-reindexing)
- [Backup Strategies](#backup-strategies)
- [Monitoring](#monitoring)
- [Alerting with Watcher and Kibana](#alerting-with-watcher-and-kibana)
- [Security Hardening](#security-hardening)
- [Audit Logging](#audit-logging)
- [Hot-Warm-Cold Architecture](#hot-warm-cold-architecture)

---

## Cluster Sizing

### Node types and recommended specs

| Node Role | CPU | Memory | Disk | Count |
|-----------|-----|--------|------|-------|
| Master-eligible | 4-8 cores | 8-16 GB | 50 GB SSD | 3 (always odd) |
| Hot data | 16-64 cores | 64-128 GB | NVMe SSD, 1-10 TB | Scale with ingest rate |
| Warm data | 8-16 cores | 32-64 GB | SSD or HDD, 5-20 TB | Scale with retention |
| Cold data | 4-8 cores | 16-32 GB | HDD, 10-50 TB | Scale with archive size |
| Coordinating | 8-16 cores | 32-64 GB | 50 GB SSD | 2+ for heavy query load |
| Ingest | 8-16 cores | 16-32 GB | 50 GB SSD | Scale with pipeline load |
| ML | 16+ cores | 64+ GB | 200+ GB SSD | Per ML workload |

### Shard sizing guidelines

| Metric | Target | Why |
|--------|--------|-----|
| Shard size | 10-50 GB | Too small wastes overhead; too large slows recovery |
| Shards per GB heap | < 20 | Each shard consumes ~10 MB heap |
| Total shards per node | < 1000 | Master overhead per shard |
| Shards per index | Start with 1 | Scale up only when needed |
| Docs per shard | < 2 billion | Lucene limit (2^31 - 1) |

### Calculating shard count

```
daily_data_gb = docs_per_day × avg_doc_size_kb / 1_000_000
retention_days = 90
total_data_gb = daily_data_gb × retention_days
shards_per_index = CEIL(daily_data_gb × retention_days / rollover_interval_days / target_shard_size_gb)

Example:
- 50 GB/day, 90 day retention, 7-day rollover, 30 GB target shard size
- Indices: 90 / 7 = ~13 rollover indices
- Data per index: 50 × 7 = 350 GB
- Shards per index: CEIL(350 / 30) = 12 primary shards
- Total primary shards: 13 × 12 = 156
- With 1 replica: 312 total shards
```

### JVM heap sizing

```
Rule: 50% of available RAM, max 31 GB (compressed oops threshold)

RAM     | Heap   | Notes
16 GB   | 8 GB   | Minimum for production
32 GB   | 16 GB  | Good balance
64 GB   | 31 GB  | Max recommended (leave rest for OS cache)
128 GB  | 31 GB  | Extra RAM for filesystem cache (Lucene benefits)
```

**Never exceed 31 GB heap** — crossing the compressed oops boundary wastes ~30% of heap.

---

## Capacity Planning

### Estimating storage

```
raw_data_size_gb = docs × avg_doc_size_bytes / 1e9
indexed_size_gb = raw_data_size_gb × indexing_overhead   # 1.1-1.5x typical
total_with_replicas = indexed_size_gb × (1 + replica_count)
total_with_headroom = total_with_replicas × 1.15          # 15% headroom for merges
```

### Indexing overhead factors

| Factor | Multiplier |
|--------|-----------|
| Text fields (inverted index) | 1.0-1.3x |
| Keyword fields (doc values) | 0.8-1.0x |
| Nested objects | 1 hidden doc per nested object |
| Dense vectors (768 dims, float32) | ~3 KB per doc per vector field |
| _source stored | +1x raw size (disable if not needed) |

### Benchmarking approach

1. Index representative sample (1M+ docs) to a single-shard index.
2. Measure: shard size, indexing rate, query latency.
3. Extrapolate: `num_shards = expected_total_size / target_shard_size`.
4. Load test queries at expected concurrency.
5. Add nodes until latency targets are met.

```bash
# Useful stats for capacity planning
GET /my_index/_stats/store,indexing,search
GET _cat/indices/my_index?v&h=index,pri,rep,docs.count,store.size,pri.store.size
GET _nodes/stats/fs    # disk usage
```

---

## Rolling Upgrades

### Pre-upgrade

```json
// 1. Review deprecation warnings
GET _migration/deprecations

// 2. Full snapshot
PUT _snapshot/backup_repo/pre_upgrade_snap?wait_for_completion=true
{ "indices": "*", "include_global_state": true }

// 3. Check all indices are green
GET _cluster/health

// 4. Stop unnecessary operations
// - Pause ML jobs
// - Pause ILM
POST _ilm/stop
// - Pause CCR (if applicable)
```

### Upgrade one node at a time

```json
// Step 1: Disable allocation
PUT _cluster/settings
{
  "persistent": { "cluster.routing.allocation.enable": "primaries" }
}

// Step 2: Flush
POST _flush

// Step 3: Stop the node, upgrade ES, start the node.
// Wait for it to rejoin:
GET _cat/nodes?v

// Step 4: Re-enable allocation
PUT _cluster/settings
{
  "persistent": { "cluster.routing.allocation.enable": null }
}

// Step 5: Wait for green
GET _cluster/health?wait_for_status=green&timeout=5m

// Repeat for each node. Upgrade master-eligible nodes LAST.
```

### Post-upgrade

```json
// Resume ILM
POST _ilm/start

// Resume ML jobs
// Verify no deprecation warnings remain
GET _migration/deprecations

// Update index settings for new features
```

---

## Index Template Versioning

### Versioned component templates

```json
PUT _component_template/logs_mappings_v3
{
  "template": {
    "mappings": {
      "dynamic": "strict",
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" },
        "log.level": { "type": "keyword" },
        "service.name": { "type": "keyword" },
        "trace.id": { "type": "keyword" },
        "http.status_code": { "type": "integer" }
      }
    }
  },
  "version": 3,
  "_meta": {
    "description": "Standard log mappings",
    "updated": "2024-01-15",
    "changelog": "Added http.status_code field"
  }
}

PUT _index_template/logs
{
  "index_patterns": ["logs-*"],
  "data_stream": {},
  "composed_of": ["logs_mappings_v3", "logs_settings_v2"],
  "priority": 200,
  "version": 3,
  "_meta": { "description": "Logs template v3" }
}
```

### Template change workflow

1. Create new component template version (don't modify in-place).
2. Update index template to reference new components.
3. Rollover active data streams to pick up changes.
4. Apply mapping updates to existing backing indices if needed.
5. Keep old component templates until all referencing indices are deleted.

```json
// Force rollover to pick up template changes
POST logs-app/_rollover

// Apply compatible mapping changes to existing backing indices
PUT logs-app/_mapping
{ "properties": { "http.status_code": { "type": "integer" } } }
```

---

## Alias-Based Zero-Downtime Reindexing

### Step-by-step

```json
// 1. Current state: app writes to "products" alias → "products-v1" index

// 2. Create new index with updated mappings
PUT /products-v2
{
  "settings": { "number_of_shards": 3, "number_of_replicas": 0 },
  "mappings": { "properties": { /* updated mappings */ } }
}

// 3. Reindex data (background)
POST _reindex?wait_for_completion=false
{
  "source": { "index": "products-v1" },
  "dest": { "index": "products-v2" }
}

// Monitor progress
GET _tasks?actions=*reindex*&detailed

// 4. Once complete, swap alias atomically
POST _aliases
{
  "actions": [
    { "remove": { "index": "products-v1", "alias": "products" } },
    { "add": { "index": "products-v2", "alias": "products" } }
  ]
}

// 5. Enable replicas on new index
PUT /products-v2/_settings
{ "index.number_of_replicas": 1 }

// 6. Verify, then delete old index
GET /products/_count
DELETE /products-v1
```

### Handling writes during reindex

For write-heavy indices, two strategies:

**Dual-write**: application writes to both v1 and v2 during reindex. Swap alias when reindex catches up.

**Write alias**: use separate read and write aliases:

```json
POST _aliases
{
  "actions": [
    { "add": { "index": "products-v1", "alias": "products-read" } },
    { "add": { "index": "products-v1", "alias": "products-write" } }
  ]
}
// During reindex: point products-read to both, products-write to v2
// After reindex: point both aliases to v2 only
```

---

## Backup Strategies

### Snapshot repositories

```json
// S3
PUT _snapshot/s3_repo
{
  "type": "s3",
  "settings": {
    "bucket": "es-backups",
    "base_path": "cluster-prod",
    "server_side_encryption": true,
    "storage_class": "standard_ia",
    "max_snapshot_bytes_per_sec": "200mb",
    "max_restore_bytes_per_sec": "200mb"
  }
}

// GCS
PUT _snapshot/gcs_repo
{
  "type": "gcs",
  "settings": {
    "bucket": "es-backups",
    "base_path": "cluster-prod"
  }
}

// Azure
PUT _snapshot/azure_repo
{
  "type": "azure",
  "settings": {
    "container": "es-backups",
    "base_path": "cluster-prod"
  }
}

// Shared filesystem
PUT _snapshot/fs_repo
{
  "type": "fs",
  "settings": { "location": "/mnt/backups/es" }
}
```

### SLM (Snapshot Lifecycle Management)

```json
PUT _slm/policy/nightly
{
  "schedule": "0 0 1 * * ?",
  "name": "<nightly-{now/d}>",
  "repository": "s3_repo",
  "config": {
    "indices": ["*"],
    "ignore_unavailable": true,
    "include_global_state": false
  },
  "retention": {
    "expire_after": "30d",
    "min_count": 7,
    "max_count": 90
  }
}

// Verify
GET _slm/policy/nightly
POST _slm/policy/nightly/_execute    # manual trigger
GET _slm/stats
```

### Restore procedure

```json
// List available snapshots
GET _snapshot/s3_repo/_all

// Restore specific indices
POST _snapshot/s3_repo/nightly-2024.01.15/_restore
{
  "indices": "products,orders",
  "rename_pattern": "(.+)",
  "rename_replacement": "restored-$1",
  "index_settings": {
    "index.number_of_replicas": 0
  },
  "ignore_index_settings": ["index.refresh_interval"]
}

// Monitor restore
GET _recovery?active_only=true&detailed=true
```

---

## Monitoring

### Cluster-level health

```bash
GET _cluster/health                          # overall status
GET _cluster/health?level=indices            # per-index health
GET _cluster/health?level=shards             # per-shard health
GET _cluster/stats                           # comprehensive cluster stats
GET _cluster/pending_tasks                   # queued cluster state changes
```

### Node-level stats

```bash
GET _nodes/stats                             # all stats for all nodes
GET _nodes/stats/jvm,os,fs,indices           # specific categories
GET _cat/nodes?v&h=name,role,heap.percent,ram.percent,cpu,load_1m,disk.used_percent,segments.count
GET _nodes/hot_threads                       # CPU hotspots
```

### Index-level stats

```bash
GET _cat/indices?v&s=store.size:desc&h=index,health,pri,rep,docs.count,store.size
GET /my_index/_stats                         # per-index detailed stats
GET /my_index/_stats/search,indexing,merge   # specific categories
GET /my_index/_segments                      # segment details
```

### Cat APIs reference (most useful)

```bash
GET _cat/health?v                    # cluster health
GET _cat/nodes?v                     # node list with stats
GET _cat/indices?v&s=store.size:desc # indices sorted by size
GET _cat/shards?v&s=store:desc       # shard distribution
GET _cat/allocation?v                # disk allocation per node
GET _cat/thread_pool?v&h=node_name,name,active,queue,rejected  # thread pools
GET _cat/pending_tasks?v             # pending cluster tasks
GET _cat/recovery?v&active_only=true # active shard recoveries
GET _cat/segments?v&s=size:desc      # segment details
GET _cat/fielddata?v                 # fielddata memory usage
GET _cat/master?v                    # current master node
GET _cat/plugins?v                   # installed plugins
GET _cat/templates?v                 # index templates
GET _cat/tasks?v&actions=*search*    # running tasks filtered
```

### Key metrics to track

| Metric | Warning | Critical | Source |
|--------|---------|----------|--------|
| Cluster status | yellow | red | `_cluster/health` |
| Heap usage | >75% | >85% | `_nodes/stats/jvm` |
| Disk usage | >80% | >90% | `_cat/allocation` |
| Search latency p99 | >500ms | >2s | `_nodes/stats/indices/search` |
| Indexing latency p99 | >200ms | >1s | `_nodes/stats/indices/indexing` |
| Search rejected | >0 | >10/min | `_cat/thread_pool/search` |
| Write rejected | >0 | >10/min | `_cat/thread_pool/write` |
| GC old gen time | >500ms | >1s | `_nodes/stats/jvm` |
| Pending tasks | >5 | >20 | `_cluster/pending_tasks` |
| Unassigned shards | >0 (non-new) | any primary | `_cluster/health` |

---

## Alerting with Watcher and Kibana

### Watcher (built-in)

```json
PUT _watcher/watch/cluster_health_alert
{
  "trigger": { "schedule": { "interval": "1m" } },
  "input": {
    "http": {
      "request": {
        "host": "localhost", "port": 9200, "path": "/_cluster/health",
        "scheme": "https",
        "auth": { "basic": { "username": "elastic", "password": "{{password}}" } }
      }
    }
  },
  "condition": {
    "compare": { "ctx.payload.status": { "not_eq": "green" } }
  },
  "actions": {
    "notify_slack": {
      "webhook": {
        "scheme": "https", "host": "hooks.slack.com", "port": 443,
        "method": "post", "path": "/services/XXX/YYY/ZZZ",
        "body": "{\"text\": \"ES cluster status: {{ctx.payload.status}}. Unassigned shards: {{ctx.payload.unassigned_shards}}\"}"
      }
    },
    "notify_email": {
      "email": {
        "to": "ops@company.com",
        "subject": "ES Alert: Cluster {{ctx.payload.cluster_name}} is {{ctx.payload.status}}",
        "body": "Cluster health degraded. Active shards: {{ctx.payload.active_shards}}. Unassigned: {{ctx.payload.unassigned_shards}}."
      }
    }
  }
}
```

### Watcher for disk space

```json
PUT _watcher/watch/disk_space_alert
{
  "trigger": { "schedule": { "interval": "5m" } },
  "input": {
    "http": {
      "request": {
        "host": "localhost", "port": 9200, "path": "/_cat/allocation",
        "params": { "format": "json" }
      }
    }
  },
  "condition": {
    "script": {
      "source": "return ctx.payload.any(node -> node['disk.percent'] != null && Integer.parseInt(node['disk.percent']) > 85)"
    }
  },
  "actions": {
    "log_alert": {
      "logging": { "text": "Disk usage alert: nodes exceeding 85%" }
    }
  }
}
```

### Kibana alerting (preferred for most teams)

1. **Stack Management → Rules → Create Rule**
2. Select rule type: Elasticsearch query, Index threshold, or Cluster health
3. Configure conditions and actions (email, Slack, PagerDuty, webhook)
4. Set check interval and notification throttle

Recommended Kibana alerts:
- Cluster health != green
- Disk usage > 80% on any node
- Heap usage > 80% sustained 5min
- Search/write thread pool rejections > 0
- Unassigned shards > 0
- Indexing rate drops > 50% from baseline
- Search latency p95 > threshold

---

## Security Hardening

### Transport and HTTP TLS

```yaml
# elasticsearch.yml
xpack.security.enabled: true

# Transport layer (inter-node)
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.keystore.path: elastic-certificates.p12

# HTTP layer (client connections)
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.keystore.path: http.p12
```

### Authentication

```json
// API keys (preferred for services)
POST /_security/api_key
{
  "name": "app-backend",
  "expiration": "90d",
  "role_descriptors": {
    "app_role": {
      "cluster": ["monitor"],
      "index": [{
        "names": ["products*", "orders*"],
        "privileges": ["read", "write", "create_index"]
      }]
    }
  },
  "metadata": { "application": "backend", "team": "platform" }
}

// Rotate: create new key, update apps, invalidate old
POST /_security/api_key/_invalidate
{ "ids": ["old_key_id"] }
```

### Authorization (RBAC)

```json
// Read-only role
POST /_security/role/analyst
{
  "cluster": ["monitor"],
  "indices": [{
    "names": ["logs-*", "metrics-*"],
    "privileges": ["read", "view_index_metadata"],
    "field_security": {
      "grant": ["*"],
      "except": ["user.email", "user.ip"]
    }
  }]
}

// Index-specific write role
POST /_security/role/ingest_writer
{
  "cluster": [],
  "indices": [{
    "names": ["logs-app-*"],
    "privileges": ["create_doc", "create_index", "auto_configure"]
  }]
}

// Document-level security
POST /_security/role/team_reader
{
  "indices": [{
    "names": ["tickets-*"],
    "privileges": ["read"],
    "query": { "term": { "team": "engineering" } }
  }]
}
```

### Network security

```yaml
# elasticsearch.yml
# Bind to specific interface
network.host: _site_

# Restrict HTTP access
http.host: 10.0.0.0/8

# IP filtering
xpack.security.transport.filter.allow: ["10.0.0.0/8"]
xpack.security.transport.filter.deny: ["_all"]
```

### Checklist

- [ ] Change `elastic` superuser password
- [ ] Disable unused built-in users
- [ ] Enable TLS on transport and HTTP
- [ ] Use API keys (not passwords) for services
- [ ] Apply least-privilege roles
- [ ] Enable audit logging
- [ ] Restrict network binding
- [ ] Set up IP filtering
- [ ] Rotate API keys on schedule
- [ ] Review roles quarterly

---

## Audit Logging

```yaml
# elasticsearch.yml
xpack.security.audit.enabled: true

# Log to file (default) and/or index
xpack.security.audit.outputs: [logfile, index]

# Filter what gets logged
xpack.security.audit.logfile.events.include:
  - access_denied
  - access_granted
  - anonymous_access_denied
  - authentication_failed
  - connection_denied
  - tampered_request
  - run_as_denied
  - run_as_granted

xpack.security.audit.logfile.events.exclude:
  - access_granted    # too noisy in most clusters

# Filter by user (log only specific users)
xpack.security.audit.logfile.events.ignore_filters:
  system_filter:
    users: ["_xpack_security", "_xpack"]
```

### Query audit index

```json
POST /.security-audit-*/_search
{
  "query": {
    "bool": {
      "must": [
        { "term": { "event.action": "access_denied" } },
        { "range": { "@timestamp": { "gte": "now-24h" } } }
      ]
    }
  },
  "sort": [{ "@timestamp": "desc" }],
  "size": 100
}
```

---

## Hot-Warm-Cold Architecture

### Node configuration

```yaml
# Hot node (fast SSDs, high CPU)
node.roles: [data_hot, ingest]
path.data: /nvme/elasticsearch

# Warm node (larger SSDs or fast HDDs)
node.roles: [data_warm]
path.data: /ssd/elasticsearch

# Cold node (HDDs, high capacity)
node.roles: [data_cold]
path.data: /hdd/elasticsearch

# Frozen node (minimal local, backed by snapshots)
node.roles: [data_frozen]
path.data: /hdd/elasticsearch
xpack.searchable.snapshot.shared_cache.size: 90%
```

### ILM policy for tiered architecture

```json
PUT _ilm/policy/tiered_policy
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": { "max_primary_shard_size": "50gb", "max_age": "7d" },
          "set_priority": { "priority": 100 }
        }
      },
      "warm": {
        "min_age": "30d",
        "actions": {
          "shrink": { "number_of_shards": 1 },
          "forcemerge": { "max_num_segments": 1 },
          "set_priority": { "priority": 50 },
          "allocate": { "number_of_replicas": 1 }
        }
      },
      "cold": {
        "min_age": "90d",
        "actions": {
          "set_priority": { "priority": 0 },
          "searchable_snapshot": {
            "snapshot_repository": "cold_repo",
            "force_merge_index": true
          }
        }
      },
      "frozen": {
        "min_age": "180d",
        "actions": {
          "searchable_snapshot": {
            "snapshot_repository": "frozen_repo"
          }
        }
      },
      "delete": {
        "min_age": "365d",
        "actions": {
          "wait_for_snapshot": { "policy": "nightly" },
          "delete": {}
        }
      }
    }
  }
}
```

### Data stream with tier preference

```json
PUT _index_template/logs_tiered
{
  "index_patterns": ["logs-*"],
  "data_stream": {},
  "template": {
    "settings": {
      "number_of_shards": 2,
      "number_of_replicas": 1,
      "index.lifecycle.name": "tiered_policy",
      "index.routing.allocation.include._tier_preference": "data_hot"
    }
  },
  "priority": 200
}
```

### Verify tier allocation

```bash
GET _cat/shards?v&h=index,shard,prirep,state,node,store&s=index
GET _cat/nodeattrs?v&h=node,attr,value
GET _cat/nodes?v&h=name,role,disk.used_percent
```

### Cost optimization

| Tier | Data Age | Storage Cost | Query Latency |
|------|----------|-------------|---------------|
| Hot | 0-30 days | $$$ (NVMe) | <100ms |
| Warm | 30-90 days | $$ (SSD) | <500ms |
| Cold | 90-180 days | $ (HDD/snapshot) | <2s |
| Frozen | 180+ days | ¢ (object storage) | <10s |

Typical savings: 60-80% reduction in storage costs vs. keeping everything on hot tier.
