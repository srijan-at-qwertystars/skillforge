---
name: web-performance-optimization
description:
  positive: "Use when user optimizes web page performance, asks about Core Web Vitals (LCP, INP, CLS), Lighthouse scores, bundle size reduction, code splitting, lazy loading, image optimization, font loading, or resource hints (preload, prefetch, preconnect)."
  negative: "Do NOT use for server-side performance (database queries, API latency), backend caching (use http-caching skill), or CSS layout issues."
---

# Web Performance Optimization

## Core Web Vitals

Three metrics measured at the 75th percentile of real user visits. All three must pass for Google's page experience signal.

### LCP (Largest Contentful Paint)
Measures when the largest visible element finishes rendering.

| Rating | Threshold |
|--------|-----------|
| Good | ≤ 2.5s |
| Needs Improvement | 2.5–4.0s |
| Poor | > 4.0s |

Optimize LCP:
- Eliminate render-blocking resources (CSS, synchronous JS).
- Preload the LCP resource (`<link rel="preload">`).
- Set `fetchpriority="high"` on the LCP image.
- Use a CDN to reduce TTFB.
- Inline critical CSS; defer the rest.
- Avoid lazy-loading above-the-fold images.
- Use SSR or SSG to deliver HTML with content, not an empty shell.

### INP (Interaction to Next Paint)
Measures responsiveness across all user interactions (replaced FID in March 2024).

| Rating | Threshold |
|--------|-----------|
| Good | ≤ 200ms |
| Needs Improvement | 200–500ms |
| Poor | > 500ms |

Optimize INP:
- Break long tasks (>50ms) with `scheduler.yield()` or `setTimeout`.
- Minimize main-thread JavaScript execution.
- Debounce/throttle rapid-fire event handlers.
- Move heavy computation to Web Workers.
- Avoid layout thrashing in event handlers (batch DOM reads before writes).
- Reduce third-party script impact on the main thread.

```js
// Break long task with scheduler.yield()
async function processItems(items) {
  for (const item of items) {
    doWork(item);
    if (navigator.scheduling?.isInputPending?.()) {
      await scheduler.yield();
    }
  }
}
```

### CLS (Cumulative Layout Shift)
Measures visual stability — unexpected layout movement.

| Rating | Threshold |
|--------|-----------|
| Good | ≤ 0.1 |
| Needs Improvement | 0.1–0.25 |
| Poor | > 0.25 |

Optimize CLS:
- Set explicit `width` and `height` on all images, videos, and iframes.
- Use CSS `aspect-ratio` for responsive containers.
- Reserve space for ads, embeds, and dynamic content.
- Preload fonts; use `font-display: optional` or `swap`.
- Never inject content above the current viewport.
- Use CSS `contain: layout` on components that resize.
- Animate with `transform` and `opacity`, not layout properties.

---

## Critical Rendering Path

### Render-Blocking Resources
Stylesheets and synchronous scripts block first paint. Eliminate or defer them.

```html
<!-- Inline critical CSS -->
<style>/* above-the-fold styles only */</style>

<!-- Defer non-critical CSS -->
<link rel="stylesheet" href="non-critical.css" media="print" onload="this.media='all'">

<!-- Async/defer scripts -->
<script src="analytics.js" defer></script>
<script src="widget.js" async></script>
```

**Rules:**
- `defer`: Execute after HTML parsing, in order. Use for app logic.
- `async`: Execute as soon as downloaded, out of order. Use for independent scripts.
- Inline critical CSS (< 14KB) for first paint; load the rest asynchronously.
- Avoid `@import` in CSS — it serializes network requests.

---

## Code Splitting & Lazy Loading

### Dynamic Imports
Split bundles at route and component boundaries. Load code on demand.

```js
// Route-based splitting (React + React Router)
import { lazy, Suspense } from 'react';
const Dashboard = lazy(() => import('./pages/Dashboard'));

function App() {
  return (
    <Suspense fallback={<Spinner />}>
      <Routes>
        <Route path="/dashboard" element={<Dashboard />} />
      </Routes>
    </Suspense>
  );
}
```

