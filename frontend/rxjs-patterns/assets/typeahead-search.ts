/**
 * Complete Typeahead Search Implementation
 *
 * Features:
 *   - Debounced input (configurable delay)
 *   - distinctUntilChanged to skip redundant searches
 *   - Minimum query length filter
 *   - switchMap for automatic request cancellation
 *   - Loading state tracking
 *   - Error handling with retry
 *   - Empty state handling
 *   - Keyboard navigation support (signals for selected index)
 *   - Highlight matching text utility
 *
 * Works as:
 *   1. Standalone RxJS (no framework)
 *   2. Angular component (uncomment Angular section)
 */

import {
  Observable,
  BehaviorSubject,
  Subject,
  of,
  EMPTY,
  fromEvent,
  merge,
  combineLatest,
} from 'rxjs';
import {
  debounceTime,
  distinctUntilChanged,
  switchMap,
  map,
  filter,
  tap,
  catchError,
  startWith,
  takeUntil,
  share,
  finalize,
  retry,
} from 'rxjs';

// ─── Types ──────────────────────────────────────────────────

export interface TypeaheadConfig<T> {
  /** Function that performs the search API call */
  searchFn: (query: string) => Observable<T[]>;

  /** Debounce delay in ms (default: 300) */
  debounceMs?: number;

  /** Minimum characters before searching (default: 2) */
  minLength?: number;

  /** Maximum results to display (default: 10) */
  maxResults?: number;

  /** Retry count for failed requests (default: 1) */
  retryCount?: number;
}

export interface TypeaheadState<T> {
  results: T[];
  loading: boolean;
  error: string | null;
  query: string;
  isOpen: boolean;
  selectedIndex: number;
}

// ─── Core Typeahead Logic (Framework-Agnostic) ──────────────

export class Typeahead<T> {
  private readonly config: Required<TypeaheadConfig<T>>;
  private readonly querySubject$ = new BehaviorSubject<string>('');
  private readonly destroy$ = new Subject<void>();

  private readonly stateSubject$ = new BehaviorSubject<TypeaheadState<T>>({
    results: [],
    loading: false,
    error: null,
    query: '',
    isOpen: false,
    selectedIndex: -1,
  });

  // ── Public Observables ──

  readonly state$ = this.stateSubject$.asObservable();
  readonly results$ = this.state$.pipe(map(s => s.results), distinctUntilChanged());
  readonly loading$ = this.state$.pipe(map(s => s.loading), distinctUntilChanged());
  readonly error$ = this.state$.pipe(map(s => s.error), distinctUntilChanged());
  readonly isOpen$ = this.state$.pipe(map(s => s.isOpen), distinctUntilChanged());
  readonly selectedIndex$ = this.state$.pipe(map(s => s.selectedIndex), distinctUntilChanged());

  readonly selectedItem$: Observable<T | null> = this.state$.pipe(
    map(s => s.selectedIndex >= 0 ? s.results[s.selectedIndex] ?? null : null),
    distinctUntilChanged()
  );

  constructor(config: TypeaheadConfig<T>) {
    this.config = {
      debounceMs: 300,
      minLength: 2,
      maxResults: 10,
      retryCount: 1,
      ...config,
    };

    this.setupSearchPipeline();
  }

  // ── Public Methods ──

  /** Update the search query (call on each input change) */
  setQuery(query: string): void {
    this.querySubject$.next(query);
    this.patchState({ query, selectedIndex: -1 });
  }

  /** Select an item by index */
  selectIndex(index: number): void {
    const { results } = this.stateSubject$.getValue();
    if (index >= -1 && index < results.length) {
      this.patchState({ selectedIndex: index });
    }
  }

  /** Move selection up */
  moveUp(): void {
    const { selectedIndex } = this.stateSubject$.getValue();
    this.selectIndex(Math.max(-1, selectedIndex - 1));
  }

  /** Move selection down */
  moveDown(): void {
    const { selectedIndex, results } = this.stateSubject$.getValue();
    this.selectIndex(Math.min(results.length - 1, selectedIndex + 1));
  }

  /** Get the currently selected item (synchronous) */
  getSelectedItem(): T | null {
    const { selectedIndex, results } = this.stateSubject$.getValue();
    return selectedIndex >= 0 ? results[selectedIndex] ?? null : null;
  }

  /** Open the dropdown */
  open(): void {
    this.patchState({ isOpen: true });
  }

  /** Close the dropdown */
  close(): void {
    this.patchState({ isOpen: false, selectedIndex: -1 });
  }

  /** Clear everything */
  clear(): void {
    this.querySubject$.next('');
    this.patchState({
      results: [],
      query: '',
      loading: false,
      error: null,
      isOpen: false,
      selectedIndex: -1,
    });
  }

  /** Destroy and clean up */
  destroy(): void {
    this.destroy$.next();
    this.destroy$.complete();
  }

