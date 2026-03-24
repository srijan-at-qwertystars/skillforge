---
name: accessibility-patterns
description: >
  Web accessibility (a11y) patterns for WCAG 2.2 compliant UI development. Use when building
  accessible components, adding ARIA attributes, fixing a11y audit failures, implementing keyboard
  navigation, managing focus in modals/dialogs, writing accessible forms, handling dynamic content
  announcements, creating data tables, adding skip links, or reviewing components for screen reader
  compatibility. Also use when asked about color contrast ratios, alt text, semantic HTML, landmark
  regions, live regions, focus trapping, or accessible React patterns with React Aria or Radix UI.
  Do NOT use for backend API design, database queries, DevOps/CI configuration, native mobile
  development (iOS/Android), PDF accessibility remediation, or general CSS styling unrelated to
  accessibility. Do NOT use for SEO-only concerns or performance optimization without a11y context.
---

# Web Accessibility Patterns

## WCAG 2.2 Conformance Levels

**Level A (Minimum):** Text alternatives for non-text content (1.1.1). Captions for prerecorded media (1.2.1–1.2.3). No color-only meaning (1.4.1). Keyboard operable, no traps (2.1.1–2.1.2). Skip navigation (2.4.1). Descriptive page titles (2.4.2). Determinable link purpose (2.4.4). Page language declared (3.1.1). No context changes on focus/input (3.2.1–3.2.2). Error identification in text (3.3.1). Input labels/instructions (3.3.2). Consistent help placement (3.2.6) [NEW 2.2]. No redundant entry (3.3.7) [NEW 2.2].

**Level AA (Standard Target):** Contrast ≥ 4.5:1 normal text, ≥ 3:1 large text (1.4.3). Text resizable to 200% (1.4.4). Non-text contrast ≥ 3:1 (1.4.11). Reflow at 320px (1.4.10). Text spacing overridable (1.4.12). Multiple nav methods (2.4.5). Descriptive headings/labels (2.4.6). Visible focus indicator (2.4.7). Focus not obscured by sticky elements (2.4.11) [NEW 2.2]. Dragging has pointer alternative (2.5.7) [NEW 2.2]. Touch targets ≥ 24×24 CSS px (2.5.8) [NEW 2.2]. Accessible authentication (3.3.8) [NEW 2.2]. Status messages announced via roles (4.1.3).

**Level AAA (Enhanced):** Focus indicator ≥ 3:1 contrast, 2px outline (2.4.13) [NEW 2.2]. Focused element fully visible (2.4.12) [NEW 2.2]. Enhanced contrast ≥ 7:1 normal, ≥ 4.5:1 large (1.4.6).

## Semantic HTML

Use native elements—they provide built-in roles, keyboard behavior, and focus management.
```html
<!-- WRONG --> <div class="btn" onclick="go()">Click</div>
<!-- RIGHT --> <button type="button" onclick="go()">Click</button>
```

**Heading hierarchy:** One `<h1>` per page. Never skip levels (h1→h2→h3, not h1→h3). Do not use headings for visual styling.

### Landmark Elements
| Element     | Role          | Usage                         |
|-------------|---------------|-------------------------------|
| `<header>`  | banner        | Site-wide header (top-level)  |
| `<nav>`     | navigation    | Navigation blocks             |
| `<main>`    | main          | Primary content (one per page)|
| `<aside>`   | complementary | Sidebar/related content       |
| `<footer>`  | contentinfo   | Site-wide footer (top-level)  |
| `<section>` | region        | Only when given aria-label    |
| `<form>`    | form          | Only when given aria-label    |

Label duplicate landmarks: `<nav aria-label="Main">`, `<nav aria-label="Footer">`.

## ARIA

### Five Rules
1. Use native HTML instead of ARIA whenever possible.
2. Do not change native semantics unless absolutely necessary.
3. All interactive ARIA controls must be keyboard operable.
4. Never use `role="presentation"` or `aria-hidden="true"` on focusable elements.
5. All interactive elements must have an accessible name.

### Roles
- **Widget**: `button`, `checkbox`, `dialog`, `menu`, `menuitem`, `tab`, `tabpanel`, `switch`, `slider`, `combobox`, `listbox`, `option`, `tree`, `treeitem`
- **Landmark**: `banner`, `navigation`, `main`, `complementary`, `contentinfo`, `search`, `form`, `region`
- **Live region**: `alert`, `status`, `log`, `timer`, `marquee`
- **Structure**: `heading`, `list`, `listitem`, `table`, `row`, `cell`, `columnheader`, `rowheader`

