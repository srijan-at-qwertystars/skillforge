# QA Review: biome-toolchain

**Skill path:** `~/skillforge/devtools/biome-toolchain/`
**Reviewed:** 2025-07-18
**Reviewer:** Copilot CLI (automated QA)

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter (`name`, `description`) | ✅ Pass | `name: biome-toolchain`, multi-line `description` present |
| Positive triggers | ✅ Pass | 12+ trigger phrases: biome linting, formatting, biome.json, migration, CI/CD, VS Code, GritQL, monorepo, etc. |
| Negative triggers | ✅ Pass | ESLint-only, Prettier-only, Ruff, Go/Rust linters, Stylelint, Markdown/YAML linting excluded |
| Body under 500 lines | ✅ Pass | 492 lines (`wc -l`) — 8 lines of headroom |
| Imperative voice | ✅ Pass | Commands use imperative ("Place `biome.json`…", "Use `--save-exact`…", "Install…", "Run…") |
| Examples present | ✅ Pass | Extensive code blocks: config snippets, CLI commands, CI YAML, GritQL patterns, package.json |
| References/scripts linked | ✅ Pass | All 3 references + 2 scripts + 3 templates linked with relative paths and described in tables |

**Files inventory:**

| File | Lines | Purpose |
|------|-------|---------|
| `SKILL.md` | 492 | Main skill body |
| `references/api-reference.md` | 759 | Full biome.json schema, rules, CLI flags, exit codes |
| `references/advanced-patterns.md` | 733 | Rule customization, GritQL, monorepo, assist, imports |
| `references/troubleshooting.md` | 601 | Parse errors, migration issues, CI failures, editor problems |
| `scripts/init-biome.sh` | 337 | Project setup (standard/strict/react modes) |
| `scripts/lint-check.sh` | 163 | Multi-mode check runner |
| `assets/biome.react.template.jsonc` | 229 | React/Next.js config template |
| `assets/biome.strict.template.jsonc` | 233 | Strict TypeScript config template |
| `assets/ci-workflow.template.yml` | 66 | GitHub Actions workflow template |

---

## B. Content Check

### Verified Against Official Docs & Web Sources

| Item | Verified | Notes |
|------|----------|-------|
| `biome check / lint / format / ci` commands | ✅ Correct | All four core commands accurate |
| `--write`, `--unsafe`, `--staged`, `--changed` flags | ✅ Correct | Flag names and behavior match official CLI docs |
| `biome migrate eslint --write` | ✅ Correct | Matches official migration guide |
| `biome migrate prettier --write` | ✅ Correct | Matches official migration guide |
| `biome search` (GritQL) | ✅ Correct | Experimental command, syntax accurate |
| `biome init` | ✅ Correct | Mentioned in installation section |
| Rule categories (suspicious, correctness, style, complexity, a11y, performance, security, nursery) | ✅ Correct | All 8 categories verified |
| Rule names (`noDebugger`, `noDoubleEquals`, `useConst`, `noExplicitAny`, etc.) | ✅ Correct | Spot-checked 15+ rules — all valid |
| Biome v2 domains (`react`, `next`, `solid`, `test`) | ✅ Correct | Matches official v2 beta docs |
| `assist.actions.source.organizeImports` (v2 syntax) | ✅ Correct | Properly documented in advanced-patterns and templates |
| Import group tokens (`:NODE:`, `:PACKAGE:`, `:BLANK_LINE:`) | ✅ Correct | Verified against official docs |
| `biomejs/setup-biome@v2` action | ✅ Correct | Current GitHub Action version |
| `--reporter=github` flag | ✅ Correct | Produces GitHub annotations |
| Exit codes (0, 1, 2) | ✅ Correct | Matches official docs |
| GritQL plugin syntax (`register_diagnostic`, `$variable`, backtick patterns) | ✅ Correct | Matches Biome plugin docs |
| `biome-ignore` / `biome-ignore-start` / `biome-ignore-end` suppression | ✅ Correct | Range suppression is valid v2 syntax |

### Issues Found

