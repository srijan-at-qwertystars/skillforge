---
name: elasticsearch-patterns
description: |
  Positive: "Use when user works with Elasticsearch, asks about mappings, query DSL (bool, match, term, range), aggregations, index lifecycle management (ILM), analyzers, or Elasticsearch performance tuning."
  Negative: "Do NOT use for Solr, OpenSearch-specific features, or general full-text search concepts without Elasticsearch specifics."
---

# Elasticsearch Patterns and Best Practices

## Index and Mapping Design

Define explicit mappings. Never rely on dynamic mapping in production—it causes mapping explosion and unpredictable field types.

```json
PUT /products
{ "settings": { "number_of_shards": 3, "number_of_replicas": 1 },
  "mappings": { "dynamic": "strict",
    "properties": {
      "title":       { "type": "text", "analyzer": "english" },
      "sku":         { "type": "keyword" },
      "price":       { "type": "scaled_float", "scaling_factor": 100 },
      "created_at":  { "type": "date", "format": "strict_date_optional_time||epoch_millis" },
      "tags":        { "type": "keyword" },
      "description": { "type": "text", "index": false },
      "in_stock":    { "type": "boolean" }
    }
  }
}
```

### Field Type Selection

- Use `keyword` for IDs, enums, tags, and exact-match fields. Use `text` only when full-text search is needed.
- Use `scaled_float` over `float` for monetary values.
- Use `date` with explicit format strings.
- Set `"index": false` on fields not used for search to save disk and CPU.
- Use `doc_values: false` on text fields not used for sorting or aggregations.

### Dynamic Templates

Use dynamic templates to control how unknown fields are mapped when strict mode is not feasible:

```json
PUT /logs
{ "mappings": { "dynamic_templates": [
    { "strings_as_keywords": {
        "match_mapping_type": "string",
        "mapping": { "type": "keyword", "ignore_above": 256 } } },
    { "longs_as_integers": {
        "match_mapping_type": "long",
        "mapping": { "type": "integer" } } }
] } }
```

## Analyzers

### Built-in Analyzers

- `standard`: Default. Lowercases, removes punctuation. Good starting point.
- `simple`: Splits on non-letter characters, lowercases.
- `whitespace`: Splits on whitespace only. No lowercasing.
- `keyword`: No-op analyzer. Entire input as single token.

### Custom Analyzers

Build custom analyzers from char filters, tokenizer, and token filters:

```json
PUT /articles
{ "settings": { "analysis": {
    "char_filter": { "strip_html": { "type": "html_strip" } },
    "tokenizer": { "autocomplete_tokenizer": {
        "type": "edge_ngram", "min_gram": 2, "max_gram": 15,
        "token_chars": ["letter", "digit"] } },
    "filter": {
      "english_stop": { "type": "stop", "stopwords": "_english_" },
      "english_stem": { "type": "stemmer", "language": "english" },
      "synonym_filter": { "type": "synonym", "synonyms_path": "analysis/synonyms.txt" }
    },
    "analyzer": {
      "content_analyzer": {
        "type": "custom", "char_filter": ["strip_html"], "tokenizer": "standard",
        "filter": ["lowercase", "english_stop", "english_stem", "asciifolding"] },
      "autocomplete_analyzer": {
        "type": "custom", "tokenizer": "autocomplete_tokenizer",
        "filter": ["lowercase"] }
    }
} } }
```

Test analyzers with `POST /articles/_analyze { "analyzer": "content_analyzer", "text": "The Quick Brown Fox's résumé" }`.

Use different analyzers at index time vs search time for autocomplete. Apply `edge_ngram` at index time, `standard` at search time.

## Query DSL

### Bool Query

Combine clauses with `must`, `filter`, `should`, and `must_not`. Place non-scoring conditions in `filter` for caching:

