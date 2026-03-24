# QA Review: zig-language

**Skill path:** `languages/zig-language/`
**Reviewed:** 2025-07-17
**Zig versions targeted:** 0.13 / 0.14

---

## a. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML `name` field | ✅ | `zig-language` |
| YAML `description` field | ✅ | Present, detailed |
| Positive triggers | ✅ | Comprehensive: .zig files, build.zig, allocators, comptime, error unions, @cImport, std.*, cross-compilation, etc. |
| Negative triggers | ✅ | "zig-zag" references, Apache ZIG, Zigbee protocol, non-programming uses |
| Body under 500 lines | ✅ | 455 lines |
| Imperative voice, no filler | ✅ | Concise, direct, well-structured |
| Examples with input/output | ✅ | Every section has runnable code examples with inline comments explaining results |
| References linked | ✅ | 3 reference docs properly linked (advanced-patterns, troubleshooting, c-interop-guide) |
| Scripts linked | ✅ | 3 scripts properly linked (init-project.sh, cross-compile.sh, benchmark.sh) |
| Assets linked | ✅ | 4 assets properly linked (build.zig, build.zig.zon, main.zig, Dockerfile) |

**Structure verdict:** Excellent. Clean layout, well-organized sections, proper linking.

---

## b. Content Accuracy Check

### Verified Accurate ✅

1. **comptime** — Correct syntax for blocks, generics via `comptime T: type`, compile-time evaluation. `@setEvalBranchQuota`, `@compileLog`, `@compileError` all accurate.
2. **Error unions** — `FileError![]u8`, `try`, `catch`, `errdefer` all syntactically correct for 0.14.
3. **Allocators** — `GeneralPurposeAllocator`, `ArenaAllocator`, `FixedBufferAllocator`, `page_allocator` APIs all accurate. `std.mem.Allocator` interface correct.
4. **build.zig** — `b.standardTargetOptions`, `b.standardOptimizeOption`, `b.addExecutable`, `b.path()`, `b.installArtifact`, `b.addRunArtifact` all correct for 0.14.
5. **build.zig.zon** — Correctly uses 0.14 bare-identifier `.name = .myproject` (not string), includes `.fingerprint` field. Format verified accurate.
6. **@typeInfo syntax** — Uses `.@"struct"` which is correct for 0.14 (tags were lowercased from `.Struct` to `.@"struct"` per style guide changes).
7. **C interop** — `@cImport`, `@cInclude`, `@cDefine`, `translate-c`, `extern struct`, C type mappings, `[*c]T` pointer type all accurate. Single-@cImport-block advice is correct.
8. **Labeled switch** — Correctly marked as 0.14+ feature. `sw: switch` / `continue :sw` / `break :sw` syntax verified.
9. **std library** — `std.mem.eql`, `std.fs.cwd().openFile`, `std.json.parseFromSlice`, `std.ArrayList`, `std.StringHashMap`, `std.Thread` all correct for 0.14.
10. **Cross-compilation** — Target triples and `-Dtarget` flag accurate.
11. **Async/await removal** — Correctly noted as removed (experimental). Advises `std.Thread` instead.
12. **Slices and arrays** — `[5]u8`, `[]const u8`, `[:0]const u8` syntax correct. String literals as `[]const u8` accurate.

### Minor Accuracy Concerns ⚠️

1. **GPA `deinit()` return type** — The skill uses `if (status == .leak)` (enum pattern). In Zig 0.14.0 the return may still be `bool` (with `true` = leak), though the enum form (`Check.leak`) was adopted around this timeframe. The pattern shown is the more modern/idiomatic form and works on recent 0.14.x builds. Low risk.

2. **Custom panic handler** (`references/advanced-patterns.md` line 464) — Uses `std.debug.FullPanic(...)` which is a 0.14-era API. This is correct but may surprise users on 0.13.

3. **`@branchHint`** — Listed in YAML triggers but never documented in the body or references. This is a 0.14 feature replacing `@setCold` for branch prediction hints. Should be covered since it's triggered on.

### Missing Content (not critical)

- **`@branchHint`** builtin (triggered but undocumented)
- **`DebugAllocator`** — New in 0.14, not mentioned (GPA is the closest documented equivalent)
- **`SmpAllocator`** — New multithreaded allocator in 0.14, not mentioned
- **ZON serialization/deserialization** — `std.zon` module new in 0.14, not covered
- **Incremental compilation** — Major 0.14 feature, not mentioned (arguably a tooling feature, not a language skill topic)

---

## c. Trigger Check

| Aspect | Status | Notes |
|---|---|---|
| Zig source files (.zig) | ✅ | Covered |
| Build files (build.zig, build.zig.zon) | ✅ | Covered |
| CLI commands (zig build, zig test, zig run) | ✅ | Covered |
| Key builtins (@cImport, @cInclude, @typeInfo, @Type) | ✅ | Covered |
| Allocator types | ✅ | All major allocators listed |
| Language comparisons (vs C/Rust/Go) | ✅ | Covered |
| False positive prevention | ✅ | Zigbee, zig-zag, Apache ZIG excluded |
| `@branchHint` trigger without body coverage | ⚠️ | Trigger-body mismatch |

**Trigger verdict:** Strong. Comprehensive positive triggers with well-defined exclusions. One minor trigger-body gap on `@branchHint`.

---

## d. Scores

| Dimension | Score | Justification |
|---|---|---|
| **Accuracy** | 4 | Core language features, build system, std library, and C interop all verified accurate for 0.14. Minor uncertainty on GPA deinit return type. @typeInfo syntax correctly updated. |
| **Completeness** | 4 | Thorough coverage of core Zig: types, errors, structs, comptime, memory, testing, C interop, build system, packages, cross-compilation, concurrency. References add depth on advanced patterns, troubleshooting, and C interop. Missing `@branchHint`, new 0.14 allocators, and ZON serialization. |
| **Actionability** | 5 | Every section has runnable code examples. Scripts (init-project, cross-compile, benchmark) are production-quality with arg parsing, validation, and colored output. Assets provide ready-to-use templates including Dockerfile. Common pitfalls section is excellent. |
| **Trigger quality** | 4 | Well-scoped positive triggers covering files, commands, builtins, allocators, and comparison contexts. Negative triggers prevent false positives on non-Zig uses. One triggered keyword (`@branchHint`) lacks body coverage. |

**Overall: 4.25** (average of 4 + 4 + 5 + 4)

---

## e. Issue Filing

Overall ≥ 4.0 and no dimension ≤ 2. **No issues filed.**

### Recommendations for future improvement (non-blocking):

1. Add a section on `@branchHint` since it's listed in triggers — even a brief example would close the gap.
2. Mention `DebugAllocator` and `SmpAllocator` in the allocator section or in advanced-patterns reference.
3. Add ZON serialization coverage (`std.zon.parse`, `std.zon.stringify`) — increasingly important in 0.14+ ecosystem.
4. Clarify GPA `deinit()` return type with a version note if supporting both 0.13 and 0.14.

---

## f. Result

**PASS** ✅

Review file: `~/skillforge/reviews/languages-zig-language.md`
