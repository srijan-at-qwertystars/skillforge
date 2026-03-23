---
name: pgvector-embeddings
description: >
  Use when: writing SQL or Python code for vector similarity search in PostgreSQL,
  storing/querying embeddings with pgvector, building RAG pipelines over Postgres,
  creating HNSW or IVFFlat indexes on vector columns, using halfvec/sparsevec/bit
  types, combining vector search with full-text search (hybrid search), tuning
  pgvector index parameters (ef_construction, m, lists, probes), choosing distance
  functions (L2, cosine, inner product), integrating OpenAI/Cohere embeddings with
  PostgreSQL, or using pgvector with psycopg/SQLAlchemy/Django.
  Do NOT use when: working with standalone vector databases (Pinecone, Weaviate,
  Qdrant, Milvus, ChromaDB), using SQLite/MySQL/MongoDB, doing general PostgreSQL
  administration unrelated to vectors, or working with non-embedding ML tasks like
  training models or running inference.
---

# pgvector Embeddings — PostgreSQL Vector Search

## Installation & Setup

Enable the extension (requires pgvector installed on the server):

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

Requires PostgreSQL 13+ (pgvector 0.8+). Verify:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'vector';
-- Returns: 0.8.0
```

## Vector Column Types

### `vector` — Dense float32 vectors
```sql
CREATE TABLE items (
    id BIGSERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    embedding vector(1536)  -- OpenAI ada-002 dimension
);
```

### `halfvec` — Half-precision float16 (saves 50% storage)
```sql
ALTER TABLE items ADD COLUMN embedding_half halfvec(1536);
-- Index supports up to 4000 dimensions (vs 2000 for vector)
```

### `sparsevec` — Sparse vectors (high-dim, mostly zeros)
```sql
ALTER TABLE items ADD COLUMN sparse_emb sparsevec(10000);
-- Insert sparse format: {index1:val1,index2:val2}/total_dims
INSERT INTO items (sparse_emb) VALUES ('{1:0.5,42:0.8,999:0.3}/10000');
```

### `bit` — Binary vectors (ultra-compact)
```sql
ALTER TABLE items ADD COLUMN binary_emb bit(1536);
-- Supports up to 64,000 dimensions. Use Hamming/Jaccard distance.
```

## Distance Functions & Operators

| Function        | Operator | Index Ops Class           | Use When                         |
|----------------|----------|---------------------------|----------------------------------|
| L2 (Euclidean) | `<->`    | `vector_l2_ops`           | Default for most embeddings      |
| Inner Product  | `<#>`    | `vector_ip_ops`           | Pre-normalized embeddings        |
| Cosine         | `<=>`    | `vector_cosine_ops`       | Text embeddings (OpenAI, Cohere) |
| L1 (Manhattan) | `<+>`    | `vector_l1_ops`           | Sparse or categorical data       |
| Hamming        | `<~>`    | `bit_hamming_ops`         | Binary quantized vectors         |
| Jaccard        | `<%>`    | `bit_jaccard_ops`         | Binary set similarity            |

**Note:** `<#>` returns negative inner product. Negate for actual similarity.

## Indexing Strategies

### HNSW — Use for production workloads (default choice)
```sql
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
```

- **m** (default 16): Max connections per node. Higher → better recall, more RAM/build time. Range: 2–100.
- **ef_construction** (default 64): Build-time search width. Higher → better recall, slower build. Range: 4–1000.
- No training step. Handles inserts without rebuild.
- Search-time tuning:
```sql
SET hnsw.ef_search = 100;  -- default 40. Higher → better recall, slower query.
```

### IVFFlat — Use for quick prototyping or low-memory environments
```sql
CREATE INDEX ON items USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);
```

- **lists**: Number of clusters. Rule of thumb: `sqrt(row_count)` for <1M rows, `row_count / 1000` for 1M+.
- **Requires data first** — builds clusters from existing rows. Empty table → useless index.
- Search-time tuning:
```sql
SET ivfflat.probes = 10;  -- default 1. Higher → better recall, slower query.
```

### When to choose

| Criteria                    | HNSW    | IVFFlat |
|-----------------------------|---------|---------|
| Query speed                 | Faster  | Slower  |
| Recall accuracy             | Higher  | Lower   |
| Index build time            | Slower  | Faster  |
| Memory usage                | Higher  | Lower   |
| Handles inserts gracefully  | Yes     | No (needs rebuild) |
| Needs training data         | No      | Yes     |

**Default to HNSW** unless memory-constrained or building a quick prototype.

### Iterative Scans (pgvector 0.8+)
Enable for filtered queries to guarantee result count:
```sql
SET hnsw.iterative_scan = relaxed_order;
SET hnsw.max_scan_tuples = 20000;
-- Now filtered queries keep scanning until LIMIT is satisfied
```

