/**
 * type-utils.ts — Utility types for strict TypeScript projects.
 *
 * Drop this file into your project and import what you need:
 *
 *   import { Result, ok, err, assertNever, type UserId } from './type-utils';
 */

// ════════════════════════════════════════════════════════════════════
// § Branded / Opaque Types
// ════════════════════════════════════════════════════════════════════

/**
 * Creates a "branded" type — a type that is structurally identical to its
 * base type but nominally distinct. Prevents accidentally mixing values
 * that share the same underlying type (e.g., UserId vs. OrderId).
 *
 * @example
 *   type UserId = Brand<string, 'UserId'>;
 *   type OrderId = Brand<string, 'OrderId'>;
 *
 *   const userId = 'abc' as UserId;
 *   const orderId = 'abc' as OrderId;
 *
 *   function getUser(id: UserId) { ... }
 *   getUser(orderId); // ✗ Type error!
 *   getUser(userId);  // ✓ OK
 */
declare const __brand: unique symbol;
export type Brand<T, B extends string> = T & { readonly [__brand]: B };

// Pre-built branded types — extend as needed for your domain.
export type UserId = Brand<string, 'UserId'>;
export type Email = Brand<string, 'Email'>;
export type Timestamp = Brand<number, 'Timestamp'>;
export type PositiveInt = Brand<number, 'PositiveInt'>;
export type Url = Brand<string, 'Url'>;

/**
 * Smart constructors for branded types with runtime validation.
 *
 * @example
 *   const email = toEmail('user@example.com'); // Email | null
 */
export function toEmail(value: string): Email | null {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) ? (value as Email) : null;
}

export function toPositiveInt(value: number): PositiveInt | null {
  return Number.isInteger(value) && value > 0 ? (value as PositiveInt) : null;
}

// ════════════════════════════════════════════════════════════════════
// § NonNullable Helpers
// ════════════════════════════════════════════════════════════════════

/**
 * Asserts that a value is neither `null` nor `undefined` at runtime.
 * Narrows the type for the compiler automatically.
 *
 * @example
 *   const el = document.getElementById('root');
 *   assertDefined(el, 'Root element not found');
 *   el.textContent = 'Hello'; // ✓ No null check needed
 */
export function assertDefined<T>(
  value: T,
  message = 'Expected value to be defined',
): asserts value is NonNullable<T> {
  if (value === null || value === undefined) {
    throw new Error(message);
  }
}

/**
 * Returns the value if defined, otherwise returns the fallback.
 * Useful in pipelines where throwing is undesirable.
 *
 * @example
 *   const port = withDefault(process.env.PORT, '3000');
 */
export function withDefault<T>(
  value: T | null | undefined,
  fallback: NonNullable<T>,
): NonNullable<T> {
  return (value ?? fallback) as NonNullable<T>;
}

// ════════════════════════════════════════════════════════════════════
// § Exhaustive Switch Helper
// ════════════════════════════════════════════════════════════════════

/**
 * Used in the `default` case of a switch to ensure every variant of a
 * union/enum is handled. If a new variant is added and not handled,
 * TypeScript will report a compile-time error.
 *
 * @example
 *   type Shape = 'circle' | 'square' | 'triangle';
 *
 *   function area(shape: Shape): number {
 *     switch (shape) {
 *       case 'circle':   return Math.PI * r * r;
 *       case 'square':   return s * s;
 *       case 'triangle': return (b * h) / 2;
 *       default:         return assertNever(shape);
 *     }
 *   }
 *   // Adding 'hexagon' to Shape will now cause a compile error here. ✓
 */
export function assertNever(value: never, message?: string): never {
  throw new Error(
    message ?? `Unexpected value: ${JSON.stringify(value)}`,
  );
}

// ════════════════════════════════════════════════════════════════════
// § Type-Safe Dictionary Access
// ════════════════════════════════════════════════════════════════════

/**
 * A dictionary type that always returns `T | undefined` when indexed,
 * matching runtime behavior even without `noUncheckedIndexedAccess`.
 *
 * @example
 *   const counts: StrictRecord<string, number> = {};
 *   const val = counts['foo']; // type is number | undefined  ✓
 */
export type StrictRecord<K extends PropertyKey, V> = {
  [P in K]?: V;
};

/**
 * Safely access a dictionary value with a fallback.
 *
 * @example
 *   const config: Record<string, string> = loadConfig();
 *   const host = dictGet(config, 'host', 'localhost');
 */
export function dictGet<K extends PropertyKey, V>(
  record: Partial<Record<K, V>>,
  key: K,
  fallback: V,
): V {
  return record[key] ?? fallback;
}

// ════════════════════════════════════════════════════════════════════
// § Deep Utility Types
// ════════════════════════════════════════════════════════════════════

/**
 * Makes every property in T (and nested objects) required and non-nullable.
 *
 * @example
 *   type Config = { db?: { host?: string; port?: number } };
 *   type FullConfig = DeepRequired<Config>;
 *   // { db: { host: string; port: number } }
 */
export type DeepRequired<T> = {
  [P in keyof T]-?: T[P] extends object
    ? DeepRequired<NonNullable<T[P]>>
    : NonNullable<T[P]>;
};