```json
GET /products/_search
{ "query": { "bool": {
    "must":     [{ "match": { "title": "wireless headphones" } }],
    "filter":   [{ "term": { "in_stock": true } },
                 { "range": { "price": { "gte": 20, "lte": 200 } } }],
    "should":   [{ "term": { "tags": { "value": "premium", "boost": 2.0 } } }],
    "must_not": [{ "term": { "tags": "refurbished" } }]
} } }
```

### Match and Multi-Match

```json
{ "match": { "title": { "query": "noise cancelling", "operator": "and" } } }

{ "multi_match": {
    "query": "noise cancelling headphones",
    "fields": ["title^3", "description", "tags^2"],
    "type": "best_fields",
    "tie_breaker": 0.3
} }
```

### Term-Level Queries

Use `term`, `terms`, `range`, `exists`, `prefix`, `wildcard` for structured data. Never use `term` on analyzed `text` fields.

```json
{ "terms": { "status": ["published", "draft"] } }
{ "range": { "created_at": { "gte": "now-30d/d", "lte": "now/d" } } }
{ "exists": { "field": "tags" } }
```

### Nested Queries

Query nested objects with the `nested` query type:

```json
GET /orders/_search
{ "query": { "nested": { "path": "line_items", "query": { "bool": { "must": [
    { "term": { "line_items.product_id": "ABC123" } },
    { "range": { "line_items.quantity": { "gte": 5 } } }
] } } } } }
```

### Function Score

Combine relevance with custom scoring signals:

```json
GET /products/_search
{ "query": { "function_score": {
    "query": { "match": { "title": "laptop" } },
    "functions": [
      { "field_value_factor": { "field": "popularity", "modifier": "log1p", "factor": 2 } },
      { "gauss": { "created_at": { "origin": "now", "scale": "30d", "decay": 0.5 } } }
    ],
    "score_mode": "sum", "boost_mode": "multiply"
} } }
```

## Full-Text Search Patterns

### Relevance Tuning

- Boost important fields in `multi_match` with `field^weight` syntax.
- Use `function_score` to blend text relevance with business signals (popularity, recency, margin).
- Set `minimum_should_match` to control precision vs recall.

### Fuzziness

```json
{ "match": { "title": { "query": "laptp", "fuzziness": "AUTO" } } }
```

`AUTO` uses edit distance 0 for 1-2 char terms, 1 for 3-5 char terms, 2 for 6+ char terms.

### Synonyms

Define synonyms in a file or inline. Use `search_analyzer` with synonyms so index size stays lean:

```json
"search_analyzer": {
  "type": "custom",
  "tokenizer": "standard",
  "filter": ["lowercase", "synonym_filter"]
}
```

## Aggregations

### Terms Aggregation

```json
GET /orders/_search
{ "size": 0,
  "aggs": { "by_status": {
    "terms": { "field": "status", "size": 20 },
    "aggs": { "avg_total": { "avg": { "field": "total_amount" } } }
} } }
```

### Date Histogram

```json
"aggs": { "sales_over_time": {
    "date_histogram": { "field": "order_date", "calendar_interval": "month" },
    "aggs": { "revenue": { "sum": { "field": "total_amount" } } }
} }
```

### Range Aggregation

```json
"aggs": { "price_ranges": { "range": { "field": "price",
    "ranges": [{ "to": 50 }, { "from": 50, "to": 200 }, { "from": 200 }]
} } }
```

### Nested Aggregation

```json
"aggs": { "line_items": {
    "nested": { "path": "line_items" },
    "aggs": { "top_products": { "terms": { "field": "line_items.product_id", "size": 10 } } }
} }
```

### Pipeline Aggregations

```json
"aggs": { "monthly_sales": {
    "date_histogram": { "field": "order_date", "calendar_interval": "month" },
    "aggs": {
      "total_sales": { "sum": { "field": "total_amount" } },
      "cumulative_sales": { "cumulative_sum": { "buckets_path": "total_sales" } },
      "sales_derivative": { "derivative": { "buckets_path": "total_sales" } }
    }
} }
```

Set `"size": 0` when only aggregation results are needed. Filter data before aggregating to reduce computation. Avoid high-cardinality terms aggregations—use `composite` aggregation for paginated results.

