# QA Review: nuxt-framework

**Skill path:** `frontend/nuxt-framework/`  
**Reviewer:** Copilot CLI (automated)  
**Date:** 2025-07-17  
**Verdict:** ✅ PASS

---

## A. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ | `nuxt-framework` |
| YAML frontmatter `description` | ✅ | Detailed, covers scope comprehensively |
| Positive triggers in description | ✅ | 12+ trigger phrases: Nuxt app, Nuxt 3, Vue SSR, Nitro server, useFetch, useAsyncData, nuxt.config, NuxtHub, Nuxt Image, etc. |
| Negative triggers in description | ✅ | 3 exclusions: plain Vue SPA without SSR, React/Next.js, Nuxt 2 |
| Body under 500 lines | ✅ | 496 lines (4 lines under limit — tight but passes) |
| Imperative voice | ✅ | Consistent: "Always scaffold with", "Never manually import", "Use `useFetch`/`useAsyncData` in `<script setup>`" |
| Examples with I/O | ✅ | 4 worked examples (blog with Nuxt Content, auth middleware, Cloudflare D1 deploy, hybrid rendering) each with input prompt and output description |
| Resources properly linked | ✅ | 3 reference files, 3 scripts, 5 asset templates — all documented in tables with descriptions and relative links |

---

## B. Content Check — API Accuracy

### useFetch options
✅ **Accurate.** All documented options (`query`, `pick`, `transform`, `watch`, `lazy`, `server`, `immediate`, `default`, `dedupe`, `timeout`, `getCachedData`, `onRequest`, `onResponse`, `onRequestError`, `onResponseError`) verified against official Nuxt docs and community sources.

### useAsyncData behavior
✅ **Accurate.** Return signature `{ data, status, error, refresh, execute, clear }` confirmed. Status values `'idle' | 'pending' | 'success' | 'error'` match. Key/handler/options API correctly described.

### useState SSR behavior
✅ **Accurate.** Correctly states: (1) SSR-serialized automatically, (2) survives hydration, (3) values must be JSON-serializable, (4) same key shares state across components, (5) warns against plain `ref()` for shared state (leaks between SSR requests).

### routeRules for hybrid rendering
✅ **Accurate.** All rendering modes verified: `prerender: true` (SSG), `isr: <seconds>` (ISR), `swr: <seconds>` (SWR), `ssr: false` (SPA), `redirect` rules. The rendering mode table on line 325-332 is correct and clear.

### Nitro deployment presets
✅ **Accurate.** Presets `vercel`, `netlify`, `cloudflare-pages`, `cloudflare-module`, `node-server`, `bun` all valid. Note: Nitro docs have shifted toward underscore naming (`cloudflare_pages`) but hyphenated aliases still work. The deploy-preset.sh script correctly handles all four primary platforms.

### defineModel support
⚠️ **Not covered.** `defineModel` (Vue 3.4+, stable in Nuxt 3.10+) is not mentioned. This is a Vue-level feature rather than Nuxt-specific, and its omission is understandable in a Nuxt-focused skill. Not a blocking issue.

### Composable examples
✅ **Accurate.** The `composable-template.ts` demonstrates 5 patterns, all correctly implemented:
- Pattern 1 (SSR-safe state): Correct use of `useState` with `readonly` wrapper
- Pattern 2 (data fetching): Correct reactive URL with `useFetch` and `MaybeRef`
- Pattern 3 (client-only): Correct use of `import.meta.client` guard
- Pattern 4 (auth with cookies): Proper `useCookie` + `useState` combo
- Pattern 5 (form with validation): Clean generic composable pattern

### Other verified content
- **Server routes:** `defineEventHandler`, `getQuery`, `readBody`, `getRouterParam`, `createError` all correct
- **Middleware:** `defineNuxtRouteMiddleware`, `navigateTo`, `abortNavigation` correct
- **SEO:** `useSeoMeta` and `useHead` APIs accurately documented
- **Error handling:** `createError`, `showError`, `clearError` correctly described
- **Caching:** `defineCachedEventHandler` with `maxAge`, `staleMaxAge`, `swr` options correct
- **WebSocket:** `defineWebSocketHandler` under `nitro.experimental.websocket` confirmed

---

## C. Trigger Check

| Query | Should Trigger? | Would It? | Result |
|-------|----------------|-----------|--------|
| "Create a Nuxt 3 app with SSR" | Yes | ✅ Yes — matches "Nuxt 3", "Nuxt app" | ✅ |
| "How do I use useFetch in Nuxt?" | Yes | ✅ Yes — matches "useFetch" | ✅ |
| "Set up Nitro server routes" | Yes | ✅ Yes — matches "Nitro server" | ✅ |
| "Configure nuxt.config for ISR" | Yes | ✅ Yes — matches "nuxt.config" | ✅ |
| "Build a Vue SPA with Vite" | No | ✅ No — excluded by "NOT for plain Vue SPA without SSR" | ✅ |
| "Create a Next.js app with SSR" | No | ✅ No — excluded by "NOT for React/Next.js" | ✅ |
| "Migrate Nuxt 2 app to Nuxt 3" | Partial | ⚠️ Might trigger — "Nuxt 2" is excluded but "Nuxt 3" is a trigger | ⚠️ |
| "Use useAsyncData with Nuxt Content" | Yes | ✅ Yes — matches "useAsyncData", "Nuxt Content" | ✅ |
| "Deploy to Cloudflare Workers" | Yes | ✅ Yes — matches general Nuxt deployment context | ✅ |

**Trigger edge case:** A Nuxt 2→3 migration query could partially match. The skill doesn't cover migration steps, but the negative trigger "NOT for Nuxt 2" should prevent false activation. Acceptable tradeoff.

---

## D. Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5/5 | All APIs verified correct against official docs. No factual errors found in composable signatures, options, SSR behavior, routeRules, or deployment presets. |
| **Completeness** | 4/5 | Excellent coverage of core Nuxt 3 features with deep reference materials. Minor gaps: no `defineModel` mention, no Nuxt 4 forward-compat notes, no `useRequestURL` composable. Reference files fill most gaps well. |
| **Actionability** | 5/5 | Every section has runnable code. 4 worked examples with I/O. 3 shell scripts for scaffolding, hydration checking, and deployment. 5 copy-ready asset templates. Setup script creates a fully working project. |
| **Trigger quality** | 5/5 | Clear positive triggers (12+ phrases) covering all major Nuxt concepts. Clean negative triggers excluding Vue SPA, React/Next.js, and Nuxt 2. No overlap with sibling framework skills. |

### Overall: **4.75 / 5.0**

---

## Summary

This is a high-quality, production-ready skill. The SKILL.md body is dense with accurate, imperative guidance and stays just within the 500-line limit. Supporting materials (3 reference docs, 3 scripts, 5 asset templates) provide substantial depth. All Nuxt 3 APIs verified correct. The trigger description cleanly delineates scope.

### Minor recommendations (non-blocking)
1. Consider adding a brief `defineModel` note under a Vue 3.4+ features section
2. The 496-line body is very close to the limit — future additions may require trimming
3. The `cloudflare-pages` preset name could note the underscore alias (`cloudflare_pages`) for clarity
4. A Nuxt 2→3 migration pointer (even just a link) would help with edge-case queries
