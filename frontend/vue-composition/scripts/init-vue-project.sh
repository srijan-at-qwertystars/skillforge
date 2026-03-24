#!/usr/bin/env bash
# ============================================================================
# init-vue-project.sh — Scaffold a Vue 3 + Composition API project
# ============================================================================
# Usage:
#   ./init-vue-project.sh <project-name>
#   ./init-vue-project.sh my-app
#
# Creates a Vite + Vue 3 + TypeScript project with:
#   - Pinia (state management)
#   - VueUse (composable utilities)
#   - Vue Router 4
#   - Strict TypeScript configuration
#   - Example composable (useCounter)
#   - Organized folder structure
# ============================================================================

set -euo pipefail

PROJECT_NAME="${1:?Usage: $0 <project-name>}"

if [ -d "$PROJECT_NAME" ]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

echo "🚀 Creating Vue 3 + Composition API project: $PROJECT_NAME"

# --- Scaffold with Vite ---
npm create vite@latest "$PROJECT_NAME" -- --template vue-ts
cd "$PROJECT_NAME"

# --- Install core dependencies ---
echo "📦 Installing dependencies..."
npm install vue-router@4 pinia @vueuse/core
npm install -D @vue/test-utils @pinia/testing vitest happy-dom @vitejs/plugin-vue

# --- Strict TypeScript ---
echo "⚙️  Configuring strict TypeScript..."
cat > tsconfig.json << 'TSEOF'
{
  "compilerOptions": {
    "target": "ESNext",
    "useDefineForClassFields": true,
    "module": "ESNext",
    "lib": ["ESNext", "DOM", "DOM.Iterable"],
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "isolatedModules": true,
    "moduleDetection": "force",
    "noEmit": true,
    "jsx": "preserve",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": false,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "paths": {
      "@/*": ["./src/*"]
    },
    "types": ["vite/client", "vitest/globals"]
  },
  "include": ["src/**/*.ts", "src/**/*.tsx", "src/**/*.vue", "env.d.ts"],
  "references": [{ "path": "./tsconfig.node.json" }]
}
TSEOF

# --- Create folder structure ---
echo "📁 Creating project structure..."
mkdir -p src/{composables,stores,views,components,router,types,test}

# --- Router setup ---
cat > src/router/index.ts << 'EOF'
import { createRouter, createWebHistory } from 'vue-router'

const routes = [
  {
    path: '/',
    name: 'Home',
    component: () => import('@/views/HomeView.vue'),
  },
]

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes,
})

export default router
EOF

# --- Pinia setup ---
cat > src/stores/index.ts << 'EOF'
export { useCounterStore } from './counter'
EOF

cat > src/stores/counter.ts << 'EOF'
import { defineStore } from 'pinia'
import { ref, computed } from 'vue'

export const useCounterStore = defineStore('counter', () => {
  const count = ref(0)
  const doubled = computed(() => count.value * 2)

  function increment() {
    count.value++
  }

  function decrement() {
    count.value--
  }

  function reset() {
    count.value = 0
  }

  return { count, doubled, increment, decrement, reset }
})
EOF

# --- Example composable ---
cat > src/composables/useCounter.ts << 'EOF'
import { ref, computed, type Ref } from 'vue'

interface UseCounterOptions {
  min?: number
  max?: number
}

interface UseCounterReturn {
  count: Ref<number>
  doubled: Readonly<Ref<number>>
  increment: () => void
  decrement: () => void
  reset: () => void
}

export function useCounter(initial = 0, options: UseCounterOptions = {}): UseCounterReturn {
  const { min = -Infinity, max = Infinity } = options
  const count = ref(Math.max(min, Math.min(max, initial)))
  const doubled = computed(() => count.value * 2)

  const increment = () => {
    if (count.value < max) count.value++
  }

  const decrement = () => {
    if (count.value > min) count.value--
  }

  const reset = () => {
    count.value = Math.max(min, Math.min(max, initial))
  }

  return { count, doubled, increment, decrement, reset }
}
EOF

# --- Composable barrel export ---
cat > src/composables/index.ts << 'EOF'
export { useCounter } from './useCounter'
EOF

