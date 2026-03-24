#!/usr/bin/env bash
# operator-finder.sh — Interactive RxJS operator suggestion tool
#
# Usage:
#   ./operator-finder.sh                    # Interactive mode
#   ./operator-finder.sh "combine streams"  # Direct query
#   ./operator-finder.sh --list             # List all categories
#
# Describes what you want to do, and the script suggests the right
# RxJS operators with usage examples.

set -euo pipefail

# ─── Operator Database ───────────────────────────────────────

suggest() {
  local category="$1"
  local operators="$2"
  local description="$3"
  local example="$4"

  echo ""
  echo "  📦 Category: $category"
  echo "  🔧 Operators: $operators"
  echo "  📝 $description"
  echo ""
  echo "  Example:"
  echo "$example" | sed 's/^/    /'
  echo ""
  echo "  ─────────────────────────────────────────"
}

find_operators() {
  local query
  query=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  local found=0

  # --- Combination patterns ---
  if echo "$query" | grep -qE "combine|latest|merge.*stream|join.*stream|multiple.*stream|parallel.*observable"; then
    found=1
    suggest "Combine Latest Values" "combineLatest, combineLatestWith" \
      "Emit latest value from each source whenever ANY source emits. All sources must emit at least once." \
'combineLatest([stream1$, stream2$]).pipe(
  map(([a, b]) => a + b)
);
// or inside pipe:
stream1$.pipe(combineLatestWith(stream2$));'

    suggest "Merge (Interleave)" "merge, mergeWith" \
      "Interleave emissions from multiple sources into a single stream." \
'merge(clicks$, keypresses$, touches$);
// or inside pipe:
clicks$.pipe(mergeWith(keypresses$));'

    suggest "Fork Join (Parallel, Wait All)" "forkJoin" \
      "Run observables in parallel, emit array of final values when ALL complete. Like Promise.all()." \
'forkJoin({
  users: this.http.get("/api/users"),
  config: this.http.get("/api/config")
}).subscribe(({ users, config }) => { /* ... */ });'
  fi

  if echo "$query" | grep -qE "sequen|concat|order|one.*after|queue|serial"; then
    found=1
    suggest "Sequential (Concat)" "concat, concatWith, concatMap" \
      "Subscribe to observables one after another. Next starts only when previous completes." \
'// Static:
concat(init$, loadData$, cleanup$);

// As higher-order mapping (queue inner observables):
saveQueue$.pipe(
  concatMap(item => this.api.save(item))  // strict order
);'
  fi

  if echo "$query" | grep -qE "zip|pair|index|match.*by.*position"; then
    found=1
    suggest "Zip (Pair by Index)" "zip, zipWith" \
      "Combine emissions by index. Waits for each source to emit before pairing." \
'zip(names$, scores$).pipe(
  map(([name, score]) => ({ name, score }))
);'
  fi

  if echo "$query" | grep -qE "race|first.*emit|fastest|fallback"; then
    found=1
    suggest "Race (First to Emit)" "race, raceWith" \
      "Use whichever observable emits first. Unsubscribe from losers." \
'race(primaryApi$, timer(5000).pipe(switchMap(() => fallbackApi$)));'
  fi

  # --- Transformation patterns ---
  if echo "$query" | grep -qE "transform|map|convert|change.*value|modify"; then
    found=1
    suggest "Transform Values" "map, scan, reduce" \
      "Transform each emitted value." \
'// map: 1-to-1 transform
source$.pipe(map(x => x * 2));

// scan: running accumulator (emits each step)
clicks$.pipe(scan(count => count + 1, 0));

// reduce: final accumulated value (on complete)
source$.pipe(reduce((acc, val) => acc + val, 0));'
  fi

  if echo "$query" | grep -qE "flatten|inner.*observable|higher.*order|switch|cancel.*previous|latest.*wins"; then
    found=1
    suggest "Flatten (Latest Wins)" "switchMap" \
      "Map to inner observable, cancel previous. Use for typeahead, route changes." \
'searchTerm$.pipe(
  switchMap(term => this.api.search(term))
);'

    suggest "Flatten (All Concurrent)" "mergeMap" \
      "Map to inner observable, run all concurrently. Use for fire-and-forget." \
'clicks$.pipe(
  mergeMap(click => this.api.track(click), 5)  // max 5 concurrent
);'

    suggest "Flatten (Sequential)" "concatMap" \
      "Map to inner observable, queue and run in order." \
'queue$.pipe(concatMap(item => processItem(item)));'

    suggest "Flatten (Ignore While Active)" "exhaustMap" \
      "Ignore new emissions while inner observable is active. Prevents double-submit." \
