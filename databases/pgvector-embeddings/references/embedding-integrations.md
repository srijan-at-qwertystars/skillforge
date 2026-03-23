# Embedding Model Integrations for pgvector

## Table of Contents

- [OpenAI Embeddings API](#openai-embeddings-api)
- [Cohere Embed v3](#cohere-embed-v3)
- [Local Models](#local-models)
- [Batch Embedding Strategies](#batch-embedding-strategies)
- [Embedding Caching Patterns](#embedding-caching-patterns)
- [Dimension Reduction Techniques](#dimension-reduction-techniques)
- [Cost Optimization for Embedding APIs](#cost-optimization-for-embedding-apis)

---

## OpenAI Embeddings API

### Available Models

| Model | Dimensions | Max Tokens | Cost (per 1M tokens) | Notes |
|-------|-----------|------------|---------------------|-------|
| text-embedding-3-large | 3072 (default) | 8191 | ~$0.13 | Best quality, Matryoshka support |
| text-embedding-3-small | 1536 (default) | 8191 | ~$0.02 | Good balance of cost/quality |
| text-embedding-ada-002 | 1536 (fixed) | 8191 | ~$0.10 | Legacy, no Matryoshka |

### Basic Usage

```python
from openai import OpenAI

client = OpenAI()  # uses OPENAI_API_KEY env var

def get_embedding(text: str, model: str = "text-embedding-3-small") -> list[float]:
    """Get embedding for a single text."""
    text = text.replace("\n", " ").strip()
    response = client.embeddings.create(input=text, model=model)
    return response.data[0].embedding

# Insert into pgvector
embedding = get_embedding("PostgreSQL vector search is powerful")
conn.execute(
    "INSERT INTO items (content, embedding) VALUES (%s, %s)",
    ("PostgreSQL vector search is powerful", embedding)
)
```

### Batch Embeddings (up to 2048 inputs per request)

```python
def get_embeddings_batch(
    texts: list[str],
    model: str = "text-embedding-3-small",
    batch_size: int = 2048
) -> list[list[float]]:
    """Get embeddings for multiple texts in batches."""
    all_embeddings = []
    for i in range(0, len(texts), batch_size):
        batch = [t.replace("\n", " ").strip() for t in texts[i:i + batch_size]]
        response = client.embeddings.create(input=batch, model=model)
        # Response may not preserve order — sort by index
        sorted_data = sorted(response.data, key=lambda x: x.index)
        all_embeddings.extend([d.embedding for d in sorted_data])
    return all_embeddings
```

### Matryoshka Dimension Reduction

text-embedding-3-* models support requesting fewer dimensions:

```python
def get_embedding_reduced(
    text: str,
    dimensions: int = 256,
    model: str = "text-embedding-3-large"
) -> list[float]:
    """Get a dimensionally-reduced embedding (Matryoshka)."""
    response = client.embeddings.create(
        input=text,
        model=model,
        dimensions=dimensions  # 256, 512, 1024, 1536, or 3072
    )
    return response.data[0].embedding

# Store in a smaller vector column
embedding = get_embedding_reduced("sample text", dimensions=256)
conn.execute(
    "INSERT INTO items_small (content, embedding) VALUES (%s, %s)",
    ("sample text", embedding)
)
```

**Recommended dimensions for text-embedding-3-large:**

| Dimensions | MTEB Score (relative) | Storage Savings |
|-----------|----------------------|-----------------|
| 3072 | 100% | — |
| 1536 | ~99% | 50% |
| 1024 | ~98% | 67% |
| 512 | ~96% | 83% |
| 256 | ~93% | 92% |

### Error Handling and Retries

```python
import time
from openai import RateLimitError, APITimeoutError, APIConnectionError

def get_embedding_robust(
    text: str,
    model: str = "text-embedding-3-small",
    max_retries: int = 5
) -> list[float]:
    """Get embedding with exponential backoff retry."""
    for attempt in range(max_retries):
        try:
            response = client.embeddings.create(input=text, model=model)
            return response.data[0].embedding
        except RateLimitError:
            wait = 2 ** attempt
            time.sleep(wait)
        except (APITimeoutError, APIConnectionError):
            wait = min(2 ** attempt, 30)
            time.sleep(wait)
    raise RuntimeError(f"Failed to get embedding after {max_retries} retries")
```

---

## Cohere Embed v3

### Available Models

| Model | Dimensions | Max Tokens | Notes |
|-------|-----------|------------|-------|
| embed-english-v3.0 | 1024 | 512 | English-optimized |
| embed-multilingual-v3.0 | 1024 | 512 | 100+ languages |
| embed-english-light-v3.0 | 384 | 512 | Faster, smaller |
| embed-multilingual-light-v3.0 | 384 | 512 | Multilingual, smaller |

### Key Difference: `input_type`

Cohere v3 requires specifying the input type for asymmetric search:

```python
import cohere

co = cohere.ClientV2("your-api-key")  # or COHERE_API_KEY env var

def embed_documents(texts: list[str]) -> list[list[float]]:
    """Embed documents for storage (use 'search_document' type)."""
    response = co.embed(
        texts=texts,
        model="embed-english-v3.0",
        input_type="search_document",   # for docs being stored
        embedding_types=["float"]
    )
    return response.embeddings.float_

def embed_query(text: str) -> list[float]:
    """Embed a query for searching (use 'search_query' type)."""
    response = co.embed(
        texts=[text],
        model="embed-english-v3.0",
        input_type="search_query",      # for search queries
        embedding_types=["float"]
    )
    return response.embeddings.float_[0]
```

### Input Types

| input_type | Use For |
|-----------|---------|
| `search_document` | Documents being stored in the database |
| `search_query` | User search queries |
| `classification` | Text classification tasks |
| `clustering` | Clustering tasks |

**Always use `search_document` when inserting and `search_query` when searching.** Mixing these up significantly hurts recall.

### Batch with Cohere (up to 96 texts per request)

```python
def embed_documents_batch(
    texts: list[str],
    batch_size: int = 96
) -> list[list[float]]:
    """Batch embed documents for pgvector storage."""
    all_embeddings = []
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]
        response = co.embed(
            texts=batch,
            model="embed-english-v3.0",
            input_type="search_document",
            embedding_types=["float"]
        )
        all_embeddings.extend(response.embeddings.float_)
    return all_embeddings
```

### Binary and Compressed Embeddings (Cohere v3)

Cohere v3 natively supports binary and int8 embeddings:

```python
response = co.embed(
    texts=["sample"],
    model="embed-english-v3.0",
    input_type="search_document",
    embedding_types=["float", "int8", "binary"]
)

float_emb = response.embeddings.float_[0]    # 1024 floats
int8_emb = response.embeddings.int8[0]       # 1024 int8 values
binary_emb = response.embeddings.binary[0]   # 128 bytes (1024 bits)
```

Store binary embeddings in pgvector `bit` column for ultra-fast coarse search:

```sql
ALTER TABLE items ADD COLUMN embedding_bin bit(1024);
```

---

## Local Models

### sentence-transformers (Python)

Best for privacy-sensitive workloads, offline use, or high-volume embedding without API costs.

```python
from sentence_transformers import SentenceTransformer
import numpy as np

# Popular models
# all-MiniLM-L6-v2:  384 dims, fast,  good general purpose
# all-mpnet-base-v2: 768 dims, slower, better quality
# bge-large-en-v1.5: 1024 dims, SOTA for retrieval
# nomic-embed-text-v1.5: 768 dims, Matryoshka, long context

model = SentenceTransformer("all-MiniLM-L6-v2")

# Single text
embedding = model.encode("PostgreSQL with pgvector").tolist()

# Batch (automatically batches internally)
texts = ["text one", "text two", "text three"]
embeddings = model.encode(texts, batch_size=64, show_progress_bar=True).tolist()
```

### GPU Acceleration

```python
model = SentenceTransformer("all-MiniLM-L6-v2", device="cuda")

# Batch encode with GPU
embeddings = model.encode(
    texts,
    batch_size=256,    # larger batches for GPU
    show_progress_bar=True,
    convert_to_numpy=True,
    normalize_embeddings=True  # for cosine similarity
).tolist()
```

### Ollama

Run embedding models locally via Ollama:

```python
import requests

def ollama_embed(text: str, model: str = "nomic-embed-text") -> list[float]:
    """Get embedding from local Ollama instance."""
    response = requests.post(
        "http://localhost:11434/api/embeddings",
        json={"model": model, "prompt": text}
    )
    return response.json()["embedding"]

# Available models:
# nomic-embed-text:  768 dims
# mxbai-embed-large: 1024 dims
# all-minilm:        384 dims
# snowflake-arctic-embed: 1024 dims
```

### Batch with Ollama

```python
def ollama_embed_batch(
    texts: list[str],
    model: str = "nomic-embed-text"
) -> list[list[float]]:
    """Batch embed using Ollama (sequential, as Ollama processes one at a time)."""
    embeddings = []
    for text in texts:
        emb = ollama_embed(text, model)
        embeddings.append(emb)
    return embeddings
```

### HuggingFace Transformers (Direct)

For maximum control:

```python
import torch
from transformers import AutoTokenizer, AutoModel

tokenizer = AutoTokenizer.from_pretrained("BAAI/bge-large-en-v1.5")
model = AutoModel.from_pretrained("BAAI/bge-large-en-v1.5")

def embed_texts(texts: list[str]) -> list[list[float]]:
    encoded = tokenizer(texts, padding=True, truncation=True,
                        max_length=512, return_tensors="pt")
    with torch.no_grad():
        outputs = model(**encoded)
    # Mean pooling
    attention_mask = encoded["attention_mask"]
    token_embeddings = outputs.last_hidden_state
    input_mask_expanded = attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()
    embeddings = torch.sum(token_embeddings * input_mask_expanded, 1) / \
                 torch.clamp(input_mask_expanded.sum(1), min=1e-9)
    # Normalize for cosine similarity
    embeddings = torch.nn.functional.normalize(embeddings, p=2, dim=1)
    return embeddings.tolist()
```

### Model Comparison

| Model | Dims | MTEB Avg | Speed (CPU) | Speed (GPU) | License |
|-------|------|----------|-------------|-------------|---------|
| all-MiniLM-L6-v2 | 384 | 56.3 | ~2000/s | ~10000/s | Apache 2.0 |
| all-mpnet-base-v2 | 768 | 57.8 | ~500/s | ~5000/s | Apache 2.0 |
| bge-large-en-v1.5 | 1024 | 64.2 | ~200/s | ~3000/s | MIT |
| nomic-embed-text-v1.5 | 768 | 62.3 | ~800/s | ~6000/s | Apache 2.0 |
| OpenAI text-embedding-3-small | 1536 | 62.3 | API | API | Proprietary |
| OpenAI text-embedding-3-large | 3072 | 64.6 | API | API | Proprietary |
| Cohere embed-english-v3.0 | 1024 | 64.5 | API | API | Proprietary |

---

## Batch Embedding Strategies

### Pipeline Architecture

For large-scale embedding jobs (>100K documents):

```python
import psycopg
from pgvector.psycopg import register_vector
from concurrent.futures import ThreadPoolExecutor
import queue
import threading

class EmbeddingPipeline:
    """Producer-consumer pipeline for batch embedding + insertion."""

    def __init__(self, db_url: str, embed_fn, batch_size: int = 100):
        self.db_url = db_url
        self.embed_fn = embed_fn
        self.batch_size = batch_size
        self.queue = queue.Queue(maxsize=10)

    def _embed_worker(self, texts_batch: list[tuple[int, str]]):
        """Embed a batch and put results on the queue."""
        ids, texts = zip(*texts_batch)
        embeddings = self.embed_fn(list(texts))
        self.queue.put(list(zip(ids, texts, embeddings)))

    def _insert_worker(self):
        """Consume from queue and insert into database."""
        conn = psycopg.connect(self.db_url)
        register_vector(conn)
        while True:
            batch = self.queue.get()
            if batch is None:
                break
            with conn.cursor() as cur:
                cur.executemany(
                    "UPDATE items SET embedding = %s WHERE id = %s",
                    [(emb, id_) for id_, _, emb in batch]
                )
            conn.commit()
        conn.close()

    def run(self, items: list[tuple[int, str]]):
        """Process all items through the pipeline."""
        insert_thread = threading.Thread(target=self._insert_worker)
        insert_thread.start()

        with ThreadPoolExecutor(max_workers=4) as pool:
            for i in range(0, len(items), self.batch_size):
                batch = items[i:i + self.batch_size]
                pool.submit(self._embed_worker, batch)

        self.queue.put(None)  # signal done
        insert_thread.join()
```

### COPY-Based Bulk Insert

For initial loads, `COPY` is 5–10× faster than individual INSERTs:

```python
import io
import psycopg

def bulk_insert_embeddings(conn, items: list[tuple[str, list[float]]]):
    """Bulk insert using COPY (fastest method)."""
    buf = io.StringIO()
    for content, embedding in items:
        vec_str = "[" + ",".join(f"{x:.8f}" for x in embedding) + "]"
        # Escape tabs and newlines in content
        safe_content = content.replace("\t", " ").replace("\n", " ")
        buf.write(f"{safe_content}\t{vec_str}\n")
    buf.seek(0)

    with conn.cursor() as cur:
        with cur.copy("COPY items (content, embedding) FROM STDIN") as copy:
            while data := buf.read(8192):
                copy.write(data)
    conn.commit()
```

### Rate Limiting for API Providers

```python
import time
import threading

class RateLimiter:
    """Token bucket rate limiter for API calls."""

    def __init__(self, tokens_per_minute: int):
        self.rate = tokens_per_minute / 60.0
        self.tokens = tokens_per_minute
        self.max_tokens = tokens_per_minute
        self.last_refill = time.monotonic()
        self.lock = threading.Lock()

    def acquire(self, tokens: int = 1):
        while True:
            with self.lock:
                now = time.monotonic()
                elapsed = now - self.last_refill
                self.tokens = min(self.max_tokens, self.tokens + elapsed * self.rate)
                self.last_refill = now
                if self.tokens >= tokens:
                    self.tokens -= tokens
                    return
            time.sleep(0.1)

# Usage with OpenAI (1M TPM limit)
limiter = RateLimiter(tokens_per_minute=1_000_000)

def embed_with_rate_limit(texts: list[str]) -> list[list[float]]:
    est_tokens = sum(len(t.split()) * 1.3 for t in texts)
    limiter.acquire(int(est_tokens))
    return get_embeddings_batch(texts)
```

---

## Embedding Caching Patterns

### Content-Hash Cache Table

Avoid re-embedding identical content:

```sql
CREATE TABLE embedding_cache (
    content_hash TEXT PRIMARY KEY,  -- SHA-256 of content
    model TEXT NOT NULL,
    embedding vector(1536),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX ON embedding_cache (model, content_hash);
```

```python
import hashlib

def get_or_create_embedding(
    content: str,
    model: str = "text-embedding-3-small",
    conn=None
) -> list[float]:
    """Cache embeddings by content hash."""
    content_hash = hashlib.sha256(content.encode()).hexdigest()

    # Check cache
    row = conn.execute(
        "SELECT embedding FROM embedding_cache WHERE content_hash = %s AND model = %s",
        (content_hash, model)
    ).fetchone()

    if row:
        return row[0]

    # Generate and cache
    embedding = get_embedding(content, model)
    conn.execute(
        "INSERT INTO embedding_cache (content_hash, model, embedding) "
        "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
        (content_hash, model, embedding)
    )
    conn.commit()
    return embedding
```

### Redis Cache (for high-throughput)

```python
import redis
import json
import hashlib

r = redis.Redis()

def get_embedding_cached(text: str, model: str = "text-embedding-3-small") -> list[float]:
    cache_key = f"emb:{model}:{hashlib.sha256(text.encode()).hexdigest()}"

    cached = r.get(cache_key)
    if cached:
        return json.loads(cached)

    embedding = get_embedding(text, model)
    r.setex(cache_key, 86400 * 7, json.dumps(embedding))  # 7 day TTL
    return embedding
```

### Cache Invalidation Strategies

| Strategy | When to Use |
|----------|-------------|
| Content-hash | Default — identical text always gets same embedding |
| TTL-based | When model versions change periodically |
| Version key | Include model version in cache key for upgrades |
| No cache | When text is always unique (e.g., user queries) |

---

## Dimension Reduction Techniques

### Matryoshka Representation Learning (MRL)

Models trained with MRL (OpenAI text-embedding-3-*, nomic-embed-text-v1.5) produce embeddings where the first N dimensions are a valid lower-dimensional embedding.

**API-level truncation (preferred):**
```python
# OpenAI — request reduced dimensions directly
response = client.embeddings.create(
    input="sample text",
    model="text-embedding-3-large",
    dimensions=512  # truncated at the API level
)
```

**Post-hoc truncation (any MRL model):**
```python
import numpy as np

def truncate_embedding(embedding: list[float], target_dims: int) -> list[float]:
    """Truncate and re-normalize a Matryoshka embedding."""
    truncated = np.array(embedding[:target_dims])
    truncated = truncated / np.linalg.norm(truncated)
    return truncated.tolist()
```

**SQL-level truncation:**
```sql
-- Truncate stored 3072-dim to 256-dim
SELECT id, (embedding::real[])[1:256]::vector(256) <=> $1 AS distance
FROM items
ORDER BY (embedding::real[])[1:256]::vector(256) <=> $1
LIMIT 10;
```

### PCA Dimension Reduction

For non-MRL models, use PCA to reduce dimensions:

```python
from sklearn.decomposition import PCA
import numpy as np

# Fit PCA on your corpus embeddings
all_embeddings = np.array(get_all_embeddings())  # shape: (N, 1536)
pca = PCA(n_components=256)
pca.fit(all_embeddings)

# Transform new embeddings
def reduce_dimensions(embedding: list[float]) -> list[float]:
    reduced = pca.transform([embedding])[0]
    reduced = reduced / np.linalg.norm(reduced)
    return reduced.tolist()

# Store the PCA model for reuse
import joblib
joblib.dump(pca, "pca_1536_to_256.joblib")
```

### Random Projection (Fast, No Training)

```python
from sklearn.random_projection import GaussianRandomProjection

# Create projector (deterministic with random_state)
projector = GaussianRandomProjection(n_components=256, random_state=42)
projector.fit(np.zeros((1, 1536)))  # just needs shape

def project_embedding(embedding: list[float]) -> list[float]:
    projected = projector.transform([embedding])[0]
    projected = projected / np.linalg.norm(projected)
    return projected.tolist()
```

### Choosing a Reduction Method

| Method | Quality | Speed | Requires Training | Best For |
|--------|---------|-------|------------------|----------|
| Matryoshka (API) | Best | N/A | No | Models that support it |
| Matryoshka (truncate) | Very good | Instant | No | MRL-trained models |
| PCA | Good | Fast | Yes (on corpus) | Non-MRL models, moderate reduction |
| Random projection | Moderate | Instant | No | Quick experiments, large reductions |

---

## Cost Optimization for Embedding APIs

### Token Estimation

```python
import tiktoken

def estimate_tokens(texts: list[str], model: str = "text-embedding-3-small") -> int:
    """Estimate token count for cost calculation."""
    enc = tiktoken.encoding_for_model(model)
    return sum(len(enc.encode(text)) for text in texts)

def estimate_cost(texts: list[str], model: str = "text-embedding-3-small") -> float:
    """Estimate USD cost for embedding these texts."""
    costs_per_1m = {
        "text-embedding-3-small": 0.02,
        "text-embedding-3-large": 0.13,
        "text-embedding-ada-002": 0.10,
    }
    tokens = estimate_tokens(texts, model)
    return tokens / 1_000_000 * costs_per_1m.get(model, 0.10)
```

### Cost Reduction Strategies

**1. Use the smallest model that meets quality requirements**

Test recall on a sample before committing:
```python
# Embed 1000 samples with both models, compare recall
small_embs = get_embeddings_batch(samples, model="text-embedding-3-small")
large_embs = get_embeddings_batch(samples, model="text-embedding-3-large")
# Measure recall@10 against ground truth for both
```

**2. Reduce dimensions (Matryoshka)**

Lower dimensions = less storage, faster queries, same cost:
```python
embedding = get_embedding_reduced(text, dimensions=256, model="text-embedding-3-large")
```

**3. Cache embeddings aggressively**

See [Embedding Caching Patterns](#embedding-caching-patterns).

**4. Deduplicate before embedding**

```python
unique_texts = list(set(texts))
embeddings = get_embeddings_batch(unique_texts)
text_to_embedding = dict(zip(unique_texts, embeddings))
# Map back to original order
result = [text_to_embedding[t] for t in texts]
```

**5. Truncate long texts**

Most information is in the first ~500 tokens:
```python
def truncate_for_embedding(text: str, max_tokens: int = 512) -> str:
    enc = tiktoken.encoding_for_model("text-embedding-3-small")
    tokens = enc.encode(text)[:max_tokens]
    return enc.decode(tokens)
```

**6. Use local models for non-critical workloads**

| Use Case | Recommendation |
|----------|---------------|
| Production RAG (customer-facing) | OpenAI or Cohere API |
| Internal search / prototyping | sentence-transformers locally |
| High-volume (>10M docs) | Local model on GPU |
| Multilingual | Cohere multilingual or local multilingual model |

### Cost Comparison (1M documents × ~200 tokens each)

| Model | Total Tokens | Cost | Quality |
|-------|-------------|------|---------|
| text-embedding-3-small | 200M | $4.00 | Good |
| text-embedding-3-large | 200M | $26.00 | Best |
| text-embedding-ada-002 | 200M | $20.00 | Good (legacy) |
| Cohere embed-english-v3.0 | 200M | ~$10.00 | Best |
| all-MiniLM-L6-v2 (local) | 200M | $0 (compute only) | Moderate |
| bge-large-en-v1.5 (local) | 200M | $0 (compute only) | Very good |
