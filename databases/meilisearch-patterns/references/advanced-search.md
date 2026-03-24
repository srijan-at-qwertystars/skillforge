# Advanced Meilisearch Search Features

A deep-dive reference covering hybrid search, multi-search, federated search, geosearch, facets, and fine-grained relevancy tuning in Meilisearch.

---

## Table of Contents

- [1. Hybrid Search with Vectors](#1-hybrid-search-with-vectors)
  - [1.1 Embedder Configuration](#11-embedder-configuration)
  - [1.2 Document Templates](#12-document-templates)
  - [1.3 Semantic Ratio Tuning](#13-semantic-ratio-tuning)
  - [1.4 User-Provided Embeddings](#14-user-provided-embeddings)
  - [1.5 Choosing Embedding Models](#15-choosing-embedding-models)
- [2. Multi-Search](#2-multi-search)
  - [2.1 Endpoint and Request Structure](#21-endpoint-and-request-structure)
  - [2.2 Per-Query Parameters](#22-per-query-parameters)
  - [2.3 Response Structure](#23-response-structure)
  - [2.4 Use Cases](#24-use-cases)
- [3. Federated Search](#3-federated-search)
  - [3.1 Merging Results into a Single List](#31-merging-results-into-a-single-list)
  - [3.2 Federation Options and Weighting](#32-federation-options-and-weighting)
  - [3.3 Deduplication and Pagination](#33-deduplication-and-pagination)
- [4. Geosearch](#4-geosearch)
  - [4.1 The _geo Field](#41-the-_geo-field)
  - [4.2 Geo Filtering](#42-geo-filtering)
  - [4.3 Geo Sorting](#43-geo-sorting)
  - [4.4 Combining Geo with Text Search](#44-combining-geo-with-text-search)
- [5. Facet Distribution and Stats](#5-facet-distribution-and-stats)
  - [5.1 Requesting Facets](#51-requesting-facets)
  - [5.2 Facet Stats](#52-facet-stats)
  - [5.3 Facet Settings](#53-facet-settings)
  - [5.4 Facet Search Endpoint](#54-facet-search-endpoint)
- [6. Distinct Attributes](#6-distinct-attributes)
  - [6.1 Configuration](#61-configuration)
  - [6.2 Behavior and Use Cases](#62-behavior-and-use-cases)
- [7. Typo Tolerance Tuning](#7-typo-tolerance-tuning)
  - [7.1 Global Toggle](#71-global-toggle)
  - [7.2 minWordSizeForTypos](#72-minwordsizefortypos)
  - [7.3 Disabling on Attributes and Words](#73-disabling-on-attributes-and-words)
  - [7.4 How Typo Distance Works](#74-how-typo-distance-works)
- [8. Stop Words](#8-stop-words)
  - [8.1 Purpose and Configuration](#81-purpose-and-configuration)
  - [8.2 Language-Specific Lists](#82-language-specific-lists)
  - [8.3 Impact on Index Size and Relevancy](#83-impact-on-index-size-and-relevancy)
- [9. Synonyms](#9-synonyms)
  - [9.1 Multi-Way Synonyms](#91-multi-way-synonyms)
  - [9.2 One-Way Synonyms](#92-one-way-synonyms)
  - [9.3 Limitations](#93-limitations)
- [10. Pagination Strategies](#10-pagination-strategies)
  - [10.1 Offset / Limit (Cursor-Based)](#101-offset--limit-cursor-based)
  - [10.2 hitsPerPage / Page (Page-Based)](#102-hitsperpage--page-page-based)
  - [10.3 maxTotalHits and Deep Pagination](#103-maxtotalhits-and-deep-pagination)
  - [10.4 Choosing the Right Strategy](#104-choosing-the-right-strategy)
- [11. Highlighting and Cropping](#11-highlighting-and-cropping)
  - [11.1 Highlight Configuration](#111-highlight-configuration)
  - [11.2 Crop Configuration](#112-crop-configuration)
  - [11.3 The _formatted Response Field](#113-the-_formatted-response-field)
  - [11.4 Frontend Rendering](#114-frontend-rendering)

---

## 1. Hybrid Search with Vectors

Hybrid search combines traditional keyword matching with semantic vector search, letting Meilisearch return results that are relevant both lexically and by meaning.

### 1.1 Embedder Configuration

Before using hybrid search, configure one or more embedders in index settings. Meilisearch supports four embedder sources:

**OpenAI**

```bash
curl -X PATCH 'http://localhost:7700/indexes/movies/settings' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "embedders": {
      "default": {
        "source": "openAi",
        "apiKey": "sk-...",
        "model": "text-embedding-3-small",
        "dimensions": 1536,
        "documentTemplate": "A movie titled {{doc.title}} described as: {{doc.overview}}"
      }
    }
  }'
```

**Hugging Face**

```bash
curl -X PATCH 'http://localhost:7700/indexes/articles/settings' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "embedders": {
      "default": {
        "source": "huggingFace",
        "model": "BAAI/bge-base-en-v1.5",
        "documentTemplate": "{{doc.title}}: {{doc.body}}"
      }
    }
  }'
```

**REST (custom endpoint)**

Use any embedding API that accepts JSON and returns a vector array:

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "embedders": {
      "custom": {
        "source": "rest",
        "url": "https://your-api.example.com/embed",
        "apiKey": "your-token",
        "dimensions": 768,
        "documentTemplate": "{{doc.name}} — {{doc.description}}",
        "request": {
          "input": "{{text}}"
        },
        "response": {
          "embedding": "{{embedding}}"
        }
      }
    }
  }'
```

**User-Provided**

When you generate embeddings externally and supply them at index time:

```bash
curl -X PATCH 'http://localhost:7700/indexes/docs/settings' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "embedders": {
      "manual": {
        "source": "userProvided",
        "dimensions": 384
      }
    }
  }'
```

### 1.2 Document Templates

The `documentTemplate` field controls what text is sent to the embedding model for each document. Use `{{doc.field}}` placeholders to reference document attributes:

```
"documentTemplate": "{{doc.title}} by {{doc.author}}. {{doc.summary}}"
```

Guidelines:
- Include the fields most relevant to how users will search.
- Keep templates concise — embedding models have token limits.
- Field values are coerced to strings automatically. Arrays and nested objects are JSON-serialized.
- If a referenced field is missing from a document, the placeholder renders as an empty string.

### 1.3 Semantic Ratio Tuning

The `semanticRatio` parameter controls the balance between keyword and semantic results at search time:

| Value | Behavior |
|-------|----------|
| `0.0` | Pure keyword search — vector results are ignored entirely |
| `0.5` | Equal blend of keyword and semantic results (default) |
| `1.0` | Pure semantic search — keyword matching is ignored |

```bash
# Lean toward keyword matching (good for exact-term queries)
curl -X POST 'http://localhost:7700/indexes/movies/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "batman dark knight",
    "hybrid": {
      "semanticRatio": 0.2,
      "embedder": "default"
    }
  }'
```

```bash
# Lean toward semantic search (good for natural-language questions)
curl -X POST 'http://localhost:7700/indexes/movies/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "a superhero movie set in a dark city",
    "hybrid": {
      "semanticRatio": 0.8,
      "embedder": "default"
    }
  }'
```

**Tuning advice:** Start at `0.5` and adjust. Use lower ratios (0.1–0.3) for catalogs with precise terminology (e-commerce SKU search). Use higher ratios (0.7–0.9) for knowledge bases where users ask questions in natural language.

### 1.4 User-Provided Embeddings

When using the `userProvided` source, supply vectors directly in documents via the `_vectors` field:

```bash
curl -X POST 'http://localhost:7700/indexes/docs/documents' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '[
    {
      "id": 1,
      "title": "Getting Started with Rust",
      "content": "Rust is a systems programming language...",
      "_vectors": {
        "manual": [0.123, -0.456, 0.789, ...]
      }
    }
  ]'
```

When searching with user-provided embedders, you must supply the query vector directly:

```bash
curl -X POST 'http://localhost:7700/indexes/docs/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "vector": [0.111, -0.222, 0.333, ...],
    "hybrid": {
      "semanticRatio": 1.0,
      "embedder": "manual"
    }
  }'
```

The `_vectors` field supports multiple embedders simultaneously:

```json
{
  "id": 1,
  "title": "Document Title",
  "_vectors": {
    "manual": [0.1, 0.2, 0.3],
    "openai_emb": [0.4, 0.5, 0.6]
  }
}
```

### 1.5 Choosing Embedding Models

| Model | Dimensions | Speed | Quality | Best For |
|-------|-----------|-------|---------|----------|
| `text-embedding-3-small` (OpenAI) | 1536 | Fast (API) | High | General-purpose, production apps |
| `text-embedding-3-large` (OpenAI) | 3072 | Fast (API) | Very high | High-accuracy requirements |
| `BAAI/bge-base-en-v1.5` (HF) | 768 | Local | High | Self-hosted, English-only |
| `sentence-transformers/all-MiniLM-L6-v2` (HF) | 384 | Very fast (local) | Good | Low-latency, resource-constrained |

Considerations:
- **Latency:** Hugging Face models run locally and avoid network round-trips but require GPU/CPU resources on the Meilisearch host.
- **Cost:** OpenAI charges per token. For large indexes, local models may be more economical.
- **Multilingual:** Choose multilingual models (e.g., `BAAI/bge-m3`) if your corpus spans languages.
- **Dimensions:** Higher dimensions capture more nuance but increase index size and memory usage.

---

## 2. Multi-Search

Multi-search lets you execute multiple independent search queries against one or more indexes in a single HTTP request, reducing network round-trips.

### 2.1 Endpoint and Request Structure

```bash
curl -X POST 'http://localhost:7700/multi-search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "queries": [
      {
        "indexUid": "movies",
        "q": "inception",
        "limit": 5
      },
      {
        "indexUid": "books",
        "q": "inception",
        "limit": 5
      },
      {
        "indexUid": "movies",
        "q": "",
        "filter": "genres = Action",
        "limit": 10
      }
    ]
  }'
```

Each object in the `queries` array is an independent search request. You can query the same index multiple times with different parameters.

### 2.2 Per-Query Parameters

Every query in a multi-search request accepts the full set of search parameters:

```json
{
  "indexUid": "products",
  "q": "wireless headphones",
  "filter": "price < 100 AND brand = Sony",
  "sort": ["price:asc"],
  "limit": 20,
  "offset": 0,
  "attributesToRetrieve": ["name", "price", "brand"],
  "attributesToHighlight": ["name"],
  "facets": ["brand", "category"]
}
```

Parameters include `q`, `filter`, `sort`, `limit`, `offset`, `hitsPerPage`, `page`, `facets`, `attributesToRetrieve`, `attributesToHighlight`, `attributesToCrop`, `hybrid`, and all other standard search parameters.

### 2.3 Response Structure

The response contains a `results` array with one result set per query, in the same order as the request:

```json
{
  "results": [
    {
      "indexUid": "movies",
      "hits": [ { "id": 1, "title": "Inception", ... } ],
      "query": "inception",
      "processingTimeMs": 2,
      "limit": 5,
      "offset": 0,
      "estimatedTotalHits": 1
    },
    {
      "indexUid": "books",
      "hits": [ { "id": 42, "title": "Inception Point", ... } ],
      "query": "inception",
      "processingTimeMs": 1,
      "limit": 5,
      "offset": 0,
      "estimatedTotalHits": 3
    },
    {
      "indexUid": "movies",
      "hits": [ ... ],
      "query": "",
      "processingTimeMs": 3,
      "limit": 10,
      "offset": 0,
      "estimatedTotalHits": 87
    }
  ]
}
```

### 2.4 Use Cases

**Search-as-you-type across content types:** Fire one multi-search request per keystroke to populate separate result sections (movies, actors, directors) in a dropdown.

**JavaScript SDK example:**

```javascript
const { MeiliSearch } = require('meilisearch');
const client = new MeiliSearch({ host: 'http://localhost:7700', apiKey: 'YOUR_API_KEY' });

const results = await client.multiSearch({
  queries: [
    { indexUid: 'movies', q: userInput, limit: 3 },
    { indexUid: 'actors', q: userInput, limit: 3 },
    { indexUid: 'directors', q: userInput, limit: 3 },
  ],
});

// results.results[0].hits → movie matches
// results.results[1].hits → actor matches
// results.results[2].hits → director matches
```

**Dashboard widgets:** Populate multiple dashboard panels (recent orders, popular products, trending articles) with a single API call.

---

## 3. Federated Search

While multi-search returns separate result sets per query, federated search merges results from multiple indexes into a single ranked list.

### 3.1 Merging Results into a Single List

Add a top-level `federation` object to a multi-search request to enable federation:

```bash
curl -X POST 'http://localhost:7700/multi-search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "federation": {},
    "queries": [
      { "indexUid": "movies", "q": "adventure" },
      { "indexUid": "books", "q": "adventure" },
      { "indexUid": "games", "q": "adventure" }
    ]
  }'
```

Instead of three separate result arrays, you receive a single `hits` array with results from all indexes interleaved by relevance:

```json
{
  "hits": [
    { "title": "Adventure Time", "_federation": { "indexUid": "movies", "queriesPosition": 0 } },
    { "title": "Choose Your Own Adventure", "_federation": { "indexUid": "books", "queriesPosition": 1 } },
    { "title": "Adventure Quest", "_federation": { "indexUid": "games", "queriesPosition": 2 } }
  ],
  "processingTimeMs": 5,
  "limit": 20,
  "offset": 0,
  "estimatedTotalHits": 42
}
```

Each hit includes a `_federation` object identifying which index and query it came from.

### 3.2 Federation Options and Weighting

Use `federationOptions` on individual queries to boost or demote results from specific indexes:

```bash
curl -X POST 'http://localhost:7700/multi-search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "federation": {},
    "queries": [
      {
        "indexUid": "movies",
        "q": "adventure",
        "federationOptions": { "weight": 2.0 }
      },
      {
        "indexUid": "books",
        "q": "adventure",
        "federationOptions": { "weight": 1.0 }
      },
      {
        "indexUid": "games",
        "q": "adventure",
        "federationOptions": { "weight": 0.5 }
      }
    ]
  }'
```

- A `weight` of `2.0` doubles the ranking score of movie results, pushing them higher.
- A `weight` of `0.5` halves the ranking score of game results, pushing them lower.
- Default weight is `1.0`.

This is useful when certain content types are more important to your users.

### 3.3 Deduplication and Pagination

**Deduplication:** Federated search does not automatically deduplicate across indexes. If the same document exists in multiple indexes, it may appear multiple times. Handle deduplication client-side if needed, or structure your indexes to avoid overlap.

**Pagination:** Federated results support `offset` and `limit` at the federation level:

```json
{
  "federation": {
    "offset": 20,
    "limit": 10
  },
  "queries": [
    { "indexUid": "movies", "q": "adventure" },
    { "indexUid": "books", "q": "adventure" }
  ]
}
```

Note that per-query `limit` and `offset` are ignored when federation is enabled — pagination is controlled at the federation level.

---

## 4. Geosearch

Meilisearch supports filtering and sorting by geographic coordinates, enabling location-aware search experiences.

### 4.1 The _geo Field

Documents must include a `_geo` field with `lat` (latitude) and `lng` (longitude) as numbers:

```json
[
  {
    "id": 1,
    "name": "Central Park",
    "type": "park",
    "_geo": { "lat": 40.7829, "lng": -73.9654 }
  },
  {
    "id": 2,
    "name": "Brooklyn Bridge",
    "type": "landmark",
    "_geo": { "lat": 40.7061, "lng": -73.9969 }
  }
]
```

Before using geo features, add `_geo` to `filterableAttributes` and/or `sortableAttributes`:

```bash
curl -X PATCH 'http://localhost:7700/indexes/places/settings' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "filterableAttributes": ["_geo", "type"],
    "sortableAttributes": ["_geo"]
  }'
```

### 4.2 Geo Filtering

**Radius filter** — find documents within a circular area:

```bash
# All places within 5 km of Times Square
curl -X POST 'http://localhost:7700/indexes/places/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "filter": "_geoRadius(40.7580, -73.9855, 5000)"
  }'
```

The syntax is `_geoRadius(lat, lng, distanceInMeters)`.

**Bounding box filter** — find documents within a rectangular area:

```bash
# All places within a bounding box over Manhattan
curl -X POST 'http://localhost:7700/indexes/places/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "filter": "_geoBoundingBox([40.8200, -74.0100], [40.6980, -73.9200])"
  }'
```

The syntax is `_geoBoundingBox([topLeftLat, topLeftLng], [bottomRightLat, bottomRightLng])`.

### 4.3 Geo Sorting

Sort results by proximity to a reference point:

```bash
# Sort by distance from the user's location (ascending = nearest first)
curl -X POST 'http://localhost:7700/indexes/places/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "sort": ["_geoPoint(40.7580, -73.9855):asc"]
  }'
```

When geo-sorting is active, each hit includes a `_geoDistance` field (in meters) indicating its distance from the reference point:

```json
{
  "hits": [
    {
      "id": 3,
      "name": "Times Square Diner",
      "_geo": { "lat": 40.7577, "lng": -73.9857 },
      "_geoDistance": 42
    },
    {
      "id": 1,
      "name": "Central Park",
      "_geo": { "lat": 40.7829, "lng": -73.9654 },
      "_geoDistance": 3120
    }
  ]
}
```

### 4.4 Combining Geo with Text Search

Geo filters and sorting compose freely with text queries and other filters:

```bash
# Restaurants within 2 km of the user, sorted by proximity, matching "sushi"
curl -X POST 'http://localhost:7700/indexes/restaurants/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "sushi",
    "filter": "_geoRadius(40.7580, -73.9855, 2000) AND type = restaurant",
    "sort": ["_geoPoint(40.7580, -73.9855):asc"]
  }'
```

```javascript
// JavaScript SDK equivalent
const results = await client.index('restaurants').search('sushi', {
  filter: '_geoRadius(40.7580, -73.9855, 2000) AND type = restaurant',
  sort: ['_geoPoint(40.7580, -73.9855):asc'],
});

results.hits.forEach(hit => {
  console.log(`${hit.name} — ${hit._geoDistance}m away`);
});
```

---

## 5. Facet Distribution and Stats

Facets provide aggregated counts and statistics about search results, powering filter sidebars and analytics.

### 5.1 Requesting Facets

First, add target fields to `filterableAttributes`:

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "filterableAttributes": ["brand", "category", "price", "rating"]
  }'
```

Then request facets at search time:

```bash
curl -X POST 'http://localhost:7700/indexes/products/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "headphones",
    "facets": ["brand", "category"]
  }'
```

The response includes `facetDistribution`:

```json
{
  "hits": [ ... ],
  "facetDistribution": {
    "brand": {
      "Sony": 12,
      "Bose": 8,
      "Apple": 5,
      "Sennheiser": 3
    },
    "category": {
      "over-ear": 15,
      "in-ear": 10,
      "on-ear": 3
    }
  }
}
```

Each key is a facet value; each number is the count of matching documents.

### 5.2 Facet Stats

For numeric fields, the response also includes `facetStats` with min and max values:

```bash
curl -X POST 'http://localhost:7700/indexes/products/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "headphones",
    "facets": ["price", "rating"]
  }'
```

```json
{
  "hits": [ ... ],
  "facetDistribution": { ... },
  "facetStats": {
    "price": { "min": 19.99, "max": 549.99 },
    "rating": { "min": 2.1, "max": 4.9 }
  }
}
```

Use `facetStats` to render price range sliders or rating filters in your UI.

### 5.3 Facet Settings

**`maxValuesPerFacet`** — controls how many distinct values are returned per facet (default: 100):

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings/faceting' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "maxValuesPerFacet": 200
  }'
```

**`sortFacetValuesBy`** — controls the ordering of facet values:

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings/faceting' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "sortFacetValuesBy": {
      "*": "count",
      "brand": "alpha"
    }
  }'
```

- `"count"` — sort by document count, descending (default). Best for showing the most common values first.
- `"alpha"` — sort alphabetically. Best for fields where users scan for a specific value (e.g., brand name).
- `"*"` sets the default for all facets; specific field names override it.

### 5.4 Facet Search Endpoint

Search within facet values themselves (useful for long facet lists, e.g., hundreds of brands):

```bash
curl -X POST 'http://localhost:7700/indexes/products/facet-search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "facetName": "brand",
    "facetQuery": "son",
    "q": "headphones"
  }'
```

Response:

```json
{
  "facetHits": [
    { "value": "Sony", "count": 12 },
    { "value": "Sonos", "count": 4 }
  ],
  "facetQuery": "son",
  "processingTimeMs": 1
}
```

The `q` parameter is optional — it scopes the facet search to results matching the main query. Omit it to search all facet values in the index.

---

## 6. Distinct Attributes

Distinct attributes let you deduplicate search results by collapsing documents that share the same value for a given field.

### 6.1 Configuration

Set via the index settings:

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "distinctAttribute": "product_id"
  }'
```

Only one distinct attribute can be set per index. To remove it:

```bash
curl -X DELETE 'http://localhost:7700/indexes/products/settings/distinct-attribute' \
  -H 'Authorization: Bearer YOUR_API_KEY'
```

### 6.2 Behavior and Use Cases

When a distinct attribute is set, Meilisearch returns only the most relevant document for each unique value of that field. Other matching documents with the same value are hidden.

**Product variants:** If you index every color/size variant of a product as a separate document, set `distinctAttribute` to `product_id` so each product appears only once in results:

```json
[
  { "id": 1, "product_id": "shoe-123", "color": "red",   "name": "Running Shoe" },
  { "id": 2, "product_id": "shoe-123", "color": "blue",  "name": "Running Shoe" },
  { "id": 3, "product_id": "shoe-123", "color": "black", "name": "Running Shoe" }
]
```

A search for "running shoe" returns only one of these three documents — the one Meilisearch considers most relevant.

**Grouped content:** Blog posts with multiple translations — set `distinctAttribute` to `canonical_id` to show each post once, in the user's preferred language (ranked higher via custom ranking rules).

**Important:** The distinct attribute field must contain a single value (string or number) per document — arrays are not supported.

---

## 7. Typo Tolerance Tuning

Meilisearch matches queries even when the user makes typos. Fine-tune this behavior to balance tolerance with precision.

### 7.1 Global Toggle

Disable typo tolerance entirely:

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings/typo-tolerance' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "enabled": false
  }'
```

### 7.2 minWordSizeForTypos

Control how many characters a query word must have before Meilisearch allows typos:

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings/typo-tolerance' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "minWordSizeForTypos": {
      "oneTypo": 5,
      "twoTypos": 9
    }
  }'
```

| Setting | Default | Meaning |
|---------|---------|---------|
| `oneTypo` | 5 | Words with fewer than this many characters allow zero typos |
| `twoTypos` | 9 | Words with fewer than this many characters allow at most one typo |

With the defaults:
- `"cat"` (3 chars) → no typos allowed
- `"phone"` (5 chars) → one typo allowed
- `"headphones"` (10 chars) → two typos allowed

Increase these thresholds if you see too many false matches. Decrease them for more forgiving search.

### 7.3 Disabling on Attributes and Words

**`disableOnAttributes`** — enforce exact matching on specific fields:

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings/typo-tolerance' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "disableOnAttributes": ["sku", "isbn", "barcode"]
  }'
```

This is critical for identifier fields where a single-character difference means a completely different product. SKU `AB-1234` should not match `AB-1235`.

**`disableOnWords`** — disable typo tolerance for specific terms:

```bash
curl -X PATCH 'http://localhost:7700/indexes/products/settings/typo-tolerance' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "disableOnWords": ["iphone", "imac"]
  }'
```

This prevents "iphone" from matching "iphones" via typo tolerance (though it may still match via other rules like plurals).

### 7.4 How Typo Distance Works

Meilisearch uses Damerau–Levenshtein distance to measure the edit distance between the query term and indexed terms. The allowed operations are:

- **Substitution:** `phne` → `phone` (1 edit)
- **Insertion:** `phon` → `phone` (1 edit)
- **Deletion:** `phhone` → `phone` (1 edit)
- **Transposition:** `phnoe` → `phone` (1 edit)

Meilisearch ranks exact matches above one-typo matches, and one-typo matches above two-typo matches. This is the `typo` ranking rule in the default ranking rules list.

---

## 8. Stop Words

Stop words are common, low-information words that Meilisearch can ignore during indexing and search.

### 8.1 Purpose and Configuration

```bash
curl -X PUT 'http://localhost:7700/indexes/articles/settings/stop-words' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '["the", "a", "an", "is", "are", "was", "were", "in", "on", "at", "to", "for", "of", "and", "or", "but"]'
```

When a user searches for "the best restaurants in paris", Meilisearch treats it as "best restaurants paris" — ignoring `the` and `in`.

### 8.2 Language-Specific Lists

Different languages need different stop word lists. Here are common examples:

**French:**
```json
["le", "la", "les", "un", "une", "des", "du", "de", "et", "en", "est", "que", "qui"]
```

**Spanish:**
```json
["el", "la", "los", "las", "un", "una", "de", "en", "y", "que", "es", "por"]
```

**German:**
```json
["der", "die", "das", "ein", "eine", "und", "ist", "in", "von", "zu", "mit", "den"]
```

For multilingual indexes, combine stop words from all relevant languages. Be cautious — a stop word in one language might be meaningful in another.

### 8.3 Impact on Index Size and Relevancy

**Index size:** Stop words are excluded from the inverted index. Adding a comprehensive stop word list reduces index size, especially for text-heavy documents.

**Relevancy:** Removing stop words prevents them from diluting relevancy scores. Without stop words configured, a search for "to be or not to be" treats every word equally, causing irrelevant results to rank highly because they contain common words like "to" and "be".

**Search speed:** Fewer indexed terms means faster lookups. This is most noticeable on large indexes.

**Caveat:** Be conservative. Over-aggressive stop word lists can hurt searches where the stop word is significant (e.g., "The Who" as a band name, "IT" as a department).

---

## 9. Synonyms

Synonyms let you define equivalences between words so that a search for one term also returns results for its synonyms.

### 9.1 Multi-Way Synonyms

Multi-way synonyms treat all terms as interchangeable. A search for any one of them matches all:

```bash
curl -X PUT 'http://localhost:7700/indexes/products/settings/synonyms' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "sweater": ["pullover", "jumper"],
    "pullover": ["sweater", "jumper"],
    "jumper": ["sweater", "pullover"]
  }'
```

Now searching for "jumper" also returns results containing "sweater" or "pullover".

### 9.2 One-Way Synonyms

One-way synonyms expand only in one direction. Useful when a broad term should match specific terms but not vice versa:

```bash
curl -X PUT 'http://localhost:7700/indexes/products/settings/synonyms' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "footwear": ["shoes", "boots", "sandals"]
  }'
```

A search for "footwear" returns results containing "shoes", "boots", or "sandals". But a search for "shoes" does **not** return results for "boots" or "sandals" (unless you add those mappings separately).

**Multi-word synonyms:**

```json
{
  "ny": ["new york"],
  "new york": ["ny"]
}
```

### 9.3 Limitations

- Synonyms apply after tokenization. Multi-word synonym keys must be space-separated.
- Synonyms are not transitive. If A → B and B → C, searching for A does **not** automatically match C. You must define A → C explicitly.
- Synonyms are case-insensitive. `"NY"` and `"ny"` are treated the same.
- Very large synonym maps (thousands of entries) can increase indexing time.
- Synonyms do not affect filters — only full-text search queries.

---

## 10. Pagination Strategies

Meilisearch offers two pagination modes. Choose based on your UI requirements and dataset size.

### 10.1 Offset / Limit (Cursor-Based)

The default approach. Suitable for infinite scroll and "load more" UIs:

```bash
# First page
curl -X POST 'http://localhost:7700/indexes/movies/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "action",
    "offset": 0,
    "limit": 20
  }'
```

```bash
# Next page
curl -X POST 'http://localhost:7700/indexes/movies/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "action",
    "offset": 20,
    "limit": 20
  }'
```

The response includes `estimatedTotalHits` — an approximation of total matching documents. This number is fast to compute but not exact for large result sets.

### 10.2 hitsPerPage / Page (Page-Based)

Better for traditional paginated UIs with numbered page buttons:

```bash
curl -X POST 'http://localhost:7700/indexes/movies/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "action",
    "hitsPerPage": 20,
    "page": 1
  }'
```

The response includes exact pagination metadata:

```json
{
  "hits": [ ... ],
  "page": 1,
  "hitsPerPage": 20,
  "totalPages": 5,
  "totalHits": 97
}
```

`totalHits` is exact (not estimated), and `totalPages` is computed automatically. Use these to render page number navigation.

### 10.3 maxTotalHits and Deep Pagination

By default, Meilisearch limits results to the first 1,000 hits. Configure this in pagination settings:

```bash
curl -X PATCH 'http://localhost:7700/indexes/movies/settings/pagination' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "maxTotalHits": 5000
  }'
```

**Deep pagination limitations:**
- Higher `maxTotalHits` increases memory usage during search.
- Accessing pages far from the beginning (e.g., page 200) is slower because Meilisearch must evaluate all preceding results.
- For truly large datasets, consider using filters to narrow results rather than deep pagination.

### 10.4 Choosing the Right Strategy

| UI Pattern | Strategy | Why |
|-----------|----------|-----|
| Infinite scroll | `offset` / `limit` | No need for exact page count; `estimatedTotalHits` suffices |
| Page number buttons | `hitsPerPage` / `page` | Provides exact `totalPages` and `totalHits` |
| Search-as-you-type dropdown | `limit` only | Show a fixed number of suggestions; no pagination needed |
| Export / batch processing | `offset` / `limit` | Iterate in batches until `hits` is empty |

Do not mix the two strategies in a single request. Use either `offset`/`limit` or `hitsPerPage`/`page`, not both.

---

## 11. Highlighting and Cropping

Highlighting and cropping help users see why a result matched their query by emphasizing matching terms and showing relevant text excerpts.

### 11.1 Highlight Configuration

```bash
curl -X POST 'http://localhost:7700/indexes/articles/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "rust programming",
    "attributesToHighlight": ["title", "body"],
    "highlightPreTag": "<mark>",
    "highlightPostTag": "</mark>"
  }'
```

- `attributesToHighlight` — array of fields to highlight. Use `["*"]` to highlight all returned attributes.
- `highlightPreTag` — string inserted before matching terms (default: `<em>`).
- `highlightPostTag` — string inserted after matching terms (default: `</em>`).

### 11.2 Crop Configuration

Cropping extracts a short, relevant excerpt from long text fields:

```bash
curl -X POST 'http://localhost:7700/indexes/articles/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "rust programming",
    "attributesToCrop": ["body"],
    "cropLength": 50,
    "cropMarker": "..."
  }'
```

- `attributesToCrop` — array of fields to crop. Use `["*"]` for all attributes. You can also set per-attribute crop lengths: `["body:30", "summary:100"]`.
- `cropLength` — maximum number of words in the cropped excerpt (default: 10).
- `cropMarker` — string appended/prepended to indicate cropped content (default: `…`).

Meilisearch centers the crop around the matched query terms so that users see the matching context.

### 11.3 The _formatted Response Field

Highlighted and cropped content appears in the `_formatted` field of each hit, alongside the original fields:

```json
{
  "hits": [
    {
      "id": 1,
      "title": "Getting Started with Rust Programming",
      "body": "Rust is a systems programming language focused on safety...",
      "_formatted": {
        "id": "1",
        "title": "Getting Started with <mark>Rust</mark> <mark>Programming</mark>",
        "body": "...<mark>Rust</mark> is a systems <mark>programming</mark> language focused on safety..."
      }
    }
  ]
}
```

The original fields are untouched. The `_formatted` field mirrors the same structure with highlighting and cropping applied.

### 11.4 Frontend Rendering

**React example using `dangerouslySetInnerHTML`:**

```jsx
function SearchResult({ hit }) {
  return (
    <div className="result">
      <h3
        dangerouslySetInnerHTML={{ __html: hit._formatted.title }}
      />
      <p
        dangerouslySetInnerHTML={{ __html: hit._formatted.body }}
      />
    </div>
  );
}
```

**Security note:** If you use `dangerouslySetInnerHTML`, ensure your Meilisearch data is trusted or sanitize the HTML. Alternatively, use a library like `DOMPurify`:

```jsx
import DOMPurify from 'dompurify';

function SearchResult({ hit }) {
  return (
    <div className="result">
      <h3
        dangerouslySetInnerHTML={{
          __html: DOMPurify.sanitize(hit._formatted.title),
        }}
      />
    </div>
  );
}
```

**Vue example:**

```vue
<template>
  <div class="result">
    <h3 v-html="hit._formatted.title" />
    <p v-html="hit._formatted.body" />
  </div>
</template>
```

**Full search request combining highlights and crops:**

```bash
curl -X POST 'http://localhost:7700/indexes/articles/search' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_API_KEY' \
  --data-binary '{
    "q": "rust async runtime",
    "attributesToHighlight": ["title", "body"],
    "attributesToCrop": ["body:40"],
    "highlightPreTag": "<mark class=\"highlight\">",
    "highlightPostTag": "</mark>",
    "cropLength": 40,
    "cropMarker": " [...]"
  }'
```

---

*This reference covers Meilisearch v1.x features. Consult the [official documentation](https://www.meilisearch.com/docs) for the latest updates and API changes.*
