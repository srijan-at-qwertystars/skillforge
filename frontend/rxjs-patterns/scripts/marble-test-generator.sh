#!/usr/bin/env bash
# marble-test-generator.sh — Generate marble test templates for RxJS operators
#
# Usage:
#   ./marble-test-generator.sh <operator-name> [output-file]
#
# Examples:
#   ./marble-test-generator.sh map
#   ./marble-test-generator.sh switchMap ./src/tests/switch-map.spec.ts
#   ./marble-test-generator.sh debounceTime
#   ./marble-test-generator.sh combineLatest
#
# Generates a TypeScript marble test file with:
#   - TestScheduler setup (Jest/Jasmine compatible)
#   - Input marble diagrams
#   - Expected output marbles
#   - Assertion boilerplate
#
# Supported operators: map, filter, switchMap, mergeMap, concatMap, exhaustMap,
#   debounceTime, throttleTime, distinctUntilChanged, take, skip, delay,
#   catchError, retry, combineLatest, merge, concat, forkJoin, zip,
#   scan, reduce, bufferTime, bufferCount, withLatestFrom, startWith,
#   shareReplay, share, tap, takeUntil, auditTime, sampleTime

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <operator-name> [output-file]"
  echo "Example: $0 switchMap ./switch-map.spec.ts"
  exit 1
fi

OPERATOR="$1"
OUTPUT_FILE="${2:-${OPERATOR}.spec.ts}"

generate_header() {
  cat << 'HEADER'
import { TestScheduler } from 'rxjs/testing';
HEADER
}

generate_imports() {
  local op="$1"
  local imports=""

  case "$op" in
    map)                imports="map" ;;
    filter)             imports="filter" ;;
    switchMap)          imports="switchMap" ;;
    mergeMap)           imports="mergeMap" ;;
    concatMap)          imports="concatMap" ;;
    exhaustMap)         imports="exhaustMap" ;;
    debounceTime)       imports="debounceTime" ;;
    throttleTime)       imports="throttleTime" ;;
    auditTime)          imports="auditTime" ;;
    sampleTime)         imports="sampleTime" ;;
    distinctUntilChanged) imports="distinctUntilChanged" ;;
    take)               imports="take" ;;
    skip)               imports="skip" ;;
    delay)              imports="delay" ;;
    catchError)         imports="catchError, of" ;;
    retry)              imports="retry" ;;
    scan)               imports="scan" ;;
    reduce)             imports="reduce" ;;
    bufferTime)         imports="bufferTime" ;;
    bufferCount)        imports="bufferCount" ;;
    startWith)          imports="startWith" ;;
    tap)                imports="tap" ;;
    takeUntil)          imports="takeUntil" ;;
    withLatestFrom)     imports="withLatestFrom" ;;
    combineLatest)      imports="combineLatest, map" ;;
    merge)              imports="merge" ;;
    concat)             imports="concat" ;;
    forkJoin)           imports="forkJoin" ;;
    zip)                imports="zip, map" ;;
    share)              imports="share" ;;
    shareReplay)        imports="shareReplay" ;;
    *)                  imports="$op" ;;
  esac

  echo "import { $imports } from 'rxjs';"
}

generate_body() {
  local op="$1"

  # Common scheduler setup
  cat << 'SETUP'

describe('OPERATOR_NAME operator', () => {
  let scheduler: TestScheduler;

  beforeEach(() => {
    scheduler = new TestScheduler((actual, expected) => {
      expect(actual).toEqual(expected);
    });
  });

SETUP

  # Operator-specific tests
  case "$op" in

    map)
      cat << 'TEST'
  it('should transform each emitted value', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--|', { a: 1, b: 2, c: 3 });
      const expected =       '--x--y--z--|';
      const values = { x: 10, y: 20, z: 30 };

      const result = source.pipe(map(val => val * 10));
      expectObservable(result).toBe(expected, values);
    });
  });

  it('should handle empty source', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('|');
      const expected =       '|';

      const result = source.pipe(map(val => val * 10));
      expectObservable(result).toBe(expected);
    });
  });

  it('should propagate errors', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--#', { a: 1 }, new Error('fail'));
      const expected =       '--x--#';

      const result = source.pipe(map(val => val * 10));
      expectObservable(result).toBe(expected, { x: 10 }, new Error('fail'));
    });
  });
