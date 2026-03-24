# Tailwind CSS Troubleshooting Guide

## Table of Contents
- [Classes Not Being Applied (Content Scanning)](#classes-not-being-applied-content-scanning)
- [Specificity Conflicts](#specificity-conflicts)
- [Dynamic Class Names Not Working](#dynamic-class-names-not-working)
- [Purge / Tree-Shaking Problems](#purge--tree-shaking-problems)
- [v3 → v4 Migration Issues](#v3--v4-migration-issues)
- [PostCSS Config Conflicts](#postcss-config-conflicts)
- [IDE IntelliSense Setup](#ide-intellisense-setup)
- [Browser Dev Tools Debugging](#browser-dev-tools-debugging)
- [Production Build Size Optimization](#production-build-size-optimization)
- [SSR Hydration Mismatches](#ssr-hydration-mismatches)

---

## Classes Not Being Applied (Content Scanning)

### Symptom
Tailwind classes exist in your markup but no CSS is generated for them.

### Diagnosis Checklist
1. **Is the file being scanned?** v4 auto-detects files in the project root. Files outside the project (monorepo packages, `node_modules`) need explicit `@source`:
   ```css
   @source "../packages/ui/src";
   @source "../node_modules/@acme/components";
   ```

2. **Is the CSS entry file imported?** Verify your `app.css` / `globals.css` has `@import "tailwindcss";` and is loaded by the application.

3. **Is the dev server running?** v4 generates CSS on demand. Restart if you've changed `@source` or `@theme`.

4. **Check file extensions.** v4 scans `.html`, `.js`, `.jsx`, `.ts`, `.tsx`, `.vue`, `.svelte`, `.astro`, `.mdx` by default. For other extensions:
   ```css
   @source "../../content/**/*.md";
   ```

5. **Is the class spelled correctly?** Check for typos. `bg-grey-500` is wrong — it's `bg-gray-500`.

### Quick Debug
```bash
# Check if Tailwind sees your files (v4 CLI)
npx @tailwindcss/cli --input src/app.css --output /dev/stdout 2>&1 | grep "text-blue-500"
```

---

## Specificity Conflicts

### Problem: Utilities Not Overriding Other Styles
Tailwind utilities have low specificity (`0,1,0` — single class). They lose to:
- ID selectors (`#header`)
- Inline styles
- `!important` declarations
- Multi-class selectors (`.card .title`)

### Solutions

**1. Use `!` prefix (Tailwind's `!important` shorthand):**
```html
<div class="!bg-red-500">Forces override</div>
```

**2. Increase specificity with arbitrary variants:**
```html
<div class="[&]:bg-red-500">Wraps in & — same element, higher specificity</div>
```

**3. Reset third-party styles in a low-priority layer:**
```css
@layer vendor {
  @import "third-party/styles.css";
}
/* Tailwind utilities in the utilities layer will always beat vendor layer */
```

**4. Override inherited styles explicitly:**
```html
<!-- Third-party sets color on parent; override on child -->
<div class="third-party-widget">
  <p class="!text-gray-900">Tailwind takes control here</p>
</div>
```

### v4 Specificity Note
`@utility` classes in v4 have consistent specificity. The order of classes in your HTML does NOT determine which wins — the last-defined utility in the CSS wins. This is different from v3.

```html
<!-- v4: w-full wins if defined after w-1/2 in the CSS, regardless of HTML order -->
<div class="w-1/2 w-full">...</div>
```
To conditionally apply: use only one class, controlled by logic in your template.

---

## Dynamic Class Names Not Working

### Root Cause
Tailwind scans source code as plain text. It cannot evaluate runtime expressions.

### ❌ Patterns That Fail
```js
// String interpolation
const cls = `text-${color}-500`;

// Template literal concatenation
const bg = 'bg-' + variant;

// Dynamic property access
const sizes = { sm: 'p-2', lg: 'p-6' };
const cls = sizes[unknownKey]; // Works IF all values are literal strings in THIS file
```

### ✅ Patterns That Work
```js
// Complete class name lookup
const colorClasses = {
  success: 'text-green-600 bg-green-50 border-green-200',
  warning: 'text-yellow-600 bg-yellow-50 border-yellow-200',
  error: 'text-red-600 bg-red-50 border-red-200',
};
const cls = colorClasses[status];

// Conditional with full names
const cls = isActive ? 'bg-blue-600 text-white' : 'bg-gray-100 text-gray-700';

// Array join
const classes = [
  'px-4 py-2 rounded-lg',
  isActive && 'bg-blue-600 text-white',
  isDisabled && 'opacity-50 cursor-not-allowed',
].filter(Boolean).join(' ');
```

### Safelist as Last Resort (v4)
```css
@source inline("
  text-green-600 bg-green-50 border-green-200
  text-yellow-600 bg-yellow-50 border-yellow-200
  text-red-600 bg-red-50 border-red-200
");
```

---

## Purge / Tree-Shaking Problems

### Classes Disappearing in Production

**Symptom:** Styles work in dev but break in production builds.

**Cause 1: Dynamic classes (see above)**
All class names must appear as complete strings in source files.

**Cause 2: Files not in scan path**
```css
/* Add missing paths */
@source "../shared-components/src";
@source "../cms-content/**/*.html";
```

**Cause 3: Classes in external data (CMS, API, database)**
```css
/* Safelist classes returned by APIs */
@source inline("prose prose-lg prose-xl bg-red-500 bg-blue-500 bg-green-500");
```

**Cause 4: Content in `node_modules`**
v4 ignores `node_modules` by default. Add explicit source:
```css
@source "../node_modules/@headlessui/react";
```

### Debugging Production CSS
```bash
# Build and check output size
npx @tailwindcss/cli -i src/app.css -o dist/output.css --minify
wc -l dist/output.css  # Should be <5000 lines for most projects

# Search for specific class
grep "bg-blue-500" dist/output.css
```

### CSS Size Unexpectedly Large
- Remove unused `@source` paths that scan too many files
- Check for safelist patterns matching too many classes
- Ensure you're not importing full CSS frameworks alongside Tailwind

---

## v3 → v4 Migration Issues

### Automated Migration
```bash
npx @tailwindcss/upgrade
```
Handles most changes automatically. Review diff carefully.

### Common Post-Migration Fixes

**1. `tailwind.config.js` not deleted:**
v4 doesn't use `tailwind.config.js`. The upgrade tool converts it to `@theme` blocks. Delete the old file if it remains.

**2. Import syntax changed:**
```css
/* v3 — REMOVE */
@tailwind base;
@tailwind components;
@tailwind utilities;

/* v4 — REPLACE WITH */
@import "tailwindcss";
```

**3. Plugin registration changed:**
```css
/* v3 — REMOVE from config */
plugins: [require('@tailwindcss/typography')]

/* v4 — ADD in CSS */
@plugin "@tailwindcss/typography";
```

**4. `content` array no longer needed:**
v4 auto-detects. Remove `content: ['./src/**/*.{ts,tsx}']` from config.

**5. Renamed utilities in v4:**
| v3                    | v4                      |
|-----------------------|-------------------------|
| `flex-shrink-0`       | `shrink-0`              |
| `flex-grow`           | `grow`                  |
| `overflow-ellipsis`   | `text-ellipsis`         |
| `decoration-clone`    | `box-decoration-clone`  |
| `decoration-slice`    | `box-decoration-slice`  |
| `bg-opacity-50`       | `bg-black/50` (modifier)|
| `text-opacity-75`     | `text-blue-600/75`      |
| `border-opacity-30`   | `border-red-500/30`     |
| `ring-opacity-50`     | `ring-blue-500/50`      |
| `placeholder-gray-400`| `placeholder:text-gray-400` |

**6. Color opacity utilities removed:**
v4 removes `bg-opacity-*`, `text-opacity-*`, etc. Use the `/` modifier:
```html
<!-- v3 -->
<div class="bg-blue-500 bg-opacity-50">

<!-- v4 -->
<div class="bg-blue-500/50">
```

**7. `@apply` in `@layer components` → `@utility`:**
```css
/* v3 */
@layer components {
  .btn { @apply px-4 py-2 rounded-lg; }
}

/* v4 */
@utility btn {
  @apply px-4 py-2 rounded-lg;
}
```

**8. Container query plugin → native:**
Remove `@tailwindcss/container-queries` plugin. Use native `@container` and `@sm:` / `@md:` etc.

**9. Custom variant syntax changed:**
```js
// v3 plugin
plugin(({ addVariant }) => {
  addVariant('hocus', ['&:hover', '&:focus']);
});

// v4 CSS
@custom-variant hocus (&:hover, &:focus);
```

---

## PostCSS Config Conflicts

### Symptom
Build errors like `Unknown at-rule @theme`, `@import not supported`, or double-processing.

### Common Conflicts

**1. Multiple PostCSS plugins processing Tailwind:**
```js
// ❌ WRONG — don't mix postcss-import with Tailwind's import handling
export default {
  plugins: {
    'postcss-import': {},       // Remove this
    '@tailwindcss/postcss': {},
    'autoprefixer': {},         // v4 handles this — remove
  },
};
```
```js
// ✅ CORRECT
export default {
  plugins: {
    '@tailwindcss/postcss': {},
  },
};
```

**2. Using `@tailwindcss/postcss` with Vite:**
Vite projects should use `@tailwindcss/vite` plugin instead of PostCSS:
```js
// vite.config.ts
import tailwindcss from '@tailwindcss/vite';
export default defineConfig({
  plugins: [tailwindcss()],
});
```
Don't add both `@tailwindcss/vite` and `@tailwindcss/postcss`.

**3. Old PostCSS 7 compatibility build:**
v4 requires PostCSS 8. Remove `@tailwindcss/postcss7-compat`.

**4. postcss.config naming:**
v4 prefers `postcss.config.mjs` (ESM). If using CJS:
```js
// postcss.config.cjs
module.exports = {
  plugins: {
    '@tailwindcss/postcss': {},
  },
};
```

### Framework-Specific PostCSS

**Next.js:** Uses PostCSS automatically. Only need `postcss.config.mjs`.
**Remix:** Same PostCSS setup. CSS import in `root.tsx`.
**Nuxt:** Use `@nuxtjs/tailwindcss` module or manual PostCSS config.
**Astro:** `npx astro add tailwind` handles everything.

---

## IDE IntelliSense Setup

### VS Code — Tailwind CSS IntelliSense
1. Install extension: "Tailwind CSS IntelliSense" (bradlc.vscode-tailwindcss)
2. Works automatically if `@import "tailwindcss"` is in a CSS file in your project

**Settings for better DX:**
```json
// .vscode/settings.json
{
  "tailwindCSS.experimental.classRegex": [
    ["clsx\\(([^)]*)\\)", "(?:'|\"|`)([^']*)(?:'|\"|`)"],
    ["cva\\(([^)]*)\\)", "[\"'`]([^\"'`]*).*?[\"'`]"],
    ["cn\\(([^)]*)\\)", "(?:'|\"|`)([^']*)(?:'|\"|`)"]
  ],
  "tailwindCSS.includeLanguages": {
    "plaintext": "html"
  },
  "editor.quickSuggestions": {
    "strings": "on"
  },
  "css.validate": false,
  "scss.validate": false
}
```

**Troubleshooting IntelliSense:**
- Restart VS Code if suggestions stop after config changes
- Check Output panel → "Tailwind CSS IntelliSense" for errors
- Ensure CSS entry file is in workspace root or configured path
- v4: IntelliSense reads `@theme` from CSS — no `tailwind.config.js` needed

### JetBrains (WebStorm/IntelliJ)
- Built-in Tailwind support since 2023.1
- Recognizes `tailwind.config.js` (v3) and `@import "tailwindcss"` (v4)
- Check Settings → Languages & Frameworks → Style Sheets → Tailwind CSS

### Neovim
Use `tailwindcss` LSP via `nvim-lspconfig`:
```lua
require('lspconfig').tailwindcss.setup({
  settings = {
    tailwindCSS = {
      experimental = {
        classRegex = {
          { "clsx\\(([^)]*)\\)", "(?:'|\"|`)([^']*)(?:'|\"|`)" },
        },
      },
    },
  },
})
```

---

## Browser Dev Tools Debugging

### Finding Which Tailwind Class Applied
1. Inspect element → Styles panel
2. Tailwind utilities appear as individual rules: `.bg-blue-500 { background-color: ... }`
3. Look for struck-through styles — indicates overridden rules

### Debug Utility Class Issues
```html
<!-- Temporarily add outline to see element boundaries -->
<div class="outline outline-2 outline-red-500">Debug this element</div>

<!-- Or use the * selector trick in dev -->
<style>* { outline: 1px solid rgba(255,0,0,0.2); }</style>
```

### Check Computed Values
1. Inspect → Computed tab → search for the property
2. Shows final computed value and which rule won

### Tailwind CSS Debug Screens (Dev Only)
```html
<!-- Shows current breakpoint in corner -->
<div class="fixed bottom-2 right-2 z-50 rounded bg-black/80 px-2 py-1 text-xs text-white
            sm:after:content-['sm'] md:after:content-['md'] lg:after:content-['lg']
            xl:after:content-['xl'] 2xl:after:content-['2xl'] after:content-['xs']">
</div>
```

### Common Dev Tools Checks
| Issue | Where to Look |
|-------|---------------|
| Color wrong | Computed → `color` / `background-color` |
| Spacing off | Computed → `margin` / `padding` box model diagram |
| Not visible | Computed → `display`, `visibility`, `opacity`, `overflow` on parents |
| Z-index issues | Computed → `z-index`, check stacking context parents |
| Overflow hidden | Check all ancestors for `overflow: hidden` |

---

## Production Build Size Optimization

### Baseline Expectations
- Well-configured Tailwind v4: **8–25 KB** gzipped for most projects
- If >50 KB gzipped, something is wrong

### Optimization Checklist

**1. Enable minification:**
```bash
# CLI
npx @tailwindcss/cli -i src/app.css -o dist/output.css --minify
```
Build tools (Vite, Next.js, etc.) minify automatically in production.

**2. Remove unused `@source` paths:**
Overly broad source paths scan irrelevant files:
```css
/* ❌ Too broad */
@source "..";

/* ✅ Targeted */
@source "../src";
@source "../components";
```

**3. Audit `@source inline` safelists:**
Every safelisted class increases output size. Remove unused entries.

**4. Split CSS per route (code splitting):**
Modern frameworks (Next.js, Remix) handle this automatically. For Vite:
```js
// Dynamic imports naturally split CSS
const Dashboard = lazy(() => import('./Dashboard'));
```

**5. Compress output:**
Ensure gzip/brotli compression is enabled on your server:
```nginx
gzip on;
gzip_types text/css;
```

**6. Check for duplicate CSS imports:**
```bash
# Search for multiple Tailwind imports
grep -r '@import "tailwindcss"' src/
# Should find exactly ONE file
```

---

## SSR Hydration Mismatches

### Symptom
Console warnings: "Text content does not match server-rendered HTML" or style flicker on page load.

### Common Causes

**1. Dark mode class applied client-side only:**
```js
// ❌ CAUSES MISMATCH — server doesn't know theme preference
useEffect(() => {
  document.documentElement.classList.add('dark');
}, []);
```
```js
// ✅ Apply before hydration via inline script in <head>
// pages/_document.tsx (Next.js) or similar
<script dangerouslySetInnerHTML={{ __html: `
  try {
    const theme = localStorage.getItem('theme');
    if (theme === 'dark' || (!theme && matchMedia('(prefers-color-scheme: dark)').matches)) {
      document.documentElement.classList.add('dark');
    }
  } catch(e) {}
` }} />
```

**2. Viewport-dependent class rendering:**
```js
// ❌ Server doesn't know viewport width
const isMobile = window.innerWidth < 768;
return <div className={isMobile ? 'flex-col' : 'flex-row'}>

// ✅ Use Tailwind responsive classes instead
return <div className="flex-col md:flex-row">
```

**3. Browser-only APIs in class logic:**
```js
// ❌ navigator doesn't exist on server
const isTouch = navigator.maxTouchPoints > 0;

// ✅ Use CSS media queries via Tailwind variants
<div class="pointer-coarse:p-4 pointer-fine:p-2">
```

**4. Random/dynamic values differ between server and client:**
```js
// ❌ Different ID on server vs client
const id = `input-${Math.random()}`;

// ✅ Use useId() (React 18+) or stable IDs
const id = useId();
```

### General SSR Rules with Tailwind
1. Never conditionally render based on browser APIs — use Tailwind variants
2. Apply theme class before React hydration (blocking `<script>` in `<head>`)
3. Use `suppressHydrationWarning` only as a last resort on the `<html>` element
4. Test with SSR disabled to isolate if Tailwind or logic is the cause
