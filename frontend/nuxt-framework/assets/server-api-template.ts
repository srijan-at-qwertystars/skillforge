// =============================================================================
// server-api-template.ts — Nitro API route template with validation
//
// Usage: Copy to server/api/<name>.<method>.ts
// Example: server/api/posts.get.ts, server/api/posts.post.ts
// =============================================================================

import { z } from 'zod'

// ---- GET handler with query validation ----
// File: server/api/items.get.ts
export default defineEventHandler(async (event) => {
  // Parse and validate query parameters
  const querySchema = z.object({
    page: z.coerce.number().int().min(1).default(1),
    limit: z.coerce.number().int().min(1).max(100).default(20),
    search: z.string().optional(),
    sort: z.enum(['created', 'updated', 'name']).default('created'),
  })

  const query = await getValidatedQuery(event, querySchema.parse)

  // Access runtime config (for API keys, DB urls, etc.)
  const config = useRuntimeConfig()

  // Access context set by server middleware (e.g., authenticated user)
  const user = event.context.user

  // Fetch data (replace with your data source)
  const items = await fetchItems({
    page: query.page,
    limit: query.limit,
    search: query.search,
    sort: query.sort,
  })

  return {
    data: items,
    meta: {
      page: query.page,
      limit: query.limit,
      total: items.length,
    },
  }
})

// ---- POST handler with body validation ----
// File: server/api/items.post.ts
/*
export default defineEventHandler(async (event) => {
  const bodySchema = z.object({
    name: z.string().min(1).max(255),
    description: z.string().max(1000).optional(),
    status: z.enum(['draft', 'published', 'archived']).default('draft'),
    tags: z.array(z.string()).max(10).default([]),
  })

  const body = await readValidatedBody(event, bodySchema.parse)

  // Create item (replace with your data source)
  const item = await createItem(body)

  setResponseStatus(event, 201)
  return item
})
*/

// ---- GET by ID handler with param validation ----
// File: server/api/items/[id].get.ts
/*
export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')

  if (!id || !/^[a-zA-Z0-9_-]+$/.test(id)) {
    throw createError({
      statusCode: 400,
      statusMessage: 'Invalid ID format',
    })
  }

  const item = await getItemById(id)

  if (!item) {
    throw createError({
      statusCode: 404,
      statusMessage: 'Item not found',
    })
  }

  return item
})
*/

// ---- PUT handler (update) ----
// File: server/api/items/[id].put.ts
/*
export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')

  const bodySchema = z.object({
    name: z.string().min(1).max(255).optional(),
    description: z.string().max(1000).optional(),
    status: z.enum(['draft', 'published', 'archived']).optional(),
  })

  const body = await readValidatedBody(event, bodySchema.parse)

  const updated = await updateItem(id!, body)

  if (!updated) {
    throw createError({ statusCode: 404, statusMessage: 'Item not found' })
  }

  return updated
})
*/

// ---- DELETE handler ----
// File: server/api/items/[id].delete.ts
/*
export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')

  const deleted = await deleteItem(id!)

  if (!deleted) {
    throw createError({ statusCode: 404, statusMessage: 'Item not found' })
  }

  setResponseStatus(event, 204)
  return null
})
*/

// ---- Cached handler (for expensive operations) ----
// File: server/api/stats.get.ts
/*
export default defineCachedEventHandler(async (event) => {
  const stats = await computeExpensiveStats()
  return stats
}, {
  maxAge: 60 * 60,        // Cache for 1 hour
  staleMaxAge: 60 * 60 * 24,
  swr: true,
  name: 'api-stats',
})
*/
