---
name: vite-build-tools
description:
  positive: "Use when user configures Vite, asks about vite.config, HMR, Rollup plugins, code splitting, SSR, library mode, environment variables, or migrating from Webpack/CRA to Vite."
  negative: "Do NOT use for Webpack configuration (without migration context), esbuild standalone, or Turbopack/Next.js bundling."
---

# Vite & Modern JavaScript Build Tools

## Vite Fundamentals

- **Dev**: esbuild pre-bundles deps (CJS→ESM, many-file→single-module). Source served as native ESM with on-demand transforms.
- **Build**: Rollup bundles for production with tree-shaking, code splitting, and optimized chunking.
- **HMR**: Module-level hot replacement over native ESM. Sub-50ms updates regardless of app size.

Requires Node.js 18, 20, or 22+.

## Configuration

Use `vite.config.ts` (or `.js`, `.mjs`) at project root:

```ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({
  plugins: [react()],
  root: 'src',
  base: '/app/',
  publicDir: '../public',
})
```

### Conditional and Async Config

```ts
export default defineConfig(({ command, mode }) => {
  const isProd = mode === 'production'
  return {
    build: { sourcemap: !isProd, minify: isProd ? 'esbuild' : false },
  }
})
// Async: return a promise from the function body
```

## Dev Server

```ts
export default defineConfig({
  server: {
    port: 3000,
    host: '0.0.0.0',
    open: true,
    strictPort: true,
    https: { key: fs.readFileSync('key.pem'), cert: fs.readFileSync('cert.pem') },
    proxy: {
      '/api': { target: 'http://localhost:8080', changeOrigin: true, rewrite: (p) => p.replace(/^\/api/, '') },
      '/ws': { target: 'ws://localhost:8080', ws: true },
    },
  },
})
```

Add custom middleware via the `configureServer` plugin hook:

```ts
const myMiddleware = () => ({
  name: 'my-middleware',
  configureServer(server) {
    server.middlewares.use('/health', (req, res) => res.end('ok'))
  },
})
```

## Build Configuration

```ts
export default defineConfig({
  build: {
    target: 'es2022',
    outDir: 'dist',
    minify: 'esbuild',             // 'esbuild' (fast) | 'terser' (smaller)
    sourcemap: true,               // true | 'inline' | 'hidden'
    cssMinify: 'lightningcss',
    reportCompressedSize: false,   // faster builds
    chunkSizeWarningLimit: 500,
    rollupOptions: {
      output: {
        entryFileNames: 'js/[name]-[hash].js',
        chunkFileNames: 'js/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
})
```

Set `target: 'esnext'` for maximum tree-shaking. Use `'es2015'` only for legacy browsers.

## Code Splitting

### Dynamic Imports

Vite splits dynamically imported modules into separate chunks automatically:

```ts
const Home = () => import('./pages/Home')
const Dashboard = React.lazy(() => import('./pages/Dashboard'))
```

### Manual Chunks

```ts
build: {
  rollupOptions: {
    output: {
      manualChunks: {
        vendor: ['react', 'react-dom'],
        ui: ['@radix-ui/react-dialog', '@radix-ui/react-popover'],
      },
      // Function form for fine-grained control:
      // manualChunks(id) {
      //   if (id.includes('node_modules')) {
      //     if (id.includes('@mui')) return 'mui'
      //     return 'vendor'
      //   }
      // }
    },
  },
}
```

Avoid over-splitting — each chunk adds an HTTP request.

## CSS Handling

Place `postcss.config.js` at project root — Vite auto-detects it:

```js
export default { plugins: { 'postcss-nesting': {}, autoprefixer: {} } }
```

**CSS Modules**: Files ending in `.module.css` are scoped automatically. Configure via `css.modules`:

```ts
css: { modules: { localsConvention: 'camelCaseOnly' } }
```

**Preprocessors**: Install and Vite auto-detects — `sass-embedded` (Sass, modern API default in Vite 6), `less`, `stylus`.

**Tailwind CSS**:
```ts
import tailwindcss from '@tailwindcss/vite'
export default defineConfig({ plugins: [tailwindcss()] })
```

## Static Assets

```ts
import imgUrl from './image.png'         // resolved URL
import rawSvg from './icon.svg?raw'      // inline string
import worker from './worker.js?worker'  // web worker
```

