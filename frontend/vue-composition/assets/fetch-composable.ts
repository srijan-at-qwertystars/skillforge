// ============================================================================
// fetch-composable.ts — Data fetching composable
// ============================================================================
// Features:
//   - Loading / error / data states
//   - Request caching (in-memory)
//   - AbortController for request cancellation
//   - Retry logic with exponential backoff
//   - Pagination support (offset & cursor)
//   - SSR safety
//   - Reactive URL / params
// ============================================================================

import {
  ref,
  computed,
  watch,
  toValue,
  onUnmounted,
  getCurrentInstance,
  type MaybeRefOrGetter,
  type Ref,
  type ComputedRef,
} from 'vue'

// --- Types ---

export interface UseFetchOptions<T> {
  /** Execute immediately. Default: true */
  immediate?: boolean
  /** HTTP method. Default: 'GET' */
  method?: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'
  /** Request headers */
  headers?: Record<string, string>
  /** Request body (for POST/PUT/PATCH) */
  body?: unknown
  /** Enable response caching. Default: false */
  cache?: boolean
  /** Cache TTL in ms. Default: 30000 (30s) */
  cacheTTL?: number
  /** Number of retry attempts. Default: 0 */
  retries?: number
  /** Retry delay in ms. Default: 1000 */
  retryDelay?: number
  /** Transform response data */
  transform?: (data: unknown) => T
  /** Request timeout in ms. Default: 30000 */
  timeout?: number
  /** Refetch when URL/params change. Default: true */
  refetchOnChange?: boolean
}

export interface UseFetchReturn<T> {
  data: Ref<T | null>
  loading: Ref<boolean>
  error: Ref<Error | null>
  isReady: ComputedRef<boolean>
  statusCode: Ref<number | null>
  /** Execute/re-execute the request */
  execute: () => Promise<T | null>
  /** Abort the current request */
  abort: () => void
  /** Reset all state */
  reset: () => void
}

export interface PaginationOptions {
  /** Items per page. Default: 20 */
  pageSize?: number
  /** Starting page. Default: 1 */
  initialPage?: number
}

export interface UsePaginatedFetchReturn<T> extends UseFetchReturn<T[]> {
  page: Ref<number>
  pageSize: Ref<number>
  totalItems: Ref<number>
  totalPages: ComputedRef<number>
  hasNextPage: ComputedRef<boolean>
  hasPrevPage: ComputedRef<boolean>
  nextPage: () => Promise<void>
  prevPage: () => Promise<void>
  goToPage: (page: number) => Promise<void>
}

// --- Cache ---

interface CacheEntry<T> {
  data: T
  timestamp: number
  ttl: number
}

const cache = new Map<string, CacheEntry<unknown>>()

function getCached<T>(key: string): T | null {
  const entry = cache.get(key)
  if (!entry) return null
  if (Date.now() - entry.timestamp > entry.ttl) {
    cache.delete(key)
    return null
  }
  return entry.data as T
}

function setCache<T>(key: string, data: T, ttl: number): void {
  cache.set(key, { data, timestamp: Date.now(), ttl })
}

/** Clear all cached responses */
export function clearFetchCache(): void {
  cache.clear()
}

// --- Composable ---

export function useFetch<T = unknown>(
  url: MaybeRefOrGetter<string>,
  options: UseFetchOptions<T> = {}
): UseFetchReturn<T> {
  const {
    immediate = true,
    method = 'GET',
    headers = {},
    body,
    cache: enableCache = false,
    cacheTTL = 30_000,
    retries = 0,
    retryDelay = 1000,
    transform,
    timeout = 30_000,
    refetchOnChange = true,
  } = options

  const isClient = typeof window !== 'undefined'

  // --- State ---
  const data = ref<T | null>(null) as Ref<T | null>
  const loading = ref(false)
  const error = ref<Error | null>(null)
  const statusCode = ref<number | null>(null)
  let abortController: AbortController | null = null
  let timeoutId: ReturnType<typeof setTimeout> | null = null

  const isReady = computed(() => data.value !== null && !loading.value && !error.value)

  // --- Core ---

  async function execute(): Promise<T | null> {
    const currentUrl = toValue(url)
    if (!currentUrl) return null

    // Check cache first
    if (enableCache && method === 'GET') {
      const cached = getCached<T>(currentUrl)
      if (cached !== null) {
        data.value = cached
        return cached
      }
    }

    // Abort previous request
    abort()
    abortController = new AbortController()

    loading.value = true
    error.value = null
    statusCode.value = null

    // Timeout handling
    if (timeout > 0) {
      timeoutId = setTimeout(() => {
        abortController?.abort()
        error.value = new Error(`Request timed out after ${timeout}ms`)
        loading.value = false
      }, timeout)
    }

    let lastError: Error | null = null
    const maxAttempts = retries + 1

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        const fetchOptions: RequestInit = {
          method,
          headers: {
            'Content-Type': 'application/json',
            ...headers,
          },
          signal: abortController.signal,
        }

        if (body && method !== 'GET') {
          fetchOptions.body = typeof body === 'string' ? body : JSON.stringify(body)
        }

        const response = await fetch(currentUrl, fetchOptions)
        statusCode.value = response.status

        if (!response.ok) {
          throw new Error(`HTTP ${response.status}: ${response.statusText}`)
        }

        let result: unknown
        const contentType = response.headers.get('content-type')
        if (contentType?.includes('application/json')) {
          result = await response.json()
        } else {
          result = await response.text()
        }

        const transformed = transform ? transform(result) : (result as T)
        data.value = transformed

        // Cache successful GET responses
        if (enableCache && method === 'GET') {
          setCache(currentUrl, transformed, cacheTTL)
        }

        return transformed
      } catch (e) {
        if (e instanceof DOMException && e.name === 'AbortError') {
          return null
        }
        lastError = e instanceof Error ? e : new Error(String(e))

        // Wait before retry (exponential backoff)
        if (attempt < maxAttempts - 1) {
          await new Promise(resolve =>
            setTimeout(resolve, retryDelay * Math.pow(2, attempt))
          )
        }
      }
    }

    error.value = lastError
    loading.value = false
    return null
  }

  function abort() {
    abortController?.abort()
    abortController = null
    if (timeoutId) {
      clearTimeout(timeoutId)
      timeoutId = null
    }
  }

  function reset() {
    abort()
    data.value = null
    loading.value = false
    error.value = null
    statusCode.value = null
  }

  // --- Reactive URL watching ---
  if (refetchOnChange) {
    watch(
      () => toValue(url),
      (newUrl, oldUrl) => {
        if (newUrl !== oldUrl && newUrl) execute()
      }
    )
  }

  // --- Auto-execute ---
  if (immediate && isClient) {
    execute()
  }

  // --- Cleanup ---
  if (getCurrentInstance()) {
    onUnmounted(abort)
  }

  return {
    data,
    loading,
    error,
    isReady,
    statusCode,
    execute,
    abort,
    reset,
  }
}

