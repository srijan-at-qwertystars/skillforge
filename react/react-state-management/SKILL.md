---
name: react-state-management
description:
  positive: "Use when user manages React state, asks about Zustand, Jotai, TanStack Query, React Context, useReducer, Redux Toolkit, state machines (XState), or choosing between state management solutions."
  negative: "Do NOT use for React Server Components data fetching (use react-server-components skill), Vue/Svelte state, or backend state management."
---

# React State Management

## State Management Decision Guide

Follow this escalation path. Stop at the simplest layer that solves the problem:

1. **Local state** → `useState` / `useReducer` inside one component
2. **Lifted state** → Move state to nearest common parent, pass via props
3. **Context** → Share state across a subtree without prop drilling (low-frequency updates)
4. **URL state** → Filters, pagination, search params — use `nuqs` or router search params
5. **Server state** → Data from APIs — use TanStack Query
6. **External client state** → Complex shared UI state — use Zustand or Jotai
7. **State machines** → Complex workflows with defined transitions — use XState

Never reach for an external library when `useState` suffices. Never store server data in Zustand — use TanStack Query.

## Built-in React State

### useState — simple values

```tsx
const [count, setCount] = useState(0);
// Functional updates for derived-from-previous
setCount(prev => prev + 1);
```

### useReducer — complex state logic

Use when next state depends on previous state and multiple actions exist:

```tsx
type State = { items: Item[]; loading: boolean; error: string | null };
type Action =
  | { type: 'FETCH_START' }
  | { type: 'FETCH_OK'; items: Item[] }
  | { type: 'FETCH_ERR'; error: string };

function reducer(state: State, action: Action): State {
  switch (action.type) {
    case 'FETCH_START': return { ...state, loading: true, error: null };
    case 'FETCH_OK':    return { items: action.items, loading: false, error: null };
    case 'FETCH_ERR':   return { ...state, loading: false, error: action.error };
  }
}

const [state, dispatch] = useReducer(reducer, { items: [], loading: false, error: null });
```

### useContext — limits

Context triggers re-renders in **all** consumers when the value changes. Do not use for high-frequency updates. Split contexts by concern and memoize values.

## React Context Optimization

### Split state and dispatch into separate contexts

```tsx
const StateCtx = createContext<AppState>(initialState);
const DispatchCtx = createContext<React.Dispatch<Action>>(() => {});

function AppProvider({ children }: { children: ReactNode }) {
  const [state, dispatch] = useReducer(reducer, initialState);
  return (
    <DispatchCtx.Provider value={dispatch}>
      <StateCtx.Provider value={state}>{children}</StateCtx.Provider>
    </DispatchCtx.Provider>
  );
}

// Components that only dispatch never re-render on state change
function useAppDispatch() { return useContext(DispatchCtx); }
function useAppState() { return useContext(StateCtx); }
```

### Split contexts by domain

Create `ThemeContext`, `AuthContext`, `NotificationContext` separately. Never put unrelated state in one context.

### Memoize provider values

```tsx
const value = useMemo(() => ({ user, preferences }), [user, preferences]);
<UserCtx.Provider value={value}>{children}</UserCtx.Provider>
```

For fine-grained subscriptions without splitting, use `use-context-selector`:

```tsx
import { createContext, useContextSelector } from 'use-context-selector';
const userName = useContextSelector(Ctx, s => s.user.name);
```

## Zustand

Lightweight store with automatic selector-based re-renders. No providers.

### Basic store

```tsx
import { create } from 'zustand';

interface CounterStore {
  count: number;
  increment: () => void;
  reset: () => void;
}

const useCounterStore = create<CounterStore>((set) => ({
  count: 0,
  increment: () => set((s) => ({ count: s.count + 1 })),
  reset: () => set({ count: 0 }),
}));

// In component — select only what you need
const count = useCounterStore(s => s.count);
const increment = useCounterStore(s => s.increment);
```

### Selectors — prevent unnecessary re-renders

```tsx
// BAD: re-renders on any store change
const { count, increment } = useCounterStore();

// GOOD: re-renders only when count changes
const count = useCounterStore(s => s.count);

// For objects/arrays, use useShallow
import { useShallow } from 'zustand/react/shallow';
const { items, total } = useStore(useShallow(s => ({ items: s.items, total: s.total })));
```

### Slices pattern — modular stores

```tsx
import { StateCreator } from 'zustand';

interface AuthSlice { user: User | null; login: (u: User) => void; logout: () => void; }
interface CartSlice { items: Item[]; addItem: (i: Item) => void; clearCart: () => void; }
type StoreState = AuthSlice & CartSlice;

const createAuthSlice: StateCreator<StoreState, [], [], AuthSlice> = (set, get) => ({
  user: null,
  login: (user) => set({ user }),
  logout: () => { set({ user: null }); get().clearCart(); },
});

const createCartSlice: StateCreator<StoreState, [], [], CartSlice> = (set) => ({
  items: [],
  addItem: (item) => set((s) => ({ items: [...s.items, item] })),
  clearCart: () => set({ items: [] }),
});

const useStore = create<StoreState>()((...a) => ({
  ...createAuthSlice(...a),
  ...createCartSlice(...a),
}));
```

