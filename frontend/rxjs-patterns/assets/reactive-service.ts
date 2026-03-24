/**
 * Reactive Angular Service Template
 *
 * BehaviorSubject-based state management with:
 *   - Loading and error states
 *   - CRUD operations returning observables
 *   - Immutable state updates
 *   - Automatic cache invalidation
 *
 * Replace `Item` with your entity type.
 * Replace `/api/items` with your API endpoint.
 */

import { Injectable, inject } from '@angular/core';
import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import {
  BehaviorSubject,
  Observable,
  combineLatest,
  throwError,
  EMPTY,
} from 'rxjs';
import {
  map,
  tap,
  catchError,
  shareReplay,
  distinctUntilChanged,
  switchMap,
  finalize,
  retry,
  take,
} from 'rxjs';

// ─── Types ──────────────────────────────────────────────────

export interface Item {
  id: string;
  name: string;
  // Add your fields here
}

interface ServiceState {
  items: Item[];
  loading: boolean;
  error: string | null;
  selectedId: string | null;
}

const initialState: ServiceState = {
  items: [],
  loading: false,
  error: null,
  selectedId: null,
};

// ─── Service ────────────────────────────────────────────────

@Injectable({ providedIn: 'root' })
export class ItemService {
  private readonly http = inject(HttpClient);
  private readonly apiUrl = '/api/items';

  // ── State ──

  private readonly state$ = new BehaviorSubject<ServiceState>(initialState);

  // ── Selectors (derived observables) ──

  readonly items$ = this.state$.pipe(
    map(s => s.items),
    distinctUntilChanged()
  );

  readonly loading$ = this.state$.pipe(
    map(s => s.loading),
    distinctUntilChanged()
  );

  readonly error$ = this.state$.pipe(
    map(s => s.error),
    distinctUntilChanged()
  );

  readonly selectedItem$ = this.state$.pipe(
    map(s => s.items.find(i => i.id === s.selectedId) ?? null),
    distinctUntilChanged()
  );

  readonly itemCount$ = this.items$.pipe(map(items => items.length));

  // ── State Helpers ──

  private patchState(patch: Partial<ServiceState>): void {
    this.state$.next({ ...this.state$.getValue(), ...patch });
  }

  private setLoading(loading: boolean): void {
    this.patchState({ loading, error: loading ? null : this.state$.getValue().error });
  }

  // ── CRUD Operations ──

  loadItems(): Observable<Item[]> {
    this.setLoading(true);

    return this.http.get<Item[]>(this.apiUrl).pipe(
      retry(2),
      tap(items => this.patchState({ items, loading: false, error: null })),
      catchError(err => this.handleError(err)),
      finalize(() => this.setLoading(false))
    );
  }

  getItemById(id: string): Observable<Item> {
    // Check local cache first
    const cached = this.state$.getValue().items.find(i => i.id === id);
    if (cached) {
      return new Observable(sub => { sub.next(cached); sub.complete(); });
    }

    this.setLoading(true);
    return this.http.get<Item>(`${this.apiUrl}/${id}`).pipe(
      tap(item => {
        const items = this.state$.getValue().items;
        const exists = items.some(i => i.id === item.id);
        this.patchState({
          items: exists ? items.map(i => i.id === item.id ? item : i) : [...items, item],
          loading: false,
        });
      }),
      catchError(err => this.handleError(err)),
      finalize(() => this.setLoading(false))
    );
  }

  createItem(item: Omit<Item, 'id'>): Observable<Item> {
    this.setLoading(true);

    return this.http.post<Item>(this.apiUrl, item).pipe(
      tap(created => {
        this.patchState({
          items: [...this.state$.getValue().items, created],
          loading: false,
          error: null,
        });
      }),
      catchError(err => this.handleError(err)),
      finalize(() => this.setLoading(false))
    );
  }

  updateItem(item: Item): Observable<Item> {
    this.setLoading(true);

    // Optimistic update
    const previousItems = this.state$.getValue().items;
    this.patchState({
      items: previousItems.map(i => i.id === item.id ? item : i),
    });

    return this.http.put<Item>(`${this.apiUrl}/${item.id}`, item).pipe(
      tap(updated => {
        this.patchState({
          items: this.state$.getValue().items.map(i => i.id === updated.id ? updated : i),
          loading: false,
          error: null,
        });
      }),
      catchError(err => {
        // Rollback on error
        this.patchState({ items: previousItems });
        return this.handleError(err);
      }),
      finalize(() => this.setLoading(false))
    );
  }

  deleteItem(id: string): Observable<void> {
    this.setLoading(true);

    // Optimistic delete
    const previousItems = this.state$.getValue().items;
    this.patchState({
      items: previousItems.filter(i => i.id !== id),
    });

    return this.http.delete<void>(`${this.apiUrl}/${id}`).pipe(
      tap(() => this.patchState({ loading: false, error: null })),
      catchError(err => {
        // Rollback on error
        this.patchState({ items: previousItems });
        return this.handleError(err);
      }),
      finalize(() => this.setLoading(false))
    );
  }

  // ── Selection ──

  selectItem(id: string | null): void {
    this.patchState({ selectedId: id });
  }

  // ── Search / Filter ──

  searchItems(query: string): Observable<Item[]> {
    return this.items$.pipe(
      map(items =>
        items.filter(item =>
          item.name.toLowerCase().includes(query.toLowerCase())
        )
      )
    );
  }

  // ── Error Handling ──

  private handleError(error: HttpErrorResponse): Observable<never> {
    const message = error.error?.message
      ?? error.message
      ?? 'An unexpected error occurred';

    this.patchState({ error: message, loading: false });
    console.error('[ItemService]', message, error);
    return throwError(() => new Error(message));
  }

  clearError(): void {
    this.patchState({ error: null });
  }

  // ── Reset ──

  reset(): void {
    this.state$.next(initialState);
  }
}

// ─── Usage Example ──────────────────────────────────────────
//
// @Component({
//   template: `
//     <div *ngIf="loading$ | async" class="spinner">Loading...</div>
//     <div *ngIf="error$ | async as error" class="error">{{ error }}</div>
//
//     <ul>
//       <li *ngFor="let item of items$ | async; trackBy: trackById"
//           [class.selected]="(selectedItem$ | async)?.id === item.id"
//           (click)="itemService.selectItem(item.id)">
//         {{ item.name }}
//       </li>
//     </ul>
//   `,
//   changeDetection: ChangeDetectionStrategy.OnPush
// })
// class ItemListComponent implements OnInit {
//   readonly itemService = inject(ItemService);
//   readonly items$ = this.itemService.items$;
//   readonly loading$ = this.itemService.loading$;
//   readonly error$ = this.itemService.error$;
//   readonly selectedItem$ = this.itemService.selectedItem$;
//
//   ngOnInit() {
//     this.itemService.loadItems().subscribe();
//   }
//
//   trackById(_: number, item: Item): string { return item.id; }
// }
