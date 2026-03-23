---
name: eslint-prettier-config
description: >
  Use when user configures ESLint, Prettier, asks about eslint.config.js (flat config),
  typescript-eslint, eslint-plugin-react, lint rules, autofix, or Biome as an alternative.
  Do NOT use for Python linting (ruff/pylint), Go linting (golangci-lint), or Rust linting (clippy).
---

# ESLint & Prettier Configuration

## ESLint Flat Config (eslint.config.js)

ESLint 9+ uses flat config by default. ESLint 10 removes legacy `.eslintrc` support entirely.

### Structure

Export an array of config objects from `eslint.config.js` (or `.mjs`/`.ts`):

```js
// eslint.config.js
import js from '@eslint/js';
import { defineConfig } from 'eslint/config';

export default defineConfig([
  js.configs.recommended,
  {
    files: ['**/*.js', '**/*.ts'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: { console: 'readonly' },
    },
    rules: {
      'no-unused-vars': 'warn',
      'no-console': ['error', { allow: ['warn', 'error'] }],
    },
  },
  { ignores: ['dist/**', 'node_modules/**', 'coverage/**'] },
]);
```

### Key Properties per Config Object

- `files` — glob patterns this config applies to.
- `ignores` — glob patterns to exclude. A standalone `{ ignores: [...] }` object acts as global ignores.
- `languageOptions` — `ecmaVersion`, `sourceType`, `parser`, `parserOptions`, `globals`.
- `plugins` — object mapping plugin namespace to imported plugin module.
- `rules` — rule ID to severity (`"off"`, `"warn"`, `"error"`) or `[severity, options]`.
- `settings` — shared data for plugins (e.g., `react.version`).
- `linterOptions` — `reportUnusedDisableDirectives`, `noInlineConfig`.

Use `defineConfig()` for type safety and editor autocompletion.

## Migration from .eslintrc

```bash
npx @eslint/migrate-config .eslintrc.json   # outputs eslint.config.mjs (--commonjs for CJS)
```

Manual checklist:
- Replace `extends` with direct imports and array spreading.
- Move `env` into `languageOptions.globals` (use `globals` npm package).
- Import plugins as modules, not string references.
- Move `.eslintignore` into `ignores`-only config objects.
- Replace `overrides` with separate config objects using `files` globs.
- Remove `root: true` (flat config stops at config file automatically).

```js
import globals from 'globals';
export default [
  { languageOptions: { globals: { ...globals.browser, ...globals.node } } },
];
```

## typescript-eslint

### Basic Setup

```bash
npm install --save-dev eslint @eslint/js typescript typescript-eslint
```

```js
import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';

export default [
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['**/*.ts', '**/*.tsx'],
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    plugins: { '@typescript-eslint': tseslint.plugin },
    rules: {
      '@typescript-eslint/no-explicit-any': 'warn',
      '@typescript-eslint/no-floating-promises': 'error',
    },
  },
];
```

### Config Presets

- `tseslint.configs.recommended` — common errors. `strict` — fewer false positives. `stylistic` — naming/style.
- `tseslint.configs.recommendedTypeChecked` — adds rules requiring type info. `strictTypeChecked` — strict + type-checked.

Type-checked rules require `parserOptions.projectService: true`. Use `projectService` over `project` for faster resolution. Set `tsconfigRootDir` to avoid unnecessary traversal. Exclude test files from type-checked configs when unnecessary.

## Framework Plugins

### React

```bash
npm install --save-dev eslint-plugin-react eslint-plugin-react-hooks eslint-plugin-jsx-a11y
```

```js
import react from 'eslint-plugin-react';
import reactHooks from 'eslint-plugin-react-hooks';

export default [
  {
    files: ['**/*.jsx', '**/*.tsx'],
    plugins: { react, 'react-hooks': reactHooks },
    languageOptions: {
      parserOptions: { ecmaFeatures: { jsx: true } },
    },
    settings: { react: { version: 'detect' } },
    rules: {
      'react/react-in-jsx-scope': 'off', // React 17+ JSX transform
      'react/prop-types': 'off', // use TypeScript instead
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'warn',
    },
  },
];
```

### Vue / Svelte

- **Vue**: `npm i -D eslint-plugin-vue vue-eslint-parser` → spread `vue.configs['flat/recommended']`, set `languageOptions.parser` to `vueParser` for `**/*.vue`.
- **Svelte**: `npm i -D eslint-plugin-svelte svelte-eslint-parser` → spread `svelte.configs.recommended`.

