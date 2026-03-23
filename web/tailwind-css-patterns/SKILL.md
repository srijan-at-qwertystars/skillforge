---
name: tailwind-css-patterns
description: |
  Use when user styles with Tailwind CSS, asks about utility classes, responsive design, dark mode, custom theme configuration, @apply, component extraction, Tailwind plugins, or Tailwind v4 features.
  Do NOT use for vanilla CSS layout (use css-grid-flexbox skill), CSS-in-JS (styled-components, Emotion), or Bootstrap/Material UI.
---

# Tailwind CSS Patterns & Best Practices

## Tailwind v4 Changes

Tailwind v4 replaces JavaScript config with CSS-first configuration. The Lightning CSS engine delivers 5–100x faster builds.

### CSS-First Configuration

Import Tailwind with a single line. No `@tailwind` directives needed:

```css
@import "tailwindcss";

@theme {
  --color-primary: #1e40af;
  --color-secondary: #64748b;
  --font-display: "Inter", sans-serif;
  --breakpoint-xl: 1400px;
  --ease-fluid: cubic-bezier(0.3, 0, 0, 1);
}
```

Every `@theme` variable becomes a native CSS custom property usable anywhere.

### Key v4 Differences

- **No `tailwind.config.js` required.** Define tokens in CSS via `@theme`.
- **Automatic content detection.** No `content` array — Tailwind respects `.gitignore` and scans source automatically.
- **`@utility` directive** replaces JS-based `addUtilities` for custom functional utilities.
- **`@custom-variant`** replaces JS-based variant plugins.
- **`@plugin`** imports legacy JS plugins when needed: `@plugin "./legacy-plugin.js";`
- **`@config`** loads a JS config for backward compatibility: `@config "./tailwind.config.js";`
- **Native CSS features**: cascade layers, container queries, `color-mix()`, 3D transforms.

## Core Concepts

### Utility-First Workflow

Compose small utilities directly in markup instead of writing custom CSS:

```html
<div class="flex items-center gap-4 rounded-lg bg-white p-6 shadow-md">
  <img class="size-12 rounded-full" src="/avatar.jpg" alt="Avatar" />
  <div>
    <p class="text-sm font-semibold text-gray-900">Jane Doe</p>
    <p class="text-sm text-gray-500">Engineer</p>
  </div>
</div>
```

### Responsive Prefixes

Mobile-first. Unprefixed = all sizes. Breakpoints: `sm` (640px), `md` (768px), `lg` (1024px), `xl` (1280px), `2xl` (1536px):

```html
<div class="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
  <!-- Responsive grid -->
</div>
```

### State Variants

```html
<button class="bg-blue-600 hover:bg-blue-700 focus:ring-2 focus:ring-blue-500
  active:bg-blue-800 disabled:opacity-50 disabled:cursor-not-allowed">Submit</button>

<!-- Group/peer variants for parent/sibling state -->
<div class="group rounded-lg p-4 hover:bg-gray-50">
  <h3 class="text-gray-700 group-hover:text-blue-600">Title</h3>
</div>
```

## Layout Utilities

### Flexbox and Grid

```html
<nav class="flex items-center justify-between px-6 py-4">
  <div class="flex shrink-0 items-center gap-2">Logo</div>
  <div class="flex gap-6">Links</div>
</nav>

<div class="grid grid-cols-[250px_1fr] gap-6">
  <aside class="sticky top-0 h-screen overflow-y-auto">Sidebar</aside>
  <main class="min-w-0">Content</main>
</div>
```

Arbitrary grid values: `grid-cols-[repeat(auto-fill,minmax(280px,1fr))]`.

### Spacing, Sizing, Positioning

- Padding/margin: `p-4`, `px-6`, `mt-8`, `mx-auto`.
- Width/height: `w-full`, `h-screen`, `min-h-dvh`, `max-w-prose`. `size-*` sets both.
- Prefer `gap` over `space-x-*`/`space-y-*` with flex/grid.

```html
<div class="relative">
  <div class="absolute inset-0 bg-black/50"></div>
  <div class="sticky top-0 z-50 bg-white/80 backdrop-blur-sm">Header</div>
</div>
```

## Typography

```html
<h1 class="text-3xl font-bold tracking-tight text-gray-900 lg:text-5xl">Heading</h1>
<p class="text-base leading-relaxed text-gray-600">Body text.</p>
<span class="text-sm font-medium uppercase tracking-wide text-gray-500">Label</span>
```

### Prose Plugin (@tailwindcss/typography)

```html
<article class="prose prose-lg prose-gray dark:prose-invert max-w-none">
  <!-- Rendered markdown here -->
</article>
```

Customize: `prose-headings:text-blue-900`, `prose-a:text-blue-600`.

## Colors and Theming

### Custom Colors via @theme

```css
@theme {
  --color-brand: #2563eb;
  --color-brand-light: #60a5fa;
  --color-brand-dark: #1d4ed8;
  --color-surface: #ffffff;
}
```

Use as: `bg-brand`, `text-brand-dark`, `border-brand-light`.

### Opacity Modifiers and Dynamic Theming

