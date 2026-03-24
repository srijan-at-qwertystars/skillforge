// i18n-config.ts — Complete i18n configuration for react-i18next
//
// Copy into your project as src/i18n.ts or src/lib/i18n.ts
// Then import at your app entry point: import './i18n';
//
// Features:
//   - Namespace-based translation loading (lazy per route)
//   - Browser language detection (URL, cookie, localStorage, navigator)
//   - Fallback chain with regional → language → default
//   - Type-safe translation keys (see CustomTypeOptions)
//   - Interpolation with React component support
//   - Missing key handler for development debugging
//   - Plural rules via ICU format

import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import Backend from 'i18next-http-backend';
import LanguageDetector from 'i18next-browser-languagedetector';

// ---------------------------------------------------------------------------
// Configuration constants
// ---------------------------------------------------------------------------

export const SUPPORTED_LOCALES = ['en', 'fr', 'de', 'es', 'ja', 'ar', 'zh-Hans', 'pt-BR'] as const;
export type SupportedLocale = (typeof SUPPORTED_LOCALES)[number];

export const DEFAULT_LOCALE: SupportedLocale = 'en';

export const NAMESPACES = ['common', 'auth', 'dashboard', 'settings', 'errors'] as const;
export type Namespace = (typeof NAMESPACES)[number];

export const DEFAULT_NS: Namespace = 'common';

// RTL locales for layout direction
export const RTL_LOCALES: ReadonlySet<string> = new Set(['ar', 'he', 'fa', 'ur']);

// ---------------------------------------------------------------------------
// Type-safe resource definitions (enable with TypeScript)
// ---------------------------------------------------------------------------

// Uncomment and adjust paths to enable compile-time key checking:
// declare module 'react-i18next' {
//   interface CustomTypeOptions {
//     defaultNS: typeof DEFAULT_NS;
//     resources: {
//       common: typeof import('../public/locales/en/common.json');
//       auth: typeof import('../public/locales/en/auth.json');
//       dashboard: typeof import('../public/locales/en/dashboard.json');
//       settings: typeof import('../public/locales/en/settings.json');
//       errors: typeof import('../public/locales/en/errors.json');
//     };
//   }
// }

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

i18n
  // Load translations from server / static files
  .use(Backend)
  // Detect user language
  .use(LanguageDetector)
  // Bind to React
  .use(initReactI18next)
  .init({
    // --- Language settings ---
    supportedLngs: [...SUPPORTED_LOCALES],
    fallbackLng: {
      'pt-BR': ['pt', 'en'],
      'zh-Hant': ['zh-Hans', 'en'],
      'de-AT': ['de', 'en'],
      'es-MX': ['es', 'en'],
      'fr-CA': ['fr', 'en'],
      default: ['en'],
    },
    nonExplicitSupportedLngs: true, // 'de-AT' matches 'de'

    // --- Namespace settings ---
    ns: [...NAMESPACES],
    defaultNS: DEFAULT_NS,
    fallbackNS: 'common', // fall back to common namespace

    // --- Backend: where to load translations from ---
    backend: {
      loadPath: '/locales/{{lng}}/{{ns}}.json',
      // Optional: add query param for cache busting
      queryStringParams: { v: process.env.REACT_APP_VERSION ?? '1.0.0' },
      // Retry on failure
      requestOptions: {
        cache: 'default',
      },
    },

    // --- Language detection ---
    detection: {
      // Priority order for detecting language
      order: ['querystring', 'cookie', 'localStorage', 'navigator', 'htmlTag'],
      // Query parameter name (?lng=fr)
      lookupQuerystring: 'lng',
      // Cookie name
      lookupCookie: 'i18next',
      // localStorage key
      lookupLocalStorage: 'i18nextLng',
      // Cache detected language in these stores
      caches: ['cookie', 'localStorage'],
      // Cookie options
      cookieMinutes: 365 * 24 * 60,
      cookieDomain: typeof window !== 'undefined' ? window.location.hostname : undefined,
    },

    // --- Interpolation ---
    interpolation: {
      escapeValue: false, // React already escapes
      formatSeparator: ',',
      format(value, format, lng) {
        // Custom formatters — use via {{value, format}}
        if (format === 'uppercase') return String(value).toUpperCase();
        if (format === 'lowercase') return String(value).toLowerCase();
        if (format === 'number') return new Intl.NumberFormat(lng).format(value);
        if (format === 'currency') {
          return new Intl.NumberFormat(lng, {
            style: 'currency',
            currency: 'USD',
          }).format(value);
        }
        if (value instanceof Date) {
          return new Intl.DateTimeFormat(lng, { dateStyle: 'medium' }).format(value);
        }
        return String(value);
      },
    },

    // --- React-specific ---
    react: {
      useSuspense: true,         // enable Suspense for loading states
      bindI18n: 'languageChanged loaded',
      bindI18nStore: 'added removed',
      transEmptyNodeValue: '',
      transSupportBasicHtmlNodes: true,
      transKeepBasicHtmlNodesFor: ['br', 'strong', 'i', 'p', 'em', 'b', 'u', 'code'],
    },

    // --- Missing keys ---
    saveMissing: process.env.NODE_ENV === 'development',
    missingKeyHandler(lngs, ns, key, fallbackValue) {
      if (process.env.NODE_ENV === 'development') {
        console.warn(
          `[i18n] Missing translation: ${ns}:${key}`,
          `\n  Locales: ${lngs.join(', ')}`,
          `\n  Fallback: "${fallbackValue}"`
        );
      }
    },

    // --- Debugging ---
    debug: process.env.NODE_ENV === 'development' && process.env.REACT_APP_I18N_DEBUG === 'true',
  });

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Check if the given locale uses right-to-left writing direction. */
export function isRTL(locale: string): boolean {
  return RTL_LOCALES.has(locale.split('-')[0]);
}

/** Get the document direction for a locale. */
export function getDirection(locale: string): 'ltr' | 'rtl' {
  return isRTL(locale) ? 'rtl' : 'ltr';
}

/** Update document direction and lang when locale changes. */
i18n.on('languageChanged', (lng: string) => {
  const dir = getDirection(lng);
  document.documentElement.lang = lng;
  document.documentElement.dir = dir;
});

/** Preload a namespace for the current locale (useful before route transitions). */
export async function preloadNamespace(ns: Namespace): Promise<void> {
  if (!i18n.hasLoadedNamespace(ns)) {
    await i18n.loadNamespaces(ns);
  }
}

/** Preload a locale (useful for locale switcher hover). */
export async function preloadLocale(locale: SupportedLocale): Promise<void> {
  await i18n.loadLanguages(locale);
}

export default i18n;
