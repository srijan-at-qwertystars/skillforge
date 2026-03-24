/**
 * Custom RxJS Operator Templates
 *
 * Two patterns:
 *   1. MonoTypeOperatorFunction<T>  — input and output share the same type
 *   2. OperatorFunction<T, R>       — input type T, output type R (type-changing)
 *
 * Usage:
 *   source$.pipe(myOperator(args))
 */

import {
  Observable,
  OperatorFunction,
  MonoTypeOperatorFunction,
  Subscriber,
  TeardownLogic,
} from 'rxjs';
import { map, filter, tap } from 'rxjs';

// ─── Pattern 1: MonoType Operator (same input/output type) ───────────

/**
 * Compose existing operators for simple transforms.
 * This is the preferred approach when no internal state is needed.
 */
function filterGreaterThan(threshold: number): MonoTypeOperatorFunction<number> {
  return (source: Observable<number>) =>
    source.pipe(filter(n => n > threshold));
}

/**
 * Stateful monotype operator using the Observable constructor.
 * Use when you need to maintain state across emissions.
 *
 * Example: emit only when value changes by more than `delta`.
 */
function distinctByDelta<T extends number>(delta: number): MonoTypeOperatorFunction<T> {
  return (source: Observable<T>): Observable<T> =>
    new Observable<T>((subscriber: Subscriber<T>): TeardownLogic => {
      let lastEmitted: T | undefined;

      const subscription = source.subscribe({
        next(value: T) {
          if (lastEmitted === undefined || Math.abs(value - lastEmitted) >= delta) {
            lastEmitted = value;
            subscriber.next(value);
          }
        },
        error(err: unknown) {
          subscriber.error(err);
        },
        complete() {
          subscriber.complete();
        },
      });

      // Return teardown logic
      return () => subscription.unsubscribe();
    });
}

// ─── Pattern 2: Type-Changing Operator (T → R) ──────────────────────

/**
 * Compose existing operators for type-changing transforms.
 */
function pluckField<T, K extends keyof T>(key: K): OperatorFunction<T, T[K]> {
  return (source: Observable<T>) =>
    source.pipe(map(obj => obj[key]));
}

/**
 * Stateful type-changing operator.
 *
 * Example: collect emissions into arrays of size `n` (like bufferCount
 * but as a standalone example).
 */
function collectIntoChunks<T>(size: number): OperatorFunction<T, T[]> {
  return (source: Observable<T>): Observable<T[]> =>
    new Observable<T[]>((subscriber: Subscriber<T[]>): TeardownLogic => {
      let buffer: T[] = [];

      const subscription = source.subscribe({
        next(value: T) {
          buffer.push(value);
          if (buffer.length >= size) {
            subscriber.next(buffer);
            buffer = [];
          }
        },
        error(err: unknown) {
          subscriber.error(err);
        },
        complete() {
          // Emit remaining items on complete
          if (buffer.length > 0) {
            subscriber.next(buffer);
          }
          subscriber.complete();
        },
      });

      return () => subscription.unsubscribe();
    });
}

// ─── Pattern 3: Generic Operator with Configurable Behavior ──────────

interface RetryWithDelayConfig {
  count: number;
  delayMs: number;
  shouldRetry?: (error: unknown) => boolean;
  onRetry?: (error: unknown, attempt: number) => void;
}

/**
 * Generic operator with configuration object.
 * Demonstrates a production-quality operator pattern.
 */
function retryWithDelay<T>(config: RetryWithDelayConfig): MonoTypeOperatorFunction<T> {
  const {
    count,
    delayMs,
    shouldRetry = () => true,
    onRetry = () => {},
  } = config;

  return (source: Observable<T>): Observable<T> =>
    new Observable<T>((subscriber: Subscriber<T>): TeardownLogic => {
      let attempt = 0;
      let activeTimeout: ReturnType<typeof setTimeout> | null = null;
      let activeSubscription: { unsubscribe(): void } | null = null;

      function subscribe() {
        activeSubscription = source.subscribe({
          next(value: T) {
            subscriber.next(value);
          },
          error(err: unknown) {
            if (attempt < count && shouldRetry(err)) {
              attempt++;
              onRetry(err, attempt);
              activeTimeout = setTimeout(() => subscribe(), delayMs * attempt);
            } else {
              subscriber.error(err);
            }
          },
          complete() {
            subscriber.complete();
          },
        });
      }

      subscribe();

      return () => {
        activeSubscription?.unsubscribe();
        if (activeTimeout) clearTimeout(activeTimeout);
      };
    });
}

// ─── Usage Examples ──────────────────────────────────────────────────

export {
  filterGreaterThan,
  distinctByDelta,
  pluckField,
  collectIntoChunks,
  retryWithDelay,
};

// Example usage:
//
// import { of, interval } from 'rxjs';
// import { take } from 'rxjs';
// import { filterGreaterThan, distinctByDelta, pluckField, collectIntoChunks } from './custom-operator';
//
// // MonoType
// of(1, 5, 3, 8, 2).pipe(filterGreaterThan(4)).subscribe(console.log);
// // Output: 5, 8
//
// // Stateful MonoType
// of(1, 1.5, 4, 4.3, 7).pipe(distinctByDelta(2)).subscribe(console.log);
// // Output: 1, 4, 7
//
// // Type-changing
// of({ name: 'Alice', age: 30 }, { name: 'Bob', age: 25 })
//   .pipe(pluckField('name'))
//   .subscribe(console.log);
// // Output: 'Alice', 'Bob'
//
// // Chunking
// interval(100).pipe(take(7), collectIntoChunks(3)).subscribe(console.log);
// // Output: [0,1,2], [3,4,5], [6]
