# Complete RTL Support Guide

> Comprehensive reference for implementing right-to-left (RTL) language support in web applications.

## Table of Contents

- [CSS Logical Properties](#css-logical-properties)
- [Direction-Aware Flexbox and Grid](#direction-aware-flexbox-and-grid)
- [Bidirectional Text (Bidi Algorithm)](#bidirectional-text-bidi-algorithm)
- [Icon Mirroring](#icon-mirroring)
- [Chart and Graph RTL Adaptation](#chart-and-graph-rtl-adaptation)
- [Form Layout for RTL](#form-layout-for-rtl)
- [Testing RTL with Pseudo-Localization](#testing-rtl-with-pseudo-localization)
- [Tailwind CSS RTL Plugin](#tailwind-css-rtl-plugin)
- [CSS Specificity with dir Selectors](#css-specificity-with-dir-selectors)

---

## CSS Logical Properties

Logical properties replace physical (left/right/top/bottom) with direction-aware equivalents that automatically adapt to LTR and RTL layouts.

### Complete Property Mapping

| Physical Property | Logical Equivalent | Notes |
|---|---|---|
| `margin-left` | `margin-inline-start` | Start of inline axis |
| `margin-right` | `margin-inline-end` | End of inline axis |
| `margin-top` | `margin-block-start` | Start of block axis |
| `margin-bottom` | `margin-block-end` | End of block axis |
| `padding-left` | `padding-inline-start` | |
| `padding-right` | `padding-inline-end` | |
| `left` | `inset-inline-start` | Positioning |
| `right` | `inset-inline-end` | Positioning |
| `top` | `inset-block-start` | Positioning |
| `bottom` | `inset-block-end` | Positioning |
| `border-left` | `border-inline-start` | |
| `border-right` | `border-inline-end` | |
| `border-top-left-radius` | `border-start-start-radius` | block-start + inline-start |
| `border-top-right-radius` | `border-start-end-radius` | block-start + inline-end |
| `border-bottom-left-radius` | `border-end-start-radius` | block-end + inline-start |
| `border-bottom-right-radius` | `border-end-end-radius` | block-end + inline-end |
| `text-align: left` | `text-align: start` | |
| `text-align: right` | `text-align: end` | |
| `float: left` | `float: inline-start` | |
| `float: right` | `float: inline-end` | |
| `width` | `inline-size` | |
| `height` | `block-size` | |
| `min-width` | `min-inline-size` | |
| `max-height` | `max-block-size` | |
| `overflow-x` | `overflow-inline` | |
| `overflow-y` | `overflow-block` | |

### Shorthand Properties

```css
/* Margin/Padding shorthands */
.element {
  /* block-start | block-end */
  margin-block: 8px 16px;
  /* inline-start | inline-end */
  padding-inline: 12px 24px;
  /* Single value = both sides */
  margin-block: 16px;
  padding-inline: 20px;
}

/* Inset shorthand */
.overlay {
  /* block-start | inline-start | block-end | inline-end */
  inset: 0 auto auto 0;              /* physical */
  inset-block: 0 auto;               /* logical block */
  inset-inline: 0 auto;              /* logical inline */
}

/* Border shorthand */
.card {
  border-inline-start: 4px solid var(--accent);
  border-block-end: 1px solid var(--border);
}

/* Size shorthands */
.sidebar {
  inline-size: 280px;                /* width in LTR, still width in RTL */
  block-size: 100vh;
  min-inline-size: 200px;
  max-inline-size: 400px;
}
```

### Practical Refactoring Example

```css
/* ✗ Before — physical properties */
.sidebar {
  position: fixed;
  left: 0;
  top: 0;
  width: 280px;
  height: 100vh;
  border-right: 1px solid #e2e8f0;
  padding: 16px 24px 16px 16px;
}

.sidebar .nav-item {
  margin-left: 12px;
  padding-left: 8px;
  border-left: 3px solid transparent;
  text-align: left;
}

.sidebar .nav-item.active {
  border-left-color: #3b82f6;
}

/* ✓ After — logical properties */
.sidebar {
  position: fixed;
  inset-inline-start: 0;
  inset-block-start: 0;
  inline-size: 280px;
  block-size: 100vh;
  border-inline-end: 1px solid #e2e8f0;
  padding: 16px;
  padding-inline-end: 24px;
}

.sidebar .nav-item {
  margin-inline-start: 12px;
  padding-inline-start: 8px;
  border-inline-start: 3px solid transparent;
  text-align: start;
}

.sidebar .nav-item.active {
  border-inline-start-color: #3b82f6;
}
```

---

## Direction-Aware Flexbox and Grid

### Flexbox

Flexbox is inherently direction-aware — `flex-direction: row` follows the writing direction. In RTL, `row` goes right-to-left.

```css
/* This layout automatically reverses in RTL */
.nav {
  display: flex;
  flex-direction: row;
  gap: 16px;
}

/* Use row-reverse only when you need to invert the LOGICAL order */
/* Don't use row-reverse as an RTL fix — flexbox handles it natively */

/* Alignment with logical properties */
.header {
  display: flex;
  justify-content: flex-start;    /* inline-start in both LTR and RTL */
  align-items: center;
}

/* For order-sensitive layouts */
.toolbar {
  display: flex;
  gap: 8px;
}
.toolbar .logo { order: 0; }      /* always first in flow */
.toolbar .actions { order: 1; margin-inline-start: auto; }
```

### Grid

Grid also respects document direction. Named lines and areas work correctly in both directions.

```css
/* Grid template — automatically mirrors in RTL */
.page-layout {
  display: grid;
  grid-template-columns: 280px 1fr 320px;
  grid-template-areas: "sidebar main aside";
  gap: 24px;
}

/* Grid item placement with logical properties */
.sidebar { grid-area: sidebar; }
.main    { grid-area: main; }
.aside   { grid-area: aside; }

/* Use start/end instead of left/right */
.feature-card {
  grid-column-start: 1;           /* logical — follows direction */
  grid-column-end: span 2;
}
```

### Handling Exceptions

```css
/* When you MUST override direction for specific elements */
.ltr-only {
  direction: ltr;
  unicode-bidi: isolate;          /* prevent bidi influence on children */
}

/* Phone numbers, code blocks should always be LTR */
.phone-number,
.code-block,
.email-address {
  direction: ltr;
  unicode-bidi: embed;
  text-align: start;
}
```

---

## Bidirectional Text (Bidi Algorithm)

### Unicode Bidi Algorithm Basics

The Unicode Bidirectional Algorithm (UBA) determines text display order for mixed-direction content. Browsers implement this automatically, but edge cases need manual control.

### HTML Bidi Elements

```html
<!-- bdi: Bidirectional Isolate — isolates content from surrounding text -->
<p>User <bdi>محمد</bdi> posted 5 comments.</p>
<!-- Without bdi, numbers near Arabic text may shift position -->

<!-- bdo: Bidirectional Override — forces explicit direction -->
<p>Product code: <bdo dir="ltr">ABC-123-XYZ</bdo></p>

<!-- Nested direction changes -->
<div dir="rtl">
  <p>النص العربي مع <span dir="ltr">English text containing <span dir="rtl">عربي</span> inside</span>.</p>
</div>
```

### Unicode Control Characters

Use when HTML elements aren't available (e.g., in strings, attributes, tooltips).

| Character | Unicode | Purpose |
|---|---|---|
| LRM (Left-to-Right Mark) | `\u200E` | Forces LTR direction for adjacent text |
| RLM (Right-to-Left Mark) | `\u200F` | Forces RTL direction for adjacent text |
| LRE (Left-to-Right Embedding) | `\u202A` | Start LTR embedding |
| RLE (Right-to-Left Embedding) | `\u202B` | Start RTL embedding |
| PDF (Pop Directional Format) | `\u202C` | End embedding |
| LRI (Left-to-Right Isolate) | `\u2066` | Start LTR isolation (preferred) |
| RLI (Right-to-Left Isolate) | `\u2067` | Start RTL isolation (preferred) |
| PDI (Pop Directional Isolate) | `\u2069` | End isolation |

```ts
// Use isolation for user-generated content in formatted strings
function formatUserMention(username: string, direction: 'ltr' | 'rtl'): string {
  // Wrap username in directional isolate to prevent it from disrupting surrounding text
  return `\u2068${username}\u2069`;  // FSI (First Strong Isolate) + PDI
}

// In translation strings with embedded numbers near RTL text:
// ✗ "المستخدم لديه 5 رسائل" — "5" might jump to wrong position
// ✓ "المستخدم لديه \u200F5\u200F رسائل" — RLM anchors the number
```

### CSS `unicode-bidi`

```css
/* isolate — recommended for most cases */
.user-content {
  unicode-bidi: isolate;   /* treat as isolated directional run */
}

/* embed — for inline direction changes */
.product-code {
  direction: ltr;
  unicode-bidi: embed;     /* establish new embedding level */
}

/* plaintext — let the bidi algorithm determine direction */
.dynamic-text {
  unicode-bidi: plaintext; /* direction determined by first strong character */
}

/* isolate-override — force direction, ignore bidi algorithm */
.forced-ltr {
  direction: ltr;
  unicode-bidi: isolate-override;
}
```

---

## Icon Mirroring

### What to Mirror

| Mirror ✓ | Don't Mirror ✗ |
|---|---|
| Back/forward arrows | Media play/pause/stop |
| Navigation chevrons | Checkmarks ✓ |
| List bullets/indentation | Logos and brand marks |
| Progress indicators | Clocks (clockwise is universal) |
| Text alignment icons | Search magnifying glass |
| Undo/redo arrows | Download/upload arrows |
| Chat bubble tail direction | Mathematical operators |
| Breadcrumb separators | Sliders (keep thumb direction) |

### CSS Transform Approach

```css
/* Mirror icons that indicate direction */
[dir="rtl"] .icon-arrow-right,
[dir="rtl"] .icon-chevron-right,
[dir="rtl"] .icon-back,
[dir="rtl"] .icon-breadcrumb-sep {
  transform: scaleX(-1);
}

/* Better: use a utility class */
[dir="rtl"] .rtl-mirror {
  transform: scaleX(-1);
}

/* Don't mirror these — they're universal */
.icon-checkmark,
.icon-play,
.icon-download,
.icon-search {
  /* No [dir="rtl"] override needed */
}
```

### SVG Icon Mirroring

```tsx
interface IconProps {
  name: string;
  mirror?: boolean;  // Whether this icon should mirror in RTL
  className?: string;
}

function Icon({ name, mirror = false, className }: IconProps) {
  const dir = document.documentElement.dir;
  const shouldMirror = mirror && dir === 'rtl';

  return (
    <svg
      className={className}
      style={shouldMirror ? { transform: 'scaleX(-1)' } : undefined}
      aria-hidden="true"
    >
      <use href={`/icons.svg#${name}`} />
    </svg>
  );
}

// Usage:
<Icon name="arrow-right" mirror />       {/* mirrors in RTL */}
<Icon name="checkmark" />                 {/* never mirrors */}
<Icon name="breadcrumb-sep" mirror />     {/* mirrors in RTL */}
```

### React Component with Auto-Mirror

```tsx
const RTL_MIRROR_ICONS = new Set([
  'arrow-left', 'arrow-right', 'chevron-left', 'chevron-right',
  'reply', 'forward', 'undo', 'redo', 'indent', 'outdent',
  'exit', 'enter', 'external-link', 'sort',
]);

function SmartIcon({ name, ...props }: { name: string } & SVGProps<SVGSVGElement>) {
  const isRTL = useDirection() === 'rtl';
  const shouldMirror = isRTL && RTL_MIRROR_ICONS.has(name);

  return (
    <svg {...props} style={{ ...props.style, transform: shouldMirror ? 'scaleX(-1)' : undefined }}>
      <use href={`#icon-${name}`} />
    </svg>
  );
}
```

---

## Chart and Graph RTL Adaptation

### Axis and Label Positioning

```ts
// Chart.js RTL configuration
const chartConfig = {
  options: {
    rtl: isRTL,   // Chart.js v4+ has native RTL support
    scales: {
      x: {
        position: 'bottom',
        reverse: isRTL,  // reverse x-axis in RTL so time flows right-to-left
        ticks: {
          align: isRTL ? 'end' : 'start',
        },
      },
      y: {
        position: isRTL ? 'right' : 'left',  // y-axis moves to right side in RTL
      },
    },
    plugins: {
      legend: {
        rtl: isRTL,
        align: isRTL ? 'end' : 'start',
      },
      tooltip: {
        rtl: isRTL,
        textDirection: isRTL ? 'rtl' : 'ltr',
      },
    },
  },
};
```

### D3.js RTL Handling

```ts
// D3 bar chart with RTL support
function createBarChart(data: DataPoint[], { isRTL }: { isRTL: boolean }) {
  const margin = {
    top: 20, bottom: 30,
    // Swap left/right margins
    [isRTL ? 'right' : 'left']: 60,
    [isRTL ? 'left' : 'right']: 20,
  };

  const xScale = d3.scaleLinear()
    .domain([0, d3.max(data, d => d.value)!])
    .range(isRTL ? [width, 0] : [0, width]);  // reverse range for RTL

  const yScale = d3.scaleBand()
    .domain(data.map(d => d.label))
    .range([0, height]);

  // Position y-axis on the right for RTL
  const yAxis = isRTL ? d3.axisRight(yScale) : d3.axisLeft(yScale);

  svg.attr('dir', isRTL ? 'rtl' : 'ltr');
}
```

### Table and Data Grid RTL

```css
/* Tables auto-mirror with dir="rtl" on the root */
/* Ensure alignment is logical */
.data-table th,
.data-table td {
  text-align: start;         /* logical — start side in any direction */
  padding-inline: 12px;
}

/* Numeric columns: always LTR aligned end */
.data-table .col-numeric {
  text-align: end;
  direction: ltr;             /* numbers always LTR */
  unicode-bidi: isolate;
}

/* Sticky columns in RTL */
.data-table .sticky-col {
  position: sticky;
  inset-inline-start: 0;     /* sticks to start side (left in LTR, right in RTL) */
  z-index: 1;
}
```

---

## Form Layout for RTL

### Input Direction

```css
/* Most inputs follow document direction automatically */
input, textarea, select {
  text-align: start;
}

/* Force LTR for specific input types */
input[type="email"],
input[type="url"],
input[type="tel"],
input[type="number"] {
  direction: ltr;
  text-align: start;          /* aligns left even in RTL document */
}

/* Password fields: always LTR to match keyboard layout */
input[type="password"] {
  direction: ltr;
}
```

### Label and Field Alignment

```css
/* Form layout using grid + logical properties */
.form-group {
  display: grid;
  grid-template-columns: minmax(120px, auto) 1fr;
  gap: 8px 16px;
  align-items: center;
}

.form-group label {
  text-align: end;            /* right-aligned in LTR, left-aligned in RTL */
  padding-inline-end: 8px;
}

/* Inline form with icon */
.input-with-icon {
  position: relative;
}

.input-with-icon .icon {
  position: absolute;
  inset-inline-start: 12px;
  inset-block-start: 50%;
  transform: translateY(-50%);
}

.input-with-icon input {
  padding-inline-start: 40px;  /* space for icon on start side */
}
```

### Validation Message Positioning

```css
.field-error {
  margin-block-start: 4px;
  padding-inline-start: 4px;
  text-align: start;
  color: var(--error);
}

/* Error icon before/after message */
.field-error::before {
  content: '⚠ ';
  /* No mirroring needed — Unicode character is direction-neutral */
}

/* Inline validation indicator */
.input-wrapper {
  position: relative;
}

.validation-icon {
  position: absolute;
  inset-inline-end: 12px;    /* appears on end side of input */
  inset-block-start: 50%;
  transform: translateY(-50%);
}
```

### Checkbox and Radio Layout

```css
/* Custom checkbox/radio with logical spacing */
.checkbox-group,
.radio-group {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.checkbox-label,
.radio-label {
  display: flex;
  align-items: center;
  gap: 8px;
  cursor: pointer;
}

/* Checkmark position doesn't change — it's inside the box */
/* But the label text flows naturally with direction */
```

---

## Testing RTL with Pseudo-Localization

### RTL Pseudo-Locale Generation

```ts
// Generate a pseudo-RTL translation file for testing
// Wraps strings in RTL marks and adds Arabic-like characters
function pseudoRTL(text: string): string {
  // Skip ICU placeholders and HTML tags
  const RTL_CHAR_MAP: Record<string, string> = {
    a: 'ɐ', b: 'q', c: 'ɔ', d: 'p', e: 'ǝ', f: 'ɟ', g: 'ƃ',
    h: 'ɥ', i: 'ᴉ', j: 'ɾ', k: 'ʞ', l: 'l', m: 'ɯ', n: 'u',
    o: 'o', p: 'd', q: 'b', r: 'ɹ', s: 's', t: 'ʇ', u: 'n',
    v: 'ʌ', w: 'ʍ', x: 'x', y: 'ʎ', z: 'z',
  };

  let result = '';
  let inPlaceholder = 0;

  for (const char of text) {
    if (char === '{') inPlaceholder++;
    if (char === '}') inPlaceholder--;
    if (inPlaceholder > 0 || char === '{' || char === '}') {
      result += char;
    } else {
      result += RTL_CHAR_MAP[char.toLowerCase()] ?? char;
    }
  }

  return `\u200F${result}\u200F`;  // Wrap in RLM
}
```

### Visual Testing Checklist

```ts
// Playwright RTL visual testing
import { test, expect } from '@playwright/test';

const RTL_LOCALES = ['ar', 'he', 'fa', 'ur'];
const PAGES = ['/', '/dashboard', '/settings', '/checkout'];

for (const locale of RTL_LOCALES) {
  for (const page of PAGES) {
    test(`RTL visual: ${locale} ${page}`, async ({ page: p }) => {
      await p.goto(`/${locale}${page}`);

      // Verify dir attribute
      const dir = await p.getAttribute('html', 'dir');
      expect(dir).toBe('rtl');

      // Verify lang attribute
      const lang = await p.getAttribute('html', 'lang');
      expect(lang).toBe(locale);

      // Take screenshot for visual comparison
      await expect(p).toHaveScreenshot(`${locale}${page.replace(/\//g, '-')}.png`, {
        fullPage: true,
        threshold: 0.1,
      });
    });
  }
}
```

### Automated RTL Checks

```ts
// Check for physical CSS properties that should be logical
function auditPhysicalCSS(cssText: string): string[] {
  const violations: string[] = [];
  const physicalProps = [
    { pattern: /margin-left\s*:/g, replacement: 'margin-inline-start' },
    { pattern: /margin-right\s*:/g, replacement: 'margin-inline-end' },
    { pattern: /padding-left\s*:/g, replacement: 'padding-inline-start' },
    { pattern: /padding-right\s*:/g, replacement: 'padding-inline-end' },
    { pattern: /(?<!inset-inline-)left\s*:/g, replacement: 'inset-inline-start' },
    { pattern: /(?<!inset-inline-)right\s*:/g, replacement: 'inset-inline-end' },
    { pattern: /text-align\s*:\s*left/g, replacement: 'text-align: start' },
    { pattern: /text-align\s*:\s*right/g, replacement: 'text-align: end' },
    { pattern: /float\s*:\s*left/g, replacement: 'float: inline-start' },
    { pattern: /float\s*:\s*right/g, replacement: 'float: inline-end' },
    { pattern: /border-left\s*:/g, replacement: 'border-inline-start' },
    { pattern: /border-right\s*:/g, replacement: 'border-inline-end' },
  ];

  for (const { pattern, replacement } of physicalProps) {
    let match;
    while ((match = pattern.exec(cssText)) !== null) {
      violations.push(`Line contains "${match[0].trim()}" — use "${replacement}" instead.`);
    }
  }

  return violations;
}
```

### Stylelint Plugin for Logical Properties

```json
// .stylelintrc.json
{
  "plugins": ["stylelint-use-logical-spec"],
  "rules": {
    "liberty/use-logical-spec": [
      "always",
      {
        "except": [
          "overflow-x",
          "overflow-y"
        ]
      }
    ]
  }
}
```

---

## Tailwind CSS RTL Plugin

### Setup with `tailwindcss-rtl`

```bash
npm install tailwindcss-rtl
```

```js
// tailwind.config.js
module.exports = {
  plugins: [
    require('tailwindcss-rtl'),
  ],
};
```

### Logical Property Utilities

The plugin replaces physical utilities with logical alternatives:

| Physical Class | Logical Class | LTR | RTL |
|---|---|---|---|
| `ml-4` | `ms-4` | margin-left | margin-right |
| `mr-4` | `me-4` | margin-right | margin-left |
| `pl-4` | `ps-4` | padding-left | padding-right |
| `pr-4` | `pe-4` | padding-right | padding-left |
| `left-0` | `start-0` | left: 0 | right: 0 |
| `right-0` | `end-0` | right: 0 | left: 0 |
| `text-left` | `text-start` | text-align: left | text-align: right |
| `text-right` | `text-end` | text-align: right | text-align: left |
| `float-left` | `float-start` | float: left | float: right |
| `float-right` | `float-end` | float: right | float: left |
| `rounded-l-lg` | `rounded-s-lg` | border-start-radius | |
| `rounded-r-lg` | `rounded-e-lg` | border-end-radius | |
| `border-l-4` | `border-s-4` | border-start | |
| `border-r-4` | `border-e-4` | border-end | |

### Tailwind v3.3+ Built-in RTL Support

Tailwind CSS v3.3+ has built-in `rtl:` and `ltr:` modifiers:

```html
<!-- Use rtl: modifier for direction-specific overrides -->
<div class="flex flex-row rtl:flex-row-reverse">
  <!-- This is rarely needed since flexbox respects direction natively -->
</div>

<!-- Logical properties are preferred; use rtl: for edge cases only -->
<div class="ms-4 ps-3 text-start border-s-4 border-blue-500">
  Automatically adapts to RTL
</div>

<!-- Override only when needed -->
<div class="space-x-4 rtl:space-x-reverse">
  <span>First</span>
  <span>Second</span>
  <span>Third</span>
</div>

<!-- Force LTR for specific content -->
<span class="rtl:direction-ltr">+1 (555) 123-4567</span>
```

### Migration from Physical to Logical Classes

```bash
# Find and replace physical classes with logical equivalents
# Run in your project root:
find src -name "*.tsx" -o -name "*.jsx" | xargs sed -i \
  -e 's/\bml-/ms-/g' \
  -e 's/\bmr-/me-/g' \
  -e 's/\bpl-/ps-/g' \
  -e 's/\bpr-/pe-/g' \
  -e 's/\btext-left\b/text-start/g' \
  -e 's/\btext-right\b/text-end/g'

# WARNING: Review changes manually — some physical classes are intentional
# (e.g., absolute positioning of decorative elements)
```

---

## CSS Specificity with dir Selectors

### Specificity Pitfalls

The `[dir="rtl"]` attribute selector adds specificity. This can cause cascade conflicts.

```css
/* Problem: [dir="rtl"] has higher specificity than a class */
.button {
  padding-left: 16px;       /* specificity: 0,1,0 */
}

[dir="rtl"] .button {
  padding-right: 16px;      /* specificity: 0,1,1 — wins over other .button rules */
  padding-left: 0;
}

/* This override LOSES to the [dir="rtl"] rule above: */
.button.compact {
  padding-left: 8px;        /* specificity: 0,2,0 */
  /* In RTL: [dir] .button's padding-left: 0 has lower specificity (0,1,1),
     so .button.compact's padding-left wins, but you also need RTL handling */
}
```

### Solutions

#### 1. Use Logical Properties (Best)

```css
/* No dir selectors needed — works in both directions */
.button {
  padding-inline-start: 16px;
}

.button.compact {
  padding-inline-start: 8px;
}
```

#### 2. `:dir()` Pseudo-Class (Modern CSS)

```css
/* :dir() doesn't add extra specificity like [dir] does */
.button:dir(rtl) {
  padding-right: 16px;
  padding-left: 0;
}

/* Same specificity as .button — no cascade surprises */
/* Note: :dir() is inherited — child elements match parent direction */
/* Browser support: Chrome 120+, Firefox 49+, Safari 16.4+ */
```

#### 3. CSS Custom Properties for Direction

```css
:root {
  --dir: 1;
}

:root[dir="rtl"] {
  --dir: -1;
}

/* Use for transforms and calculations */
.icon {
  transform: scaleX(var(--dir));              /* auto-mirror */
}

.slider-thumb {
  transform: translateX(calc(var(--offset) * var(--dir)));
}

/* Animation direction */
@keyframes slide-in {
  from { transform: translateX(calc(-100% * var(--dir))); }
  to   { transform: translateX(0); }
}
```

#### 4. Cascade Layers for Direction Styles

```css
/* Use @layer to control specificity */
@layer base, direction, components, utilities;

@layer direction {
  [dir="rtl"] .sidebar {
    /* Direction-specific overrides in their own layer */
    border-inline-end: 1px solid var(--border);
  }
}

@layer components {
  .sidebar {
    /* Component styles always override direction layer regardless of specificity */
    inline-size: 280px;
  }
}
```

### Common Patterns with Minimal Specificity Issues

```css
/* Pattern 1: CSS custom properties for direction-dependent values */
.tooltip {
  --tooltip-offset: 8px;
  inset-inline-start: var(--tooltip-offset);
}

/* Pattern 2: Logical properties with fallbacks for older browsers */
.element {
  margin-left: 16px;                  /* fallback */
  margin-inline-start: 16px;          /* logical — overrides in supporting browsers */
}

/* Pattern 3: @supports for progressive enhancement */
@supports (margin-inline-start: 0) {
  .element {
    margin-left: unset;
    margin-inline-start: 16px;
  }
}
```

### Debugging RTL Issues

```js
// Browser DevTools: Toggle direction on the fly
document.documentElement.dir = document.documentElement.dir === 'rtl' ? 'ltr' : 'rtl';

// Bookmarklet for quick RTL testing
javascript:void(document.documentElement.dir=document.documentElement.dir==='rtl'?'ltr':'rtl')

// Audit all physical properties in computed styles
function auditRTL() {
  const physicalProps = ['margin-left', 'margin-right', 'padding-left', 'padding-right',
    'border-left', 'border-right', 'left', 'right'];
  const elements = document.querySelectorAll('*');
  const violations = [];

  elements.forEach(el => {
    const computed = getComputedStyle(el);
    physicalProps.forEach(prop => {
      const value = computed.getPropertyValue(prop);
      if (value && value !== '0px' && value !== 'auto') {
        violations.push({ element: el, property: prop, value });
      }
    });
  });

  console.table(violations.map(v => ({
    selector: v.element.tagName + (v.element.className ? '.' + v.element.className.split(' ')[0] : ''),
    property: v.property,
    value: v.value,
  })));
}
```
