# QA Review: gleam-language

**Reviewed:** 2025-07-18
**Files inspected:** SKILL.md, references/advanced-patterns.md, references/ecosystem-guide.md, references/web-development.md, scripts/setup-gleam.sh, scripts/new-gleam-web.sh, scripts/gleam-ci.sh, assets/gleam.toml, assets/wisp-app-template.gleam, assets/dockerfile

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `gleam-language` |
| YAML frontmatter `description` | ✅ | Comprehensive, 5 lines |
| Positive triggers | ✅ | .gleam files, gleam.toml, CLI commands, libraries, frameworks |
| Negative triggers | ✅ | Explicitly excludes Erlang/Elixir/JS without Gleam, general FP |
| Body under 500 lines | ✅ | 460 lines (474 total minus 14 frontmatter) |
| Imperative voice, no filler | ✅ | Direct, terse, code-heavy |
| Examples with input/output | ✅ | Inline comments show expected values |
| References linked | ✅ | Table at end maps 3 reference files |
| Scripts linked | ✅ | Table at end maps 3 scripts |
| Assets linked | ✅ | Table at end maps 3 assets |

**Structure verdict: PASS**

---

## b. Content Check (Web-Search Verified)

### ✅ Correct

- **Core syntax**: Type definitions, pattern matching, `case` expressions, pipe operator, labelled arguments, anonymous functions, string concatenation with `<>` — all verified correct for Gleam 1.x.
- **`use` expressions**: Callback-flattening semantics correctly described. Usage with `result.try`, `bool.guard`, `list.map`, `list.filter` — all accurate.
- **FFI syntax**: `@external(erlang, "module", "function")` and `@external(javascript, "./file.mjs", "export")` — correct current syntax. Dual-target stacking is accurate.
- **Wisp routing pattern**: `wisp.path_segments(req)` returning `List(String)` for pattern matching, `wisp_mist.handler(fn, secret)` integration — matches current Wisp API (v2.x).
- **Lustre TEA architecture**: `lustre.simple(init, update, view)` and `lustre.application(init, update, view)` patterns — correct for Lustre v5.x.
- **Testing with gleeunit**: `should.equal`, `should.be_error`, `should.be_ok` — correct API.
- **JSON encoding/decoding**: `gleam/dynamic/decode` module path, `decode.field`, `decode.success` pattern — correct for gleam_json v3.x and current gleam_stdlib.
- **Common pitfalls**: All 10 items are accurate (no if/else, float operators, exhaustive matching, etc.).
- **Ecosystem package table**: All packages listed exist and serve the described purposes.

### ⚠️ Issues Found

#### 1. **gleam_otp actor API outdated** (Accuracy: HIGH)
The skill uses the old `actor.start(initial_state, handle_message)` two-argument pattern (SKILL.md line 292, advanced-patterns.md). As of gleam_otp v1.2.0, the recommended API is the builder pattern:
```gleam
// NEW (v1.2.0+)
actor.new(initial_state)
|> actor.on_message(handle_message)
|> actor.start
```
The old `actor.start/2` may still compile but is no longer the documented primary API. All OTP examples (SKILL.md, advanced-patterns.md actors/supervisors sections) should be updated.

#### 2. **Package version ranges in assets/gleam.toml exclude current releases** (Accuracy: HIGH)
| Package | Skill Range | Current Version | Problem |
|---------|-------------|----------------|---------|
| `gleam_json` | `>= 2.1.0 and < 3.0.0` | 3.1.0 | **Excludes latest** |
| `gleam_http` | `>= 3.7.0 and < 4.0.0` | 4.3.0 | **Excludes latest** |
| `wisp` | `>= 1.3.0 and < 2.0.0` | 2.2.1 | **Excludes latest** |
| `mist` | `>= 4.0.0 and < 5.0.0` | ~2.0.0 | **Range seems wrong** |

Users following this template would get old versions or build errors.

#### 3. **Gleam version in setup-gleam.sh is stale** (Accuracy: MEDIUM)
`GLEAM_VERSION` defaults to `1.9.1` but current stable is **v1.14.0** (Dec 2025).

#### 4. **Missing `echo` keyword** (Completeness: LOW)
Gleam v1.9+ introduced the `echo` keyword for debugging (prints value with file/line). Not mentioned anywhere in the skill. Should be in Syntax Fundamentals or Common Patterns.

#### 5. **Missing Gleam language server / tooling mention** (Completeness: LOW)
No mention of `gleam lsp` or editor integration, which is a common developer need.

#### 6. **supervisor API may be outdated** (Accuracy: MEDIUM)
The `supervisor.start(fn(children) { children |> supervisor.add(...) })` pattern in SKILL.md and advanced-patterns.md should be verified against gleam_otp v1.2.0 which may have changed supervisor APIs alongside actor changes.

---

## c. Trigger Check

| Aspect | Assessment |
|--------|------------|
| **Positive triggers** | Strong. Covers: .gleam files, gleam.toml, gleam CLI commands, all major libraries by name, framework names (Wisp, Lustre, Mist), OTP concepts, FFI mentions. |
| **Negative triggers** | Well-scoped. Excludes: standalone Erlang/Elixir/JS, general FP, other BEAM languages without Gleam interop. |
| **Pushy enough?** | Yes — triggers on any mention of Gleam language, .gleam files, or Gleam-specific packages. |
| **False trigger risk** | Low. "Gleam" is distinctive enough. Negative triggers prevent firing on Erlang/Elixir questions. Minor risk: "gleam" as an English word (rare in technical contexts). |

**Trigger verdict: GOOD**

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 3 | OTP actor API outdated for v1.2.0; package version ranges exclude current releases; setup script has stale Gleam version. Core syntax, FFI, Wisp, Lustre, and pattern matching are all correct. |
| **Completeness** | 4 | Excellent breadth: syntax, types, error handling, OTP, web (backend + frontend), FFI, testing, ecosystem, deployment (Dockerfile). Missing: `echo` keyword, LSP/editor tooling. Three substantial reference docs cover advanced patterns, web dev, and ecosystem in depth. |
| **Actionability** | 5 | Outstanding. Runnable code examples throughout. Three executable scripts (setup, scaffold, CI). Three ready-to-use assets (gleam.toml template, Wisp app template, Dockerfile). The wisp-app-template.gleam is a complete CRUD app with JSON encoding/decoding. |
| **Trigger quality** | 4 | Strong positive coverage of all Gleam-specific terms. Clear negative boundaries. Low false-trigger risk. |

**Overall: 4.0** (average of 3 + 4 + 5 + 4)

---

## e. GitHub Issues

No issues filed. Overall = 4.0 (not < 4.0) and no dimension ≤ 2.

---

## f. Recommended Fixes

1. **Update OTP examples** to use gleam_otp v1.2.0 builder pattern (`actor.new` / `actor.on_message` / `actor.start`) in SKILL.md and advanced-patterns.md.
2. **Update assets/gleam.toml** version ranges to include current major versions (gleam_json 3.x, gleam_http 4.x, wisp 2.x, mist 2.x).
3. **Update setup-gleam.sh** default `GLEAM_VERSION` to latest stable (1.14.0+).
4. **Add `echo` keyword** to SKILL.md Syntax Fundamentals or Common Patterns section.
5. **Verify supervisor API** against gleam_otp v1.2.0 and update if changed.

**Status: `needs-fix`** — Accuracy issues with outdated OTP API and package versions could cause compilation errors for users following the skill's examples.