## Index Lifecycle Management (ILM)

### Hot-Warm-Cold Architecture

```json
PUT _ilm/policy/logs_policy
{ "policy": { "phases": {
    "hot": { "min_age": "0ms", "actions": {
        "rollover": { "max_primary_shard_size": "50gb", "max_age": "1d" },
        "set_priority": { "priority": 100 } } },
    "warm": { "min_age": "7d", "actions": {
        "shrink": { "number_of_shards": 1 },
        "forcemerge": { "max_num_segments": 1 },
        "set_priority": { "priority": 50 },
        "allocate": { "require": { "data": "warm" } } } },
    "cold": { "min_age": "30d", "actions": {
        "set_priority": { "priority": 0 },
        "allocate": { "require": { "data": "cold" } } } },
    "delete": { "min_age": "90d", "actions": { "delete": {} } }
} } }
```

Attach ILM policy to an index template:

```json
PUT _index_template/logs_template
{ "index_patterns": ["logs-*"],
  "template": { "settings": {
    "index.lifecycle.name": "logs_policy",
    "index.lifecycle.rollover_alias": "logs"
} } }
```

## Aliases and Reindexing

Use aliases for zero-downtime index swaps:

```json
POST _aliases
{ "actions": [
    { "remove": { "index": "products_v1", "alias": "products" } },
    { "add":    { "index": "products_v2", "alias": "products" } }
] }
```

Reindex with transformation:

```json
POST _reindex
{ "source": { "index": "products_v1" },
  "dest":   { "index": "products_v2" },
  "script": { "source": "ctx._source.price = ctx._source.price * 100", "lang": "painless" } }
```

Use `slices: "auto"` for parallel reindexing on large indices.

## Performance Tuning

### Shard Sizing

- Target 10–50 GB per shard. Avoid shards under 1 GB or over 65 GB.
- Keep shard count below 20 shards per GB of JVM heap.
- Limit to ~600 shards per node maximum.
- Use the `_cat/shards` API to monitor shard sizes.

### Bulk Indexing

```json
POST _bulk
{"index": {"_index": "products", "_id": "1"}}
{"title": "Wireless Mouse", "price": 2999, "sku": "WM-001"}
{"index": {"_index": "products", "_id": "2"}}
{"title": "Mechanical Keyboard", "price": 8999, "sku": "MK-002"}
```

- Use 5–15 MB bulk request sizes. Benchmark to find optimal size.
- Set `refresh_interval: -1` during bulk loads with `number_of_replicas: 0`. Restore after.
- Use multiple threads for concurrent bulk requests.
- Monitor `_nodes/stats` for thread pool rejections.

### Query Optimization

- Place exact filters in `filter` context for caching.
- Use `_source` filtering to return only needed fields.
- Prefer `search_after` over `from/size` for deep pagination.
- Use `index.sort.field` for queries that match the sort order.
- Profile slow queries with `"profile": true` in the request body.

### Caching

- Node query cache: Caches `filter` context results automatically.
- Request cache: Caches full aggregation responses for `size: 0` queries. Invalidated on refresh.
- Fielddata cache: Monitor with `_cat/fielddata`. Avoid `text` fields in aggregations.

## Search Templates

Store parameterized queries for reuse:

```json
PUT _scripts/product_search
{ "script": { "lang": "mustache", "source": {
    "query": { "bool": {
        "must": { "multi_match": { "query": "{{query_string}}", "fields": ["title^3", "description"] } },
        "filter": [{ "range": { "price": { "gte": "{{min_price}}", "lte": "{{max_price}}" } } }]
    } },
    "size": "{{result_size}}{{^result_size}}10{{/result_size}}"
} } }
```

Render with:

```json
GET /products/_search/template
{ "id": "product_search",
  "params": { "query_string": "laptop", "min_price": 500, "max_price": 2000 } }
```

## Runtime Fields

Define computed fields without reindexing:

