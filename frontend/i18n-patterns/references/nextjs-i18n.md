# Next.js Internationalization Deep Dive

> Complete guide to i18n with Next.js App Router using next-intl, covering routing, middleware, static generation, SEO, and server components.

## Table of Contents

- [App Router i18n with next-intl](#app-router-i18n-with-next-intl)
- [Middleware for Locale Detection](#middleware-for-locale-detection)
- [Static Generation with Locales](#static-generation-with-locales)
- [Dynamic Routes with i18n](#dynamic-routes-with-i18n)
- [Metadata and SEO per Locale](#metadata-and-seo-per-locale)
- [API Route i18n](#api-route-i18n)
- [ISR with Translations](#isr-with-translations)
- [Server Components and i18n](#server-components-and-i18n)
- [Navigation Between Locales](#navigation-between-locales)
- [Cookie-Based Locale Preference](#cookie-based-locale-preference)

---

## App Router i18n with next-intl

### Installation and Project Structure

```bash
npm install next-intl
```

```
app/
├── [locale]/
│   ├── layout.tsx           # locale-aware root layout
│   ├── page.tsx             # home page
│   ├── about/
│   │   └── page.tsx
│   └── dashboard/
│       ├── layout.tsx       # namespace: dashboard
│       └── page.tsx
├── not-found.tsx            # global 404
messages/
├── en.json
├── fr.json
├── ar.json
└── ja.json
middleware.ts
i18n/
├── request.ts               # server-side i18n config
├── routing.ts               # routing configuration
└── navigation.ts            # navigation helpers
next.config.mjs
```

### Configuration Files

```ts
// i18n/routing.ts
import { defineRouting } from 'next-intl/routing';

export const routing = defineRouting({
  locales: ['en', 'fr', 'ar', 'ja'],
  defaultLocale: 'en',
  localePrefix: 'as-needed',  // hide prefix for default locale
  pathnames: {
    '/': '/',
    '/about': {
      en: '/about',
      fr: '/a-propos',
      ar: '/حول',
      ja: '/about',
    },
    '/blog/[slug]': {
      en: '/blog/[slug]',
      fr: '/blog/[slug]',
      ar: '/مدونة/[slug]',
      ja: '/blog/[slug]',
    },
  },
});

export type Locale = (typeof routing.locales)[number];
export type Pathnames = keyof typeof routing.pathnames;
```

```ts
// i18n/request.ts
import { getRequestConfig } from 'next-intl/server';
import { routing } from './routing';

export default getRequestConfig(async ({ requestLocale }) => {
  let locale = await requestLocale;

  if (!locale || !routing.locales.includes(locale as any)) {
    locale = routing.defaultLocale;
  }

  return {
    locale,
    messages: (await import(`../messages/${locale}.json`)).default,
    timeZone: 'UTC',
    now: new Date(),
    formats: {
      dateTime: {
        short: { day: 'numeric', month: 'short', year: 'numeric' },
        long: { day: 'numeric', month: 'long', year: 'numeric', weekday: 'long' },
      },
      number: {
        precise: { maximumFractionDigits: 2 },
      },
    },
  };
});
```

```ts
// i18n/navigation.ts
import { createNavigation } from 'next-intl/navigation';
import { routing } from './routing';

export const { Link, redirect, usePathname, useRouter, getPathname } =
  createNavigation(routing);
```

```ts
// next.config.mjs
import createNextIntlPlugin from 'next-intl/plugin';

const withNextIntl = createNextIntlPlugin('./i18n/request.ts');

/** @type {import('next').NextConfig} */
const nextConfig = {};

export default withNextIntl(nextConfig);
```

### Root Layout

```tsx
// app/[locale]/layout.tsx
import { NextIntlClientProvider } from 'next-intl';
import { getMessages, setRequestLocale } from 'next-intl/server';
import { notFound } from 'next/navigation';
import { routing } from '@/i18n/routing';

export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }));
}

export default async function LocaleLayout({
  children,
  params,
}: {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;

  if (!routing.locales.includes(locale as any)) {
    notFound();
  }

  setRequestLocale(locale);
  const messages = await getMessages();

  return (
    <html lang={locale} dir={locale === 'ar' ? 'rtl' : 'ltr'}>
      <body>
        <NextIntlClientProvider messages={messages}>
          {children}
        </NextIntlClientProvider>
      </body>
    </html>
  );
}
```

### Translation Files Structure

```json
// messages/en.json
{
  "common": {
    "siteName": "MyApp",
    "nav": {
      "home": "Home",
      "about": "About",
      "dashboard": "Dashboard"
    },
    "actions": {
      "save": "Save",
      "cancel": "Cancel",
      "delete": "Delete"
    }
  },
  "home": {
    "title": "Welcome to {siteName}",
    "description": "Build amazing things with i18n support.",
    "stats": {
      "users": "You have {count, plural, =0 {no users} one {# user} other {# users}}."
    }
  },
  "about": {
    "title": "About Us",
    "body": "We've been building software since {year}."
  },
  "dashboard": {
    "title": "Dashboard",
    "lastLogin": "Last login: {date, date, short}",
    "revenue": "Revenue: {amount, number, ::currency/USD}"
  }
}
```

---

## Middleware for Locale Detection

```ts
// middleware.ts
import createMiddleware from 'next-intl/middleware';
import { routing } from './i18n/routing';

export default createMiddleware(routing, {
  localeDetection: true,
});

export const config = {
  matcher: [
    // Match all paths except:
    '/((?!api|_next|_vercel|.*\\..*).*)',
  ],
};
```

### Custom Middleware with Extended Logic

```ts
// middleware.ts — advanced version with geo-detection and A/B testing
import createMiddleware from 'next-intl/middleware';
import { NextRequest, NextResponse } from 'next/server';
import { routing } from './i18n/routing';

const intlMiddleware = createMiddleware(routing);

export default function middleware(request: NextRequest) {
  // Skip locale handling for API routes
  if (request.nextUrl.pathname.startsWith('/api')) {
    return NextResponse.next();
  }

  // Priority: 1) URL locale, 2) cookie, 3) Accept-Language, 4) geo
  const cookieLocale = request.cookies.get('NEXT_LOCALE')?.value;
  const geoCountry = request.geo?.country;

  // Map country to locale as last-resort fallback
  const countryLocaleMap: Record<string, string> = {
    FR: 'fr', DE: 'de', JP: 'ja', SA: 'ar', EG: 'ar', AE: 'ar',
  };

  if (!cookieLocale && geoCountry && countryLocaleMap[geoCountry]) {
    // Set cookie for geo-detected locale so it persists
    const response = intlMiddleware(request);
    const detectedLocale = countryLocaleMap[geoCountry];
    if (routing.locales.includes(detectedLocale as any)) {
      response.cookies.set('NEXT_LOCALE', detectedLocale, {
        maxAge: 365 * 24 * 60 * 60,
        path: '/',
      });
    }
    return response;
  }

  return intlMiddleware(request);
}

export const config = {
  matcher: ['/((?!api|_next|_vercel|.*\\..*).*)',],
};
```

### Locale Detection Priority

```
1. URL path segment:      /fr/about → locale = "fr"
2. NEXT_LOCALE cookie:    cookie value set by locale switcher
3. Accept-Language header: browser language preference
4. Geo-IP (optional):     country → locale mapping
5. Default locale:        "en" (fallback)
```

---

## Static Generation with Locales

### Static Params for All Locales

```tsx
// app/[locale]/page.tsx
import { setRequestLocale } from 'next-intl/server';
import { useTranslations } from 'next-intl';

export default function HomePage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = React.use(params);
  setRequestLocale(locale);
  const t = useTranslations('home');

  return (
    <main>
      <h1>{t('title', { siteName: t('common.siteName') })}</h1>
      <p>{t('description')}</p>
    </main>
  );
}
```

### Static Pages with Dynamic Data

```tsx
// app/[locale]/blog/page.tsx
import { setRequestLocale } from 'next-intl/server';
import { useTranslations } from 'next-intl';
import { getBlogPosts } from '@/lib/blog';

export default async function BlogPage({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  setRequestLocale(locale);
  const posts = await getBlogPosts(locale);
  const t = useTranslations('blog');

  return (
    <section>
      <h1>{t('title')}</h1>
      {posts.map(post => (
        <article key={post.slug}>
          <h2>{post.title}</h2>
          <p>{post.excerpt}</p>
        </article>
      ))}
    </section>
  );
}
```

### Generating Static Params for Dynamic Segments

```tsx
// app/[locale]/blog/[slug]/page.tsx
import { routing } from '@/i18n/routing';
import { setRequestLocale } from 'next-intl/server';
import { getBlogPost, getAllSlugs } from '@/lib/blog';

export async function generateStaticParams() {
  const slugs = await getAllSlugs();
  return routing.locales.flatMap(locale =>
    slugs.map(slug => ({ locale, slug }))
  );
}

export default async function BlogPostPage({
  params,
}: {
  params: Promise<{ locale: string; slug: string }>;
}) {
  const { locale, slug } = await params;
  setRequestLocale(locale);
  const post = await getBlogPost(slug, locale);

  if (!post) notFound();

  return (
    <article>
      <h1>{post.title}</h1>
      <div dangerouslySetInnerHTML={{ __html: post.content }} />
    </article>
  );
}
```

---

## Dynamic Routes with i18n

### Localized Pathnames

```tsx
// Configured in i18n/routing.ts (see above)
// /about → /a-propos (fr), /حول (ar)

// Using the localized Link component:
import { Link } from '@/i18n/navigation';

// Automatically resolves to the correct localized pathname
<Link href="/about">About</Link>
// In fr: renders <a href="/fr/a-propos">
// In ar: renders <a href="/ar/حول">
```

### Catch-All Routes with Locale

```tsx
// app/[locale]/docs/[...slug]/page.tsx
export async function generateStaticParams() {
  const docs = await getAllDocs();
  return routing.locales.flatMap(locale =>
    docs.map(doc => ({
      locale,
      slug: doc.path.split('/'),
    }))
  );
}

export default async function DocPage({
  params,
}: {
  params: Promise<{ locale: string; slug: string[] }>;
}) {
  const { locale, slug } = await params;
  setRequestLocale(locale);
  const path = slug.join('/');
  const doc = await getDoc(path, locale);
  // ...
}
```

### Parallel Routes with i18n

```tsx
// app/[locale]/layout.tsx with parallel routes
export default async function Layout({
  children,
  modal,
  params,
}: {
  children: React.ReactNode;
  modal: React.ReactNode;
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  return (
    <>
      {children}
      {modal}
    </>
  );
}
```

---

## Metadata and SEO per Locale

### Dynamic Metadata with Translations

```tsx
// app/[locale]/layout.tsx
import { getTranslations } from 'next-intl/server';
import { routing } from '@/i18n/routing';

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'metadata' });

  return {
    title: {
      default: t('title'),
      template: `%s | ${t('siteName')}`,
    },
    description: t('description'),
    openGraph: {
      title: t('title'),
      description: t('description'),
      locale,
      alternateLocales: routing.locales.filter(l => l !== locale),
      siteName: t('siteName'),
    },
    twitter: {
      card: 'summary_large_image',
      title: t('title'),
      description: t('description'),
    },
    alternates: {
      canonical: `https://example.com/${locale}`,
      languages: Object.fromEntries(
        routing.locales.map(l => [l, `https://example.com/${l}`])
      ),
    },
  };
}
```

### Page-Level Metadata

```tsx
// app/[locale]/about/page.tsx
import { getTranslations } from 'next-intl/server';

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: 'about' });

  return {
    title: t('title'),
    description: t('metaDescription'),
    alternates: {
      languages: {
        en: '/en/about',
        fr: '/fr/a-propos',
        ar: '/ar/حول',
        ja: '/ja/about',
      },
    },
  };
}
```

### Hreflang Tags

```tsx
// components/HreflangTags.tsx — for additional hreflang control
import { routing } from '@/i18n/routing';
import { getPathname } from '@/i18n/navigation';

export function HreflangTags({ currentLocale, pathname }: {
  currentLocale: string;
  pathname: string;
}) {
  const baseUrl = 'https://example.com';

  return (
    <>
      {routing.locales.map(locale => {
        const localizedPath = getPathname({ locale, href: pathname });
        return (
          <link
            key={locale}
            rel="alternate"
            hrefLang={locale}
            href={`${baseUrl}${localizedPath}`}
          />
        );
      })}
      <link
        rel="alternate"
        hrefLang="x-default"
        href={`${baseUrl}${getPathname({ locale: routing.defaultLocale, href: pathname })}`}
      />
    </>
  );
}
```

### Structured Data (JSON-LD) per Locale

```tsx
// components/LocalizedJsonLd.tsx
export function LocalizedJsonLd({ locale, page }: { locale: string; page: any }) {
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'WebPage',
    name: page.title,
    description: page.description,
    inLanguage: locale,
    url: `https://example.com/${locale}${page.path}`,
    isPartOf: {
      '@type': 'WebSite',
      name: 'MyApp',
      url: 'https://example.com',
    },
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
    />
  );
}
```

---

## API Route i18n

### Route Handlers with Locale

```ts
// app/api/greeting/route.ts
import { getTranslations } from 'next-intl/server';
import { NextRequest, NextResponse } from 'next/server';
import { routing } from '@/i18n/routing';

export async function GET(request: NextRequest) {
  const locale = request.nextUrl.searchParams.get('locale') ?? 'en';

  if (!routing.locales.includes(locale as any)) {
    return NextResponse.json(
      { error: `Unsupported locale: ${locale}` },
      { status: 400 }
    );
  }

  const t = await getTranslations({ locale, namespace: 'api' });

  return NextResponse.json({
    message: t('greeting'),
    locale,
  }, {
    headers: { 'Content-Language': locale },
  });
}
```

### Error Messages in User's Locale

```ts
// lib/api-errors.ts
import { getTranslations } from 'next-intl/server';

export async function createErrorResponse(
  locale: string,
  errorKey: string,
  status: number,
  params?: Record<string, string | number>
) {
  const t = await getTranslations({ locale, namespace: 'errors' });

  return NextResponse.json(
    {
      error: {
        code: errorKey,
        message: t(errorKey, params),
      },
    },
    {
      status,
      headers: { 'Content-Language': locale },
    }
  );
}

// Usage:
// return createErrorResponse('fr', 'notFound', 404);
// → { "error": { "code": "notFound", "message": "Ressource non trouvée" } }
```

### Localized Email Templates

```ts
// app/api/send-welcome/route.ts
export async function POST(request: NextRequest) {
  const { email, locale } = await request.json();
  const t = await getTranslations({ locale, namespace: 'emails.welcome' });

  await sendEmail({
    to: email,
    subject: t('subject'),
    html: `
      <h1>${t('heading')}</h1>
      <p>${t('body')}</p>
      <a href="${t('ctaUrl')}">${t('ctaText')}</a>
    `,
  });

  return NextResponse.json({ success: true });
}
```

---

## ISR with Translations

### Incremental Static Regeneration for Translated Pages

```tsx
// app/[locale]/products/[id]/page.tsx
import { setRequestLocale } from 'next-intl/server';
import { useTranslations } from 'next-intl';
import { getProduct } from '@/lib/products';

// Revalidate product pages every hour
export const revalidate = 3600;

export async function generateStaticParams() {
  // Pre-render top products in all locales
  const topProducts = await getTopProducts(50);
  return routing.locales.flatMap(locale =>
    topProducts.map(p => ({ locale, id: p.id }))
  );
}

export default async function ProductPage({
  params,
}: {
  params: Promise<{ locale: string; id: string }>;
}) {
  const { locale, id } = await params;
  setRequestLocale(locale);
  const product = await getProduct(id, locale);
  const t = useTranslations('products');

  return (
    <div>
      <h1>{product.name}</h1>
      <p>{product.description}</p>
      <span>{t('price', { price: product.price })}</span>
      <span>{t('inStock', { count: product.stock })}</span>
    </div>
  );
}
```

### On-Demand Revalidation per Locale

```ts
// app/api/revalidate/route.ts
import { revalidatePath } from 'next/cache';
import { routing } from '@/i18n/routing';

export async function POST(request: NextRequest) {
  const { path, locale, secret } = await request.json();

  if (secret !== process.env.REVALIDATION_SECRET) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }

  if (locale) {
    // Revalidate specific locale
    revalidatePath(`/${locale}${path}`);
  } else {
    // Revalidate all locales for the given path
    for (const loc of routing.locales) {
      revalidatePath(`/${loc}${path}`);
    }
  }

  return NextResponse.json({ revalidated: true, path, locale: locale ?? 'all' });
}

// Webhook from CMS:
// POST /api/revalidate { "path": "/blog/my-post", "locale": "fr", "secret": "..." }
```

### Revalidation When Translations Update

```ts
// app/api/translations-updated/route.ts
// Called by TMS webhook when translations are updated
export async function POST(request: NextRequest) {
  const { locale, namespace } = await request.json();

  // Revalidate all pages that use the updated namespace
  const affectedPaths = getPathsByNamespace(namespace);
  for (const path of affectedPaths) {
    revalidatePath(`/${locale}${path}`);
  }

  // Also revalidate the layout if common namespace changed
  if (namespace === 'common') {
    revalidatePath(`/${locale}`, 'layout');
  }

  return NextResponse.json({ revalidated: true });
}
```

---

## Server Components and i18n

### Server Component Usage

```tsx
// Server Components — use next-intl server APIs directly
import { useTranslations } from 'next-intl';
import { setRequestLocale } from 'next-intl/server';

export default function ServerComponent({ locale }: { locale: string }) {
  setRequestLocale(locale);
  const t = useTranslations('dashboard');

  return (
    <section>
      <h2>{t('title')}</h2>
      <p>{t('description')}</p>
    </section>
  );
}
```

### Client Component Usage

```tsx
'use client';

import { useTranslations, useLocale, useNow, useTimeZone } from 'next-intl';

export function ClientWidget() {
  const t = useTranslations('widget');
  const locale = useLocale();
  const now = useNow({ updateInterval: 1000 });
  const timeZone = useTimeZone();

  return (
    <div>
      <p>{t('currentTime', { time: now })}</p>
      <p>{t('timezone', { tz: timeZone })}</p>
    </div>
  );
}
```

### Mixing Server and Client Components

```tsx
// app/[locale]/dashboard/page.tsx — Server Component
import { setRequestLocale } from 'next-intl/server';
import { useTranslations } from 'next-intl';
import { LiveCounter } from './LiveCounter';     // Client Component
import { getStats } from '@/lib/stats';

export default async function DashboardPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);
  const t = useTranslations('dashboard');
  const stats = await getStats();

  return (
    <div>
      <h1>{t('title')}</h1>

      {/* Static translated content — rendered on server */}
      <p>{t('stats.totalUsers', { count: stats.totalUsers })}</p>

      {/* Interactive client component with its own translations */}
      <LiveCounter initialCount={stats.activeUsers} />
    </div>
  );
}
```

```tsx
// app/[locale]/dashboard/LiveCounter.tsx — Client Component
'use client';

