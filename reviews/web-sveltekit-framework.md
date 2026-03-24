# QA Review: sveltekit-framework

**Skill path:** `web/sveltekit-framework/`
**Reviewed:** $(date -u +%Y-%m-%d)
**Verdict:** ✅ PASS

---

## a. Structure

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter | ✅ | `name` + `description` with USE/DO NOT USE triggers |
| Body length | ✅ | 495 lines (under 500 limit) |
| Imperative tone | ✅ | "Scaffold with…", "Always use runes", "Never use legacy…" |
| Code examples | ✅ | Every section has concrete, copy-paste-ready examples |
| Links to refs/scripts/assets | ✅ | Tables at bottom link all reference, script, and asset files |

**Supporting files reviewed:**
- `references/advanced-patterns.md` (523 lines) — runes deep dive, snippets, streaming, shallow routing, SSE, WebSockets
- `references/troubleshooting.md` (593 lines) — hydration, SSR, adapter-specific, env vars, cookies, prerendering, deployment
- `references/migration-guide.md` (630 lines) — Svelte 4→5 and SvelteKit 1→2 with before/after examples, codemods
- `scripts/setup-project.sh` — project scaffolding with Tailwind, TS, Vitest, Playwright
- `scripts/create-route.sh` — route file generation with multiple flags
- `scripts/check-routes.sh` — route tree analysis and conflict detection
- `assets/svelte.config.js` — production config with CSP, aliases, prerender options
- `assets/route-template.svelte` — full page template with forms, SEO, streaming
- `assets/hooks.server.ts` — production hooks: auth, rate limiting, logging, security headers
- `assets/docker-compose.yml` — dev environment with PostgreSQL, Redis, Adminer, Mailpit

---

## b. Content Accuracy (web-verified)

### SvelteKit 2.x APIs ✅

| API/Feature | Skill Content | Verified |
|-------------|--------------|----------|
| `npx sv create` | Correct — current official Svelte CLI | ✅ |
| `vitePreprocess` import | `from '@sveltejs/vite-plugin-svelte'` — correct for SK2 | ✅ |
| Load functions | +page.ts (universal), +page.server.ts (server-only) — correct | ✅ |
| `$types` auto-generated types | PageLoad, PageServerLoad from `./$types` — correct | ✅ |
| Form actions | `actions` export, `fail()`, `use:enhance` — correct | ✅ |
| `$app/state` | Uses `page` from `$app/state` (not deprecated `$app/stores`) | ✅ |
| Hooks | `Handle`, `HandleFetch`, `HandleServerError`, `sequence()` — correct | ✅ |
| `throw error/redirect` | Correctly uses `throw` (not `return`) for SK2 | ✅ |
| Adapters | auto, node, static, vercel, netlify, cloudflare — all correct packages | ✅ |
| `$env` modules | static/dynamic × private/public matrix — correct | ✅ |
| `cookies.set` requires `path` | Correctly noted as SK2 requirement | ✅ |
| Page options (ssr, csr, prerender) | Correct values and defaults | ✅ |

### Svelte 5 Runes ✅

| Rune | Skill Content | Verified |
|------|--------------|----------|
| `$state` | Correct syntax, deep reactivity on objects/arrays | ✅ |
| `$state.raw` | Non-proxied, reassignment-only reactivity — correct | ✅ |
| `$state.snapshot` | Strips proxy for serialization — correct | ✅ |
| `$derived` / `$derived.by` | Correct usage for simple and complex derivations | ✅ |
| `$effect` | Correct: runs after DOM, browser-only, auto-tracks deps | ✅ |
| `$effect.pre` | Before DOM update — correct | ✅ |
| `$effect.root` | Detached effect scope — correct | ✅ |
| `$props` | Destructuring syntax, rest props, TypeScript — correct | ✅ |
| `$bindable` | Two-way binding with `bind:value` — correct | ✅ |
| Snippets | `{@render children()}`, typed `Snippet<[T]>` — correct | ✅ |

### Migration Guide ✅
- Svelte 4→5: export let→$props, $:→$derived/$effect, stores→runes, slots→snippets, events→callback props — all accurate
- SvelteKit 1→2: 10 breaking changes listed, all verified (throw redirect, $app/state, cookies path, resolveRoute)
- Codemod: `npx sv migrate svelte-5` and `npx sv migrate sveltekit-2` — correct commands

### Minor Observations (not errors)
1. WebSocket section (advanced-patterns.md L417-438): shows `import { server } from '$app/server'` labeled "not yet stable" and immediately offers a Vite plugin alternative. The mixing of hooks.server.ts context with vite.config.ts code is slightly confusing but the code itself is correct.
2. SKILL.md at 495 lines is at the structural limit — adding content would require moving sections to references.

---

## c. Trigger Quality

### Positive Triggers ✅
- SvelteKit, Svelte 5, runes ($state, $derived, $effect, $props)
- File patterns: +page.svelte, +layout.svelte, +server.ts, svelte.config.js
- CLI: `npx sv create`
- Topics: auth, error handling, env vars ($env), adapter config

### Negative Triggers ✅
- Explicitly excludes: React, Next.js, Vue, Nuxt, Angular, Astro
- Excludes: Svelte 4 legacy syntax (export let, $: reactive statements)
- Excludes: general HTML/CSS/JS without SvelteKit context

### False Positive Risk: **LOW**
- No overlap with React/Next.js/Vue/Nuxt terminology
- Svelte 4 legacy syntax explicitly excluded
- Framework-specific file patterns (+page.svelte, etc.) are unique to SvelteKit

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 5 | All APIs verified against current SvelteKit 2 + Svelte 5 docs. Correct imports, correct rune syntax, correct SK2 breaking changes. No factual errors found. |
| **Completeness** | 5 | Covers setup, project structure, all runes, routing, load functions, form actions, API routes, error handling, hooks, page options, adapters, env vars, state management, auth patterns, testing. References add advanced patterns, troubleshooting, and migration. Scripts automate scaffolding. Assets provide production templates. |
| **Actionability** | 5 | Every section has runnable code examples. Scripts are executable with proper argument validation. Assets are copy-paste-ready with inline documentation. Common pitfalls list addresses real developer pain points. Troubleshooting guide covers adapter-specific deployment issues. |
| **Trigger quality** | 4 | Good positive and negative triggers. Covers all key entry points. Could be marginally improved by adding more negative triggers (e.g., Remix, Solid, Qwik) but current exclusions adequately prevent false positives. |

### Overall: **4.75 / 5.0**

---

## Summary

This is an excellent, production-grade skill. The SKILL.md body is comprehensive yet within the line limit, with accurate SvelteKit 2 + Svelte 5 runes coverage verified against official docs. The supporting references are thorough (advanced patterns, troubleshooting, migration), the scripts are practical and well-engineered, and the assets provide real production templates (hooks with rate limiting, Docker Compose, route templates with progressive enhancement). No issues filed — all dimensions score well above thresholds.