## Querying Patterns

### Nearest neighbor search
```sql
-- Find 10 closest items by cosine distance
SELECT id, content, embedding <=> '[0.1,0.2,...,0.05]'::vector AS distance
FROM items
ORDER BY embedding <=> '[0.1,0.2,...,0.05]'::vector
LIMIT 10;
```

### Filtered search
```sql
-- Nearest neighbor within a category
SELECT id, content
FROM items
WHERE category = 'electronics'
ORDER BY embedding <=> $1
LIMIT 10;
```
Create a partial index for hot filters:
```sql
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops)
    WHERE category = 'electronics';
```

### Distance threshold search
```sql
SELECT id, content
FROM items
WHERE embedding <=> $1 < 0.3
ORDER BY embedding <=> $1
LIMIT 50;
```

### Batch similarity (find duplicates)
```sql
SELECT a.id, b.id, a.embedding <=> b.embedding AS distance
FROM items a
CROSS JOIN LATERAL (
    SELECT id, embedding FROM items
    WHERE id > a.id
    ORDER BY embedding <=> a.embedding
    LIMIT 1
) b
WHERE a.embedding <=> b.embedding < 0.1;
```

## Hybrid Search (Vector + Full-Text)

Combine semantic and lexical search using Reciprocal Rank Fusion (RRF):

```sql
-- Schema with both vector and tsvector
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    embedding vector(1536),
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED
);
CREATE INDEX ON documents USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON documents USING gin (search_vector);

-- Hybrid search with RRF
WITH vector_results AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY embedding <=> $1) AS rank_v
    FROM documents
    ORDER BY embedding <=> $1
    LIMIT 20
),
fts_results AS (
    SELECT id, ROW_NUMBER() OVER (
        ORDER BY ts_rank(search_vector, plainto_tsquery('english', $2)) DESC
    ) AS rank_f
    FROM documents
    WHERE search_vector @@ plainto_tsquery('english', $2)
    LIMIT 20
)
SELECT d.id, d.content,
    COALESCE(1.0 / (v.rank_v + 60), 0) +
    COALESCE(1.0 / (f.rank_f + 60), 0) AS rrf_score
FROM documents d
LEFT JOIN vector_results v ON d.id = v.id
LEFT JOIN fts_results f ON d.id = f.id
WHERE v.id IS NOT NULL OR f.id IS NOT NULL
ORDER BY rrf_score DESC
LIMIT 10;
```
The constant `60` is the RRF k-parameter. Tune between 1–100 based on preference for vector vs text results.

## Binary Quantization for Speed

Quantize float vectors to binary for fast coarse search, then re-rank:

```sql
-- Add binary column and index
ALTER TABLE items ADD COLUMN embedding_bin bit(1536);
UPDATE items SET embedding_bin = binary_quantize(embedding)::bit(1536);
CREATE INDEX ON items USING hnsw (embedding_bin bit_hamming_ops);

-- Two-stage search: fast binary filter → precise re-rank
WITH candidates AS (
    SELECT id, embedding
    FROM items
    ORDER BY embedding_bin <~> binary_quantize($1::vector)::bit(1536)
    LIMIT 100
)
SELECT id, embedding <=> $1 AS distance
FROM candidates
ORDER BY distance
LIMIT 10;
```

## Python Integration

### psycopg (v3, recommended)
```python
import psycopg
from pgvector.psycopg import register_vector

conn = psycopg.connect("postgresql://user:pass@localhost/db")
register_vector(conn)

# Insert
embedding = [0.1, 0.2, 0.3]  # from your embedding API
conn.execute(
    "INSERT INTO items (content, embedding) VALUES (%s, %s)",
    ("sample text", embedding)
)

# Query nearest neighbors
results = conn.execute(
    "SELECT id, content, embedding <=> %s AS dist "
    "FROM items ORDER BY embedding <=> %s LIMIT 5",
    (embedding, embedding)
).fetchall()
```

### psycopg2 (legacy)
```python
import psycopg2
from pgvector.psycopg2 import register_vector

conn = psycopg2.connect("dbname=mydb")
register_vector(conn)
cur = conn.cursor()
cur.execute("INSERT INTO items (embedding) VALUES (%s)", ([0.1, 0.2, 0.3],))
conn.commit()
```

