/**
 * Signal-Based Component Template — All inputs, outputs, and queries use signal APIs.
 * No decorators for component communication. OnPush + standalone + zoneless-ready.
 *
 * Copy this template and adapt types, template, and logic.
 */

import {
  Component,
  ChangeDetectionStrategy,
  computed,
  effect,
  inject,
  signal,
  input,
  output,
  model,
  viewChild,
  viewChildren,
  contentChild,
  contentChildren,
  linkedSignal,
  resource,
  ElementRef,
  DestroyRef,
  TemplateRef,
} from '@angular/core';
import { toSignal, takeUntilDestroyed } from '@angular/core/rxjs-interop';

// ─── Child/Projected Component Stubs (replace with real components) ──
// import { HeaderComponent } from './header.component';
// import { ItemComponent } from './item.component';
// import { TabDirective } from './tab.directive';

// ─── Types ─────────────────────────────────────────────────────
interface Item {
  id: string;
  name: string;
  active: boolean;
}

// ─── Component ─────────────────────────────────────────────────
@Component({
  selector: 'app-example',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  // imports: [HeaderComponent, ItemComponent],
  template: `
    <header #headerRef>
      <h2>{{ title() }}</h2>
    </header>

    <section>
      <!-- Two-way binding with parent -->
      <input
        [value]="searchQuery()"
        (input)="searchQuery.set($any($event.target).value)"
        placeholder="Search..."
      />

      <!-- Derived state -->
      <p>{{ statusText() }}</p>

      <!-- Resource-based async data -->
      @if (itemsResource.isLoading()) {
        <div class="spinner">Loading...</div>
      }

      @if (itemsResource.error(); as err) {
        <div class="error">Failed: {{ err }}</div>
        <button (click)="itemsResource.reload()">Retry</button>
      }

      @for (item of filteredItems(); track item.id) {
        <div
          class="item"
          [class.active]="item.active"
          (click)="selectItem(item)"
        >
          {{ item.name }}
        </div>
      }

      @empty {
        <p>No items found</p>
      }
    </section>

    <!-- Projected content queries (uncomment with real directives) -->
    <!-- <ng-content select="[appTab]"></ng-content> -->

    <footer>
      <button (click)="save.emit(selectedItem()!)">
        Save
      </button>
    </footer>
  `,
})
export class ExampleComponent {
  private destroyRef = inject(DestroyRef);

  // ── Signal Inputs (replace @Input) ────────────────────────────
  title = input('Default Title');                     // InputSignal<string>
  userId = input.required<number>();                  // InputSignal<number> — required
  config = input<{ pageSize: number }>(               // with default
    { pageSize: 20 }
  );

  // ── Signal Outputs (replace @Output + EventEmitter) ───────────
  save = output<Item>();                              // OutputEmitterRef<Item>
  closed = output<void>();                            // void output

  // ── Model (two-way binding) ───────────────────────────────────
  searchQuery = model('');                            // ModelSignal<string>

  // ── View Queries (replace @ViewChild/@ViewChildren) ───────────
  headerRef = viewChild<ElementRef>('headerRef');     // Signal<ElementRef | undefined>
  // items = viewChildren(ItemComponent);              // Signal<readonly ItemComponent[]>

  // ── Content Queries (replace @ContentChild/@ContentChildren) ──
  // tab = contentChild(TabDirective);                  // Signal<TabDirective | undefined>
  // tabs = contentChildren(TabDirective);              // Signal<readonly TabDirective[]>

  // ── Internal State ────────────────────────────────────────────
  private selectedId = signal<string | null>(null);

  // ── Async Data (resource API) ─────────────────────────────────
  itemsResource = resource({
    params: () => ({ uid: this.userId(), page: 1 }),
    loader: async ({ params, abortSignal }) => {
      const res = await fetch(
        `/api/users/${params.uid}/items?page=${params.page}`,
        { signal: abortSignal }
      );
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json() as Promise<Item[]>;
    },
  });

  // ── Computed (derived state) ──────────────────────────────────
  filteredItems = computed(() => {
    const items = this.itemsResource.value() ?? [];
    const query = this.searchQuery().toLowerCase();
    return query
      ? items.filter(i => i.name.toLowerCase().includes(query))
      : items;
  });

  selectedItem = computed(() => {
    const id = this.selectedId();
    if (!id) return null;
    return (this.itemsResource.value() ?? []).find(i => i.id === id) ?? null;
  });

  statusText = computed(() => {
    const total = this.itemsResource.value()?.length ?? 0;
    const filtered = this.filteredItems().length;
    const query = this.searchQuery();
    if (this.itemsResource.isLoading()) return 'Loading...';
    if (query) return `${filtered} of ${total} items match "${query}"`;
    return `${total} items`;
  });

  // ── linkedSignal (writable derived) ───────────────────────────
  // Resets to first item when userId changes
  activeTab = linkedSignal(() => 0);

  // ── Effects (side effects only) ───────────────────────────────
  private logEffect = effect(() => {
    console.log(`[ExampleComponent] userId=${this.userId()}, items=${this.filteredItems().length}`);
  });

  private storageEffect = effect((onCleanup) => {
    const query = this.searchQuery();
    const timer = setTimeout(() => {
      localStorage.setItem('lastSearch', query);
    }, 500);
    onCleanup(() => clearTimeout(timer));
  });

  // ── Methods ───────────────────────────────────────────────────
  selectItem(item: Item) {
    this.selectedId.set(item.id);
  }

  onClose() {
    this.closed.emit();
  }
}

// ─── Parent Usage ──────────────────────────────────────────────
// <app-example
//   [title]="'My Items'"
//   [userId]="currentUserId()"
//   [(searchQuery)]="parentQuery"
//   (save)="onSave($event)"
//   (closed)="onClose()"
// />
