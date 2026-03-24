# Review: astro-framework

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.2/5

Issues:

1. **`content.config.ts` location error** — SKILL.md line 111 says "Define collections in `content.config.ts` at project root." The correct Astro 5 location is `src/content.config.ts` (inside `src/`, not project root). The scaffold script also incorrectly places it at the project root. The Astro docs and migration guides are clear: it moved from `src/content/config.ts` (v4) up one level to `src/content.config.ts` (v5).

2. **`astro:schema` import may be incorrect** — SKILL.md line 338 uses `import { z } from 'astro:schema'` in the Actions section. The current official Astro docs recommend `import { z } from 'astro/zod'`. The `astro:schema` virtual module is not documented as the canonical import path. Should verify and update.

3. **`@astrojs/deno` adapter listed but deprecated** — Line 244 lists `@astrojs/deno` as an adapter. The Deno adapter has been removed from official Astro integrations. Should be removed from the list.

4. **`Astro.glob()` shown without deprecation warning** — Line 206 shows `Astro.glob()` as a data fetching method. While the skill notes content collections are "preferred," `Astro.glob()` is deprecated in Astro 5 and should carry a clearer warning or be removed.

5. **Minor: `astro sync` not mentioned in main body** — The `npx astro sync` command for regenerating types after content collection changes is only mentioned in the `content-config.ts` asset comment, not in the main SKILL.md body. This is a critical step users frequently miss.

## Structure Assessment

- ✅ YAML frontmatter has `name` and `description`
- ✅ Description has positive AND negative triggers
- ✅ Body is 431 lines (under 500 limit)
- ✅ Imperative voice used consistently
- ✅ Abundant code examples with clear patterns
- ✅ References (3 files) and scripts (2 files) properly linked with descriptions
- ✅ Assets (3 template files) documented

## Content Assessment

- ✅ Content Collections v5 API (loaders, `post.id`, `render()`) — correct
- ✅ Islands architecture and `client:*` directives — correct
- ✅ Server Islands with `server:defer` and fallback slots — correct
- ✅ View Transitions import from `astro:transitions` — correct
- ✅ Hybrid mode removal in Astro 5 — correctly noted
- ✅ Output modes (`static` | `server`) — correct
- ✅ SSR adapters and `prerender` export — correct
- ⚠️ `content.config.ts` location — incorrect (see issue #1)
- ⚠️ Actions Zod import path — potentially incorrect (see issue #2)
- ⚠️ Deno adapter — outdated (see issue #3)

## Trigger Assessment

- Strong positive triggers: Astro islands, content collections, View Transitions, Actions, DB, middleware, SSR/SSG, partial hydration
- Good negative triggers: explicitly excludes React-only (Next.js/Remix), Vue-only (Nuxt), Svelte-only (SvelteKit), Hugo/Jekyll
- Could improve: add ".astro files", "Astro components", "build blog with Astro" as trigger phrases
- False positive risk: low (Astro-specific terminology throughout)
- False negative risk: low-moderate (covers most common Astro queries)
