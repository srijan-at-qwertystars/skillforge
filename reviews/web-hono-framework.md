# QA Review: hono-framework

**Skill path:** `~/skillforge/web/hono-framework/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Verdict:** PASS

---

## a. Structure

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ | `name` + `description` with positive triggers (import paths, class names, runtime contexts) and negative triggers (Express, Fastify, Koa, Nest, Next.js, React/Vue/Svelte, plain Workers) |
| Under 500 lines | ✅ | SKILL.md is 498 lines |
| Imperative tone | ✅ | Instructional throughout; direct code examples |
| Examples | ✅ | Abundant copy-paste-ready code in every section |
| Linked resources | ✅ | 3 reference docs, 3 scripts, 3 asset templates — all described in SKILL.md |

**Files reviewed:**
- `SKILL.md` (498 lines)
- `references/advanced-patterns.md` (~860 lines)
- `references/runtime-guide.md` (~599 lines)
- `references/troubleshooting.md` (~695 lines)
- `scripts/create-hono-app.sh`, `scripts/openapi-scaffold.sh`, `scripts/hono-benchmark.sh`
- `assets/cloudflare-worker-template/` (wrangler.toml + src/index.ts)
- `assets/bun-server-template/` (package.json + src/index.ts)
- `assets/docker-compose.yml`

---

## b. Content Accuracy (Hono 4.x)

### Verified correct ✅
- **Routing:** `app.get/post/put/delete`, path params via `c.req.param()`, wildcards, regex constraints, route groups via `app.route()`, method chaining — all match Hono 4.x API.
- **Context response helpers:** `c.json()`, `c.text()`, `c.html()`, `c.redirect()`, `c.body()`, `c.notFound()`, `c.header()`, `c.status()` — confirmed correct.
- **Context request methods:** `c.req.param()`, `c.req.query()`, `c.req.queries()`, `c.req.header()`, `c.req.json()`, `c.req.parseBody()`, `c.req.text()`, `c.req.url`, `c.req.method`, `c.req.raw` — all valid.
- **Middleware imports:** `hono/cors`, `hono/logger`, `hono/jwt`, `hono/compress`, `hono/cache`, `hono/etag`, `hono/secure-headers`, `hono/pretty-json`, `hono/timing` — all confirmed.
- **Custom middleware:** `createMiddleware` from `hono/factory` — correct API.
- **Validation:** `@hono/zod-validator` with targets `'json'`, `'query'`, `'param'`, `'header'`, `'cookie'`, `'form'` — correct.
- **RPC client:** `hc` from `hono/client`, `InferRequestType`/`InferResponseType` — correct.
- **JSX:** `jsxImportSource: "hono/jsx"`, `FC` type, `Suspense`, `jsxRenderer` — correct.
- **Testing:** `app.request()` API with `(path, init?, env?)` signature — correct.
- **Error handling:** `HTTPException` from `hono/http-exception`, `app.onError()`, `app.notFound()` — correct.
- **Runtime adapters:** All 7 runtime patterns verified (CF Workers export default, `@hono/node-server`, `Deno.serve`, Bun export, `hono/aws-lambda`, `hono/vercel`, `app.fire()` for Fastly).
- **Environment access:** `c.env` for CF Workers, `env()` helper from `hono/adapter`, `getRuntimeKey()` — correct.
- **Cookies:** `getCookie`, `setCookie`, `deleteCookie`, `getSignedCookie`, `setSignedCookie` from `hono/cookie` — correct.
- **Middleware composition:** `every`/`some` from `hono/combine` — correct.
- **OpenAPI:** `@hono/zod-openapi` with `OpenAPIHono`, `createRoute`, `swaggerUI` — correct.
- **WebSocket:** Runtime-specific imports (`hono/cloudflare-workers`, `hono/bun` via `createBunWebSocket`, `hono/deno`) — correct.

### Issues found ⚠️

1. **Streaming API — inconsistent/outdated pattern (minor)**
   - SKILL.md describes streaming as `c.stream`, `c.streamText` (context methods) but `streamSSE` as standalone.
   - `references/advanced-patterns.md` uses `c.streamText(async (stream) => {` and `c.stream(async (stream) => {` as context methods.
   - Hono 4.x official API uses **standalone functions**: `import { stream, streamText, streamSSE } from 'hono/streaming'` with signature `streamText(c, async (stream) => { ... })`.
   - The troubleshooting guide correctly uses `streamSSE(c, ...)` but is inconsistent with the advanced-patterns doc.
   - **Impact:** Users copying examples may get runtime errors or use a deprecated API.

2. **RegExpRouter described as "trie-based" (minor)**
   - SKILL.md line 20: "Routing uses a high-performance RegExpRouter (trie-based)."
   - RegExpRouter is actually a **trie-to-regexp hybrid**: it uses a trie during route registration/compilation, then produces a single optimized regexp per HTTP method for runtime matching. Calling it "trie-based" is misleading. TrieRouter is the purely trie-based alternative.
   - **Suggested fix:** "RegExpRouter (compiles routes into a single optimized regexp)"

3. **Unclosed code block in SKILL.md (formatting bug)**
   - Lines 99–112: The "Response Helpers" code block (opened at line 99) is never closed before the `### Request Data` heading at line 112. The heading renders inside the fenced code block in strict markdown parsers.
   - **Fix:** Add closing ` ``` ` before line 112.

4. **Missing built-in middleware from listing (minor omission)**
   - The built-in middleware section omits several Hono 4.x middleware: `hono/basic-auth`, `hono/bearer-auth`, `hono/csrf`, `hono/request-id`, `hono/timeout`, `hono/ip-restriction`, `hono/body-limit` (only mentioned in troubleshooting, not in main listing).
   - Not critical — the most commonly used ones are present.

---

## c. Trigger Check

### Positive triggers — pushy enough? ✅ Yes
- Covers specific imports (`'hono'`, `hono/cors`, `hono/jwt`, `@hono/zod-validator`, `hono/client`)
- Covers class/function names (`Hono`, `c.json`, `c.text`, `c.html`, `hc`)
- Covers project signals (`create-hono`, `hono.dev`, `wrangler.toml + Hono`)
- Covers runtime combos (`Cloudflare Workers with Hono`, `Bun/Deno/Node.js Hono servers`)
- Covers feature areas (`Hono middleware`, `Hono RPC client`, `hono/jsx SSR`)

### Negative triggers — false trigger prevention? ✅ Good
- Excludes competing frameworks: Express.js, Fastify, Koa, Nest.js, Next.js API routes
- Excludes frontend-only: React/Vue/Svelte
- Excludes adjacent context: plain Cloudflare Workers without Hono imports
- Excludes generic: general TypeScript questions unrelated to Hono

### False trigger risk: Low
- "wrangler.toml + Hono project" could theoretically match a wrangler.toml without Hono, but the conjunction mitigates this.
- The negative trigger for "plain Cloudflare Workers without Hono imports" provides clear boundary.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Core APIs all correct. Minor issues: streaming API uses deprecated `c.stream()`/`c.streamText()` context-method pattern in some sections; RegExpRouter misdescribed as "trie-based"; unclosed code block formatting bug. |
| **Completeness** | 4 | Excellent coverage of routing, middleware, validation, RPC, JSX, testing, error handling, 7 runtime adapters, advanced patterns (WebSocket, SSE, sessions, rate limiting, multi-tenant, OpenAPI). Missing a handful of newer built-in middleware. Reference docs and scripts are thorough. |
| **Actionability** | 5 | Outstanding. Every section has copy-paste-ready code. Three scaffold/utility scripts. Two starter templates. Docker Compose. Express migration table. Common pitfalls section with ❌/✅ patterns. |
| **Trigger quality** | 4 | Comprehensive positive triggers covering imports, class names, and runtime contexts. Strong negative triggers. Slightly verbose description but appropriate for matching breadth. |
| **Overall** | **4.25** | — |

---

## e. GitHub Issues

No issues filed. Overall score (4.25) ≥ 4.0 and no dimension ≤ 2.

### Recommended improvements (non-blocking):
1. Fix streaming examples to use standalone `stream()`/`streamText()` from `hono/streaming` instead of `c.stream()`/`c.streamText()`.
2. Correct RegExpRouter description from "trie-based" to "compiles routes into a single optimized regexp."
3. Close the unclosed code block at SKILL.md line 110 (add ` ``` ` before `### Request Data`).
4. Consider adding `hono/basic-auth`, `hono/bearer-auth`, `hono/body-limit`, `hono/csrf` to the built-in middleware listing.

---

## f. SKILL.md Annotation

`<!-- tested: pass -->` appended to SKILL.md.
