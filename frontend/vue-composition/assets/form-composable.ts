// ============================================================================
// form-composable.ts — Form handling composable
// ============================================================================
// Features:
//   - Field validation with custom rules
//   - Dirty tracking per field and form-level
//   - Submit handling with loading/error states
//   - Field-level and form-level error state
//   - Reset to initial values
//   - Touch tracking (for showing errors after interaction)
// ============================================================================

import {
  ref,
  reactive,
  computed,
  watch,
  type Ref,
  type ComputedRef,
  type UnwrapNestedRefs,
} from 'vue'

// --- Types ---

type ValidationRule<T> = (value: T) => string | true
type ValidationRules<T> = { [K in keyof T]?: ValidationRule<T[K]>[] }

export interface UseFormOptions<T extends Record<string, unknown>> {
  /** Initial form values */
  initialValues: T
  /** Validation rules per field */
  rules?: ValidationRules<T>
  /** Validate on value change. Default: true */
  validateOnChange?: boolean
  /** Submit handler */
  onSubmit: (values: T) => Promise<void> | void
}

export interface FieldState {
  dirty: boolean
  touched: boolean
  error: string | null
}

export interface UseFormReturn<T extends Record<string, unknown>> {
  /** Reactive form values */
  values: UnwrapNestedRefs<T>
  /** Per-field state (dirty, touched, error) */
  fields: Record<keyof T, FieldState>
  /** All current errors */
  errors: ComputedRef<Partial<Record<keyof T, string>>>
  /** Whether form has any errors */
  hasErrors: ComputedRef<boolean>
  /** Whether any field has been modified */
  isDirty: ComputedRef<boolean>
  /** Whether form is currently submitting */
  isSubmitting: Ref<boolean>
  /** Form-level error (from submit handler) */
  submitError: Ref<string | null>
  /** Number of times form was submitted */
  submitCount: Ref<number>
  /** Validate all fields, returns true if valid */
  validate: () => boolean
  /** Validate a single field */
  validateField: (field: keyof T) => string | null
  /** Mark a field as touched */
  touch: (field: keyof T) => void
  /** Handle form submission */
  handleSubmit: (e?: Event) => Promise<void>
  /** Reset form to initial values */
  reset: (newValues?: Partial<T>) => void
  /** Set a single field value */
  setFieldValue: <K extends keyof T>(field: K, value: T[K]) => void
  /** Set a field error manually */
  setFieldError: (field: keyof T, error: string | null) => void
}

// --- Composable ---

export function useForm<T extends Record<string, unknown>>(
  options: UseFormOptions<T>
): UseFormReturn<T> {
  const { initialValues, rules = {} as ValidationRules<T>, validateOnChange = true, onSubmit } = options

  // Deep clone initial values
  const cloneValues = (vals: T): T => JSON.parse(JSON.stringify(vals))

  // --- State ---
  const values = reactive(cloneValues(initialValues)) as UnwrapNestedRefs<T>
  const isSubmitting = ref(false)
  const submitError = ref<string | null>(null)
  const submitCount = ref(0)

  // Per-field state
  const fields = reactive(
    Object.keys(initialValues).reduce((acc, key) => {
      acc[key as keyof T] = { dirty: false, touched: false, error: null }
      return acc
    }, {} as Record<keyof T, FieldState>)
  )

  // --- Validation ---

  function validateField(field: keyof T): string | null {
    const fieldRules = rules[field]
    if (!fieldRules) return null

    for (const rule of fieldRules) {
      const result = rule((values as T)[field])
      if (result !== true) {
        fields[field].error = result
        return result
      }
    }
    fields[field].error = null
    return null
  }

  function validate(): boolean {
    let isValid = true
    for (const field of Object.keys(initialValues) as Array<keyof T>) {
      const error = validateField(field)
      if (error) isValid = false
    }
    return isValid
  }

  // --- Computed ---

  const errors = computed(() => {
    const result: Partial<Record<keyof T, string>> = {}
    for (const [key, state] of Object.entries(fields) as Array<[keyof T, FieldState]>) {
      if (state.error) result[key] = state.error
    }
    return result
  })

  const hasErrors = computed(() => Object.keys(errors.value).length > 0)

  const isDirty = computed(() =>
    Object.values(fields).some((f) => (f as FieldState).dirty)
  )

  // --- Watch for changes ---

  if (validateOnChange) {
    for (const key of Object.keys(initialValues) as Array<keyof T>) {
      watch(
        () => (values as T)[key],
        () => {
          fields[key].dirty = (values as T)[key] !== (initialValues as T)[key]
          if (fields[key].touched) {
            validateField(key)
          }
        }
      )
    }
  }

  // --- Actions ---

  function touch(field: keyof T) {
    fields[field].touched = true
    validateField(field)
  }

  async function handleSubmit(e?: Event) {
    e?.preventDefault()

    // Touch all fields
    for (const key of Object.keys(initialValues) as Array<keyof T>) {
      fields[key].touched = true
    }

    if (!validate()) return

    isSubmitting.value = true
    submitError.value = null
    submitCount.value++

    try {
      await onSubmit(cloneValues(values as T))
    } catch (err) {
      submitError.value = err instanceof Error ? err.message : 'Submit failed'
    } finally {
      isSubmitting.value = false
    }
  }

  function reset(newValues?: Partial<T>) {
    const resetTo = { ...initialValues, ...newValues }
    Object.assign(values, cloneValues(resetTo as T))

    for (const key of Object.keys(initialValues) as Array<keyof T>) {
      fields[key].dirty = false
      fields[key].touched = false
      fields[key].error = null
    }

    submitError.value = null
  }

  function setFieldValue<K extends keyof T>(field: K, value: T[K]) {
    ;(values as T)[field] = value
  }

  function setFieldError(field: keyof T, error: string | null) {
    fields[field].error = error
  }

  return {
    values,
    fields,
    errors,
    hasErrors,
    isDirty,
    isSubmitting,
    submitError,
    submitCount,
    validate,
    validateField,
    touch,
    handleSubmit,
    reset,
    setFieldValue,
    setFieldError,
  }
}

