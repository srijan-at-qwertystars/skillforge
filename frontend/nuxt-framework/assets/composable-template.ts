// =============================================================================
// composable-template.ts — Custom composable template with SSR safety
//
// Usage: Copy to composables/use<Name>.ts
// Composables in composables/ are auto-imported by Nuxt.
// =============================================================================

// ---- Pattern 1: Simple state composable (SSR-safe with useState) ----

export const useCounter = () => {
  // useState is SSR-safe — state is serialized on server, hydrated on client
  // The key ('counter') must be unique across the app
  const count = useState<number>('counter', () => 0)

  const increment = () => { count.value++ }
  const decrement = () => { count.value-- }
  const reset = () => { count.value = 0 }

  return { count: readonly(count), increment, decrement, reset }
}


// ---- Pattern 2: Data fetching composable ----

interface User {
  id: string
  name: string
  email: string
}

export const useUser = (userId: MaybeRef<string>) => {
  const id = toRef(userId)

  const { data: user, status, error, refresh } = useFetch<User>(
    () => `/api/users/${id.value}`,
    {
      key: `user-${id.value}`,
      // Don't fetch if no ID
      immediate: !!id.value,
    }
  )

  return { user, status, error, refresh }
}


// ---- Pattern 3: Client-only composable (browser APIs) ----

export const useMediaQuery = (query: string) => {
  const matches = ref(false)

  // Browser APIs only available on client
  if (import.meta.client) {
    const mediaQuery = window.matchMedia(query)
    matches.value = mediaQuery.matches

    // Listen for changes
    const handler = (e: MediaQueryListEvent) => {
      matches.value = e.matches
    }
    mediaQuery.addEventListener('change', handler)

    // Cleanup on unmount
    onUnmounted(() => {
      mediaQuery.removeEventListener('change', handler)
    })
  }

  return { matches: readonly(matches) }
}

// Usage: const { matches: isMobile } = useMediaQuery('(max-width: 768px)')


// ---- Pattern 4: Auth composable with cookie persistence ----

interface AuthUser {
  id: string
  name: string
  role: string
}

export const useAuth = () => {
  const user = useState<AuthUser | null>('auth-user', () => null)
  const token = useCookie<string | null>('auth-token', {
    maxAge: 60 * 60 * 24 * 7, // 7 days
    secure: true,
    sameSite: 'lax',
  })
  const isLoggedIn = computed(() => !!user.value)

  const login = async (credentials: { email: string; password: string }) => {
    const response = await $fetch<{ user: AuthUser; token: string }>('/api/auth/login', {
      method: 'POST',
      body: credentials,
    })
    user.value = response.user
    token.value = response.token
  }

  const logout = async () => {
    await $fetch('/api/auth/logout', { method: 'POST' }).catch(() => {})
    user.value = null
    token.value = null
    await navigateTo('/login')
  }

  const fetchUser = async () => {
    if (!token.value) return
    try {
      user.value = await $fetch<AuthUser>('/api/auth/me', {
        headers: { Authorization: `Bearer ${token.value}` },
      })
    } catch {
      user.value = null
      token.value = null
    }
  }

  return { user: readonly(user), isLoggedIn, token, login, logout, fetchUser }
}


// ---- Pattern 5: Form composable with validation ----

export const useForm = <T extends Record<string, any>>(initialValues: T) => {
  const values = ref<T>({ ...initialValues }) as Ref<T>
  const errors = ref<Partial<Record<keyof T, string>>>({})
  const isSubmitting = ref(false)

  const setError = (field: keyof T, message: string) => {
    errors.value[field] = message
  }

  const clearErrors = () => {
    errors.value = {}
  }

  const reset = () => {
    values.value = { ...initialValues }
    clearErrors()
  }

  const handleSubmit = (
    onSubmit: (values: T) => Promise<void>,
    validate?: (values: T) => Partial<Record<keyof T, string>> | null
  ) => {
    return async () => {
      clearErrors()

      if (validate) {
        const validationErrors = validate(values.value)
        if (validationErrors && Object.keys(validationErrors).length > 0) {
          errors.value = validationErrors
          return
        }
      }

      isSubmitting.value = true
      try {
        await onSubmit(values.value)
      } finally {
        isSubmitting.value = false
      }
    }
  }

  return { values, errors, isSubmitting, setError, clearErrors, reset, handleSubmit }
}
