# QA Review: zod-validation

**Skill:** `typescript/zod-validation`
**Reviewer:** Copilot QA
**Date:** 2025-07-23

---

## a. Structure Check

| Criterion | Status | Notes |
|---|---|---|
| YAML frontmatter `name` | ✅ | `zod-validation` |
| YAML frontmatter `description` with positive triggers | ✅ | Comprehensive: z.object, z.string, z.infer, safeParse, zodResolver, tRPC, Zod transforms, refinements, coercion, discriminated unions, branded types, etc. |
| Negative triggers | ✅ | Explicit exclusions: Yup, Joi, Valibot, ArkType, io-ts, class-validator, JSON Schema without Zod |
| Body under 500 lines | ✅ | Exactly 500 lines (at limit) |
| Imperative voice, no filler | ✅ | Tight, directive prose throughout |
| Examples with I/O | ✅ | Nearly every section has code examples with inline comments showing expected output |
| Links to refs/scripts | ⚠️ | No explicit markdown links to `references/` or `scripts/` files from SKILL.md body. Content is self-contained but the supporting files are discoverable only by directory listing. |

**Supporting files reviewed:**
- `references/advanced-patterns.md` (611 lines) — recursive schemas, branded types, discriminated unions, z.pipe, custom error maps, schema composition, conditional validation, file validation
- `references/framework-recipes.md` (827 lines) — RHF, Conform, tRPC, Next.js server actions, Remix, t3-env, API middleware, OpenAPI generation
- `references/troubleshooting.md` (515 lines) — type inference issues, circular refs, performance, ESM/CJS, bundle size, error formatting, async pitfalls, coercion edge cases, Zod 3→4 migration
- `scripts/benchmark-schemas.ts` — executable benchmark comparing schema parsing performance
- `scripts/generate-schema.ts` — JSON→Zod schema generator utility
- `scripts/validate-env.ts` — environment variable validation template
- `assets/api-middleware.ts` — Express/Hono Zod validation middleware
- `assets/common-schemas.ts` — reusable schema library (email, password, pagination, address, auth, etc.)
- `assets/env-schema.ts` — production-ready env validation with cross-field rules
- `assets/form-validation.tsx` — complete React Hook Form + Zod form component

---

## b. Content Check (Web-Verified)

### Zod 3.x APIs
| API | Correct? | Notes |
|---|---|---|
| `z.object`, `z.string`, `z.number`, etc. | ✅ | All primitive and object APIs match official docs |
| `z.infer<typeof Schema>` | ✅ | Correct usage throughout |
| `z.input<typeof Schema>` | ✅ | Correctly documented as pre-transform type |
| `.refine()` / `.superRefine()` | ✅ | Correct signatures, path option, ctx.addIssue, z.NEVER |
| `.transform()` | ✅ | Correct chaining behavior documented |
| `.safeParse()` / `.parse()` | ✅ | Result shape `{ success, data/error }` correct |
| `z.discriminatedUnion` | ✅ | Correct O(1) vs O(n) explanation |
| `z.coerce.*` | ✅ | Correct; truthy trap for `z.coerce.boolean()` properly warned |
| `z.lazy()` for recursion | ✅ | Correct pattern with `z.ZodType<T>` annotation |
| `.brand<T>()` | ✅ | Correct usage and type inference |
| Object manipulation (extend/merge/pick/omit/partial/deepPartial) | ✅ | All correct |
| `z.preprocess` | ✅ | Correct |
| `z.pipe` | ✅ | Correct |

### Framework Integrations
| Integration | Correct? | Notes |
|---|---|---|
| React Hook Form `zodResolver` | ✅ | Correct import from `@hookform/resolvers/zod`, correct `useForm` config |
| tRPC `.input()` | ✅ | Correct pattern with `publicProcedure.input(schema)` |
| Next.js Server Actions | ✅ | Correct `safeParse` + `formData.get()` pattern |
| Conform `parseWithZod` | ✅ | Correct import from `@conform-to/zod` |

### Error Handling
| Pattern | Correct? | Notes |
|---|---|---|
| `ZodError` / `z.ZodError` | ✅ | Correct class reference |
| `.format()` | ✅ | Correctly shows nested `{ _errors: [] }` structure |
| `.flatten()` | ✅ | Correctly shows `{ formErrors, fieldErrors }` structure |
| `.flatten()` nested path loss | ✅ | Documented in troubleshooting as a gotcha |
| `z.setErrorMap` | ✅ | Correct global error map pattern |
| Custom per-field messages | ✅ | `required_error`, `invalid_type_error`, inline `message` |

