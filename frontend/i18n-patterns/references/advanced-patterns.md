# Advanced i18n Patterns

> Dense reference for advanced internationalization techniques in JavaScript/TypeScript and React applications.

## Table of Contents

- [Context-Aware Translations](#context-aware-translations)
- [Interpolation with Components (Trans)](#interpolation-with-components-trans)
- [Namespaced Translations for Micro-Frontends](#namespaced-translations-for-micro-frontends)
- [Dynamic Locale Loading](#dynamic-locale-loading)
- [Translation Key Naming Conventions](#translation-key-naming-conventions)
- [Handling Missing Translations](#handling-missing-translations)
- [Intl.Segmenter for Text Processing](#intlsegmenter-for-text-processing)
- [Relative Date/Time Formatting Across Locales](#relative-datetime-formatting-across-locales)
- [Currency Conversion Display Patterns](#currency-conversion-display-patterns)
- [Number System Support](#number-system-support)

---

## Context-Aware Translations

Translations often need context beyond simple key-value mapping. ICU MessageFormat `select` handles grammatical gender, formality, and semantic context.

### Grammatical Gender Context

```ts
// translation key: "user.action"
// en: "{gender, select, male {He} female {She} other {They}} updated {gender, select, male {his} female {her} other {their}} profile."
// de: "{gender, select, male {Er hat sein Profil aktualisiert.} female {Sie hat ihr Profil aktualisiert.} other {Profil wurde aktualisiert.}}"

t('user.action', { gender: user.gender });
```

### Formality Levels (T-V Distinction)

Languages like German, French, Japanese require formal/informal variants.

```ts
// Store formality preference per user session
type Formality = 'formal' | 'informal';

// Key structure: namespace.key.formality
// de/common.json:
// "greeting.formal": "Guten Tag, wie geht es Ihnen?"
// "greeting.informal": "Hey, wie geht's?"

function tWithFormality(key: string, formality: Formality, params?: object): string {
  const formalKey = `${key}.${formality}`;
  if (i18n.exists(formalKey)) return t(formalKey, params);
  return t(key, params); // fallback to default
}
```

### Context-Based Plurals

```ts
// Some languages have different plural forms based on context (e.g., counting objects vs. people)
// Polish: "2 pliki" (files) vs "2 osoby" (people) — different plural form for 2-4
// Use select + plural nesting:
// "items.count": "{type, select,
//   file {{count, plural, one {# plik} few {# pliki} many {# plików} other {# pliku}}}
//   person {{count, plural, one {# osoba} few {# osoby} many {# osób} other {# osoby}}}
//   other {{count, plural, one {# element} few {# elementy} many {# elementów} other {# elementu}}}
// }"
```

### Date Context Sensitivity

```ts
// "Last seen" context differs from "Created on" context in some languages
// Use separate keys rather than composing:
// ✗ t('lastSeen') + formatDate(d)        — word order may differ
// ✓ t('lastSeen', { date: formatDate(d, locale) })  — translator controls placement

// Russian example where date case changes with context:
// "Создано 5 марта" (Created March 5 — genitive)
// "Сегодня 5 март" (Today is March 5 — nominative)
```

---

## Interpolation with Components (Trans)

### react-i18next Trans Component

The `Trans` component enables embedding React components inside translated strings without string concatenation.

```tsx
import { Trans } from 'react-i18next';

// en.json: "terms": "By signing up, you agree to our <termsLink>Terms</termsLink> and <privacyLink>Privacy Policy</privacyLink>."
<Trans
  i18nKey="terms"
  components={{
    termsLink: <a href="/terms" className="underline" />,
    privacyLink: <a href="/privacy" className="underline" />,
  }}
/>
```

### Nested Components and Rich Text

```tsx
// en.json: "promo": "Get <bold><discount>20%</discount> off</bold> your first order!"
<Trans
  i18nKey="promo"
  components={{
    bold: <strong />,
    discount: <span className="text-red-600 text-xl" />,
  }}
/>
// Output: Get <strong><span class="text-red-600 text-xl">20%</span> off</strong> your first order!
```

### Dynamic Count with Components

```tsx
// en.json: "cart": "You have <bold>{{count}}</bold> {{count, plural, one {item} other {items}}} in your cart."
<Trans
  i18nKey="cart"
  values={{ count: cartItems.length }}
  components={{ bold: <strong className="font-semibold" /> }}
/>
```

### FormatJS Rich Text (react-intl)

```tsx
import { FormattedMessage } from 'react-intl';

// en.json: "welcome": "Welcome to <app>MyApp</app>. Read the <link>docs</link> to learn more."
<FormattedMessage
  id="welcome"
  values={{
    app: (chunks) => <span className="font-bold text-blue-600">{chunks}</span>,
    link: (chunks) => <a href="/docs" className="underline">{chunks}</a>,
  }}
/>
```

### Handling Lists Inside Translations

```tsx
// Rather than joining items manually, pass the formatted list:
const intl = useIntl();
const formattedList = new Intl.ListFormat(intl.locale, { type: 'conjunction' })
  .format(selectedItems.map(i => i.name));

t('selected.summary', { items: formattedList, count: selectedItems.length });
// en: "You selected {items} ({count, plural, one {# item} other {# items}} total)."
```

---

## Namespaced Translations for Micro-Frontends

### Namespace Isolation Strategy

Each micro-frontend owns its translation namespace to prevent key collisions.

```
locales/
├── en/
│   ├── shell.json          # app shell / layout
│   ├── mfe-checkout.json   # checkout micro-frontend
│   ├── mfe-catalog.json    # catalog micro-frontend
│   └── shared.json         # shared components (buttons, errors)
```

### Dynamic Namespace Registration

```ts
// Each MFE registers its translations at mount time
export function mountCheckoutMFE(container: HTMLElement, i18nInstance: i18n) {
  // Load MFE-specific translations
  const loadTranslations = async (lng: string) => {
    const translations = await import(`./locales/${lng}/checkout.json`);
    i18nInstance.addResourceBundle(lng, 'mfe-checkout', translations.default, true, true);
  };

  // Load for current and fallback language
  await Promise.all([
    loadTranslations(i18nInstance.language),
    loadTranslations(i18nInstance.options.fallbackLng as string),
  ]);

  // MFE components use their namespace
  // const { t } = useTranslation('mfe-checkout');
}
```

### Shared Translation Contract

```ts
// shared-i18n-types.ts — shared across MFEs
interface SharedTranslationKeys {
  'common.save': string;
  'common.cancel': string;
  'common.loading': string;
  'error.generic': string;
  'error.network': string;
  'error.notFound': string;
}

// Each MFE's translations extend shared:
// const { t } = useTranslation(['mfe-checkout', 'shared']);
// t('mfe-checkout:cart.title')  — MFE-specific
// t('shared:common.save')       — shared across MFEs
```

### Federated Translation Loading (Module Federation)

```ts
// webpack.config.js — expose translations as federated module
new ModuleFederationPlugin({
  name: 'checkout',
  exposes: {
    './translations': './src/locales/index.ts',
  },
});

// Host app loads MFE translations dynamically:
const checkoutTranslations = await import('checkout/translations');
i18n.addResourceBundle('en', 'mfe-checkout', checkoutTranslations.en);
```

---

## Dynamic Locale Loading

### Webpack Dynamic Imports

```ts
// Chunk translations by locale — only load the active locale
async function loadLocale(locale: string): Promise<void> {
  // Webpack magic comment creates separate chunk per locale
  const messages = await import(
    /* webpackChunkName: "locale-[request]" */
    `./locales/${locale}/messages.json`
  );
  i18n.addResourceBundle(locale, 'translation', messages.default);
}

// Preload likely-needed locales
function preloadLocale(locale: string) {
  import(/* webpackPrefetch: true */ `./locales/${locale}/messages.json`);
}
```

### Vite Glob Import

```ts
// Vite glob import — lazy load all locale files
const localeModules = import.meta.glob('./locales/*/messages.json');

async function loadLocale(locale: string): Promise<Record<string, string>> {
  const path = `./locales/${locale}/messages.json`;
  if (!(path in localeModules)) {
    console.warn(`Locale ${locale} not found, falling back to 'en'`);
    return loadLocale('en');
  }
  const mod = await localeModules[path]() as { default: Record<string, string> };
  return mod.default;
}

// Eager load only default locale, lazy load the rest
const defaultMessages = import.meta.glob('./locales/en/messages.json', { eager: true });
```

### Namespace-Level Lazy Loading

```ts
// Load namespaces on-demand per route
const routeNamespaces: Record<string, string[]> = {
  '/dashboard': ['dashboard', 'charts'],
  '/settings': ['settings', 'account'],
  '/checkout': ['checkout', 'payment'],
};

async function loadRouteTranslations(path: string, locale: string) {
  const namespaces = routeNamespaces[path] ?? ['common'];
  await Promise.all(
    namespaces
      .filter(ns => !i18n.hasResourceBundle(locale, ns))
      .map(async ns => {
        const msgs = await import(`./locales/${locale}/${ns}.json`);
        i18n.addResourceBundle(locale, ns, msgs.default);
      })
  );
}

// Use with React Router loader:
export const loader = async ({ params }) => {
  await loadRouteTranslations(params.path, i18n.language);
  return null;
};
```

### Service Worker Caching for Translations

```ts
// sw.js — cache translation bundles for offline support
const TRANSLATION_CACHE = 'i18n-v1';
self.addEventListener('fetch', (event) => {
  if (event.request.url.includes('/locales/')) {
    event.respondWith(
      caches.match(event.request).then(cached =>
        cached || fetch(event.request).then(response => {
          const clone = response.clone();
          caches.open(TRANSLATION_CACHE).then(cache => cache.put(event.request, clone));
          return response;
        })
      )
    );
  }
});
```

---

## Translation Key Naming Conventions

### Recommended Structure

```
<namespace>.<feature>.<element>.<variant>

Examples:
  common.button.save              → "Save"
  common.button.cancel            → "Cancel"
  auth.login.title                → "Sign In"
  auth.login.error.invalidEmail   → "Please enter a valid email address."
  dashboard.chart.tooltip.revenue → "Revenue for {month}"
  shop.product.price.sale         → "Sale: {price}"
  shop.cart.items.count           → "{count, plural, one {# item} other {# items}}"
```

### Rules

| Rule | Example | Rationale |
|------|---------|-----------|
| Use dot notation | `auth.login.title` | Hierarchical, IDE-friendly |
| Lowercase with camelCase segments | `shop.productCard.addToCart` | Consistency |
| Prefix with namespace | `checkout:summary.total` | MFE isolation |
| Use descriptive names | `error.networkTimeout` not `err1` | Translator context |
| Keep keys stable | Never rename without migration | Breaks TMS history |
| Group by feature, not by UI component | `auth.login.*` not `button.login.*` | Easier for translators |
| Include action for interactive elements | `button.save`, `link.learnMore` | Clarifies element type |

### Type-Safe Keys

```ts
// Generate types from translation JSON
// en.json: { "auth": { "login": { "title": "Sign In", "submit": "Log In" } } }

type NestedKeyOf<T, Prefix extends string = ''> = T extends object
  ? { [K in keyof T & string]:
      T[K] extends object
        ? NestedKeyOf<T[K], `${Prefix}${K}.`>
        : `${Prefix}${K}`
    }[keyof T & string]
  : never;

type TranslationKeys = NestedKeyOf<typeof import('./locales/en.json')>;
// → "auth.login.title" | "auth.login.submit" | ...

// Usage with react-i18next:
declare module 'react-i18next' {
  interface CustomTypeOptions {
    defaultNS: 'common';
    resources: {
      common: typeof import('./locales/en/common.json');
      auth: typeof import('./locales/en/auth.json');
    };
  }
}
```

---

## Handling Missing Translations

### Fallback Strategies

```ts
i18n.init({
  fallbackLng: {
    'pt-BR': ['pt', 'en'],     // Brazilian Portuguese → Portuguese → English
    'zh-Hant': ['zh-Hans', 'en'], // Traditional Chinese → Simplified → English
    default: ['en'],
  },
  // Log missing keys in development
  saveMissing: process.env.NODE_ENV === 'development',
  missingKeyHandler: (lngs, ns, key, fallbackValue) => {
    console.warn(`[i18n] Missing: ${ns}:${key} for ${lngs.join(', ')}`);
    // Optional: send to monitoring service
    if (process.env.NODE_ENV === 'production') {
      reportMissingTranslation({ key, namespace: ns, locales: lngs });
    }
  },
});
```

### Missing Key Reporter

```ts
// Batch missing key reports to avoid flooding
class MissingKeyReporter {
  private buffer: Map<string, Set<string>> = new Map();
  private flushTimer: ReturnType<typeof setTimeout> | null = null;

  report(key: string, locale: string) {
    if (!this.buffer.has(key)) this.buffer.set(key, new Set());
    this.buffer.get(key)!.add(locale);

    if (!this.flushTimer) {
      this.flushTimer = setTimeout(() => this.flush(), 5000);
    }
  }

  private async flush() {
    const entries = Array.from(this.buffer.entries()).map(([key, locales]) => ({
      key,
      locales: Array.from(locales),
    }));
    this.buffer.clear();
    this.flushTimer = null;

    await fetch('/api/i18n/missing', {
      method: 'POST',
      body: JSON.stringify({ entries }),
    });
  }
}
```

### Graceful Degradation UI

```tsx
function TranslatedText({ id, fallback, ...params }: {
  id: string;
  fallback?: string;
  [key: string]: unknown;
}) {
  const { t, i18n } = useTranslation();
  const translated = t(id, params);

  // Detect untranslated key (i18next returns the key itself)
  if (translated === id) {
    if (process.env.NODE_ENV === 'development') {
      return <span className="bg-yellow-200 border border-yellow-500" title={`Missing: ${id}`}>
        {fallback ?? id}
      </span>;
    }
    return <>{fallback ?? translated}</>;
  }
  return <>{translated}</>;
}
```

---

## Intl.Segmenter for Text Processing

### Word Segmentation for CJK Text

CJK languages (Chinese, Japanese, Korean) don't use spaces between words. `Intl.Segmenter` provides locale-aware word boundaries.

```ts
function getWords(text: string, locale: string): string[] {
  const segmenter = new Intl.Segmenter(locale, { granularity: 'word' });
  return [...segmenter.segment(text)]
    .filter(seg => seg.isWordLike)
    .map(seg => seg.segment);
}

getWords('東京スカイツリーは高い塔です', 'ja');
// → ["東京", "スカイツリー", "は", "高い", "塔", "です"]

getWords('今天天气很好', 'zh');
// → ["今天", "天气", "很", "好"]
```

### Sentence Segmentation

```ts
function getSentences(text: string, locale: string): string[] {
  const segmenter = new Intl.Segmenter(locale, { granularity: 'sentence' });
  return [...segmenter.segment(text)].map(seg => seg.segment.trim()).filter(Boolean);
}

// Useful for truncating text at sentence boundaries rather than mid-word
function truncateAtSentence(text: string, locale: string, maxLength: number): string {
  const sentences = getSentences(text, locale);
  let result = '';
  for (const sentence of sentences) {
    if ((result + sentence).length > maxLength) break;
    result += sentence + ' ';
  }
  return result.trim() || sentences[0]; // at minimum return first sentence
}
```

### Grapheme Cluster Segmentation

```ts
// Character counting that respects grapheme clusters (emoji, combined characters)
function graphemeLength(text: string, locale: string): number {
  const segmenter = new Intl.Segmenter(locale, { granularity: 'grapheme' });
  return [...segmenter.segment(text)].length;
}

graphemeLength('👨‍👩‍👧‍👦', 'en');  // → 1 (family emoji = 1 grapheme)
graphemeLength('café', 'fr');       // → 4 (é = 1 grapheme)

// Use for character limits in forms — .length gives wrong count for emoji/combining chars
function truncateGraphemes(text: string, locale: string, max: number): string {
  const segmenter = new Intl.Segmenter(locale, { granularity: 'grapheme' });
  const segments = [...segmenter.segment(text)];
  if (segments.length <= max) return text;
  return segments.slice(0, max).map(s => s.segment).join('') + '…';
}
```

---

## Relative Date/Time Formatting Across Locales

### Comprehensive Relative Time Utility

```ts
type TimeUnit = 'second' | 'minute' | 'hour' | 'day' | 'week' | 'month' | 'year';

interface RelativeTimeOptions {
  locale: string;
  numeric?: 'always' | 'auto';       // "1 day ago" vs "yesterday"
  style?: 'long' | 'short' | 'narrow'; // "in 3 months" vs "in 3 mo." vs "in 3mo."
  now?: Date;
}

function formatRelativeTime(date: Date, options: RelativeTimeOptions): string {
  const { locale, numeric = 'auto', style = 'long', now = new Date() } = options;
  const diffMs = date.getTime() - now.getTime();
  const diffSec = diffMs / 1000;
  const absDiff = Math.abs(diffSec);

  const units: [TimeUnit, number][] = [
    ['year', 31536000],
    ['month', 2592000],
    ['week', 604800],
    ['day', 86400],
    ['hour', 3600],
    ['minute', 60],
    ['second', 1],
  ];

  const rtf = new Intl.RelativeTimeFormat(locale, { numeric, style });

  for (const [unit, seconds] of units) {
    if (absDiff >= seconds || unit === 'second') {
      return rtf.format(Math.round(diffSec / seconds), unit);
    }
  }
  return rtf.format(0, 'second');
}

// Examples:
// formatRelativeTime(yesterday, { locale: 'en' })        → "yesterday"
// formatRelativeTime(yesterday, { locale: 'ja' })        → "昨日"
// formatRelativeTime(nextWeek, { locale: 'ar-EG' })      → "خلال أسبوع واحد"
// formatRelativeTime(twoHoursAgo, { locale: 'de', style: 'short' }) → "vor 2 Std."
```

### Smart Formatting with Absolute Date Fallback

```ts
// Show relative time for recent dates, absolute for older dates
function smartFormatDate(date: Date, locale: string, now = new Date()): string {
  const diffMs = Math.abs(now.getTime() - date.getTime());
  const ONE_WEEK = 7 * 24 * 60 * 60 * 1000;

  if (diffMs < ONE_WEEK) {
    return formatRelativeTime(date, { locale });
  }

  // Same year: show month and day
  if (date.getFullYear() === now.getFullYear()) {
    return new Intl.DateTimeFormat(locale, { month: 'short', day: 'numeric' }).format(date);
  }

  // Different year: include year
  return new Intl.DateTimeFormat(locale, { dateStyle: 'medium' }).format(date);
}
```

### Calendar System Support

```ts
// Some locales use non-Gregorian calendars
new Intl.DateTimeFormat('fa-IR', { dateStyle: 'full', calendar: 'persian' })
  .format(new Date('2024-03-20'));
// → "۱۴۰۳ فروردین ۱, جمعه" (Persian Solar Hijri calendar)

new Intl.DateTimeFormat('th-TH', { dateStyle: 'long', calendar: 'buddhist' })
  .format(new Date('2024-03-15'));
// → "15 มีนาคม 2567" (Buddhist Era — Gregorian + 543)

new Intl.DateTimeFormat('ja-JP', { dateStyle: 'long', calendar: 'japanese' })
  .format(new Date('2024-03-15'));
// → "令和6年3月15日" (Japanese Imperial Era)
```

---

## Currency Conversion Display Patterns

### Multi-Currency Display

```ts
interface PriceDisplay {
  amount: number;
  currency: string;
  locale: string;
  converted?: { amount: number; currency: string };
}

function formatPrice({ amount, currency, locale, converted }: PriceDisplay): string {
  const primary = new Intl.NumberFormat(locale, {
    style: 'currency',
    currency,
    currencyDisplay: 'narrowSymbol',
  }).format(amount);

  if (!converted) return primary;

  const secondary = new Intl.NumberFormat(locale, {
    style: 'currency',
    currency: converted.currency,
    currencyDisplay: 'narrowSymbol',
    maximumFractionDigits: 0,
  }).format(converted.amount);

  return `${primary} (≈${secondary})`;
}

// formatPrice({ amount: 29.99, currency: 'EUR', locale: 'de-DE',
//   converted: { amount: 32.50, currency: 'USD' } })
// → "29,99 € (≈$33)"
```

### Currency Range and Approximation

```ts
// Price ranges with locale-aware formatting
function formatPriceRange(min: number, max: number, currency: string, locale: string): string {
  const fmt = new Intl.NumberFormat(locale, { style: 'currency', currency });
  return fmt.formatRange(min, max);
  // en-US: "$10.00 – $50.00"
  // de-DE: "10,00 € – 50,00 €"
}

// "Starting from" pattern
// en: "From {price}"  de: "Ab {price}"  ja: "{price}から"
function formatStartingPrice(amount: number, currency: string, locale: string): string {
  const price = new Intl.NumberFormat(locale, { style: 'currency', currency }).format(amount);
  return t('price.startingFrom', { price });
}
```

### Accounting vs. Standard Notation

```ts
// Accounting sign display: negative values in parentheses
new Intl.NumberFormat('en-US', {
  style: 'currency', currency: 'USD', signDisplay: 'accounting',
}).format(-1234.56);
// → "($1,234.56)"  — accounting format

new Intl.NumberFormat('en-US', {
  style: 'currency', currency: 'USD', signDisplay: 'exceptZero',
}).format(1234.56);
// → "+$1,234.56"  — always show sign except for zero
```

---

## Number System Support

### Using Alternate Numbering Systems

```ts
// Arabic-Indic numerals
new Intl.NumberFormat('ar-EG', { numberingSystem: 'arab' }).format(1234567);
// → "١٬٢٣٤٬٥٦٧"

// Devanagari numerals
new Intl.NumberFormat('hi-IN', { numberingSystem: 'deva' }).format(1234567);
// → "१२,३४,५६७"  (note: Indian grouping style with lakhs/crores)

// Thai numerals
new Intl.NumberFormat('th-TH', { numberingSystem: 'thai' }).format(1234567);
// → "๑,๒๓๔,๕๖๗"

// Traditional Chinese numerals (financial)
new Intl.NumberFormat('zh-TW', { numberingSystem: 'hanidec' }).format(1234);
// → "一,二三四"
```

### Locale-Default Numbering System Detection

```ts
// Determine the default numbering system for a locale
function getNumberingSystem(locale: string): string {
  const parts = new Intl.NumberFormat(locale).formatToParts(0);
  const integerPart = parts.find(p => p.type === 'integer');
  if (!integerPart) return 'latn';

  // Check if the digit is in Latin range
  const charCode = integerPart.value.charCodeAt(0);
  if (charCode >= 0x30 && charCode <= 0x39) return 'latn';      // 0-9
  if (charCode >= 0x660 && charCode <= 0x669) return 'arab';     // ٠-٩
  if (charCode >= 0x966 && charCode <= 0x96F) return 'deva';     // ०-९
  return 'unknown';
}
```

### Number Input Parsing for Different Locales

```ts
// Parse locale-formatted number strings back to numbers
function parseLocalizedNumber(value: string, locale: string): number {
  const parts = new Intl.NumberFormat(locale).formatToParts(1234.5);
  const groupSep = parts.find(p => p.type === 'group')?.value ?? ',';
  const decimalSep = parts.find(p => p.type === 'decimal')?.value ?? '.';

  const normalized = value
    .replace(new RegExp(`\\${groupSep}`, 'g'), '')
    .replace(new RegExp(`\\${decimalSep}`), '.');

  return parseFloat(normalized);
}

parseLocalizedNumber('1.234,56', 'de-DE');  // → 1234.56
parseLocalizedNumber('1,234.56', 'en-US');  // → 1234.56
parseLocalizedNumber('١٬٢٣٤٫٥٦', 'ar-EG'); // → 1234.56 (needs extended regex for Arabic digits)
```

### Indian Number Grouping

```ts
// Indian numbering: lakhs (1,00,000) and crores (1,00,00,000)
new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR' }).format(12345678.9);
// → "₹1,23,45,678.90"

new Intl.NumberFormat('hi-IN', {
  style: 'currency', currency: 'INR',
  notation: 'compact',
}).format(10000000);
// → "₹1 क." (1 crore)
```
