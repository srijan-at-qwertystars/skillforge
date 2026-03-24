# Review: sveltekit-patterns

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.8/5

Issues:
- **Lucia auth is deprecated (March 2025).** The skill recommends `lucia` and `arctic` in the Authentication Patterns section (line 446) and the scaffold script installs `lucia`/`@lucia-auth/adapter-drizzle`. Lucia is now an educational resource only; Better Auth is the officially recommended SvelteKit replacement. Update auth recommendations and scaffold script `--auth lucia` option.
- **Minor: SKILL.md is exactly 499 lines** — one line from the 500-line limit. Any future additions to the body should be moved to references instead.

## Structure Check
- ✅ YAML frontmatter: `name` + `description` present
- ✅ Positive triggers: SvelteKit, Svelte 5, runes, $state/$derived/$effect/$props/$bindable/$inspect, routing, form actions, load functions, SSR, hooks, API routes, env vars, auth, adapters, deploying
- ✅ Negative triggers: "Do NOT use for Svelte 3/4 legacy code without SvelteKit, React/Next.js apps, Vue/Nuxt apps, Astro sites, or general JavaScript frameworks without Svelte"
- ✅ Body: 499 lines (under 500)
- ✅ Imperative voice throughout ("Use", "Scaffold", "Configure", "Build", "Install")
- ✅ Examples with input/output: extensive code blocks covering every major topic
- ✅ References linked and verified: advanced-patterns.md (1048 lines), troubleshooting.md (1062 lines), migration-guide.md (1139 lines)
- ✅ Scripts linked and verified: scaffold-sveltekit-project.sh (750 lines), sveltekit-route-generator.sh (350 lines) — both have `--help`, `set -euo pipefail`, proper arg parsing
- ✅ Assets linked and verified: svelte.config.js, hooks.server.ts, +layout.server.ts — all production-ready templates

## Content Check (verified via web search)
- ✅ Runes API ($state, $derived, $effect, $props, $bindable, $inspect) — all syntax and semantics accurate per official Svelte 5 docs
- ✅ $state.raw, $state.snapshot, $derived.by — correct usage and guidance
- ✅ `npx sv create` — correct scaffold command (replaced `npm create svelte@latest`)
- ✅ `$app/state` used instead of deprecated `$app/stores` — correct for SvelteKit 2.12+/Svelte 5
- ✅ File-based routing, layout groups, param matchers, catch-all routes — all accurate
- ✅ Universal vs server load functions — streaming limitation correctly documented
- ✅ Form actions, progressive enhancement, use:enhance — correct
- ✅ Environment variable modules ($env/static/private, $env/static/public, $env/dynamic/*) — correct
- ✅ Adapter table — correct packages and use cases
- ✅ Hooks (handle, handleFetch, handleError, sequence) — correct signatures and patterns
- ✅ Migration guide (Svelte 4→5, SvelteKit 1→2, React→SvelteKit, Next.js→SvelteKit) — thorough and accurate
- ✅ Troubleshooting guide covers real-world gotchas (hydration, $state pitfalls, CORS, cookies, adapter issues)
- ⚠️ Lucia auth deprecated — recommend Better Auth or Auth.js instead

## Trigger Check
- ✅ Would trigger reliably for: "build SvelteKit app", "Svelte 5 runes", "SvelteKit routing", "$state example", "SvelteKit form actions", "deploy SvelteKit", "SvelteKit auth", "migrate React to SvelteKit"
- ✅ Would NOT false-trigger for: React/Next.js, Vue/Nuxt, Astro, vanilla Svelte 3/4
- ✅ Description is comprehensive enough to catch edge queries like "SvelteKit environment variables" or "Svelte 5 $bindable"

## Verdict
Exceptionally well-crafted skill. The 4800+ lines across all files form a comprehensive SvelteKit reference. The only substantive issue is the Lucia auth recommendation which should be updated to Better Auth. All technical claims about Svelte 5 runes, SvelteKit 2.x routing, load functions, and streaming were verified as accurate.
