---
name: elasticsearch-patterns
description: >
  USE when user asks about Elasticsearch, ES, Elastic, OpenSearch, ELK stack,
  Kibana, Logstash, Beats, search indexing, inverted index, full-text search with
  Elasticsearch, ES Query DSL, ES|QL, Lucene queries, analyzers/tokenizers,
  Elasticsearch mappings, shard management, index lifecycle management (ILM),
  data streams, Elasticsearch aggregations, Elasticsearch bulk API, reindex,
  Elasticsearch security/RBAC, Elasticsearch vector search / kNN, search_as_you_type,
  Elasticsearch client libraries (elasticsearch-py, @elastic/elasticsearch, olivere/elastic),
  Elasticsearch cluster health, cat APIs, or Elasticsearch performance tuning.
  DO NOT USE for ClickHouse (use clickhouse skill), DuckDB (use duckdb skill),
  pgvector (use pgvector skill), PostgreSQL full-text search, Solr, Meilisearch,
  Typesense, Algolia, Redis Search, or general SQL databases.
---

# Elasticsearch 8.x Patterns

Target ES 8.x. Security enabled by default. Single `_doc` type. Always use HTTPS + auth.

## Architecture

- **Cluster**: nodes sharing cluster name. One elected master.
- **Node roles**: `master`, `data`, `data_hot`, `data_warm`, `data_cold`, `data_frozen`, `ingest`, `ml`, `coordinating` (no roles).
- **Index**: logical namespace mapped to one or more shards. **Shard**: a Lucene index (primary or replica). **Segment**: immutable file within shard; segments merge over time.
- Dedicate 3+ master nodes in production. Use hot/warm/cold data tiers for cost optimization.

## Index Management

### Create index with mappings and settings

```json
PUT /products
{
  "settings": { "number_of_shards": 3, "number_of_replicas": 1, "refresh_interval": "5s" },
  "mappings": { "properties": {
    "name":        { "type": "text", "analyzer": "standard" },
    "sku":         { "type": "keyword" },
    "price":       { "type": "scaled_float", "scaling_factor": 100 },
    "description": { "type": "text", "fields": { "keyword": { "type": "keyword", "ignore_above": 256 }}},
    "created_at":  { "type": "date", "format": "strict_date_optional_time||epoch_millis" },
    "location":    { "type": "geo_point" },
    "tags":        { "type": "keyword" },
    "metadata":    { "type": "object" },
    "variants":    { "type": "nested", "properties": { "color": { "type": "keyword" }, "size": { "type": "keyword" }}},
    "embedding":   { "type": "dense_vector", "dims": 768, "index": true, "similarity": "cosine" }
  }}
}
```

### Field types: `text` (analyzed full-text), `keyword` (exact match/sort/agg), `integer`/`long`/`float`/`double`, `scaled_float`, `date`, `boolean`, `object` (flattened), `nested` (preserves array-of-object boundaries), `geo_point`, `geo_shape`, `dense_vector` (kNN), `search_as_you_type` (autocomplete), `ip`, `completion` (FST suggest), `flattened` (entire JSON as one field).

### Aliases for zero-downtime reindexing

```json
POST /_aliases
{ "actions": [
  { "add": { "index": "products-v2", "alias": "products" }},
  { "remove": { "index": "products-v1", "alias": "products" }}
]}
```

### Index templates and data streams

```json
PUT _component_template/base_settings
{ "template": { "settings": { "number_of_shards": 2, "number_of_replicas": 1 }}}

PUT _index_template/logs_template
{ "index_patterns": ["logs-*"], "data_stream": {}, "composed_of": ["base_settings"], "priority": 200 }
```

Data streams: append-only time-series (logs, metrics). Backed by auto-rolling hidden indices. Always require `@timestamp`.

### ILM (Index Lifecycle Management)

