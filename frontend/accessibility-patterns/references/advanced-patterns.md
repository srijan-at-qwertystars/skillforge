# Advanced Accessibility Patterns

Dense reference for complex accessible widget implementations. All patterns follow WAI-ARIA Authoring Practices 1.2+ and WCAG 2.2 AA.

## Table of Contents

- [Combobox](#combobox)
- [Tree View](#tree-view)
- [Data Grid](#data-grid)
- [Tabs (Advanced)](#tabs-advanced)
- [Accordion](#accordion)
- [Drag and Drop](#drag-and-drop)
- [Virtual Scrolling](#virtual-scrolling)
- [SPA Route Announcements](#spa-route-announcements)
- [Toast / Notification](#toast--notification)
- [Tooltip Patterns](#tooltip-patterns)
- [Disclosure Widget](#disclosure-widget)
- [Mega Menu](#mega-menu)
- [Accessible Charts & Data Visualization](#accessible-charts--data-visualization)

---

## Combobox

A combobox combines a text input with a popup listbox. It is one of the most complex ARIA patterns.

### Roles & Attributes

```html
<label for="city-input">City</label>
<div class="combobox-wrapper">
  <input
    id="city-input"
    role="combobox"
    aria-expanded="false"
    aria-autocomplete="list"
    aria-controls="city-listbox"
    aria-activedescendant=""
    autocomplete="off"
  />
  <ul id="city-listbox" role="listbox" aria-label="Cities" hidden>
    <li id="city-1" role="option" aria-selected="false">New York</li>
    <li id="city-2" role="option" aria-selected="false">Los Angeles</li>
    <li id="city-3" role="option" aria-selected="false">Chicago</li>
  </ul>
</div>
```

### Keyboard Interactions

| Key | Behavior |
|-----|----------|
| `↓` | Open listbox (if closed), move to next option |
| `↑` | Move to previous option |
| `Enter` | Select current option, close listbox |
| `Escape` | Close listbox, clear input or restore previous value |
| `Home` / `End` | Move to first/last option |
| Type characters | Filter options, update `aria-activedescendant` |

### React Implementation

```tsx
import { useCombobox } from 'downshift';

function CityCombobox({ cities }: { cities: string[] }) {
  const [items, setItems] = useState(cities);
  const {
    isOpen, getMenuProps, getInputProps, getItemProps,
    highlightedIndex, selectedItem,
  } = useCombobox({
    items,
    onInputValueChange: ({ inputValue }) => {
      setItems(cities.filter(c =>
        c.toLowerCase().includes((inputValue ?? '').toLowerCase())
      ));
    },
  });

  return (
    <div>
      <label htmlFor="city-combo">City</label>
      <input {...getInputProps({ id: 'city-combo' })} />
      <ul {...getMenuProps()} role="listbox">
        {isOpen && items.map((item, index) => (
          <li
            key={item}
            {...getItemProps({ item, index })}
            style={{
              background: highlightedIndex === index ? '#e0e7ff' : 'transparent',
              fontWeight: selectedItem === item ? 'bold' : 'normal',
            }}
          >
            {item}
          </li>
        ))}
      </ul>
    </div>
  );
}
```

### Multi-Select Combobox

Add `aria-multiselectable="true"` to the listbox. Toggle `aria-selected` on options. Display selected items as removable chips above the input. Each chip needs a remove button with `aria-label="Remove {item}"`.

```tsx
function SelectedChips({ items, onRemove }: { items: string[]; onRemove: (item: string) => void }) {
  return (
    <ul aria-label="Selected cities" role="list">
      {items.map(item => (
        <li key={item}>
          {item}
          <button
            aria-label={`Remove ${item}`}
            onClick={() => onRemove(item)}
            type="button"
          >
            ×
          </button>
        </li>
      ))}
    </ul>
  );
}
```

### Common Mistakes

- Not updating `aria-activedescendant` as user arrows through options
- Forgetting `aria-expanded` toggle on open/close
- Missing `aria-autocomplete` attribute
- Not announcing result count changes to screen readers

---

## Tree View

Hierarchical list with expandable/collapsible nodes.

### Roles & Structure

```html
<ul role="tree" aria-label="File explorer">
  <li role="treeitem" aria-expanded="true" aria-level="1" aria-setsize="3" aria-posinset="1">
    <span>src/</span>
    <ul role="group">
      <li role="treeitem" aria-level="2" aria-setsize="2" aria-posinset="1">
        <span>index.ts</span>
      </li>
      <li role="treeitem" aria-expanded="false" aria-level="2" aria-setsize="2" aria-posinset="2">
        <span>components/</span>
        <ul role="group" hidden>
          <li role="treeitem" aria-level="3" aria-setsize="1" aria-posinset="1">
            <span>Button.tsx</span>
          </li>
        </ul>
      </li>
    </ul>
  </li>
</ul>
```

### Keyboard Interactions

| Key | Behavior |
|-----|----------|
| `↓` | Next visible treeitem |
| `↑` | Previous visible treeitem |
| `→` | Expand (if collapsed), or move to first child |
| `←` | Collapse (if expanded), or move to parent |
| `Home` | First treeitem |
| `End` | Last visible treeitem |
| `Enter` | Activate/select item |
| `*` | Expand all siblings at current level |
| Type-ahead | Focus matching item |

### React Pattern with Roving Tabindex

```tsx
interface TreeNode {
  id: string;
  label: string;
  children?: TreeNode[];
}

function TreeItem({ node, level, onSelect }: {
  node: TreeNode;
  level: number;
  onSelect: (id: string) => void;
}) {
  const [expanded, setExpanded] = useState(false);
  const hasChildren = node.children && node.children.length > 0;

  const handleKeyDown = (e: React.KeyboardEvent) => {
    switch (e.key) {
      case 'ArrowRight':
        if (hasChildren && !expanded) { setExpanded(true); e.preventDefault(); }
        break;
      case 'ArrowLeft':
        if (hasChildren && expanded) { setExpanded(false); e.preventDefault(); }
        break;
      case 'Enter':
      case ' ':
        onSelect(node.id);
        e.preventDefault();
        break;
    }
  };

  return (
    <li
      role="treeitem"
      aria-expanded={hasChildren ? expanded : undefined}
      aria-level={level}
      tabIndex={-1}
      onKeyDown={handleKeyDown}
    >
      <span onClick={() => hasChildren ? setExpanded(!expanded) : onSelect(node.id)}>
        {hasChildren && (expanded ? '▾ ' : '▸ ')}
        {node.label}
      </span>
      {hasChildren && expanded && (
        <ul role="group">
          {node.children!.map(child => (
            <TreeItem key={child.id} node={child} level={level + 1} onSelect={onSelect} />
          ))}
        </ul>
      )}
    </li>
  );
}
```

### Selection Modes

- **Single select**: `aria-selected="true"` on one treeitem.
- **Multi-select**: Add `aria-multiselectable="true"` on the tree. Space toggles `aria-selected`. Ctrl+A selects all visible. Shift+↓/↑ extends selection.

---

## Data Grid

Interactive tabular data with cell-level keyboard navigation. Not to be confused with a static `<table>`.

### Roles & Structure

```html
<div role="grid" aria-label="Employee directory" aria-rowcount="150">
  <div role="rowgroup">
    <div role="row" aria-rowindex="1">
      <div role="columnheader" aria-sort="ascending" aria-colindex="1">Name</div>
      <div role="columnheader" aria-colindex="2">Department</div>
      <div role="columnheader" aria-colindex="3">Actions</div>
    </div>
  </div>
  <div role="rowgroup">
    <div role="row" aria-rowindex="2">
      <div role="gridcell" aria-colindex="1">Jane Doe</div>
      <div role="gridcell" aria-colindex="2">Engineering</div>
      <div role="gridcell" aria-colindex="3">
        <button tabindex="-1">Edit</button>
      </div>
    </div>
  </div>
</div>
```

### Keyboard Navigation

| Key | Behavior |
|-----|----------|
| `→` / `←` | Move between cells in a row |
| `↓` / `↑` | Move between rows |
| `Home` / `End` | First/last cell in row |
| `Ctrl+Home` / `Ctrl+End` | First/last cell in grid |
| `Page Down` / `Page Up` | Scroll by visible page |
| `Enter` | Enter edit mode / activate cell widget |
| `Escape` | Exit edit mode |
| `Tab` | Move to next interactive element within cell, then exit grid |

### Focus Model

Use a **roving tabindex** on cells. Only one cell has `tabindex="0"` at a time. Interactive content within cells gets `tabindex="-1"` and is activated via Enter on the cell.

```tsx
function useGridNavigation(rows: number, cols: number) {
  const [activeCell, setActiveCell] = useState({ row: 0, col: 0 });

  const handleKeyDown = (e: React.KeyboardEvent) => {
    const { row, col } = activeCell;
    let newRow = row, newCol = col;

    switch (e.key) {
      case 'ArrowRight': newCol = Math.min(col + 1, cols - 1); break;
      case 'ArrowLeft': newCol = Math.max(col - 1, 0); break;
      case 'ArrowDown': newRow = Math.min(row + 1, rows - 1); break;
      case 'ArrowUp': newRow = Math.max(row - 1, 0); break;
      case 'Home':
        newCol = 0;
        if (e.ctrlKey) newRow = 0;
        break;
      case 'End':
        newCol = cols - 1;
        if (e.ctrlKey) newRow = rows - 1;
        break;
      default: return;
    }
    e.preventDefault();
    setActiveCell({ row: newRow, col: newCol });
  };

  return { activeCell, handleKeyDown };
}
```

### Sortable Columns

```html
<div role="columnheader" aria-sort="ascending" tabindex="0">
  Name
  <span aria-hidden="true">▲</span>
</div>
```

Update `aria-sort` to `ascending`, `descending`, or `none`. Announce sort change via live region: `"Sorted by Name, ascending"`.

### Row Selection

```html
<div role="row" aria-selected="true" aria-rowindex="5">...</div>
```

For multi-select grids, add `aria-multiselectable="true"` to the grid element.

---

## Tabs (Advanced)

Beyond basic tabs: lazy loading, vertical orientation, deletable tabs, and overflow handling.

### Automatic vs Manual Activation

**Automatic** (recommended for ≤8 tabs): Panel changes on arrow key focus.

```tsx
const handleKeyDown = (e: React.KeyboardEvent, index: number) => {
  let newIndex = index;
  if (e.key === 'ArrowRight') newIndex = (index + 1) % tabs.length;
  if (e.key === 'ArrowLeft') newIndex = (index - 1 + tabs.length) % tabs.length;
  if (newIndex !== index) {
    e.preventDefault();
    setActiveTab(newIndex); // activates immediately
    tabRefs[newIndex].current?.focus();
  }
};
```

**Manual** (for many tabs or expensive panel loads): Focus moves, but Enter/Space activates.

```tsx
const [focusedTab, setFocusedTab] = useState(0);
const [activeTab, setActiveTab] = useState(0);

const handleKeyDown = (e: React.KeyboardEvent, index: number) => {
  if (e.key === 'ArrowRight') {
    const next = (index + 1) % tabs.length;
    setFocusedTab(next);
    tabRefs[next].current?.focus();
    e.preventDefault();
  }
  if (e.key === 'Enter' || e.key === ' ') {
    setActiveTab(focusedTab);
    e.preventDefault();
  }
};
```

### Vertical Tabs

```html
<div role="tablist" aria-orientation="vertical" aria-label="Settings">
```

Use `↑`/`↓` instead of `←`/`→` for navigation.

### Deletable Tabs

```tsx
<button
  role="tab"
  aria-selected={isActive}
  aria-controls={`panel-${tab.id}`}
>
  {tab.label}
  <span
    role="button"
    aria-label={`Close ${tab.label} tab`}
    onClick={(e) => { e.stopPropagation(); removeTab(tab.id); }}
    onKeyDown={(e) => {
      if (e.key === 'Delete' || e.key === 'Backspace') removeTab(tab.id);
    }}
  >
    ×
  </span>
</button>
```

After deletion, focus the next tab (or previous if last was deleted). Announce: `"{Tab name} tab removed, {N} tabs remaining"`.

### Overflow / Scroll Tabs

When tabs overflow their container, provide scroll buttons:

```tsx
<div role="tablist" aria-label="Content sections">
  <button aria-label="Scroll tabs left" tabIndex={-1} onClick={scrollLeft}>‹</button>
  <div className="tabs-scroll-container" ref={scrollRef}>
    {tabs.map(tab => <Tab key={tab.id} {...tab} />)}
  </div>
  <button aria-label="Scroll tabs right" tabIndex={-1} onClick={scrollRight}>›</button>
</div>
```

Scroll buttons are outside the tab order; arrow keys handle tab navigation within the tablist.

---

## Accordion

### Roles & Structure

```html
<div class="accordion">
  <h3>
    <button
      aria-expanded="false"
      aria-controls="panel-1"
      id="header-1"
    >
      Section 1
    </button>
  </h3>
  <div id="panel-1" role="region" aria-labelledby="header-1" hidden>
    <p>Panel content...</p>
  </div>
</div>
```

### Keyboard

| Key | Behavior |
|-----|----------|
| `Enter` / `Space` | Toggle expanded state |
| `↓` | Next accordion header |
| `↑` | Previous accordion header |
| `Home` | First header |
| `End` | Last header |

### Single vs Multi-Expand

- **Single expand**: Collapse others when one opens. Use `aria-expanded` to track.
- **Multi expand**: Each section independent. No accordion-level state needed.

### Animated Expand/Collapse

```css
.accordion-panel {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows 200ms ease;
}
.accordion-panel[aria-hidden="false"] {
  grid-template-rows: 1fr;
}
.accordion-panel > div {
  overflow: hidden;
}

@media (prefers-reduced-motion: reduce) {
  .accordion-panel { transition: none; }
}
```

---

## Drag and Drop

Drag and drop is inherently mouse-centric. Provide keyboard and screen reader alternatives.

### Alternative Interaction Pattern

Every drag-and-drop must have a keyboard-accessible alternative:

```tsx
function SortableList({ items, onReorder }: { items: Item[]; onReorder: (items: Item[]) => void }) {
  const [grabbedIndex, setGrabbedIndex] = useState<number | null>(null);

  const handleKeyDown = (e: React.KeyboardEvent, index: number) => {
    if (e.key === ' ' || e.key === 'Enter') {
      e.preventDefault();
      if (grabbedIndex === null) {
        setGrabbedIndex(index);
        announce(`Grabbed ${items[index].label}. Use arrow keys to move, Space to drop, Escape to cancel.`);
      } else {
        setGrabbedIndex(null);
        announce(`Dropped ${items[grabbedIndex].label} at position ${index + 1}.`);
      }
    }
    if (grabbedIndex !== null) {
      if (e.key === 'ArrowDown' && grabbedIndex < items.length - 1) {
        e.preventDefault();
        const newItems = [...items];
        [newItems[grabbedIndex], newItems[grabbedIndex + 1]] = [newItems[grabbedIndex + 1], newItems[grabbedIndex]];
        onReorder(newItems);
        setGrabbedIndex(grabbedIndex + 1);
        announce(`Moved ${items[grabbedIndex].label} to position ${grabbedIndex + 2}.`);
      }
      if (e.key === 'ArrowUp' && grabbedIndex > 0) {
        e.preventDefault();
        const newItems = [...items];
        [newItems[grabbedIndex], newItems[grabbedIndex - 1]] = [newItems[grabbedIndex - 1], newItems[grabbedIndex]];
        onReorder(newItems);
        setGrabbedIndex(grabbedIndex - 1);
        announce(`Moved ${items[grabbedIndex].label} to position ${grabbedIndex}.`);
      }
      if (e.key === 'Escape') {
        setGrabbedIndex(null);
        announce('Reorder cancelled.');
      }
    }
  };

  return (
    <>
      <ul role="listbox" aria-label="Sortable list">
        {items.map((item, i) => (
          <li
            key={item.id}
            role="option"
            aria-selected={i === grabbedIndex}
            aria-grabbed={i === grabbedIndex}
            tabIndex={0}
            onKeyDown={(e) => handleKeyDown(e, i)}
            aria-roledescription="sortable item"
            aria-label={`${item.label}, position ${i + 1} of ${items.length}`}
          >
            {item.label}
            {i === grabbedIndex && <span aria-hidden="true"> (grabbed)</span>}
          </li>
        ))}
      </ul>
      <div role="status" aria-live="assertive" className="sr-only" id="dnd-announcer" />
    </>
  );
}

function announce(message: string) {
  const el = document.getElementById('dnd-announcer');
  if (el) el.textContent = message;
}
```

### Required Announcements

1. **On grab**: "Grabbed {item}. Use arrow keys to reorder. Space to drop. Escape to cancel."
2. **On move**: "Moved {item} to position {N} of {total}."
3. **On drop**: "Dropped {item} at position {N}."
4. **On cancel**: "Reorder cancelled. {item} returned to position {N}."

### Libraries

- **@dnd-kit/core**: Best React DnD library for accessibility. Has built-in keyboard sensor and announcements.
- **react-beautiful-dnd**: Built-in keyboard and screen reader support. Archived but stable.

---

## Virtual Scrolling

Rendering only visible items breaks screen reader navigation if not handled carefully.

### Maintaining A11y in Virtualized Lists

```tsx
import { useVirtualizer } from '@tanstack/react-virtual';

function VirtualList({ items }: { items: Item[] }) {
  const parentRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 48,
  });

  return (
    <div
      ref={parentRef}
      role="listbox"
      aria-label={`Items list, ${items.length} items`}
      style={{ height: '400px', overflow: 'auto' }}
      tabIndex={0}
    >
      <div style={{ height: `${virtualizer.getTotalSize()}px`, position: 'relative' }}>
        {virtualizer.getVirtualItems().map(virtualRow => (
          <div
            key={virtualRow.key}
            role="option"
            aria-setsize={items.length}
            aria-posinset={virtualRow.index + 1}
            style={{
              position: 'absolute',
              top: `${virtualRow.start}px`,
              height: `${virtualRow.size}px`,
              width: '100%',
            }}
          >
            {items[virtualRow.index].label}
          </div>
        ))}
      </div>
      <div role="status" aria-live="polite" className="sr-only">
        Showing items {virtualizer.getVirtualItems()[0]?.index + 1} to{' '}
        {virtualizer.getVirtualItems().at(-1)?.index! + 1} of {items.length}
      </div>
    </div>
  );
}
```

### Key Techniques

1. **`aria-setsize` + `aria-posinset`**: Tell AT the full list size and each item's position.
2. **`aria-rowcount` + `aria-rowindex`**: For grids, convey total rows and current row index.
3. **Live region**: Announce current range when scrolling pauses.
4. **Keyboard scrolling**: Ensure arrow keys scroll the container to reveal new items and focus them.
5. **Search**: Provide a search/filter to let users jump without scrolling.

---

## SPA Route Announcements

Single-page apps don't trigger screen reader page-load announcements. You must build this.

### Pattern 1: Route Announcer Component

```tsx
function RouteAnnouncer() {
  const location = useLocation();
  const [announcement, setAnnouncement] = useState('');

  useEffect(() => {
    // Wait for page to render and title to update
    const timer = setTimeout(() => {
      const title = document.title || 'New page';
      setAnnouncement(`Navigated to ${title}`);
    }, 100);
    return () => clearTimeout(timer);
  }, [location.pathname]);

  return (
    <div
      role="status"
      aria-live="assertive"
      aria-atomic="true"
      className="sr-only"
    >
      {announcement}
    </div>
  );
}
```

### Pattern 2: Focus Management on Navigation

```tsx
function PageShell({ title, children }: { title: string; children: React.ReactNode }) {
  const headingRef = useRef<HTMLHeadElement>(null);

  useEffect(() => {
    document.title = title;
    headingRef.current?.focus();
  }, [title]);

  return (
    <main>
      <h1 ref={headingRef} tabIndex={-1}>{title}</h1>
      {children}
    </main>
  );
}
```

### Best Practices

- Focus the `<h1>` on route change (with `tabIndex={-1}`)
- Update `document.title` on every route change
- Use `aria-live="assertive"` for route changes—they're important
- Delay announcement slightly (50–150ms) to allow DOM updates
- Reset scroll position to top

---

## Toast / Notification

### Roles by Urgency

| Urgency | Role | `aria-live` | Use case |
|---------|------|-------------|----------|
| Low | `status` | `polite` | Success, info messages |
| High | `alert` | `assertive` | Errors, warnings |
| Critical | `alertdialog` | — | Requires action (has focus trap) |

### Accessible Toast Component

```tsx
interface Toast {
  id: string;
  message: string;
  type: 'success' | 'error' | 'info' | 'warning';
  duration?: number;
}

function ToastContainer({ toasts, onDismiss }: { toasts: Toast[]; onDismiss: (id: string) => void }) {
  return (
    <div
      aria-label="Notifications"
      role="region"
      className="toast-container"
    >
      {/* Separate live regions for different urgency levels */}
      <div aria-live="polite" aria-atomic="false" role="status">
        {toasts.filter(t => t.type !== 'error').map(toast => (
          <ToastItem key={toast.id} toast={toast} onDismiss={onDismiss} />
        ))}
      </div>
      <div aria-live="assertive" aria-atomic="false" role="alert">
        {toasts.filter(t => t.type === 'error').map(toast => (
          <ToastItem key={toast.id} toast={toast} onDismiss={onDismiss} />
        ))}
      </div>
    </div>
  );
}

function ToastItem({ toast, onDismiss }: { toast: Toast; onDismiss: (id: string) => void }) {
  useEffect(() => {
    if (toast.duration) {
      const timer = setTimeout(() => onDismiss(toast.id), toast.duration);
      return () => clearTimeout(timer);
    }
  }, [toast]);

  return (
    <div className={`toast toast-${toast.type}`} role="group" aria-label={`${toast.type} notification`}>
      <p>{toast.message}</p>
      <button
        aria-label={`Dismiss: ${toast.message}`}
        onClick={() => onDismiss(toast.id)}
      >
        ×
      </button>
    </div>
  );
}
```

### Rules

1. **Auto-dismiss timing**: Minimum 5 seconds. Pause timer on hover/focus.
2. **Error toasts**: Don't auto-dismiss. Require manual dismissal.
3. **Stacking**: Limit to 3 visible toasts. Queue the rest.
4. **Keyboard**: Ensure dismiss button is focusable. Consider `F6` to jump to toast region.
5. **Motion**: Respect `prefers-reduced-motion` for slide/fade animations.

---

## Tooltip Patterns

### Types

1. **Descriptive tooltip** (`role="tooltip"`): Provides additional description.
2. **Label tooltip**: Acts as the accessible name for icon-only buttons.
3. **Rich tooltip / toggletip**: Contains interactive content—use disclosure pattern instead.

### Basic Tooltip

```html
<button aria-describedby="save-tip">
  <svg aria-hidden="true"><!-- save icon --></svg>
  <span class="sr-only">Save</span>
</button>
<div id="save-tip" role="tooltip" hidden>
  Save your changes (Ctrl+S)
</div>
```

### Rules

| Rule | Details |
|------|---------|
| Trigger | Show on hover AND focus |
| Dismiss | Hide on Escape, blur, and mouse leave |
| Delay | 200–400ms hover delay to prevent flicker |
| Persistent | Must remain visible while pointer is over tooltip itself |
| Content | Text only. No interactive elements. |
| Touch | Not reliable on touch—provide alternative |

### React Tooltip

```tsx
function Tooltip({ content, children }: { content: string; children: React.ReactElement }) {
  const [visible, setVisible] = useState(false);
  const id = useId();
  const timeoutRef = useRef<number>();

  const show = () => {
    timeoutRef.current = window.setTimeout(() => setVisible(true), 300);
  };
  const hide = () => {
    clearTimeout(timeoutRef.current);
    setVisible(false);
  };

  useEffect(() => {
    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') hide();
    };
    document.addEventListener('keydown', handleEscape);
    return () => document.removeEventListener('keydown', handleEscape);
  }, []);

  return (
    <>
      {cloneElement(children, {
        'aria-describedby': visible ? id : undefined,
        onMouseEnter: show,
        onMouseLeave: hide,
        onFocus: show,
        onBlur: hide,
      })}
      {visible && (
        <div id={id} role="tooltip" className="tooltip">
          {content}
        </div>
      )}
    </>
  );
}
```

---

## Disclosure Widget

A button that toggles visibility of a section.

### HTML Pattern

```html
<button aria-expanded="false" aria-controls="details-1">
  Show details
</button>
<div id="details-1" hidden>
  <p>Additional details here...</p>
</div>
```

### Native `<details>` / `<summary>`

```html
<details>
  <summary>System requirements</summary>
  <ul>
    <li>Node.js 18+</li>
    <li>npm 9+</li>
  </ul>
</details>
```

Screen readers announce as "disclosure triangle, collapsed/expanded". Keyboard: Enter/Space toggles.

### Animated Disclosure

```tsx
function Disclosure({ label, children }: { label: string; children: React.ReactNode }) {
  const [open, setOpen] = useState(false);
  const contentRef = useRef<HTMLDivElement>(null);
  const id = useId();

  return (
    <div>
      <button
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen(!open)}
      >
        <span aria-hidden="true">{open ? '▾' : '▸'}</span>
        {label}
      </button>
      <div
        id={id}
        role="region"
        aria-labelledby={undefined}
        ref={contentRef}
        hidden={!open}
      >
        {children}
      </div>
    </div>
  );
}
```

---

## Mega Menu

A large dropdown menu with categorized links, often spanning multiple columns.

### Structure

```html
<nav aria-label="Main navigation">
  <ul role="menubar">
    <li role="none">
      <button
        role="menuitem"
        aria-haspopup="true"
        aria-expanded="false"
        aria-controls="mega-products"
      >
        Products
      </button>
      <div id="mega-products" role="menu" hidden>
        <div role="group" aria-label="Development tools">
          <span role="presentation" id="dev-heading">Development</span>
          <ul role="group" aria-labelledby="dev-heading">
            <li role="none">
              <a role="menuitem" href="/ide">IDE</a>
            </li>
            <li role="none">
              <a role="menuitem" href="/cli">CLI Tools</a>
            </li>
          </ul>
        </div>
        <div role="group" aria-label="Collaboration tools">
          <span role="presentation" id="collab-heading">Collaboration</span>
          <ul role="group" aria-labelledby="collab-heading">
            <li role="none">
              <a role="menuitem" href="/chat">Chat</a>
            </li>
          </ul>
        </div>
      </div>
    </li>
  </ul>
</nav>
```

### Keyboard Interactions

| Key | Context | Behavior |
|-----|---------|----------|
| `→` / `←` | Menubar | Move between top-level items |
| `↓` | Menubar item | Open submenu, focus first item |
| `↓` / `↑` | Within mega menu | Move between items |
| `Tab` | Within mega menu | Move to next group |
| `Escape` | Within mega menu | Close menu, focus trigger |
| `Home` / `End` | Within group | First/last item in group |

### Simpler Alternative: Disclosure Navigation

For most sites, a disclosure-based nav is better than `role="menu"`:

```html
<nav aria-label="Main">
  <button aria-expanded="false" aria-controls="products-panel">Products</button>
  <div id="products-panel" hidden>
    <h3>Development</h3>
    <ul>
      <li><a href="/ide">IDE</a></li>
      <li><a href="/cli">CLI Tools</a></li>
    </ul>
  </div>
</nav>
```

This is simpler, more tolerant of implementation errors, and works well with screen readers.

---

## Accessible Charts & Data Visualization

Charts are visual by nature. Making them accessible requires multiple complementary approaches.

### Strategy Stack

1. **Alt text**: Brief description of what the chart shows.
2. **Extended description**: Detailed summary of data and trends.
3. **Data table**: Provide underlying data in an accessible table.
4. **Sonification**: Optional audio representation.
5. **Keyboard navigation**: Navigate data points with arrow keys.

### SVG Chart Pattern

```tsx
function BarChart({ data, title }: { data: { label: string; value: number }[]; title: string }) {
  const max = Math.max(...data.map(d => d.value));
  const descId = useId();
  const tableId = useId();

  return (
    <figure>
      <figcaption id={descId}>{title}</figcaption>
      <svg
        role="img"
        aria-labelledby={descId}
        aria-describedby={tableId}
        viewBox={`0 0 ${data.length * 60} 200`}
      >
        <title>{title}</title>
        <desc>
          Bar chart showing {data.length} items.
          Highest: {data.reduce((a, b) => a.value > b.value ? a : b).label} at {max}.
        </desc>
        {data.map((d, i) => {
          const height = (d.value / max) * 180;
          return (
            <g key={d.label} role="listitem">
              <rect
                x={i * 60 + 10}
                y={200 - height}
                width={40}
                height={height}
                fill="#4f46e5"
                aria-label={`${d.label}: ${d.value}`}
                tabIndex={0}
                role="img"
                onFocus={() => announce(`${d.label}: ${d.value}`)}
              />
              <text x={i * 60 + 30} y={195} textAnchor="middle" fontSize="12">
                {d.label}
              </text>
            </g>
          );
        })}
      </svg>
      {/* Always provide a data table alternative */}
      <details>
        <summary>View data table</summary>
        <table id={tableId}>
          <caption>{title} - Data</caption>
          <thead>
            <tr><th scope="col">Category</th><th scope="col">Value</th></tr>
          </thead>
          <tbody>
            {data.map(d => (
              <tr key={d.label}>
                <th scope="row">{d.label}</th>
                <td>{d.value}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </details>
    </figure>
  );
}
```

### Chart Library Considerations

| Library | A11y Support | Notes |
|---------|-------------|-------|
| Highcharts | Excellent | Built-in screen reader module, keyboard nav |
| Chart.js | Limited | Needs manual `<canvas>` fallback content |
| D3.js | Manual | Full control but all a11y is your responsibility |
| Recharts | Basic | Add descriptions, data tables manually |
| Victory | Good | ARIA attributes supported on chart elements |

### Key Rules

1. **Never use charts as the only way to convey information**. Always provide a text summary and/or data table.
2. Canvas-based charts need `<canvas>` fallback content:
   ```html
   <canvas aria-label="Sales chart">
     <p>Sales increased from $100K in January to $450K in December.</p>
     <table><!-- data table --></table>
   </canvas>
   ```
3. Use high-contrast colors. Test with color-blindness simulators.
4. Provide pattern fills alongside colors for print and colorblind users.
5. Make interactive charts keyboard-navigable with arrow keys between data points.
