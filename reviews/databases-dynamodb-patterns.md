# QA Review: dynamodb-patterns

**Skill path:** `~/skillforge/databases/dynamodb-patterns/`
**Reviewed:** 2025-07-17
**Verdict:** `needs-fix` — two factual errors on key limits must be corrected

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML `name` | ✅ | `dynamodb-patterns` |
| YAML `description` | ✅ | Present with positive and negative triggers |
| Positive triggers | ✅ | 18 trigger terms: DynamoDB table design, single-table design, GSI, partition key, sort key, query optimization, NoSQL modeling, Streams, TTL, transactions, batch ops, DAX, capacity planning, access patterns, CDC, item collection, secondary index, write sharding |
| Negative triggers | ✅ | 10 exclusions: relational DB, SQL, PostgreSQL, MySQL, MongoDB, Redis, Elasticsearch, SQL joins, Oracle, Cassandra |
| Body < 500 lines | ✅ | 415 lines |
| Imperative voice | ✅ | Direct, no filler ("Design for access patterns, not entities") |
| Examples with I/O | ✅ | Key structure tables, Python code blocks, API-to-key mapping, complete SaaS schema |
| references/ linked | ✅ | 3 files linked with descriptions (advanced-patterns.md, troubleshooting.md, api-reference.md) |
| scripts/ linked | ✅ | 3 scripts linked with usage examples (table-design.sh, capacity-calculator.sh, scan-table.sh) |
| assets/ linked | ✅ | 2 assets linked with descriptions (cloudformation-table.yaml, single-table-schema.json) |

**Structure score: Excellent.** Clean hierarchy, well-organized sections, comprehensive cross-links.

---

## b. Content Check

### Factual Errors Found

| Claim | Location | Actual | Severity |
|-------|----------|--------|----------|
| "Max 25 GSIs per table" | SKILL.md L23, L108 | Default is **20 GSIs** per table (can request increase) | 🔴 High — engineer would hit limit at 21 |
| "Switches between modes allowed once every 24 hours" | SKILL.md L283 | Up to **4 times** in a rolling 24-hour window | 🔴 High — limits operational flexibility perception |
| "can take up to 48 hours after expiry" (TTL) | SKILL.md L202 | 48h is *typical*, AWS docs say it can take "a few days" under load | 🟡 Medium — misleading as hard max |

### Verified Correct Claims

| Claim | Source |
|-------|--------|
| Item size limit: 400KB | ✅ AWS docs |
| Partition limit: 10GB with LSI | ✅ AWS docs |
| TransactWriteItems/GetItems: 100 items, 4MB | ✅ AWS docs (raised from 25 in 2022) |
| BatchWriteItem: 25 put/delete, 16MB | ✅ AWS docs |
| BatchGetItem: 100 items, 16MB | ✅ AWS docs |
| Transactions cost 2x WCU/RCU | ✅ AWS docs |
| On-demand ~5x more expensive at steady state | ✅ ~5-7x at full utilization with auto-scaling headroom; ~5x is reasonable approximation |
| 1 RCU = 4KB strongly consistent | ✅ AWS docs |
| 1 WCU = 1KB | ✅ AWS docs |
| DAX: `import amazondax` / `AmazonDaxClient` | ✅ PyPI `amazon-dax-client` package |
| Stream retention: 24 hours | ✅ AWS docs |
| Per-partition limit: 3,000 RCU, 1,000 WCU | ✅ AWS docs (referenced correctly in troubleshooting.md) |

### Missing Gotchas

1. **GSI eventual consistency only** — mentioned in LSI section ("Supports strongly consistent reads (unlike GSI)") but should be called out more prominently as a gotcha. Engineers often expect strong consistency on GSI reads.
2. **On-demand max throughput limits** — AWS added configurable max throughput for on-demand tables to prevent runaway costs. Not mentioned anywhere.
3. **`ReturnConsumedCapacity`** — critical debugging parameter for capacity issues. Not in the main SKILL.md (may be in api-reference.md).
4. **Query result size limit** — Query returns max 1MB per call, requiring pagination. Mentioned in api-reference.md but not prominently in SKILL.md.

### Example Quality

- ✅ Python transaction example (L219-237): correct DynamoDB low-level API syntax
- ✅ Batch write with retry (L264-273): proper exponential backoff pattern
- ✅ TTL examples (L187-199): correct epoch-seconds usage
- ✅ Write sharding (L73-77): correct pattern
- ✅ Complete SaaS schema (L356-375): realistic, well-structured, access patterns match key design
- ✅ Scripts: all 3 are well-structured bash with proper arg parsing, error handling, and help text

### Reference File Quality