### Zod 4 Migration Notes
| Claim | Accurate? | Notes |
|---|---|---|
| Performance (14x string, 7x array, 6.5x object) | ✅ | Matches official release notes |
| Bundle size 2.3x smaller | ✅ | Confirmed |
| `@zod/mini` ~1.9KB gzipped | ✅ | Confirmed |
| Top-level `z.email()`, `z.uuid()`, etc. | ✅ | Confirmed as new Zod 4 feature |
| `z.stringbool()` | ✅ | Confirmed; handles "true"/"false"/"1"/"0"/"yes"/"no" |
| Unified `error` parameter | ✅ | Replaces `message`, `required_error`, `invalid_type_error` |
| `.toJSONSchema()` | ⚠️ | SKILL.md line 469 writes **`.toJSONSchema()`** which reads like an instance method. The correct Zod 4 API is `z.toJSONSchema(schema)` (a top-level function, not instance method). The troubleshooting reference (line 492) correctly shows `z.toJSONSchema(MySchema)`. The SKILL.md bullet is ambiguous rather than outright wrong, but could mislead users into writing `schema.toJSONSchema()` which will fail. |
| Official codemod `npx @zod/codemod` | ✅ | Confirmed |

### Missing Gotchas
- ✅ `z.coerce.boolean()` truthy trap — covered
- ✅ `z.coerce.number()` empty string → 0 — covered in troubleshooting
- ✅ `z.coerce.date()` null → Date(0) — covered in troubleshooting
- ✅ Async `safeParse` vs sync with async refinements — covered
- ✅ Transform ordering (refine after transform receives transformed type) — covered
- ✅ `.flatten()` dropping nested paths — covered
- ⚠️ `z.string().email()` described as "RFC-compliant" (SKILL.md line 37) — Zod uses a simplified regex, not full RFC 5322 compliance. Minor inaccuracy but unlikely to cause issues.

---

## c. Trigger Check

| Criterion | Status | Notes |
|---|---|---|
| Positive triggers relevant | ✅ | Comprehensive coverage of Zod-specific terms, framework integrations, and pattern names |
| No false positives for Yup | ✅ | Explicitly excluded |
| No false positives for Joi | ✅ | Explicitly excluded |
| No false positives for plain TypeScript | ✅ | Triggers are Zod-specific (z.object, z.infer, safeParse, etc.), not generic TS terms |
| No false positives for Valibot/ArkType/io-ts | ✅ | Explicitly excluded |

The trigger description is well-crafted — long enough to catch relevant queries without over-triggering on generic validation or TypeScript type-checking questions.

---

## d. Scores

| Dimension | Score | Rationale |
|---|---|---|
| **Accuracy** | 4 | All Zod 3.x APIs verified correct. Minor issue: `.toJSONSchema()` in SKILL.md is ambiguous (correct form is `z.toJSONSchema(schema)`). `email()` described as "RFC-compliant" is slightly misleading. Troubleshooting ref has correct Zod 4 syntax. |
| **Completeness** | 5 | Exceptionally comprehensive. Covers primitives through advanced patterns (branded types, recursive schemas, discriminated unions). Framework integrations for RHF, tRPC, Next.js, Conform, Remix. Troubleshooting covers all major gotchas. Scripts and assets are practical, production-ready templates. Comparison table with alternatives is a valuable addition. |
| **Actionability** | 5 | Nearly every section has copy-pasteable code with inline output annotations. Assets provide complete, ready-to-use templates (form component, API middleware, env schema, common schemas library). Scripts are executable utilities. The skill reads as a practical cookbook, not a theoretical overview. |
| **Trigger Quality** | 5 | Positive triggers are specific and comprehensive. Negative triggers explicitly exclude all major competing libraries. No risk of false positives for plain TypeScript, Yup, Joi, or other validation tools. |
| **Overall** | **4.75** | |

---

## e. Issue Filing

Overall score (4.75) ≥ 4.0 and no dimension ≤ 2. **No GitHub issues required.**

### Recommendations (non-blocking)

1. **Clarify `.toJSONSchema()` in SKILL.md line 469:** Change to `z.toJSONSchema(schema)` to match the actual Zod 4 API (top-level function, not instance method). The troubleshooting reference already has the correct syntax.

2. **Add explicit links to references/scripts/assets** in SKILL.md body or a "See also" section to improve discoverability.

3. **Minor:** Line 37 says `z.string().email()` is "RFC-compliant." Consider changing to "email format validation" since Zod's regex is simplified, not full RFC 5322.

---

## f. Verdict

**PASS** ✅

High-quality skill with comprehensive, accurate content, excellent actionability, and well-tuned triggers. The minor `.toJSONSchema()` ambiguity and "RFC-compliant" label are non-blocking issues.
