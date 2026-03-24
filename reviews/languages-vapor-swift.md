# QA Review: `vapor-swift`

**Skill path:** `~/skillforge/languages/vapor-swift/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-16

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (name, description) | ✅ Pass | `name` and `description` present with positive and negative triggers |
| +/- triggers in description | ✅ Pass | Positive: Vapor, server-side Swift, Fluent ORM, Swift web API. Negative: iOS, SwiftUI, Kitura, Perfect |
| Under 500 lines | ✅ Pass | 498 lines (borderline — watch for growth) |
| Imperative voice | ✅ Pass | "Use Swift Package Manager", "Validate before decoding", "Register migrations in dependency order" |
| Code examples | ✅ Pass | Rich examples for routing, Fluent, auth, middleware, WebSockets, Leaf, queues, testing |
| References linked | ✅ Pass | 3 reference guides, 3 scripts, 5 template assets — all with summary tables |

## b. Content Check

### Verified Accurate
- Project structure and `Package.swift` layout
- Entrypoint with `@main struct`, `Application.make`, `app.execute()`
- Routing syntax: path parameters, route groups, `RouteCollection` controllers
- Fluent model definitions: `@ID`, `@Field`, `@OptionalField`, `@Timestamp`, `@Parent`, `@Children`, `@Siblings`
- Migrations with `AsyncMigration`, `.schema()` builder, `.unique(on:)`, `.references()`
- Query builder: `.filter()`, `.sort()`, `.limit()`, `.with()` eager loading, `.paginate(for:)`, joins, aggregates
- Sibling attach/detach
- DTOs with `Content` + `Validatable`, validation rules
- `ModelAuthenticatable` / `ModelTokenAuthenticatable` protocols
- Session auth, middleware patterns, `Abort` error handling
- Leaf templating, Queues with Redis driver, `XCTVapor` testing
- Deployment checklist and concurrency rules
- Reference guides (fluent-orm-guide, authentication-guide, troubleshooting) are thorough and well-organized

### ❌ Inaccuracies Found

1. **`@Boolean` and `@Enum` property wrappers do not exist** (line 163)
   The skill lists `@Enum` and `@Boolean` as Fluent property wrappers. Fluent has **no such wrappers**. Booleans use `@Field` with `Bool` type; enums use `@Field` with a `String`-backed `Codable` enum (or native DB enums via migration schema). This is a factual error that could confuse users.

2. **JWT API is deprecated** (lines 310–317)
   - `app.jwt.signers.use(.hs256(key: ...))` is deprecated in JWTKit 5.x. The current API is:
     ```swift
     await app.jwt.keys.add(hmac: "secret", digestAlgorithm: .sha256)
     ```
   - `func verify(using signer: JWTSigner) throws` signature has changed — `JWTSigner` is replaced by newer key-based verification.
   - `JWTKeyCollection` is now an actor; all key operations are `async`.

3. **WebSocket `ws.send()` should be async** (line 373)
   Modern Vapor recommends `try await ws.send(...)` inside a `Task` block within `onText`. The synchronous call style shown may produce warnings or unexpected behavior under strict concurrency.

### Missing Gotchas
- No mention of `app.asyncShutdown()` vs `app.shutdown()` distinction (entrypoint uses `shutdown()`, tests use `asyncShutdown()` — inconsistent)
- No coverage of database connection pool configuration (`app.databases.use(..., maxConnectionsPerEventLoop:)`)
- No mention of `StrictConcurrency` setting in `Package.swift` for Swift 6 readiness
- Built-in `CORSMiddleware` is mentioned but the custom example doesn't show using it; no preflight OPTIONS handling discussed

## c. Trigger Check

| Aspect | Assessment |
|--------|-----------|
| Vapor-specific activation | ✅ Strong — triggers on "Vapor", "Fluent ORM", "server-side Swift", "Swift web API", "Swift backend" |
| iOS false-positive risk | ✅ Low — explicitly excludes "iOS, SwiftUI" |
| General web framework risk | ✅ Low — excludes "non-Swift web frameworks" |
| Other Swift server frameworks | ✅ Low — excludes "Kitura, Perfect" |
| Edge case: "Swift backend" | ⚠️ Marginal — could match non-Vapor Swift server code, but reasonable |

**Trigger verdict:** Well-crafted. Specific enough to avoid false positives for the vast majority of cases.

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3 / 5 | Two factual errors: phantom `@Boolean`/`@Enum` wrappers and deprecated JWT API. WebSocket `send` pattern is outdated. |
| **Completeness** | 4 / 5 | Excellent breadth (routing, ORM, auth, middleware, WS, Leaf, queues, testing, deployment). Good references and scripts. Missing connection pool config and Swift 6 concurrency prep. |
| **Actionability** | 5 / 5 | Outstanding. Every section has copy-paste-ready code. Scripts automate project scaffolding, Docker builds, and testing. Template assets are production-ready. |
| **Trigger Quality** | 5 / 5 | Precise positive/negative triggers. Low false-positive risk across iOS, SwiftUI, and non-Swift frameworks. |
| **Overall** | **4.25** | |

## e. Recommended Fixes

### Must Fix (accuracy)
1. **Remove `@Boolean` and `@Enum` from property wrapper list** on line 163. Replace with a note that `@Field` handles `Bool` and `Codable` enum types directly.
2. **Update JWT section** (lines 308–318) to use `JWTKeyCollection` API:
   ```swift
   await app.jwt.keys.add(hmac: Environment.get("JWT_SECRET")!, digestAlgorithm: .sha256)
   ```
3. **Update WebSocket example** to use `try await ws.send(...)`.

### Should Fix (completeness)
4. Add a note about `app.asyncShutdown()` in the entrypoint pattern.
5. Add connection pool configuration guidance.
6. Mention Swift 6 strict concurrency and `StrictConcurrency` build setting.

## f. GitHub Issue

No issue required. Overall score 4.25 ≥ 4.0 and no dimension ≤ 2.

---

*Generated by Copilot CLI automated skill review.*
