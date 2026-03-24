# QA Review: graphql-federation

**Skill path:** `api/graphql-federation/SKILL.md`
**Reviewer:** Copilot QA
**Date:** 2025-07-17

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ | name, description, positive (13) and negative (7) triggers |
| Line count | ✅ | 480 lines — under 500-line limit |
| Imperative voice | ✅ | Consistent imperative throughout ("Declare", "Mark", "Use", "Enable") |
| Code examples | ✅ | Extensive: directives, resolvers (TS/Java/Python), Rover CLI, router YAML, auth patterns |
| References linked | ✅ | 3 reference docs, 3 scripts, 5 assets — all files exist on disk |

**Markdown defects (2):**
- **Line 93–97:** `@requires` code block missing closing ` ``` ` before the `### @provides` heading.
- **Line 119–122:** `@override` code block missing closing ` ``` ` before the `### @inaccessible` heading.

These cause downstream markdown to render inside fenced code blocks.

---

## B. Content Check

### Directives — verified against Apollo docs

| Directive | Covered in SKILL.md | Accurate |
|-----------|---------------------|----------|
| @key | ✅ Section + examples | ✅ |
| @shareable | ✅ Section + examples | ✅ |
| @external | ✅ Section (brief) | ✅ |
| @requires | ✅ Section + examples | ✅ |
| @provides | ✅ Section + examples | ✅ |
| @override | ✅ Section + progressive example | ✅ |
| @inaccessible | ✅ Section + example | ✅ |
| @tag | ⚠️ Imported in schema line 47 but not documented | — |
| @interfaceObject | ❌ Missing from SKILL.md (covered in references) | — |
| @composeDirective | ❌ Missing | — |
| @authenticated | ✅ Auth Pattern 3 | ✅ |
| @requiresScopes | ✅ Auth Pattern 3 | ✅ |
| @cost / @listSize | ❌ Missing (v2.9+, 2024) | — |
| @context / @fromContext | ❌ Missing (v2.8+, 2024) | — |

**Verdict:** All covered directives are accurate. Missing newer v2.8–v2.12 directives are acceptable given the skill targets v2.7, but `@interfaceObject` (v2.3+) and `@tag` (core) should be mentioned in the main directives section. The references/subgraph-patterns.md partially fills this gap for interface entities.

### Rover CLI — verified against official docs

| Command | In skill | Accurate |
|---------|----------|----------|
| `rover supergraph compose --config ... --output ...` | ✅ | ✅ |
| `rover subgraph check GRAPH_REF --name ... --schema ...` | ✅ | ✅ |
| `rover subgraph publish GRAPH_REF --name ... --schema ... --routing-url ...` | ✅ | ✅ |
| `rover subgraph introspect URL` | ✅ | ✅ |

All Rover commands match current official syntax.

### Router configuration — verified

The `assets/router.yaml` is comprehensive and correct: CORS, JWT auth, traffic shaping, telemetry (OTLP + Prometheus), health checks, limits, subscriptions, APQ. No invalid config keys found.

### Missing gotchas / improvements

1. **Batch `__resolveReference` example (lines 150–158):** Shows `__resolveReference(refs, ...)` receiving an array, but standard Apollo Server 4 passes individual representations. The skill says "Enable entity batching in subgraph setup" without showing how (`allowBatchedHttpRequests: true`). The references doc covers this properly.
2. **`experimental_entity_caching` (line 333):** This was experimental/preview and may have graduated or been renamed in newer Router versions. Minor staleness risk.
3. **`@tag` imported but undocumented:** Line 47 imports `@tag` but no section explains its use for contract schemas and API variants.

---

## C. Trigger Check

### Positive triggers (13)
Well-scoped to federation-specific terminology: "GraphQL Federation", "Apollo Federation", "supergraph", "subgraph", "Apollo Router", "federated GraphQL", "@key directive", "federation directives", "rover supergraph compose", "reference resolver", "entity resolution", "federated schema", "GraphOS managed federation".

### Negative triggers (7)
Properly exclude adjacent topics: general GraphQL without federation, REST, single GraphQL server, Hasura, Apollo Client, subscriptions-only, Prisma.

### False trigger risk
- **Low risk.** "subgraph" could theoretically match graph-database contexts, but combined with other contextual signals this is unlikely.
- General Apollo Client queries are correctly excluded.
- General GraphQL schema design (without federation) is correctly excluded.
- Would NOT falsely trigger for someone doing plain `@apollo/server` without federation.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Accuracy | **4** | All covered content is correct; two unclosed code blocks are rendering bugs; batch `__resolveReference` example slightly misleading |
| Completeness | **4** | Thorough for v2.7; missing `@tag` docs, `@interfaceObject` in main file, and v2.8+ directives; references fill some gaps |
| Actionability | **5** | Working TS subgraphs, production router.yaml, docker-compose, scaffold/validation/health scripts — exceptional |
| Trigger quality | **5** | Precise positive triggers, comprehensive negative triggers, low false-positive risk |
| **Overall** | **4.5** | |

---

## E. Recommendations

### Must fix
1. **Close unclosed code blocks** at lines 95 and 120 — these break markdown rendering for everything below them.

### Should fix
2. Add `@tag` directive documentation (it's imported but unexplained).
3. Add `@interfaceObject` to the Federation Directives section (or cross-reference the patterns doc).
4. Clarify the batch `__resolveReference` example — show that individual resolution is the default and `allowBatchedHttpRequests: true` enables array mode.

### Nice to have
5. Add a "What's New in v2.8+" section mentioning `@context`/`@fromContext`, `@cost`/`@listSize`.
6. Note that `experimental_entity_caching` may have graduated from experimental status.

---

## F. Issue Filing

**Overall score 4.5 ≥ 4.0 and no dimension ≤ 2 → no GitHub issues required.**

---

## G. Verdict

**PASS** — High-quality, comprehensive skill with minor markdown rendering bugs and small content gaps.
