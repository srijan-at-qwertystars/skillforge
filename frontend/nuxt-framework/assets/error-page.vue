<!--
  error-page.vue — Custom error page template for Nuxt 3

  Usage: Copy to error.vue in project root (NOT in pages/).
  This file handles all unhandled errors (404, 500, etc.).
  Customize styling and messages to match your design.
-->
<script setup lang="ts">
import type { NuxtError } from '#app'

const props = defineProps<{
  error: NuxtError
}>()

const statusMessages: Record<number, { title: string; description: string }> = {
  400: { title: 'Bad Request', description: 'The request could not be understood.' },
  401: { title: 'Unauthorized', description: 'You need to sign in to access this page.' },
  403: { title: 'Forbidden', description: 'You don\'t have permission to access this page.' },
  404: { title: 'Page Not Found', description: 'The page you\'re looking for doesn\'t exist.' },
  500: { title: 'Server Error', description: 'Something went wrong on our end.' },
}

const errorInfo = computed(() => {
  const code = props.error.statusCode || 500
  return statusMessages[code] || {
    title: props.error.statusMessage || 'Error',
    description: 'An unexpected error occurred.',
  }
})

// SEO — set appropriate title for error pages
useHead({
  title: `${props.error.statusCode} - ${errorInfo.value.title}`,
})
</script>

<template>
  <div class="error-page">
    <div class="error-container">
      <h1 class="error-code">{{ error.statusCode }}</h1>
      <h2 class="error-title">{{ errorInfo.title }}</h2>
      <p class="error-description">{{ errorInfo.description }}</p>

      <!-- Show error details in development -->
      <pre v-if="error.stack" class="error-stack">{{ error.stack }}</pre>

      <div class="error-actions">
        <button class="btn btn-primary" @click="clearError({ redirect: '/' })">
          Go Home
        </button>
        <button class="btn btn-secondary" @click="clearError()">
          Try Again
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.error-page {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  font-family: system-ui, -apple-system, sans-serif;
  background: #fafafa;
  padding: 2rem;
}

.error-container {
  text-align: center;
  max-width: 480px;
}

.error-code {
  font-size: 6rem;
  font-weight: 800;
  color: #e11d48;
  line-height: 1;
  margin: 0 0 0.5rem;
}

.error-title {
  font-size: 1.5rem;
  font-weight: 600;
  color: #1a1a1a;
  margin: 0 0 0.75rem;
}

.error-description {
  font-size: 1rem;
  color: #666;
  margin: 0 0 2rem;
}

.error-stack {
  text-align: left;
  background: #1a1a1a;
  color: #f0f0f0;
  padding: 1rem;
  border-radius: 8px;
  font-size: 0.75rem;
  overflow-x: auto;
  margin: 0 0 2rem;
  max-height: 200px;
}

.error-actions {
  display: flex;
  gap: 1rem;
  justify-content: center;
}

.btn {
  padding: 0.625rem 1.5rem;
  border-radius: 8px;
  font-size: 0.875rem;
  font-weight: 500;
  cursor: pointer;
  border: none;
  transition: opacity 0.2s;
}

.btn:hover {
  opacity: 0.85;
}

.btn-primary {
  background: #1a1a1a;
  color: white;
}

.btn-secondary {
  background: white;
  color: #1a1a1a;
  border: 1px solid #ddd;
}

@media (prefers-color-scheme: dark) {
  .error-page { background: #0a0a0a; }
  .error-title { color: #f0f0f0; }
  .error-description { color: #999; }
  .btn-primary { background: #f0f0f0; color: #0a0a0a; }
  .btn-secondary { background: #1a1a1a; color: #f0f0f0; border-color: #333; }
}
</style>