```json
PUT _ilm/policy/logs_policy
{ "policy": { "phases": {
  "hot":    { "actions": { "rollover": { "max_size": "50gb", "max_age": "7d" }}},
  "warm":   { "min_age": "30d", "actions": { "shrink": { "number_of_shards": 1 }, "forcemerge": { "max_num_segments": 1 }}},
  "cold":   { "min_age": "90d", "actions": { "searchable_snapshot": { "snapshot_repository": "my_repo" }}},
  "delete": { "min_age": "365d", "actions": { "delete": {} }}
}}}
```

Phases: hot -> warm -> cold -> frozen -> delete. Attach to index templates.

## Query DSL

### Match (full-text) and Term (exact)

```json
// Full-text (analyzed):
{ "query": { "match": { "description": { "query": "wireless bluetooth", "operator": "and" }}}}
// Exact (keyword fields only, NEVER on text):
{ "query": { "term": { "sku": { "value": "ABC-123" }}}}
```

### Bool query

```json
{ "query": { "bool": {
  "must":     [{ "match": { "name": "laptop" }}],
  "filter":   [{ "range": { "price": { "gte": 500, "lte": 2000 }}}, { "term": { "in_stock": true }}],
  "should":   [{ "match": { "description": "gaming" }}],
  "must_not": [{ "term": { "brand": "excluded_brand" }}],
  "minimum_should_match": 1
}}}
```

Put non-scoring clauses in `filter` -- cached and skip scoring.

### Multi-match

```json
{ "query": { "multi_match": { "query": "search terms", "fields": ["name^3", "description"], "type": "best_fields" }}}
```

Types: `best_fields`, `most_fields`, `cross_fields`, `phrase`, `phrase_prefix`.

### Nested query (required for `nested` type fields)

```json
{ "query": { "nested": { "path": "variants", "query": { "bool": { "must": [
  { "term": { "variants.color": "red" }}, { "term": { "variants.size": "L" }}
]}}}}}
```

### Function score

```json
{ "query": { "function_score": {
  "query": { "match": { "name": "shoes" }},
  "functions": [
    { "field_value_factor": { "field": "popularity", "modifier": "log1p", "factor": 2 }},
    { "gauss": { "location": { "origin": "40.7,-74.0", "scale": "5km" }}}
  ],
  "boost_mode": "multiply", "score_mode": "sum"
}}}
```

## Full-Text Search and Analyzers

Analyzer = character filters -> tokenizer -> token filters.

```json
PUT /my_index
{ "settings": { "analysis": {
  "analyzer": { "my_custom": {
    "type": "custom", "tokenizer": "standard",
    "char_filter": ["html_strip"],
    "filter": ["lowercase", "asciifolding", "my_synonym", "my_stop"]
  }},
  "filter": {
    "my_synonym": { "type": "synonym", "synonyms": ["laptop,notebook", "phone,mobile"] },
    "my_stop": { "type": "stop", "stopwords": "_english_" }
  }
}}}
```

Built-in: `standard`, `simple`, `whitespace`, `keyword`, `pattern`, language analyzers.

```json
// Test analyzer:
POST /_analyze
{ "analyzer": "standard", "text": "The Quick Brown Fox" }
// Output tokens: ["the", "quick", "brown", "fox"]
```

### search_as_you_type (autocomplete)

```json
// Mapping:
{ "properties": { "title": { "type": "search_as_you_type" }}}
// Query:
{ "query": { "multi_match": { "query": "elast", "type": "bool_prefix",
  "fields": ["title", "title._2gram", "title._3gram"] }}}
```

## Aggregations

### Terms with sub-aggregation

```json
{ "size": 0, "aggs": { "by_brand": {
  "terms": { "field": "brand", "size": 20 },
  "aggs": { "avg_price": { "avg": { "field": "price" }}}
}}}
// Response buckets: [{ "key": "Apple", "doc_count": 150, "avg_price": { "value": 1299.5 }}, ...]
```

### Date histogram

```json
{ "size": 0, "aggs": { "over_time": {
  "date_histogram": { "field": "created_at", "calendar_interval": "month" },
  "aggs": { "revenue": { "sum": { "field": "price" }}}
}}}
```

