// solid-component.tsx — SolidJS component template with signals, effects, cleanup, and props.
//
// Usage: Copy and adapt for new components.
// Includes: createSignal, createEffect, onMount, onCleanup, splitProps, Show.

import {
  createSignal,
  createEffect,
  createMemo,
  onMount,
  onCleanup,
  splitProps,
  Show,
  type ParentProps,
  type JSX,
} from "solid-js";

// -- Types --
interface ComponentProps {
  title: string;
  initialCount?: number;
  onCountChange?: (count: number) => void;
}

// -- Component --
function MyComponent(props: ParentProps<ComponentProps>) {
  // Split local props from pass-through props (preserves reactivity)
  const [local, others] = splitProps(props, [
    "title",
    "initialCount",
    "onCountChange",
    "children",
  ]);

  // Reactive state
  const [count, setCount] = createSignal(local.initialCount ?? 0);
  const [isActive, setIsActive] = createSignal(false);

  // Derived value (cached, recalculates only when count changes)
  const doubled = createMemo(() => count() * 2);

  // Side effect — auto-tracks count()
  createEffect(() => {
    local.onCountChange?.(count());
  });

  // DOM ref (definite assignment — set by ref={} before onMount)
  let containerRef!: HTMLDivElement;

  // Lifecycle: runs once after initial render
  onMount(() => {
    console.log("Mounted, container width:", containerRef.offsetWidth);

    // Timer with cleanup to prevent leaks
    const interval = setInterval(() => setCount((c) => c + 1), 5000);
    onCleanup(() => clearInterval(interval));
  });

  // Event handler
  const handleClick: JSX.EventHandler<HTMLButtonElement, MouseEvent> = () => {
    setCount((c) => c + 1);
  };

  // Component body runs ONCE — put reactive logic in JSX or effects
  return (
    <div ref={containerRef} {...others}>
      <h2>{local.title}</h2>

      <p>Count: {count()} (doubled: {doubled()})</p>

      <button onClick={handleClick}>Increment</button>

      <button onClick={() => setIsActive((a) => !a)}>
        {isActive() ? "Deactivate" : "Activate"}
      </button>

      <Show when={isActive()} fallback={<p>Inactive</p>}>
        <p>Component is active!</p>
      </Show>

      {/* Render children */}
      <Show when={local.children}>
        <div class="children-wrapper">{local.children}</div>
      </Show>
    </div>
  );
}

export default MyComponent;
