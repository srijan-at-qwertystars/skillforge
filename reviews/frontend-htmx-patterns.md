# Review: htmx-patterns

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

1. **hx-swap table missing `textContent`**: htmx 2.x added `textContent` as a valid hx-swap value (replaces text content without HTML parsing). The swap strategies table omits it.

2. **Pinned htmx version outdated**: SKILL.md and all assets pin `htmx.org@2.0.4` but the latest stable release is `2.0.7` (Sep 2025). CDN links still work, but an engineer may wonder if they're getting the latest.

3. **WebSocket/SSE section omits extension script includes**: The WS/SSE example uses `hx-ext="ws"` and `hx-ext="sse"` but doesn't show the required separate extension script tags (`htmx-ext-ws`, `htmx-ext-sse`). The base-template.html comments include these, but the SKILL.md section itself would mislead someone who only reads the main doc.

4. **`assets/htmx-tailwind-starter.html` not linked from SKILL.md**: The Assets table lists `base-template.html` and `component-library.html` but omits the Tailwind starter template that exists in the assets directory.

## Structure Assessment

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description includes positive triggers (htmx, hypermedia, HTML-over-the-wire, AJAX without JS, server-rendered UI, partial updates, specific patterns, framework integrations) AND negative triggers (NOT React/Vue/Angular, NOT JS frameworks, NOT REST API design, NOT static site generators)
- ✅ Body is 499 lines (under 500 limit — just barely)
- ✅ Imperative voice throughout, no filler
- ✅ Extensive examples with input/output (HTML markup, server responses, CSS)
- ✅ `references/`, `scripts/`, and `assets/` properly linked from SKILL.md with description tables

## Content Assessment

- Core HTTP attributes (hx-get/post/put/patch/delete): **Correct**
- Targeting (hx-target) with CSS/relative selectors: **Correct**
- Swap strategies and modifiers: **Correct** (minus missing `textContent`)
- Trigger modifiers (changed, once, delay, throttle, from, every, revealed, intersect, consume, queue): **All verified correct**
- Request headers (HX-Request, HX-Target, HX-Trigger, HX-Current-URL, etc.): **Correct**
- Response headers (HX-Trigger, HX-Redirect, HX-Refresh, HX-Push-Url, HX-Replace-Url, HX-Reswap, HX-Retarget, HX-Reselect, HX-Location): **Correct**
- OOB swaps, boosting, history, forms, validation, progressive enhancement: **Correct**
- Server integration patterns (Django/Flask/Express/Go/Rails): **Correct**
- Scripts are functional (scaffold generates valid project structures, dev server is well-structured)
- References provide excellent depth (advanced patterns, troubleshooting, server integration)

## Trigger Assessment

- Positive triggers cover broad surface: htmx, hypermedia, HTML-over-the-wire, AJAX without JS, specific patterns (infinite scroll, active search, click-to-edit, lazy loading), specific frameworks, WebSocket/SSE
- Negative triggers are clear and prevent false matches against SPA frameworks, REST API design, static site generators
- Would correctly trigger for: "add htmx to my Flask app", "build infinite scroll with htmx", "htmx click-to-edit pattern"
- Would correctly NOT trigger for: "build a React component", "design a REST API", "set up Next.js"

## Verdict: PASS
