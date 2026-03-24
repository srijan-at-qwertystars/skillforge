/**
 * RxJS ↔ Signal Interop Patterns Template
 *
 * Demonstrates all interop functions with practical patterns:
 * toSignal, toObservable, takeUntilDestroyed, outputToObservable, outputFromObservable
 */

import { Component, Injectable, computed, effect, inject, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { ActivatedRoute, Router, NavigationEnd } from '@angular/router';
import {
  toSignal,
  toObservable,
  takeUntilDestroyed,
  outputToObservable,
  outputFromObservable,
} from '@angular/core/rxjs-interop';
import {
  BehaviorSubject,
  Subject,
  Observable,
  of,
  interval,
  combineLatest,
  merge,
  timer,
} from 'rxjs';
import {
  switchMap,
  map,
  filter,
  debounceTime,
  distinctUntilChanged,
  catchError,
  retry,
  shareReplay,
  startWith,
  withLatestFrom,
  take,
  tap,
} from 'rxjs/operators';
import { DestroyRef } from '@angular/core';

// ═══════════════════════════════════════════════════════════════
// Pattern 1: Observable → Signal (toSignal)
// ═══════════════════════════════════════════════════════════════

@Injectable({ providedIn: 'root' })
export class RouteSignalService {
  private route = inject(ActivatedRoute);
  private router = inject(Router);

  // Route params as signals — available synchronously after init
  readonly routeParams = toSignal(this.route.params, { initialValue: {} });
  readonly queryParams = toSignal(this.route.queryParams, { initialValue: {} });

  // Current URL as a signal
  readonly currentUrl = toSignal(
    this.router.events.pipe(
      filter((e): e is NavigationEnd => e instanceof NavigationEnd),
      map(e => e.url),
      startWith(this.router.url),
    ),
    { requireSync: true } // startWith ensures sync emission
  );

  // Derived signal from route param signal
  readonly currentId = computed(() => {
    const params = this.routeParams();
    return params['id'] ? Number(params['id']) : null;
  });
}

// ═══════════════════════════════════════════════════════════════
// Pattern 2: Signal → Observable (toObservable)
// ═══════════════════════════════════════════════════════════════

@Injectable({ providedIn: 'root' })
export class SearchService {
  private http = inject(HttpClient);

  // Signal as the "input"
  readonly query = signal('');
  readonly filters = signal<{ category: string; sort: string }>({
    category: 'all',
    sort: 'name',
  });

  // Convert signals to observables for RxJS pipeline
  readonly results = toSignal(
    combineLatest([
      toObservable(this.query).pipe(debounceTime(300), distinctUntilChanged()),
      toObservable(this.filters).pipe(distinctUntilChanged()),
    ]).pipe(
      switchMap(([q, f]) =>
        q.length < 2
          ? of([])
          : this.http
              .get<SearchResult[]>('/api/search', {
                params: { q, category: f.category, sort: f.sort },
              })
              .pipe(
                retry(2),
                catchError(() => of([]))
              )
      )
    ),
    { initialValue: [] as SearchResult[] }
  );

  // Simple setter methods
  search(q: string) { this.query.set(q); }
  setFilters(f: { category: string; sort: string }) { this.filters.set(f); }
}

interface SearchResult {
  id: string;
  title: string;
  score: number;
}

// ═══════════════════════════════════════════════════════════════
// Pattern 3: Bridging Legacy BehaviorSubject Services
// ═══════════════════════════════════════════════════════════════

@Injectable({ providedIn: 'root' })
export class LegacyAuthService {
  // Existing BehaviorSubject-based API
  private _user$ = new BehaviorSubject<User | null>(null);
  readonly user$ = this._user$.asObservable();

  login(user: User) { this._user$.next(user); }
  logout() { this._user$.next(null); }
}

@Injectable({ providedIn: 'root' })
export class AuthSignalAdapter {
  private legacy = inject(LegacyAuthService);

  // Bridge to signal — requireSync works because BehaviorSubject emits immediately
  readonly user = toSignal(this.legacy.user$, { requireSync: true });
  readonly isLoggedIn = computed(() => this.user() !== null);
  readonly displayName = computed(() => this.user()?.name ?? 'Guest');
}

interface User {
  id: number;
  name: string;
  email: string;
}

// ═══════════════════════════════════════════════════════════════
// Pattern 4: takeUntilDestroyed — Auto-Cleanup
// ═══════════════════════════════════════════════════════════════

@Component({
  selector: 'app-dashboard',
  standalone: true,
  template: `<p>{{ status() }}</p>`,
})
export class DashboardComponent {
  private destroyRef = inject(DestroyRef);
  private http = inject(HttpClient);

  // In field initializer (injection context) — no DestroyRef needed
  readonly status = toSignal(
    interval(30_000).pipe(
      switchMap(() => this.http.get<{ status: string }>('/api/health')),
      map(r => r.status),
      takeUntilDestroyed(), // auto-unsubscribes on component destroy
    ),
    { initialValue: 'checking...' }
  );

  // For subscriptions in ngOnInit (outside injection context):
  ngOnInit() {
    this.http
      .get<Notification[]>('/api/notifications')
      .pipe(takeUntilDestroyed(this.destroyRef)) // pass DestroyRef explicitly
      .subscribe(notifications => {
        console.log('Received', notifications.length, 'notifications');
      });
  }
}

interface Notification {
  id: string;
  message: string;
}

// ═══════════════════════════════════════════════════════════════
// Pattern 5: Output Interop
// ═══════════════════════════════════════════════════════════════

@Component({
  selector: 'app-ticker',
  standalone: true,
  template: `<span>Tick: {{ currentTick() }}</span>`,
})
export class TickerComponent {
  // Observable → Output: expose interval as component output
  tick = outputFromObservable(interval(1000));

  // Internal signal for display
  currentTick = toSignal(interval(1000), { initialValue: 0 });
}

// Parent consuming output as observable:
// @Component({
//   template: `<app-ticker #ticker />`,
// })
// export class ParentComponent {
//   @ViewChild('ticker') tickerRef!: TickerComponent;
//   private destroyRef = inject(DestroyRef);
//
//   ngAfterViewInit() {
//     // Output → Observable
//     const tick$ = outputToObservable(this.tickerRef.tick);
//     tick$.pipe(
//       takeUntilDestroyed(this.destroyRef),
//       filter(t => t % 10 === 0),
//     ).subscribe(t => console.log(`10-second mark: ${t}`));
//   }
// }

// ═══════════════════════════════════════════════════════════════
// Pattern 6: Complex Async Flow — Signal + RxJS Hybrid
// ═══════════════════════════════════════════════════════════════

@Injectable({ providedIn: 'root' })
export class DataSyncService {
  private http = inject(HttpClient);

  // Signal inputs
  readonly selectedId = signal<number | null>(null);
  readonly refreshTrigger = signal(0);

  // RxJS pipeline consuming signal + producing signal
  readonly detail = toSignal(
    combineLatest([
      toObservable(this.selectedId),
      toObservable(this.refreshTrigger),
    ]).pipe(
      filter(([id]) => id !== null),
      switchMap(([id]) =>
        this.http.get<ItemDetail>(`/api/items/${id}`).pipe(
          catchError(err => {
            console.error('Load failed:', err);
            return of(null);
          })
        )
      ),
      shareReplay(1)
    ),
    { initialValue: null as ItemDetail | null }
  );

  readonly isLoading = signal(false);

  select(id: number) { this.selectedId.set(id); }
  refresh() { this.refreshTrigger.update(v => v + 1); }
}

interface ItemDetail {
  id: number;
  name: string;
  description: string;
}

// ═══════════════════════════════════════════════════════════════
// Pattern 7: WebSocket → Signal (Real-Time Data)
// ═══════════════════════════════════════════════════════════════

@Injectable({ providedIn: 'root' })
export class WebSocketSignalService {
  private messages = signal<ChatMessage[]>([]);
  private connectionStatus = signal<'connected' | 'disconnected' | 'error'>('disconnected');

  readonly allMessages = this.messages.asReadonly();
  readonly status = this.connectionStatus.asReadonly();
  readonly unreadCount = computed(() =>
    this.messages().filter(m => !m.read).length
  );

  connect(url: string) {
    const ws$ = new Observable<ChatMessage>(subscriber => {
      const ws = new WebSocket(url);
      ws.onmessage = (e) => subscriber.next(JSON.parse(e.data));
      ws.onerror = (e) => subscriber.error(e);
      ws.onclose = () => subscriber.complete();
      return () => ws.close();
    });

    // Bridge observable to signal
    ws$.pipe(
      tap(() => this.connectionStatus.set('connected')),
      catchError(err => {
        this.connectionStatus.set('error');
        return of();
      }),
    ).subscribe({
      next: (msg) => this.messages.update(msgs => [...msgs, msg]),
      complete: () => this.connectionStatus.set('disconnected'),
    });
  }
}

interface ChatMessage {
  id: string;
  text: string;
  sender: string;
  read: boolean;
  timestamp: number;
}
