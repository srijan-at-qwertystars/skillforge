---
name: meilisearch-patterns
description: >
  Patterns for Meilisearch search engine: index management, document CRUD, search
  with filters/facets/geosearch, multi-search, federated search, hybrid/vector search,
  ranking rules, typo tolerance, multi-tenancy with tenant tokens, API key security,
  SDK usage (JS, Python, Go, Ruby, PHP, Rust), Docker deployment, snapshots, and dumps.
  Triggers: Meilisearch, instant search with Meilisearch, typo-tolerant search,
  faceted search engine, Meilisearch index, Meilisearch Cloud, meilisearch-js,
  meilisearch-python. Negative triggers: Elasticsearch, OpenSearch, Algolia,
  Typesense, Solr, Lucene, general full-text search without Meilisearch context.
---

# Meilisearch Patterns

## Architecture Overview

Meilisearch is a Rust-based, typo-tolerant, RESTful search engine delivering sub-50ms responses. All operations go through HTTP endpoints on port 7700. Every write operation (document add, settings update, index creation) is asynchronous — returns a `taskUid` for status polling. Use `GET /tasks/{taskUid}` to check completion.

Base URL pattern: `http://localhost:7700` (default). Authenticate every request with `Authorization: Bearer <API_KEY>` header.

## Index Management

Create indexes explicitly or implicitly on first document add. Each index requires a unique `uid` and an optional `primaryKey`.

```bash
# Create index
curl -X POST 'http://localhost:7700/indexes' \
  -H 'Authorization: Bearer MASTER_KEY' \
  -H 'Content-Type: application/json' \
  --data-binary '{ "uid": "movies", "primaryKey": "id" }'

# List indexes
curl -X GET 'http://localhost:7700/indexes' -H 'Authorization: Bearer MASTER_KEY'

# Delete index
curl -X DELETE 'http://localhost:7700/indexes/movies' -H 'Authorization: Bearer MASTER_KEY'
```

### Index Settings

Configure all settings atomically via `PATCH /indexes/{uid}/settings`. Apply settings before bulk document ingestion for optimal indexing performance.

```json
{
  "searchableAttributes": ["title", "description", "tags"],
  "filterableAttributes": ["genre", "release_year", "rating", "_geo"],
  "sortableAttributes": ["release_year", "rating", "price"],
  "displayedAttributes": ["title", "description", "genre", "poster_url"],
  "rankingRules": ["words", "typo", "proximity", "attribute", "sort", "exactness"],
  "distinctAttribute": "product_group_id",
  "stopWords": ["the", "a", "an"],
  "synonyms": { "phone": ["mobile", "cell"], "laptop": ["notebook"] },
  "typoTolerance": {
    "enabled": true,
    "minWordSizeForTypos": { "oneTypo": 5, "twoTypos": 9 },
    "disableOnAttributes": ["sku", "isbn"],
    "disableOnWords": ["exact_brand_name"]
  },
  "faceting": { "maxValuesPerFacet": 100, "sortFacetValuesBy": { "genre": "count" } },
  "pagination": { "maxTotalHits": 1000 },
  "separatorTokens": ["&", "/"],
  "dictionary": ["C++", ".NET"]
}
```

Key rules:
- `searchableAttributes` order determines attribute ranking priority. Put the most important field first.
- Only attributes in `filterableAttributes` can be used in `filter` queries. Add `_geo` here for geosearch.
- `sortableAttributes` must be declared before sort queries work.
- `distinctAttribute` deduplicates results — use for product variants or grouped content.
- Changing settings triggers a full reindex. Batch setting changes into one `PATCH` call.

## Document Management

Documents are JSON objects. The primary key field must exist in every document and be unique.

```bash
# Add or replace documents (upsert by primary key)
curl -X POST 'http://localhost:7700/indexes/movies/documents' \
  -H 'Authorization: Bearer MASTER_KEY' \
  -H 'Content-Type: application/json' \
  --data-binary '[
    { "id": 1, "title": "Inception", "genre": "sci-fi", "release_year": 2010 },
    { "id": 2, "title": "The Matrix", "genre": "sci-fi", "release_year": 1999 }
  ]'

# Partial update (merge fields, keep existing)
curl -X PUT 'http://localhost:7700/indexes/movies/documents' \
  -H 'Content-Type: application/json' \
  --data-binary '[{ "id": 1, "rating": 8.8 }]'

# Delete by ID
curl -X POST 'http://localhost:7700/indexes/movies/documents/delete-batch' \
  -H 'Content-Type: application/json' \
  --data-binary '{ "ids": [1, 2, 3] }'

# Delete by filter
curl -X POST 'http://localhost:7700/indexes/movies/documents/delete' \
  -H 'Content-Type: application/json' \
  --data-binary '{ "filter": "release_year < 1950" }'

# Get documents with pagination
curl 'http://localhost:7700/indexes/movies/documents?limit=20&offset=40'
```