```js
// Component-based splitting — load heavy component on interaction
const ChartModule = lazy(() => import('./Chart'));

function Report({ showChart }) {
  return showChart ? (
    <Suspense fallback={<Placeholder />}>
      <ChartModule />
    </Suspense>
  ) : null;
}
```

```js
// Conditional dynamic import — load only when needed
async function handleExport() {
  const { exportToPDF } = await import('./exportUtils');
  exportToPDF(data);
}
```

### Splitting Guidelines
- Split at route boundaries first (biggest wins).
- Split heavy libraries used in few places (chart libs, editors).
- Avoid over-splitting — too many small chunks increase HTTP overhead.

---

## Image Optimization

### Modern Formats
Prefer AVIF > WebP > JPEG/PNG. AVIF gives ~50% smaller files than JPEG at equal quality.

```html
<picture>
  <source srcset="hero.avif" type="image/avif">
  <source srcset="hero.webp" type="image/webp">
  <img src="hero.jpg" alt="Hero" width="1200" height="600"
       fetchpriority="high" decoding="async">
</picture>
```

### Responsive Images
Serve appropriately-sized images for each viewport.

```html
<img
  srcset="photo-400.webp 400w, photo-800.webp 800w, photo-1200.webp 1200w"
  sizes="(max-width: 600px) 400px, (max-width: 1000px) 800px, 1200px"
  src="photo-800.webp"
  alt="Product"
  width="800" height="600"
  loading="lazy"
  decoding="async"
>
```

### Image Rules
- Always set `width` and `height` (or `aspect-ratio`) — prevents CLS.
- Use `loading="lazy"` on below-the-fold images.
- Never lazy-load the LCP image — add `fetchpriority="high"` instead.
- Use an image CDN (Cloudinary, imgix, Cloudflare Images) for on-the-fly resizing/format conversion.
- Compress with tools: Squoosh, Sharp, or `sharp` in build pipelines.
- Target ≤ 200KB for hero images, ≤ 50KB for thumbnails.

---

## Font Loading

### Font Display Strategy

```css
@font-face {
  font-family: 'Brand';
  src: url('/fonts/brand.woff2') format('woff2');
  font-display: swap;        /* Show fallback immediately, swap when loaded */
  unicode-range: U+0000-00FF; /* Subset to Latin characters */
}
```

### Font Rules
- Use `font-display: swap` for body text (prevents invisible text).
- Use `font-display: optional` for non-critical fonts (avoids layout shift).
- Preload critical fonts:
  ```html
  <link rel="preload" href="/fonts/brand.woff2" as="font" type="font/woff2" crossorigin>
  ```
- Self-host fonts — eliminates DNS lookup to Google Fonts.
- Subset fonts to needed character ranges (`pyftsubset` or `glyphhanger`).
- Prefer variable fonts — one file replaces multiple weights/styles.

---

## Resource Hints

Use resource hints to help the browser discover and prioritize resources earlier.

```html
<!-- Preconnect: warm up connections to critical third-party origins -->
<link rel="preconnect" href="https://api.example.com" crossorigin>
<link rel="dns-prefetch" href="https://cdn.example.com">

<!-- Preload: fetch critical resources early in current navigation -->
<link rel="preload" href="/fonts/main.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="/hero.avif" as="image" fetchpriority="high">

<!-- Prefetch: fetch resources for likely next navigation -->
<link rel="prefetch" href="/next-page-bundle.js" as="script">

<!-- Modulepreload: preload ES modules with full dependency graph -->
<link rel="modulepreload" href="/app.js">
```

### fetchpriority Attribute
Override browser heuristics for download scheduling.

```html
<!-- High priority for LCP image -->
<img src="hero.avif" fetchpriority="high" alt="Hero">

<!-- Low priority for below-fold images -->
<img src="footer-bg.webp" fetchpriority="low" loading="lazy" alt="">

<!-- High priority for critical async script -->
<script src="app.js" async fetchpriority="high"></script>
```

