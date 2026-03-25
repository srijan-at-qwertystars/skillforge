---
name: biome-toolchain
description: >
  Guide for configuring and using the Biome (formerly Rome) toolchain for JavaScript, TypeScript, JSX, TSX, CSS, JSON, and GraphQL projects. Use when: setting up Biome linting or formatting, configuring biome.json/biome.jsonc, migrating from ESLint or Prettier to Biome, writing JS/TS/CSS lint rules, organizing imports, setting up Biome in CI/CD or GitHub Actions, configuring Biome in VS Code or JetBrains, using biome check/lint/format/ci commands, creating GritQL custom rules, monorepo Biome config. Do NOT use when: configuring ESLint-specific plugins or shareable configs, Prettier-only formatting without Biome, Ruff or Python linting, Go or Rust linting tools (clippy/golangci-lint), Stylelint CSS-only workflows, Markdown or YAML linting.
---

# Biome Toolchain

## Installation

```bash
npm install --save-dev --save-exact @biomejs/biome
npx biome init
```

Use `--save-exact` — Biome minor versions may add/change rules.

## biome.json Configuration

Place `biome.json` or `biome.jsonc` at the project root.

```jsonc
{
  "$schema": "https://biomejs.dev/schemas/2.2.7/schema.json",
  "files": {
    "includes": ["src/**", "tests/**"],
    "ignore": ["dist", "build", "coverage", "node_modules"]
  },
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true,
    "defaultBranch": "main"
  },
  "formatter": {
    "enabled": true,
    "indentStyle": "space",
    "indentWidth": 2,
    "lineWidth": 100,
    "lineEnding": "lf"
  },
  "linter": {
    "enabled": true,
    "rules": { "recommended": true }
  },
  "organizeImports": { "enabled": true }
}
```

### Key Top-Level Fields

- `$schema` — editor autocomplete; pin version or use `latest`.
- `extends` — config inheritance: `["./shared-biome.json"]`.
- `files.includes` / `files.ignore` — glob patterns controlling scope.
- `files.maxSize` — skip files above byte limit (default 1MB).
- `vcs` — respect `.gitignore`, enable diff-based checks via `defaultBranch`.

## Formatter Options

```jsonc
{
  "formatter": {
    "indentStyle": "tab",       // "tab" | "space"
    "indentWidth": 2,           // 1-24
    "lineWidth": 80,            // 1-320
    "lineEnding": "lf",         // "lf" | "crlf" | "cr"
    "formatWithErrors": false,
    "ignore": ["generated/**"]
  },
  "javascript": {
    "formatter": {
      "quoteStyle": "single",          // "single" | "double"
      "jsxQuoteStyle": "double",
      "semicolons": "asNeeded",        // "always" | "asNeeded"
      "trailingCommas": "all",         // "all" | "es5" | "none"
      "arrowParentheses": "always",    // "always" | "asNeeded"
      "bracketSpacing": true,
      "bracketSameLine": false,
      "quoteProperties": "asNeeded"
    }
  },
  "css": { "formatter": { "quoteStyle": "double", "enabled": true } },
  "json": { "formatter": { "trailingCommas": "none", "enabled": true } }
}
```

## Linter Configuration

### Rule Categories

| Category | Purpose | Examples |
|----------|---------|----------|
| `suspicious` | Likely bugs | `noDebugger`, `noDoubleEquals`, `noExplicitAny` |
| `correctness` | Definite errors | `noConstAssign`, `noUndeclaredVariables`, `useExhaustiveDependencies` |
| `style` | Consistency | `useConst`, `noDefaultExport`, `useTemplate`, `noVar` |
| `complexity` | Simplicity | `noExtraBooleanCast`, `useFlatMap`, `noForEach` |
| `a11y` | Accessibility | `useAltText`, `noBlankTarget`, `useValidAriaRole` |
| `performance` | Efficiency | `noAccumulatingSpread`, `noBarrelFile`, `noDelete` |
| `security` | Safety | `noGlobalEval`, `noDangerouslySetInnerHtml` |
| `nursery` | Experimental | Unstable rules before promotion |