### Middleware — persist, devtools

```tsx
import { devtools, persist } from 'zustand/middleware';

const useStore = create<StoreState>()(
  devtools(
    persist(
      (...a) => ({ ...createAuthSlice(...a), ...createCartSlice(...a) }),
      { name: 'app-store' }
    )
  )
);
```

Place `devtools` outermost. Use `immer` middleware for deep nested updates.

## Jotai

Atomic state — each atom is independent reactive state. Components subscribe only to atoms they read.

### Primitive atoms

```tsx
import { atom, useAtom, useAtomValue, useSetAtom } from 'jotai';

const countAtom = atom(0);
const themeAtom = atom<'light' | 'dark'>('light');

function Counter() {
  const [count, setCount] = useAtom(countAtom);
  return <button onClick={() => setCount(c => c + 1)}>{count}</button>;
}

// Read-only or write-only
const count = useAtomValue(countAtom);
const setCount = useSetAtom(countAtom);
```

### Derived atoms

```tsx
const todosAtom = atom<Todo[]>([]);
const completedAtom = atom((get) => get(todosAtom).filter(t => t.done));
const statsAtom = atom((get) => ({
  total: get(todosAtom).length,
  done: get(completedAtom).length,
}));
```

### Async atoms

```tsx
const userAtom = atom(async () => {
  const res = await fetch('/api/user');
  return res.json() as Promise<User>;
});
// Wrap consumer in <Suspense> for loading state
```

### Writable derived atoms

```tsx
const uppercaseAtom = atom(
  (get) => get(nameAtom).toUpperCase(),
  (_get, set, newName: string) => set(nameAtom, newName.toLowerCase()),
);
```

### Atom families — parameterized atoms

```tsx
import { atomFamily } from 'jotai/utils';
const todoAtomFamily = atomFamily((id: string) =>
  atom(async () => fetchTodo(id))
);
// Usage: useAtomValue(todoAtomFamily('todo-1'))
```

Use `splitAtom` for per-item granularity on array atoms. Use `focusAtom` from `jotai-optics` to subscribe to object subfields.

## TanStack Query (React Query v5)

Handles all server/async state: fetching, caching, background sync, mutations.

```tsx
import { useQuery, useSuspenseQuery } from '@tanstack/react-query';

const { data, isPending, error } = useQuery({
  queryKey: ['todos', { status: 'active' }],
  queryFn: () => fetchTodos({ status: 'active' }),
  staleTime: 5 * 60 * 1000,  // 5 min before refetch
});

// With Suspense
const { data } = useSuspenseQuery({ queryKey: ['user'], queryFn: fetchUser });
```

### Mutations with optimistic updates

```tsx
const queryClient = useQueryClient();
const mutation = useMutation({
  mutationFn: updateTodo,
  onMutate: async (newTodo) => {
    await queryClient.cancelQueries({ queryKey: ['todos'] });
    const previous = queryClient.getQueryData<Todo[]>(['todos']);
    queryClient.setQueryData<Todo[]>(['todos'], old =>
      old?.map(t => t.id === newTodo.id ? { ...t, ...newTodo } : t)
    );
    return { previous };  // snapshot for rollback
  },
  onError: (_err, _vars, context) => {
    queryClient.setQueryData(['todos'], context?.previous);
  },
  onSettled: () => {
    queryClient.invalidateQueries({ queryKey: ['todos'] });
  },
});
```

### Prefetching

```tsx
queryClient.prefetchQuery({
  queryKey: ['todo', id],
  queryFn: () => fetchTodo(id),
});
```

### Select for derived data

```tsx
const { data: count } = useQuery({
  queryKey: ['todos'], queryFn: fetchTodos,
  select: (data) => data.length,
});
```

Key config: `staleTime` (freshness duration), `gcTime` (unused cache TTL). Use consistent `queryKey` arrays.

## Redux Toolkit

Use Redux Toolkit when you need: time-travel debugging, middleware-heavy architecture, large teams with established Redux patterns.

### createSlice

```tsx
import { createSlice, PayloadAction } from '@reduxjs/toolkit';

const counterSlice = createSlice({
  name: 'counter',
  initialState: { value: 0 },
  reducers: {
    increment: (state) => { state.value += 1; },  // immer-powered mutation
    set: (state, action: PayloadAction<number>) => { state.value = action.payload; },
  },
});
export const { increment, set } = counterSlice.actions;
```

### RTK Query

Use RTK Query for API data when already using Redux. Prefer TanStack Query in new non-Redux projects.

```tsx
import { createApi, fetchBaseQuery } from '@reduxjs/toolkit/query/react';

const api = createApi({
  baseQuery: fetchBaseQuery({ baseUrl: '/api' }),
  tagTypes: ['Todo'],
  endpoints: (build) => ({
    getTodos: build.query<Todo[], void>({
      query: () => 'todos',
      providesTags: ['Todo'],
    }),
    addTodo: build.mutation<Todo, Partial<Todo>>({
      query: (body) => ({ url: 'todos', method: 'POST', body }),
      invalidatesTags: ['Todo'],
    }),
  }),
});
export const { useGetTodosQuery, useAddTodoMutation } = api;
```

