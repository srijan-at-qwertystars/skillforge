# Advanced ELK Stack Patterns Reference

Practical reference for advanced Elasticsearch, Logstash, and Kibana patterns.

---

## Table of Contents

1. [Elasticsearch Advanced Queries](#1-elasticsearch-advanced-queries)
   - [Script Queries](#11-script-queries)
   - [Runtime Fields](#12-runtime-fields)
   - [Search Templates](#13-search-templates)
   - [Async Search](#14-async-search)
2. [Aggregation Pipelines](#2-aggregation-pipelines)
   - [Pipeline Aggregations](#21-pipeline-aggregations)
   - [Matrix Aggregations](#22-matrix-aggregations)
   - [Composite Aggregations](#23-composite-aggregations)
3. [Analyzer Customization](#3-analyzer-customization)
   - [Character Filters](#31-character-filters)
   - [Custom Tokenizers](#32-custom-tokenizers)
   - [Token Filters](#33-token-filters)
   - [Full Custom Analyzer Examples](#34-full-custom-analyzer-examples)
4. [Cross-Cluster Search and Replication](#4-cross-cluster-search-and-replication)
   - [Remote Cluster Setup](#41-remote-cluster-setup)
   - [Cross-Cluster Search (CCS)](#42-cross-cluster-search-ccs)
   - [Cross-Cluster Replication (CCR)](#43-cross-cluster-replication-ccr)
5. [Data Streams and ILM Policy Design](#5-data-streams-and-ilm-policy-design)
   - [Data Stream Internals](#51-data-stream-internals)
   - [ILM Policy Design Patterns](#52-ilm-policy-design-patterns)
   - [Data Stream Lifecycle (DSL)](#53-data-stream-lifecycle-dsl)
   - [Composable Index Templates](#54-composable-index-templates)
6. [Ingest Pipeline Processors](#6-ingest-pipeline-processors)
   - [Script Processor](#61-script-processor)
   - [Enrich Processor](#62-enrich-processor)
   - [GeoIP and Circle Processors](#63-geoip-and-circle-processors)
   - [Pipeline Chaining and Conditional Execution](#64-pipeline-chaining-and-conditional-execution)
7. [Rollups and Transforms](#7-rollups-and-transforms)
   - [Rollup Jobs](#71-rollup-jobs)
   - [Transforms](#72-transforms)
8. [Searchable Snapshots](#8-searchable-snapshots)
   - [Frozen Tier and Mounting](#81-frozen-tier-and-mounting)
   - [Cost Optimization Strategies](#82-cost-optimization-strategies)
9. [Elastic Agent Fleet Management](#9-elastic-agent-fleet-management)
   - [Fleet Server Setup](#91-fleet-server-setup)
   - [Agent Policies and Integrations](#92-agent-policies-and-integrations)
   - [Upgrade and Monitoring](#93-upgrade-and-monitoring)

---

## 1. Elasticsearch Advanced Queries

### 1.1 Script Queries

Painless scripts enable custom filtering logic that cannot be expressed with standard query DSL.

```json
POST /sales/_search
{
  "query": {
    "bool": {
      "filter": {
        "script": {
          "script": {
            "source": "double margin = (doc['revenue'].value - doc['cost'].value) / doc['revenue'].value; return margin > params.min_margin;",
            "lang": "painless",
            "params": { "min_margin": 0.25 }
          }
        }
      }
    }
  }
}
```

Script scoring adjusts relevance with custom calculations:

```json
POST /products/_search
{
  "query": {
    "script_score": {
      "query": { "match": { "description": "wireless headphones" } },
      "script": {
        "source": "_score * Math.log(2 + doc['rating'].value) * decayDateGauss(params.origin, params.scale, params.offset, params.decay, doc['release_date'].value)",
        "params": { "origin": "2024-01-01", "scale": "90d", "offset": "7d", "decay": 0.5 }
      }
    }
  }
}
```

### 1.2 Runtime Fields

Define fields at query time without re-indexing. Evaluated on the fly per search.

```json
POST /web-logs/_search
{
  "runtime_mappings": {
    "response_bucket": {
      "type": "keyword",
      "script": {
        "source": "long ms = doc['response_time_ms'].value; if (ms < 100) emit('fast'); else if (ms < 500) emit('normal'); else emit('slow');"
      }
    }
  },
  "aggs": { "by_bucket": { "terms": { "field": "response_bucket" } } },
  "size": 0
}
```

Add runtime fields persistently to an index mapping:

```json
PUT /web-logs/_mapping
{
  "runtime": {
    "day_of_week": {
      "type": "keyword",
      "script": { "source": "emit(doc['@timestamp'].value.dayOfWeekEnum.getDisplayName(TextStyle.FULL, Locale.ROOT));" }
    }
  }
}
```

### 1.3 Search Templates

Mustache-based parameterized queries stored in the cluster state.

```json
PUT _scripts/log_search_template
{
  "script": {
    "lang": "mustache",
    "source": {
      "query": {
        "bool": {
          "must": [{ "match": { "message": "{{query_string}}" } }],
          "filter": [
            { "range": { "@timestamp": { "gte": "{{from}}", "lte": "{{to}}" } } },
            {{#severity}}{ "term": { "log.level": "{{severity}}" } },{{/severity}}
            { "term": { "service.name": "{{service}}" } }
          ]
        }
      },
      "size": "{{size}}{{^size}}50{{/size}}"
    }
  }
}

POST /app-logs/_search/template
{
  "id": "log_search_template",
  "params": {
    "query_string": "connection timeout",
    "from": "2024-06-01T00:00:00Z",
    "to": "2024-06-30T23:59:59Z",
    "service": "payment-api",
    "severity": "ERROR"
  }
}
```

### 1.4 Async Search

For long-running queries — submit, poll, and retrieve results asynchronously.

```json
POST /massive-dataset-*/_async_search?wait_for_completion_timeout=5s&keep_alive=1m
{
  "query": { "bool": { "filter": [
    { "range": { "@timestamp": { "gte": "now-365d" } } },
    { "term": { "status": "error" } }
  ]}},
  "aggs": { "errors_weekly": { "date_histogram": { "field": "@timestamp", "calendar_interval": "week" } } },
  "size": 0
}
// Response: { "id": "FkZ2...", "is_partial": true, ... }

GET /_async_search/FkZ2...?wait_for_completion_timeout=10s
DELETE /_async_search/FkZ2...
```

---

## 2. Aggregation Pipelines

### 2.1 Pipeline Aggregations

Pipeline aggregations operate on the output of other aggregations — derivative, cumulative sum, moving average, bucket script, and bucket selector.

```json
POST /metrics/_search
{
  "size": 0,
  "aggs": {
    "sales_per_month": {
      "date_histogram": { "field": "@timestamp", "calendar_interval": "month" },
      "aggs": {
        "total_sales": { "sum": { "field": "amount" } },
        "sales_derivative": { "derivative": { "buckets_path": "total_sales" } },
        "cumulative_sales": { "cumulative_sum": { "buckets_path": "total_sales" } },
        "sales_moving_avg": {
          "moving_avg": { "buckets_path": "total_sales", "window": 3, "model": "ewma", "settings": { "alpha": 0.5 } }
        }
      }
    }
  }
}
```

`bucket_script` computes custom per-bucket metrics; `bucket_selector` filters buckets:

```json
POST /ecommerce/_search
{
  "size": 0,
  "aggs": {
    "by_category": {
      "terms": { "field": "category.keyword", "size": 100 },
      "aggs": {
        "total_revenue": { "sum": { "field": "revenue" } },
        "total_cost": { "sum": { "field": "cost" } },
        "profit_margin": {
          "bucket_script": {
            "buckets_path": { "rev": "total_revenue", "cost": "total_cost" },
            "script": "(params.rev - params.cost) / params.rev * 100"
          }
        },
        "high_margin_only": {
          "bucket_selector": {
            "buckets_path": { "margin": "profit_margin" },
            "script": "params.margin > 30"
          }
        }
      }
    }
  }
}
```

### 2.2 Matrix Aggregations

Compute multi-field statistics (mean, variance, covariance, correlation) in a single pass.

```json
POST /sensor-data/_search
{
  "size": 0,
  "aggs": {
    "sensor_stats": {
      "matrix_stats": {
        "fields": ["temperature", "humidity", "pressure"],
        "missing": { "temperature": 20.0, "humidity": 50.0 }
      }
    }
  }
}
```

### 2.3 Composite Aggregations

Paginate through large aggregation result sets efficiently using `after`.

```json
POST /logs/_search
{
  "size": 0,
  "aggs": {
    "log_groups": {
      "composite": {
        "size": 500,
        "sources": [
          { "service": { "terms": { "field": "service.name" } } },
          { "level": { "terms": { "field": "log.level" } } },
          { "hour": { "date_histogram": { "field": "@timestamp", "calendar_interval": "hour" } } }
        ],
        "after": { "service": "payment-api", "level": "WARN", "hour": 1719878400000 }
      },
      "aggs": { "avg_duration": { "avg": { "field": "duration_ms" } } }
    }
  }
}
```

---

## 3. Analyzer Customization

### 3.1 Character Filters

Transform raw text before tokenization.

```json
PUT /content-index
{
  "settings": { "analysis": { "char_filter": {
    "strip_html": { "type": "html_strip", "escaped_tags": ["code", "pre"] },
    "normalize_dashes": { "type": "pattern_replace", "pattern": "[–—]", "replacement": "-" },
    "emoticon_map": { "type": "mapping", "mappings": [":) => _happy_", ":( => _sad_", "<3 => _heart_"] }
  }}}
}
```

### 3.2 Custom Tokenizers

```json
PUT /log-analysis
{
  "settings": { "analysis": { "tokenizer": {
    "log_pattern": { "type": "pattern", "pattern": "[\\s|,;:]+", "group": -1 },
    "kv_tokenizer": { "type": "char_group", "tokenize_on_chars": ["=", "&", " ", "\t"] },
    "filepath_tok": { "type": "path_hierarchy", "delimiter": "/", "replacement": "/" }
  }}}
}
```

### 3.3 Token Filters

Modify, add, or remove tokens after tokenization.

```json
PUT /search-index
{
  "settings": { "analysis": { "filter": {
    "eng_synonyms": { "type": "synonym", "synonyms": ["k8s, kubernetes", "db, database", "err, error, exception"] },
    "eng_stemmer": { "type": "stemmer", "language": "english" },
    "autocomplete_edge": { "type": "edge_ngram", "min_gram": 2, "max_gram": 15 },
    "eng_stop": { "type": "stop", "stopwords": "_english_" },
    "lc": { "type": "lowercase" }
  }}}
}
```

### 3.4 Full Custom Analyzer Examples

**Log analyzer** — strips ANSI codes, tokenizes on whitespace/brackets, normalizes levels:

```json
PUT /application-logs
{
  "settings": {
    "analysis": {
      "char_filter": { "strip_ansi": { "type": "pattern_replace", "pattern": "\\u001B\\[[0-9;]*m", "replacement": "" } },
      "tokenizer": { "log_tok": { "type": "pattern", "pattern": "[\\s\\[\\](){}]+", "group": -1 } },
      "filter": { "level_synonyms": { "type": "synonym", "synonyms": ["err, error, ERROR", "warn, warning, WARN"] } },
      "analyzer": { "log_analyzer": { "type": "custom", "char_filter": ["strip_ansi"], "tokenizer": "log_tok", "filter": ["lowercase", "level_synonyms"] } }
    }
  },
  "mappings": { "properties": { "message": { "type": "text", "analyzer": "log_analyzer", "fields": { "raw": { "type": "keyword" } } } } }
}
```

**Autocomplete analyzer** — edge_ngram at index time, standard at search time:

```json
PUT /products-search
{
  "settings": {
    "analysis": {
      "filter": { "ac_ngram": { "type": "edge_ngram", "min_gram": 1, "max_gram": 20 } },
      "analyzer": {
        "autocomplete_index": { "type": "custom", "tokenizer": "standard", "filter": ["lowercase", "ac_ngram"] },
        "autocomplete_search": { "type": "custom", "tokenizer": "standard", "filter": ["lowercase"] }
      }
    }
  },
  "mappings": { "properties": { "name": { "type": "text", "analyzer": "autocomplete_index", "search_analyzer": "autocomplete_search" } } }
}
```

---

## 4. Cross-Cluster Search and Replication

### 4.1 Remote Cluster Setup

```json
PUT /_cluster/settings
{
  "persistent": {
    "cluster.remote": {
      "cluster_west": { "seeds": ["es-west-01:9300", "es-west-02:9300"], "transport.compress": true, "skip_unavailable": true },
      "cluster_eu": { "mode": "proxy", "proxy_address": "es-proxy-eu:9443", "num_proxy_sockets_per_connection": 18, "skip_unavailable": true }
    }
  }
}
```

### 4.2 Cross-Cluster Search (CCS)

Query multiple clusters using `cluster_name:index` prefix syntax.

```json
POST /local-logs,cluster_west:app-logs,cluster_eu:app-logs/_search?ccs_minimize_roundtrips=true
{
  "query": { "bool": {
    "must": [{ "match": { "message": "auth failure" } }],
    "filter": [{ "range": { "@timestamp": { "gte": "now-24h" } } }]
  }},
  "size": 100
}
```

### 4.3 Cross-Cluster Replication (CCR)

Replicate indices from a leader cluster to a follower for DR or read scaling.

```json
// Manual follower
PUT /app-logs-replica/_ccr/follow
{
  "remote_cluster": "cluster_west",
  "leader_index": "app-logs-2024.06",
  "max_read_request_operation_count": 5120,
  "max_write_buffer_size": "512mb"
}

// Auto-follow pattern for new indices
PUT /_ccr/auto_follow/replicate-logs
{
  "remote_cluster": "cluster_west",
  "leader_index_patterns": ["app-logs-*", "metrics-*"],
  "leader_index_exclusion_patterns": ["*-tmp"],
  "follow_index_pattern": "{{leader_index}}-replica",
  "settings": { "index.number_of_replicas": 1 }
}
```

**Use cases:** disaster recovery (failover to follower region), geo-proximity reads, centralized reporting across clusters.

---

## 5. Data Streams and ILM Policy Design

### 5.1 Data Stream Internals

Data streams abstract time-series data over automatically managed backing indices (`.ds-<stream>-<date>-<gen>`). The most recent backing index is the **write index**; rollover creates a new write index while older ones become read-only.

```json
GET /_data_stream/logs-nginx-default
POST /logs-nginx-default/_rollover
```

### 5.2 ILM Policy Design Patterns

**High-volume logs — 30-day retention:**

```json
PUT _ilm/policy/logs-standard
{
  "policy": { "phases": {
    "hot":  { "actions": { "rollover": { "max_primary_shard_size": "50gb", "max_age": "1d" }, "set_priority": { "priority": 100 } } },
    "warm": { "min_age": "2d", "actions": { "shrink": { "number_of_shards": 1 }, "forcemerge": { "max_num_segments": 1 }, "allocate": { "require": { "data": "warm" } } } },
    "cold": { "min_age": "14d", "actions": { "allocate": { "require": { "data": "cold" } } } },
    "delete": { "min_age": "30d", "actions": { "delete": {} } }
  }}
}
```

**Compliance — 7-year retention with frozen tier:**

```json
PUT _ilm/policy/audit-compliance
{
  "policy": { "phases": {
    "hot":    { "actions": { "rollover": { "max_primary_shard_size": "50gb", "max_age": "1d" } } },
    "warm":   { "min_age": "7d", "actions": { "shrink": { "number_of_shards": 1 }, "forcemerge": { "max_num_segments": 1 } } },
    "cold":   { "min_age": "90d", "actions": { "searchable_snapshot": { "snapshot_repository": "s3-snapshots" } } },
    "frozen": { "min_age": "365d", "actions": { "searchable_snapshot": { "snapshot_repository": "s3-archive" } } },
    "delete": { "min_age": "2555d", "actions": { "delete": {} } }
  }}
}
```

### 5.3 Data Stream Lifecycle (DSL)

Simplified retention management introduced in Elasticsearch 8.14+, without phase transitions.

```json
PUT _data_stream/logs-app-prod/_lifecycle
{ "data_retention": "30d" }

PUT /_cluster/settings
{ "persistent": { "data_streams.lifecycle.retention.default": "90d", "data_streams.lifecycle.retention.max": "365d" } }
```

### 5.4 Composable Index Templates

Build data stream templates from reusable component templates.

```json
PUT _component_template/logs-mappings
{ "template": { "mappings": { "properties": {
  "@timestamp": { "type": "date" }, "message": { "type": "text" },
  "log.level": { "type": "keyword" }, "service.name": { "type": "keyword" }
}}}}

PUT _component_template/logs-settings
{ "template": { "settings": {
  "index.lifecycle.name": "logs-standard", "index.number_of_shards": 2, "index.codec": "best_compression"
}}}

PUT _index_template/logs-app
{ "index_patterns": ["logs-app-*"], "data_stream": {}, "composed_of": ["logs-mappings", "logs-settings"], "priority": 200 }
```

---

## 6. Ingest Pipeline Processors

### 6.1 Script Processor

Painless scripts for arbitrary document transformations at ingest time.

```json
PUT _ingest/pipeline/enrich-logs
{
  "processors": [{
    "script": {
      "source": "int code = ctx['status_code']; if (code >= 500) ctx['severity'] = 'critical'; else if (code >= 400) ctx['severity'] = 'warning'; else ctx['severity'] = 'info'; if (ctx.containsKey('start_ts') && ctx.containsKey('end_ts')) { long s = ZonedDateTime.parse(ctx['start_ts']).toInstant().toEpochMilli(); long e = ZonedDateTime.parse(ctx['end_ts']).toInstant().toEpochMilli(); ctx['duration_ms'] = e - s; }"
    }
  }]
}
```

### 6.2 Enrich Processor

Look up data from a dedicated enrich index and attach it to incoming documents.

```json
// 1. Define and execute an enrich policy
PUT /_enrich/policy/ip-lookup
{
  "match": { "indices": "ip-geo-data", "match_field": "cidr", "enrich_fields": ["region", "owner"] }
}
POST /_enrich/policy/ip-lookup/_execute

// 2. Use in an ingest pipeline
PUT _ingest/pipeline/add-geo-info
{
  "processors": [{
    "enrich": { "policy_name": "ip-lookup", "field": "client.ip", "target_field": "client.geo", "max_matches": 1 }
  }]
}
```

### 6.3 GeoIP and Circle Processors

```json
PUT _ingest/pipeline/geo-pipeline
{
  "processors": [
    { "geoip": { "field": "source.ip", "target_field": "source.geo", "properties": ["city_name", "country_name", "location"], "ignore_missing": true } },
    { "circle": { "field": "area", "error_distance": 10.0, "shape_type": "geo_shape", "ignore_missing": true } }
  ]
}
```

### 6.4 Pipeline Chaining and Conditional Execution

Use `pipeline` processors for delegation, `if` for conditional logic, `dissect` for parsing, and `foreach` for iteration.

```json
PUT _ingest/pipeline/router-pipeline
{
  "processors": [
    { "pipeline": { "if": "ctx.agent?.type == 'filebeat'", "name": "filebeat-processing" } },
    { "pipeline": { "if": "ctx.agent?.type == 'metricbeat'", "name": "metricbeat-processing" } },
    { "dissect": {
      "if": "ctx.message != null && ctx.message.startsWith('{') == false",
      "field": "message",
      "pattern": "%{timestamp} %{log_level} [%{thread}] %{logger} - %{msg}",
      "on_failure": [{ "set": { "field": "_dissect_failed", "value": true } }]
    }},
    { "foreach": {
      "if": "ctx.tags instanceof List",
      "field": "tags",
      "processor": { "lowercase": { "field": "_ingest._value" } }
    }}
  ]
}
```

---

## 7. Rollups and Transforms

### 7.1 Rollup Jobs

Pre-aggregate historical data into compact summaries for long-term analysis.

```json
PUT _rollup/job/metrics-hourly
{
  "index_pattern": "metrics-raw-*",
  "rollup_index": "metrics-rollup",
  "cron": "0 0 * * * ?",
  "page_size": 1000,
  "groups": {
    "date_histogram": { "field": "@timestamp", "fixed_interval": "1h", "delay": "7d" },
    "terms": { "fields": ["service.name", "host.name"] }
  },
  "metrics": [
    { "field": "cpu.usage", "metrics": ["avg", "max", "min"] },
    { "field": "request.count", "metrics": ["sum", "value_count"] }
  ]
}

POST _rollup/job/metrics-hourly/_start
```

### 7.2 Transforms

**Pivot transform** — create entity-centric summaries from event data:

```json
PUT _transform/customer-360
{
  "source": { "index": ["orders-*"], "query": { "range": { "@timestamp": { "gte": "now-2y" } } } },
  "dest": { "index": "customer-summary" },
  "pivot": {
    "group_by": { "customer_id": { "terms": { "field": "customer.id" } } },
    "aggregations": {
      "total_orders": { "value_count": { "field": "order.id" } },
      "total_spend": { "sum": { "field": "order.total" } },
      "avg_order": { "avg": { "field": "order.total" } },
      "last_order": { "max": { "field": "@timestamp" } }
    }
  },
  "frequency": "15m",
  "sync": { "time": { "field": "@timestamp", "delay": "1m" } }
}
POST _transform/customer-360/_start
```

**Latest transform** — keep only the most recent document per entity:

```json
PUT _transform/latest-device-status
{
  "source": { "index": "device-events-*" },
  "dest": { "index": "device-status-latest" },
  "latest": { "unique_key": ["device.id"], "sort": "@timestamp" },
  "sync": { "time": { "field": "@timestamp", "delay": "30s" } },
  "frequency": "30s"
}
```

---

## 8. Searchable Snapshots

### 8.1 Frozen Tier and Mounting

Register a snapshot repository and mount snapshots as searchable indices.

```json
PUT /_snapshot/s3-archive
{
  "type": "s3",
  "settings": { "bucket": "elk-snapshots-prod", "region": "us-east-1", "base_path": "es/snapshots" }
}

PUT /_snapshot/s3-archive/snap-2024-06
{ "indices": "logs-*-2024.05.*", "include_global_state": false }
```

**Fully mounted** (cold tier — restored to local disk, full performance):

```json
POST /_snapshot/s3-archive/snap-2024-06/_mount?storage=full_copy
{ "index": "logs-app-2024.05.01", "renamed_index": "restored-logs-2024.05.01" }
```

**Partially mounted** (frozen tier — data on object storage, local cache):

```json
POST /_snapshot/s3-archive/snap-2024-06/_mount?storage=shared_cache
{ "index": "logs-app-2024.05.01", "renamed_index": "frozen-logs-2024.05.01" }
```

Frozen-tier node configuration (`elasticsearch.yml`):

```yaml
node.roles: [data_frozen]
xpack.searchable.snapshot.shared_cache.size: 90%
xpack.searchable.snapshot.shared_cache.size.max_headroom: 100GB
```

### 8.2 Cost Optimization Strategies

- **Automate tier transitions via ILM** — hot → warm → cold (fully mounted) → frozen (partially mounted) → delete.
- **Size the shared cache** — monitor hit rates with `GET /_nodes/stats/searchable_snapshots`.
- **Use frozen tier for compliance data** — 80-90% storage cost reduction vs. hot tier.
- **Use async search for frozen queries** — they can be slow; async prevents timeouts.

---

## 9. Elastic Agent Fleet Management

### 9.1 Fleet Server Setup

Fleet Server is the central coordination point for Elastic Agents.

```yaml
# docker-compose.yml excerpt
services:
  fleet-server:
    image: docker.elastic.co/beats/elastic-agent:8.14.0
    environment:
      - FLEET_SERVER_ENABLE=true
      - FLEET_SERVER_ELASTICSEARCH_HOST=https://es-node-01:9200
      - FLEET_SERVER_SERVICE_TOKEN=AAEAAWVs...token
      - FLEET_SERVER_POLICY_ID=fleet-server-policy
      - FLEET_SERVER_PORT=8220
    ports: ["8220:8220"]
```

Generate a service token: `POST /_security/service/elastic/fleet-server/credential/token/fleet-token-1`

### 9.2 Agent Policies and Integrations

```json
// Create an agent policy
POST kbn:/api/fleet/agent_policies
{ "name": "Production Linux Servers", "namespace": "production", "monitoring_enabled": ["logs", "metrics"] }

// Add an integration to the policy
POST kbn:/api/fleet/package_policies
{
  "name": "system-metrics",
  "policy_id": "<agent_policy_id>",
  "package": { "name": "system", "version": "1.54.0" },
  "inputs": {
    "system-logfile": { "enabled": true, "streams": {
      "system.syslog": { "vars": { "paths": ["/var/log/syslog", "/var/log/messages"] } }
    }},
    "system-metrics": { "enabled": true, "streams": {
      "system.cpu": { "vars": { "period": "30s" } },
      "system.memory": { "vars": { "period": "30s" } }
    }}
  }
}

// Configure output
PUT kbn:/api/fleet/outputs/default
{
  "name": "Production ES",
  "type": "elasticsearch",
  "hosts": ["https://es-node-01:9200", "https://es-node-02:9200"],
  "config_yaml": "bulk_max_size: 1600\nworker: 4"
}
```

### 9.3 Upgrade and Monitoring

```json
// Bulk upgrade agents with a rolling window
POST kbn:/api/fleet/agents/bulk_upgrade
{
  "version": "8.14.1",
  "agents": "policy_id:<policy_id>",
  "start_time": "2024-07-01T02:00:00Z",
  "rollout_duration_seconds": 3600
}

// Check agent health
GET kbn:/api/fleet/agent_status?policyId=<policy_id>
GET kbn:/api/fleet/agents?kuery=status:degraded%20OR%20status:offline&perPage=50
```

Query agent metrics directly in Elasticsearch:

```json
POST /metrics-elastic_agent*/_search
{
  "query": { "bool": { "filter": [
    { "range": { "@timestamp": { "gte": "now-15m" } } },
    { "term": { "data_stream.dataset": "elastic_agent.metricbeat" } }
  ]}},
  "aggs": { "by_agent": { "terms": { "field": "agent.id" }, "aggs": {
    "cpu": { "top_metrics": { "metrics": { "field": "system.cpu.total.pct" }, "sort": { "@timestamp": "desc" } } }
  }}},
  "size": 0
}
```
