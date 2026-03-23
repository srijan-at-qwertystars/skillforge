---
name: css-grid-flexbox
description:
  positive: "Use when user builds layouts with CSS Grid or Flexbox, asks about grid-template, flex properties, responsive layouts, subgrid, container queries, or common layout patterns (holy grail, sidebar, card grid, sticky footer)."
  negative: "Do NOT use for CSS animations, color/typography, CSS-in-JS libraries, or Tailwind utility classes unless layout-specific."
---

# CSS Grid & Flexbox Layout

## Grid vs Flexbox Decision Guide

Use **Flexbox** for one-dimensional flow (row OR column): navbars, toolbars, button groups, centering single items, card internals.

Use **Grid** for two-dimensional structure (rows AND columns): page shells, dashboards, galleries, any layout needing alignment on both axes.

Combine both: Grid for macro layout (page regions), Flexbox for micro layout (content inside grid cells).

| Scenario | Use |
|---|---|
| Nav bar, toolbar | Flexbox |
| Card internal layout | Flexbox |
| Full page structure | Grid |
| Image gallery | Grid |
| Centering one element | Flexbox or Grid |
| Aligned card grid | Grid + Flexbox inside cards |
| Nested alignment across siblings | Grid + Subgrid |

---

## Flexbox

### Core Properties (Container)

```css
.flex-container {
  display: flex;
  flex-direction: row;            /* row | row-reverse | column | column-reverse */
  flex-wrap: wrap;                /* nowrap | wrap | wrap-reverse */
  justify-content: space-between; /* flex-start | flex-end | center | space-around | space-evenly */
  align-items: stretch;           /* flex-start | flex-end | center | baseline | stretch */
  align-content: flex-start;     /* controls multi-line cross-axis (only with wrap) */
  gap: 16px;                     /* row-gap column-gap shorthand */
}
```

### Core Properties (Item)

```css
.flex-item {
  flex-grow: 1;     /* proportion of remaining space to absorb */
  flex-shrink: 1;   /* proportion of overflow to surrender */
  flex-basis: 200px; /* initial main-axis size before grow/shrink */
  flex: 1 1 200px;  /* shorthand: grow shrink basis */
  order: 2;         /* visual reorder without changing DOM */
  align-self: center; /* override container's align-items for this item */
}
```

### Key Flex Shortcuts

- `flex: 1` → `1 1 0%` — grow equally, basis 0
- `flex: auto` → `1 1 auto` — grow equally, basis auto
- `flex: none` → `0 0 auto` — rigid, no grow/shrink

---

## CSS Grid

### Defining Tracks

```css
.grid {
  display: grid;
  grid-template-columns: 200px 1fr 1fr;       /* fixed + fractional */
  grid-template-columns: repeat(3, 1fr);       /* 3 equal columns */
  grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); /* responsive */
  grid-template-rows: auto 1fr auto;           /* header, stretch, footer */
  gap: 24px;
}
```

### fr Units

`fr` distributes remaining space after fixed/min/max tracks are resolved. `1fr 2fr` gives ⅓ and ⅔.

### minmax()

```css
grid-template-columns: minmax(150px, 1fr) 3fr;
/* first column: at least 150px, at most 1fr */
```

### auto-fill vs auto-fit

```css
/* auto-fill: keeps empty tracks, preserving column slots */
grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));

/* auto-fit: collapses empty tracks, items stretch to fill */
grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
```

Use `auto-fit` when items should expand to fill the row. Use `auto-fill` when you want consistent column sizing even with few items.

### Placing Items

```css
.item {
  grid-column: 1 / 3;      /* start line 1, end line 3 */
  grid-column: span 2;     /* span 2 columns from auto-placed position */
  grid-row: 2 / -1;        /* row 2 to last line */
}
```

---

## Grid Areas and Named Lines