// ============================================================================
// Common Validation Rules
// ============================================================================

export const rules = {
  required: (msg = 'Required'): ValidationRule<unknown> =>
    (value) => (value !== null && value !== undefined && value !== '') || msg,

  minLength: (min: number, msg?: string): ValidationRule<string> =>
    (value) => value.length >= min || (msg ?? `Minimum ${min} characters`),

  maxLength: (max: number, msg?: string): ValidationRule<string> =>
    (value) => value.length <= max || (msg ?? `Maximum ${max} characters`),

  email: (msg = 'Invalid email'): ValidationRule<string> =>
    (value) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value) || msg,

  pattern: (regex: RegExp, msg = 'Invalid format'): ValidationRule<string> =>
    (value) => regex.test(value) || msg,

  min: (min: number, msg?: string): ValidationRule<number> =>
    (value) => value >= min || (msg ?? `Minimum value is ${min}`),

  max: (max: number, msg?: string): ValidationRule<number> =>
    (value) => value <= max || (msg ?? `Maximum value is ${max}`),

  match: (otherValue: () => unknown, msg = 'Values must match'): ValidationRule<unknown> =>
    (value) => value === otherValue() || msg,
}

// ============================================================================
// Usage Example
// ============================================================================
//
// <script setup lang="ts">
// import { useForm, rules } from '@/composables/useForm'
//
// const {
//   values,
//   fields,
//   errors,
//   hasErrors,
//   isDirty,
//   isSubmitting,
//   submitError,
//   handleSubmit,
//   reset,
//   touch,
// } = useForm({
//   initialValues: {
//     email: '',
//     password: '',
//     confirmPassword: '',
//   },
//   rules: {
//     email: [rules.required(), rules.email()],
//     password: [rules.required(), rules.minLength(8)],
//     confirmPassword: [
//       rules.required(),
//       rules.match(() => values.password, 'Passwords must match'),
//     ],
//   },
//   async onSubmit(data) {
//     await api.register(data)
//   },
// })
// </script>
//
// <template>
//   <form @submit="handleSubmit">
//     <div>
//       <input v-model="values.email" @blur="touch('email')" />
//       <span v-if="fields.email.touched && errors.email">{{ errors.email }}</span>
//     </div>
//
//     <div>
//       <input v-model="values.password" type="password" @blur="touch('password')" />
//       <span v-if="fields.password.touched && errors.password">{{ errors.password }}</span>
//     </div>
//
//     <div>
//       <input v-model="values.confirmPassword" type="password" @blur="touch('confirmPassword')" />
//       <span v-if="fields.confirmPassword.touched && errors.confirmPassword">
//         {{ errors.confirmPassword }}
//       </span>
//     </div>
//
//     <button :disabled="isSubmitting || hasErrors" type="submit">
//       {{ isSubmitting ? 'Submitting...' : 'Register' }}
//     </button>
//
//     <p v-if="submitError" class="error">{{ submitError }}</p>
//
//     <button type="button" @click="reset()" :disabled="!isDirty">Reset</button>
//   </form>
// </template>