```json
GET /orders/_search
{ "runtime_mappings": {
    "total_with_tax": { "type": "double",
      "script": "emit(doc['total_amount'].value * 1.08)" },
    "day_of_week": { "type": "keyword",
      "script": "emit(doc['order_date'].value.dayOfWeekEnum.getDisplayName(TextStyle.FULL, Locale.ROOT))" }
  },
  "query": { "range": { "total_with_tax": { "gte": 100 } } },
  "aggs": { "orders_by_day": { "terms": { "field": "day_of_week" } } } }
```

Use runtime fields for prototyping. Promote to indexed fields once the schema stabilizes.

## Data Modeling

### Nested vs Parent-Child vs Denormalization

| Approach       | Query Speed | Update Cost | Best For                                |
|----------------|-------------|-------------|-----------------------------------------|
| Nested         | Fast        | High        | Tightly coupled, rarely updated objects |
| Parent-Child   | Medium      | Low         | Frequently updated child documents      |
| Denormalized   | Fastest     | High        | Read-heavy analytics, reporting         |

### Join Field (Parent-Child)

```json
PUT /support_tickets
{ "mappings": { "properties": {
    "ticket_relation": { "type": "join", "relations": { "ticket": "comment" } },
    "content": { "type": "text" },
    "author":  { "type": "keyword" }
} } }
```

Use parent-child only when children update independently and frequently. Route parent and child to the same shard with `routing`. Prefer denormalization or nested types when possible—join queries are expensive.

## Monitoring

### Cluster Health

```
GET _cluster/health
GET _cat/indices?v&s=store.size:desc
GET _cat/shards?v&s=store:desc
GET _nodes/stats/jvm,os,process
```

### Slow Logs

Configure slow log thresholds:

```json
PUT /products/_settings
{ "index.search.slowlog.threshold.query.warn": "5s",
  "index.search.slowlog.threshold.query.info": "2s",
  "index.search.slowlog.threshold.fetch.warn": "1s",
  "index.indexing.slowlog.threshold.index.warn": "10s" }
```

### Key Metrics to Watch

- JVM heap usage and GC frequency.
- Search and indexing latency (`_nodes/stats`).
- Thread pool rejections (`search`, `write`, `bulk`).
- Disk watermarks (flood stage at 95%).
- Pending tasks (`_cluster/pending_tasks`).

## Common Anti-Patterns

### Too Many Shards

Over-sharding wastes cluster resources. Each shard consumes memory, file descriptors, and CPU. Consolidate small indices. Use `_shrink` API to reduce shard count.

### Mapping Explosion

Uncontrolled dynamic mapping with high-cardinality field names exhausts cluster memory. Set `"dynamic": "strict"` or use `"dynamic": "runtime"` to prevent runaway field creation. Set `index.mapping.total_fields.limit` as a safety net (default 1000).

### Deep Pagination

`from + size` beyond 10,000 hits is blocked by default (`index.max_result_window`). Use `search_after` with a point-in-time (PIT) for deep traversal:

```json
GET /_search
{ "size": 100, "query": { "match_all": {} },
  "pit": { "id": "<pit_id>", "keep_alive": "5m" },
  "sort": [{ "created_at": "desc" }, { "_id": "asc" }],
  "search_after": ["2025-01-01T00:00:00Z", "abc123"] }
```

### Other Anti-Patterns

- **Wildcard queries on large text fields**: Use `keyword` + prefix or edge n-grams instead.
- **Aggregations on `text` fields**: Causes fielddata loading, OOM risk. Use `keyword` sub-field.
- **Missing `keyword` sub-fields**: Always add `.keyword` sub-field on text fields used for sorting or aggregation.
- **Single large index instead of time-based indices**: Use rollover with ILM for time-series data.
- **Ignoring `_bulk` API**: Single-document indexing wastes network round trips. Always batch.
- **Not setting `refresh_interval`**: Default 1s is aggressive for write-heavy workloads. Increase to 30s or disable during bulk loads.

<!-- tested: pass -->
