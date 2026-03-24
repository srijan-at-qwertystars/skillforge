# Deep RxJS + Angular Integration Patterns

> Production patterns for Angular applications using RxJS. Angular 16+ assumed unless noted.

## Table of Contents

- [Reactive Forms with valueChanges](#reactive-forms-with-valuechanges)
  - [Single Field Validation](#single-field-validation)
  - [Cross-Field Validation](#cross-field-validation)
  - [Form Auto-Save](#form-auto-save)
  - [Dynamic Form from Observable](#dynamic-form-from-observable)
- [Route Parameter Handling](#route-parameter-handling)
  - [Single Param with Data Fetch](#single-param-with-data-fetch)
  - [Multiple Route Params](#multiple-route-params)
  - [Query Param Sync with Form](#query-param-sync-with-form)
  - [Resolver Patterns](#resolver-patterns)
- [HttpClient Interceptors](#httpclient-interceptors)
  - [Auth Token Interceptor](#auth-token-interceptor)
  - [Retry Interceptor](#retry-interceptor)
  - [Cache Interceptor](#cache-interceptor)
  - [Loading Interceptor](#loading-interceptor)
- [NgRx and ComponentStore Patterns](#ngrx-and-componentstore-patterns)
  - [NgRx Effects with RxJS](#ngrx-effects-with-rxjs)
  - [ComponentStore Reactive Patterns](#componentstore-reactive-patterns)
  - [Selector Composition](#selector-composition)
- [Signal Interop](#signal-interop)
  - [toSignal — Observable to Signal](#tosignal--observable-to-signal)
  - [toObservable — Signal to Observable](#toobservable--signal-to-observable)
  - [Mixing Signals and Observables](#mixing-signals-and-observables)
  - [Migration Strategies](#migration-strategies)
- [Async Pipe Best Practices](#async-pipe-best-practices)
  - [Single Subscription Pattern](#single-subscription-pattern)
  - [Multiple Observables in Template](#multiple-observables-in-template)
  - [Loading and Error States](#loading-and-error-states)
- [OnPush Change Detection with Observables](#onpush-change-detection-with-observables)
  - [Immutable Data Patterns](#immutable-data-patterns)
  - [Triggering CD from Observables](#triggering-cd-from-observables)
  - [Performance Optimization](#performance-optimization)

---

## Reactive Forms with valueChanges

### Single Field Validation

```typescript
@Component({
  template: `
    <input [formControl]="email">
    <span *ngIf="emailError$ | async as error">{{ error }}</span>
  `
})
class SignupComponent implements OnInit {
  email = new FormControl('', [Validators.required, Validators.email]);
  emailError$!: Observable<string | null>;

  constructor(private userService: UserService) {}

  ngOnInit() {
    this.emailError$ = this.email.valueChanges.pipe(
      debounceTime(400),
      distinctUntilChanged(),
      filter(email => this.email.valid),  // only check valid emails
      switchMap(email => this.userService.checkEmailAvailable(email).pipe(
        map(available => available ? null : 'Email already taken'),
        catchError(() => of(null))  // fail open on API error
      )),
      startWith(null)
    );
  }
}
```

### Cross-Field Validation

```typescript
@Component({
  template: `
    <form [formGroup]="form">
      <input formControlName="start">
      <input formControlName="end">
      <span *ngIf="dateError$ | async as error">{{ error }}</span>
    </form>
  `
})
class DateRangeComponent implements OnInit {
  form = new FormGroup({
    start: new FormControl<Date | null>(null),
    end: new FormControl<Date | null>(null),
  });

  dateError$!: Observable<string | null>;

  ngOnInit() {
    this.dateError$ = this.form.valueChanges.pipe(
      map(({ start, end }) => {
        if (start && end && start > end) return 'Start must be before end';
        return null;
      }),
      distinctUntilChanged()
    );
  }
}
```

### Form Auto-Save

```typescript
@Component({ /* ... */ })
class EditorComponent implements OnInit {
  form = new FormGroup({
    title: new FormControl(''),
    content: new FormControl(''),
  });

  saveStatus$ = new BehaviorSubject<'idle' | 'saving' | 'saved' | 'error'>('idle');

  private destroy$ = new Subject<void>();

  ngOnInit() {
    this.form.valueChanges.pipe(
      debounceTime(2000),                      // wait 2s of inactivity
      distinctUntilChanged((a, b) => JSON.stringify(a) === JSON.stringify(b)),
      filter(() => this.form.valid),
      tap(() => this.saveStatus$.next('saving')),
      switchMap(value =>
        this.api.save(value).pipe(
          map(() => 'saved' as const),
          catchError(() => of('error' as const))
        )
      ),
      takeUntil(this.destroy$)
    ).subscribe(status => this.saveStatus$.next(status));
  }

  ngOnDestroy() { this.destroy$.next(); this.destroy$.complete(); }
}
```

### Dynamic Form from Observable

```typescript
class DynamicFormComponent implements OnInit {
  form$!: Observable<FormGroup>;

  ngOnInit() {
    this.form$ = this.configService.getFormConfig().pipe(
      map(config => {
        const group: Record<string, FormControl> = {};
        config.fields.forEach(field => {
          group[field.name] = new FormControl(
            field.defaultValue,
            field.required ? Validators.required : []
          );
        });
        return new FormGroup(group);
      }),
      shareReplay({ bufferSize: 1, refCount: true })
    );
  }
}
```

---

## Route Parameter Handling

### Single Param with Data Fetch

```typescript
@Component({
  template: `
    <ng-container *ngIf="item$ | async as item; else loading">
      <h1>{{ item.name }}</h1>
    </ng-container>
    <ng-template #loading>Loading...</ng-template>
  `
})
class ItemDetailComponent {
  item$ = this.route.paramMap.pipe(
    map(params => params.get('id')!),
    distinctUntilChanged(),
    switchMap(id => this.itemService.getItem(id).pipe(
      catchError(err => {
        this.router.navigate(['/404']);
        return EMPTY;
      })
    )),
    shareReplay({ bufferSize: 1, refCount: true })
  );

  constructor(
    private route: ActivatedRoute,
    private itemService: ItemService,
    private router: Router
  ) {}
}
```

### Multiple Route Params

```typescript
class CompareComponent {
  comparison$ = combineLatest([
    this.route.paramMap.pipe(map(p => p.get('leftId')!)),
    this.route.paramMap.pipe(map(p => p.get('rightId')!))
  ]).pipe(
    distinctUntilChanged((a, b) => a[0] === b[0] && a[1] === b[1]),
    switchMap(([leftId, rightId]) =>
      forkJoin({
        left: this.service.getItem(leftId),
        right: this.service.getItem(rightId)
      })
    )
  );
}
```

### Query Param Sync with Form

Bidirectional sync between URL query params and a filter form:

```typescript
@Component({ /* ... */ })
class ListComponent implements OnInit {
  filterForm = new FormGroup({
    search: new FormControl(''),
    category: new FormControl('all'),
    page: new FormControl(1),
  });

  private destroy$ = new Subject<void>();

  ngOnInit() {
    // URL → Form: seed form from query params on init
    this.route.queryParamMap.pipe(
      take(1)
    ).subscribe(params => {
      this.filterForm.patchValue({
        search: params.get('search') || '',
        category: params.get('category') || 'all',
        page: +(params.get('page') || 1),
      }, { emitEvent: false });  // don't trigger valueChanges
    });

    // Form → URL: sync form changes to query params
    this.filterForm.valueChanges.pipe(
      debounceTime(300),
      takeUntil(this.destroy$)
    ).subscribe(values => {
      this.router.navigate([], {
        relativeTo: this.route,
        queryParams: values,
        queryParamsHandling: 'merge',
      });
    });
  }

  ngOnDestroy() { this.destroy$.next(); this.destroy$.complete(); }
}
```

### Resolver Patterns

```typescript
// Basic resolver — must complete (use take(1) for ongoing observables)
@Injectable({ providedIn: 'root' })
class ItemResolver implements Resolve<Item> {
  constructor(private service: ItemService) {}

  resolve(route: ActivatedRouteSnapshot): Observable<Item> {
    return this.service.getItem(route.paramMap.get('id')!).pipe(
      take(1),
      catchError(() => {
        this.router.navigate(['/error']);
        return EMPTY;
      })
    );
  }
}

// Functional resolver (Angular 15+)
export const itemResolver: ResolveFn<Item> = (route) => {
  const service = inject(ItemService);
  const router = inject(Router);
  return service.getItem(route.paramMap.get('id')!).pipe(
    take(1),
    catchError(() => {
      router.navigate(['/error']);
      return EMPTY;
    })
  );
};

// Route config
const routes: Routes = [
  {
    path: 'items/:id',
    component: ItemDetailComponent,
    resolve: { item: itemResolver }
  }
];

// Accessing resolved data
class ItemDetailComponent {
  item$ = this.route.data.pipe(map(data => data['item'] as Item));
  constructor(private route: ActivatedRoute) {}
}
```

---

## HttpClient Interceptors

### Auth Token Interceptor

```typescript
// Functional interceptor (Angular 15+)
export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const auth = inject(AuthService);
  const token = auth.getToken();

  if (token) {
    req = req.clone({
      setHeaders: { Authorization: `Bearer ${token}` }
    });
  }

  return next(req).pipe(
    catchError(err => {
      if (err.status === 401) {
        return auth.refreshToken().pipe(
          switchMap(newToken => {
            const retryReq = req.clone({
              setHeaders: { Authorization: `Bearer ${newToken}` }
            });
            return next(retryReq);
          }),
          catchError(() => {
            auth.logout();
            return throwError(() => err);
          })
        );
      }
      return throwError(() => err);
    })
  );
};

// Register in app config
export const appConfig: ApplicationConfig = {
  providers: [
    provideHttpClient(withInterceptors([authInterceptor]))
  ]
};
```

### Retry Interceptor

```typescript
export const retryInterceptor: HttpInterceptorFn = (req, next) => {
  // Only retry GET requests (idempotent)
  if (req.method !== 'GET') return next(req);

  return next(req).pipe(
    retry({
      count: 3,
      delay: (error, retryCount) => {
        if (error.status === 404 || error.status === 400) {
          return throwError(() => error);  // don't retry client errors
        }
        return timer(Math.pow(2, retryCount) * 1000);
      }
    })
  );
};
```

### Cache Interceptor

```typescript
export const cacheInterceptor: HttpInterceptorFn = (req, next) => {
  const cache = inject(HttpCacheService);

  if (req.method !== 'GET') {
    cache.invalidate(req.url);
    return next(req);
  }

  const cached = cache.get(req.url);
  if (cached) return of(cached);

  return next(req).pipe(
    tap(response => {
      if (response instanceof HttpResponse) {
        cache.set(req.url, response);
      }
    })
  );
};

@Injectable({ providedIn: 'root' })
class HttpCacheService {
  private cache = new Map<string, { response: HttpResponse<unknown>; expiry: number }>();
  private ttlMs = 60_000; // 1 minute

  get(url: string): HttpResponse<unknown> | null {
    const entry = this.cache.get(url);
    if (!entry || Date.now() > entry.expiry) {
      this.cache.delete(url);
      return null;
    }
    return entry.response.clone();
  }

  set(url: string, response: HttpResponse<unknown>): void {
    this.cache.set(url, { response: response.clone(), expiry: Date.now() + this.ttlMs });
  }

  invalidate(urlPattern: string): void {
    for (const key of this.cache.keys()) {
      if (key.startsWith(urlPattern)) this.cache.delete(key);
    }
  }
}
```

### Loading Interceptor

```typescript
@Injectable({ providedIn: 'root' })
export class LoadingService {
  private activeRequests = 0;
  private loading$ = new BehaviorSubject<boolean>(false);

  readonly isLoading$ = this.loading$.asObservable().pipe(
    distinctUntilChanged()
  );

  show() { this.loading$.next(++this.activeRequests > 0); }
  hide() { this.loading$.next(--this.activeRequests > 0); }
}

export const loadingInterceptor: HttpInterceptorFn = (req, next) => {
  // Skip for background requests flagged with custom header
  if (req.headers.has('X-Background-Request')) {
    return next(req.clone({ headers: req.headers.delete('X-Background-Request') }));
  }

  const loading = inject(LoadingService);
  loading.show();

  return next(req).pipe(
    finalize(() => loading.hide())
  );
};
```

---

## NgRx and ComponentStore Patterns

### NgRx Effects with RxJS

```typescript
@Injectable()
class ItemEffects {
  // Load items with error handling
  loadItems$ = createEffect(() =>
    this.actions$.pipe(
      ofType(ItemActions.loadItems),
      exhaustMap(action =>
        this.itemService.getItems(action.params).pipe(
          map(items => ItemActions.loadItemsSuccess({ items })),
          catchError(error => of(ItemActions.loadItemsFailure({ error: error.message })))
        )
      )
    )
  );

  // Debounced search
  searchItems$ = createEffect(() =>
    this.actions$.pipe(
      ofType(ItemActions.searchItems),
      debounceTime(300),
      distinctUntilChanged((a, b) => a.query === b.query),
      switchMap(action =>
        this.itemService.search(action.query).pipe(
          map(results => ItemActions.searchItemsSuccess({ results })),
          catchError(error => of(ItemActions.searchItemsFailure({ error: error.message })))
        )
      )
    )
  );

  // Optimistic update with rollback
  updateItem$ = createEffect(() =>
    this.actions$.pipe(
      ofType(ItemActions.updateItem),
      concatMap(action =>
        this.itemService.update(action.item).pipe(
          map(() => ItemActions.updateItemSuccess({ item: action.item })),
          catchError(error => of(
            ItemActions.updateItemRollback({ originalItem: action.originalItem }),
            ItemActions.updateItemFailure({ error: error.message })
          ))
        )
      )
    )
  );

  // Navigation side effect (non-dispatching)
  navigateOnSave$ = createEffect(() =>
    this.actions$.pipe(
      ofType(ItemActions.saveItemSuccess),
      tap(action => this.router.navigate(['/items', action.item.id]))
    ),
    { dispatch: false }
  );

  constructor(
    private actions$: Actions,
    private itemService: ItemService,
    private router: Router
  ) {}
}
```

### ComponentStore Reactive Patterns

```typescript
interface ItemState {
  items: Item[];
  loading: boolean;
  error: string | null;
  selectedId: string | null;
}

@Injectable()
class ItemStore extends ComponentStore<ItemState> {
  constructor(private api: ItemService) {
    super({ items: [], loading: false, error: null, selectedId: null });
  }

  // Selectors
  readonly items$ = this.select(state => state.items);
  readonly loading$ = this.select(state => state.loading);
  readonly selectedItem$ = this.select(
    this.items$,
    this.select(state => state.selectedId),
    (items, id) => items.find(item => item.id === id) ?? null
  );

  // Updaters
  readonly setLoading = this.updater((state, loading: boolean) => ({
    ...state, loading
  }));

  readonly addItem = this.updater((state, item: Item) => ({
    ...state,
    items: [...state.items, item]
  }));

  // Effects
  readonly loadItems = this.effect((trigger$: Observable<void>) =>
    trigger$.pipe(
      tap(() => this.setLoading(true)),
      switchMap(() =>
        this.api.getItems().pipe(
          tapResponse(
            items => this.patchState({ items, loading: false, error: null }),
            error => this.patchState({ loading: false, error: (error as Error).message })
          )
        )
      )
    )
  );

  // Effect with parameter
  readonly deleteItem = this.effect((id$: Observable<string>) =>
    id$.pipe(
      concatMap(id =>
        this.api.delete(id).pipe(
          tapResponse(
            () => this.patchState({
              items: this.get().items.filter(i => i.id !== id)
            }),
            error => this.patchState({ error: (error as Error).message })
          )
        )
      )
    )
  );
}
```

### Selector Composition

```typescript
// NgRx feature selectors with RxJS
const selectFeature = createFeatureSelector<AppState>('items');
const selectAll = createSelector(selectFeature, state => state.items);
const selectFilter = createSelector(selectFeature, state => state.filter);

// Derived selector with rxjs in component
@Component({ /* ... */ })
class FilteredListComponent {
  filteredItems$ = combineLatest([
    this.store.select(selectAll),
    this.store.select(selectFilter),
    this.searchControl.valueChanges.pipe(startWith(''))
  ]).pipe(
    map(([items, filter, search]) =>
      items
        .filter(item => filter === 'all' || item.category === filter)
        .filter(item => item.name.toLowerCase().includes(search.toLowerCase()))
    ),
    distinctUntilChanged((a, b) => JSON.stringify(a) === JSON.stringify(b))
  );
}
```

---

## Signal Interop

### toSignal — Observable to Signal

```typescript
import { toSignal } from '@angular/core/rxjs-interop';
import { inject } from '@angular/core';

@Component({
  template: `
    <ul>
      @for (item of items(); track item.id) {
        <li>{{ item.name }}</li>
      }
    </ul>
  `
})
class ItemListComponent {
  private itemService = inject(ItemService);

  // Observable → Signal with initial value
  items = toSignal(this.itemService.getItems(), { initialValue: [] as Item[] });

  // With requireSync for BehaviorSubject (emits synchronously)
  private store = inject(Store);
  count = toSignal(this.store.select(selectCount), { requireSync: true });

  // Computed from signal (no RxJS needed)
  hasItems = computed(() => this.items().length > 0);
}
```

**Rules:**
- Must be called in an injection context (constructor, field initializer, or provide `injector` option).
- Without `initialValue`, signal type is `T | undefined`.
- With `requireSync: true`, observable MUST emit synchronously (BehaviorSubject, startWith).
- Auto-unsubscribes when component is destroyed.

### toObservable — Signal to Observable

```typescript
import { toObservable } from '@angular/core/rxjs-interop';
import { signal, inject, effect } from '@angular/core';

@Component({ /* ... */ })
class SearchComponent {
  searchTerm = signal('');

  // Signal → Observable for RxJS pipelines
  results$ = toObservable(this.searchTerm).pipe(
    debounceTime(300),
    distinctUntilChanged(),
    filter(term => term.length >= 2),
    switchMap(term => inject(SearchService).search(term))
  );

  // Back to signal for template
  results = toSignal(this.results$, { initialValue: [] });
}
```

**Rules:**
- Emits current signal value on subscription (like ReplaySubject(1)).
- Only emits when signal value actually changes (reference equality).
- Requires an injection context.
- Runs in a `microtask` — not synchronous.

### Mixing Signals and Observables

```typescript
@Component({ /* ... */ })
class DashboardComponent {
  private http = inject(HttpClient);

  // Signals for local UI state
  selectedTab = signal<'overview' | 'details'>('overview');
  refreshTrigger = signal(0);

  // Observable for data fetching, driven by signal changes
  private refresh$ = toObservable(this.refreshTrigger);

  data$ = this.refresh$.pipe(
    switchMap(() => this.http.get<DashboardData>('/api/dashboard')),
    shareReplay({ bufferSize: 1, refCount: true })
  );

  // Convert back to signal for template
  data = toSignal(this.data$, { initialValue: null });

  // Computed signals from observable-derived signals
  chartData = computed(() => {
    const d = this.data();
    return d ? this.transformForChart(d) : [];
  });

  refresh() {
    this.refreshTrigger.update(n => n + 1);
  }
}
```

### Migration Strategies

Gradual migration from RxJS to signals:

```typescript
// Step 1: Keep service layer as RxJS
@Injectable({ providedIn: 'root' })
class DataService {
  private data$ = this.http.get<Data[]>('/api/data').pipe(
    shareReplay({ bufferSize: 1, refCount: true })
  );

  // Expose both Observable and Signal
  readonly dataObservable$ = this.data$;
  readonly dataSignal = toSignal(this.data$, { initialValue: [] });
}

// Step 2: Components use signals
@Component({
  template: `
    @if (data().length > 0) {
      <app-list [items]="data()" />
    }
  `
})
class ListPage {
  data = inject(DataService).dataSignal;
}

// Step 3: Eventually migrate service internals to signals (when ready)
@Injectable({ providedIn: 'root' })
class DataService {
  private data = signal<Data[]>([]);
  readonly dataSignal = this.data.asReadonly();
  readonly dataObservable$ = toObservable(this.data); // backward compat
}
```

---

## Async Pipe Best Practices

### Single Subscription Pattern

```typescript
// ❌ BAD: Multiple async pipes = multiple subscriptions
<div>{{ data$ | async }}</div>
<div>{{ (data$ | async)?.name }}</div>

// ✅ GOOD: Single subscription with *ngIf...as
<ng-container *ngIf="data$ | async as data">
  <div>{{ data }}</div>
  <div>{{ data.name }}</div>
</ng-container>

// ✅ Angular 17+ @if syntax
@if (data$ | async; as data) {
  <div>{{ data }}</div>
  <div>{{ data.name }}</div>
}
```

### Multiple Observables in Template

```typescript
// Combine into a single view model observable
interface ViewModel {
  user: User;
  items: Item[];
  permissions: Permission[];
}

@Component({
  template: `
    <ng-container *ngIf="vm$ | async as vm">
      <h1>{{ vm.user.name }}</h1>
      <app-item-list [items]="vm.items" [permissions]="vm.permissions" />
    </ng-container>
  `
})
class DashboardComponent {
  vm$: Observable<ViewModel> = combineLatest({
    user: this.userService.currentUser$,
    items: this.itemService.items$,
    permissions: this.authService.permissions$
  }).pipe(
    // Ensure all sources have emitted
    filter(vm => !!vm.user && !!vm.items && !!vm.permissions)
  );
}
```

### Loading and Error States

```typescript
interface AsyncState<T> {
  loading: boolean;
  data: T | null;
  error: string | null;
}

function toAsyncState<T>(): OperatorFunction<T, AsyncState<T>> {
  return (source$: Observable<T>) =>
    source$.pipe(
      map(data => ({ loading: false, data, error: null })),
      startWith({ loading: true, data: null, error: null }),
      catchError(err => of({
        loading: false,
        data: null,
        error: err.message || 'Unknown error'
      }))
    );
}

// Usage
@Component({
  template: `
    <ng-container *ngIf="state$ | async as state">
      <app-spinner *ngIf="state.loading" />
      <app-error *ngIf="state.error" [message]="state.error" />
      <app-list *ngIf="state.data" [items]="state.data" />
    </ng-container>
  `
})
class ItemListComponent {
  state$ = this.itemService.getItems().pipe(toAsyncState());
}
```

---

## OnPush Change Detection with Observables

### Immutable Data Patterns

```typescript
@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <app-item-card
      *ngFor="let item of items$ | async; trackBy: trackById"
      [item]="item"
    />
  `
})
class ItemListComponent {
  items$ = this.store.select(selectItems);

  trackById(_: number, item: Item): string { return item.id; }
}

// Service must return new references for OnPush to detect changes
@Injectable({ providedIn: 'root' })
class ItemService {
  private items = new BehaviorSubject<Item[]>([]);

  addItem(item: Item) {
    const current = this.items.getValue();
    this.items.next([...current, item]);  // new array reference
  }

  updateItem(updated: Item) {
    const current = this.items.getValue();
    this.items.next(
      current.map(i => i.id === updated.id ? { ...updated } : i)  // new object reference
    );
  }
}
```

### Triggering CD from Observables

```typescript
@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `<div>{{ counter }}</div>`
})
class TimerComponent implements OnInit {
  counter = 0;
  private destroy$ = new Subject<void>();

  constructor(private cdr: ChangeDetectorRef) {}

  ngOnInit() {
    // Option 1: markForCheck (schedules CD for next cycle)
    interval(1000).pipe(takeUntil(this.destroy$)).subscribe(n => {
      this.counter = n;
      this.cdr.markForCheck();  // mark component and ancestors dirty
    });

    // Option 2: detectChanges (immediate, synchronous CD)
    // Use sparingly — can cause ExpressionChanged errors if called during CD
    someObservable$.subscribe(val => {
      this.value = val;
      this.cdr.detectChanges();  // runs CD immediately on this component subtree
    });
  }

  ngOnDestroy() { this.destroy$.next(); this.destroy$.complete(); }
}
```

### Performance Optimization

```typescript
@Component({
  changeDetection: ChangeDetectionStrategy.OnPush,
  template: `
    <!-- ✅ Input binding with async pipe: only updates when value changes -->
    <app-chart [data]="chartData$ | async" />

    <!-- ✅ trackBy prevents unnecessary DOM recreation -->
    <div *ngFor="let row of rows$ | async; trackBy: trackByFn">
      {{ row.value }}
    </div>
  `
})
class AnalyticsComponent {
  // Memoized computation with shareReplay
  chartData$ = this.rawData$.pipe(
    map(data => this.computeChartData(data)),
    distinctUntilChanged((a, b) => JSON.stringify(a) === JSON.stringify(b)),
    shareReplay({ bufferSize: 1, refCount: true })
  );

  // Debounced resize handler running outside Angular zone
  private resize$ = new Observable<Event>(subscriber => {
    this.ngZone.runOutsideAngular(() => {
      const handler = (e: Event) => subscriber.next(e);
      window.addEventListener('resize', handler);
      return () => window.removeEventListener('resize', handler);
    });
  }).pipe(
    debounceTime(200),
    map(() => ({ width: window.innerWidth, height: window.innerHeight })),
    distinctUntilChanged((a, b) => a.width === b.width && a.height === b.height)
  );

  constructor(private ngZone: NgZone) {}
}
```
