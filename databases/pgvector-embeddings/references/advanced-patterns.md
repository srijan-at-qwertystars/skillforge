# pgvector Advanced Patterns

## Table of Contents

- [HNSW Index Tuning](#hnsw-index-tuning)
- [IVFFlat Index Tuning](#ivfflat-index-tuning)
- [Hybrid Search: Vector + Full-Text](#hybrid-search-vector--full-text)
- [Reciprocal Rank Fusion (RRF)](#reciprocal-rank-fusion-rrf)
- [Multi-Vector Search](#multi-vector-search)
- [Filtered Vector Search Optimization](#filtered-vector-search-optimization)
- [Halfvec and Binary Quantization](#halfvec-and-binary-quantization)
- [Sparse Vector Operations](#sparse-vector-operations)
- [Partitioned Tables with pgvector](#partitioned-tables-with-pgvector)

---

## HNSW Index Tuning

HNSW (Hierarchical Navigable Small World) is the recommended index type for production pgvector workloads. It builds a multi-layer graph where each node connects to its approximate nearest neighbors.

### Parameters

| Parameter | Default | Range | Controls |
|-----------|---------|-------|----------|
| `m` | 16 | 2–100 | Max bi-directional links per node per layer |
| `ef_construction` | 64 | 4–1000 | Search width during index build |
| `ef_search` | 40 | 1–1000 | Search width at query time (SET param) |

### Parameter Tradeoffs

**`m` (connectivity)**
- Higher `m` → more edges per node → better recall, larger index, slower builds.
- Lower `m` → smaller index, faster builds, recall drops on high-dimensional data.
- Rule of thumb: `m = 16` works for dims ≤ 1536. For dims > 1536, try `m = 32–48`.

**`ef_construction` (build quality)**
- Higher `ef_construction` → index explores more candidates during construction → better graph quality → better recall at query time.
- Must be ≥ `2 * m` for good results.
- Sweet spot: `ef_construction = 128` balances build time and recall for most workloads.

**`ef_search` (query quality)**
- Set at query time via `SET hnsw.ef_search = N`.
- Must be ≥ `k` (the LIMIT in your query).
- Higher → better recall, higher latency.

### Benchmark Reference (1M vectors, 1536 dims, cosine)

| m | ef_construction | ef_search | Recall@10 | QPS (p50) | Index Size |
|---|-----------------|-----------|-----------|-----------|------------|
| 16 | 64 | 40 | 0.92 | 850 | 1.8 GB |
| 16 | 64 | 100 | 0.97 | 520 | 1.8 GB |
| 16 | 128 | 100 | 0.98 | 510 | 1.8 GB |
| 16 | 256 | 200 | 0.99 | 310 | 1.8 GB |
| 32 | 128 | 100 | 0.99 | 420 | 3.2 GB |
| 32 | 256 | 200 | 0.995 | 260 | 3.2 GB |
| 48 | 256 | 200 | 0.997 | 200 | 4.5 GB |
| 64 | 256 | 400 | 0.999 | 120 | 5.8 GB |

**Key takeaways:**
- For most apps, `m=16, ef_construction=128, ef_search=100` gives ≥97% recall with solid throughput.
- If you need 99%+ recall, increase `m` to 32 and `ef_search` to 200.
- Index size grows roughly linearly with `m`.

### Build Memory Requirements

HNSW builds require significant memory. Set `maintenance_work_mem` appropriately:

```sql
-- Rough formula: rows × dims × 4 bytes × factor
-- For 1M rows × 1536 dims: ~8-12 GB recommended
SET maintenance_work_mem = '8GB';
SET max_parallel_maintenance_workers = 7;

CREATE INDEX CONCURRENTLY idx_items_embedding
ON items USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 128);
```

### Parallel Index Build

pgvector 0.5.1+ supports parallel HNSW builds:

```sql
SET max_parallel_maintenance_workers = 7;  -- use N-1 cores
```

Build time scales roughly linearly with parallel workers for large datasets.

---

## IVFFlat Index Tuning

IVFFlat (Inverted File with Flat compression) partitions vectors into clusters using k-means, then searches only the most relevant clusters at query time.

### Parameters

| Parameter | Default | Controls |
|-----------|---------|----------|
| `lists` | — (required) | Number of k-means clusters |
| `probes` | 1 | Number of clusters to search at query time |

### Choosing `lists`

| Dataset Size | Recommended `lists` |
|-------------|-------------------|
| < 100K rows | `sqrt(rows)` → ~316 for 100K |
| 100K – 1M | `sqrt(rows)` → ~1000 for 1M |
| 1M – 10M | `rows / 1000` → 5000 for 5M |
| > 10M | `rows / 1000` to `sqrt(rows)` |

**Too few lists:** Each cluster is large → slow sequential scan within cluster.
**Too many lists:** Clusters are too small → need more probes for good recall → lose advantage.

### Choosing `probes`

```sql
SET ivfflat.probes = 10;  -- default is 1
```

| probes / lists ratio | Typical Recall@10 | Relative Latency |
|---------------------|-------------------|-----------------|
| 1% | 0.60–0.70 | 1× |
| 3% | 0.80–0.88 | 2–3× |
| 5% | 0.90–0.95 | 4–5× |
| 10% | 0.95–0.98 | 8–10× |
| 20% | 0.98–0.99 | 15–20× |

### Benchmark Reference (1M vectors, 1536 dims, cosine)

| lists | probes | Recall@10 | QPS (p50) | Index Build Time |
|-------|--------|-----------|-----------|-----------------|
| 1000 | 1 | 0.65 | 1200 | 45s |
| 1000 | 10 | 0.92 | 450 | 45s |
| 1000 | 50 | 0.98 | 120 | 45s |
| 1000 | 100 | 0.99 | 65 | 45s |
| 3000 | 10 | 0.85 | 600 | 90s |
| 3000 | 30 | 0.95 | 250 | 90s |
| 3000 | 100 | 0.99 | 95 | 90s |

**Key takeaways:**
- IVFFlat builds much faster than HNSW but needs higher probes for equivalent recall.
- Always build on a representative data sample — IVFFlat on an empty or tiny table produces poor clusters.
- After large data changes (>20%), consider rebuilding: `REINDEX INDEX CONCURRENTLY idx_name;`

---

## Hybrid Search: Vector + Full-Text

Hybrid search combines semantic similarity (pgvector) with lexical matching (PostgreSQL `tsvector`/`tsquery`). This is critical for RAG pipelines where exact keyword matches matter alongside semantic understanding.

### Schema Setup

```sql
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    embedding vector(1536),
    search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', title), 'A') ||
        setweight(to_tsvector('english', content), 'B')
    ) STORED
);

-- Indexes for both search modalities
CREATE INDEX idx_docs_embedding ON documents
    USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 128);
CREATE INDEX idx_docs_search ON documents USING gin (search_vector);
```

### Weighted tsvector

Use `setweight` to boost title matches over body matches:

- **A** weight: Title/heading matches (highest priority)
- **B** weight: Body content
- **C** weight: Metadata, tags
- **D** weight: Default (lowest priority)

### Query Strategies

**Strategy 1: Filter by text, rank by vector**
```sql
SELECT id, title, embedding <=> $1 AS distance
FROM documents
WHERE search_vector @@ plainto_tsquery('english', $2)
ORDER BY embedding <=> $1
LIMIT 10;
```

**Strategy 2: Union + re-rank (RRF)**
See [Reciprocal Rank Fusion](#reciprocal-rank-fusion-rrf) below.

**Strategy 3: Score blending**
```sql
SELECT id, title,
    0.7 * (1 - (embedding <=> $1)) +
    0.3 * ts_rank_cd(search_vector, plainto_tsquery('english', $2))
    AS combined_score
FROM documents
WHERE search_vector @@ plainto_tsquery('english', $2)
ORDER BY combined_score DESC
LIMIT 10;
```

**When to use each:**
- Strategy 1: Fast, simple. Good when keyword filter is strict.
- Strategy 2 (RRF): Best general-purpose hybrid. No need to normalize scores.
- Strategy 3: When you want direct control over vector vs text weight.

---

## Reciprocal Rank Fusion (RRF)

RRF merges ranked lists without requiring score normalization. It uses the formula:

```
RRF_score(d) = Σ 1 / (k + rank_i(d))
```

Where `k` is a constant (typically 60) and `rank_i(d)` is the rank of document `d` in list `i`.

### Standard Implementation

```sql
CREATE OR REPLACE FUNCTION hybrid_search(
    query_embedding vector(1536),
    query_text text,
    match_count int DEFAULT 10,
    rrf_k int DEFAULT 60,
    vector_weight float DEFAULT 1.0,
    text_weight float DEFAULT 1.0
)
RETURNS TABLE(id bigint, title text, content text, rrf_score float)
LANGUAGE sql STABLE AS $$
    WITH vector_results AS (
        SELECT d.id, ROW_NUMBER() OVER (ORDER BY d.embedding <=> query_embedding) AS rank_v
        FROM documents d
        ORDER BY d.embedding <=> query_embedding
        LIMIT match_count * 3
    ),
    fts_results AS (
        SELECT d.id, ROW_NUMBER() OVER (
            ORDER BY ts_rank_cd(d.search_vector, websearch_to_tsquery('english', query_text)) DESC
        ) AS rank_f
        FROM documents d
        WHERE d.search_vector @@ websearch_to_tsquery('english', query_text)
        LIMIT match_count * 3
    )
    SELECT
        d.id, d.title, d.content,
        COALESCE(vector_weight / (rrf_k + v.rank_v), 0.0) +
        COALESCE(text_weight / (rrf_k + f.rank_f), 0.0) AS rrf_score
    FROM documents d
    LEFT JOIN vector_results v ON d.id = v.id
    LEFT JOIN fts_results f ON d.id = f.id
    WHERE v.id IS NOT NULL OR f.id IS NOT NULL
    ORDER BY rrf_score DESC
    LIMIT match_count;
$$;
```

### Usage

```sql
SELECT * FROM hybrid_search(
    '[0.1, 0.2, ...]'::vector(1536),
    'PostgreSQL vector search',
    10,     -- match_count
    60,     -- rrf_k
    1.0,    -- vector_weight
    1.0     -- text_weight
);
```

### Tuning `k`

| k value | Behavior |
|---------|----------|
| 1–10 | Top-ranked results dominate heavily |
| 60 (default) | Balanced — standard in literature |
| 100–200 | Flatter ranking — lower-ranked results get more influence |

### Multi-source RRF

Extend to three or more sources:

```sql
-- Add a metadata/recency signal
WITH vector_results AS (...),
     fts_results AS (...),
     recency_results AS (
         SELECT id, ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rank_r
         FROM documents
         LIMIT match_count * 3
     )
SELECT d.id,
    COALESCE(1.0 / (60 + v.rank_v), 0) +
    COALESCE(1.0 / (60 + f.rank_f), 0) +
    COALESCE(0.5 / (60 + r.rank_r), 0)  -- lower weight for recency
    AS rrf_score
FROM documents d
LEFT JOIN vector_results v ON d.id = v.id
LEFT JOIN fts_results f ON d.id = f.id
LEFT JOIN recency_results r ON d.id = r.id
WHERE v.id IS NOT NULL OR f.id IS NOT NULL OR r.id IS NOT NULL
ORDER BY rrf_score DESC
LIMIT 10;
```

---

## Multi-Vector Search

### Document Chunk Search

When documents are split into chunks, each chunk gets its own embedding. Find the best document by aggregating chunk scores:

```sql
CREATE TABLE doc_chunks (
    id BIGSERIAL PRIMARY KEY,
    document_id BIGINT REFERENCES documents(id),
    chunk_index INT NOT NULL,
    chunk_text TEXT NOT NULL,
    embedding vector(1536)
);
CREATE INDEX ON doc_chunks USING hnsw (embedding vector_cosine_ops);

-- Find best documents (not just chunks)
SELECT document_id, MIN(embedding <=> $1) AS best_distance,
       COUNT(*) AS matching_chunks
FROM doc_chunks
ORDER BY embedding <=> $1
LIMIT 50  -- oversample chunks
GROUP BY document_id
ORDER BY best_distance
LIMIT 10;
```

### MaxSim (ColBERT-style multi-vector)

Late interaction models produce one vector per token. Score by max similarity across token pairs:

```sql
-- Store per-token embeddings
CREATE TABLE doc_token_embeddings (
    id BIGSERIAL PRIMARY KEY,
    document_id BIGINT,
    token_index INT,
    embedding vector(128)  -- ColBERT uses 128-dim
);
CREATE INDEX ON doc_token_embeddings USING hnsw (embedding vector_cosine_ops);

-- MaxSim: for each query token, find best matching doc token
-- Then sum the max similarities per query token
WITH query_tokens AS (
    SELECT unnest AS token_embedding, ROW_NUMBER() OVER () AS token_idx
    FROM unnest($1::vector[])
),
token_matches AS (
    SELECT qt.token_idx, dte.document_id,
           MAX(1 - (dte.embedding <=> qt.token_embedding)) AS max_sim
    FROM query_tokens qt
    CROSS JOIN LATERAL (
        SELECT document_id, embedding
        FROM doc_token_embeddings
        ORDER BY embedding <=> qt.token_embedding
        LIMIT 100
    ) dte
    GROUP BY qt.token_idx, dte.document_id
)
SELECT document_id, SUM(max_sim) AS maxsim_score
FROM token_matches
GROUP BY document_id
ORDER BY maxsim_score DESC
LIMIT 10;
```

### Multi-Modal Search

Store different modalities (text, image, audio) with aligned embeddings (e.g., CLIP):

```sql
CREATE TABLE multimodal_items (
    id BIGSERIAL PRIMARY KEY,
    modality TEXT CHECK (modality IN ('text', 'image', 'audio')),
    source_uri TEXT,
    description TEXT,
    embedding vector(768)  -- CLIP ViT-L/14 dimension
);
CREATE INDEX ON multimodal_items USING hnsw (embedding vector_cosine_ops);

-- Cross-modal search: text query → find images
SELECT id, source_uri, description, embedding <=> $1 AS distance
FROM multimodal_items
WHERE modality = 'image'
ORDER BY embedding <=> $1
LIMIT 10;
```

---

## Filtered Vector Search Optimization

Filtered vector search is one of the most common — and most tricky — patterns. The key challenge: the ANN index doesn't know about your filters.

### Pre-filtering vs Post-filtering

**Post-filtering (default behavior):**
The ANN index returns top-K candidates, then non-matching rows are discarded. If the filter is selective, you may get fewer than K results.

```sql
-- Post-filtering: index finds 10 nearest, then filters
SELECT * FROM items
WHERE category = 'electronics'
ORDER BY embedding <=> $1
LIMIT 10;
-- May return < 10 rows if few electronics items are in the top candidates
```

**Pre-filtering (partial index):**
Build a separate index for each hot filter value:

```sql
-- Pre-filtering via partial index
CREATE INDEX idx_items_electronics ON items
    USING hnsw (embedding vector_cosine_ops)
    WHERE category = 'electronics';

-- Planner uses the partial index → always returns 10 results
SELECT * FROM items
WHERE category = 'electronics'
ORDER BY embedding <=> $1
LIMIT 10;
```

### Iterative Scan (pgvector 0.8+)

The best solution for filtered queries — keeps scanning the index until LIMIT is satisfied:

```sql
SET hnsw.iterative_scan = relaxed_order;
SET hnsw.max_scan_tuples = 20000;  -- max candidates to consider

-- Now guaranteed to return 10 results (if 10 exist)
SELECT * FROM items
WHERE category = 'electronics'
ORDER BY embedding <=> $1
LIMIT 10;
```

### Optimization Strategies

| Strategy | Best When | Overhead |
|----------|-----------|----------|
| Partial indexes | Few distinct filter values (< 20), hot filters | One index per filter value |
| Iterative scan | Many distinct values, moderate selectivity | Extra candidate scanning |
| Over-fetch + filter | Moderate selectivity (>10% of rows match) | Memory for extra candidates |
| Partitioned tables | Very large tables, natural partition key | Schema complexity |

### Over-fetch Pattern

```sql
-- Fetch 5× candidates, filter, re-rank
WITH candidates AS (
    SELECT id, content, category, embedding <=> $1 AS distance
    FROM items
    ORDER BY embedding <=> $1
    LIMIT 50  -- 5× the desired count
)
SELECT * FROM candidates
WHERE category = 'electronics'
ORDER BY distance
LIMIT 10;
```

---

## Halfvec and Binary Quantization

### Halfvec (float16)

Halfvec stores each dimension in 2 bytes instead of 4, cutting storage by 50%:

```sql
ALTER TABLE items ADD COLUMN embedding_half halfvec(1536);
UPDATE items SET embedding_half = embedding::halfvec(1536);

CREATE INDEX ON items USING hnsw (embedding_half halfvec_cosine_ops)
    WITH (m = 16, ef_construction = 128);
```

**Tradeoffs:**
- Index supports up to 4000 dimensions (vs 2000 for vector).
- Typical recall loss: < 1% for most embedding models.
- 50% storage reduction on both heap and index.
- Recommended for dimensions > 1024 where storage matters.

### Binary Quantization

Converts each float dimension to a single bit (positive → 1, zero/negative → 0):

```sql
-- Create binary column
ALTER TABLE items ADD COLUMN embedding_bin bit(1536);
UPDATE items SET embedding_bin = binary_quantize(embedding)::bit(1536);

CREATE INDEX ON items USING hnsw (embedding_bin bit_hamming_ops);
```

**Two-stage search for high recall:**

```sql
-- Stage 1: Fast coarse search with binary vectors (32× less memory)
-- Stage 2: Re-rank top candidates with full-precision vectors
WITH candidates AS (
    SELECT id, embedding
    FROM items
    ORDER BY embedding_bin <~> binary_quantize($1::vector)::bit(1536)
    LIMIT 200  -- oversample
)
SELECT id, embedding <=> $1 AS distance
FROM candidates
ORDER BY distance
LIMIT 10;
```

**Storage comparison (1M vectors × 1536 dims):**

| Type | Per Vector | Total (1M) | Index Size (HNSW, m=16) |
|------|-----------|------------|------------------------|
| vector (float32) | 6,144 B | 5.7 GB | ~1.8 GB |
| halfvec (float16) | 3,072 B | 2.9 GB | ~0.9 GB |
| bit (binary) | 192 B | 183 MB | ~0.06 GB |

### Matryoshka Embedding Truncation

Some models (OpenAI text-embedding-3-*) support Matryoshka representation learning — you can truncate vectors and still get useful embeddings:

```sql
-- Store full 3072-dim embedding and truncated 256-dim version
ALTER TABLE items ADD COLUMN embedding_small vector(256);
UPDATE items SET embedding_small = (embedding::real[])[1:256]::vector(256);

-- Build index on small version for fast search
CREATE INDEX ON items USING hnsw (embedding_small vector_cosine_ops);

-- Two-stage: coarse search on 256-dim, re-rank on full 3072-dim
WITH candidates AS (
    SELECT id, embedding
    FROM items
    ORDER BY embedding_small <=> ($1::real[])[1:256]::vector(256)
    LIMIT 100
)
SELECT id, embedding <=> $1 AS distance
FROM candidates
ORDER BY distance
LIMIT 10;
```

---

## Sparse Vector Operations

Sparse vectors store only non-zero elements, ideal for high-dimensional sparse data like BM25 scores, TF-IDF, or SPLADE outputs.

### Schema and Insertion

```sql
CREATE TABLE sparse_items (
    id BIGSERIAL PRIMARY KEY,
    content TEXT,
    sparse_embedding sparsevec(30000)  -- SPLADE output dimension
);

-- Insert with sparse format: {index:value,...}/total_dims
INSERT INTO sparse_items (content, sparse_embedding) VALUES
    ('query about databases', '{1:0.5,42:0.8,999:0.3,5000:1.2}/30000'),
    ('PostgreSQL tutorial', '{1:0.3,100:0.9,5000:0.7,29999:0.1}/30000');
```

### Querying

```sql
-- L2 distance on sparse vectors
SELECT id, content,
    sparse_embedding <-> '{1:0.4,42:0.7,5000:1.0}/30000'::sparsevec AS distance
FROM sparse_items
ORDER BY distance
LIMIT 10;
```

### HNSW Index on Sparse Vectors

```sql
CREATE INDEX ON sparse_items USING hnsw (sparse_embedding sparsevec_l2_ops);
```

**Supported ops classes for sparsevec:**
- `sparsevec_l2_ops` (L2 distance `<->`)
- `sparsevec_ip_ops` (inner product `<#>`)
- `sparsevec_cosine_ops` (cosine distance `<=>`)

### Combining Dense + Sparse (Hybrid Retrieval)

```sql
CREATE TABLE hybrid_items (
    id BIGSERIAL PRIMARY KEY,
    content TEXT,
    dense_embedding vector(1536),    -- semantic
    sparse_embedding sparsevec(30000) -- lexical (SPLADE)
);

-- RRF over dense + sparse
WITH dense_results AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY dense_embedding <=> $1) AS rank_d
    FROM hybrid_items ORDER BY dense_embedding <=> $1 LIMIT 20
),
sparse_results AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY sparse_embedding <#> $2) AS rank_s
    FROM hybrid_items ORDER BY sparse_embedding <#> $2 LIMIT 20
)
SELECT h.id, h.content,
    COALESCE(1.0/(60 + d.rank_d), 0) + COALESCE(1.0/(60 + s.rank_s), 0) AS score
FROM hybrid_items h
LEFT JOIN dense_results d ON h.id = d.id
LEFT JOIN sparse_results s ON h.id = s.id
WHERE d.id IS NOT NULL OR s.id IS NOT NULL
ORDER BY score DESC LIMIT 10;
```

---

## Partitioned Tables with pgvector

For very large datasets (10M+ vectors), partition tables to keep indexes manageable and enable partition pruning.

### Range Partitioning (by date)

```sql
CREATE TABLE embeddings (
    id BIGSERIAL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    content TEXT,
    embedding vector(1536)
) PARTITION BY RANGE (created_at);

CREATE TABLE embeddings_2024_q1 PARTITION OF embeddings
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
CREATE TABLE embeddings_2024_q2 PARTITION OF embeddings
    FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');

-- Each partition gets its own HNSW index
CREATE INDEX ON embeddings_2024_q1 USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON embeddings_2024_q2 USING hnsw (embedding vector_cosine_ops);
```

### List Partitioning (by tenant)

```sql
CREATE TABLE tenant_embeddings (
    id BIGSERIAL,
    tenant_id TEXT NOT NULL,
    content TEXT,
    embedding vector(1536)
) PARTITION BY LIST (tenant_id);

CREATE TABLE tenant_embeddings_acme PARTITION OF tenant_embeddings
    FOR VALUES IN ('acme');
CREATE TABLE tenant_embeddings_globex PARTITION OF tenant_embeddings
    FOR VALUES IN ('globex');

-- Index per partition
CREATE INDEX ON tenant_embeddings_acme USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON tenant_embeddings_globex USING hnsw (embedding vector_cosine_ops);
```

### Query with Partition Pruning

```sql
-- Planner skips partitions that don't match the WHERE clause
SELECT id, content, embedding <=> $1 AS distance
FROM embeddings
WHERE created_at >= '2024-04-01' AND created_at < '2024-07-01'
ORDER BY embedding <=> $1
LIMIT 10;
-- Only scans embeddings_2024_q2 and its index
```

### Best Practices for Partitioned pgvector

1. **Keep partitions under 5M rows** — HNSW build time and memory scale with partition size.
2. **Always filter on the partition key** — otherwise all partitions are scanned.
3. **Create indexes per partition**, not on the parent table.
4. **Use `CONCURRENTLY` for index builds** on live partitions.
5. **Consider hash partitioning** for uniform distribution when no natural range exists:

```sql
CREATE TABLE hash_embeddings (
    id BIGSERIAL,
    embedding vector(1536)
) PARTITION BY HASH (id);

CREATE TABLE hash_embeddings_p0 PARTITION OF hash_embeddings
    FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE hash_embeddings_p1 PARTITION OF hash_embeddings
    FOR VALUES WITH (MODULUS 4, REMAINDER 1);
-- ... p2, p3
```

### Caveats

- Cross-partition vector search scans all matching partitions and merges results — this is slower than a single index.
- pgvector does not support global HNSW indexes across partitions.
- For multi-tenant, consider one schema per tenant if tenant count is small and isolation matters.
