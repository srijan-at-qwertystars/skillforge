// solid-store.tsx — Store pattern with context provider for shared state.
//
// Usage: Wrap app/subtree with <AppProvider>, consume with useAppState().
// Includes: createStore, produce, createContext, useContext.

import {
  createContext,
  useContext,
  createMemo,
  type ParentProps,
  type Accessor,
} from "solid-js";
import { createStore, produce } from "solid-js/store";

// -- Types --
interface Todo {
  id: number;
  text: string;
  done: boolean;
}

interface AppState {
  todos: Todo[];
  filter: "all" | "active" | "done";
  user: { name: string; theme: "light" | "dark" } | null;
}

interface AppActions {
  addTodo: (text: string) => void;
  toggleTodo: (id: number) => void;
  removeTodo: (id: number) => void;
  setFilter: (filter: AppState["filter"]) => void;
  setUser: (name: string) => void;
  toggleTheme: () => void;
}

interface AppStore {
  state: AppState;
  actions: AppActions;
  derived: {
    filteredTodos: Accessor<Todo[]>;
    remaining: Accessor<number>;
  };
}

// -- Context --
const AppContext = createContext<AppStore>();

export function useAppState(): AppStore {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error("useAppState must be used within <AppProvider>");
  return ctx;
}

// -- Provider --
export function AppProvider(props: ParentProps) {
  let nextId = 1;

  const [state, setState] = createStore<AppState>({
    todos: [],
    filter: "all",
    user: null,
  });

  // Actions — always use setState, never mutate store directly
  const actions: AppActions = {
    addTodo(text: string) {
      setState(
        produce((draft) => {
          draft.todos.push({ id: nextId++, text, done: false });
        })
      );
    },

    toggleTodo(id: number) {
      setState("todos", (todo) => todo.id === id, "done", (d) => !d);
    },

    removeTodo(id: number) {
      setState("todos", (todos) => todos.filter((t) => t.id !== id));
    },

    setFilter(filter: AppState["filter"]) {
      setState("filter", filter);
    },

    setUser(name: string) {
      setState("user", { name, theme: "light" });
    },

    toggleTheme() {
      setState("user", "theme", (t) => (t === "light" ? "dark" : "light"));
    },
  };

  // Derived values
  const filteredTodos = createMemo(() => {
    switch (state.filter) {
      case "active":
        return state.todos.filter((t) => !t.done);
      case "done":
        return state.todos.filter((t) => t.done);
      default:
        return state.todos;
    }
  });

  const remaining = createMemo(() => state.todos.filter((t) => !t.done).length);

  const store: AppStore = {
    state,
    actions,
    derived: { filteredTodos, remaining },
  };

  return (
    <AppContext.Provider value={store}>{props.children}</AppContext.Provider>
  );
}

// -- Example usage --
// import { AppProvider, useAppState } from "./solid-store";
//
// function App() {
//   return (
//     <AppProvider>
//       <TodoList />
//     </AppProvider>
//   );
// }
//
// function TodoList() {
//   const { state, actions, derived } = useAppState();
//   return (
//     <div>
//       <p>{derived.remaining()} remaining</p>
//       <For each={derived.filteredTodos()}>
//         {(todo) => (
//           <div>
//             <span classList={{ done: todo.done }}>{todo.text}</span>
//             <button onClick={() => actions.toggleTodo(todo.id)}>Toggle</button>
//           </div>
//         )}
//       </For>
//     </div>
//   );
// }
