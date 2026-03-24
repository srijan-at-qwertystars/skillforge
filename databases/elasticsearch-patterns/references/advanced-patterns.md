# Elasticsearch Advanced Patterns

> Dense reference for advanced ES 8.x features. Each section is self-contained with production-ready examples.

## Table of Contents

- [Index Lifecycle Management (ILM)](#index-lifecycle-management-ilm)
- [Data Streams](#data-streams)
- [Cross-Cluster Search (CCS)](#cross-cluster-search-ccs)
- [Cross-Cluster Replication (CCR)](#cross-cluster-replication-ccr)
- [Snapshot and Restore](#snapshot-and-restore)
- [Searchable Snapshots](#searchable-snapshots)
- [Runtime Fields](#runtime-fields)
- [Field Aliases](#field-aliases)
- [Ingest Pipelines](#ingest-pipelines)
- [Transform Jobs](#transform-jobs)
- [Rollup Jobs](#rollup-jobs)
- [Async Search](#async-search)
- [Point-in-Time API](#point-in-time-api)
- [ES|QL Deep Dive](#esql-deep-dive)
- [Vector Search Strategies](#vector-search-strategies)
- [Semantic Search with ELSER](#semantic-search-with-elser)
- [Relevance Tuning](#relevance-tuning)

---

## Index Lifecycle Management (ILM)

ILM automates index phase transitions: hot → warm → cold → frozen → delete.

### Complete ILM policy with all phases

```json
PUT _ilm/policy/production_policy
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_primary_shard_size": "50gb",
            "max_age": "7d",
            "max_docs": 100000000
          },
          "set_priority": { "priority": 100 },
          "forcemerge": { "max_num_segments": 1 }
        }
      },
      "warm": {
        "min_age": "30d",
        "actions": {
          "set_priority": { "priority": 50 },
          "shrink": { "number_of_shards": 1 },
          "forcemerge": { "max_num_segments": 1 },
          "allocate": {
            "number_of_replicas": 1,
            "require": { "data": "warm" }
          },
          "readonly": {}
        }
      },
      "cold": {
        "min_age": "90d",
        "actions": {
          "set_priority": { "priority": 0 },
          "searchable_snapshot": {
            "snapshot_repository": "cold_repo",
            "force_merge_index": true
          },
          "allocate": {
            "require": { "data": "cold" }
          }
        }
      },
      "frozen": {
        "min_age": "180d",
        "actions": {
          "searchable_snapshot": {
            "snapshot_repository": "frozen_repo",
            "force_merge_index": true
          }
        }
      },
      "delete": {
        "min_age": "365d",
        "actions": {
          "wait_for_snapshot": {
            "policy": "daily_backup"
          },
          "delete": {}
        }
      }
    }
  }
}
```

### Attach ILM to index template

```json
PUT _index_template/logs_template
{
  "index_patterns": ["logs-*"],
  "template": {
    "settings": {
      "index.lifecycle.name": "production_policy",
      "index.lifecycle.rollover_alias": "logs"
    }
  }
}
```

### Monitor ILM status

```
GET logs-*/_ilm/explain
GET _ilm/status
POST _ilm/retry                            # retry failed steps
PUT logs-000001/_settings
{ "index.lifecycle.origination_date": 1609459200000 }  # backdate for testing
```

### Common ILM pitfalls

- **Rollover requires a write alias**: bootstrap index must have `is_write_index: true`.
- **min_age is from rollover**, not index creation (unless `origination_date` set).
- **forcemerge blocks writes**: only use on read-only indices (warm+).
- **Shrink requires all shards on one node**: ensure enough disk on target node.

---

## Data Streams

Append-only time-series data backed by auto-rolling hidden indices. Always require `@timestamp`.

### Create data stream with component templates

```json
PUT _component_template/logs_mappings
{
  "template": {
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" },
        "log.level": { "type": "keyword" },
        "service.name": { "type": "keyword" },
        "host.name": { "type": "keyword" },
        "trace.id": { "type": "keyword" }
      }
    }
  }
}

PUT _component_template/logs_settings
{
  "template": {
    "settings": {
      "number_of_shards": 2,
      "number_of_replicas": 1,
      "index.lifecycle.name": "production_policy"
    }
  }
}

PUT _index_template/logs
{
  "index_patterns": ["logs-*"],
  "data_stream": {},
  "composed_of": ["logs_mappings", "logs_settings"],
  "priority": 200,
  "_meta": { "description": "Template for application logs" }
}
```

### Operate on data streams

```
POST logs-app/_doc
{ "@timestamp": "2024-01-15T10:00:00Z", "message": "Request processed", "log.level": "info" }

POST logs-app/_rollover                     # force rollover
POST logs-app/_doc/abc123?op_type=index     # cannot use create (append-only)
DELETE _data_stream/logs-app                # deletes all backing indices

GET _data_stream/logs-app                   # inspect backing indices
GET _resolve/index/logs-*                   # resolve data streams and aliases
```

### Update mappings on data streams

```json
PUT _component_template/logs_mappings
{
  "template": {
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "message": { "type": "text" },
        "log.level": { "type": "keyword" },
        "service.name": { "type": "keyword" },
        "host.name": { "type": "keyword" },
        "trace.id": { "type": "keyword" },
        "http.status_code": { "type": "integer" }
      }
    }
  }
}

POST logs-app/_rollover   # new field only applies to new backing index
PUT logs-app/_mapping      # apply to existing backing indices too
{ "properties": { "http.status_code": { "type": "integer" } } }
```

---

## Cross-Cluster Search (CCS)

Query remote clusters from a local cluster without data replication.

### Configure remote cluster

```json
PUT _cluster/settings
{
  "persistent": {
    "cluster.remote.cluster_west": {
      "seeds": ["west-node1:9300", "west-node2:9300"],
      "transport.compress": true,
      "skip_unavailable": true
    },
    "cluster.remote.cluster_east": {
      "seeds": ["east-node1:9300"],
      "skip_unavailable": true
    }
  }
}

GET _remote/info    # verify connectivity
```

### Cross-cluster queries

```json
POST /cluster_west:logs-*,cluster_east:logs-*,logs-*/_search
{
  "query": { "match": { "message": "error" } },
  "sort": [{ "@timestamp": "desc" }],
  "size": 100
}

// Minimize round trips with ccs_minimize_roundtrips (default true in 8.x)
POST /cluster_west:logs-*/_search?ccs_minimize_roundtrips=true
{ "query": { "range": { "@timestamp": { "gte": "now-1h" } } } }
```

### CCS with API keys

```json
POST /_security/api_key
{
  "name": "ccs-key",
  "role_descriptors": {
    "ccs_role": {
      "cluster": ["cross_cluster_search"],
      "index": [{ "names": ["logs-*"], "privileges": ["read"] }]
    }
  }
}
```

---

## Cross-Cluster Replication (CCR)

Replicate indices from leader to follower cluster for DR or geo-locality.

```json
// On follower cluster: follow a leader index
PUT /products-replica/_ccr/follow
{
  "remote_cluster": "cluster_primary",
  "leader_index": "products",
  "max_read_request_operation_count": 5120,
  "max_outstanding_read_requests": 12,
  "max_write_buffer_count": 2147483647,
  "max_write_buffer_size": "512mb"
}

// Auto-follow pattern (all new indices matching pattern)
PUT /_ccr/auto_follow/logs_pattern
{
  "remote_cluster": "cluster_primary",
  "leader_index_patterns": ["logs-*"],
  "follow_index_pattern": "{{leader_index}}-replica"
}

// Monitoring
GET /_ccr/stats
GET /products-replica/_ccr/stats
POST /products-replica/_ccr/pause_follow
POST /products-replica/_ccr/resume_follow
```

---

## Snapshot and Restore

### Register repository (S3 example)

```json
PUT _snapshot/s3_backup
{
  "type": "s3",
  "settings": {
    "bucket": "es-backups",
    "region": "us-east-1",
    "base_path": "production",
    "max_snapshot_bytes_per_sec": "200mb",
    "max_restore_bytes_per_sec": "200mb",
    "server_side_encryption": true
  }
}
```

### Snapshot operations

```json
// Create snapshot (async by default)
PUT _snapshot/s3_backup/snapshot_2024_01_15
{
  "indices": "products,logs-*",
  "ignore_unavailable": true,
  "include_global_state": false,
  "metadata": { "taken_by": "admin", "reason": "pre-upgrade" }
}

// SLM (Snapshot Lifecycle Management)
PUT _slm/policy/nightly_backup
{
  "schedule": "0 0 2 * * ?",
  "name": "<nightly-{now/d}>",
  "repository": "s3_backup",
  "config": {
    "indices": ["*"],
    "ignore_unavailable": true,
    "include_global_state": false
  },
  "retention": {
    "expire_after": "30d",
    "min_count": 5,
    "max_count": 50
  }
}

// Restore
POST _snapshot/s3_backup/snapshot_2024_01_15/_restore
{
  "indices": "products",
  "rename_pattern": "(.+)",
  "rename_replacement": "restored_$1",
  "index_settings": { "index.number_of_replicas": 0 }
}

// Monitor
GET _snapshot/s3_backup/_status
GET _snapshot/s3_backup/snapshot_2024_01_15
GET _recovery?active_only=true
```

---

## Searchable Snapshots

Mount snapshots as read-only indices. Two tiers:

| Mount Type | Cache | Latency | Cost | Use Case |
|-----------|-------|---------|------|----------|
| `full_copy` | Full local cache | Fast | Medium | Cold tier |
| `shared_cache` | Shared node cache | Variable | Low | Frozen tier |

```json
// Mount fully cached (cold tier)
POST _snapshot/s3_backup/snap1/_mount
{
  "index": "logs-2023",
  "renamed_index": "logs-2023-cold",
  "index_settings": { "index.number_of_replicas": 0 },
  "storage": "full_copy"
}

// Mount with shared cache (frozen tier)
POST _snapshot/s3_backup/snap1/_mount
{
  "index": "logs-2022",
  "storage": "shared_cache"
}

GET _cat/indices/logs-2023-cold?v    # verify mounted
```

---

## Runtime Fields

Computed fields at query time. No reindexing needed. Trade CPU for flexibility.

```json
// Define in mapping (persistent)
PUT /logs/_mapping
{
  "runtime": {
    "day_of_week": {
      "type": "keyword",
      "script": "emit(doc['@timestamp'].value.dayOfWeekEnum.getDisplayName(TextStyle.FULL, Locale.ROOT))"
    },
    "duration_seconds": {
      "type": "double",
      "script": "emit(doc['duration_ms'].value / 1000.0)"
    },
    "full_name": {
      "type": "keyword",
      "script": "emit(doc['first_name'].value + ' ' + doc['last_name'].value)"
    }
  }
}

// Define at query time (ad-hoc)
POST /logs/_search
{
  "runtime_mappings": {
    "hour_of_day": {
      "type": "long",
      "script": "emit(doc['@timestamp'].value.getHour())"
    }
  },
  "query": { "range": { "hour_of_day": { "gte": 9, "lte": 17 } } },
  "aggs": { "by_hour": { "terms": { "field": "hour_of_day" } } }
}

// Lookup runtime field (enrich-like without ingest pipeline)
PUT /orders/_mapping
{
  "runtime": {
    "customer_name": {
      "type": "lookup",
      "target_index": "customers",
      "input_field": "customer_id",
      "target_field": "_id",
      "fetch_fields": ["name"]
    }
  }
}
```

**When to use**: prototyping mappings, ad-hoc analytics, avoiding reindex. Move to indexed fields once queries stabilize.

---

## Field Aliases

Point one field name to another. Useful during migration.

```json
PUT /my_index/_mapping
{
  "properties": {
    "user_id": { "type": "alias", "path": "legacy_uid" }
  }
}

// Now queries on "user_id" resolve to "legacy_uid"
POST /my_index/_search
{ "query": { "term": { "user_id": "abc123" } } }
```

Limitations: aliases cannot be used in `_source`, `doc_values`, or `stored_fields`.

---

## Ingest Pipelines

Process documents before indexing. Chain processors for ETL.

### Grok processor (regex-based parsing)

```json
PUT _ingest/pipeline/apache_logs
{
  "description": "Parse Apache access logs",
  "processors": [
    {
      "grok": {
        "field": "message",
        "patterns": [
          "%{COMBINEDAPACHELOG}"
        ],
        "ignore_failure": true
      }
    },
    {
      "date": {
        "field": "timestamp",
        "formats": ["dd/MMM/yyyy:HH:mm:ss Z"],
        "target_field": "@timestamp"
      }
    },
    {
      "convert": { "field": "response", "type": "integer" }
    },
    {
      "convert": { "field": "bytes", "type": "long", "ignore_missing": true }
    },
    {
      "user_agent": { "field": "agent", "target_field": "user_agent" }
    },
    {
      "geoip": { "field": "clientip", "target_field": "geo" }
    },
    {
      "remove": { "field": ["message", "timestamp", "agent"], "ignore_missing": true }
    }
  ],
  "on_failure": [
    {
      "set": {
        "field": "_index",
        "value": "failed-logs"
      }
    },
    {
      "set": {
        "field": "error.message",
        "value": "{{ _ingest.on_failure_message }}"
      }
    }
  ]
}
```

### Dissect processor (delimiter-based, faster than grok)

```json
{
  "dissect": {
    "field": "message",
    "pattern": "%{ts} %{+ts} %{level} [%{thread}] %{logger} - %{msg}",
    "append_separator": " "
  }
}
```

### Enrich processor (join external data)

```json
// 1. Create enrich policy source index
PUT /geo_data/_doc/1
{ "zip": "10001", "city": "New York", "state": "NY", "coords": { "lat": 40.7, "lon": -74.0 } }

// 2. Define enrich policy
PUT _enrich/policy/zip_lookup
{
  "match": {
    "indices": "geo_data",
    "match_field": "zip",
    "enrich_fields": ["city", "state", "coords"]
  }
}

// 3. Execute policy (creates internal .enrich-* index)
POST _enrich/policy/zip_lookup/_execute

// 4. Use in pipeline
PUT _ingest/pipeline/enrich_zip
{
  "processors": [
    {
      "enrich": {
        "policy_name": "zip_lookup",
        "field": "zip_code",
        "target_field": "geo",
        "max_matches": 1
      }
    }
  ]
}
```

### Test and simulate pipelines

```json
POST _ingest/pipeline/apache_logs/_simulate
{
  "docs": [
    { "_source": { "message": "83.149.9.216 - - [17/May/2024:10:05:03 +0000] \"GET /index.html HTTP/1.1\" 200 1234 \"http://example.com\" \"Mozilla/5.0\"" } }
  ]
}
```

---

## Transform Jobs

Create entity-centric summaries from event data (like materialized views).

```json
PUT _transform/customer_summary
{
  "source": {
    "index": "orders",
    "query": { "range": { "order_date": { "gte": "now-1y" } } }
  },
  "dest": { "index": "customer_summaries" },
  "pivot": {
    "group_by": {
      "customer_id": { "terms": { "field": "customer_id" } }
    },
    "aggregations": {
      "total_orders": { "value_count": { "field": "order_id" } },
      "total_spent": { "sum": { "field": "total_amount" } },
      "avg_order": { "avg": { "field": "total_amount" } },
      "last_order": { "max": { "field": "order_date" } },
      "top_category": {
        "scripted_metric": {
          "init_script": "state.cats = [:]",
          "map_script": "def c = doc['category'].value; state.cats[c] = (state.cats[c] ?: 0) + 1",
          "combine_script": "return state.cats",
          "reduce_script": "def merged = [:]; for (s in states) { for (e in s.entrySet()) { merged[e.key] = (merged[e.key] ?: 0) + e.value } } return merged.max { it.value }?.key"
        }
      }
    }
  },
  "frequency": "5m",
  "sync": {
    "time": { "field": "order_date", "delay": "1m" }
  },
  "retention_policy": {
    "time": { "field": "last_order", "max_age": "365d" }
  }
}

POST _transform/customer_summary/_start
GET _transform/customer_summary/_stats
```

---

## Rollup Jobs

Pre-aggregate historical time-series data to reduce storage. (Legacy — prefer transforms or downsampling in 8.x.)

```json
PUT _rollup/job/metrics_rollup
{
  "index_pattern": "metrics-*",
  "rollup_index": "metrics-rollup",
  "cron": "0 */20 * * * ?",
  "page_size": 1000,
  "groups": {
    "date_histogram": { "field": "timestamp", "fixed_interval": "1h" },
    "terms": { "fields": ["host", "datacenter"] }
  },
  "metrics": [
    { "field": "cpu_usage", "metrics": ["avg", "max", "min"] },
    { "field": "memory_usage", "metrics": ["avg", "max"] },
    { "field": "request_count", "metrics": ["sum", "value_count"] }
  ]
}

POST _rollup/job/metrics_rollup/_start
```

**8.x downsampling** (preferred):

```json
POST /metrics-2023.01/_downsample/metrics-2023.01-1h
{
  "fixed_interval": "1h"
}
```

---

## Async Search

Submit long-running queries, poll for results. Ideal for complex aggregations or cross-cluster searches.

```json
// Submit async search
POST /logs-*/_async_search?wait_for_completion_timeout=5s&keep_alive=1m
{
  "size": 0,
  "aggs": {
    "per_service": {
      "terms": { "field": "service.name", "size": 1000 },
      "aggs": {
        "error_rate": {
          "avg": { "script": "doc['status_code'].value >= 500 ? 1 : 0" }
        }
      }
    }
  }
}

// Response includes { "id": "FjE1..." } if not completed within timeout

// Poll for results
GET _async_search/FjE1...

// Get status only (no results)
GET _async_search/status/FjE1...

// Delete when done
DELETE _async_search/FjE1...
```

---

## Point-in-Time API

Freeze a consistent view of data for paginating. Preferred over scroll in 8.x.

```json
// Open PIT
POST /products/_pit?keep_alive=5m
// Returns: { "id": "46ToAwMDaWR..." }

// First page
POST /_search
{
  "size": 100,
  "pit": { "id": "46ToAwMDaWR...", "keep_alive": "5m" },
  "sort": [
    { "created_at": "desc" },
    { "_shard_doc": "asc" }
  ],
  "query": { "match_all": {} }
}

// Next page: add search_after from last hit's sort values
POST /_search
{
  "size": 100,
  "pit": { "id": "46ToAwMDaWR...", "keep_alive": "5m" },
  "sort": [
    { "created_at": "desc" },
    { "_shard_doc": "asc" }
  ],
  "search_after": ["2024-01-14T23:59:59Z", 42],
  "query": { "match_all": {} }
}

// Close PIT when done
DELETE /_pit
{ "id": "46ToAwMDaWR..." }
```

**Rules**: always include `_shard_doc` in sort for PIT. Extend `keep_alive` on each request. Close PITs to free resources.

---

## ES|QL Deep Dive

Pipe-based query language. Compiled to Lucene queries — often faster than equivalent Query DSL.

### Multi-value handling

```esql
FROM products
| WHERE tags == "electronics"         // matches if ANY value in array matches
| EVAL tag_count = MV_COUNT(tags)
| EVAL first_tag = MV_FIRST(tags)
| MV_EXPAND tags                      // explode: one row per array element
```

### Enrichment and lookups

```esql
FROM orders
| ENRICH customer_policy ON customer_id WITH customer_name, segment
| WHERE segment == "enterprise"
| STATS total = SUM(amount) BY customer_name
| SORT total DESC
| LIMIT 20
```

### String parsing

```esql
FROM web_logs
| DISSECT message "%{method} %{path} HTTP/%{version}"
| GROK path "%{WORD:section}/%{WORD:page}"
| EVAL path_length = LENGTH(path)
| STATS hits = COUNT(*) BY section
```

### Date and math functions

```esql
FROM events
| EVAL hour = DATE_EXTRACT("HOUR_OF_DAY", @timestamp)
| EVAL day = DATE_FORMAT("EEEE", @timestamp)
| EVAL age_days = DATE_DIFF("day", created_at, NOW())
| WHERE age_days <= 30
| STATS events = COUNT(*) BY day, hour
```

### Using ES|QL via API

```json
POST /_query
{
  "query": "FROM logs-* | WHERE @timestamp >= NOW() - 1 hour | STATS count = COUNT(*) BY log.level | SORT count DESC",
  "columnar": false,
  "locale": "en"
}
```

---

## Vector Search Strategies

### HNSW tuning

```json
PUT /vectors
{
  "mappings": {
    "properties": {
      "embedding": {
        "type": "dense_vector",
        "dims": 768,
        "index": true,
        "similarity": "cosine",
        "index_options": {
          "type": "hnsw",
          "m": 16,
          "ef_construction": 100
        }
      }
    }
  }
}
```

| Parameter | Default | Effect |
|-----------|---------|--------|
| `m` | 16 | Graph connectivity. Higher = better recall, more RAM |
| `ef_construction` | 100 | Build-time quality. Higher = better index, slower build |
| `num_candidates` (query) | — | Search beam width. 1.5-10x `k` typical |

### Quantization strategies

```json
// int8 quantization (~4x memory reduction, <5% recall loss)
{ "index_options": { "type": "int8_hnsw", "m": 16, "ef_construction": 100, "confidence_interval": 0.99 } }

// int4 quantization (~8x memory reduction, experimental in 8.x)
{ "index_options": { "type": "int4_hnsw" } }

// Binary quantization (bbq — 32x reduction)
{ "index_options": { "type": "bbq_hnsw" } }
```

### Hybrid search (kNN + BM25)

```json
POST /docs/_search
{
  "query": { "match": { "content": "machine learning transformers" } },
  "knn": {
    "field": "embedding",
    "query_vector": [0.1, 0.2, 0.3],
    "k": 10,
    "num_candidates": 50,
    "boost": 0.3
  },
  "_source": ["title", "content"],
  "size": 10
}
```

### Pre-filtering kNN

```json
POST /docs/_search
{
  "knn": {
    "field": "embedding",
    "query_vector": [0.1, 0.2, 0.3],
    "k": 10,
    "num_candidates": 100,
    "filter": {
      "bool": {
        "must": [
          { "term": { "category": "research" } },
          { "range": { "date": { "gte": "2023-01-01" } } }
        ]
      }
    }
  }
}
```

---

## Semantic Search with ELSER

ELSER (Elastic Learned Sparse EncodeR) generates sparse vectors — works like BM25 but with semantic understanding.

### Deploy ELSER model

```json
// Download and deploy
PUT _ml/trained_models/.elser_model_2
{ "input": { "field_names": ["text_field"] } }

POST _ml/trained_models/.elser_model_2/deployment/_start
{ "number_of_allocations": 2, "threads_per_allocation": 1 }
```

### Ingest with ELSER

```json
PUT _ingest/pipeline/elser_pipeline
{
  "processors": [
    {
      "inference": {
        "model_id": ".elser_model_2",
        "input_output": [
          { "input_field": "content", "output_field": "content_embedding" }
        ]
      }
    }
  ]
}

PUT /articles
{
  "mappings": {
    "properties": {
      "content": { "type": "text" },
      "content_embedding": { "type": "sparse_vector" }
    }
  }
}
```

### Query with ELSER

```json
POST /articles/_search
{
  "query": {
    "sparse_vector": {
      "field": "content_embedding",
      "inference_id": ".elser_model_2",
      "query": "how do neural networks learn?"
    }
  }
}
```

### Hybrid: ELSER + BM25 with RRF

```json
POST /articles/_search
{
  "retriever": {
    "rrf": {
      "retrievers": [
        { "standard": { "query": { "match": { "content": "neural networks" } } } },
        { "standard": { "query": { "sparse_vector": { "field": "content_embedding", "inference_id": ".elser_model_2", "query": "neural networks" } } } }
      ],
      "rank_window_size": 100,
      "rank_constant": 60
    }
  }
}
```

---

## Relevance Tuning

### function_score

```json
POST /products/_search
{
  "query": {
    "function_score": {
      "query": { "multi_match": { "query": "wireless headphones", "fields": ["name^3", "description"] } },
      "functions": [
        {
          "field_value_factor": {
            "field": "sales_count",
            "modifier": "log1p",
            "factor": 0.5,
            "missing": 1
          },
          "weight": 2
        },
        {
          "gauss": {
            "created_at": {
              "origin": "now",
              "scale": "30d",
              "decay": 0.5
            }
          },
          "weight": 1
        },
        {
          "filter": { "term": { "featured": true } },
          "weight": 5
        }
      ],
      "score_mode": "sum",
      "boost_mode": "multiply",
      "max_boost": 100
    }
  }
}
```

### Rescoring (2-phase ranking)

```json
POST /products/_search
{
  "query": { "match": { "name": "laptop" } },
  "rescore": {
    "window_size": 100,
    "query": {
      "rescore_query": {
        "function_score": {
          "script_score": {
            "script": "_score * doc['quality_score'].value * (1 + doc['review_count'].value / 100.0)"
          }
        }
      },
      "query_weight": 0.7,
      "rescore_query_weight": 1.2
    }
  }
}
```

### Learning to Rank (LTR)

```json
// 1. Define feature set
PUT _ltr/_featureset/product_features
{
  "featureset": {
    "features": [
      { "name": "title_match", "params": ["query"], "template": { "match": { "title": "{{query}}" } } },
      { "name": "price_factor", "params": [], "template": { "function_score": { "field_value_factor": { "field": "price", "modifier": "reciprocal" } } } },
      { "name": "popularity", "params": [], "template": { "function_score": { "field_value_factor": { "field": "popularity" } } } }
    ]
  }
}

// 2. Train model externally (XGBoost/LambdaMART), upload
POST _ltr/_featureset/product_features/_createmodel
{
  "model": {
    "name": "product_ranker_v1",
    "model": { "type": "model/xgboost+json", "definition": "<model_json>" }
  }
}

// 3. Use in rescore
POST /products/_search
{
  "query": { "match": { "title": "laptop" } },
  "rescore": {
    "window_size": 100,
    "query": {
      "rescore_query": {
        "sltr": {
          "params": { "query": "laptop" },
          "model": "product_ranker_v1"
        }
      }
    }
  }
}
```

### Relevance debugging

```json
// Explain scoring for a specific doc
GET /products/_explain/doc_id
{ "query": { "match": { "name": "laptop" } } }

// Profile query execution
POST /products/_search
{ "profile": true, "query": { "match": { "name": "laptop" } } }

// Rank Evaluation API
POST /products/_rank_eval
{
  "requests": [
    {
      "id": "query_1",
      "request": { "query": { "match": { "name": "laptop" } } },
      "ratings": [
        { "_index": "products", "_id": "1", "rating": 3 },
        { "_index": "products", "_id": "2", "rating": 1 }
      ]
    }
  ],
  "metric": { "dcg": { "k": 10, "normalize": true } }
}
```
