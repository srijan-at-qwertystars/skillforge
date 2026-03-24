# Sass/SCSS Troubleshooting Guide

## Table of Contents
- [@import to @use Migration](#import-to-use-migration)
- [Namespace Conflicts](#namespace-conflicts)
- [Circular Dependencies](#circular-dependencies)
- [Variable Scoping](#variable-scoping)
- [!default vs !global](#default-vs-global)
- [Performance and Deep Nesting](#performance-and-deep-nesting)
- [Source Map Issues](#source-map-issues)
- [Dart Sass vs LibSass](#dart-sass-vs-libsass)
- [Build Tool Issues](#build-tool-issues)

---

## @import to @use Migration

### Problem: "This module was already loaded" error
`@use` loads modules once. Multiple `@use` of the same file in different partials is fine — they share state. But you cannot `@use` the same file with different `with` configurations.

```scss
// ❌ ERROR — conflicting configurations
@use 'tokens' with ($primary: red);
@use 'tokens' with ($primary: blue); // Already loaded

// ✅ FIX — configure once, at the entry point
// main.scss
@use 'tokens' with ($primary: red);
// Other files just @use 'tokens' without `with`
```

### Problem: Variables not accessible after migration
With `@import`, everything was global. With `@use`, variables are namespaced.

```scss
// ❌ BROKEN — after mechanical @import→@use replacement
@use 'variables';
.btn { color: $primary; } // Error: undefined variable

// ✅ FIX — use namespace
@use 'variables';
.btn { color: variables.$primary; }

// ✅ ALT — use as * (sparingly)
@use 'variables' as *;
.btn { color: $primary; }
```

### Problem: Deprecated global function warnings
Dart Sass warns on global functions that moved to modules.

```scss
// ❌ Deprecated
$lighter: lighten($color, 10%);
$value: map-get($map, key);
$type: type-of($x);

// ✅ Module functions
@use 'sass:color';
@use 'sass:map';
@use 'sass:meta';
$lighter: color.adjust($color, $lightness: 10%);
$value: map.get($map, key);
$type: meta.type-of($x);
```

### Problem: @use must come before other rules
Unlike `@import`, `@use` must be at the top of the file (after `@charset` and `@forward` only).

```scss
// ❌ ERROR
$var: 10px;
@use 'sass:math'; // Error: @use must come before other rules

// ✅ FIX
@use 'sass:math';
$var: 10px;
```

### Problem: Third-party libraries still using @import
Wrap the library in a `@forward` file:

```scss
// _vendor.scss — bridge file
@forward 'legacy-library';

// main.scss
@use 'vendor';
```

Or use the sass-migrator tool: `sass-migrator module --migrate-deps entry.scss`

---

## Namespace Conflicts

### Problem: Two modules export same name
```scss
// ❌ Ambiguous — both have $primary
@use 'brand-tokens' as *;
@use 'legacy-tokens' as *;
.btn { color: $primary; } // Which $primary?

// ✅ FIX — explicit namespaces
@use 'brand-tokens' as brand;
@use 'legacy-tokens' as legacy;
.btn { color: brand.$primary; }

// ✅ ALT — show/hide specific members
@use 'brand-tokens' show $primary, $secondary;
@use 'legacy-tokens' hide $primary;
```

### Problem: @forward re-exports collide
```scss
// _index.scss
@forward 'colors';   // exports $primary
@forward 'brand';    // also exports $primary → ERROR

// ✅ FIX — prefix re-exports
@forward 'colors' as color-*;   // color.$color-primary
@forward 'brand' as brand-*;    // brand.$brand-primary
```

---

## Circular Dependencies

### Problem: "This module is currently being loaded"
Module A uses Module B, which uses Module A.

```scss
// ❌ Circular
// _buttons.scss
@use 'utils';      // utils uses buttons → CIRCULAR

// ✅ FIX — extract shared code
// _shared.scss (no dependencies)
$radius: 4px;

// _utils.scss
@use 'shared';

// _buttons.scss
@use 'shared';
@use 'utils';
```

### Resolution strategy:
1. Map your dependency graph (which file uses which)
2. Extract shared variables/mixins into a leaf module with no `@use`
3. Make the dependency tree acyclic — data flows one direction
4. Use `@forward` to create barrel files that don't add cross-deps

```
tokens.scss (leaf — no @use)
  ↑
mixins.scss (@use 'tokens')
  ↑
components/*.scss (@use 'mixins')
```

---

## Variable Scoping

### Problem: Variable set inside mixin doesn't persist
Variables in Sass are block-scoped with `@use` modules.

```scss
$color: red;

@mixin set-blue {
  $color: blue; // Creates a LOCAL $color — does not change outer
}

@include set-blue;
.box { color: $color; } // Still red

// ✅ If you truly need to modify outer scope:
@mixin set-blue {
  $color: blue !global; // Modifies the module-level variable
}
```

### Problem: Variables not available in @content blocks
`@content` blocks are evaluated in the **caller's** scope, not the mixin's scope.

```scss
@mixin with-theme($color) {
  $bg: lighten($color, 40%);
  @content; // $bg is NOT available inside @content
}

// ❌ BROKEN
@include with-theme(blue) {
  background: $bg; // Error: undefined variable
}

// ✅ FIX — use @content with named arguments (Dart Sass 1.15+)
@mixin with-theme($color) {
  $bg: color.adjust($color, $lightness: 40%);
  @content($bg);
}

@include with-theme(blue) using ($bg) {
  background: $bg; // ✅ Works
}
```

---

## !default vs !global

### !default — "set only if undefined"
Used in libraries to provide overridable defaults:

```scss
// _tokens.scss
$primary: #007bff !default;   // Consumer can override via @use...with
$radius: 4px !default;

// Consumer
@use 'tokens' with ($primary: #e63946);
// $primary is #e63946, $radius stays 4px
```

**Key rules:**
- Only works at the top level of a module (not inside mixins/functions)
- Variable must not already exist in the module for `!default` to take effect
- With `@use...with`, the override happens BEFORE the module body runs

### !global — "write to module scope"
Modifies a variable in the enclosing module's scope from within a block:

```scss
$theme: 'light';

@mixin switch-theme($name) {
  $theme: $name !global; // Changes the module-level $theme
}
```

**Dangers:**
- Makes code hard to reason about (action at a distance)
- Cannot create new globals — variable must already exist at module level
- Avoid in libraries; use configuration maps or `@use...with` instead

---

## Performance and Deep Nesting

### Problem: Slow compilation
**Causes:**
- Deep nesting (>4 levels) creates exponential selector expansion
- Large `@each` loops over big maps
- `@extend` across many selectors (selector unification is O(n²))
- Using `sass` (JS) instead of `sass-embedded` (native Dart process)

**Fixes:**
```bash
# Switch to sass-embedded (3-5x faster)
npm uninstall sass && npm install -D sass-embedded
```

```scss
// ❌ Deep nesting — huge output
.page .content .article .section .paragraph .link { ... }

// ✅ Flatten with BEM
.article__link { ... }
```

```scss
// ❌ @extend explosion
%base { ... }
.a { @extend %base; }
.b { @extend %base; }
// ... 50 more → one giant grouped selector

// ✅ Use mixin for large fan-out
@mixin base { ... }
.a { @include base; }
```

### Performance checklist:
- Max nesting: 3 levels
- Use `sass-embedded` + `api: 'modern-compiler'` in Vite/webpack
- Prefer `@mixin` over `@extend` when >10 selectors extend the same thing
- Split large map iterations into separate partials for parallel compilation
- Avoid `@import` (reimported on every use vs `@use` loaded once)

---

## Source Map Issues

### Problem: Browser DevTools shows compiled CSS, not SCSS
Ensure source maps are enabled in your build tool:

```js
// Vite (enabled by default in dev)
export default defineConfig({
  css: { devSourcemap: true },
});

// webpack
{ loader: 'sass-loader', options: { sourceMap: true } }
```

```bash
# CLI compilation
sass --source-map input.scss output.css
```

### Problem: Source maps point to wrong files
- Check that `sourceMapIncludeSources: true` is set
- Relative paths may break with monorepo symlinks — use absolute paths
- Clear build cache after changing Sass file structure

### Problem: Source maps missing in production
By default, production builds strip source maps:

```js
// Vite — keep in production (not recommended for public sites)
export default defineConfig({
  build: { sourcemap: true },
});
```

---

## Dart Sass vs LibSass

### Feature comparison

| Feature                       | Dart Sass          | LibSass (deprecated) |
|-------------------------------|--------------------|-----------------------|
| `@use` / `@forward`          | ✅ Full support    | ❌ Not supported      |
| `map.deep-merge()`           | ✅ Since 1.27      | ❌ Not available      |
| `meta.load-css()`            | ✅ Supported       | ❌ Not available      |
| `math.div()` (no `/` divide) | ✅ Required        | ❌ Uses `/` operator  |
| Color Level 4 functions      | ✅ Since 1.80      | ❌ Not available      |
| `@content` with args         | ✅ Since 1.15      | ❌ Not available      |
| Speed (JS wrapper)           | Slower             | Faster (C++)          |
| Speed (native/embedded)      | ✅ Fast            | N/A (deprecated)      |
| Maintenance                  | ✅ Active          | ❌ EOL Oct 2025       |

### Migration from LibSass/node-sass
```bash
# Remove old packages
npm uninstall node-sass

# Install Dart Sass
npm install -D sass-embedded

# Run migrator
npx sass-migrator module --migrate-deps src/main.scss
```

### Common breakages after migration:
- `/` used for division → use `math.div()`
- Global functions → prefix with module namespace
- `@import` order-dependent code → restructure as modules
- Color functions renamed: `lighten()` → `color.adjust($c, $lightness: N%)`

---

## Build Tool Issues

### Problem: "Can't find stylesheet to import" in Vite
```js
// Ensure resolve alias is configured
import { defineConfig } from 'vite';
import path from 'path';

export default defineConfig({
  resolve: { alias: { '@': path.resolve(__dirname, 'src') } },
  css: {
    preprocessorOptions: {
      scss: {
        api: 'modern-compiler',
        additionalData: `@use "@/styles/abstracts" as *;\n`,
      },
    },
  },
});
```

### Problem: "Deprecation: import" warnings flooding console
```bash
# Suppress deprecation warnings temporarily
sass --quiet-deps input.scss output.css

# Or in build config
scss: { silenceDeprecations: ['import'] }
```

### Problem: Hot reload not picking up partial changes
- Ensure partials start with `_` (e.g., `_variables.scss`)
- Vite tracks `@use` deps automatically but not dynamic `meta.load-css()` paths
- Restart dev server after adding new partials
