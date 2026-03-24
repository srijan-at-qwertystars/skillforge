/**
 * Workbox Configuration — workbox-config.js
 *
 * Used with: workbox injectManifest workbox-config.js
 * Or with:   workbox generateSW workbox-config.js
 *
 * Integration:
 *   CLI:     npx workbox injectManifest workbox-config.js
 *   Webpack: const { InjectManifest } = require('workbox-webpack-plugin');
 *   Vite:    import { VitePWA } from 'vite-plugin-pwa';
 *
 * Choose injectManifest (custom SW) or generateSW (auto-generated SW).
 */

module.exports = {
  // ─── injectManifest Mode (recommended for custom SW) ───────

  // Source service worker with Workbox imports
  swSrc: 'src/service-worker.js',

  // Output path for the processed service worker
  swDest: 'dist/sw.js',

  // Root of your build output
  globDirectory: 'dist/',

  // Files to precache (matched against globDirectory)
  globPatterns: [
    '**/*.{html,js,css,png,jpg,svg,woff2,webp}',
  ],

  // Files to exclude from precaching
  globIgnores: [
    '**/node_modules/**',
    'sw.js',                    // Don't precache the SW itself
    'workbox-*.js',             // Don't precache Workbox runtime
    '**/*.map',                 // Skip source maps
    'stats.json',               // Skip build stats
    '**/screenshots/**',        // Skip screenshot assets
  ],

  // Maximum file size to precache (in bytes)
  maximumFileSizeToCacheInBytes: 5 * 1024 * 1024, // 5 MB

  // Modify URL paths (e.g., strip hash from filenames for matching)
  modifyURLPrefix: {
    // '': '/subpath/',         // Add path prefix if served from subdirectory
  },

  // Manifest transforms (modify entries before injection)
  // manifestTransforms: [
  //   (entries) => ({
  //     manifest: entries.filter((e) => !e.url.includes('legacy')),
  //   }),
  // ],

  // ─── generateSW Mode (alternative — auto-generates SW) ────
  // Uncomment below and comment out swSrc/swDest above to use.

  // mode: 'production',
  // navigateFallback: '/index.html',
  // navigateFallbackAllowlist: [/^(?!\/__)/],  // Exclude /__api paths
  //
  // runtimeCaching: [
  //   {
  //     urlPattern: /^https:\/\/fonts\.googleapis\.com\/.*/,
  //     handler: 'StaleWhileRevalidate',
  //     options: { cacheName: 'google-fonts-stylesheets' },
  //   },
  //   {
  //     urlPattern: /^https:\/\/fonts\.gstatic\.com\/.*/,
  //     handler: 'CacheFirst',
  //     options: {
  //       cacheName: 'google-fonts-webfonts',
  //       expiration: { maxEntries: 30, maxAgeSeconds: 365 * 24 * 60 * 60 },
  //       cacheableResponse: { statuses: [0, 200] },
  //     },
  //   },
  //   {
  //     urlPattern: /\/api\/.*/,
  //     handler: 'NetworkFirst',
  //     options: {
  //       cacheName: 'api-cache',
  //       networkTimeoutSeconds: 5,
  //       expiration: { maxEntries: 50, maxAgeSeconds: 5 * 60 },
  //     },
  //   },
  //   {
  //     urlPattern: /\.(?:png|jpg|jpeg|svg|gif|webp)$/,
  //     handler: 'CacheFirst',
  //     options: {
  //       cacheName: 'images',
  //       expiration: { maxEntries: 100, maxAgeSeconds: 30 * 24 * 60 * 60 },
  //     },
  //   },
  // ],
  //
  // skipWaiting: true,
  // clientsClaim: true,
  // cleanupOutdatedCaches: true,
  // offlineGoogleAnalytics: true,
};
