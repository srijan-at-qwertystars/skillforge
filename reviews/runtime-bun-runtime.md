# Review: bun-runtime

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.2/5

Issues:

1. **HTTP/2 claim is incorrect (references/advanced-patterns.md lines 155-177)**: States "Bun supports HTTP/2 automatically when TLS is configured" for Bun.serve. This is false — Bun.serve does NOT support HTTP/2 natively (see [oven-sh/bun#14672](https://github.com/oven-sh/bun/issues/14672)). HTTP/2 is only available via the `node:http2` compatibility module, not through Bun.serve. The entire HTTP/2 section (including claims about ALPN negotiation, multiplexing, and header compression) should be corrected or removed.

2. **Missing `routes` API (Bun 1.2.3+)**: The skill only documents the `fetch`-based pattern for Bun.serve routing. Since Bun 1.2.3, `Bun.serve({ routes: { ... } })` provides declarative routing with typed parameters, per-method handlers, and wildcard support. This is a significant omission for a current Bun skill.

3. **Bundler default target nuance (SKILL.md line 192)**: States `browser` is the default target. While this is correct for CLI `bun build`, the actual default is inferred from entrypoint type (HTML → browser, .ts/.js → browser for CLI). Minor, but could confuse users targeting Bun runtime.

4. **`static` option in Bun.serve may be outdated**: The `static` key shown in the SKILL.md static file routes example (lines 123-134) is less idiomatic than the newer `routes` approach with `Bun.file()` values. Should mention both patterns.

## Structure Check
- ✅ YAML frontmatter: has `name` and `description`
- ✅ Description: has positive triggers (runtime, package manager, bundler, test runner, specific APIs) AND negative triggers (not Node.js, Deno, browser JS, npm/yarn without Bun)
- ✅ Body: 499 lines (under 500 limit)
- ✅ Imperative voice throughout
- ✅ Examples with code input/output patterns
- ✅ All references linked and files exist (3 reference docs, 3 scripts, 3 assets)

## Content Check
- ✅ Installation methods accurate (curl, Homebrew, npm, Windows PowerShell)
- ✅ Bun.serve() basic API correct (fetch handler, Response.json, WebSocket upgrade)
- ✅ WebSocket pub/sub pattern correct (subscribe/publish/unsubscribe)
- ✅ TLS configuration syntax correct
- ✅ Package manager commands accurate (bun add, bun install, bun remove)
- ✅ bun.lock text-based lockfile (Bun 1.2+) correctly documented
- ✅ Bundler API (Bun.build) options correct
- ✅ Test runner (bun:test) imports, mock, snapshot syntax correct
- ✅ mock.module() syntax correct
- ✅ Bun Shell (Bun.$) API correct including .text(), .nothrow(), .quiet()
- ✅ Bun.file()/Bun.write() API correct
- ✅ bun:sqlite synchronous API correct
- ✅ bun:ffi dlopen/FFIType correct
- ✅ Environment variable loading order correct
- ✅ Hot reload (--watch vs --hot) distinction correct
- ✅ Macros import attributes syntax correct
- ✅ Plugin API (build.onLoad/onResolve) correct
- ❌ HTTP/2 in advanced-patterns.md is wrong (see issue #1)
- ⚠️ Missing routes API (see issue #2)

## Trigger Check
- ✅ Would trigger for: "Bun HTTP server", "Bun.serve WebSocket", "migrate Node to Bun", "bun:sqlite", "Bun shell scripting", "Bun bundler", "bun test"
- ✅ Would NOT false-trigger for: "Node.js express app", "Deno deploy", "browser fetch API"
- ✅ Negative triggers clearly scoped
- ⚠️ Could be stronger: doesn't explicitly mention "Bun routing" or "Bun fullstack" as triggers

## Asset/Script Quality
- ✅ Dockerfile: well-structured multi-stage build with health check
- ✅ bunfig.toml: comprehensive commented template
- ✅ server.ts: production-ready with CORS, WebSocket, logging, graceful shutdown
- ✅ scaffold-bun-project.sh: handles 4 project types, 3 framework options, well-validated
- ✅ migrate-from-node.sh: thorough compatibility analysis with auto-fix option
- ✅ bun-benchmark.sh: covers startup, file I/O, JSON, crypto, HTTP, install benchmarks
- ✅ Reference docs (troubleshooting, migration-guide, advanced-patterns): comprehensive
