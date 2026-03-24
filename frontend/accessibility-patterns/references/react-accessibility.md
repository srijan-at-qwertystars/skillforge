# React-Specific Accessibility Patterns

Comprehensive guide to building accessible React applications using modern libraries, hooks, and patterns.

## Table of Contents

- [React Aria (Adobe)](#react-aria-adobe)
- [Radix UI Primitives](#radix-ui-primitives)
- [Headless UI](#headless-ui)
- [Accessible Forms](#accessible-forms)
- [Focus Management](#focus-management)
- [Live Region Announcements](#live-region-announcements)
- [Accessible Routing](#accessible-routing)
- [SSR Accessibility](#ssr-accessibility)
- [Component Library Audit Patterns](#component-library-audit-patterns)

---

## React Aria (Adobe)

React Aria provides unstyled, accessible hooks for building design systems. It handles ARIA, keyboard, focus, and internationalization.

### Installation

```bash
npm install react-aria react-stately
# Or individual hooks:
npm install @react-aria/button @react-aria/dialog @react-aria/focus
```

### Button

```tsx
import { useButton } from 'react-aria';
import { useRef } from 'react';

function Button({ onPress, children, isDisabled }: {
  onPress: () => void;
  children: React.ReactNode;
  isDisabled?: boolean;
}) {
  const ref = useRef<HTMLButtonElement>(null);
  const { buttonProps } = useButton({ onPress, isDisabled }, ref);

  return (
    <button {...buttonProps} ref={ref} className="btn">
      {children}
    </button>
  );
}
```

### TextField

```tsx
import { useTextField } from 'react-aria';

function TextField({ label, description, errorMessage, ...props }: {
  label: string;
  description?: string;
  errorMessage?: string;
  value: string;
  onChange: (value: string) => void;
}) {
  const ref = useRef<HTMLInputElement>(null);
  const { labelProps, inputProps, descriptionProps, errorMessageProps } = useTextField(
    { ...props, label, description, errorMessage, isInvalid: !!errorMessage },
    ref
  );

  return (
    <div className="field">
      <label {...labelProps}>{label}</label>
      <input {...inputProps} ref={ref} />
      {description && <p {...descriptionProps} className="field-desc">{description}</p>}
      {errorMessage && <p {...errorMessageProps} className="field-error">{errorMessage}</p>}
    </div>
  );
}
```

### ComboBox

```tsx
import { useComboBox, useFilter } from 'react-aria';
import { useComboBoxState } from 'react-stately';
import type { ComboBoxProps } from '@react-types/combobox';

function ComboBox<T extends object>(props: ComboBoxProps<T>) {
  const { contains } = useFilter({ sensitivity: 'base' });
  const state = useComboBoxState({ ...props, defaultFilter: contains });

  const inputRef = useRef<HTMLInputElement>(null);
  const listBoxRef = useRef<HTMLUListElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);

  const { inputProps, listBoxProps, labelProps } = useComboBox(
    { ...props, inputRef, listBoxRef, popoverRef },
    state
  );

  return (
    <div className="combobox">
      <label {...labelProps}>{props.label}</label>
      <input {...inputProps} ref={inputRef} />
      {state.isOpen && (
        <div ref={popoverRef} className="combobox-popover">
          <ul {...listBoxProps} ref={listBoxRef} className="combobox-list">
            {[...state.collection].map(item => (
              <li
                key={item.key}
                className={`combobox-option ${
                  state.selectionManager.isSelected(item.key) ? 'selected' : ''
                }`}
              >
                {item.rendered}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
```

### Dialog / Modal

```tsx
import { useDialog } from 'react-aria';

function Dialog({ title, children, ...props }: {
  title: string;
  children: React.ReactNode;
  role?: 'dialog' | 'alertdialog';
}) {
  const ref = useRef<HTMLDivElement>(null);
  const { dialogProps, titleProps } = useDialog({ ...props, role: props.role ?? 'dialog' }, ref);

  return (
    <div {...dialogProps} ref={ref} className="dialog">
      <h2 {...titleProps}>{title}</h2>
      {children}
    </div>
  );
}
```

### useTabList

```tsx
import { useTabList, useTab, useTabPanel } from 'react-aria';
import { useTabListState } from 'react-stately';
import type { TabListProps } from '@react-types/tabs';

function Tabs<T extends object>(props: TabListProps<T>) {
  const state = useTabListState(props);
  const ref = useRef<HTMLDivElement>(null);
  const { tabListProps } = useTabList(props, state, ref);

  return (
    <div className="tabs">
      <div {...tabListProps} ref={ref} className="tab-list">
        {[...state.collection].map(item => (
          <Tab key={item.key} item={item} state={state} />
        ))}
      </div>
      <TabPanel key={state.selectedItem?.key} state={state} />
    </div>
  );
}

function Tab({ item, state }: { item: any; state: any }) {
  const ref = useRef<HTMLDivElement>(null);
  const { tabProps } = useTab({ key: item.key }, state, ref);
  return <div {...tabProps} ref={ref} className="tab">{item.rendered}</div>;
}

function TabPanel({ state }: { state: any }) {
  const ref = useRef<HTMLDivElement>(null);
  const { tabPanelProps } = useTabPanel({}, state, ref);
  return <div {...tabPanelProps} ref={ref} className="tab-panel">{state.selectedItem?.props.children}</div>;
}
```

### Key React Aria Hooks Reference

| Hook | Purpose |
|------|---------|
| `useButton` | Accessible button with press events |
| `useTextField` | Input with label, description, error |
| `useCheckbox` | Checkbox with indeterminate state |
| `useRadioGroup` | Radio group with arrow key navigation |
| `useSwitch` | Toggle switch |
| `useSlider` | Range slider with keyboard |
| `useComboBox` | Combobox with filtering |
| `useSelect` | Select/dropdown |
| `useListBox` | Listbox with selection |
| `useMenu` | Menu with keyboard navigation |
| `useDialog` | Dialog/modal |
| `useTabList` | Tabs with panels |
| `useTable` | Data table with sort, selection |
| `useTooltip` | Tooltip with hover/focus |
| `useFocusRing` | Focus indicator styling |
| `useFocusWithin` | Track focus within a container |
| `usePress` | Cross-platform press events |
| `useLongPress` | Long press with a11y alternative |

---

## Radix UI Primitives

Radix provides unstyled, accessible components with built-in keyboard navigation, focus management, and ARIA.

### Installation

```bash
npm install @radix-ui/react-dialog @radix-ui/react-dropdown-menu \
  @radix-ui/react-tabs @radix-ui/react-tooltip @radix-ui/react-accordion \
  @radix-ui/react-popover @radix-ui/react-select @radix-ui/react-switch \
  @radix-ui/react-checkbox @radix-ui/react-radio-group
```

### Dialog

```tsx
import * as Dialog from '@radix-ui/react-dialog';

function ConfirmDialog({ trigger, title, description, onConfirm }: {
  trigger: React.ReactNode;
  title: string;
  description: string;
  onConfirm: () => void;
}) {
  return (
    <Dialog.Root>
      <Dialog.Trigger asChild>{trigger}</Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="dialog-overlay" />
        <Dialog.Content className="dialog-content">
          <Dialog.Title>{title}</Dialog.Title>
          <Dialog.Description>{description}</Dialog.Description>
          <div className="dialog-actions">
            <Dialog.Close asChild>
              <button className="btn-secondary">Cancel</button>
            </Dialog.Close>
            <button className="btn-primary" onClick={onConfirm}>Confirm</button>
          </div>
          <Dialog.Close asChild>
            <button className="dialog-close" aria-label="Close">×</button>
          </Dialog.Close>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
```

### Dropdown Menu

```tsx
import * as DropdownMenu from '@radix-ui/react-dropdown-menu';

function ActionsMenu({ items }: { items: { label: string; onSelect: () => void; icon?: string; danger?: boolean }[] }) {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button aria-label="Actions">⋮</button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content className="menu-content" sideOffset={5}>
          {items.map((item, i) => (
            <DropdownMenu.Item
              key={i}
              className={`menu-item ${item.danger ? 'menu-item-danger' : ''}`}
              onSelect={item.onSelect}
            >
              {item.icon && <span aria-hidden="true">{item.icon}</span>}
              {item.label}
            </DropdownMenu.Item>
          ))}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}
```

### Tabs

```tsx
import * as Tabs from '@radix-ui/react-tabs';

function SettingsTabs() {
  return (
    <Tabs.Root defaultValue="general">
      <Tabs.List aria-label="Settings sections">
        <Tabs.Trigger value="general">General</Tabs.Trigger>
        <Tabs.Trigger value="security">Security</Tabs.Trigger>
        <Tabs.Trigger value="notifications">Notifications</Tabs.Trigger>
      </Tabs.List>
      <Tabs.Content value="general"><GeneralSettings /></Tabs.Content>
      <Tabs.Content value="security"><SecuritySettings /></Tabs.Content>
      <Tabs.Content value="notifications"><NotificationSettings /></Tabs.Content>
    </Tabs.Root>
  );
}
```

### Accordion

```tsx
import * as Accordion from '@radix-ui/react-accordion';

function FAQ({ items }: { items: { question: string; answer: string }[] }) {
  return (
    <Accordion.Root type="single" collapsible>
      {items.map((item, i) => (
        <Accordion.Item key={i} value={`item-${i}`}>
          <Accordion.Header>
            <Accordion.Trigger className="accordion-trigger">
              {item.question}
              <span aria-hidden="true" className="accordion-chevron">▸</span>
            </Accordion.Trigger>
          </Accordion.Header>
          <Accordion.Content className="accordion-content">
            <p>{item.answer}</p>
          </Accordion.Content>
        </Accordion.Item>
      ))}
    </Accordion.Root>
  );
}
```

### Radix vs React Aria Decision Guide

| Criteria | Radix UI | React Aria |
|----------|----------|------------|
| API style | Component-based | Hook-based |
| Rendering | Renders DOM structure | You control all DOM |
| Styling freedom | Full (unstyled) | Full (unstyled) |
| Customization | Moderate (composition) | Maximum (hooks) |
| Bundle size | Per-component packages | Per-hook packages |
| SSR support | Yes | Yes |
| Animation | CSS-based, `data-state` | Manual |
| Best for | Rapid component building | Design systems, full control |

---

## Headless UI

From Tailwind Labs. Unstyled, accessible components designed for Tailwind CSS but framework-agnostic.

### Installation

```bash
npm install @headlessui/react
```

### Listbox (Select)

```tsx
import { Listbox, ListboxButton, ListboxOption, ListboxOptions } from '@headlessui/react';

function StatusSelect({ value, onChange, options }: {
  value: string;
  onChange: (value: string) => void;
  options: { value: string; label: string }[];
}) {
  const selected = options.find(o => o.value === value);

  return (
    <Listbox value={value} onChange={onChange}>
      <div className="relative">
        <ListboxButton className="select-button">
          {selected?.label}
        </ListboxButton>
        <ListboxOptions className="select-options">
          {options.map(option => (
            <ListboxOption
              key={option.value}
              value={option.value}
              className={({ active }) => `select-option ${active ? 'active' : ''}`}
            >
              {({ selected }) => (
                <span className={selected ? 'font-bold' : ''}>{option.label}</span>
              )}
            </ListboxOption>
          ))}
        </ListboxOptions>
      </div>
    </Listbox>
  );
}
```

### Disclosure

```tsx
import { Disclosure, DisclosureButton, DisclosurePanel } from '@headlessui/react';

function FilterPanel({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <Disclosure>
      {({ open }) => (
        <>
          <DisclosureButton className="disclosure-btn">
            {title}
            <span aria-hidden="true">{open ? '−' : '+'}</span>
          </DisclosureButton>
          <DisclosurePanel className="disclosure-panel">
            {children}
          </DisclosurePanel>
        </>
      )}
    </Disclosure>
  );
}
```

### Transition with Accessibility

```tsx
import { Dialog, DialogBackdrop, DialogPanel, DialogTitle, Transition, TransitionChild } from '@headlessui/react';
import { Fragment } from 'react';

function Modal({ isOpen, onClose, title, children }: {
  isOpen: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <Transition show={isOpen} as={Fragment}>
      <Dialog onClose={onClose}>
        <TransitionChild
          as={Fragment}
          enter="ease-out duration-300" enterFrom="opacity-0" enterTo="opacity-100"
          leave="ease-in duration-200" leaveFrom="opacity-100" leaveTo="opacity-0"
        >
          <DialogBackdrop className="fixed inset-0 bg-black/30" />
        </TransitionChild>
        <div className="fixed inset-0 flex items-center justify-center p-4">
          <TransitionChild
            as={Fragment}
            enter="ease-out duration-300" enterFrom="opacity-0 scale-95" enterTo="opacity-100 scale-100"
            leave="ease-in duration-200" leaveFrom="opacity-100 scale-100" leaveTo="opacity-0 scale-95"
          >
            <DialogPanel className="bg-white rounded-lg p-6 max-w-md w-full">
              <DialogTitle className="text-lg font-bold">{title}</DialogTitle>
              {children}
            </DialogPanel>
          </TransitionChild>
        </div>
      </Dialog>
    </Transition>
  );
}
```

---

## Accessible Forms

### React Hook Form + Accessibility

```bash
npm install react-hook-form @hookform/resolvers zod
```

```tsx
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { useRef, useEffect } from 'react';

const schema = z.object({
  name: z.string().min(1, 'Name is required'),
  email: z.string().email('Enter a valid email address'),
  role: z.enum(['admin', 'user', 'viewer'], { required_error: 'Select a role' }),
  agree: z.literal(true, { errorMap: () => ({ message: 'You must agree to the terms' }) }),
});

type FormData = z.infer<typeof schema>;

function AccessibleForm() {
  const errorSummaryRef = useRef<HTMLDivElement>(null);
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitted },
  } = useForm<FormData>({ resolver: zodResolver(schema) });

  // Focus error summary on failed submission
  useEffect(() => {
    if (isSubmitted && Object.keys(errors).length > 0) {
      errorSummaryRef.current?.focus();
    }
  }, [isSubmitted, errors]);

  const onSubmit = (data: FormData) => {
    console.log('Submitted:', data);
  };

  const errorEntries = Object.entries(errors);

  return (
    <form onSubmit={handleSubmit(onSubmit)} noValidate aria-label="Registration form">
      {/* Error Summary */}
      {errorEntries.length > 0 && (
        <div
          ref={errorSummaryRef}
          role="alert"
          tabIndex={-1}
          className="error-summary"
        >
          <h2>Please fix the following errors:</h2>
          <ul>
            {errorEntries.map(([field, error]) => (
              <li key={field}>
                <a href={`#field-${field}`}>{error?.message as string}</a>
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* Name field */}
      <div className="field">
        <label htmlFor="field-name">
          Name <span aria-hidden="true">*</span>
        </label>
        <input
          id="field-name"
          {...register('name')}
          aria-required="true"
          aria-invalid={!!errors.name}
          aria-describedby={errors.name ? 'name-error' : undefined}
        />
        {errors.name && (
          <p id="name-error" className="field-error" role="alert">
            {errors.name.message}
          </p>
        )}
      </div>

      {/* Email field */}
      <div className="field">
        <label htmlFor="field-email">
          Email <span aria-hidden="true">*</span>
        </label>
        <input
          id="field-email"
          type="email"
          {...register('email')}
          aria-required="true"
          aria-invalid={!!errors.email}
          aria-describedby={errors.email ? 'email-error' : 'email-hint'}
          autoComplete="email"
        />
        <p id="email-hint" className="field-hint">We'll never share your email.</p>
        {errors.email && (
          <p id="email-error" className="field-error" role="alert">
            {errors.email.message}
          </p>
        )}
      </div>

      {/* Role select */}
      <div className="field">
        <label htmlFor="field-role">
          Role <span aria-hidden="true">*</span>
        </label>
        <select
          id="field-role"
          {...register('role')}
          aria-required="true"
          aria-invalid={!!errors.role}
          aria-describedby={errors.role ? 'role-error' : undefined}
        >
          <option value="">Select a role</option>
          <option value="admin">Admin</option>
          <option value="user">User</option>
          <option value="viewer">Viewer</option>
        </select>
        {errors.role && (
          <p id="role-error" className="field-error" role="alert">
            {errors.role.message}
          </p>
        )}
      </div>

      {/* Checkbox */}
      <div className="field">
        <label>
          <input
            type="checkbox"
            {...register('agree')}
            aria-invalid={!!errors.agree}
            aria-describedby={errors.agree ? 'agree-error' : undefined}
          />
          I agree to the terms <span aria-hidden="true">*</span>
        </label>
        {errors.agree && (
          <p id="agree-error" className="field-error" role="alert">
            {errors.agree.message}
          </p>
        )}
      </div>

      <button type="submit">Register</button>
    </form>
  );
}
```

### Form Field Wrapper Component

```tsx
interface FieldProps {
  id: string;
  label: string;
  error?: string;
  hint?: string;
  required?: boolean;
  children: (props: {
    id: string;
    'aria-invalid': boolean;
    'aria-required': boolean;
    'aria-describedby': string | undefined;
  }) => React.ReactNode;
}

function Field({ id, label, error, hint, required, children }: FieldProps) {
  const describedBy = [
    hint ? `${id}-hint` : null,
    error ? `${id}-error` : null,
  ].filter(Boolean).join(' ') || undefined;

  return (
    <div className="field">
      <label htmlFor={id}>
        {label}
        {required && <span aria-hidden="true"> *</span>}
        {required && <span className="sr-only"> (required)</span>}
      </label>
      {children({
        id,
        'aria-invalid': !!error,
        'aria-required': !!required,
        'aria-describedby': describedBy,
      })}
      {hint && <p id={`${id}-hint`} className="field-hint">{hint}</p>}
      {error && <p id={`${id}-error`} className="field-error" role="alert">{error}</p>}
    </div>
  );
}

// Usage:
<Field id="email" label="Email" error={errors.email?.message} hint="Work email preferred" required>
  {(fieldProps) => <input type="email" {...fieldProps} {...register('email')} />}
</Field>
```

---

## Focus Management

### useRef for Programmatic Focus

```tsx
function SearchResults({ results, query }: { results: Item[]; query: string }) {
  const headingRef = useRef<HTMLHeadingElement>(null);

  useEffect(() => {
    if (query) {
      headingRef.current?.focus();
    }
  }, [results]);

  return (
    <section aria-label="Search results">
      <h2 ref={headingRef} tabIndex={-1}>
        {results.length} results for "{query}"
      </h2>
      <ul>
        {results.map(r => <li key={r.id}>{r.name}</li>)}
      </ul>
    </section>
  );
}
```

### FocusScope (React Aria)

```tsx
import { FocusScope } from 'react-aria';

function TrapExample({ isOpen, onClose, children }: {
  isOpen: boolean;
  onClose: () => void;
  children: React.ReactNode;
}) {
  if (!isOpen) return null;

  return (
    <FocusScope contain restoreFocus autoFocus>
      <div role="dialog" aria-modal="true" aria-label="Dialog">
        {children}
        <button onClick={onClose}>Close</button>
      </div>
    </FocusScope>
  );
}
```

**FocusScope props:**
- `contain`: Trap focus within the scope
- `restoreFocus`: Return focus to trigger on unmount
- `autoFocus`: Focus first tabbable element on mount

### Custom Focus Trap Hook

```tsx
function useFocusTrap(ref: React.RefObject<HTMLElement>, active: boolean) {
  useEffect(() => {
    if (!active || !ref.current) return;

    const container = ref.current;
    const focusableSelector = [
      'a[href]', 'button:not([disabled])', 'input:not([disabled])',
      'select:not([disabled])', 'textarea:not([disabled])',
      '[tabindex]:not([tabindex="-1"])',
    ].join(',');

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key !== 'Tab') return;

      const focusable = Array.from(container.querySelectorAll<HTMLElement>(focusableSelector));
      if (focusable.length === 0) return;

      const first = focusable[0];
      const last = focusable[focusable.length - 1];

      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault();
        first.focus();
      }
    };

    container.addEventListener('keydown', handleKeyDown);
    // Auto-focus first element
    const focusable = container.querySelectorAll<HTMLElement>(focusableSelector);
    focusable[0]?.focus();

    return () => container.removeEventListener('keydown', handleKeyDown);
  }, [ref, active]);
}
```

### Focus Restoration Pattern

```tsx
function useRestoreFocus() {
  const triggerRef = useRef<Element | null>(null);

  const saveFocus = () => {
    triggerRef.current = document.activeElement;
  };

  const restoreFocus = () => {
    if (triggerRef.current instanceof HTMLElement) {
      triggerRef.current.focus();
    }
  };

  return { saveFocus, restoreFocus };
}

// Usage in a modal component:
function Modal({ isOpen, onClose, children }: ModalProps) {
  const { saveFocus, restoreFocus } = useRestoreFocus();

  useEffect(() => {
    if (isOpen) saveFocus();
    return () => { if (isOpen) restoreFocus(); };
  }, [isOpen]);

  // ... render modal
}
```

### Managing Focus After Delete

```tsx
function ItemList({ items, onDelete }: { items: Item[]; onDelete: (id: string) => void }) {
  const itemRefs = useRef<Map<string, HTMLLIElement>>(new Map());
  const [lastDeleted, setLastDeleted] = useState<number | null>(null);

  useEffect(() => {
    if (lastDeleted !== null) {
      // Focus next item, or previous if last was deleted
      const nextIndex = Math.min(lastDeleted, items.length - 1);
      if (items[nextIndex]) {
        itemRefs.current.get(items[nextIndex].id)?.focus();
      }
    }
  }, [items, lastDeleted]);

  const handleDelete = (id: string, index: number) => {
    setLastDeleted(index);
    onDelete(id);
  };

  return (
    <ul>
      {items.map((item, i) => (
        <li
          key={item.id}
          ref={(el) => { if (el) itemRefs.current.set(item.id, el); }}
          tabIndex={-1}
        >
          {item.name}
          <button
            aria-label={`Delete ${item.name}`}
            onClick={() => handleDelete(item.id, i)}
          >
            Delete
          </button>
        </li>
      ))}
    </ul>
  );
}
```

---

## Live Region Announcements

### Announcement Hook

```tsx
function useAnnounce() {
  const [message, setMessage] = useState('');
  const [politeness, setPoliteness] = useState<'polite' | 'assertive'>('polite');

  const announce = useCallback((msg: string, priority: 'polite' | 'assertive' = 'polite') => {
    setPoliteness(priority);
    // Clear first to re-trigger announcement for repeated messages
    setMessage('');
    requestAnimationFrame(() => setMessage(msg));
  }, []);

  const Announcer = useMemo(() => (
    <div
      role={politeness === 'assertive' ? 'alert' : 'status'}
      aria-live={politeness}
      aria-atomic="true"
      className="sr-only"
    >
      {message}
    </div>
  ), [message, politeness]);

  return { announce, Announcer };
}
```

### Global Announcer Provider

```tsx
const AnnouncerContext = createContext<(msg: string, priority?: 'polite' | 'assertive') => void>(() => {});

export function AnnouncerProvider({ children }: { children: React.ReactNode }) {
  const politeRef = useRef<HTMLDivElement>(null);
  const assertiveRef = useRef<HTMLDivElement>(null);

  const announce = useCallback((message: string, priority: 'polite' | 'assertive' = 'polite') => {
    const el = priority === 'assertive' ? assertiveRef.current : politeRef.current;
    if (el) {
      el.textContent = '';
      // Delay to ensure AT picks up the change
      requestAnimationFrame(() => { el.textContent = message; });
    }
  }, []);

  return (
    <AnnouncerContext.Provider value={announce}>
      {children}
      <div ref={politeRef} role="status" aria-live="polite" aria-atomic="true" className="sr-only" />
      <div ref={assertiveRef} role="alert" aria-live="assertive" aria-atomic="true" className="sr-only" />
    </AnnouncerContext.Provider>
  );
}

export function useAnnouncer() {
  return useContext(AnnouncerContext);
}

// Usage:
function TodoList() {
  const announce = useAnnouncer();

  const addTodo = (text: string) => {
    // ... add logic
    announce(`Todo "${text}" added. ${todos.length + 1} items total.`);
  };

  const deleteTodo = (id: string, name: string) => {
    // ... delete logic
    announce(`Todo "${name}" deleted.`, 'assertive');
  };
}
```

### Debounced Announcements

For rapidly changing values (counters, filters):

```tsx
function useDebounceAnnounce(delay = 500) {
  const announce = useAnnouncer();
  const timeoutRef = useRef<number>();

  return useCallback((message: string, priority?: 'polite' | 'assertive') => {
    clearTimeout(timeoutRef.current);
    timeoutRef.current = window.setTimeout(() => {
      announce(message, priority);
    }, delay);
  }, [announce, delay]);
}

// Usage: rapidly changing filter results
function FilteredList({ items, filter }: { items: Item[]; filter: string }) {
  const debounceAnnounce = useDebounceAnnounce(300);
  const filtered = items.filter(i => i.name.includes(filter));

  useEffect(() => {
    debounceAnnounce(`${filtered.length} results found`);
  }, [filtered.length]);

  return <ul>{filtered.map(i => <li key={i.id}>{i.name}</li>)}</ul>;
}
```

---

## Accessible Routing

### React Router v6+

```tsx
import { useLocation, useNavigationType } from 'react-router-dom';

function RouteAnnouncer() {
  const location = useLocation();
  const navType = useNavigationType();
  const [announcement, setAnnouncement] = useState('');

  useEffect(() => {
    // Delay to allow route component to render and set document.title
    const timer = setTimeout(() => {
      const title = document.title;
      setAnnouncement(`${navType === 'POP' ? 'Returned to' : 'Navigated to'} ${title}`);
    }, 100);

    // Reset scroll position
    window.scrollTo(0, 0);

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

// In App.tsx:
function App() {
  return (
    <BrowserRouter>
      <RouteAnnouncer />
      <SkipNavigation />
      <Header />
      <main id="main-content" tabIndex={-1}>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/about" element={<About />} />
        </Routes>
      </main>
    </BrowserRouter>
  );
}
```

### Page Title Management

```tsx
function useDocumentTitle(title: string) {
  useEffect(() => {
    const prevTitle = document.title;
    document.title = `${title} | My App`;
    return () => { document.title = prevTitle; };
  }, [title]);
}

// In each route component:
function Dashboard() {
  useDocumentTitle('Dashboard');
  return <h1>Dashboard</h1>;
}
```

### Focus Management on Route Change

```tsx
function useFocusOnRouteChange() {
  const location = useLocation();
  const mainRef = useRef<HTMLElement>(null);

  useEffect(() => {
    // Focus the main content area (with tabIndex={-1})
    mainRef.current?.focus({ preventScroll: false });
  }, [location.pathname]);

  return mainRef;
}

function AppShell({ children }: { children: React.ReactNode }) {
  const mainRef = useFocusOnRouteChange();

  return (
    <>
      <SkipNavigation target="main-content" />
      <nav aria-label="Main navigation">{/* ... */}</nav>
      <main ref={mainRef} id="main-content" tabIndex={-1}>
        {children}
      </main>
    </>
  );
}
```

### Loading States During Navigation

```tsx
import { useNavigation } from 'react-router-dom';

function NavigationProgress() {
  const { state } = useNavigation();

  return (
    <>
      {state === 'loading' && (
        <div className="progress-bar" role="progressbar" aria-label="Loading page" />
      )}
      <div role="status" aria-live="polite" className="sr-only">
        {state === 'loading' ? 'Loading page...' : ''}
      </div>
    </>
  );
}
```

---

## SSR Accessibility

### Hydration Considerations

```tsx
// Avoid hydration mismatch with IDs
import { useId } from 'react';

function FormField({ label }: { label: string }) {
  const id = useId(); // Consistent between server and client

  return (
    <div>
      <label htmlFor={id}>{label}</label>
      <input id={id} />
    </div>
  );
}
```

### `suppressHydrationWarning` for Dynamic A11y Content

```tsx
// Live regions populated on client only
function LiveAnnouncer() {
  const [message, setMessage] = useState('');

  return (
    <div
      role="status"
      aria-live="polite"
      className="sr-only"
      suppressHydrationWarning
    >
      {message}
    </div>
  );
}
```

### Next.js Specific

```tsx
// app/layout.tsx
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <a href="#main-content" className="skip-link">Skip to main content</a>
        <Header />
        <main id="main-content" tabIndex={-1}>
          {children}
        </main>
        <Footer />
      </body>
    </html>
  );
}
```

### `<head>` Metadata for Accessibility

```tsx
// Next.js App Router
export const metadata = {
  title: {
    default: 'My App',
    template: '%s | My App',
  },
};

// Per-page:
export const metadata = {
  title: 'Dashboard',
  description: 'View your account dashboard and recent activity',
};
```

### Streaming SSR and Live Regions

With React 18 streaming SSR (`renderToPipeableStream`), live regions may not exist in the DOM when the first update fires. Mount live region containers in the initial shell:

```tsx
// Shell component (renders first)
function Shell({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        {children}
        {/* Mount live regions early in the stream */}
        <div id="announcer" role="status" aria-live="polite" className="sr-only" />
        <div id="alert-region" role="alert" className="sr-only" />
      </body>
    </html>
  );
}
```

---

## Component Library Audit Patterns

### Automated Audit Script

```tsx
// scripts/audit-components.tsx
import { render } from '@testing-library/react';
import { axe } from 'jest-axe';
import * as components from '../src/components';

const auditResults: { component: string; violations: any[]; passes: number }[] = [];

for (const [name, Component] of Object.entries(components)) {
  try {
    // Attempt rendering with minimal props
    const { container } = render(<Component />);
    const results = await axe(container);
    auditResults.push({
      component: name,
      violations: results.violations,
      passes: results.passes.length,
    });
  } catch {
    auditResults.push({ component: name, violations: [{ id: 'render-error' }], passes: 0 });
  }
}

console.table(auditResults.map(r => ({
  Component: r.component,
  Violations: r.violations.length,
  Passes: r.passes,
  Status: r.violations.length === 0 ? '✅' : '❌',
})));
```

### Component A11y Requirements Checklist

For each component in your library, verify:

```markdown
## Component: [Name]

### Keyboard
- [ ] Focusable with Tab (if interactive)
- [ ] Activatable with Enter/Space
- [ ] Dismissible with Escape (if overlay/popup)
- [ ] Arrow key navigation (if composite widget)
- [ ] Focus visible indicator

### ARIA
- [ ] Correct role assigned
- [ ] Accessible name (label/aria-label)
- [ ] States communicated (expanded, selected, checked, etc.)
- [ ] Descriptions linked (aria-describedby)
- [ ] Live region for dynamic updates

### Visual
- [ ] Color contrast passes AA
- [ ] Works without color
- [ ] Respects reduced motion
- [ ] Works in forced-colors mode
- [ ] Visible at 200% zoom

### Screen Reader
- [ ] Component type announced correctly
- [ ] State changes announced
- [ ] Error messages announced
- [ ] Instructions/hints read
```

### CI Gate for A11y

```ts
// a11y.test.ts — Runs on every component in the library
import { readdirSync } from 'fs';
import { join } from 'path';

const componentDir = join(__dirname, '../src/components');
const componentFiles = readdirSync(componentDir).filter(f => f.endsWith('.tsx'));

describe.each(componentFiles)('A11y: %s', (file) => {
  it('has no axe violations in default state', async () => {
    const mod = await import(join(componentDir, file));
    const Component = mod.default || Object.values(mod)[0];
    const { container } = render(<Component />);
    expect(await axe(container)).toHaveNoViolations();
  });
});
```

### A11y Documentation Template for Components

```tsx
// Button.a11y.mdx
/**
 * ## Accessibility
 *
 * ### Keyboard
 * - `Enter` / `Space`: Activates the button
 * - Focus indicator: 2px blue outline
 *
 * ### Screen Reader
 * - Announces as "button"
 * - Icon-only buttons: use `aria-label`
 * - Loading state: announces "loading" via aria-busy
 *
 * ### ARIA
 * | Prop | ARIA attribute | Description |
 * |------|---------------|-------------|
 * | `isDisabled` | `aria-disabled` | Keeps button focusable |
 * | `isLoading` | `aria-busy` | Indicates loading state |
 * | `pressed` | `aria-pressed` | Toggle button state |
 *
 * ### Testing
 * ```tsx
 * it('is accessible', async () => {
 *   const { container } = render(<Button>Click me</Button>);
 *   expect(await axe(container)).toHaveNoViolations();
 * });
 * ```
 */
```