Set `build.assetsInlineLimit` (default 4096 bytes) for base64 inlining threshold.

Files in `public/` are served at root and copied as-is. Reference with absolute paths (`/logo.png`). Never import from `public/` — use `src/assets/` for imported assets.

## Environment Variables

### .env Files

```
.env                # always loaded
.env.local          # always loaded, git-ignored
.env.[mode]         # mode-specific (.production, .development, .staging)
.env.[mode].local   # mode-specific, git-ignored
```

Priority: mode-specific > generic. `.local` overrides non-local.

### Usage

Only `VITE_`-prefixed vars are exposed to client code:

```bash
VITE_API_URL=https://api.example.com
DB_PASSWORD=secret  # NOT exposed to client
```

```ts
import.meta.env.VITE_API_URL  // custom var
import.meta.env.MODE           // 'development' | 'production'
import.meta.env.DEV            // boolean
import.meta.env.PROD           // boolean
import.meta.env.SSR            // boolean
```

TypeScript: augment `ImportMetaEnv` in `src/vite-env.d.ts`. Custom modes: `vite build --mode staging` loads `.env.staging`.

## Plugins

### Official

| Package | Purpose |
|---------|---------|
| `@vitejs/plugin-react` | React Fast Refresh via Babel |
| `@vitejs/plugin-react-swc` | React Fast Refresh via SWC (faster) |
| `@vitejs/plugin-vue` | Vue 3 SFC support |
| `@vitejs/plugin-legacy` | Legacy browser polyfills |

### Community

`vite-plugin-svgr` (SVG→React), `vite-plugin-pwa`, `vite-plugin-checker` (TS/ESLint in worker), `rollup-plugin-visualizer` (bundle analysis), `vite-plugin-dts` (.d.ts for libs), `unplugin-auto-import`.

### Writing Custom Plugins

Extend Rollup's plugin interface with Vite-specific hooks:

```ts
function myPlugin(): Plugin {
  return {
    name: 'my-plugin',
    configResolved(config) { /* read resolved config */ },
    configureServer(server) { /* add dev middleware */ },
    transformIndexHtml(html) { return html.replace('__TITLE__', 'My App') },
    resolveId(source) { if (source === 'virtual:mod') return source },
    load(id) { if (id === 'virtual:mod') return `export const x = 1` },
    transform(code, id) {
      if (id.endsWith('.custom')) return { code: transform(code), map: null }
    },
  }
}
```

**Ordering**: `enforce: 'pre'` (before core), `enforce: 'post'` (after core).
**Conditional**: `apply: 'serve'` (dev only), `apply: 'build'` (build only).

## Library Mode

```ts
import { resolve } from 'path'
import dts from 'vite-plugin-dts'
export default defineConfig({
  plugins: [dts({ rollupTypes: true })],
  build: {
    lib: {
      entry: resolve(__dirname, 'lib/main.ts'),
      name: 'MyLib',
      formats: ['es', 'cjs', 'umd'],
      fileName: (format) => `my-lib.${format}.js`,
    },
    rollupOptions: {
      external: ['react', 'react-dom', 'react/jsx-runtime'],
      output: { globals: { react: 'React', 'react-dom': 'ReactDOM' } },
    },
  },
})
```

### package.json Exports

```json
{
  "type": "module",
  "main": "dist/my-lib.cjs.js",
  "module": "dist/my-lib.es.js",
  "types": "dist/main.d.ts",
  "exports": {
    ".": { "import": "./dist/my-lib.es.js", "require": "./dist/my-lib.cjs.js", "types": "./dist/main.d.ts" },
    "./styles.css": "./dist/style.css"
  }
}
```

Mark all peer deps as `external`. Never bundle framework runtimes into the library.

## SSR (Server-Side Rendering)

### Config

```ts
export default defineConfig({
  ssr: {
    noExternal: ['my-css-in-js-lib'],  // force bundle
    external: ['express'],              // keep as require()
  },
})
```

### Dev Server with SSR

```ts
import express from 'express'
import { createServer as createViteServer } from 'vite'
const app = express()
const vite = await createViteServer({ server: { middlewareMode: true }, appType: 'custom' })
app.use(vite.middlewares)
app.use('*', async (req, res) => {
  const template = await vite.transformIndexHtml(req.originalUrl, fs.readFileSync('index.html', 'utf-8'))
  const { render } = await vite.ssrLoadModule('/src/entry-server.ts')
  res.send(template.replace('<!--ssr-outlet-->', await render(req.originalUrl)))
})
```

