# Review: pgvector-embeddings

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

## Issues

### 1. Version compatibility table incorrect (references/troubleshooting.md, lines 356–361)

The version table lists `halfvec` as introduced in pgvector 0.5.0 and `sparsevec`/binary quantization in 0.6.0. Per the official pgvector changelog, **both `halfvec` and `sparsevec` were introduced in 0.7.0** (2024-04-29). The `bit` type indexing, `binary_quantize()`, Hamming/Jaccard operators, and L1 distance were also all added in 0.7.0, not 0.5.0/0.6.0.

Correct table should be:
| pgvector | Key Features |
|----------|-------------|
| 0.5.0 | HNSW indexes, L1 distance |
| 0.6.0 | Parallel HNSW build |
| 0.7.0 | halfvec, sparsevec, bit indexing, binary_quantize, Hamming/Jaccard ops |
| 0.8.0 | Iterative scan stable, IVFFlat iterative scan, improved cost estimation |

**Severity:** Medium — factual error in reference doc; could cause confusion about minimum required version.

### 2. Invalid SQL in references/advanced-patterns.md (lines 330–337)

The "Document Chunk Search" query has `ORDER BY` before `GROUP BY` and two `LIMIT`/`ORDER BY` clauses:
```sql
SELECT document_id, MIN(embedding <=> $1) AS best_distance, COUNT(*) AS matching_chunks
FROM doc_chunks
ORDER BY embedding <=> $1
LIMIT 50
GROUP BY document_id
ORDER BY best_distance
LIMIT 10;
```
This is syntactically invalid PostgreSQL. It should use a CTE to first select top-50 chunks, then group.

**Severity:** Low — in reference file, not SKILL.md body; intent is clear but code won't run.

### 3. Cohere client API in SKILL.md (line 371)

SKILL.md uses `cohere.Client()` but the modern Cohere Python SDK (v5+) uses `cohere.ClientV2()`. The embedding-integrations.md reference correctly uses `ClientV2`. Minor inconsistency.

**Severity:** Low — `cohere.Client()` still works but is legacy.

## Verification Summary

| Claim | Status |
|-------|--------|
| Distance operators (`<->`, `<=>`, `<#>`, `<+>`, `<~>`, `<%>`) | ✅ Correct |
| HNSW params (m, ef_construction, ef_search) | ✅ Correct |
| IVFFlat params (lists, probes) | ✅ Correct |
| halfvec max indexed dims = 4000 | ✅ Correct |
| vector max indexed dims = 2000 | ✅ Correct |
| sparsevec format `{idx:val,...}/dims` | ✅ Correct |
| `binary_quantize()` function | ✅ Correct |
| `<#>` returns negative inner product | ✅ Correct |
| Iterative scan syntax (0.8+) | ✅ Correct |
| psycopg v3 `register_vector` pattern | ✅ Correct |
| SQLAlchemy `pgvector.sqlalchemy` imports | ✅ Correct |
| Django `pgvector.django` VectorField/HnswIndex | ✅ Correct |
| PostgreSQL 13+ requirement | ✅ Correct |

## Structure Assessment

- ✅ YAML frontmatter with name and description
- ✅ Positive AND negative triggers in description
- ✅ Body under 500 lines (468 lines)
- ✅ Imperative voice, no filler
- ✅ Extensive examples with input/output
- ✅ All references/ and scripts/ properly linked from SKILL.md
- ✅ Assets include ready-to-use schema, docker-compose, SQLAlchemy model, Django model
- ✅ Scripts are complete and runnable (setup, benchmark, batch-embed)

## Trigger Assessment

The description is comprehensive: covers vector similarity search, RAG pipelines, HNSW/IVFFlat indexes, halfvec/sparsevec/bit types, hybrid search, tuning parameters, distance functions, embedding API integrations, and ORM frameworks. Negative triggers correctly exclude standalone vector DBs, non-PostgreSQL databases, and non-embedding ML tasks. Would trigger accurately for real queries and not falsely trigger for unrelated work.

## Notable Strengths

- Exceptionally thorough coverage: from setup to production optimization
- Connection pooling gotchas covered in troubleshooting (SET LOCAL pattern)
- Binary quantization two-stage search pattern included
- Complete assets (docker-compose, schema, ORM models) enable immediate use
- Benchmark script for empirical index tuning