import { useTranslations } from 'next-intl';
import { useState, useEffect } from 'react';

export function LiveCounter({ initialCount }: { initialCount: number }) {
  const t = useTranslations('dashboard.live');
  const [count, setCount] = useState(initialCount);

  useEffect(() => {
    const ws = new WebSocket('/ws/active-users');
    ws.onmessage = (e) => setCount(JSON.parse(e.data).count);
    return () => ws.close();
  }, []);

  return <span>{t('activeUsers', { count })}</span>;
}
```

### Async Server Component with Format

```tsx
import { getFormatter, getTranslations } from 'next-intl/server';

export default async function StatsSection({ locale }: { locale: string }) {
  const t = await getTranslations({ locale, namespace: 'stats' });
  const format = await getFormatter({ locale });
  const data = await fetchStats();

  return (
    <dl>
      <dt>{t('revenue')}</dt>
      <dd>{format.number(data.revenue, { style: 'currency', currency: 'USD' })}</dd>

      <dt>{t('lastUpdated')}</dt>
      <dd>{format.relativeTime(data.updatedAt)}</dd>

      <dt>{t('users')}</dt>
      <dd>{format.number(data.users, { notation: 'compact' })}</dd>
    </dl>
  );
}
```

---

## Navigation Between Locales

### Locale-Aware Link Component

```tsx
// Already configured via i18n/navigation.ts
import { Link } from '@/i18n/navigation';