### Resource Hint Rules
- Limit `preconnect` to 2–4 origins — each has CPU/memory cost.
- Use `dns-prefetch` as fallback for broader browser support.
- Preload only resources needed in the current page (not speculative).
- Use `prefetch` for resources needed on the next likely navigation.
- Combine `preload` with `fetchpriority="high"` for LCP resources.
- Add `crossorigin` to font preloads (required even for same-origin).

---

## JavaScript Optimization

### Tree Shaking
Ensure unused exports are eliminated at build time.

```js
// BAD: imports entire library
import _ from 'lodash';
_.get(obj, 'a.b');

// GOOD: imports only what's needed (tree-shakable)
import get from 'lodash-es/get';
get(obj, 'a.b');
```

### Bundle Analysis
Identify oversized dependencies and duplicates.

```bash
# Webpack
npx webpack-bundle-analyzer dist/stats.json

# Vite
npx vite-bundle-visualizer

# Next.js
ANALYZE=true next build   # with @next/bundle-analyzer
```

### JS Optimization Rules
- Use ES modules (`import`/`export`) — required for tree shaking.
- Avoid barrel files (`index.ts` re-exporting everything) — hinders tree shaking.
- Replace heavy libraries with lighter alternatives (e.g., `date-fns` over `moment`, `just-debounce` over `lodash`).
- Remove dead code with build tool DCE (dead code elimination).
- Set `"sideEffects": false` in `package.json` for libraries.
- Use `browserslist` to avoid shipping unnecessary polyfills.
- Target modern browsers: `"browserslist": ["last 2 versions, not dead, >0.2%"]`.

---

## Third-Party Script Management

Third-party scripts are the #1 cause of performance regressions.

### Loading Strategies

```html
<!-- Defer non-critical third-party scripts -->
<script src="https://analytics.example.com/track.js" defer></script>

<!-- Use async for independent scripts -->
<script src="https://widget.example.com/embed.js" async></script>
```

### Advanced Patterns

```js
// Facade pattern: load heavy embed only on interaction
function VideoPlayer({ videoId }) {
  const [activated, setActivated] = useState(false);
  if (!activated) {
    return (
      <button onClick={() => setActivated(true)}>
        <img src={`/thumbnails/${videoId}.webp`} alt="Play video" />
      </button>
    );
  }
  return <iframe src={`https://youtube.com/embed/${videoId}`} />;
}
```

### Third-Party Rules
- Audit third-party impact with Lighthouse "Third-party summary".
- Load analytics and tracking scripts with `defer` or after `load` event.
- Use facades for YouTube, maps, chat widgets — load real embed on interaction.
- Consider Partytown to move third-party scripts to a Web Worker.
- Set `Content-Security-Policy` headers to control allowed script origins.
- Regularly prune unused third-party scripts.

---

## Performance Budgets & CI Enforcement

### Define Budgets

| Metric | Budget |
|--------|--------|
| Total JS (compressed) | ≤ 200KB |
| Total CSS (compressed) | ≤ 50KB |
| LCP | ≤ 2.5s |
| INP | ≤ 200ms |
| CLS | ≤ 0.1 |
| Total page weight | ≤ 500KB |
| Lighthouse Performance | ≥ 90 |

### Lighthouse CI Configuration

```json
// lighthouserc.json
{
  "ci": {
    "collect": {
      "url": ["http://localhost:3000/", "http://localhost:3000/products"],
      "numberOfRuns": 3
    },
    "assert": {
      "assertions": {
        "categories:performance": ["error", { "minScore": 0.9 }],
        "largest-contentful-paint": ["error", { "maxNumericValue": 2500 }],
        "interactive": ["error", { "maxNumericValue": 3500 }],
        "cumulative-layout-shift": ["error", { "maxNumericValue": 0.1 }],
        "total-byte-weight": ["warn", { "maxNumericValue": 500000 }]
      }
    },
    "upload": {
      "target": "temporary-public-storage"
    }
  }
}
```

```yaml
# GitHub Actions workflow
- name: Lighthouse CI
  run: |
    npm install -g @lhci/cli
    lhci autorun
  env:
    LHCI_GITHUB_APP_TOKEN: ${{ secrets.LHCI_GITHUB_APP_TOKEN }}
