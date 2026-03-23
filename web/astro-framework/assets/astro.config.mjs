// astro.config.mjs — Production Astro configuration template
//
// Customize this template for your project. Uncomment sections as needed.
// Docs: https://docs.astro.build/en/reference/configuration-reference/

import { defineConfig } from 'astro/config';

// --- UI Framework (pick one) ---
import react from '@astrojs/react';
// import vue from '@astrojs/vue';
// import svelte from '@astrojs/svelte';
// import solid from '@astrojs/solid-js';
// import preact from '@astrojs/preact';

// --- Integrations ---
import sitemap from '@astrojs/sitemap';
import mdx from '@astrojs/mdx';
// import tailwind from '@astrojs/tailwind';

// --- SSR Adapters (pick one for server/hybrid output) ---
// import vercel from '@astrojs/vercel';
// import netlify from '@astrojs/netlify';
// import cloudflare from '@astrojs/cloudflare';
// import node from '@astrojs/node';

export default defineConfig({
  // --- Site URL (required for sitemap, canonical URLs, RSS) ---
  site: 'https://example.com',

  // --- Output mode ---
  // 'static'  — Full static build (default)
  // 'server'  — Full SSR (requires adapter)
  // 'hybrid'  — Static by default, opt-in SSR per page
  output: 'static',

  // --- SSR Adapter (uncomment one and the matching import above) ---
  // adapter: vercel(),
  // adapter: netlify(),
  // adapter: cloudflare(),
  // adapter: node({ mode: 'standalone' }),

  // --- Integrations ---
  integrations: [
    react(),
    // vue(),
    // svelte(),
    // solid(),
    sitemap(),
    mdx(),
    // tailwind(),
  ],

  // --- Image optimization ---
  image: {
    // Allow remote image domains for <Image /> component
    domains: [
      // 'cdn.example.com',
      // 'images.unsplash.com',
    ],
    // Remote patterns (more flexible than domains)
    // remotePatterns: [
    //   { protocol: 'https', hostname: '**.example.com' },
    // ],
  },

  // --- i18n (internationalization) ---
  // i18n: {
  //   defaultLocale: 'en',
  //   locales: ['en', 'es', 'fr', 'de'],
  //   routing: {
  //     prefixDefaultLocale: false,
  //   },
  //   fallback: {
  //     es: 'en',
  //     fr: 'en',
  //     de: 'en',
  //   },
  // },

  // --- Markdown configuration ---
  markdown: {
    shikiConfig: {
      theme: 'github-dark',
      wrap: true,
    },
    // remarkPlugins: [],
    // rehypePlugins: [],
  },

  // --- Vite configuration ---
  vite: {
    // Custom Vite config (CSS, plugins, build options)
    // css: {
    //   preprocessorOptions: {
    //     scss: { additionalData: `@use "src/styles/variables" as *;` },
    //   },
    // },
    build: {
      // Increase chunk size warning limit
      // chunkSizeWarningLimit: 1000,
    },
  },

  // --- Build options ---
  build: {
    // 'directory' → /about/index.html (clean URLs)
    // 'file'      → /about.html
    format: 'directory',
    // Inline stylesheets below this size (bytes)
    inlineStylesheets: 'auto',
  },

  // --- Dev server ---
  server: {
    port: 4321,
    host: false, // set to true or '0.0.0.0' for network access
  },

  // --- Prefetch ---
  prefetch: {
    prefetchAll: false,
    defaultStrategy: 'hover', // 'hover' | 'tap' | 'viewport' | 'load'
  },

  // --- Experimental features ---
  // experimental: {
  //   responsiveImages: true,
  //   svg: true,
  // },
});