'submitBtn$.pipe(exhaustMap(() => this.api.submit(formData)));'
  fi

  # --- Filtering patterns ---
  if echo "$query" | grep -qE "debounce|wait.*stop|pause.*typing|silence|idle"; then
    found=1
    suggest "Debounce" "debounceTime, debounce" \
      "Wait for silence before emitting. Use for search input, resize events." \
'input$.pipe(
  debounceTime(300),           // wait 300ms of no activity
  distinctUntilChanged(),       // skip if same value
  switchMap(term => search(term))
);'
  fi

  if echo "$query" | grep -qE "throttle|rate.*limit|at.*most|slow.*down"; then
    found=1
    suggest "Throttle / Rate Limit" "throttleTime, auditTime, sampleTime" \
      "Limit emission rate." \
'// throttleTime: emit first, then ignore for duration
scroll$.pipe(throttleTime(100));

// auditTime: wait for duration, emit LAST value
mousemove$.pipe(auditTime(100));

// sampleTime: emit latest at regular intervals
data$.pipe(sampleTime(1000));'
  fi

  if echo "$query" | grep -qE "distinct|duplicate|unique|skip.*same|changed"; then
    found=1
    suggest "Skip Duplicates" "distinctUntilChanged, distinctUntilKeyChanged, distinct" \
      "Skip consecutive duplicate emissions." \
'// Default: reference equality
source$.pipe(distinctUntilChanged());

// Custom comparator
source$.pipe(distinctUntilChanged((a, b) => a.id === b.id));

// By key
source$.pipe(distinctUntilKeyChanged("name"));'
  fi

  if echo "$query" | grep -qE "filter|only.*if|exclude|predicate|condition"; then
    found=1
    suggest "Filter Values" "filter, first, last, take, skip, takeWhile, skipWhile" \
      "Emit only values matching a condition." \
'source$.pipe(filter(x => x > 10));
source$.pipe(first());              // first value, then complete
source$.pipe(take(5));              // first 5, then complete
source$.pipe(skip(2));              // skip first 2
source$.pipe(takeWhile(x => x < 100));  // until condition fails'
  fi

  # --- Error handling ---
  if echo "$query" | grep -qE "error|catch|retry|recover|fail|fallback|backoff"; then
    found=1
    suggest "Error Recovery" "catchError, retry, retryWhen, throwError, EMPTY" \
      "Handle and recover from errors in the stream." \
'// Catch and provide fallback
source$.pipe(catchError(err => of(fallbackValue)));

// Retry N times
source$.pipe(retry(3));

// Retry with exponential backoff
source$.pipe(retry({
  count: 4,
  delay: (err, attempt) => timer(Math.pow(2, attempt) * 1000)
}));

// Catch and complete silently
source$.pipe(catchError(() => EMPTY));'
  fi

  # --- Timing ---
  if echo "$query" | grep -qE "delay|wait|timeout|after.*time|slow"; then
    found=1
    suggest "Delay & Timing" "delay, delayWhen, timeout, timer" \
      "Add delays or enforce timeouts." \
'// Delay all emissions
source$.pipe(delay(1000));

// Delay based on value
source$.pipe(delayWhen(val => timer(val.priority * 100)));

// Timeout: error if no emission within duration
source$.pipe(timeout(5000));

// Timer: emit after delay
timer(2000);              // emit 0 after 2s
timer(0, 1000);           // emit 0 immediately, then every 1s'
  fi

  # --- Creation ---
  if echo "$query" | grep -qE "create|from.*array|from.*promise|from.*event|emit|generate|interval|timer"; then
    found=1
    suggest "Create Observables" "of, from, interval, timer, fromEvent, defer, EMPTY" \
      "Create observables from various sources." \
'of(1, 2, 3);                      // emit values
from([1, 2, 3]);                   // from iterable
from(fetch("/api"));               // from Promise
interval(1000);                    // emit 0,1,2... every 1s
timer(2000, 1000);                 // delay 2s, then every 1s
fromEvent(element, "click");       // DOM events
defer(() => from(fetch("/api")));  // lazy creation per subscriber'
  fi

  # --- Multicasting ---
  if echo "$query" | grep -qE "share|multicast|cache|replay|hot|cold.*to.*hot|single.*subscription|broadcast"; then
    found=1
    suggest "Share / Multicast" "share, shareReplay, Subject, BehaviorSubject, ReplaySubject" \
      "Share a single subscription among multiple subscribers." \
'// share: refcounted multicast
const shared$ = source$.pipe(share());

// shareReplay: cache for late subscribers (ALWAYS use refCount: true)
const cached$ = source$.pipe(
  shareReplay({ bufferSize: 1, refCount: true })
);

// BehaviorSubject: current value + multicast
const state$ = new BehaviorSubject(initialValue);'
  fi

  # --- Batching ---
  if echo "$query" | grep -qE "batch|buffer|collect|group|chunk|window|accumulate.*array"; then
    found=1
    suggest "Batch / Buffer" "bufferTime, bufferCount, buffer, windowTime, windowCount" \
      "Collect emissions into arrays or sub-observables." \