/**
 * Makes every property in T (and nested objects) optional.
 *
 * @example
 *   type FullUser = { name: string; address: { city: string } };
 *   type PatchUser = DeepPartial<FullUser>;
 *   // { name?: string; address?: { city?: string } }
 */
export type DeepPartial<T> = {
  [P in keyof T]?: T[P] extends object ? DeepPartial<T[P]> : T[P];
};

/**
 * Makes every property in T (and nested objects) readonly.
 * Useful for immutable state, Redux stores, or frozen configs.
 *
 * @example
 *   type AppState = { user: { name: string; prefs: { theme: string } } };
 *   type FrozenState = DeepReadonly<AppState>;
 *   // All properties are recursively readonly.
 */
export type DeepReadonly<T> = {
  readonly [P in keyof T]: T[P] extends object ? DeepReadonly<T[P]> : T[P];
};

// ════════════════════════════════════════════════════════════════════
// § Strict Event Handler Types
// ════════════════════════════════════════════════════════════════════

/**
 * Generic strict event map — maps event names to their payload types.
 * Use with `TypedEventEmitter` for fully typed pub/sub.
 *
 * @example
 *   interface AppEvents {
 *     userLoggedIn:  { userId: UserId; timestamp: Timestamp };
 *     itemPurchased: { itemId: string; quantity: PositiveInt };
 *   }
 */
export type EventHandler<T = void> = (payload: T) => void;

export interface TypedEventEmitter<Events extends Record<string, unknown>> {
  on<K extends keyof Events>(event: K, handler: EventHandler<Events[K]>): void;
  off<K extends keyof Events>(event: K, handler: EventHandler<Events[K]>): void;
  emit<K extends keyof Events>(event: K, payload: Events[K]): void;
}

/**
 * Strict DOM event handler — parameterised on the element and event.
 *
 * @example
 *   const handleClick: StrictDOMHandler<HTMLButtonElement, 'click'> = (e) => {
 *     console.log(e.currentTarget.disabled); // ✓ correctly typed
 *   };
 */
export type StrictDOMHandler<
  E extends Element,
  K extends keyof HTMLElementEventMap,
> = (this: E, event: HTMLElementEventMap[K] & { currentTarget: E }) => void;

// ════════════════════════════════════════════════════════════════════
// § Result Type (Error handling without exceptions)
// ════════════════════════════════════════════════════════════════════

/**
 * A discriminated union representing either a success value (`Ok`) or
 * a failure value (`Err`). Use instead of try/catch for expected errors
 * to keep the type-checker in the loop.
 *
 * @example
 *   function parseJson(input: string): Result<unknown, Error> {
 *     try {
 *       return ok(JSON.parse(input));
 *     } catch (e) {
 *       return err(e instanceof Error ? e : new Error(String(e)));
 *     }
 *   }
 *
 *   const result = parseJson('{"a":1}');
 *   if (result.ok) {
 *     console.log(result.value); // ✓ typed as unknown
 *   } else {
 *     console.error(result.error); // ✓ typed as Error
 *   }
 */
export type Result<T, E = Error> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: E };

/** Create a success result. */
export function ok<T>(value: T): Result<T, never> {
  return { ok: true, value };
}

/** Create a failure result. */
export function err<E>(error: E): Result<never, E> {
  return { ok: false, error };
}

/**
 * Unwrap a Result, throwing if it is an Err.
 *
 * @example
 *   const data = unwrap(parseJson(rawInput));
 */
export function unwrap<T, E>(result: Result<T, E>): T {
  if (result.ok) return result.value;
  throw result.error instanceof Error
    ? result.error
    : new Error(String(result.error));
}

/**
 * Map over the success value of a Result.
 *
 * @example
 *   const lengths = mapResult(parseJson(input), (val) => JSON.stringify(val).length);
 */
export function mapResult<T, U, E>(
  result: Result<T, E>,
  fn: (value: T) => U,
): Result<U, E> {
  return result.ok ? ok(fn(result.value)) : result;
}

// ════════════════════════════════════════════════════════════════════
// § Miscellaneous Strict Helpers
// ════════════════════════════════════════════════════════════════════

/**
 * Type-safe `Object.keys` — returns `(keyof T)[]` instead of `string[]`.
 *
 * @example
 *   const user = { name: 'Ada', age: 36 };
 *   const keys = typedKeys(user); // ('name' | 'age')[]
 */
export function typedKeys<T extends object>(obj: T): (keyof T)[] {
  return Object.keys(obj) as (keyof T)[];
}

/**
 * Type-safe `Object.entries`.
 */
export function typedEntries<T extends Record<string, unknown>>(
  obj: T,
): [keyof T, T[keyof T]][] {
  return Object.entries(obj) as [keyof T, T[keyof T]][];
}

/**
 * Narrow an unknown value to a specific type using a type guard function.
 * Returns a Result so callers don't need to think about exceptions.
 *
 * @example
 *   const isString = (v: unknown): v is string => typeof v === 'string';
 *   const result = narrow(someValue, isString, 'Expected a string');
 */
export function narrow<T>(
  value: unknown,
  guard: (v: unknown) => v is T,
  message = 'Type narrowing failed',
): Result<T, Error> {
  return guard(value) ? ok(value) : err(new Error(message));
}