### Composite (paginated aggs)

```json
{ "size": 0, "aggs": { "my_composite": { "composite": { "size": 100, "sources": [
  { "brand": { "terms": { "field": "brand" }}},
  { "category": { "terms": { "field": "category" }}}
]}}}}
// Next page: add "after": { "brand": "...", "category": "..." } from previous response
```

### Nested agg and pipeline agg

```json
// Nested:
{ "aggs": { "variants": { "nested": { "path": "variants" },
  "aggs": { "colors": { "terms": { "field": "variants.color" }}}}}}
// Pipeline:
{ "size": 0, "aggs": {
  "monthly": { "date_histogram": { "field": "date", "calendar_interval": "month" },
    "aggs": { "total": { "sum": { "field": "amount" }}}},
  "max_monthly": { "max_bucket": { "buckets_path": "monthly>total" }}
}}
```

## Pagination

| Method | Use | Limit |
|--------|-----|-------|
| `from`/`size` | UI paging, small sets | 10,000 max |
| `search_after` | Deep pagination, stateless | Needs sort values |
| PIT + `search_after` | Consistent deep pagination | Preferred in 8.x |
| Scroll | Batch export | Avoid for user-facing |

```json
// Open PIT, search with sort, pass search_after for next page, close PIT:
POST /products/_pit?keep_alive=5m   // returns { "id": "abc..." }
POST /_search
{ "size": 100, "pit": { "id": "abc...", "keep_alive": "5m" },
  "sort": [{ "created_at": "desc" }, { "_shard_doc": "asc" }] }
// Next: add "search_after": [<last_sort_values>]
DELETE /_pit { "id": "abc..." }
```

## Bulk Operations

```json
POST /_bulk
{"index":{"_index":"products","_id":"1"}}
{"name":"Widget","price":9.99}
{"delete":{"_index":"products","_id":"3"}}
{"update":{"_index":"products","_id":"1"}}
{"doc":{"price":8.99}}
```

- Batch 5-15 MB. Parse response for per-item errors (bulk returns 200 on partial failure).
- Set `refresh_interval: "-1"` and `replicas: 0` during large ingests. Restore after.
- Use 8-16 concurrent threads for throughput.

```json
// Reindex with optional pipeline:
POST /_reindex { "source": { "index": "v1" }, "dest": { "index": "v2", "pipeline": "enrich" }}
// Update by query:
POST /products/_update_by_query
{ "query": { "term": { "status": "draft" }}, "script": { "source": "ctx._source.status = 'published'" }}
```

## Client Libraries

### Python (elasticsearch-py)

```python
from elasticsearch import Elasticsearch
es = Elasticsearch("https://localhost:9200", api_key="key", ca_certs="/path/to/http_ca.crt")
es.index(index="products", id="1", document={"name": "Widget", "price": 9.99})
resp = es.search(index="products", query={"match": {"name": "widget"}})

from elasticsearch.helpers import bulk
actions = [{"_index": "products", "_id": i, "_source": {"name": f"Item {i}"}} for i in range(1000)]
success, errors = bulk(es, actions, chunk_size=500, raise_on_error=False)
```

### Node.js (@elastic/elasticsearch)

```typescript
import { Client } from '@elastic/elasticsearch';
const client = new Client({ node: 'https://localhost:9200', auth: { apiKey: 'key' },
  tls: { ca: fs.readFileSync('/path/to/http_ca.crt') }});
const result = await client.search({ index: 'products', query: { match: { name: 'widget' } } });
const { errors } = await client.bulk({ operations: items.flatMap(d => [{ index: { _index: 'products' } }, d]) });
```

### Go (elastic/go-elasticsearch v8)

```go
es, _ := elasticsearch.NewClient(elasticsearch.Config{
  Addresses: []string{"https://localhost:9200"}, APIKey: "key",
})
res, _ := es.Search(es.Search.WithIndex("products"),
  es.Search.WithBody(strings.NewReader(`{"query":{"match":{"name":"widget"}}}`)))
```

