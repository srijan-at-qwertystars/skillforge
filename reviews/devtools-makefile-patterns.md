# QA Review: makefile-patterns

**Skill path:** `~/skillforge/devtools/makefile-patterns/`
**Reviewer:** Copilot CLI automated QA
**Date:** 2025-07-14

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter has `name` | ✅ Pass | `makefile-patterns` |
| YAML frontmatter has `description` | ✅ Pass | Multi-line, detailed |
| Positive triggers in description | ✅ Pass | Makefile, GNU Make, build automation, targets, recipes, variables, pattern rules, phony targets, parallel builds, debugging, self-documenting |
| Negative triggers in description | ✅ Pass | CMake, Bazel/Buck, npm scripts, Just, Task, GitHub Actions, Jenkins |
| Body under 500 lines | ✅ Pass | 488 body lines (excluding frontmatter) |
| Imperative voice | ✅ Pass | "Use these inside recipes only", "Replace repetitive rules", "Declare targets", "Set the default target explicitly" |
| Examples with I/O | ✅ Pass | Most examples show input→output via inline comments (e.g., `# Result: OBJECTS = ...`, `# Output of \`make help\`:`) |
| `references/` linked from SKILL.md | ✅ Pass | Both `references/advanced-patterns.md` and `references/troubleshooting.md` are described in §Reference Documentation |
| `scripts/` linked from SKILL.md | ❌ **Fail** | The `## Scripts` section at line 498 is **empty** — no mention of `make-graph.sh`, `makefile-init.sh`, or `makefile-lint.sh`. All three exist but are undiscoverable. |
| `assets/templates/` linked from SKILL.md | ❌ **Fail** | No mention of `assets/templates/Makefile.{go,node,python,docker}` anywhere in SKILL.md. These rich templates are invisible to the LLM. |

### Structure verdict: **Mostly passing**, two linking gaps.

---

## b. Content Check — Accuracy Verification

All key Make syntax was verified against the GNU Make manual and authoritative sources.

| Claim | Verified | Notes |
|-------|----------|-------|
| Automatic variables `$@`, `$<`, `$^`, `$?`, `$*`, `$(@D)`, `$(@F)` | ✅ Correct | Definitions and example contexts all accurate per GNU Make manual |
| Variable assignment operators `=`, `:=`, `?=`, `+=` | ✅ Correct | Semantic descriptions match official docs |
| Pattern rules with `%` | ✅ Correct | Both regular and static pattern rules accurate |
| `.PHONY` explanation | ✅ Correct | "if a file named `clean` exists, `make clean` does nothing" — correct |
| `$(wildcard)`, `$(patsubst)`, `$(filter)`, `$(filter-out)` | ✅ Correct | Syntax and semantics accurate |
| `$(foreach)`, `$(shell)`, `$(call)` | ✅ Correct | |
| Substitution reference `$(SOURCES:src/%.c=build/%.o)` | ✅ Correct | Valid shorthand for `patsubst` |
| Conditional directives (`ifeq`, `ifdef`, `ifndef`, `ifneq`) | ✅ Correct | |
| `include` vs `-include` | ✅ Correct | |
| VPATH and `vpath` | ✅ Correct | Colon-separated for VPATH, pattern-specific for `vpath` |
| Order-only prerequisites `\|` syntax | ✅ Correct | |
| `.SUFFIXES:` to disable built-in rules | ✅ Correct | |
| `-Otarget` output sync | ✅ Correct | |
| `.NOTPARALLEL:` | ⚠️ Partially | SKILL.md says "Use `.NOTPARALLEL:` to disable parallelism for specific targets if needed" — this is **misleading**. Global `.NOTPARALLEL:` (no prereqs) disables all parallelism. Per-target `.NOTPARALLEL: target` only works in GNU Make ≥4.4. The text conflates the two. |
| Grouped targets `&:` (GNU Make 4.3+) | ✅ Correct | Correctly noted as 4.3+ in `references/advanced-patterns.md` |
| `.ONESHELL` | ✅ Correct | Global scope, `@`/`-`/`+` only first line, `$$` for shell vars — all noted. Version minimum (3.82) correct. |
| `.DELETE_ON_ERROR` | ✅ Correct | |
| `eval`/`call` escaping (`$$` → `$`, `$$$$` → `$$` → `$`) | ✅ Correct | |
| Self-documenting help target grep pattern | ✅ Correct | Standard community pattern |