Append `/` + opacity: `bg-black/50`, `text-white/90`, `border-white/20`.

For runtime theming, reference CSS variables with fallbacks:

```css
@theme {
  --color-primary: var(--app-primary, #2563eb);
}
```

Override by setting `--app-primary` on any ancestor element.

## Dark Mode

### Class Strategy (Recommended)

```css
@custom-variant dark (&:where([data-theme="dark"], [data-theme="dark"] *));
```

```html
<div class="bg-white text-gray-900 dark:bg-gray-950 dark:text-gray-100">
  <h2 class="text-gray-800 dark:text-gray-200">Adapts to theme</h2>
</div>
```

Media strategy (default) follows `prefers-color-scheme` automatically.

### Dark Mode Toggle

```js
function toggleDarkMode() {
  const isDark = document.documentElement.getAttribute("data-theme") === "dark";
  document.documentElement.setAttribute("data-theme", isDark ? "light" : "dark");
  localStorage.setItem("theme", isDark ? "light" : "dark");
}
```

### Semantic Token Pattern (No `dark:` Prefix Needed)

```css
@theme {
  --color-bg: #ffffff;
  --color-fg: #0f172a;
  --color-muted: #64748b;
}
@custom-variant dark (&:where(.dark, .dark *));
@layer base {
  .dark { --color-bg: #0f172a; --color-fg: #f8fafc; --color-muted: #94a3b8; }
}
```

Use `bg-bg`, `text-fg`, `text-muted` — theme switches automatically.

## Responsive Design

```html
<!-- Stack on mobile, side-by-side on tablet+ -->
<div class="flex flex-col gap-6 md:flex-row">
  <div class="md:w-1/3">Sidebar</div>
  <div class="md:w-2/3">Main</div>
</div>

<!-- Hide/show at breakpoints -->
<nav class="hidden lg:flex">Desktop nav</nav>
<button class="lg:hidden">Menu</button>
```

### Container Queries

```html
<div class="@container">
  <div class="flex flex-col @md:flex-row @lg:gap-8">
    Responds to container width, not viewport
  </div>
</div>
```

### Custom Breakpoints and Fluid Typography

```css
@theme {
  --breakpoint-xs: 475px;
  --breakpoint-3xl: 1920px;
}
```

```html
<h1 class="text-[clamp(1.5rem,4vw,3rem)]">Fluid heading</h1>
```

## Component Patterns

### Extracting Components (React/Vue)

Prefer component extraction over `@apply`. Move repeated utility patterns into framework components:

```tsx
function Card({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <div className={cn("rounded-xl border border-gray-200 bg-white p-6 shadow-sm", className)}>
      {children}
    </div>
  );
}
```

### CVA (class-variance-authority)

Define variant-driven components with type safety:

```tsx
import { cva, type VariantProps } from "class-variance-authority";

const buttonVariants = cva(
  "inline-flex items-center justify-center rounded-lg font-medium transition-colors focus:outline-none focus:ring-2 focus:ring-offset-2 disabled:pointer-events-none disabled:opacity-50",
  {
    variants: {
      variant: {
        primary: "bg-blue-600 text-white hover:bg-blue-700 focus:ring-blue-500",
        secondary: "bg-gray-100 text-gray-900 hover:bg-gray-200 focus:ring-gray-500",
        ghost: "hover:bg-gray-100 text-gray-700",
        destructive: "bg-red-600 text-white hover:bg-red-700 focus:ring-red-500",
      },
      size: {
        sm: "h-8 px-3 text-sm",
        md: "h-10 px-4 text-sm",
        lg: "h-12 px-6 text-base",
      },
    },
    defaultVariants: { variant: "primary", size: "md" },
  }
);

type ButtonProps = React.ButtonHTMLAttributes<HTMLButtonElement> &
  VariantProps<typeof buttonVariants>;

export function Button({ variant, size, className, ...props }: ButtonProps) {
  return <button className={cn(buttonVariants({ variant, size }), className)} {...props} />;
}
```

### When to Use @apply

Reserve for markup you don't control (e.g., CMS/WYSIWYG output):

```css
@layer components {
  .wysiwyg-content h2 { @apply text-xl font-bold text-gray-900 mt-8 mb-4; }
  .wysiwyg-content a { @apply text-blue-600 underline hover:text-blue-800; }
}
```

## Animation Utilities

```html
<button class="transition-colors duration-200 ease-in-out hover:bg-blue-700">Smooth hover</button>
<div class="transition-all duration-300 hover:scale-105 hover:shadow-lg">Card</div>
<div class="animate-spin size-5">Spinner</div>
<div class="animate-pulse rounded-lg bg-gray-200 h-4 w-3/4">Skeleton</div>
```

### Custom Keyframes (v4)

```css
@theme {
  --animate-fade-in: fade-in 0.3s ease-out;
  --animate-slide-up: slide-up 0.4s ease-out;
}
@keyframes fade-in { from { opacity: 0; } to { opacity: 1; } }
@keyframes slide-up {
  from { opacity: 0; transform: translateY(8px); }
  to { opacity: 1; transform: translateY(0); }
}
```