## Security

ES 8.x enables security by default: TLS on transport+HTTP, built-in users.

```json
// Create API key with scoped permissions:
POST /_security/api_key
{ "name": "backend-key", "expiration": "90d", "role_descriptors": {
  "reader": { "cluster": ["monitor"], "index": [{ "names": ["products*"], "privileges": ["read"] }] }
}}
// Use: Authorization: ApiKey <encoded>

// Role with field-level + document-level security:
POST /_security/role/pii_restricted
{ "indices": [{ "names": ["users*"], "privileges": ["read"],
  "field_security": { "grant": ["name", "email"], "except": ["ssn"] },
  "query": { "term": { "department": "engineering" }}
}]}
```

- Use API keys for service auth, not username/password. Set expiration and rotate.
- Apply least-privilege roles. Use field_security for PII protection.
- Change `elastic` superuser password immediately. Disable unused built-in users.

## Performance Tuning

**Shard sizing**: 10-50 GB/shard. Under 20 shards per GB heap per node. Under 1000 total shards/node.

**Indexing**: `refresh_interval: "30s"` or `"-1"` during bulk. Use `_bulk` API (not single-doc). Disable replicas during initial load.

**Query optimization**:
- Filters in `bool.filter` (cached, no scoring). Avoid leading wildcards.
- `keyword` for exact match/sort/agg. `search_after`+PIT over deep `from/size`.
- `"size": 0` for agg-only queries. `_source: false` or `fields` to limit data.
- Profile: `GET /index/_search?profile=true`.

## Observability

```
GET _cluster/health            // green/yellow/red status
GET _cat/indices?v&s=store.size:desc&h=index,health,pri,rep,docs.count,store.size
GET _cat/shards?v&s=store:desc
GET _cat/nodes?v&h=name,heap.percent,ram.percent,cpu,load_1m
GET _cat/thread_pool?v&h=node_name,name,active,queue,rejected
GET _nodes/hot_threads         // high CPU diagnosis
GET _tasks?actions=*search&detailed
```

### Slow log

```json
PUT /my_index/_settings
{ "index.search.slowlog.threshold.query.warn": "5s",
  "index.search.slowlog.threshold.query.info": "2s",
  "index.indexing.slowlog.threshold.index.warn": "10s" }
```

## Vector Search / kNN

```json
// Mapping:
{ "properties": { "embedding": { "type": "dense_vector", "dims": 768, "index": true, "similarity": "cosine" }}}

// kNN search:
POST /my_index/_search
{ "knn": { "field": "embedding", "query_vector": [0.1, 0.2], "k": 10, "num_candidates": 100 },
  "fields": ["title"] }

// Hybrid (kNN + text):
{ "query": { "match": { "content": "machine learning" }},
  "knn": { "field": "embedding", "query_vector": [0.1, 0.2], "k": 10, "num_candidates": 100, "boost": 0.5 }}

// Quantized index for scale (int8 reduces memory ~4x):
{ "properties": { "embedding": { "type": "dense_vector", "dims": 768, "index": true,
  "similarity": "cosine", "index_options": { "type": "int8_hnsw" }}}}
```

Similarity: `cosine`, `dot_product` (normalize first), `l2_norm`, `max_inner_product`.

## ES|QL

Pipe-delimited query language. Simpler than Query DSL for analytics.

```esql
FROM logs-*
| WHERE @timestamp >= NOW() - 24 hours AND level == "error"
| STATS error_count = COUNT(*) BY service.name
| SORT error_count DESC
| LIMIT 10
```

Commands: `FROM` (source), `WHERE` (filter), `EVAL` (compute columns), `STATS ... BY` (aggregate), `SORT`, `LIMIT`, `KEEP`/`DROP` (select/remove columns), `RENAME`, `ENRICH` (join), `DISSECT`/`GROK` (parse strings).

```json
POST /_query
{ "query": "FROM products | WHERE price > 100 | STATS avg_price = AVG(price) BY brand | SORT avg_price DESC" }
```

## ELK Stack