```

### Bundle Size Check in CI

```bash
# bundlesize (package.json)
"bundlesize": [
  { "path": "dist/js/*.js", "maxSize": "200 kB" },
  { "path": "dist/css/*.css", "maxSize": "50 kB" }
]
```

```yaml
# size-limit (package.json)
"size-limit": [
  { "path": "dist/index.js", "limit": "50 kB" },
  { "path": "dist/vendor.js", "limit": "150 kB" }
]
```

---

## Measuring Performance

### Lighthouse
Run in Chrome DevTools, CLI, or CI. Scores 0–100 across categories. Use `--preset=desktop` or default mobile.

```bash
npx lighthouse https://example.com --output=json --output-path=./report.json
```

### Chrome User Experience Report (CrUX)
Real-user data from Chrome. Query via CrUX API, BigQuery, or PageSpeed Insights.

### Performance Observer API
Measure Core Web Vitals in production with the `web-vitals` library.

```js
import { onLCP, onINP, onCLS } from 'web-vitals';

onLCP(metric => sendToAnalytics('LCP', metric));
onINP(metric => sendToAnalytics('INP', metric));
onCLS(metric => sendToAnalytics('CLS', metric));

function sendToAnalytics(name, { value, rating, id }) {
  navigator.sendBeacon('/analytics', JSON.stringify({ name, value, rating, id }));
}
```

### WebPageTest
Run multi-step tests with real browsers. Use `webpagetest.org` or self-host.

---

## Framework-Specific Tips

### React
- Use `React.lazy()` + `Suspense` for code splitting.
- Memoize with `React.memo`, `useMemo`, `useCallback` where profiling shows benefit.
- Use `useTransition` for non-urgent state updates.

### Next.js
- Use `next/image` — automatic format conversion, responsive sizing, lazy loading.
- Use App Router with React Server Components — zero client JS for server components.
- Set `priority` prop on LCP images (adds `fetchpriority="high"`).
- Use `next/font` for zero-CLS font loading with automatic subsetting.
- Use `next/script` with `strategy="lazyOnload"` for third-party scripts.

```html
<!-- LCP image — priority prop handles preload + fetchpriority -->
<Image src="/hero.avif" width={1200} height={600} alt="Hero" priority />
```

### Vue / Nuxt
- Use `defineAsyncComponent` for lazy-loaded components.
- Use `<NuxtImage>` for automatic image optimization in Nuxt.
- Use `useHead` for resource hints in Nuxt 3.

---

## Common Anti-Patterns

| Anti-Pattern | Fix |
|---|---|
| Lazy-loading the LCP image | Add `fetchpriority="high"`, remove `loading="lazy"` |
| Loading all JS upfront | Code-split at route boundaries |
| Images without dimensions | Always set `width`/`height` or `aspect-ratio` |
| Synchronous third-party scripts | Use `async`/`defer` or facades |
| `@import` in CSS | Use `<link>` tags or bundle CSS |
| Barrel file re-exports | Import directly from source modules |
| Unused polyfills | Configure `browserslist` and use modern targets |
| Web fonts causing FOIT | Add `font-display: swap` and preload critical fonts |
| Too many `preconnect` hints | Limit to 2–4 most critical origins |
| No performance monitoring | Add `web-vitals` library, report to analytics |

## Quick Wins Checklist

1. Add `fetchpriority="high"` to the LCP element.
2. Add `loading="lazy"` to all below-fold images.
3. Set `width`/`height` on every `<img>` and `<video>`.
4. Add `<link rel="preconnect">` for top 2–3 third-party origins.
5. Move render-blocking `<script>` tags to `defer`.
6. Inline critical CSS (< 14KB); async-load the rest.
7. Convert images to WebP/AVIF.
8. Self-host and preload web fonts.
9. Add `font-display: swap` to all `@font-face` rules.
10. Run `npx lighthouse` and fix the top 3 opportunities.
