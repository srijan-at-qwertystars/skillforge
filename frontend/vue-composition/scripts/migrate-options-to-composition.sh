#!/usr/bin/env bash
# ============================================================================
# migrate-options-to-composition.sh — Options API → Composition API migration helper
# ============================================================================
# Usage:
#   ./migrate-options-to-composition.sh <component.vue>
#   ./migrate-options-to-composition.sh src/components/UserList.vue
#
# Analyzes an Options API component and:
#   1. Detects Options API patterns (data, computed, methods, watch, etc.)
#   2. Prints a Composition API equivalent mapping
#   3. Generates a migration template file (<component>.composition.vue)
#
# Note: This is a helper/guide — generated code requires manual review.
# ============================================================================

set -euo pipefail

INPUT_FILE="${1:?Usage: $0 <component.vue>}"

if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: File '$INPUT_FILE' not found."
  exit 1
fi

# --- Extract script content ---
SCRIPT_CONTENT=$(sed -n '/<script/,/<\/script>/p' "$INPUT_FILE" | sed '1d;$d')

if [ -z "$SCRIPT_CONTENT" ]; then
  echo "Error: No <script> block found in $INPUT_FILE"
  exit 1
fi

# Check if already using Composition API
if echo "$SCRIPT_CONTENT" | grep -qE '<script\s+setup|setup\(\)'; then
  echo "⚠️  This component already uses Composition API (script setup or setup())."
  echo "   No migration needed."
  exit 0
fi

echo "============================================================"
echo "🔍 Analyzing Options API component: $INPUT_FILE"
echo "============================================================"
echo ""

# --- Detect patterns ---
detect() {
  local pattern="$1"
  local label="$2"
  local matches
  matches=$(echo "$SCRIPT_CONTENT" | grep -cE "$pattern" 2>/dev/null || true)
  if [ "$matches" -gt 0 ]; then
    echo "  ✓ $label ($matches occurrence(s))"
    return 0
  fi
  return 1
}

echo "📋 Detected Options API patterns:"
echo ""

HAS_DATA=false
HAS_COMPUTED=false
HAS_METHODS=false
HAS_WATCH=false
HAS_PROPS=false
HAS_EMITS=false
HAS_MOUNTED=false
HAS_UNMOUNTED=false
HAS_CREATED=false
HAS_MIXINS=false
HAS_COMPONENTS=false
HAS_REFS=false

detect 'data\s*\(\)|data\s*:' "data()" && HAS_DATA=true
detect 'computed\s*:' "computed" && HAS_COMPUTED=true
detect 'methods\s*:' "methods" && HAS_METHODS=true
detect 'watch\s*:' "watch" && HAS_WATCH=true
detect 'props\s*:' "props" && HAS_PROPS=true
detect 'emits\s*:' "emits" && HAS_EMITS=true
detect 'mounted\s*\(' "mounted()" && HAS_MOUNTED=true
detect 'beforeUnmount\s*\(|unmounted\s*\(|destroyed\s*\(' "unmount/destroy hooks" && HAS_UNMOUNTED=true
detect 'created\s*\(' "created()" && HAS_CREATED=true
detect 'mixins\s*:' "mixins" && HAS_MIXINS=true
detect 'components\s*:' "components" && HAS_COMPONENTS=true
detect 'this\.\$refs' "template refs" && HAS_REFS=true

echo ""
echo "============================================================"
echo "📖 Migration Guide"
echo "============================================================"
echo ""

# --- Print migration mappings ---
if $HAS_DATA; then
  echo "📌 data() → ref() / reactive()"
  echo "   BEFORE: data() { return { count: 0, user: null } }"
  echo "   AFTER:  const count = ref(0)"
  echo "           const user = ref<User | null>(null)"
  echo "   Tip: Prefer ref() for all values. Access via .value in script."
  echo ""
fi

if $HAS_COMPUTED; then
  echo "📌 computed: {} → computed()"
  echo "   BEFORE: computed: { fullName() { return this.first + this.last } }"
  echo "   AFTER:  const fullName = computed(() => first.value + ' ' + last.value)"
  echo ""
fi

if $HAS_METHODS; then
  echo "📌 methods: {} → plain functions"
  echo "   BEFORE: methods: { fetchUser() { ... } }"
  echo "   AFTER:  function fetchUser() { ... }"
  echo "   OR:     const fetchUser = async () => { ... }"
  echo ""
fi

if $HAS_WATCH; then
  echo "📌 watch: {} → watch() / watchEffect()"
  echo "   BEFORE: watch: { query(newVal) { this.search(newVal) } }"
  echo "   AFTER:  watch(query, (newVal) => search(newVal))"
  echo "   Tip: Use watchEffect() if you want immediate + auto-tracking."
  echo ""
fi

if $HAS_PROPS; then
  echo "📌 props: {} → defineProps<T>()"
  echo "   BEFORE: props: { title: { type: String, required: true } }"
  echo "   AFTER:  const props = defineProps<{ title: string }>()"
  echo "   With defaults: withDefaults(defineProps<Props>(), { count: 0 })"
  echo ""
fi

if $HAS_EMITS; then
  echo "📌 emits: [] → defineEmits<T>()"
  echo "   BEFORE: emits: ['update', 'delete']"
  echo "   AFTER:  const emit = defineEmits<{ update: [id: number]; delete: [id: number] }>()"
  echo ""
