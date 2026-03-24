// =============================================================================
// nuxt.config.ts — Production-ready Nuxt 3 configuration template
//
// Usage: Copy to project root and customize. Remove unused sections.
// Docs: https://nuxt.com/docs/api/nuxt-config
// =============================================================================

export default defineNuxtConfig({
  // ---- Compatibility & Rendering ----
  compatibilityDate: '2024-11-01',
  ssr: true,

  // ---- Modules ----
  modules: [
    '@pinia/nuxt',
    '@nuxt/eslint',
    '@nuxt/image',
    '@nuxt/fonts',
    // '@nuxt/ui',           // Uncomment for Nuxt UI components
    // '@nuxt/content',      // Uncomment for Markdown/YAML content
    // '@nuxtjs/i18n',       // Uncomment for internationalization
    // '@nuxtseo/module',    // Uncomment for SEO (sitemap, robots, og-image)
    // '@nuxt/test-utils',   // Uncomment for testing
  ],

  // ---- Pinia State Management ----
  pinia: {
    storesDirs: ['./stores/**'],
  },

  // ---- Global CSS ----
  css: ['~/assets/css/main.css'],

  // ---- App Head Defaults ----
  app: {
    head: {
      htmlAttrs: { lang: 'en' },
      title: 'My App',
      meta: [
        { charset: 'utf-8' },
        { name: 'viewport', content: 'width=device-width, initial-scale=1' },
        { name: 'description', content: 'My Nuxt 3 application' },
      ],
      link: [{ rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg' }],
    },
    pageTransition: { name: 'page', mode: 'out-in' },
  },

  // ---- Runtime Config (env vars) ----
  runtimeConfig: {
    // Server-only — override with NUXT_<KEY>
    dbUrl: '',
    apiSecret: '',
    // Public — override with NUXT_PUBLIC_<KEY>
    public: {
      apiBase: '/api',
      appName: 'My App',
    },
  },

  // ---- Route Rules (hybrid rendering) ----
  routeRules: {
    '/':           { prerender: true },
    // '/blog/**': { isr: 3600 },             // ISR: revalidate hourly
    // '/app/**':  { ssr: false },             // SPA mode
    // '/api/**':  { cors: true },             // CORS headers
  },

  // ---- Auto-Imports ----
  imports: {
    dirs: ['stores'],
  },

  // ---- Components ----
  components: [
    { path: '~/components', pathPrefix: false },
    // { path: '~/components/ui', prefix: 'Ui' },
  ],

  // ---- Build ----
  build: {
    transpile: [],
  },

  // ---- Vite Config ----
  vite: {
    css: {
      preprocessorOptions: {
        // scss: { additionalData: '@use "~/assets/scss/vars" as *;' },
      },
    },
  },

  // ---- Nitro Server ----
  nitro: {
    // preset: 'node-server', // vercel | netlify | cloudflare-pages
    compressPublicAssets: true,
    prerender: {
      routes: ['/sitemap.xml'],
      crawlLinks: true,
    },
  },

  // ---- Image Optimization ----
  image: {
    quality: 80,
    formats: ['avif', 'webp'],
    // provider: 'cloudinary',
  },

  // ---- TypeScript ----
  typescript: {
    strict: true,
  },

  // ---- DevTools ----
  devtools: { enabled: true },

  // ---- Experimental Features ----
  experimental: {
    payloadExtraction: true,
    typedPages: true,
  },

  // ---- Environment-Specific Overrides ----
  $development: {
    devtools: { enabled: true },
  },
  $production: {
    devtools: { enabled: false },
  },
})