### Key States and Properties
```
aria-expanded="true|false"      — collapsible sections, menus
aria-selected="true|false"      — tabs, listbox options
aria-checked="true|false|mixed" — checkboxes, switches
aria-pressed="true|false"       — toggle buttons
aria-disabled="true"            — non-interactive state (keep focusable)
aria-hidden="true"              — hide from AT (NEVER on focusable elements)
aria-current="page|step|true"   — current item in navigation/breadcrumbs
aria-invalid="true"             — form validation errors
aria-required="true"            — required fields (prefer HTML required)
aria-busy="true"                — content loading/updating
```

### Naming
```html
<!-- aria-label: no visible label exists -->
<button aria-label="Close dialog">×</button>
<!-- aria-labelledby: references visible text (preferred when text exists) -->
<h2 id="dlg-title">Confirm Delete</h2>
<div role="dialog" aria-labelledby="dlg-title">...</div>
<!-- aria-describedby: supplemental description -->
<input id="email" aria-describedby="email-hint" />
<p id="email-hint">We'll never share your email.</p>
```

## Keyboard Navigation

### Focus Management
- All interactive elements reachable via Tab. Use `tabindex="0"` for custom elements.
- `tabindex="-1"` for programmatic focus only. Never use `tabindex` > 0.
- Visible focus indicator is mandatory (WCAG 2.4.7).

### Focus Indicator
```css
:focus-visible { outline: 2px solid #005fcc; outline-offset: 2px; }
:focus:not(:focus-visible) { outline: none; } /* only with custom indicator */
```

### Skip Link
```html
<a href="#main-content" class="skip-link">Skip to main content</a>
<!-- ... site header ... -->
<main id="main-content" tabindex="-1">...</main>
```
```css
.skip-link { position: absolute; left: -9999px; z-index: 999; }
.skip-link:focus { position: fixed; top: 0; left: 0; background: #fff; padding: 8px 16px; }
```

### Roving tabindex (Tabs, Toolbars)
```jsx
function TabList({ tabs, activeIndex, onSelect }) {
  const refs = tabs.map(() => useRef(null));
  const handleKeyDown = (e, i) => {
    let next = i;
    if (e.key === 'ArrowRight') next = (i + 1) % tabs.length;
    if (e.key === 'ArrowLeft') next = (i - 1 + tabs.length) % tabs.length;
    if (e.key === 'Home') next = 0;
    if (e.key === 'End') next = tabs.length - 1;
    if (next !== i) { e.preventDefault(); onSelect(next); refs[next].current.focus(); }
  };
  return (
    <div role="tablist">
      {tabs.map((tab, i) => (
        <button key={tab.id} ref={refs[i]} role="tab" id={`tab-${tab.id}`}
          aria-selected={i === activeIndex} aria-controls={`panel-${tab.id}`}
          tabIndex={i === activeIndex ? 0 : -1}
          onClick={() => onSelect(i)} onKeyDown={(e) => handleKeyDown(e, i)}>
          {tab.label}
        </button>
      ))}
    </div>
  );
}
```

## Color and Contrast

| Category | AA Ratio | AAA Ratio |
|----------|----------|-----------|
| Normal text (< 18pt / < 14pt bold) | 4.5:1 | 7:1 |
| Large text (≥ 18pt / ≥ 14pt bold) | 3:1 | 4.5:1 |
| UI components & graphics | 3:1 | — |

Never rely on color alone—pair with icons, text, or patterns.
```html
<!-- WRONG --> <span style="color:red">Error occurred</span>
<!-- RIGHT --> <span style="color:red">⚠ Error: Email is required</span>
```

### Dark Mode
```css
@media (prefers-color-scheme: dark) {
  :root { --bg: #1a1a2e; --text: #e0e0e0; --link: #6eb5ff; --focus: #ffd700; }
}
```
Verify contrast in both themes. Test with `forced-colors` / high-contrast mode.

**Tools:** Chrome DevTools Accessibility pane, axe DevTools extension, WebAIM Contrast Checker, Stark (Figma).

## Screen Reader Support

### Alt Text
```html
<img src="chart.png" alt="Sales increased 40% from Q1 to Q3 2024" />  <!-- informative -->
<img src="divider.png" alt="" />  <!-- decorative -->
<figure>  <!-- complex image -->
  <img src="flow.png" alt="Registration flow" aria-describedby="flow-desc" />
  <figcaption id="flow-desc">Step 1: Enter email. Step 2: Verify. Step 3: Set password.</figcaption>
</figure>
```

### Visually Hidden Text
```css
.sr-only {
  position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
  overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0;
}
```
```html
<button><svg aria-hidden="true"><!-- icon --></svg><span class="sr-only">Delete item</span></button>
```

## Accessible Forms

