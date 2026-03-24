# QA Review: sass-patterns

**Skill path:** `~/skillforge/frontend/sass-patterns/`
**Reviewer:** Copilot CLI (automated QA)
**Date:** 2025-07-18

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `name: sass-patterns` present |
| YAML frontmatter `description` | ✅ Pass | Comprehensive multi-line description |
| Positive triggers | ✅ Pass | 15+ positive trigger phrases (Sass, SCSS, @use, @forward, mixins, maps, design tokens, etc.) |
| Negative triggers | ✅ Pass | 5 explicit NOT-for clauses (plain CSS, CSS-in-JS, Tailwind, Less/Stylus, vanilla PostCSS) |
| Body under 500 lines | ✅ Pass | SKILL.md is 494 lines (just under limit — tight but compliant) |
| Imperative voice | ✅ Pass | "Always use Dart Sass", "Use @use/@forward exclusively", "Never @import", "Prefer %placeholder" |
| Examples with I/O | ✅ Pass | Most code blocks include INPUT/OUTPUT annotations or inline comments showing results |
| Resources properly linked | ✅ Pass | Supplemental Files section correctly lists all 3 references, 3 scripts, 5 assets with descriptions |

**Structure verdict:** All criteria met.

---

## B. Content Check — Technical Accuracy

### @use / @forward Syntax — ✅ Accurate
- `@use` with namespace, `as` alias, and `as *` glob — all correct per official docs.
- `@forward` with `show`/`hide` — correct.
- `@use ... with ()` for module configuration — correct.
- Ordering constraint (`@use` must precede other rules) — correctly documented in troubleshooting.

### @import Deprecation — ⚠️ Minor Inaccuracy
- **SKILL.md states:** "@import is deprecated and removed in Dart Sass 3.0."
- **Actual:** @import was deprecated in Dart Sass 1.80.0 (Oct 2024). Removal is planned for Dart Sass 3.0, which will ship **no earlier than October 2026** — not yet released. The phrasing "removed in Dart Sass 3.0" reads as if it has already happened. Should say "will be removed in Dart Sass 3.0."
- **Severity:** Low — the guidance to use @use/@forward is correct, just the tense is slightly misleading.

### Built-in Module Functions — ✅ Accurate
- `math.div()`, `math.round()`, `math.clamp()`, `math.pow()` — all correct signatures.
- `color.adjust()`, `color.scale()`, `color.change()`, `color.mix()` — correct per sass-lang.com.
- `meta.load-css()` — correctly described as a mixin (`@include meta.load-css()`), with `$with` parameter.
- `meta.type-of()`, `meta.get-function()`, `meta.call()` — correct.
- `map.deep-merge()` (Dart Sass 1.27+) — correct.
- `string.split()` (Dart Sass 1.57+) — correct with version annotation.
- Color Space functions (1.80+) — `color.to-space()`, `color.same()`, `color.is-legacy()`, `color.space()` — correct.
- The api-reference.md is comprehensive and accurate for all 7 built-in modules.

### Migration Renames — ✅ Accurate
- `lighten($c, 10%)` → `color.adjust($c, $lightness: 10%)` — correct.
- `map-get()` → `map.get()` — correct.
- `type-of()` → `meta.type-of()` — correct.
- `percentage()` → `math.percentage()` — correct.

### Stylelint Configuration — ⚠️ Minor Issue
- `stylelint-config-standard-scss` + `stylelint-order` — correct and current packages.
- **`stylelint-config-prettier-scss`** referenced in `lint-setup.sh` (`--with-prettier` flag) — this package is **effectively deprecated** as of Stylelint v15, which removed stylistic rules. The script should note this or recommend against it for Stylelint v15+.
- `scss/no-global-function-names: true` — valid rule.
- `scss/at-import-no-partial-leading-underscore` — valid rule.
- `selector-class-pattern` BEM regex — valid and correctly matches `block__element--modifier`.
- `declaration-no-important` — valid rule name and config.
- Property ordering groups — sensible and correct `stylelint-order` syntax.
- **Severity:** Low — the `--with-prettier` path in lint-setup.sh is the only concern and it's behind an opt-in flag.

### Vite Configuration — ✅ Accurate
- `api: 'modern-compiler'` — correct for Vite 5.4+. Correctly noted as default in Vite 7+.
- `sass-embedded` recommendation — correct.
- `additionalData` with `@use` injection — correct pattern.
- `silenceDeprecations: ['import']` — correct option name.
- `loadPaths` — correct option.
- `cssMinify: 'lightningcss'` — valid Vite option.
- `NodePackageImporter` mention in comments — correct and current.

