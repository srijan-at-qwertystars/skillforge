# QA Review: effect-ts

**Skill path:** `~/skillforge/typescript/effect-ts/`
**Reviewed:** 2025-07-17
**Verdict:** PASS

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `effect-ts` |
| YAML frontmatter `description` | ✅ | Present, detailed |
| Positive triggers in description | ✅ | Covers imports, APIs, library mentions |
| Negative triggers in description | ✅ | Excludes plain async/await, Zod-only, fp-ts, RxJS, NestJS/Express without Effect |
| Body ≤ 500 lines | ✅ | Exactly 500 lines (at limit) |
| Imperative voice, no filler | ✅ | Direct, rule-based writing throughout |
| Examples with input/output | ✅ | Extensive code examples with type annotations |
| References linked | ✅ | 3 reference files linked in table |
| Scripts linked | ✅ | 3 scripts linked in table with usage |
| Assets linked | ✅ | 4 asset files linked in table |

**Structure score: Excellent.** All structural requirements met.

---

## b. Content Check — API Accuracy Verification

### Effect.gen, pipe, Layer, Context.Tag — ✅ Accurate

- `Effect.gen(function* () { ... })` with `yield*` — correct for 3.x (no longer needs `_` adapter argument removed in 3.x).
- `pipe` and pipeable method style (`Effect.succeed(5).pipe(...)`) — both shown correctly.
- `Context.Tag("TagName")<Service, Interface>()` class pattern — correct.
- `Layer.succeed`, `Layer.effect`, `Layer.scoped`, `Layer.merge`, `Layer.provide`, `Layer.provideMerge` — all accurate.
- `Effect<A, E, R>` parameter order (Success, Error, Requirements) — correct for 3.x.

### Tagged Error Patterns — ✅ Accurate

- `Data.TaggedError("TagName")<{ fields }>` pattern — correct.
- `Effect.catchTag` / `Effect.catchTags` usage — correct.
- `Schema.TaggedError` for schema-integrated errors — correct.

### Schema API — ✅ Accurate (with one asset issue)

- `Schema.Struct` (uppercase S) — correct, current API.
- `Schema.decodeUnknownSync` vs `Schema.decodeSync` — correctly distinguished.
- `Schema.decodeUnknown` for effectful composition — correct.
- `typeof Schema.Type` / `typeof Schema.Encoded` — correct (post-0.64 naming).
- `Schema.transform` / `Schema.transformOrFail` — correct.
- `Schema.Class` — correct.
- `Schema.optional` with `default` — correct.

**Issue:** `assets/package.json` lists `"@effect/schema": "^0.75.0"` as a separate dependency. This package is **deprecated** — Schema is now part of the core `effect` package. The SKILL.md body correctly imports from `"effect"` (not `@effect/schema`), so the body is fine, but the starter template is stale.

### Layer Composition — ✅ Accurate

- `Layer.merge` for independent layers — correct.
- `Layer.provide` for wiring dependencies — correct.
- `Layer.provideMerge` for provide-and-expose — correct.
- Bottom-up composition pattern — correctly described.
- Diamond dependency sharing — correctly explained.
- `ManagedRuntime` bridge pattern — correct.

### Platform Packages — ✅ Mostly Accurate

- `HttpClient`, `HttpClientRequest`, `HttpClientResponse` imports from `@effect/platform` — correct.
- `NodeHttpClient` / `NodeHttpServer` from `@effect/platform-node` — correct.
- `HttpRouter`, `HttpServer`, `HttpServerResponse` — correct.
- `HttpMiddleware.make` pattern — correct.
- `FileSystem`, `Command`, `KeyValueStore` — correct.

### Missing Content / Gotchas

| Item | Severity | Details |
|------|----------|---------|
| `Effect.Service` (v3.9+) | **Medium** | New unified service+layer pattern that reduces boilerplate. Currently the recommended approach for new code. Skill only shows `Context.Tag` + separate `Layer`. |
| `Effect.fn` (v3.11+) | **Low** | Named, traced effect functions with pipeline support. Nice-to-have. |
| `@effect/schema` deprecation warning | **Medium** | `assets/package.json` includes deprecated `@effect/schema` dep. Should be removed since Schema is in core `effect`. |
| Declarative `HttpApi` / `HttpApiGroup` / `HttpApiEndpoint` | **Low** | Newer high-level API for type-safe HTTP APIs with auto-generated clients and OpenAPI. Supplementary to existing HttpRouter coverage. |
| `Context.Reference` | **Low** | Tags with built-in defaults. Minor convenience API. |
| `Effect.provide` shorthand | **Low** | Can pass services directly without Layer in simple cases. |

---

## c. Trigger Check

**Positive triggers:** Comprehensive. Covers:
- All major import paths (`"effect"`, `"effect/*"`, `@effect/platform`, `@effect/platform-node`, `@effect/cli`, `@effect/sql`)
- Key API tokens (`Effect.gen`, `Effect.pipe`, `Layer`, `Schema.Struct`, `Data.TaggedError`, `Context.GenericTag`, `Effect.succeed/fail/tryPromise`, `Stream`, `Fiber`, `Scope`)
- Natural language mentions ("Effect-TS", "effect-ts", "the Effect library")

**Negative triggers:** Well-defined exclusions:
- Plain async/await without Effect imports
- Zod-only schemas
- fp-ts code
- RxJS observables
- General TypeScript without Effect
- NestJS/Express middleware without Effect

**False trigger risk:** Low. The requirement for Effect-specific imports or explicit mentions makes false positives unlikely.

**Pushy enough?** Yes — the trigger list is broad enough to catch most Effect-TS usage patterns. Could add `Effect.Service` and `Effect.fn` to positive triggers for completeness.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All API patterns shown are correct for Effect 3.x. Deducted 1 for `@effect/schema` in `assets/package.json` (deprecated dep). |
| **Completeness** | 3 | Missing `Effect.Service` (v3.9+), which is now the recommended service pattern. Missing `Effect.fn`. Strong coverage otherwise — Schema, Layers, Streams, Concurrency, Config, Testing, HTTP, migration all present. |
| **Actionability** | 5 | Excellent. Migration guide, setup script, layer viz tool, HTTP service template, repository pattern template. Rules clearly stated. Pitfalls listed. Code is copy-pasteable. |
| **Trigger quality** | 5 | Comprehensive positive/negative triggers. Low false-trigger risk. Covers imports, API tokens, and natural language. |

**Overall: 4.25 / 5**

---

## e. GitHub Issues

No issues filed. Overall ≥ 4.0 and no dimension ≤ 2.

**Recommended improvements (non-blocking):**
1. Add `Effect.Service` pattern to Services section (or as a "Modern alternative" note)
2. Remove `@effect/schema` from `assets/package.json` — Schema ships in core `effect`
3. Mention `Effect.fn` for traced named functions
4. Add `Effect.Service` and `Effect.fn` to trigger list
5. Consider adding declarative `HttpApi` pattern to platform section

---

## f. SKILL.md Tag

`<!-- tested: pass -->` appended to SKILL.md.