```css
.layout {
  display: grid;
  grid-template-areas:
    "header  header  header"
    "sidebar main   aside"
    "footer  footer  footer";
  grid-template-columns: 220px 1fr 200px;
  grid-template-rows: auto 1fr auto;
}
header  { grid-area: header; }
.sidebar { grid-area: sidebar; }
main    { grid-area: main; }
aside   { grid-area: aside; }
footer  { grid-area: footer; }
```

### Named Lines

```css
.grid {
  grid-template-columns: [sidebar-start] 250px [sidebar-end main-start] 1fr [main-end];
}
.item { grid-column: main-start / main-end; }
```

---

## Subgrid

Inherit parent grid tracks in nested grids. Supported in all major browsers (2025+).

```css
.parent {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  grid-template-rows: auto auto auto;
  gap: 1rem;
}
.child {
  grid-column: 1 / -1;             /* span all parent columns */
  display: grid;
  grid-template-columns: subgrid;  /* inherit parent's column tracks */
}
```

### Row Subgrid (align card parts across siblings)

```css
.card-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  grid-auto-rows: auto;
  gap: 1.5rem;
}
.card {
  display: grid;
  grid-row: span 3;                /* header, body, footer */
  grid-template-rows: subgrid;     /* inherit parent row sizing */
}
```

Each card's header, body, and footer align across the row regardless of content length.

Subgrid inherits parent gap. Override with the child's own `gap` if needed.

---

## Container Queries

Make components respond to their container width, not the viewport.

```css
.card-wrapper {
  container-type: inline-size;     /* opt in to container queries */
  container-name: card;            /* optional name */
  /* shorthand: container: card / inline-size; */
}

@container card (width > 400px) {
  .card {
    grid-template-columns: 1fr 2fr;
  }
}

@container card (width <= 400px) {
  .card {
    grid-template-columns: 1fr;
  }
}
```

### Container Query Units

```css
.component {
  font-size: clamp(0.875rem, 2cqi, 1.25rem); /* scale relative to container inline size */
  padding: 2cqi;
}
/* cqw/cqh = container width/height, cqi/cqb = container inline/block */
```

Use container queries for reusable components in design systems. Apply `container-type` only where needed to avoid unnecessary layout overhead.

---

## Common Layout Recipes

### Holy Grail

```css
.holy-grail {
  display: grid;
  grid-template-areas:
    "header header header"
    "nav    main   aside"
    "footer footer footer";
  grid-template-columns: 200px 1fr 200px;
  grid-template-rows: auto 1fr auto;
  min-height: 100dvh;
  gap: 1rem;
}
@media (max-width: 768px) {
  .holy-grail {
    grid-template-areas: "header" "main" "nav" "aside" "footer";
    grid-template-columns: 1fr;
  }
}
```

### Sidebar Layout

```css
.sidebar-layout {
  display: grid;
  grid-template-columns: minmax(200px, 25%) 1fr;
  gap: 1.5rem;
}
@media (max-width: 640px) {
  .sidebar-layout { grid-template-columns: 1fr; }
}
```

### Card Grid (Responsive, No Media Queries)

```css
.card-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 280px), 1fr));
  gap: 1.5rem;
}
```

Wrap `minmax` first argument in `min(100%, 280px)` to prevent overflow on small screens.

### Sticky Footer

```css
body {
  display: grid;
  grid-template-rows: auto 1fr auto;
  min-height: 100dvh;
}
header { /* auto height */ }
main   { /* stretches to fill */ }
footer { /* auto height, always at bottom */ }
```

### Centering (Multiple Methods)

```css
/* Grid centering */
.center-grid {
  display: grid;
  place-items: center;
  min-height: 100dvh;
}

/* Flexbox centering */
.center-flex {
  display: flex;
  justify-content: center;
  align-items: center;
  min-height: 100dvh;
}
```

### Masonry-like (CSS Grid)

```css
/* Experimental native masonry (Firefox, behind flag in others) */
.masonry {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
  grid-template-rows: masonry;
  gap: 1rem;
}

/* Fallback: CSS columns */
.masonry-fallback {
  columns: 3 250px;
  column-gap: 1rem;
}
.masonry-fallback > * {
  break-inside: avoid;
  margin-bottom: 1rem;
}
```

