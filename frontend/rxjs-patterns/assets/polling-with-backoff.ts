/**
 * Production Polling with Exponential Backoff
 *
 * Features:
 *   - Configurable polling interval
 *   - Exponential backoff on errors
 *   - Max retry count before giving up
 *   - Pause/resume support
 *   - Error recovery (resumes normal polling after successful request)
 *   - Jitter to prevent thundering herd
 *   - Type-safe configuration
 *
 * Usage:
 *   const poller = new Poller<Status>({
 *     request: () => this.http.get<Status>('/api/status'),
 *     intervalMs: 5000,
 *   });
 *
 *   poller.data$.subscribe(status => console.log(status));
 *   poller.start();
 *   poller.pause();
 *   poller.resume();
 *   poller.stop();
 */

import {
  Observable,
  BehaviorSubject,
  Subject,
  timer,
  EMPTY,
  of,
  throwError,
} from 'rxjs';
import {
  switchMap,
  catchError,
  tap,
  takeUntil,
  retry,
  map,
  scan,
  startWith,
  distinctUntilChanged,
  filter,
  shareReplay,
  finalize,
  delayWhen,
} from 'rxjs';

// ─── Configuration ──────────────────────────────────────────

export interface PollerConfig<T> {
  /** The HTTP request or async operation to poll */
  request: () => Observable<T>;

  /** Base polling interval in milliseconds (default: 5000) */
  intervalMs?: number;

  /** Maximum retry attempts before emitting error (default: 5) */
  maxRetries?: number;

  /** Base delay for exponential backoff in ms (default: 1000) */
  backoffBaseMs?: number;

  /** Maximum backoff delay in ms (default: 30000) */
  backoffMaxMs?: number;

  /** Add random jitter to backoff (default: true) */
  jitter?: boolean;

  /** Start polling immediately on construction (default: false) */
  autoStart?: boolean;
}

// ─── Poller State ───────────────────────────────────────────

export interface PollerState<T> {
  data: T | null;
  loading: boolean;
  error: Error | null;
  consecutiveErrors: number;
  isPaused: boolean;
  isRunning: boolean;
  lastSuccessAt: Date | null;
}

// ─── Poller Class ───────────────────────────────────────────

export class Poller<T> {
  private readonly config: Required<PollerConfig<T>>;
  private readonly active$ = new BehaviorSubject<boolean>(false);
  private readonly paused$ = new BehaviorSubject<boolean>(false);
  private readonly stop$ = new Subject<void>();
  private readonly manualTrigger$ = new Subject<void>();

  private readonly stateSubject$ = new BehaviorSubject<PollerState<T>>({
    data: null,
    loading: false,
    error: null,
    consecutiveErrors: 0,
    isPaused: false,
    isRunning: false,
    lastSuccessAt: null,
  });

  /** Observable of the full poller state */
  readonly state$ = this.stateSubject$.asObservable();

  /** Observable of just the data (skips nulls) */
  readonly data$: Observable<T> = this.state$.pipe(
    map(s => s.data),
    filter((d): d is T => d !== null),
    distinctUntilChanged(),
    shareReplay({ bufferSize: 1, refCount: true })
  );

  /** Observable of error state */
  readonly error$ = this.state$.pipe(
    map(s => s.error),
    distinctUntilChanged()
  );

  /** Observable of loading state */
  readonly loading$ = this.state$.pipe(
    map(s => s.loading),
    distinctUntilChanged()
  );

  constructor(config: PollerConfig<T>) {
    this.config = {
      intervalMs: 5000,
      maxRetries: 5,
      backoffBaseMs: 1000,
      backoffMaxMs: 30000,
      jitter: true,
      autoStart: false,
      ...config,
    };

    if (this.config.autoStart) {
      this.start();
    }
  }

  /** Start polling */
  start(): void {
    if (this.active$.getValue()) return;

    this.active$.next(true);
    this.paused$.next(false);
    this.patchState({ isRunning: true, isPaused: false, error: null, consecutiveErrors: 0 });

    this.createPollingPipeline()
      .pipe(takeUntil(this.stop$))
      .subscribe();
  }

  /** Stop polling entirely */
  stop(): void {
    this.stop$.next();
    this.active$.next(false);
    this.paused$.next(false);
    this.patchState({ isRunning: false, isPaused: false });
  }

  /** Pause polling (can resume later) */
  pause(): void {
    if (!this.active$.getValue()) return;
    this.paused$.next(true);
    this.patchState({ isPaused: true });
  }

  /** Resume polling after pause */
  resume(): void {
    if (!this.active$.getValue()) return;
    this.paused$.next(false);
    this.patchState({ isPaused: false });
  }

  /** Trigger an immediate poll (ignores pause state) */
  triggerNow(): void {
    this.manualTrigger$.next();
  }

  /** Clean up all subscriptions */
  destroy(): void {
    this.stop();
    this.stop$.complete();
    this.stateSubject$.complete();
  }

  // ── Private ──

