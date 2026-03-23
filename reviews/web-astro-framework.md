# QA Review: astro-framework

**Reviewed:** 2025-07-17
**Skill path:** `~/skillforge/web/astro-framework/`
**Reviewer:** Copilot QA

---

## a. Structure Check

| Criterion | Status | Notes |
|-----------|--------|-------|
| YAML frontmatter `name` | ✅ Pass | `name: astro-framework` |
| YAML frontmatter `description` | ✅ Pass | Comprehensive, 5-line description |
| Positive triggers in description | ✅ Pass | Lists 12+ concrete trigger scenarios (.astro files, content collections, client directives, SSR adapters, astro:assets, middleware, API routes, islands, view transitions, deployment) |
| Negative triggers in description | ✅ Pass | Excludes React/Next.js/Nuxt/SvelteKit/Remix, general HTML/CSS, Node/Express, Hugo/Jekyll/11ty |
| Body under 500 lines | ✅ Pass | 493 lines — just under limit |
| Imperative voice, no filler | ✅ Pass | Direct, terse, action-oriented prose throughout |
| Input/output examples | ✅ Pass | Abundant code examples with input patterns and expected output for routing, components, collections, directives, styling, SSR, middleware, API routes, images |
| References properly linked | ✅ Pass | Supplemental Resources section at bottom describes all reference files and their contents |
| Scripts properly linked | ✅ Pass | Three scripts described with purpose; all have `--help` documentation |
| Assets properly linked | ✅ Pass | Four asset files described (config template, blog layout, content config, docker-compose) |

**Structure verdict:** All structural requirements met.

---

## b. Content Accuracy Check (verified via web search)

### Content Collections (defineCollection, glob loader, schema API)
- ✅ **Accurate.** The skill correctly documents the Astro 5 Content Layer API: `src/content.config.ts` location, `defineCollection` with `loader: glob(...)`, `z` from `astro/zod`, `z.coerce.date()` for dates. All match current Astro 5.x docs.
- ✅ `getCollection` and `getEntry` APIs are correct.
- ✅ `reference()` for cross-collection references documented in advanced-patterns.md.
- ✅ Legacy `Astro.glob` correctly flagged as deprecated in pitfalls.

### Client Directives
- ✅ **Accurate.** All five directives (`client:load`, `client:idle`, `client:visible`, `client:media`, `client:only`) are correctly documented with proper syntax and use cases.
- ✅ Rule about `.astro` components not accepting client directives is correct and prominently stated.
- ⚠️ **Minor gap:** `client:idle` and `client:visible` accept optional config objects (e.g., `client:idle={{ timeout: 1000 }}`, `client:visible={{ rootMargin: "200px" }}`). These options are not mentioned. Low severity since they are edge-case tuning knobs.

### View Transitions
- ⚠️ **Outdated naming.** The skill consistently uses `<ViewTransitions />` from `astro:transitions`. In Astro 5, this component was **renamed to `<ClientRouter />`**. `<ViewTransitions />` still works as a backward-compatible alias, but the canonical Astro 5 name is `<ClientRouter />`. The skill should mention the rename and note that native browser view transitions can now work without the component.
- ✅ `transition:name`, `transition:animate`, `transition:persist`, lifecycle events, swap functions are all accurately documented.

### Component Syntax (.astro files)
- ✅ **Accurate.** Frontmatter fences (`---`), `Astro.props`, `Props` interface, expressions, slots (named + default), conditional rendering — all correct.

### Adapter Names and Config
- ✅ **Accurate.** The skill uses the modern unified import style: `import vercel from '@astrojs/vercel'` (not the deprecated `@astrojs/vercel/serverless` sub-path). This is correct for Astro 5.
- ✅ Node adapter `mode: 'standalone'` syntax is correct.
- ✅ Cloudflare and Netlify adapter configs are accurate.

### Image Optimization (astro:assets)
- ✅ **Accurate.** `import { Image } from 'astro:assets'`, ESM imports for local images, explicit dimensions for remote images, `image.domains` config — all correct.
- ✅ Responsive images mention (`widths` and `sizes` props for Astro 5.10+) is accurate.
- ⚠️ **Minor gap:** The `<Picture />` component from `astro:assets` is not mentioned. It provides multi-format source generation (`<source>` elements for AVIF/WebP). Worth a brief mention.