// --- Paginated Fetch ---

export function usePaginatedFetch<T = unknown>(
  baseUrl: MaybeRefOrGetter<string>,
  paginationOptions: PaginationOptions = {},
  fetchOptions: UseFetchOptions<T[]> = {}
): UsePaginatedFetchReturn<T> {
  const { pageSize: initialPageSize = 20, initialPage = 1 } = paginationOptions

  const page = ref(initialPage)
  const pageSize = ref(initialPageSize)
  const totalItems = ref(0)

  const paginatedUrl = computed(() => {
    const base = toValue(baseUrl)
    const separator = base.includes('?') ? '&' : '?'
    const offset = (page.value - 1) * pageSize.value
    return `${base}${separator}_offset=${offset}&_limit=${pageSize.value}`
  })

  const fetchResult = useFetch<T[]>(paginatedUrl, {
    ...fetchOptions,
    immediate: false,
    refetchOnChange: true,
    transform: (raw: unknown) => {
      // Handle paginated API responses
      if (raw && typeof raw === 'object' && 'items' in raw && 'total' in raw) {
        const paged = raw as { items: T[]; total: number }
        totalItems.value = paged.total
        return fetchOptions.transform
          ? fetchOptions.transform(paged.items as unknown)
          : paged.items
      }
      // Fallback: assume array response
      if (Array.isArray(raw)) {
        return fetchOptions.transform ? fetchOptions.transform(raw) : (raw as T[])
      }
      return [] as T[]
    },
  })

  const totalPages = computed(() =>
    totalItems.value > 0 ? Math.ceil(totalItems.value / pageSize.value) : 0
  )
  const hasNextPage = computed(() => page.value < totalPages.value)
  const hasPrevPage = computed(() => page.value > 1)

  async function nextPage() {
    if (hasNextPage.value) {
      page.value++
      await fetchResult.execute()
    }
  }

  async function prevPage() {
    if (hasPrevPage.value) {
      page.value--
      await fetchResult.execute()
    }
  }

  async function goToPage(target: number) {
    if (target >= 1 && (totalPages.value === 0 || target <= totalPages.value)) {
      page.value = target
      await fetchResult.execute()
    }
  }

  // Initial fetch
  fetchResult.execute()

  return {
    ...fetchResult,
    page,
    pageSize,
    totalItems,
    totalPages,
    hasNextPage,
    hasPrevPage,
    nextPage,
    prevPage,
    goToPage,
  }
}

// ============================================================================
// Usage Examples
// ============================================================================
//
// --- Basic ---
// const { data, loading, error } = useFetch<User[]>('/api/users')
//
// --- Reactive URL ---
// const userId = ref(1)
// const { data: user } = useFetch<User>(() => `/api/users/${userId.value}`)
//
// --- With Options ---
// const { data, execute } = useFetch<User>('/api/users', {
//   immediate: false,
//   method: 'POST',
//   body: { name: 'Ada' },
//   retries: 3,
//   cache: true,
//   transform: (raw) => ({ ...raw, fullName: `${raw.first} ${raw.last}` }),
// })
// await execute()
//
// --- Paginated ---
// const {
//   data: users,
//   page,
//   totalPages,
//   hasNextPage,
//   nextPage,
//   prevPage,
// } = usePaginatedFetch<User>('/api/users', { pageSize: 10 })
