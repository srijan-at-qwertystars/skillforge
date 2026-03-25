# Review: netlify-deploy

Accuracy: 3/5
Completeness: 4/5
Actionability: 4/5
Trigger quality: 5/5
Overall: 4.0/5

Issues:

1. **[build.processing] is deprecated (CRITICAL)** — Netlify deprecated post-processing asset optimization in July 2023 and removed it entirely in October 2023. The `[build.processing.css]`, `[build.processing.js]`, `[build.processing.html]`, and `[build.processing.images]` directives are now ignored. This stale config appears in:
   - `SKILL.md` lines 412–424 ("Performance" section)
   - `assets/netlify.toml` lines 181–195
   - `scripts/setup-netlify.sh` lines 262–276
   An AI following this skill would generate non-functional configuration. Remove these sections and advise using build-tool-level minification (Vite, Webpack, PostCSS, cssnano, Terser) instead.

2. **Default Node.js version outdated** — `references/troubleshooting.md` line 79 states "Netlify defaults to Node.js 18" but the current default is Node.js 22.

3. **Netlify Graph is deprecated** — `references/advanced-patterns.md` (lines 413–435) documents Netlify Graph as if it is an active product. Netlify Graph was sunset; this section should be removed or replaced with a note about manual API integration patterns.

4. **@netlify/plugin-gatsby deprecated** — `scripts/setup-netlify.sh` line 157 references `@netlify/plugin-gatsby`, which Netlify has deprecated along with first-class Gatsby support.

5. **`pretty_urls` is part of deprecated build.processing** — Used in SKILL.md and the netlify.toml asset template as if active.

Strengths:

- Excellent trigger description with clear positive/negative boundaries
- SKILL.md is well within 500-line limit (472 lines), imperative voice, no filler
- Comprehensive coverage: functions (serverless/edge/scheduled/background), deploy contexts, redirects, forms, identity, CLI, monorepos, custom domains, split testing, build plugins
- All references and scripts properly linked from SKILL.md
- Scripts are well-structured with argument parsing, help text, and framework auto-detection
- Code examples are runnable with correct types and patterns
- Core facts verified correct: function timeouts (10s/26s), A record IP (75.2.60.5), edge CPU limit (50ms), background function 15-min limit