### Production Build

```bash
vite build                            # client
vite build --ssr src/entry-server.ts  # server
```

Set `ssrManifest: true` in client build for preload directives. Use framework solutions (Vike, Remix, Nuxt, SvelteKit) for production SSR with routing and streaming.

## Multi-Page Apps

```ts
build: {
  rollupOptions: {
    input: {
      main: resolve(__dirname, 'index.html'),
      admin: resolve(__dirname, 'admin/index.html'),
    },
  },
}
```

Shared dependencies are deduplicated into common chunks automatically.

## Performance Optimization

### Dependency Pre-Bundling

```ts
optimizeDeps: {
  include: ['linked-package'],       // force pre-bundle
  exclude: ['large-esm-only-dep'],   // skip
}
```

Force re-bundle: `vite --force` or delete `node_modules/.vite`.

### Bundle Analysis

```ts
import { visualizer } from 'rollup-plugin-visualizer'
export default defineConfig({ plugins: [visualizer({ open: true, gzipSize: true })] })
```

### Chunk Strategy Checklist

1. Dynamic imports for routes and heavy components.
2. Group related vendor deps with `manualChunks`.
3. Keep initial chunk under 200kb gzipped.
4. Set `build.reportCompressedSize: false` for faster builds.
5. Use `build.cssCodeSplit: true` (default) to split CSS per chunk.
6. Prefer ESM packages. Use `optimizeDeps.include` for problematic CJS deps.

## Migration from Webpack/CRA

### Steps

1. Install: `npm install -D vite @vitejs/plugin-react && npm uninstall react-scripts`
2. Create `vite.config.ts` with `defineConfig` and `plugin-react`.
3. Move `index.html` to project root. Add `<script type="module" src="/src/main.tsx"></script>`.
4. Update scripts: `vite` (dev), `vite build` (build), `vite preview` (preview).
5. Rename env vars: `REACT_APP_*` → `VITE_*`. Use `import.meta.env` instead of `process.env`.
6. Replace `require()` with ESM `import`. Replace `require.context` with `import.meta.glob`.
7. Check Webpack-specific plugins — find Vite equivalents or remove.

### Common Gotchas

- **`process.env`**: Use `import.meta.env` or `define: { 'process.env.NODE_ENV': JSON.stringify(mode) }`.
- **SVG as components**: Install `vite-plugin-svgr`.
- **Proxy**: Move from `package.json` to `server.proxy` in vite config.
- **Public path**: Replace `PUBLIC_URL` with `base` config.
- **Jest → Vitest**: Migrate for native Vite integration and speed.

### import.meta.glob (replacing require.context)

```ts
const modules = import.meta.glob('./modules/*.ts', { eager: true })        // eager
const lazy = import.meta.glob('./modules/*.ts')                            // lazy (promises)
const defaults = import.meta.glob('./components/*.vue', { import: 'default', eager: true })
```

## Vite 6 Features

### Environment API (Experimental)

Per-environment config for client, SSR, and edge targets:

```ts
export default defineConfig({
  environments: {
    client: { build: { outDir: 'dist/client' }, resolve: { conditions: ['browser'] } },
    ssr: { build: { outDir: 'dist/server', ssr: true }, resolve: { conditions: ['node'] } },
    edge: { build: { outDir: 'dist/edge', ssr: true }, resolve: { conditions: ['edge-light'] } },
  },
})
```

Each environment gets its own module graph, plugin pipeline, and resolved config. Framework authors use the `DevEnvironment` API to run code in target runtimes during dev.

### New Defaults

- **Sass**: Modern API by default. Use `sass-embedded` for best performance.
- **PostCSS**: Supports `postcss-load-config` v6.
- **`resolve.conditions`**: Updated defaults for better package export resolution.
- **CSS in library mode**: Customizable output file names.
- **Node.js**: Requires 18, 20, or 22+. Node 21 dropped.
- **Rolldown** (future): Rust-based bundler integration in progress. Rollup plugin API remains compatible.

<!-- tested: pass -->
