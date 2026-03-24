# Advanced MongoDB Patterns

## Table of Contents

- [Aggregation Deep Dive](#aggregation-deep-dive)
  - [$facet — Multi-Faceted Aggregation](#facet--multi-faceted-aggregation)
  - [$bucket and $bucketAuto](#bucket-and-bucketauto)
  - [$graphLookup — Recursive Graph Queries](#graphlookup--recursive-graph-queries)
  - [$merge — Incremental Materialized Views](#merge--incremental-materialized-views)
  - [$out — Replace Collection Output](#out--replace-collection-output)
  - [$setWindowFields — Window Functions](#setwindowfields--window-functions)
  - [Pipeline Optimization Tips](#pipeline-optimization-tips)
- [Atlas Search](#atlas-search)
  - [Lucene Analyzers](#lucene-analyzers)
  - [Autocomplete](#autocomplete)
  - [Compound Queries](#compound-queries)
  - [Facets and Counting](#facets-and-counting)
  - [Custom Scoring](#custom-scoring)
  - [Search Index Definition](#search-index-definition)
- [Atlas Vector Search](#atlas-vector-search)
  - [Index Configuration](#index-configuration)
  - [Querying Vectors](#querying-vectors)
  - [Hybrid Search (Vector + Text)](#hybrid-search-vector--text)
  - [Embedding Strategies](#embedding-strategies)
- [Queryable Encryption](#queryable-encryption)
  - [Architecture Overview](#architecture-overview)
  - [Equality Queries](#equality-queries)
  - [Range Queries (8.0+)](#range-queries-80)
  - [Key Management](#key-management)
  - [Automatic vs Explicit Encryption](#automatic-vs-explicit-encryption)
- [Time Series Collections](#time-series-collections)
  - [Creating Time Series Collections](#creating-time-series-collections)
  - [Querying and Aggregating](#querying-and-aggregating)
  - [Secondary Indexes on Time Series](#secondary-indexes-on-time-series)
  - [Performance Considerations](#performance-considerations)
- [Schema Versioning Patterns](#schema-versioning-patterns)
  - [Schema Version Field](#schema-version-field)
  - [Incremental Migration](#incremental-migration)
  - [Application-Level Versioning](#application-level-versioning)
- [Capped Collections](#capped-collections)
  - [Creating Capped Collections](#creating-capped-collections)
  - [Tailable Cursors](#tailable-cursors)
  - [Use Cases and Limitations](#use-cases-and-limitations)

---

## Aggregation Deep Dive

### $facet — Multi-Faceted Aggregation

`$facet` processes multiple aggregation pipelines on the same input documents in a single stage. Each sub-pipeline receives the same set of input documents and produces independent results.

```javascript
db.products.aggregate([
  { $match: { status: "active" } },
  { $facet: {
    // Price distribution
    priceRanges: [
      { $bucket: {
        groupBy: "$price",
        boundaries: [0, 25, 50, 100, 500, Infinity],
        default: "Other",
        output: { count: { $sum: 1 }, avgPrice: { $avg: "$price" } }
      }}
    ],

    // Top categories by revenue
    topCategories: [
      { $group: { _id: "$category", revenue: { $sum: "$price" } } },
      { $sort: { revenue: -1 } },
      { $limit: 5 }
    ],

    // Total stats
    overview: [
      { $group: {
        _id: null,
        totalProducts: { $sum: 1 },
        avgPrice: { $avg: "$price" },
        maxPrice: { $max: "$price" }
      }}
    ]
  }}
]);
// Output: single document with priceRanges[], topCategories[], overview[] arrays
```

**Key constraints:**
- Each sub-pipeline output is limited to 16MB (BSON document size limit)
- Sub-pipelines cannot include `$out`, `$merge`, or `$facet`
- No indexes used within sub-pipelines (but `$match` before `$facet` uses indexes)

### $bucket and $bucketAuto

```javascript
// $bucket — manual boundaries
db.sales.aggregate([
  { $bucket: {
    groupBy: "$amount",
    boundaries: [0, 100, 500, 1000, 5000],
    default: "5000+",
    output: {
      count: { $sum: 1 },
      total: { $sum: "$amount" },
      avgAmount: { $avg: "$amount" },
      orders: { $push: { id: "$_id", amount: "$amount" } }
    }
  }}
]);

// $bucketAuto — MongoDB determines boundaries for even distribution
db.sales.aggregate([
  { $bucketAuto: {
    groupBy: "$amount",
    buckets: 5,    // desired number of buckets
    granularity: "R5",  // Renard series rounding (R5, R10, R20, R40, R80)
    output: { count: { $sum: 1 }, total: { $sum: "$amount" } }
  }}
]);
```

### $graphLookup — Recursive Graph Queries

Performs recursive search on a collection, following references to build hierarchical or graph-like results.

```javascript
// Org chart: find all reports under a manager (recursive)
db.employees.aggregate([
  { $match: { name: "CEO" } },
  { $graphLookup: {
    from: "employees",
    startWith: "$_id",
    connectFromField: "_id",
    connectToField: "managerId",
    as: "allReports",
    maxDepth: 5,                    // limit recursion depth
    depthField: "level",            // adds depth level to each result
    restrictSearchWithMatch: { status: "active" }  // filter during traversal
  }}
]);

// Social graph: find friends-of-friends up to 3 degrees
db.users.aggregate([
  { $match: { _id: "user1" } },
  { $graphLookup: {
    from: "users",
    startWith: "$friendIds",
    connectFromField: "friendIds",
    connectToField: "_id",
    as: "network",
    maxDepth: 2,
    depthField: "connectionDegree"
  }},
  { $project: {
    network: {
      $filter: {
        input: "$network",
        cond: { $ne: ["$$this._id", "user1"] }  // exclude self
      }
    }
  }}
]);
```

**Performance notes:**
- Index `connectToField` for efficient lookups
- Always set `maxDepth` to prevent runaway recursion
- `restrictSearchWithMatch` filters during traversal, not after

### $merge — Incremental Materialized Views

```javascript
// Incremental update: only process new/changed data
db.orders.aggregate([
  { $match: {
    updatedAt: { $gte: lastRunTimestamp }
  }},
  { $group: {
    _id: { product: "$productId", date: { $dateToString: { format: "%Y-%m-%d", date: "$orderDate" } } },
    dailySales: { $sum: "$amount" },
    orderCount: { $sum: 1 }
  }},
  { $merge: {
    into: "daily_sales_summary",
    on: "_id",
    whenMatched: [
      { $set: {
        dailySales: { $add: ["$$ROOT.dailySales", "$$new.dailySales"] },
        orderCount: { $add: ["$$ROOT.orderCount", "$$new.orderCount"] },
        lastUpdated: "$$NOW"
      }}
    ],
    whenNotMatched: "insert"
  }}
]);
```

**$merge vs $out:**
| Feature | $merge | $out |
|---|---|---|
| Target collection | Same or different DB | Same DB only |
| When matched | merge/replace/keepExisting/fail/pipeline | Replaces entire collection |
| When not matched | insert/discard/fail | N/A |
| Incremental updates | ✅ | ❌ |
| Sharded output | ✅ | ❌ |

### $out — Replace Collection Output

```javascript
// $out replaces the entire target collection atomically
db.logs.aggregate([
  { $match: { level: "error", ts: { $gte: ISODate("2024-01-01") } } },
  { $group: { _id: "$service", errorCount: { $sum: 1 } } },
  { $out: "error_report" }   // replaces error_report collection entirely
]);

// With database specification (MongoDB 7.0+)
{ $out: { db: "reporting", coll: "error_report" } }
```

### $setWindowFields — Window Functions

```javascript
// Running total and moving average
db.sales.aggregate([
  { $setWindowFields: {
    partitionBy: "$region",
    sortBy: { date: 1 },
    output: {
      // Cumulative sum
      runningTotal: {
        $sum: "$amount",
        window: { documents: ["unbounded", "current"] }
      },
      // 7-day moving average
      movingAvg: {
        $avg: "$amount",
        window: { range: [-6, "current"], unit: "day" }
      },
      // Rank within partition
      salesRank: { $rank: {} },
      // Dense rank (no gaps)
      denseRank: { $denseRank: {} },
      // Percentile (MongoDB 7.0+)
      percentile: {
        $percentile: { input: "$amount", p: [0.5, 0.9, 0.99], method: "approximate" }
      },
      // Lead/lag (peek at adjacent rows)
      nextDaySales: { $shift: { output: "$amount", by: 1, default: 0 } },
      prevDaySales: { $shift: { output: "$amount", by: -1, default: 0 } }
    }
  }}
]);

// Row numbering for pagination alternative
db.products.aggregate([
  { $setWindowFields: {
    sortBy: { price: -1 },
    output: { rowNum: { $documentNumber: {} } }
  }},
  { $match: { rowNum: { $gt: 20, $lte: 40 } } }  // page 2 (20 per page)
]);
```

### Pipeline Optimization Tips

```javascript
// 1. $match + $sort + $limit coalescence — MongoDB auto-optimizes
db.coll.aggregate([
  { $sort: { score: -1 } },
  { $limit: 10 },
  { $match: { status: "active" } }
]);
// Optimizer rewrites to: $match → $sort → $limit

// 2. $project/$addFields before $group reduces memory
db.coll.aggregate([
  { $project: { category: 1, price: 1 } },  // drop unnecessary fields early
  { $group: { _id: "$category", total: { $sum: "$price" } } }
]);

// 3. allowDiskUse for large datasets (>100MB in-memory limit)
db.coll.aggregate([...], { allowDiskUse: true });

// 4. $match early to leverage indexes
// BAD: { $project } → { $match }
// GOOD: { $match } → { $project }

// 5. Use $expr and $let for complex computed comparisons in $match
db.orders.aggregate([
  { $match: {
    $expr: {
      $gt: [
        { $multiply: ["$qty", "$price"] },
        1000
      ]
    }
  }}
]);
```

---

## Atlas Search

### Lucene Analyzers

```json
{
  "analyzers": [
    {
      "name": "custom_english",
      "charFilters": [
        { "type": "mapping", "mappings": { "&": "and", "@": "at" } }
      ],
      "tokenizer": { "type": "standard" },
      "tokenFilters": [
        { "type": "lowercase" },
        { "type": "stopword", "tokens": ["the", "a", "an", "is", "are"] },
        { "type": "snowballStemming", "stemmerName": "english" },
        { "type": "synonym", "synonyms": [
          { "input": ["laptop", "notebook"], "synonyms": ["laptop", "notebook", "portable computer"] }
        ]}
      ]
    },
    {
      "name": "autocomplete_analyzer",
      "tokenizer": {
        "type": "edgeGram",
        "minGram": 2,
        "maxGram": 15
      },
      "tokenFilters": [{ "type": "lowercase" }]
    }
  ],
  "mappings": {
    "dynamic": false,
    "fields": {
      "title": { "type": "string", "analyzer": "custom_english" },
      "description": { "type": "string", "analyzer": "custom_english" },
      "name": { "type": "autocomplete", "analyzer": "autocomplete_analyzer" },
      "price": { "type": "number" },
      "location": { "type": "geo" },
      "createdAt": { "type": "date" }
    }
  }
}
```

**Built-in analyzers:** `lucene.standard`, `lucene.simple`, `lucene.whitespace`, `lucene.keyword`, `lucene.english` (and other languages).

### Autocomplete

```javascript
// Search index definition for autocomplete
{
  "mappings": {
    "fields": {
      "productName": {
        "type": "autocomplete",
        "tokenization": "edgeGram",  // or "rightEdgeGram", "nGram"
        "minGrams": 2,
        "maxGrams": 15,
        "foldDiacritics": true
      }
    }
  }
}

// Query
db.products.aggregate([
  { $search: {
    index: "autocomplete_index",
    autocomplete: {
      query: "mon",
      path: "productName",
      tokenOrder: "sequential",  // or "any"
      fuzzy: { maxEdits: 1, prefixLength: 2 }
    }
  }},
  { $limit: 10 },
  { $project: { productName: 1, score: { $meta: "searchScore" } } }
]);
```

### Compound Queries

```javascript
db.movies.aggregate([
  { $search: {
    index: "movies_search",
    compound: {
      // All must match
      must: [
        { text: { query: "adventure", path: "genres" } }
      ],
      // At least one should match (boosts score)
      should: [
        { text: { query: "epic", path: "plot", score: { boost: { value: 3 } } } },
        { range: { path: "imdb.rating", gte: 8.0, score: { boost: { value: 2 } } } }
      ],
      // Must not match (excluded)
      mustNot: [
        { text: { query: "horror", path: "genres" } }
      ],
      // Must match but doesn't affect score
      filter: [
        { range: { path: "year", gte: 2000 } },
        { equals: { path: "rated", value: "PG-13" } }
      ],
      minimumShouldMatch: 1
    },
    highlight: { path: ["plot", "title"] }
  }},
  { $project: {
    title: 1, year: 1, plot: 1,
    score: { $meta: "searchScore" },
    highlights: { $meta: "searchHighlights" }
  }},
  { $limit: 20 }
]);
```

### Facets and Counting

```javascript
db.products.aggregate([
  { $searchMeta: {
    index: "product_search",
    facet: {
      operator: {
        compound: {
          must: [{ text: { query: "laptop", path: "description" } }]
        }
      },
      facets: {
        brandFacet: { type: "string", path: "brand", numBuckets: 10 },
        priceFacet: {
          type: "number", path: "price",
          boundaries: [0, 500, 1000, 2000, 5000]
        },
        dateFacet: {
          type: "date", path: "createdAt",
          boundaries: [
            ISODate("2023-01-01"), ISODate("2024-01-01"), ISODate("2025-01-01")
          ]
        }
      }
    }
  }}
]);
// Returns: { count: { total: N }, facet: { brandFacet: {...}, priceFacet: {...} } }
```

### Custom Scoring

```javascript
{ $search: {
  compound: {
    should: [
      { text: {
        query: "mongodb",
        path: "title",
        score: { boost: { value: 5 } }  // static boost
      }},
      { text: {
        query: "mongodb",
        path: "body",
        score: { function: {
          multiply: [
            { score: "relevance" },
            { path: { value: "popularity", undefined: 1 } }  // field-based boost
          ]
        }}
      }}
    ]
  }
}}
```

### Search Index Definition

```javascript
// Create via mongosh (Atlas)
db.runCommand({
  createSearchIndexes: "products",
  indexes: [
    {
      name: "product_search",
      definition: {
        analyzer: "lucene.english",
        searchAnalyzer: "lucene.english",
        mappings: {
          dynamic: false,
          fields: {
            name: { type: "string", analyzer: "lucene.english" },
            description: { type: "string", analyzer: "lucene.english" },
            category: { type: "stringFacet" },
            price: { type: "number" },
            tags: { type: "token" }
          }
        },
        storedSource: { include: ["name", "price"] }  // return stored fields
      }
    }
  ]
});
```

---

## Atlas Vector Search

### Index Configuration

```json
{
  "fields": [
    {
      "type": "vector",
      "path": "embedding",
      "numDimensions": 1536,
      "similarity": "cosine"
    },
    {
      "type": "filter",
      "path": "category"
    },
    {
      "type": "filter",
      "path": "status"
    }
  ]
}
```

**Similarity metrics:** `cosine` (normalized), `dotProduct` (pre-normalized, fastest), `euclidean` (absolute distance).

**MongoDB 8.0 enhancements:** Scalar and binary quantization reduce memory by up to 32x with minimal accuracy loss.

### Querying Vectors

```javascript
db.documents.aggregate([
  { $vectorSearch: {
    index: "vector_index",
    path: "embedding",
    queryVector: embeddingVector,    // float array from embedding model
    numCandidates: 200,              // HNSW candidates (higher = more accurate, slower)
    limit: 10,
    filter: {
      $and: [
        { category: { $eq: "technology" } },
        { status: { $eq: "published" } }
      ]
    }
  }},
  { $project: {
    title: 1,
    content: 1,
    score: { $meta: "vectorSearchScore" }  // 0.0-1.0 for cosine
  }}
]);
```

### Hybrid Search (Vector + Text)

```javascript
// Combine vector search with Atlas Search using $unionWith or reciprocal rank fusion
db.documents.aggregate([
  // Vector search results
  { $vectorSearch: {
    index: "vector_idx",
    path: "embedding",
    queryVector: queryEmbedding,
    numCandidates: 100,
    limit: 20
  }},
  { $addFields: { vs_score: { $meta: "vectorSearchScore" } } },
  { $unionWith: {
    coll: "documents",
    pipeline: [
      // Full-text search results
      { $search: { index: "text_idx", text: { query: "mongodb patterns", path: "content" } } },
      { $limit: 20 },
      { $addFields: { ts_score: { $meta: "searchScore" } } }
    ]
  }},
  // Reciprocal Rank Fusion (RRF) to combine scores
  { $group: {
    _id: "$_id",
    doc: { $first: "$$ROOT" },
    vs_score: { $max: "$vs_score" },
    ts_score: { $max: "$ts_score" }
  }},
  { $addFields: {
    rrf_score: {
      $add: [
        { $divide: [1, { $add: [60, { $ifNull: ["$vs_score", 0] }] }] },
        { $divide: [1, { $add: [60, { $ifNull: ["$ts_score", 0] }] }] }
      ]
    }
  }},
  { $sort: { rrf_score: -1 } },
  { $limit: 10 }
]);
```

### Embedding Strategies

```javascript
// 1. Store embeddings at document creation
async function insertWithEmbedding(doc) {
  const embedding = await openai.embeddings.create({
    model: "text-embedding-3-small",  // 1536 dimensions
    input: `${doc.title} ${doc.description}`
  });
  doc.embedding = embedding.data[0].embedding;
  await collection.insertOne(doc);
}

// 2. Chunk large documents for better retrieval
function chunkText(text, chunkSize = 500, overlap = 50) {
  const chunks = [];
  for (let i = 0; i < text.length; i += chunkSize - overlap) {
    chunks.push(text.slice(i, i + chunkSize));
  }
  return chunks;
}

// 3. Use Atlas triggers to auto-generate embeddings on insert/update
// (Configure in Atlas UI: Database Triggers → Function)
```

---

## Queryable Encryption

### Architecture Overview

Queryable Encryption (QE) encrypts sensitive fields client-side before sending to the server. The server processes queries on encrypted data without ever decrypting it.

**Components:**
- **Client:** Encrypts/decrypts data; holds encryption keys
- **Key Vault:** Collection storing encrypted data encryption keys (DEKs)
- **KMS:** External key management (AWS KMS, Azure Key Vault, GCP KMS, or local)
- **Server:** Stores and queries encrypted data; never sees plaintext

### Equality Queries

```javascript
const autoEncryptionOpts = {
  keyVaultNamespace: "encryption.__keyVault",
  kmsProviders: {
    aws: {
      accessKeyId: process.env.AWS_ACCESS_KEY_ID,
      secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY
    }
  },
  encryptedFieldsMap: {
    "medical.patients": {
      fields: [
        {
          path: "ssn",
          bsonType: "string",
          queries: { queryType: "equality" }
        },
        {
          path: "insurance.policyNumber",
          bsonType: "string",
          queries: { queryType: "equality" }
        },
        {
          path: "bloodType",
          bsonType: "string"
          // no queries = encrypted but not queryable
        }
      ]
    }
  }
};

const client = new MongoClient(uri, { autoEncryption: autoEncryptionOpts });
const patients = client.db("medical").collection("patients");

// Insert — automatically encrypted client-side
await patients.insertOne({
  name: "Jane Doe",
  ssn: "123-45-6789",
  bloodType: "O+",
  insurance: { policyNumber: "POL-12345" }
});

// Query — equality on encrypted field works transparently
const patient = await patients.findOne({ ssn: "123-45-6789" });
```

### Range Queries (8.0+)

```javascript
// MongoDB 8.0 adds range query support for Queryable Encryption
{
  path: "billing.amount",
  bsonType: "int",
  queries: {
    queryType: "range",
    sparsity: 2,          // trade-off: lower = more precise, higher = faster
    trimFactor: 6,
    contention: 4
  }
}

// Range queries work transparently
await invoices.find({
  "billing.amount": { $gte: 1000, $lte: 5000 }
});
```

### Key Management

```javascript
const { ClientEncryption } = require("mongodb-client-encryption");

const encryption = new ClientEncryption(client, {
  keyVaultNamespace: "encryption.__keyVault",
  kmsProviders: { aws: { accessKeyId: "...", secretAccessKey: "..." } }
});

// Create a data encryption key (DEK)
const dataKeyId = await encryption.createDataKey("aws", {
  masterKey: {
    key: "arn:aws:kms:us-east-1:123456:key/abcd-1234",
    region: "us-east-1"
  },
  keyAltNames: ["patient-data-key"]
});
```

### Automatic vs Explicit Encryption

```javascript
// Explicit encryption — manual control per field
const encrypted = await encryption.encrypt(
  "123-45-6789",
  {
    algorithm: "Indexed",       // or "Unindexed" for non-queryable
    keyId: dataKeyId,
    contentionFactor: 4         // higher = more secure, slower writes
  }
);
await collection.insertOne({ ssn: encrypted });

// Automatic encryption (recommended) — driven by encryptedFieldsMap
// See equality queries section above; fields encrypted/decrypted transparently
```

---

## Time Series Collections

### Creating Time Series Collections

```javascript
db.createCollection("sensor_data", {
  timeseries: {
    timeField: "timestamp",           // required: field containing time
    metaField: "metadata",            // optional: identifies data source
    granularity: "seconds"            // "seconds" | "minutes" | "hours"
    // MongoDB 7.0+: use bucketMaxSpanSeconds/bucketRoundingSeconds instead
  },
  expireAfterSeconds: 2592000         // optional TTL: 30 days
});

// MongoDB 7.0+ granularity control
db.createCollection("metrics", {
  timeseries: {
    timeField: "ts",
    metaField: "source",
    bucketMaxSpanSeconds: 3600,       // max time span per bucket
    bucketRoundingSeconds: 3600       // bucket boundary alignment
  }
});

// Insert data — MongoDB handles bucketing automatically
db.sensor_data.insertMany([
  { timestamp: new Date(), metadata: { sensorId: "temp-01", location: "floor1" }, value: 22.5 },
  { timestamp: new Date(), metadata: { sensorId: "temp-01", location: "floor1" }, value: 22.7 },
  { timestamp: new Date(), metadata: { sensorId: "humidity-01", location: "floor1" }, value: 45.2 }
]);
```

### Querying and Aggregating

```javascript
// Time-based aggregation — automatically optimized for bucket structure
db.sensor_data.aggregate([
  { $match: {
    "metadata.sensorId": "temp-01",
    timestamp: { $gte: ISODate("2024-06-01"), $lt: ISODate("2024-07-01") }
  }},
  { $group: {
    _id: {
      day: { $dateToString: { format: "%Y-%m-%d", date: "$timestamp" } }
    },
    avgValue: { $avg: "$value" },
    minValue: { $min: "$value" },
    maxValue: { $max: "$value" },
    readings: { $sum: 1 }
  }},
  { $sort: { "_id.day": 1 } }
]);

// Window function for rolling averages on time series
db.sensor_data.aggregate([
  { $setWindowFields: {
    partitionBy: "$metadata.sensorId",
    sortBy: { timestamp: 1 },
    output: {
      rollingAvg: {
        $avg: "$value",
        window: { range: [-1, 0], unit: "hour" }
      }
    }
  }}
]);
```

### Secondary Indexes on Time Series

```javascript
// Compound index on metaField subfields + timeField
db.sensor_data.createIndex({ "metadata.sensorId": 1, timestamp: -1 });

// Partial index for specific sensors
db.sensor_data.createIndex(
  { timestamp: -1 },
  { partialFilterExpression: { "metadata.location": "critical-zone" } }
);
```

### Performance Considerations

- **Batch inserts:** Insert many documents at once; MongoDB optimizes bucket packing
- **metaField design:** Keep metaField values consistent per source; changing meta creates new buckets
- **Granularity:** Match to your insert frequency. Finer granularity = more buckets = more overhead
- **Memory:** Time series uses ~1KB per active bucket in WiredTiger cache
- **MongoDB 8.0:** 200% faster aggregations on time series via columnar scanning

---

## Schema Versioning Patterns

### Schema Version Field

```javascript
// Add version field to every document
{ _id: 1, schemaVersion: 1, name: "Alice", email: "alice@example.com" }

// After adding address field in v2
{ _id: 2, schemaVersion: 2, name: "Bob", email: "bob@example.com",
  address: { street: "123 Main", city: "NYC", zip: "10001" } }

// Application reads both versions
function normalizeUser(doc) {
  switch (doc.schemaVersion) {
    case 1:
      return { ...doc, address: null, schemaVersion: 2 };
    case 2:
      return doc;
    default:
      throw new Error(`Unknown schema version: ${doc.schemaVersion}`);
  }
}
```

### Incremental Migration

```javascript
// Lazy migration: upgrade on read/write
async function findUser(id) {
  const user = await db.users.findOne({ _id: id });
  if (user.schemaVersion < CURRENT_VERSION) {
    const migrated = migrateToLatest(user);
    await db.users.replaceOne({ _id: id }, migrated);
    return migrated;
  }
  return user;
}

// Background migration: batch update in chunks
async function batchMigrate(batchSize = 1000) {
  let processed = 0;
  while (true) {
    const docs = await db.users
      .find({ schemaVersion: { $lt: CURRENT_VERSION } })
      .limit(batchSize)
      .toArray();
    if (docs.length === 0) break;

    const ops = docs.map(doc => ({
      replaceOne: {
        filter: { _id: doc._id, schemaVersion: doc.schemaVersion },
        replacement: migrateToLatest(doc)
      }
    }));
    await db.users.bulkWrite(ops);
    processed += docs.length;
  }
  return processed;
}
```

### Application-Level Versioning

```javascript
// Using MongoDB's $jsonSchema validation with versioning
db.runCommand({
  collMod: "users",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["schemaVersion", "name", "email"],
      properties: {
        schemaVersion: { bsonType: "int", minimum: 1, maximum: 3 },
        name: { bsonType: "string" },
        email: { bsonType: "string" }
      }
    }
  },
  validationLevel: "moderate",  // only validate inserts and updates (not existing docs)
  validationAction: "warn"      // log warnings instead of rejecting
});
```

---

## Capped Collections

### Creating Capped Collections

```javascript
// Fixed-size collection — oldest documents automatically removed
db.createCollection("logs", {
  capped: true,
  size: 104857600,    // 100MB max size (required)
  max: 100000         // optional max document count
});

// Verify collection is capped
db.logs.isCapped();  // true

// Convert existing collection to capped (blocks writes)
db.runCommand({ convertToCapped: "oldLogs", size: 52428800 });
```

### Tailable Cursors

```javascript
// Tailable cursor — like Unix `tail -f`
const cursor = db.logs.find({}, {
  tailable: true,
  awaitData: true,      // block for new data instead of returning immediately
  maxAwaitTimeMS: 1000
});

while (await cursor.hasNext()) {
  const doc = await cursor.next();
  console.log(doc);
  // Cursor stays open, waiting for new inserts
}

// Node.js driver equivalent
const cursor = collection.find({}, {
  tailable: true,
  awaitData: true,
  maxAwaitTimeMS: 1000
});

for await (const doc of cursor) {
  processLog(doc);
}
```

### Use Cases and Limitations

**Good for:** Logging, event streaming, circular buffers, recent activity feeds.

**Limitations:**
- Cannot delete individual documents (only drop the collection)
- Cannot update documents to increase their size
- No sharding support
- No `$out` or `$merge` aggregation target
- Inserts maintain natural insertion order (FIFO)
- Consider change streams or time series collections as modern alternatives

```javascript
// Common pattern: capped collection as event bus
db.createCollection("events", { capped: true, size: 10485760 });

// Producer
db.events.insertOne({ type: "order_created", orderId: "abc", ts: new Date() });

// Consumer (tailable cursor)
const stream = db.events.find(
  { ts: { $gte: new Date() } },
  { tailable: true, awaitData: true }
);
```
