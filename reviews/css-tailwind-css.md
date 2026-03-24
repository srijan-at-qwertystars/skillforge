# Review: tailwind-css

Accuracy: 4/5
Completeness: 4/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:

1. **`assets/app.css` redefines built-in v4 utilities** — `@utility text-balance` and `@utility text-pretty` conflict with Tailwind v4's built-in `text-balance` and `text-pretty` utilities (which map to `text-wrap: balance` and `text-wrap: pretty` natively). These custom definitions should be removed from the template to avoid shadowing built-ins.

2. **Missing `@reference` directive** — Tailwind v4 introduces `@reference` for CSS Modules to pull in theme/utilities from the main stylesheet (important for Next.js + CSS Modules). Not mentioned in SKILL.md or troubleshooting.md.

3. **Incomplete container query breakpoint list** — The cheatsheet and main SKILL.md only list `@xs:` through `@2xl:`. Tailwind v4 also includes `@3xl:` (768px), `@4xl:` (896px), `@5xl:` (1024px), `@6xl:` (1152px), `@7xl:` (1280px) by default.

4. **Questionable print example** — `advanced-patterns.md` line 639 uses `print:after:content-['_('_attr(href)_')']` which is syntactically fragile with Tailwind's class parser due to nested parentheses and spaces.

## Verification Summary

**Verified accurate via web search:**
- All v4 directives (@theme, @utility, @plugin, @custom-variant, @source) — correct
- Browser support (Chrome 111+, Safari 16.4+, Firefox 128+) — matches official docs
- Container query breakpoints (@xs: 320px through @2xl: 672px) — correct
- `@source inline()` safelist syntax — correct (introduced in v4.1)
- Installation paths (Vite/PostCSS/CLI) — correct
- Migration via `npx @tailwindcss/upgrade` — correct
- Dark mode class strategy syntax — correct
- Renamed utilities table (v3→v4) — correct

**Structure:**
- YAML frontmatter: ✅ has name + description
- Positive & negative triggers in description: ✅
- Body: 499 lines (under 500 limit) ✅
- Imperative voice, no filler: ✅
- Examples with input/output: ✅
- References/scripts linked from SKILL.md: ✅

**Assets & scripts quality:**
- Shell scripts are well-structured with error handling, auto-detection, and color output
- Component HTML templates are production-quality with dark mode, responsive, and accessibility
- Cheatsheet is comprehensive and accurate

**Trigger assessment:**
- Would correctly trigger for: Tailwind utility classes, v4 config, @theme, responsive layouts, dark mode, component styling
- Would correctly NOT trigger for: vanilla CSS, Bootstrap, styled-components, Emotion
- Description is sufficiently specific without being overly broad
