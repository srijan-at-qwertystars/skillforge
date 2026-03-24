---
name: sass-patterns
description: >
  Modern Dart Sass/SCSS patterns using the module system (@use/@forward), namespacing,
  variables, nesting, partials, mixins with @content, @extend, placeholder selectors,
  built-in modules (sass:math, sass:color, sass:string, sass:list, sass:map, sass:meta),
  control flow, interpolation, color functions, responsive mixins, design tokens with
  Sass maps, BEM methodology, CSS custom properties integration, build tool configuration
  (Vite/webpack/PostCSS), stylelint setup, and migration from @import to @use.
  Triggers: Sass, SCSS, Sass mixins, Sass variables, Sass modules, @use, @forward,
  Sass functions, Sass maps, Sass nesting, Sass partials, design tokens SCSS,
  responsive mixins SCSS, BEM Sass, Sass color functions, sass-embedded.
  NOT for plain CSS without preprocessor features, NOT for CSS-in-JS (styled-components,
  Emotion, Stitches), NOT for Tailwind utility classes, NOT for Less/Stylus preprocessors,
  NOT for vanilla PostCSS-only workflows.
---

# Sass/SCSS Patterns (Dart Sass)

Dart Sass is the only active Sass implementation. LibSass and Ruby Sass are deprecated.
Always use `sass` or `sass-embedded` npm packages. Prefer `sass-embedded` for performance.

## Module System (@use / @forward)

`@import` is deprecated and removed in Dart Sass 3.0. Use `@use` and `@forward` exclusively.

### @use — Import with Namespace

```scss
// INPUT: _tokens.scss
$primary: #007bff;
$radius: 4px;

// INPUT: component.scss
@use 'tokens';

.btn { color: tokens.$primary; border-radius: tokens.$radius; }
```

```scss
// Custom namespace
@use 'tokens' as t;
.btn { color: t.$primary; }

// Glob namespace (use sparingly, only for small utility modules)
@use 'tokens' as *;
.btn { color: $primary; }
```

### @forward — Re-export for API Surfaces

```scss
// INPUT: abstracts/_index.scss
@forward 'tokens';
@forward 'mixins';
@forward 'functions';

// INPUT: main.scss
@use 'abstracts';
.card { color: abstracts.$primary; }
```

Use `show`/`hide` to control exposed API:

```scss
@forward 'tokens' show $primary, $secondary;
@forward 'tokens' hide $internal-var;
```

### Configure Modules

```scss
// _tokens.scss
$primary: #007bff !default;
$font-stack: system-ui, sans-serif !default;

// main.scss
@use 'tokens' with ($primary: #e63946, $font-stack: 'Inter', sans-serif);
```

## Variables, Nesting, Partials

### Variables

```scss
// Scoped variables
$spacing-unit: 8px;
$z-layers: (modal: 1000, dropdown: 500, tooltip: 700);
```

### Nesting — Max 3 Levels

```scss
.nav {
  &__list { display: flex; }
  &__link {
    color: inherit;
    &:hover { text-decoration: underline; } // deepest acceptable level
  }
}
```

### Partials and File Structure

```
scss/
├── abstracts/       # _tokens.scss, _mixins.scss, _functions.scss, _index.scss
├── base/            # _reset.scss, _typography.scss
├── components/      # _button.scss, _card.scss, _modal.scss
├── layout/          # _grid.scss, _header.scss, _footer.scss
├── themes/          # _light.scss, _dark.scss
└── main.scss        # Entry point — @use only, no direct styles
```

## Mixins with @content

```scss
// INPUT
@mixin overlay($bg: rgba(0, 0, 0, 0.5)) {
  position: fixed;
  inset: 0;
  background: $bg;
  @content;
}

.modal-backdrop {
  @include overlay { z-index: 1000; display: grid; place-items: center; }
}

// OUTPUT
.modal-backdrop {
  position: fixed;
  inset: 0;
  background: rgba(0, 0, 0, 0.5);
  z-index: 1000;
  display: grid;
  place-items: center;
}
```

### Mixin with Named Arguments

```scss
@mixin truncate($lines: 1, $display: -webkit-box) {
  overflow: hidden;
  @if $lines == 1 {
    text-overflow: ellipsis;
    white-space: nowrap;
  } @else {
    display: $display;
    -webkit-line-clamp: $lines;
    -webkit-box-orient: vertical;
  }
}

.title { @include truncate($lines: 2); }
```

## @extend and Placeholder Selectors

Prefer `%placeholder` over extending concrete classes to avoid unintended CSS output.

```scss
// INPUT
%visually-hidden {
  position: absolute; width: 1px; height: 1px;
  overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap;
}
.sr-only { @extend %visually-hidden; }
.skip-link:not(:focus) { @extend %visually-hidden; }

// OUTPUT — grouped selector, placeholder itself emits nothing
.sr-only, .skip-link:not(:focus) {
  position: absolute; width: 1px; height: 1px;
  overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap;
}
```

## Built-in Modules

Always load via `@use 'sass:<module>'`. Never use deprecated global functions.

### sass:math

