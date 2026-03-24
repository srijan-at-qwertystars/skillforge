/**
 * NgRx SignalStore Template — Entity-based store with computed state,
 * async methods, lifecycle hooks, and reusable features.
 *
 * Install: npm i @ngrx/signals
 * Usage: Copy and adapt entity type, service calls, and computed selectors.
 */

import { computed, inject } from '@angular/core';
import {
  signalStore,
  withState,
  withComputed,
  withMethods,
  withHooks,
  patchState,
  type,
} from '@ngrx/signals';
import {
  withEntities,
  setAllEntities,
  addEntity,
  updateEntity,
  removeEntity,
  setEntities,
} from '@ngrx/signals/entities';
import { rxMethod } from '@ngrx/signals/rxjs-interop';
import { pipe, switchMap, tap } from 'rxjs';
import { tapResponse } from '@ngrx/operators';

// ─── Entity Type ───────────────────────────────────────────────
export interface TodoItem {
  id: string;
  title: string;
  completed: boolean;
  createdAt: string;
}

// ─── Store State ───────────────────────────────────────────────
interface TodoStoreState {
  loading: boolean;
  error: string | null;
  filter: 'all' | 'active' | 'completed';
}

const initialState: TodoStoreState = {
  loading: false,
  error: null,
  filter: 'all',
};

// ─── Service (inject into store methods) ───────────────────────
// Replace with your actual service:
// @Injectable({ providedIn: 'root' })
// export class TodoService {
//   private http = inject(HttpClient);
//   getAll() { return this.http.get<TodoItem[]>('/api/todos'); }
//   create(todo: Partial<TodoItem>) { return this.http.post<TodoItem>('/api/todos', todo); }
//   update(todo: TodoItem) { return this.http.put<TodoItem>(`/api/todos/${todo.id}`, todo); }
//   delete(id: string) { return this.http.delete<void>(`/api/todos/${id}`); }
// }

// ─── Store Definition ──────────────────────────────────────────
export const TodoStore = signalStore(
  { providedIn: 'root' }, // or remove for component-scoped

  // Base state (non-entity fields)
  withState(initialState),

  // Entity collection — auto-generates entityMap, ids, entities signals
  withEntities({ entity: type<TodoItem>(), collection: 'todo' }),

  // Computed selectors
  withComputed(({ todoEntities, filter, loading }) => ({
    filteredTodos: computed(() => {
      const f = filter();
      const todos = todoEntities();
      switch (f) {
        case 'active':
          return todos.filter(t => !t.completed);
        case 'completed':
          return todos.filter(t => t.completed);
        default:
          return todos;
      }
    }),

    totalCount: computed(() => todoEntities().length),

    completedCount: computed(() =>
      todoEntities().filter(t => t.completed).length
    ),

    activeCount: computed(() =>
      todoEntities().filter(t => !t.completed).length
    ),

    isEmpty: computed(() => todoEntities().length === 0 && !loading()),
  })),

  // Methods (actions)
  withMethods((store /*, service = inject(TodoService) */) => ({
    // Sync methods
    setFilter(filter: 'all' | 'active' | 'completed') {
      patchState(store, { filter });
    },

    addTodo(title: string) {
      const todo: TodoItem = {
        id: crypto.randomUUID(),
        title,
        completed: false,
        createdAt: new Date().toISOString(),
      };
      patchState(store, addEntity(todo, { collection: 'todo' }));
    },

    toggleTodo(id: string) {
      const entity = store.todoEntityMap()[id];
      if (entity) {
        patchState(
          store,
          updateEntity(
            { id, changes: { completed: !entity.completed } },
            { collection: 'todo' }
          )
        );
      }
    },

    removeTodo(id: string) {
      patchState(store, removeEntity(id, { collection: 'todo' }));
    },

    clearCompleted() {
      const activeIds = store
        .todoEntities()
        .filter(t => !t.completed)
        .map(t => t);
      patchState(store, setEntities(activeIds, { collection: 'todo' }));
    },

    // Async method using rxMethod (uncomment service injection above)
    // loadAll: rxMethod<void>(
    //   pipe(
    //     tap(() => patchState(store, { loading: true, error: null })),
    //     switchMap(() =>
    //       service.getAll().pipe(
    //         tapResponse({
    //           next: (todos) => {
    //             patchState(store, setAllEntities(todos, { collection: 'todo' }));
    //             patchState(store, { loading: false });
    //           },
    //           error: (err: Error) => {
    //             patchState(store, { error: err.message, loading: false });
    //           },
    //         })
    //       )
    //     )
    //   )
    // ),
  })),

  // Lifecycle hooks
  withHooks({
    onInit(store) {
      console.log('[TodoStore] initialized');
      // store.loadAll();  // auto-load on init
    },
    onDestroy(store) {
      console.log('[TodoStore] destroyed');
    },
  })
);

// ─── Usage in Component ────────────────────────────────────────
// @Component({
//   // providers: [TodoStore],  // if not providedIn: 'root'
//   template: `
//     @if (store.loading()) { <p>Loading...</p> }
//     @if (store.error(); as err) { <p class="error">{{ err }}</p> }
//     @for (todo of store.filteredTodos(); track todo.id) {
//       <div (click)="store.toggleTodo(todo.id)"
//            [class.done]="todo.completed">
//         {{ todo.title }}
//       </div>
//     }
//     <p>{{ store.activeCount() }} items left</p>
//   `,
// })
// export class TodoListComponent {
//   readonly store = inject(TodoStore);
// }