### SQLAlchemy
```python
from sqlalchemy import create_engine, Column, Integer, Text
from sqlalchemy.orm import declarative_base, Session
from pgvector.sqlalchemy import Vector, HalfVector

Base = declarative_base()

class Item(Base):
    __tablename__ = "items"
    id = Column(Integer, primary_key=True)
    content = Column(Text)
    embedding = Column(Vector(1536))         # float32
    embedding_half = Column(HalfVector(1536)) # float16

engine = create_engine("postgresql+psycopg://user:pass@localhost/db")
Base.metadata.create_all(engine)

# Query with distance
from pgvector.sqlalchemy import cosine_distance
with Session(engine) as session:
    q = [0.1] * 1536
    results = session.query(Item).order_by(
        cosine_distance(Item.embedding, q)
    ).limit(10).all()
```

### Django
```python
# models.py
from pgvector.django import VectorField, HnswIndex

class Document(models.Model):
    content = models.TextField()
    embedding = VectorField(dimensions=1536)

    class Meta:
        indexes = [
            HnswIndex(
                name="doc_embedding_idx",
                fields=["embedding"],
                m=16, ef_construction=64,
                opclasses=["vector_cosine_ops"],
            )
        ]

# queries.py
from pgvector.django import CosineDistance
results = Document.objects.order_by(
    CosineDistance("embedding", query_vector)
)[:10]
```

### Batch insert with COPY (fastest)
```python
import io, struct
import psycopg

def vectors_to_copy_buffer(rows):
    buf = io.StringIO()
    for content, emb in rows:
        vec_str = "[" + ",".join(str(x) for x in emb) + "]"
        buf.write(f"{content}\t{vec_str}\n")
    buf.seek(0)
    return buf

with psycopg.connect("postgresql://user:pass@localhost/db") as conn:
    with conn.cursor() as cur:
        buf = vectors_to_copy_buffer(rows)
        with cur.copy("COPY items (content, embedding) FROM STDIN") as copy:
            while data := buf.read(8192):
                copy.write(data)
```

## Embedding API Integration

### OpenAI
```python
from openai import OpenAI
client = OpenAI()

def get_embedding(text: str) -> list[float]:
    resp = client.embeddings.create(input=text, model="text-embedding-3-small")
    return resp.data[0].embedding  # 1536 dims

# Store
embedding = get_embedding("PostgreSQL is a powerful database")
conn.execute("INSERT INTO items (content, embedding) VALUES (%s, %s)",
             ("PostgreSQL is a powerful database", embedding))
```

### Cohere
```python
import cohere
co = cohere.Client("your-api-key")

def get_embeddings(texts: list[str]) -> list[list[float]]:
    resp = co.embed(texts=texts, model="embed-english-v3.0",
                    input_type="search_document")
    return resp.embeddings  # 1024 dims
```

### Local models (sentence-transformers)
```python
from sentence_transformers import SentenceTransformer
model = SentenceTransformer("all-MiniLM-L6-v2")  # 384 dims

embeddings = model.encode(["text one", "text two"]).tolist()
```

## Performance Optimization

### Index build — set memory high
```sql
SET maintenance_work_mem = '8GB';       -- Prevents disk spill during HNSW build
SET max_parallel_maintenance_workers = 7; -- Parallel index build (pgvector 0.5.1+)
CREATE INDEX CONCURRENTLY ON items USING hnsw (embedding vector_cosine_ops);
```

### Monitor index build progress
```sql
SELECT phase, tuples_done, tuples_total,
       ROUND(100.0 * tuples_done / NULLIF(tuples_total, 0), 1) AS pct
FROM pg_stat_progress_create_index;
```

### Batch insert strategy
1. Drop or defer index creation
2. Bulk load with `COPY` or multi-row `INSERT`
3. Create index after load completes
4. Run `VACUUM ANALYZE` on the table

```sql
-- After bulk load
VACUUM ANALYZE items;
```

### Check index size
```sql
SELECT indexrelid::regclass AS index_name,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE relname = 'items';
```

### Warm OS page cache
```sql
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
SELECT pg_prewarm('items_embedding_idx');
```

## Common Pitfalls

| Pitfall | Fix |
|---------|-----|
| Index build OOM / extremely slow | Increase `maintenance_work_mem` to 2–16GB |
| Poor recall on IVFFlat | Increase `ivfflat.probes` (try 10–50) |
| IVFFlat index on empty table | Load data first, then create index |
| HNSW recall too low | Increase `hnsw.ef_search` (try 100–400) |
| Filtered query returns too few rows | Enable `hnsw.iterative_scan = relaxed_order` (0.8+) |
| Dimension mismatch error | Ensure all vectors match column dimension exactly |
| Slow queries without index | Always create an ANN index for tables > 10K rows |
| Index not used by planner | Check `EXPLAIN` — planner may prefer seq scan for small tables. Use `SET enable_seqscan = off` to test |
| `halfvec` precision loss | Acceptable for most embeddings; validate recall on your data |
| Embedding dimension > 2000 | Use `halfvec` (up to 4000) or reduce dims via PCA/Matryoshka |