```scss
@use 'sass:math';

$cols: 12;
.col-4 { width: math.div(4, $cols) * 100%; }        // 33.3333%
$rounded: math.round(3.7);                            // 4
$clamped: math.clamp(10px, 5px, 20px);                // 10px
$power: math.pow(2, 3);                                // 8
```

### sass:color

```scss
@use 'sass:color';
$brand: #3498db;
$lighter: color.adjust($brand, $lightness: 15%);
$scaled:  color.scale($brand, $lightness: 30%);   // scales toward white
$mixed:   color.mix($brand, #e74c3c, 50%);
$faded:   color.adjust($brand, $alpha: -0.3);

@function shade($color, $pct) { @return color.mix(black, $color, $pct); }
@function tint($color, $pct)  { @return color.mix(white, $color, $pct); }
```

### sass:string / sass:list

```scss
@use 'sass:string';
@use 'sass:list';

$cls: string.slice('btn-primary', 5);     // "primary"
$upper: string.to-upper-case('hello');     // "HELLO"
$first: list.nth(('Helvetica', 'Arial'), 1); // "Helvetica"
$joined: list.join(('a', 'b'), ('c', 'd'));  // 'a', 'b', 'c', 'd'
```

### sass:map

```scss
@use 'sass:map';
$theme: (primary: #007bff, secondary: #6c757d, danger: #dc3545);
$primary: map.get($theme, primary);
$merged:  map.merge($theme, (success: #28a745));
$has:     map.has-key($theme, primary);             // true

// Deep map access
$tokens: (color: (brand: (primary: #007bff)));
$deep: map.get($tokens, color, brand, primary);    // #007bff
```

### sass:meta

```scss
@use 'sass:meta';
$type: meta.type-of(42px);      // "number"
@include meta.load-css('path/to/module'); // dynamic CSS loading
```

## Control Flow

### @if / @else

```scss
@mixin theme-color($variant) {
  @if $variant == 'light'      { background: #fff; color: #333; }
  @else if $variant == 'dark'  { background: #1a1a2e; color: #eee; }
  @else { @error "Unknown theme variant: #{$variant}"; }
}
```

### @each

```scss
$sizes: (sm: 0.875rem, md: 1rem, lg: 1.25rem, xl: 1.5rem);

@each $name, $size in $sizes {
  .text-#{$name} { font-size: $size; }
}
// OUTPUT: .text-sm { font-size: 0.875rem; } ...
```

### @for

```scss
@for $i from 1 through 12 {
  .col-#{$i} { width: math.div($i, 12) * 100%; }
}
```

### @while (rare — prefer @for or @each)

```scss
$i: 6;
@while $i > 0 { .order-#{$i} { order: $i; } $i: $i - 2; }
```

## Interpolation

Use `#{}` in selectors, property names, and values. Not supported in `@use` paths.

```scss
$prop: 'margin'; $side: 'top';
.spacing { #{$prop}-#{$side}: 1rem; }
```

## Responsive Mixins

```scss
@use 'sass:map';
$breakpoints: (sm: 576px, md: 768px, lg: 992px, xl: 1200px, xxl: 1400px);

@mixin respond($bp) {
  @if not map.has-key($breakpoints, $bp) {
    @error "Unknown breakpoint `#{$bp}`. Available: #{map.keys($breakpoints)}";
  }
  @media (min-width: map.get($breakpoints, $bp)) { @content; }
}

@mixin respond-down($bp) {
  @media (max-width: map.get($breakpoints, $bp) - 0.02px) { @content; }
}

@mixin respond-between($lower, $upper) {
  @media (min-width: map.get($breakpoints, $lower))
     and (max-width: map.get($breakpoints, $upper) - 0.02px) {
    @content;
  }
}

// Usage
.container {
  padding: 1rem;
  @include respond(md) { padding: 2rem; }
  @include respond(xl) { padding: 3rem; max-width: 1200px; }
}
```

## Design Tokens with Sass Maps

```scss
@use 'sass:map';

$spacing: (0: 0, 1: 0.25rem, 2: 0.5rem, 3: 1rem, 4: 1.5rem, 5: 3rem);
@each $key, $val in $spacing {
  .m-#{$key} { margin: $val; }
  .p-#{$key} { padding: $val; }
}