| # | Severity | Description |
|---|----------|-------------|
| 1 | **Minor** | **Inconsistent `organizeImports` syntax in main example (line 47):** Uses v1 syntax `"organizeImports": { "enabled": true }` while the rest of the doc (and templates) use v2 `assist.actions.source.organizeImports`. Should use v2 syntax for consistency since the schema is pinned to 2.2.7. |
| 2 | **Minor** | **`node` domain listed but unconfirmed:** Advanced-patterns.md lists `node` as an available domain alongside react/next/solid/test. Official docs only confirm the first four; `node` may be planned but not yet GA. Add caveat or remove. |
| 3 | **Minor** | **Missing migration gotcha — YAML ESLint configs:** The `biome migrate eslint` command does not support YAML-format ESLint configs (`.eslintrc.yml`/`.yaml`). Only JSON and JS configs are migrated. The troubleshooting guide should mention this. |
| 4 | **Minor** | **Missing migration gotcha — overwrite risk:** Running `biome migrate eslint --write` then `biome migrate prettier --write` can overwrite settings from the first migration. Should warn to review merged config. |
| 5 | **Nitpick** | **Missing `biome explain <rule>` command:** Useful for looking up rule docs from CLI. Not mentioned anywhere. |
| 6 | **Nitpick** | **Missing `biome rage` command:** Useful for debugging; generates diagnostic info for bug reports. |

### Missing Gotchas (not critical but would improve completeness)

- Biome does not support `eslint-disable` inline comments — migration does not auto-convert them (partially covered in troubleshooting, but should be more prominent in SKILL.md migration section)
- Biome has limited Vue/Svelte/Astro support (embedded JS only) — covered in troubleshooting but could be mentioned in SKILL.md CSS/JSON/GraphQL section
- `--apply` is an alternative alias for `--write` in some contexts (minor)

---

## C. Trigger Check

### Description Analysis

The description field (lines 3-4) is **well-crafted** with strong trigger coverage:

**Strengths:**
- Mentions tool by current name ("Biome") and former name ("formerly Rome")
- Covers primary use cases: linting, formatting, config, migration, CI/CD, editor setup
- Includes specific CLI commands as triggers (`biome check/lint/format/ci`)
- Mentions GritQL and monorepo — advanced differentiators
- Explicit negative triggers prevent false activation on competing tools

**Potential gaps:**
- Missing "Rome" as a standalone trigger word (only "formerly Rome" in parenthetical)
- Could add "import sorting" as explicit positive trigger (only says "organizing imports")
- No mention of "code quality" as a trigger phrase

### False Trigger Risk: **Low**

The negative triggers are specific and comprehensive. The only edge case: a user asking about "Vite config" or "webpack config" in general might weakly match "biome in CI/CD" phrasing, but this is unlikely to trigger given the description specificity.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 / 5 | All CLI commands, rule names, config options verified correct. Minor v1/v2 syntax inconsistency in main example. `node` domain status uncertain. |
| **Completeness** | 4 / 5 | Excellent breadth: install → config → CLI → migration → CI → monorepo → GritQL → editor. Missing a few migration gotchas and CLI commands (`explain`, `rage`). Reference docs are thorough. |
| **Actionability** | 5 / 5 | Outstanding. Copy-paste config snippets, ready-to-use shell scripts, CI templates, VS Code settings, package.json scripts. Init script handles three project modes with auto-migration. |
| **Trigger Quality** | 4 / 5 | Strong positive and negative triggers. Good "formerly Rome" mention. Minor gaps: standalone "Rome" trigger, "import sorting" as explicit phrase. Low false-trigger risk. |
| **Overall** | **4.25 / 5** | High-quality skill. Production-ready with minor polish needed. |

---

## E. GitHub Issues

**No issues filed.** Overall score 4.25 ≥ 4.0 and no dimension ≤ 2.

**Recommended improvements (non-blocking):**
1. Fix `organizeImports` v1→v2 syntax inconsistency in main config example
2. Add YAML ESLint config migration caveat to troubleshooting
3. Add `biome explain` and `biome rage` to CLI commands section
4. Clarify `node` domain availability status

---

## F. Test Status

**Result: PASS**

The skill is accurate, comprehensive, and highly actionable. The issues found are minor and do not affect usability. All CLI commands, rule names, config structures, and migration workflows verified against official Biome documentation and current web sources.
