---
name: oxc
description: |
  High-performance JS/TS linter written in Rust. Use for fast linting of large codebases.
  NOT for projects requiring full ESLint compatibility or custom rules.
---

# OXC (Oxidation Compiler)

Rust-based JavaScript/TypeScript toolchain. Oxc linter (`oxlint`) is 50-100x faster than ESLint.

## When to Use

**USE OXC:**
- Large codebases (10k+ files) needing fast CI linting
- Projects wanting zero-config sensible defaults
- Teams prioritizing speed over plugin ecosystem
- Monorepos with many packages

**USE ESLint INSTEAD:**
- Need custom rules or plugins
- Require autofix for all rules
- Using Prettier integration via ESLint
- Need specific ESLint ecosystem tools

## Installation

```bash
# Global install
npm install -g oxlint

# Project install (recommended)
npm install -D oxlint

# npx (no install)
npx oxlint@latest
```

## Quick Start

```bash
# Lint current directory
npx oxlint

# Lint specific paths
npx oxlint src/
npx oxlint src/ tests/

# Auto-fix issues
npx oxlint --fix

# Show all rules
npx oxlint --rules
```

## Configuration

### `.oxlintrc.json`

```json
{
  "rules": {
    "eqeqeq": "error",
    "no-console": "warn",
    "no-debugger": "error"
  },
  "env": {
    "browser": true,
    "es2021": true,
    "node": true
  },
  "globals": {
    "myGlobal": "readonly"
  }
}
```

### `oxlint.config.js` (ESM)

```javascript
export default {
  rules: {
    'eqeqeq': 'error',
    'no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    '@typescript-eslint/no-explicit-any': 'warn'
  },
  env: {
    browser: true,
    node: true,
    jest: true
  },
  ignorePatterns: [
    'dist/**',
    'node_modules/**',
    '*.config.js'
  ]
};
```

### CLI Flags

```bash
# Config file path
npx oxlint --config ./custom-oxlintrc.json

# Disable config, use defaults
npx oxlint --no-config

# Specific rules only
npx oxlint --rules eqeqeq,no-console

# Disable specific rules
npx oxlint --deny-no-console --allow-eqeqeq

# Output format
npx oxlint --format json
npx oxlint --format unix
npx oxlint --format checkstyle

# Quiet (errors only)
npx oxlint --quiet

# Max warnings (exit code)
npx oxlint --max-warnings 10
```

## Rule Categories

```bash
# Enable all recommended rules (default)
npx oxlint

# Enable all rules (aggressive)
npx oxlint --all

# Specific categories
npx oxlint --correctness      # Bug prevention
npx oxlint --suspicious       # Likely mistakes
npx oxlint --perf             # Performance issues
npx oxlint --style            # Style/consistency
npx oxlint --restriction      # Restrictive patterns
npx oxlint --pedantic         # Pedantic checks
```

## TypeScript Support

```bash
# Auto-detects .ts, .tsx, .mts, .cts
npx oxlint src/

# With tsconfig for path resolution
npx oxlint --tsconfig ./tsconfig.json

# Check specific TS rules
npx oxlint --rules @typescript-eslint/no-explicit-any
```

## React/JSX Support

```bash
# Auto-detects JSX
npx oxlint src/

# React-specific rules
npx oxlint --rules react/jsx-key,react/no-danger
```

## Monorepo Setup

```bash
# Root config, lint all packages
npx oxlint packages/

# Per-package configs
# packages/app/.oxlintrc.json
# packages/lib/.oxlintrc.json
```

### Root `.oxlintrc.json`

```json
{
  "root": true,
  "rules": {
    "eqeqeq": "error"
  },
  "overrides": [
    {
      "files": ["packages/app/**/*"],
      "rules": {
        "no-console": "warn"
      }
    },
    {
      "files": ["packages/lib/**/*"],
      "rules": {
        "no-console": "error"
      }
    }
  ]
}
```

## Package.json Scripts

```json
{
  "scripts": {
    "lint": "oxlint .",
    "lint:fix": "oxlint . --fix",
    "lint:ci": "oxlint . --max-warnings 0",
    "lint:changed": "oxlint $(git diff --name-only HEAD | grep -E '\.(js|ts|jsx|tsx)$')"
  }
}
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Lint
on: [push, pull_request]
jobs:
  oxlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npx oxlint --max-warnings 0
```

### Fast CI (no npm install)

```yaml
jobs:
  oxlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npx oxlint@latest --max-warnings 0
```

### Pre-commit Hook

```yaml
# .pre-commit-config.yaml
repos:
  - repo: local
    hooks:
      - id: oxlint
        name: oxlint
        entry: npx oxlint
        language: system
        files: '\.(js|ts|jsx|tsx)$'
```

