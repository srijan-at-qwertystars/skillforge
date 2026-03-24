#!/usr/bin/env bash
# init-rxjs-project.sh — Set up a new RxJS playground project
#
# Usage:
#   ./init-rxjs-project.sh [project-name]
#
# Creates a directory with npm, TypeScript, RxJS, and ts-node configured.
# Includes a starter file with common imports and an example observable.
#
# Examples:
#   ./init-rxjs-project.sh my-rxjs-playground
#   ./init-rxjs-project.sh                    # defaults to "rxjs-playground"

set -euo pipefail

PROJECT_NAME="${1:-rxjs-playground}"

if [ -d "$PROJECT_NAME" ]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

echo "🚀 Creating RxJS playground: $PROJECT_NAME"

mkdir -p "$PROJECT_NAME"
cd "$PROJECT_NAME"

# Initialize npm
echo "📦 Initializing npm project..."
npm init -y --quiet 2>/dev/null

# Install dependencies
echo "📥 Installing rxjs, typescript, ts-node..."
npm install --save rxjs 2>/dev/null
npm install --save-dev typescript ts-node @types/node 2>/dev/null

# Create tsconfig.json
echo "⚙️  Creating tsconfig.json..."
cat > tsconfig.json << 'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "lib": ["ES2020"],
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
TSCONFIG

# Create source directory
mkdir -p src

# Create starter file
echo "📝 Creating starter file..."
cat > src/index.ts << 'STARTER'
/**
 * RxJS Playground — Starter File
 *
 * Run with:  npx ts-node src/index.ts
 */

import {
  // Creation
  of, from, interval, timer, defer, EMPTY, throwError,
  // Combination
  combineLatest, merge, concat, forkJoin, zip,
  // Subjects
  Subject, BehaviorSubject, ReplaySubject, AsyncSubject,
  // Types
  Observable, OperatorFunction, MonoTypeOperatorFunction,
  // Utilities
  firstValueFrom, lastValueFrom,
} from 'rxjs';

import {
  map, filter, tap, take, takeUntil, skip, first, last,
  switchMap, mergeMap, concatMap, exhaustMap,
  debounceTime, throttleTime, distinctUntilChanged,
  catchError, retry, finalize,
  scan, reduce,
  share, shareReplay,
  delay, delayWhen,
  bufferTime, bufferCount,
  withLatestFrom,
  startWith,
} from 'rxjs';

// ─── Example 1: Basic Observable Pipeline ──────────────────

console.log('=== Example 1: Basic Pipeline ===');

of(1, 2, 3, 4, 5).pipe(
  filter(n => n % 2 === 1),
  map(n => n * 10),
  tap(n => console.log(`  Emitting: ${n}`)),
  take(2)
).subscribe({
  next: val => console.log(`  Received: ${val}`),
  complete: () => console.log('  Complete!\n'),
});

// ─── Example 2: Timer with Scan ────────────────────────────

console.log('=== Example 2: Timer with Accumulator ===');

interval(500).pipe(
  scan((acc, val) => acc + val, 0),
  take(5),
  tap(sum => console.log(`  Running sum: ${sum}`))
).subscribe({
  complete: () => console.log('  Complete!\n'),
});

// ─── Example 3: Error Handling ─────────────────────────────

setTimeout(() => {
  console.log('=== Example 3: Error Recovery ===');

  const unreliable$ = new Observable<number>(subscriber => {
    subscriber.next(1);
    subscriber.next(2);
    subscriber.error(new Error('Something broke!'));
  });

  unreliable$.pipe(
    catchError(err => {
      console.log(`  Caught error: ${err.message}`);
      return of(-1); // fallback value
    })
  ).subscribe({
    next: val => console.log(`  Value: ${val}`),
    complete: () => console.log('  Recovered and complete!\n'),
  });
}, 3000);

// ─── Example 4: Subject Multicasting ──────────────────────

setTimeout(() => {
  console.log('=== Example 4: BehaviorSubject ===');

  const state$ = new BehaviorSubject<string>('initial');

  state$.subscribe(val => console.log(`  Subscriber A: ${val}`));
  state$.next('updated');
  state$.subscribe(val => console.log(`  Subscriber B: ${val}`));
  state$.next('final');
  state$.complete();

  console.log('  Complete!\n');
  console.log('🎉 Playground ready. Edit src/index.ts and run: npx ts-node src/index.ts');
}, 4000);
STARTER

# Add run script to package.json
npx --yes json -I -f package.json -e 'this.scripts.start="ts-node src/index.ts"' 2>/dev/null || \
  node -e "
    const pkg = require('./package.json');
    pkg.scripts = pkg.scripts || {};
    pkg.scripts.start = 'ts-node src/index.ts';
    require('fs').writeFileSync('package.json', JSON.stringify(pkg, null, 2));
  "

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "   cd $PROJECT_NAME"
echo "   npm start              # Run the starter example"
echo "   npx ts-node src/index.ts  # Same thing"
echo ""
echo "   Edit src/index.ts to experiment with RxJS operators."