### Webpack Configuration — ✅ Accurate
- `sass-loader` with `implementation: require('sass-embedded')` and `api: 'modern-compiler'` — correct.

### Advanced Patterns — ✅ Accurate
- `meta.load-css()` scoping pattern — correct caveats (no `&`, independent evaluation).
- `@at-root (without: media)` — correct syntax.
- `selector.unify()` — correct usage.
- `map.deep-merge()` recursive behavior — correctly described.
- `@content` with named arguments (`using` keyword) — correct (Dart Sass 1.15+).
- Container query mixin syntax — correct CSS spec.

### Troubleshooting — ✅ Accurate
- "This module was already loaded" error explanation — correct.
- Circular dependency resolution strategy — correct.
- `!default` vs `!global` semantics — correct.
- LibSass feature comparison table — correct (LibSass EOL noted).
- `devSourcemap` for Vite — correct option name.

---

## C. Trigger Check

| Query | Should Trigger? | Would Trigger? | Verdict |
|-------|----------------|----------------|---------|
| "How do I write a Sass mixin?" | Yes | ✅ Yes — matches "Sass mixins" | Pass |
| "SCSS variables and nesting" | Yes | ✅ Yes — matches "Sass variables", "Sass nesting" | Pass |
| "How to use @use and @forward in Sass" | Yes | ✅ Yes — matches "@use", "@forward", "Sass modules" | Pass |
| "Sass color functions" | Yes | ✅ Yes — explicit trigger | Pass |
| "Design tokens with SCSS maps" | Yes | ✅ Yes — explicit trigger | Pass |
| "sass-embedded Vite setup" | Yes | ✅ Yes — matches "sass-embedded" | Pass |
| "BEM naming in Sass" | Yes | ✅ Yes — matches "BEM Sass" | Pass |
| "Responsive mixins SCSS" | Yes | ✅ Yes — explicit trigger | Pass |
| "CSS flexbox layout" | No | ✅ No — plain CSS, no Sass keywords | Pass |
| "styled-components theme" | No | ✅ No — explicit NOT for CSS-in-JS | Pass |
| "Tailwind utility classes" | No | ✅ No — explicit NOT for Tailwind | Pass |
| "Less variables and mixins" | No | ✅ No — explicit NOT for Less/Stylus | Pass |
| "PostCSS autoprefixer setup" | No | ✅ No — explicit NOT for vanilla PostCSS | Pass |
| "CSS custom properties" | Borderline | ⚠️ Maybe — skill covers CSS custom props integration with Sass but shouldn't trigger for pure CSS custom props | Acceptable |

**Trigger verdict:** Strong positive and negative trigger coverage. Only borderline case (CSS custom properties) is correctly handled by the description focusing on "CSS custom properties integration" in Sass context.

---

## D. Scores (1–5)

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All Dart Sass APIs verified correct. @import deprecation tense is minor. Built-in module docs match official sass-lang.com. Vite/webpack configs are current and correct. |
| **Completeness** | 5 | Covers the full Sass ecosystem: module system, all 7 built-in modules, control flow, BEM, design tokens, responsive patterns, dark mode, animations, container queries, build tools (Vite + webpack), stylelint, migration. Three reference docs, three scripts, five assets. |
| **Actionability** | 5 | Copy-paste code examples with I/O throughout. Ready-to-use scripts (migrate, lint, analyze). Production-grade asset files (stylelint config, Vite config, design tokens, responsive mixins, BEM component template). Clear imperative rules section. |
| **Trigger Quality** | 4 | 15+ positive triggers cover key Sass terminology well. 5 negative triggers clearly exclude CSS-in-JS, Tailwind, Less/Stylus, PostCSS. Slight gap: could add "node-sass migration" or "LibSass to Dart Sass" as explicit triggers since the content covers it extensively. |

**Overall Score: 4.75 / 5.0**

---

## E. Issues Found

1. **Low — @import tense:** SKILL.md line 25 says "removed in Dart Sass 3.0" (present tense). Should say "will be removed" since Dart Sass 3.0 has not shipped yet (earliest Oct 2026).
2. **Low — `stylelint-config-prettier-scss` deprecated:** `lint-setup.sh` offers `--with-prettier` which installs this package. It's effectively obsolete for Stylelint v15+ (stylistic rules removed). Should add a note or warn users.
3. **Suggestion — Trigger expansion:** Consider adding "node-sass migration", "LibSass migration" as positive triggers.

---

## F. Verdict

**Overall: 4.75 — PASS** ✅

No dimension ≤ 2. Overall ≥ 4.0. No GitHub issues required.

All findings are low-severity suggestions that do not warrant blocking issues.
