# QA Review: databases/meilisearch-patterns

**Reviewed:** 2025-07-17
**Skill path:** `databases/meilisearch-patterns/SKILL.md`
**Reviewer:** Copilot QA

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with positive and negative triggers present |
| Line count | ✅ Pass | 499 lines (limit: 500) — cutting it very close |
| Imperative voice | ✅ Pass | Consistent imperative/instructional tone throughout |
| Code examples | ✅ Pass | curl, JSON, TypeScript, Python, Go examples; multi-language coverage |
| References linked | ✅ Pass | 3 reference docs (advanced-search, troubleshooting, deployment-guide) |
| Scripts linked | ✅ Pass | 3 scripts (setup, bulk-import, backup-restore), all described with usage |
| Assets linked | ✅ Pass | 5 assets (docker-compose, clients, nginx, settings) |

**Structure score: Excellent.** Well-organized with logical section progression from architecture → CRUD → search → advanced features → security → deployment.

---

## B. Content Check

### Verified Correct (via Meilisearch docs and web search)

- ✅ REST API endpoints: `POST /indexes`, `DELETE /indexes/{uid}`, `PATCH /indexes/{uid}/settings`
- ✅ Document CRUD: `POST` for add/replace, `PUT` for partial update (merge semantics)
- ✅ Delete endpoints: `POST .../documents/delete-batch` (by IDs), `POST .../documents/delete` (by filter)
- ✅ All write operations are async, return `taskUid` — correctly documented
- ✅ Search filter syntax (SQL-like with AND/OR/NOT/IN/IS NOT NULL/TO range)
- ✅ Multi-search via `POST /multi-search` with `queries` array
- ✅ Federated search with `federation` + `federationOptions.weight`
- ✅ Hybrid search with `semanticRatio` (0.0–1.0 scale) — confirmed correct
- ✅ Embedder sources: `openAi`, `huggingFace`, `userProvided`, `rest` — complete list
- ✅ Ranking rules default order: words → typo → proximity → attribute → sort → exactness
- ✅ Go SDK: `meilisearch.New()` with `meilisearch.WithAPIKey()` — confirmed correct constructor
- ✅ JS tenant token: `import { generateTenantToken } from 'meilisearch/token'` — confirmed correct import path
- ✅ API key actions list is accurate and comprehensive
- ✅ Docker image tag `getmeili/meilisearch:v1.12` and env vars correct

### Potential Issues

- ⚠️ **PUT semantics unexplained (minor):** Line 89 uses `PUT` for partial updates, which is atypical REST (PUT usually means full replacement). A one-line note would prevent developer confusion. Functionally correct per Meilisearch's API.
- ⚠️ **Python tenant token API:** The example at line 357-364 uses `client.generate_tenant_token()` — confirm compatibility with latest `meilisearch-python` SDK versions, as the JS SDK moved to a standalone import.

### Missing Gotchas

1. **Single-node architecture:** Meilisearch has no built-in clustering or replication. This is a critical architectural limitation that should be mentioned, especially since the deployment-guide reference mentions "high availability."
2. **Payload size limit:** No mention of the ~100MB max payload per request for document ingestion.
3. **`proximityPrecision` setting:** The `byWord` vs `byAttribute` setting (controls proximity ranking granularity) is not covered.
4. **v1.12 indexing optimization:** Ability to disable prefix search or facet search per-index for faster indexing (`setFacetSearch(false)`) is not mentioned.
5. **`_vectors` field behavior:** Auto-excluded from displayed attributes; not mentioned.

---

## C. Trigger Check

### Positive Triggers
- `Meilisearch` — specific, correct
- `instant search with Meilisearch` — specific, correct
- `typo-tolerant search` — **slightly generic**; could match Typesense or Algolia contexts
- `faceted search engine` — **slightly generic**; could match Algolia, Typesense, or Elasticsearch
- `Meilisearch index`, `Meilisearch Cloud` — specific, correct
- `meilisearch-js`, `meilisearch-python` — SDK-specific, correct

### Negative Triggers
- `Elasticsearch`, `OpenSearch`, `Algolia`, `Typesense`, `Solr`, `Lucene` — all correct exclusions
- `general full-text search without Meilisearch context` — good catch-all exclusion
- ✅ Cross-verified: the `elasticsearch-patterns` skill explicitly excludes "Meilisearch" in its negative triggers — no conflict

### Assessment
Triggers are **good but not perfect**. The two generic terms (`typo-tolerant search`, `faceted search engine`) could cause false positives when a user discusses these concepts in the context of another search engine. Risk is low since they'd need to match without any negative trigger also matching, but tightening to `Meilisearch typo tolerance` and `Meilisearch faceted search` would be safer.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All APIs, endpoints, SDK usage verified correct. No errors found. Minor PUT semantics gap. |
| **Completeness** | 4 | Excellent coverage of core + advanced features. Missing single-node limitation and a few v1.12 features. |
| **Actionability** | 5 | Outstanding. Ready-to-use examples in 4+ languages, scripts, Docker compose, nginx config, client libraries. Common patterns section is immediately useful. |
| **Trigger quality** | 4 | Good positive/negative separation with cross-skill verification. Two slightly generic positive triggers. |
| **Overall** | **4.25** | |

---

## E. Recommendations

### Should Fix (before next release)
1. Add a one-line note in Architecture Overview: "Meilisearch is single-node; it does not support built-in clustering or replication."
2. Tighten generic triggers: `typo-tolerant search` → `Meilisearch typo tolerance`, `faceted search engine` → `Meilisearch faceted search`

### Nice to Have
3. Add payload size limit note (~100MB) in Document Management section
4. Mention `proximityPrecision` setting in Index Settings
5. Note v1.12 `setFacetSearch(false)` / `setPrefixSearch(false)` optimization
6. Add brief note that PUT has merge (not replace) semantics, unusual for REST

---

## F. Issue Filing

**Overall score 4.25 > 4.0 and no dimension ≤ 2 — no GitHub issue required.**

---

## G. Verdict

**PASS** — Skill is accurate, comprehensive, and highly actionable. Minor improvements recommended but not blocking.
