# QA Review: swagger-openapi

**Skill path:** `api/swagger-openapi/`  
**Reviewed:** 2025-07-18  
**Reviewer:** Copilot QA  

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ Pass | `name`, `description` with TRIGGER/NOT clauses present |
| Under 500 lines | ✅ Pass | SKILL.md is 499 lines (just under limit) |
| Imperative voice | ✅ Pass | Direct, instructional tone throughout |
| Examples | ✅ Pass | 3 examples with Input/Output (CRUD spec, OAuth2+webhook, validate+generate) |
| References linked | ✅ Pass | 3 reference docs: advanced-patterns, troubleshooting, code-generation-guide |
| Scripts linked | ✅ Pass | 3 scripts: validate-spec.sh, generate-client.sh, diff-specs.sh |
| Assets linked | ✅ Pass | 5 assets: template, spectral ruleset, redocly config, GH Actions workflow, generator config |

**Structure verdict:** Excellent. Well-organized with tables documenting scripts and assets.

---

## b. Content Check

### OpenAPI 3.1 Spec Syntax — ✅ Verified

- `nullable: true` → `type: ["string", "null"]` — **correct** per OAS 3.1 / JSON Schema 2020-12
- `example` → `examples` (array) — **correct**
- `format: binary` → `contentEncoding: base64` / `contentMediaType` — **mostly correct**; `format: binary` is still valid for multipart in 3.1, the skill's own template correctly uses `format: binary` for file upload
- `paths` optional — **correct**
- JSON Schema keywords (`if/then/else`, `prefixItems`, `$dynamicRef`) — **correct**
- Schema composition (allOf, oneOf, anyOf, discriminator) — **correct** syntax and explanations
- Security schemes (Bearer, API Key, OAuth2, OpenID Connect) — **correct**
- Webhooks, Links, Callbacks — **correct** OAS 3.1 syntax

### Code Generator Commands — ✅ Verified

- `typescript-axios` generator name — **correct** (confirmed via openapi-generator docs)
- `python-fastapi` generator name — **correct**
- `openapi-generator-cli generate` syntax — **correct**
- `spectral lint` and `redocly lint/bundle/split` commands — **correct**

### oasdiff Commands — ⚠️ Minor Issue

- `oasdiff breaking base.yaml new.yaml` syntax — **correct**
- `--fail-on ERR` flag — **correct**
- **Issue:** `diff-specs.sh` line 23 references `go install github.com/tufin/oasdiff@latest`. The oasdiff project migrated from `tufin/oasdiff` to `oasdiff/oasdiff` in mid-2024. The old import path may still redirect but should be updated to `github.com/oasdiff/oasdiff@latest`.

### Scripts — ⚠️ Minor Bug

- `validate-spec.sh` JSON output (lines 183–195) produces **trailing commas** in the JSON object, which makes the output invalid JSON. The `for` loop appends `","` after every result entry, and `"results": { ... },` also has a trailing comma before `overallStatus`.

### Missing Gotchas

- No mention of **OpenAPI 3.2** (released 2024) — acceptable omission for now since 3.1 is still dominant
- No coverage of `exclusiveMinimum`/`exclusiveMaximum` change from boolean (3.0) to numeric (3.1)
- No mention of the `null` enum value gotcha (must explicitly include `null` in enum list when using nullable enums)

---

## c. Trigger Check

### Positive Triggers — ✅ Good Coverage

Triggers on: `"OpenAPI"`, `"Swagger"`, `"openapi spec"`, `"API specification"`, `"swagger-ui"`, `"openapi-generator"`, `"swagger-codegen"`, `"API schema definition"`, `"paths and operations"`, `"openapi.yaml"`, `"openapi.json"`, `"OAS 3"`, `"$ref in API spec"`, `"API documentation generation"`, `"Redoc"`, `"spectral"`, `"openapi-lint"`, `"API design-first"`, `"code-first API"`, `"swagger editor"`, `"operationId"`, `"requestBody"`, `"API components schema"`

Coverage is comprehensive. Includes tool names (Spectral, Redoc, swagger-codegen), spec concepts (operationId, requestBody, $ref), and file names (openapi.yaml).

### Negative Triggers — ✅ Well Scoped

`NOT for GraphQL schemas, gRPC proto files, AsyncAPI, RAML, or general REST API design without OpenAPI context.`

Correctly excludes adjacent API specification technologies.

### False-Trigger Risk Assessment

| Trigger | Risk | Analysis |
|---------|------|----------|
| "API specification" | Medium | Could match generic API design questions without OpenAPI context |
| "API documentation generation" | Medium | Could match Javadoc, Sphinx, or generic doc tooling |
| "$ref in API spec" | Low | "$ref" + "API spec" qualifier is sufficiently specific |
| "API schema definition" | Medium | Could match JSON Schema, GraphQL schema, or Protobuf |
| All others | Low | Specific tool/concept names unlikely to collide |

**Trigger verdict:** Good overall. Three terms carry moderate false-trigger risk but the NOT clause provides reasonable guardrails. No high-risk false triggers.

---

## d. Scores

| Dimension | Score | Justification |
|-----------|-------|---------------|
| **Accuracy** | 5 | All OAS 3.1 syntax, code-gen commands, and tool usage verified correct against current docs |
| **Completeness** | 4 | Thorough coverage of OAS 3.1, tooling, and patterns. Minor gaps: no 3.2 mention, nullable enum gotcha, exclusiveMin/Max change. Reference docs fill most gaps well. |
| **Actionability** | 5 | Ready-to-use template, scripts with proper flags/help, CI/CD pipeline, Spectral/Redocly configs, generator config. Excellent. |
| **Trigger quality** | 4 | Comprehensive positive triggers with good negative exclusions. Minor false-trigger risk on 3 generic terms. |

**Overall: 4.5 / 5.0**

---

## e. Issues Found (non-blocking)

1. **`diff-specs.sh` stale oasdiff install path** — `github.com/tufin/oasdiff` should be `github.com/oasdiff/oasdiff` (repo migrated mid-2024)
2. **`validate-spec.sh` invalid JSON output** — trailing commas in `--format json` mode produce malformed JSON
3. **Missing gotcha: nullable enums** — When using `type: ["string", "null"]` with `enum`, `null` must be explicitly listed in the enum array
4. **Trigger precision** — "API specification", "API documentation generation", and "API schema definition" could be more specific (e.g. "OpenAPI specification", "OpenAPI documentation generation")

---

## f. GitHub Issue Filing

**Not required.** Overall score (4.5) ≥ 4.0 and no individual dimension ≤ 2.

---

## g. Test Result

**PASS** — High-quality skill with minor non-blocking issues noted above.
