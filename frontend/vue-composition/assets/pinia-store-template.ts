// ============================================================================
// pinia-store-template.ts — Setup store template
// ============================================================================
// Copy and customize. Includes:
//   - Setup store syntax (recommended)
//   - State, getters, actions
//   - Persistence plugin support
//   - DevTools support
//   - $reset implementation (not auto-generated for setup stores)
//   - Subscription example
// ============================================================================

import { ref, computed } from 'vue'
import { defineStore, acceptHMRUpdate } from 'pinia'

// --- Types ---

export interface FeatureItem {
  id: string
  name: string
  status: 'active' | 'inactive' | 'archived'
  createdAt: Date
  updatedAt: Date
}

export interface FeatureFilters {
  status: FeatureItem['status'] | 'all'
  search: string
}

// --- Store ---

export const useFeatureStore = defineStore('feature', () => {
  // ========== State ==========

  const items = ref<FeatureItem[]>([])
  const filters = ref<FeatureFilters>({
    status: 'all',
    search: '',
  })
  const loading = ref(false)
  const error = ref<string | null>(null)
  const selectedId = ref<string | null>(null)

  // ========== Getters (computed) ==========

  const filteredItems = computed(() => {
    let result = items.value

    if (filters.value.status !== 'all') {
      result = result.filter(item => item.status === filters.value.status)
    }

    if (filters.value.search) {
      const query = filters.value.search.toLowerCase()
      result = result.filter(item =>
        item.name.toLowerCase().includes(query)
      )
    }

    return result
  })

  const selectedItem = computed(() =>
    items.value.find(item => item.id === selectedId.value) ?? null
  )

  const totalCount = computed(() => items.value.length)
  const activeCount = computed(() =>
    items.value.filter(item => item.status === 'active').length
  )
  const isEmpty = computed(() => items.value.length === 0)

  // ========== Actions ==========

  async function fetchItems() {
    loading.value = true
    error.value = null
    try {
      // TODO: Replace with actual API call
      const response = await fetch('/api/features')
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      items.value = await response.json()
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Unknown error'
      throw e
    } finally {
      loading.value = false
    }
  }

  async function createItem(data: Omit<FeatureItem, 'id' | 'createdAt' | 'updatedAt'>) {
    const newItem: FeatureItem = {
      ...data,
      id: crypto.randomUUID(),
      createdAt: new Date(),
      updatedAt: new Date(),
    }

    // Optimistic update
    items.value.push(newItem)
    try {
      // TODO: Replace with actual API call
      await fetch('/api/features', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(newItem),
      })
    } catch (e) {
      // Rollback on failure
      items.value = items.value.filter(item => item.id !== newItem.id)
      throw e
    }

    return newItem
  }

  async function updateItem(id: string, updates: Partial<FeatureItem>) {
    const index = items.value.findIndex(item => item.id === id)
    if (index === -1) throw new Error(`Item ${id} not found`)

    const previous = items.value[index]!
    const updated = { ...previous, ...updates, updatedAt: new Date() }

    // Optimistic update
    items.value[index] = updated
    try {
      await fetch(`/api/features/${id}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(updates),
      })
    } catch (e) {
      items.value[index] = previous // Rollback
      throw e
    }
  }

  async function deleteItem(id: string) {
    const index = items.value.findIndex(item => item.id === id)
    if (index === -1) return

    const removed = items.value.splice(index, 1)[0]!
    try {
      await fetch(`/api/features/${id}`, { method: 'DELETE' })
    } catch (e) {
      items.value.splice(index, 0, removed) // Rollback
      throw e
    }

    if (selectedId.value === id) selectedId.value = null
  }

  function selectItem(id: string | null) {
    selectedId.value = id
  }

  function setFilters(newFilters: Partial<FeatureFilters>) {
    Object.assign(filters.value, newFilters)
  }

  // $reset() is not auto-generated for setup stores — implement manually
  function $reset() {
    items.value = []
    filters.value = { status: 'all', search: '' }
    loading.value = false
    error.value = null
    selectedId.value = null
  }

  // ========== Return ==========

  return {
    // State
    items,
    filters,
    loading,
    error,
    selectedId,

    // Getters
    filteredItems,
    selectedItem,
    totalCount,
    activeCount,
    isEmpty,

    // Actions
    fetchItems,
    createItem,
    updateItem,
    deleteItem,
    selectItem,
    setFilters,
    $reset,
  }
},
// --- Plugin Options ---
{
  // pinia-plugin-persistedstate options (if installed)
  // persist: {
  //   key: 'feature-store',
  //   storage: localStorage,
  //   pick: ['items', 'filters'], // Only persist specific state
  // },
})

// --- HMR Support ---
// Enables hot module replacement for this store during development
if (import.meta.hot) {
  import.meta.hot.accept(acceptHMRUpdate(useFeatureStore, import.meta.hot))
}

// ============================================================================
// Usage in components:
// ============================================================================
//
// <script setup lang="ts">
// import { storeToRefs } from 'pinia'
// import { useFeatureStore } from '@/stores/feature'
//
// const store = useFeatureStore()
// const { filteredItems, loading, selectedItem } = storeToRefs(store)
// const { fetchItems, createItem, deleteItem } = store
//
// // ⚠️ CRITICAL: storeToRefs for state/getters, direct destructure for actions
//
// onMounted(() => fetchItems())
// </script>
