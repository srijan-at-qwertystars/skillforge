# Tailwind CSS Cheatsheet

## Table of Contents
- [Layout](#layout)
- [Flexbox](#flexbox)
- [Grid](#grid)
- [Spacing](#spacing)
- [Sizing](#sizing)
- [Typography](#typography)
- [Colors & Backgrounds](#colors--backgrounds)
- [Borders](#borders)
- [Shadows & Effects](#shadows--effects)
- [Transitions & Animations](#transitions--animations)
- [Responsive Breakpoints](#responsive-breakpoints)
- [State Variants](#state-variants)
- [Dark Mode](#dark-mode)
- [Arbitrary Values](#arbitrary-values)

---

## Layout

| Utility | CSS |
|---------|-----|
| `block` | `display: block` |
| `inline-block` | `display: inline-block` |
| `inline` | `display: inline` |
| `flex` | `display: flex` |
| `inline-flex` | `display: inline-flex` |
| `grid` | `display: grid` |
| `hidden` | `display: none` |
| `contents` | `display: contents` |

### Position
| Utility | CSS |
|---------|-----|
| `static` | `position: static` |
| `relative` | `position: relative` |
| `absolute` | `position: absolute` |
| `fixed` | `position: fixed` |
| `sticky` | `position: sticky` |

### Inset
| Utility | CSS |
|---------|-----|
| `inset-0` | `inset: 0` |
| `inset-x-0` | `left: 0; right: 0` |
| `inset-y-0` | `top: 0; bottom: 0` |
| `top-0` | `top: 0` |
| `right-0` | `right: 0` |
| `bottom-0` | `bottom: 0` |
| `left-0` | `left: 0` |

### Overflow
| Utility | CSS |
|---------|-----|
| `overflow-auto` | `overflow: auto` |
| `overflow-hidden` | `overflow: hidden` |
| `overflow-visible` | `overflow: visible` |
| `overflow-scroll` | `overflow: scroll` |
| `overflow-x-auto` | `overflow-x: auto` |
| `overflow-y-auto` | `overflow-y: auto` |

### Z-Index
`z-0` `z-10` `z-20` `z-30` `z-40` `z-50` `z-auto`

---

## Flexbox

| Utility | CSS |
|---------|-----|
| `flex-row` | `flex-direction: row` |
| `flex-col` | `flex-direction: column` |
| `flex-row-reverse` | `flex-direction: row-reverse` |
| `flex-col-reverse` | `flex-direction: column-reverse` |
| `flex-wrap` | `flex-wrap: wrap` |
| `flex-nowrap` | `flex-wrap: nowrap` |
| `flex-1` | `flex: 1 1 0%` |
| `flex-auto` | `flex: 1 1 auto` |
| `flex-initial` | `flex: 0 1 auto` |
| `flex-none` | `flex: none` |
| `grow` | `flex-grow: 1` |
| `grow-0` | `flex-grow: 0` |
| `shrink` | `flex-shrink: 1` |
| `shrink-0` | `flex-shrink: 0` |

### Alignment
| Utility | CSS |
|---------|-----|
| `justify-start` | `justify-content: flex-start` |
| `justify-center` | `justify-content: center` |
| `justify-end` | `justify-content: flex-end` |
| `justify-between` | `justify-content: space-between` |
| `justify-around` | `justify-content: space-around` |
| `justify-evenly` | `justify-content: space-evenly` |
| `items-start` | `align-items: flex-start` |
| `items-center` | `align-items: center` |
| `items-end` | `align-items: flex-end` |
| `items-baseline` | `align-items: baseline` |
| `items-stretch` | `align-items: stretch` |
| `self-auto` | `align-self: auto` |
| `self-start` | `align-self: flex-start` |
| `self-center` | `align-self: center` |
| `self-end` | `align-self: flex-end` |

### Gap
`gap-0` `gap-1` (0.25rem) `gap-2` (0.5rem) `gap-3` (0.75rem) `gap-4` (1rem) `gap-5` (1.25rem) `gap-6` (1.5rem) `gap-8` (2rem) `gap-10` (2.5rem) `gap-12` (3rem)

Also: `gap-x-*` and `gap-y-*` for axis-specific gaps.

---

## Grid

| Utility | CSS |
|---------|-----|
| `grid-cols-1` to `grid-cols-12` | `grid-template-columns: repeat(n, minmax(0, 1fr))` |
| `grid-cols-none` | `grid-template-columns: none` |
| `grid-rows-1` to `grid-rows-6` | `grid-template-rows: repeat(n, minmax(0, 1fr))` |
| `col-span-1` to `col-span-12` | `grid-column: span n / span n` |
| `col-span-full` | `grid-column: 1 / -1` |
| `row-span-1` to `row-span-6` | `grid-row: span n / span n` |
| `col-start-1` to `col-start-13` | `grid-column-start: n` |
| `col-end-1` to `col-end-13` | `grid-column-end: n` |

**Auto-fit responsive grid:**
```html
grid grid-cols-[repeat(auto-fill,minmax(250px,1fr))] gap-4
```

---

## Spacing

### Padding
| Utility | CSS |
|---------|-----|
| `p-0` | `padding: 0` |
| `p-1` | `padding: 0.25rem` (4px) |
| `p-2` | `padding: 0.5rem` (8px) |
| `p-3` | `padding: 0.75rem` (12px) |
| `p-4` | `padding: 1rem` (16px) |
| `p-5` | `padding: 1.25rem` (20px) |
| `p-6` | `padding: 1.5rem` (24px) |
| `p-8` | `padding: 2rem` (32px) |
| `p-10` | `padding: 2.5rem` (40px) |
| `p-12` | `padding: 3rem` (48px) |
| `p-16` | `padding: 4rem` (64px) |

Axis/side: `px-*` `py-*` `pt-*` `pr-*` `pb-*` `pl-*` `ps-*` `pe-*`

### Margin
Same scale as padding: `m-0` through `m-16`
Also: `mx-auto` (center), `-m-*` (negative margins)
Axis/side: `mx-*` `my-*` `mt-*` `mr-*` `mb-*` `ml-*` `ms-*` `me-*`

### Space Between
`space-x-*` `space-y-*` — Adds margin between children (not first child).

---

## Sizing

### Width
| Utility | Value |
|---------|-------|
| `w-0` | `0` |
| `w-px` | `1px` |
| `w-1` – `w-96` | `0.25rem` – `24rem` |
| `w-1/2` | `50%` |
| `w-1/3` | `33.333%` |
| `w-2/3` | `66.667%` |
| `w-1/4` | `25%` |
| `w-3/4` | `75%` |
| `w-full` | `100%` |
| `w-screen` | `100vw` |
| `w-fit` | `fit-content` |
| `w-min` | `min-content` |
| `w-max` | `max-content` |
| `w-auto` | `auto` |

### Height
Same pattern: `h-0` through `h-96`, `h-full`, `h-screen`, `h-dvh`, `h-fit`, `h-min`, `h-max`

### Min/Max
`min-w-0` `min-w-full` `max-w-sm` `max-w-md` `max-w-lg` `max-w-xl` `max-w-2xl` `max-w-3xl` `max-w-4xl` `max-w-5xl` `max-w-6xl` `max-w-7xl` `max-w-full` `max-w-none` `max-w-prose`

`min-h-0` `min-h-full` `min-h-screen` `max-h-*`

### Size (width + height)
`size-0` through `size-96`, `size-full`

### Aspect Ratio
`aspect-auto` `aspect-square` `aspect-video`

---

## Typography

### Font Size
| Utility | Size | Line Height |
|---------|------|------------|
| `text-xs` | 0.75rem (12px) | 1rem |
| `text-sm` | 0.875rem (14px) | 1.25rem |
| `text-base` | 1rem (16px) | 1.5rem |
| `text-lg` | 1.125rem (18px) | 1.75rem |
| `text-xl` | 1.25rem (20px) | 1.75rem |
| `text-2xl` | 1.5rem (24px) | 2rem |
| `text-3xl` | 1.875rem (30px) | 2.25rem |
| `text-4xl` | 2.25rem (36px) | 2.5rem |
| `text-5xl` | 3rem (48px) | 1 |
| `text-6xl` | 3.75rem (60px) | 1 |

### Font Weight
`font-thin` (100) `font-extralight` (200) `font-light` (300) `font-normal` (400) `font-medium` (500) `font-semibold` (600) `font-bold` (700) `font-extrabold` (800) `font-black` (900)

### Other Typography
| Category | Utilities |
|----------|-----------|
| Alignment | `text-left` `text-center` `text-right` `text-justify` `text-start` `text-end` |
| Line Height | `leading-none` (1) `leading-tight` (1.25) `leading-snug` (1.375) `leading-normal` (1.5) `leading-relaxed` (1.625) `leading-loose` (2) |
| Letter Spacing | `tracking-tighter` `tracking-tight` `tracking-normal` `tracking-wide` `tracking-wider` `tracking-widest` |
| Transform | `uppercase` `lowercase` `capitalize` `normal-case` |
| Decoration | `underline` `overline` `line-through` `no-underline` |
| Wrapping | `truncate` `text-ellipsis` `text-clip` `whitespace-nowrap` `whitespace-pre` `break-words` `break-all` |
| Clamp | `line-clamp-1` `line-clamp-2` `line-clamp-3` `line-clamp-4` `line-clamp-5` `line-clamp-6` |

---

## Colors & Backgrounds

### Color Scale
All colors: `slate` `gray` `zinc` `neutral` `stone` `red` `orange` `amber` `yellow` `lime` `green` `emerald` `teal` `cyan` `sky` `blue` `indigo` `violet` `purple` `fuchsia` `pink` `rose`

Shades: `50` `100` `200` `300` `400` `500` `600` `700` `800` `900` `950`

**Pattern:** `{property}-{color}-{shade}`
- Text: `text-blue-500`
- Background: `bg-blue-500`
- Border: `border-blue-500`

### Opacity Modifier
Use `/` for opacity: `bg-black/50` `text-blue-600/75` `border-red-500/30`

### Gradients
| Utility | Direction |
|---------|-----------|
| `bg-gradient-to-r` | Left → Right |
| `bg-gradient-to-l` | Right → Left |
| `bg-gradient-to-t` | Bottom → Top |
| `bg-gradient-to-b` | Top → Bottom |
| `bg-gradient-to-br` | Top-left → Bottom-right |
| `bg-gradient-to-tr` | Bottom-left → Top-right |

Stops: `from-blue-500 via-purple-500 to-pink-500`

---

## Borders

| Utility | CSS |
|---------|-----|
| `border` | `border-width: 1px` |
| `border-0` | `border-width: 0` |
| `border-2` | `border-width: 2px` |
| `border-4` | `border-width: 4px` |
| `border-t` `border-r` `border-b` `border-l` | Single side |
| `border-solid` | `border-style: solid` |
| `border-dashed` | `border-style: dashed` |
| `border-dotted` | `border-style: dotted` |
| `border-none` | `border-style: none` |

### Border Radius
| Utility | Value |
|---------|-------|
| `rounded-none` | `0` |
| `rounded-sm` | `0.125rem` |
| `rounded` | `0.25rem` |
| `rounded-md` | `0.375rem` |
| `rounded-lg` | `0.5rem` |
| `rounded-xl` | `0.75rem` |
| `rounded-2xl` | `1rem` |
| `rounded-3xl` | `1.5rem` |
| `rounded-full` | `9999px` |

Corners: `rounded-t-*` `rounded-r-*` `rounded-b-*` `rounded-l-*` `rounded-tl-*` `rounded-tr-*` `rounded-bl-*` `rounded-br-*`

### Rings
`ring-0` `ring-1` `ring-2` `ring-4` `ring-8` `ring-inset`
Color: `ring-blue-500` + opacity `ring-blue-500/50`
Offset: `ring-offset-1` `ring-offset-2` `ring-offset-4`

### Divide
`divide-x` `divide-y` `divide-gray-200` — Adds borders between children.

---

## Shadows & Effects

### Box Shadow
| Utility | Effect |
|---------|--------|
| `shadow-sm` | Subtle shadow |
| `shadow` | Default shadow |
| `shadow-md` | Medium |
| `shadow-lg` | Large |
| `shadow-xl` | Extra large |
| `shadow-2xl` | Highest |
| `shadow-none` | No shadow |
| `shadow-inner` | Inner shadow |

Colored: `shadow-blue-500/20`

### Opacity
`opacity-0` `opacity-5` `opacity-10` `opacity-20` `opacity-25` `opacity-30` `opacity-40` `opacity-50` `opacity-60` `opacity-70` `opacity-75` `opacity-80` `opacity-90` `opacity-95` `opacity-100`

### Backdrop
`backdrop-blur-sm` `backdrop-blur` `backdrop-blur-md` `backdrop-blur-lg`

---

## Transitions & Animations

### Transitions
| Utility | Properties |
|---------|-----------|
| `transition-none` | None |
| `transition-all` | All properties |
| `transition-colors` | Color, background, border, text-decoration, fill, stroke |
| `transition-opacity` | Opacity |
| `transition-shadow` | Box-shadow |
| `transition-transform` | Transform |

**Duration:** `duration-75` `duration-100` `duration-150` `duration-200` `duration-300` `duration-500` `duration-700` `duration-1000`

**Easing:** `ease-linear` `ease-in` `ease-out` `ease-in-out`

### Animations
`animate-spin` `animate-ping` `animate-pulse` `animate-bounce` `animate-none`

### Transforms
`scale-*` `rotate-*` `translate-x-*` `translate-y-*` `skew-x-*` `skew-y-*`
`hover:scale-105` `hover:-translate-y-1`

---

## Responsive Breakpoints

| Prefix | Min-width | Target |
|--------|-----------|--------|
| (none) | 0px | Mobile (default) |
| `sm:` | 640px | Landscape phones |
| `md:` | 768px | Tablets |
| `lg:` | 1024px | Laptops |
| `xl:` | 1280px | Desktops |
| `2xl:` | 1536px | Large screens |

**Usage:** Mobile-first. Unprefixed = all sizes. Prefix = that breakpoint and up.
```html
class="text-sm md:text-base lg:text-lg"
class="grid-cols-1 sm:grid-cols-2 lg:grid-cols-3"
class="hidden md:block"
class="block md:hidden"
```

### Container Queries (v4)
| Prefix | Min-width |
|--------|-----------|
| `@xs:` | 320px |
| `@sm:` | 384px |
| `@md:` | 448px |
| `@lg:` | 512px |
| `@xl:` | 576px |

Wrap parent with `@container`, use `@sm:` etc. on children.

---

## State Variants

| Variant | When Applied |
|---------|-------------|
| `hover:` | Mouse hover |
| `focus:` | Element focused |
| `focus-visible:` | Keyboard focus |
| `focus-within:` | Any child focused |
| `active:` | Being clicked |
| `disabled:` | Disabled attribute |
| `first:` | First child |
| `last:` | Last child |
| `odd:` | Odd children |
| `even:` | Even children |
| `group-hover:` | Parent `.group` hovered |
| `peer-checked:` | Sibling `.peer` checked |
| `placeholder:` | Placeholder text |
| `before:` | ::before pseudo |
| `after:` | ::after pseudo |
| `file:` | File input button |
| `motion-safe:` | Prefers motion |
| `motion-reduce:` | Prefers reduced motion |
| `print:` | Print media |
| `rtl:` / `ltr:` | Direction |

**Stacking:** `md:dark:hover:bg-gray-700`

---

## Dark Mode

```html
class="bg-white dark:bg-gray-900 text-gray-900 dark:text-white"
```

v4 default: `prefers-color-scheme`. For class strategy:
```css
@custom-variant dark (&:where(.dark, .dark *));
```

---

## Arbitrary Values

| Pattern | Example |
|---------|---------|
| One-off value | `w-[350px]` `mt-[17px]` `bg-[#1da1f2]` |
| CSS function | `w-[calc(100%-2rem)]` `text-[clamp(1rem,2vw,2rem)]` |
| CSS variable | `bg-[var(--brand)]` `text-[var(--heading-size)]` |
| Arbitrary property | `[mask-type:luminance]` |
| Arbitrary grid | `grid-cols-[1fr_2fr_1fr]` |