## Import Rules

```bash
npm install --save-dev eslint-plugin-import
```

```js
import importPlugin from 'eslint-plugin-import';

export default [
  {
    plugins: { import: importPlugin },
    settings: {
      'import/resolver': {
        node: { extensions: ['.js', '.ts', '.tsx'] },
        typescript: { alwaysTryTypes: true },
      },
    },
    rules: {
      'import/order': ['error', {
        groups: ['builtin', 'external', 'internal', 'parent', 'sibling', 'index'],
        'newlines-between': 'always',
        alphabetize: { order: 'asc', caseInsensitive: true },
      }],
      'import/no-cycle': ['error', { maxDepth: 3 }],
      'import/no-unresolved': 'error',
      'import/no-duplicates': 'error',
      'import/no-extraneous-dependencies': 'error',
    },
  },
];
```

For TypeScript resolution, install `eslint-import-resolver-typescript`.

## Prettier Integration

### Recommended Approach: Run Separately

Let ESLint handle logic/quality rules. Let Prettier handle formatting. Disable conflicting rules:

```bash
npm install --save-dev prettier eslint-config-prettier
```

```js
import eslintConfigPrettier from 'eslint-config-prettier/flat';

export default [
  // ...other configs
  eslintConfigPrettier, // MUST be last to override conflicting rules
];
```

Run both tools:

```json
{
  "scripts": {
    "lint": "eslint . && prettier --check .",
    "lint:fix": "eslint --fix . && prettier --write ."
  }
}
```

### Alternative: Prettier as ESLint Plugin

Reports formatting differences as ESLint errors. Slower but gives unified output:

```bash
npm install --save-dev eslint-plugin-prettier eslint-config-prettier
```

```js
import prettierRecommended from 'eslint-plugin-prettier/recommended';

export default [
  // ...other configs
  prettierRecommended,
];
```

## Prettier Configuration

```json
{
  "printWidth": 100,
  "tabWidth": 2,
  "useTabs": false,
  "semi": true,
  "singleQuote": true,
  "trailingComma": "all",
  "bracketSpacing": true,
  "arrowParens": "always",
  "endOfLine": "lf",
  "overrides": [
    { "files": "*.md", "options": { "proseWrap": "always", "printWidth": 80 } }
  ],
  "plugins": ["prettier-plugin-tailwindcss"],
  "tailwindFunctions": ["clsx", "cn", "cva"]
}
```

Create `.prettierignore` for files Prettier should skip (dist, coverage, lock files).

## Custom ESLint Rules

```js
// rules/no-foo.js
export default {
  meta: {
    type: 'suggestion',
    docs: { description: 'Disallow foo identifiers' },
    fixable: 'code',
    schema: [],
    messages: { noFoo: 'Avoid using "foo" as an identifier.' },
  },
  create(context) {
    return {
      Identifier(node) {
        if (node.name === 'foo') {
          context.report({ node, messageId: 'noFoo' });
        }
      },
    };
  },
};
```

Register in config:

```js
import noFoo from './rules/no-foo.js';
export default [
  {
    plugins: { custom: { rules: { 'no-foo': noFoo } } },
    rules: { 'custom/no-foo': 'error' },
  },
];
```

Test with `RuleTester` from `eslint`. Explore ASTs at https://astexplorer.net.

## Biome

Biome is a Rust-based linter + formatter that replaces ESLint + Prettier in a single tool. 15–25x faster.

### Setup

```bash
npm install --save-dev @biomejs/biome
npx @biomejs/biome init
```

### biome.json

```json
{
  "$schema": "https://biomejs.dev/schemas/1.9.4/schema.json",
  "organizeImports": { "enabled": true },
  "linter": {
    "enabled": true,
    "rules": {
      "recommended": true,
      "complexity": { "noForEach": "warn" },
      "suspicious": { "noExplicitAny": "error" }
    }
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 100
  },
  "files": {
    "ignore": ["dist/**", "node_modules/**"]
  }
}
```

### Migration from ESLint/Prettier

```bash
npx @biomejs/biome migrate eslint --write
npx @biomejs/biome migrate prettier --write
```

### Package Scripts