fi

if $HAS_MOUNTED; then
  echo "📌 mounted() → onMounted()"
  echo "   BEFORE: mounted() { this.init() }"
  echo "   AFTER:  onMounted(() => init())"
  echo "   ⚠️  Register BEFORE any await statements!"
  echo ""
fi

if $HAS_CREATED; then
  echo "📌 created() → top-level setup code"
  echo "   BEFORE: created() { this.fetchData() }"
  echo "   AFTER:  fetchData()  // Just call directly in setup"
  echo ""
fi

if $HAS_UNMOUNTED; then
  echo "📌 beforeUnmount/destroyed → onUnmounted()"
  echo "   BEFORE: beforeUnmount() { clearInterval(this.timer) }"
  echo "   AFTER:  onUnmounted(() => clearInterval(timer))"
  echo ""
fi

if $HAS_MIXINS; then
  echo "📌 mixins: [] → composables"
  echo "   BEFORE: mixins: [searchMixin, paginationMixin]"
  echo "   AFTER:  const { query, results } = useSearch()"
  echo "           const { page, next, prev } = usePagination()"
  echo "   Tip: Extract each mixin into a useX composable."
  echo ""
fi

if $HAS_REFS; then
  echo "📌 this.\$refs → template refs"
  echo "   BEFORE: this.\$refs.input.focus()"
  echo "   AFTER:  const input = ref<HTMLInputElement | null>(null)"
  echo "           onMounted(() => input.value?.focus())"
  echo "           // <input ref=\"input\" /> in template"
  echo ""
fi

# --- Generate migration template ---
OUTPUT_FILE="${INPUT_FILE%.vue}.composition.vue"

echo "============================================================"
echo "📄 Generating migration template: $OUTPUT_FILE"
echo "============================================================"

# Extract template block
TEMPLATE_BLOCK=$(sed -n '/<template>/,/<\/template>/p' "$INPUT_FILE")

# Extract style block
STYLE_BLOCK=$(sed -n '/<style/,/<\/style>/p' "$INPUT_FILE")

cat > "$OUTPUT_FILE" << 'MIGEOF'
<script setup lang="ts">
// ============================================================
// MIGRATED FROM OPTIONS API — Review and adjust
// ============================================================
import {
  ref,
  reactive,
  computed,
  watch,
  watchEffect,
  onMounted,
  onUnmounted,
  nextTick,
  type Ref,
} from 'vue'
MIGEOF

# Add Pinia import if store-like patterns detected
if echo "$SCRIPT_CONTENT" | grep -qE 'mapState|mapGetters|mapActions|useStore'; then
  echo "import { storeToRefs } from 'pinia'" >> "$OUTPUT_FILE"
fi

cat >> "$OUTPUT_FILE" << 'MIGEOF'

// --- Props ---
// TODO: Define your props interface
// interface Props {
//   title: string
//   count?: number
// }
// const props = withDefaults(defineProps<Props>(), {
//   count: 0,
// })

// --- Emits ---
// TODO: Define your emits
// const emit = defineEmits<{
//   update: [value: string]
// }>()

// --- State (from data()) ---
// TODO: Convert each data property to ref()
// const count = ref(0)
// const items = ref<Item[]>([])
// const user = ref<User | null>(null)

// --- Computed ---
// TODO: Convert each computed property
// const fullName = computed(() => `${firstName.value} ${lastName.value}`)

// --- Methods ---
// TODO: Convert each method to a function
// async function fetchData() {
//   loading.value = true
//   try {
//     data.value = await api.get('/endpoint')
//   } catch (e) {
//     error.value = e as Error
//   } finally {
//     loading.value = false
//   }
// }

// --- Watchers ---
// TODO: Convert each watcher
// watch(query, (newQuery) => {
//   search(newQuery)
// }, { immediate: true })

// --- Lifecycle ---
// ⚠️ Register ALL hooks BEFORE any await!
// onMounted(() => {
//   // DOM is ready
// })
// onUnmounted(() => {
//   // Cleanup: timers, listeners, subscriptions
// })

// --- Template Refs ---
// const inputRef = ref<HTMLInputElement | null>(null)
MIGEOF

echo "" >> "$OUTPUT_FILE"
echo "</script>" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Append original template (with this. references noted)
if [ -n "$TEMPLATE_BLOCK" ]; then
  echo "<!-- TODO: Remove 'this.' references if any, remove .value in templates -->" >> "$OUTPUT_FILE"
  echo "$TEMPLATE_BLOCK" >> "$OUTPUT_FILE"
else
  echo "<template>" >> "$OUTPUT_FILE"
  echo "  <div><!-- TODO: Add template --></div>" >> "$OUTPUT_FILE"
  echo "</template>" >> "$OUTPUT_FILE"
fi

echo "" >> "$OUTPUT_FILE"

# Append original styles
if [ -n "$STYLE_BLOCK" ]; then
  echo "$STYLE_BLOCK" >> "$OUTPUT_FILE"
fi

echo ""
echo "✅ Migration template generated: $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "  1. Review the generated template"
echo "  2. Move actual data/computed/methods/watchers into the template"
echo "  3. Update template references (remove 'this.')"
echo "  4. Extract reusable logic into composables"
echo "  5. Test the component"
echo "  6. Replace original file when ready"
