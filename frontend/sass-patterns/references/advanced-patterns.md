# Advanced Sass Patterns

## Table of Contents
- [meta.load-css() — Scoped CSS Loading](#metaload-css)
- [@at-root and Selector Manipulation](#at-root-and-selector-manipulation)
- [Custom Functions with @function](#custom-functions)
- [Sass Maps Deep Merge](#sass-maps-deep-merge)
- [Module Configuration with @forward...with](#module-configuration)
- [CSS Grid Mixins](#css-grid-mixins)
- [Container Query Mixins](#container-query-mixins)
- [Dark Mode Theming](#dark-mode-theming)
- [Animation Mixins](#animation-mixins)
- [Complex Selector Patterns](#complex-selector-patterns)

---

## meta.load-css()

Dynamically load a module's CSS output inside a selector. Unlike `@use`, it can be scoped.

```scss
@use 'sass:meta';

// Scope third-party styles under a wrapper
.admin-panel {
  @include meta.load-css('vendor/datepicker');
}
// Output: .admin-panel .dp-header { ... }

// Override !default vars in the loaded module
.dark-theme {
  @include meta.load-css('themes/dark', $with: ('contrast': high));
}
```

**Caveats:**
- Loaded file must NOT use `&` at top level (no parent context)
- Module is evaluated independently — no access to outer variables
- Can only be used inside a rule or at root, not in functions
- File is loaded once per unique `($url, $with)` combination

**Use case — theme scoping:**
```scss
@use 'sass:meta';

@mixin scoped-theme($name) {
  [data-theme='#{$name}'] {
    @include meta.load-css('themes/#{$name}');
  }
}

@include scoped-theme('ocean');
@include scoped-theme('forest');
```

---

## @at-root and Selector Manipulation

### @at-root basics
Escape nesting context to emit rules at document root:

```scss
.parent {
  color: blue;
  @at-root .sibling { color: red; }
  // Output: .sibling { color: red; } — NOT .parent .sibling
}
```

### @at-root with selector.unify()
Combine parent context with a target selector:

```scss
@use 'sass:selector';

@mixin unify-parent($sel) {
  @at-root #{selector.unify(&, $sel)} {
    @content;
  }
}

.wrapper .field {
  @include unify-parent('input') { border: 1px solid blue; }
  @include unify-parent('select') { border: 1px solid green; }
}
// Output: .wrapper input.field { border: 1px solid blue; }
//         .wrapper select.field { border: 1px solid green; }
```

### @at-root with (without:)
Control which at-rules to escape:

```scss
@media print {
  .page {
    @at-root (without: media) {
      // Emitted outside @media print
      .screen-only { display: none; }
    }
  }
}
```

---

## Custom Functions

### Utility functions with type checking

```scss
@use 'sass:math';
@use 'sass:meta';
@use 'sass:list';

// Convert px to rem
@function to-rem($px, $base: 16px) {
  @if meta.type-of($px) != 'number' {
    @error 'to-rem() expects a number, got #{meta.type-of($px)}';
  }
  @if math.unit($px) != 'px' {
    @error 'to-rem() expects px units, got #{math.unit($px)}';
  }
  @return math.div($px, $base) * 1rem;
}

// Fluid value between min and max viewport
@function fluid($min, $max, $vw-min: 320px, $vw-max: 1200px) {
  $slope: math.div($max - $min, $vw-max - $vw-min);
  $intercept: $min - $slope * $vw-min;
  @return clamp(#{$min}, #{$intercept} + #{$slope * 100}vw, #{$max});
}

// Strip units from a number
@function strip-unit($val) {
  @return math.div($val, $val * 0 + 1);
}

// Get contrast color (black or white) for a background
@function contrast-color($bg) {
  $r: color.red($bg);
  $g: color.green($bg);
  $b: color.blue($bg);
  $luminance: math.div($r * 299 + $g * 587 + $b * 114, 1000);
  @return if($luminance > 128, #000, #fff);
}
```

### Higher-order functions with meta.get-function()

```scss
@use 'sass:meta';
@use 'sass:list';

@function transform-list($list, $fn) {
  $result: ();
  @each $item in $list {
    $result: list.append($result, meta.call($fn, $item));
  }
  @return $result;
}

@function double($n) { @return $n * 2; }

$doubled: transform-list((1 2 3 4), meta.get-function('double'));
// => (2 4 6 8)
```

---

## Sass Maps Deep Merge

`map.deep-merge()` recursively merges nested maps (Dart Sass 1.27+):

```scss
@use 'sass:map';

$defaults: (
  font: (size: 16px, family: 'Inter', weight: 400),
  color: (primary: #007bff, text: #333),
  spacing: (unit: 8px),
);

$overrides: (
  font: (size: 18px, weight: 500),
  color: (accent: #e63946),
);

$config: map.deep-merge($defaults, $overrides);
// Result:
// font:    (size: 18px, family: 'Inter', weight: 500)
// color:   (primary: #007bff, text: #333, accent: #e63946)
// spacing: (unit: 8px)
```

### Merging multiple maps

```scss
@function merge-all($maps...) {
  $result: ();
  @each $map in $maps {
    $result: map.deep-merge($result, $map);
  }
  @return $result;
}

$final: merge-all($base-tokens, $brand-tokens, $component-tokens);
```

### Deep get/set helpers

```scss
@function deep-set($map, $keys, $value) {
  $current-key: list.nth($keys, 1);
  $rest: if(list.length($keys) > 1, list.slice($keys, 2), ());

  @if list.length($rest) == 0 {
    @return map.set($map, $current-key, $value);
  }

  $nested: if(map.has-key($map, $current-key), map.get($map, $current-key), ());
  @return map.set($map, $current-key, deep-set($nested, $rest, $value));
}
```

---

## Module Configuration

### Configurable library pattern with @forward...with

```scss
// _config.scss — library defaults
$primary: #007bff !default;
$radius: 4px !default;
$font-stack: system-ui, sans-serif !default;

// _index.scss — library entry
@forward 'config';
@forward 'buttons';
@forward 'cards';

// Consumer's main.scss — override defaults
@use 'my-library' with (
  $primary: #e63946,
  $radius: 8px,
);
```

### Multi-level configuration

```scss
// _tokens.scss
$tokens: (
  color: (primary: blue, secondary: gray),
  spacing: (sm: 4px, md: 8px, lg: 16px),
) !default;

// _index.scss
@forward 'tokens';

// Consumer overrides nested values
@use 'sass:map';
@use 'design-system' with (
  $tokens: map.deep-merge(
    (color: (primary: blue, secondary: gray), spacing: (sm: 4px, md: 8px, lg: 16px)),
    (color: (primary: #e63946))
  )
);
```

---

## CSS Grid Mixins

```scss
@mixin grid($cols: 12, $gap: 1rem) {
  display: grid;
  grid-template-columns: repeat($cols, 1fr);
  gap: $gap;
}

@mixin grid-area($col-start, $col-span, $row-start: auto, $row-span: 1) {
  grid-column: #{$col-start} / span #{$col-span};
  @if $row-start != auto {
    grid-row: #{$row-start} / span #{$row-span};
  }
}

@mixin auto-grid($min-col-width: 250px, $gap: 1rem) {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax($min-col-width, 1fr));
  gap: $gap;
}

// Subgrid (modern browsers)
@mixin subgrid($direction: both) {
  display: grid;
  @if $direction == both {
    grid-template-columns: subgrid;
    grid-template-rows: subgrid;
  } @else if $direction == columns {
    grid-template-columns: subgrid;
  } @else {
    grid-template-rows: subgrid;
  }
}
```

---

## Container Query Mixins

```scss
@mixin container($name: null, $type: inline-size) {
  container-type: $type;
  @if $name { container-name: $name; }
}

@mixin cq-up($width, $name: null) {
  $query: if($name, '#{$name} ', '') + '(min-width: #{$width})';
  @container #{$query} { @content; }
}

@mixin cq-down($width, $name: null) {
  $query: if($name, '#{$name} ', '') + '(max-width: #{$width})';
  @container #{$query} { @content; }
}

// Usage
.card-grid { @include container(cards); }
.card {
  @include cq-up(400px, cards) {
    flex-direction: row;
  }
  @include cq-up(700px, cards) {
    grid-template-columns: 1fr 2fr;
  }
}
```

---

## Dark Mode Theming

### Strategy 1: Sass maps → CSS custom properties

```scss
@use 'sass:map';
@use 'sass:color';

$themes: (
  light: (bg: #fff, surface: #f5f5f5, text: #1a1a2e, text-muted: #666, accent: #007bff),
  dark:  (bg: #121212, surface: #1e1e2f, text: #e0e0e0, text-muted: #999, accent: #4dabf7),
);

@mixin emit-theme($name) {
  $theme: map.get($themes, $name);
  @each $key, $value in $theme {
    --color-#{$key}: #{$value};
  }
}

:root                   { @include emit-theme(light); }
[data-theme='dark']     { @include emit-theme(dark); }

@media (prefers-color-scheme: dark) {
  :root:not([data-theme='light']) { @include emit-theme(dark); }
}
```

### Strategy 2: Auto-generate dark palette

```scss
@use 'sass:color';
@use 'sass:map';

@function auto-dark($light-theme) {
  $dark: ();
  @each $key, $value in $light-theme {
    $dark: map.set($dark, $key, color.adjust($value, $lightness: -40%, $saturation: -10%));
  }
  @return $dark;
}
```

---

## Animation Mixins

```scss
// Keyframe generator
@mixin keyframes($name) {
  @keyframes #{$name} { @content; }
}

// Animation shorthand
@mixin animate($name, $dur: 0.3s, $ease: ease, $delay: 0s, $fill: both, $count: 1) {
  animation: #{$name} $dur $ease $delay $fill $count;
}

// Predefined animations
@include keyframes(fade-in) {
  from { opacity: 0; }
  to   { opacity: 1; }
}

@include keyframes(slide-up) {
  from { opacity: 0; transform: translateY(20px); }
  to   { opacity: 1; transform: translateY(0); }
}

@include keyframes(scale-in) {
  from { opacity: 0; transform: scale(0.9); }
  to   { opacity: 1; transform: scale(1); }
}

// Transition helper
@mixin transition($props...) {
  $transitions: ();
  @each $prop in $props {
    $transitions: append($transitions, $prop 0.2s ease, comma);
  }
  transition: $transitions;
}

// Usage
.modal   { @include animate(scale-in, 0.25s, cubic-bezier(0.34, 1.56, 0.64, 1)); }
.card    { @include transition(transform, box-shadow, opacity); }
```

---

## Complex Selector Patterns

### Dynamic utility class generation

```scss
@use 'sass:map';
@use 'sass:list';

$utilities: (
  display: (none, block, flex, grid, inline-flex),
  position: (static, relative, absolute, fixed, sticky),
  overflow: (hidden, auto, scroll, visible),
);

@each $prop, $values in $utilities {
  @each $val in $values {
    .#{$prop}-#{$val} { #{$prop}: $val; }
  }
}
```

### State-variant mixin

```scss
@mixin with-states($states: hover focus active) {
  @each $state in $states {
    &:#{$state}, &.is-#{$state} { @content; }
  }
}

.btn {
  background: var(--color-accent);
  @include with-states {
    background: var(--color-accent-hover);
  }
}
```

### Responsive utility generator

```scss
@use 'sass:map';

$breakpoints: (sm: 576px, md: 768px, lg: 992px, xl: 1200px);

@mixin responsive-utility($class, $prop, $value) {
  .#{$class} { #{$prop}: $value; }
  @each $bp, $width in $breakpoints {
    @media (min-width: $width) {
      .#{$bp}\:#{$class} { #{$prop}: $value; }
    }
  }
}

@include responsive-utility('hidden', 'display', 'none');
@include responsive-utility('flex', 'display', 'flex');
```
