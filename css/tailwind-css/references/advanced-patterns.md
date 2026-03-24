# Advanced Tailwind CSS Patterns

## Table of Contents
- [Complex Responsive Layouts](#complex-responsive-layouts)
- [Container Queries](#container-queries)
- [@layer Usage](#layer-usage)
- [CSS Variables with Tailwind](#css-variables-with-tailwind)
- [Dynamic Classes — Safelist & matchUtilities](#dynamic-classes--safelist--matchutilities)
- [Animation Keyframes](#animation-keyframes)
- [Custom Variants](#custom-variants)
- [Tailwind + CSS Modules Coexistence](#tailwind--css-modules-coexistence)
- [Design System Tokens](#design-system-tokens)
- [Multi-Theme Support Beyond Dark Mode](#multi-theme-support-beyond-dark-mode)
- [RTL Support](#rtl-support)
- [Print Styles](#print-styles)

---

## Complex Responsive Layouts

### Fluid Grid with Breakpoint Overrides
```html
<!-- Auto-fit grid: fills available space, snaps at breakpoints -->
<div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6">
  <div class="sm:col-span-2 lg:col-span-1">Featured card — wide on sm, normal on lg</div>
  <div>Card 2</div>
  <div>Card 3</div>
  <div class="hidden xl:block">Only on xl</div>
</div>
```

### Intrinsic Grid (No Breakpoints)
```html
<!-- Fluid columns: each at least 280px, auto-fill remaining space -->
<div class="grid grid-cols-[repeat(auto-fill,minmax(280px,1fr))] gap-6">
  <div>Adapts naturally</div>
  <div>No breakpoints needed</div>
  <div>Fills available space</div>
</div>
```

### Holy Grail Layout (Sticky Header + Footer)
```html
<div class="min-h-screen flex flex-col">
  <header class="sticky top-0 z-40 h-16 border-b bg-white/80 backdrop-blur">Nav</header>
  <div class="flex flex-1">
    <aside class="hidden lg:block w-64 border-r p-4">Sidebar</aside>
    <main class="flex-1 p-6">Content</main>
    <aside class="hidden xl:block w-72 border-l p-4">Right panel</aside>
  </div>
  <footer class="border-t p-4">Footer</footer>
</div>
```

### Aspect-Ratio Responsive Cards
```html
<div class="grid grid-cols-2 md:grid-cols-3 gap-4">
  <div class="aspect-video rounded-xl overflow-hidden bg-gray-100">
    <img src="..." class="w-full h-full object-cover" alt="" />
  </div>
  <div class="aspect-square rounded-xl bg-gray-100">Square</div>
</div>
```

### Responsive Typography Scale
```html
<h1 class="text-2xl sm:text-3xl md:text-4xl lg:text-5xl xl:text-6xl
           font-bold tracking-tight leading-tight">
  Scales with viewport
</h1>
<!-- Or use clamp for fluid sizing -->
<h1 class="text-[clamp(1.5rem,4vw,3.5rem)] font-bold">Fluid heading</h1>
```

### Responsive Table → Card Pattern
```html
<!-- Table on desktop, stacked cards on mobile -->
<div class="hidden md:block">
  <table class="w-full text-sm">
    <thead><tr><th class="text-left p-3">Name</th><th class="text-left p-3">Status</th></tr></thead>
    <tbody><tr class="border-t"><td class="p-3">Item</td><td class="p-3">Active</td></tr></tbody>
  </table>
</div>
<div class="md:hidden space-y-3">
  <div class="rounded-lg border p-4">
    <p class="font-medium">Item</p>
    <p class="text-sm text-gray-500">Status: Active</p>
  </div>
</div>
```

---

## Container Queries

### Basic Container Query
```html
<div class="@container">
  <div class="flex flex-col @md:flex-row @md:items-center gap-4">
    <img class="w-full @md:w-48 rounded-lg" src="..." alt="" />
    <div class="flex-1">
      <h3 class="text-lg @lg:text-xl font-semibold">Title</h3>
      <p class="text-sm @md:text-base text-gray-600">Description</p>
    </div>
  </div>
</div>
```

### Named Containers for Nested Queries
```html
<div class="@container/main">
  <div class="grid grid-cols-1 @lg/main:grid-cols-[1fr_300px] gap-6">
    <section class="@container/content">
      <div class="grid grid-cols-1 @sm/content:grid-cols-2 gap-4">
        <div>Card responds to content area</div>
        <div>Not viewport or main container</div>
      </div>
    </section>
    <aside>Sidebar</aside>
  </div>
</div>
```

### Container Query Breakpoints
| Prefix  | Min-width |
|---------|-----------|
| `@xs:`  | 320px (20rem) |
| `@sm:`  | 384px (24rem) |
| `@md:`  | 448px (28rem) |
| `@lg:`  | 512px (32rem) |
| `@xl:`  | 576px (36rem) |
| `@2xl:` | 672px (42rem) |

### Custom Container Breakpoints (v4)
```css
@theme {
  --container-3xs: 16rem;   /* 256px */
  --container-2xs: 18rem;   /* 288px */
  --container-narrow: 30rem; /* 480px */
}
```
Use: `@narrow:flex-row`

---

## @layer Usage

### Standard Layers in v4
v4 uses `@layer` internally. User code should prefer `@utility` and `@custom-variant` instead:
```css
/* v4 preferred approach — not @layer */
@utility card-base {
  @apply rounded-xl border border-gray-200 bg-white p-6 shadow-sm;
}

/* If you must use @layer for non-utility styles: */
@layer base {
  html {
    font-family: var(--font-sans);
    -webkit-font-smoothing: antialiased;
  }
  ::selection {
    background-color: oklch(80% 0.15 250 / 0.3);
  }
}

@layer components {
  /* Legacy v3-style components — prefer @utility in v4 */
  .prose-custom blockquote {
    @apply border-l-4 border-blue-500 pl-4 italic;
  }
}
```

### Layer Ordering
CSS cascade layers have fixed specificity order: `base` < `components` < `utilities`. This means utilities always win over components, and components over base — regardless of source order.

### Third-Party CSS in Layers
```css
/* Push third-party CSS into a low-priority layer */
@layer vendor {
  @import "some-library/styles.css";
}
```

---

## CSS Variables with Tailwind

### Defining and Using CSS Variables
```css
/* In your CSS */
@theme {
  --color-brand: oklch(55% 0.25 260);
  --spacing-section: 4rem;
}
```
```html
<!-- Reference via Tailwind utilities -->
<div class="bg-brand p-[var(--spacing-section)]">Uses theme tokens</div>
```

### Runtime Dynamic Variables
```html
<!-- Set variables inline, use in utilities -->
<div style="--cols: 3; --gap: 1.5rem"
     class="grid grid-cols-[repeat(var(--cols),1fr)] gap-[var(--gap)]">
  <div>Dynamic grid</div>
</div>
```

### Variables for Component Variants
```css
@utility btn {
  background-color: var(--btn-bg, theme(--color-blue-600));
  color: var(--btn-text, white);
  padding: var(--btn-py, 0.5rem) var(--btn-px, 1rem);
  border-radius: var(--btn-radius, 0.5rem);
}
```
```html
<!-- Override per-instance -->
<button class="btn [--btn-bg:theme(--color-red-600)] [--btn-radius:9999px]">
  Danger pill button
</button>
```

### JavaScript ↔ Tailwind Variable Bridge
```js
// Read Tailwind theme values at runtime
const brand = getComputedStyle(document.documentElement)
  .getPropertyValue('--color-brand');

// Set dynamic values
document.documentElement.style.setProperty('--accent', newColor);
```
```html
<div class="bg-[var(--accent)]">Dynamically themed</div>
```

---

## Dynamic Classes — Safelist & matchUtilities

### The Problem
Tailwind scans source code statically. Dynamic class names won't be detected:
```js
// ❌ BROKEN — Tailwind never sees "text-red-500"
const cls = `text-${color}-500`;

// ✅ WORKS — full class names are scannable
const colorMap = {
  red: 'text-red-500',
  green: 'text-green-500',
  blue: 'text-blue-500',
};
```

### v4: @source inline for Safelisting
```css
/* Force-include specific classes */
@source inline("
  text-red-500 text-green-500 text-blue-500
  bg-red-100 bg-green-100 bg-blue-100
");
```

### v4: @source for External Paths
```css
/* Scan a UI library for classes */
@source "../node_modules/@acme/ui/dist";
/* Scan specific file patterns */
@source "../content/**/*.mdx";
```

### v3 Safelist (Legacy)
```js
// tailwind.config.js (v3)
module.exports = {
  safelist: [
    'bg-red-500', 'bg-green-500', 'bg-blue-500',
    { pattern: /^text-(red|green|blue)-(400|500|600)$/ },
    { pattern: /^bg-(red|green|blue)-100$/, variants: ['hover', 'dark'] },
  ],
};
```

### matchUtilities for Dynamic Values (Plugin API)
```js
// v3 plugin or v4 JS plugin
const plugin = require('tailwindcss/plugin');
module.exports = plugin(function({ matchUtilities, theme }) {
  matchUtilities(
    { 'grid-area': (value) => ({ gridArea: value }) },
    { values: { header: 'header', sidebar: 'sidebar', main: 'main', footer: 'footer' } }
  );
});
```
Generates: `grid-area-header`, `grid-area-sidebar`, etc.

---

## Animation Keyframes

### Defining Custom Animations (v4)
```css
@theme {
  --animate-slide-in: slide-in 0.3s ease-out;
  --animate-fade-up: fade-up 0.5s ease-out;
  --animate-shake: shake 0.5s ease-in-out;
}

@keyframes slide-in {
  from { transform: translateX(-100%); opacity: 0; }
  to { transform: translateX(0); opacity: 1; }
}

@keyframes fade-up {
  from { transform: translateY(1rem); opacity: 0; }
  to { transform: translateY(0); opacity: 1; }
}

@keyframes shake {
  0%, 100% { transform: translateX(0); }
  25% { transform: translateX(-4px); }
  75% { transform: translateX(4px); }
}
```
```html
<div class="animate-slide-in">Slides in</div>
<div class="animate-fade-up">Fades up</div>
<div class="animate-shake">Shakes on error</div>
```

### Staggered Animations
```html
<div class="space-y-2">
  <div class="animate-fade-up [animation-delay:0ms]">Item 1</div>
  <div class="animate-fade-up [animation-delay:100ms]">Item 2</div>
  <div class="animate-fade-up [animation-delay:200ms]">Item 3</div>
</div>
```

### Motion-Safe / Motion-Reduce
```html
<div class="motion-safe:animate-bounce motion-reduce:animate-none">
  Respects user preference
</div>
```

### Arbitrary Animation Values
```html
<div class="animate-[wiggle_0.3s_ease-in-out_infinite]">
  Inline animation definition
</div>
```

---

## Custom Variants

### @custom-variant in v4
```css
/* Media-based variants */
@custom-variant pointer-coarse (@media (pointer: coarse));
@custom-variant pointer-fine (@media (pointer: fine));
@custom-variant landscape (@media (orientation: landscape));
@custom-variant portrait (@media (orientation: portrait));
@custom-variant high-contrast (@media (forced-colors: active));
@custom-variant reduced-data (@media (prefers-reduced-data: reduce));

/* Selector-based variants */
@custom-variant dark (&:where(.dark, .dark *));
@custom-variant theme-ocean (&:where([data-theme="ocean"], [data-theme="ocean"] *));

/* Parent-state variants */
@custom-variant sidebar-open (&:where([data-sidebar="open"] *));
@custom-variant loading (&:where(.loading *));

/* Attribute-based variants */
@custom-variant aria-selected (&[aria-selected="true"]);
@custom-variant data-active (&[data-active]);
```

### Usage
```html
<div class="pointer-coarse:text-lg pointer-fine:text-sm">
  Bigger text on touch devices
</div>
<div class="theme-ocean:bg-cyan-900 theme-ocean:text-cyan-100">
  Ocean theme styling
</div>
<nav class="sidebar-open:translate-x-0 -translate-x-full transition-transform">
  Sidebar toggled by parent attribute
</nav>
```

### Stacking Variants
```html
<div class="dark:hover:bg-gray-700 md:dark:hover:bg-gray-600">
  Stacked: breakpoint + dark + hover
</div>
<div class="group-hover:dark:text-white">
  Group hover in dark mode
</div>
```

---

## Tailwind + CSS Modules Coexistence

### When CSS Modules Are Needed
Use CSS Modules alongside Tailwind for:
- Third-party components requiring scoped styles
- Complex animations or pseudo-element art
- Legacy code migration

### Setup
```css
/* Component.module.css */
.wrapper {
  /* CSS Module scoped styles */
  container-type: inline-size;
}

.complexAnimation {
  animation: morphShape 3s infinite;
}

@keyframes morphShape {
  0%, 100% { clip-path: circle(50%); }
  50% { clip-path: polygon(50% 0%, 100% 50%, 50% 100%, 0% 50%); }
}
```
```jsx
import styles from './Component.module.css';

export function Component() {
  return (
    <div className={`${styles.wrapper} p-6 bg-white rounded-xl`}>
      {/* Mix CSS Module class + Tailwind utilities */}
      <div className={`${styles.complexAnimation} size-24 bg-blue-500`} />
    </div>
  );
}
```

### Rules for Coexistence
1. Use Tailwind for all standard styling (layout, spacing, colors, typography)
2. Use CSS Modules only for what Tailwind can't do (complex animations, clip-paths, scoped third-party overrides)
3. Never duplicate what Tailwind provides in a CSS Module
4. Import order: Tailwind base CSS first, then modules

---

## Design System Tokens

### Token Architecture in v4
```css
@theme {
  /* === Primitive Tokens === */
  --color-blue-50: oklch(97% 0.02 250);
  --color-blue-100: oklch(93% 0.04 250);
  --color-blue-500: oklch(55% 0.25 260);
  --color-blue-600: oklch(48% 0.25 260);
  --color-blue-900: oklch(25% 0.15 260);

  /* === Semantic Tokens (reference primitives) === */
  --color-primary: var(--color-blue-500);
  --color-primary-hover: var(--color-blue-600);
  --color-surface: var(--color-blue-50);
  --color-on-surface: var(--color-blue-900);

  /* === Component Tokens === */
  --color-btn-primary: var(--color-primary);
  --color-btn-primary-hover: var(--color-primary-hover);
  --color-btn-text: white;

  /* === Spacing Scale === */
  --spacing-xs: 0.25rem;
  --spacing-sm: 0.5rem;
  --spacing-md: 1rem;
  --spacing-lg: 1.5rem;
  --spacing-xl: 2rem;
  --spacing-2xl: 3rem;
  --spacing-section: 4rem;

  /* === Typography === */
  --font-sans: "Inter Variable", ui-sans-serif, system-ui, sans-serif;
  --font-mono: "JetBrains Mono", ui-monospace, monospace;
  --font-display: "Cal Sans", var(--font-sans);

  /* === Radii === */
  --radius-sm: 0.25rem;
  --radius-md: 0.5rem;
  --radius-lg: 0.75rem;
  --radius-xl: 1rem;
  --radius-full: 9999px;

  /* === Shadows === */
  --shadow-xs: 0 1px 2px rgba(0,0,0,0.05);
  --shadow-sm: 0 1px 3px rgba(0,0,0,0.1), 0 1px 2px rgba(0,0,0,0.06);
  --shadow-md: 0 4px 6px -1px rgba(0,0,0,0.1);
  --shadow-lg: 0 10px 15px -3px rgba(0,0,0,0.1);
}
```

### Token Naming Conventions
| Layer       | Pattern               | Example              |
|-------------|----------------------|----------------------|
| Primitive   | `--color-{hue}-{shade}` | `--color-blue-500`  |
| Semantic    | `--color-{role}`        | `--color-primary`   |
| Component   | `--color-{comp}-{prop}` | `--color-btn-bg`    |

---

## Multi-Theme Support Beyond Dark Mode

### Data-Attribute Theme Switching
```css
/* Define theme variants */
@custom-variant theme-ocean (&:where([data-theme="ocean"], [data-theme="ocean"] *));
@custom-variant theme-forest (&:where([data-theme="forest"], [data-theme="forest"] *));
@custom-variant theme-sunset (&:where([data-theme="sunset"], [data-theme="sunset"] *));
```
```html
<html data-theme="ocean">
  <body class="bg-white theme-ocean:bg-cyan-950 theme-forest:bg-green-950 theme-sunset:bg-orange-50
               text-gray-900 theme-ocean:text-cyan-100 theme-forest:text-green-100 theme-sunset:text-orange-900">
    ...
  </body>
</html>
```

### CSS Variables for Theme Tokens (More Scalable)
```css
:root, [data-theme="light"] {
  --theme-bg: oklch(99% 0.01 250);
  --theme-surface: oklch(97% 0.01 250);
  --theme-text: oklch(15% 0.02 250);
  --theme-primary: oklch(55% 0.25 260);
  --theme-border: oklch(85% 0.02 250);
}

[data-theme="dark"] {
  --theme-bg: oklch(15% 0.02 250);
  --theme-surface: oklch(20% 0.02 250);
  --theme-text: oklch(92% 0.01 250);
  --theme-primary: oklch(65% 0.2 260);
  --theme-border: oklch(30% 0.02 250);
}

[data-theme="ocean"] {
  --theme-bg: oklch(15% 0.04 220);
  --theme-surface: oklch(22% 0.05 220);
  --theme-text: oklch(90% 0.02 200);
  --theme-primary: oklch(65% 0.18 200);
  --theme-border: oklch(30% 0.04 220);
}

@theme {
  --color-theme-bg: var(--theme-bg);
  --color-theme-surface: var(--theme-surface);
  --color-theme-text: var(--theme-text);
  --color-theme-primary: var(--theme-primary);
  --color-theme-border: var(--theme-border);
}
```
```html
<div class="bg-theme-bg text-theme-text border-theme-border">
  Works with any theme — no variant prefixes needed
</div>
```

### Theme Switching JavaScript
```js
function setTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  localStorage.setItem('theme', theme);
}
// On load
const saved = localStorage.getItem('theme') || 'light';
setTheme(saved);
```

---

## RTL Support

### Built-in RTL Utilities
Tailwind provides `ltr:` and `rtl:` variants and logical properties:
```html
<div dir="rtl">
  <div class="ms-4 me-2 ps-6 pe-4">
    <!-- ms = margin-inline-start, me = margin-inline-end -->
    <!-- ps = padding-inline-start, pe = padding-inline-end -->
    Logical properties auto-flip for RTL
  </div>
</div>
```

### Logical vs Physical Properties
| Physical (avoid) | Logical (prefer) |
|------------------|-------------------|
| `ml-4`           | `ms-4`           |
| `mr-4`           | `me-4`           |
| `pl-4`           | `ps-4`           |
| `pr-4`           | `pe-4`           |
| `text-left`      | `text-start`     |
| `text-right`     | `text-end`       |
| `float-left`     | `float-start`    |
| `float-right`    | `float-end`      |
| `left-0`         | `start-0`        |
| `right-0`        | `end-0`          |
| `border-l`       | `border-s`       |
| `border-r`       | `border-e`       |
| `rounded-l-lg`   | `rounded-s-lg`   |
| `rounded-r-lg`   | `rounded-e-lg`   |

### Directional Variants for Asymmetric Cases
```html
<div class="flex items-center gap-3">
  <span class="rtl:order-2">←</span>
  <span class="rtl:order-1">Back</span>
</div>
```

---

## Print Styles

### Print Variant
```html
<div class="bg-white print:bg-transparent">
  <nav class="print:hidden">Navigation — hidden on print</nav>
  <main class="text-sm print:text-xs print:text-black">
    <h1 class="text-blue-600 print:text-black">Title</h1>
    <a href="https://example.com"
       class="text-blue-500 print:text-black print:underline print:after:content-['_('_attr(href)_')']">
      Link — shows URL on print
    </a>
  </main>
  <footer class="print:hidden">Footer — hidden on print</footer>
</div>
```

### Print-Specific Utilities
```html
<!-- Page breaks -->
<div class="break-before-page">Starts on new page</div>
<div class="break-after-avoid">Keep with next element</div>
<div class="break-inside-avoid">Don't split this block</div>

<!-- Print layout adjustments -->
<div class="print:w-full print:max-w-none print:p-0 print:shadow-none print:border-none">
  Content expands to full page width on print
</div>
```

### Print Stylesheet Pattern
```css
@utility print-only {
  display: none;
  @media print {
    display: block;
  }
}

@utility screen-only {
  @media print {
    display: none;
  }
}
```
