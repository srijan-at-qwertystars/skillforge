/**
 * Custom Writable Signal Utilities
 *
 * Reusable signal wrappers: toggle, history (undo/redo), debounced,
 * array helpers, form field, local storage persistence.
 *
 * All utilities return WritableSignal-compatible objects.
 */

import {
  signal,
  computed,
  effect,
  WritableSignal,
  Signal,
  Injector,
  runInInjectionContext,
} from '@angular/core';

// ═══════════════════════════════════════════════════════════════
// 1. Toggle Signal
// ═══════════════════════════════════════════════════════════════

export interface ToggleSignal extends WritableSignal<boolean> {
  toggle(): void;
  setTrue(): void;
  setFalse(): void;
}

export function toggleSignal(initial = false): ToggleSignal {
  const s = signal(initial) as WritableSignal<boolean> & {
    toggle: () => void;
    setTrue: () => void;
    setFalse: () => void;
  };
  s.toggle = () => s.update(v => !v);
  s.setTrue = () => s.set(true);
  s.setFalse = () => s.set(false);
  return s as ToggleSignal;
}

// Usage:
// const isOpen = toggleSignal(false);
// isOpen.toggle();    // true
// isOpen.setTrue();   // true
// isOpen.setFalse();  // false
// isOpen();           // read: false

// ═══════════════════════════════════════════════════════════════
// 2. History Signal (Undo/Redo)
// ═══════════════════════════════════════════════════════════════

export interface HistorySignal<T> extends WritableSignal<T> {
  undo(): void;
  redo(): void;
  canUndo: Signal<boolean>;
  canRedo: Signal<boolean>;
  history: Signal<T[]>;
  clear(): void;
}

export function historySignal<T>(initial: T, maxSize = 50): HistorySignal<T> {
  const current = signal(initial);
  const past = signal<T[]>([]);
  const future = signal<T[]>([]);

  const wrapper: any = (...args: any[]) => {
    if (args.length === 0) return current();
    return current(...args);
  };

  // Copy signal methods
  wrapper[Symbol.toStringTag] = 'HistorySignal';

  wrapper.set = (value: T) => {
    past.update(p => [...p.slice(-(maxSize - 1)), current()]);
    future.set([]);
    current.set(value);
  };

  wrapper.update = (fn: (v: T) => T) => {
    wrapper.set(fn(current()));
  };

  wrapper.asReadonly = () => current.asReadonly();

  wrapper.undo = () => {
    const p = past();
    if (p.length === 0) return;
    future.update(f => [current(), ...f]);
    current.set(p[p.length - 1]);
    past.update(p => p.slice(0, -1));
  };

  wrapper.redo = () => {
    const f = future();
    if (f.length === 0) return;
    past.update(p => [...p, current()]);
    current.set(f[0]);
    future.update(f => f.slice(1));
  };

  wrapper.canUndo = computed(() => past().length > 0);
  wrapper.canRedo = computed(() => future().length > 0);
  wrapper.history = computed(() => [...past(), current()]);

  wrapper.clear = () => {
    past.set([]);
    future.set([]);
  };

  return wrapper as HistorySignal<T>;
}

// Usage:
// const text = historySignal('');
// text.set('Hello');
// text.set('Hello World');
// text.undo();        // 'Hello'
// text.redo();        // 'Hello World'
// text.canUndo();     // true
// text.history();     // ['', 'Hello', 'Hello World']

// ═══════════════════════════════════════════════════════════════
// 3. Debounced Signal
// ═══════════════════════════════════════════════════════════════

export interface DebouncedSignalResult<T> {
  /** The immediate (non-debounced) value */
  immediate: WritableSignal<T>;
  /** The debounced value — updates after delay */
  debounced: Signal<T>;
  /** True while waiting for debounce */
  pending: Signal<boolean>;
}

export function debouncedSignal<T>(
  initial: T,
  delayMs: number,
  injector: Injector
): DebouncedSignalResult<T> {
  const immediate = signal(initial);
  const debounced = signal(initial);
  const pending = signal(false);

  runInInjectionContext(injector, () => {
    effect((onCleanup) => {
      const val = immediate();
      pending.set(true);
      const timer = setTimeout(() => {
        debounced.set(val);
        pending.set(false);
      }, delayMs);
      onCleanup(() => {
        clearTimeout(timer);
        pending.set(false);
      });
    });
  });

  return {
    immediate,
    debounced: debounced.asReadonly(),
    pending: pending.asReadonly(),
  };
}

// Usage:
// private injector = inject(Injector);
// search = debouncedSignal('', 300, this.injector);
// Template: <input (input)="search.immediate.set($event.target.value)" />
// API call: uses search.debounced() which updates 300ms after last keystroke
// Loading indicator: search.pending()

// ═══════════════════════════════════════════════════════════════
// 4. Array Signal
// ═══════════════════════════════════════════════════════════════