# --- Example composable test ---
cat > src/composables/__tests__/useCounter.test.ts << 'EOF'
import { describe, it, expect } from 'vitest'
import { useCounter } from '../useCounter'

describe('useCounter', () => {
  it('initializes with given value', () => {
    const { count } = useCounter(10)
    expect(count.value).toBe(10)
  })

  it('increments and decrements', () => {
    const { count, increment, decrement } = useCounter(0)
    increment()
    expect(count.value).toBe(1)
    decrement()
    expect(count.value).toBe(0)
  })

  it('respects min/max bounds', () => {
    const { count, increment, decrement } = useCounter(0, { min: 0, max: 3 })
    decrement()
    expect(count.value).toBe(0)
    increment(); increment(); increment(); increment()
    expect(count.value).toBe(3)
  })

  it('computes doubled value', () => {
    const { count, doubled, increment } = useCounter(5)
    expect(doubled.value).toBe(10)
    increment()
    expect(doubled.value).toBe(12)
  })

  it('resets to initial value', () => {
    const { count, increment, reset } = useCounter(5)
    increment(); increment()
    reset()
    expect(count.value).toBe(5)
  })
})
EOF

mkdir -p src/composables/__tests__

# --- HomeView ---
cat > src/views/HomeView.vue << 'EOF'
<script setup lang="ts">
import { useCounter } from '@/composables/useCounter'
import { storeToRefs } from 'pinia'
import { useCounterStore } from '@/stores/counter'

const { count: localCount, increment: localIncrement } = useCounter(0)
const store = useCounterStore()
const { count: storeCount, doubled } = storeToRefs(store)
</script>

<template>
  <main>
    <h1>Vue 3 + Composition API</h1>

    <section>
      <h2>Composable Counter</h2>
      <button @click="localIncrement">Local: {{ localCount }}</button>
    </section>

    <section>
      <h2>Pinia Store Counter</h2>
      <p>Count: {{ storeCount }} (doubled: {{ doubled }})</p>
      <button @click="store.increment">Store +1</button>
      <button @click="store.decrement">Store -1</button>
      <button @click="store.reset">Reset</button>
    </section>
  </main>
</template>
EOF

# --- Update main.ts ---
cat > src/main.ts << 'EOF'
import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import router from './router'

const app = createApp(App)
app.use(createPinia())
app.use(router)
app.mount('#app')
EOF

# --- Update App.vue ---
cat > src/App.vue << 'EOF'
<script setup lang="ts">
import { RouterView } from 'vue-router'
</script>

<template>
  <RouterView />
</template>
EOF

# --- Vitest config ---
cat > vitest.config.ts << 'EOF'
import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'

export default defineConfig({
  plugins: [vue()],
  test: {
    environment: 'happy-dom',
    globals: true,
    include: ['src/**/*.{test,spec}.{ts,tsx}'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{ts,vue}'],
      exclude: ['src/test/**', 'src/**/*.d.ts'],
    },
  },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
})
EOF

# --- Add test script to package.json ---
npx --yes json -I -f package.json -e '
  this.scripts.test = "vitest run";
  this.scripts["test:watch"] = "vitest";
  this.scripts["test:coverage"] = "vitest run --coverage";
'

# --- Types ---
cat > src/types/index.ts << 'EOF'
// Shared types for the application
export interface User {
  id: number
  name: string
  email: string
}
EOF

# --- env.d.ts ---
cat > env.d.ts << 'EOF'
/// <reference types="vite/client" />

declare module '*.vue' {
  import type { DefineComponent } from 'vue'
  const component: DefineComponent<object, object, unknown>
  export default component
}
EOF

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "  cd $PROJECT_NAME"
echo "  npm run dev          # Start dev server"
echo "  npm run test         # Run tests"
echo "  npm run build        # Production build"
echo ""
echo "Structure:"
echo "  src/composables/     # Reusable composables (useX pattern)"
echo "  src/stores/          # Pinia stores"
echo "  src/views/           # Route-level components"
echo "  src/components/      # Reusable components"
echo "  src/router/          # Vue Router config"
echo "  src/types/           # TypeScript types"