Batch ingestion: send documents in chunks of 10,000–50,000. Monitor task queue with `GET /tasks?indexUids=movies&statuses=processing`.

Supported formats: `application/json`, `application/x-ndjson`, `text/csv`. Use NDJSON for streaming large datasets.

## Search

### Basic Search

```bash
curl -X POST 'http://localhost:7700/indexes/movies/search' \
  -H 'Authorization: Bearer SEARCH_KEY' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "q": "interstellar",
    "limit": 20,
    "offset": 0,
    "attributesToRetrieve": ["title", "genre", "release_year"],
    "attributesToHighlight": ["title"],
    "attributesToCrop": ["description"],
    "cropLength": 50,
    "showRankingScore": true,
    "showMatchesPosition": true
  }'
```

### Filters

Use SQL-like syntax. Combine with `AND`, `OR`, `NOT`, and parentheses.

```json
{ "q": "action", "filter": "release_year >= 2000 AND genre = 'sci-fi'" }
{ "q": "", "filter": "rating > 4.0 AND (genre = 'drama' OR genre = 'thriller')" }
{ "q": "phone", "filter": "price 100 TO 500" }
{ "q": "", "filter": "tags IN ['bestseller', 'new-arrival']" }
{ "q": "", "filter": "director IS NOT NULL" }
{ "q": "", "filter": "NOT genre = 'horror'" }
```

### Faceted Search

Request facet distributions alongside results. Attributes must be in `filterableAttributes`.

```json
{
  "q": "laptop",
  "filter": "price < 1500",
  "facets": ["brand", "ram", "screen_size"]
}
```

Response includes `facetDistribution` with counts per value and `facetStats` for numeric fields (min/max).

### Sorting

Declare fields in `sortableAttributes` first. Place the `sort` ranking rule where desired in `rankingRules`.

```json
{ "q": "laptop", "sort": ["price:asc"] }
{ "q": "", "sort": ["release_date:desc", "title:asc"] }
{ "q": "restaurant", "sort": ["_geoPoint(48.8566, 2.3522):asc"] }
```

### Geosearch

Add `_geo` to documents as `{ "lat": 48.8566, "lng": 2.3522 }`. Add `_geo` to `filterableAttributes` and `sortableAttributes`.

```json
{ "q": "pizza", "filter": "_geoRadius(48.8566, 2.3522, 5000)" }
{ "q": "coffee", "filter": "_geoBoundingBox([48.90, 2.25], [48.80, 2.40])" }
{ "q": "hotel", "sort": ["_geoPoint(48.8566, 2.3522):asc"] }
```

### Pagination Strategies

**Offset/limit** — simple but limited to `maxTotalHits` (default 1000):
```json
{ "q": "shoes", "offset": 20, "limit": 10 }
```

**Cursor-based (hitsPerPage/page)** — for UI page navigation:
```json
{ "q": "shoes", "hitsPerPage": 10, "page": 3 }
```

Response includes `totalHits`, `totalPages`, `page`. Prefer cursor-based for user-facing pagination.

## Multi-Search

Execute multiple queries in one HTTP request. Returns separate result sets per query.

```bash
curl -X POST 'http://localhost:7700/multi-search' \
  -H 'Authorization: Bearer SEARCH_KEY' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "queries": [
      { "indexUid": "movies", "q": "avengers", "limit": 5 },
      { "indexUid": "actors", "q": "avengers", "limit": 5 },
      { "indexUid": "reviews", "q": "avengers", "limit": 3 }
    ]
  }'
```

Use multi-search for search-as-you-type across multiple content types (products, categories, articles).

## Federated Search

Merge results from multiple indexes into a single ranked list. Add `federation` parameter to multi-search.

```json
{
  "queries": [
    { "indexUid": "movies", "q": "space", "federationOptions": { "weight": 1.0 } },
    { "indexUid": "books", "q": "space", "federationOptions": { "weight": 0.8 } },
    { "indexUid": "articles", "q": "space", "federationOptions": { "weight": 0.5 } }
  ],
  "federation": { "limit": 20, "offset": 0 }
}
```

Results are merged, deduplicated, and ranked by weighted relevance scores. Use `weight` to boost specific indexes.