### Rule Severity

Rules accept `"error"` | `"warn"` | `"off"`, or object form with options:

```jsonc
"style": { "useConst": "error" },
"suspicious": { "noConsole": { "level": "warn", "options": { "allow": ["error", "warn"] } } }
```

Set `"recommended": true` for curated defaults, then override individual rules. Use `"all": true` for strict mode. See [`references/api-reference.md`](references/api-reference.md) for all rules.

## CLI Commands

```bash
# Check: lint + format + import sort (read-only)
npx biome check .
npx biome check --write .              # apply all safe fixes
npx biome check --write --unsafe .      # include unsafe fixes

# Lint only
npx biome lint src/
npx biome lint --write src/

# Format only
npx biome format src/
npx biome format --write src/

# CI mode: read-only, strict exit codes
npx biome ci .

# Migration
npx biome migrate eslint --write
npx biome migrate prettier --write

# GritQL search
npx biome search 'console.log($msg)' src/
```

### Useful Flags

```bash
--changed                 # Files changed since defaultBranch
--staged                  # Git-staged files only (pre-commit)
--config-path ./config    # Custom config directory
--diagnostic-level=warn   # Minimum severity to report
--max-diagnostics=50      # Cap diagnostics count
--colors=off              # Disable colors (CI logs)
```

## Overrides

Apply different settings per file pattern:

```jsonc
{
  "overrides": [
    {
      "include": ["**/*.test.ts", "**/*.spec.ts"],
      "linter": { "rules": { "suspicious": { "noConsole": "off" } } }
    },
    {
      "include": ["*.config.ts", "*.config.js"],
      "linter": { "rules": { "style": { "noDefaultExport": "off" } } }
    },
    {
      "include": ["scripts/**"],
      "formatter": { "lineWidth": 120 }
    }
  ]
}
```

## Ignore Patterns

Three mechanisms:

1. **`files.ignore`** in `biome.json` — global exclusion.
2. **Per-tool** — `formatter.ignore`, `linter.ignore` for granular control.
3. **VCS** — `vcs.useIgnoreFile: true` respects `.gitignore`.

Inline suppression:

```typescript
// biome-ignore lint/suspicious/noDebugger: needed for dev
debugger;

// biome-ignore format: keep manual alignment
const matrix = [
  [1, 0, 0],
  [0, 1, 0],
];

// Range suppression
// biome-ignore-start lint/suspicious/noConsole
console.log("debug start");
console.log("debug end");
// biome-ignore-end lint/suspicious/noConsole
```

## VCS Integration & Pre-Commit Hooks

```jsonc
{
  "vcs": {
    "enabled": true,
    "clientKind": "git",
    "useIgnoreFile": true,
    "defaultBranch": "main"
  }
}
```

Husky pre-commit (`.husky/pre-commit`):

```bash
npx biome check --staged --write --no-errors-on-unmatched
```

Lefthook (`lefthook.yml`):

```yaml
pre-commit:
  commands:
    biome:
      glob: "*.{js,ts,jsx,tsx,json,css}"
      run: npx biome check --staged --write --no-errors-on-unmatched {staged_files}
```

## Editor Setup

### VS Code

Install `biomejs.biome` extension. Add to `.vscode/settings.json`:

```json
{
  "editor.defaultFormatter": "biomejs.biome",
  "editor.formatOnSave": true,
  "editor.codeActionsOnSave": {
    "source.fixAll.biome": "explicit",
    "source.organizeImports.biome": "explicit"
  },
  "[javascript]": { "editor.defaultFormatter": "biomejs.biome" },
  "[typescript]": { "editor.defaultFormatter": "biomejs.biome" },
  "[typescriptreact]": { "editor.defaultFormatter": "biomejs.biome" },
  "[json]": { "editor.defaultFormatter": "biomejs.biome" },
  "[css]": { "editor.defaultFormatter": "biomejs.biome" }
}
```