// Automatically adds locale prefix and resolves localized pathnames
<Link href="/about">About</Link>
// en → /about (prefix hidden for default locale)
// fr → /fr/a-propos
// ar → /ar/حول

// With explicit locale
<Link href="/about" locale="fr">Version française</Link>
```

### Programmatic Navigation

```tsx
'use client';

import { useRouter, usePathname } from '@/i18n/navigation';
import { useLocale } from 'next-intl';

function SearchForm() {
  const router = useRouter();
  const locale = useLocale();

  function handleSubmit(query: string) {
    router.push(`/search?q=${encodeURIComponent(query)}`);
    // Automatically includes current locale in URL
  }

  function switchLocale(newLocale: string) {
    router.replace(pathname, { locale: newLocale });
    // Navigates to same page in different locale
  }
}
```

### Full Locale Switcher Component

```tsx
'use client';

import { useLocale, useTranslations } from 'next-intl';
import { usePathname, useRouter } from '@/i18n/navigation';
import { routing } from '@/i18n/routing';

const localeNames: Record<string, string> = {
  en: 'English',
  fr: 'Français',
  ar: 'العربية',
  ja: '日本語',
};

export function LocaleSwitcher() {
  const locale = useLocale();
  const router = useRouter();
  const pathname = usePathname();
  const t = useTranslations('common');

  function onChange(newLocale: string) {
    router.replace(pathname, { locale: newLocale });
  }

  return (
    <select
      value={locale}
      onChange={(e) => onChange(e.target.value)}
      aria-label={t('switchLocale')}
    >
      {routing.locales.map((loc) => (
        <option key={loc} value={loc}>
          {localeNames[loc]}
        </option>
      ))}
    </select>
  );
}
```

### Preserving Query Params During Locale Switch

```tsx
'use client';