### Astro Actions (advanced-patterns.md)
- ✅ **Accurate.** `defineAction` API with Zod input validation, `accept: 'form'`, and client-side invocation via `actions.myAction()` are correctly documented.
- ✅ Actions file location (`src/actions/index.ts`) and `ActionError` handling are covered.

### Astro DB (advanced-patterns.md)
- ✅ Drizzle ORM integration documented accurately.

### Server Islands (advanced-patterns.md)
- ✅ `server:defer` directive and fallback content documented correctly.

### Missing Gotchas
- ⚠️ **`<ViewTransitions />` → `<ClientRouter />` rename** (as noted above).
- ⚠️ **`slug` → `id` change in Astro 5 content collections.** In Astro 5, collection entries use `entry.id` instead of `entry.slug`. The skill uses `id` in most places (correctly), but the detail page in `content-collection-scaffold.sh` also uses `id` (correct). Worth an explicit callout in pitfalls since this trips up migrators.
- ⚠️ **Deno adapter deprecation.** The deployment guide references `@astrojs/deno`, which has been deprecated. Astro recommends using `@astrojs/node` with Deno compatibility or Deno's native adapter. Low impact since it's in a reference file.

---

## c. Trigger Check

### Positive triggers — pushy enough?
✅ **Yes.** The description casts a wide net covering:
- File patterns: `.astro`, `astro.config.mjs`, `src/pages/`, `src/content/`, `content.config.ts`
- Features: content collections, client directives, SSR adapters, `astro:assets`, middleware, API routes, view transitions, framework islands
- Tasks: creating, editing, configuring, integrating, deploying

This will reliably trigger for any Astro-related work.

### False trigger risk?
✅ **Low.** Negative triggers are well-crafted:
- Explicitly excludes all major competing frameworks (Next.js, Nuxt, SvelteKit, Remix)
- Excludes generic HTML/CSS and Node.js/Express
- Excludes other SSGs (Hugo, Jekyll, 11ty)
- The only minor risk: a project using React + Express that happens to have a file called `astro.config.mjs` could false-trigger, but this is extremely unlikely in practice.

**Trigger verdict:** Strong positive coverage, low false-trigger risk. No changes needed.

---

## d. Scores

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| **Accuracy** | 4 | Content collections, client directives, adapters, images, middleware, API routes all verified accurate. Minor issue: `<ViewTransitions />` → `<ClientRouter />` rename not reflected. Deprecated Deno adapter in deployment guide. |
| **Completeness** | 5 | Exceptional breadth: core concepts, 3 reference files (1189-line advanced patterns, troubleshooting, deployment guide), 3 executable scripts, 4 asset templates. Covers Actions, Server Islands, i18n, Astro DB, nano stores, Docker, CI/CD. Hard to find a significant Astro topic not covered. |
| **Actionability** | 5 | Every section has copy-paste-ready code examples. Scripts are executable with `--help`. Asset templates are production-grade (blog layout with JSON-LD, docker-compose with health checks, multi-collection content config with references). Troubleshooting guide has symptom → cause → fix format. |
| **Trigger quality** | 5 | Comprehensive positive triggers, explicit negative triggers, low false-positive risk. |

**Overall: 4.75**

---

## e. GitHub Issues

No issues required. Overall score (4.75) exceeds 4.0 threshold and no individual dimension is ≤ 2.

**Recommendations for future improvement (non-blocking):**
1. Add a note about `<ClientRouter />` being the Astro 5 canonical name for the view transitions component (currently uses the legacy `<ViewTransitions />` alias).
2. Mention `<Picture />` component from `astro:assets` for multi-format source sets.
3. Note `client:idle` and `client:visible` optional config objects.
4. Flag `@astrojs/deno` as deprecated in deployment-guide.md.
5. Add explicit pitfall about `slug` → `id` rename in Astro 5 collections for migrators.

---

## f. Test Status

**Result: PASS** ✅

The skill is accurate, comprehensive, and immediately actionable. The identified issues are minor (backward-compatible naming, deprecated reference-file content) and do not materially affect the skill's utility.
