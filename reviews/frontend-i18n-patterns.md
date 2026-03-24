# QA Review: i18n-patterns

**Skill path:** `~/skillforge/frontend/i18n-patterns/`
**Reviewer:** Copilot CLI (automated)
**Date:** 2025-07-18

---

## A. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter `name` | ✅ Pass | `name: i18n-patterns` |
| YAML frontmatter `description` | ✅ Pass | Multi-line, comprehensive |
| Positive triggers in description | ✅ Pass | "Use when adding multi-language support, formatting dates/numbers/currencies per locale, handling RTL layouts, setting up translation pipelines, or fixing i18n bugs" |
| Negative triggers in description | ✅ Pass | "Do NOT use for general CSS styling, non-i18n routing, authentication, or backend API design unrelated to locales" |
| Body under 500 lines | ✅ Pass | 474 body lines (excluding frontmatter) |
| Imperative voice | ✅ Pass | Consistently uses imperatives: "Prefer native Intl", "Use ICU syntax", "Replace all physical directional properties", "Always store dates as UTC", "Never conflate language with country" |
| Examples with I/O | ✅ Pass | Every section includes runnable code with expected output in comments (30+ examples across Intl API, ICU, React libs, CSS, date/time) |
| Resources properly linked | ✅ Pass | 3 references, 3 scripts, 5 assets — all linked with relative paths and described |

**Structure verdict: PASS** — no issues found.

---

## B. Content Check

### Intl API Support
All 7 Intl constructors covered (DateTimeFormat, NumberFormat, PluralRules, RelativeTimeFormat, ListFormat, Collator, Segmenter) are well-supported in all modern browsers as of 2024. `formatRange()` and `formatToParts()` also have broad support. The advice "Prefer native Intl over libraries when possible" is sound. ✅

### react-intl / react-i18next APIs
- **react-intl:** `IntlProvider`, `FormattedMessage`, `useIntl`, `intl.formatMessage()` — all current and correct. Rich text via `values` with render functions is accurate.
- **react-i18next:** `useTranslation`, `Trans` component, `i18next-http-backend`, `i18next-browser-languagedetector` — all current. Config with namespaces, `interpolation.escapeValue: false` (React already escapes) is correct.
- Pluralization difference (ICU in react-intl vs. `_one`/`_other` keys in react-i18next) is correctly implied. ✅

### ICU MessageFormat Syntax
- `plural`, `select`, `selectordinal` examples are syntactically correct.
- Nested plural+select example is valid ICU syntax.
- Rule "`other` is required as fallback" is verified correct per ICU specification.
- `#` placeholder usage inside plural/selectordinal is correct.
- Advice to keep full sentences inside each branch is a known best practice. ✅

### next-intl Setup
- APIs `defineRouting`, `createNavigation`, `getRequestConfig`, `createMiddleware`, `NextIntlClientProvider`, `getMessages`, `setRequestLocale` all match the current next-intl API for Next.js App Router.
- The `localePrefix: 'as-needed'` option is correct.
- Middleware matcher pattern is correct.
- `params` typed as `Promise<{ locale: string }>` reflects Next.js 15+ async params. ✅

### CSS Logical Properties
- Physical-to-logical mapping table is fully correct:
  - `margin-left/right` → `margin-inline-start/end` ✅
  - `padding-left/right` → `padding-inline-start/end` ✅
  - `left/right` → `inset-inline-start/end` ✅
  - `text-align: left` → `text-align: start` ✅
  - `float: left` → `float: inline-start` ✅
- `border-start-start-radius` correctly described as "top-left in LTR, top-right in RTL" ✅
- Do/don't mirror guidance (logos, playback controls vs. navigation, progress bars) is accurate. ✅