- **Logstash**: data pipeline (inputs -> filters -> outputs). Use for complex ETL.
- **Kibana**: visualization, dashboards, Lens, Discover, Dev Tools console.
- **Beats**: lightweight shippers (Filebeat, Metricbeat, Packetbeat, Heartbeat).
- **Elastic Agent / Fleet**: unified agent replacing Beats. Centrally managed. Prefer for new deployments.

## Common Pitfalls

- **Mapping explosion**: set `"dynamic": "strict"` or `index.mapping.total_fields.limit`. Never use dynamic mapping in production.
- **Oversharding**: too many small shards waste heap. Start small, scale via ILM rollover.
- **`term` on `text` fields**: won't match analyzed text. Use `.keyword` subfield.
- **Deep `from/size`**: hard limit 10,000. Use `search_after` + PIT.
- **Ignoring bulk errors**: bulk returns 200 on partial failure. Always check `errors` flag.
- **Missing `nested` query**: regular queries on nested type flatten objects, producing wrong matches.
- **Default `refresh_interval` during bulk**: 1s creates excessive segments. Set to `"-1"`.
- **Replicas during initial load**: doubles write work. Set to 0, restore after.
- **Scroll for user-facing pagination**: holds server resources. Use PIT + search_after.
- **Large blobs in `_source`**: ES is not a blob store. Store references only.
- **Ignoring cluster health**: monitor `_cluster/health` and `_cat` APIs. Yellow = replicas unassigned.

## Additional Resources

### Reference Guides (`references/`)

| File | Covers |
|------|--------|
| [advanced-patterns.md](references/advanced-patterns.md) | ILM policies, data streams, CCS/CCR, snapshot/restore, searchable snapshots, runtime fields, field aliases, ingest pipelines (grok/dissect/enrich), transforms, rollups, async search, PIT API, ES\|QL deep dive, vector search (HNSW tuning, quantization), ELSER semantic search, relevance tuning (function_score, rescoring, LTR) |
| [troubleshooting.md](references/troubleshooting.md) | Cluster yellow/red diagnosis, unassigned shards, allocation failures, disk watermarks, mapping explosion, field limits, circuit breaker errors, slow log analysis, indexing bottlenecks, GC pressure, node disconnections, split brain, upgrade issues, reindex failures, analyzer debugging |
| [operations-guide.md](references/operations-guide.md) | Cluster sizing (nodes/shards/heap), capacity planning, rolling upgrades, index template versioning, alias-based zero-downtime reindexing, backup strategies (SLM), monitoring (cluster/node/index stats, cat APIs), Watcher/Kibana alerting, security hardening, audit logging, hot-warm-cold-frozen architecture |

### Scripts (`scripts/`)

| Script | Purpose | Usage |
|--------|---------|-------|
| [es-health-check.sh](scripts/es-health-check.sh) | Cluster diagnostics: health, nodes, shards, disk, thread pools | `./scripts/es-health-check.sh [ES_URL]` |
| [index-management.sh](scripts/index-management.sh) | Create/delete/reindex indices, alias swaps | `./scripts/index-management.sh create myindex --shards 3` |
| [es-local.sh](scripts/es-local.sh) | Local ES 8.x + Kibana via Docker, with sample data | `./scripts/es-local.sh start && ./scripts/es-local.sh seed` |

### Templates (`assets/`)

| File | Description |
|------|-------------|
| [docker-compose.yml](assets/docker-compose.yml) | ES 8.x + Kibana dev environment (optional Logstash) |
| [index-template.json](assets/index-template.json) | Production index template with mappings, settings, ILM, analyzers |
| [ingest-pipeline.json](assets/ingest-pipeline.json) | Log processing pipeline: grok, dissect, date, GeoIP, user-agent |
| [search-template.json](assets/search-template.json) | Parameterized search with highlighting, aggregations, facets |
| [ilm-policy.json](assets/ilm-policy.json) | Hot→warm→cold→frozen→delete ILM policy |

<!-- tested: pass -->
