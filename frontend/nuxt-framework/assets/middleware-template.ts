// =============================================================================
// middleware-template.ts — Auth middleware templates for Nuxt 3
//
// Usage: Copy to middleware/auth.ts (or middleware/auth.global.ts for global)
// Apply per page: definePageMeta({ middleware: ['auth'] })
// =============================================================================

// ---- Pattern 1: Basic auth guard (redirect unauthenticated users) ----

// middleware/auth.ts
export default defineNuxtRouteMiddleware((to, _from) => {
  const { isLoggedIn } = useAuth() // Your auth composable

  if (!isLoggedIn.value) {
    // Save intended destination for post-login redirect
    return navigateTo({
      path: '/login',
      query: { redirect: to.fullPath },
    })
  }
})


// ---- Pattern 2: Role-based access control ----

// middleware/admin.ts
/*
export default defineNuxtRouteMiddleware((to) => {
  const { user, isLoggedIn } = useAuth()

  if (!isLoggedIn.value) {
    return navigateTo('/login')
  }

  if (user.value?.role !== 'admin') {
    // Return error instead of redirect for forbidden access
    return abortNavigation(
      createError({ statusCode: 403, statusMessage: 'Forbidden' })
    )
  }
})
*/


// ---- Pattern 3: Guest-only (redirect authenticated users away from login) ----

// middleware/guest.ts
/*
export default defineNuxtRouteMiddleware(() => {
  const { isLoggedIn } = useAuth()

  if (isLoggedIn.value) {
    return navigateTo('/dashboard')
  }
})
*/

// Usage: definePageMeta({ middleware: ['guest'] }) in pages/login.vue


// ---- Pattern 4: Global auth initializer (load user on every page) ----

// middleware/00.auth-init.global.ts
// Prefix with 00 to ensure it runs before other middleware
/*
export default defineNuxtRouteMiddleware(async () => {
  const { user, fetchUser } = useAuth()

  // Only fetch once per SSR request / client session
  if (!user.value) {
    await fetchUser()
  }
})
*/


// ---- Pattern 5: Page validation middleware ----

// This can also be done inline with definePageMeta's validate option
// middleware/validate-id.ts
/*
export default defineNuxtRouteMiddleware((to) => {
  const id = to.params.id as string

  // Validate route param format
  if (!/^\d+$/.test(id)) {
    return abortNavigation(
      createError({ statusCode: 400, statusMessage: 'Invalid ID' })
    )
  }
})
*/

// Usage: definePageMeta({ middleware: ['validate-id'] }) in pages/items/[id].vue


// ---- Server middleware (Nitro — runs on every server request) ----
// Place in server/middleware/

// server/middleware/auth.ts
/*
export default defineEventHandler(async (event) => {
  // Only protect API routes
  const url = getRequestURL(event)
  if (!url.pathname.startsWith('/api/')) return

  // Skip public endpoints
  const publicPaths = ['/api/auth/login', '/api/auth/register', '/api/health']
  if (publicPaths.some(p => url.pathname.startsWith(p))) return

  const token = getHeader(event, 'authorization')?.replace('Bearer ', '')
  if (!token) {
    throw createError({ statusCode: 401, statusMessage: 'Authentication required' })
  }

  try {
    const user = await verifyJwtToken(token) // Your JWT verification
    event.context.user = user
  } catch {
    throw createError({ statusCode: 401, statusMessage: 'Invalid or expired token' })
  }
})
*/