```html
<label for="user-email">Email address</label>
<input id="user-email" type="email" required aria-describedby="email-err" />
<p id="email-err" role="alert" hidden>Enter a valid email address.</p>

<fieldset>
  <legend>Notification preferences</legend>
  <label><input type="checkbox" name="notify" value="email" /> Email</label>
  <label><input type="checkbox" name="notify" value="sms" /> SMS</label>
</fieldset>
```

### Error Handling Pattern (React)
```jsx
function FormField({ label, id, error, ...props }) {
  const errId = `${id}-error`;
  return (
    <div>
      <label htmlFor={id}>{label}</label>
      <input id={id} aria-invalid={!!error} aria-describedby={error ? errId : undefined}
        aria-required={props.required} {...props} />
      {error && <p id={errId} role="alert">{error}</p>}
    </div>
  );
}
```

### Error Summary
```html
<div role="alert" aria-live="assertive" tabindex="-1" id="error-summary">
  <h2>Please fix the following errors:</h2>
  <ul>
    <li><a href="#user-email">Email is required</a></li>
    <li><a href="#user-pass">Password must be 8+ characters</a></li>
  </ul>
</div>
```
Focus the error summary after failed submission. Links jump to each field.

## Dynamic Content and Live Regions

```html
<div aria-live="polite" aria-atomic="true">3 results found</div>  <!-- polite: after current speech -->
<div role="alert">Session expiring in 60 seconds</div>             <!-- assertive: interrupts -->
<div role="status">File uploaded successfully</div>                 <!-- status: polite by default -->
```

**Rules:** Mount live region container *before* injecting content. Use `aria-atomic="true"` to re-read entire region. Use `aria-relevant="additions removals"` for dynamic lists. Reserve `role="alert"` for critical messages only.

### Loading States
```jsx
function DataLoader({ isLoading, data }) {
  return (
    <>
      <div aria-live="polite" aria-busy={isLoading}>
        {isLoading ? <p>Loading…</p> : <ResultsList data={data} />}
      </div>
      <div role="status" className="sr-only">
        {isLoading ? 'Loading' : `${data.length} results loaded`}
      </div>
    </>
  );
}
```

## Modals and Dialogs

### Native `<dialog>` (Preferred)
```html
<dialog id="confirm-dialog">
  <h2>Confirm action</h2>
  <p>Are you sure?</p>
  <button onclick="this.closest('dialog').close('confirm')">Yes</button>
  <button onclick="this.closest('dialog').close('cancel')">Cancel</button>
</dialog>
```
`showModal()` handles focus trapping, backdrop, Escape key, and `inert` on background automatically.

### Custom Modal (React)
```jsx
function Modal({ isOpen, onClose, title, children }) {
  const ref = useRef(null);
  const prev = useRef(null);
  useEffect(() => {
    if (isOpen) { prev.current = document.activeElement; ref.current?.focus(); }
    return () => prev.current?.focus();
  }, [isOpen]);
  if (!isOpen) return null;
  return (
    <div className="backdrop" onClick={onClose}>
      <div ref={ref} role="dialog" aria-modal="true" aria-labelledby="modal-title"
        tabIndex={-1} onClick={e => e.stopPropagation()}
        onKeyDown={e => { if (e.key === 'Escape') onClose(); }}>
        <h2 id="modal-title">{title}</h2>
        {children}
        <button onClick={onClose}>Close</button>
      </div>
    </div>
  );
}
```

### Focus Trapping
```js
function trapFocus(container) {
  const sel = 'a[href],button:not([disabled]),input:not([disabled]),select,textarea,[tabindex]:not([tabindex="-1"])';
  const els = container.querySelectorAll(sel);
  const first = els[0], last = els[els.length - 1];
  container.addEventListener('keydown', (e) => {
    if (e.key !== 'Tab') return;
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });
}
```

### The `inert` Attribute
```js
document.querySelector('main').inert = true;   // modal opens: block background
document.querySelector('main').inert = false;  // modal closes: restore
```

## Accessible Tables

```html
<table>
  <caption>Q3 2024 Sales by Region</caption>
  <thead>
    <tr><th scope="col">Region</th><th scope="col">Revenue</th><th scope="col">Growth</th></tr>
  </thead>
  <tbody>
    <tr><th scope="row">North America</th><td>$2.4M</td><td>+12%</td></tr>
  </tbody>
</table>
```

**Complex tables** (multi-level headers): Use `headers` attribute with `id` refs.
```html
<th id="mon" scope="col">Monday</th>
<th id="am" scope="row">Morning</th>
<td headers="mon am">Alice</td>
```

## Media Accessibility

