---
name: tailwind-css
description: >
  TRIGGER: Use when writing HTML/JSX/TSX with Tailwind CSS utility classes, configuring Tailwind v4, using @theme/@utility/@plugin directives, creating responsive layouts with Tailwind breakpoints, adding dark mode with Tailwind, building UI components styled with utility classes (buttons, cards, forms, navbars), or using @apply, arbitrary values like bg-[#hex], or Tailwind plugins (@tailwindcss/typography, @tailwindcss/forms). Also trigger for migrating Tailwind v3 to v4, setting up @tailwindcss/vite or @tailwindcss/postcss, or customizing design tokens. DO NOT trigger for plain CSS without Tailwind classes, CSS-in-JS libraries (styled-components, Emotion), Bootstrap, or other CSS frameworks.
---

# Tailwind CSS v4 — Comprehensive Skill

## V4 BREAKING CHANGES (from v3)

Tailwind v4 is a ground-up rewrite. Key differences:

- **CSS-first config**: No `tailwind.config.js` by default. All config lives in CSS.
- **Single import**: Replace `@tailwind base; @tailwind components; @tailwind utilities;` with `@import "tailwindcss";`
- **@theme replaces theme config**: Define design tokens as CSS custom properties inside `@theme {}`.
- **@plugin replaces require()**: Add plugins via `@plugin "@tailwindcss/forms";` in CSS.
- **@utility replaces @layer utilities**: Define custom utilities with `@utility name {}`.
- **@custom-variant**: Create custom variants in CSS instead of JS plugins.
- **@source**: Explicitly add content paths for class scanning: `@source "../node_modules/@my-lib";`
- **Automatic content detection**: No `content` array needed — Tailwind scans automatically.
- **Rust engine (Oxide)**: 5–10x faster builds, ~25% smaller CSS output.
- **Native container queries**: Use `@sm:`, `@md:`, `@lg:` without plugins.
- **OKLCH color support**: Modern color spaces built in.
- **No PostCSS required** for Vite projects (use `@tailwindcss/vite` instead).

## INSTALLATION

### Vite (React, Vue, Svelte, SvelteKit)
```bash
npm install -D tailwindcss @tailwindcss/vite
```
```js
// vite.config.ts
import tailwindcss from '@tailwindcss/vite'
export default defineConfig({
  plugins: [tailwindcss()],
})
```
```css
/* src/index.css */
@import "tailwindcss";
```

### PostCSS (Next.js, Remix, Nuxt)
```bash
npm install -D tailwindcss @tailwindcss/postcss postcss
```
```js
// postcss.config.mjs
export default {
  plugins: {
    "@tailwindcss/postcss": {},
  },
}
```
```css
/* globals.css */
@import "tailwindcss";
```

### CLI (static sites, prototyping)
```bash
npm install -D @tailwindcss/cli
npx @tailwindcss/cli -i src/input.css -o dist/output.css --watch
```

### Migration from v3
```bash
npx @tailwindcss/upgrade
```
Converts `tailwind.config.js` → `@theme` blocks, updates imports, rewrites plugin syntax.

## CORE CONCEPTS

### Utility-First Approach
Apply styles directly via classes. Never leave HTML to write CSS for common patterns:
```html
<!-- GOOD: utility-first -->
<button class="bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700 transition-colors">
  Save
</button>

<!-- AVOID: custom CSS for simple styling -->
```

### Responsive Design
Mobile-first breakpoints. Unprefixed = all sizes. Prefix = that breakpoint and up:

| Prefix | Min-width | CSS |
|--------|-----------|-----|
| `sm:`  | 640px     | `@media (min-width: 640px)` |
| `md:`  | 768px     | `@media (min-width: 768px)` |
| `lg:`  | 1024px    | `@media (min-width: 1024px)` |
| `xl:`  | 1280px    | `@media (min-width: 1280px)` |
| `2xl:` | 1536px    | `@media (min-width: 1536px)` |

```html
<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
  <!-- 1 col mobile, 2 col tablet, 3 col desktop -->
</div>
```

Custom breakpoints in v4:
```css
@theme {
  --breakpoint-xs: 475px;
  --breakpoint-3xl: 1920px;
}
```

### State Variants
Prefix utilities with state modifiers:
```html
<input class="border border-gray-300 focus:border-blue-500 focus:ring-2 focus:ring-blue-200
             hover:border-gray-400 disabled:opacity-50 disabled:cursor-not-allowed"
       type="text" />
```

Common variants: `hover:`, `focus:`, `active:`, `disabled:`, `first:`, `last:`, `odd:`, `even:`, `group-hover:`, `peer-checked:`, `focus-within:`, `focus-visible:`, `placeholder:`, `file:`, `before:`, `after:`.

### Group and Peer States
```html
<!-- group: parent state affects children -->
<div class="group rounded-lg p-6 hover:bg-blue-50 transition">
  <h3 class="group-hover:text-blue-600">Title</h3>
  <p class="group-hover:text-gray-700">Description</p>
</div>

<!-- peer: sibling state affects next sibling -->
<input class="peer" type="checkbox" />
<label class="peer-checked:text-blue-600 peer-checked:font-bold">Agree</label>
```

## LAYOUT

### Flexbox
```html
<div class="flex items-center justify-between gap-4">
  <div class="flex-1">Content</div>
  <div class="flex-shrink-0">Fixed</div>
</div>

<!-- Column layout -->
<div class="flex flex-col gap-2">
  <div>Row 1</div>
  <div>Row 2</div>
</div>
```

### Grid
```html
<div class="grid grid-cols-3 gap-6">
  <div class="col-span-2">Wide</div>
  <div>Normal</div>
</div>

<!-- Auto-fit responsive grid -->
<div class="grid grid-cols-[repeat(auto-fit,minmax(250px,1fr))] gap-4">
  <div>Card</div>
  <div>Card</div>
  <div>Card</div>
</div>
```

### Container
```html
<div class="container mx-auto px-4">
  <!-- Centered, responsive max-width content -->
</div>
```

### Spacing and Sizing
- Padding: `p-4`, `px-6`, `py-2`, `pt-8`, `pl-3`
- Margin: `m-4`, `mx-auto`, `my-2`, `mt-8`, `-mt-4` (negative)
- Width: `w-full`, `w-1/2`, `w-64`, `w-screen`, `w-fit`, `w-[350px]`
- Height: `h-full`, `h-screen`, `h-dvh`, `min-h-screen`, `max-h-96`
- Size (w+h): `size-10`, `size-full`

## TYPOGRAPHY

```html
<h1 class="text-4xl font-bold tracking-tight text-gray-900">Heading</h1>
<p class="text-base text-gray-600 leading-relaxed">Body text with relaxed line height.</p>
<span class="text-sm font-medium text-blue-600 uppercase tracking-wide">Label</span>
<p class="text-lg italic text-gray-500 line-clamp-3">Truncated after 3 lines...</p>
```

Key utilities:
- Size: `text-xs` through `text-9xl`
- Weight: `font-thin` through `font-black`
- Line height: `leading-none`, `leading-tight`, `leading-relaxed`, `leading-loose`
- Alignment: `text-left`, `text-center`, `text-right`, `text-justify`
- Decoration: `underline`, `line-through`, `no-underline`
- Transform: `uppercase`, `lowercase`, `capitalize`, `normal-case`
- Overflow: `truncate`, `text-ellipsis`, `line-clamp-{n}`

### Prose (Typography Plugin)
```css
@plugin "@tailwindcss/typography";
```
```html
<article class="prose prose-lg dark:prose-invert max-w-none">
  <!-- Renders markdown/HTML content with beautiful defaults -->
  <h2>Article Title</h2>
  <p>Rich text content styled automatically.</p>
</article>
```

## COLORS

### Built-in Palette
Colors follow `{property}-{color}-{shade}` pattern. Shades: 50–950.
```html
<div class="bg-blue-500 text-white border-blue-700">Styled</div>
<div class="bg-slate-100 text-slate-900">Neutral</div>
```

### Opacity Modifier
Use `/` syntax for opacity:
```html
<div class="bg-black/50">50% opacity black background</div>
<div class="text-blue-600/75">75% opacity text</div>
<div class="border-red-500/30">30% opacity border</div>
```

### Custom Colors (v4)
```css
@theme {
  --color-brand: #1a73e8;
  --color-brand-light: #4a9aea;
  --color-brand-dark: #1557b0;
  --color-surface: oklch(98% 0.01 250);
}
```
Generates: `bg-brand`, `text-brand-light`, `border-brand-dark`, etc.

### Arbitrary Color Values
```html
<div class="bg-[#1da1f2] text-[rgb(255,255,255)]">Twitter blue</div>
<div class="bg-[oklch(70%_0.15_200)]">Modern color space</div>
```

## BACKGROUNDS, BORDERS, SHADOWS, EFFECTS

```html
<!-- Backgrounds -->
<div class="bg-gradient-to-r from-blue-500 to-purple-600">Gradient</div>
<div class="bg-cover bg-center bg-no-repeat" style="background-image: url(...)">Image BG</div>

<!-- Borders -->
<div class="border border-gray-200 rounded-xl">Rounded border</div>
<div class="border-2 border-dashed border-blue-400">Dashed</div>
<div class="divide-y divide-gray-200">
  <div>Item 1</div>
  <div>Item 2</div>
</div>
<div class="ring-2 ring-blue-500 ring-offset-2">Focus ring</div>

<!-- Shadows -->
<div class="shadow-sm">Subtle</div>
<div class="shadow-lg">Pronounced</div>
<div class="shadow-xl shadow-blue-500/20">Colored shadow</div>

<!-- Effects -->
<div class="opacity-75">Semi-transparent</div>
<div class="backdrop-blur-sm bg-white/80">Frosted glass</div>
<div class="mix-blend-multiply">Blend mode</div>
```

## DARK MODE

v4 defaults to `prefers-color-scheme` (media strategy). Override with class strategy:
```css
@custom-variant dark (&:where(.dark, .dark *));
```

Usage:
```html
<div class="bg-white dark:bg-gray-900 text-gray-900 dark:text-gray-100">
  <h1 class="text-black dark:text-white">Adapts to theme</h1>
</div>
```

Toggle dark mode via class on `<html>`:
```js
document.documentElement.classList.toggle('dark')
```

## ANIMATIONS AND TRANSITIONS

```html
<!-- Transitions -->
<button class="bg-blue-600 hover:bg-blue-700 transition-colors duration-200 ease-in-out">
  Smooth hover
</button>
<div class="transform hover:scale-105 hover:-translate-y-1 transition-all duration-300">
  Lift on hover
</div>

<!-- Built-in animations -->
<div class="animate-spin">Loading spinner</div>
<div class="animate-pulse">Skeleton loader</div>
<div class="animate-bounce">Bouncing arrow</div>
<div class="animate-ping">Notification dot</div>
```

## CUSTOM UTILITIES (v4)

### Static Utility
```css
@utility content-auto {
  content-visibility: auto;
}
```
Use: `<div class="content-auto">` — automatically supports all variants (`hover:content-auto`, `md:content-auto`).

### Dynamic Utility (Wildcard)
```css
@utility tab-* {
  tab-size: --value(integer);
}
```
Use: `<pre class="tab-4">` → `tab-size: 4;`

### Complex Custom Utility
```css
@utility scrollbar-hidden {
  scrollbar-width: none;
  &::-webkit-scrollbar {
    display: none;
  }
}
```

## THEME CUSTOMIZATION (v4)

### Extending the Default Theme
```css
@theme {
  --font-display: "Cal Sans", sans-serif;
  --color-primary: oklch(55% 0.25 260);
  --color-primary-light: oklch(70% 0.2 260);
  --breakpoint-xs: 475px;
  --shadow-soft: 0 2px 8px rgba(0,0,0,0.08);
}
```

### Overriding Defaults
Use `--color-*: initial;` to clear all defaults before defining custom palette:
```css
@theme {
  --color-*: initial;
  --color-primary: #3b82f6;
  --color-gray: #6b7280;
}
```

### Custom Variants (v4)
```css
@custom-variant pointer-coarse (@media (pointer: coarse));
@custom-variant theme-midnight (&:where([data-theme="midnight"] *));
```
Use: `pointer-coarse:text-lg`, `theme-midnight:bg-gray-950`

## ARBITRARY VALUES

Escape hatch for one-off values not in the default scale:
```html
<div class="top-[117px] grid-cols-[1fr_2fr_1fr] bg-[#1da1f2]">One-off values</div>
<div class="w-[calc(100%-2rem)] text-[clamp(1rem,2vw,2rem)]">CSS functions</div>
<div class="lg:w-[calc(50%-theme(spacing.4))]">Theme function in arbitrary</div>
<div class="[mask-type:luminance]">Arbitrary property</div>
```

## COMPONENT PATTERNS

### Button
```html
<button class="inline-flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2
               text-sm font-semibold text-white shadow-sm
               hover:bg-blue-700 focus-visible:outline-2 focus-visible:outline-offset-2
               focus-visible:outline-blue-600 active:bg-blue-800
               disabled:opacity-50 disabled:cursor-not-allowed transition-colors">
  Save Changes
</button>
```

### Card
```html
<div class="rounded-xl border border-gray-200 bg-white p-6 shadow-sm
            dark:border-gray-700 dark:bg-gray-800">
  <h3 class="text-lg font-semibold text-gray-900 dark:text-white">Card Title</h3>
  <p class="mt-2 text-sm text-gray-600 dark:text-gray-300">Card content here.</p>
</div>
```

### Form Input
```html
<label class="block text-sm font-medium text-gray-700 dark:text-gray-300">Email</label>
<input type="email"
       class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2
              text-sm shadow-sm placeholder:text-gray-400
              focus:border-blue-500 focus:ring-2 focus:ring-blue-200 focus:outline-none
              dark:border-gray-600 dark:bg-gray-800 dark:text-white"
       placeholder="you@example.com" />
```

### Responsive Navbar
```html
<nav class="flex items-center justify-between px-6 py-4 bg-white shadow-sm dark:bg-gray-900">
  <a href="/" class="text-xl font-bold">Logo</a>
  <div class="hidden md:flex items-center gap-6">
    <a href="#" class="text-sm text-gray-600 hover:text-gray-900">About</a>
  </div>
  <button class="md:hidden" aria-label="Menu">☰</button>
</nav>
```

## @apply — USE SPARINGLY

Use `@apply` only for highly repeated multi-utility patterns in CSS. Prefer component abstractions (React/Vue/Svelte components) over `@apply`:
```css
/* Acceptable: base styles reused across many files */
@utility btn-primary {
  @apply inline-flex items-center rounded-lg bg-blue-600 px-4 py-2
         text-sm font-semibold text-white hover:bg-blue-700 transition-colors;
}

/* AVOID: using @apply for everything — defeats the purpose of utility-first */
```
In v4, prefer `@utility` over raw `@apply` in `@layer`. Utilities defined with `@utility` get automatic variant support.

## PLUGINS

Install and register in CSS (v4):
```css
@plugin "@tailwindcss/typography";
@plugin "@tailwindcss/forms";
@plugin "@tailwindcss/container-queries";
```

- **@tailwindcss/typography**: `prose` classes for rich text/markdown rendering.
- **@tailwindcss/forms**: Reset form elements to be easily styleable with utilities.
- **@tailwindcss/container-queries**: v3 polyfill (v4 has native `@container` support — plugin optional).

## CONTAINER QUERIES (v4 Native)

```html
<div class="@container">
  <div class="flex flex-col @sm:flex-row @lg:grid @lg:grid-cols-3 gap-4">
    <div>Responds to container width, not viewport</div>
  </div>
</div>
```

Named containers:
```html
<div class="@container/sidebar">
  <nav class="@sm/sidebar:flex-row flex-col flex">Sidebar nav</nav>
</div>
```

## PERFORMANCE

- **Automatic content scanning**: v4 detects files automatically. Use `@source` to add external paths.
- **Tree shaking**: Only classes found in source files are generated. Unused classes are never emitted.
- **Safelist equivalent in v4**: Use `@source inline("text-red-500 bg-blue-600")` to force-include dynamic classes.
- **Avoid string concatenation** for class names — Tailwind cannot detect them:
```js
// BAD: Tailwind can't find this
const color = `text-${status}-500`

// GOOD: use complete class names
const colorMap = { success: 'text-green-500', error: 'text-red-500' }
```

## FRAMEWORK INTEGRATION

### Next.js (App Router)
Use `@tailwindcss/postcss`. Add to `postcss.config.mjs`: `plugins: { "@tailwindcss/postcss": {} }`. CSS: `@import "tailwindcss";` in `globals.css`.

### SvelteKit / Vite Projects
Use `@tailwindcss/vite`. Add `tailwindcss()` to Vite plugins. CSS: `@import "tailwindcss";` in `app.css`.

### Remix
PostCSS setup (same as Next.js). Import CSS in `root.tsx`.

### Astro
Run `npx astro add tailwind`.

## COMMON PITFALLS

1. **Dynamic class names**: Never concatenate class strings. Use lookup objects with complete class names.
2. **Specificity in v4**: `@utility` classes have fixed specificity — class order in HTML does NOT control override order. Use arbitrary variants `[&]:` or separate elements.
3. **Missing classes**: If using external UI libraries, add `@source "../node_modules/@lib";`.
4. **Stale builds**: v4's Rust engine is fast but ensure your dev server restarts after `@theme` changes.
5. **Browser support**: v4 targets modern browsers (Chrome 111+, Safari 16.4+, Firefox 128+). No IE support.
6. **@apply order**: `@apply` respects utility order but not cascade position. Prefer `@utility` in v4.
7. **Purge false positives**: If classes disappear in production, check `@source` paths cover all template locations.
8. **Container query prefix collision**: `@sm:` (container) vs `sm:` (viewport). Use `@` prefix for container queries.