TEST
      ;;

    filter)
      cat << 'TEST'
  it('should emit only values matching predicate', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--d--|', { a: 1, b: 2, c: 3, d: 4 });
      const expected =       '-----b-----d--|';

      const result = source.pipe(filter(val => val % 2 === 0));
      expectObservable(result).toBe(expected, { b: 2, d: 4 });
    });
  });

  it('should emit nothing if no values match', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--|', { a: 1, b: 3 });
      const expected =       '--------|';

      const result = source.pipe(filter(val => val > 10));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    switchMap)
      cat << 'TEST'
  it('should switch to latest inner observable', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source = cold(' --a------b------|');
      const inner  =       '  ---x--y|';
      const expected =      '-----x---x--y---|';

      const result = source.pipe(
        switchMap(() => cold('---x--y|', { x: 'x', y: 'y' }))
      );
      expectObservable(result).toBe(expected);
    });
  });

  it('should cancel previous inner on new emission', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source = cold(' --a--b----------|');
      const innerA =       '  ----A---|';  // cancelled at b
      const innerB =       '       ----B---|';
      const expected =      '  -----------B---|';

      const result = source.pipe(
        switchMap(val =>
          cold('----x---|', { x: val.toUpperCase() })
        )
      );
      expectObservable(result).toBe(expected, { B: 'B' });
    });
  });
TEST
      ;;

    mergeMap)
      cat << 'TEST'
  it('should merge inner observables concurrently', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source = cold(' --a--b------|');
      const expected =      '----x--yx--y|';

      const result = source.pipe(
        mergeMap(() => cold('--x--y|'))
      );
      expectObservable(result).toBe(expected);
    });
  });

  it('should limit concurrency', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a-b-c---|');
      const expected =       '----a---b---c---|';

      const result = source.pipe(
        mergeMap(val => cold('--x|', { x: val }), 1) // concurrency: 1
      );
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    concatMap)
      cat << 'TEST'
  it('should process inner observables sequentially', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a-b------|');
      const expected =       '----x--yx--y|';

      const result = source.pipe(
        concatMap(() => cold('--x--y|'))
      );
      // b's inner waits for a's inner to complete
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    exhaustMap)
      cat << 'TEST'
  it('should ignore emissions while inner is active', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a-b--------c------|');
      const expected =       '-----x--|-----x--|---|';

      const result = source.pipe(
        exhaustMap(() => cold('---x--|'))
      );
      // b is ignored because a's inner is still active
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    debounceTime)
      cat << 'TEST'
  it('should emit value after silence period', () => {
    scheduler.run(({ cold, expectObservable }) => {
      // Each '-' = 1ms in scheduler.run()
      const source   = cold('-a--bc---d---|');
      const expected =       '----b-----d--|';
      // Note: exact timing depends on debounce duration.
      // Adjust the expected marble to match your debounceTime value.

      const result = source.pipe(debounceTime(2));
      expectObservable(result).toBe(expected);
    });
  });

  it('should complete even if no values pass debounce', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('---|');
      const expected =       '---|';

      const result = source.pipe(debounceTime(10));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    throttleTime)
      cat << 'TEST'
  it('should emit first value then throttle', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('-abcdef---|');
      const expected =       '-a---d----|';
      // throttleTime(3): emit a, skip b/c/d (within 3ms), emit d, skip e/f

      const result = source.pipe(throttleTime(3));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    distinctUntilChanged)
      cat << 'TEST'
  it('should skip consecutive duplicates', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--a--b--b--a--|', { a: 1, b: 2 });
      const expected =       '--a-----b-----a--|';

      const result = source.pipe(distinctUntilChanged());
      expectObservable(result).toBe(expected, { a: 1, b: 2 });
    });
  });

  it('should use custom comparator', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--|', {
        a: { id: 1, v: 'x' },
        b: { id: 1, v: 'y' },
        c: { id: 2, v: 'z' }
      });
      const expected =       '--a-----c--|';

      const result = source.pipe(
        distinctUntilChanged((prev, curr) => prev.id === curr.id)
      );
      expectObservable(result).toBe(expected, {
        a: { id: 1, v: 'x' },
        c: { id: 2, v: 'z' }
      });
    });
  });