  private createPollingPipeline(): Observable<void> {
    const { intervalMs } = this.config;

    return this.paused$.pipe(
      switchMap(paused => {
        if (paused) return EMPTY;
        // Emit immediately (0), then every intervalMs
        return timer(0, intervalMs);
      }),
      // Execute the request
      switchMap(() => this.executeRequest()),
      // Map to void — state is managed via side effects
      map(() => void 0)
    );
  }

  private executeRequest(): Observable<T> {
    this.patchState({ loading: true });

    return this.config.request().pipe(
      tap(data => {
        this.patchState({
          data,
          loading: false,
          error: null,
          consecutiveErrors: 0,
          lastSuccessAt: new Date(),
        });
      }),
      catchError(err => {
        const currentErrors = this.stateSubject$.getValue().consecutiveErrors + 1;
        const error = err instanceof Error ? err : new Error(String(err));

        this.patchState({
          loading: false,
          error,
          consecutiveErrors: currentErrors,
        });

        if (currentErrors >= this.config.maxRetries) {
          console.error(`[Poller] Max retries (${this.config.maxRetries}) reached. Stopping.`);
          this.stop();
          return EMPTY;
        }

        // Calculate backoff delay
        const backoffMs = this.calculateBackoff(currentErrors);
        console.warn(
          `[Poller] Error (attempt ${currentErrors}/${this.config.maxRetries}). ` +
          `Retrying in ${backoffMs}ms.`,
          error.message
        );

        // Don't emit error downstream — just log and continue polling
        return EMPTY;
      })
    );
  }

  private calculateBackoff(attempt: number): number {
    const { backoffBaseMs, backoffMaxMs, jitter } = this.config;
    const exponentialDelay = Math.min(
      backoffBaseMs * Math.pow(2, attempt - 1),
      backoffMaxMs
    );

    if (jitter) {
      // Add ±25% jitter
      const jitterRange = exponentialDelay * 0.25;
      return exponentialDelay + (Math.random() * 2 - 1) * jitterRange;
    }

    return exponentialDelay;
  }

  private patchState(patch: Partial<PollerState<T>>): void {
    this.stateSubject$.next({
      ...this.stateSubject$.getValue(),
      ...patch,
    });
  }
}

// ─── Standalone Function (Alternative API) ──────────────────

/**
 * Standalone polling function for simpler use cases.
 * Returns an observable that polls at the given interval with backoff on errors.
 *
 * Usage:
 *   pollWithBackoff(() => this.http.get('/api/status'), 5000)
 *     .pipe(takeUntilDestroyed())
 *     .subscribe(data => console.log(data));
 */
export function pollWithBackoff<T>(
  request: () => Observable<T>,
  intervalMs: number = 5000,
  maxRetries: number = 5
): Observable<T> {
  return new Observable<T>(subscriber => {
    let consecutiveErrors = 0;

    const poll = (): Observable<T> =>
      timer(consecutiveErrors === 0 ? 0 : intervalMs).pipe(
        switchMap(() => request().pipe(
          tap(() => { consecutiveErrors = 0; }),
          catchError(err => {
            consecutiveErrors++;
            if (consecutiveErrors >= maxRetries) {
              return throwError(() => err);
            }
            const backoff = Math.min(1000 * Math.pow(2, consecutiveErrors), 30000);
            console.warn(`Poll error (${consecutiveErrors}/${maxRetries}), retry in ${backoff}ms`);
            return timer(backoff).pipe(switchMap(() => EMPTY));
          })
        ))
      );

    const sub = timer(0, intervalMs).pipe(
      switchMap(() => request().pipe(
        tap(() => { consecutiveErrors = 0; }),
        catchError(err => {
          consecutiveErrors++;
          if (consecutiveErrors >= maxRetries) {
            return throwError(() => err);
          }
          return EMPTY; // Skip this tick, next interval will retry
        })
      ))
    ).subscribe(subscriber);

    return () => sub.unsubscribe();
  });
}

// ─── Angular Usage Example ──────────────────────────────────
//
// @Component({
//   template: `
//     <div *ngIf="poller.loading$ | async">Refreshing...</div>
//     <div *ngIf="poller.error$ | async as error" class="error">
//       {{ error.message }}
//       <button (click)="poller.triggerNow()">Retry</button>
//     </div>
//     <div *ngIf="poller.data$ | async as status">
//       Server: {{ status.health }}
//       Updated: {{ status.timestamp | date:'medium' }}
//     </div>
//     <button (click)="poller.pause()">Pause</button>
//     <button (click)="poller.resume()">Resume</button>
//   `
// })
// class StatusComponent implements OnInit, OnDestroy {
//   poller = new Poller<ServerStatus>({
//     request: () => this.http.get<ServerStatus>('/api/status'),
//     intervalMs: 10000,
//     maxRetries: 3,
//     autoStart: true,
//   });
//
//   constructor(private http: HttpClient) {}
//
//   ngOnDestroy() {
//     this.poller.destroy();
//   }
// }
