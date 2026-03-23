/**
 * Vite Configuration — React Router v7 Framework Mode
 *
 * Production-ready config with common plugins and settings.
 * Adjust based on your deployment target and CSS strategy.
 */
import { reactRouter } from "@react-router/dev/vite";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";
import tsconfigPaths from "vite-tsconfig-paths";

export default defineConfig(({ mode }) => ({
  plugins: [
    // Tailwind CSS v4 — remove if not using Tailwind
    tailwindcss(),

    // React Router framework plugin — MUST come before most other plugins
    reactRouter(),

    // Resolve TypeScript path aliases from tsconfig.json
    tsconfigPaths(),
  ],

  // ---------------------------------------------------------------------------
  // Build settings
  // ---------------------------------------------------------------------------
  build: {
    // Generate source maps for production debugging
    sourcemap: mode === "production",

    // Target modern browsers for smaller bundles
    target: "esnext",

    // CSS code splitting — each route gets its own CSS chunk
    cssCodeSplit: true,

    // Raise warning threshold for large chunks (default 500kB)
    chunkSizeWarningLimit: 1000,

    rollupOptions: {
      output: {
        // Stable chunk names for better caching
        manualChunks: {
          "react-vendor": ["react", "react-dom"],
        },
      },
    },
  },

  // ---------------------------------------------------------------------------
  // Dev server settings
  // ---------------------------------------------------------------------------
  server: {
    // Change port if 5173 conflicts
    port: 5173,

    // Auto-open browser on dev start
    open: false,

    // Proxy API calls to a backend server (uncomment if needed)
    // proxy: {
    //   "/api/external": {
    //     target: "http://localhost:8080",
    //     changeOrigin: true,
    //     rewrite: (path) => path.replace(/^\/api\/external/, ""),
    //   },
    // },
  },

  // ---------------------------------------------------------------------------
  // Dependency optimization
  // ---------------------------------------------------------------------------
  optimizeDeps: {
    // Pre-bundle these for faster dev startup
    include: ["react", "react-dom", "react-router"],

    // Exclude server-only packages from client bundle optimization
    // exclude: ["@prisma/client"],
  },

  // ---------------------------------------------------------------------------
  // Environment variables
  // ---------------------------------------------------------------------------
  // Only variables prefixed with VITE_ are exposed to client code.
  // Access server-only env vars in loaders/actions via process.env.
  envPrefix: "VITE_",

  // ---------------------------------------------------------------------------
  // CSS configuration
  // ---------------------------------------------------------------------------
  css: {
    // CSS Modules settings
    modules: {
      localsConvention: "camelCase",
    },

    // PostCSS plugins (autoprefixer, etc.) — add postcss.config.js if needed
    // postcss: "./postcss.config.js",
  },
}));