TEST
      ;;

    take)
      cat << 'TEST'
  it('should take first N values then complete', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--d--e--|');
      const expected =       '--a--b--(c|)';

      const result = source.pipe(take(3));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    skip)
      cat << 'TEST'
  it('should skip first N values', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--d--|');
      const expected =       '--------c--d--|';

      const result = source.pipe(skip(2));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    catchError)
      cat << 'TEST'
  it('should catch error and replace with fallback', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--#', { a: 1, b: 2 }, new Error('fail'));
      const expected =       '--a--b--(c|)';

      const result = source.pipe(
        catchError(() => of(0))
      );
      expectObservable(result).toBe(expected, { a: 1, b: 2, c: 0 });
    });
  });

  it('should rethrow error', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--#', { a: 1 }, new Error('original'));
      const expected =       '--a--#';

      const result = source.pipe(
        catchError(err => { throw new Error('wrapped: ' + err.message); })
      );
      expectObservable(result).toBe(expected, { a: 1 }, new Error('wrapped: original'));
    });
  });
TEST
      ;;

    retry)
      cat << 'TEST'
  it('should retry on error', () => {
    scheduler.run(({ cold, expectObservable }) => {
      // retry(1) means: try once, then retry once = 2 total attempts
      const source   = cold('--a--#');
      const expected =       '--a----a--#';

      const result = source.pipe(retry(1));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    scan)
      cat << 'TEST'
  it('should accumulate values', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--|', { a: 1, b: 2, c: 3 });
      const expected =       '--x--y--z--|';

      const result = source.pipe(scan((acc, val) => acc + val, 0));
      expectObservable(result).toBe(expected, { x: 1, y: 3, z: 6 });
    });
  });
TEST
      ;;

    reduce)
      cat << 'TEST'
  it('should emit final accumulated value on complete', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--|', { a: 1, b: 2, c: 3 });
      const expected =       '-----------(x|)';

      const result = source.pipe(reduce((acc, val) => acc + val, 0));
      expectObservable(result).toBe(expected, { x: 6 });
    });
  });
TEST
      ;;

    combineLatest)
      cat << 'TEST'
  it('should emit when any source emits after all have emitted', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const a$       = cold('--a------c--|');
      const b$       = cold('-----b--------|');
      const expected =       '-----x---y--|';
      // x = [a,b], y = [c,b]

      const result = combineLatest([a$, b$]).pipe(
        map(([a, b]) => a + b)
      );
      expectObservable(result).toBe(expected, { x: 'ab', y: 'cb' });
    });
  });
TEST
      ;;

    merge)
      cat << 'TEST'
  it('should interleave emissions from sources', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const a$       = cold('--a-----c--|');
      const b$       = cold('----b--------|');
      const expected =       '--a-b---c--|';

      const result = merge(a$, b$);
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    concat)
      cat << 'TEST'
  it('should subscribe sequentially', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const a$       = cold('--a--|');
      const b$       = cold(     '--b--|');
      const expected =       '--a----b--|';

      const result = concat(a$, b$);
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    forkJoin)
      cat << 'TEST'
  it('should emit array of last values when all complete', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const a$       = cold('--a--b--|');
      const c$       = cold('---c--|');
      const expected =       '--------(x|)';

      const result = forkJoin([a$, c$]);
      expectObservable(result).toBe(expected, { x: ['b', 'c'] });
    });
  });
TEST
      ;;

    zip)
      cat << 'TEST'
  it('should pair emissions by index', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const a$       = cold('--a--b--|');
      const n$       = cold('---1---2---|');
      const expected =       '---x---y---|';

      const result = zip(a$, n$).pipe(
        map(([letter, num]) => letter + num)
      );
      expectObservable(result).toBe(expected, { x: 'a1', y: 'b2' });
    });
  });
TEST
      ;;

    takeUntil)
      cat << 'TEST'
  it('should complete when notifier emits', () => {
    scheduler.run(({ cold, hot, expectObservable }) => {
      const source   = cold('--a--b--c--d--|');
      const notifier = hot(' ---------n|');
      const expected =       '--a--b--c|';

      const result = source.pipe(takeUntil(notifier));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    withLatestFrom)
      cat << 'TEST'
  it('should combine with latest value from other source', () => {
    scheduler.run(({ cold, hot, expectObservable }) => {
      const source = cold('  --a-----b---|');
      const other  = hot('  -x---y----------|');
      const expected =      '--i-----j---|';

      const result = source.pipe(
        withLatestFrom(other),
        map(([a, b]) => a + b)
      );
      expectObservable(result).toBe(expected, { i: 'ax', j: 'by' });
    });
  });
TEST
      ;;

    startWith)
      cat << 'TEST'
  it('should prepend initial value', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--|');
      const expected =       '(x)--a--b--|';
      // Note: parentheses denote synchronous emission

      const result = source.pipe(startWith('init'));
      expectObservable(result).toBe(expected, { x: 'init', a: 'a', b: 'b' });
    });
  });
