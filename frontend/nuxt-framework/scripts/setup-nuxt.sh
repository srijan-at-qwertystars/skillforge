#!/usr/bin/env bash
# ==============================================================================
# setup-nuxt.sh — Scaffold a Nuxt 3 project with recommended configuration
#
# Usage:
#   ./setup-nuxt.sh <project-name>
#   ./setup-nuxt.sh my-app
#
# What it does:
#   1. Creates a new Nuxt 3 project via nuxi
#   2. Installs recommended modules (Pinia, ESLint, Nuxt UI, testing)
#   3. Sets up directory structure
#   4. Configures nuxt.config.ts with best-practice defaults
#   5. Creates starter files (layouts, error page, composable example)
# ==============================================================================
set -euo pipefail

PROJECT_NAME="${1:-}"

if [[ -z "$PROJECT_NAME" ]]; then
  echo "Usage: $0 <project-name>"
  echo "Example: $0 my-nuxt-app"
  exit 1
fi

if [[ -d "$PROJECT_NAME" ]]; then
  echo "Error: Directory '$PROJECT_NAME' already exists."
  exit 1
fi

echo "🚀 Creating Nuxt 3 project: $PROJECT_NAME"
npx nuxi@latest init "$PROJECT_NAME" --packageManager npm --gitInit
cd "$PROJECT_NAME"

# ---------- Install recommended modules ----------
echo "📦 Installing recommended modules..."
npm install --save \
  @pinia/nuxt \
  pinia

npm install --save-dev \
  @nuxt/eslint \
  @nuxt/test-utils \
  vitest \
  @vue/test-utils \
  happy-dom \
  typescript

# ---------- Create directory structure ----------
echo "📁 Creating directory structure..."
mkdir -p \
  components \
  composables \
  layouts \
  middleware \
  pages \
  plugins \
  public \
  server/api \
  server/middleware \
  server/utils \
  stores \
  assets/css \
  utils \
  tests

# ---------- Configure nuxt.config.ts ----------
echo "⚙️  Writing nuxt.config.ts..."
cat > nuxt.config.ts << 'NUXTCONFIG'
// https://nuxt.com/docs/api/configuration/nuxt-config
export default defineNuxtConfig({
  compatibilityDate: '2024-11-01',
  ssr: true,

  modules: [
    '@pinia/nuxt',
    '@nuxt/eslint',
  ],

  pinia: {
    storesDirs: ['./stores/**'],
  },

  css: ['~/assets/css/main.css'],

  runtimeConfig: {
    // Server-only keys (set via NUXT_<KEY> env vars)
    apiSecret: '',
    public: {
      // Client-exposed keys (set via NUXT_PUBLIC_<KEY> env vars)
      apiBase: '/api',
    },
  },

  routeRules: {
    '/': { prerender: true },
  },

  devtools: { enabled: true },

  typescript: {
    strict: true,
  },

  imports: {
    dirs: ['stores'],
  },
})
NUXTCONFIG

# ---------- Create app.vue ----------
echo "📝 Creating starter files..."
cat > app.vue << 'APPVUE'
<template>
  <NuxtLayout>
    <NuxtPage />
  </NuxtLayout>
</template>
APPVUE

# ---------- Create default layout ----------
cat > layouts/default.vue << 'LAYOUT'
<template>
  <div class="layout-default">
    <header>
      <nav>
        <NuxtLink to="/">Home</NuxtLink>
        <NuxtLink to="/about">About</NuxtLink>
      </nav>
    </header>
    <main>
      <slot />
    </main>
    <footer>
      <p>&copy; {{ new Date().getFullYear() }}</p>
    </footer>
  </div>
</template>
LAYOUT

# ---------- Create index page ----------
cat > pages/index.vue << 'INDEXPAGE'
<script setup lang="ts">
useSeoMeta({
  title: 'Home',
  description: 'Welcome to our Nuxt 3 application',
})
</script>

<template>
  <div>
    <h1>Welcome</h1>
    <p>Your Nuxt 3 app is ready.</p>
  </div>
</template>
INDEXPAGE

# ---------- Create about page ----------
cat > pages/about.vue << 'ABOUTPAGE'
<script setup lang="ts">
useSeoMeta({ title: 'About' })
</script>

<template>
  <div>
    <h1>About</h1>
    <p>Built with Nuxt 3.</p>
  </div>
</template>
ABOUTPAGE

# ---------- Create error page ----------
cat > error.vue << 'ERRORPAGE'
<script setup lang="ts">
const props = defineProps<{
  error: {
    statusCode: number
    statusMessage: string
    message?: string
  }
}>()
</script>

<template>
  <div class="error-page">
    <h1>{{ error.statusCode }}</h1>
    <p>{{ error.statusMessage || error.message }}</p>
    <button @click="clearError({ redirect: '/' })">Go Home</button>
  </div>
</template>
ERRORPAGE

# ---------- Create example composable ----------
cat > composables/useAppState.ts << 'COMPOSABLE'
export const useAppState = () => {
  const isLoading = useState<boolean>('app-loading', () => false)

  const setLoading = (value: boolean) => {
    isLoading.value = value
  }

  return { isLoading, setLoading }
}
COMPOSABLE

# ---------- Create example store ----------
cat > stores/counter.ts << 'STORE'
export const useCounterStore = defineStore('counter', () => {
  const count = ref(0)
  const doubleCount = computed(() => count.value * 2)

  function increment() {
    count.value++
  }

  function reset() {
    count.value = 0
  }

  return { count, doubleCount, increment, reset }
})
STORE

# ---------- Create example API route ----------
cat > server/api/health.get.ts << 'APIROUTE'
export default defineEventHandler(() => {
  return { status: 'ok', timestamp: new Date().toISOString() }
})
APIROUTE

# ---------- Create base CSS ----------
cat > assets/css/main.css << 'CSS'
*,
*::before,
*::after {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: system-ui, -apple-system, sans-serif;
  line-height: 1.6;
  color: #1a1a1a;
}
CSS

# ---------- Create vitest config ----------
cat > vitest.config.ts << 'VITEST'
import { defineVitestConfig } from '@nuxt/test-utils/config'

export default defineVitestConfig({
  test: {
    environment: 'nuxt',
    environmentOptions: {
      nuxt: {
        domEnvironment: 'happy-dom',
      },
    },
  },
})
VITEST

# ---------- Create .gitignore additions ----------
cat >> .gitignore << 'GITIGNORE'

# Testing
coverage/
GITIGNORE

echo ""
echo "✅ Project '$PROJECT_NAME' created successfully!"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  npm run dev"
echo ""
echo "Available commands:"
echo "  npm run dev       — Start dev server"
echo "  npm run build     — Build for production"
echo "  npm run preview   — Preview production build"
echo "  npx vitest        — Run tests"
echo "  npx nuxi typecheck — Type check"