import { useSearchParams } from 'next/navigation';
import { usePathname, useRouter } from '@/i18n/navigation';

export function switchLocalePreservingParams(
  newLocale: string,
  pathname: string,
  searchParams: URLSearchParams,
  router: ReturnType<typeof useRouter>
) {
  const params = searchParams.toString();
  const fullPath = params ? `${pathname}?${params}` : pathname;
  router.replace(fullPath, { locale: newLocale });
}
```

---

## Cookie-Based Locale Preference

### Setting the Cookie

```tsx
'use client';

import { useRouter, usePathname } from '@/i18n/navigation';

export function useLocaleSwitcher() {
  const router = useRouter();
  const pathname = usePathname();

  function switchLocale(newLocale: string) {
    // Set cookie for locale persistence
    document.cookie = `NEXT_LOCALE=${newLocale};path=/;max-age=${365 * 24 * 60 * 60};samesite=lax`;

    // Navigate to same page with new locale
    router.replace(pathname, { locale: newLocale });
  }

  return { switchLocale };
}
```

### Reading Cookie in Middleware

```ts
// middleware.ts
import createMiddleware from 'next-intl/middleware';
import { routing } from './i18n/routing';

// next-intl middleware automatically reads the NEXT_LOCALE cookie
// Priority: URL path > NEXT_LOCALE cookie > Accept-Language > default
export default createMiddleware(routing, {
  localeDetection: true,  // reads Accept-Language and cookies
});
```

### Server-Side Cookie Handling

```ts
// lib/locale.ts
import { cookies } from 'next/headers';
import { routing } from '@/i18n/routing';

