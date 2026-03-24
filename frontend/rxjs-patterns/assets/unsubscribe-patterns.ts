/**
 * RxJS Unsubscribe Patterns Compared
 *
 * All major patterns for managing Observable subscriptions in Angular,
 * with pros, cons, and when to use each.
 */

import { Component, OnInit, OnDestroy, inject, DestroyRef } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { Subject, Subscription, Observable, interval } from 'rxjs';
import { takeUntil, take } from 'rxjs';

// ─── Pattern 1: takeUntil + destroy$ Subject ─────────────────────────
//
// Pros:
//   ✅ Works with any Angular version
//   ✅ Single teardown point for all subscriptions
//   ✅ Declarative — lives in the pipe
//   ✅ Well understood, widely adopted
//
// Cons:
//   ❌ Boilerplate (destroy$ + ngOnDestroy)
//   ❌ Must remember to call next() AND complete()
//   ❌ takeUntil must be LAST in the pipe to avoid leaks
//   ❌ Easy to forget adding to new subscriptions

@Component({ selector: 'pattern-1', template: '' })
class TakeUntilPatternComponent implements OnInit, OnDestroy {
  private destroy$ = new Subject<void>();

  ngOnInit() {
    // Add takeUntil(this.destroy$) as the LAST operator
    interval(1000).pipe(
      takeUntil(this.destroy$)
    ).subscribe(val => console.log('Pattern 1:', val));

    // Multiple subscriptions share the same destroy$
    interval(5000).pipe(
      takeUntil(this.destroy$)
    ).subscribe(val => console.log('Pattern 1b:', val));
  }

  ngOnDestroy() {
    this.destroy$.next();
    this.destroy$.complete();
  }
}

// ─── Pattern 2: Async Pipe (Template-Only) ───────────────────────────
//
// Pros:
//   ✅ Zero manual subscription management
//   ✅ Auto-subscribes and auto-unsubscribes
//   ✅ Triggers OnPush change detection automatically
//   ✅ No ngOnDestroy needed
//   ✅ Recommended by Angular team
//
// Cons:
//   ❌ Only works in templates — can't use in component logic
//   ❌ Multiple uses of same observable = multiple subscriptions
//      (fix with *ngIf="obs$ | async as value" or shareReplay)
//   ❌ Can be verbose with multiple observables

@Component({
  selector: 'pattern-2',
  template: `
    <!-- Single subscription with *ngIf...as -->
    <ng-container *ngIf="data$ | async as data">
      <div>{{ data.name }}</div>
      <div>{{ data.value }}</div>
    </ng-container>

    <!-- Angular 17+ @if syntax -->
    <!-- @if (data$ | async; as data) { -->
    <!--   <div>{{ data.name }}</div> -->
    <!-- } -->
  `,
})
class AsyncPipePatternComponent {
  data$: Observable<{ name: string; value: number }> = interval(1000).pipe(
    // No takeUntil needed — async pipe handles unsubscription
  ) as any; // Simplified for template example
}

// ─── Pattern 3: Manual Subscription.unsubscribe() ────────────────────
//
// Pros:
//   ✅ Fine-grained control
//   ✅ Can unsubscribe individual streams at different times
//   ✅ Clear imperative style
//
// Cons:
//   ❌ Must track every subscription manually
//   ❌ Easy to forget one
//   ❌ Verbose with many subscriptions
//   ❌ Not composable in pipes

@Component({ selector: 'pattern-3', template: '' })
class ManualSubscriptionComponent implements OnInit, OnDestroy {
  private sub1!: Subscription;
  private sub2!: Subscription;

  ngOnInit() {
    this.sub1 = interval(1000).subscribe(val => console.log('Sub 1:', val));
    this.sub2 = interval(5000).subscribe(val => console.log('Sub 2:', val));
  }

  ngOnDestroy() {
    this.sub1.unsubscribe();
    this.sub2.unsubscribe();
  }
}

