---
name: i18n-patterns
description: >
  Internationalization (i18n) and localization (l10n) patterns for JavaScript/TypeScript
  and React applications. Covers Intl API (DateTimeFormat, NumberFormat, PluralRules,
  RelativeTimeFormat, ListFormat, Collator, Segmenter), react-intl/react-i18next/next-intl,
  ICU MessageFormat with plural/gender/select, RTL/bidi support, CSS logical properties,
  timezone handling, currency formatting, hreflang SEO, translation extraction workflows,
  pseudo-localization testing, and lazy-loaded translation architecture. Use when adding
  multi-language support, formatting dates/numbers/currencies per locale, handling RTL
  layouts, setting up translation pipelines, or fixing i18n bugs. Do NOT use for general
  CSS styling, non-i18n routing, authentication, or backend API design unrelated to locales.
---

# Internationalization (i18n) Patterns

## Core Concepts

- **i18n** = engineering for locale-readiness; **l10n** = adapting content for a specific locale.
- **Locale code** = BCP 47: `language[-script][-region]`. Examples: `en`, `en-US`, `zh-Hant-TW`, `ar-EG`.
- Never conflate language with country. `pt-BR` ≠ `pt-PT`. Always use full locale tags.
- **Language negotiation**: match user preference against available locales with fallback chain.

```ts
const SUPPORTED = ['en', 'fr', 'de', 'ja'] as const;
type Locale = (typeof SUPPORTED)[number];
function negotiateLocale(acceptLang: string, fallback: Locale = 'en'): Locale {
  const preferred = acceptLang.split(',')
    .map(l => l.split(';')[0].trim().split('-')[0].toLowerCase());
  return (preferred.find(l => SUPPORTED.includes(l as Locale)) as Locale) ?? fallback;
}
// Input:  "ja,en-US;q=0.9,fr;q=0.8" → Output: "ja"
```

## JavaScript Intl API

Prefer native `Intl` over libraries when possible. Always pass explicit locale.

### DateTimeFormat
```ts
new Intl.DateTimeFormat('de-DE', { dateStyle: 'long' }).format(new Date('2024-03-15'));
// → "15. März 2024"
new Intl.DateTimeFormat('en-US', {
  dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Tokyo',
}).format(new Date());
// → "Mar 15, 2024, 2:30 AM"
// Use formatToParts() for custom rendering of individual date components
new Intl.DateTimeFormat('en-US', { month: 'long', day: 'numeric' })
  .formatToParts(new Date('2024-12-25'));
// → [{ type: 'month', value: 'December' }, { type: 'literal', value: ' ' }, { type: 'day', value: '25' }]
```

### NumberFormat
```ts
new Intl.NumberFormat('ja-JP', { style: 'currency', currency: 'JPY' }).format(1500);
// → "￥1,500"
new Intl.NumberFormat('en', { notation: 'compact', maximumFractionDigits: 1 }).format(1_234_567);
// → "1.2M"
new Intl.NumberFormat('de-DE', { style: 'unit', unit: 'kilometer-per-hour' }).format(120);
// → "120 km/h"
new Intl.NumberFormat('fr-FR', { style: 'percent', minimumFractionDigits: 1 }).format(0.856);
// → "85,6 %"
new Intl.NumberFormat('en', { style: 'currency', currency: 'USD' }).formatRange(10, 50);
// → "$10.00 – $50.00"
```

### RelativeTimeFormat
```ts
const rtf = new Intl.RelativeTimeFormat('es', { numeric: 'auto' });
rtf.format(-1, 'day');   // → "ayer"
rtf.format(3, 'month');  // → "dentro de 3 meses"
rtf.format(0, 'day');    // → "hoy"
```

### PluralRules
```ts
const pr = new Intl.PluralRules('ar-EG');
pr.select(0);  // "zero"    pr.select(1);  // "one"     pr.select(2);  // "two"
pr.select(5);  // "few"     pr.select(11); // "many"    pr.select(100);// "other"
// Arabic has 6 plural categories — never hardcode "singular/plural" logic.
```