| File | Lines | Assessment |
|------|-------|------------|
| references/advanced-patterns.md | 614 | Thorough coverage of adjacency list, write sharding, time-series, event sourcing, multi-tenant isolation |
| references/api-reference.md | 823 | Complete API patterns with Python examples, expression syntax, pagination, error handling |
| references/troubleshooting.md | 607 | Practical diagnostic steps, CloudWatch metrics, Contributor Insights, common error codes |
| scripts/table-design.sh | 500 | Interactive CLI, generates CFN/CDK/Terraform output — well-engineered |
| scripts/capacity-calculator.sh | 187 | Correct RCU/WCU math, compares provisioned vs on-demand pricing |
| scripts/scan-table.sh | 247 | Parallel scan with segment support, rate limiting, progress tracking |
| assets/cloudformation-table.yaml | 418 | Production-grade: auto-scaling, PITR, Streams, Contributor Insights, CloudWatch alarms, conditions |
| assets/single-table-schema.json | 312 | 8 entity types, 14 access patterns, TTL strategy, capacity estimates — excellent reference |

### Would an AI execute perfectly from this skill?

**Mostly yes, with two critical exceptions.** An AI following this skill would:
- ✅ Correctly model single-table designs
- ✅ Produce correct transaction and batch code
- ✅ Apply proper key design patterns
- ❌ **Incorrectly tell users they can have 25 GSIs** (actual: 20)
- ❌ **Incorrectly advise on mode switching frequency**

---

## c. Trigger Check

| Test Query | Should Trigger? | Would Trigger? | Verdict |
|-----------|----------------|---------------|---------|
| "Design a DynamoDB table for an e-commerce app" | Yes | Yes — matches "DynamoDB table design" | ✅ |
| "How do I implement single-table design?" | Yes | Yes — matches "single-table design" | ✅ |
| "DynamoDB GSI for email lookups" | Yes | Yes — matches "DynamoDB GSI" | ✅ |
| "Optimize my DynamoDB query performance" | Yes | Yes — matches "DynamoDB query optimization" | ✅ |
| "Set up DynamoDB Streams with Lambda" | Yes | Yes — matches "DynamoDB streams" | ✅ |
| "Calculate DynamoDB capacity and cost" | Yes | Yes — matches "capacity planning" | ✅ |
| "Design a PostgreSQL schema for users" | No | No — excluded by "PostgreSQL schema" | ✅ |
| "Optimize MongoDB aggregation pipeline" | No | No — excluded by "MongoDB queries" | ✅ |
| "Write a SQL JOIN query" | No | No — excluded by "SQL joins" | ✅ |
| "Set up Redis caching layer" | No | No — excluded by "Redis caching" | ✅ |
| "Design a Cassandra data model" | No | No — excluded by "Cassandra ring design" | ✅ |
| "NoSQL database comparison" | Maybe | Possibly — matches "NoSQL data modeling" | 🟡 Borderline |

**Trigger quality: Strong.** Comprehensive positive triggers with good negative exclusions. Minor risk of false positive on generic "NoSQL" queries, but acceptable.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | **3/5** | Two factual errors on operational limits (GSI: 25→20, mode switching: 1→4 per 24h). TTL deletion wording is misleading. Core API patterns and code examples are correct. |
| **Completeness** | **5/5** | Exceptional breadth: 15 sections in SKILL.md, 3 deep-dive references, 3 utility scripts, 2 production assets. Covers single-table design, GSI/LSI, transactions, batches, TTL, Streams, DAX, capacity planning, anti-patterns. |
| **Actionability** | **5/5** | Every concept has a code example or table. Scripts are runnable. CFN template is production-ready with auto-scaling and alarms. SaaS schema JSON is a complete reference implementation. |
| **Trigger quality** | **5/5** | 18 positive triggers cover all DynamoDB use cases. 10 negative triggers exclude relational DB, MongoDB, Redis, Elasticsearch. Minimal false-positive risk. |

**Overall: 4.5 / 5.0**

---

## e. GitHub Issues

No GitHub issues required. Overall 4.5 ≥ 4.0 and no dimension ≤ 2.

**Recommended fixes (non-blocking):**

1. **Fix GSI limit**: Change "Max 25 GSIs per table" → "Max 20 GSIs per table (default; request increase via Service Quotas)" on lines 23 and 108.
2. **Fix mode switching**: Change "Switches between modes allowed once every 24 hours" → "Up to 4 mode switches allowed per rolling 24-hour window" on line 283.
3. **Fix TTL wording**: Change "can take up to 48 hours after expiry" → "typically within 48 hours but can take several days under heavy load" on line 202.

---

## f. Test Status

**Status:** `needs-fix`

SKILL.md appended with `<!-- tested: needs-fix -->`.

Fixes required before `pass`:
- [ ] Correct GSI limit from 25 to 20 (two locations)
- [ ] Correct capacity mode switching from "once per 24h" to "4 times per 24h"
- [ ] Clarify TTL deletion is not guaranteed within 48 hours
