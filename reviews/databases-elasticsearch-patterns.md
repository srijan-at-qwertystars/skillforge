# Review: elasticsearch-patterns

**Reviewed**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Skill path**: `~/skillforge/databases/elasticsearch-patterns/`
**SKILL.md lines**: 448 (under 500 ✅)

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter with name | ✅ | `elasticsearch-patterns` |
| Description with positive triggers | ✅ | Covers ES, Elastic, ELK, Query DSL, ES\|QL, analyzers, mappings, kNN, client libs, cat APIs, etc. |
| Description with negative triggers | ✅ | Excludes ClickHouse, DuckDB, pgvector, Solr, Meilisearch, Typesense, Algolia, Redis Search |
| Body under 500 lines | ✅ | 448 lines |
| Imperative voice | ✅ | Consistent throughout ("Use", "Set", "Put", "Avoid") |
| Examples with input/output | ✅ | Analyzer test shows output tokens; agg response shows bucket structure; bulk shows NDJSON format |
| References linked from SKILL.md | ✅ | 3 reference files linked via table with descriptions |
| Scripts linked from SKILL.md | ✅ | 3 scripts linked via table with usage examples |
| Assets linked from SKILL.md | ✅ | 5 asset files linked via table |

**Reference/script quality**: All 3 scripts are production-grade bash with `set -euo pipefail`, proper arg parsing, colored output, and error handling. All 3 reference files are substantial (821–1119 lines). All 5 asset files are valid JSON/YAML with inline documentation.

---

## B. Content Check (Web-Verified)

| Claim | Verified | Notes |
|-------|----------|-------|
| `dense_vector` with `int8_hnsw` index_options | ✅ | Correct. Default since ES 8.14 for new indices. |
| Similarity metrics: `cosine`, `dot_product`, `l2_norm`, `max_inner_product` | ✅ | `max_inner_product` added in ES 8.14+. Confirmed in official docs. |
| ES\|QL syntax (FROM, WHERE, EVAL, STATS BY, SORT, LIMIT, KEEP/DROP, RENAME, ENRICH, DISSECT/GROK) | ✅ | All commands verified against official ES\|QL reference. |
| ES\|QL endpoint: `POST /_query` | ✅ | Correct for ES 8.x. |
| kNN search syntax with top-level `knn` clause | ✅ | Correct for ES 8.x (`POST /index/_search` with `knn` body). |
| Client libraries: `elasticsearch-py`, `@elastic/elasticsearch`, `elastic/go-elasticsearch v8` | ✅ | All are the correct official 8.x clients. |
| Security enabled by default in 8.x | ✅ | TLS + auth enabled OOTB since 8.0. |
| Single `_doc` type | ✅ | Types removed in 7.x, single `_doc` since then. |
| `from/size` max 10,000 | ✅ | Default `index.max_result_window` is 10,000. |
| PIT + `search_after` preferred in 8.x | ✅ | Correct recommendation. |
| ILM phases: hot → warm → cold → frozen → delete | ✅ | Correct order. |
| Bulk API returns 200 on partial failure | ✅ | Critical gotcha, correctly documented. |
| `_shard_doc` as PIT sort tiebreaker | ✅ | Correct ES 8.x idiom. |

**Missing gotchas** (minor):
- No mention of `bbq_hnsw` (binary quantization, 8.15+ for 384+ dim vectors)
- No mention of 4096 max dimensions limit for `dense_vector`
- JVM heap sizing (50% RAM, max ~31GB) is in operations-guide.md but not SKILL.md — acceptable since it's a reference concern

**Example correctness**: All JSON examples are syntactically valid and use correct ES 8.x API patterns. The Python/Node/Go client examples match current API surfaces.

---

## C. Trigger Check

| Scenario | Triggers? | Correct? |
|----------|-----------|----------|
| "How do I write an Elasticsearch bool query?" | ✅ Yes | ✅ Correct |
| "ES aggregation with date histogram" | ✅ Yes | ✅ Correct |
| "kNN vector search in Elasticsearch" | ✅ Yes | ✅ Correct |
| "Elasticsearch cluster health yellow" | ✅ Yes | ✅ Correct |
| "ES\|QL query syntax" | ✅ Yes | ✅ Correct |
| "elasticsearch-py bulk helpers" | ✅ Yes | ✅ Correct |
| **"OpenSearch query DSL"** | ⚠️ Yes | ❌ **FALSE POSITIVE** — OpenSearch is listed as a positive trigger but is a divergent fork. ES 8.x content (security defaults, ES\|QL, int8_hnsw) does not apply to OpenSearch. |
| "Solr faceted search" | ❌ No | ✅ Correctly excluded |
| "Meilisearch setup" | ❌ No | ✅ Correctly excluded |
| "PostgreSQL full-text search" | ❌ No | ✅ Correctly excluded |
| **"olivere/elastic Go client"** | ⚠️ Yes | ⚠️ **Misleading** — olivere/elastic is listed in triggers but does NOT support ES 8.x (max v7). Code examples use the correct `elastic/go-elasticsearch` but the trigger could attract users seeking olivere-specific help. |

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All API endpoints, query syntax, mapping types, config properties verified correct. Minor: `olivere/elastic` in triggers is misleading for 8.x context. |
| **Completeness** | 5 | Exceptionally thorough: architecture, Query DSL, analyzers, aggregations, pagination, bulk ops, 3 client languages, security, performance, observability, vector search, ES\|QL, ELK stack, plus 3 deep reference docs, 3 scripts, 5 asset templates. |
| **Actionability** | 5 | Every section has copy-paste-ready code with expected output. Scripts are production-grade. Docker setup enables immediate local experimentation. Pitfalls section is excellent. |
| **Trigger quality** | 3 | Strong positive coverage for ES-specific terms. **However, OpenSearch is incorrectly included as a positive trigger** — OpenSearch has diverged significantly (no ES\|QL, different security model, different vector search API). This would serve wrong content to OpenSearch users. `olivere/elastic` trigger is also misleading for 8.x. Negative triggers are well-chosen. |

**Overall: 4.25 / 5**

---

## E. Issues

No GitHub issues required (overall ≥ 4.0 and no dimension ≤ 2).

**Recommended fixes** (for skill author):
1. **Remove `OpenSearch` from positive triggers** — move it to the `DO NOT USE` list or add a dedicated OpenSearch skill. OpenSearch forked at ES 7.10 and lacks ES\|QL, built-in security defaults, int8_hnsw, and other 8.x features.
2. **Remove `olivere/elastic` from triggers** — it doesn't support ES 8.x. Replace with just `elastic/go-elasticsearch` or note olivere as a legacy v7-only client.
3. **Add `bbq_hnsw`** quantization mention (ES 8.15+, for vectors ≥ 384 dims).
4. **Add max dims limit** (4096) for `dense_vector`.

---

## F. Verdict

**Status: PASS** ✅

The skill is comprehensive, accurate, and highly actionable. The trigger description needs minor corrections (OpenSearch false positive, olivere/elastic), but the core content is excellent and well-verified against current ES 8.x documentation.