Do not store RTK Query cache results in a separate `createSlice`. Let RTK Query own its cache.

## State Machines with XState v5

Use state machines for workflows with well-defined states and transitions: multi-step forms, auth flows, media players, payment flows.

### Define a machine

```tsx
import { setup, assign, fromPromise } from 'xstate';
import { useMachine } from '@xstate/react';

const fetchMachine = setup({
  types: {
    context: {} as { data: Item[] | null; error: string | null },
    events: {} as { type: 'FETCH' } | { type: 'RETRY' },
  },
  actors: {
    fetchData: fromPromise(async () => {
      const res = await fetch('/api/items');
      if (!res.ok) throw new Error('Failed');
      return res.json() as Promise<Item[]>;
    }),
  },
  guards: {
    hasRetries: ({ context }) => (context.error !== null),
  },
}).createMachine({
  id: 'fetcher',
  initial: 'idle',
  context: { data: null, error: null },
  states: {
    idle: { on: { FETCH: 'loading' } },
    loading: {
      invoke: {
        src: 'fetchData',
        onDone: { target: 'success', actions: assign({ data: ({ event }) => event.output }) },
        onError: { target: 'failure', actions: assign({ error: ({ event }) => String(event.error) }) },
      },
    },
    success: { type: 'final' },
    failure: { on: { RETRY: { guard: 'hasRetries', target: 'loading' } } },
  },
});

function ItemList() {
  const [state, send] = useMachine(fetchMachine);
  if (state.matches('idle')) return <button onClick={() => send({ type: 'FETCH' })}>Load</button>;
  if (state.matches('loading')) return <Spinner />;
  if (state.matches('failure')) return <button onClick={() => send({ type: 'RETRY' })}>Retry</button>;
  return <List items={state.context.data!} />;
}
```

State machines eliminate impossible states. Model as a machine when a component has 3+ boolean flags governing behavior.

## Server State vs Client State

| Aspect | Server state | Client state |
|--------|-------------|--------------|
| Source | Remote API / database | Browser / user interaction |
| Tool | TanStack Query, RTK Query | useState, Zustand, Jotai |
| Caching | Automatic stale-while-revalidate | Manual or none |
| Examples | User profile, product list | Modal open, selected tab, theme |

Never duplicate server state into client stores. Let TanStack Query's cache be the source of truth.

## Form State

Use **React Hook Form** for forms with uncontrolled inputs for performance. Validate with Zod.

```tsx
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';

const schema = z.object({
  email: z.string().email(),
  name: z.string().min(2),
});

function MyForm() {
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof schema>>({
    resolver: zodResolver(schema),
  });
  return (
    <form onSubmit={handleSubmit(data => mutation.mutate(data))}>
      <input {...register('email')} />
      {errors.email && <span>{errors.email.message}</span>}
      <input {...register('name')} />
      <button type="submit">Submit</button>
    </form>
  );
}
```

Prefer `register` (uncontrolled) over `Controller` (controlled) unless the input requires it. Do not store form state in Zustand or Redux.

## URL State

Use URL search params for state that should survive refresh and be shareable: filters, pagination, search, sort.

### nuqs — type-safe URL state

```tsx
import { useQueryState, parseAsInteger, parseAsStringEnum } from 'nuqs';

function ProductList() {
  const [page, setPage] = useQueryState('page', parseAsInteger.withDefault(1));
  const [sort, setSort] = useQueryState('sort', parseAsStringEnum(['price', 'name', 'date']).withDefault('date'));
  const [search, setSearch] = useQueryState('q', { defaultValue: '' });

  // URL updates automatically: ?page=2&sort=price&q=shoes
  return (
    <div>
      <input value={search} onChange={e => setSearch(e.target.value)} />
      <button onClick={() => setPage(p => p + 1)}>Next page</button>
    </div>
  );
}
```

Feed URL state into TanStack Query keys for automatic refetching on param change.

## Performance Patterns

- Select specific slices in Zustand/Jotai — never destructure the whole store.
- Use `React.memo` on expensive child components.
- Split contexts so unrelated updates don't cascade.
- Use `useDeferredValue` for expensive derived renders.
- Define selectors as stable references outside components.
- Use TanStack Query's `select` option to narrow reactive scope.
- Colocate state — keep it as close to where it's used as possible.

## Anti-patterns

- **Prop drilling** → If passing through 3+ components that don't use the prop, use context or Zustand.
- **Global state abuse** → Modal open/close, form drafts, animation state — keep local.
- **Derived state in state** → Never store values computable from other state. Use `useMemo`.
- **Syncing stores** → If two stores hold the same data, one is redundant. Single source of truth.
- **useEffect for state transforms** → Never use `useEffect` to derive state. Compute inline with `useMemo`.

```tsx
// BAD                                  // GOOD
const [total, setTotal] = useState(0);  const total = useMemo(
useEffect(() => {                       //   () => items.reduce((s, i) => s + i.price, 0),
  setTotal(items.reduce(/*...*/));      //   [items]
}, [items]);                            // );
```