'// Collect into arrays by time
source$.pipe(bufferTime(1000));  // emit array every 1s

// Collect by count
source$.pipe(bufferCount(10));   // emit array of 10

// Both: flush at 1s OR 100 items
source$.pipe(bufferTime(1000, null, 100));

// window: like buffer but emits inner Observables
source$.pipe(
  windowTime(5000),
  mergeMap(win$ => win$.pipe(take(3)))  // max 3 per window
);'
  fi

  # --- Unsubscribe / Cleanup ---
  if echo "$query" | grep -qE "unsubscribe|cleanup|destroy|stop|cancel|complete|takeuntil|memory.*leak"; then
    found=1
    suggest "Unsubscribe / Cleanup" "takeUntil, take, first, finalize, Subscription" \
      "Automatically unsubscribe and clean up resources." \
'// takeUntil: complete when signal emits (Angular pattern)
source$.pipe(takeUntil(this.destroy$));

// take: complete after N values
source$.pipe(take(1));

// takeUntilDestroyed (Angular 16+):
source$.pipe(takeUntilDestroyed());

// finalize: run cleanup on unsubscribe
source$.pipe(finalize(() => console.log("cleaned up")));'
  fi

  # --- Pagination / Recursion ---
  if echo "$query" | grep -qE "pagina|recursive|expand|tree|traverse|next.*page|cursor|infinite.*scroll"; then
    found=1
    suggest "Pagination / Recursion" "expand" \
      "Recursively project each value. Great for paginated APIs and tree traversal." \
'// Paginated API
this.http.get(firstPageUrl).pipe(
  expand(response =>
    response.nextCursor
      ? this.http.get(url + "?cursor=" + response.nextCursor)
      : EMPTY  // stop recursion
  ),
  map(response => response.data),
  reduce((all, page) => [...all, ...page], [])
);'
  fi

  # --- Side effects ---
  if echo "$query" | grep -qE "side.*effect|log|debug|tap|do|inspect|trace"; then
    found=1
    suggest "Side Effects / Debug" "tap, finalize" \
      "Perform side effects without modifying the stream." \
'source$.pipe(
  tap({
    next: val => console.log("next:", val),
    error: err => console.error("error:", err),
    complete: () => console.log("complete"),
    subscribe: () => console.log("subscribed"),
    unsubscribe: () => console.log("unsubscribed"),
  })
);'
  fi

  if [ "$found" -eq 0 ]; then
    echo ""
    echo "  🤔 No matching pattern found for: '$1'"
    echo ""
    echo "  Try describing what you want to do, e.g.:"
    echo "    - 'combine latest values from multiple streams'"
    echo "    - 'cancel previous request'"
    echo "    - 'retry with backoff'"
    echo "    - 'debounce input'"
    echo "    - 'batch events'"
    echo "    - 'handle errors'"
    echo "    - 'share subscription'"
    echo "    - 'paginate API'"
    echo ""
    echo "  Run with --list to see all categories."
  fi
}

list_categories() {
  echo ""
  echo "  📋 Available operator categories:"
  echo ""
  echo "    combine     — Combine/merge multiple streams"
  echo "    sequential  — Run observables in sequence"
  echo "    zip         — Pair emissions by index"
  echo "    race        — First to emit wins"
  echo "    transform   — Map/transform values"
  echo "    flatten     — Higher-order observable strategies"
  echo "    debounce    — Wait for silence"
  echo "    throttle    — Rate limiting"
  echo "    distinct    — Skip duplicates"
  echo "    filter      — Conditional filtering"
  echo "    error       — Error handling & recovery"
  echo "    delay       — Timing & delays"
  echo "    create      — Create observables from sources"
  echo "    share       — Multicast/cache subscriptions"
  echo "    batch       — Buffer/window emissions"
  echo "    unsubscribe — Cleanup patterns"
  echo "    paginate    — Recursive/pagination patterns"
  echo "    debug       — Side effects & logging"
  echo ""
}

# ─── Main ────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════╗"
echo "║     🔍 RxJS Operator Finder              ║"
echo "╚══════════════════════════════════════════╝"

if [ "${1:-}" = "--list" ]; then
  list_categories
  exit 0
fi

if [ $# -gt 0 ]; then
  find_operators "$*"
  exit 0
fi

# Interactive mode
echo ""
echo "  Describe what you want to do (or type 'list', 'quit'):"
echo ""

while true; do
  printf "  🔎 > "
  read -r input || break

  case "$input" in
    quit|exit|q) echo "  Bye! 👋"; exit 0 ;;
    list|ls) list_categories ;;
    "") continue ;;
    *) find_operators "$input" ;;
  esac
done