### JetBrains (WebStorm / IntelliJ)

Install "Biome" from Marketplace. Auto-detects binary from `node_modules`. Configure at `Settings → Languages & Frameworks → Biome`.

## Migration from ESLint / Prettier

```bash
# 1. Install
npm install --save-dev --save-exact @biomejs/biome

# 2. Migrate configs (reads .eslintrc* / .prettierrc* → biome.json)
npx biome migrate eslint --write
npx biome migrate prettier --write

# 3. Verify
npx biome check .

# 4. Remove old tools
npm uninstall eslint prettier eslint-config-prettier eslint-plugin-import \
  @typescript-eslint/parser @typescript-eslint/eslint-plugin
rm .eslintrc* .prettierrc* .eslintignore .prettierignore
```

### Rule Mapping (Common)

| ESLint Rule | Biome Rule |
|-------------|-----------|
| `no-debugger` | `suspicious/noDebugger` |
| `no-console` | `suspicious/noConsole` |
| `eqeqeq` | `suspicious/noDoubleEquals` |
| `prefer-const` | `style/useConst` |
| `no-var` | `style/noVar` |
| `@typescript-eslint/no-explicit-any` | `suspicious/noExplicitAny` |
| `react-hooks/exhaustive-deps` | `correctness/useExhaustiveDependencies` |
| `jsx-a11y/alt-text` | `a11y/useAltText` |

### package.json Scripts

```jsonc
{
  "scripts": {
    "check": "biome check .",
    "check:fix": "biome check --write .",
    "lint": "biome lint .",
    "lint:fix": "biome lint --write .",
    "format": "biome format --write ."
  }
}
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Code Quality
on: [push, pull_request]
jobs:
  biome:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: biomejs/setup-biome@v2
        with:
          version: latest
      - run: biome ci .
```

### With npm Project

```yaml
jobs:
  quality:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: npm }
      - run: npm ci
      - run: npx biome ci .
```

Diff-only in large repos: `biome ci --changed --since=origin/main .`

## Monorepo Support

Nested `biome.json` files inherit from parents automatically (Biome walks up directory tree). Use `extends` for non-parent shared configs:

```
monorepo/
├── biome.json              ← shared base
├── packages/
│   ├── app/biome.json      ← inherits base, overrides as needed
│   └── lib/biome.json
```

```jsonc
// packages/app/biome.json
{
  "extends": ["../../shared/biome-react.json"],
  "linter": { "rules": { "style": { "noDefaultExport": "off" } } }
}
```

## CSS / JSON / GraphQL Support

```jsonc
{
  "css": {
    "formatter": { "enabled": true, "quoteStyle": "double" },
    "linter": { "enabled": true }
  },
  "json": {
    "formatter": { "enabled": true, "trailingCommas": "none" },
    "linter": { "enabled": true }
  },
  "graphql": { "formatter": { "enabled": true } }
}
```

CSS: standard CSS only (no SCSS/Less/Sass). JSON: auto-detects JSONC for `tsconfig.json` etc.

## GritQL Custom Rules (Plugins)

Register `.grit` files in `biome.json`:

```jsonc
{ "plugins": ["./biome-plugins/no-moment.grit"] }
```

Ban moment.js imports:

```grit
`import $_ from "moment"` => . where {
  register_diagnostic(
    message = "Use date-fns or Temporal API instead of moment.js",
    severity = "error"
  )
}
```

Enforce strict equality:

```grit
`$left == $right` where {
  $right <: not `null`,
  $left <: not `null`,
  register_diagnostic(
    message = "Use === instead of ==. Loose equality only for null checks.",
    severity = "warn"
  )
}
```

## Biome Assist & Import Organizing

```jsonc
{
  "assist": {
    "enabled": true,
    "actions": { "source": { "useSortedKeys": "on" } }
  },
  "organizeImports": { "enabled": true }
}
```

