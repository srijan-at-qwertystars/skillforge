// next-intl-setup.ts — Next.js App Router i18n setup with next-intl
//
// This file contains all the pieces needed for next-intl in a Next.js App Router project.
// Copy each section into the corresponding file in your project.
//
// Structure:
//   i18n/routing.ts      — Locale and pathname configuration
//   i18n/request.ts      — Server-side request config
//   i18n/navigation.ts   — Typed Link, redirect, useRouter, usePathname
//   middleware.ts         — Locale detection and routing middleware
//   app/[locale]/layout.tsx — Root layout with provider
//   components/LocaleSwitcher.tsx — Client component for switching locales

// ===========================================================================
// FILE: i18n/routing.ts
// ===========================================================================

import { defineRouting } from 'next-intl/routing';

export const routing = defineRouting({
  locales: ['en', 'fr', 'de', 'es', 'ar', 'ja'] as const,
  defaultLocale: 'en',
  localePrefix: 'as-needed', // hide /en prefix for default locale
  pathnames: {
    '/': '/',
    '/about': {
      en: '/about',
      fr: '/a-propos',
      de: '/ueber-uns',
      es: '/acerca-de',
      ar: '/حول',
      ja: '/about',
    },
    '/contact': {
      en: '/contact',
      fr: '/contact',
      de: '/kontakt',
      es: '/contacto',
      ar: '/اتصل',
      ja: '/contact',
    },
    '/blog/[slug]': {
      en: '/blog/[slug]',
      fr: '/blog/[slug]',
      de: '/blog/[slug]',
      es: '/blog/[slug]',
      ar: '/مدونة/[slug]',
      ja: '/blog/[slug]',
    },
  },
});

export type Locale = (typeof routing.locales)[number];
export type Pathnames = keyof typeof routing.pathnames;

// RTL locales
export const RTL_LOCALES: ReadonlySet<string> = new Set(['ar', 'he', 'fa', 'ur']);
export function isRTL(locale: string): boolean {
  return RTL_LOCALES.has(locale);
}

// ===========================================================================
// FILE: i18n/request.ts
// ===========================================================================

import { getRequestConfig } from 'next-intl/server';
// import { routing } from './routing';

export default getRequestConfig(async ({ requestLocale }) => {
  let locale = await requestLocale;

  // Validate locale
  if (!locale || !routing.locales.includes(locale as any)) {
    locale = routing.defaultLocale;
  }

  return {
    locale,
    messages: (await import(`../messages/${locale}.json`)).default,
    // Default timezone for date formatting
    timeZone: 'UTC',
    // Provide `now` for consistent server rendering
    now: new Date(),
    // Custom format definitions
    formats: {
      dateTime: {
        short: {
          day: 'numeric',
          month: 'short',
          year: 'numeric',
        },
        long: {
          day: 'numeric',
          month: 'long',
          year: 'numeric',
          weekday: 'long',
        },
        time: {
          hour: 'numeric',
          minute: 'numeric',
        },
      },
      number: {
        compact: {
          notation: 'compact',
          maximumFractionDigits: 1,
        },
        currency: {
          style: 'currency',
          currency: 'USD',
        },
      },
    },
  };
});

// ===========================================================================
// FILE: i18n/navigation.ts
// ===========================================================================

import { createNavigation } from 'next-intl/navigation';
// import { routing } from './routing';

export const {
  Link,       // <Link href="/about" /> — auto-localizes
  redirect,   // redirect('/about') — auto-localizes
  usePathname, // returns pathname without locale prefix
  useRouter,   // router.push('/about') — auto-localizes
  getPathname, // getPathname({ locale: 'fr', href: '/about' }) → '/fr/a-propos'
} = createNavigation(routing);

// ===========================================================================
// FILE: middleware.ts
// ===========================================================================

import createMiddleware from 'next-intl/middleware';
// import { routing } from './i18n/routing';

export default createMiddleware(routing, {
  // Enable automatic locale detection from Accept-Language and cookies
  localeDetection: true,
});

export const config = {
  // Match all paths except API routes, Next.js internals, and static files
  matcher: ['/((?!api|_next|_vercel|.*\\..*).*)'],
};

// ===========================================================================
// FILE: app/[locale]/layout.tsx
// ===========================================================================

import { NextIntlClientProvider } from 'next-intl';
import { getMessages, setRequestLocale } from 'next-intl/server';
import { notFound } from 'next/navigation';
// import { routing, isRTL } from '@/i18n/routing';

type Props = {
  children: React.ReactNode;
  params: Promise<{ locale: string }>;
};

// Generate static params for all locales
export function generateStaticParams() {
  return routing.locales.map((locale) => ({ locale }));
}

// Generate metadata with locale-aware title/description
export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  // You can use getTranslations here for translated metadata
  return {
    title: { default: 'MyApp', template: '%s | MyApp' },
    alternates: {
      languages: Object.fromEntries(
        routing.locales.map(l => [l, `https://example.com/${l}`])
      ),
    },
  };
}

export default async function LocaleLayout({ children, params }: Props) {
  const { locale } = await params;

  // Validate locale
  if (!routing.locales.includes(locale as any)) {
    notFound();
  }

  // Enable static rendering
  setRequestLocale(locale);

  // Load messages for the current locale
  const messages = await getMessages();

  return (
    <html lang={locale} dir={isRTL(locale) ? 'rtl' : 'ltr'}>
      <body>
        <NextIntlClientProvider messages={messages}>
          {children}
        </NextIntlClientProvider>
      </body>
    </html>
  );
}

// ===========================================================================
// FILE: next.config.mjs
// ===========================================================================

// import createNextIntlPlugin from 'next-intl/plugin';
//
// const withNextIntl = createNextIntlPlugin('./i18n/request.ts');
//
// /** @type {import('next').NextConfig} */
// const nextConfig = {};
//
// export default withNextIntl(nextConfig);

// ===========================================================================
// Usage Examples
// ===========================================================================

// --- Server Component ---
// import { useTranslations } from 'next-intl';
// import { setRequestLocale } from 'next-intl/server';
//
// export default function AboutPage({ params }: { params: Promise<{ locale: string }> }) {
//   const { locale } = React.use(params);
//   setRequestLocale(locale);
//   const t = useTranslations('about');
//   return <h1>{t('title')}</h1>;
// }

// --- Client Component ---
// 'use client';
// import { useTranslations, useLocale } from 'next-intl';
//
// export function WelcomeBanner() {
//   const t = useTranslations('home');
//   const locale = useLocale();
//   return <p>{t('welcome', { name: 'User' })}</p>;
// }

// --- Server-side translation (API routes, metadata) ---
// import { getTranslations } from 'next-intl/server';
//
// export async function generateMetadata({ params }) {
//   const { locale } = await params;
//   const t = await getTranslations({ locale, namespace: 'about' });
//   return { title: t('title') };
// }
