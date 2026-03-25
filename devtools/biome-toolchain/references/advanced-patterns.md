# Biome Advanced Patterns

> Dense reference for advanced Biome configuration, customization, and integration patterns.

## Table of Contents

- [Rule Customization Deep-Dive](#rule-customization-deep-dive)
- [Nursery Rules](#nursery-rules)
- [Domains (Biome v2)](#domains-biome-v2)
- [Custom Lint Rules with GritQL](#custom-lint-rules-with-gritql)
- [Per-File Overrides](#per-file-overrides)
- [Workspace and Multi-Config Setup](#workspace-and-multi-config-setup)
- [Formatter Philosophy](#formatter-philosophy)
- [Integration with Bundlers](#integration-with-bundlers)
- [Pre-Commit Hooks](#pre-commit-hooks)
- [Monorepo Strategies](#monorepo-strategies)
- [Biome Assist](#biome-assist)
- [Import Sorting and Organize Imports](#import-sorting-and-organize-imports)

---

## Rule Customization Deep-Dive

### Severity Levels

Every rule accepts three severity forms:

```jsonc
{
  "linter": {
    "rules": {
      "style": {
        "useConst": "error",       // simple string: "error" | "warn" | "off"
        "noVar": "warn"
      },
      "suspicious": {
        "noConsole": {              // object form with options
          "level": "warn",
          "options": { "allow": ["error", "warn", "info"] }
        }
      }
    }
  }
}
```

### Bulk Enable Strategies

| Strategy | Effect |
|----------|--------|
| `"recommended": true` | Curated defaults — safe for most projects |
| `"all": true` | Every stable rule enabled — strict mode |
| `"recommended": true` + overrides | Best practice: start recommended, tighten selectively |

```jsonc
{
  "linter": {
    "rules": {
      "all": true,
      // Then disable individual rules that are too strict
      "style": { "noDefaultExport": "off" },
      "complexity": { "noForEach": "off" }
    }
  }
}
```

### Rule Options — Complex Examples

**Custom hook dependencies** (React):
```jsonc
"correctness": {
  "useExhaustiveDependencies": {
    "level": "warn",
    "options": {
      "hooks": [
        { "name": "useMyEffect", "closureIndex": 0, "dependenciesIndex": 1 },
        { "name": "useCustomQuery", "stableResult": true }
      ]
    }
  }
}
```

**Naming conventions:**
```jsonc
"style": {
  "useNamingConvention": {
    "level": "warn",
    "options": {
      "conventions": [
        { "selector": { "kind": "variable" }, "formats": ["camelCase", "CONSTANT_CASE"] },
        { "selector": { "kind": "typeLike" }, "formats": ["PascalCase"] },
        { "selector": { "kind": "enumMember" }, "formats": ["PascalCase", "CONSTANT_CASE"] }
      ]
    }
  }
}
```

**Restricted imports:**
```jsonc
"suspicious": {
  "noRestrictedImports": {
    "level": "error",
    "options": {
      "paths": {
        "lodash": "Use lodash-es or native alternatives",
        "moment": "Use date-fns or Temporal API"
      }
    }
  }
}
```

---

## Nursery Rules

Nursery rules are experimental — not enabled by `"recommended": true` or `"all": true`. You must opt in individually.

### When to Use Nursery Rules

- **Early adopters**: Get ahead of upcoming best practices
- **Strict projects**: Catch more issues at the cost of potential false positives
- **Feedback**: Help Biome stabilize rules by reporting issues

### Enabling Nursery Rules

```jsonc
{
  "linter": {
    "rules": {
      "recommended": true,
      "nursery": {
        "noImportCycles": "error",
        "noFloatingPromises": "warn",
        "noMissingGenericFamilyKeyword": "warn",
        "noCommonJs": "error",
        "noEnum": "warn",
        "useAtIndex": "warn",
        "useSortedClasses": "warn"
      }
    }
  }
}
```

### Notable Nursery Rules (subject to change)

| Rule | Purpose |
|------|---------|
| `noImportCycles` | Detect circular imports (multi-file analysis) |
| `noFloatingPromises` | Require handling of Promises |
| `noCommonJs` | Disallow `require()`/`module.exports` |
| `noEnum` | Prefer union types over `enum` |
| `noMisplacedAssertion` | Test assertions in wrong context |
| `useAtIndex` | Prefer `.at()` over bracket access for negative indices |
| `useSortedClasses` | Sort Tailwind CSS classes |
| `useImportRestrictions` | Restrict deep imports from packages |

> **Warning**: Nursery rules may change behavior, be renamed, or be removed between minor versions. Pin `@biomejs/biome` with `--save-exact`.

---

## Domains (Biome v2)

Biome v2 introduces **domains** — technology-specific rule groupings that automatically enable relevant rules.

```jsonc
{
  "linter": {
    "domains": {
      "react": "recommended",   // Enable recommended React rules
      "next": "all",            // Enable all Next.js-related rules
      "solid": "none",          // Disable Solid.js rules
      "test": "recommended"     // Enable test-framework rules
    }
  }
}
```

Available domains: `react`, `next`, `solid`, `test`, `node` (growing list).

Biome can auto-detect domains from `package.json` dependencies when enabled, reducing config boilerplate.

---

## Custom Lint Rules with GritQL

GritQL plugins let you write project-specific lint rules as `.grit` files.

### Setup

```jsonc
// biome.json
{
  "plugins": [
    "./biome-plugins/no-moment.grit",
    "./biome-plugins/enforce-design-system.grit"
  ]
}
```

### Pattern Syntax

```
`code_pattern` => replacement where { conditions }
```

- Backticks wrap code patterns (AST-matched)
- `$variable` captures AST nodes
- `where { }` adds constraints
- `register_diagnostic()` reports findings

### Practical Examples

**Ban deprecated imports:**
```grit
`import $_ from $source` where {
  $source <: or { `"lodash"`, `"moment"`, `"uuid"` },
  register_diagnostic(
    span = $source,
    message = "This package is banned. See docs/adr/003-deps.md for alternatives.",
    severity = "error"
  )
}
```

**Enforce `for...of` over `.forEach()`:**
```grit
`$collection.forEach($...)` as $call where {
  register_diagnostic(
    span = $call,
    message = "Prefer `for...of` over `.forEach()` — it supports break, continue, and await.",
    severity = "warn"
  )
}
```

**Enforce strict equality (except null):**
```grit
`$left == $right` where {
  $right <: not `null`,
  $left <: not `null`,
  register_diagnostic(
    span = $left,
    message = "Use === instead of ==. Loose equality is only acceptable for null checks.",
    severity = "warn"
  )
}
```

**Ban raw DOM elements in JSX (enforce design system):**
```grit
language js
or {
  `<$tag />`,
  `<$tag $_ />`,
  `<$tag>$_</$_>`,
  `<$tag $_>$_</$_>`
} where {
  $tag <: r"^(div|span|button|input|a|p|h[1-6])$",
  register_diagnostic(
    span = $tag,
    message = "Use design system components instead of raw DOM elements.",
    severity = "error"
  )
}
```

**Search with GritQL (CLI only, no plugin needed):**
```bash
npx biome search 'console.log($msg)' src/
npx biome search '$x == null' --include='**/*.ts' src/
```

### Current Limitations

- Diagnostic-only (no autofix rewrites yet — planned)
- No npm plugin resolution — must use explicit file paths
- No sharing via npm packages yet

---

## Per-File Overrides

The `overrides` array applies different config per glob pattern. Evaluated top-to-bottom; later entries win.

### Common Override Patterns

```jsonc
{
  "overrides": [
    // Relax rules in test files
    {
      "include": ["**/*.test.ts", "**/*.spec.ts", "**/__tests__/**"],
      "linter": {
        "rules": {
          "suspicious": { "noExplicitAny": "off", "noConsole": "off" },
          "complexity": { "noForEach": "off" }
        }
      }
    },
    // Allow default exports in framework entry points
    {
      "include": ["*.config.ts", "*.config.js", "app/**/page.tsx", "app/**/layout.tsx"],
      "linter": {
        "rules": { "style": { "noDefaultExport": "off" } }
      }
    },
    // Wider line width for scripts
    {
      "include": ["scripts/**"],
      "formatter": { "lineWidth": 120 }
    },
    // Disable formatting for generated files
    {
      "include": ["src/generated/**"],
      "formatter": { "enabled": false },
      "linter": { "enabled": false }
    },
    // Different quote style for JSON
    {
      "include": ["**/*.json"],
      "json": { "formatter": { "trailingCommas": "none" } }
    }
  ]
}
```

### Override Precedence

1. Base config applies first
2. Overrides apply in array order
3. More specific globs should come later
4. Language-specific settings inside overrides work the same as top-level

---

## Workspace and Multi-Config Setup

### Config Resolution

Biome resolves config by walking up the directory tree from the file being processed:
1. Closest `biome.json` / `biome.jsonc` in the file's directory
2. Parent directories up to the project root
3. Child configs **inherit** from parent configs automatically

### `extends` for Shared Configs

```jsonc
// packages/app/biome.json
{
  "extends": ["../../shared/biome-base.json", "../../shared/biome-react.json"]
}
```

- Arrays merge (rules combine)
- Later extends entries override earlier ones
- Relative paths resolve from the config file's location

### Config Layering Strategy

```
monorepo/
├── biome.json                  ← base: formatter, shared rules
├── shared/
│   ├── biome-base.json         ← common rule overrides
│   └── biome-react.json        ← React-specific rules
├── packages/
│   ├── api/biome.json          ← extends base only
│   ├── web/biome.json          ← extends base + react
│   └── scripts/biome.json      ← extends base, relaxed
```

---

## Formatter Philosophy

### Opinionated by Design

Biome follows Prettier's philosophy: **minimize configuration, maximize consistency**. The formatter is intentionally opinionated:

- It does **not** attempt to match your existing style perfectly
- Line-breaking decisions prioritize readability over compactness
- ~97% compatibility with Prettier output

### What You Can Configure

| Option | Scope | Values |
|--------|-------|--------|
| `indentStyle` | Global | `"tab"` / `"space"` |
| `indentWidth` | Global | 1–24 |
| `lineWidth` | Global | 1–320 |
| `lineEnding` | Global | `"lf"` / `"crlf"` / `"cr"` |
| `quoteStyle` | JS/CSS | `"single"` / `"double"` |
| `jsxQuoteStyle` | JS | `"single"` / `"double"` |
| `semicolons` | JS | `"always"` / `"asNeeded"` |
| `trailingCommas` | JS | `"all"` / `"es5"` / `"none"` |
| `arrowParentheses` | JS | `"always"` / `"asNeeded"` |
| `bracketSpacing` | JS | `true` / `false` |
| `bracketSameLine` | JS | `true` / `false` |
| `quoteProperties` | JS | `"asNeeded"` / `"preserve"` |
| `attributePosition` | JS | `"auto"` / `"multiline"` |

### What You Cannot Configure

- Line-breaking algorithm (Prettier-compatible heuristics)
- Whitespace between statements
- Comment placement rules
- Parenthesization of expressions

### Formatter vs Linter Boundary

Biome deliberately separates formatting (whitespace, line breaks, quotes) from linting (code patterns, best practices). Use `// biome-ignore format:` to suppress formatting, not lint suppression.

---

## Integration with Bundlers

Biome operates **independently** of your build tool. It runs as a separate step — not as a bundler plugin.

### Vite

```jsonc
// package.json
{
  "scripts": {
    "dev": "vite",
    "build": "biome check . && vite build",
    "lint": "biome check ."
  }
}
```

For Vite plugin integration (optional, shows errors in overlay):
```bash
npm install -D vite-plugin-biome  # community plugin — verify current status
```

### Webpack

```jsonc
// package.json
{
  "scripts": {
    "build": "biome check . && webpack --mode production",
    "lint": "biome check ."
  }
}
```

### esbuild

```bash
biome check src/ && esbuild src/index.ts --bundle --outdir=dist
```

### General Pattern

Run Biome **before** the build step in your pipeline. This ensures:
- Fast fail on lint/format errors before expensive compilation
- No bundler coupling — Biome works on source files directly
- Parallel execution possible (Biome is fast enough to run alongside type-checking)

```jsonc
// package.json — recommended script setup
{
  "scripts": {
    "check": "biome check .",
    "check:fix": "biome check --write .",
    "typecheck": "tsc --noEmit",
    "build": "npm run check && npm run typecheck && vite build",
    "ci": "biome ci . && tsc --noEmit"
  }
}
```

---

## Pre-Commit Hooks

### Biome's Built-in `--staged` Flag

Biome natively supports staged file filtering — you may not need `lint-staged` at all:

```bash
npx biome check --staged --write --no-errors-on-unmatched
```

### Husky Setup

```bash
npm install -D husky
npx husky init
```

`.husky/pre-commit`:
```bash
npx biome check --staged --write --no-errors-on-unmatched
git update-index --again  # re-stage auto-fixed files
```

### Lefthook Setup (recommended for speed)

```yaml
# lefthook.yml
pre-commit:
  commands:
    biome-check:
      glob: "*.{js,ts,jsx,tsx,json,css,graphql}"
      run: npx biome check --write --no-errors-on-unmatched --staged {staged_files}
      stage_fixed: true
```

### lint-staged (if needed for multi-tool pipelines)

```jsonc
// package.json
{
  "lint-staged": {
    "*.{js,ts,jsx,tsx}": ["biome check --write --no-errors-on-unmatched"],
    "*.{json,css}": ["biome format --write"],
    "*.py": ["ruff check --fix"]
  }
}
```

### Comparison

| Approach | Pros | Cons |
|----------|------|------|
| Biome `--staged` directly | Simplest, fastest | Single-tool only |
| Husky + Biome `--staged` | Good DX, well-known | Node.js dependency |
| Lefthook + Biome | Fastest, polyglot | Less well-known |
| lint-staged | Multi-tool support | Extra dependency, slower |

---

## Monorepo Strategies

### Strategy 1: Root Config + Package Overrides

```
monorepo/
├── biome.json              ← shared base config
├── packages/
│   ├── app/
│   │   └── biome.json      ← overrides for app (inherits root)
│   ├── lib/
│   │   └── biome.json      ← overrides for lib
│   └── cli/                ← no biome.json → uses root config
```

### Strategy 2: Shared Config via `extends`

```jsonc
// packages/app/biome.json
{
  "extends": ["../../config/biome-react.json"],
  "linter": { "rules": { "style": { "noDefaultExport": "off" } } }
}
```

### Strategy 3: Single Root Config with Overrides

For simpler monorepos, use one config with `overrides`:

```jsonc
{
  "overrides": [
    {
      "include": ["packages/app/**"],
      "linter": { "rules": { "a11y": { "recommended": true } } }
    },
    {
      "include": ["packages/cli/**"],
      "linter": { "rules": { "suspicious": { "noConsole": "off" } } }
    }
  ]
}
```

### CI for Monorepos

```bash
# Check only changed files (fast CI)
biome ci --changed --since=origin/main .

# Check a specific package
biome check packages/app/
```

---

## Biome Assist

Assist provides code actions that are **not lint rules** — they transform code without diagnosing errors.

### Configuration

```jsonc
{
  "assist": {
    "enabled": true,
    "actions": {
      "source": {
        "organizeImports": "on",
        "useSortedKeys": "on"
      }
    }
  }
}
```

### Available Actions

| Action | Effect |
|--------|--------|
| `organizeImports` | Sort and group imports/exports |
| `useSortedKeys` | Sort object keys alphabetically |

### Running Assist Only

```bash
# Run only assist actions (no lint, no format)
npx biome check --formatter-enabled=false --linter-enabled=false .

# Run everything including assist
npx biome check --write .
```

### VS Code Integration

```jsonc
// .vscode/settings.json
{
  "editor.codeActionsOnSave": {
    "source.organizeImports.biome": "explicit",
    "source.fixAll.biome": "explicit"
  }
}
```

---

## Import Sorting and Organize Imports

### Basic Setup

```jsonc
{
  "assist": {
    "actions": {
      "source": {
        "organizeImports": "on"
      }
    }
  }
}
```

### Custom Import Groups

```jsonc
{
  "assist": {
    "actions": {
      "source": {
        "organizeImports": {
          "level": "on",
          "options": {
            "groups": [
              ":NODE:",                              // Node built-ins (fs, path, etc.)
              ":PACKAGE:",                           // npm packages
              ":BLANK_LINE:",
              ["@app/**", "@components/**", "@lib/**"],  // project aliases
              ":BLANK_LINE:",
              ["./**", "../**"]                      // relative imports
            ]
          }
        }
      }
    }
  }
}
```

### Special Group Tokens

| Token | Matches |
|-------|---------|
| `:NODE:` | Node.js built-in modules |
| `:PACKAGE:` | npm packages |
| `:BLANK_LINE:` | Insert blank line separator |
| Glob patterns | Custom path matching |

### How Sorting Works

1. Imports are split into **chunks** (separated by non-import code or comments)
2. Within each chunk, imports are sorted by:
   - Group order (as configured)
   - Kind (type imports after value imports within same group)
   - Source path (alphabetical)
3. Duplicate imports are merged
4. Unused imports are removed (if lint rule `noUnusedImports` is active)

### Example Result

```typescript
// :NODE:
import { readFile } from 'node:fs/promises';
import path from 'node:path';

// :PACKAGE:
import { useQuery } from '@tanstack/react-query';
import React from 'react';

// Project aliases
import { Button } from '@components/Button';
import { db } from '@lib/database';

// Relative
import { helper } from './utils';
```

### Troubleshooting Import Sorting

- If aliases aren't grouped correctly, verify glob patterns match your `tsconfig.json` paths
- Side-effect imports (`import './styles.css'`) are preserved in place and not reordered
- Use `// biome-ignore format:` above an import block to preserve manual ordering