Assist provides non-lint transforms (e.g., sort object keys). Import organizing sorts, deduplicates, and groups imports on `biome check --write`.

## Common Project Templates

For full ready-to-use templates, see [`assets/`](assets/). Quick examples:

**Strict TypeScript** — use [`assets/biome.strict.template.jsonc`](assets/biome.strict.template.jsonc) or inline:

```jsonc
{
  "$schema": "https://biomejs.dev/schemas/2.2.7/schema.json",
  "linter": {
    "rules": {
      "recommended": true,
      "suspicious": { "noExplicitAny": "error" },
      "style": { "useConst": "error", "noVar": "error" },
      "performance": { "noAccumulatingSpread": "error" }
    }
  },
  "formatter": { "indentStyle": "space", "indentWidth": 2, "lineWidth": 100 },
  "javascript": { "formatter": { "quoteStyle": "single", "semicolons": "always" } }
}
```

**React / Next.js** — use [`assets/biome.react.template.jsonc`](assets/biome.react.template.jsonc) or inline:

```jsonc
{
  "$schema": "https://biomejs.dev/schemas/2.2.7/schema.json",
  "linter": {
    "rules": {
      "recommended": true,
      "a11y": { "recommended": true },
      "correctness": { "useExhaustiveDependencies": "warn", "useHookAtTopLevel": "error" }
    }
  },
  "overrides": [
    { "include": ["app/**/page.tsx", "app/**/layout.tsx"], "linter": { "rules": { "style": { "noDefaultExport": "off" } } } }
  ]
}
```

## Performance

- Rust-native with multi-threaded processing — 10-25x faster than ESLint + Prettier.
- Single binary with no plugin resolution or JS runtime overhead.
- Use `--changed` in CI for incremental checks on large repos.
- `biome ci` is optimized for CI with minimal overhead and strict exit codes.

---

## Additional Resources

### Reference Documentation

| Document | Contents |
|----------|----------|
| [`references/advanced-patterns.md`](references/advanced-patterns.md) | Rule customization deep-dive, nursery rules, GritQL custom lint rules, per-file overrides, formatter philosophy, bundler integration (Vite/webpack/esbuild), pre-commit hooks, monorepo strategies, Biome Assist, import sorting/organize imports, domains (v2) |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Parse errors, config validation errors, conflicting rules, ESLint/Prettier migration issues, v1→v2 migration, CI/CD failures, editor integration (VS Code/JetBrains), performance tuning, rule suppression patterns, handling third-party/generated code |
| [`references/api-reference.md`](references/api-reference.md) | Complete biome.json schema, all linter rule categories with individual rules (suspicious/correctness/style/complexity/a11y/performance/security/nursery), formatter options per language (JS/TS/JSON/CSS/GraphQL), CLI commands and flags, exit codes, reporters, ignore patterns |

### Scripts

| Script | Purpose |
|--------|---------|
| [`scripts/init-biome.sh`](scripts/init-biome.sh) | Set up Biome in existing project — installs Biome, auto-migrates from ESLint/Prettier if detected, creates biome.json (`--strict` or `--react` modes), configures VS Code, adds npm scripts |
| [`scripts/lint-check.sh`](scripts/lint-check.sh) | Run Biome checks with modes: `check`, `lint`, `format`, `fix`, `fix-all`, `ci`, `changed`, `staged` — outputs timing and summary |

### Templates

| Template | Use Case |
|----------|----------|
| [`assets/biome.strict.template.jsonc`](assets/biome.strict.template.jsonc) | Strict TypeScript config — all recommended + extra strict rules, naming conventions, import sorting, nursery rules |
| [`assets/biome.react.template.jsonc`](assets/biome.react.template.jsonc) | React/Next.js config — a11y rules, hook validation, Next.js App Router overrides, Storybook support, import groups with React first |
| [`assets/ci-workflow.template.yml`](assets/ci-workflow.template.yml) | GitHub Actions workflow — Biome CI with annotations, diff-only option, caching |

<!-- tested: pass -->
