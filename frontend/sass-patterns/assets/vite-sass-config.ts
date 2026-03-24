// vite-sass-config.ts — Vite configuration for Sass with global imports
// Copy relevant sections into your project's vite.config.ts.
// Install: npm i -D vite sass-embedded

import { defineConfig } from 'vite';
import path from 'path';

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
      '@styles': path.resolve(__dirname, 'src/styles'),
    },
  },

  css: {
    // Enable source maps in dev (default: true) and optionally in build
    devSourcemap: true,

    preprocessorOptions: {
      scss: {
        // Use the modern Dart Sass compiler API (default in Vite 7+, required for Vite 5.4+)
        api: 'modern-compiler',

        // Inject global variables, mixins, and functions into every SCSS file
        // Only @use abstracts here — not files that emit CSS output
        additionalData: `
          @use "sass:math";
          @use "sass:color";
          @use "sass:map";
          @use "@styles/abstracts/tokens" as tokens;
          @use "@styles/abstracts/mixins" as *;
        `,

        // Silence specific deprecation warnings during migration
        // Remove these once migration is complete
        silenceDeprecations: ['import'],

        // Load paths for resolving bare @use imports
        loadPaths: [path.resolve(__dirname, 'src/styles')],
      },
    },
  },

  build: {
    // Generate source maps for production debugging (set false for public sites)
    sourcemap: false,

    cssMinify: 'lightningcss',
  },
});

// ─── Alternative: Framework-specific configs ──────────────────

// --- React (with Vite) ---
// No changes needed — Sass works out of the box with the config above.

// --- Vue 3 ---
// import vue from '@vitejs/plugin-vue';
// plugins: [vue()],
// The scss preprocessorOptions above apply to <style lang="scss"> blocks.

// --- Svelte ---
// import { svelte } from '@sveltejs/vite-plugin-svelte';
// plugins: [svelte()],
// preprocessorOptions apply to <style lang="scss"> blocks in .svelte files.

// ─── Notes ────────────────────────────────────────────────────
//
// 1. Use `sass-embedded` (not `sass`) for 3-5x faster compilation.
//    npm uninstall sass && npm install -D sass-embedded
//
// 2. `additionalData` is prepended to EVERY .scss file. Only include
//    abstracts (variables, mixins, functions) — never CSS-emitting code,
//    or it will be duplicated in every compiled file.
//
// 3. For Vite < 5.4, use `api: 'legacy'` and the `sass` package.
//    For Vite 7+, `modern-compiler` is the only supported API.
//
// 4. To use npm packages as Sass modules (e.g., design tokens published
//    as npm packages), add NodePackageImporter:
//
//    import { NodePackageImporter } from 'sass-embedded';
//    scss: { importers: [new NodePackageImporter()] }
