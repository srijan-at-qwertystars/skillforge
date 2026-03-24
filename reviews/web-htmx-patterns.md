# QA Review: htmx-patterns

**Skill path:** `web/htmx-patterns/`
**Reviewed:** 2025-07-17
**Reviewer:** Copilot QA

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `htmx-patterns` |
| YAML `description` positive triggers | ✅ | Covers hx-get/post/put/patch/delete, hx-swap, hx-target, hx-trigger, OOB, extensions, backends |
| YAML `description` negative triggers | ✅ | Excludes React, Vue, Angular, Svelte, SPA frameworks, general JS DOM, REST without htmx |
| Body under 500 lines | ✅ | 480 lines |
| Imperative voice | ✅ | "Return HTML", "Use progressive enhancement", "Specify where…" |
| No filler | ✅ | Dense, practical content throughout |
| Examples with I/O | ✅ | HTML input + server response patterns across multiple languages |
| Links to refs/scripts/assets | ✅ | All 3 reference docs, 3 scripts, 4 assets linked and described |

**Verdict:** Passes all structure checks.

---

## b. Content Check (Web-Verified)

### Core attributes — ✅ Accurate
- `hx-get`, `hx-post`, `hx-put`, `hx-patch`, `hx-delete`: correct usage and semantics.
- `hx-target` special values (`this`, `closest`, `find`, `next`, `previous`): confirmed correct.
- `hx-trigger` modifiers (`once`, `changed`, `delay`, `throttle`, `from`, `target`, `consume`, `queue`): all accurate.

### Swap strategies — ✅ Accurate
All 8 strategies listed are correct: `innerHTML` (default), `outerHTML`, `beforebegin`, `afterbegin`, `beforeend`, `afterend`, `delete`, `none`. Swap modifiers (`swap:`, `settle:`, `scroll:`, `show:`, `transition:true`, `focus-scroll:`) are accurate.

### Request headers — ✅ Accurate
`HX-Request`, `HX-Target`, `HX-Trigger`, `HX-Trigger-Name`, `HX-Boosted`, `HX-Current-URL`, `HX-Prompt` — all confirmed correct.

### Response headers — ✅ Mostly accurate
All listed headers are correct. **Minor omission:** `HX-Location` (AJAX-style redirect) and `HX-Reselect` (server-side hx-select override) are not mentioned. These are less commonly used but exist in htmx 2.x.

### htmx 2.x breaking changes — ✅ Accurate
- `hx-delete` sends params as query strings: correctly documented.
- `hx-on:` colon syntax required: correctly documented.
- Double-colon shorthand `hx-on::` for htmx-namespaced events: correctly explained in troubleshooting.md.

### Extension names — ⚠️ Minor inaccuracy
The extensions table lists `morph` as an extension. In htmx 2.x, the official morphing extension is named **`idiomorph`** (not `morph`). The `hx-ext` value should be `idiomorph`. All other extension names (`sse`, `ws`, `json-enc`, `multi-swap`, `head-support`, `preload`) are correct.

### Missing gotchas
- `htmx.config.scrollBehavior` default changed from `'smooth'` to `'instant'` in 2.x — not mentioned.
- IE support dropped in 2.x — not mentioned (minor, as IE is largely irrelevant).
- `htmx-1-compat` extension for migration not mentioned.

---

## c. Trigger Check

| Concern | Status | Notes |
|---------|--------|-------|
| Positive triggers cover htmx use cases | ✅ | Comprehensive: attributes, patterns, extensions, backends |
| Negative triggers exclude SPA frameworks | ✅ | React, Vue, Angular, Svelte explicitly excluded |
| False positive risk for React/Vue/Angular | ✅ None | Clear negative triggers; no overlap keywords |
| False positive for generic JS DOM | ✅ None | Explicitly excluded "general JavaScript DOM manipulation" |
| False positive for REST API design | ✅ None | Only excluded "without htmx context" |

**Verdict:** Trigger description is well-crafted with minimal false-positive risk.

---

## d. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Nearly perfect. `morph` → `idiomorph` naming error, missing `HX-Location`/`HX-Reselect` headers. All other attributes, strategies, headers, and 2.x changes are correct. |
| **Completeness** | 4 | Exceptional breadth: 4 backends, 12 UI components, troubleshooting, scripts, assets. Minor gaps: `HX-Location`, `HX-Reselect`, `idiomorph` naming, `scrollBehavior` default change. |
| **Actionability** | 5 | Outstanding. Copy-paste HTML components, production-ready server templates (Express, Django), project scaffolding script, analysis tool, component generator. Immediately usable. |
| **Trigger quality** | 5 | Precise positive triggers with comprehensive htmx vocabulary. Clean negative triggers prevent SPA framework false positives. |

### **Overall: 4.5 / 5**

---

## e. Issues

Overall ≥ 4.0 and no dimension ≤ 2. **No GitHub issues required.**

### Recommended improvements (non-blocking)
1. Rename `morph` to `idiomorph` in the extensions table (SKILL.md line 267).
2. Add `HX-Location` and `HX-Reselect` to the response headers table.
3. Add note about `scrollBehavior` default change (`'smooth'` → `'instant'`) in 2.x changes.

---

## f. Test Status

**Result: PASS** ✅