export async function getPreferredLocale(): Promise<string> {
  const cookieStore = await cookies();
  const cookieLocale = cookieStore.get('NEXT_LOCALE')?.value;

  if (cookieLocale && routing.locales.includes(cookieLocale as any)) {
    return cookieLocale;
  }

  return routing.defaultLocale;
}

export async function setLocalePreference(locale: string) {
  const cookieStore = await cookies();
  cookieStore.set('NEXT_LOCALE', locale, {
    path: '/',
    maxAge: 365 * 24 * 60 * 60,
    sameSite: 'lax',
    secure: process.env.NODE_ENV === 'production',
  });
}
```

### Server Action for Locale Switch

```ts
// app/actions.ts
'use server';

import { cookies } from 'next/headers';
import { redirect } from '@/i18n/navigation';

export async function switchLocaleAction(formData: FormData) {
  const locale = formData.get('locale') as string;
  const pathname = formData.get('pathname') as string;

  const cookieStore = await cookies();
  cookieStore.set('NEXT_LOCALE', locale, {
    path: '/',
    maxAge: 365 * 24 * 60 * 60,
  });

  redirect({ href: pathname, locale });
}
```

### Locale Preference with User Account Sync

```ts
// When user logs in, sync their saved locale preference
async function syncLocalePreference(userId: string): Promise<string> {
  const user = await getUser(userId);

  if (user.preferredLocale) {
    // Set cookie to match account preference
    await setLocalePreference(user.preferredLocale);
    return user.preferredLocale;
  }

  // If no account preference, save current cookie/detected locale
  const currentLocale = await getPreferredLocale();
  await updateUser(userId, { preferredLocale: currentLocale });
  return currentLocale;
}
```