### ListFormat, Collator, Segmenter
```ts
new Intl.ListFormat('en', { type: 'conjunction' }).format(['Alice', 'Bob', 'Carol']);
// → "Alice, Bob, and Carol"
new Intl.ListFormat('zh', { type: 'conjunction' }).format(['小明', '小红', '小刚']);
// → "小明、小红和小刚"

['ä', 'a', 'z'].sort(new Intl.Collator('de').compare); // → ['a', 'ä', 'z']

const seg = new Intl.Segmenter('ja', { granularity: 'word' });
[...seg.segment('東京タワー')].filter(s => s.isWordLike).map(s => s.segment);
// → ["東京", "タワー"]
```

## ICU MessageFormat

Use ICU syntax for all translatable strings with dynamic content.

```ts
// Plural
`{count, plural, =0 {No messages} one {# message} other {# messages}}`
// { count: 5 } → "5 messages"

// Select (gender)
`{gender, select, male {He left a comment.} female {She left a comment.} other {They left a comment.}}`

// Nested plural + select
`{gender, select,
  male {{count, plural, one {He has # item} other {He has # items}}}
  female {{count, plural, one {She has # item} other {She has # items}}}
  other {{count, plural, one {They have # item} other {They have # items}}}
}`
// { gender: 'female', count: 3 } → "She has 3 items"

// Selectordinal
`{pos, selectordinal, one {#st place} two {#nd place} few {#rd place} other {#th place}}`
// { pos: 2 } → "2nd place"
```

ICU rules:
- Always include `other` as fallback category.
- Use `#` for the number placeholder inside plural/selectordinal.
- Keep full sentences inside each branch — never split sentences across keys.
- Provide translator context via descriptions, not inline comments.

## React i18n Libraries

### react-intl (FormatJS)
```tsx
import { IntlProvider, FormattedMessage, useIntl } from 'react-intl';
import messages_fr from './lang/fr.json';

function App() {
  return (
    <IntlProvider locale="fr" messages={messages_fr}>
      <Greeting name="Marie" />
    </IntlProvider>
  );
}
function Greeting({ name }: { name: string }) {
  const intl = useIntl();
  const title = intl.formatMessage({ id: 'greeting.title' }, { name }); // imperative
  return <FormattedMessage id="greeting.hello" values={{
    name, bold: (chunks) => <b>{chunks}</b>
  }} />;
}
// fr.json: { "greeting.hello": "Bonjour <bold>{name}</bold> !" }
// Output:  Bonjour <b>Marie</b> !
```

### react-i18next
```tsx
import { useTranslation, Trans } from 'react-i18next';

function ItemCount() {
  const { t } = useTranslation('shop');
  return <p>{t('items.count', { count: 3 })}</p>; // plural via JSON keys
}
function Welcome() {
  return <Trans i18nKey="welcome" components={{ bold: <strong />, link: <a href="/help" /> }} />;
  // en.json: "welcome": "Read our <link>guide</link> to get <bold>started</bold>."
}
// Config with namespaces and lazy loading
import i18n from 'i18next';
import Backend from 'i18next-http-backend';
import LanguageDetector from 'i18next-browser-languagedetector';
i18n.use(Backend).use(LanguageDetector).init({
  fallbackLng: 'en',
  ns: ['common', 'shop', 'auth'],
  defaultNS: 'common',
  backend: { loadPath: '/locales/{{lng}}/{{ns}}.json' },
  interpolation: { escapeValue: false },
});
```

### next-intl (Next.js App Router)
```tsx
// app/[locale]/layout.tsx
import { NextIntlClientProvider } from 'next-intl';
import { getMessages } from 'next-intl/server';
export default async function LocaleLayout({ children, params: { locale } }) {
  const messages = await getMessages();
  return (
    <html lang={locale} dir={locale === 'ar' ? 'rtl' : 'ltr'}>
      <body>
        <NextIntlClientProvider messages={messages}>{children}</NextIntlClientProvider>
      </body>
    </html>
  );
}
// middleware.ts — locale detection and routing
import createMiddleware from 'next-intl/middleware';
export default createMiddleware({ locales: ['en', 'fr', 'ar'], defaultLocale: 'en' });
export const config = { matcher: ['/((?!api|_next|.*\\..*).*)'] };
```

## RTL & Bidirectional Text

### HTML dir Attribute
```html
<html lang="ar" dir="rtl"> <!-- Set at root; update dynamically on locale switch -->
<p dir="rtl">السعر: <span dir="ltr">$99.99</span></p> <!-- Isolate embedded LTR -->
<p>User: <bdi>مستخدم</bdi> posted a comment.</p> <!-- bdi for user-generated content -->
```

### CSS Logical Properties

Replace all physical directional properties with logical equivalents:
```css
/* ✗ Breaks in RTL */
.card { margin-left: 16px; padding-right: 8px; text-align: left; border-left: 2px solid; }
/* ✓ Works in both directions */
.card {
  margin-inline-start: 16px;
  padding-inline-end: 8px;
  text-align: start;
  border-inline-start: 2px solid;
}
/* Logical shorthands */
.box {
  margin-block: 8px 16px;            /* top / bottom */
  padding-inline: 12px 24px;         /* start / end */
  inset-inline-start: 0;             /* replaces left: 0 */
  border-start-start-radius: 8px;    /* top-left in LTR, top-right in RTL */
}
```

| Physical | Logical |
|---|---|
| `margin-left/right` | `margin-inline-start/end` |
| `padding-left/right` | `padding-inline-start/end` |
| `left/right` | `inset-inline-start/end` |
| `text-align: left` | `text-align: start` |
| `float: left` | `float: inline-start` |

Do NOT mirror: logos, media playback controls, phone numbers, clocks, checkmarks.
DO mirror: navigation flow, progress bars, arrows/chevrons, layout alignment.

## Date/Time & Timezone Handling

Always store dates as UTC ISO 8601 strings. Format only at display time.

```ts
// date-fns with locale
import { format } from 'date-fns';
import { ja } from 'date-fns/locale';
format(new Date('2024-03-15'), 'PPP', { locale: ja });
// → "2024年3月15日"

// Luxon for timezone-aware display
import { DateTime } from 'luxon';
DateTime.now().setZone('America/Sao_Paulo').setLocale('pt-BR')
  .toLocaleString(DateTime.DATE_FULL);
// → "15 de março de 2024"

// Relative time helper using Intl
function relativeTime(date: Date, locale: string): string {
  const diff = (date.getTime() - Date.now()) / 1000;
  const units: [Intl.RelativeTimeFormatUnit, number][] = [
    ['year', 31536000], ['month', 2592000], ['week', 604800],
    ['day', 86400], ['hour', 3600], ['minute', 60], ['second', 1],
  ];
  const rtf = new Intl.RelativeTimeFormat(locale, { numeric: 'auto' });
  for (const [unit, secs] of units) {
    if (Math.abs(diff) >= secs) return rtf.format(Math.round(diff / secs), unit);
  }
  return rtf.format(0, 'second');
}
// relativeTime(yesterday, 'ko') → "어제"
```

## Number & Currency Formatting

```ts
function formatPrice(amount: number, currency: string, locale: string): string {
  return new Intl.NumberFormat(locale, {
    style: 'currency', currency, currencyDisplay: 'narrowSymbol',
  }).format(amount);
}
formatPrice(29.99, 'EUR', 'de-DE'); // → "29,99 €"
formatPrice(1500, 'JPY', 'ja-JP');  // → "￥1,500"
```

## String Extraction & Translation Workflow

### Extraction Tools
```bash
# FormatJS — extract and compile
npx formatjs extract 'src/**/*.tsx' --out-file lang/en.json \
  --id-interpolation-pattern '[sha512:contenthash:base64:6]'
npx formatjs compile lang/fr.json --out-file compiled/fr.json

# i18next-parser
npx i18next-parser --config i18next-parser.config.js
```

```js
// i18next-parser.config.js
module.exports = {
  locales: ['en', 'fr', 'de', 'ja'],
  output: 'public/locales/$LOCALE/$NAMESPACE.json',
  input: ['src/**/*.{ts,tsx}'],
  defaultNamespace: 'common',
  keySeparator: '.', namespaceSeparator: ':',
};
```

### Translation Pipeline
1. Extract source strings → JSON/XLIFF.
2. Push to TMS (Phrase, Crowdin, Lokalise, Locize) via CLI or CI.
3. Translators work in TMS with context and screenshots.
4. Pull translations back via TMS CLI or GitHub Action.
5. Validate at build: missing keys, unused keys, invalid ICU syntax.
6. Deploy with lazy-loaded namespace bundles per locale.

## Server-Side i18n

```ts
// Locale detection priority: URL path > cookie > Accept-Language > default
function detectLocale(req: Request): string {
  const pathLocale = new URL(req.url).pathname.split('/')[1];
  if (SUPPORTED.includes(pathLocale)) return pathLocale;
  const cookieLocale = parseCookies(req).locale;
  if (cookieLocale && SUPPORTED.includes(cookieLocale)) return cookieLocale;
  return negotiateLocale(req.headers.get('Accept-Language') ?? '');
}
// Response headers
res.headers.set('Content-Language', locale);
res.headers.set('Vary', 'Accept-Language');
```

## SEO for Multilingual Sites

```html
<head>
  <link rel="alternate" hreflang="en" href="https://example.com/en/about" />
  <link rel="alternate" hreflang="fr" href="https://example.com/fr/about" />
  <link rel="alternate" hreflang="x-default" href="https://example.com/en/about" />
</head>
```
```xml
<!-- Sitemap hreflang -->
<url>
  <loc>https://example.com/en/about</loc>
  <xhtml:link rel="alternate" hreflang="en" href="https://example.com/en/about"/>
  <xhtml:link rel="alternate" hreflang="fr" href="https://example.com/fr/about"/>
  <xhtml:link rel="alternate" hreflang="x-default" href="https://example.com/en/about"/>
</url>
```

SEO rules:
- Every page must reference itself AND all alternates with absolute URLs.
- Include `x-default` for the fallback page.
- Use subdirectory structure (`/en/`, `/fr/`) for consolidated SEO authority.
- Never auto-redirect by IP — let user choose, persist via cookie.
- Translate `<title>`, `<meta description>`, and Open Graph tags per locale.

## Lazy Loading & Architecture

```ts
// Namespace splitting — load only what the current route needs
async function loadMessages(locale: string, ns: string) {
  return (await import(`../locales/${locale}/${ns}.json`)).default;
}

// React.lazy + Suspense for translation chunks
const DashboardPage = React.lazy(async () => {
  const [mod, msgs] = await Promise.all([
    import('./DashboardPage'),
    loadMessages(locale, 'dashboard'),
  ]);
  i18n.addResourceBundle(locale, 'dashboard', msgs);
  return mod;
});

// Fallback chain: regional → language → default ("pt-BR" → "pt" → "en")
i18n.init({ fallbackLng: { 'pt-BR': ['pt', 'en'], default: ['en'] } });
```

## Testing

### Pseudo-Localization
```ts
// Transforms: "Hello" → "[Ĥéļļö ~~~~~]"
// Brackets → spot untranslated strings. Accents → verify encoding. Padding → test ~40% expansion.
function pseudoLocalize(str: string): string {
  const map: Record<string, string> = {
    a:'á', e:'é', i:'í', o:'ó', u:'ú', c:'ç', n:'ñ',
    A:'Á', E:'É', I:'Í', O:'Ó', U:'Ú', C:'Ç', N:'Ñ',
  };
  const replaced = str.replace(/[a-zA-Z]/g, c => map[c] ?? c);
  return `[${replaced} ${'~'.repeat(Math.ceil(str.length * 0.4))}]`;
}
// "Save changes" → "[Sávé çháñgés ~~~~~]"
```

### Automated Checks
```ts
import en from '../locales/en/common.json';
import fr from '../locales/fr/common.json';
test('fr has all keys from en', () => {
  expect(Object.keys(en).filter(k => !(k in fr))).toEqual([]);
});
// Validate ICU syntax at build time
import { parse } from '@formatjs/icu-messageformat-parser';
Object.entries(messages).forEach(([id, msg]) => {
  expect(() => parse(msg)).not.toThrow();
});
```

### RTL Visual Testing
- Run Playwright/Cypress with `dir="rtl"` on `<html>`.
- Capture screenshots in both LTR and RTL; diff for regressions.
- Test with real Arabic/Hebrew content, not just `dir` attribute flip.

## Common Gotchas

### ✗ String Concatenation
```ts
// WRONG — word order varies by language
const msg = "Welcome, " + name + "! You have " + count + " items.";
// CORRECT — use ICU message with placeholders
const msg = t('welcome', { name, count });
// en: "Welcome, {name}! You have {count, plural, one {# item} other {# items}}."
// ja: "{name}さん、ようこそ！{count, plural, other {#個のアイテム}}があります。"
```

### ✗ Hardcoded Formats
```ts
// WRONG
const price = "$" + amount.toFixed(2);
const date = `${d.getMonth()+1}/${d.getDate()}/${d.getFullYear()}`;
// CORRECT
const price = new Intl.NumberFormat(locale, { style: 'currency', currency }).format(amount);
const date = new Intl.DateTimeFormat(locale, { dateStyle: 'medium' }).format(d);
```

### ✗ Naive Pluralization
```ts
// WRONG — breaks for languages with >2 plural forms (Arabic: 6, Russian: 3, Japanese: 1)
const label = count === 1 ? 'item' : 'items';
// CORRECT — use Intl.PluralRules or ICU plural syntax
```

### ✗ Splitting Sentences
```ts
// WRONG — translators cannot reorder fragments
t('greeting.start') + name + t('greeting.end')
// CORRECT — single key with placeholder
t('greeting', { name })
```

### ✗ Assumptions About Text
- Text length varies 30-200% across languages. Design flexible layouts.
- Not all scripts use spaces between words (Chinese, Japanese, Thai).
- Number formats differ: `1.234,56` (German) vs `1,234.56` (US). Always use `Intl.NumberFormat`.
- Sort order is locale-dependent — always use `Intl.Collator`.
- Calendar systems differ: Buddhist, Islamic, Japanese Imperial. Use `calendar` option in Intl.
- First day of week varies: Sunday (US), Monday (EU/ISO), Saturday (Middle East).

## Reference Documents

In-depth guides in `references/`:

- **[advanced-patterns.md](references/advanced-patterns.md)** — Context-aware translations, Trans component interpolation, namespaced translations for micro-frontends, dynamic locale loading (webpack/vite), key naming conventions, missing translation handling, Intl.Segmenter text processing, relative time formatting, currency display patterns, number system support.
- **[rtl-guide.md](references/rtl-guide.md)** — Complete RTL support: CSS logical properties reference table, direction-aware flexbox/grid, bidi algorithm and Unicode control characters, icon mirroring rules, chart/graph RTL adaptation, form layout, pseudo-localization testing, Tailwind CSS RTL plugin, CSS specificity with `[dir]` selectors.
- **[nextjs-i18n.md](references/nextjs-i18n.md)** — Next.js App Router i18n with next-intl: routing/request/navigation config, middleware locale detection, static generation, dynamic routes, metadata/SEO per locale, API route i18n, ISR with translations, server/client component patterns, locale navigation, cookie-based preferences.

## Scripts

Executable utilities in `scripts/` (run with `./scripts/<name>.sh --help`):

- **[init-i18n-project.sh](scripts/init-i18n-project.sh)** — Bootstrap i18n in a React or Next.js project. Installs deps, creates locale directory structure, generates config files, adds extraction scripts to package.json. Usage: `./scripts/init-i18n-project.sh --framework nextjs --locales en,fr,de`
- **[extract-strings.sh](scripts/extract-strings.sh)** — Scan source code for `t()`, `<FormattedMessage>`, `<Trans>` calls. Extracts keys to JSON or POT format. Reports untranslated and unused keys. Usage: `./scripts/extract-strings.sh --src src/ --format json`
- **[pseudo-localize.sh](scripts/pseudo-localize.sh)** — Generate pseudo-localized translation files with diacritics, 30% expansion, bracket wrapping. Use to catch truncation, encoding issues, and untranslated strings. Usage: `./scripts/pseudo-localize.sh --input messages/en.json`

## Assets (Copy-Paste Templates)

Production-ready code in `assets/`:

- **[i18n-config.ts](assets/i18n-config.ts)** — Complete react-i18next configuration with namespace loading, browser language detection, regional fallback chains, type-safe keys, custom formatters, and missing key handler.
- **[next-intl-setup.ts](assets/next-intl-setup.ts)** — All-in-one Next.js App Router i18n setup: routing, request config, navigation helpers, middleware, root layout with provider, and usage examples for server/client components.
- **[translation-schema.json](assets/translation-schema.json)** — JSON Schema for validating translation file structure. Enforces required keys, correct types, and namespace organization. Use with `ajv` or IDE validation.
- **[locale-switcher.tsx](assets/locale-switcher.tsx)** — Accessible locale switcher dropdown component with native locale names, flag emoji, keyboard navigation, current locale indicator. Works with next-intl and react-i18next.
- **[date-formatter.ts](assets/date-formatter.ts)** — Zero-dependency utility module wrapping Intl API: date/time formatting, relative time, smart format (relative vs absolute), date ranges, calendar systems, timezone utilities, duration formatting.
