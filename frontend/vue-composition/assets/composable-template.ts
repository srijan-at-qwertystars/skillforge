// ============================================================================
// composable-template.ts — Standard composable template
// ============================================================================
// Copy and customize. Includes:
//   - Options pattern for configuration
//   - SSR safety guards
//   - Cleanup on unmount
//   - TypeScript generics
//   - MaybeRefOrGetter inputs
// ============================================================================

import {
  ref,
  computed,
  watch,
  toValue,
  onMounted,
  onUnmounted,
  getCurrentInstance,
  type MaybeRefOrGetter,
  type Ref,
  type ComputedRef,
} from 'vue'

// --- Types ---

export interface UseFeatureOptions {
  /** Run automatically on mount. Default: true */
  immediate?: boolean
  /** Debounce interval in ms. Default: 0 (no debounce) */
  debounce?: number
}

export interface UseFeatureReturn<T> {
  /** Main reactive data */
  data: Ref<T | null>
  /** Loading state */
  loading: Ref<boolean>
  /** Error state */
  error: Ref<Error | null>
  /** Whether data is available */
  isReady: ComputedRef<boolean>
  /** Execute the main operation */
  execute: () => Promise<void>
  /** Reset all state */
  reset: () => void
}

// --- Composable ---

/**
 * useFeature — Description of what this composable does.
 *
 * @param source - Reactive input (accepts ref, getter, or plain value)
 * @param options - Configuration options
 * @returns Reactive state and methods
 *
 * @example
 * ```vue
 * <script setup lang="ts">
 * const { data, loading, error, execute } = useFeature(() => props.id)
 * </script>
 * ```
 */
export function useFeature<T = unknown>(
  source: MaybeRefOrGetter<string>,
  options: UseFeatureOptions = {}
): UseFeatureReturn<T> {
  const { immediate = true, debounce = 0 } = options

  // --- SSR Safety ---
  const isClient = typeof window !== 'undefined'
  const instance = getCurrentInstance()

  // --- State ---
  const data = ref<T | null>(null) as Ref<T | null>
  const loading = ref(false)
  const error = ref<Error | null>(null)
  let abortController: AbortController | null = null
  let debounceTimer: ReturnType<typeof setTimeout> | null = null

  // --- Computed ---
  const isReady = computed(() => data.value !== null && !loading.value)

  // --- Core Logic ---
  async function execute() {
    // Abort previous request
    abortController?.abort()
    abortController = new AbortController()

    const currentSource = toValue(source)
    loading.value = true
    error.value = null

    try {
      // TODO: Replace with actual implementation
      const response = await fetch(currentSource, {
        signal: abortController.signal,
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      data.value = await response.json()
    } catch (e) {
      if (e instanceof DOMException && e.name === 'AbortError') return
      error.value = e instanceof Error ? e : new Error(String(e))
    } finally {
      loading.value = false
    }
  }

  function debouncedExecute() {
    if (debounce <= 0) {
      execute()
      return
    }
    if (debounceTimer) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(execute, debounce)
  }

  function reset() {
    data.value = null
    loading.value = false
    error.value = null
    abortController?.abort()
    if (debounceTimer) clearTimeout(debounceTimer)
  }

  // --- Watchers ---
  // Re-execute when source changes
  watch(
    () => toValue(source),
    () => debouncedExecute(),
    { immediate: false }
  )

  // --- Lifecycle ---
  if (isClient) {
    onMounted(() => {
      if (immediate) execute()
    })
  }

  onUnmounted(() => {
    abortController?.abort()
    if (debounceTimer) clearTimeout(debounceTimer)
  })

  return {
    data,
    loading,
    error,
    isReady,
    execute,
    reset,
  }
}