  // ── Private ──

  private setupSearchPipeline(): void {
    this.querySubject$.pipe(
      debounceTime(this.config.debounceMs),
      distinctUntilChanged(),
      tap(query => {
        if (query.length < this.config.minLength) {
          this.patchState({ results: [], loading: false, error: null, isOpen: false });
        }
      }),
      filter(query => query.length >= this.config.minLength),
      tap(() => this.patchState({ loading: true, error: null })),
      switchMap(query =>
        this.config.searchFn(query).pipe(
          retry(this.config.retryCount),
          map(results => results.slice(0, this.config.maxResults)),
          tap(results => {
            this.patchState({
              results,
              loading: false,
              error: null,
              isOpen: results.length > 0,
              selectedIndex: -1,
            });
          }),
          catchError(err => {
            const message = err instanceof Error ? err.message : 'Search failed';
            this.patchState({
              results: [],
              loading: false,
              error: message,
              isOpen: false,
            });
            return EMPTY;
          })
        )
      ),
      takeUntil(this.destroy$)
    ).subscribe();
  }

  private patchState(patch: Partial<TypeaheadState<T>>): void {
    this.stateSubject$.next({
      ...this.stateSubject$.getValue(),
      ...patch,
    });
  }
}

// ─── Utility: Highlight Matching Text ───────────────────────

/**
 * Wraps matching portions of text in <mark> tags for highlighting.
 *
 * Usage:
 *   highlightMatch('John Doe', 'john') → 'John Doe' with 'John' wrapped
 */
export function highlightMatch(text: string, query: string): string {
  if (!query || !text) return text;
  const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const regex = new RegExp(`(${escaped})`, 'gi');
  return text.replace(regex, '<mark>$1</mark>');
}

// ─── Standalone Usage Example ───────────────────────────────
//
// const searchApi = (query: string): Observable<string[]> =>
//   of(['Apple', 'Application', 'Appetite'].filter(s =>
//     s.toLowerCase().includes(query.toLowerCase())
//   )).pipe(delay(200));
//
// const typeahead = new Typeahead<string>({
//   searchFn: searchApi,
//   debounceMs: 300,
//   minLength: 1,
// });
//
// typeahead.results$.subscribe(results => console.log('Results:', results));
// typeahead.loading$.subscribe(loading => console.log('Loading:', loading));
//
// typeahead.setQuery('app');
// // After 300ms debounce → Results: ['Apple', 'Application', 'Appetite']
//
// typeahead.destroy();

// ─── Angular Component Example ──────────────────────────────
//
// @Component({
//   selector: 'app-typeahead',
//   template: `
//     <div class="typeahead-container">
//       <input
//         type="text"
//         [value]="(typeahead.state$ | async)?.query"
//         (input)="typeahead.setQuery($any($event.target).value)"
//         (focus)="typeahead.open()"
//         (keydown.arrowDown)="typeahead.moveDown(); $event.preventDefault()"
//         (keydown.arrowUp)="typeahead.moveUp(); $event.preventDefault()"
//         (keydown.enter)="onSelect()"
//         (keydown.escape)="typeahead.close()"
//         placeholder="Search..."
//       />
//
//       <div *ngIf="typeahead.loading$ | async" class="loading">
//         Searching...
//       </div>
//
//       <div *ngIf="typeahead.error$ | async as error" class="error">
//         {{ error }}
//       </div>
//
//       <ul *ngIf="typeahead.isOpen$ | async" class="results">
//         <li
//           *ngFor="let item of typeahead.results$ | async; let i = index"
//           [class.selected]="i === (typeahead.selectedIndex$ | async)"
//           (click)="selectItem(item)"
//           (mouseenter)="typeahead.selectIndex(i)"
//           [innerHTML]="highlightMatch(item.name, (typeahead.state$ | async)?.query || '')"
//         ></li>
//       </ul>
//     </div>
//   `,
//   changeDetection: ChangeDetectionStrategy.OnPush
// })
// class TypeaheadComponent implements OnInit, OnDestroy {
//   typeahead!: Typeahead<SearchResult>;
//   highlightMatch = highlightMatch;
//
//   constructor(private searchService: SearchService) {}
//
//   ngOnInit() {
//     this.typeahead = new Typeahead<SearchResult>({
//       searchFn: query => this.searchService.search(query),
//       debounceMs: 300,
//       minLength: 2,
//       maxResults: 8,
//     });
//   }
//
//   onSelect() {
//     const item = this.typeahead.getSelectedItem();
//     if (item) this.selectItem(item);
//   }
//
//   selectItem(item: SearchResult) {
//     console.log('Selected:', item);
//     this.typeahead.close();
//   }
//
//   ngOnDestroy() {
//     this.typeahead.destroy();
//   }
// }