---

## Responsive Patterns

### Fluid Sizing with clamp()

```css
.container {
  padding: clamp(1rem, 3vw, 3rem);
  gap: clamp(0.75rem, 2vw, 2rem);
}
h1 { font-size: clamp(1.5rem, 4vw, 3rem); }
```

### Responsive Grid with Media Queries

```css
.grid { display: grid; grid-template-columns: 1fr; }
@media (min-width: 640px)  { .grid { grid-template-columns: repeat(2, 1fr); } }
@media (min-width: 1024px) { .grid { grid-template-columns: repeat(4, 1fr); } }
```

### Intrinsic Responsive (No Breakpoints)

```css
.auto-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(100%, 300px), 1fr));
  gap: 1rem;
}
```

---

## Alignment Deep-Dive

### Grid/Flex Alignment Properties

| Property | Applies to | Axes |
|---|---|---|
| `justify-content` | Container | Inline (row) |
| `align-content` | Container | Block (column) |
| `place-content` | Container | Shorthand: `align-content justify-content` |
| `justify-items` | Container → all items | Inline |
| `align-items` | Container → all items | Block |
| `place-items` | Container → all items | Shorthand: `align-items justify-items` |
| `justify-self` | Individual item | Inline |
| `align-self` | Individual item | Block |
| `place-self` | Individual item | Shorthand: `align-self justify-self` |

```css
/* Center everything in grid */
.grid { display: grid; place-items: center; }

/* Stretch items horizontally, center vertically */
.grid { display: grid; place-items: center stretch; }

/* Override for one item */
.special { place-self: end start; }
```

---

## Nesting Grid Inside Flex and Vice Versa

### Flex container with Grid children

```css
.toolbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 1rem;
}
.toolbar .button-group {
  display: grid;
  grid-template-columns: repeat(3, auto);
  gap: 0.5rem;
}
```

### Grid container with Flex children

```css
.dashboard {
  display: grid;
  grid-template-columns: 250px 1fr;
  gap: 2rem;
}
.dashboard .stats-card {
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 1rem;
}
```

No restrictions on nesting depth. Keep under 3 levels for maintainability.

---

## Common Pitfalls and Fixes

### 1. Overflow from Long Words / URLs

**Problem:** Flex/grid items overflow their container.

```css
/* Fix: set min-width: 0 on flex/grid items */
.item {
  min-width: 0;       /* allow shrinking below content size */
  overflow-wrap: break-word;
}
```

Grid and flex items default to `min-width: auto`, which prevents shrinking below content size. Override with `min-width: 0`.

### 2. Images Breaking Grid Layout

```css
.grid img {
  max-width: 100%;
  height: auto;
  display: block;
}
```

### 3. Implicit Tracks (Unexpected Rows/Columns)

**Problem:** Items wrap into auto-generated tracks with default sizing.

```css
.grid {
  grid-auto-rows: minmax(100px, auto);   /* control implicit row height */
  grid-auto-columns: 1fr;                /* control implicit column width */
  grid-auto-flow: dense;                 /* fill gaps left by spanning items */
}
```

### 4. flex-basis vs width

Use `flex-basis` for main-axis sizing in flex containers. `width` works but `flex-basis` respects flex-direction and interacts correctly with grow/shrink.

### 5. 1fr Does Not Mean Equal Widths

`1fr` distributes *remaining* space. If content differs, columns may not be equal. Force equal widths:

```css
grid-template-columns: repeat(3, minmax(0, 1fr));
```

### 6. Grid Items Stretching Unexpectedly

Grid items default to `stretch` alignment. Override:

```css
.grid { align-items: start; }
```

### 7. z-index in Grid

Grid items can overlap. Use `z-index` directly on grid items without `position: relative` — grid creates a stacking context.

### 8. 100vh on Mobile

`100vh` excludes mobile browser chrome. Use `100dvh` (dynamic viewport height) instead:

```css
.full-height { min-height: 100dvh; }
```

<!-- tested: pass -->