## Hybrid Search (Semantic + Keyword)

Combine full-text keyword search with vector-based semantic search. Requires embedder configuration.

### Configure Embedders

```bash
curl -X PATCH 'http://localhost:7700/indexes/movies/settings' \
  -H 'Authorization: Bearer MASTER_KEY' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "embedders": {
      "default": {
        "source": "openAi",
        "apiKey": "sk-...",
        "model": "text-embedding-3-small",
        "documentTemplate": "A movie titled {{doc.title}} about {{doc.description}}"
      }
    }
  }'
```

Embedder sources: `openAi`, `huggingFace`, `userProvided`, `rest`. Use `documentTemplate` with `{{doc.field}}` placeholders to control what text gets embedded.

### Hybrid Search Query

```json
{
  "q": "movies about space exploration and human survival",
  "hybrid": {
    "semanticRatio": 0.5,
    "embedder": "default"
  }
}
```

- `semanticRatio: 0.0` = pure keyword search
- `semanticRatio: 1.0` = pure semantic search
- `semanticRatio: 0.5` = balanced blend (recommended starting point)

### Vector Search (Pure Semantic)

```json
{
  "vector": [0.123, 0.456, ...],
  "hybrid": { "semanticRatio": 1.0, "embedder": "default" }
}
```

For `userProvided` embedder, supply vectors directly in documents under the `_vectors` field.

## Ranking Rules and Relevancy

Default ranking rule order: `words` → `typo` → `proximity` → `attribute` → `sort` → `exactness`.

- `words`: prioritize documents matching more query terms
- `typo`: fewer typos rank higher
- `proximity`: closer query terms in text rank higher
- `attribute`: matches in higher-priority searchable attributes rank higher
- `sort`: apply user-requested sort order
- `exactness`: exact word matches over prefix matches

Add custom ranking rules for domain-specific boosting:

```json
{
  "rankingRules": [
    "words", "typo", "proximity", "attribute", "sort", "exactness",
    "popularity:desc", "release_date:desc"
  ]
}
```

Place `sort` earlier in `rankingRules` to prioritize user-controlled sorting over relevancy. Place it later to prioritize relevancy.

## API Keys and Security

Meilisearch uses a master key to generate scoped API keys.

```bash
# Start with master key
meilisearch --master-key="your-master-key-min-16-bytes"

# Create scoped API key
curl -X POST 'http://localhost:7700/keys' \
  -H 'Authorization: Bearer MASTER_KEY' \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "description": "Search-only key for products",
    "actions": ["search"],
    "indexes": ["products"],
    "expiresAt": "2025-12-31T23:59:59Z"
  }'
```

Available actions: `search`, `documents.add`, `documents.get`, `documents.delete`, `indexes.create`, `indexes.get`, `indexes.update`, `indexes.delete`, `settings.get`, `settings.update`, `tasks.get`, `stats.get`, `dumps.create`, `version`, `keys.get`, `keys.create`, `keys.update`, `keys.delete`, `*` (all).

Rules:
- Never expose master key or admin keys to frontend code
- Create search-only keys scoped to specific indexes for client-side use
- Set `expiresAt` on all keys
- Use tenant tokens for per-user access control

## Multi-Tenancy with Tenant Tokens

Generate JWTs server-side that embed filter rules restricting data access per user/tenant.

```javascript
// Node.js — generate tenant token
import { generateTenantToken } from 'meilisearch/token';

const token = await generateTenantToken({
  apiKey: SEARCH_API_KEY,
  apiKeyUid: SEARCH_KEY_UID,   // from GET /keys
  searchRules: {
    products: { filter: 'tenant_id = 42' },
    orders:   { filter: 'tenant_id = 42' }
  },
  expiresAt: new Date(Date.now() + 3600 * 1000) // 1 hour
});
// Send `token` to frontend; use as Bearer token for search requests
```

```python
# Python
from meilisearch.models.tenant_token import TenantTokenSearchRules
import meilisearch

client = meilisearch.Client('http://localhost:7700', MASTER_KEY)
token = client.generate_tenant_token(
    api_key_uid=SEARCH_KEY_UID,
    search_rules={"products": {"filter": "tenant_id = 42"}},
    expires_at=datetime.now() + timedelta(hours=1),
    api_key=SEARCH_API_KEY
)
```

Requirements:
- Every document must include the tenant identifier field (e.g., `tenant_id`)
- The tenant field must be in `filterableAttributes`
- Generate tokens server-side only; never expose the parent API key
- Set short expiration times (1–24 hours)

## SDK Quick Reference

### JavaScript / TypeScript

