#!/usr/bin/env bash
# ============================================================================
# generate-composable.sh — Generate a new Vue 3 composable with test file
# ============================================================================
# Usage:
#   ./generate-composable.sh <name> [--dir <path>]
#   ./generate-composable.sh counter
#   ./generate-composable.sh fetchUsers --dir src/composables
#   ./generate-composable.sh darkMode --dir lib/hooks
#
# Generates:
#   - src/composables/use<Name>.ts    (composable with ref, computed, lifecycle, return)
#   - src/composables/__tests__/use<Name>.test.ts (Vitest test file)
#   - Updates src/composables/index.ts (barrel export)
#
# Name is normalized: "fetch-users" → "useFetchUsers"
# ============================================================================

set -euo pipefail

NAME_RAW="${1:?Usage: $0 <name> [--dir <path>]}"
COMPOSABLES_DIR="src/composables"

# Parse optional --dir flag
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) COMPOSABLES_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Normalize name ---
# Convert kebab-case or snake_case to PascalCase
to_pascal() {
  echo "$1" | sed -E 's/(^|[-_])([a-z])/\U\2/g'
}

PASCAL_NAME=$(to_pascal "$NAME_RAW")
COMPOSABLE_NAME="use${PASCAL_NAME}"
FILE_NAME="${COMPOSABLE_NAME}.ts"
TEST_DIR="${COMPOSABLES_DIR}/__tests__"
TEST_FILE="${COMPOSABLE_NAME}.test.ts"

# --- Check for existing files ---
if [ -f "${COMPOSABLES_DIR}/${FILE_NAME}" ]; then
  echo "Error: ${COMPOSABLES_DIR}/${FILE_NAME} already exists."
  exit 1
fi

# --- Create directories ---
mkdir -p "$COMPOSABLES_DIR" "$TEST_DIR"

echo "📝 Generating composable: ${COMPOSABLE_NAME}"

# --- Generate composable ---
cat > "${COMPOSABLES_DIR}/${FILE_NAME}" << EOF
import {
  ref,
  computed,
  onMounted,
  onUnmounted,
  toValue,
  type MaybeRefOrGetter,
  type Ref,
  type ComputedRef,
} from 'vue'

// --- Types ---

export interface ${PASCAL_NAME}Options {
  /** Enable automatic initialization on mount */
  immediate?: boolean
}

export interface ${COMPOSABLE_NAME}Return {
  /** Reactive state */
  data: Ref<unknown>
  /** Whether an operation is in progress */
  loading: Ref<boolean>
  /** Error state */
  error: Ref<Error | null>
  /** Derived/computed value */
  isEmpty: ComputedRef<boolean>
  /** Execute the main action */
  execute: () => Promise<void>
  /** Reset to initial state */
  reset: () => void
}

// --- Composable ---

/**
 * ${COMPOSABLE_NAME} — TODO: describe what this composable does.
 *
 * @param options - Configuration options
 * @returns Reactive state and actions
 *
 * @example
 * \`\`\`ts
 * const { data, loading, error, execute } = ${COMPOSABLE_NAME}()
 * \`\`\`
 */
export function ${COMPOSABLE_NAME}(
  options: ${PASCAL_NAME}Options = {}
): ${COMPOSABLE_NAME}Return {
  const { immediate = true } = options

  // --- State ---
  const data = ref<unknown>(null)
  const loading = ref(false)
  const error = ref<Error | null>(null)

  // --- Computed ---
  const isEmpty = computed(() => data.value == null)

  // --- Actions ---
  async function execute() {
    loading.value = true
    error.value = null
    try {
      // TODO: implement
      data.value = null
    } catch (e) {
      error.value = e instanceof Error ? e : new Error(String(e))
    } finally {
      loading.value = false
    }
  }

  function reset() {
    data.value = null
    loading.value = false
    error.value = null
  }

  // --- Lifecycle ---
  onMounted(() => {
    if (immediate) {
      execute()
    }
  })

  onUnmounted(() => {
    // TODO: cleanup (timers, listeners, abort controllers)
  })

  return {
    data,
    loading,
    error,
    isEmpty,
    execute,
    reset,
  }
}
EOF

# --- Generate test file ---
cat > "${TEST_DIR}/${TEST_FILE}" << EOF
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { nextTick } from 'vue'
import { ${COMPOSABLE_NAME} } from '../${COMPOSABLE_NAME}'

// Helper for composables that use lifecycle hooks
function withSetup<T>(composable: () => T) {
  const { createApp } = require('vue')
  let result!: T
  const app = createApp({
    setup() {
      result = composable()
      return () => {}
    },
  })
  app.mount(document.createElement('div'))
  return { result, app }
}

describe('${COMPOSABLE_NAME}', () => {
  it('initializes with default state', () => {
    const { result, app } = withSetup(() => ${COMPOSABLE_NAME}({ immediate: false }))

    expect(result.data.value).toBeNull()
    expect(result.loading.value).toBe(false)
    expect(result.error.value).toBeNull()
    expect(result.isEmpty.value).toBe(true)

    app.unmount()
  })

  it('executes action', async () => {
    const { result, app } = withSetup(() => ${COMPOSABLE_NAME}({ immediate: false }))

    await result.execute()

    expect(result.loading.value).toBe(false)

    app.unmount()
  })

  it('resets state', async () => {
    const { result, app } = withSetup(() => ${COMPOSABLE_NAME}({ immediate: false }))

    await result.execute()
    result.reset()

    expect(result.data.value).toBeNull()
    expect(result.loading.value).toBe(false)
    expect(result.error.value).toBeNull()

    app.unmount()
  })

  it('isEmpty is true when data is null', () => {
    const { result, app } = withSetup(() => ${COMPOSABLE_NAME}({ immediate: false }))

    expect(result.isEmpty.value).toBe(true)

    app.unmount()
  })
})
EOF

# --- Update barrel export ---
INDEX_FILE="${COMPOSABLES_DIR}/index.ts"
EXPORT_LINE="export { ${COMPOSABLE_NAME} } from './${COMPOSABLE_NAME}'"

if [ -f "$INDEX_FILE" ]; then
  if ! grep -qF "$COMPOSABLE_NAME" "$INDEX_FILE"; then
    echo "$EXPORT_LINE" >> "$INDEX_FILE"
    echo "📦 Updated ${INDEX_FILE}"
  fi
else
  echo "$EXPORT_LINE" > "$INDEX_FILE"
  echo "📦 Created ${INDEX_FILE}"
fi

echo ""
echo "✅ Generated:"
echo "   ${COMPOSABLES_DIR}/${FILE_NAME}"
echo "   ${TEST_DIR}/${TEST_FILE}"
echo ""
echo "Next steps:"
echo "   1. Implement the logic in ${COMPOSABLE_NAME}"
echo "   2. Update the types (${PASCAL_NAME}Options, ${COMPOSABLE_NAME}Return)"
echo "   3. Write tests in ${TEST_DIR}/${TEST_FILE}"