TEST
      ;;

    bufferTime)
      cat << 'TEST'
  it('should buffer emissions by time', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a-b---c-d--|');
      const expected =       '-----x-----y-(z|)';

      const result = source.pipe(bufferTime(5));
      expectObservable(result).toBe(expected, {
        x: ['a', 'b'],
        y: ['c', 'd'],
        z: []
      });
    });
  });
TEST
      ;;

    bufferCount)
      cat << 'TEST'
  it('should buffer emissions by count', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--d--|');
      const expected =       '--------x------(y|)';

      const result = source.pipe(bufferCount(3));
      // Note: bufferCount also emits remaining on complete
      expectObservable(result).toBe(expected, {
        x: ['a', 'b', 'c'],
        y: ['d']
      });
    });
  });
TEST
      ;;

    auditTime)
      cat << 'TEST'
  it('should emit latest value after each time window', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('-ab--c---d--|');
      const expected =       '----b-----d-|';

      const result = source.pipe(auditTime(3));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    sampleTime)
      cat << 'TEST'
  it('should sample latest value at intervals', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('-a-b-c-d-e-|');
      const expected =       '---b---d---|';

      const result = source.pipe(sampleTime(3));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    tap)
      cat << 'TEST'
  it('should not modify the stream', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--|');
      const expected =       '--a--b--c--|';

      // tap performs side effects; values pass through unchanged
      const sideEffects: string[] = [];
      const result = source.pipe(tap(val => sideEffects.push(val)));
      expectObservable(result).toBe(expected);
    });
  });
TEST
      ;;

    share)
      cat << 'TEST'
  it('should share a single subscription', () => {
    scheduler.run(({ cold, expectObservable }) => {
      let subscriptions = 0;
      const source = cold('--a--b--c--|').pipe(
        tap({ subscribe: () => subscriptions++ }),
        share()
      );

      expectObservable(source).toBe('--a--b--c--|');
      // Note: verifying subscription count requires imperative testing
    });
  });
TEST
      ;;

    shareReplay)
      cat << 'TEST'
  it('should replay last value to late subscribers', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source = cold('--a--b--|').pipe(
        shareReplay({ bufferSize: 1, refCount: true })
      );

      // First subscriber sees all values
      expectObservable(source).toBe('--a--b--|');

      // Note: testing replay behavior requires imperative tests
      // with delayed subscriptions, not marble tests
    });
  });
TEST
      ;;

    *)
      cat << TEST
  it('should apply $op correctly', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--b--c--|');
      const expected =       '--a--b--c--|';  // TODO: adjust expected output

      const result = source.pipe($op(/* TODO: add arguments */));
      expectObservable(result).toBe(expected);
    });
  });

  it('should handle empty source', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('|');
      const expected =       '|';  // TODO: adjust

      const result = source.pipe($op(/* TODO: add arguments */));
      expectObservable(result).toBe(expected);
    });
  });

  it('should propagate errors', () => {
    scheduler.run(({ cold, expectObservable }) => {
      const source   = cold('--a--#', undefined, new Error('fail'));
      const expected =       '--a--#';  // TODO: adjust

      const result = source.pipe($op(/* TODO: add arguments */));
      expectObservable(result).toBe(expected, undefined, new Error('fail'));
    });
  });
TEST
      ;;
  esac

  # Close the describe block
  echo "});"
}

# ─── Main ────────────────────────────────────────────────────

echo "📝 Generating marble test for: $OPERATOR"

{
  generate_header
  generate_imports "$OPERATOR"
  generate_body "$OPERATOR"
} | sed "s/OPERATOR_NAME/$OPERATOR/g" > "$OUTPUT_FILE"

LINES=$(wc -l < "$OUTPUT_FILE")
echo "✅ Created $OUTPUT_FILE ($LINES lines)"
echo ""
echo "   Next steps:"
echo "   1. Review and adjust marble diagrams"
echo "   2. Add edge cases specific to your usage"
echo "   3. Run: npx jest $OUTPUT_FILE"