export interface ArraySignal<T> extends WritableSignal<T[]> {
  push(...items: T[]): void;
  removeAt(index: number): void;
  removeWhere(predicate: (item: T) => boolean): void;
  updateAt(index: number, fn: (item: T) => T): void;
  updateWhere(predicate: (item: T) => boolean, fn: (item: T) => T): void;
  clear(): void;
  readonly length: Signal<number>;
  readonly isEmpty: Signal<boolean>;
}

export function arraySignal<T>(initial: T[] = []): ArraySignal<T> {
  const s = signal<T[]>([...initial]);

  const extended = Object.assign(s, {
    push: (...items: T[]) => s.update(a => [...a, ...items]),

    removeAt: (index: number) =>
      s.update(a => a.filter((_, i) => i !== index)),

    removeWhere: (predicate: (item: T) => boolean) =>
      s.update(a => a.filter(item => !predicate(item))),

    updateAt: (index: number, fn: (item: T) => T) =>
      s.update(a => a.map((item, i) => (i === index ? fn(item) : item))),

    updateWhere: (predicate: (item: T) => boolean, fn: (item: T) => T) =>
      s.update(a => a.map(item => (predicate(item) ? fn(item) : item))),

    clear: () => s.set([]),

    length: computed(() => s().length),
    isEmpty: computed(() => s().length === 0),
  });

  return extended as ArraySignal<T>;
}

// Usage:
// const items = arraySignal<Todo>([]);
// items.push({ id: '1', text: 'Buy milk', done: false });
// items.removeWhere(t => t.done);
// items.updateWhere(t => t.id === '1', t => ({ ...t, done: true }));
// items.length();  // Signal<number>
// items.isEmpty(); // Signal<boolean>
// items.clear();

// ═══════════════════════════════════════════════════════════════
// 5. LocalStorage-Persisted Signal
// ═══════════════════════════════════════════════════════════════

export function storedSignal<T>(
  key: string,
  initial: T,
  injector: Injector,
  options?: {
    serialize?: (value: T) => string;
    deserialize?: (raw: string) => T;
  }
): WritableSignal<T> {
  const serialize = options?.serialize ?? JSON.stringify;
  const deserialize = options?.deserialize ?? JSON.parse;

  // Hydrate from storage
  let hydrated = initial;
  try {
    const raw = localStorage.getItem(key);
    if (raw !== null) hydrated = deserialize(raw);
  } catch {
    // Invalid stored data — use initial
  }

  const s = signal<T>(hydrated);

  // Persist on change
  runInInjectionContext(injector, () => {
    effect(() => {
      try {
        localStorage.setItem(key, serialize(s()));
      } catch {
        // Storage full or unavailable
      }
    });
  });

  return s;
}

// Usage:
// private injector = inject(Injector);
// theme = storedSignal('app-theme', 'light', this.injector);
// theme.set('dark');  // automatically persisted to localStorage
// On reload: theme() returns 'dark' (hydrated from storage)

// ═══════════════════════════════════════════════════════════════
// 6. Form Field Signal
// ═══════════════════════════════════════════════════════════════

export interface FormFieldSignal<T> {
  value: WritableSignal<T>;
  dirty: Signal<boolean>;
  touched: WritableSignal<boolean>;
  errors: Signal<string[]>;
  valid: Signal<boolean>;
  reset(): void;
  markTouched(): void;
}

type Validator<T> = (value: T) => string | null;

export function formFieldSignal<T>(
  initial: T,
  validators: Validator<T>[] = []
): FormFieldSignal<T> {
  const value = signal(initial);
  const initialValue = initial;
  const touched = signal(false);

  const dirty = computed(() => value() !== initialValue);
  const errors = computed(() =>
    validators.map(v => v(value())).filter((e): e is string => e !== null)
  );
  const valid = computed(() => errors().length === 0);

  return {
    value,
    dirty,
    touched,
    errors,
    valid,
    reset: () => {
      value.set(initialValue);
      touched.set(false);
    },
    markTouched: () => touched.set(true),
  };
}

// Built-in validators
export const Validators = {
  required: (msg = 'Required'): Validator<string> =>
    (v) => v.trim().length === 0 ? msg : null,

  minLength: (min: number, msg?: string): Validator<string> =>
    (v) => v.length < min ? (msg ?? `Min ${min} characters`) : null,

  maxLength: (max: number, msg?: string): Validator<string> =>
    (v) => v.length > max ? (msg ?? `Max ${max} characters`) : null,

  pattern: (regex: RegExp, msg = 'Invalid format'): Validator<string> =>
    (v) => regex.test(v) ? null : msg,

  email: (msg = 'Invalid email'): Validator<string> =>
    (v) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) ? null : msg,

  min: (min: number, msg?: string): Validator<number> =>
    (v) => v < min ? (msg ?? `Min value is ${min}`) : null,

  max: (max: number, msg?: string): Validator<number> =>
    (v) => v > max ? (msg ?? `Max value is ${max}`) : null,
};

// Usage:
// const name = formFieldSignal('', [Validators.required(), Validators.minLength(2)]);
// name.value.set('A');
// name.errors();   // ['Min 2 characters']
// name.valid();    // false
// name.dirty();    // true
// name.reset();    // resets to '', dirty=false, touched=false