```json
{
  "scripts": {
    "lint": "biome check .",
    "lint:fix": "biome check --write .",
    "format": "biome format --write ."
  }
}
```

### Trade-offs vs ESLint + Prettier

- **Speed**: Biome is 15–25x faster (Rust, multi-core). ESLint is JS-based, single-threaded.
- **Config**: Biome uses one `biome.json`. ESLint + Prettier need multiple config files.
- **Ecosystem**: ESLint has massive plugin ecosystem. Biome covers common cases, growing.
- **Custom rules**: ESLint has full AST visitor API. Biome has no custom rule API yet.
- **Type-aware linting**: Only ESLint (via typescript-eslint). Biome does not support it yet.
- **Framework support**: ESLint covers React, Vue, Svelte, Angular. Biome covers React, Vue (Svelte partial).

Use Biome when speed matters and standard rules suffice. Keep ESLint for type-aware linting, niche plugins, or custom rules.

## Performance

### ESLint Caching

```bash
eslint --cache --cache-location .eslintcache .
```

Add `.eslintcache` to `.gitignore`.

### Parallel and Flat Config Performance

ESLint is single-threaded. Lint only changed files in CI or use `lint-staged`. Biome parallelizes automatically. Flat config is faster than legacy — no cascading, no string plugin resolution, single evaluation at startup.

## CI Integration

### lint-staged + husky

```bash
npm install --save-dev lint-staged husky
npx husky init
```

```json
// package.json
{
  "lint-staged": {
    "*.{js,ts,jsx,tsx}": ["eslint --fix", "prettier --write"],
    "*.{json,md,yaml}": ["prettier --write"]
  }
}
```

```bash
# .husky/pre-commit
npx lint-staged
```

### GitHub Actions

```yaml
name: Lint
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22 }
      - run: npm ci
      - run: npx eslint . && npx prettier --check .
```

Require the lint job to pass via branch protection rules to block merges.

## Monorepo Configuration

### Single Root Config (Recommended)

Use one `eslint.config.js` at the repo root. Scope rules with `files` globs:

```js
export default [
  { files: ['packages/api/**/*.ts'], rules: { 'no-console': 'off' } },
  { files: ['packages/web/**/*.tsx'], plugins: { react }, rules: { /* ... */ } },
];
```

### Shared Config Package

Create `@myorg/eslint-config` as a workspace package exporting config arrays:

```js
// packages/eslint-config/index.js
import tseslint from 'typescript-eslint';
import react from 'eslint-plugin-react';

export const base = [
  ...tseslint.configs.recommended,
  { rules: { '@typescript-eslint/no-explicit-any': 'warn' } },
];

export const reactConfig = [
  ...base,
  { plugins: { react }, settings: { react: { version: 'detect' } } },
];
```

Import and spread in root config with `files` globs to scope per-workspace.

## Common Rule Sets

### Recommended Starter (TypeScript + React)

```js
import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';
import react from 'eslint-plugin-react';
import reactHooks from 'eslint-plugin-react-hooks';
import eslintConfigPrettier from 'eslint-config-prettier/flat';

export default [
  eslint.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  {
    files: ['**/*.ts', '**/*.tsx'],
    languageOptions: {
      parser: tseslint.parser,
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
  },
  {
    files: ['**/*.tsx'],
    plugins: { react, 'react-hooks': reactHooks },
    settings: { react: { version: 'detect' } },
    rules: {
      'react/react-in-jsx-scope': 'off',
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'warn',
    },
  },
  eslintConfigPrettier,
];
```

For maximum strictness, swap `recommendedTypeChecked` with `strictTypeChecked` and add `stylisticTypeChecked`.

## Anti-Patterns

- **Over-configuring** — start with recommended presets, override only what you need.
- **Disabling too many rules** — if you disable more than ~10 rules, reconsider your preset choice.
- **`eslint-disable` abuse** — require comments: `// eslint-disable-next-line no-console -- staging debug`. Enforce with `reportUnusedDisableDirectives: 'error'`.
- **Running Prettier through ESLint** — slower, confusing output. Run them separately.
- **Not caching** — always use `--cache` in CI and local scripts.
- **Ignoring type-checked rules** — `no-floating-promises` and `no-misused-promises` catch real bugs.
- **Mixing legacy and flat config** — pick one. Flat config is the future.
- **Global `eslint-disable` at file top** — use line-level disables with justification instead.