$colors: (
  primary: (base: #007bff, light: #66b2ff, dark: #0056b3),
  danger:  (base: #dc3545, light: #e4606d, dark: #a71d2a),
);

@each $name, $shades in $colors {
  @each $shade, $value in $shades {
    .text-#{$name}-#{$shade} { color: $value; }
    .bg-#{$name}-#{$shade}   { background-color: $value; }
  }
}
```

## BEM Methodology with Sass

```scss
.card {
  border: 1px solid #ddd; border-radius: 8px;
  &__header { padding: 1rem; border-bottom: 1px solid #ddd; }
  &__body   { padding: 1rem; }
  &__footer { padding: 1rem; border-top: 1px solid #ddd; }
  &--featured {
    border-color: #007bff;
    .card__header { background: #007bff; color: #fff; }
  }
}
```

### BEM Mixin Pattern

```scss
@mixin element($name) { &__#{$name} { @content; } }
@mixin modifier($name) { &--#{$name} { @content; } }

.alert {
  padding: 1rem;
  @include element(icon) { margin-right: 0.5rem; }
  @include modifier(success) { background: #d4edda; color: #155724; }
  @include modifier(error)   { background: #f8d7da; color: #721c24; }
}
```

## CSS Custom Properties + Sass

Use Sass for build-time logic; CSS custom properties for runtime theming.

```scss
@use 'sass:map';

$theme-light: (bg: #ffffff, text: #333333, accent: #007bff);
$theme-dark:  (bg: #1a1a2e, text: #e0e0e0, accent: #4dabf7);

@mixin apply-theme($theme) {
  @each $key, $value in $theme {
    --color-#{$key}: #{$value};
  }
}

:root            { @include apply-theme($theme-light); }
[data-theme='dark'] { @include apply-theme($theme-dark); }

// Consumption — pure CSS, no Sass dependency at runtime
.card {
  background: var(--color-bg);
  color: var(--color-text);
  border: 2px solid var(--color-accent);
}
```

## Build Tool Configuration

### Vite (recommended) — see `assets/vite-sass-config.ts` for full config

```bash
npm install -D sass-embedded
```

```js
// vite.config.js
export default defineConfig({
  css: {
    preprocessorOptions: {
      scss: {
        api: 'modern-compiler',   // default in Vite 7+
        additionalData: `@use "@/styles/abstracts" as *;`,
      },
    },
  },
});
```

### Webpack

```js
// webpack.config.js — SCSS rule
{
  test: /\.scss$/,
  use: [
    'style-loader', 'css-loader', 'postcss-loader',
    { loader: 'sass-loader', options: { implementation: require('sass-embedded'), api: 'modern-compiler' } },
  ],
}
```

### Stylelint — see `assets/stylelint.config.js` for production config

```bash
npm install -D stylelint stylelint-config-standard-scss stylelint-order
```

## Migration from @import to @use

1. Install the migration tool: `npm install -g sass-migrator`
2. Run: `sass-migrator module --migrate-deps main.scss`
3. Review changes: global functions become `module.fn()`, variables become `ns.$var`
4. Replace `@import` with `@use` / `@forward` in every file
5. Create `_index.scss` entry points per folder using `@forward`
6. Update build configs to remove deprecated `--quiet-deps` if no longer needed

### Common Renames

```scss
// BEFORE (deprecated)                  // AFTER (module system)
@import 'variables';                    @use 'variables' as vars;
$color: lighten($brand, 10%);          $color: color.adjust($brand, $lightness: 10%);
$val: map-get($map, key);              $val: map.get($map, key);
$n: nth($list, 1);                     $n: list.nth($list, 1);
$type: type-of($x);                    $type: meta.type-of($x);
$result: percentage(0.5);              $result: math.percentage(0.5);
```

## Key Rules

- Always use Dart Sass (`sass` or `sass-embedded`). Never LibSass.
- Use `@use`/`@forward` exclusively. Never `@import`.
- Namespace all module access: `tokens.$var`, `color.adjust()`.
- Max nesting depth: 3 levels. Flatten with BEM naming.
- Prefer `%placeholder` + `@extend` over extending concrete selectors.
- Use `@error` and `@warn` for defensive mixin/function APIs.
- Keep partials small and focused. One component per file.
- Use `sass-embedded` + `api: 'modern-compiler'` in build tools.
- Emit CSS custom properties from Sass maps for runtime theming.
- Validate with `stylelint-config-standard-scss`.

## Supplemental Files

### references/
- `advanced-patterns.md` — meta.load-css(), @at-root, selector manipulation, custom @function, deep merge, CSS grid/container query mixins, dark mode theming, animation mixins, module configuration
- `troubleshooting.md` — @import→@use migration pitfalls, namespace conflicts, circular deps, variable scoping, !default vs !global, nesting performance, source maps, Dart Sass vs LibSass
- `api-reference.md` — Complete built-in module API: sass:math, sass:color, sass:string, sass:list, sass:map, sass:selector, sass:meta — all functions with signatures and examples

### scripts/
- `migrate-imports.sh` — Convert @import to @use/@forward using sass-migrator (--dry-run, --verbose, --no-deps)
- `lint-setup.sh` — Set up stylelint with SCSS plugin, property ordering, BEM patterns (--with-prettier)
- `analyze-sass.sh` — Find unused variables/mixins, deep nesting, @import usage, file complexity metrics

### assets/
- `design-tokens.scss` — Complete token system: colors (with auto light/dark variants), spacing scale, typography, breakpoints, radii, shadows, z-index, transitions, CSS variable emission
- `responsive-mixins.scss` — Breakpoint mixins (up/down/between/only), container queries, fluid typography, visibility helpers, auto-grid, preference queries (dark mode, reduced motion)
- `bem-component.scss` — BEM card component template with modifiers, variants from maps, responsive behavior
- `stylelint.config.js` — Production config with BEM naming, nesting limits, property ordering, SCSS rules
- `vite-sass-config.ts` — Vite config with sass-embedded, global @use injection, path aliases, framework notes

<!-- tested: pass -->
