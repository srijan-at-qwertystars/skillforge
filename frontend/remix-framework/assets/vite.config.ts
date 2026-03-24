/**
 * Remix / React Router v7 — Vite Configuration Template
 *
 * Copy to your project root as vite.config.ts and customize as needed.
 * The reactRouter() plugin must be listed first.
 */

import { reactRouter } from "@react-router/dev/vite";
import { defineConfig } from "vite";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig({
  plugins: [
    // React Router / Remix Vite plugin — MUST be first
    reactRouter(),

    // Resolve paths from tsconfig.json (e.g., ~/components → app/components)
    tsconfigPaths(),

    // Tailwind CSS v4 (uncomment if using @tailwindcss/vite)
    // tailwindcss(),
  ],

  // ---------------------------------------------------------------------------
  // Server options (dev server)
  // ---------------------------------------------------------------------------
  server: {
    port: 3000,
    // open: true,
    // https: { key: "...", cert: "..." },  // For local HTTPS
  },

  // ---------------------------------------------------------------------------
  // Build options
  // ---------------------------------------------------------------------------
  build: {
    // Target modern browsers for smaller bundles
    target: "esnext",

    // Source maps for production debugging (set to false for smaller deploys)
    sourcemap: true,

    // Rollup options
    // rollupOptions: {
    //   external: [],
    // },
  },

  // ---------------------------------------------------------------------------
  // CSS options
  // ---------------------------------------------------------------------------
  css: {
    // CSS Modules configuration
    modules: {
      localsConvention: "camelCase",
    },

    // PostCSS configuration (if using postcss.config.js, this can be omitted)
    // postcss: "./postcss.config.js",
  },

  // ---------------------------------------------------------------------------
  // Dependency optimization
  // ---------------------------------------------------------------------------
  optimizeDeps: {
    // Force-include CJS dependencies that Vite might not auto-detect
    // include: ["some-cjs-package"],
  },

  // ---------------------------------------------------------------------------
  // SSR options
  // ---------------------------------------------------------------------------
  ssr: {
    // Force-bundle packages that don't work with SSR externalization
    // noExternal: ["some-package-with-css-imports"],
  },

  // ---------------------------------------------------------------------------
  // Environment variables
  // ---------------------------------------------------------------------------
  // Only variables prefixed with VITE_ are exposed to client code.
  // Server-side code (loaders/actions) can access all process.env variables.
  //
  // envPrefix: "VITE_",
  // envDir: ".",
});
