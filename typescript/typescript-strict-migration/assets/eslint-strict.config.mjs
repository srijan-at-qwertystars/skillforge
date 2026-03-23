// eslint-strict.config.mjs — ESLint flat config for strict TypeScript projects.
//
// Prerequisites:
//   npm i -D eslint @typescript-eslint/parser @typescript-eslint/eslint-plugin \
//          eslint-plugin-import-x

import tseslint from "typescript-eslint";
import importX from "eslint-plugin-import-x";

export default tseslint.config(
  // ── Ignores ──────────────────────────────────────────────────────
  {
    ignores: ["dist/", "node_modules/", "coverage/", "**/*.js", "**/*.mjs"],
  },

  // ── Base: strict + type-checked rules ────────────────────────────
  // "strict-type-checked" is the strictest built-in preset. It includes
  // all "recommended" + "strict" rules and enables rules that require
  // type information (slower but far more powerful).
  ...tseslint.configs.strictTypeChecked,

  // Stylistic rules that enforce consistent type-level syntax.
  ...tseslint.configs.stylisticTypeChecked,

  // ── TypeScript rule overrides ────────────────────────────────────
  {
    languageOptions: {
      parserOptions: {
        // Required for rules that use type information.
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },

    rules: {
      // ── Ban `any` completely ──────────────────────────────────
      // `any` silently disables type-checking for everything it touches.
      // Use `unknown` and narrow instead.
      "@typescript-eslint/no-explicit-any": "error",

      // ── Unsafe operations — every "escape hatch" from the type system ─
      // These catch code that smuggles `any` into otherwise safe code.
      "@typescript-eslint/no-unsafe-argument": "error",
      "@typescript-eslint/no-unsafe-assignment": "error",
      "@typescript-eslint/no-unsafe-call": "error",
      "@typescript-eslint/no-unsafe-member-access": "error",
      "@typescript-eslint/no-unsafe-return": "error",

      // ── Require explicit return types on exported functions ────
      // Prevents accidental public-API type widening. Internal/private
      // functions can still rely on inference.
      "@typescript-eslint/explicit-function-return-type": [
        "error",
        {
          allowExpressions: true,
          allowTypedFunctionExpressions: true,
          allowHigherOrderFunctions: true,
        },
      ],

      // ── Enforce explicit accessibility on class members ───────
      // Makes it clear which members are part of the public API.
      "@typescript-eslint/explicit-member-accessibility": [
        "error",
        { accessibility: "explicit" },
      ],

      // ── Naming conventions ────────────────────────────────────
      // Enforces a consistent naming style across the codebase:
      //   • variables/functions: camelCase
      //   • types/interfaces/enums: PascalCase
      //   • boolean variables: prefixed with is/has/should/can/etc.
      //   • private members: prefixed with _
      "@typescript-eslint/naming-convention": [
        "error",
        {
          selector: "default",
          format: ["camelCase"],
          leadingUnderscore: "allow",
        },
        {
          selector: "variable",
          format: ["camelCase", "UPPER_CASE"],
          leadingUnderscore: "allow",
        },
        {
          selector: "parameter",
          format: ["camelCase"],
          leadingUnderscore: "allow",
        },
        {
          selector: "typeLike",
          format: ["PascalCase"],
        },
        {
          selector: "enumMember",
          format: ["PascalCase"],
        },
        {
          selector: "variable",
          types: ["boolean"],
          format: ["PascalCase"],
          prefix: ["is", "has", "should", "can", "does", "will"],
        },
        {
          selector: "memberLike",
          modifiers: ["private"],
          format: ["camelCase"],
          leadingUnderscore: "require",
        },
      ],

      // ── Prefer nullish coalescing over logical OR ─────────────
      // `??` only falls through on null/undefined; `||` also falls
      // through on 0, '', and false — a common source of bugs.
      "@typescript-eslint/prefer-nullish-coalescing": "error",

      // ── Prefer optional chaining ──────────────────────────────
      // `a?.b` is clearer and safer than `a && a.b`.
      "@typescript-eslint/prefer-optional-chain": "error",

      // ── No floating promises ──────────────────────────────────
      // An un-awaited promise silently swallows errors.
      "@typescript-eslint/no-floating-promises": "error",

      // ── No misused promises ───────────────────────────────────
      // Catches passing an async function where a sync one is expected.
      "@typescript-eslint/no-misused-promises": "error",

      // ── Strict boolean expressions ────────────────────────────
      // Prevents truthy/falsy checks on non-boolean types.
      // e.g., `if (count)` when count could be 0.
      "@typescript-eslint/strict-boolean-expressions": [
        "error",
        {
          allowString: false,
          allowNumber: false,
          allowNullableObject: true,
          allowNullableBoolean: false,
          allowNullableString: false,
          allowNullableNumber: false,
        },
      ],

      // ── Switch exhaustiveness ─────────────────────────────────
      // Ensures all union members are handled in switch statements.
      "@typescript-eslint/switch-exhaustiveness-check": "error",

      // ── Consistent type imports/exports ───────────────────────
      // Uses `import type { ... }` so bundlers can tree-shake more
      // effectively and it's explicit which imports are types.
      "@typescript-eslint/consistent-type-imports": [
        "error",
        { prefer: "type-imports", fixStyle: "separate-type-imports" },
      ],
      "@typescript-eslint/consistent-type-exports": [
        "error",
        { fixMixedExportsWithInlineTypeSpecifier: true },
      ],
    },
  },

  // ── Import ordering ──────────────────────────────────────────────
  // Keeps imports organized and consistent across the codebase.
  // Groups: built-in → external → internal → parent → sibling → index.
  {
    plugins: { "import-x": importX },
    rules: {
      "import-x/order": [
        "error",
        {
          groups: [
            "builtin",
            "external",
            "internal",
            ["parent", "sibling"],
            "index",
            "type",
          ],
          "newlines-between": "always",
          alphabetize: { order: "asc", caseInsensitive: true },
        },
      ],
      "import-x/no-duplicates": "error",
      "import-x/no-mutable-exports": "error",
    },
  },
);