```html
<video controls>
  <source src="demo.mp4" type="video/mp4" />
  <track kind="captions" src="captions-en.vtt" srclang="en" label="English" default />
  <track kind="descriptions" src="desc-en.vtt" srclang="en" label="Audio descriptions" />
</video>
```
Always provide a transcript link for audio/video content.

### Reduced Motion
```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important; animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important; scroll-behavior: auto !important;
  }
}
```
```jsx
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
```

## Testing

### Automated (catches ~30-50% of issues)
```js
import AxeBuilder from '@axe-core/playwright';
import { test, expect } from '@playwright/test';
test('no a11y violations', async ({ page }) => {
  await page.goto('/dashboard');
  const r = await new AxeBuilder({ page }).withTags(['wcag2a','wcag2aa','wcag22aa']).analyze();
  expect(r.violations).toEqual([]);
});
// Scoped: await new AxeBuilder({ page }).include('#modal-root').analyze();
```

### Manual Checklist
1. Tab through entire page—every interactive element reachable and visible.
2. Activate controls with Enter and Space.
3. Escape closes modals/popups and returns focus.
4. Screen reader (NVDA/VoiceOver) reads content logically.
5. Zoom to 200%—no clipping or overlap.
6. Test with `prefers-reduced-motion` and `forced-colors` active.

### CI: Run `npx playwright test --project=a11y` on every PR. Fail build on violations.
### Lighthouse: `npx lighthouse URL --only-categories=accessibility --output=json`

## React Patterns

### React Aria (Adobe)
```jsx
import { useButton } from 'react-aria';
function AccessibleButton({ onPress, children }) {
  const ref = useRef(null);
  const { buttonProps } = useButton({ onPress }, ref);
  return <button {...buttonProps} ref={ref}>{children}</button>;
}
```
Handles ARIA attributes, keyboard events, focus management, and cross-browser quirks.

### Radix UI Primitives
```jsx
import * as Dialog from '@radix-ui/react-dialog';
function AccessibleDialog({ trigger, title, children }) {
  return (
    <Dialog.Root>
      <Dialog.Trigger asChild>{trigger}</Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="dialog-overlay" />
        <Dialog.Content aria-describedby={undefined}>
          <Dialog.Title>{title}</Dialog.Title>
          {children}
          <Dialog.Close asChild><button>Close</button></Dialog.Close>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
```

### Route Change Announcements (SPA)
```jsx
function RouteAnnouncer() {
  const location = useLocation();
  const [msg, setMsg] = useState('');
  useEffect(() => { setMsg(`Navigated to ${document.title}`); }, [location]);
  return <div role="status" aria-live="polite" className="sr-only">{msg}</div>;
}
```

### Accessible Dropdown Menu
```jsx
import * as DropdownMenu from '@radix-ui/react-dropdown-menu';
function UserMenu() {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button aria-label="User menu">☰</button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Content>
        <DropdownMenu.Item onSelect={() => navigate('/profile')}>Profile</DropdownMenu.Item>
        <DropdownMenu.Item onSelect={() => navigate('/settings')}>Settings</DropdownMenu.Item>
        <DropdownMenu.Separator />
        <DropdownMenu.Item onSelect={logout}>Sign out</DropdownMenu.Item>
      </DropdownMenu.Content>
    </DropdownMenu.Root>
  );
}
```

## Quick Reference: Semantic Element Choices

| Instead of… | Use… | Why |
|---|---|---|
| `<div onclick>` | `<button>` | Keyboard + role + focus free |
| `<span class="link">` | `<a href>` | Navigable, right-click, focus |
| `<div class="input">` | `<input>` / `<select>` | Form participation, labels |
| `<b>` for headings | `<h2>`–`<h6>` | Document structure for AT |
| `<div class="list">` | `<ul>` / `<ol>` | "List of N items" announced |
| `<div class="table">` | `<table>` | Row/column navigation in AT |

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `<div>` with click handler | Use `<button>` |
| Missing `alt` on `<img>` | Descriptive `alt` or `alt=""` for decorative |
| Color-only indicators | Add icon + text alongside color |
| Autoplaying media with sound | `muted` attribute or provide pause control |
| `outline: none` without replacement | `:focus-visible` with custom outline |
| Missing form labels | `<label for="">` or `aria-label` |
| Skipped heading levels | Maintain h1→h2→h3 hierarchy |
| Mouse-only interactions | Add keyboard + touch equivalents |
| `aria-hidden` on focusable element | Remove aria-hidden or remove from tab order |
| No skip link | First focusable element skips to main |
| Modal doesn't trap focus | `<dialog>`, `inert`, or manual focus trap |
| Live region populated on mount | Mount empty container, then update |
| `tabindex` > 0 | Use 0 or -1 only; rely on DOM order |
| Placeholder as only label | Always provide visible `<label>` |
