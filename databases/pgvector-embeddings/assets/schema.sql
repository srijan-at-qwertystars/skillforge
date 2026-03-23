-- pgvector Schema Template
-- Complete schema with vector, halfvec, sparsevec columns,
-- HNSW and IVFFlat indexes, and hybrid search function.
--
-- Usage:
--   psql -d mydb -f schema.sql
--
-- Prerequisites:
--   PostgreSQL 15+ with pgvector extension installed

-- =============================================================================
-- Extension Setup
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS vector;

-- =============================================================================
-- Main Document Table
-- =============================================================================

CREATE TABLE IF NOT EXISTS documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT NOT NULL,
    title TEXT,
    source TEXT,
    metadata JSONB DEFAULT '{}',

    -- Dense embedding (float32, primary search vector)
    embedding vector(1536),

    -- Half-precision embedding (float16, 50% storage savings)
    embedding_half halfvec(1536),

    -- Binary quantized (for ultra-fast coarse search)
    embedding_binary bit(1536),

    -- Sparse embedding (for lexical/SPLADE models)
    sparse_embedding sparsevec(30000),

    -- Full-text search vector (auto-generated)
    search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(content, '')), 'B')
    ) STORED,

    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- Indexes
-- =============================================================================

-- HNSW index on dense embedding (recommended for production)
CREATE INDEX IF NOT EXISTS idx_documents_hnsw
ON documents USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 128);

-- HNSW index on half-precision embedding
CREATE INDEX IF NOT EXISTS idx_documents_hnsw_half
ON documents USING hnsw (embedding_half halfvec_cosine_ops)
WITH (m = 16, ef_construction = 128);

-- HNSW index on binary embedding (Hamming distance)
CREATE INDEX IF NOT EXISTS idx_documents_hnsw_binary
ON documents USING hnsw (embedding_binary bit_hamming_ops);

-- IVFFlat index (alternative — build AFTER loading data)
-- Uncomment when you have data loaded and want to compare:
-- CREATE INDEX idx_documents_ivfflat
-- ON documents USING ivfflat (embedding vector_cosine_ops)
-- WITH (lists = 1000);

-- Full-text search index
CREATE INDEX IF NOT EXISTS idx_documents_fts
ON documents USING gin (search_vector);

-- Metadata JSONB index
CREATE INDEX IF NOT EXISTS idx_documents_metadata
ON documents USING gin (metadata jsonb_path_ops);

-- Partial index example (for hot filter values)
-- CREATE INDEX idx_documents_hnsw_source_web
-- ON documents USING hnsw (embedding vector_cosine_ops)
-- WHERE source = 'web';

-- =============================================================================
-- Updated_at Trigger
-- =============================================================================

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_documents_updated_at
BEFORE UPDATE ON documents
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

-- =============================================================================
-- Hybrid Search Function (Vector + Full-Text with RRF)
-- =============================================================================

CREATE OR REPLACE FUNCTION hybrid_search(
    query_embedding vector(1536),
    query_text text,
    match_count int DEFAULT 10,
    rrf_k int DEFAULT 60,
    vector_weight float DEFAULT 1.0,
    text_weight float DEFAULT 1.0,
    filter_metadata jsonb DEFAULT NULL
)
RETURNS TABLE(
    id bigint,
    title text,
    content text,
    metadata jsonb,
    rrf_score float,
    vector_rank int,
    text_rank int
)
LANGUAGE sql STABLE
SET hnsw.ef_search = 200
AS $$
    WITH vector_results AS (
        SELECT d.id,
               ROW_NUMBER() OVER (ORDER BY d.embedding <=> query_embedding) AS rank_v
        FROM documents d
        WHERE (filter_metadata IS NULL OR d.metadata @> filter_metadata)
        ORDER BY d.embedding <=> query_embedding
        LIMIT match_count * 4
    ),
    fts_results AS (
        SELECT d.id,
               ROW_NUMBER() OVER (
                   ORDER BY ts_rank_cd(d.search_vector,
                       websearch_to_tsquery('english', query_text)) DESC
               ) AS rank_f
        FROM documents d
        WHERE d.search_vector @@ websearch_to_tsquery('english', query_text)
          AND (filter_metadata IS NULL OR d.metadata @> filter_metadata)
        LIMIT match_count * 4
    )
    SELECT
        d.id,
        d.title,
        d.content,
        d.metadata,
        COALESCE(vector_weight / (rrf_k + v.rank_v), 0.0) +
        COALESCE(text_weight / (rrf_k + f.rank_f), 0.0) AS rrf_score,
        v.rank_v::int AS vector_rank,
        f.rank_f::int AS text_rank
    FROM documents d
    LEFT JOIN vector_results v ON d.id = v.id
    LEFT JOIN fts_results f ON d.id = f.id
    WHERE v.id IS NOT NULL OR f.id IS NOT NULL
    ORDER BY rrf_score DESC
    LIMIT match_count;
$$;

-- =============================================================================
-- Binary Quantization Search Function (Two-Stage)
-- =============================================================================

CREATE OR REPLACE FUNCTION binary_rerank_search(
    query_embedding vector(1536),
    match_count int DEFAULT 10,
    oversample_factor int DEFAULT 20
)
RETURNS TABLE(id bigint, title text, content text, distance float)
LANGUAGE sql STABLE
AS $$
    WITH candidates AS (
        SELECT d.id, d.title, d.content, d.embedding
        FROM documents d
        WHERE d.embedding_binary IS NOT NULL
        ORDER BY d.embedding_binary <~> binary_quantize(query_embedding)::bit(1536)
        LIMIT match_count * oversample_factor
    )
    SELECT c.id, c.title, c.content,
           c.embedding <=> query_embedding AS distance
    FROM candidates c
    ORDER BY distance
    LIMIT match_count;
$$;

-- =============================================================================
-- Utility: Sync halfvec and binary columns from embedding
-- =============================================================================

CREATE OR REPLACE FUNCTION sync_derived_embeddings()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.embedding IS NOT NULL THEN
        NEW.embedding_half = NEW.embedding::halfvec(1536);
        NEW.embedding_binary = binary_quantize(NEW.embedding)::bit(1536);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_sync_embeddings
BEFORE INSERT OR UPDATE OF embedding ON documents
FOR EACH ROW
EXECUTE FUNCTION sync_derived_embeddings();

-- =============================================================================
-- Usage Examples
-- =============================================================================

-- Insert a document:
-- INSERT INTO documents (title, content, embedding)
-- VALUES ('My Title', 'My content text', '[0.1,0.2,...,0.05]'::vector(1536));

-- Nearest neighbor search:
-- SELECT id, title, embedding <=> '[0.1,...]'::vector AS distance
-- FROM documents ORDER BY embedding <=> '[0.1,...]'::vector LIMIT 10;

-- Hybrid search:
-- SELECT * FROM hybrid_search(
--     '[0.1,...]'::vector(1536), 'search keywords', 10
-- );

-- Binary re-rank search:
-- SELECT * FROM binary_rerank_search('[0.1,...]'::vector(1536), 10);

-- Filtered search:
-- SELECT * FROM hybrid_search(
--     '[0.1,...]'::vector(1536), 'search keywords', 10,
--     60, 1.0, 1.0, '{"source": "web"}'::jsonb
-- );
