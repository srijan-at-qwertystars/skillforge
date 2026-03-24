# QA Review: wasm-components

**Skill path:** `~/skillforge/systems/wasm-components/`
**Reviewed:** 2025-07-17
**Verdict:** `pass`

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `wasm-components` |
| YAML frontmatter `description` with positive triggers | ✅ | Comprehensive USE-when list covering WASM targets, toolchains, runtimes, WIT, SIMD, threads |
| YAML frontmatter `description` with negative triggers | ✅ | DO NOT USE for plain JS, native binaries, non-WASM Docker, general Rust/Go/C |
| Body ≤ 500 lines | ✅ | Exactly 500 lines |
| Imperative voice | ✅ | Consistent imperative/instructional tone |
| Examples with input/output | ✅ | Extensive code blocks with commands and expected outputs throughout |
| references/ linked from SKILL.md | ❌ | No links to `references/advanced-patterns.md`, `references/platform-guide.md`, or `references/troubleshooting.md` |
| scripts/ linked from SKILL.md | ❌ | No links to `scripts/wasm-build.sh`, `scripts/wasm-inspect.sh`, or `scripts/wasm-rust-init.sh` |
| assets/ linked from SKILL.md | ❌ | No links to `assets/docker-compose.yml`, `assets/js-loader.html`, `assets/rust-component/`, or `assets/wit/` |

**Structure issue:** SKILL.md has a terminal `## Additional Resources` heading (line 500) with no content beneath it. This is where references, scripts, and assets should be linked. The supporting files are high-quality but effectively invisible to the skill consumer.

---

## B. Content Check

### Claims verified via web search

| Claim | Verdict | Notes |
|-------|---------|-------|
| WASI Preview 2 released January 2024 | ✅ Accurate | WASI 0.2 voted stable Jan 25, 2024 by the WASI Subgroup (Bytecode Alliance) |
| Component Model built on WIT | ✅ Accurate | Under W3C Community Group, WIT is the IDL |
| `wasm-tools` install via `cargo install wasm-tools` | ✅ Accurate | Latest is v1.245.x; command is correct |
| Wasmtime: WASI P2 ✅, Component Model ✅ | ✅ Accurate | Reference implementation; `wasmtime serve` for HTTP components |
| Wasmer: WASI P2 ✅, Component Model Partial | ✅ Accurate | Wasmer trails Wasmtime on Component Model |
| WasmEdge: WASI P2 ✅, Component Model ✅ | ✅ Accurate | Confirmed |
| wazero: P1 only, no Component Model | ✅ Accurate | Pure Go, preview1 only, no CM support |
| TinyGo wasip2 target | ✅ Accurate | TinyGo v0.33+ supports `-target=wasip2` |
| WASI Preview 3 in development with `stream<T>`, `future<T>` | ✅ Accurate | Expected 2025, async/streaming focus |
| `wee_alloc` ~1KB allocator recommendation | ❌ Outdated | `wee_alloc` is **deprecated and unmaintained** (archived Aug 2025). Buggy heap fragmentation. Default `dlmalloc` is recommended; `alloc_cat` is an alternative |
| Spin serves on `:3000` | ✅ Accurate | Default `spin up` listens on 127.0.0.1:3000 |
| `cargo-component` output target `wasm32-wasip1` | ⚠️ Nuance | Newer cargo-component versions may default to `wasm32-wasip2`; skill states `wasm32-wasip1` |

### Missing gotchas

1. **`wee_alloc` deprecation** — Skill recommends it in §Performance and §Size optimization, and the troubleshooting reference doubles down. Must be corrected or flagged.
2. **`cargo-component` target evolution** — cargo-component has shifted toward `wasm32-wasip2` as default; line 164 says output is `target/wasm32-wasip1/release/` which may be inaccurate for current tooling.
3. **Wasmer WASI P2 caveats** — table says ✅ for WASI P2 but Wasmer's P2 support is less mature than Wasmtime's; a footnote would help.

### Example correctness

