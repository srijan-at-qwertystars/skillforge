// vite.config.ts — Vite config for SolidJS with testing setup (Vitest + jsdom).
//
// Usage: Place at project root. Works with both plain SolidJS and component libraries.
// Includes: vite-plugin-solid, vitest config, path aliases, build optimization.

import { defineConfig } from "vite";
import solidPlugin from "vite-plugin-solid";
import { resolve } from "path";

export default defineConfig({
  plugins: [solidPlugin()],

  resolve: {
    alias: {
      "~": resolve(__dirname, "src"),
    },
  },

  build: {
    target: "esnext",
    // Uncomment for library mode:
    // lib: {
    //   entry: resolve(__dirname, "src/index.tsx"),
    //   formats: ["es"],
    // },
  },

  server: {
    port: 3000,
    // Proxy API requests during development:
    // proxy: {
    //   "/api": {
    //     target: "http://localhost:8080",
    //     changeOrigin: true,
    //   },
    // },
  },

  // Vitest configuration (inline — no separate vitest.config.ts needed)
  test: {
    environment: "jsdom",
    globals: true,
    transformMode: {
      web: [/\.[jt]sx?$/],
    },
    deps: {
      optimizer: {
        web: {
          // Ensure solid-js is processed correctly in test environment
          include: ["solid-js"],
        },
      },
    },
    // Coverage configuration (uncomment to enable):
    // coverage: {
    //   provider: "v8",
    //   include: ["src/**/*.{ts,tsx}"],
    //   exclude: ["src/**/*.test.*", "src/**/*.spec.*"],
    // },
    setupFiles: ["./src/test-setup.ts"],
  },
});

// --- src/test-setup.ts (create this file) ---
// import "@testing-library/jest-dom";