## IDE Integration

### VS Code

**Extension:** `oxc.oxc-vscode`

```json
// .vscode/settings.json
{
  "oxc.enable": true,
  "oxc.configPath": ".oxlintrc.json",
  "editor.codeActionsOnSave": {
    "source.fixAll.oxc": "explicit"
  }
}
```

### Vim/Neovim

```lua
-- nvim-lint
require('lint').linters.oxlint = {
  cmd = 'oxlint',
  args = { '--format', 'json' },
  parser = require('lint.parser').from_errorformat('%f:%l:%c: %m')
}

require('lint').linters_by_ft = {
  javascript = { 'oxlint' },
  typescript = { 'oxlint' }
}
```

### Zed

```json
// .zed/settings.json
{
  "lsp": {
    "oxc": {
      "binary": {
        "path": "oxlint",
        "arguments": ["--lsp"]
      }
    }
  }
}
```

## Migration from ESLint

### 1. Run Both (Gradual)

```json
{
  "scripts": {
    "lint": "eslint . && oxlint .",
    "lint:fast": "oxlint ."
  }
}
```

### 2. Map ESLint Config

| ESLint | OXC |
|--------|-----|
| `.eslintrc.json` | `.oxlintrc.json` |
| `extends: ['eslint:recommended']` | Default behavior |
| `plugins: ['@typescript-eslint']` | Built-in |
| `plugins: ['react']` | Built-in |
| `env: { node: true }` | `"env": { "node": true }` |
| `globals` | `"globals": { "name": "readonly" }` |
| `ignorePatterns` | `"ignorePatterns": []` |
| `overrides` | `"overrides": []` |

### 3. Rule Mapping

```bash
# See available rules
npx oxlint --rules

# Common equivalents
eslint: eqeqeq          -> oxlint: eqeqeq
eslint: no-console      -> oxlint: no-console
eslint: no-debugger     -> oxlint: no-debugger
@typescript-eslint/*   -> oxlint: @typescript-eslint/*
react/*                -> oxlint: react/*
```

### 4. Unsupported (Keep ESLint)

```javascript
// Keep ESLint for:
// - Custom rules
// - Prettier integration
// - import/no-unresolved (if needed)
// - Complex override patterns
```

## Performance Comparison

```bash
# ESLint
time npx eslint .  # ~30-60s for large codebase

# OXC
time npx oxlint .  # ~0.5-1s for same codebase
```

**Typical Speedup:** 50-100x

## Common Patterns

### Lint Staged Files Only

```bash
# lint-staged config
{
  "*.{js,ts,jsx,tsx}": ["oxlint --fix"]
}
```

### Filter by Severity

```bash
# Errors only
npx oxlint --quiet

# Specific exit codes
npx oxlint --max-warnings 0  # Fail on any warning
```

### Parallel with Other Tools

```json
{
  "scripts": {
    "check": "concurrently 'npm:lint:*'",
    "lint:oxc": "oxlint .",
    "lint:tsc": "tsc --noEmit",
    "lint:fmt": "prettier --check ."
  }
}
```

## Troubleshooting

### Rule not working

```bash
# Check if rule exists
npx oxlint --rules | grep rule-name

# Enable explicitly
npx oxlint --rules rule-name
```

### Config not loading

```bash
# Verbose output
npx oxlint --verbose

# Specify config path
npx oxlint --config ./path/to/config.json
```

### False positives

```json
{
  "rules": {
    "rule-name": "off"
  },
  "overrides": [
    {
      "files": ["test/**/*"],
      "rules": {
        "no-console": "off"
      }
    }
  ]
}
```

## Best Practices

1. **Start with defaults** - OXC has sensible defaults; add rules incrementally
2. **Use in CI** - Fast execution makes it perfect for CI gates
3. **Combine with tsc** - OXC for style/bugs, TypeScript for type checking
4. **Pre-commit hooks** - Instant feedback without slowing commits
5. **Gradual migration** - Run alongside ESLint, then remove ESLint when ready
6. **Team consistency** - Commit `.oxlintrc.json` to version control
7. **Document exceptions** - Use `// oxlint-disable-next-line` sparingly with comments

## Example Workflows

### New Project

```bash
npm init -y
npm install -D oxlint
npx oxlint --init  # Create config
npx oxlint .       # First run
```

### Existing ESLint Project

```bash
npm install -D oxlint
# Add to package.json scripts alongside eslint
# Migrate rules over time
# Remove eslint when confident
```

### Large Monorepo

```bash
# Root package.json
{
  "scripts": {
    "lint": "oxlint packages/",
    "lint:ci": "oxlint packages/ --max-warnings 0 --format json > lint-results.json"
  }
}
```