- Rust wasm-bindgen, wasm-pack, cargo-component examples: ✅ correct
- Go/TinyGo targets: ✅ correct
- C/C++ Emscripten and WASI SDK: ✅ correct
- AssemblyScript init command: ✅ correct (`npm init assemblyscript`)
- JS interop (instantiateStreaming, memory access): ✅ correct
- WIT syntax examples: ✅ correct
- Docker/OCI examples: ✅ correct
- Reference files (advanced-patterns.md, platform-guide.md, troubleshooting.md): ✅ all well-written and accurate
- Scripts (wasm-build.sh, wasm-inspect.sh, wasm-rust-init.sh): ✅ functional, well-documented
- Assets (docker-compose.yml, js-loader.html, rust-component/, wit/): ✅ correct and useful

---

## C. Trigger Check

### Positive triggers (would it fire for WASM queries?)

| Query | Would trigger? |
|-------|---------------|
| "Compile Rust to WASM for browser" | ✅ Yes — `wasm-pack`, `wasm-bindgen`, `wasm32-unknown-unknown` |
| "Write a WIT interface for my component" | ✅ Yes — `WIT interfaces`, `worlds` |
| "Run WASM in Wasmtime with WASI" | ✅ Yes — `Wasmtime`, `WASI preview 1 or preview 2` |
| "Build WASM component with TinyGo" | ✅ Yes — `TinyGo for WASM` |
| "Docker WASM workload" | ✅ Yes — `Docker with WASM` |
| "WASM SIMD optimization" | ✅ Yes — `WASM SIMD` |
| "Package WASM as OCI artifact" | ✅ Yes — `packaging WASM as OCI artifacts` |

### Negative triggers (false positives?)

| Query | Would falsely trigger? |
|-------|----------------------|
| "Build a React app with Vite" | ✅ No — plain JavaScript, no WASM |
| "Compile C++ to native binary with GCC" | ✅ No — native binary excluded |
| "Docker compose for PostgreSQL" | ✅ No — Docker without WASM runtimes excluded |
| "Rust async web server with Tokio" | ✅ No — general Rust not targeting WASM excluded |
| "Node.js Express API" | ✅ No — plain JS excluded |

**Trigger quality is excellent.** Broad positive coverage with well-scoped negative exclusions.

---

## D. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Nearly all claims verified correct. Deducted for `wee_alloc` deprecation (recommended in two places) and minor `cargo-component` target nuance. |
| **Completeness** | 5 | Exceptionally comprehensive: covers 6 source languages, 6+ runtimes, browser/server/container/K8s, Component Model, WIT, networking, testing, profiling, 12 pitfalls. Reference files add substantial depth (platform guide, troubleshooting, advanced patterns). |
| **Actionability** | 4 | Highly actionable with concrete commands, code, and config. Deducted because SKILL.md does not link to the excellent reference files, scripts, or assets — a user would not know they exist. The empty `## Additional Resources` section is a missed opportunity. |
| **Trigger quality** | 5 | Comprehensive positive trigger list covering all major WASM tools, targets, and workflows. Clean negative triggers prevent false activation for JS, native builds, and general language work. |

### Overall: **4.5 / 5.0** → **PASS**

---

## E. Issues

No GitHub issues required (overall ≥ 4.0, no dimension ≤ 2).

### Recommended improvements (non-blocking)

1. **Fix `wee_alloc` references** — Replace recommendation with default allocator guidance. Note `wee_alloc` is archived/unmaintained. Consider mentioning `alloc_cat` as a lightweight alternative.
2. **Populate `## Additional Resources`** — Link to all files in `references/`, `scripts/`, and `assets/` with brief descriptions.
3. **Update `cargo-component` target** — Clarify that newer versions may target `wasm32-wasip2` by default; adjust line 164 output path accordingly.
4. **Add Wasmer P2 footnote** — Note that Wasmer's WASI P2 support is less mature than Wasmtime's.

---

## F. Test Marker

`<!-- tested: pass -->` appended to SKILL.md.
