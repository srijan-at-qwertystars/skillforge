# QA Review: backend/fastify-patterns

**Reviewer:** Copilot CLI  
**Date:** 2025-07-14  
**Skill path:** `~/skillforge/backend/fastify-patterns/`

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML `name` | ✅ | `fastify-patterns` |
| YAML `description` | ✅ | Present, comprehensive |
| Positive triggers in description | ✅ | 20+ specific triggers (routes, plugins, hooks, decorators, Zod, TypeBox, @fastify/jwt, autoload, etc.) |
| Negative triggers in description | ✅ | Explicitly excludes Express, Koa, Hapi, NestJS, Connect, general HTTP |
| Body ≤ 500 lines | ✅ | 491 lines |
| Imperative voice, no filler | ✅ | Dense, code-forward, no filler paragraphs |
| Examples with input/output | ✅ | Zod section: `POST /items {...} → 201 {...}` / `→ 400 validation error`; WS section: `WS {...} → {...}` |
| references/ linked | ✅ | All 3 files linked under "## References" with relative paths |
| scripts/ linked | ✅ | Both scripts linked under "## Scripts" with usage instructions |
| assets/ linked | ✅ | All 3 templates linked under "## Templates" |

## B. Content Check

### Accuracy (verified via web search against official Fastify v5 docs)

| Claim | Verified | Source |
|-------|----------|--------|
| Node.js v20+ required for Fastify v5 | ✅ | fastify.dev Migration Guide V5 |
| Full JSON Schema required (no shorthand) in v5 | ✅ | fastify.dev Migration Guide V5 |
| `loggerInstance` for custom loggers in v5 | ✅ | fastify.dev Migration Guide V5 |
| Type providers split into ValidatorSchema / SerializerSchema | ✅ | fastify.dev Type-Providers docs |
| WebSocket handler signature `(socket, request)` | ✅ | @fastify/websocket README (latest — raw WebSocket, not SocketStream) |
| Hook lifecycle order | ✅ | Matches official docs |
| `fastify-plugin` encapsulation behavior | ✅ | Correct |
| `fast-json-stringify` 2-3x performance | ✅ | Official benchmarks |
| @fastify/rate-limit, @fastify/cors, @fastify/multipart, @fastify/jwt APIs | ✅ | Checked against npm docs |

### Missing Gotchas (minor)

- No mention of `useSemicolonDelimiter` v5 change (semicolons no longer query delimiters by default)
- No mention of `reply.getResponseTime()` → `reply.elapsedTime` rename
- No mention of `hasRoute()` exact-match behavior change in v5

These are minor v5 migration details; the skill correctly focuses on patterns rather than migration.

### Example Correctness

- All TypeScript examples are syntactically valid
- Zod integration correctly sets both `validatorCompiler` and `serializerCompiler`
- Testing examples use `app.inject()` correctly with `buildApp()` factory pattern
- Plugin template correctly demonstrates `fp()` with dependency declaration
- Scripts are well-structured bash with `set -euo pipefail`

### Reference Files

| File | Lines | Quality |
|------|-------|---------|
| `references/advanced-patterns.md` | 691 | Excellent — covers encapsulation, DI, graceful shutdown, SSE, streaming, custom constraints, multitenancy, full lifecycle diagram |
| `references/troubleshooting.md` | 561 | Excellent — covers all major error codes, Express migration, memory leaks, TypeScript issues, production debugging |
| `references/api-reference.md` | 727 | Comprehensive — full constructor options, request/reply objects, all hooks, decorators, schema compilation |
| `scripts/init-fastify.sh` | 263 | Production-ready scaffold with ESM, autoload, Dockerfile, .env |
| `scripts/generate-plugin.sh` | 150 | Generates shared or encapsulated plugins with TypeScript typing |
| `assets/fastify-app.template.ts` | 183 | Production app template with graceful shutdown drain, error handling, health check |
| `assets/plugin.template.ts` | 124 | Full plugin template with service class, typed options, declaration merging |
| `assets/docker-compose.template.yml` | 95 | Fastify + PostgreSQL 16 + Redis 7 with health checks |

## C. Trigger Check

**Would it trigger for real Fastify queries?**  
✅ Yes — description covers all major use cases: routes, plugins, hooks, schemas, Zod/TypeBox, JWT, testing, rate limiting, CORS, multipart, WebSocket, database, autoload.

**Would it falsely trigger?**  
✅ Low risk — explicit negative triggers for Express, Koa, Hapi, NestJS, Connect, and "general HTTP concepts without Fastify context."

**Edge cases considered:**  
- "How do I add middleware in Fastify?" → triggers correctly (maps to hooks/plugins)
- "Express vs Fastify" → might trigger but troubleshooting.md has Express migration section, so acceptable
- "How do I validate request body?" (no framework context) → correctly excluded by negative trigger

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | All major APIs verified correct. Minor omissions on v5 migration edge cases (semicolonDelimiter, hasRoute). |
| **Completeness** | 5 | Covers every major Fastify topic. 3 reference docs, 2 scripts, 3 templates. |
| **Actionability** | 5 | Every section has working code. Scripts scaffold immediately. Templates are production-ready. I/O annotations on key examples. |
| **Trigger Quality** | 5 | Comprehensive positive triggers, well-defined negative triggers, low false-positive risk. |

**Overall: 4.75 / 5.0**

## E. Issues

No GitHub issues required (overall ≥ 4.0, no dimension ≤ 2).

### Suggested Improvements (non-blocking)

1. Add a brief note about `useSemicolonDelimiter: true` option in v5 under Schema Validation or Setup
2. Consider mentioning `reply.elapsedTime` (the SKILL.md already uses it correctly in the onResponse hook example at line 196, but the rename from `getResponseTime()` could be called out)
3. The api-reference.md is 727 lines — consider whether it could link to official docs rather than duplicating

## F. Verdict

**PASS** ✅