Use as `animate-fade-in`, `animate-slide-up`.

## Custom Configuration

### Extending the Theme

```css
@theme {
  --color-brand-50: #eff6ff;
  --color-brand-500: #3b82f6;
  --color-brand-900: #1e3a5f;
  --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif;
  --radius-xl: 1rem;
  --shadow-card: 0 1px 3px rgba(0,0,0,0.1), 0 1px 2px rgba(0,0,0,0.06);
}
```

### Custom Utilities (v4)

```css
/* Static */
@layer utilities {
  .text-balance { text-wrap: balance; }
  .scrollbar-hidden { scrollbar-width: none; &::-webkit-scrollbar { display: none; } }
}

/* Functional — generates classes like text-outline-2, grid-auto-fill-280 */
@utility text-outline-* {
  -webkit-text-stroke-width: --value(integer)px;
  -webkit-text-stroke-color: currentColor;
}
@utility grid-auto-fill-* {
  grid-template-columns: repeat(auto-fill, minmax(--value(integer)px, 1fr));
}
```

### Custom Variants and Legacy Plugins

```css
@custom-variant hocus (&:hover, &:focus-visible);
@custom-variant theme-midnight (&:where([data-theme="midnight"], [data-theme="midnight"] *));

/* Load legacy JS plugins */
@plugin "@tailwindcss/typography";
@plugin "@tailwindcss/forms";
```

## Tailwind with React/Vue

### The `cn` Utility

```ts
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";
export function cn(...inputs: ClassValue[]) { return twMerge(clsx(inputs)); }
```

### Conditional Classes and className Forwarding

```tsx
<div className={cn(
  "rounded-lg border p-4",
  isActive ? "border-blue-500 bg-blue-50" : "border-gray-200",
  isDisabled && "pointer-events-none opacity-50"
)}>Content</div>
```

Always merge incoming `className` with defaults:

```tsx
function Badge({ className, ...props }: React.HTMLAttributes<HTMLSpanElement>) {
  return <span className={cn("rounded-full bg-gray-100 px-2.5 py-0.5 text-xs font-medium", className)} {...props} />;
}
```

### Vue Class Binding

```vue
<template>
  <button :class="cn(
    'rounded-lg px-4 py-2 font-medium transition-colors',
    variant === 'primary' ? 'bg-blue-600 text-white' : 'bg-gray-100 text-gray-900',
    props.class
  )"><slot /></button>
</template>
```

## Performance

- Tailwind v4 auto-detects content files — no manual `content` config needed.
- Lightning CSS engine (default in v4) — no PostCSS config needed for most setups.
- Only CSS for actually-used utilities is produced.
- **Never** dynamically construct class names: `text-${color}-500` breaks detection. Use complete literals.
- Safelist truly dynamic classes: `@source inline("text-red-500 text-blue-500");`

## Common Patterns

### Card Component

```html
<div class="overflow-hidden rounded-xl border border-gray-200 bg-white shadow-sm
  transition-shadow hover:shadow-md">
  <img class="aspect-video w-full object-cover" src="/img.jpg" alt="" />
  <div class="p-6">
    <h3 class="text-lg font-semibold text-gray-900">Title</h3>
    <p class="mt-2 text-sm text-gray-600">Description text here.</p>
  </div>
</div>
```

### Responsive Navbar

```html
<header class="sticky top-0 z-50 border-b bg-white/80 backdrop-blur-sm">
  <div class="mx-auto flex h-16 max-w-7xl items-center justify-between px-4">
    <a href="/" class="text-xl font-bold">Logo</a>
    <nav class="hidden items-center gap-6 md:flex">
      <a href="#" class="text-sm text-gray-600 hover:text-gray-900">Link</a>
    </nav>
    <button class="md:hidden" aria-label="Menu">☰</button>
  </div>
</header>
```

### Form Input

```html
<label class="block">
  <span class="text-sm font-medium text-gray-700">Email</span>
  <input type="email" class="mt-1 block w-full rounded-lg border border-gray-300 px-3 py-2
    text-sm shadow-sm placeholder:text-gray-400
    focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500
    disabled:bg-gray-50 disabled:text-gray-500" placeholder="you@example.com" />
</label>
```

## Anti-Patterns

### Avoid These

- **@apply overuse.** Extract framework components instead. `@apply` hides the utility-first benefit and creates maintenance overhead.
- **Dynamic class construction.** `bg-${color}-500` breaks purging. Use complete literal strings.
- **Excessive custom classes.** If you're writing more custom CSS than utilities, reconsider the approach.
- **Ignoring `cn`/`twMerge`.** Without merge logic, class conflicts produce unpredictable results (e.g., `p-4` vs `p-6` both applied).
- **Inline `!important`.** Use `!` prefix sparingly (`!mt-0`). If needed often, the architecture has a problem.
- **Nesting responsive inside state.** Write `md:hover:bg-blue-600`, not `hover:md:bg-blue-600`. Responsive prefixes come first.
- **Ignoring semantic tokens.** Hardcoding `bg-blue-600` everywhere instead of `bg-primary` makes theme changes painful.
