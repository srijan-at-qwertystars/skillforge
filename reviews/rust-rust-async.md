# QA Review: rust-async

**Skill path:** `~/skillforge/rust/rust-async/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Verdict:** PASS

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter — `name` | ✅ | `rust-async` |
| YAML frontmatter — `description` with positive triggers | ✅ | 10+ USE triggers covering tokio, Future, Pin, channels, axum, tower, tracing, etc. |
| YAML frontmatter — negative triggers | ✅ | DO NOT USE for sync Rust, ownership/borrowing, Zig, Go, C++, JS, GUI, embedded, WASM |
| Body under 500 lines | ✅ | Body is 486 lines (lines 15–500). Total file 500 lines. |
| Imperative voice | ✅ | Consistent throughout ("Use bounded channels", "Never call blocking code", "Always use tokio::fs") |
| Examples with input/output | ✅ | Extensive code examples with inline comments showing expected behavior. Return types serve as "output." |
| References linked from SKILL.md | ✅ | All 3 reference files linked in table with topic summaries |
| Scripts linked from SKILL.md | ✅ | All 3 scripts linked with purpose and usage columns |
| Assets linked from SKILL.md | ⚠️ | 4 of 5 assets linked. `docker-compose.yml` exists in `assets/` but is not listed in the SKILL.md assets table |

## b. Content Check — Accuracy Verification

| Claim | Verified | Source |
|-------|----------|--------|
| `Future` trait signature (`poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>`) | ✅ | std lib docs, Tokio docs |
| Pin guarantees pointee won't move; most types are Unpin | ✅ | std::pin docs |
| `tokio::spawn` requires `Send + 'static` | ✅ | Tokio docs |
| `JoinSet::join_next()` API | ✅ | tokio::task::JoinSet docs |
| Channel types (mpsc/oneshot/broadcast/watch) — APIs correct | ✅ | tokio::sync docs |
| `tokio::sync::Mutex` vs `std::sync::Mutex` guidance | ✅ | Tokio best practices |
| `select!` cancellation — first branch runs, others dropped | ✅ | tokio::select! docs |
| `futures::StreamExt::next` "may not be" cancellation-safe | ✅ | Nuanced but correct — depends on underlying stream impl |
| axum 0.8 route syntax uses `{id}` (not `:id`) | ✅ | axum 0.8 changelog, docs.rs |
| Tower layer ordering: "last added wraps outermost" | ✅ | axum middleware docs, tower docs |
| `axum::serve(listener, app)` API (current for 0.8) | ✅ | axum docs |
| `#[tokio::test(start_paused = true)]` for mock time | ✅ | Tokio test-util docs |
| `thiserror` v2 / `anyhow` v1 pattern | ✅ | Crate docs |

**Missing gotchas (minor):**
- Native async fn in traits (RPITIT, Rust 1.75+) not covered in SKILL.md body — only in `references/advanced-patterns.md`. Acceptable since it's linked.
- `tokio-console` for runtime debugging mentioned only in troubleshooting reference, not main body.
- No coverage of `async fn` lifetime elision pitfalls in the main body.

**Code correctness:** All examples compile-correct. The `assets/` files (main.rs, error.rs, middleware.rs, Cargo.toml) are production-quality templates with proper error handling, tracing, and graceful shutdown.

## c. Trigger Check

| Scenario | Expected | Actual | Status |
|----------|----------|--------|--------|
| "How do I use tokio::spawn?" | Trigger | ✅ Matches "tokio::spawn" | ✅ |
| "axum middleware ordering" | Trigger | ✅ Matches "axum" and "tower middleware" | ✅ |
| "Future trait Pin Unpin" | Trigger | ✅ Matches "Future trait, Pin/Unpin" | ✅ |
| "async channels mpsc" | Trigger | ✅ Matches "channels (mpsc/oneshot/broadcast/watch)" | ✅ |
| "Cargo.toml includes tokio" | Trigger | ✅ Matches "Cargo.toml includes tokio" | ✅ |
| "Rust ownership borrowing" | No trigger | ✅ Excluded by "general Rust ownership/borrowing" | ✅ |
| "Rust sync Mutex without async" | No trigger | ✅ Excluded by "synchronous Rust" | ✅ |
| "Go goroutines" | No trigger | ✅ Excluded by "Go" | ✅ |
| "JavaScript async/await Promise" | No trigger | ✅ Excluded by "JavaScript async/Promise" | ✅ |
| "Rust GUI with iced" | No trigger | ✅ Excluded by "Rust GUI frameworks" | ✅ |
| "WASM async runtime" | No trigger | ✅ Excluded by "WASM-only async runtimes" | ✅ |

**False positive risk:** Low. Negative triggers are specific and comprehensive.
**False negative risk:** Low. Positive triggers cover crate names, concepts, and common error patterns.

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All technical claims verified against current docs. Future trait, tokio APIs, axum 0.8 syntax, tower layer ordering all correct. |
| **Completeness** | 4 | Excellent coverage of core async ecosystem. Minor gaps: unlisted docker-compose.yml asset, native async traits only in reference, tokio-console only in troubleshooting ref. |
| **Actionability** | 5 | Copy-paste examples for every concept. Three executable scripts (scaffolding, benchmarking, linting). Four production-ready asset templates. Clear pitfall/fix pairs. |
| **Trigger quality** | 5 | Precise positive triggers cover concepts + crate names. Negative triggers prevent false activation for sync Rust, other languages, GUI/embedded/WASM. |

| **Overall** | **4.75** |
|-------------|----------|

## e. Issues

No GitHub issues required (overall ≥ 4.0, no dimension ≤ 2).

**Recommendations (non-blocking):**
1. Add `docker-compose.yml` to the assets table in SKILL.md.
2. Consider a brief mention of native async trait methods (RPITIT, Rust 1.75+) in the main body, since it deprecates the `async-trait` crate for many use cases.
3. Add a one-liner about `tokio-console` in the Tracing section of SKILL.md.

## f. Test Status

**`<!-- tested: pass -->`** appended to SKILL.md.
