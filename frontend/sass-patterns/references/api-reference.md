# Sass Built-in Modules — API Reference

All functions require `@use 'sass:<module>'`. Never use deprecated global function names.

## Table of Contents
- [sass:math](#sassmath)
- [sass:color](#sasscolor)
- [sass:string](#sassstring)
- [sass:list](#sasslist)
- [sass:map](#sassmap)
- [sass:selector](#sassselector)
- [sass:meta](#sassmeta)

---

## sass:math

```scss
@use 'sass:math';
```

### Constants
| Constant    | Value               |
|------------|---------------------|
| `math.$e`  | 2.7182818285...     |
| `math.$pi` | 3.1415926536...     |

### Rounding & Clamping
```scss
math.ceil(4.2)                 // 5
math.floor(4.9)                // 4
math.round(4.5)                // 5
math.clamp($min, $val, $max)   // clamp value between min and max
// math.clamp(10px, 8px, 20px) → 10px
// math.clamp(10px, 15px, 20px) → 15px
```

### Arithmetic
```scss
math.div($a, $b)           // Division (replaces / operator)
// math.div(100px, 3) → 33.3333px

math.abs($n)               // Absolute value
math.max($n...)             // Largest value
math.min($n...)             // Smallest value
math.percentage($n)         // Convert to percentage
// math.percentage(0.5) → 50%
```

### Powers & Roots
```scss
math.pow($base, $exp)      // math.pow(2, 3) → 8
math.sqrt($n)              // math.sqrt(16) → 4
math.log($n, $base: null)  // Natural log, or log base $base
math.hypot($n...)           // Hypotenuse: sqrt(a² + b²...)
```

### Trigonometry
```scss
math.cos($angle)    math.sin($angle)    math.tan($angle)
math.acos($n)       math.asin($n)       math.atan($n)
math.atan2($y, $x)
// Angles: use deg, rad, grad, or turn units
// math.cos(0deg) → 1
// math.sin(90deg) → 1
```

### Unit Functions
```scss
math.unit($n)                   // 'px', 'rem', '%', ''
// math.unit(100px) → 'px'
math.is-unitless($n)            // true/false
math.compatible($a, $b)         // Can units be combined?
// math.compatible(1px, 1em) → false
```

### Random
```scss
math.random()        // Float 0..1
math.random($limit)  // Int 1..$limit
// math.random(10) → integer between 1 and 10
```

---

## sass:color

```scss
@use 'sass:color';
```

### Adjusting Colors
```scss
color.adjust($color, $channels...)
// Add/subtract from channel values
// color.adjust(#007bff, $lightness: 15%) → lighter
// color.adjust(#007bff, $red: -20, $alpha: -0.3)

color.scale($color, $channels...)
// Scale channels toward their min/max
// color.scale(#007bff, $lightness: 50%)   → scale 50% toward white
// color.scale(#007bff, $lightness: -50%)  → scale 50% toward black

color.change($color, $channels...)
// Set channels to absolute values
// color.change(#007bff, $lightness: 80%)  → set lightness to exactly 80%
// color.change(#007bff, $alpha: 0.5)      → set alpha to 0.5
```

**Channel keyword arguments (all three functions):**
- RGB: `$red`, `$green`, `$blue` (0-255 for adjust/change, -100%–100% for scale)
- HSL: `$hue` (degrees), `$saturation`, `$lightness` (percentages)
- HWB: `$hue`, `$whiteness`, `$blackness`
- Alpha: `$alpha` (-1–1 for adjust, -100%–100% for scale, 0–1 for change)

### Mixing & Blending
```scss
color.mix($color1, $color2, $weight: 50%)
// color.mix(#007bff, #e74c3c, 70%) → 70% first color, 30% second
```

### Channel Accessors
```scss
color.red($c)          // 0–255
color.green($c)        // 0–255
color.blue($c)         // 0–255
color.hue($c)          // 0deg–360deg
color.saturation($c)   // 0%–100%
color.lightness($c)    // 0%–100%
color.alpha($c)        // 0–1  (alias: color.opacity)
color.whiteness($c)    // HWB whiteness
color.blackness($c)    // HWB blackness
```

### Color Space (Dart Sass 1.80+)
```scss
color.to-space($color, $space)
// color.to-space(#007bff, oklch)

color.to-gamut($color, $space: null)
// Clamp to gamut of target space

color.same($a, $b)
// Compare ignoring space — true if visually identical

color.is-legacy($c)
// true for rgb/hsl/hwb colors (pre-CSS-Color-4)

color.space($c)
// Returns the color's space name: 'rgb', 'hsl', 'oklch', etc.

color.complement($c)
// Rotate hue 180°

color.grayscale($c)
// Set saturation to 0%

color.ie-hex-str($c)
// #AARRGGBB format for legacy IE filters

color.invert($c, $weight: 100%)
// Invert color channels
```

---

## sass:string

```scss
@use 'sass:string';
```

### All Functions

```scss
string.quote($str)
// Adds quotes: string.quote(hello) → "hello"

string.unquote($str)
// Removes quotes: string.unquote("hello") → hello

string.index($str, $substr)
// 1-based index of first match, or null
// string.index("abcdef", "cd") → 3

string.insert($str, $insert, $index)
// string.insert("abcd", "XX", 3) → "abXXcd"

string.length($str)
// string.length("hello") → 5

string.slice($str, $start, $end: -1)
// 1-based, inclusive. Negative = from end.
// string.slice("abcdef", 3)    → "cdef"
// string.slice("abcdef", 2, 4) → "bcd"

string.to-upper-case($str)
string.to-lower-case($str)

string.unique-id()
// Generates a random unique CSS identifier (no quotes)
// Useful for generating unique class names or @keyframes names

string.split($str, $separator, $limit: null)
// Dart Sass 1.57+
// string.split("a,b,c", ",") → ("a", "b", "c")
// string.split("a,b,c", ",", 2) → ("a", "b,c")
```

---

## sass:list

```scss
@use 'sass:list';
```

### All Functions

```scss
list.append($list, $val, $separator: auto)
// list.append((a, b), c) → (a, b, c)
// Separator: comma, space, slash, or auto (inherits from $list)

list.index($list, $val)
// 1-based index, or null
// list.index((a, b, c), b) → 2

list.join($list1, $list2, $separator: auto, $bracketed: auto)
// list.join((a, b), (c, d)) → (a, b, c, d)

list.length($list)
// list.length((a, b, c)) → 3
// Single values are 1-element lists: list.length(42) → 1

list.nth($list, $n)
// 1-based. Negative indexes from end.
// list.nth((a, b, c), 2) → b
// list.nth((a, b, c), -1) → c

list.set-nth($list, $n, $val)
// Returns new list with replaced value
// list.set-nth((a, b, c), 2, X) → (a, X, c)

list.separator($list)
// Returns: 'comma', 'space', or 'slash'

list.zip($lists...)
// Combine lists element-by-element
// list.zip((1, 2), (a, b), (x, y)) → ((1, a, x), (2, b, y))

list.slash($elements...)
// Create slash-separated list
// list.slash(1, 2, 3) → 1 / 2 / 3

list.is-bracketed($list)
// true if list is [bracketed]
```

---

## sass:map

```scss
@use 'sass:map';
```

### All Functions

```scss
map.get($map, $keys...)
// Single key: map.get($m, name) → value or null
// Deep access: map.get($m, color, brand, primary) → nested value

map.set($map, $keys..., $value)
// Returns new map. Supports deep set.
// map.set($m, color, brand, primary, blue)

map.has-key($map, $keys...)
// Deep check: map.has-key($m, color, brand) → true/false

map.keys($map)
// Returns list of keys: map.keys((a: 1, b: 2)) → (a, b)

map.values($map)
// Returns list of values: map.values((a: 1, b: 2)) → (1, 2)

map.merge($map1, $map2)
// Shallow merge. $map2 wins on conflicts.
// map.merge((a: 1, b: 2), (b: 3, c: 4)) → (a: 1, b: 3, c: 4)
// Also accepts: map.merge($map, $key, $map2) for nested merge

map.deep-merge($map1, $map2)
// Recursive merge — nested maps are merged, not replaced
// Dart Sass 1.27+

map.remove($map, $keys...)
// map.remove((a: 1, b: 2, c: 3), b, c) → (a: 1)

map.deep-remove($map, $keys...)
// Remove a deeply nested key
// map.deep-remove($m, color, brand) → removes 'brand' from nested 'color'
```

### Map iteration
```scss
@each $key, $value in $map { ... }

// Nested maps
$tokens: (color: (primary: blue, accent: red));
@each $group, $values in $tokens {
  @each $name, $val in $values {
    .#{$group}-#{$name} { color: $val; }
  }
}
```

---

## sass:selector

```scss
@use 'sass:selector';
```

### All Functions

```scss
selector.append($selectors...)
// Append without space (compound selector)
// selector.append('.foo', '.bar') → '.foo.bar'
// selector.append('.a', '__b') → '.a__b'

selector.extend($selector, $extendee, $extender)
// Simulate @extend: replace $extendee with $extender in $selector
// selector.extend('.a.b', '.b', '.c') → '.a.b, .a.c'

selector.is-superselector($super, $sub)
// Does $super match everything $sub matches?
// selector.is-superselector('.a', '.a.b') → true

selector.nest($selectors...)
// Nest selectors like Sass nesting
// selector.nest('.a', '.b') → '.a .b'
// selector.nest('.a', '&.b') → '.a.b'

selector.parse($selector)
// Parse into list structure
// selector.parse('.a, .b') → ('.a', '.b')

selector.replace($selector, $original, $replacement)
// selector.replace('.a.b', '.b', '.c') → '.a.c'

selector.simple-selectors($selector)
// Break compound selector into parts
// selector.simple-selectors('.a.b#c') → ('.a', '.b', '#c')

selector.unify($sel1, $sel2)
// Intersect: find selector matching both
// selector.unify('.a', '.b') → '.a.b'
// selector.unify('.a', 'input') → 'input.a'
// Returns null if impossible
```

---

## sass:meta

```scss
@use 'sass:meta';
```

### Type Inspection
```scss
meta.type-of($value)
// Returns: 'number', 'string', 'color', 'list', 'map', 'bool',
//          'null', 'function', 'arglist', 'calculation'

meta.inspect($value)
// Unquoted string representation of any value
// Useful for debugging: @debug meta.inspect($complex-map);
```

### Variable & Function Existence
```scss
meta.variable-exists($name)
// Does variable exist in current scope?
// meta.variable-exists('primary') → true/false

meta.global-variable-exists($name, $module: null)
// Does variable exist at module level?
// meta.global-variable-exists('primary', 'tokens') → true

meta.function-exists($name, $module: null)
// meta.function-exists('adjust', 'color') → true

meta.mixin-exists($name, $module: null)
// meta.mixin-exists('respond', 'breakpoints') → true
```

### First-Class Functions
```scss
meta.get-function($name, $css: false, $module: null)
// Get a function reference for use with meta.call()
// $css: true to get a plain CSS function (not Sass)

meta.call($function, $args...)
// Call a function by reference
$fn: meta.get-function('adjust', $module: 'color');
$result: meta.call($fn, blue, $lightness: 20%);
```

### Module Introspection
```scss
meta.module-variables($module)
// Returns map of all variables in a loaded module
// meta.module-variables('tokens') → (primary: #007bff, ...)

meta.module-functions($module)
// Returns map of all functions in a loaded module
// meta.module-functions('utils') → (to-rem: get-function(...), ...)
```

### Dynamic CSS Loading
```scss
meta.load-css($url, $with: null)
// Load and emit CSS from another module
// Can only be used as @include (it's a mixin)
// $with: configuration map for !default vars in target

.scoped {
  @include meta.load-css('components/buttons', $with: ('radius': 8px));
}
```

### Content Detection
```scss
meta.content-exists()
// Use inside a mixin to check if @content block was passed

@mixin optional-wrapper {
  @if meta.content-exists() {
    .wrapper { @content; }
  } @else {
    .wrapper { display: block; }
  }
}
```

### Feature Detection
```scss
meta.feature-exists($feature)
// Check Sass implementation features
// Known features: 'global-variable-shadowing', 'extend-selector-pseudoclass',
//   'units-level-3', 'at-error', 'custom-property'
```

### Keyword Arguments
```scss
meta.keywords($args)
// Extract keyword arguments from an arglist as a map

@mixin config($args...) {
  $kw: meta.keywords($args);
  // If called as: @include config($color: red, $size: lg)
  // $kw → (color: red, size: lg)
}
```

### Calc Arguments (Dart Sass 1.40+)
```scss
meta.calc-args($calc)
// Returns args of a calculation: meta.calc-args(calc(1px + 10%)) → (1px, '+', 10%)

meta.calc-name($calc)
// Returns name: meta.calc-name(min(1px, 10%)) → 'min'
```