```typescript
import { MeiliSearch } from 'meilisearch';
const client = new MeiliSearch({ host: 'http://localhost:7700', apiKey: 'KEY' });

// Index and search
const index = client.index('products');
await index.addDocuments(documents);
await index.updateSettings({ filterableAttributes: ['category'] });
const results = await index.search('keyboard', {
  filter: 'category = electronics',
  limit: 20,
  facets: ['brand']
});

// Wait for task
const task = await index.addDocuments(docs);
await client.waitForTask(task.taskUid);
```

### Python

```python
import meilisearch
client = meilisearch.Client('http://localhost:7700', 'KEY')
index = client.index('products')
index.add_documents(documents)
index.update_settings({'filterableAttributes': ['category']})
results = index.search('keyboard', {'filter': 'category = electronics', 'limit': 20})
```

### Go

```go
client := meilisearch.New("http://localhost:7700", meilisearch.WithAPIKey("KEY"))
index := client.Index("products")
task, _ := index.AddDocuments(documents)
index.WaitForTask(task.TaskUID)
resp, _ := index.Search("keyboard", &meilisearch.SearchRequest{
    Filter: "category = electronics",
    Limit:  20,
})
```

### Ruby / PHP / Rust

Follow the same pattern: instantiate client → get index → add documents → configure settings → search. All official SDKs mirror the REST API structure.

## Docker Deployment

```yaml
# docker-compose.yml
services:
  meilisearch:
    image: getmeili/meilisearch:v1.12
    ports:
      - "7700:7700"
    volumes:
      - meili_data:/meili_data
    environment:
      MEILI_MASTER_KEY: "your-master-key-min-16-bytes"
      MEILI_ENV: production
      MEILI_HTTP_ADDR: 0.0.0.0:7700
      MEILI_MAX_INDEXING_MEMORY: 2Gb
      MEILI_MAX_INDEXING_THREADS: 4
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:7700/health"]
      interval: 30s
      timeout: 5s
      retries: 3
volumes:
  meili_data:
```

Production checklist:
- Always set `MEILI_MASTER_KEY` (min 16 bytes) and `MEILI_ENV=production`
- Mount persistent volume for `/meili_data`
- Place behind a reverse proxy (nginx/Caddy) with TLS
- Set `MEILI_MAX_INDEXING_MEMORY` based on available RAM
- Use health checks for orchestration readiness

## Snapshots and Dumps

```bash
# Create a dump (portable backup)
curl -X POST 'http://localhost:7700/dumps' -H 'Authorization: Bearer MASTER_KEY'

# Enable scheduled snapshots via env
MEILI_SCHEDULE_SNAPSHOT=true
MEILI_SNAPSHOT_DIR=/meili_data/snapshots

# Restore from dump on startup
meilisearch --import-dump /path/to/dump.dump

# Restore from snapshot
meilisearch --import-snapshot /path/to/snapshot
```

- **Dumps**: portable, cross-version compatible. Use for migrations and version upgrades.
- **Snapshots**: exact binary copy. Use for fast disaster recovery on same version.

## Common Patterns

### Search-as-you-type frontend
Send search requests on every keystroke with debounce (150–300ms). Use multi-search to query multiple indexes simultaneously. Return results grouped by content type.

### E-commerce product search
Configure `filterableAttributes` for category, brand, price, rating, availability. Use facets for sidebar refinement UI. Set `distinctAttribute` to deduplicate product variants. Add custom ranking rule `popularity:desc` for boosting bestsellers.

### Content platform with access control
Store `tenant_id` or `user_id` on every document. Generate tenant tokens server-side with filter rules. Use short-lived tokens refreshed on session renewal.

### Geo-aware local search
Include `_geo` in documents. Add `_geo` to `filterableAttributes` and `sortableAttributes`. Filter with `_geoRadius` for "near me" queries. Sort by `_geoPoint` distance for proximity-ordered results.

### Hybrid AI search
Configure an embedder (OpenAI, HuggingFace, or custom REST endpoint). Set `semanticRatio: 0.5` as baseline. Increase toward `1.0` for natural-language queries; decrease toward `0.0` for exact-match queries. Use `documentTemplate` to control which fields are embedded.

## Task Monitoring

All write operations return `taskUid`. Poll with `GET /tasks/{taskUid}`. Filter tasks: `GET /tasks?statuses=failed&indexUids=products`. Statuses: `enqueued`, `processing`, `succeeded`, `failed`, `canceled`. Always check for `failed` tasks after bulk operations. Set `searchableAttributes` explicitly and batch writes for production performance.
