# QA Review: devtools/jq-patterns

**Reviewer:** Copilot CLI  
**Date:** 2025-07-16  
**Skill path:** `~/skillforge/devtools/jq-patterns/`

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `jq-patterns` |
| YAML frontmatter `description` | ✅ Pass | Multi-line, detailed |
| Positive triggers | ✅ Pass | 8 trigger phrases: jq JSON processing, command-line JSON manipulation, JSON transformation, filtering JSON data, parsing API responses, extracting fields, reshaping structures, writing jq expressions |
| Negative triggers | ✅ Pass | 5 exclusions: Python json, JS JSON.parse, JSON Schema, YAML/yq, XML/xq, database queries |
| Body under 500 lines | ✅ Pass | 483 lines (just under limit) |
| Imperative voice | ✅ Pass | "Guide for…", "Use when…" |
| Examples with I/O | ✅ Pass | Nearly every code block shows input → output in comments |
| References linked from SKILL.md | ✅ Pass | 3 references, 3 scripts, 3 assets — all linked in tables at end |

**Structure verdict:** All structural criteria met.

---

## b. Content Check

### Verified Correct

- **Basic filters** (`.`, `.name`, `.[]`, slicing, `length`): All correct.
- **`@base64`/`@base64d`**: `echo '"hello"' | jq '@base64'` → `"aGVsbG8="` ✓
- **`@uri`**: `echo '"a b&c=d"' | jq '@uri'` → `"a%20b%26c%3Dd"` ✓
- **`--stream` / `tostream` / `fromstream` / `truncate_stream`**: Syntax and usage patterns verified against jq manual and community docs. Correct.
- **`walk`**: Correctly noted as "Available in jq 1.6+ (built-in)" with manual definition fallback.
- **`INDEX` single-arg form**: `INDEX(.id)` usage is correct (jq 1.6+).
- **`reduce`, `group_by`, `sort_by`, `select`**: All examples syntactically correct.
- **CLI flags**: `--arg`, `--argjson`, `--slurpfile`, `--rawfile`, `-e`, `-j`, `--tab`, `-S`, `--indent` — all accurate.
- **String interpolation** `\()` syntax: Correct.
- **`if-then-else` requires `else`**: Correctly documented.
- **Security guidance**: `--arg` for injection prevention — excellent coverage in troubleshooting and shell-integration docs.

### Issues Found

1. **Missing `@sh` format string** (Minor gap)  
   SKILL.md §Format Strings (line 203) lists `@base64, @uri, @html, @csv, @tsv` but omits `@sh` — a commonly used format string for shell escaping. The cheatsheet also omits `@sh` from its format strings table. Given the skill's heavy shell-integration focus, this is a notable omission.

2. **`--stream` output escaping** (Cosmetic)  
   `references/advanced-patterns.md` line 34-38 shows streaming output with escaped quotes (`[[\"a\"],1]`). Actual `jq -c --stream` output uses unescaped JSON (`[["a"],1]`). This is a display/readability issue only.

3. **`.b?` example pedagogy** (Nitpick)  
   SKILL.md line 29: `.b?` on `{"a":1}` → `null (no error)`. Technically correct, but `.b` (without `?`) on an object also returns `null` without error. The `?` operator is more meaningful for type-mismatch suppression (e.g., `.b?` on a number). Could add a clarifying note.

4. **Missing `-R` / `--raw-input` from main SKILL.md CLI Options section**  
   The cheatsheet covers it, but the main SKILL.md §CLI Options omits `-R`, which is useful for processing non-JSON line input.

5. **Missing `-C` / `--color-output` from CLI Options and cheatsheet flags table**  
   Only appears in one-liners.md. Useful flag for terminal usage.

### Missing Gotchas (Suggestions)

- **`sponge` alternative** for in-place editing (mentioned only in shell-integration, not main SKILL.md).
- **`--jsonargs` / `--args`** only in cheatsheet, not main SKILL.md CLI Options.
- **macOS ships old jq** (often 1.6 via Homebrew, sometimes older). A version compatibility note would help.
- No mention of **`jq -f filter.jq`** in the main SKILL.md (it's in troubleshooting under "Compilation Tips").

---

## c. Trigger Check

| Aspect | Assessment |
|--------|------------|
| Description specificity | Good — clearly identifies jq command-line tool |
| Positive trigger coverage | Strong — 8 distinct trigger phrases |
| Negative trigger clarity | Excellent — 5 explicit NOT clauses with alternatives |
| False positive risk | Low — Python/JS JSON, YAML, XML, DB queries excluded |
| False negative risk | Low-Medium — could add "pipe JSON", "jq one-liner", "format JSON output", "pretty print JSON" as additional triggers |
| Pushy enough? | Yes — description is detailed and action-oriented |

**Trigger verdict:** Solid trigger design. Minor expansion opportunities for edge-case queries.

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All jq syntax, builtins, CLI flags verified correct. No wrong examples found. Streaming output escaping is cosmetic only. |
| **Completeness** | 4 | Exceptionally thorough (4600+ lines across all files). Missing `@sh` format string is a real gap. Minor omissions of `-R`, `-C` flags in main doc. References and assets fill most gaps. |
| **Actionability** | 5 | Outstanding. Copy-paste examples with I/O throughout. 73 cookbook recipes, 107 one-liners, 3 functional scripts, shell function library. Real-world DevOps recipes (K8s, Terraform, AWS, Docker, GitHub API). |
| **Trigger quality** | 4 | Well-designed positive+negative triggers. Could expand positive triggers slightly for edge cases. |
| **Overall** | **4.5** | High-quality, production-ready skill |

---

## e. Issue Filing

**Overall score 4.5 ≥ 4.0** and **no dimension ≤ 2** → No GitHub issues required.

---

## f. SKILL.md Annotation

`<!-- tested: pass -->` appended to SKILL.md.

---

## Summary

This is an excellent skill. The jq-patterns skill provides comprehensive, accurate, and highly actionable guidance for jq command-line JSON processing. The main SKILL.md stays within the 500-line limit while covering all essential topics, and the supporting references (advanced patterns, troubleshooting, cookbook) plus assets (cheatsheet, one-liners, shell integration) provide exceptional depth. The three utility scripts are well-implemented and documented.

**Recommended improvements (non-blocking):**
1. Add `@sh` to the Format Strings section in SKILL.md and cheatsheet
2. Add `-R` and `-C` flags to the CLI Options section
3. Clarify the `.b?` example with a type-mismatch case
4. Fix escaped quotes in streaming output example
5. Consider adding a jq version compatibility note
