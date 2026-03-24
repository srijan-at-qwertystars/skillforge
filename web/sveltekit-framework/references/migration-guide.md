# SvelteKit Migration Guide

## Table of Contents

- [Svelte 4 → Svelte 5 Migration](#svelte-4--svelte-5-migration)
  - [Reactive State: export let → $props](#reactive-state-export-let--props)
  - [Reactive Declarations: $: → $derived](#reactive-declarations---derived)
  - [Reactive Statements: $: → $effect](#reactive-statements---effect)
  - [Stores → Runes](#stores--runes)
  - [Events: createEventDispatcher → Callback Props](#events-createeventdispatcher--callback-props)
  - [Slots → Snippets](#slots--snippets)
  - [Lifecycle Hooks → $effect](#lifecycle-hooks--effect)
  - [Reactive Classes and Stores](#reactive-classes-and-stores)
- [SvelteKit 1 → SvelteKit 2 Migration](#sveltekit-1--sveltekit-2-migration)
- [Common Breaking Changes](#common-breaking-changes)
- [Codemods and Migration Tools](#codemods-and-migration-tools)

---

## Svelte 4 → Svelte 5 Migration

Svelte 5 introduces **runes** — compiler-driven primitives that replace the implicit reactivity model. Svelte 4 syntax still works in compatibility mode but should be migrated.

### Reactive State: export let → $props

**Svelte 4:**
```svelte
<script>
  export let name;
  export let count = 0;
  export let items = [];
</script>
```

**Svelte 5:**
```svelte
<script>
  let { name, count = 0, items = [] } = $props();
</script>
```

**Key differences:**
- All props are destructured from a single `$props()` call
- Default values use standard JS destructuring defaults
- Rest props: `let { known, ...rest } = $props()`
- Props are **not** reactive by default for parent updates — they update when the parent re-renders
- `$$props` and `$$restProps` are replaced by `$props()` rest syntax

**TypeScript:**
```svelte
<script lang="ts">
  // Svelte 4
  export let name: string;
  export let count: number = 0;

  // Svelte 5
  interface Props {
    name: string;
    count?: number;
    children?: Snippet;
  }
  let { name, count = 0, children }: Props = $props();
</script>
```

### Reactive Declarations: $: → $derived

**Svelte 4:**
```svelte
<script>
  export let price;
  export let quantity;
  $: total = price * quantity;
  $: formatted = `$${total.toFixed(2)}`;
  $: isExpensive = total > 100;
</script>
```

**Svelte 5:**
```svelte
<script>
  let { price, quantity } = $props();
  let total = $derived(price * quantity);
  let formatted = $derived(`$${total.toFixed(2)}`);
  let isExpensive = $derived(total > 100);
</script>
```

For complex derivations:
```svelte
<script>
  // Svelte 4
  $: {
    const tax = calculateTax(subtotal);
    total = subtotal + tax + shipping;
  }

  // Svelte 5
  let total = $derived.by(() => {
    const tax = calculateTax(subtotal);
    return subtotal + tax + shipping;
  });
</script>
```

### Reactive Statements: $: → $effect

**Svelte 4:**
```svelte
<script>
  export let title;
  $: document.title = title;
  $: console.log('Count changed:', count);
  $: {
    // multi-line side effect
    saveToStorage(data);
    updateAnalytics(data);
  }
</script>
```

**Svelte 5:**
```svelte
<script>
  let { title } = $props();
  $effect(() => {
    document.title = title;
  });
  $effect(() => {
    console.log('Count changed:', count);
  });
  $effect(() => {
    saveToStorage(data);
    updateAnalytics(data);
  });
</script>
```

**Important `$effect` differences from `$:`:**
- `$effect` runs **after** DOM updates (not before). Use `$effect.pre` for pre-update.
- `$effect` only runs in the browser (not during SSR).
- `$effect` tracks dependencies automatically — no need to reference vars.
- `$effect` supports cleanup via returned function.
- **Never use `$effect` to set state that could be `$derived`.** This is the most common anti-pattern.

```svelte
<script>
  // BAD: $effect used to derive state
  let doubled = $state(0);
  $effect(() => { doubled = count * 2; });

  // GOOD: use $derived
  let doubled = $derived(count * 2);
</script>
```

### Stores → Runes

**Svelte 4 (writable store):**
```ts
// store.ts
import { writable, derived } from 'svelte/store';

export const count = writable(0);
export const doubled = derived(count, $count => $count * 2);
```

```svelte
<script>
  import { count, doubled } from './store';
</script>
<button on:click={() => $count++}>{$count} (doubled: {$doubled})</button>
```

**Svelte 5 (runes in .svelte.ts):**
```ts
// counter.svelte.ts
let count = $state(0);
let doubled = $derived(count * 2);

export function getCounter() {
  return {
    get count() { return count; },
    get doubled() { return doubled; },
    increment() { count++; },
    reset() { count = 0; }
  };
}
```

```svelte
<script>
  import { getCounter } from './counter.svelte';
  const counter = getCounter();
</script>
<button onclick={counter.increment}>{counter.count} (doubled: {counter.doubled})</button>
```

**Key migration points:**
- `.svelte.ts` files (not `.ts`) can use runes
- No more `$store` auto-subscription syntax
- Use getter properties to maintain reactivity when exporting
- `writable` → `$state`
- `derived` → `$derived`
- `readable` → `$state` with exported getters only
- Custom stores → classes or factory functions with `$state`

### Events: createEventDispatcher → Callback Props

**Svelte 4:**
```svelte
<!-- Child.svelte -->
<script>
  import { createEventDispatcher } from 'svelte';
  const dispatch = createEventDispatcher();
</script>
<button on:click={() => dispatch('increment', { value: 1 })}>+1</button>

<!-- Parent.svelte -->
<Child on:increment={(e) => count += e.detail.value} />
```

**Svelte 5:**
```svelte
<!-- Child.svelte -->
<script>
  let { onincrement } = $props();
</script>
<button onclick={() => onincrement?.(1)}>+1</button>

<!-- Parent.svelte -->
<Child onincrement={(value) => count += value} />
```

**Migration rules:**
- `dispatch('eventname', data)` → `props.oneventname(data)`
- `on:eventname` directive → `oneventname={handler}` prop
- No more `e.detail` wrapper — pass data directly
- Event forwarding (`on:click`) → `let { onclick, ...rest } = $props()` and spread
- Bubbling events → explicitly pass handlers through props

**Event forwarding migration:**
```svelte
<!-- Svelte 4: automatic forwarding -->
<button on:click>Click me</button>

<!-- Svelte 5: explicit forwarding -->
<script>
  let { onclick, ...rest } = $props();
</script>
<button {onclick} {...rest}>Click me</button>
```

### Slots → Snippets

**Svelte 4 (default slot):**
```svelte
<!-- Card.svelte -->
<div class="card"><slot /></div>

<!-- Usage -->
<Card><p>Content</p></Card>
```

**Svelte 5 (children snippet):**
```svelte
<!-- Card.svelte -->
<script>
  let { children } = $props();
</script>
<div class="card">{@render children()}</div>

<!-- Usage (same) -->
<Card><p>Content</p></Card>
```

**Svelte 4 (named slots):**
```svelte
<!-- Card.svelte -->
<div class="card">
  <div class="header"><slot name="header" /></div>
  <slot />
  <div class="footer"><slot name="footer" /></div>
</div>

<!-- Usage -->
<Card>
  <h2 slot="header">Title</h2>
  <p>Body</p>
  <button slot="footer">OK</button>
</Card>
```

**Svelte 5 (named snippets):**
```svelte
<!-- Card.svelte -->
<script>
  import type { Snippet } from 'svelte';
  let { header, children, footer }: {
    header?: Snippet;
    children: Snippet;
    footer?: Snippet;
  } = $props();
</script>
<div class="card">
  {#if header}<div class="header">{@render header()}</div>{/if}
  {@render children()}
  {#if footer}<div class="footer">{@render footer()}</div>{/if}
</div>

<!-- Usage -->
<Card>
  {#snippet header()}<h2>Title</h2>{/snippet}
  <p>Body</p>
  {#snippet footer()}<button>OK</button>{/snippet}
</Card>
```

**Svelte 4 (slot props):**
```svelte
<!-- List.svelte -->
<slot items={filteredItems} />

<!-- Usage -->
<List let:items>
  {#each items as item}<p>{item}</p>{/each}
</List>
```

**Svelte 5 (snippet parameters):**
```svelte
<!-- List.svelte -->
<script>
  import type { Snippet } from 'svelte';
  let { children }: { children: Snippet<[typeof filteredItems]> } = $props();
</script>
{@render children(filteredItems)}

<!-- Usage -->
<List>
  {#snippet children(items)}
    {#each items as item}<p>{item}</p>{/each}
  {/snippet}
</List>
```

### Lifecycle Hooks → $effect

**Svelte 4:**
```svelte
<script>
  import { onMount, onDestroy, beforeUpdate, afterUpdate } from 'svelte';

  onMount(() => {
    const interval = setInterval(tick, 1000);
    return () => clearInterval(interval); // cleanup = onDestroy
  });
  beforeUpdate(() => { /* before DOM update */ });
  afterUpdate(() => { /* after DOM update */ });
</script>
```

**Svelte 5:**
```svelte
<script>
  // onMount + onDestroy → $effect
  $effect(() => {
    const interval = setInterval(tick, 1000);
    return () => clearInterval(interval);
  });

  // beforeUpdate → $effect.pre
  $effect.pre(() => { /* before DOM update */ });

  // afterUpdate → $effect (runs after DOM update by default)
  $effect(() => { /* after DOM update */ });
</script>
```

**Note:** `onMount` still works but `$effect` is preferred. `onMount` callbacks don't track reactive dependencies.

### Reactive Classes and Stores

**Svelte 4 (class with store):**
```ts
import { writable } from 'svelte/store';

export class TodoList {
  items = writable([]);
  add(item) { this.items.update(list => [...list, item]); }
}
```

**Svelte 5 (class with $state):**
```ts
// TodoList.svelte.ts
export class TodoList {
  items = $state<string[]>([]);
  add(item: string) { this.items.push(item); }
  get count() { return this.items.length; }
}
```

Classes with `$state` fields are deeply reactive. Use `$state.raw` for non-reactive fields.

---

## SvelteKit 1 → SvelteKit 2 Migration

### Breaking Changes

1. **Minimum Node.js version: 18.13+**

2. **`redirect` and `error` are now thrown, not returned:**
   ```ts
   // SvelteKit 1 (both worked)
   return redirect(303, '/login');
   throw redirect(303, '/login');

   // SvelteKit 2 (must throw)
   throw redirect(303, '/login');
   throw error(404, 'Not found');
   ```

3. **`$app/state` replaces `$app/stores` for page data:**
   ```svelte
   <!-- SvelteKit 1 -->
   <script>
     import { page } from '$app/stores';
     $: url = $page.url;
   </script>

   <!-- SvelteKit 2 + Svelte 5 -->
   <script>
     import { page } from '$app/state';
     // page is a reactive object, no $ prefix
   </script>
   <p>{page.url.pathname}</p>
   ```

4. **`load` function `depends` is stricter** — must use valid URL schemes or `app:` prefix.

5. **`cookies.set/delete` requires `path`:**
   ```ts
   // SvelteKit 1
   cookies.set('name', 'value');

   // SvelteKit 2
   cookies.set('name', 'value', { path: '/' });  // path required
   cookies.delete('name', { path: '/' });         // path required
   ```

6. **`resolvePath` replaced with `resolveRoute`:**
   ```ts
   // SvelteKit 1
   import { resolvePath } from '@sveltejs/kit';

   // SvelteKit 2
   import { resolveRoute } from '$app/paths';
   const path = resolveRoute('/blog/[slug]', { slug: 'hello' });
   ```

7. **`goto()` changes:** relative paths now resolve against the current URL, not the page route.

8. **`preloadData` returns different shape:**
   ```ts
   // SvelteKit 2
   const result = await preloadData('/url');
   if (result.type === 'loaded') {
     // result.data, result.status
   }
   ```

9. **Dynamic env requires adapter support** — `$env/dynamic/*` in prerendered pages requires specific adapter handling.

10. **Top-level promise handling in load:** Promises returned (not awaited) from load are streamed. Wrap in `Promise.resolve()` if you want immediate resolution.

---

## Common Breaking Changes

### Event Attribute Syntax

```svelte
<!-- Svelte 4 -->
<button on:click={handler}>Click</button>
<button on:click|preventDefault={handler}>Click</button>
<input on:input={handler} />

<!-- Svelte 5 -->
<button onclick={handler}>Click</button>
<button onclick={(e) => { e.preventDefault(); handler(e); }}>Click</button>
<input oninput={handler} />
```

**Modifiers removed.** `|preventDefault`, `|stopPropagation`, `|once`, `|self` — handle in the callback:

```svelte
<script>
  function handleClick(e) {
    e.preventDefault();
    e.stopPropagation();
    // ... handler logic
  }
</script>
```

### Transition Directive Syntax

```svelte
<!-- Svelte 4 — unchanged in Svelte 5 -->
<div transition:fade={{ duration: 300 }}>...</div>
<div in:fly={{ y: -20 }} out:fade>...</div>
```

Transitions still use the directive syntax. No changes needed.

### Action Directive Syntax

```svelte
<!-- Svelte 4 — unchanged in Svelte 5 -->
<div use:clickOutside>...</div>
<input use:focus={shouldFocus} />
```

Actions still use `use:` syntax. No changes needed.

### bind: Syntax

```svelte
<!-- Svelte 4 — unchanged in Svelte 5 -->
<input bind:value={name} />
<div bind:clientWidth={w} />
```

Bindings still use `bind:` syntax. For component bindings, the prop must use `$bindable()`:

```svelte
<!-- Component with bindable prop (Svelte 5) -->
<script>
  let { value = $bindable('') } = $props();
</script>
```

### Component Instantiation (Advanced)

```ts
// Svelte 4
const app = new App({ target: document.body, props: { name: 'world' } });
app.$set({ name: 'Svelte' });
app.$destroy();

// Svelte 5
import { mount, unmount } from 'svelte';
const app = mount(App, { target: document.body, props: { name: 'world' } });
// No $set — pass reactive state via props
unmount(app);
```

---

## Codemods and Migration Tools

### Official Migration Script

```bash
# Run the Svelte 5 migration tool
npx sv migrate svelte-5

# For SvelteKit 2 migration
npx sv migrate sveltekit-2
```

The migration script handles:
- `export let` → `$props()`
- `$:` reactive declarations → `$derived`
- `$:` reactive statements → `$effect`
- `createEventDispatcher` → callback props
- `on:event` directives → `onevent` attributes
- Slot syntax → snippet syntax
- `$$props` / `$$restProps` → rest `$props()`

**Always review the output.** The codemod is conservative but not perfect:
- Complex `$:` blocks may need manual `$derived.by()` conversion
- Event forwarding requires manual attention
- Store `$` prefix removal needs careful review
- Some edge cases with slot forwarding

### Manual Migration Checklist

1. ☐ Update `svelte` and `@sveltejs/kit` to latest versions
2. ☐ Run `npx sv migrate svelte-5` (or `sveltekit-2`)
3. ☐ Review and fix all automated changes
4. ☐ Convert remaining `export let` to `$props()`
5. ☐ Replace `$:` with `$derived` or `$effect` as appropriate
6. ☐ Replace `createEventDispatcher` with callback props
7. ☐ Replace `on:event` with `onevent` attributes
8. ☐ Convert named slots to snippets
9. ☐ Replace `$app/stores` with `$app/state`
10. ☐ Migrate `.ts` store files to `.svelte.ts` with runes
11. ☐ Update component instantiation if using `new Component()`
12. ☐ Remove event modifiers (`|preventDefault`) — handle in callbacks
13. ☐ Add `{ path: '/' }` to all `cookies.set/delete` calls
14. ☐ Ensure `throw` (not `return`) for `redirect()` and `error()`
15. ☐ Run tests and fix any failures
16. ☐ Test SSR, hydration, and client navigation

### Incremental Migration

Svelte 5 supports a compatibility mode. You don't have to migrate everything at once:
- Old `export let` syntax still works (with deprecation warnings)
- Stores still work
- `on:event` still works
- Slots still work

Enable runes per-component or project-wide:
```svelte
<!-- Per-component opt-in (Svelte 5 legacy mode) -->
<svelte:options runes={true} />
```

```js
// svelte.config.js — project-wide
const config = {
  compilerOptions: {
    runes: true  // enforce runes in all components
  }
};
```