### BCP 47 / WCAG / SEO
- BCP 47 format `language[-script][-region]` is correct. Examples (`en`, `en-US`, `zh-Hant-TW`, `ar-EG`) follow the standard.
- Arabic PluralRules with 6 categories (zero, one, two, few, many, other) is linguistically correct.
- hreflang implementation: self-referential tags, `x-default`, absolute URLs, sitemap `xhtml:link` — all match Google's documented best practices.
- SEO advice "never auto-redirect by IP" is correct (Google recommends user choice).
- **Minor gap:** The locale-switcher component doesn't set `lang` attributes on locale names (WCAG SC 3.1.2 recommends `<span lang="fr">Français</span>` so screen readers pronounce correctly). This is a minor accessibility enhancement opportunity, not a blocking issue.

**Content verdict: PASS** — all technical content verified accurate against current standards and APIs.

---

## C. Trigger Check

| Scenario | Expected | Result |
|---|---|---|
| "How do I add i18n to my React app?" | ✅ Trigger | ✅ Matches "multi-language support", "react-intl/react-i18next" |
| "Format a date in German locale" | ✅ Trigger | ✅ Matches "formatting dates…per locale", "Intl API" |
| "How to handle RTL layout in CSS?" | ✅ Trigger | ✅ Matches "RTL/bidi support", "CSS logical properties" |
| "Set up next-intl in Next.js App Router" | ✅ Trigger | ✅ Matches "next-intl" explicitly |
| "How do I pluralize strings for Arabic?" | ✅ Trigger | ✅ Matches "ICU MessageFormat with plural", "PluralRules" |
| "How do I style a button with Tailwind?" | ❌ No trigger | ✅ Excluded by "Do NOT use for general CSS styling" |
| "Set up React Router with auth guards" | ❌ No trigger | ✅ Excluded by "non-i18n routing, authentication" |
| "Build a REST API with Express" | ❌ No trigger | ✅ Excluded by "backend API design unrelated to locales" |
| "CSS logical properties for general layout" | ❌ No trigger | ⚠️ Could partially match — the skill mentions "CSS logical properties" in the description. However, the negative trigger "general CSS styling" should suppress this. |

**Trigger verdict: PASS** — strong selectivity with one minor edge case noted.

---

## D. Scoring

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 5/5 | All APIs, syntax, and standards verified correct through web searches. Code examples produce stated outputs. No factual errors found. |
| **Completeness** | 5/5 | Covers full i18n stack: 7 Intl constructors, ICU MessageFormat (3 forms), 3 React libraries, RTL/bidi, CSS logical properties, date/timezone, currency, extraction workflow, translation pipeline, server-side i18n, SEO, lazy loading, testing (pseudo-loc, automated, visual). 3 reference docs, 3 scripts, 5 assets. |
| **Actionability** | 5/5 | Every concept has runnable code with expected output. Scripts are immediately executable (`init-i18n-project.sh` bootstraps full setup). Assets are copy-paste production-ready with type safety. |
| **Trigger quality** | 4/5 | Strong positive/negative trigger coverage. Minor deduction: "CSS logical properties" in description could edge-trigger on general CSS queries, though the negative trigger "general CSS styling" should suppress it. |

**Overall: 4.75 / 5.0**

---

## E. Issues & Recommendations

No blocking issues found. Minor enhancement opportunities:

1. **Locale switcher a11y (minor):** Add `lang` attributes to locale name labels in `locale-switcher.tsx` for WCAG SC 3.1.2 compliance (e.g., `<span lang="fr">Français</span>`).
2. **Intl.DurationFormat note (minor):** `date-formatter.ts` uses `Intl.DurationFormat` which is still a Stage 3 proposal. The code already has a fallback, but a brief note in SKILL.md about its proposal status would be helpful.
3. **Trigger edge case (minor):** Consider adding "CSS logical properties for RTL" specificity to the description to further disambiguate from general CSS queries.

---

## F. Verdict

| Check | Result |
|---|---|
| Overall ≥ 4.0 | ✅ (4.75) |
| All dimensions > 2 | ✅ (min: 4) |
| GitHub issues required | ❌ No |
| SKILL.md tag | `<!-- tested: pass -->` |

**PASS** — Exceptionally well-crafted skill. Production-ready.
