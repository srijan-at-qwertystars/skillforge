// Production-ready Astro configuration template
// Copy this file to your project root and customize as needed.
//
// Usage:
//   1. Copy to project root: cp astro.config.mjs /path/to/project/
//   2. Install required integrations: npx astro add react tailwind sitemap mdx
//   3. Install adapter for SSR: npx astro add vercel (or netlify, cloudflare, node)
//   4. Adjust settings below for your project

import { defineConfig } from 'astro/config';

// --- Framework integrations (uncomment as needed) ---
import react from '@astrojs/react';
// import vue from '@astrojs/vue';
// import svelte from '@astrojs/svelte';

// --- Feature integrations ---
import tailwind from '@astrojs/tailwind';
import sitemap from '@astrojs/sitemap';
import mdx from '@astrojs/mdx';

// --- SSR Adapters (uncomment one for server-side rendering) ---
// import node from '@astrojs/node';
// import vercel from '@astrojs/vercel';
// import netlify from '@astrojs/netlify';
// import cloudflare from '@astrojs/cloudflare';

export default defineConfig({
  // ─── Site URL (required for sitemap, canonical URLs, OG images) ───
  site: 'https://example.com',

  // ─── Output Mode ───
  // 'static' — Prerender all pages at build time (default)
  // 'server' — Server-render pages on demand (requires adapter)
  output: 'static',

  // ─── SSR Adapter (uncomment and configure for server output) ───
  // adapter: node({ mode: 'standalone' }),
  // adapter: vercel(),
  // adapter: netlify(),
  // adapter: cloudflare(),

  // ─── Integrations ───
  integrations: [
    react(),
    // vue(),
    // svelte(),
    tailwind(),
    sitemap({
      filter: (page) => !page.includes('/admin/') && !page.includes('/draft/'),
      changefreq: 'weekly',
      priority: 0.7,
      lastmod: new Date(),
    }),
    mdx(),
  ],

  // ─── Image Optimization ───
  image: {
    // Allowlist domains for remote images
    domains: [
      // 'images.unsplash.com',
      // 'cdn.sanity.io',
    ],
    remotePatterns: [
      // { protocol: 'https', hostname: '**.cloudinary.com' },
      // { protocol: 'https', hostname: '*.amazonaws.com' },
    ],
  },

  // ─── Internationalization ───
  // i18n: {
  //   locales: ['en', 'es', 'fr'],
  //   defaultLocale: 'en',
  //   prefixDefaultLocale: false,
  //   routing: {
  //     fallbackType: 'rewrite',
  //   },
  // },

  // ─── Redirects ───
  redirects: {
    // '/old-path': '/new-path',
    // '/blog/[...slug]': '/articles/[...slug]',
  },

  // ─── Prefetch ───
  prefetch: {
    prefetchAll: false,
    defaultStrategy: 'hover',
  },

  // ─── Markdown ───
  markdown: {
    shikiConfig: {
      theme: 'github-dark',
      wrap: true,
    },
    remarkPlugins: [],
    rehypePlugins: [],
  },

  // ─── Vite Configuration ───
  vite: {
    resolve: {
      alias: {
        '@': '/src',
        '@components': '/src/components',
        '@layouts': '/src/layouts',
        '@styles': '/src/styles',
      },
    },
    // Server options for dev
    server: {
      // Expose to network (useful for mobile testing)
      // host: true,
    },
    // Build optimizations
    build: {
      // Enable CSS code splitting
      cssCodeSplit: true,
    },
    // Dependency optimization
    optimizeDeps: {
      // include: ['lodash-es'],  // Pre-bundle specific deps
      // exclude: [],              // Skip pre-bundling for linked packages
    },
  },

  // ─── Dev Server ───
  server: {
    port: 4321,
    // host: true,  // Expose to network
  },

  // ─── Experimental Features ───
  // experimental: {
  //   svg: true,
  // },
});