### Missing gotchas

The "Key Anti-Patterns to Avoid" section is good but omits a few commonly-encountered gotchas:

1. **`.DELETE_ON_ERROR` not recommended in SKILL.md body** — It's mentioned as a feature but not in the anti-patterns list. The references recommend "Always include `.DELETE_ON_ERROR:`" but the main SKILL.md templates (inline) do not all include it.
2. **Stale timestamp issues** — No mention of `make` relying on filesystem timestamps and how NFS/containers/git-checkout can break this.
3. **`export` directive gotcha** — Bare `export` (after `include .env`) exports ALL Make variables to sub-processes, which can cause subtle bugs. Mentioned in the "Environment file loading" pattern but not flagged as potentially dangerous.

### Content verdict: **Highly accurate**, one minor inaccuracy (`.NOTPARALLEL` wording), a few omitted gotchas.

---

## c. Trigger Check

**Description text:**
> Guide for writing production-grade GNU Makefiles with correct syntax, automatic variables, pattern rules, functions, conditionals, and modern project templates. Use when user needs Makefile, GNU Make, build automation with make, Makefile targets, make recipes, make variables, pattern rules, phony targets, parallel builds, Makefile debugging, or self-documenting Makefiles. NOT for CMake, NOT for Bazel/Buck build systems, NOT for npm scripts or task runners like Just or Task, NOT for CI/CD pipeline configuration files like GitHub Actions or Jenkins.

| Aspect | Assessment |
|--------|------------|
| Trigger breadth | ✅ Good — covers most query formulations: "Makefile", "GNU Make", "make targets", "pattern rules", "phony targets", etc. |
| Negative triggers | ✅ Good — explicitly excludes CMake, Bazel, Buck, npm scripts, Just, Task, GitHub Actions, Jenkins |
| Missing positive triggers | ⚠️ Minor — Could add: "build system", "make dependency tracking", "make include", "makefile template", ".PHONY" |
| False positive risk | Low — "build automation with make" could technically match non-GNU-make contexts but the description is sufficiently specific |
| False negative risk | Low — the keyword coverage is thorough |
| Pushiness / specificity | ✅ Good — description is directive ("Guide for writing…", "Use when…") and specific |

### Trigger verdict: **Strong**. Minor additions possible but not critical.

---

## d. Scoring

| Dimension | Score (1–5) | Justification |
|-----------|-------------|---------------|
| **Accuracy** | 5 | All Make syntax verified correct. One minor `.NOTPARALLEL` imprecision in body text (not technically wrong, just imprecise). References are excellent. |
| **Completeness** | 4 | Comprehensive coverage of core Make + advanced patterns + troubleshooting + templates. Loses a point for: (1) empty Scripts section, (2) templates not linked, (3) missing a few gotchas (stale timestamps, `export` footgun). |
| **Actionability** | 5 | Excellent I/O examples, copy-paste templates, project-specific Makefiles (Go/Node/Python/Docker/C/C++), 3 utility scripts, comparison table vs alternatives. Very hands-on. |
| **Trigger quality** | 4 | Broad positive triggers, clear negative exclusions. Could benefit from a few more keywords ("build system", ".PHONY", "makefile template"). |

**Overall score: 4.5** (average of 5 + 4 + 5 + 4)

---

## e. Issues

Overall ≥ 4.0 and no dimension ≤ 2. **No GitHub issues required.**

### Recommended improvements (non-blocking)

1. **Populate the `## Scripts` section** in SKILL.md with descriptions/usage of:
   - `scripts/make-graph.sh` — Visualize Makefile dependency graph via Graphviz
   - `scripts/makefile-init.sh` — Generate Makefile templates (go/node/python/docker/c/cpp)
   - `scripts/makefile-lint.sh` — Lint Makefiles for common issues (tabs, .PHONY, directives)
2. **Add `## Templates` section** or mention `assets/templates/Makefile.{go,node,python,docker}` in the body so the LLM knows to use them.
3. **Clarify `.NOTPARALLEL` wording** at line 247 — note that per-target usage requires GNU Make ≥4.4.
4. **Add stale-timestamp gotcha** to the anti-patterns section (git checkout, NFS, containers).
5. **Add `export` footgun warning** near the "Environment file loading" pattern.

---

## f. Test Annotation

**Result: PASS** — appending `<!-- tested: pass -->` to SKILL.md.

---

*Review generated by Copilot CLI automated QA.*