// ─── Pattern 4: Subscription.add() (Composite) ──────────────────────
//
// Pros:
//   ✅ Single unsubscribe call tears down everything
//   ✅ Works with any Angular version
//
// Cons:
//   ❌ Imperative style
//   ❌ Must remember to add() each subscription
//   ❌ Not declarative — subscriptions managed outside the pipe

@Component({ selector: 'pattern-4', template: '' })
class CompositeSubscriptionComponent implements OnInit, OnDestroy {
  private subscriptions = new Subscription();

  ngOnInit() {
    this.subscriptions.add(
      interval(1000).subscribe(val => console.log('Composite 1:', val))
    );
    this.subscriptions.add(
      interval(5000).subscribe(val => console.log('Composite 2:', val))
    );
  }

  ngOnDestroy() {
    this.subscriptions.unsubscribe();
  }
}

// ─── Pattern 5: DestroyRef + takeUntilDestroyed (Angular 16+) ───────
//
// Pros:
//   ✅ Minimal boilerplate — no Subject, no ngOnDestroy
//   ✅ Framework-native solution
//   ✅ Works in constructor without explicit DestroyRef
//   ✅ Can be used outside components (directives, services with scope)
//   ✅ Declarative — lives in the pipe
//
// Cons:
//   ❌ Angular 16+ only
//   ❌ Without DestroyRef param, must be called in injection context (constructor)
//   ❌ Requires import from '@angular/core/rxjs-interop'

// --- Variant A: In constructor (automatic injection context) ---
@Component({ selector: 'pattern-5a', template: '' })
class DestroyRefAutoComponent {
  constructor() {
    // takeUntilDestroyed() auto-injects DestroyRef when in constructor
    interval(1000).pipe(
      takeUntilDestroyed()
    ).subscribe(val => console.log('DestroyRef auto:', val));
  }
}

// --- Variant B: Explicit DestroyRef (works anywhere, e.g. ngOnInit) ---
@Component({ selector: 'pattern-5b', template: '' })
class DestroyRefExplicitComponent implements OnInit {
  private destroyRef = inject(DestroyRef);

  ngOnInit() {
    // Must pass destroyRef explicitly when outside constructor
    interval(1000).pipe(
      takeUntilDestroyed(this.destroyRef)
    ).subscribe(val => console.log('DestroyRef explicit:', val));
  }
}

// ─── Pattern 6: take(1) / first() for One-Shot Observables ──────────
//
// Pros:
//   ✅ Self-completing — no teardown needed
//   ✅ Perfect for HTTP calls, one-time data loads
//   ✅ Simple and clear intent
//
// Cons:
//   ❌ Only works for single-value scenarios
//   ❌ first() throws EmptyError if source completes without emitting
//   ❌ Doesn't help with long-lived streams

@Component({ selector: 'pattern-6', template: '' })
class OneShotComponent implements OnInit {
  ngOnInit() {
    // HTTP calls already auto-complete, but take(1) makes intent clear
    // and provides cancellation protection
    someObservable$.pipe(
      take(1)
    ).subscribe(val => console.log('One-shot:', val));
  }
}

// Placeholder
declare const someObservable$: Observable<any>;

// ─── Decision Guide ─────────────────────────────────────────────────
//
// | Scenario                        | Recommended Pattern         |
// |--------------------------------|----------------------------|
// | Angular 16+ component          | Pattern 5 (DestroyRef)     |
// | Template binding                | Pattern 2 (async pipe)     |
// | Pre-Angular 16 component       | Pattern 1 (takeUntil)      |
// | One-time data load             | Pattern 6 (take(1))        |
// | Multiple subs, fine control    | Pattern 4 (Subscription)   |
// | Service with no lifecycle      | N/A (use shareReplay)      |
//
// Best practice: Prefer async pipe when possible. Use DestroyRef
// (Angular 16+) for imperative subscriptions. Fall back to takeUntil
// for older Angular versions.
